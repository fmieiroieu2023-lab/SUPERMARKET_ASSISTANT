// Receipt eval (PLAN step 4 "done when": >= 9/10 receipts pass the sum check, line totals >= 95% right).
// Put photos in receipts/ (e.g. mercadona-1.jpg, or mercadona-1-a.jpg + mercadona-1-b.jpg for a long ticket)
// and next to each a ground-truth file mercadona-1.json: { "total_cents": 4730, "lines": [190, 389, -50, ...] }
// (just the line amounts in cents, top to bottom; discounts negative).
// Run on your Mac:  EVAL_EMAIL=you@x EVAL_PASSWORD=... pnpm --filter receipt-eval eval
// Each receipt uses one of the 20 daily parses. Drafts are discarded afterwards, so nothing is logged.
import { createClient } from "@supabase/supabase-js";
import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const URL = process.env.SUPABASE_URL ?? "https://fijlwdcbindkymqgyfck.supabase.co";
const KEY = process.env.SUPABASE_KEY ?? "sb_publishable_MQAaBG14xPHsOEmGTGzYxQ_3rWFTkKO";
const dir = join(dirname(fileURLToPath(import.meta.url)), "receipts");
const db = createClient(URL, KEY, { auth: { persistSession: false } });

const { error: authErr } = await db.auth.signInWithPassword({ email: process.env.EVAL_EMAIL ?? "", password: process.env.EVAL_PASSWORD ?? "" });
if (authErr) { console.error("Sign-in failed:", authErr.message); process.exit(1); }
const { data: hm } = await db.from("household_members").select("household_id").limit(1).single();
const hh = hm.household_id;

// group files: "name.jpg" or "name-a.jpg", "name-b.jpg" -> receipt "name"
const groups = new Map();
for (const f of readdirSync(dir).filter((f) => /\.(jpe?g|png|pdf)$/i.test(f)).sort()) {
  const name = f.replace(/\.(jpe?g|png|pdf)$/i, "").replace(/-[a-d]$/, "");
  groups.set(name, [...(groups.get(name) ?? []), f]);
}

let sumOk = 0, n = 0, lineHit = 0, lineTotal = 0;
for (const [name, files] of groups) {
  const truthPath = join(dir, `${name}.json`);
  const truth = existsSync(truthPath) ? JSON.parse(readFileSync(truthPath, "utf8")) : null;
  const pid = crypto.randomUUID();
  const paths = [];
  for (const [i, f] of files.entries()) {
    const ext = f.split(".").pop().toLowerCase();
    const path = `${hh}/${pid}/${i + 1}.${ext === "pdf" ? "pdf" : "jpg"}`;
    const type = ext === "pdf" ? "application/pdf" : ext === "png" ? "image/png" : "image/jpeg";
    const { error } = await db.storage.from("receipts").upload(path, readFileSync(join(dir, f)), { contentType: type });
    if (error) { console.log(`${name}: upload failed: ${error.message}`); continue; }
    paths.push(path);
  }
  const t0 = Date.now();
  const { data, error } = await db.functions.invoke("parse-receipt", { body: { purchase_id: pid, paths } });
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  n++;
  if (error) {
    let msg = error.message; try { msg = JSON.stringify(await error.context.json()); } catch {}
    console.log(`${name}: ERROR ${msg}`);
  } else {
    const r = data.review;
    const ok = r.missing_cents === 0;
    if (ok) sumOk++;
    let detail = "";
    if (truth) {
      const got = r.lines.map((l) => l.line_total_cents);
      const left = [...got]; let hit = 0;
      for (const v of truth.lines) { const i = left.indexOf(v); if (i >= 0) { hit++; left.splice(i, 1); } }
      lineHit += hit; lineTotal += truth.lines.length;
      detail = ` | total ${r.total_cents === truth.total_cents ? "right" : `WRONG (${r.total_cents} vs ${truth.total_cents})`} | lines ${hit}/${truth.lines.length}`;
    }
    const matched = r.lines.filter((l) => l.match === "matched").length;
    console.log(`${name}: ${ok ? "sum ok" : `sum off by ${r.missing_cents}`} | ${r.model} | ${secs}s | ${r.lines.length} lines, ${matched} auto-matched${detail}`);
  }
  // clean up: discard the draft and its photos
  const v = await db.rpc("void_receipt_draft", { p_purchase: pid });
  if (!v.error && v.data?.paths?.length) await db.storage.from("receipts").remove(v.data.paths);
  else await db.storage.from("receipts").remove(paths);
}
console.log(`\nSum check: ${sumOk}/${n} (target >= 9/10)`);
if (lineTotal) console.log(`Line totals: ${lineHit}/${lineTotal} = ${((100 * lineHit) / lineTotal).toFixed(1)}% (target >= 95%)`);
