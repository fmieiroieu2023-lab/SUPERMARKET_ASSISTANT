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

type Lot = { lot_id: string; name: string; name_es: string; date: string; qty: number; unit: string; location: string; kind: string };
type Digest = { day: string; count: number; empty: boolean; expired: Lot[]; check: Lot[]; today: Lot[]; soon: Lot[]; still_have: Lot[];
  budget: { alert: string | null; pct: number | null; spent_cents: number; budget_cents: number | null; projected_cents: number | null; projection_alert: boolean } | null;
  list: { count: number; estimate_cents: number; unknown: number } | null };
type Sub = { endpoint: string; keys: { p256dh: string; auth: string } };

// ── Wording (approved by Francisco, 2026-11-10). Order: today → soon → bin → check → still have → list → budget.
const euro = (c: number | null | undefined) => c == null ? "" : `€${(c / 100).toFixed(2)}`;
const join = (ls: string[]) => ls.join(", ");
const weekday = (iso: string) => new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-GB", { weekday: "short", timeZone: "UTC" });
const longDay = (iso: string) => new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" });
const daysAgo = (from: string, to: string) => Math.round((Date.parse(`${to}T12:00:00Z`) - Date.parse(`${from}T12:00:00Z`)) / 864e5);
const PLACE: Record<string, string> = { fridge: "fridge", freezer: "freezer", pantry: "cupboard" };
const qty = (l: Lot) => { const n = Number(l.qty); return l.unit === "unit" ? `${n} item${n === 1 ? "" : "s"}` : `${n} ${l.unit}`; };
const esc = (t: string) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function budgetLine(b: Digest["budget"]): string | null {
  if (!b) return null;
  if (b.alert === "over") return `💶 Budget: over (${euro(b.spent_cents)} of ${euro(b.budget_cents)})`;
  if (b.alert === "near") return `💶 Budget: ${b.pct}% used (${euro(b.spent_cents)} of ${euro(b.budget_cents)})`;
  if (b.projection_alert) return `💶 Budget: on course for about ${euro(b.projected_cents)} this month`;
  return null;
}
const listLine = (l: Digest["list"]) => l ? `🛒 List: ${l.count} item${l.count === 1 ? "" : "s"}${l.estimate_cents ? ` · about ${euro(l.estimate_cents)}` : ""}` : null;

function title(d: Digest): string {
  if (d.count > 0) return `🧺 ${d.count} item${d.count === 1 ? " needs" : "s need"} you today`;
  if (d.list) return `🛒 ${d.list.count} item${d.list.count === 1 ? "" : "s"} on your list`;
  return budgetLine(d.budget) ?? "🧺 Nothing urgent today";
}

// Phone notification: one line per group, only groups with something in them.
function pushText(d: Digest): { title: string; body: string } {
  const lines = [
    d.today.length ? `🔥 Use today: ${join(d.today.map((l) => l.name))}` : null,
    d.soon.length ? `⏳ Soon: ${join(d.soon.map((l) => `${l.name} (${weekday(l.date)})`))}` : null,
    d.expired.length ? `🗑️ Bin: ${join(d.expired.map((l) => l.name))}` : null,
    d.check.length ? `👀 Check: ${join(d.check.map((l) => l.name))}` : null,
    d.still_have.length ? `❓ Still have?: ${join(d.still_have.map((l) => l.name))}` : null,
    d.count > 0 || d.budget ? listLine(d.list) : null,   // when the list is the only news, it is the title
    budgetLine(d.budget) && (d.count > 0 || d.list) ? budgetLine(d.budget) : null,
  ].filter(Boolean) as string[];
  const quiet = d.list && d.count === 0 ? `${d.list.estimate_cents ? `About ${euro(d.list.estimate_cents)} · ` : ""}tap to see it` : "Open the app to see your kitchen.";
  return { title: title(d), body: lines.join("\n") || quiet };
}

