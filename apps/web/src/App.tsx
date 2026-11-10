// App shell (step 3, slice 1): sign-in, bottom bar, Home and Pantry reading the same database functions Claude uses.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./supabase";
import { FAMILY_ICON, FAMILY_ORDER, familyOf, iconFor, type Family } from "./families";
import { IconSprite, Tile } from "./Icons";
import { ReceiptFlow } from "./Receipt";
import { Spending } from "./Spending";
import { dayLabel, euro, friendly } from "./shared";
import { ItemPage, UndoBar, takeFromLot, type UndoFn } from "./Item";
import { ListTab } from "./List";
import { catName, loadNames, Name, useNames } from "./names";

type Lot = {
  lot_id: string; name: string; name_en?: string | null; product_id?: string; category: string; location: string; qty_left: number; unit: string;
  packs_left: number | null; expires_on: string | null; days_left: number | null; state: string;
  expiry_kind: string; expiry_source: string;
};
type Overview = { today: string; expired: number; expiring_3_days: number; to_check: number; unconfirmed: number; in_stock: number };
type Tab = "home" | "pantry" | "list" | "spending";

// A lot needs attention when it is past its date, needs a check, or ends within 3 days (same window as get_overview).
const lotName = (l: Lot) => ({ en: l.name_en || l.name, es: l.name });
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
const PLACE_WORD: Record<string, string> = { fridge: "fridge", freezer: "freezer", pantry: "cupboard" };
const qtyLabel = (l: Lot) => `${Number(l.qty_left)} ${unitLabel(l.unit, Number(l.qty_left))} · ${PLACE_WORD[l.location] ?? l.location}`;


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
      <form className="login" method="post" action="/" onSubmit={go}>
        <h1 className="serif">Pantry</h1>
        <p className="muted">Sign in to see what you have at home.</p>
        {/* name/id/autocomplete let Safari's and Chrome's password managers save and fill these */}
        <label htmlFor="email">Email<input id="email" name="email" type="email" autoComplete="username" inputMode="email" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
        <label htmlFor="password">Password<input id="password" name="password" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
        {err && <p className="err">{err}</p>}
        <button className="primary" type="submit" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
        <p className="small">You stay signed in on this device. The installed app and the browser each sign in once.</p>
      </form>
    </div>
  );
}

