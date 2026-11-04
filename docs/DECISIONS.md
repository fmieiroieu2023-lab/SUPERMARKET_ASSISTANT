# Decisions

| # | Date | Decision | Why | Trade-off accepted |
|---|---|---|---|---|
| D1 | 2026-11-04 | Base design = Arena winner (16-agent tournament, 4 rounds) | Most precise plan; every rule has a test case | Over-engineered in places; trimmed below |
| D2 | 2026-11-04 | Web app (PWA) instead of native Expo iPhone app | Avoids €99/yr Apple Developer fee; instant updates; no TestFlight | Weaker barcode scanning, no App Store listing, no widgets. Native app can be added later on the same backend |
| D3 | 2026-11-04 | Online-only (no offline write queue) | Scanning happens at home on Wi-Fi; list is made before shopping | App needs a connection to save changes |
| D4 | 2026-11-04 | Alerts via Web Push (home-screen app) + email digest, sent from the server | iOS supports push for home-screen web apps; server alerts also cover items Claude logs | No alarms scheduled on the phone itself |
| D5 | 2026-11-04 | Build with Claude Code on the Mac; Lovable credits kept in reserve | Backend (SQL, OAuth, MCP) is most of the work and needs full control; Claude usage resets every 5h, Lovable credits monthly | Screens take a bit longer than with Lovable |
| D6 | 2026-11-04 | No custom domain for now | Free `*.pages.dev` and `*.supabase.co` URLs work; domain only needed to email other people or for branding | Digest email only reaches the owner's own address |
| D7 | 2026-11-04 | Budget: ≤ $5/month extra running cost | Owner's constraint | Supabase free tier (pause risk handled by the hourly Worker cron) |
