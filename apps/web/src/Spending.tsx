// Spending tab (D15): Trips first (past shops by month -> trip page), Budget second (arrives in step 7).
import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { dayLabel, euro, friendly, monthLabel } from "./shared";

type Trip = { purchase_id: string; chain: string; store_label: string | null; local_date: string; month: string;
  total_cents: number; verification: string; items: number; lots: number };
type Draft = { purchase_id: string; chain_id: string; created_at: string; total_cents: number | null };
type TLine = { line_no: number; kind: string; name: string; raw_text: string | null; is_food: boolean; printed_qty: number; printed_unit: string;
  line_total_cents: number; product_id: string | null;
  lot: { lot_id: string; qty_left: number; unit: string; state: string; days_left: number | null } | null };
type TripFull = { purchase_id: string; chain: string; store_label: string | null; local_date: string; total_cents: number;
  verification: string; ticket_number: string | null; receipt_paths: string[]; lines: TLine[] };

export function Spending({ openTrip, onOpenTrip, onResume }: {
  openTrip: string | null; onOpenTrip: (id: string | null) => void; onResume: (id: string) => void;
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

  if (openTrip) return <TripPage id={openTrip} onBack={() => onOpenTrip(null)} />;
  return (
    <div className="pad stack">
      <h1 className="serif">Spending</h1>
      <div className="seg" role="tablist">
        <button role="tab" aria-selected={view === "trips"} className={view === "trips" ? "on" : ""} onClick={() => setView("trips")}>Trips</button>
        <button role="tab" aria-selected={view === "budget"} className={view === "budget" ? "on" : ""} onClick={() => setView("budget")}>Budget</button>
      </div>
      {err && <p className="err">{err} <button className="link" onClick={() => void load()}>Retry</button></p>}
      {view === "budget" && <p className="muted">Your monthly budget, alerts at 80% and 100%, and where the money goes arrive with the budget step.</p>}
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

function TripPage({ id, onBack }: { id: string; onBack: () => void }) {
  const [t, setT] = useState<TripFull | null>(null);
  const [err, setErr] = useState("");
  const [photo, setPhoto] = useState<string | null>(null);
  useEffect(() => {
    void supabase.rpc("get_purchase", { p_purchase: id }).then(({ data, error }) => {
      if (error) setErr(friendly(error.message)); else setT(data as TripFull);
    });
  }, [id]);
  async function showPhoto() {
    if (!t?.receipt_paths?.length) return;
    const { data } = await supabase.storage.from("receipts").createSignedUrl(t.receipt_paths[0], 300);
    if (data?.signedUrl) setPhoto(data.signedUrl);
  }
  return (
    <div className="pad stack">
      <button className="link back" onClick={onBack}>‹ All trips</button>
      {err && <p className="err">{err}</p>}
      {!t && !err && <p className="muted">Loading…</p>}
      {t && <>
        <div className="between"><div><h1 className="serif">{t.chain}</h1><p className="muted">{dayLabel(t.local_date)}{t.store_label ? ` · ${t.store_label}` : ""}</p></div>
          <span className="serif num">{euro(t.total_cents)}</span></div>
        {t.verification === "adjusted" && <p className="banner warn-b">Includes an unclassified amount so the total matches the ticket.</p>}
        <div className="stack-sm">
          {t.lines.map((l) => (
            <div key={l.line_no} className="line card">
              <div className="grow">
                <strong>{l.name}</strong>
                <div className="muted small">
                  {l.kind === "item" ? (l.printed_unit === "g" ? `${Number(l.printed_qty)} g` : `${Number(l.printed_qty)} ×`) : l.kind}
                  {l.lot ? ` · in pantry: ${Number(l.lot.qty_left)} ${l.lot.unit === "unit" ? "items" : l.lot.unit}${l.lot.state === "finished" ? " (finished)" : ""}` : l.kind === "item" && !l.product_id ? " · spend only" : ""}
                </div>
              </div>
              <span className="amt">{euro(l.line_total_cents)}</span>
            </div>
          ))}
        </div>
        {t.receipt_paths?.length > 0 && !photo && <button className="ghost" onClick={() => void showPhoto()}>Show receipt photo</button>}
        {photo && <img src={photo} alt="Receipt photo" className="receipt-img" />}
        <p className="muted small">Fixing a price, adding a forgotten item and deleting a trip come next.</p>
      </>}
    </div>
  );
}
