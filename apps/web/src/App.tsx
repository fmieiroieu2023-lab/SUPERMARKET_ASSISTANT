// App shell (step 3, slice 1): sign-in, bottom bar, Home and Pantry reading the same database functions Claude uses.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./supabase";
import { FAMILY_ICON, FAMILY_ORDER, familyOf, type Family } from "./families";
import { IconSprite, Tile } from "./Icons";
import { ReceiptFlow } from "./Receipt";
import { Spending } from "./Spending";
import { dayLabel, friendly } from "./shared";

type Lot = {
  lot_id: string; name: string; category: string; location: string; qty_left: number; unit: string;
  packs_left: number | null; expires_on: string | null; days_left: number | null; state: string;
  expiry_kind: string; expiry_source: string;
};
type Overview = { today: string; expired: number; expiring_3_days: number; to_check: number; unconfirmed: number; in_stock: number };
type Tab = "home" | "pantry" | "list" | "spending";

// A lot needs attention when it is past its date, needs a check, or ends within 3 days (same window as get_overview).
const needsAttention = (l: Lot) => l.state !== "ok" || (l.expiry_kind !== "none" && l.days_left !== null && l.days_left <= 3);

function daysLabel(l: Lot): { n: string; u: string } {
  if (l.state === "expired") return { n: "!", u: "expired" };
  if (l.state === "check") return { n: "?", u: "check it" };
  if (l.expiry_kind === "none" || l.days_left === null) return { n: "", u: "" };
  if (l.days_left === 0) return { n: "today", u: "" };
  const n = `${l.expiry_kind === "estimate" ? "~" : ""}${l.days_left}`;
  return { n, u: l.days_left === 1 ? "day" : "days" };
}
const unitLabel = (u: string, n: number) => (u === "unit" ? (n === 1 ? "item" : "items") : u);
const qtyLabel = (l: Lot) => `${Number(l.qty_left)} ${unitLabel(l.unit, Number(l.qty_left))} · ${l.location}`;


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
  const [selected, setSelected] = useState<Lot | null>(null);
  const [receipt, setReceipt] = useState<{ files?: File[]; resumeId?: string } | null>(null);
  const [openTrip, setOpenTrip] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<{ purchase_id: string; created_at: string }[]>([]);

  const load = useCallback(async () => {
    // One call (app_snapshot) instead of three: faster, and the numbers and the list always agree.
    const { data, error } = await supabase.rpc("app_snapshot");
    if (error) return setErr(friendly(error.message));
    setErr("");
    const snap = data as { overview: Overview; lots: Lot[] };
    setOverview(snap.overview);
    setLots(snap.lots);
    // Unfinished receipts (Resume or discard). Quietly skipped if the receipts update isn't on the server yet.
    const p = await supabase.rpc("list_purchases", { p_limit: 1 });
    setDrafts(p.error ? [] : (p.data as { drafts: { purchase_id: string; created_at: string }[] }).drafts);
  }, []);
  useEffect(() => {
    void load();
    // Reopening the app from the home screen shows fresh data, not what was there yesterday.
    const onVisible = () => { if (document.visibilityState === "visible") void load(); };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [load]);

  const attention = useMemo(() => (lots ?? []).filter(needsAttention), [lots]);
  const attentionCount = overview ? overview.expired + overview.expiring_3_days + overview.to_check : attention.length;

  const go = (t: Tab, flag = false) => { setTab(t); setOnlyFlag(flag); };
  return (
    <div className="app">
      <IconSprite />
      <main className="screen">
        {err && <p className="err pad">{err} <button className="link" onClick={() => void load()}>Retry</button></p>}
        {tab === "home" && drafts[0] && (
          <div className="pad" style={{ paddingBottom: 0 }}>
            <button className="banner warn-b item-btn" onClick={() => setReceipt({ resumeId: drafts[0].purchase_id })}>
              Unfinished receipt from {dayLabel(drafts[0].created_at.slice(0, 10))}. Tap to finish or discard.
            </button>
          </div>
        )}
        {tab === "home" && <Home lots={lots} attention={attention} count={attentionCount} onAttention={() => go("pantry", true)} onPantry={() => go("pantry")} />}
        {tab === "pantry" && <Pantry lots={lots} onlyFlag={onlyFlag} setOnlyFlag={setOnlyFlag} total={overview?.in_stock ?? 0} onSelect={setSelected} />}
        {tab === "list" && <Soon title="Shopping list" note="Arrives with the shopping-list step." />}
        {tab === "spending" && <Spending openTrip={openTrip} onOpenTrip={setOpenTrip} onResume={(id) => setReceipt({ resumeId: id })} />}
      </main>
      {addOpen && <AddSheet onClose={() => setAddOpen(false)} onDone={() => { setAddOpen(false); void load(); }}
                            onReceipt={(files) => { setAddOpen(false); setReceipt({ files }); }} />}
      {receipt && <ReceiptFlow files={receipt.files} resumeId={receipt.resumeId}
                               onClose={() => { setReceipt(null); void load(); }}
                               onSaved={(id) => { setReceipt(null); setTab("spending"); setOpenTrip(id); void load(); }} />}
      {selected && <LotSheet lot={selected} onClose={() => setSelected(null)} onDone={() => { setSelected(null); void load(); }} />}
      <nav className="bar" aria-label="Main">
        <TabBtn label="Home" on={tab === "home"} onClick={() => go("home")} d="M4 11 12 4l8 7v9h-5v-6H9v6H4z" />
        <TabBtn label="Pantry" on={tab === "pantry"} onClick={() => go("pantry")} d="M4 8h16v12H4zM3 4h18v4H3zM10 12h4" />
        <div className="plus-wrap"><button className="plus" aria-label="Add a shop" onClick={() => setAddOpen(true)}><svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#E3C47A" strokeWidth="2.6" strokeLinecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg></button></div>
        <TabBtn label="List" on={tab === "list"} onClick={() => go("list")} d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01" />
        <TabBtn label="Spending" on={tab === "spending"} onClick={() => { go("spending"); setOpenTrip(null); }} d="M6 3h12v18l-3-2-3 2-3-2-3 2zM9 8h6M9 12h6M9 16h3" />
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

function Pantry({ lots, onlyFlag, setOnlyFlag, total, onSelect }: { lots: Lot[] | null; onlyFlag: boolean; setOnlyFlag: (v: boolean) => void; total: number; onSelect: (l: Lot) => void }) {
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
              <button key={l.lot_id} className={`item ${flag ? "alert" : "card"}`} onClick={() => onSelect(l)}>
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
              </button>); })}
          </section>
        );
      })}
    </div>
  );
}

