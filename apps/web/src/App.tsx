// App shell (step 3, slice 1): sign-in, bottom bar, Home and Pantry reading the same database functions Claude uses.
import { useCallback, useEffect, useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./supabase";
import { FAMILY_ICON, FAMILY_ORDER, familyOf, type Family } from "./families";
import { IconSprite, Tile } from "./Icons";

type Lot = {
  lot_id: string; name: string; category: string; location: string; qty_left: number; unit: string;
  packs_left: number | null; expires_on: string | null; days_left: number | null; state: string;
  expiry_kind: string; expiry_source: string;
};
type Overview = { today: string; expired: number; expiring_3_days: number; to_check: number; unconfirmed: number; in_stock: number };
type Tab = "home" | "pantry" | "list" | "budget";

// A lot needs attention when it is past its date, needs a check, or ends within 3 days (same window as get_overview).
const needsAttention = (l: Lot) => l.state !== "ok" || (l.expiry_kind !== "none" && l.days_left !== null && l.days_left <= 3);

function daysLabel(l: Lot): { n: string; u: string } {
  if (l.state === "expired") return { n: "!", u: "expired" };
  if (l.state === "check") return { n: "?", u: "check it" };
  if (l.expiry_kind === "none" || l.days_left === null) return { n: "", u: "" };
  const n = `${l.expiry_kind === "estimate" ? "~" : ""}${l.days_left}`;
  return { n, u: l.days_left === 1 ? "day" : "days" };
}
const qtyLabel = (l: Lot) => `${Number(l.qty_left)} ${l.unit} · ${l.location}`;

export function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);
  if (session === undefined) return <div className="app"><p className="muted pad">Loading…</p></div>;
  if (!session) return <Login />;
  return <Shell />;
}

function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  async function go(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setErr("");
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setBusy(false); if (error) setErr(error.message);
  }
  return (
    <div className="app center">
      <form className="login" onSubmit={go}>
        <h1 className="serif">Pantry</h1>
        <p className="muted">Sign in to see what you have at home.</p>
        <label>Email<input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
        <label>Password<input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
        {err && <p className="err">{err}</p>}
        <button className="primary" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
      </form>
    </div>
  );
}

function Shell() {
  const [tab, setTab] = useState<Tab>("home");
  const [onlyFlag, setOnlyFlag] = useState(false);
  const [lots, setLots] = useState<Lot[] | null>(null);
  const [overview, setOverview] = useState<Overview | null>(null);
  const [err, setErr] = useState("");
  const [addOpen, setAddOpen] = useState(false);

  const load = useCallback(async () => {
    const [o, ok, expired] = await Promise.all([
      supabase.rpc("get_overview"),
      supabase.rpc("list_pantry", { p_limit: 200 }),
      supabase.rpc("list_pantry", { p_state: "expired", p_limit: 200 }),
    ]);
    const bad = o.error ?? ok.error ?? expired.error;
    if (bad) return setErr(bad.message);
    setErr("");
    setOverview(o.data as Overview);
    setLots([...(expired.data as { lots: Lot[] }).lots, ...(ok.data as { lots: Lot[] }).lots]);
  }, []);
  useEffect(() => { void load(); }, [load]);

  const attention = useMemo(() => (lots ?? []).filter(needsAttention), [lots]);
  const attentionCount = overview ? overview.expired + overview.expiring_3_days + overview.to_check : attention.length;

  const go = (t: Tab, flag = false) => { setTab(t); setOnlyFlag(flag); };
  return (
    <div className="app">
      <IconSprite />
      <main className="screen">
        {err && <p className="err pad">{err}</p>}
        {tab === "home" && <Home lots={lots} attention={attention} count={attentionCount} onAttention={() => go("pantry", true)} onPantry={() => go("pantry")} />}
        {tab === "pantry" && <Pantry lots={lots} onlyFlag={onlyFlag} setOnlyFlag={setOnlyFlag} total={overview?.in_stock ?? 0} />}
        {tab === "list" && <Soon title="Shopping list" note="Arrives with the shopping-list step." />}
        {tab === "budget" && <Soon title="Budget" note="Arrives with the budget step." />}
      </main>
      {addOpen && (
        <div className="sheet-back" onClick={() => setAddOpen(false)}>
          <div className="sheet" onClick={(e) => e.stopPropagation()}>
            <h2 className="serif">Add a shop</h2>
            <p className="muted">The receipt camera comes in the next slice. For now you can ask Claude to log a shop.</p>
            <button className="primary" onClick={() => setAddOpen(false)}>OK</button>
          </div>
        </div>
      )}
      <nav className="bar" aria-label="Main">
        <TabBtn label="Home" on={tab === "home"} onClick={() => go("home")} d="M4 11 12 4l8 7v9h-5v-6H9v6H4z" />
        <TabBtn label="Pantry" on={tab === "pantry"} onClick={() => go("pantry")} d="M4 8h16v12H4zM3 4h18v4H3zM10 12h4" />
        <div className="plus-wrap"><button className="plus" aria-label="Add a shop" onClick={() => setAddOpen(true)}><svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#E3C47A" strokeWidth="2.6" strokeLinecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg></button></div>
        <TabBtn label="List" on={tab === "list"} onClick={() => go("list")} d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01" />
        <TabBtn label="Budget" on={tab === "budget"} onClick={() => go("budget")} d="M4 20V10M10 20V4M16 20v-7M22 20H2" />
      </nav>
    </div>
  );
}

