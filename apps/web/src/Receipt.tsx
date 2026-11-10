// Receipt flow (D11, step 4): photos -> upload -> Claude reads them -> run list to review -> Save -> check dates.
// Every rule (sum check, duplicates, matching, units, lots) is in SQL; this screen only shows and collects choices.
import { useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "./supabase";
import { chainName, CHAINS, dayLabel, euro, friendly, householdId, invokeError } from "./shared";
import { allIngredients, catName, prodName, useNames } from "./names";

type RLine = {
  line_no: number; kind: string; raw_text: string | null; name_guess: string; name_en: string | null; category_id: string | null; is_food: boolean;
  printed_qty: number; printed_unit: string; line_total_cents: number; product_id: string | null; product_name: string | null;
  match: "matched" | "suggested" | "new" | "spend" | "none"; suggestion: { product_id: string; name: string } | null;
  ingredient_id: string | null; ingredient_name: string | null;
};
type Review = {
  purchase_id: string; status: string; chain_id: string; store_label: string | null; local_date: string; time_source: string;
  total_cents: number | null; lines_sum_cents: number; missing_cents: number; ticket_number: string | null;
  duplicate: { verdict: string; other_purchase_id: string | null; evidence: string | null; notice: string | null };
  lines: RLine[];
};
type Edit = { action: "match" | "new" | "spend"; product_id?: string; name?: string; name_en?: string; category_id?: string | null; ingredient_id?: string | null; unit?: string; pack_size?: number | null };
type Cat = { id: string; name_es: string; is_food: boolean };
type Ing = { id: string; name_es: string };
type DateRow = { lot_id: string; name: string; expires_on: string; expiry_kind: string };
type Ask = { kind: "sum"; missing: number } | { kind: "dup"; other: string; evidence: string } | { kind: "logged"; other: string | null };

const MAX_EDGE = 1568;   // Claude reads images up to this size without downscaling

// Shrink a photo to ≤1568 px (JPEG 0.8) before upload: faster, cheaper, and the model sees the same detail.
async function shrink(file: File): Promise<Blob> {
  if (file.type === "application/pdf") return file;
  try {
    const bmp = await createImageBitmap(file, { imageOrientation: "from-image" });
    const k = Math.min(1, MAX_EDGE / Math.max(bmp.width, bmp.height));
    const c = document.createElement("canvas");
    c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
    c.getContext("2d")!.drawImage(bmp, 0, 0, c.width, c.height);
    return await new Promise<Blob>((ok, bad) => c.toBlob((b) => (b ? ok(b) : bad(new Error("encode"))), "image/jpeg", 0.8));
  } catch { return file; }
}

function defaultEdit(l: RLine, ids: Map<number, string>): Edit | null {
  if (l.kind !== "item" || l.match === "matched") return null;
  if (l.match === "suggested" && l.suggestion) return { action: "match", product_id: l.suggestion.product_id };
  if (l.match === "spend" || !l.is_food) return { action: "spend", category_id: l.category_id };
  if (!ids.has(l.line_no)) ids.set(l.line_no, crypto.randomUUID());
  return { action: "new", product_id: ids.get(l.line_no), name: l.name_guess, name_en: l.name_en ?? l.name_guess, category_id: l.category_id,
           ingredient_id: l.ingredient_id, unit: l.printed_unit === "pack" ? "unit" : l.printed_unit };
}

export function ReceiptFlow({ files, resumeId, onClose, onSaved }: {
  files?: File[]; resumeId?: string; onClose: () => void; onSaved: (purchaseId: string) => void;
}) {
  const [phase, setPhase] = useState<"upload" | "review" | "dates">(resumeId ? "review" : "upload");
  const [status, setStatus] = useState("Uploading photos…");
  const [err, setErr] = useState("");
  const [review, setReview] = useState<Review | null>(null);
  const [edits, setEdits] = useState<Record<number, Edit | null>>({});
  const [header, setHeader] = useState<{ chain_id?: string; total?: string }>({});
  const [showMatched, setShowMatched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [ask, setAsk] = useState<Ask | null>(null);
  const [dates, setDates] = useState<DateRow[]>([]);
  const [cats, setCats] = useState<Cat[]>([]);
  const [ings, setIngs] = useState<Ing[]>([]);
  const job = useRef<{ pid: string; paths: string[] } | null>(null);
  const newIds = useRef(new Map<number, string>());
  const started = useRef(false);
  const savedId = useRef<string | null>(null);
  useNames();

  useEffect(() => {
    void supabase.from("categories").select("id,name_es,is_food").order("name_es").then(({ data }) => setCats((data as Cat[]) ?? []));
    void supabase.from("ingredients").select("id,name_es").order("name_es").then(({ data }) => setIngs((data as Ing[]) ?? []));
  }, []);

  function show(r: Review) {
    setReview(r);
    const e: Record<number, Edit | null> = {};
    for (const l of r.lines) e[l.line_no] = defaultEdit(l, newIds.current);
    setEdits(e); setHeader({}); setPhase("review");
  }

  async function parse() {
    const j = job.current!;
    setErr(""); setStatus("Reading your receipt… this takes 10–30 seconds");
    const t0 = Date.now();
    const tick = setInterval(() => setStatus(`Reading your receipt… ${Math.round((Date.now() - t0) / 1000)} s`), 1000);
    const { data, error } = await supabase.functions.invoke("parse-receipt", { body: { purchase_id: j.pid, paths: j.paths } });
    clearInterval(tick);
    if (error) return setErr(friendly(await invokeError(error)));
    show((data as { review: Review }).review);
  }

  // Start: upload the photos under {household}/{purchase}/n.jpg, then parse. Or resume a saved draft.
  useEffect(() => {
    if (started.current) return; started.current = true;
    void (async () => {
      try {
        if (resumeId) {
          const { data, error } = await supabase.rpc("receipt_review", { p_purchase: resumeId });
          if (error) throw new Error(error.message);
          show(data as Review); return;
        }
        const hh = await householdId();
        const pid = crypto.randomUUID();
        const paths: string[] = [];
        for (const [i, f] of (files ?? []).slice(0, 4).entries()) {
          setStatus(`Uploading photo ${i + 1} of ${Math.min(files!.length, 4)}…`);
          const blob = await shrink(f);
          const ext = blob.type === "application/pdf" ? "pdf" : "jpg";
          const path = `${hh}/${pid}/${i + 1}.${ext}`;
          const { error } = await supabase.storage.from("receipts").upload(path, blob, { contentType: blob.type || "image/jpeg", upsert: true });
          if (error) throw new Error(error.message);
          paths.push(path);
        }
        job.current = { pid, paths };
        await parse();
      } catch (e) { setErr(friendly(e instanceof Error ? e.message : String(e))); }
    })();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const lines = review?.lines ?? [];
  const matched = lines.filter((l) => l.kind === "item" && l.match === "matched");
  const open = lines.filter((l) => !(l.kind === "item" && l.match === "matched"));
  const total = header.total !== undefined ? Math.round(Number(header.total.replace(",", ".")) * 100) : review?.total_cents ?? null;
  const missing = (total ?? 0) - (review?.lines_sum_cents ?? 0);
  const foodCats = useMemo(() => cats.filter((c) => c.is_food), [cats]);
  const setEdit = (n: number, e: Edit | null) => setEdits((x) => ({ ...x, [n]: e }));

  async function save(opts: { accept?: boolean; force?: boolean; merge?: string } = {}) {
    if (!review) return;
    const bad = Object.values(edits).find((e) => e?.action === "new" && !e.category_id);
    if (bad) return setErr("Choose a type for every new item (or mark it spend only).");
    setBusy(true); setErr(""); setAsk(null);
    const p_lines = Object.entries(edits).filter(([, e]) => e).map(([n, e]) => ({ line_no: Number(n), ...e }));
    const p_header: Record<string, unknown> = {};
    if (header.chain_id && header.chain_id !== review.chain_id) p_header.chain_id = header.chain_id;
    if (header.total !== undefined && total !== review.total_cents && Number.isFinite(total)) p_header.total_cents = total;
    const { data, error } = await supabase.rpc("finish_receipt", {
      p_purchase: review.purchase_id, p_lines, p_header,
      p_accept_difference: !!opts.accept, p_force_new: !!opts.force, p_merge_into: opts.merge ?? null,
    });
    setBusy(false);
    if (error) {
      const m = error.message;
      if (m.includes("SUM_MISMATCH")) return setAsk({ kind: "sum", missing });
      if (m.includes("POSSIBLE_DUPLICATE")) return setAsk({ kind: "dup", other: error.hint ?? "", evidence: error.details ?? "" });
      if (m.includes("ALREADY_LOGGED")) return setAsk({ kind: "logged", other: error.hint ?? null });
      if (m.includes("UNIT_MISMATCH") || m.includes("NEEDS_PACK_SIZE")) setShowMatched(true);
      return setErr(friendly(m));
    }
    const res = data as { purchase_id: string; check_dates?: DateRow[]; notice?: string };
    savedId.current = res.purchase_id;
    if (res.check_dates?.length) { setDates(res.check_dates); setPhase("dates"); }
    else onSaved(res.purchase_id);
  }

  async function discard() {
    const id = review?.purchase_id ?? job.current?.pid;
    setBusy(true);
    if (review) {
      const { data } = await supabase.rpc("void_receipt_draft", { p_purchase: review.purchase_id });
      const paths = ((data as { paths?: string[] })?.paths ?? []);
      if (paths.length) await supabase.storage.from("receipts").remove(paths);
    } else if (job.current) {
      await supabase.storage.from("receipts").remove(job.current.paths);
    }
    setBusy(false);
    void id; onClose();
  }

  // ── Upload / reading ───────────────────────────────────────────────────────
  if (phase === "upload") return (
    <div className="flow">
      <header className="flow-h"><button className="link" onClick={() => void discard()}>Cancel</button></header>
      <div className="pad stack center-y">
        {!err && <><div className="spinner" aria-hidden="true" /><p className="serif big-status" role="status">{status}</p></>}
        {err && <>
          <p className="err" role="alert">{err}</p>
          {job.current && <button className="primary" onClick={() => void parse()}>Try again</button>}
          <button className="ghost" onClick={() => void discard()}>Cancel</button>
        </>}
      </div>
    </div>
  );

  // ── Check dates (only short-life items, once per product) ─────────────────
  if (phase === "dates") return (
    <DatesSheet rows={dates} onDone={() => onSaved(savedId.current!)} />
  );

  // ── Review: the run list ──────────────────────────────────────────────────
  const r = review;
  return (
    <div className="flow">
      <header className="flow-h">
        <button className="link" onClick={onClose}>Later</button>
        <button className="link danger-t" disabled={busy} onClick={() => void discard()}>Discard</button>
      </header>
      {!r ? <p className="muted pad">{err || "Loading…"}</p> : (
        <div className="pad stack flow-body">
          <div className="run-h">
            <select aria-label="Shop" value={header.chain_id ?? r.chain_id} onChange={(e) => setHeader((h) => ({ ...h, chain_id: e.target.value }))}>
              {CHAINS.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
            <span className="muted">· {dayLabel(r.local_date)}{r.time_source === "entered" ? " (date not readable)" : ""} ·</span>
            <label className="total-in">€<input inputMode="decimal" aria-label="Ticket total"
              value={header.total ?? ((r.total_cents ?? 0) / 100).toFixed(2)} onChange={(e) => setHeader((h) => ({ ...h, total: e.target.value }))} /></label>
          </div>

          {r.duplicate.verdict === "same_ticket" || r.duplicate.verdict === "same_receipt"
            ? <p className="banner alert-b" role="alert">This receipt looks already logged. Saving will be refused; you can discard it.</p>
            : r.duplicate.verdict === "possible_duplicate" || r.duplicate.verdict === "mergeable"
              ? <p className="banner warn-b">A trip at {chainName(r.chain_id)} with a similar total is already logged {r.duplicate.evidence ? `(${r.duplicate.evidence})` : ""}. You'll be asked when you save.</p>
              : null}
          {missing !== 0 && <p className="banner warn-b">Lines add up to {euro(r.lines_sum_cents)}, ticket says {euro(total)}: {euro(Math.abs(missing))} {missing > 0 ? "missing" : "too much"}.</p>}

          {matched.length > 0 && (
            <button className="card matched-row" onClick={() => setShowMatched((v) => !v)} aria-expanded={showMatched}>
              <strong>{matched.length} item{matched.length === 1 ? "" : "s"} matched ✓</strong>
              <span className="muted">{showMatched ? "Hide" : "Show"}</span>
            </button>
          )}
          {showMatched && matched.map((l) => { const sp = edits[l.line_no]?.action === "spend"; return (
            <div key={l.line_no} className="line card">
              <div className="grow"><strong>{prodName(l.product_id, l.product_name ?? "").en}</strong><div className="muted">{l.raw_text}{sp ? " · spend only" : ""}</div></div>
              <span className="amt">{euro(l.line_total_cents)}</span>
              <button className="chip" onClick={() => setEdit(l.line_no, sp ? null : { action: "spend", category_id: l.category_id })}>{sp ? "Undo" : "Spend only"}</button>
            </div>); })}

          {open.map((l) => (
            <LineCard key={l.line_no} l={l} e={edits[l.line_no] ?? null} cats={cats} foodCats={foodCats} ings={ings}
              newId={() => { if (!newIds.current.has(l.line_no)) newIds.current.set(l.line_no, crypto.randomUUID()); return newIds.current.get(l.line_no)!; }}
              onChange={(e) => setEdit(l.line_no, e)} />
          ))}

          {err && <p className="err" role="alert">{err}</p>}
          {ask?.kind === "sum" && (
            <div className="banner warn-b stack-sm" role="alert">
              <span>{euro(Math.abs(ask.missing))} {ask.missing >= 0 ? "missing" : "too much"}. Add it as unclassified so the month total stays right?</span>
              <button className="primary" disabled={busy} onClick={() => void save({ accept: true })}>Add as unclassified and save</button>
            </div>
          )}
          {ask?.kind === "dup" && (
            <div className="banner warn-b stack-sm" role="alert">
              <span>This looks like a trip that's already logged{ask.evidence ? ` (${ask.evidence})` : ""}. Same trip?</span>
              <button className="primary" disabled={busy} onClick={() => void save({ merge: ask.other })}>Same trip: combine them</button>
              <button className="ghost" disabled={busy} onClick={() => void save({ force: true })}>It's a different trip</button>
            </div>
          )}
          {ask?.kind === "logged" && (
            <div className="banner alert-b stack-sm" role="alert">
              <span>Already logged. Nothing was added twice.</span>
              {ask.other && <button className="primary" onClick={() => onSaved(ask.other!)}>Open that trip</button>}
              <button className="ghost danger" disabled={busy} onClick={() => void discard()}>Discard this photo</button>
            </div>
          )}
        </div>
      )}
      {r && <div className="flow-foot"><button className="primary" disabled={busy} onClick={() => void save()}>{busy ? "Saving…" : `Save ${euro(total)}`}</button></div>}
    </div>
  );
}

function LineCard({ l, e, cats, foodCats, ings, newId, onChange }: {
  l: RLine; e: Edit | null; cats: Cat[]; foodCats: Cat[]; ings: Ing[]; newId: () => string; onChange: (e: Edit | null) => void;
}) {
  const qty = l.printed_unit === "g" ? `${Number(l.printed_qty)} g` : l.printed_qty !== 1 ? `${Number(l.printed_qty)} ×` : "";
  if (l.kind !== "item") return (
    <div className="line card"><div className="grow"><strong>{l.kind === "discount" ? "Discount" : l.kind === "refund" ? "Refund" : "Adjustment"}</strong><div className="muted">{l.raw_text}</div></div><span className="amt">{euro(l.line_total_cents)}</span></div>
  );
  const asNew = (): Edit => ({ action: "new", product_id: newId(), name: l.name_guess, name_en: l.name_en ?? l.name_guess, category_id: l.category_id && cats.find((c) => c.id === l.category_id)?.is_food ? l.category_id : null,
                               ingredient_id: l.ingredient_id, unit: l.printed_unit === "pack" ? "unit" : l.printed_unit });
  return (
    <div className="line card stack-sm">
      <div className="between"><div className="grow"><span className="muted small">{l.raw_text} {qty}</span></div><span className="amt">{euro(l.line_total_cents)}</span></div>

      {e?.action === "match" && (
        <div className="stack-sm">
          <p>Is it <strong>{l.suggestion?.name ?? "the same product"}</strong>?</p>
          <div className="row"><button className="chip on" aria-pressed="true">Yes</button><button className="chip" onClick={() => onChange(asNew())}>No, new item</button></div>
        </div>
      )}

      {e?.action === "new" && (
        <div className="stack-sm">
          <label className="field">Name<input value={e.name_en ?? ""} onChange={(x) => onChange({ ...e, name_en: x.target.value })} /></label>
          {e.name && <p className="es">On the receipt: {e.name}</p>}
          <div className="row">
            <label className="field">Type<select value={e.category_id ?? ""} onChange={(x) => onChange({ ...e, category_id: x.target.value })}>
              <option value="">Choose…</option>{[...foodCats].sort((a, b) => catName(a.id).en.localeCompare(catName(b.id).en)).map((c) => <option key={c.id} value={c.id}>{catName(c.id).en}</option>)}
            </select></label>
            <label className="field">Counted as<select value={e.unit ?? "unit"} onChange={(x) => onChange({ ...e, unit: x.target.value })}>
              <option value="unit">items</option><option value="g">grams</option><option value="ml">ml</option>
            </select></label>
          </div>
          {e.unit !== "unit" && l.printed_unit === "pack" && (
            <label className="field">How much is one pack ({e.unit === "g" ? "grams" : "ml"})?
              <input type="number" inputMode="decimal" min="1" placeholder={e.unit === "g" ? "500" : "1000"} value={e.pack_size ?? ""}
                     onChange={(x) => onChange({ ...e, pack_size: x.target.value ? Number(x.target.value) : null })} /></label>
          )}
          <label className="field">Ingredient <span className="muted small">(links recipes and the shopping list)</span>
            <select value={e.ingredient_id ?? ""} onChange={(x) => onChange({ ...e, ingredient_id: x.target.value || null })} className={e.ingredient_id ? "" : "amber"}>
              <option value="">Set ingredient…</option>{(allIngredients().length ? allIngredients().map(([id, n]) => ({ id, en: n.en })) : ings.map((i) => ({ id: i.id, en: i.name_es })))
                .sort((a, b) => a.en.localeCompare(b.en)).map((i) => <option key={i.id} value={i.id}>{i.en}</option>)}
            </select></label>
        </div>
      )}

      {e?.action === "spend" && <p className="muted">Spend only: counts for the budget, not added to the pantry.</p>}

      <div className="chips">
        {e?.action !== "spend"
          ? <button className="chip" onClick={() => onChange({ action: "spend", category_id: l.category_id })}>Spend only</button>
          : l.is_food && <button className="chip" onClick={() => onChange(l.suggestion ? { action: "match", product_id: l.suggestion.product_id } : asNew())}>Add to pantry</button>}
      </div>
    </div>
  );
}

function DatesSheet({ rows, onDone }: { rows: DateRow[]; onDone: () => void }) {
  const [vals, setVals] = useState(() => Object.fromEntries(rows.map((r) => [r.lot_id, { date: r.expires_on, kind: r.expiry_kind === "use_by" ? "use_by" : "best_before" }])));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  async function save() {
    setBusy(true); setErr("");
    for (const r of rows) {
      const v = vals[r.lot_id];
      const { error } = await supabase.rpc("set_lot_expiry", { p_lot: r.lot_id, p_expires_on: v.date !== r.expires_on ? v.date : null, p_kind: v.kind });
      if (error) { setBusy(false); return setErr(friendly(error.message)); }
    }
    setBusy(false); onDone();
  }
  return (
    <div className="flow">
      <header className="flow-h"><span /><button className="link" onClick={onDone}>Skip</button></header>
      <div className="pad stack flow-body">
        <h1 className="serif">Check dates</h1>
        <p className="muted">Only for fresh things. Look at the label: the date, and whether it says <strong>Caducidad</strong> (use by) or <strong>Consumir preferentemente</strong> (best before).</p>
        {rows.map((r) => { const v = vals[r.lot_id]; const set = (p: Partial<typeof v>) => setVals((x) => ({ ...x, [r.lot_id]: { ...v, ...p } })); return (
          <div key={r.lot_id} className="card line stack-sm">
            <strong>{r.name}</strong>
            <input type="date" aria-label={`Date for ${r.name}`} value={v.date} onChange={(e) => set({ date: e.target.value })} />
            <div className="chips">
              <button className={`chip${v.kind === "use_by" ? " on" : ""}`} aria-pressed={v.kind === "use_by"} onClick={() => set({ kind: "use_by" })}>Caducidad</button>
              <button className={`chip${v.kind === "best_before" ? " on" : ""}`} aria-pressed={v.kind === "best_before"} onClick={() => set({ kind: "best_before" })}>Consumir pref.</button>
            </div>
          </div>); })}
        {err && <p className="err" role="alert">{err}</p>}
      </div>
      <div className="flow-foot"><button className="primary" disabled={busy} onClick={() => void save()}>{busy ? "Saving…" : "Save dates"}</button></div>
    </div>
  );
}
