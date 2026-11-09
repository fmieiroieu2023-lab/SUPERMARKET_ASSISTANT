# CLAUDE.md

Grocery/pantry web app + Claude MCP connector. Owner: Francisco (not a professional developer; explain decisions briefly).

## Rules
- Work on ONE step of docs/PLAN.md per session. Stop when its "done when" test passes, then update the step's status in PLAN.md and commit.
- Do not read docs/reference/arena-winning-plan.md in full. It is ~22k words. Grep for the section you need (e.g. `## 5. Data model`, `### 6.6`).
- Business rules live in Postgres functions (`security invoker`). The app and the MCP server call the same functions. Never duplicate a rule in TypeScript.
- Every table has `household_id` + RLS. No service-role key outside cron-only functions.
- Money = integer cents. Expiry = `date`. Events = `timestamptz`. Time zone `Europe/Madrid`.
- Every write carries a client-generated UUID; repeats are no-ops.
- Online-only app: cache the app shell, no offline write queue.
- Keep changes small. Prefer editing existing files over adding new ones. No new dependencies without saying why.

## Commands
- Web: `pnpm --filter web dev` / `build`
- DB: `supabase db reset` (local), `supabase db push` (remote), `supabase test db`
- SQL tests without Docker: `pnpm --filter sqltest test` (PGlite; all migrations + tests)
- Functions: `supabase functions deploy <name>`
- Scheduler: `pnpm --filter scheduler deploy`
