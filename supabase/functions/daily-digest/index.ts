// daily-digest: sends each user their morning summary as a phone notification (Web Push) and, if set up, by email.
// Two ways in:
//  - the scheduler (Cloudflare Worker, every hour) with the x-cron-secret header: everyone whose digest time is now.
//    Only this path uses the service-role key (CLAUDE.md: cron-only).
//  - the app with your own token: "Send a test notification" to your devices, now.
// What goes in the digest is decided in SQL (_digest / my_digest / cron_digest); this file only formats and delivers.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "https://supermarket-assistant.pages.dev";
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND_FROM = Deno.env.get("RESEND_FROM") ?? "Pantry <onboarding@resend.dev>";
const APP_URL = Deno.env.get("APP_URL") ?? "https://supermarket-assistant.pages.dev";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

type Lot = { lot_id: string; name: string; name_es: string; date: string };
type Digest = { day: string; count: number; empty: boolean; expired: Lot[]; check: Lot[]; today: Lot[]; soon: Lot[]; still_have: Lot[];
  budget: { alert: string | null; pct: number | null; spent_cents: number; budget_cents: number | null; projected_cents: number | null; projection_alert: boolean } | null };
type Sub = { endpoint: string; keys: { p256dh: string; auth: string } };

const euro = (c: number | null | undefined) => c == null ? "" : `€${(c / 100).toFixed(2)}`;
const names = (ls: Lot[], max = 3) => ls.slice(0, max).map((l) => l.name).join(", ") + (ls.length > max ? ` +${ls.length - max}` : "");
const weekday = (iso: string) => new Date(`${iso}T12:00:00`).toLocaleDateString("en-GB", { weekday: "short" });

// Turn the digest groups into words (formatting only).
function words(d: Digest): { title: string; lines: string[] } {
  const lines: string[] = [];
  if (d.today.length) lines.push(`Use today: ${names(d.today)}`);
  if (d.soon.length) lines.push(`Next days: ${d.soon.slice(0, 3).map((l) => `${l.name} (${weekday(l.date)})`).join(", ")}${d.soon.length > 3 ? ` +${d.soon.length - 3}` : ""}`);
  if (d.expired.length) lines.push(`Past its date, bin it: ${names(d.expired)}`);
  if (d.check.length) lines.push(`Check it first: ${names(d.check)}`);
  if (d.still_have.length) lines.push(`Still have these? ${names(d.still_have)}`);
  const b = d.budget;
  if (b?.alert === "over") lines.push(`Budget: over (${euro(b.spent_cents)} of ${euro(b.budget_cents)})`);
  else if (b?.alert === "near") lines.push(`Budget: ${b.pct}% used (${euro(b.spent_cents)} of ${euro(b.budget_cents)})`);
  else if (b?.projection_alert) lines.push(`Budget: on course for about ${euro(b.projected_cents)} this month`);
  const title = d.count === 0 ? (b ? "Your budget" : "Nothing urgent today")
    : d.today.length ? `${d.today.length} to use today${d.count > d.today.length ? ` · ${d.count - d.today.length} more to look at` : ""}`
    : `${d.count} thing${d.count === 1 ? "" : "s"} in your kitchen to look at`;
  return { title, lines };
}

// Send one notification. Returns "ok", "gone" (the device unsubscribed: forget it) or an error text.
async function push(sub: Sub, payload: unknown): Promise<string> {
  try {
    const r = webpush.generateRequestDetails(sub, JSON.stringify(payload), {
      TTL: 12 * 3600, vapidDetails: { subject: VAPID_SUBJECT, publicKey: VAPID_PUBLIC, privateKey: VAPID_PRIVATE },
    });
    const res = await fetch(r.endpoint, { method: r.method, headers: r.headers as Record<string, string>, body: r.body as BodyInit });
    if (res.status === 404 || res.status === 410) return "gone";
    return res.ok ? "ok" : `push ${res.status}`;
  } catch (e) { return e instanceof Error ? e.message : "push failed"; }
}

async function email(to: string, title: string, lines: string[]): Promise<string> {
  if (!RESEND_KEY) return "no email key";
  const html = `<div style="font-family:system-ui,sans-serif;font-size:16px;color:#1D211C">
    <h2 style="font-family:Georgia,serif;color:#234032">${title}</h2>
    ${lines.map((l) => `<p style="margin:8px 0">${l.replace(/&/g, "&amp;").replace(/</g, "&lt;")}</p>`).join("")}
    <p style="margin-top:20px"><a href="${APP_URL}" style="color:#234032;font-weight:700">Open your pantry</a></p></div>`;
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST", headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: RESEND_FROM, to, subject: title, html, text: [title, ...lines, APP_URL].join("\n") }),
  });
  return res.ok ? "ok" : `email ${res.status}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  if (!VAPID_PUBLIC || !VAPID_PRIVATE) return json({ error: "NO_VAPID_KEYS" }, 500);

  // ── Scheduler path ──
  const secret = req.headers.get("x-cron-secret");
  if (secret !== null) {
    if (!CRON_SECRET || secret !== CRON_SECRET) return json({ error: "UNAUTHORIZED" }, 401);
    const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
    const due = await admin.rpc("cron_due_users");
    if (due.error) return json({ error: due.error.message }, 500);
    const report: unknown[] = [];
    for (const u of due.data as { user_id: string; email: string; email_digest: boolean; push: Sub[]; day: string }[]) {
      const d = await admin.rpc("cron_digest", { p_user: u.user_id });
      if (d.error || !d.data) { report.push({ user: u.user_id, error: d.error?.message ?? "no household" }); continue; }
      const dg = d.data as Digest;
      const r: Record<string, unknown> = { user: u.user_id, count: dg.count };
      if (!dg.empty) {
        const { title, lines } = words(dg);
        const results = [];
        for (const s of u.push ?? []) {
          const out = await push(s, { title, body: lines.join("\n"), count: dg.count, url: "/" });
          if (out === "gone") await admin.rpc("cron_drop_subscription", { p_user: u.user_id, p_endpoint: s.endpoint });
          results.push(out);
        }
        r.push = results;
        if (u.email_digest && u.email) r.email = await email(u.email, title, lines);
      }
      await admin.rpc("cron_mark_sent", { p_user: u.user_id, p_day: u.day });   // once a day, even when empty
      report.push(r);
    }
    const ret = await admin.rpc("cron_retention");
    return json({ ok: true, users: report, retention: ret.data ?? ret.error?.message });
  }

  // ── Test path: your own token, your own devices ──
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer /i, "");
  if (!token) return json({ error: "UNAUTHORIZED" }, 401);
  const db = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: claims, error: authErr } = await db.auth.getClaims(token);
  if (authErr || !claims?.claims?.sub) return json({ error: "UNAUTHORIZED" }, 401);
  const [d, s] = await Promise.all([db.rpc("my_digest"), db.from("user_settings").select("push_subscription").maybeSingle()]);
  if (d.error) return json({ error: d.error.message }, 400);
  const subs = (Array.isArray(s.data?.push_subscription) ? s.data!.push_subscription : []) as Sub[];
  if (!subs.length) return json({ error: "NO_DEVICES", message: "Turn on notifications on this device first." }, 400);
  const { title, lines } = words(d.data as Digest);
  const results = [];
  for (const sub of subs) {
    const out = await push(sub, { title: `Test · ${title}`, body: lines.join("\n") || "This is how your morning summary will arrive.", count: (d.data as Digest).count, url: "/" });
    if (out === "gone") await db.rpc("remove_push_subscription", { p_endpoint: sub.endpoint });
    results.push(out);
  }
  return json({ ok: true, devices: subs.length, results });
});
