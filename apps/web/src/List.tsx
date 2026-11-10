// Shopping list (first slice of step 8): add by hand or from suggestions, tick off in the shop, see what it will cost.
// The automatic rules (below par, runs out soon, usual purchase) come with step 8 and fill the same list.
import { useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "./supabase";
import { euro, friendly } from "./shared";
import type { UndoFn } from "./Item";
import { Tile } from "./Icons";
import { allIngredients, allProducts, itemName, Name, useNames } from "./names";

type Item = { id: string; label: string; quantity: number | null; unit: string | null; reasons: string[]; ingredient_id: string | null;
  product_id: string | null; last: { chain: string; product: string; price_cents: number } | null };
type Sugg = { label: string; ingredient_id: string | null; product_id: string | null; why: string };
type ListData = { items: Item[]; basket: { id: string; label: string }[]; suggestions: Sugg[]; estimate_cents: number;
  estimate_unknown: number; budget_left_cents: number | null };
type Option = { label: string; es: string | null; ingredient_id?: string; product_id?: string; hint: string };

const UNITS: { id: string | null; label: string }[] = [{ id: null, label: "items" }, { id: "pack", label: "packs" }, { id: "kg", label: "kg" }, { id: "g", label: "g" }, { id: "l", label: "L" }, { id: "ml", label: "ml" }];
export const qtyText = (q: number | null, u: string | null) => q == null ? "" : u == null ? `×${Number(q)}` : `${Number(q)} ${u === "pack" ? (Number(q) === 1 ? "pack" : "packs") : u === "l" ? "L" : u}`;
// "2 milk", "500g cheese", "1.5 kg potatoes" -> quantity, unit, name
function parseAdd(t: string): { quantity?: number; unit?: string | null; label: string } {
  const m = t.trim().match(/^(\d+(?:[.,]\d+)?)\s*(kg|g|ml|l|packs?|x|×)?\s+(.+)$/i);
  if (!m) return { label: t.trim() };
  const u = (m[2] ?? "").toLowerCase();
  return { quantity: Number(m[1].replace(",", ".")), unit: u.startsWith("pack") ? "pack" : ["kg", "g", "ml", "l"].includes(u) ? u : null, label: m[3].trim() };
}

const norm = (s: string) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");

// Add one thing to the list (used here, from the item page and from Home).
export async function addToList(entry: { label?: string; ingredient_id?: string | null; product_id?: string | null; quantity?: number; unit?: string | null }) {
  const { data, error } = await supabase.rpc("update_shopping_list", { p_add: [{ id: crypto.randomUUID(), ...entry }] });
  if (error) throw new Error(error.message);
  return data as ListData;
}

export function ListTab({ onChanged }: { onChanged: (u: UndoFn | null) => void }) {
  const [d, setD] = useState<ListData | null>(null);
  const [err, setErr] = useState("");
  const [text, setText] = useState("");
  const [opts, setOpts] = useState<Option[]>([]);
  const [showBasket, setShowBasket] = useState(false);
  const busy = useRef(false);
  const [qEdit, setQEdit] = useState<{ id: string; q: string; unit: string | null } | null>(null);
  useNames();

  async function load() {
    const { data, error } = await supabase.rpc("get_shopping_list");
    if (error) setErr(friendly(error.message)); else { setErr(""); setD(data as ListData); }
  }
  useEffect(() => {
    void load();
  }, []);
  // what you can pick from: the products you've bought, plus every ingredient (English first, Spanish as a hint)
  const ing = allIngredients(); const prods = allProducts();
  useEffect(() => {
    setOpts([
      ...prods.map(([id, p]) => { const n = itemName(id, p.ing, p.es); return { label: n.en, es: n.es, product_id: id, ingredient_id: p.ing ?? undefined, hint: "you've bought this" }; }),
      ...ing.map(([id, n]) => ({ label: n.en, es: n.es, ingredient_id: id, hint: "any brand" })),
    ]);
  }, [ing.length, prods.length]); // eslint-disable-line react-hooks/exhaustive-deps


  const matches = useMemo(() => {
    const q = norm(parseAdd(text).label);
    if (q.length < 2) return [];
    const seen = new Set<string>();
    return opts.filter((o) => norm(o.label).includes(q) || (o.es != null && norm(o.es).includes(q))).filter((o) => { const k = norm(o.label); if (seen.has(k)) return false; seen.add(k); return true; }).slice(0, 6);
  }, [text, opts]);

  async function run(f: () => Promise<UndoFn | null>) {
    if (busy.current) return; busy.current = true; setErr("");
    try { const u = await f(); onChanged(u); await load(); } catch (e) { setErr(friendly(e instanceof Error ? e.message : String(e))); }
    busy.current = false;
  }
  const update = async (args: Record<string, unknown>) => { const { error } = await supabase.rpc("update_shopping_list", args); if (error) throw new Error(error.message); };
  const add = (o: { label?: string; ingredient_id?: string | null; product_id?: string | null }) => run(async () => {
    const p = parseAdd(text);
    await addToList({ label: o.label, ingredient_id: o.ingredient_id, product_id: o.product_id, ...(p.quantity ? { quantity: p.quantity, unit: p.unit ?? null } : {}) });
    setText(""); return null;
  });
  const saveQty = () => run(async () => {
    if (!qEdit) return null;
    const q = qEdit.q.trim() === "" ? null : Number(qEdit.q.replace(",", "."));
    const { error } = await supabase.rpc("set_list_quantity", { p_item: qEdit.id, p_quantity: q && q > 0 ? q : null, p_unit: qEdit.unit });
    if (error) throw new Error(error.message);
    setQEdit(null); return null;
  });
  const tick = (i: Item) => run(async () => { await update({ p_bought: [i.id] }); return { text: `${itemName(i.product_id, i.ingredient_id, i.label).en}: in the basket`, run: () => update({ p_reopen: [i.id] }) }; });
  const remove = (i: Item) => run(async () => { await update({ p_dismiss: [i.id] }); return { text: `${itemName(i.product_id, i.ingredient_id, i.label).en}: removed`, run: () => update({ p_reopen: [i.id] }) }; });

  return (
    <div className="pad stack">
      <div className="between"><h1 className="serif">Shopping list</h1>{d && <span className="muted">{d.items.length} to buy</span>}</div>

      <form className="add-row" onSubmit={(e) => { e.preventDefault(); const lab = parseAdd(text).label; if (lab) void add(matches[0] && norm(matches[0].label) === norm(lab) ? matches[0] : { label: lab }); }}>
        <input value={text} onChange={(e) => setText(e.target.value)} placeholder="Add “2 milk”, eggs, 500 g cheese…" aria-label="Add to the list" autoComplete="off" />
        <button className="primary add-btn" type="submit" disabled={!text.trim()} aria-label="Add">+</button>
        {matches.length > 0 && (
          <div className="suggest-box" role="listbox">
            {matches.map((o) => (
              <button type="button" key={o.label + (o.product_id ?? o.ingredient_id)} className="suggest-opt" onClick={() => void add(o)}>
                <span><span>{o.label}</span>{o.es && norm(o.es) !== norm(o.label) && <span className="es">{o.es}</span>}</span><span className="muted small">{o.hint}</span>
              </button>
            ))}
          </div>
        )}
      </form>

      {d && d.items.length > 0 && (
        <div className="card est">
          <Tile id="receipt" bg="#ECE6D8" size={44} />
          <div className="grow">
            <strong>About {euro(d.estimate_cents)}</strong>
            <div className="muted small">
              {d.estimate_unknown > 0 ? `${d.estimate_unknown} item${d.estimate_unknown === 1 ? "" : "s"} without a price yet · ` : ""}
              {d.budget_left_cents != null ? `leaves ${euro(d.budget_left_cents - d.estimate_cents)} of this month's budget` : "set a budget in Spending to compare"}
            </div>
          </div>
        </div>
      )}

      {err && <p className="err" role="alert">{err} <button className="link" onClick={() => void load()}>Retry</button></p>}
      {!d && !err && <p className="muted">Loading…</p>}
      {d && d.items.length === 0 && (
        <div className="card pad-in"><strong className="serif">Nothing to buy yet</strong><p className="muted">Type above, or tap a suggestion below. Things you run out of will show up here.</p></div>
      )}

      {d && d.items.length > 0 && (
        <section className="stack-sm">
          {d.items.map((i) => (
            <div key={i.id} className="card list-row">
              <button className="tick" aria-label={`Tick off ${i.label}`} onClick={() => void tick(i)} />
              <div className="grow">
                <Name n={itemName(i.product_id, i.ingredient_id, i.label)} />
                <div className="muted small">{i.last ? `last: ${i.last.chain} · ${euro(i.last.price_cents)}` : "not bought here yet"}{i.reasons.includes("claude") ? " · added by Claude" : ""}</div>
              </div>
              <button className={`qty-chip${i.quantity ? " on" : ""}`} aria-label={`How many ${i.label}`}
                      onClick={() => setQEdit(qEdit?.id === i.id ? null : { id: i.id, q: i.quantity ? String(Number(i.quantity)) : "1", unit: i.unit })}>
                {i.quantity ? qtyText(i.quantity, i.unit) : "Qty"}
              </button>
              <button className="x-btn" aria-label={`Remove ${i.label}`} onClick={() => void remove(i)}>×</button>
              {qEdit?.id === i.id && (
                <div className="qty-edit">
                  <div className="stepper">
                    <button type="button" aria-label="Less" onClick={() => setQEdit({ ...qEdit, q: String(Math.max(0, (Number(qEdit.q.replace(",", ".")) || 0) - (qEdit.unit === "g" || qEdit.unit === "ml" ? 100 : 1))) })}>−</button>
                    <input inputMode="decimal" aria-label="Quantity" value={qEdit.q} onChange={(e) => setQEdit({ ...qEdit, q: e.target.value })} />
                    <button type="button" aria-label="More" onClick={() => setQEdit({ ...qEdit, q: String((Number(qEdit.q.replace(",", ".")) || 0) + (qEdit.unit === "g" || qEdit.unit === "ml" ? 100 : 1)) })}>+</button>
                  </div>
                  <div className="chips">
                    {UNITS.map((u) => <button type="button" key={u.label} className={`chip small-chip${qEdit.unit === u.id ? " on" : ""}`} onClick={() => setQEdit({ ...qEdit, unit: u.id })}>{u.label}</button>)}
                  </div>
                  <div className="row">
                    <button type="button" className="primary" onClick={() => void saveQty()}>Done</button>
                    <button type="button" className="ghost" onClick={() => void run(async () => { await supabase.rpc("set_list_quantity", { p_item: i.id, p_quantity: null }); setQEdit(null); return null; })}>No quantity</button>
                  </div>
                </div>
              )}
            </div>
          ))}
        </section>
      )}

      {d && d.suggestions.length > 0 && (
        <section className="stack-sm">
          <h2 className="serif">You ran out of</h2>
          <div className="chips">
            {d.suggestions.map((s) => (
              <button key={s.label} className="chip sugg" onClick={() => void add(s)}>+ {itemName(s.product_id, s.ingredient_id, s.label).en}<span className="muted small"> · {s.why}</span></button>
            ))}
          </div>
        </section>
      )}

      {d && d.basket.length > 0 && (
        <section className="stack-sm">
          <button className="link" style={{ alignSelf: "flex-start" }} onClick={() => setShowBasket((v) => !v)}>
            {showBasket ? "Hide" : "Show"} basket ({d.basket.length})
          </button>
          {showBasket && d.basket.map((b) => (
            <div key={b.id} className="card list-row done">
              <button className="tick on" aria-label={`Untick ${b.label}`} onClick={() => void run(async () => { await update({ p_reopen: [b.id] }); return null; })} />
              <span className="grow">{b.label}</span>
            </div>
          ))}
          <p className="small">Ticked items stay in the basket until your receipt is logged, so they aren't suggested again meanwhile.</p>
        </section>
      )}
    </div>
  );
}
