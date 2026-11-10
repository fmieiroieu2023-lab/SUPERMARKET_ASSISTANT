// Spending tab (D15): Trips first (past shops by month -> trip page), Budget second (arrives in step 7).
import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { dayLabel, euro, friendly, monthLabel } from "./shared";
import type { UndoFn } from "./Item";
import { catName, Name, prodName, useNames } from "./names";

type Trip = { purchase_id: string; chain: string; store_label: string | null; local_date: string; month: string;
  total_cents: number; verification: string; items: number; lots: number };
type Draft = { purchase_id: string; chain_id: string; created_at: string; total_cents: number | null };
type TLine = { line_no: number; kind: string; name: string; raw_text: string | null; is_food: boolean; printed_qty: number; printed_unit: string;
  line_total_cents: number; product_id: string | null;
  lot: { lot_id: string; qty_left: number; unit: string; state: string; days_left: number | null } | null };
type TripFull = { purchase_id: string; chain: string; store_label: string | null; local_date: string; total_cents: number;
  verification: string; ticket_number: string | null; receipt_paths: string[]; lines: TLine[] };

export function Spending({ openTrip, onOpenTrip, onResume, onChanged }: {
  openTrip: string | null; onOpenTrip: (id: string | null) => void; onResume: (id: string) => void; onChanged: (u: UndoFn | null) => void;
}) {
  const [view, setView] = useState<"trips" | "budget">("trips");
  const [trips, setTrips] = useState<Trip[] | null>(null);
  const [drafts, setDrafts] = useState<Draft[]>([]);
  const [err, setErr] = useState("");

  async function load() {
    const { data, error } = await supabase.rpc("list_purchases", { p_limit: 200 });
    if (error) return setErr(friendly(error.message));
    setErr("");
    const d = data as { trips: Trip[]; drafts: Draft[] };
    setTrips(d.trips); setDrafts(d.drafts);
  }
  useEffect(() => { void load(); }, [openTrip]);

  const months = useMemo(() => {
    const by = new Map<string, Trip[]>();
    for (const t of trips ?? []) by.set(t.month, [...(by.get(t.month) ?? []), t]);
    return [...by.entries()];
  }, [trips]);

  if (openTrip) return <TripPage id={openTrip} onBack={() => onOpenTrip(null)} onChanged={onChanged} />;
  return (
    <div className="pad stack">
      <h1 className="serif">Spending</h1>
      <div className="seg" role="tablist">
        <button role="tab" aria-selected={view === "trips"} className={view === "trips" ? "on" : ""} onClick={() => setView("trips")}>Trips</button>
        <button role="tab" aria-selected={view === "budget"} className={view === "budget" ? "on" : ""} onClick={() => setView("budget")}>Budget</button>
      </div>
      {err && <p className="err">{err} <button className="link" onClick={() => void load()}>Retry</button></p>}
      {view === "budget" && <BudgetView />}
      {view === "trips" && <>
        {drafts.map((d) => (
          <button key={d.purchase_id} className="banner warn-b item-btn" onClick={() => onResume(d.purchase_id)}>
            Unfinished receipt from {dayLabel(d.created_at.slice(0, 10))}{d.total_cents != null ? ` (${euro(d.total_cents)})` : ""}. Tap to finish or discard.
          </button>
        ))}
        {trips === null && !err && <p className="muted">Loading…</p>}
        {trips && trips.length === 0 && <div className="card pad"><h2 className="serif">No trips yet</h2><p className="muted">Tap + and photograph a receipt. Each shop shows up here.</p></div>}
        {months.map(([m, ts]) => (
          <section key={m} className="stack-sm">
            <div className="between month-h"><h2 className="serif">{monthLabel(m)}</h2>
              <span className="muted">{euro(ts.reduce((s, t) => s + t.total_cents, 0))} · {ts.length} trip{ts.length === 1 ? "" : "s"}</span></div>
            {ts.map((t) => (
              <button key={t.purchase_id} className="card trip item-btn" onClick={() => onOpenTrip(t.purchase_id)}>
                <div className="grow"><strong>{t.chain}</strong><div className="muted">{dayLabel(t.local_date)} · {t.items} item{t.items === 1 ? "" : "s"}{t.verification === "adjusted" ? " · adjusted" : ""}</div></div>
                <span className="serif amt-big">{euro(t.total_cents)}</span>
              </button>
            ))}
          </section>
        ))}
      </>}
    </div>
  );
}

type Cat = { id: string; name_es: string; is_food: boolean };