function TabBtn({ label, on, onClick, d }: { label: string; on: boolean; onClick: () => void; d: string }) {
  return (
    <button className={`tab${on ? " on" : ""}`} onClick={onClick} aria-current={on ? "page" : undefined}>
      <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={d} /></svg>
      {label}
    </button>
  );
}

function Soon({ title, note }: { title: string; note: string }) {
  return <div className="pad"><h1 className="serif">{title}</h1><p className="muted">{note}</p></div>;
}

function Home({ lots, attention, count, onAttention, onPantry }: { lots: Lot[] | null; attention: Lot[]; count: number; onAttention: () => void; onPantry: () => void }) {
  const first = attention[0] ?? (lots ?? []).find((l) => l.expiry_kind !== "none");
  const soon = (lots ?? []).filter((l) => l.expiry_kind !== "none").slice(0, 6);
  return (
    <div className="pad stack">
      <p className="muted">{new Date().toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" })}</p>
      {lots && !first && <div className="card pad"><h2 className="serif">Nothing here yet</h2><p className="muted">Tap + to add your first shop.</p></div>}
      {first && (
        <section className="hero rise">
          <span className="eyebrow">USE FIRST</span>
          <div className="hero-row">
            <div className="stage"><div className="tilt"><Tile id={FAMILY_ICON[familyOf(first.category)].id} bg={FAMILY_ICON[familyOf(first.category)].tile} size={112} /></div></div>
            <div>
              <div className="big"><span className="serif">{daysLabel(first).n || "–"}</span><span>{daysLabel(first).u}</span></div>
              <strong className="hero-name">{first.name}</strong>
              <div className="hero-sub">{qtyLabel(first)}</div>
            </div>
          </div>
          {count > 0 && <button className="pill-alert" onClick={onAttention}>{count} need{count === 1 ? "s" : ""} attention</button>}
        </section>
      )}
      {soon.length > 0 && (
        <section>
          <div className="between"><h2 className="serif">Expiring soon</h2><button className="link" onClick={onPantry}>See all</button></div>
          <div className="hscroll">
            {soon.map((l) => { const f = familyOf(l.category); const d = daysLabel(l); const flag = needsAttention(l); return (
              <div key={l.lot_id} className={`mini ${flag ? "alert" : "card"}`}>
                <Tile id={FAMILY_ICON[f].id} bg={FAMILY_ICON[f].tile} size={68} />
                <strong>{l.name}</strong>
                <div className="mini-n"><span className="serif" style={{ color: flag ? "var(--red)" : undefined }}>{d.n}</span><span className="muted">{d.u}</span></div>
              </div>); })}
          </div>
        </section>
      )}
    </div>
  );
}

function Pantry({ lots, onlyFlag, setOnlyFlag, total }: { lots: Lot[] | null; onlyFlag: boolean; setOnlyFlag: (v: boolean) => void; total: number }) {
  const groups = useMemo(() => {
    const by = new Map<Family, Lot[]>();
    for (const l of lots ?? []) {
      if (onlyFlag && !needsAttention(l)) continue;
      const f = familyOf(l.category); by.set(f, [...(by.get(f) ?? []), l]);
    }
    const urgency = (ls: Lot[]) => Math.min(...ls.map((l) => (l.state === "expired" ? -999 : l.expiry_kind === "none" ? 9999 : (l.days_left ?? 9999))));
    return [...by.entries()].sort((a, b) => urgency(a[1]) - urgency(b[1]) || FAMILY_ORDER.indexOf(a[0]) - FAMILY_ORDER.indexOf(b[0]));
  }, [lots, onlyFlag]);
  return (
    <div className="pad stack">
      <div className="between"><h1 className="serif">Pantry</h1><div><span className="serif num">{total}</span> <span className="muted">items</span></div></div>
      <div className="chips">
        <button className={`chip${onlyFlag ? "" : " on"}`} onClick={() => setOnlyFlag(false)}>All</button>
        <button className={`chip red${onlyFlag ? " on" : ""}`} onClick={() => setOnlyFlag(true)}>Needs attention</button>
      </div>
      {lots === null && <p className="muted">Loading…</p>}
      {lots && groups.length === 0 && <p className="muted">{onlyFlag ? "Nothing needs attention." : "Nothing in the pantry yet. Tap + to add a shop."}</p>}
      {groups.map(([family, ls]) => {
        const n = ls.filter(needsAttention).length;
        return (
          <section key={family} className="stack-sm">
            <div className="group-h"><h2 className="serif">{family}</h2><span className="muted">{ls.length}</span>{n > 0 && <span className="red-t">{n} needs attention</span>}</div>
            {ls.map((l) => { const d = daysLabel(l); const flag = needsAttention(l); const fi = FAMILY_ICON[family]; return (
              <div key={l.lot_id} className={`item ${flag ? "alert" : "card"}`}>
                <div className={flag ? "halo" : ""} style={{ position: "relative" }}>
                  <Tile id={fi.id} bg={fi.tile} />
                  {flag && <span className="badge" aria-label="Needs attention">!</span>}
                </div>
                <div className="grow">
                  <strong>{l.name}</strong>
                  <div className="muted">{qtyLabel(l)}</div>
                  {flag && <div className="red-t">Use soon</div>}
                </div>
                {d.n && <div className="days"><span className="serif" style={{ color: flag ? "var(--red)" : undefined }}>{d.n}</span><span className="muted">{d.u}</span></div>}
              </div>); })}
          </section>
        );
      })}
    </div>
  );
}
