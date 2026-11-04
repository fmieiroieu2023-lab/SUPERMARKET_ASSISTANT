# Your grocery app: architecture, data model, MVP and build plan

## 1. The short answer

Build an **Expo (React Native, TypeScript) iPhone app** on top of **Supabase** (Postgres, Auth, Storage and Edge Functions, hosted in the EU). Put the business rules in **Postgres functions** so the app and Claude call exactly the same logic. Expose that logic to Claude as a **remote MCP server running as a Supabase Edge Function**, secured with **Supabase's OAuth 2.1 server**, and add it in Claude as a custom connector. You then use the same connector from Claude on your iPhone, the web or the desktop app.

The main way to log a trip is **one receipt photo**. A Claude model reads it into line items, the app checks that the lines add up to the printed total, and you approve it on a review screen. The app learns how each store abbreviates each product, so after a few weeks almost every line matches on its own. Barcode scanning (Open Food Facts) and manual entry cover everything else.

Expiry dates start from per-category defaults, and the app asks you for the printed date only on risky items. Loose produce, which has no printed date, gets an estimated date and is alerted like everything else. Alerts come from two independent channels from the first build: notifications scheduled on the phone, and a daily email digest built on the server, so items Claude logs are alerted even if you never open the app. The digest is triggered from outside Supabase by an hourly Cloudflare cron, which also keeps the free-tier project active and emails you if the backend ever stops answering. A trip is counted in the budget once: re-logging the same ticket is caught by its normalised ticket number, or by its printed minute and total when the number is unreadable. Any other same-chain, same-day pair that *could* be one ticket (same total, a ticket number or minute that differs by an OCR-sized slip, or a typed total next to a receipt that could be its ticket) becomes a question, whichever was logged first. Every other same-day pair is added with a one-line notice naming the other trip, so nothing is double-counted silently. Every product is linked to a canonical cooking ingredient when it is created (by the receipt reader, the barcode lookup, a seeded alias table or Claude). That link lets recipes work from your real purchases, and it lets staples like "milk" count any brand from any chain. Recipes, the shopping list and the budget come from deterministic rules you can check, and each rule has a worked test case in the build plan. The shopping list regenerates itself after every write that changes stock and every morning, so you never press "generate". Recipes rank by how much soon-expiring food they use before anything else. Claude adds the judgement and creativity on top.

Every table belongs to a *household* and is protected by row-level security from the first day. That means the version you use alone is already the multi-user version you could sell. The build order tackles the riskiest part first, the Claude connector in week 2. Development runs free in Expo Go, tethered to your laptop. Daily use, including offline use in a supermarket basement, starts when the app is installed as a real TestFlight build at about week 9.5. Later features then reach your phone as over-the-air updates, and the full plan takes about 14.5 weeks at 8–10 hours a week.

The rest of this document explains why each piece is there and exactly how each one works.

---

## 2. How this project could fail, and what prevents each failure

I designed the system backwards from its failure modes. Each row below is a way this kind of app usually dies, followed by the specific mechanism that stops it. Sections 3–9 implement these mechanisms.

