# SUPERMARKET_ASSISTANT

AI supermarket app that helps you organize expenses and items bought: a personal grocery and pantry tracker, built to grow into a product.

- Log supermarket trips (Mercadona, Carrefour, Supercor) by receipt photo, barcode or manual entry
- Pantry with expiry dates and alerts before things go off
- Recipe suggestions that use what expires first
- Shopping list that updates itself
- Grocery budget and spending
- Claude reads and updates everything through a custom connector (MCP)

## Status

Planning done. Build not started. See [docs/PLAN.md](docs/PLAN.md) for the step list and current step.

## Stack

| Part | Choice |
|---|---|
| App | Web app (React + Vite + TypeScript), installed on iPhone via Add to Home Screen |
| Backend | Supabase (EU): Postgres + RLS, Auth, Storage, Edge Functions |
| Claude access | Remote MCP server as a Supabase Edge Function, Supabase OAuth 2.1 |
| Hosting | Cloudflare Pages (auto-deploys from `main`) |
| Scheduler | Cloudflare Worker cron (daily digest, cleanup) |
| Receipt reading | Claude API (small model, stronger model only on sum-check failure), $5/month cap |

Why these choices: [docs/DECISIONS.md](docs/DECISIONS.md).

## Repository layout

```
apps/web/            Web app (PWA)
apps/scheduler/      Cloudflare Worker cron
packages/shared/     Shared types, zod schemas, money/date utils
supabase/migrations/ Schema, RLS, SQL functions, seed data
supabase/functions/  parse-receipt, mcp, daily-digest, retention
supabase/tests/      RLS + function tests
docs/                Plan, decisions, workflow, reference
```

## Docs

- [docs/PLAN.md](docs/PLAN.md): build steps with "done when" tests
- [docs/DECISIONS.md](docs/DECISIONS.md): decision log
- [docs/WORKFLOW.md](docs/WORKFLOW.md): how to build efficiently with Claude Code, and how deployment works
- [docs/reference/arena-winning-plan.md](docs/reference/arena-winning-plan.md): the full original design (native app version). Detailed reference for the data model and rules; read one section at a time, never the whole file.