function Shell() {
  useNames();
  const [tab, setTab] = useState<Tab>("home");
  const [onlyFlag, setOnlyFlag] = useState(false);
  const [lots, setLots] = useState<Lot[] | null>(null);
  const [overview, setOverview] = useState<Overview | null>(null);
  const [err, setErr] = useState("");
  const [addOpen, setAddOpen] = useState(false);
  const [itemId, setItemId] = useState<string | null>(null);
  const [receipt, setReceipt] = useState<{ files?: File[]; resumeId?: string } | null>(null);
  const [openTrip, setOpenTrip] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<{ purchase_id: string; created_at: string }[]>([]);
  const [lastTrip, setLastTrip] = useState<LastTrip | null>(null);
  const [undo, setUndo] = useState<UndoFn | null>(null);
  const [place, setPlace] = useState("all");
  const [month, setMonth] = useState<{ spent_cents: number; budget_cents: number | null; alert: string | null } | null>(null);

  const load = useCallback(async () => {
    // One call (app_snapshot) instead of three: faster, and the numbers and the list always agree.
    void loadNames(true);   // product names change when receipts add products
    const { data, error } = await supabase.rpc("app_snapshot");
    if (error) return setErr(friendly(error.message));
    setErr("");
    const snap = data as { overview: Overview; lots: Lot[] };
    setOverview(snap.overview);
    setLots(snap.lots);
    // Last shop + unfinished receipts. Quietly skipped if the receipts update isn't on the server yet.
    const p = await supabase.rpc("list_purchases", { p_limit: 60 });
    const pd = p.error ? null : (p.data as { drafts: { purchase_id: string; created_at: string }[]; trips: (LastTrip & { month: string })[] });
    setDrafts(pd?.drafts ?? []); setLastTrip(pd?.trips[0] ?? null);
    const b = await supabase.rpc("budget_status");
    setMonth(b.error ? null : (b.data as { spent_cents: number; budget_cents: number | null; alert: string | null }));
  }, []);
  useEffect(() => {
    void load();
    // Reopening the app from the home screen shows fresh data, not what was there yesterday.
    const onVisible = () => { if (document.visibilityState === "visible") void load(); };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [load]);

  // A new screen starts at the top.
  const screen = useRef<HTMLElement>(null);
  useEffect(() => { screen.current?.scrollTo(0, 0); }, [tab, itemId, openTrip]);

  const attention = useMemo(() => (lots ?? []).filter(needsAttention), [lots]);
  const attentionCount = overview ? overview.expired + overview.expiring_3_days + overview.to_check : attention.length;
  const changed = (u: UndoFn | null) => { if (u) setUndo(u); void load(); };
  const swipe = (l: Lot, reason: "consume" | "discard") => {
    void takeFromLot(l.lot_id, Number(l.qty_left), reason, lotName(l).en).then(changed).catch((e) => setErr(friendly(String(e))));
  };
  const openTripFrom = (id: string) => { setItemId(null); setTab("spending"); setOpenTrip(id); };

  const go = (t: Tab, flag = false) => { setTab(t); setOnlyFlag(flag); setItemId(null); };
  return (
    <div className="app">
      <IconSprite />
      <main className="screen" ref={screen}>
        {err && <p className="err pad">{err} <button className="link" onClick={() => void load()}>Retry</button></p>}
        {itemId ? <ItemPage lotId={itemId} onBack={() => setItemId(null)} onChanged={changed} onOpenTrip={openTripFrom} /> : <>
          {tab === "home" && drafts[0] && (
            <div className="pad" style={{ paddingBottom: 0 }}>
              <button className="banner warn-b item-btn" onClick={() => setReceipt({ resumeId: drafts[0].purchase_id })}>
                Unfinished receipt from {dayLabel(drafts[0].created_at.slice(0, 10))}. Tap to finish or discard.
              </button>
            </div>
          )}
          {tab === "home" && <Home lots={lots} attention={attention} count={attentionCount} lastTrip={lastTrip} month={month} onBudget={() => { go("spending"); setOpenTrip(null); }}
            onAttention={() => go("pantry", true)} onPantry={(pl = "all") => { setPlace(pl); go("pantry"); }} onItem={setItemId} onTrip={openTripFrom}
            onAdd={() => setAddOpen(true)} />}
          {tab === "pantry" && <Pantry lots={lots} onlyFlag={onlyFlag} setOnlyFlag={setOnlyFlag} total={overview?.in_stock ?? 0}
            place={place} setPlace={setPlace} onSelect={(l) => setItemId(l.lot_id)} onSwipe={swipe} />}
          {tab === "list" && <ListTab onChanged={changed} />}
          {tab === "spending" && <Spending openTrip={openTrip} onOpenTrip={setOpenTrip} onResume={(id) => setReceipt({ resumeId: id })} onChanged={changed} />}
        </>}
      </main>
      {addOpen && <AddSheet onClose={() => setAddOpen(false)} onDone={() => { setAddOpen(false); void load(); }}
                            onReceipt={(files) => { setAddOpen(false); setReceipt({ files }); }} />}
      {receipt && <ReceiptFlow files={receipt.files} resumeId={receipt.resumeId}
                               onClose={() => { setReceipt(null); void load(); }}
                               onSaved={(id) => { setReceipt(null); setItemId(null); setTab("spending"); setOpenTrip(id); void load(); }} />}
      {undo && <UndoBar undo={undo} onDone={() => { setUndo(null); void load(); }} />}
      <nav className="bar" aria-label="Main">
        <TabBtn label="Home" on={tab === "home"} onClick={() => go("home")} d="M4 11 12 4l8 7v9h-5v-6H9v6H4z" />
        <TabBtn label="Pantry" on={tab === "pantry"} onClick={() => { setPlace("all"); go("pantry"); }} d="M4 8h16v12H4zM3 4h18v4H3zM10 12h4" />
        <div className="plus-wrap"><button className="plus" aria-label="Add a shop" onClick={() => setAddOpen(true)}><svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#E3C47A" strokeWidth="2.6" strokeLinecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg></button></div>
        <TabBtn label="List" on={tab === "list"} onClick={() => go("list")} d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01" />
        <TabBtn label="Spending" on={tab === "spending"} onClick={() => { go("spending"); setOpenTrip(null); }} d="M6 3h12v18l-3-2-3 2-3-2-3 2zM9 8h6M9 12h6M9 16h3" />
      </nav>
    </div>
  );
}

type LastTrip = { purchase_id: string; chain: string; local_date: string; total_cents: number; items: number };

function TabBtn({ label, on, onClick, d }: { label: string; on: boolean; onClick: () => void; d: string }) {
  return (
    <button className={`tab${on ? " on" : ""}`} onClick={onClick} aria-current={on ? "page" : undefined}>
      <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={d} /></svg>
      {label}
    </button>
  );
}


// "Ask Claude" (D17): opens Claude with a question ready; Claude answers with the Supermarket connector.
const ask = (q: string) => "https://claude.ai/new?q=" + encodeURIComponent(`Using my Supermarket connector: ${q}`);
const ASKS = [
  { label: "What can I cook tonight?", q: "what can I cook tonight with what expires soonest in my pantry?" },
  { label: "What should I buy?", q: "what am I running low on, and what should I buy on my next shop?" },
  { label: "Anything to use up?", q: "which items in my pantry should I use or freeze in the next 2 days?" },
];
const KITCHEN = [
  { id: "fridge", label: "Fridge", icon: "fridge", tile: "#E3ECEF" },
  { id: "freezer", label: "Freezer", icon: "snow", tile: "#D6E6F4" },
  { id: "pantry", label: "Cupboard", icon: "cupboard", tile: "#EEDCC4" },
];
function greeting() {
  const h = Number(new Date().toLocaleString("en-GB", { hour: "2-digit", hour12: false, timeZone: "Europe/Madrid" }));
  return h < 6 ? "Good night" : h < 13 ? "Good morning" : h < 20 ? "Good afternoon" : "Good evening";
}

function Home({ lots, attention, count, lastTrip, month, onBudget, onAttention, onPantry, onItem, onTrip, onAdd }: {
  lots: Lot[] | null; attention: Lot[]; count: number; lastTrip: LastTrip | null;
  month: { spent_cents: number; budget_cents: number | null; alert: string | null } | null; onBudget: () => void;
  onAttention: () => void; onPantry: (place?: string) => void; onItem: (id: string) => void; onTrip: (id: string) => void; onAdd: () => void;
}) {
  const inStock = (lots ?? []).filter((l) => l.state !== "finished");
  const first = attention[0] ?? inStock.find((l) => l.expiry_kind !== "none");
  const soon = inStock.filter((l) => l.expiry_kind !== "none").slice(0, 8);
  const byPlace = (id: string) => inStock.filter((l) => l.location === id).length;
  const families = useMemo(() => {
    const m = new Map<Family, number>();
    for (const l of inStock) m.set(familyOf(l.category), (m.get(familyOf(l.category)) ?? 0) + 1);
    return [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6);
  }, [inStock]);
  const fi = first ? iconFor(first.category) : null;
  return (
    <div className="pad stack">
      <header className="home-h">
        <div>
          <p className="muted">{new Date().toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" })}</p>
          <h1 className="serif">{greeting()}</h1>
        </div>
        <div className="home-badge"><Tile id="cupboard" bg="#EEDCC4" size={52} /></div>
      </header>

      {lots && inStock.length === 0 && (
        <section className="welcome rise">
          <div className="collage" aria-hidden="true">
            {[["chicken", "#F2D3B3"], ["apple", "#F5D0C8"], ["milk", "#CFDDEE"], ["bread", "#EDD7B3"], ["cheese", "#F6E3A8"], ["spinach", "#CBE4C7"]].map(([id, bg], i) =>
              <div key={id} className="float" style={{ animationDelay: `${i * 0.4}s` }}><Tile id={id} bg={bg} size={56} /></div>)}
          </div>
          <h2 className="serif">Your kitchen is empty</h2>
          <p className="muted">Photograph your next receipt and everything you bought appears here, with its date.</p>
          <button className="primary" onClick={onAdd}>Photograph a receipt</button>
        </section>
      )}

      {first && fi && (
        <section className="hero rise">
          <span className="eyebrow">USE FIRST</span>
          <button className="hero-row hero-btn" onClick={() => onItem(first.lot_id)}>
            <div className="stage"><div className="tilt"><Tile id={fi.id} bg={fi.tile} size={112} /></div></div>
            <div>
              <div className="big"><span className="serif">{daysLabel(first).n || "–"}</span><span>{daysLabel(first).u}</span></div>
              <strong className="hero-name">{lotName(first).en}</strong>
              <div className="hero-sub">{qtyLabel(first)}</div>
            </div>
          </button>
          {count > 0 && <button className="pill-alert" onClick={onAttention}>{count} need{count === 1 ? "s" : ""} attention</button>}
        </section>
      )}

      {lots && inStock.length > 0 && (
        <div className="stats">
          <button className="stat card item-btn" onClick={() => onPantry()}><Tile id="cupboard" bg="#EEDCC4" size={40} /><span className="serif stat-n">{inStock.length}</span><span className="muted">in stock</span></button>
          <button className={`stat item-btn ${count ? "alert" : "card"}`} onClick={onAttention}><Tile id="apple" bg="#F5D0C8" size={40} /><span className="serif stat-n" style={{ color: count ? "var(--red)" : undefined }}>{count}</span><span className="muted">use soon</span></button>
          <button className={`stat item-btn ${month?.alert ? "alert" : "card"}`} onClick={onBudget}><Tile id="receipt" bg="#ECE6D8" size={40} />
            <span className="serif stat-n">{month == null ? "–" : `€${Math.round(month.spent_cents / 100)}`}</span>
            <span className="muted">{month?.budget_cents ? `of €${Math.round(month.budget_cents / 100)}` : "this month"}</span></button>
        </div>
      )}

      {soon.length > 0 && (
        <section>
          <div className="between"><h2 className="serif">Expiring soon</h2><button className="link" onClick={() => onPantry()}>See all</button></div>
          <div className="hscroll">
            {soon.map((l) => { const ic = iconFor(l.category); const d = daysLabel(l); const flag = needsAttention(l); return (
              <button key={l.lot_id} className={`mini item-btn ${flag ? "alert" : "card"}`} onClick={() => onItem(l.lot_id)}>
                <Tile id={ic.id} bg={ic.tile} size={68} />
                <strong>{lotName(l).en}</strong>
                <div className="mini-n"><span className="serif" style={{ color: flag ? "var(--red)" : undefined }}>{d.n}</span><span className="muted">{d.u}</span></div>
              </button>); })}
          </div>
        </section>
      )}

      {lots && inStock.length > 0 && (
        <section className="stack-sm">
          <h2 className="serif">Your kitchen</h2>
          <div className="kitchen">
            {KITCHEN.map((k) => (
              <button key={k.id} className="card place item-btn" onClick={() => onPantry(k.id)}>
                <Tile id={k.icon} bg={k.tile} size={58} />
                <strong>{k.label}</strong>
                <span className="muted">{byPlace(k.id)} item{byPlace(k.id) === 1 ? "" : "s"}</span>
              </button>
            ))}
          </div>
          {families.length > 0 && (
            <div className="fam-grid">
              {families.map(([f, n]) => (
                <button key={f} className="fam card item-btn" onClick={() => onPantry()}>
                  <Tile id={FAMILY_ICON[f].id} bg={FAMILY_ICON[f].tile} size={40} />
                  <span className="grow">{f}</span><span className="serif fam-n">{n}</span>
                </button>
              ))}
            </div>
          )}
        </section>
      )}

      {lastTrip && (
        <section className="stack-sm">
          <h2 className="serif">Last shop</h2>
          <button className="card trip item-btn" onClick={() => onTrip(lastTrip.purchase_id)}>
            <span className="mono" aria-hidden="true">{lastTrip.chain.slice(0, 1)}</span>
            <div className="grow"><strong>{lastTrip.chain}</strong><div className="muted">{dayLabel(lastTrip.local_date)} · {lastTrip.items} items</div></div>
            <span className="serif amt-big">{euro(lastTrip.total_cents)}</span>
          </button>
        </section>
      )}

      <section className="claude-card">
        <div className="claude-h"><Tile id="spark" bg="#2E5240" size={48} /><div><strong className="serif">Ask Claude</strong><p>It can see your pantry and what you've bought.</p></div></div>
        <div className="claude-asks">
          {ASKS.map((a) => <a key={a.label} className="ask-chip" href={ask(a.q)} target="_blank" rel="noopener noreferrer">{a.label}</a>)}
        </div>
      </section>
    </div>
  );
}

// Swipe a row: right = used it all, left = threw it away. Tapping still opens the item. Undo bar follows.
function SwipeRow({ className, onTap, onRight, onLeft, children }: {
  className: string; onTap: () => void; onRight: () => void; onLeft: () => void; children: React.ReactNode;
}) {
  const [dx, setDx] = useState(0);
  const g = useRef<{ x: number; y: number; horiz: boolean | null; moved: boolean } | null>(null);
  const el = useRef<HTMLButtonElement>(null);
  return (
    <div className="swipe">
      <div className={`swipe-bg ${dx > 0 ? "used" : dx < 0 ? "bin" : ""}`} aria-hidden="true">
        <span>{dx > 0 ? "Used it" : ""}</span><span>{dx < 0 ? "Threw away" : ""}</span>
      </div>
      <button ref={el} className={className} style={{ transform: dx ? `translateX(${dx}px)` : undefined, transition: dx ? "none" : undefined }}
        onPointerDown={(e) => { g.current = { x: e.clientX, y: e.clientY, horiz: null, moved: false }; }}
        onPointerMove={(e) => {
          const s = g.current; if (!s) return;
          const ddx = e.clientX - s.x, ddy = e.clientY - s.y;
          if (s.horiz === null && (Math.abs(ddx) > 10 || Math.abs(ddy) > 10)) {
            s.horiz = Math.abs(ddx) > Math.abs(ddy);
            if (s.horiz) el.current?.setPointerCapture(e.pointerId);
          }
          if (s.horiz) { s.moved = true; setDx(ddx); }
        }}
        onPointerUp={() => {
          const s = g.current; const w = el.current?.offsetWidth ?? 300;
          if (s?.horiz) { if (dx > w * 0.35) onRight(); else if (dx < -w * 0.35) onLeft(); }
          setDx(0);
          setTimeout(() => { g.current = null; }, 0);
        }}
        onPointerCancel={() => { setDx(0); g.current = null; }}
        onClick={() => { if (!g.current?.moved) onTap(); }}>
        {children}
      </button>
    </div>
  );
}

const PLACES = [["all", "All"], ["fridge", "Fridge"], ["freezer", "Freezer"], ["pantry", "Cupboard"]] as const;

function Pantry({ lots, onlyFlag, setOnlyFlag, total, place, setPlace, onSelect, onSwipe }: {
  lots: Lot[] | null; onlyFlag: boolean; setOnlyFlag: (v: boolean) => void; total: number; place: string; setPlace: (p: string) => void;
  onSelect: (l: Lot) => void; onSwipe: (l: Lot, reason: "consume" | "discard") => void;
}) {
  const [q, setQ] = useState("");
  const groups = useMemo(() => {
    const words = q.trim().toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").split(/\s+/).filter(Boolean);
    const by = new Map<Family, Lot[]>();
    for (const l of lots ?? []) {
      if (onlyFlag && !needsAttention(l)) continue;
      if (place !== "all" && l.location !== place) continue;
      const name = (l.name + " " + (l.name_en ?? "")).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
      if (words.length && !words.every((w) => name.includes(w))) continue;
      const f = familyOf(l.category); by.set(f, [...(by.get(f) ?? []), l]);
    }
    const urgency = (ls: Lot[]) => Math.min(...ls.map((l) => (l.state === "expired" ? -999 : l.expiry_kind === "none" ? 9999 : (l.days_left ?? 9999))));
    return [...by.entries()].sort((a, b) => urgency(a[1]) - urgency(b[1]) || FAMILY_ORDER.indexOf(a[0]) - FAMILY_ORDER.indexOf(b[0]));
  }, [lots, onlyFlag, place, q]);
  return (
    <div className="pad stack">
      <div className="between"><h1 className="serif">Pantry</h1><div><span className="serif num">{total}</span> <span className="muted">items</span></div></div>
      <input type="search" className="search" placeholder="Search the pantry" aria-label="Search the pantry" value={q} onChange={(e) => setQ(e.target.value)} />
      <div className="chips">
        {PLACES.map(([id, label]) => <button key={id} className={`chip${place === id && !onlyFlag ? " on" : ""}`} onClick={() => { setPlace(id); setOnlyFlag(false); }}>{label}</button>)}
        <button className={`chip red${onlyFlag ? " on" : ""}`} onClick={() => setOnlyFlag(!onlyFlag)}>Needs attention</button>
      </div>
      {lots && lots.length > 0 && <p className="small">Tip: swipe an item right if you used it, left if you threw it away.</p>}
      {lots === null && <p className="muted">Loading…</p>}
      {lots && groups.length === 0 && <p className="muted">{q ? "Nothing matches that search." : onlyFlag ? "Nothing needs attention." : "Nothing here yet. Tap + to add a shop."}</p>}
      {groups.map(([family, ls]) => {
        const n = ls.filter(needsAttention).length;
        return (
          <section key={family} className="stack-sm">
            <div className="group-h"><h2 className="serif">{family}</h2><span className="muted">{ls.length}</span>{n > 0 && <span className="red-t">{n} needs attention</span>}</div>
            {ls.map((l) => { const d = daysLabel(l); const flag = needsAttention(l); const fi = iconFor(l.category); return (
              <SwipeRow key={l.lot_id} className={`item ${flag ? "alert" : "card"}`} onTap={() => onSelect(l)}
                        onRight={() => onSwipe(l, "consume")} onLeft={() => onSwipe(l, "discard")}>
                <div className={flag ? "halo" : ""} style={{ position: "relative" }}>
                  <Tile id={fi.id} bg={fi.tile} />
                  {flag && <span className="badge" aria-label="Needs attention">!</span>}
                </div>
                <div className="grow">
                  <Name n={lotName(l)} />
                  <div className="muted">{qtyLabel(l)}</div>
                  {flag && <div className="red-t">Use soon</div>}
                </div>
                {d.n && <div className="days"><span className="serif" style={{ color: flag ? "var(--red)" : undefined }}>{d.n}</span><span className="muted">{d.u}</span></div>}
              </SwipeRow>); })}
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
          <option value="">Choose…</option>{[...cats].sort((a, b) => catName(a.id).en.localeCompare(catName(b.id).en)).map((c) => <option key={c.id} value={c.id}>{catName(c.id).en}</option>)}
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