// Email: the same content as a page, with Spanish names, quantities and a button.
function emailHtml(d: Digest): { subject: string; html: string; text: string } {
  const es = (l: Lot) => l.name_es && l.name_es.toLowerCase() !== l.name.toLowerCase() ? ` <span style="color:#6B7166;font-style:italic">(${esc(l.name_es)})</span>` : "";
  const section = (icon: string, head: string, items: string[]) => items.length
    ? `<tr><td style="padding:14px 0 4px;font-size:17px;font-weight:700;color:#234032">${icon} ${head}</td></tr>` +
      items.map((i) => `<tr><td style="padding:3px 0 3px 26px;font-size:16px;color:#1D211C">• ${i}</td></tr>`).join("")
    : "";
  const ago = (l: Lot) => { const n = daysAgo(l.date, d.day); return n === 1 ? "yesterday" : `${n} days ago`; };
  const rows = [
    section("🔥", "Use today", d.today.map((l) => `${esc(l.name)}${es(l)}, ${qty(l)} · ${PLACE[l.location] ?? l.location}`)),
    section("⏳", "Soon", d.soon.map((l) => `${esc(l.name)}${es(l)}, ${weekday(l.date)}`)),
    section("🗑️", "Bin", d.expired.map((l) => `${esc(l.name)}${es(l)} (${l.kind === "use_by" ? "use-by" : "date"} was ${ago(l)})`)),
    section("👀", "Check", d.check.map((l) => `${esc(l.name)}${es(l)} (past its best-before, look and smell first)`)),
    section("❓", "Still have these?", d.still_have.map((l) => `${esc(l.name)}${es(l)}`)),
    d.list ? section("🛒", "Shopping list", [`${d.list.count} item${d.list.count === 1 ? "" : "s"}${d.list.estimate_cents ? `, about ${euro(d.list.estimate_cents)}` : ""}`]) : "",
    budgetLine(d.budget) ? section("💶", "Budget", [esc(budgetLine(d.budget)!.replace(/^💶 Budget: /, ""))]) : "",
  ].join("");
  const subject = title(d);
  const html = `<!doctype html><html><body style="margin:0;background:#F0EDE6">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F0EDE6;padding:24px 12px">
<tr><td align="center"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border:1px solid #DAD5C9;border-radius:20px;padding:24px;font-family:-apple-system,'Segoe UI',Helvetica,Arial,sans-serif">
<tr><td style="font-family:Georgia,'Times New Roman',serif;font-size:24px;font-weight:700;color:#1D211C">${esc(subject)}</td></tr>
<tr><td style="padding-top:4px;font-size:14px;color:#6B7166;font-style:italic">${longDay(d.day)}</td></tr>
${rows}
<tr><td style="padding-top:22px"><a href="${APP_URL}" style="display:inline-block;background:#234032;color:#F5F1E6;text-decoration:none;font-weight:700;font-size:16px;padding:14px 22px;border-radius:24px">Open your pantry</a></td></tr>
</table></td></tr></table></body></html>`;
  const p = pushText(d);
  return { subject, html, text: [subject, longDay(d.day), "", p.body, "", APP_URL].join("\n") };
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

async function email(to: string, d: Digest): Promise<string> {
  if (!RESEND_KEY) return "no email key";
  const m = emailHtml(d);
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST", headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: RESEND_FROM, to, subject: m.subject, html: m.html, text: m.text }),
  });
  return res.ok ? "ok" : `email ${res.status}: ${(await res.text()).slice(0, 160)}`;
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
        const p = pushText(dg);
        const results = [];
        for (const sb of u.push ?? []) {
          const out = await push(sb, { title: p.title, body: p.body, count: dg.count, url: "/" });
          if (out === "gone") await admin.rpc("cron_drop_subscription", { p_user: u.user_id, p_endpoint: sb.endpoint });
          results.push(out);
        }
        r.push = results;
        if (u.email_digest && u.email) r.email = await email(u.email, dg);
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
  const [d, st] = await Promise.all([db.rpc("my_digest"), db.from("user_settings").select("push_subscription,email_digest").maybeSingle()]);
  if (d.error) return json({ error: d.error.message }, 400);
  const dg = d.data as Digest;
  const subs = (Array.isArray(st.data?.push_subscription) ? st.data!.push_subscription : []) as Sub[];
  const wantsEmail = !!st.data?.email_digest && !!claims.claims.email;
  if (!subs.length && !wantsEmail) return json({ error: "NO_DEVICES", message: "Turn on notifications on this device first." }, 400);
  const p = pushText(dg);
  const results = [];
  for (const sb of subs) {
    const out = await push(sb, { title: p.title, body: p.body, count: dg.count, url: "/" });
    if (out === "gone") await db.rpc("remove_push_subscription", { p_endpoint: sb.endpoint });
    results.push(out);
  }
  const mail = wantsEmail ? await email(String(claims.claims.email), dg) : "off";
  return json({ ok: true, devices: subs.length, results, email: mail });
});