type Cat = { id: string; name_es: string };

function AddSheet({ onClose, onDone, onReceipt }: { onClose: () => void; onDone: () => void; onReceipt: (files: File[]) => void }) {
  const [manual, setManual] = useState(false);
  const pick = (e: React.ChangeEvent<HTMLInputElement>) => { const f = [...(e.target.files ?? [])]; e.target.value = ""; if (f.length) onReceipt(f); };
  if (!manual) return (
    <div className="sheet-back" onClick={onClose}>
      <div className="sheet" onClick={(e) => e.stopPropagation()}>
        <h2 className="serif">Add a shop</h2>
        <label className="primary file-btn">Photograph the receipt
          <input type="file" accept="image/*" capture="environment" onChange={pick} hidden /></label>
        <label className="ghost file-btn">Choose photos or a PDF
          <input type="file" accept="image/*,application/pdf" multiple onChange={pick} hidden /></label>
        <p className="small">Long ticket? Choose up to 4 photos, top to bottom, slightly overlapping.</p>
        <button className="ghost" onClick={() => setManual(true)}>Add one item by hand</button>
        <button className="link" onClick={onClose}>Cancel</button>
      </div>
    </div>
  );
  return <ManualAdd onClose={onClose} onDone={onDone} />;
}

function ManualAdd({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [cats, setCats] = useState<Cat[]>([]);
  const [name, setName] = useState("");
  const [cat, setCat] = useState("");
  const [qty, setQty] = useState("1");
  const [unit, setUnit] = useState("unit");
  const [date, setDate] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const lotId = useRef(crypto.randomUUID()); // one id per sheet: a double tap cannot add twice
  useEffect(() => {
    void supabase.from("categories").select("id,name_es").eq("is_food", true).order("name_es").then(({ data }) => {
      setCats((data as Cat[]) ?? []);
    });
  }, []);
  async function save(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setErr("");
    const { error } = await supabase.rpc("add_item", {
      p_lot_id: lotId.current, p_name: name, p_category: cat, p_qty: Number(qty), p_unit: unit, p_expires_on: date || null,
    });
    setBusy(false);
    if (error) setErr(friendly(error.message)); else onDone();
  }
  const past = date !== "" && date < new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Madrid" });
  return (
    <div className="sheet-back" onClick={onClose}>
      <form className="sheet" onClick={(e) => e.stopPropagation()} onSubmit={save}>
        <h2 className="serif">Add an item</h2>
        <label>What is it<input value={name} onChange={(e) => setName(e.target.value)} required placeholder="Chicken breast" /></label>
        <label>Type<select value={cat} onChange={(e) => setCat(e.target.value)} required>
          <option value="">Choose…</option>{cats.map((c) => <option key={c.id} value={c.id}>{c.name_es}</option>)}
        </select></label>
        <div className="row">
          <label>How much<input type="number" inputMode="decimal" min="0" step="any" value={qty} onChange={(e) => setQty(e.target.value)} required /></label>
          <label>Unit<select value={unit} onChange={(e) => setUnit(e.target.value)}><option value="unit">items</option><option value="g">grams</option><option value="ml">ml</option></select></label>
        </div>
        <label>Date on the pack <span className="muted">(optional, otherwise I estimate)</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        {past && <p className="err">That date has already passed. It will be marked expired.</p>}
        {err && <p className="err">{err}</p>}
        <button className="primary" disabled={busy}>{busy ? "Saving…" : "Add to pantry"}</button>
        <button type="button" className="ghost" onClick={onClose}>Cancel</button>
      </form>
    </div>
  );
}

function LotSheet({ lot, onClose, onDone }: { lot: Lot; onClose: () => void; onDone: () => void }) {
  const [qty, setQty] = useState(String(Number(lot.qty_left)));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const moveId = useRef(crypto.randomUUID());
  async function run(reason: "consume" | "discard") {
    setBusy(true); setErr("");
    const { error } = await supabase.rpc("consume", { p_lot: lot.lot_id, p_qty: Number(qty), p_reason: reason, p_movement_id: moveId.current });
    setBusy(false);
    if (error) setErr(friendly(error.message)); else onDone();
  }
  return (
    <div className="sheet-back" onClick={onClose}>
      <div className="sheet" onClick={(e) => e.stopPropagation()}>
        <h2 className="serif">{lot.name}</h2>
        <p className="muted">{Number(lot.qty_left)} {unitLabel(lot.unit, Number(lot.qty_left))} left{lot.expires_on ? ` · date ${lot.expires_on}` : ""}</p>
        <label>How much<input type="number" inputMode="decimal" min="0" step="any" value={qty} onChange={(e) => setQty(e.target.value)} /></label>
        {err && <p className="err">{err}</p>}
        <button className="primary" disabled={busy} onClick={() => run("consume")}>I used it</button>
        <button className="ghost danger" disabled={busy} onClick={() => run("discard")}>I threw it away</button>
        <button className="ghost" onClick={onClose}>Close</button>
      </div>
    </div>
  );
}