function TripPage({ id, onBack, onChanged }: { id: string; onBack: () => void; onChanged: (u: UndoFn | null) => void }) {
  const [t, setT] = useState<TripFull | null>(null);
  const [err, setErr] = useState("");
  const [photo, setPhoto] = useState<string | null>(null);
  const [edit, setEdit] = useState<{ line: number; value: string } | null>(null);
  const [adding, setAdding] = useState<{ name: string; cat: string; qty: string; unit: string; price: string; id: string } | null>(null);
  const [cats, setCats] = useState<Cat[]>([]);
  const [busy, setBusy] = useState(false);
  useNames();

  async function load() {
    const { data, error } = await supabase.rpc("get_purchase", { p_purchase: id });
    if (error) setErr(friendly(error.message)); else setT(data as TripFull);
  }
  useEffect(() => { void load(); }, [id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (adding && !cats.length) void supabase.from("categories").select("id,name_es,is_food").order("name_es").then(({ data }) => setCats((data as Cat[]) ?? [])); }, [adding, cats.length]);

  async function run(f: () => Promise<UndoFn | null>) {
    setBusy(true); setErr("");
    try { onChanged(await f()); await load(); } catch (e) { setErr(friendly(e instanceof Error ? e.message : String(e))); }
    setBusy(false);
  }
  const cents = (v: string) => Math.round(Number(v.replace(",", ".")) * 100);
  async function showPhoto() {
    if (!t?.receipt_paths?.length) return;
    const { data } = await supabase.storage.from("receipts").createSignedUrl(t.receipt_paths[0], 300);
    if (data?.signedUrl) setPhoto(data.signedUrl);
  }
  return (
    <div className="pad stack">
      <button className="link back" onClick={onBack}>‹ All trips</button>
      {!t && !err && <p className="muted">Loading…</p>}
      {t && <>
        <div className="between"><div><h1 className="serif">{t.chain}</h1><p className="muted">{dayLabel(t.local_date)}{t.store_label ? ` · ${t.store_label}` : ""}</p></div>
          <span className="serif num">{euro(t.total_cents)}</span></div>
        {t.verification === "adjusted" && <p className="banner warn-b">Includes an unclassified amount so the total matches the ticket.</p>}
        <p className="small">Tap a price to fix it.</p>
        <div className="stack-sm">
          {t.lines.map((l) => (
            <div key={l.line_no} className="line card">
              <div className="grow">
                {l.kind === "adjustment" ? <strong>Unclassified</strong> : l.kind !== "item" ? <strong>{l.kind === "discount" ? "Discount" : "Refund"}</strong> : <Name n={prodName(l.product_id, l.name)} />}
                <div className="muted small">
                  {l.kind === "item" ? (l.printed_unit === "g" ? `${Number(l.printed_qty)} g` : `${Number(l.printed_qty)} ×`) : l.kind === "adjustment" ? "difference to the ticket total" : l.kind}
                  {l.lot ? ` · in pantry: ${Number(l.lot.qty_left)} ${l.lot.unit === "unit" ? "items" : l.lot.unit}${l.lot.state === "finished" ? " (finished)" : ""}` : l.kind === "item" && !l.product_id ? " · spend only" : ""}
                </div>
              </div>
              {edit?.line === l.line_no
                ? <span className="price-edit"><input inputMode="decimal" aria-label={`Price of ${l.name}`} value={edit.value} autoFocus onChange={(e) => setEdit({ ...edit, value: e.target.value })} />
                    <button className="chip on" disabled={busy || !Number.isFinite(cents(edit.value))} onClick={() => void run(async () => {
                      const { data, error } = await supabase.rpc("fix_line_price", { p_purchase: id, p_line_no: l.line_no, p_cents: cents(edit.value) });
                      if (error) throw new Error(error.message);
                      setEdit(null);
                      const old = (data as { old_cents: number }).old_cents;
                      return { text: `${l.name}: price changed`, run: async () => { await supabase.rpc("fix_line_price", { p_purchase: id, p_line_no: l.line_no, p_cents: old }); } };
                    })}>Save</button></span>
                : l.kind !== "adjustment"
                  ? <button className="amt price-btn" onClick={() => setEdit({ line: l.line_no, value: (l.line_total_cents / 100).toFixed(2) })}>{euro(l.line_total_cents)}</button>
                  : <span className="amt">{euro(l.line_total_cents)}</span>}
            </div>
          ))}
        </div>

        {!adding
          ? <button className="ghost" onClick={() => setAdding({ name: "", cat: "", qty: "1", unit: "unit", price: "", id: crypto.randomUUID() })}>Add a forgotten item</button>
          : <div className="card pad-in stack-sm">
              <label className="field">What is it<input value={adding.name} onChange={(e) => setAdding({ ...adding, name: e.target.value })} placeholder="Perejil" /></label>
              <label className="field">Type<select value={adding.cat} onChange={(e) => setAdding({ ...adding, cat: e.target.value })}>
                <option value="">Choose…</option>{[...cats].sort((a, b) => catName(a.id).en.localeCompare(catName(b.id).en)).map((c) => <option key={c.id} value={c.id}>{catName(c.id).en}</option>)}</select></label>
              <div className="row">
                <label className="field">How much<input inputMode="decimal" value={adding.qty} onChange={(e) => setAdding({ ...adding, qty: e.target.value })} /></label>
                <label className="field">Unit<select value={adding.unit} onChange={(e) => setAdding({ ...adding, unit: e.target.value })}><option value="unit">items</option><option value="g">grams</option><option value="ml">ml</option></select></label>
              </div>
              <label className="field">Price €<input inputMode="decimal" value={adding.price} onChange={(e) => setAdding({ ...adding, price: e.target.value })} placeholder="0.40" /></label>
              <div className="row">
                <button className="primary" disabled={busy || !adding.name.trim() || !adding.cat || !(Number(adding.qty) > 0) || !(cents(adding.price) >= 0)} onClick={() => void run(async () => {
                  const { error } = await supabase.rpc("add_trip_item", { p_purchase: id, p_line_id: adding.id, p_name: adding.name, p_category: adding.cat,
                    p_qty: Number(adding.qty.replace(",", ".")), p_unit: adding.unit, p_cents: cents(adding.price) });
                  if (error) throw new Error(error.message);
                  setAdding(null); return null;
                })}>Add</button>
                <button className="ghost" onClick={() => setAdding(null)}>Cancel</button>
              </div>
            </div>}

        {t.receipt_paths?.length > 0 && !photo && <button className="ghost" onClick={() => void showPhoto()}>Show receipt photo</button>}
        {photo && <img src={photo} alt="Receipt photo" className="receipt-img" />}
        <button className="ghost danger" disabled={busy} onClick={() => void run(async () => {
          const req = crypto.randomUUID();
          const { error } = await supabase.rpc("delete_trip", { p_purchase: id, p_request: req });
          if (error) throw new Error(error.message);
          onBack();
          return { text: `${t.chain} trip deleted`, run: async () => { const { error: e } = await supabase.rpc("undo_delete_trip", { p_purchase: id, p_request: req }); if (e) throw new Error(e.message); } };
        })}>Delete this trip</button>
      </>}
      {err && <p className="err" role="alert">{err}</p>}
    </div>
  );
}

