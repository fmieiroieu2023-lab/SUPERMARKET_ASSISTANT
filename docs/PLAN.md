# Build plan (web app version)

About 12 weeks at 8–10 h/week. Daily use starts after step 3.
Reference sections are in `docs/reference/arena-winning-plan.md` (grep the heading, don't read the whole file).

**Current step: 0**

| # | Step | Weeks | Work | Done when | Reference | Status |
|---|---|---|---|---|---|---|
| 0 | Setup | 0.5 | Accounts: Supabase (projects `dev` + `prod`, EU), Cloudflare, Resend, Anthropic Console (spend cap $5/month). Mac: Node LTS, pnpm, Supabase CLI, Wrangler, Claude Code. Monorepo scaffold. | `supabase link` works for `dev`; a "hello" page is live on `*.pages.dev` and opens on the iPhone | §4 | ☐ |
| 1 | Database | 1 | Schema, RLS, `is_member`, signup trigger, seed (chains, categories, ~200 ingredients, aliases, ~60 recipes). Functions: `to_base_qty`, `classify_duplicate`, `confirm_purchase`, `consume`, `log_mcp_call`. SQL tests as two fake users. | User B sees 0 rows of A's data; `confirm_purchase` rejects a €0.01 mismatch; consuming more than is left leaves 0; unit-conversion tests pass | §5, §9 step 1 | ☐ |
| 2 | Claude connector spike | 1 | Supabase OAuth 2.1 server; consent page on Cloudflare Pages; `mcp` Edge Function with `get_overview` + `list_pantry`; add as custom connector in Claude | From the Claude iPhone app, "what's in my pantry?" returns seed data, still works next day; no-token request gets `401` + resource metadata. Fallback if stuck >1 day: Cloudflare `workers-oauth-provider` | §7.1, §9 step 2 | ☐ |
| 3 | App skeleton | 1 | Email OTP login, tabs (Pantry, Add, List, Budget, Recipes), pantry with days-left chips, quick add, consume/discard, PWA manifest + service worker (app shell only), auto-deploy from `main` | Installed on iPhone home screen, opens full-screen; add 3 items + consume 1 → 3 lots and 4 movements in DB. **Daily use starts.** | §9 step 3 (minus offline queue) | ☐ |
| 4 | Receipt photos | 2 | Upload, `parse-receipt` (small → large model fallback, quota), sum check, review screen with ingredient chips, alias learning, check-dates sheet, duplicate guard, `retention` | ≥9/10 real receipts pass the sum check; re-logging same products ≥80% auto-matched; same ticket twice → "already logged" | §6.1, §9 step 5 | ☐ |
| 5 | Barcode | 0.5 | JS camera scanner, check digit, prefix 20–29 → manual, Open Food Facts lookup (≤12/min) + cache, unpacking session with "Finish trip" | 20 kitchen products: known = 1 tap, OFF hits fill in, misses saved; weighed-fruit label goes to "pick product" | §6.2, §6.3 | ☐ |
| 6 | Alerts | 1.5 | Lot states, "Still have it?", `buildDigest` (unit-tested), Web Push (VAPID), email digest via Resend, Cloudflare Worker cron (hourly digest, nightly retention, watchdog email) | Lot dated tomorrow → push at set time with app closed; lot inserted directly in DB (as Claude would) appears in next digest; Worker logs 24 calls/day | §6.4, §9 step 6 | ☐ |
| 7 | Budget | 1 | `budget_status`, `spending`; budget screen, 80/100% alerts, projection, breakdowns | Month total = hand-written SQL `sum()`; 23:30 on the 31st lands in that month; §6.7 worked checks pass | §6.7, §9 step 8 | ☐ |
| 8 | Shopping list | 1 | Staples/par per ingredient, `refresh_shopping_list` wired into every stock write + morning run, in-transit, snooze | Refresh twice = same list; finishing the last milk adds milk in the same transaction; §6.6 checks pass | §6.6, §9 step 9 | ☐ |
| 9 | Recipes | 1 | `suggest_recipes` (lexicographic: expiring first), list + detail, "add missing", "plan" | Chicken expiring today → chicken recipe first; expired use-by never suggested; §6.5 checks pass | §6.5, §9 step 10 | ☐ |
| 10 | Full Claude access | 1 | All MCP tools, `request_id` idempotency, `undo`, audit, kill switch in app | Claude logs a Mercadona e-ticket with 3 new products → appears in app; `undo` reverts; kill switch blocks writes but not reads | §7.2, §7.3, §9 step 11 | ☐ |
| 11 | Hardening | 0.5 | Account deletion, JSON/CSV export, weekly `pg_dump` GitHub Action, OFF attribution, privacy page | Deleting a test account removes all rows + images; restoring last dump into `dev` works | §9 step 12 | ☐ |

## Then: 4 weeks of real use
Track: weeks with a logged trip (target 4/4), share logged by receipt, auto-match rate (≥80%), waste €/month, budget vs bank statement (within €1).

## Later (not now)
Household sharing (invite screen), native iPhone app on the same backend, Android, payments (Stripe for web), shared product catalog from the OFF data export, connector directory listing.
