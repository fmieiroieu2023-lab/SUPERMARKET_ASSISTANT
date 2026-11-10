// Calls daily-digest every hour. If it fails twice in the watchdog hour, emails you once (needs RESEND_API_KEY).
// Why on Cloudflare and not inside Supabase: a paused free Supabase project runs nothing, and these calls count
// as activity that keeps it awake (§6.4).
interface Env { DIGEST_URL: string; CRON_SECRET: string; WATCHDOG_HOUR: string; WATCHDOG_TO: string; RESEND_API_KEY?: string }

async function call(env: Env): Promise<string | null> {
  try {
    const res = await fetch(env.DIGEST_URL, {
      method: "POST", headers: { "x-cron-secret": env.CRON_SECRET, "content-type": "application/json" }, body: "{}",
      signal: AbortSignal.timeout(20_000),
    });
    return res.ok ? null : `HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`;
  } catch (e) { return e instanceof Error ? e.message : "no answer"; }
}

export default {
  async scheduled(_c: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil((async () => {
      let err = await call(env);
      if (err) { await new Promise((r) => setTimeout(r, 30_000)); err = await call(env); }
      if (!err) return;
      console.log("daily-digest failed:", err);
      const hour = Number(new Date().toLocaleString("en-GB", { hour: "2-digit", hour12: false, timeZone: "Europe/Madrid" }));
      if (hour === Number(env.WATCHDOG_HOUR) && env.RESEND_API_KEY && env.WATCHDOG_TO) {
        await fetch("https://api.resend.com/emails", {
          method: "POST", headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "content-type": "application/json" },
          body: JSON.stringify({ from: "Pantry <onboarding@resend.dev>", to: env.WATCHDOG_TO,
            subject: "Pantry: the backend isn't responding", text: `This morning's summary couldn't be sent.\n\n${err}` }),
        });
      }
    })());
  },
} satisfies ExportedHandler<Env>;
