# Build plan (web app version)

About 12 weeks at 8–10 h/week. Daily use starts after step 3.
Reference sections are in `docs/reference/arena-winning-plan.md` (grep the heading, don't read the whole file).

**Current step: 4**

| # | Step | Weeks | Work | Done when | Reference | Status |
|---|---|---|---|---|---|---|
| 0 | Setup | 0.5 | Accounts: Supabase (projects `dev` + `prod`, EU), Cloudflare, Resend, Anthropic Console (spend cap $5/month). Mac: Node LTS, pnpm, Supabase CLI, Wrangler, Claude Code. Monorepo scaffold. | `supabase link` works for `dev`; a "hello" page is live on `*.pages.dev` and opens on the iPhone | §4 | ☑ |
| 1 | Database | 1 | Schema, RLS, `is_member`, signup trigger, seed (chains, categories, ~200 ingredients, aliases, ~60 recipes). Functions: `to_base_qty`, `classify_duplicate`, `confirm_purchase`, `consume`, `log_mcp_call`. SQL tests as two fake users. | User B sees 0 rows of A's data; `confirm_purchase` rejects a €0.01 mismatch; consuming more than is left leaves 0; unit-conversion tests pass | §5, §9 step 1 | ☑ |
| 2 | Claude connector spike | 1 | Supabase OAuth 2.1 server; consent page on Cloudflare Pages; `mcp` Edge Function with `get_overview` + `list_pantry`; add as custom connector in Claude | From the Claude iPhone app, "what's in my pantry?" returns seed data, still works next day; no-token request gets `401` + resource metadata. Fallback if stuck >1 day: Cloudflare `workers-oauth-provider` | §7.1, §9 step 2 | ☑ |
| 3 | App skeleton | 1 | Email OTP login, tabs (Pantry, Add, List, Budget, Recipes), pantry with days-left chips, quick add, consume/discard, PWA manifest + service worker (app shell only), auto-deploy from `main` | Installed on iPhone home screen, opens full-screen; add 3 items + consume 1 → 3 lots and 4 movements in DB. **Daily use starts.** | §9 step 3 (minus offline queue) | ☑ |
| 4 | Receipt photos | 2 | Upload, `parse-receipt` (small → large model fallback, quota), sum check, pick photos from library (D17), review screen with ingredient chips, alias learning, check-dates sheet, duplicate guard, `retention`, **Spending tab with Trips list + trip page** (D15); after Save you land on the trip | ≥9/10 real receipts pass the sum check; re-logging same products ≥80% auto-matched; same ticket twice → "already logged" | §6.1, §9 step 5 | ☐ |
| 4b | Pantry flow | 1 | Full item page (bought where/when/price, link to trip, Used some / All gone / Threw away / Opened / Froze / Change date), Undo bar 6 s (D16), swipe on rows, search + Fridge/Freezer/Cupboard filters, "Ready meals & leftovers" pantry group, Home as "today" page (use first, last shop; recipe and budget cards fill in later), "Ask Claude" button | Every action can be undone within 6 s; search finds an item by any word of its name; a swipe and a tap give the same movement rows as the sheet did | D15–D17 | ☐ |
| 5 | Barcode | 0.5 | JS camera scanner, check digit, prefix 20–29 → manual, Open Food Facts lookup (≤12/min) + cache, unpacking session with "Finish trip" | 20 kitchen products: known = 1 tap, OFF hits fill in, misses saved; weighed-fruit label goes to "pick product" | §6.2, §6.3 | ☐ |
| 6 | Alerts | 1.5 | Lot states, weekly "Still have it?" cards (D17), app-icon count (Badging API), email-code login (moved from step 3), `buildDigest` (unit-tested), Web Push (VAPID), email digest via Resend, Cloudflare Worker cron (hourly digest, nightly retention, watchdog email) | Lot dated tomorrow → push at set time with app closed; lot inserted directly in DB (as Claude would) appears in next digest; Worker logs 24 calls/day | §6.4, §9 step 6 | ☐ |
| 7 | Budget | 1 | `budget_status`, `spending`; Budget view inside Spending (D15), "which store is cheaper" from own receipts (D17), 80/100% alerts, projection, breakdowns | Month total = hand-written SQL `sum()`; 23:30 on the 31st lands in that month; §6.7 worked checks pass | §6.7, §9 step 8 | ☐ |
| 8 | Shopping list | 1 | "What the list will cost" vs budget (D17); staples/par per ingredient, `refresh_shopping_list` wired into every stock write + morning run, in-transit, snooze | Refresh twice = same list; finishing the last milk adds milk in the same transaction; §6.6 checks pass | §6.6, §9 step 9 | ☐ |
| 9 | Recipes | 1 | `suggest_recipes` (lexicographic: expiring first), list + detail reached from Home and items (no tab, D15), "I cooked this" → leftovers lot in Ready meals & leftovers (D17), "add missing", "plan" | Chicken expiring today → chicken recipe first; expired use-by never suggested; §6.5 checks pass | §6.5, §9 step 10 | ☐ |
| 10 | Full Claude access | 1 | All MCP tools, `request_id` idempotency, `undo`, audit, kill switch in app | Claude logs a Mercadona e-ticket with 3 new products → appears in app; `undo` reverts; kill switch blocks writes but not reads | §7.2, §7.3, §9 step 11 | ☐ |
| 11 | Hardening | 0.5 | Account deletion, JSON/CSV export, weekly `pg_dump` GitHub Action, OFF attribution, privacy page | Deleting a test account removes all rows + images; restoring last dump into `dev` works | §9 step 12 | ☐ |

## Then: 4 weeks of real use
Track: weeks with a logged trip (target 4/4), share logged by receipt, auto-match rate (≥80%), waste €/month, budget vs bank statement (within €1).

## Later (not now)
**Top:** forward e-tickets by email (Mercadona emails tickets for a registered card; needs a domain on Cloudflare for email routing). Maybe: rescue buttons (Opened / Froze it) if not already covered by the item page. Household sharing (invite screen), native iPhone app on the same backend, Android, payments (Stripe for web), shared product catalog from the OFF data export, connector directory listing.

## Step 1 notes (done on `dev` only; `prod` has no schema yet)

- Tests: `supabase/tests/database/` (`supabase test db`). 61 checks passed against `dev`: isolation between two users, Claude kill switch, category and unit rules, `to_base_qty`, sum check and adjustment line, consume floor, the eight duplicate worked checks in both orders, merge cases, use_by product in a best-before category.
- Not covered by a repeatable test: the concurrency check (two confirms of the same receipt). Run by hand on `dev`: exactly one confirmed trip. The tool may have run the two calls one after the other, so treat it as a weak check and re-run it with two terminals before relying on it.
- Changes from the reference: `user_settings.push_subscription` (Web Push) replaces `expo_push_token`; `confirm_purchase` has an extra `p_keep_total_cents` argument (typed+typed merges); `refresh_shopping_list` is an empty stub until step 8; the ticket number is read from `parse_output->>'ticket_number'` and saved only at confirm; 63 recipes (reference said ~60).
- Bugs found by the tests and fixed in the migrations: tables had no `authenticated` privileges (RLS alone isn't enough, and TRUNCATE bypassed it); a draft can't hold a ticket number, so confirm now sets it with the status; a household couldn't be deleted in one go because of a foreign-key check order.
- Every new table from now on needs its own `grant` (default privileges are off). Put it in the same migration as the table.
- `dev` migration history has different names from the files here (seed split in two, two small patches). Before the first `supabase db push` to `prod`, the files here are the truth. For `dev`, run `supabase migration repair` or reset it.

## Step 2 notes (dev only)

- Works end to end: Claude (via the connector) called `get_overview` and `list_pantry` on dev and got the seed pantry; both calls were written to `mcp_audit` with the OAuth client id. Unauthenticated requests get 401 (checked in a browser).
- Confirmed 2026-11-09: works from the Claude iPhone app and still works the next day (get_overview returned fresh data after token refresh).
- Consent page signs in with email + password for now (Supabase can't edit email templates without custom SMTP, so the email-code login waits for step 3 + Resend). The dev user was created by hand in the dashboard.
- `get_overview` is a first version (pantry facts only). Money, staples and shopping list join it in steps 7-8.
- Known risk: some Spanish ISPs block Cloudflare addresses during football matches (`pages.dev` timed out). Fix with a VPN for now; decide on hosting in step 3.
- Demo pantry rows were inserted into the dev user's household by hand (8 lots). Delete them before real use.

## Design (agreed 2026-11-09)

See D8-D14 in DECISIONS.md. Screens to build in step 3: Home, Pantry, Add flow (camera → run list → Save), List, Budget. Use mockup board C as the visual reference.

## Step 3 notes

- Slice 1 (2026-11-09): app shell in the Classic look. Password sign-in, bottom bar (Home, Pantry, +, List, Budget), Home and Pantry read live data through `get_overview` and `list_pantry` (same functions as Claude). The + opens a placeholder; List and Budget are placeholders.
- Slice 2 (2026-11-09): quick add (`add_item` Postgres function + sheet on the +), tap an item to mark it used or thrown away (`consume`), PWA manifest + app-shell service worker. `supabase/tests/database/03_add_item.test.sql`: 13 checks pass on dev ("add 3 + consume 1 = 3 lots, 4 movements" included).
- Slice 3 (2026-11-09): review fixes. `app_snapshot()` replaces three calls with one; `add_item` repeat-safe (`on conflict do nothing`); `get_overview` reads the pantry once; `mcp` function no longer returns a bare 500 on a tool error; app refreshes when reopened, has a Retry button, plain-language errors, "today" / "items" wording, a past-date warning, lazy consent screen, and the service worker no longer caches error pages. Note: dev migration history has drifted from the files, so the first push to prod needs `supabase migration repair`.
- The receipt camera and run list (D11) are step 4, because they need the `parse-receipt` function. Until then the + is manual quick add.
- Closed 2026-11-09: new pages.dev address works for Francisco; demo data deleted from dev. Email-code login moves to step 6 (Resend is needed there anyway); password login stays until then. Hosting decision stays open until tested during a match.
- (old list, superseded) Still to do in step 3: email-code login (needs Resend), confirm it installs on the iPhone home screen, hosting decision (pages.dev is blocked on some Spanish ISPs during matches). Then mark step 3 ☑.

## Step 4 notes (night of 2026-11-10, built while Francisco slept)

- SQL (migration `20261110090000_receipts.sql`): `take_receipt_quota` (20/day), `save_receipt_draft` (parser output -> draft + lines, chain/time/units/categories validated, exact alias = auto match), `receipt_review` (trigram suggestions ≥ 0.6, ingredient guess or alias match ≥ 0.5, duplicate verdict), `finish_receipt` (applies review choices, creates products, calls `confirm_purchase`, returns the check-dates list), `void_receipt_draft`, `set_lot_expiry` (Caducidad / Consumir pref. saved on the product), `list_purchases`, `get_purchase`. Storage bucket capped at 10 MB, images + PDF.
- **Not yet applied to dev**: the Supabase tool asks for approval on migrations and nobody was awake. Apply it first thing (ask Claude "apply the receipts migration").
- `tools/sqltest`: runs every migration + test in PGlite (Postgres in Node, no Docker). `pnpm --filter sqltest test`. 120 checks pass, including the new `04_receipts.test.sql` (draft, review, finish, 2 packs x 1000 ml, 826 g bananas = 7, aliases learned, same ticket twice refused, second receipt 3/3 auto-matched, sum mismatch -> adjustment, quota, isolation). Test 01 fixed to pass just after midnight.
- Edge Function `parse-receipt` (deployed to dev): checks token, quota, downloads photos as the user, Claude Haiku 5.5 with the output forced through a tool schema, one retry with Sonnet 5.5 when lines don't add up, then `save_receipt_draft`. Never tested against the real API yet (the sandbox can't reach Supabase or Anthropic).
- App: + opens a chooser (photo / photos or PDF / one item by hand); review run list; sum and duplicate questions; check-dates sheet; "Unfinished receipt" banner; Spending tab with Trips by month and a trip page (lines, pantry link, receipt photo). Checked on a phone-size screen with mocked data.
- `tools/receipt-eval`: put the 10 receipts + a JSON of line amounts in `tools/receipt-eval/receipts/` (git-ignored), run with your email/password; prints sum-check score and line accuracy, then discards the drafts.
- Trip edits (migration `20261110110000_trip_edits.sql`, test 06): fix a price (difference goes to Unclassified), add a forgotten item (comes out of Unclassified, else the total grows), delete a trip with Undo (stock from that trip is taken out with tagged adjust movements and put back on undo).
- Step 4b built the same night (migration `20261110100000_pantry_flow.sql`, test 05): item page, Undo bar 6 s, swipe, search + place chips, Ready meals & leftovers group, Home with last shop + Ask Claude. 158 SQL checks pass locally.
- Not done in step 4 yet: `retention` job (needs the scheduler from step 6), "track as separate weighed product" fix, merge flows beyond the confirm question, per-user category expiry override.

