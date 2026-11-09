// Item page (D17, step 4b): where and when it was bought, and every action with Undo instead of "are you sure?".
import { useEffect, useRef, useState } from "react";
import { supabase } from "./supabase";
import { dayLabel, euro, friendly } from "./shared";

export type UndoFn = { text: string; run: () => Promise<void> };
type LotFull = {
  lot_id: string; name: string; category: string; ingredient: string | null; unit: string; location: string;
  initial_qty: number; qty_left: number; expires_on: string; effective_expires_on: string; days_left: number; state: string;
  expiry_kind: string; expiry_source: string; opened_on: string | null; frozen_on: string | null; can_open: boolean; can_freeze: boolean;
  bought: { purchase_id: string; chain: string; local_date: string; line_total_cents: number | null } | null;
  history: { id: string; delta: number; reason: string; at: string; undone: boolean; is_undo: boolean }[];
};

const unitWord = (u: string, n: number) => (u === "unit" ? (n === 1 ? "item" : "items") : u);
const PLACE: Record<string, string> = { fridge: "Fridge", freezer: "Freezer", pantry: "Cupboard" };

// Used / threw away, with an undo that appends the opposite movement.
export async function takeFromLot(lotId: string, qty: number, reason: "consume" | "discard", name: string): Promise<UndoFn> {
  const moveId = crypto.randomUUID();
  const { error } = await supabase.rpc("consume", { p_lot: lotId, p_qty: qty, p_reason: reason, p_movement_id: moveId });
  if (error) throw new Error(error.message);
  const undoId = crypto.randomUUID();
  return {
    text: reason === "discard" ? `${name}: thrown away` : `${name}: marked as used`,
    run: async () => { const { error: e } = await supabase.rpc("undo_movement", { p_movement: moveId, p_undo_id: undoId }); if (e) throw new Error(e.message); },
  };
}

