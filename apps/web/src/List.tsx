// Shopping list (first slice of step 8): add by hand or from suggestions, tick off in the shop, see what it will cost.
// The automatic rules (below par, runs out soon, usual purchase) come with step 8 and fill the same list.
import { useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "./supabase";
import { euro, friendly } from "./shared";
import type { UndoFn } from "./Item";
import { Tile } from "./Icons";

type Item = { id: string; label: string; quantity: number | null; unit: string | null; reasons: string[]; ingredient_id: string | null;
  product_id: string | null; last: { chain: string; product: string; price_cents: number } | null };
type Sugg = { label: string; ingredient_id: string | null; product_id: string | null; why: string };
type ListData = { items: Item[]; basket: { id: string; label: string }[]; suggestions: Sugg[]; estimate_cents: number;
  estimate_unknown: number; budget_left_cents: number | null };
type Option = { label: string; ingredient_id?: string; product_id?: string; hint: string };

const norm = (s: string) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");

// Add one thing to the list (used here, from the item page and from Home).
export async function addToList(entry: { label?: string; ingredient_id?: string | null; product_id?: string | null }) {
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

  async function load() {
    const { data, error } = await supabase.rpc("get_shopping_list");
    if (error) setErr(friendly(error.message)); else { setErr(""); setD(data as ListData); }
  }
  useEffect(() => {
    void load();
    // what you can pick from: every ingredient, plus the products you've bought
    void Promise.all([
      supabase.from("ingredients").select("id,name_es").order("name_es"),
      supabase.from("products").select("id,name,ingredient_id").order("name"),
    ]).then(([i, p]) => setOpts([
      ...((p.data as { id: string; name: string; ingredient_id: string | null }[]) ?? []).map((x) => ({ label: x.name, product_id: x.id, ingredient_id: x.ingredient_id ?? undefined, hint: "you've bought this" })),
      ...((i.data as { id: string; name_es: string }[]) ?? []).map((x) => ({ label: x.name_es[0].toUpperCase() + x.name_es.slice(1), ingredient_id: x.id, hint: "any brand" })),
    ]));
  }, []);

  const matches = useMemo(() => {
    const q = norm(text.trim());
    if (q.length < 2) return [];
    const seen = new Set<string>();
    return opts.filter((o) => norm(o.label).includes(q)).filter((o) => { const k = norm(o.label); if (seen.has(k)) return false; seen.add(k); return true; }).slice(0, 6);
  }, [text, opts]);

  async function run(f: () => Promise<UndoFn | null>) {
    if (busy.current) return; busy.current = true; setErr("");
    try { const u = await f(); onChanged(u); await load(); } catch (e) { setErr(friendly(e instanceof Error ? e.message : String(e))); }
    busy.current = false;
  }
  const update = async (args: Record<string, unknown>) => { const { error } = await supabase.rpc("update_shopping_list", args); if (error) throw new Error(error.message); };
  const add = (o: { label?: string; ingredient_id?: string | null; product_id?: string | null }) => run(async () => { await addToList(o); setText(""); return null; });
  const tick = (i: Item) => run(async () => { await update({ p_bought: [i.id] }); return { text: `${i.label}: in the basket`, run: () => update({ p_reopen: [i.id] }) }; });
  const remove = (i: Item) => run(async () => { await update({ p_dismiss: [i.id] }); return { text: `${i.label}: removed`, run: () => update({ p_reopen: [i.id] }) }; });

  return (
    <div className="pad stack">
      <div className="between"><h1 className="serif">Shopping list</h1>{d && <span className="muted">{d.items.length} to buy</span>}</div>

      <form className="add-row" onSubmit={(e) => { e.preventDefault(); if (text.trim()) void add(matches[0] && norm(matches[0].label) === norm(text.trim()) ? matches[0] : { label: text.trim() }); }}>
        <input value={text} onChange={(e) => setText(e.target.value)} placeholder="Add milk, eggs, paper towels…" aria-label="Add to the list" autoComplete="off" />
        <button className="primary add-btn" type="submit" disabled={!text.trim()} aria-label="Add">+</button>
        {matches.length > 0 && (
          <div className="suggest-box" role="listbox">
            {matches.map((o) => (
              <button type="button" key={o.label + (o.product_id ?? o.ingredient_id)} className="suggest-opt" onClick={() => void add(o)}>
                <span>{o.label}</span><span className="muted small">{o.hint}</span>
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
                <strong>{i.label}{i.quantity ? ` ×${Number(i.quantity)}` : ""}</strong>
                <div className="muted small">{i.last ? `last: ${i.last.chain} · ${euro(i.last.price_cents)}` : "not bought here yet"}{i.reasons.includes("claude") ? " · added by Claude" : ""}</div>
              </div>
              <button className="x-btn" aria-label={`Remove ${i.label}`} onClick={() => void remove(i)}>×</button>
            </div>
          ))}
        </section>
      )}

      {d && d.suggestions.length > 0 && (
        <section className="stack-sm">
          <h2 className="serif">You ran out of</h2>
          <div className="chips">
            {d.suggestions.map((s) => (
              <button key={s.label} className="chip sugg" onClick={() => void add(s)}>+ {s.label}<span className="muted small"> · {s.why}</span></button>
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
