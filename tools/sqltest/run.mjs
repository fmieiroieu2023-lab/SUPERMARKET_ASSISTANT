// Run every migration, then every test file, in PGlite (Postgres compiled to WebAssembly, in-process).
// Usage: pnpm --filter sqltest test [filter]   e.g. "04" to run only 04_*.test.sql
// Why: `supabase test db` needs Docker; this needs only Node. It is a stand-in, so dev is still the final check.
import { PGlite } from "@electric-sql/pglite";
import { pg_trgm } from "@electric-sql/pglite/contrib/pg_trgm";
import { fuzzystrmatch } from "@electric-sql/pglite/contrib/fuzzystrmatch";
import { unaccent } from "@electric-sql/pglite/contrib/unaccent";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import { uuid_ossp } from "@electric-sql/pglite/contrib/uuid_ossp";
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..", "supabase");
const filter = process.argv[2] ?? "";

const db = new PGlite({ extensions: { pg_trgm, fuzzystrmatch, unaccent, pgcrypto, uuid_ossp } });
await db.exec(readFileSync(join(here, "stubs.sql"), "utf8"));

for (const f of readdirSync(join(root, "migrations")).filter((f) => f.endsWith(".sql")).sort()) {
  try { await db.exec(readFileSync(join(root, "migrations", f), "utf8")); }
  catch (e) { console.error(`MIGRATION FAILED ${f}: ${e.message}`); process.exit(1); }
}
console.log("migrations ok");

let pass = 0, fail = 0;
for (const f of readdirSync(join(root, "tests", "database")).filter((f) => f.endsWith(".test.sql") && f.includes(filter)).sort()) {
  const sql = readFileSync(join(root, "tests", "database", f), "utf8")
    .replace(/create extension if not exists pgtap[^;]*;/gi, "set local search_path = public, tap, extensions;");
  try {
    const results = await db.exec(sql);
    for (const r of results) for (const row of r.rows ?? []) {
      const v = Object.values(row)[0];
      if (typeof v !== "string") continue;
      if (v.startsWith("ok - ")) pass++;
      else if (v.startsWith("not ok - ")) { fail++; console.log(`  ${f}: ${v}`); }
    }
    console.log(`${f}: done`);
  } catch (e) {
    fail++; console.log(`${f}: ERROR ${e.message}`);
    try { await db.exec("rollback"); } catch {}
  }
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