| # | Failure | Prevention (and where it's built) |
|---|---|---|
| F1 | **You stop logging after two weeks** because data entry is tedious. This kills most pantry apps. | One receipt photo per trip is the default (§6.1). The review screen only shows lines it is unsure about. Learned aliases auto-match repeat items (§6.1). Expiry dates come from defaults, and you confirm only flagged items. "Finished" and "Threw away" are one tap each. The budget works even from a single "spent €X at Mercadona" entry (§6.7). |
| F2 | **The receipt reader is silently wrong** (missed lines, a misread price, a duplicated section). | A hard invariant: the confirmed line items must add up exactly to the ticket total, checked in the database (§6.1, `confirm_purchase`). If they don't, the app retries with a stronger model and then highlights the gap. Nothing is confirmed automatically if it fails the check. |
| F3 | **Receipt abbreviations don't map to products** ("LECHE SEMI HACEND", "PLATANO CANARIAS"). | A per-household, per-chain `receipt_aliases` table (§5). Each line you confirm teaches the mapping permanently. |
| F4 | **Double counting** when you scan items and also photograph the receipt for the same trip, log a quick total and later photograph that ticket, photograph the same faded ticket twice (ticket number unreadable), or log in the app and again through Claude from the e-ticket. **And the reverse: merging two genuinely separate trips.** | The *trip* (purchase) is the unit. A receipt attached to a trip that already has scanned items is reconciled against them, not added on top (§6.3). Every new trip, from the app or from Claude, goes through one SQL classifier, `classify_duplicate` (§6.1 step 3), under a per-chain-per-day lock. It compares the trip with every confirmed trip of the same chain on the same Madrid date, and the verdict for a pair is the same whichever trip was logged first. **Same normalised ticket number** (alphanumerics only, so "2304-011-123456" = "2304011123456") is blocked. **Same printed minute and same total** is blocked even when no ticket number was read. **Same total** in any other case asks "Same ticket?". So do a **near match**, which is a ticket number one or two characters off or the same printed minute with a different total (one misread field), and a **typed trip next to a receipt that could be its ticket** (printed no later than 10 minutes after the total was typed, whichever was logged first). OCR-read fields (ticket number, printed minute) never *prove* two trips are separate on their own. Any same-chain, same-day trip that is added without a question shows a one-line notice naming the other trip and the reason it was judged different, so even a misread can't double-count silently (§6.1 step 3f, §7.2). Spending always comes from the trip total, counted once. |
| F5 | **Weighed products and in-store labels fail barcode lookup.** EAN-13 codes starting with 20–29 are "restricted circulation" codes made in the shop (fruit scales, deli counter). They aren't in any global database. | The app checks the prefix and sends these straight to "pick product / enter manually" without a failed lookup (§6.2). |
| F6 | **The barcode database misses a product, or rate-limits you.** Open Food Facts allows **15 product reads per minute per IP**. | Lookups run from the phone (your own IP, not a shared server IP). They go through a queue capped at 12 per minute, so scanning a full bag never errors: items are added right away and filled in when the lookup returns. Each result is cached in your own `products` table, so a barcode is looked up once. A miss becomes a 20-second manual entry that is kept for good (§6.2). At scale, the shared server-side catalog comes from the OFF data export instead of the live API (§11). |
| F7 | **Expiry dates are unknown, or of the wrong kind.** Receipts and EAN barcodes don't carry dates. Spanish labels say either *fecha de caducidad* (use-by) or *consumir preferentemente* (best-before), and the same food type can carry either: most yogurts now carry best-before. | Defaults per category and storage location. The app asks for the printed date only for categories where it matters (fresh meat and fish, chilled fresh dairy, bagged salad). The kind is a per-product setting that starts from the category and is corrected with one toggle ("Caducidad / Consumir pref.") on the check-dates sheet or the item screen. The correction is saved on the product, so every later lot of that product gets the right kind (§5, §6.1 step 7). Yogurt has its own best-before category. Opening an item shortens its life; freezing pauses it. Loose produce and unpackaged bread get an `estimate` date, which is alerted like any other (§6.4). |
| F8 | **Alerts don't fire, or fire wrongly.** iOS keeps at most **64 pending local notifications** per app. Claude can add food while the app stays closed, so the phone never schedules an alert for it. DST and time zones cause off-by-one days. | Two independent channels. (1) **Server email digest from step 6:** an hourly Cloudflare Worker cron (outside Supabase) calls the `daily-digest` function, which builds the digest from the database, so it includes everything Claude logged. Those hourly calls are themselves API activity, which keeps the free-tier project from pausing when you stop opening the app, and if a call ever fails the Worker emails you "backend not responding" directly through Resend (F27). (2) Local notifications: at most 7 daily digests, rebuilt on every app open and sync. Claude's write tools also return any lot that is due within the alert window, so Claude tells you in the chat at the moment of logging. From the TestFlight build (step 7), server push replaces the email as the primary channel. Expiry is a `date` evaluated in `Europe/Madrid`. Every pantry lot has a date and an alertable kind (`use_by`, `best_before` or `estimate`); `none` exists only for categories that don't go off, enforced by check constraints (§5, §6.4). |
| F9 | **Unsafe or stale suggestions**, such as a recipe using chicken past its *fecha de caducidad*, or tomatoes that were eaten a month ago but never marked finished. | Every lot stores `expiry_kind`: `use_by` (*caducidad*) or `best_before` (*consumir preferentemente*) or `estimate`. Past-use-by lots are **excluded** from recipes. Past-best-before and past-estimate lots stay usable, flagged "check it first", only for their category's short `check_grace_days`. After that they become *unconfirmed*: they drop out of recipes, the shopping-list stock count and the daily "Check it" group, and the app asks once "Still have this?" (§6.4, §6.5). |
| F10 | **Recipe suggestions are empty or irrelevant.** Product names don't match recipe ingredients. | Products map to canonical `ingredients` ("Pechuga de pollo Hacendado" → `chicken_breast`), and every way of creating a product sets that link: the receipt reader picks from the canonical ID list, barcode hits go through OFF category tags, names go through a seeded `ingredient_aliases` table, and the review screen shows the result as an editable chip. Unlinked food products are counted and fixable in one tap (§6.1, §6.2, §6.5). A seeded recipe library ships with the app. Basics (salt, oil, water) are assumed. Claude handles open-ended cooking ideas through the connector and can save them back (§6.5, §7). |
| F11 | **The shopping list is noisy** (duplicates, things you never buy, things you just bought, or a re-order of Hacendado milk when you just bought Carrefour milk), **or it isn't automatic at all** because it only changes when someone runs the generator. | The list refreshes itself: `refresh_shopping_list` runs at the end of every SQL function that changes stock, staples or recipe plans (from the app or from Claude), every morning from the scheduler, and when the List tab opens online (§6.6). Rules work on a *stock key*: the canonical ingredient when the product has one (milk from any brand or chain counts), the product otherwise, or a single product when you pin a staple to one brand. One open row per stock key, enforced by a unique index. Every row records *why* it was added. Items you dismiss stay snoozed. Items you tick off as bought count as **in transit** until a receipt confirms them or 3 days pass, so they aren't re-added in the gap between shopping and logging. Rows whose automatic reason no longer holds close themselves. Refreshing twice gives the same list (§6.6). |
| F12 | **Budget numbers are wrong** (float rounding, discounts, refunds, non-food, a midnight purchase landing in the wrong month), or **budget warnings are wrong** because grocery spending comes in weekly lumps, or because there is too little history (two shops on one day). | Money is stored as integer cents. Discounts and refunds are negative lines, checked by a constraint. A month is computed in `Europe/Madrid`. Any unreconciled difference becomes an explicit "adjustment" line, so the totals always tie out. Hard alerts (80% and 100%) use only money actually spent. The projection works on *shopping days* (all trips of one Madrid date summed), so several chains on one day count as one shop. It appears only after at least 3 shopping days spanning at least 14 days, so its run rate never divides by less than 14 days. It assumes your last shop covers you until your usual next shop, and uses a run rate measured between shopping days, so it doesn't jump after each shop. Its alert has a tolerance of half a typical shopping day's spend (§5, §6.7). |
| F13 | **No signal in the supermarket basement**, and scans get lost. **Or the app can't even start there**, because a project in Expo Go loads from a dev server or the network. | Daily use starts only with the installed TestFlight build (step 7), which embeds its JavaScript bundle and caches every over-the-air update, so it cold-starts in airplane mode. Before that, the app runs in Expo Go from your laptop's dev server, and the plan doesn't count it as usable in a shop. Reads come from a persisted local cache. Writes go to an offline queue with IDs generated on the phone, and the server treats a repeated ID as a no-op, so a retry never creates duplicates (§3, §4). Step 7's test is a cold start in airplane mode. |
| F14 | **Lost updates** when you and Claude change the same item at once. | Quantities are never overwritten. Each change is an appended `stock_movement`, and the quantity left is the sum of the movements. Inserts from two sides can't overwrite each other, and a row lock prevents going below zero (§5). |
| F15 | **Claude can't connect.** Its OAuth client is strict: it needs a `401` pointing to resource metadata, S256 PKCE, a specific callback URL, a form-encoded token endpoint and responses within 10 seconds. | Supabase's OAuth 2.1 server implements authorization code + PKCE and dynamic client registration. The connector is built and tested from your iPhone in **week 2**, before any app UI. A fallback is named in case the beta disappoints (§7.1, §9). |
| F16 | **Claude damages your data** (deletes things, invents items, does the wrong thing twice). | There is no hard-delete tool. Every write is reversible: a compensating movement, and `undo(request_id)` per call. Writes are idempotent by request ID. Every Claude call is audited (`via='mcp'` on movements, plus an `mcp_audit` row written through a function the kill switch does not block). An in-app kill switch for Claude writes is enforced *in the database*, not just in the MCP server (§7.3). |
| F17 | **Prompt injection through data.** A product name from a public database or receipt text could contain instructions. | Tools return structured JSON with short, length-capped strings and no free-form HTML. No tool can send data outside your account. Write tools keep Claude's per-tool permission prompt (§7.3). |
| F18 | **Data leaks between users once others join.** | Every table has `household_id` and RLS. Composite foreign keys stop a row from pointing at another household's product. Views use `security_invoker`. Automated tests check cross-tenant reads. The MCP server holds no service key: it acts with *your* token, so RLS applies to Claude too (§5, §7). |
| F19 | **Single-user shortcuts that block scaling** (a hard-coded user, data only on the phone, "my" store names in code). | Households, chains and categories are data rather than code from day one. All data lives in Postgres (§5). |
| F20 | **App Store rejection when you try to sell.** | Planned in: in-app account deletion (Guideline 5.1.1(v)), a privacy policy, and Sign in with Apple when any social login is added (4.8). Subscriptions use Apple in-app purchase via RevenueCat (§11). |
| F21 | **GDPR problems.** Receipts hold personal data (store, time, sometimes the last card digits). | EU-hosted database. Receipt images live in a private bucket and are deleted through the Storage API 30 days after the trip is confirmed. Drafts you abandon are voided after 7 days, and their images are deleted at that point. The parser never extracts card digits. JSON/CSV export and account deletion are included (§9, step 12). |
| F22 | **Costs explode with users** (an AI call per receipt). | A cheap model by default, with the stronger model only when the sum check fails. Aliases mean less work over time. A per-household daily quota table. Your own cost is cents per month (§10). |
| F23 | **The project never ships** (too big, needs a Mac, too many vendors). | One language (TypeScript) and four vendors, each free at your scale (Supabase, Cloudflare for one static page and one cron Worker, Expo, Resend for the digest email). Development starts in Expo Go with no Mac and no €99 fee. Steps 1–6 use only native modules that Expo Go already contains, and the fee is paid at step 7, when daily use begins (§4). Steps are ordered riskiest first, and each step has a pass/fail test (§9). |
| F24 | **The product only works with Claude**, which limits who you can sell to. | The app is complete on its own. The connector is an extra for Claude users, not a requirement (§11). |
| F25 | **Supermarket legal or brittleness risk.** | No scraping of Mercadona, Carrefour or Supercor websites or apps, and no store logos. Store names are used only as data labels. Ticket formats are handled by a model prompt updated on the server, so a format change needs no app release (§6.1). |
| F26 | **Store changes break assumptions.** Dozens of Supercor stores were sold to Carrefour and reopened under the Carrefour brand. | The store chain is read from each receipt header, not assumed from a location. `chains` is a table, so adding Lidl, Dia or Alcampo later is a row insert (§5). |
| F27 | **Silent infrastructure failures.** The Supabase free tier pauses a project after a 7-day window of low activity, and a paused project runs no jobs, so a digest scheduled *inside* Supabase would stop in exactly the weeks you don't open the app. TestFlight builds expire after 90 days. | The schedule lives **outside** Supabase: a Cloudflare Worker cron calls `daily-digest` every hour and `retention` every night. Supabase's documentation counts API calls as activity, and each call reads the database, so the project stays active with zero app use. If a pause happens anyway, three things tell you: Supabase's warning email about a week ahead, the Worker's own "backend not responding" email (sent through Resend, which doesn't depend on Supabase) on the first failed morning, and Supabase's pause email. A paused project can be resumed from the dashboard with its data for up to a year. Move to Pro, which never pauses, when anyone else depends on it. Weekly `pg_dump` backup via a GitHub Action. Calendar reminder to re-upload the TestFlight build (§9, §10). |
| F28 | **Quantities in the wrong unit** ("2 × leche 1 L" stored as 2 ml). | One conversion function, `to_base_qty`, used by every write path. Receipt lines record what is printed (a number of packs, or a weight in grams). Products store their base unit and the size of one pack (from Open Food Facts' `product_quantity`/`product_quantity_unit` when available). A line that can't be converted blocks confirmation and asks you, never guessing: the pack size, or for a weighed line on a counted product ("PLATANO 0,826 kg" against "Plátanos ×6") the weight of one item, prefilled from the ingredient's typical weight and saved on the product. A product's base unit is **never changed in place** once it has stock, lines or a staple, because lots and movements store bare numbers in that unit (§6.1 step 6). |
| F29 | **A trip logged by barcode only has no price, or loses its items.** | An unpacking session is a draft trip that can't end without a total. "Finish trip" asks for a receipt photo, or the amount charged (your bank app shows it to the cent), or optional per-item prices. The cleanup job never voids a draft that holds pantry lots, and voiding never touches lots. The digest reminds you about any unfinished trip after 2 days (§6.3). |
| F30 | **Recipe ranking ignores what's expiring.** A score that adds a small amount per in-stock ingredient lets a 7-ingredient pantry stew outrank a 2-ingredient dish built around chicken that's use-by in 3 days. | Ranking is lexicographic, not a weighted sum. Ingredients more than 7 days from expiry contribute **zero** urgency, and recipes are sorted first by the urgency of what they use, then by missing ingredients, then by coverage. Any recipe that uses something expiring within 7 days therefore ranks above every recipe that uses nothing expiring, however long it is (§6.5). |

---

## 3. Architecture

```
┌──────────────────── iPhone ────────────────────┐        ┌───────── Claude (iPhone / web / desktop) ────────┐
│ Expo app (TestFlight build + EAS Update OTA)   │        │ Custom connector  →  https://<ref>.supabase.co/   │
│  • Expo Router screens                         │        │                       functions/v1/mcp            │
│  • expo-camera  (EAN/UPC barcode scanning)     │        └───────────────┬──────────────────────────────────┘
│  • expo-image-picker (receipt photos, ≤4/trip) │                        │ OAuth 2.1 (PKCE) → user access token
│  • expo-notifications (local daily digests)    │                        ▼
│  • TanStack Query: persisted cache + offline   │   ┌──────────────────────── Supabase (EU region) ───────────────────────┐
│    mutation queue (client-generated UUIDs)     │   │ Auth: email OTP (+ Sign in with Apple later) + OAuth 2.1 server     │
│  • Open Food Facts lookups (rate-limited queue)│──▶│ Postgres: tables + RLS + SQL functions (the business rules)         │
└───────────────┬────────────────────────────────┘   │ Storage: private bucket "receipts/{household_id}/{purchase_id}/n"   │
                │ supabase-js with user JWT           │ Edge Functions (Deno/TS):                                           │
                └────────────────────────────────────▶│   • parse-receipt → Claude API (vision, JSON schema output)         │
                                                      │   • mcp           → MCP server, Streamable HTTP, stateless          │
                                                      │   • retention     → cron secret only, file cleanup via Storage API  │
                                                      │   • daily-digest  → cron secret only: list refresh, email, push     │
                                                      └──────────────────────────────▲──────────────────────────────────────┘
                                                                                     │ HTTPS + cron secret
                                                      ┌──────── Cloudflare (free) ───┴──────────────────┐
                                                      │ Pages: OAuth sign-in + consent page (Vite SPA), │
                                                      │        privacy policy, account-deletion page    │
                                                      │ Worker "scheduler" (Cron Trigger, hourly):      │
                                                      │   • daily-digest every hour (per-user time)     │
                                                      │   • retention once a night                      │
                                                      │   • on failure at digest hour: "backend not     │
                                                      │     responding" email via Resend (≤1 a day)     │
                                                      └─────────────────────────────────────────────────┘
```

**Design rules that the rest of the plan depends on:**

1. **One source of truth: Postgres.** The phone holds a cache and an outbox, never the master copy. That is what allows Claude to read and update the same data, and what makes multiple users possible.
2. **Business logic lives in SQL functions** (`confirm_purchase`, `consume`, `generate_shopping_list`, `suggest_recipes`, `budget_status`, …), declared `security invoker` so RLS applies. The app calls them with `supabase.rpc(...)`. The MCP server calls the same functions with the user's token. Claude and the app therefore cannot disagree about what "expiring soon" or "over budget" means.
3. **The MCP server has no privileged key.** It verifies the OAuth access token and creates a Supabase client *as you*. Even a bug in the MCP code cannot read another household's rows. The only service-role keys live in the cron-only `retention` and `daily-digest` functions, which reject any call without the cron secret header. The secret is stored as a Supabase function secret and as a Cloudflare Worker secret, nowhere else.
4. **Every write carries an ID generated on the client.** Retries over bad networks, or Claude repeating a call, are no-ops.
5. **Dates you reason about (expiry) are `date`. Events (purchases, movements) are `timestamptz`.** Calendar logic is evaluated in the household's time zone (`Europe/Madrid`).
6. **Nothing that must keep running is scheduled inside the thing it monitors.** The scheduler runs on Cloudflare, so a paused or broken Supabase project produces a failed call, which produces an email, instead of silence.
7. **Derived state is refreshed by the writes that change it, not by someone remembering.** Every SQL function that changes stock, staples or plans ends by calling `refresh_shopping_list` for that household, inside the same transaction. The morning scheduler run refreshes again for the rules that depend only on the date (§6.6).
8. **The app you use in the shop is an installed build, not a project loaded from a server.** Expo Go is a development tool; the TestFlight build embeds its bundle and launches offline (§4, step 7).

**Why the scheduler is a Cloudflare Worker rather than pg_cron:** a free Supabase project that sees a week of low activity is paused, and a paused project runs no pg_cron jobs, so an in-database schedule fails silently in exactly the case the email digest exists for (you stopped opening the app). A Worker Cron Trigger is free, runs whatever happens to Supabase, generates the inbound API activity that Supabase counts, and can report a failure through Resend. It is about 60 lines of TypeScript in `apps/scheduler`.

**Why the consent page is on Cloudflare Pages rather than Supabase:** Supabase's OAuth server sends users to *your* authorization page (Site URL + Authorization Path, e.g. `/oauth/consent`). Supabase Edge Functions only serve HTML on a custom domain, so a free static host is the simplest place for that one page. It is a small SPA that calls `supabase.auth.oauth.getAuthorizationDetails / approveAuthorization / denyAuthorization`. Cloudflare's free plan allows commercial use. Vercel's free Hobby plan does not, which would matter once you sell.

---

## 4. Tech stack and trade-offs

| Layer | Choice | Rejected alternatives and why |
|---|---|---|
| iPhone app | **Expo SDK (React Native) + TypeScript + Expo Router.** Pin the SDK version at project creation. | **SwiftUI native:** best access to Apple's own OCR and barcode scanner, but it needs a Mac and Xcode, a second language (Swift) next to a TypeScript backend, and gives no Android path for selling. **PWA:** Safari has no `BarcodeDetector`, a web app can't schedule local notifications, and offline storage is less reliable, so it fails F5, F8 and F13. **Flutter:** viable, but Dart adds a second language and the Supabase/MCP ecosystem is TypeScript-first. |
| Dev and test on device | **Expo Go** (free, no Mac) for steps 1–6, loading the project from `npx expo start` on your laptop (same Wi-Fi, or `--tunnel`). Expo Go is a development tool: it loads the project's bundle from the dev server or the network, so it is **not** what you use in the shop, and steps 1–6 make no offline promise for it. This only works if every native module is one that Expo Go already contains, so the app uses only `expo-camera`, `expo-image-picker`, `expo-image-manipulator`, `expo-notifications` (local notifications), `expo-crypto` (UUIDs), `@react-native-async-storage/async-storage` and `react-native-svg` (charts). Install them with `npx expo install` so the versions match the SDK. **Step 7: EAS cloud build → TestFlight**, which needs the Apple Developer Program (€99/yr), with `expo-updates` included. From then on the installed app is what you use daily. It embeds its JavaScript bundle and keeps the last downloaded update on the phone, so it cold-starts with no signal. Steps 8–12 reach it as **EAS Update** over-the-air releases (`eas update --channel production`), with no rebuild unless a native module changes. You keep iterating in Expo Go (it only loads EAS Update projects you own, which yours is) or in the dev server. | Building directly with Xcode needs a Mac, and free provisioning expires every 7 days. Staying in Expo Go for daily use would leave the app unable to start in a basement with no signal. |
| Backend | **Supabase**, EU region (Frankfurt or Paris): Postgres 15+, RLS, Auth, Storage, Edge Functions, pg_trgm. Schedules run on a Cloudflare Worker cron, not pg_cron (§3). Two free projects: `dev` and `prod`. | **Firebase/Firestore:** NoSQL makes spending analytics (group-by month, category, store) awkward, and it has no OAuth server for MCP. **Custom Node + Postgres:** you would run auth, storage and servers yourself. **Cloudflare D1:** auth and RLS would be DIY. |
| Auth for the app | Supabase **email OTP (6-digit code)**. Edit the email template to include `{{ .Token }}` so no deep links are needed in Expo Go. Add **Sign in with Apple** before the App Store. | Magic links are awkward to deep-link in Expo Go. Passwords add friction. |
| Auth for Claude | **Supabase OAuth 2.1 server** (beta, all plans): authorization code + PKCE, dynamic client registration, JWT access tokens with a `client_id` claim, so existing RLS applies. | **Fallback if the beta misbehaves:** a Cloudflare Worker using `@cloudflare/workers-oauth-provider` that signs you in with Supabase and forwards your Supabase session. This means more code, so it is kept only as plan B. |
| MCP server | **Supabase Edge Function** using the official MCP TypeScript SDK, **Streamable HTTP transport in stateless mode**. Use Supabase's `@supabase/server` helpers (`withOAuthProtectedResource()` for the `401` + resource metadata, and `withSupabase({ auth: 'user' })` for a client scoped to the user). | A separate host adds a vendor and a second place to deploy. A local (stdio) MCP server would only work on a computer, not from Claude on your iPhone. |
| Receipt reading | **Claude API with vision**, from the `parse-receipt` Edge Function, with output forced to a JSON schema. A small model by default (Haiku class); retry once with a larger model (Sonnet class) if the sum check fails. | **On-device OCR + regex per chain:** free and private, but abbreviations, multi-buy discounts and weighed lines break the rules, and they need app releases to fix. **Receipt APIs (Veryfi, Taggun, Textract):** another vendor, paid per receipt, and no product or category inference. |
| Barcode data | **Open Food Facts API**, called from the device with a `User-Agent: AppName/0.1 (your@email)` header and ≤12 calls per minute, cached in your DB. Attribute OFF (ODbL) on the About screen. | Scraping supermarket sites breaks their terms, is brittle, and is a legal risk once you sell. |
| Offline | **TanStack Query** with a persisted cache (`@tanstack/query-async-storage-persister` on **AsyncStorage**, which Expo Go includes) and **paused mutations** that resume on reconnect. Client UUIDs make them idempotent. | **MMKV** is faster, but it is a native module that Expo Go doesn't contain. It would force a development build, and with it the €99 account, in week 3. Swap it in after step 7 only if cache reads feel slow. PowerSync or ElectricSQL (full sync engines) are more moving parts than one user needs. Revisit them if household sharing makes offline conflicts common. |
| Notifications | Two channels in the MVP: `expo-notifications` local digests, plus a **server-built daily email** (Cloudflare Worker cron → `daily-digest` Edge Function → Resend). The email is always current, so it covers lots Claude creates while the app is closed and weeks when you don't open the app; the hourly calls keep the free project active, and a failed call emails you. From step 7 (TestFlight), the same function sends **Expo Push** and the email becomes optional. | Server push needs an APNs key, i.e. the paid Apple account, so it can't be the first channel. Resend's free plan allows 3,000 emails a month and 100 a day, enough for one user and the first few dozen testers. Until you verify a domain, Resend's test sender only delivers to your own account email, which is all the MVP needs. |
| Validation and types | `zod` schemas in `packages/shared`, used by the app, `parse-receipt` and the MCP tool inputs. DB types generated with `supabase gen types typescript`. | Hand-written types drift from the schema. |
| Tests | SQL tests (pgTAP or plain transactions) for RLS and functions. Vitest for TypeScript logic. A receipt accuracy script (§9 step 5). | — |
| Monitoring | Sentry (free tier) in the app, added at step 7 with the TestFlight build, Supabase function logs, the `mcp_audit` table. | — |
| Payments (later) | RevenueCat + Apple in-app purchase. | Selling digital subscriptions inside an iOS app without IAP risks rejection. |

**Repository layout** (one pnpm monorepo, built with Claude Code):

```
grocery/
  apps/mobile/            Expo app
  apps/web/               Vite SPA: OAuth consent, privacy, delete-account (Cloudflare Pages)
  apps/scheduler/         Cloudflare Worker: hourly cron → daily-digest, nightly → retention, failure email
  packages/shared/        zod schemas, money/date utils, generated DB types
  supabase/migrations/    SQL: schema, RLS, functions, seed (chains, categories, ingredients, recipes)
  supabase/functions/     parse-receipt/, mcp/, retention/, daily-digest/
  supabase/tests/         RLS + function tests
  tools/receipt-eval/     accuracy script + your ground-truth receipts (git-ignored images)
```

---

## 5. Data model

Every table except the global reference tables has `household_id`. On day one you are the only member of a single household. Flatmates or paying users later just mean more rows.

```sql
create extension if not exists pg_trgm;
create extension if not exists fuzzystrmatch;            -- levenshtein() for near-match ticket numbers (§6.1 3f)

-- ── Global reference data (read-only to users, seeded by migrations) ──────────
create table chains (id text primary key, name text not null);
-- seed: ('mercadona','Mercadona'), ('carrefour','Carrefour'), ('supercor','Supercor'), ('other','Otro')

create table categories (
  id                     text primary key,             -- 'fresh_meat', 'dairy_chilled', 'dry_goods', 'cleaning', ...
  name_es                text not null,
  is_food                boolean not null,
  default_location       text not null check (default_location in ('fridge','freezer','pantry')),
  shelf_life_days        int,                          -- null = don't track expiry (e.g. cleaning)
  opened_shelf_life_days int,
  freezer_life_days      int,
  expiry_kind            text not null check (expiry_kind in ('use_by','best_before','estimate','none')),
                                                       -- estimate = no printed date (loose produce, unpackaged bread)
  ask_printed_date       boolean not null default false,
  check_grace_days       int check (check_grace_days >= 0),
                                                       -- best_before/estimate only: days past the date a lot stays
                                                       -- usable ("check it first") before it becomes unconfirmed
  check ((expiry_kind = 'none') = (shelf_life_days is null)),   -- 'none' only for things that don't go off
  check ((expiry_kind in ('best_before','estimate')) = (check_grace_days is not null))
);

create table ingredients (                              -- canonical cooking ingredients
  id        text primary key,                           -- 'chicken_breast', 'spinach', 'rice'
  name_es   text not null,
  name_en   text not null,
  is_basic  boolean not null default false,             -- salt, pepper, oil, water: assumed available
  typical_unit_g numeric(8,1) check (typical_unit_g > 0) -- banana 120, onion 150, lemon 100: prefill only,
                                                          -- shown to you before it is ever used (§6.1 step 6)
);

create table ingredient_aliases (                       -- seeded; maps names and OFF tags to ingredients
  alias         text primary key,                       -- normalised: 'PECHUGA POLLO', 'ESPINACA', 'en:chicken-breasts'
  kind          text not null check (kind in ('name','off_tag')),
  ingredient_id text not null references ingredients
);
create index ingredient_aliases_trg on ingredient_aliases using gin (alias gin_trgm_ops);

-- ── Tenancy ───────────────────────────────────────────────────────────────────
create table households (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null default 'Casa',
  timezone             text not null default 'Europe/Madrid',
  currency             char(3) not null default 'EUR',
  monthly_budget_cents int check (monthly_budget_cents > 0),
  mcp_write_enabled    boolean not null default true,    -- kill switch for Claude writes
  created_at           timestamptz not null default now()
);

create table household_members (
  household_id uuid not null references households on delete cascade,
  user_id      uuid not null references auth.users on delete cascade,
  role         text not null default 'owner' check (role in ('owner','member')),
  primary key (household_id, user_id)
);
-- trigger on auth.users insert: create a household + owner membership (security definer)

-- ── Products and receipt learning ─────────────────────────────────────────────
create table products (
  id                     uuid primary key default gen_random_uuid(),
  household_id           uuid not null references households on delete cascade,
  gtin                   text check (gtin ~ '^([0-9]{8}|[0-9]{12,14})$'),
  name                   text not null,
  brand                  text,
  category_id            text not null references categories,
  ingredient_id          text references ingredients,
  unit                   text not null check (unit in ('unit','g','ml')),   -- base unit: every stock quantity is in it
  pack_size              numeric(10,3) check (pack_size > 0),               -- base units in ONE sold pack:
                                                                            -- milk 1 L → 1000 (ml); eggs ×12 → 12 (unit);
                                                                            -- null = sold loose by weight, or 1 for 'unit'
  unit_weight_g          numeric(8,1) check (unit_weight_g > 0),            -- 'unit' products only: grams in one item,
                                                                            -- confirmed by you; lets a weighed receipt
                                                                            -- line be counted ("0,826 kg" → 7 bananas)
  shelf_life_days        int,                                               -- overrides category
  opened_shelf_life_days int,
  expiry_kind            text check (expiry_kind in ('use_by','best_before','estimate')),
                                                                            -- overrides category: set by the
                                                                            -- "Caducidad / Consumir pref." toggle;
                                                                            -- null = use the category's kind
  kind_confirmed         boolean not null default false,                    -- you've checked the label once
  source                 text not null check (source in ('off','manual','receipt','claude')),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  check (unit_weight_g is null or unit = 'unit'),
  unique (id, household_id)                                                 -- target for composite FKs
);
-- trigger products_unit_frozen: an UPDATE that changes `unit` raises PRODUCT_HAS_HISTORY if any pantry_lot,
-- purchase_item with a quantity, or staple references the product. Lots and movements store bare numbers in
-- the base unit, so changing it in place would silently reinterpret them (6 bananas → 6 g).
create unique index products_gtin_uq  on products (household_id, gtin) where gtin is not null;
create index        products_name_trg on products using gin (name gin_trgm_ops);

create table receipt_aliases (                         -- "LECHE SEMI HACEND" at Mercadona → product
  household_id uuid not null references households on delete cascade,
  chain_id     text not null references chains,
  alias        text not null,                          -- normalised: upper-case, no accents, single spaces
  product_id   uuid not null,
  hits         int not null default 1,
  primary key (household_id, chain_id, alias),
  foreign key (product_id, household_id) references products (id, household_id) on delete cascade
);
create index receipt_aliases_trg on receipt_aliases using gin (alias gin_trgm_ops);

-- ── Purchases (one row per shopping trip) ─────────────────────────────────────
create table purchases (
  id            uuid primary key,                      -- generated on the phone (idempotent retries)
  household_id  uuid not null references households on delete cascade,
  chain_id      text not null references chains,
  store_label   text,
  purchased_at  timestamptz not null,
  time_source   text not null default 'entered'
                check (time_source in ('printed','entered')),   -- 'printed' = minute read from the ticket
  ticket_number text,                                  -- "factura simplificada" number; written only by confirm_purchase
  ticket_norm   text generated always as
                (nullif(regexp_replace(upper(ticket_number), '[^A-Z0-9]', '', 'g'), '')) stored,
                                                       -- "2304-011-123456" and "2304 011 123456" compare equal
  confirmed_at  timestamptz,                           -- when the total was recorded (typed, or receipt confirmed)
  status        text not null check (status in ('draft','confirmed','void')),
  source        text not null check (source in ('receipt_photo','receipt_file','scan','manual','claude')),
  total_cents   int,                                   -- amount actually charged, discounts included
  verification  text not null default 'unverified'
                check (verification in ('sum_ok','adjusted','total_only','unverified')),
  receipt_paths text[] not null default '{}',
  parse_output  jsonb,                                 -- raw model output, kept for audit/debugging
  created_by    uuid references auth.users,
  created_via   text not null check (created_via in ('app','mcp')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (status <> 'confirmed' or (total_cents is not null and confirmed_at is not null)),
  check (status <> 'draft' or ticket_number is null),  -- a draft can never block re-logging a ticket
  unique (id, household_id)
);
create unique index purchases_ticket_uq on purchases (household_id, chain_id, ticket_norm)
  where ticket_norm is not null and status = 'confirmed';     -- last line of defence; classify_duplicate (§6.1)
                                                              -- catches this and the ticketless cases first
create index purchases_day_idx on purchases (household_id, chain_id, purchased_at) where status = 'confirmed';

create table purchase_items (
  id                uuid primary key,
  purchase_id       uuid not null,
  household_id      uuid not null,
  line_no           int  not null,
  kind              text not null check (kind in ('item','discount','refund','adjustment')),
  raw_text          text,
  product_id        uuid,                               -- null = spend only (no pantry lot)
  category_id       text references categories,
  printed_qty       numeric(10,3) not null default 1 check (printed_qty > 0),   -- as on the ticket
  printed_unit      text not null default 'pack' check (printed_unit in ('pack','g','ml')),
                                                        -- 'pack' = a counted item ("2 x LECHE"); weights in g
  quantity          numeric(10,3) check (quantity > 0), -- in the product's base unit, set by to_base_qty();
                                                        -- null only while unmatched or on spend-only lines
  line_total_cents  int not null,
  check (kind = 'adjustment' or ((kind in ('discount','refund')) = (line_total_cents < 0))),
  unique (purchase_id, line_no),
  unique (id, household_id),
  foreign key (purchase_id, household_id) references purchases (id, household_id) on delete cascade,
  foreign key (product_id,  household_id) references products  (id, household_id)
);

-- ── Pantry: lots + append-only movements ──────────────────────────────────────
create table pantry_lots (
  id               uuid primary key,
  household_id     uuid not null,
  product_id       uuid not null,
  purchase_id      uuid,                               -- trip this lot came from (set for scanned lots too)
  purchase_item_id uuid,                               -- the priced receipt line, once matched
  location         text not null check (location in ('fridge','freezer','pantry')),
  initial_qty      numeric(10,3) not null check (initial_qty > 0),
  expires_on       date not null,                      -- printed, user or default: never unknown
  expiry_kind      text not null check (expiry_kind in ('use_by','best_before','estimate')),   -- every lot is alertable
  expiry_source    text not null check (expiry_source in ('printed','default','user','claude')),
  opened_on        date,
  frozen_on        date,
  checked_on       date,                               -- last "Still have it? → Yes" (restarts the grace window)
  unit_cost_cents  numeric(12,4),                      -- line total / base quantity → waste in €
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, household_id),
  foreign key (product_id, household_id) references products (id, household_id) on delete cascade,
  foreign key (purchase_id, household_id) references purchases (id, household_id) on delete set null (purchase_id),
  foreign key (purchase_item_id, household_id) references purchase_items (id, household_id)
);

create table stock_movements (
  id           uuid primary key,                       -- client-generated → retry-safe
  household_id uuid not null,
  lot_id       uuid not null,
  delta        numeric(10,3) not null check (delta <> 0),
  reason       text not null check (reason in ('purchase','consume','discard','adjust')),
  occurred_at  timestamptz not null default now(),
  actor        uuid references auth.users,
  via          text not null check (via in ('app','mcp')),
  request_id   uuid,                                   -- groups one Claude tool call, for undo
  reverses     uuid references stock_movements,
  foreign key (lot_id, household_id) references pantry_lots (id, household_id) on delete cascade
);

create view pantry with (security_invoker = true) as   -- security_invoker: RLS still applies
with b as (
  select l.*, p.name, p.category_id, p.ingredient_id, p.unit, p.pack_size,
         coalesce(c.check_grace_days, 2) as grace_days,  -- lot kind can differ from its category's
         (now() at time zone h.timezone)::date as today,
         coalesce((select sum(m.delta) from stock_movements m where m.lot_id = l.id), 0) as qty_left,
         case
           when l.frozen_on is not null
             then l.frozen_on + coalesce(c.freezer_life_days, 90)
           when l.opened_on is not null
                and coalesce(p.opened_shelf_life_days, c.opened_shelf_life_days) is not null
             then least(l.expires_on,
                        l.opened_on + coalesce(p.opened_shelf_life_days, c.opened_shelf_life_days))
           else l.expires_on
         end as effective_expires_on
  from pantry_lots l
  join products   p on p.id = l.product_id
  join categories c on c.id = p.category_id
  join households h on h.id = l.household_id
)
select b.*,
       b.effective_expires_on - b.today as days_left,
       case
         when b.qty_left <= 0                    then 'finished'
         when b.today <= b.effective_expires_on  then 'ok'
         when b.expiry_kind = 'use_by'           then 'expired'       -- never usable again
         when b.today <= greatest(b.effective_expires_on, coalesce(b.checked_on, b.effective_expires_on))
                         + b.grace_days          then 'check'         -- usable, flagged "check it first"
         else                                         'unconfirmed'   -- probably gone: ask once, stop counting it
       end as state
from b;
-- "usable" everywhere in this document means state in ('ok','check').

-- ── Recipes, shopping list, budget, audit, settings ───────────────────────────
create table recipes (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid references households on delete cascade,   -- null = built-in library
  title        text not null,
  servings     int,
  minutes      int,
  steps        text not null,
  source       text not null check (source in ('seed','user','claude')),
  created_at   timestamptz not null default now()
);
create table recipe_ingredients (
  recipe_id     uuid not null references recipes on delete cascade,
  ingredient_id text not null references ingredients,
  quantity      numeric(10,3),
  unit          text,
  optional      boolean not null default false,
  primary key (recipe_id, ingredient_id)
);

create table staples (                                  -- what the shopping list keeps in stock
  id            uuid primary key,
  household_id  uuid not null references households on delete cascade,
  ingredient_id text references ingredients,            -- default: any brand, any chain ("milk")
  product_id    uuid,                                   -- only when you pin one exact product
  par_qty       numeric(10,3) not null check (par_qty > 0),
  unit          text not null check (unit in ('unit','g','ml')),   -- base unit of par_qty
  check ((ingredient_id is null) <> (product_id is null)),
  foreign key (product_id, household_id) references products (id, household_id) on delete cascade
);
create unique index staples_key_uq on staples
  (household_id, coalesce('p:' || product_id::text, 'i:' || ingredient_id));

create table shopping_list_items (
  id            uuid primary key,
  household_id  uuid not null references households on delete cascade,
  ingredient_id text references ingredients,            -- set for ingredient-level rows ("milk")
  product_id    uuid,                                   -- set for product-level rows, or the suggested product
  label         text not null,
  quantity      numeric(10,3),
  unit          text,
  reasons       text[] not null,       -- 'below_par' | 'runs_out_soon' | 'usual_purchase' | 'recipe:<id>' | 'manual' | 'claude'
  status        text not null default 'open' check (status in ('open','bought','dismissed','resolved')),
                                       -- resolved = closed by the refresh because its automatic reason stopped holding
  snoozed_until date,
  bought_at     timestamptz,                            -- set by "Done shopping" / mark_bought
  reconciled_at timestamptz,                            -- set when a confirmed purchase contains this stock key
  check ((status = 'bought') = (bought_at is not null)),
  added_via     text not null check (added_via in ('app','mcp','auto')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  foreign key (product_id, household_id) references products (id, household_id) on delete set null (product_id)
);
create unique index shopping_open_uq on shopping_list_items      -- one open row per stock key
  (household_id, coalesce('i:' || ingredient_id, 'p:' || product_id::text, 'l:' || lower(label)))
  where status = 'open';

create table budgets (                                  -- per-month override of the household default
  household_id uuid not null references households on delete cascade,
  month        date not null check (extract(day from month) = 1),
  amount_cents int  not null check (amount_cents > 0),
  primary key (household_id, month)
);

create table mcp_audit (
  id              bigint generated always as identity primary key,
  household_id    uuid not null references households on delete cascade,
  user_id         uuid not null,
  oauth_client_id text,
  tool            text not null,
  request_id      uuid,
  args            jsonb,
  ok              boolean not null,
  at              timestamptz not null default now()
);

create table user_settings (
  user_id               uuid primary key references auth.users on delete cascade,
  digest_time           time not null default '09:00',
  use_by_lead_days      int  not null default 2 check (use_by_lead_days between 0 and 7),
  best_before_lead_days int  not null default 3 check (best_before_lead_days between 0 and 14),
  email_digest          boolean not null default true,
  last_digest_on        date,                           -- the server digest is sent at most once per local day
  expo_push_token       text                            -- from step 7
);

create table usage_counters (                           -- quota for paid AI calls
  household_id uuid not null references households on delete cascade,
  day          date not null,
  receipt_parses int not null default 0,
  primary key (household_id, day)
);
```

The `on delete set null (product_id)` column list needs Postgres 15 or later, which current Supabase projects run.

**Row-level security** (applied to every household table; reference tables are select-only):

```sql
create function public.is_member(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.household_members m
                 where m.household_id = h and m.user_id = (select auth.uid()));
$$;

-- for each household-scoped table T:
alter table T enable row level security;
create policy T_member on T for all to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));

-- Claude kill switch, enforced in the database (restrictive = AND-ed with the policy above).
-- OAuth tokens issued to Claude carry a client_id claim; the app's own sessions don't.
create function public.oauth_write_ok(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (auth.jwt() ->> 'client_id') is null
      or (select mcp_write_enabled from public.households where id = h);
$$;
create policy T_claude_insert as restrictive for insert to authenticated with check (public.oauth_write_ok(household_id));
create policy T_claude_update as restrictive for update to authenticated using (public.oauth_write_ok(household_id));
create policy T_claude_delete as restrictive for delete to authenticated using (public.oauth_write_ok(household_id));

-- Exception: mcp_audit gets NO restrictive policies and NO insert policy. It is written only through
-- log_mcp_call(), so a read made while Claude's write access is off still succeeds and is still audited.
create function public.log_mcp_call(p_household uuid, p_tool text, p_request uuid, p_args jsonb, p_ok boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_member(p_household) then raise exception 'NOT_A_MEMBER'; end if;
  insert into public.mcp_audit (household_id, user_id, oauth_client_id, tool, request_id, args, ok)
  values (p_household, auth.uid(), auth.jwt() ->> 'client_id', p_tool, p_request,
          case when octet_length(p_args::text) <= 4096 then p_args else '{"truncated":true}'::jsonb end, p_ok);
end $$;

-- recipes: select where household_id is null or is_member(household_id); writes only to own household.
-- storage.objects (bucket 'receipts'): is_member(((storage.foldername(name))[1])::uuid).
-- user_settings: user_id = (select auth.uid()). mcp_audit: select for members only; inserts only via log_mcp_call; no update/delete.
-- ingredient_aliases, like the other reference tables, is select-only.
```

**Why this shape:**

- **Lots + movements instead of a `quantity` column.** This gives conflict-free concurrent edits (F14), a full history for consumption rates (§6.6) and waste in euros (`discard` movements × `unit_cost_cents`), and undo for free.
- **Products are household-scoped**, not a shared global table. Users can't poison each other's catalog. A shared catalog comes later as a separate read-only table loaded from the OFF export (§11).
- **Composite foreign keys `(x_id, household_id)`.** Even a buggy insert can't link your lot to someone else's product. RLS protects reads; these keys protect references.
- **`purchase_items.kind` + the sign check.** Discounts and refunds are first-class, so the sum invariant in §6.1 is exact.
- **`ingredient_aliases` + the parser's `ingredient_guess`.** Recipes match on canonical ingredients, not product names, so every way of creating a product (receipt, barcode, manual, Claude) resolves an ingredient when the product is created (§6.1, §6.2, §7.2).
- **`expiry_kind = 'estimate'` and `expires_on not null` on lots.** Every lot has a date and an alertable kind. `none` exists only on categories, and a check constraint allows it only where there is no shelf life (cleaning, toiletries), which never create lots.
- **The `state` column in the `pantry` view** is the single definition of usable, expired and unconfirmed. Recipes, the shopping list, the digest and Claude all read it, so they can't disagree about whether you still have something.
- **Printed quantity and base quantity are separate columns.** `printed_qty`/`printed_unit` record the ticket exactly. `quantity` is always in the product's base unit, and only `to_base_qty()` (§6.1 step 6) writes it. That keeps one conversion rule for receipts, scans, manual entry and Claude.
- **Staples are their own table, keyed by ingredient by default.** "Milk, 2 L" is satisfied by Hacendado, Carrefour or Supercor milk. You pin a staple to one product only when the brand matters to you.
- **Ticket numbers are written only at confirmation, and compared in normalised form.** The unique index covers confirmed trips only, so an abandoned draft can never block logging that ticket later. `ticket_norm` strips spaces, dashes and case, so the number read from a paper photo and the number on the e-ticket PDF match.
- **`time_source` and `confirmed_at` exist for duplicate detection.** A printed minute identifies a ticket almost as well as its number, and the moment you typed a quick total proves which later receipts can't be that trip (§6.1 step 3).
- **`products.expiry_kind` overrides the category.** Spanish labels decide use-by versus best-before per product, not per food type, so a correction you make once applies to every later lot of that product.
- **A product's base unit is frozen once it has history, and `unit_weight_g` bridges counted and weighed.** Loose fruit is counted when you scan or quick-add it and weighed on the ticket. The bridge is an explicit per-product number you confirm once, never a guessed density, and the trigger makes the dangerous alternative (reinterpreting old lots) impossible rather than merely discouraged.
- **`bought_at` / `reconciled_at` on list rows.** They record what you've bought but not logged yet, so the automatic refresh doesn't re-add it in the gap (§6.6).

---

## 6. How each feature works

### 6.1 Receipt photo (the main logging path)

1. **Capture.** You take 1–4 photos (long tickets in overlapping sections), or pick an image or PDF screenshot. If you activate Mercadona's emailed digital ticket (you register your card at the till and confirm over WhatsApp), you can also share that file. Each image is resized to ≤1568 px on the long edge (JPEG quality 0.8) and uploaded to `receipts/{household_id}/{purchase_id}/{n}.jpg`. A `draft` purchase is created with your own UUID. If the app is closed before you confirm, the next app open shows a banner: "Unfinished receipt: Mercadona, 2 Nov. Resume or discard?".
2. **Parse.** `parse-receipt` (called with your JWT) checks today's quota, sends the images to the Claude API with a system prompt and a JSON schema, and stores the output in `parse_output`. The schema:
   ```json
   { "chain": "mercadona|carrefour|supercor|other", "store_label": "string",
     "purchased_at": "YYYY-MM-DDTHH:MM (local time)", "ticket_number": "string|null",
     "lines": [{ "raw_text": "string", "name_guess": "string", "category_guess": "<category id>",
                 "ingredient_guess": "<ingredient id>|null",
                 "printed_qty": 2, "printed_unit": "pack|g|ml", "line_total_cents": 233,
                 "kind": "item|discount|refund" }],
     "total_cents": 4567,
     "candidate_matches": [{ "line_index": 0, "product_id": "uuid" }] }
   ```
   Prompt rules: amounts are integer cents, and Spanish decimal commas are converted (`2,33` → `233`). Counted items are packs as printed ("2 x LECHE SEMI" → `printed_qty: 2, printed_unit: "pack"`); the model never multiplies by pack size, because the server does that from the product record. Weighed lines (`1,234 kg x 1,89 €/kg`) become grams (`1234, "g"`). Multi-buy discounts ("2ª ud. 70%") become negative `discount` lines. Lines repeated across overlapping photos are output once. Card numbers and loyalty IDs are never output. The prompt lists the canonical category and ingredient IDs (about 1.5k tokens, sent with prompt caching), and `ingredient_guess` must be one of them, or null for non-food. The parsed ticket number stays in `parse_output` and is copied onto the purchase only at confirmation. If the trip already has scanned items, their product IDs and names are included so the model can match them (§6.3).
3. **Validate in code (not by the model).**
   - (a) `Σ line_total_cents = total_cents`. This catches missing, duplicated and misread lines, which are the dangerous errors.
   - (b) `purchased_at` is not in the future and is at most 90 days old.
   - (c) Every quantity is > 0.
   - (d) `chain` is a known ID.
   - (e) Every `category_guess` and `ingredient_guess` is in the canonical list. Anything else becomes null instead of failing the parse.
   - (f) **Duplicate classification.** The app calls `classify_duplicate(chain, purchased_at, time_source, total_cents, ticket_number, typed_at)`. The same SQL function runs again inside `confirm_purchase` and `log_purchase` (step 6, §7.2), so a check skipped or raced on the phone is still enforced. Two kinds of trip matter here:
     - A **receipt trip** has `time_source='printed'`: its minute (and usually its ticket number) was read from a ticket, by the parser or by Claude.
     - A **typed trip** has a total you typed and no ticket: a quick total, an unpacking session finished with a typed amount, or a Claude `log_purchase` without the ticket's printed minute. Its *typed moment* is its `confirmed_at`, or now for the trip being logged.

     The function compares the new trip N with every *confirmed* trip E of the same household and chain on the same Madrid date. Each pair gets the first rule below that matches. The result is the most severe verdict over all pairs (hard block, then question, then notice). **Every rule is symmetric.** It talks about "the typed trip" and "the receipt" of a pair, never about which one came first, so logging order can't change the verdict. **OCR-read fields can only add questions, never remove them.** A ticket number or printed minute can trigger a block or a question, but a difference in them is never enough on its own to add a trip silently.

     | # | Rule (for the pair N, E) | Verdict | What you see |
     |---|---|---|---|
     | C1 | both ticket numbers known, same `ticket_norm` | `same_ticket` (hard) | "Already logged on 2 Nov at 18:12. Open it?" No way to add it again. |
     | C2 | both receipts, same printed minute, same total | `same_receipt` (hard) | The same message. This catches a re-photographed faded ticket whose number couldn't be read, and an e-ticket whose number was read differently. "It's a different ticket" sits behind a second confirmation, because two tickets from one chain in the same minute with the same total are almost never real. |
     | C3 | same total (any kinds of trip) | `possible_duplicate` | "€45,60 at Mercadona on 2 Nov is already logged (receipt, 18:12). Same ticket?" "Same ticket: don't add" is preselected. When the pair carries evidence of being different (ticket numbers 3 or more characters apart, or a receipt printed more than 10 minutes after the other trip's typed moment), that evidence is shown next to the question and nothing is preselected. |
     | C4 | near match: both ticket numbers known and `levenshtein(N.ticket_norm, E.ticket_norm)` is 1 or 2; or both receipts with the same printed minute | `possible_duplicate` | "Ticket …128456 looks like …123456, logged at 18:12 for €45,60. Same ticket?" Nothing is preselected. One misread field can't add a trip silently. |
     | C5 | one of the pair is a typed trip, and the other is a typed trip, a receipt with no printed time, or a receipt printed no later than the typed moment + 10 minutes | `mergeable` | "You typed €46,00 at Mercadona today at 21:00. This ticket was printed at 18:12 for €45,60. Is it that trip?" Both totals and both times are shown. Nothing is preselected (the totals differ, otherwise C3 would have matched). The 10 minutes allow for a till clock that runs fast. |
     | C6 | none of the above, but an E exists | `new` + notice | The trip is added, with one line on the confirmation screen (and in Claude's tool result): "Also at Mercadona today: €30,00 typed at 10:15. Treated as separate because this ticket was printed at 19:40, after that total was typed. Same trip? Undo." The printed time shown is editable, so a misread time can be corrected on the spot, and the classification runs again. |
     | — | no E | `new` | Nothing. |

     **Why C6 is safe to add.** To reach C6 the totals must differ. If both trips are receipts, each total has passed the sum check against its own lines, the ticket numbers are 3 or more characters apart (or unknown), and the printed minutes differ, so several independently read facts disagree. If one trip is typed, the receipt was printed more than 10 minutes after the total was typed, which can't be that ticket unless the minute was misread. Even then the notice names both trips and offers undo, so the case is visible. The month-end bank check (§9) is the final backstop.

     **What "Yes, same trip" does** (`merge_into`, step 6). The kept trip always takes the most authoritative data, which is a receipt's total, lines, printed time and ticket number when either side has them.
     - *Receipt N, typed E* (you typed first): the receipt merges into E, as below in step 6. If E is a finished unpacking session with scanned lots, they are passed to the parser as candidates exactly as in §6.3, so matched lines link to those lots and no item is stocked twice.
     - *Typed N, receipt E* (receipt first): nothing new is counted. A quick total is simply not created (its draft becomes `void`). An unpacking session's scanned lots move onto E. A scanned lot whose product matches an E line takes over that line's link. The lot E created for that line, if it still has nothing but its purchase movement, is zeroed with one `adjust` movement, so the food is stocked once and the scanned lot (which may carry a printed date) is the one kept. Unmatched scanned lots just get `purchase_id = E`.
     - *Typed and typed:* the earlier trip is kept. You pick which total is right (both are shown, the newer one preselected). Any per-item price lines from both are kept, and the adjustment line is recomputed so the lines still add up to the total.
     - *Receipt and receipt* (a "same ticket" answer to C3 or C4): N is not added and its draft becomes `void`.

     "It's a different trip" passes `force_new` and creates the trip.

     **Worked checks** (each one is a SQL test in step 1, all at Mercadona on one day):
     1. A crumpled ticket, number unreadable, printed 18:12, €45,60, photographed twice: C2, blocked.
     2. The same ticket logged in the app (number "2304-011-123456") and later shared with Claude as the e-ticket, whose number Claude passes as "2304011123456": C1 on the normalised number. If Claude omits the number: C2 on 18:12 + €45,60. If Claude also omits the time: C3, so `log_purchase` returns `POSSIBLE_DUPLICATE` and Claude must ask.
     3. **Typed after its receipt:** you photograph the ticket (printed 18:12, €45,60, number unreadable), then that evening type, or tell Claude, "about €46 at Mercadona today" at 21:00. That is C5 (typed at 21:00, printed 18:12 ≤ 21:10), so you get a question. In the opposite order (€46 typed at 18:20, ticket photographed later) the verdict is C5 again (18:12 ≤ 18:30). The verdict is the same whichever was logged first.
     4. **Misread ticket number:** a faded Carrefour ticket parsed as "2304011123456", 18:12, €45,60; the same paper later shared with Claude, read as "2304011128456" with no printed time. That is C3 (same total). The numbers are 1 character apart, so "same ticket" is preselected. Had the totals also differed, C4 (Levenshtein distance 1) would still ask.
     5. Two real €45,60 runs: a quick total typed at 10:15, then a ticket printed at 19:40. That is C3 with the evidence "printed 9 h after you typed €45,60" and nothing preselected. You tap "different", and the month shows €91,20. Identical totals to the cent are rare, so this question is rare.
     6. The morning trip's total is typed only at 23:00, after the 19:40 evening ticket, and both are €45,60: C3 with "same ticket" preselected, because no evidence says otherwise.
     7. Two real trips with different totals: €30,00 typed at 10:15, and a ticket printed at 19:40 for €45,60. That is C6: added with the notice, and the month shows €75,60.
     8. **Misread minute:** €46,00 typed at 18:30, then a ticket really printed at 18:12 for €45,60 but read as 19:12. That is C6, and the notice says "printed 19:12, after the €46,00 you typed at 18:30" right next to the editable time. Correcting it to 18:12 turns the verdict into C5 (a question). The mistake is visible, not silent.

   If (a) fails on the small model, retry once with the larger model. If it still fails, the review screen shows "Lines add up to €43,12, ticket says €45,67: €2,55 missing" and highlights low-confidence lines.
4. **Match products.** For each line:
   - (i) an exact alias `(household, chain, normalised raw_text)` gives an automatic match;
   - (ii) otherwise a trigram similarity ≥ 0.6 against aliases and product names becomes a suggestion;
   - (iii) otherwise the app offers "new product", prefilled from `name_guess`, `category_guess` and an ingredient resolved in this order: the model's `ingredient_guess`; else the best `ingredient_aliases` trigram match ≥ 0.5 on the normalised raw text and name guess; else none.
   - (iv) a matched product that still has no `ingredient_id` gets the same resolution, shown as a proposal.
5. **Review screen.** Matched lines are collapsed into one summary row ("18 items matched ✓"). Unmatched or uncertain lines are expanded. Non-food categories (cleaning, toiletries) count towards spending but don't create pantry lots. Each new food product shows its category and ingredient as two tappable chips (e.g. *Carne fresca* · *pechuga de pollo*). A food line with no ingredient shows an amber "set ingredient" chip. Any line can be marked "spend only": it keeps its category for the budget but gets no product and no lot.
6. **`confirm_purchase(purchase_id, accept_difference boolean, merge_into uuid default null, force_new boolean default false)`.** One SQL transaction, used for receipts, quick totals, finished unpacking sessions and Claude's `log_purchase` alike:
   - It takes a transaction-scoped advisory lock on (household, chain, Madrid date), `pg_advisory_xact_lock(hashtextextended(household_id || chain_id || local_date, 0))`, so two confirmations for the same chain and day (the app and Claude at once, or a double tap) run one after the other and the second one sees the first.
   - It locks the purchase row, which must be a `draft`. Without `merge_into`, it runs `classify_duplicate` and raises `ALREADY_LOGGED` on `same_ticket`, `ALREADY_LOGGED` on `same_receipt` unless `force_new` is passed, and `POSSIBLE_DUPLICATE` on `possible_duplicate` or `mergeable` unless `force_new` is passed (the app passes `force_new` only after you tap "It's a different trip"). On `new` with a same-day trip it returns the C6 notice text. With `merge_into`, it also locks that purchase, which must be a confirmed trip of the same household, chain and Madrid date for which `classify_duplicate` returns C3, C4 or C5. It then applies the matching case of "What 'Yes, same trip' does" (step 3f). The case spelled out here is the most involved one, a receipt draft merging into a typed trip. The receipt's lines replace any typed lines and adjustment line on that trip. A lot that pointed at a replaced line is re-linked to the receipt line matched to it, or else keeps only its `purchase_id`. The merge never removes or duplicates an existing lot; receipt lines that match no lot create lots as usual. From here on that trip is the one being confirmed. The total check below uses the receipt's parsed total, which then replaces the typed one, and the trip takes the receipt's printed time (`time_source='printed'`), so it is no longer a typed trip and can't be merged into twice. The draft becomes `void`, and its images move to the kept trip.
   - **Quantity conversion.** For every line with a product it sets `quantity = to_base_qty(product, printed_qty, printed_unit)`:
     - printed unit equals the product's base unit (`g`→`g`, `ml`→`ml`): unchanged;
     - `pack`: `printed_qty × pack_size`, where a `unit` product with no pack size counts as 1 per pack;
     - `pack` on a `g`/`ml` product with no `pack_size`: raises `NEEDS_PACK_SIZE`. The review screen asks "How much is one pack? (e.g. 1 L)" and saves the answer on the product, so it is asked once per product;
     - `g` on a `unit` product that has `unit_weight_g`: `max(1, round(printed_qty / unit_weight_g))` items. "PLATANO 0,826 kg" on "Plátanos" with `unit_weight_g = 120` gives **7** (826 / 120 = 6.88). The line keeps its printed 826 g, so price history still shows €/kg;
     - `g` on a `unit` product without `unit_weight_g`, `g` against `ml`, or `unit` against `g`/`ml`: raises `UNIT_MISMATCH`. Densities are never guessed. The review screen offers exactly three fixes, none of which reinterprets existing stock:
       1. **"Count it: about how much does one weigh?"** (only for a `unit` product and a weighed line). The field is prefilled from the ingredient's `typical_unit_g` (banana 120 g) and must be confirmed. The answer is saved as `products.unit_weight_g`, so every later weighed line of that product converts on its own.
       2. **"Track as a separate weighed product."** This creates "Plátanos (a granel)" with `unit='g'`, the same category and ingredient, and points this chain's alias at it. Recipes and ingredient-level staples still see both products, because they share the ingredient.
       3. **"Spend only."** The money is counted and no lot is created.

       Switching the base unit of the existing product is not offered. The `products_unit_frozen` trigger (§5) rejects it once the product has lots, quantified lines or a staple, because 6 bananas would silently become 6 g. A product with no history yet can still change unit freely, which is how a mistake on a brand-new product is fixed.

     Example: "2 x LECHE SEMI HACEND" (`2, pack`) matched to a product with `unit='ml', pack_size=1000` gives a lot of **2000 ml**. Barcode-created products take `unit` and `pack_size` from Open Food Facts' `product_quantity` and `product_quantity_unit` (always g or ml) when present. Otherwise the new-product form asks for the size.
   - If it has lines and `Σ ≠ total`: with `accept_difference` it inserts an `adjustment` line for the difference and sets `verification='adjusted'`; otherwise it raises `SUM_MISMATCH`. With no lines, it sets `verification='total_only'`.
   - It copies the parsed ticket number onto the purchase. If that violates the unique index, it raises `ALREADY_LOGGED` with the date of the existing trip.
   - For every `item` line that has a `product_id`, belongs to a category whose `shelf_life_days` is not null, and is not already linked to a lot, it creates a lot (with `purchase_id` set). Lines without a product are spend only. `expires_on` is the purchase date in Madrid time + `coalesce(product.shelf_life_days, category.shelf_life_days)`, `expiry_kind = coalesce(product.expiry_kind, category.expiry_kind)`, `expiry_source='default'`, `unit_cost_cents = line_total / quantity` (per base unit), and a `+quantity` purchase movement is added.
   - It upserts `receipt_aliases` (hits + 1) for every line with a product.
   - It sets `status='confirmed'` and `confirmed_at = now()`.
   - It sets `reconciled_at = now()` on every `bought` shopping-list row whose stock key appears on one of the trip's lines, then calls `refresh_shopping_list` (§6.6) in the same transaction, so the list reflects the new stock the moment the trip is confirmed.
7. **"Check dates" sheet.** Only lots whose category has `ask_printed_date`, or whose product's kind isn't confirmed yet (`products.kind_confirmed = false`) in a category with a shelf life of 60 days or less, are shown. So each new chilled product is asked about once, and pasta or tins never are. Each row has a date wheel prefilled with the default and a two-way toggle, **Caducidad / Consumir pref.**, prefilled with the product's kind, because the label prints one of those two words right next to the date. One tap accepts both; changing the date sets `expiry_source='printed'`. Changing the toggle sets this lot's `expiry_kind` and saves it on the product (`products.expiry_kind`), so the next lot of that product is right without asking. The same toggle is on every pantry item's screen, and Claude can set it with `update_product` or `update_lot`. Accepting or changing the toggle sets `kind_confirmed = true`. This typically takes about 10 seconds per trip, and less as products accumulate confirmed kinds.
8. **Retention.** The Cloudflare scheduler Worker calls the `retention` Edge Function once a night (03:00 Madrid, with the cron secret). It (a) deletes receipt images 30 days after confirmation (configurable) and keeps the structured lines, and (b) sets drafts older than 7 days to `void` and deletes their images and `parse_output`, **but only drafts that hold no pantry lots** (abandoned receipt photos). A draft with lots is an unpacking session holding real food, so it is never voided by the job (§6.3). Voiding never touches lots in any case. Files are deleted through the Storage API, because deleting rows from `storage.objects` in SQL would leave the files behind. Ticket numbers are only written at confirmation, so an abandoned or voided draft can never block re-logging the same ticket.

**Cost per receipt** at current list prices, assuming about 4.5k input tokens for a one-photo ticket (image, prompt and ID lists) and 1.5k output tokens: about $0.001 with Claude Haiku 5.5 ($0.10/$0.50 per million tokens) and about $0.02 with Claude Sonnet 5.5 ($2/$10). Ten trips a month cost cents.

### 6.2 Barcode scan

- `expo-camera` `CameraView` with `barcodeTypes: ['ean13','ean8','upc_a','upc_e']`. Each read is checked against the GS1 mod-10 check digit, and the same code is ignored for 2 seconds so one item isn't counted twice.
- **Prefix 20–29** (an in-store or variable-weight label): no lookup. The app shows "Weighed/deli item: pick product" with recent fresh products first.
- **Known GTIN in your `products`:** the lot is added with default expiry and location (one tap, or a continuous-scan mode for unpacking).
- **Unknown GTIN:** the item is added immediately as "Looking up…". The OFF request (`GET https://world.openfoodfacts.org/api/v2/product/{code}.json`) goes into an on-device queue limited to 12 per minute that persists across app restarts. On a hit, the name and brand fill in, and the base unit and pack size come from `product_quantity` + `product_quantity_unit` (g or ml; a 1 L carton gives `ml`, 1000). If OFF has no size, the form asks for it, with "sold by the unit" as a one-tap option. A scan always adds **one pack** (`to_base_qty(product, 1, 'pack')`), and a stepper adjusts the number of packs. The category and ingredient are suggested from OFF's `categories_tags`, most specific tag first, through `ingredient_aliases` (kind `off_tag`), falling back to a trigram match on the product name. You confirm both the first time. On a miss you type a name and choose a category; the ingredient chip is prefilled from the name in the same way, and the product is saved for next time.
- Scanning is for items without a receipt (gifts, a flatmate's shopping, corner-shop buys) and for pinning a product's identity the first time. It is optional for regular trips, because the receipt alone is enough.

### 6.3 Manual entry, and scan + receipt on the same trip

- **Quick total:** chain + amount + date. This creates a confirmed purchase with `verification='total_only'`, `time_source='entered'` and `confirmed_at` = the moment you saved it, so the budget stays correct even on lazy days. If you photograph that ticket later, §6.1 step 3(f) asks whether it is this trip instead of counting it twice. The same question appears if you type a quick total *after* already photographing that day's ticket, because the classifier is symmetric. A ticket with a different total printed more than 10 minutes after you saved the quick total is added as a separate trip, with a notice naming the quick total.
- **Quick add item:** autocomplete over your products (trigram search), quantity and location. Creating a new product here shows the same category and ingredient chips.
- **Unpacking session (barcode logging of a whole trip):** "Start unpacking: Carrefour, today" creates a draft trip, and every scan adds a lot with `purchase_id` set to that trip. Lots are real stock from the first scan, so the pantry, alerts and recipes see them at once. Each scanned row shows an optional price field, prefilled with the last price you paid for that product at that chain. The session **ends only through "Finish trip"**, which offers three ways to record the spend:
  1. **Add the receipt photo.** Parsing receives the scanned products as candidates. Matched lines link to the existing lot (`purchase_item_id` set, no second lot). Unmatched lines create lots as usual. The trip is verified by the sum check like any receipt.
  2. **Type the amount charged.** If the receipt is lost, the card payment in your bank app shows the exact total. This confirms the trip (`verification='total_only'` if no item has a price, `'adjusted'` otherwise). Any per-item prices you entered become lines, and the gap to the total becomes an `adjustment` line ("Unclassified" in breakdowns), so the trip total is exact and counted once.
  3. **Prices on every item.** If you filled in every price, they become the lines, and their sum is offered as the total, which you confirm.

  A session left unfinished is never voided by the cleanup job and never loses its lots. After 2 days it appears at the top of the digest and the Budget screen ("Carrefour trip from 2 Nov has no total: finish it"), and until it is finished the Budget screen shows "1 trip without a total". "Discard trip" asks "Keep the 15 items in your pantry?" (default yes). Kept lots stay as stock with `purchase_id` cleared, and the trip becomes `void`.

### 6.4 Pantry, expiry and alerts

**Effective expiry** (computed in the `pantry` view):

- frozen: `frozen_on + freezer_life_days`
- opened: `min(printed or default date, opened_on + opened_shelf_life_days)`
- otherwise: the lot date

**Lot states** (the `state` column of the `pantry` view, evaluated on day `t` in Madrid time, with `e = effective_expires_on`):

| State | Condition | Recipes and shopping-list stock | Digest |
|---|---|---|---|
| `ok` | `qty_left > 0` and `t ≤ e` | counted | "Today" / "Next 3 days" when inside the lead window |
| `check` | best-before or estimate, `e < t ≤ max(e, checked_on) + check_grace_days` | counted, flagged "check it first" | "Check it", only during the grace window |
| `expired` | use-by and `t > e` | **never counted** | "Expired: bin it" for the first 3 days after `e`, then only in the app's "Unconfirmed" filter |
| `unconfirmed` | best-before or estimate, past the grace window | **not counted** | asked once, "Still have these?", on the first day of this state |
| `finished` | `qty_left ≤ 0` | not counted | never |

"Still have it?" has three one-tap answers. **Yes** sets `checked_on = t`, which restarts the grace window. **Finished** and **Threw away** append the matching movement. The app never auto-discards: an unanswered lot just stops counting, so an item you ate without tapping "Finished" can't distort recipes or the shopping list for more than its grace window.

The default seed table below lists conservative starting values, not food-safety advice. They are editable per product, and a printed date always wins. The *kind* is a default too: the label decides. Since Spain's 2014 yogurt standard (Real Decreto 271/2014), most yogurts carry *consumir preferentemente* rather than *caducidad*, so yogurt has its own best-before category; a yogurt whose label says *caducidad* is switched with the toggle once and stays switched (§6.1 step 7). A product switched to best-before inside a use-by category gets the view's default grace of 2 days. `estimate` means there is no printed date (loose produce, unpackaged bread), so the date is the app's guess. It is alerted like best-before, but worded "use soon, check it".

| Category | Location | Default days | Opened days | Kind | Ask printed date | Check grace days |
|---|---|---|---|---|---|---|
| Fresh meat & poultry | fridge | 2 (mince 1) | — | use_by | yes | — |
| Fresh fish | fridge | 1 | — | use_by | yes | — |
| Cold cuts (sliced) | fridge | 14 | 4 | use_by | yes | — |
| Chilled fresh dairy (fresh pasteurised milk, fresh cheese, cream) | fridge | 7 | 3 | use_by | yes | — |
| Yogurt & fermented milks | fridge | 21 | 2 | best_before | no | 7 |
| UHT milk, plant drinks | pantry | 90 | 4 (fridge) | best_before | no | 30 |
| Eggs | fridge | 21 | — | best_before | no | 3 |
| Bagged salad | fridge | 4 | 1 | use_by | yes | — |
| Fruit & veg, perishable (leafy greens, berries, mushrooms) | fridge | 4 | — | estimate | no | 2 |
| Fruit & veg, counter (bananas, tomatoes, citrus, apples) | pantry | 6 | — | estimate | no | 3 |
| Potatoes, onions, garlic | pantry | 21 | — | estimate | no | 7 |
| Bread (barra, unpackaged) | pantry | 2 | — | estimate | no | 1 |
| Dry goods (pasta, rice, pulses) | pantry | 365 | 180 | best_before | no | 180 |
| Tins & jars | pantry | 730 | 4 (fridge) | best_before | no | 365 |
| Frozen | freezer | 180 | — | best_before | no | 90 |
| Cleaning, toiletries | pantry | — | — | none (no lots) | no | — |

**Alert rule.** A lot appears in the digest on day `d` if its state is `ok` and:

- `use_by` and `d ≥ e − use_by_lead_days` (default 2), or
- `best_before` or `estimate`, and `d ≥ e − best_before_lead_days` (default 3).

It also appears in the `check`, `expired` and `unconfirmed` groups as the table above says. Every lot is one of the three alertable kinds (§5), so no perishable item can drop out of the digest. Every group is bounded in time, so no item repeats in the digest forever.

The digest groups lots into **Expired: bin it** (one-tap bulk "discard"), **Check it**, **Today**, **Next 3 days** and **Still have these?**. It also carries the budget alerts (§6.7) and any unpacking trip without a total (§6.3). The rule is one pure TypeScript function, `buildDigest(pantryRows, settings, day)` in `packages/shared`. The app and the server both use it, so the two channels can't disagree.

**Delivery: two independent channels from the MVP onwards.**

1. **Server email digest (always current).** The Cloudflare scheduler Worker calls `daily-digest` every hour, at minute 5, with the cron secret. For each user whose local `digest_time` falls in that hour, whose `last_digest_on` is before today and who has `email_digest` on, it first runs `refresh_shopping_list` for that household (the date-driven rules, §6.6), then reads that household's `pantry` rows with an explicit `household_id` filter (it runs with the service key, so this filter is covered by a test), builds the digest and sends it through Resend if it is not empty. It then sets `last_digest_on`, so a retried run never sends twice. Because it reads the database, it includes lots that Claude created a minute ago, and it keeps arriving if you don't open the app for weeks.

   **Why it keeps arriving on the free tier.** Supabase pauses a free project after a 7-day window of low activity, and a paused project runs nothing, so the schedule can't live inside Supabase. The Worker runs on Cloudflare whatever Supabase's state, and its 24 calls a day are inbound API requests that read the database; Supabase's documentation counts API calls as activity and says a few requests a day is typically enough. If a call fails anyway (paused project, outage, expired secret, a bad deploy; failure means a non-2xx answer or no answer within 20 seconds), the Worker retries once after 30 seconds, and if the call in the watchdog hour still fails, it sends you one email straight through Resend. The watchdog hour is a Worker setting (`WATCHDOG_HOUR=9`, Madrid time, matching your digest time), because a Worker facing a dead backend can't read your settings from it. Only that hour's call can trigger the email, so it is sent at most once per Madrid day and needs no stored state: "Your grocery backend isn't responding, so today's expiry digest wasn't built. If Supabase paused it: Dashboard → project → Resume." A resumed project comes back with all its data (restorable for up to a year). So the failure is never silent, which a digest scheduled with pg_cron could not promise. The Worker's watchdog email is tested in step 6.
2. **Local notifications (instant, offline).** After every app foreground, every successful sync and every local mutation, the app cancels all scheduled notifications. It then computes the digest for each of the next 7 days at `digest_time` from the cached pantry and schedules only non-empty days. That is at most 7 of iOS's 64 slots, regardless of pantry size. If the app isn't opened, these run out after 7 days and may miss Claude's additions. The email covers both gaps.
3. **At the moment of logging.** Every Claude write tool returns `due_soon`: the lots it created or changed that are already inside the alert window. The tool description tells Claude to mention them ("the chicken is use-by Tuesday"). The app's confirmation screens show the same list.

From step 7 (TestFlight, paid Apple account), `daily-digest` also sends **Expo Push** to `expo_push_token`, and the email becomes an optional backup.

Worked check (the case this design must catch): on Sunday you ask Claude to log a Mercadona e-ticket with chicken that is use-by Tuesday, and you don't open the app until Wednesday. `log_purchase` returns `due_soon: [chicken, use-by Tue]` and Claude tells you in the chat. Monday's and Tuesday's server emails list the chicken under "Next 3 days" and "Today". Wednesday's lists it under "Expired: bin it". Second worked check (abandonment): you don't open the app for three weeks. The Worker has still called `daily-digest` 504 times, the project has had API activity every hour and doesn't pause, and every morning's email still arrives. If Supabase paused it regardless, the first morning without a digest brings the "backend isn't responding" email instead.

### 6.5 Recipe suggestions (soonest-expiring first)

Run `suggest_recipes(max_missing = 2, lim = 10)` on date `t`, in household time:

- **Available ingredients A**: `ingredient_id` of usable lots (state `ok` or `check`, §6.4). Past-use-by lots are therefore excluded (food safety, F9), and so are best-before or estimate lots past their grace window, which are probably gone. A lot whose product has no `ingredient_id` can't contribute, so the Recipes screen shows "3 items aren't linked to an ingredient" with a one-tap picker. `get_overview` reports the same count to Claude, which can fix the links with `update_product`.
- **Urgency of ingredient i**, with `d = max(0, effective_expires_on − t)` for its most urgent usable lot: `u(i) = 1 / (1 + d)` if `d ≤ 7` (the *urgent window*, a setting), else **0**. Today is 1, tomorrow 0.5, in 3 days 0.25, in a week 0.125, and 8 or more days away is 0. A lot in state `check` (past its best-before or estimate date, still inside the grace window) gets 1 and is flagged "check first". After the grace window it is no longer usable and contributes nothing, so it can't hold the top spot.
- For recipe r, let `R` be its non-optional, non-basic ingredients, `M = R ∩ A` and `X = R \ A`.
- **Eligible** if `|M| ≥ 1` and `|X| ≤ max_missing`.
- **Rescue value** `V(r) = Σ_{i∈M} u(i)`: how much soon-expiring food the recipe uses up.
- **Ranking is lexicographic, not a weighted sum:** sort by `V(r)` descending, then `|X|` ascending (fewer things to buy), then coverage `|M|/|R|` descending, then `minutes` ascending.

**Why lexicographic.** A weighted sum such as `10·Σu + 3·coverage − 2·|X|`, with a small floor for long-life items, lets a long recipe pile up points from food that isn't going off. A 7-ingredient lentil stew of long-life items (7 × 0.05 × 10 = 3.5, plus 3 for coverage) would beat a 2-ingredient chicken dish with chicken use-by in 3 days (10 × (0.25 + 0.05) + 3 = 6.0 < 6.5). With zero urgency outside the window and `V` compared first, **every recipe that uses something expiring within 7 days ranks above every recipe that uses nothing expiring, whatever its length or coverage.** Among rescue recipes, the one that uses more, and sooner-expiring, food comes first. Missing ingredients and coverage only order recipes that rescue equally. Each result carries a `rank_reason` ("uses chicken, use-by in 3 days"), so the order is explainable in the app and to Claude. A filter chip, "Only what I can cook now", hides recipes with `|X| > 0`.

Worked checks (each one is a SQL test in step 10):

1. Chicken expiring today, spinach tomorrow and rice (best before in 11 months) on hand. "Pollo con espinacas y arroz" has `V` = 1 + 0.5 + 0 = **1.5**. A pasta-with-tomato recipe using only long-life items has `V` = **0**. The chicken dish ranks first.
2. **Long pantry recipe versus a short rescue recipe.** Chicken is use-by in 3 days (`u` = 0.25), and garlic, onions, potatoes, lentils, tinned tomato, pimentón and bay leaf are all 19 or more days away (`u` = 0). "Pollo al ajillo" {chicken, garlic} has `V` = **0.25**. "Lentejas estofadas" (7 ingredients, all in stock) has `V` = **0**. Pollo al ajillo ranks first. That holds with 8 or 20 long-life ingredients too, because they add nothing to `V`.
3. Two recipes that both use only the chicken (`V` = 0.25): one with nothing missing, one missing an onion. The one with nothing missing ranks first.
4. **Stale data:** loose tomatoes (estimate, 6 days, grace 3) logged on 1 Oct and eaten without a "Finished" tap, and chicken use-by tomorrow, on 3 Nov. The tomatoes' date was 7 Oct and their grace ended on 10 Oct, so on 3 Nov they are `unconfirmed` and not in A. "Ensalada de tomate" has `|M| = 0` and is not eligible. "Pollo a la plancha" has `V` = 0.5 and ranks first. The tomatoes were asked about once, in the 11 Oct digest.

Each result returns the matched lots (with days left), the missing ingredients, and an "add missing to shopping list" action. The **library** starts with about 60 seeded Spanish student staples (tortilla, lentejas, arroz con pollo, pasta dishes, salads, and so on). Generate it once with Claude into SQL seed rows and review it. **Claude adds the creativity:** through the connector, it reads `get_overview` + `suggest_recipes`, improvises beyond the library, and can `save_recipe`, so good ideas become part of the deterministic library.

### 6.6 Automatic shopping list

The list is maintained by one SQL function, `refresh_shopping_list(household, horizon_days = 7)`. Nobody has to remember to run it.

**When it runs.**

1. **After every write that changes what you have or plan.** It runs at the end of `confirm_purchase`, `consume` (Finished, Threw away, Claude's `record_consumption`), `add_pantry_items`, `update_lot` (dates, opened or frozen, "Still have it?" answers), `set_staple`, recipe "plan" and "unplan", and `undo`. It runs in the same transaction, under a per-household advisory lock, so a refresh from the app and one from Claude never interleave. These are the only write paths for stock (§3 rule 2), so no change can bypass it.
2. **Every morning**, from `daily-digest` (Cloudflare scheduler), before the digest is built. "Runs out soon" and "usual purchase" depend on the date as well as on stock, so they can become true on a day when nothing is logged. The digest says "2 items added to your list".
3. **When the List tab opens with a connection**, as one RPC. Offline, the tab shows the cached list, which was current at the last sync because every sync follows a refresh.

Claude's `generate_shopping_list` tool calls the same function, but the list is already current without it. For one household with a few hundred lots, a refresh is a handful of indexed queries.

**Idempotent and self-cleaning.** Every candidate is upserted into the single open row for its stock key (reasons merged, quantity = max). An open row whose reasons are all automatic (`below_par`, `runs_out_soon`, `usual_purchase`) and that is no longer a candidate is set to `resolved`. One example is milk that is back above par because a flatmate's carton was quick-added. Rows with a `manual`, `claude` or `recipe:` reason are never closed by the refresh; you or Claude close them. Running the refresh twice gives the same list.

**Stock key.** All rules group products by what you actually need, not by brand or chain:

- `p:<product_id>` if a staple is pinned to that exact product;
- otherwise `i:<ingredient_id>` if the product has an ingredient (Hacendado, Carrefour and Supercor semi-skimmed milk all map to `milk`);
- otherwise `p:<product_id>` (non-food items such as detergent, and food not yet linked).

`on_hand(k)` = Σ `qty_left` of the usable lots (state `ok` or `check`, §6.4) of every product with key `k`, in the staple's base unit. A `unit` product with a confirmed `unit_weight_g` converts to and from `g` (7 bananas at 120 g count as 840 g). Any other product whose base unit differs from the staple's (eggs counted in `unit` against a staple in `g`, with no item weight) is not added in. The staple screen lists it as "not counted: different unit", with a one-tap fix. A carton past its use-by date, or one past its grace window, doesn't count as milk you have.

0. **In transit (checked first).** A key is *in transit* if it has a `bought` row with `reconciled_at` null and `bought_at` within the last 3 days. That covers food you ticked off in the shop but haven't logged yet. Rules 1–3 skip keys in transit, so the milk you just bought isn't re-added in the gap between shopping and logging the receipt. Confirming a purchase whose lines include that key sets `reconciled_at` (§6.1 step 6), and from then on the real lots count. If no receipt arrives within 3 days, the suppression lapses and the item returns, with "bought on Fri, no receipt logged" in its reason and in the digest, because the app can't know you still have it.
1. **Below par** (rows of `staples`): if `on_hand(k) < par_qty`, add `par_qty − on_hand(k)`, rounded up to whole packs of the suggested product. Reason: `below_par`.
2. **Runs out soon** (staple keys, and keys with ≥2 `consume` movements in 60 days): `rate(k) = base units consumed in the last 60 days / 60`. If `on_hand(k) / rate(k) < horizon_days`, add `rate × horizon_days − on_hand`, rounded up to whole packs. Reason: `runs_out_soon`.
3. **Usual purchase** (works even if you never log consumption): for keys bought on ≥3 separate trips in 120 days (a trip counts if *any* product with that key is on it), `next_expected = last purchase + median gap between purchases`. If `next_expected ≤ t + horizon_days` and `on_hand(k) = 0`, add 1 pack. Reason: `usual_purchase`. Non-food items have no lots, so for them only the purchase cadence applies.
4. **Planned recipes:** missing ingredients of recipes you tapped "plan" (key `i:<ingredient>`). Reason: `recipe:<id>`.
5. **Manual or Claude adds:** reason `manual` / `claude`.
6. **Never add** items with `snoozed_until > t`, keys in transit (rule 0), or a key with an open row already present (it is merged instead).

Worked check (cross-chain): staple `milk`, par 2000 ml. Last week you bought 2 × "Leche semidesnatada Hacendado 1 L" and this week 2 × "Carrefour semidesnatada 1 L". Both products map to `milk`, `unit='ml'`, `pack_size=1000`. After drinking the Hacendado cartons, `on_hand(i:milk)` = 2000 ml (the Carrefour lots), which is not below par, so nothing is added. The usual-purchase rule sees one `milk` key bought weekly with a usable lot, so it adds nothing either.

Each ingredient-level row shows a **suggested product and chain**: the product with that key you bought most often in the last 90 days, the chain where you bought it most often, and the last price you paid there. Checking items off works offline. "Done shopping" marks checked items `bought` with `bought_at`, which puts them in transit (rule 0). It also offers **"Stock them now?"**, which opens an unpacking trip for that chain and today with the ticked items as lots (each row's suggested product, editable). The receipt you photograph later then links to those lots exactly as in §6.3, so nothing is stocked twice, and the trip needs a total before it can be finished (F29).

Worked check (the automatic path, milk staple, par 2000 ml):

| When | What happens | List |
|---|---|---|
| Thu 21:00 | You tap "Finished" on the last carton. `consume` ends with a refresh: `on_hand(milk)` = 0 < 2000. | "Leche semidesnatada ×2: below par" appears at once, with no button pressed. |
| Fri 18:00 | You open the List tab in the shop (it is cached, so this works offline), tick milk, and tap "Done shopping". | The milk row is `bought` and in transit. |
| Fri 22:00 | Claude logs a yogurt you were given (`add_pantry_items`), which triggers a refresh. | Milk is in transit, so it is **not** re-added. |
| Sat 09:00 | The morning refresh runs. | Still in transit, not re-added. |
| Sat 13:00 | You photograph the receipt. `confirm_purchase` creates 2000 ml of lots, reconciles the milk row and refreshes. | `on_hand` = 2000 = par: nothing added. |
| (variant) Tue 09:00 | The receipt was never logged. The transit window ended Mon 18:00, so the next refresh (opening the List tab after that, or Tuesday's morning run) re-evaluates milk. | Milk returns: "bought Fri, no receipt logged". |

### 6.7 Budget and spending

- **Spent in month m** = Σ `total_cents` of `confirmed` purchases where `(purchased_at at time zone tz)` falls in m. Budget = `budgets` row for m, or `households.monthly_budget_cents`.
- **Hard alerts (facts only):** when money actually spent this month reaches 80% and 100% of the budget. These use no forecasting, so they can't be wrong.
- **Projection.** Grocery spending comes in lumps: a weekly shop buys food for the following week. Dividing spend so far by days elapsed therefore overshoots right after every shop. €100 spent by day 8 extrapolates to €375 for a shopper who spends €200 a month. The projection instead assumes the last shop covers you until your usual next shop, and uses a run rate measured between trips:
  - **Shopping days.** Take the confirmed trips of the last 90 days and group them by Madrid date. A Mercadona run and a Carrefour run on the same day form one shopping day whose total is their sum. Call them `S1 … Sk` in date order. All of the arithmetic below uses shopping days, so two trips on one day can never produce a zero or one-day gap.
  - **Minimum history:** `k ≥ 3` **and** `date(Sk) − date(S1) ≥ 14` days. Until both hold there is no projection. The screen shows "Projection from <date>: needs 3 shopping days over 2 weeks", and only the hard alerts apply. The second condition bounds the denominator below: `r` is never divided by fewer than 14 days, so a burst of early shopping can't be extrapolated as a daily rate.
  - **Run rate** `r = (Σ totals of S1 … Sk−1) / (date(Sk) − date(S1))` in € per day. Each shopping day's spend is divided by the time until the next one. The latest shopping day isn't counted, because its food hasn't been eaten yet.
  - **Gap** `g = median of the day gaps between consecutive shopping days` (each gap is at least 1 by construction), clamped to 3–14 days.
  - **Next need** `N = date(Sk) + g`, the day the current food is expected to run out.
  - **Uncovered days** `U = max(0, month_end − max(today, N) + 1)`: the days left in the month that no shop has paid for yet.
  - **Projected month spend** `P = spent + r × U`.
- **Projection alert:** when `P > budget + max(5% of budget, half the median shopping-day total)`. The tolerance stops an alert caused only by whether the next shop falls on the 30th or on the 1st.

  Worked check: €200 budget, 30-day month, €50 shops every 7 days, including the previous months, on days 1, 8, 15 and 22 of this one. Over the last 90 days that gives 13 shopping days, so `r` = 12 × €50 / 84 days = €7.14/day, `g` = 7, and tolerance = max(€10, €25) = €25.

  | Day | Spent | Last trip | N | U | P |
  |---|---|---|---|---|---|
  | 1 | 50 | 1 | 8 | 23 | 214 |
  | 7 | 50 | 1 | 8 | 23 | 214 |
  | 8 | 100 | 8 | 15 | 16 | 214 |
  | 15 | 150 | 15 | 22 | 9 | 214 |
  | 22 | 200 | 22 | 29 | 2 | 214 |
  | 28 | 200 | 22 | 29 | 2 | 214 |

  The projection is flat at €214 all month instead of swinging between €214 and €375. €214 is your true rate: €50 a week is €214 per 30 days. In a 30-day month a weekly shopper usually shops five times, so a month that totals exactly €200 is one where the shop due on day 29 slips to the 1st. The projection can't know that in advance, and the tolerance exists for exactly this case: €214 is under the €225 alert line, so you get no false alarm. A shopper spending €60 a week gets `P` ≈ €257, over €225, and is alerted from day 1.

  Second worked check (the first weeks of use, several chains on one day). Budget €250, 30-day month, no earlier history. You spend €30 at Mercadona and €15 at Carrefour on 1 Nov, and €10 at Supercor on 2 Nov. These form 2 shopping days (€45 and €10) spanning 1 day, so there is **no projection**; only the hard alerts apply, and €55 is 22% of the budget. Stocking up at all three chains on 1 Nov is one shopping day, so there is no projection and no division. A per-trip formula would have computed `r` = €45 / 1 day and projected €1,225, or divided by zero. Then you add €40 on 8 Nov and €50 on 15 Nov. On 15 Nov there are 4 shopping days spanning 14 days, so the projection starts: `r` = (45 + 10 + 40) / 14 = €6.79/day, the gaps are 1, 6 and 7 days (median 6), so `g` = 6 and `N` = 21 Nov. `U` = 30 − 21 + 1 = 10, and `P` = 145 + 6.79 × 10 = **€213**. The tolerance is max(€12.50, ½ × median(45, 10, 40, 50) = €21.25) = €21.25, so the alert line is €271.25 and no alert fires.
- **Unfinished trips:** an unpacking session without a total (§6.3) isn't in "spent" yet, so the Budget screen shows "1 trip without a total" next to the figure until you finish it.
- **Breakdowns:** by category (from lines; `adjustment` lines appear as "Unclassified", so totals always reconcile), by chain, by week, food versus non-food, price history per product (`line_total / quantity` in base units, shown per kg, per litre or per pack), and **waste in €** (Σ discard movements × `unit_cost_cents`).
- What you paid is the ticket total after discounts. Vouchers used as payment are a payment method and still count as spend.

---

## 7. The Claude connector (MCP)

### 7.1 Connection and authentication

- **Endpoint:** `https://<project-ref>.supabase.co/functions/v1/mcp` (Streamable HTTP).
- **Unauthenticated request** returns `401` with `WWW-Authenticate: Bearer resource_metadata="…"`. The protected resource metadata says `resource` = exactly that URL and `authorization_servers` = `["https://<project-ref>.supabase.co/auth/v1"]`. Claude only uses the first entry.
- **Authorization server:** Supabase OAuth 2.1 server, enabled under *Authentication → OAuth Server*, with Authorization Path `/oauth/consent` on your Cloudflare Pages Site URL. For you alone, **register one OAuth client manually** with redirect URI `https://claude.ai/api/mcp/auth_callback` and paste its client ID into the custom connector's advanced settings. Turn on **dynamic client registration** only when other users join, because open registration lets any client register. The consent page shows the client name and the redirect host, and has a Deny button.
- **Using it:** add it once in Claude (Settings → Connectors → Add custom connector). Connectors added there are available in the Claude iPhone app too. Custom connectors are available on Claude's paid plans, and the Free plan allows a limited number, so check yours.
- **Tokens:** Supabase rotates refresh tokens, which Claude's client expects for public clients. Claude refreshes when it gets a `401`, or shortly before expiry.
- **Each MCP request:** the function verifies the JWT, creates a Supabase client with your token (RLS applies), calls the same SQL functions as the app, and writes one `mcp_audit` row through `log_mcp_call`. The kill switch doesn't block that function, so reads keep working, and stay audited, while Claude's writes are off.

### 7.2 Tools

All responses include `today` (Madrid date) and `days_left` computed on the server, so Claude never does date arithmetic. Money comes as both `cents` and a formatted string ("€12,34"). Lists are paginated (default 50) and every string is capped at 120 characters.

| Tool | Type | Purpose |
|---|---|---|
| `get_overview()` | read | One-call snapshot: expired, expiring ≤3 days, lots in `check` and `unconfirmed` state, staples below par, open list count, month spend vs budget + projection, unpacking trips without a total, count of food products with no ingredient. |
| `list_pantry(location?, category?, state?, expiring_within_days?, limit?, cursor?)` | read | Lots with qty left (base unit and packs), effective expiry, days left, state, expiry kind and source. Default state filter: `ok` + `check`. |
| `search_products(query)` | read | Trigram search over your products and aliases. |
| `list_reference(kind: categories|ingredients|chains, query?)` | read | The canonical IDs Claude may use in writes. Ingredients are searchable by Spanish or English name. |
| `suggest_recipes(max_missing?, limit?)` | read | §6.5 scored candidates with matched lots and missing items. |
| `get_shopping_list()` | read | Open items with reasons and suggested chain. |
| `get_spending(from, to, group_by: chain|category|week|product, food_only?)` | read | §6.7 aggregates. |
| `get_purchases(from, to, chain?, include_items?)` | read | Trip history. |
| `get_price_history(product_id or query, chain?)` | read | Unit price over time. |
| `get_waste_report(from, to)` | read | Discarded quantity and € by category and product. |
| `record_consumption(request_id, lot_id, quantity or "all", reason: consume|discard)` | write | Appends movements; clamps at qty left under a row lock. |
| `update_lot(request_id, lot_id, expires_on?, expiry_kind?, location?, opened_on?, frozen_on?, still_have?)` | write | Corrections and opening/freezing. `still_have: true` sets `checked_on = today` (the "Still have it? → Yes" answer). |
| `add_pantry_items(request_id, items[ItemInput])` | write | Items bought without a receipt. Creates any new products, then one lot per item. |
| `log_purchase(request_id, chain, purchased_at, time_printed, total_cents, ticket_number?, lines?[LineInput], merge_into?, force_new?)` | write | Creates any new products, the lines and the trip, then runs `confirm_purchase` in the same transaction, so the sum invariant, the unit conversion and the duplicate classifier (§6.1 step 3f) apply to Claude too. This lets you share a Mercadona e-ticket PDF with Claude on your phone and say "log this". `time_printed: true` means `purchased_at` carries the minute printed on the ticket; the tool description tells Claude to copy the ticket number and that minute whenever the ticket shows them. Results: `ALREADY_LOGGED` (C1, never overridable; C2, overridable only with `force_new` after you confirm) with the existing trip's date, time and total; `POSSIBLE_DUPLICATE` (C3, C4 or C5) with both trips' totals, times, ticket numbers and the rule that matched, after which Claude must ask you and retry with `merge_into` or `force_new: true`; on success, `same_day_notice` (C6), which the tool description tells Claude to repeat to you. A quick total from Claude (no lines, `time_printed: false`) is a typed trip, so it is classified symmetrically against a receipt you already photographed. |
| `update_product(request_id, product_id, ingredient_id?, category_id?, name?, shelf_life_days?, expiry_kind?, pack_size?, unit_weight_g?)` | write | Fixes a product's mapping, e.g. links unlinked items to ingredients, records that its label says *consumir preferentemente* (sets `kind_confirmed`), or answers a `NEEDS_PACK_SIZE` / `UNIT_MISMATCH` question. It cannot change `unit`; the database refuses that once the product has history (§5). |
| `update_shopping_list(request_id, add?[], mark_bought?[], dismiss?[{id, snooze_days}])` | write | List edits. |
| `generate_shopping_list(horizon_days?)` | write | Forces `refresh_shopping_list` (§6.6), e.g. with a longer horizon before a big shop. Not needed for a current list, because every write refreshes it. Idempotent. |
| `save_recipe(request_id, title, servings, minutes, ingredients[], steps)` | write | Adds to your library; ingredients map to canonical IDs or are rejected with suggestions. |
| `set_staple(request_id, ingredient_id or product_id, par_qty, unit)` / `set_budget(request_id, month, amount_cents)` | write | Settings. A staple is set on an ingredient (any brand) unless you ask to pin one product. |
| `undo(request_id)` | write | Reverses everything one earlier call did, using compensating movements or a status revert (a logged trip becomes `void`). Products created by that call are kept, because they are reusable and hold no stock of their own. |

**Input contract for the logging tools.** These are zod schemas in `packages/shared`, published as each tool's JSON Schema:

```ts
ProductRef = { product_id: uuid }                          // an existing product, from search_products
           | { new_product: { name: string /* ≤120 */, category_id: CategoryId, ingredient_id?: IngredientId,
                              unit: 'unit'|'g'|'ml', pack_size?: number, gtin?: string } }
LineInput  = { kind: 'item'|'discount'|'refund', raw_text?: string, line_total_cents: int,
               printed_qty?: number /* > 0, default 1 */, printed_unit?: 'pack'|'g'|'ml' /* default 'pack' */,
               product?: ProductRef,                       // omitted = spend only (no pantry lot)
               category_id?: CategoryId,                   // required on an item line without a product
               expires_on?: date, expiry_kind?: 'use_by'|'best_before'|'estimate' }
ItemInput  = { product: ProductRef, qty: number /* > 0 */, qty_unit: 'pack'|'g'|'ml',
               location?: 'fridge'|'freezer'|'pantry', expires_on?: date,
               expiry_kind?: 'use_by'|'best_before'|'estimate' }
```

Quantities are given as the ticket or label shows them ("2 packs", "1234 g"). The server converts them with the same `to_base_qty()` as the app (§6.1 step 6), so Claude never multiplies by pack sizes. A `NEEDS_PACK_SIZE` or `UNIT_MISMATCH` error names the product and lists the fixes from §6.1 step 6, so Claude can ask you and retry with `new_product.pack_size`, `update_product(unit_weight_g)`, a separate weighed `new_product`, or a spend-only line.

The server applies these rules in one transaction:

1. A `new_product` is de-duplicated first. The same GTIN, or the same normalised name in the same category, reuses the existing product. Otherwise the product is created with `source='claude'`. A missing `ingredient_id` on a food category is resolved through `ingredient_aliases`, as for receipts.
2. An unknown category or ingredient ID rejects the whole call with the three closest valid IDs, so Claude can retry and nothing is half-written.
3. Each item line with a product in a tracked category gets a lot, exactly as in §6.1 step 6. A printed `expires_on` overrides the default and sets `expiry_source='claude'`. With `raw_text`, the alias is learned for that chain, so the next receipt you log in the app matches it automatically.
4. The response lists, for every line, the `product_id`, whether it was created, and the `lot_id` (or `spend_only`), plus `due_soon`: every created lot already inside the alert window (§6.4). Claude can then tell you "6 new products added to your pantry; the chicken is use-by Tuesday".

The tool descriptions tell Claude to call `search_products` for each line first and to use `new_product` only when nothing fits.

Read tools are annotated `readOnlyHint: true`. Write tools are annotated `destructiveHint: false` (they are all reversible) and `idempotentHint: true`. Leave write tools on "ask before use" in Claude's connector settings, and set read tools to "always allow" if you like.

### 7.3 Safety properties (each one is testable)

1. Claude can only reach your household, because RLS uses your token and there is no service key in the function.
2. Claude cannot hard-delete anything: no tool issues a `DELETE`, and the app's discard is a movement.
3. Every Claude write is attributable (`via='mcp'`, `request_id`, `mcp_audit`) and reversible (`undo`).
4. Turning off "Let Claude make changes" in the app blocks Claude writes at the database (restrictive RLS policy on the OAuth `client_id` claim), even if the MCP code has a bug. Reads keep working and are still audited, because `mcp_audit` is excluded from the restrictive policies and written only through `log_mcp_call`.
5. Invalid writes fail with readable errors that Claude can relay. Examples: unknown `lot_id`, a quantity ≤ 0, a purchase whose lines don't add up, a recipe ingredient that isn't canonical.

**Example sessions**

- *"What should I cook tonight?"* → `get_overview` + `suggest_recipes` → Claude proposes 2–3 dishes built around the chicken that expires today. *"Made the first one."* → `record_consumption` on the matched lots.
- *"Log this"*, with a shared Mercadona e-ticket PDF containing 6 products you've never bought → `search_products` per line, then `log_purchase` with `new_product` entries → "Logged €23,40 at Mercadona: 6 new products added to your pantry, 2 of them use-by within 3 days."
- *"How am I doing on groceries this month vs last?"* → two `get_spending` calls → Claude explains: Carrefour trips cost 31% more per trip, and €9 of yogurt was thrown away.

---

## 8. MVP scope

**In the MVP (one user, daily use):**

| Requirement | MVP feature |
|---|---|
| Log purchases from Mercadona, Carrefour, Supercor | Receipt photo with sum check + review + alias learning; barcode unpacking sessions that end with a receipt, a typed total or item prices; quick add; quick total (merged with a later receipt); e-ticket via Claude `log_purchase` |
| Pantry + expiry + alerts | Lots with default/printed/estimated expiry (loose produce included), opened/frozen, one-tap consume/discard, lot states with "Still have it?", daily server email digest + 7-day local notifications + `due_soon` in Claude's replies |
| Recipes from what you have, soonest-expiring first | Ingredient link on every product + seeded library + §6.5 lexicographic ranking (rescue value first, stale lots excluded) + "add missing to list" + Claude via connector |
| Automatic shopping list | Refreshed by every stock change and every morning, never by hand; ingredient-level staples/par (any brand, any chain), run-out, usual-purchase and recipe rules; in-transit handling between shopping and logging; offline check-off |
| Budget and spending | Monthly budget, hard 80%/100% alerts, shopping-day projection (shown only with enough history), breakdowns, waste € |
| Runs on iPhone | Expo app: developed in Expo Go, used daily as an installed TestFlight build from step 7, updated over the air |
| Claude reads and updates the data | Remote MCP connector with the 21 tools above |
| Built to scale and sell | Households + RLS + composite FKs + audit + EU hosting + export/delete from day one |

**Deliberately not in the MVP** (and why it's safe to defer):

- Shared households UI (the schema is ready; it is just an invite screen).
- Push notifications from the server before step 7. They need the paid Apple account. Until then the server email digest gives the same always-current coverage, and the local notifications give instant ones.
- Android (same codebase, just a build).
- Payments, a public catalog from the OFF dump, and listing in Claude's connector directory (none matter until other users exist).
- Live in-app camera OCR of date labels (the date wheel is faster to build and good enough).
- Nutrition data.
- Comparing prices across supermarkets using their websites (scraping risk, F25). Your own price history covers the stores you use.

---

## 9. Build plan

The plan assumes 8–10 hours a week, coding with Claude Code. Give Claude Code one step at a time, including its "done when" line, and don't start the next step until the test passes.

| Step | Weeks | Work | Done when |
|---|---|---|---|
| 0 | 0.5 | Accounts: GitHub, Supabase (projects `dev` + `prod`, EU region), Expo, Cloudflare, Resend (free plan; use the test sender to your own email), Anthropic Console (API key, **monthly spend limit €5**). Install Node LTS, pnpm, Supabase CLI, Claude Code, and Expo Go on your iPhone. Create the monorepo. | `supabase link` works for dev; an Expo "hello" screen opens on your iPhone. |
| 1 | 1 | Migrations: §5 schema, RLS, `is_member`, `oauth_write_ok`, signup trigger, seed tables (chains, ~25 categories, ~200 ingredients, ~600 ingredient aliases covering Spanish names, common receipt abbreviations and OFF tags, ~60 recipes). SQL functions `to_base_qty`, `classify_duplicate`, `confirm_purchase` (including `merge_into`, `force_new` and the advisory lock), `consume`, `log_mcp_call`. Tests run as two fake users via `set local role authenticated; set local request.jwt.claims = '{"sub":"…"}'`. | User B gets 0 rows from every table for A's data. Inserting a lot pointing at B's product fails. `confirm_purchase` rejects a €0.01 mismatch and accepts it with `accept_difference` (adjustment line created). Consuming more than is left leaves exactly 0. Seeding a category with `expiry_kind='none'` and a shelf life fails. With `mcp_write_enabled = false` and claims that include a `client_id`, inserting a lot fails while `log_mcp_call` succeeds. Unit conversion: "2 x LECHE" (`2, pack`) on a product with `ml`/1000 gives a 2000 ml lot; `pack` on a `g` product with no pack size raises `NEEDS_PACK_SIZE`; `g` on an `ml` product raises `UNIT_MISMATCH`; 826 g on a `unit` product with `unit_weight_g = 120` gives a lot of 7, and without it raises `UNIT_MISMATCH`; updating `unit` on a product that has a 6-unit lot raises `PRODUCT_HAS_HISTORY`, and the lot still reads 6. A best-before category without `check_grace_days` fails to seed. Merging a receipt into a €45,60 quick total leaves one confirmed trip, and the month total rises by €0. A €46,00 quick total typed after a €45,60 receipt raises `POSSIBLE_DUPLICATE` (C5), and merging it leaves one trip of €45,60. `classify_duplicate`: the eight worked checks of §6.1 step 3f, each run in **both logging orders** (N and E swapped), give the expected verdict both times: C2, C1/C2/C3, C5, C3 with "same" preselected, C3 with nothing preselected, C3 with "same" preselected, C6 with notice, and C6 with a notice whose time correction turns it into C5. Two receipts with different totals, ticket numbers 5 characters apart and different minutes → C6 with notice. Two concurrent `confirm_purchase` calls for the same null-ticket receipt (two sessions, `pg_sleep` inside the first) leave exactly one confirmed trip. A yogurt product with `expiry_kind='use_by'` set on the product creates `use_by` lots inside the best-before yogurt category. |
| 2 | 1 | **Connector spike (highest risk first):** enable the OAuth server; consent SPA on Cloudflare Pages; `mcp` Edge Function with `get_overview` and `list_pantry` over seed data; register the client; add the custom connector in Claude. | From the **Claude iPhone app**, "what's in my pantry?" returns the seed lots. It still works the next day (token refresh). Removing and re-adding the connector works. A request without a token gets `401` + `resource_metadata`. If this fails after a day of debugging, switch to the Cloudflare `workers-oauth-provider` fallback (§4). |
| 3 | 1 | App skeleton: OTP login, tabs (Pantry, Add, List, Budget, Recipes), pantry list with days-left chips, quick add, consume/discard, persisted cache (AsyncStorage) + offline mutations. | In airplane mode, add 3 items and consume 1. Reconnect: exactly 3 lots and 4 movements exist in the DB. Repeating the sync creates nothing new. All of this runs inside Expo Go, loaded from the laptop's dev server; no package outside the list in §4 is installed. This tests the queue logic only. The real-world offline test, a cold start with no signal, is step 7's, because Expo Go isn't the app you take to the shop. |
| 4 | 1 | Barcode: camera screen, check digit, prefix 20–29 handling, OFF queue (≤12/min, persisted), product creation with base unit and pack size from `product_quantity`/`product_quantity_unit`, continuous scan, unpacking session with optional prices and "Finish trip" (typed total or item prices). | 20 real products from your kitchen: known items take one tap, OFF hits fill in (a 1 L carton is stored as `ml`, 1000), misses are saved and found again on the next scan, a weighed fruit label goes straight to "pick product", and 20 scans in under a minute give no errors. A 15-item session finished with a typed €38,20 adds exactly €38,20 to the month and keeps all 15 lots. A session left unfinished for 8 days still has its 15 lots, isn't voided by the job, and shows the "no total" reminder. |
| 5 | 2 | Receipts: capture/upload, `parse-receipt` (schema, small → large model fallback, quota), validation, review screen with category/ingredient chips and "spend only", alias matching, check-dates sheet, duplicate ticket guard, unfinished-draft banner, `retention` function (image deletion, draft voiding). **Build `tools/receipt-eval`:** 10 real receipts (≥3 per chain), with ground truth typed once by hand. | Eval script: ≥9/10 receipts pass the sum check automatically, and line-level total accuracy is ≥95%. Re-logging a second receipt with the same products gives ≥80% auto-matched lines. Photographing the same ticket twice says "already logged", including for one of your 10 receipts with its ticket number deliberately blanked in the parse output. On the check-dates sheet, switching a yogurt to *Caducidad* saves it on the product, and the next receipt with that yogurt creates a `use_by` lot without asking. If the small model scores under 8/10, make the larger model the default (still about 2 cents a receipt). At least 90% of food lines on new products get the correct ingredient without manual edits. A draft back-dated by 8 days is voided by the job, its files are gone from Storage, and photographing that ticket again works. A quick total of €45,60 at Mercadona, followed by a photo of that ticket, offers "Add these items to that trip?"; accepting it leaves one trip of €45,60 with lines and lots. A receipt for an unpacking session links to the scanned lots and creates no second lot for them. |
| 6 | 2 | Alerts: lot states in the `pantry` view, "Still have it?" answers, `buildDigest` (pure TypeScript in `packages/shared`, unit-tested), 7-day local scheduling, `daily-digest` Edge Function + Resend email, the `apps/scheduler` Cloudflare Worker (hourly Cron Trigger → `daily-digest`, 03:00 Madrid → `retention`, watchdog email), settings screen. | Unit tests: use-by on day e−2/e−1/e, best-before e−3…, an expired use-by appears in "bin it" for 3 days and then leaves the digest, and the DST-change Sundays (last Sunday of March and of October) give correct days. Loose tomatoes bought today (estimate, 6 days, grace 3) appear in "Next 3 days" from day 3, in "Check it" on days 7–9, in "Still have these?" once on day 10, and never again. On device: a lot dated tomorrow produces a notification at the set time. With 150 lots, ≤7 notifications are pending. Server: a lot inserted directly in the DB (as Claude would) with the app closed appears in the next morning's email. Running `daily-digest` twice in the same hour sends one email. A second test household's lots never appear in your email. Scheduler: the Worker's logs show 24 successful calls a day; a call without the cron secret gets `401`. Watchdog: point the Worker's `dev` copy at a wrong function URL and set `WATCHDOG_HOUR` to the current hour; the "backend isn't responding" email arrives once, and the next hour's failure sends nothing. Pausing the `dev` project from the dashboard produces the same email on the next watchdog hour. Deploy the production Worker against `prod` on the first day of this step, and point no app at `prod` until step 7: when step 7 starts (14 days later), `prod`, with no traffic except the Worker's, is not paused. |
| 7 | 1 | **Install it for real (daily use starts here):** Apple Developer Program (€99/yr); add `expo-updates`; EAS Build → TestFlight with the app pointed at `prod`; Expo Push from `daily-digest` (the email becomes an optional backup); Sentry. From now on every step ships to your phone with `eas update --channel production`, with a new build only when a native module changes. Calendar reminder for the 90-day TestFlight expiry. | The app runs from TestFlight with the laptop switched off. **Cold start offline:** force-quit the app, turn on airplane mode, launch it: the pantry shows from the cache, 3 scans of known products and 1 "Finished" are queued, and after reconnecting exactly 3 lots and 4 movements exist. An `eas update` published from the laptop reaches the phone on the next launch, and the phone still cold-starts offline afterwards. The morning digest arrives as a push with the app closed. |
| 8 | 1 | Budget: `budget_status`, `spending` SQL; budget screen with hard alerts, projection and breakdowns. | For a month of real data, the app's totals equal a hand-written SQL `sum()`. A purchase at 23:30 Madrid time on the 31st lands in that month. Category totals + Unclassified = trip totals. The §6.7 worked check passes as a SQL test: with €50 every 7 days and a €200 budget, `P` = €214 (±€1) on days 1, 7, 8, 15, 22 and 28, and no projection alert fires. With €60 a week, the alert fires from day 1. With 2 shopping days of history there is no projection. The §6.7 second worked check passes: €30 + €15 on 1 Nov and €10 on 2 Nov give no projection; three trips on one day give no projection and no error; with €40 on 8 Nov and €50 on 15 Nov added, `P` = €213 (±€1) on 15 Nov and no alert fires. A property test over 1,000 random trip histories (1–4 trips a day, 0–90 days) never divides by zero and never shows a projection with a span under 14 days. |
| 9 | 1 | Shopping list: ingredient-level staples/par UI (with "pin this product"), stock keys, `refresh_shopping_list` wired into every stock-changing function and the morning `daily-digest` run, in-transit and `resolved` handling, "Stock them now?", snooze, offline check-off, suggested product + chain + last price. | Running the refresh twice gives an identical list. With no generator ever called by hand: tapping "Finished" on the last milk puts milk on the list in the same transaction; the §6.6 Thursday–Saturday table passes row by row (milk not re-added while in transit, nothing added once the receipt is confirmed); an unreconciled `bought` row returns after 3 days with "no receipt logged"; a `below_par` row becomes `resolved` when a quick-added carton brings milk back to par, while a `manual` row stays open; a "usual purchase" item appears in the morning email on the day it becomes due with no app open. A banana staple of 800 g counts 7 bananas with `unit_weight_g = 120` as 840 g. A dismissed item with a 7-day snooze doesn't come back. A staple at par isn't added. A staple whose only lot is past its use-by date is added. The §6.6 cross-chain check: a `milk` staple of 2000 ml with 2 × Carrefour 1 L in stock and no Hacendado adds nothing. A staple pinned to Hacendado milk in the same state adds 2 packs. A staple whose only lot is `unconfirmed` is added. |
| 10 | 1 | Recipes: `suggest_recipes`, list + detail, "add missing", "plan". | Using products created by your real receipts from step 5 (not hand-seeded rows), with chicken expiring today, a chicken recipe ranks first. An expired use-by lot never appears in any suggestion. "Add missing" creates no duplicates. The four §6.5 worked checks pass as SQL tests: the stale tomatoes don't make a tomato recipe eligible; "Pollo al ajillo" (chicken use-by in 3 days) ranks above a 7-ingredient "Lentejas estofadas" and above a 20-ingredient test recipe made only of long-life items; with equal rescue value, the recipe with nothing missing ranks first. Every result shows its `rank_reason`. |
| 11 | 1 | Full MCP tool set, `request_id` idempotency, `undo`, audit, kill switch toggle in the app. | In Claude: log a Mercadona e-ticket containing at least 3 never-seen products with `log_purchase` → the trip, the new products (with ingredients) and their pantry lots appear in the app; `undo` reverts it; repeating the same `request_id` changes nothing; with the kill switch off every write fails with "Claude write access is off in the app", while reads still work and each read leaves an `mcp_audit` row. `log_purchase` with a lot use-by tomorrow returns it in `due_soon`. `log_purchase` for a chain and date that already has a quick total returns `POSSIBLE_DUPLICATE`, and `merge_into` then leaves one trip. Telling Claude "I spent about €46 at Mercadona today" after photographing that day's €45,60 ticket returns `POSSIBLE_DUPLICATE` (C5); after you answer "same trip", the month total is unchanged. A Claude-logged trip judged C6 returns `same_day_notice`, and Claude repeats it. After any Claude write that changes stock, `get_shopping_list` already reflects it. A receipt you photographed in the app, logged again by Claude from its e-ticket PDF, is refused in all three variants: `ALREADY_LOGGED` with the ticket number, `ALREADY_LOGGED` with the number removed but the printed minute given, and `POSSIBLE_DUPLICATE` with both removed. The month total doesn't change in any of the three. |
| 12 | 1 | Hardening for other people: account deletion (app + web page); JSON/CSV export; weekly `pg_dump` GitHub Action to a private bucket; OFF attribution; privacy policy page. Shipped with `eas update` unless a native module changed. | Deleting a test account removes all its rows and images. Restoring last week's dump into `dev` works. The CSV export of a month opens in a spreadsheet and its total equals the Budget screen. |

**Then use it for 4 weeks** and track these numbers. The `mcp_audit` table and simple SQL give you most of them.

- Weeks with at least one logged trip (target 4/4).
- Share of trips logged by receipt.
- Auto-match rate (target ≥80%).
- Receipts that needed manual fixes.
- Waste € per month (it should trend down).
- Budget accuracy against your bank statement (target within €1).

These numbers tell you whether the product is worth showing to anyone else, and they become your evidence if you pitch it.

---

## 10. Running costs

| Item | Just you (MVP) | When selling |
|---|---|---|
| Supabase | €0 (free tier, 2 projects; would pause after a week of low activity, which the hourly Worker calls prevent; warning emails, and the Worker's own failure email, if it ever happens) | Pro, about $25/month (no pausing, backups) |
| Cloudflare Pages + Workers | €0 (one static site, one Worker with one Cron Trigger: about 720 calls a month, far inside the free plan) | €0 |
| Expo / EAS | €0 (Expo Go for development; the free plan's cloud builds and EAS Update allowance are far above one user's needs) | Paid plan only if build volume or update users exceed the free allowance |
| Apple Developer Program | €0 until step 7 (about week 8.5), then €99/year | €99/year; Apple's commission on subscriptions is 15% under the Small Business Program |
| Claude API (receipts) | About €0.01–0.20/month | About €0.01–0.20 per active user per month; capped with `usage_counters` quotas |
| Claude subscription (connector) | Your existing plan | Each user's own plan |
| Resend (digest email) | €0 (free plan: 3,000 emails/month, 100/day) | Free plan up to a few dozen users with daily digests; paid plan beyond that, or push only |
| Domain (optional) | About €10/year | Needed for branding and for sending the digest email to other users |

---

## 11. Path to other users and selling

What's **already in place** after the MVP: multi-tenant schema with RLS, composite FKs and tests; EU hosting; audit trail; export and deletion; a connector that works for any user (each person adds the same URL and signs in with their own account).

What to **add, in order:**

1. **Household invites:** share a pantry with flatmates. This is a natural feature for students and only needs an invite screen.
2. **Sign in with Apple** (needed in practice, and required by Guideline 4.8 if you add Google login). Use a custom SMTP sender (e.g. Resend), because Supabase's built-in email has low rate limits.
3. **A verified sending domain for the digest email** (Resend's test sender only reaches your own address), then **Android** from the same codebase. Push digests already exist from step 7.
4. **Shared product catalog:** load Spain-relevant products from the Open Food Facts data export into a read-only `catalog_products` table, refreshed nightly. Live API limits no longer matter, and new users get instant barcode hits. Comply with ODbL attribution and share-alike for that table.
5. **Turn on DCR** in the OAuth server, monitor registered clients, and later submit the connector to Claude's directory.
6. **Monetisation:** RevenueCat + Apple in-app purchase. The natural split is free (manual + barcode + N receipts a month) versus paid (unlimited receipts, household sharing, Claude connector, waste and price analytics). The quota table already enforces N.
7. **Legal pack:** privacy policy, terms, data processing agreements with Supabase and Anthropic, a GDPR record of processing activities, and App Store privacy labels.
8. **More chains:** insert rows into `chains`. The receipt prompt is generic, and per-chain hints live on the server.

The app is useful without Claude (F24). The connector differentiates the product for Claude users but is not a requirement for using it.

---

## 12. Assumptions

- You are not a professional developer and will build with Claude Code. Nothing assumes a Mac, but one would only help.
- "Connector" means a Claude **custom connector** backed by a remote MCP server, usable from Claude on iPhone, web and desktop. A local-only MCP server would not meet "on my iPhone".
- Receipts are in Spanish with prices in EUR, and your time zone is `Europe/Madrid`.
- Mercadona, Carrefour and Supercor offer no official API for your purchase history, so data comes from you (photo, scan, entry, or a shared e-ticket), never from scraping.
- Budget scope is "everything on the supermarket ticket", including cleaning and toiletries, with a food-only filter in every breakdown.
- Shelf-life defaults are conservative starting points, not food-safety advice. A printed date always overrides them.
- Prices and plan limits quoted are as published in November 2026, and may change.

## 13. Remaining risks you should know about

| Risk | Likelihood | Mitigation already planned |
|---|---|---|
| Supabase OAuth 2.1 server is **beta** and behaves differently from Claude's client. | Medium | Tested in week 2, before anything depends on it; named fallback (Cloudflare `workers-oauth-provider`). |
| Faded or crumpled thermal receipts are unreadable. | Medium | Sum check exposes it; retake prompt; quick-total entry keeps the budget right. A ticket whose number can't be read is still caught as a duplicate by its printed minute and total, or by the same-day, same-total question (§6.1 step 3f). |
| Two separate same-chain trips on one day with identical totals to the cent, or one receipt whose printed minute is misread so that it looks printed after a typed total. | Low | Neither is ever silent. Equal totals always produce a question (C3), never an automatic merge or add. A trip judged separate by its printed time is added with a notice that names the other trip and shows the editable time (C6). The month-end comparison with your bank statement (§9) catches a wrong answer. |
| Expo Go only runs the latest Expo SDK, so an Expo Go update can force an SDK upgrade mid-build. | Medium | Pinned SDK. Expo Go is only the development tool; the app you use daily is the TestFlight build from step 7, which an Expo Go update can't break. |
| You stop opening the app. | Medium | Receipt-first flow; metrics in §9 tell you early; Claude can do logging (`log_purchase`) from the app you already use every day, and the server email digest keeps alerting you about everything, including what Claude logged, without the app being opened. Its schedule runs on Cloudflare, so it also keeps the free Supabase project from pausing, and it emails you if the backend stops answering (§6.4). |
| Some products get the wrong ingredient or none. | Medium | Chips on the review screen, the unlinked count in the app and in `get_overview`, `update_product` for Claude; step 5 measures the rate. |
| Default shelf lives are wrong for some products. | Low | Per-product override; printed-date prompt on risky categories; fixes stick to the product. |

---

### Sources checked (November 2026)

- Claude connector authentication requirements (401 + resource metadata, PKCE S256, callback `https://claude.ai/api/mcp/auth_callback`, DCR/CIMD, form-encoded token endpoint, 10 s / 30 s timeouts): https://claude.com/docs/connectors/building/authentication
- Supabase OAuth 2.1 server (beta, all plans; consent at Site URL + Authorization Path; `approveAuthorization`/`denyAuthorization`): https://supabase.com/docs/guides/auth/oauth-server/getting-started and MCP guide (DCR, RLS applies, `@supabase/server` helpers): https://supabase.com/docs/guides/auth/oauth-server/mcp-authentication
- Supabase Edge Functions serve HTML only with a custom domain: https://supabase.com/changelog/29633-xhtml-responses-are-only-allowed-with-a-custom-domain-enabled
- Supabase free-project pausing (7-day window of low activity; API calls and app requests count as activity, a few requests a day is typically enough; warning email about a week ahead; restorable for up to a year): https://supabase.com/docs/guides/platform/free-project-pausing and https://supabase.com/kb/faqs/platform/free-project-pausing
- Cloudflare Workers limits (Cron Triggers on the free plan): https://developers.cloudflare.com/workers/platform/limits
- Yogurt in Spain usually carries *consumo preferente*, not *caducidad*, since Real Decreto 271/2014: https://maldita.es/malditaciencia/20211214/yogur-fecha-consumo-preferente-caducidad/ and https://boe.gob.es/boe/dias/2014/04/28/pdfs/BOE-A-2014-4515.pdf
- Open Food Facts API rate limits (15 product reads/min/IP), User-Agent rule, ODbL: https://openfoodfacts.github.io/openfoodfacts-server/api
- Claude API pricing (Haiku 5.5, Sonnet 5.5): https://platform.claude.com/docs/en/about-claude/pricing
- Mercadona digital ticket (card registration at the till, WhatsApp confirmation, email delivery): https://www.xatakamovil.com/movil-y-sociedad/ticket-digital-llega-a-mercadona-como-activarlo-whatsapp-para-recibir-ticket-movil
- Supabase Storage: delete files through the Storage API, not by deleting `storage.objects` rows: https://supabase.com/docs/guides/storage/management/delete-objects
- Expo Go loads EAS Update projects only if you own them (since 12 May 2026), and Expo recommends TestFlight or internal-distribution builds for real use: https://expo.dev/changelog/expo-go-loading-changes-may-2026
- Expo Go contains only the native modules of the Expo SDK; `react-native-mmkv` needs a development build, while AsyncStorage is included: https://docs.expo.dev/versions/latest/sdk/async-storage/ and https://github.com/mrousavy/react-native-mmkv
- Open Food Facts product schema (`quantity`, `product_quantity` "size in g or ml for the whole product", `product_quantity_unit` "g or ml"): https://openfoodfacts.github.io/documentation/docs/Product-Opener/schemas/schemas/product/
- Resend free plan (3,000 emails/month, 100/day): https://resend.com/docs/knowledge-base/what-is-resend-pricing
- Supercor stores sold to and reopened by Carrefour: https://www.alimarket.es/alimentacion/noticia_amp/385510/carrefour-reabrira-los-46-supercor-comprados-a-el-corte-ingles-a-partir-de-abril