type Budget = { month: string; budget_cents: number | null; spent_cents: number; left_cents: number | null; pct: number | null;
  alert: "near" | "over" | null; days_left: number; trips: number; food_cents: number; nonfood_cents: number; waste_cents: number;
  by_category: { category_id: string; name: string; is_food: boolean | null; cents: number }[];
  by_chain: { chain: string; cents: number; trips: number }[]; history: { month: string; cents: number }[];
  projection: { projected_cents?: number; next_shop?: string; alert?: boolean; needs?: string } | null };

function BudgetView() {
  useNames();
  const [b, setB] = useState<Budget | null>(null);
  const [err, setErr] = useState("");
  const [edit, setEdit] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function load() {
    const { data, error } = await supabase.rpc("budget_status");
    if (error) setErr(friendly(error.message)); else { setErr(""); setB(data as Budget); }
  }
  useEffect(() => { void load(); }, []);
  async function save() {
    const cents = Math.round(Number((edit ?? "").replace(",", ".")) * 100);
    if (!(cents > 0)) return setErr("Type an amount, for example 250.");
    setBusy(true);
    const { data, error } = await supabase.rpc("set_budget", { p_amount_cents: cents });
    setBusy(false);
    if (error) setErr(friendly(error.message)); else { setB(data as Budget); setEdit(null); setErr(""); }
  }
  if (!b) return <p className={err ? "err" : "muted"}>{err || "Loading…"}</p>;
  const pct = Math.min(100, b.pct ?? 0);
  const maxHist = Math.max(1, ...b.history.map((h) => h.cents));
  const maxCat = Math.max(1, ...b.by_category.map((c) => Math.abs(c.cents)));
  const monthName = new Date(`${b.month}-15T12:00:00`).toLocaleDateString("en-GB", { month: "long" });

  return (
    <div className="stack">
      {(b.budget_cents == null || edit !== null) ? (
        <div className="card pad-in stack-sm">
          <strong className="serif">{b.budget_cents == null ? "Set a monthly budget" : "Change your monthly budget"}</strong>
          <p className="muted small">For groceries and household shopping. You'll get a warning at 80% and at 100%.</p>
          <div className="row">
            <label className="total-in">€<input inputMode="decimal" aria-label="Monthly budget" placeholder="250" value={edit ?? ""} onChange={(e) => setEdit(e.target.value)} /></label>
            <button className="primary" disabled={busy} onClick={() => void save()}>Save</button>
          </div>
          {b.budget_cents != null && <button className="link" style={{ alignSelf: "flex-start" }} onClick={() => setEdit(null)}>Cancel</button>}
        </div>
      ) : (
        <div className={`card pad-in budget-card ${b.alert ? "alert" : ""}`}>
          <div className="between"><span className="muted">{monthName}</span><button className="link" onClick={() => setEdit(String((b.budget_cents ?? 0) / 100))}>Edit</button></div>
          <div className="budget-big"><span className="serif">{euro(b.spent_cents)}</span><span className="muted"> of {euro(b.budget_cents)}</span></div>
          <div className="meter" role="img" aria-label={`${b.pct}% of the budget used`}>
            <div className={`meter-fill ${b.alert ?? ""}`} style={{ width: `${pct}%` }} />
            <div className="meter-mark" style={{ left: "80%" }} />
          </div>
          <div className="between small-row">
            <span>{b.left_cents != null && b.left_cents >= 0 ? `${euro(b.left_cents)} left` : `${euro(Math.abs(b.left_cents ?? 0))} over`}</span>
            <span className="muted">{b.days_left} day{b.days_left === 1 ? "" : "s"} to go · {b.trips} trip{b.trips === 1 ? "" : "s"}</span>
          </div>
          {b.alert === "near" && <p className="banner warn-b">You've used {b.pct}% of this month's budget.</p>}
          {b.alert === "over" && <p className="banner alert-b">You're over this month's budget.</p>}
          {b.projection?.projected_cents != null && (
            <p className={`small ${b.projection.alert ? "red-t" : ""}`}>At your usual pace this month ends near {euro(b.projection.projected_cents)}.{b.projection.alert ? " That's over budget." : ""}</p>
          )}
          {b.projection?.needs && <p className="small">Forecast: {b.projection.needs.toLowerCase()} of history first.</p>}
        </div>
      )}

      {b.by_category.length > 0 && (
        <section className="stack-sm">
          <h2 className="serif">Where it went</h2>
          <div className="card pad-in stack-sm">
            {b.by_category.slice(0, 8).map((c) => (
              <div key={c.category_id} className="bar-row">
                <span className="bar-label">{catName(c.category_id).en}</span>
                <div className="bar-track"><div className={`bar-fill ${c.is_food === false ? "nonfood" : ""}`} style={{ width: `${Math.max(2, (Math.abs(c.cents) / maxCat) * 100)}%` }} /></div>
                <span className="amt">{euro(c.cents)}</span>
              </div>
            ))}
            <div className="between small-row"><span>Food {euro(b.food_cents)}</span><span>Household {euro(b.nonfood_cents)}</span></div>
          </div>
        </section>
      )}

      <div className="stats">
        <div className="stat card"><span className="muted">Thrown away</span><span className="serif stat-n">{euro(b.waste_cents)}</span></div>
        {b.by_chain.slice(0, 2).map((c) => (
          <div key={c.chain} className="stat card"><span className="muted">{c.chain}</span><span className="serif stat-n">{euro(c.cents)}</span></div>
        ))}
      </div>

      <section className="stack-sm">
        <h2 className="serif">Last 6 months</h2>
        <div className="card pad-in hist-chart" role="img" aria-label="Spending in the last 6 months">
          {b.history.map((h) => (
            <div key={h.month} className="hist-col">
              <span className="muted small">{h.cents ? `€${Math.round(h.cents / 100)}` : ""}</span>
              <div className="hist-bar" style={{ height: `${Math.max(3, (h.cents / maxHist) * 100)}%` }} />
              <span className="small">{new Date(`${h.month}-15T12:00:00`).toLocaleDateString("en-GB", { month: "short" })}</span>
            </div>
          ))}
        </div>
      </section>
      {err && <p className="err">{err}</p>}
    </div>
  );
}