export function ItemPage({ lotId, onBack, onChanged, onOpenTrip }: {
  lotId: string; onBack: () => void; onChanged: (undo: UndoFn | null) => void; onOpenTrip: (id: string) => void;
}) {
  const [lot, setLot] = useState<LotFull | null>(null);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const [some, setSome] = useState<string | null>(null);
  const [date, setDate] = useState<string | null>(null);
  const alive = useRef(true);

  async function load() {
    const { data, error } = await supabase.rpc("get_lot", { p_lot: lotId });
    if (!alive.current) return;
    if (error) setErr(friendly(error.message)); else setLot(data as LotFull);
  }
  useEffect(() => { alive.current = true; void load(); return () => { alive.current = false; }; }, [lotId]); // eslint-disable-line react-hooks/exhaustive-deps

  async function act(f: () => Promise<UndoFn | null>, leave = false) {
    setBusy(true); setErr("");
    try { const u = await f(); onChanged(u); if (leave) onBack(); else await load(); }
    catch (e) { setErr(friendly(e instanceof Error ? e.message : String(e))); }
    setBusy(false);
  }
  const mark = (action: string, text: string) => act(async () => {
    const { data, error } = await supabase.rpc("mark_lot", { p_lot: lotId, p_action: action });
    if (error) throw new Error(error.message);
    const prev = (data as { prev: unknown }).prev;
    return { text, run: async () => { const { error: e } = await supabase.rpc("mark_lot", { p_lot: lotId, p_action: "restore", p_prev: prev }); if (e) throw new Error(e.message); } };
  });

  if (!lot) return (
    <div className="pad stack"><button className="link back" onClick={onBack}>‹ Pantry</button><p className={err ? "err" : "muted"}>{err || "Loading…"}</p></div>
  );
  const q = Number(lot.qty_left);
  const flag = lot.state !== "ok" || lot.days_left <= 3;
  const when = lot.state === "finished" ? "Finished" : lot.state === "expired" ? "Past its date" : lot.state === "check" ? "Check it" :
    lot.days_left === 0 ? "Use today" : `${lot.expiry_kind === "estimate" ? "about " : ""}${lot.days_left} day${lot.days_left === 1 ? "" : "s"} left`;

  return (
    <div className="pad stack">
      <button className="link back" onClick={onBack}>‹ Pantry</button>
      <div>
        <h1 className="serif">{lot.name}</h1>
        <p className="muted">{lot.category}{lot.ingredient ? ` · ${lot.ingredient}` : ""}</p>
      </div>
      <div className={`card pad-in ${flag ? "alert" : ""}`}>
        <div className="between"><span className="serif num" style={{ color: flag ? "var(--red)" : undefined }}>{when}</span></div>
        <p className="muted">{q} {unitWord(lot.unit, q)} left · {PLACE[lot.location] ?? lot.location}
          {lot.opened_on ? " · opened" : ""}{lot.frozen_on ? ` · frozen ${dayLabel(lot.frozen_on)}` : ""}</p>
        <p className="muted small">Date {lot.effective_expires_on}{lot.expiry_source === "default" ? " (estimated from the type)" : lot.expiry_source === "printed" ? " (from the label)" : ""}
          {lot.expiry_kind === "use_by" ? " · Caducidad" : lot.expiry_kind === "best_before" ? " · Consumir pref." : ""}</p>
      </div>

      {lot.bought && (
        <button className="card trip item-btn" onClick={() => onOpenTrip(lot.bought!.purchase_id)}>
          <div className="grow"><strong>Bought at {lot.bought.chain}</strong><div className="muted">{dayLabel(lot.bought.local_date)}</div></div>
          {lot.bought.line_total_cents != null && <span className="amt">{euro(lot.bought.line_total_cents)}</span>}<span className="muted">›</span>
        </button>
      )}

      {q > 0 && <div className="stack-sm">
        {some === null
          ? <button className="ghost" disabled={busy} onClick={() => setSome(String(lot.unit === "unit" ? 1 : Math.round(q / 2)))}>Used some</button>
          : <div className="card pad-in stack-sm">
              <label className="field">How much did you use ({unitWord(lot.unit, 2)})?
                <input type="number" inputMode="decimal" min="0" step="any" value={some} onChange={(e) => setSome(e.target.value)} /></label>
              <div className="row">
                <button className="primary" disabled={busy || !(Number(some) > 0)} onClick={() => void act(() => takeFromLot(lot.lot_id, Number(some), "consume", lot.name)).then(() => setSome(null))}>Save</button>
                <button className="ghost" onClick={() => setSome(null)}>Cancel</button>
              </div>
            </div>}
        <button className="primary" disabled={busy} onClick={() => void act(() => takeFromLot(lot.lot_id, q, "consume", lot.name), true)}>All gone</button>
        <button className="ghost danger" disabled={busy} onClick={() => void act(() => takeFromLot(lot.lot_id, q, "discard", lot.name), true)}>Threw it away</button>
        <div className="row">
          {lot.can_open && !lot.opened_on && !lot.frozen_on && <button className="ghost" disabled={busy} onClick={() => void mark("opened", `${lot.name}: opened`)}>Opened it</button>}
          {lot.can_freeze && !lot.frozen_on && <button className="ghost" disabled={busy} onClick={() => void mark("frozen", `${lot.name}: moved to the freezer`)}>Froze it</button>}
          {lot.frozen_on && <button className="ghost" disabled={busy} onClick={() => void mark("thawed", `${lot.name}: thawed`)}>Thawed it</button>}
          {(lot.state === "check" || lot.state === "unconfirmed") && <button className="ghost" disabled={busy} onClick={() => void mark("still_have", `${lot.name}: still have it`)}>Still have it</button>}
        </div>
      </div>}

      {date === null
        ? <button className="link" style={{ alignSelf: "flex-start" }} onClick={() => setDate(lot.expires_on)}>Change date</button>
        : <div className="card pad-in stack-sm">
            <label className="field">Date on the label<input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
            <div className="row">
              <button className="primary" disabled={busy || !date} onClick={() => void act(async () => {
                const before = lot.expires_on;
                const { error } = await supabase.rpc("set_lot_expiry", { p_lot: lot.lot_id, p_expires_on: date });
                if (error) throw new Error(error.message);
                setDate(null);
                return { text: `${lot.name}: date changed`, run: async () => { await supabase.rpc("set_lot_expiry", { p_lot: lot.lot_id, p_expires_on: before }); } };
              })}>Save date</button>
              <button className="ghost" onClick={() => setDate(null)}>Cancel</button>
            </div>
          </div>}

      {err && <p className="err" role="alert">{err}</p>}

      <section className="stack-sm">
        <h2 className="serif">History</h2>
        {lot.history.map((h) => (
          <div key={h.id} className="between hist">
            <span>{h.is_undo ? "Undone" : h.reason === "purchase" ? "Bought" : h.reason === "consume" ? "Used" : h.reason === "discard" ? "Thrown away" : "Added"}
              {!h.is_undo ? ` ${Math.abs(Number(h.delta))} ${unitWord(lot.unit, Math.abs(Number(h.delta)))}` : ""}{h.undone ? " (undone)" : ""}</span>
            <span className="muted small">{new Date(h.at).toLocaleString("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })}</span>
          </div>
        ))}
      </section>
    </div>
  );
}

// The Undo bar: 6 seconds (D16), paused while a finger is on it.
export function UndoBar({ undo, onDone }: { undo: UndoFn; onDone: () => void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const left = useRef(6000);
  const held = useRef(false);
  useEffect(() => {
    left.current = 6000; setErr("");
    const t = setInterval(() => {
      if (held.current) return;
      left.current -= 200;
      if (left.current <= 0) { clearInterval(t); onDone(); }
    }, 200);
    return () => clearInterval(t);
  }, [undo]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <div className="undo" role="status" onPointerDown={() => (held.current = true)} onPointerUp={() => (held.current = false)}
         onPointerLeave={() => (held.current = false)}>
      <span className="grow">{err || undo.text}</span>
      <button className="undo-btn" disabled={busy} onClick={async () => {
        setBusy(true);
        try { await undo.run(); onDone(); } catch (e) { setErr(friendly(e instanceof Error ? e.message : String(e))); }
        setBusy(false);
      }}>Undo</button>
    </div>
  );
}
