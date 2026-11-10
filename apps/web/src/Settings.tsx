// Settings (step 6): morning notifications on this device, time, email, warning days, sign out.
import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import { VAPID_PUBLIC_KEY } from "./config";
import { friendly, invokeError } from "./shared";

type S = { digest_time: string; email_digest: boolean; use_by_lead_days: number; best_before_lead_days: number; devices: number; endpoints: string[] };

const b64ToBytes = (s: string) => {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const raw = atob((s + pad).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
};
const pushSupported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
const installed = () => window.matchMedia?.("(display-mode: standalone)").matches || (navigator as unknown as { standalone?: boolean }).standalone === true;
const isIOS = () => /iPhone|iPad|iPod/.test(navigator.userAgent);

export function SettingsPage({ onBack }: { onBack: () => void }) {
  const [s, setS] = useState<S | null>(null);
  const [here, setHere] = useState<string | null>(null);   // this device's push endpoint, if subscribed
  const [email, setEmail] = useState("");
  const [msg, setMsg] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  async function load() {
    const [r, u] = await Promise.all([supabase.rpc("get_notify_settings"), supabase.auth.getUser()]);
    if (r.error) setErr(friendly(r.error.message)); else setS(r.data as S);
    setEmail(u.data.user?.email ?? "");
    if (pushSupported()) {
      const reg = await navigator.serviceWorker.getRegistration();
      const sub = await reg?.pushManager.getSubscription();
      setHere(sub?.endpoint ?? null);
    }
  }
  useEffect(() => { void load(); }, []);

  async function save(patch: Record<string, unknown>) {
    setErr("");
    const { data, error } = await supabase.rpc("set_notify_settings", patch);
    if (error) setErr(friendly(error.message)); else { setS(data as S); setMsg("Saved."); setTimeout(() => setMsg(""), 1500); }
  }
  async function turnOn() {
    setBusy(true); setErr(""); setMsg("");
    try {
      const perm = await Notification.requestPermission();
      if (perm !== "granted") throw new Error("Notifications are blocked for this app. Allow them in your phone's Settings, then try again.");
      const reg = (await navigator.serviceWorker.getRegistration()) ?? (await navigator.serviceWorker.register("/sw.js"));
      await navigator.serviceWorker.ready;
      const sub = (await reg.pushManager.getSubscription()) ??
        (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(VAPID_PUBLIC_KEY) }));
      const { data, error } = await supabase.rpc("save_push_subscription", { p_sub: sub.toJSON() });
      if (error) throw new Error(error.message);
      setS(data as S); setHere(sub.endpoint); setMsg("Notifications are on for this device.");
    } catch (e) { setErr(e instanceof Error && !/^[A-Z_]+$/.test(e.message) ? e.message : friendly(String(e))); }
    setBusy(false);
  }
  async function turnOff() {
    setBusy(true); setErr("");
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = await reg?.pushManager.getSubscription();
    if (sub) { await supabase.rpc("remove_push_subscription", { p_endpoint: sub.endpoint }); await sub.unsubscribe(); }
    setHere(null); await load(); setBusy(false);
  }
  async function test() {
    setBusy(true); setErr(""); setMsg("");
    const { data, error } = await supabase.functions.invoke("daily-digest", { body: {} });
    if (error) { const m = await invokeError(error); setErr(m.includes("NO_DEVICES") ? "Turn on notifications on this device first." : friendly(m)); }
    else {
      const em = (data as { email?: string })?.email;
      setMsg(`Sent. It should arrive in a few seconds.${em === "ok" ? " Email sent too." : em === "no email key" ? " Email isn't set up on the server yet." : em && em !== "off" ? " The email didn't go out." : ""}`);
    }
    setBusy(false);
  }

  const onHere = !!here && !!s?.endpoints.includes(here);
  return (
    <div className="pad stack">
      <button className="link back" onClick={onBack}>‹ Home</button>
      <h1 className="serif">Settings</h1>

      <section className="card pad-in stack-sm">
        <strong className="serif set-h">Morning summary</strong>
        <p className="muted small">Once a day: what to use today, what expires in the next days, what to check or bin, and budget warnings. Only sent when there's something to say.</p>
        {!pushSupported() || (isIOS() && !installed()) ? (
          <p className="banner warn-b">{isIOS() ? "On iPhone, notifications only work in the installed app: in Safari tap Share → Add to Home Screen, open the app from the new icon, then come back here." : "This browser can't show notifications."}</p>
        ) : onHere ? (
          <div className="stack-sm">
            <p>✓ On for this device{s && s.devices > 1 ? ` (and ${s.devices - 1} other)` : ""}</p>
            <div className="row">
              <button className="primary" disabled={busy} onClick={() => void test()}>Send a test</button>
              <button className="ghost" disabled={busy} onClick={() => void turnOff()}>Turn off here</button>
            </div>
          </div>
        ) : (
          <button className="primary" disabled={busy} onClick={() => void turnOn()}>Turn on notifications on this device</button>
        )}
        {s && (
          <div className="stack-sm">
            <label className="field">Time<input type="time" value={s.digest_time} onChange={(e) => e.target.value && void save({ p_digest_time: e.target.value })} /></label>
            <label className="toggle-row">
              <input type="checkbox" checked={s.email_digest} onChange={(e) => void save({ p_email_digest: e.target.checked })} />
              <span>Also send it by email{email ? ` to ${email}` : ""}</span>
            </label>
          </div>
        )}
      </section>

      {s && (
        <section className="card pad-in stack-sm">
          <strong className="serif set-h">How early to warn</strong>
          <div className="row">
            <label className="field">Use-by (Caducidad)
              <select value={s.use_by_lead_days} onChange={(e) => void save({ p_use_by_lead_days: Number(e.target.value) })}>
                {[0, 1, 2, 3, 4, 5].map((n) => <option key={n} value={n}>{n === 0 ? "on the day" : `${n} day${n === 1 ? "" : "s"} before`}</option>)}
              </select></label>
            <label className="field">Best-before
              <select value={s.best_before_lead_days} onChange={(e) => void save({ p_best_before_lead_days: Number(e.target.value) })}>
                {[0, 1, 2, 3, 5, 7].map((n) => <option key={n} value={n}>{n === 0 ? "on the day" : `${n} day${n === 1 ? "" : "s"} before`}</option>)}
              </select></label>
          </div>
        </section>
      )}

      {msg && <p className="small" role="status">{msg}</p>}
      {err && <p className="err" role="alert">{err}</p>}

      <section className="card pad-in stack-sm">
        <strong className="serif set-h">Account</strong>
        <p className="muted small">Signed in as {email}</p>
        <button className="ghost danger" onClick={() => void supabase.auth.signOut()}>Sign out</button>
      </section>
    </div>
  );
}
