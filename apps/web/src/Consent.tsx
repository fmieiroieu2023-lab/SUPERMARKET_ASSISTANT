// OAuth consent page: Claude sends you here to approve access to your pantry data.
// Supabase adds ?authorization_id=... ; we sign you in (password for now; the app's email-code login comes in step 3), show who is asking, then Allow or Deny.
import { useEffect, useState } from "react";
import { supabase } from "./supabase";

type Details = { client?: { name?: string }; redirect_uri?: string; redirect_url?: string; scope?: string };
type State =
  | { s: "loading" }
  | { s: "login" }
  | { s: "ask"; details: Details }
  | { s: "error"; message: string };

const authorizationId = new URLSearchParams(window.location.search).get("authorization_id");

export function Consent() {
  const [state, setState] = useState<State>({ s: "loading" });
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState("");

  async function load() {
    if (!authorizationId) return setState({ s: "error", message: "This page is opened by Claude. Nothing to approve here." });
    const { data: sess } = await supabase.auth.getSession();
    if (!sess.session) return setState({ s: "login" });
    const { data, error } = await supabase.auth.oauth.getAuthorizationDetails(authorizationId);
    if (error || !data) return setState({ s: "error", message: error?.message ?? "Could not load the request." });
    const d = data as Details;
    if (d.redirect_url) return void (window.location.href = d.redirect_url); // already decided
    setState({ s: "ask", details: d });
  }
  useEffect(() => { void load(); }, []);

  async function signIn() {
    setBusy(true); setNote("");
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setBusy(false);
    if (error) setNote(error.message); else void load();
  }
  async function decide(allow: boolean) {
    setBusy(true);
    const call = allow ? supabase.auth.oauth.approveAuthorization : supabase.auth.oauth.denyAuthorization;
    const { data, error } = await call.call(supabase.auth.oauth, authorizationId!);
    if (error || !data) { setBusy(false); return setState({ s: "error", message: error?.message ?? "Something went wrong." }); }
    window.location.href = (data as { redirect_url: string }).redirect_url;
  }

  return (
    <main className="card">
      <h1>Supermarket Assistant</h1>
      {state.s === "loading" && <p>Loading…</p>}
      {state.s === "error" && <p className="err">{state.message}</p>}
      {state.s === "login" && (
        <>
          <p>Sign in to continue.</p>
          <input type="email" placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" />
          <input type="password" placeholder="Password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" />
          <button disabled={busy || !email || !password} onClick={signIn}>Sign in</button>
          {note && <p className="err">{note}</p>}
        </>
      )}
      {state.s === "ask" && (
        <>
          <p><strong>{state.details.client?.name ?? "An app"}</strong> wants to read and change your pantry, purchases and shopping list.</p>
          <p className="small">After approving you go back to {hostOf(state.details.redirect_uri)}. You can turn off its write access any time in the app.</p>
          <div className="row">
            <button className="ghost" disabled={busy} onClick={() => decide(false)}>Deny</button>
            <button disabled={busy} onClick={() => decide(true)}>Allow</button>
          </div>
        </>
      )}
    </main>
  );
}

function hostOf(u?: string) {
  try { return new URL(u ?? "").host; } catch { return "the app"; }
}
