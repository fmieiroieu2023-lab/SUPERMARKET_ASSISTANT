# Workflow: building efficiently with Claude Code

## Token rules
1. **One plan step per session.** Start each session with:
   `Read CLAUDE.md and step N of docs/PLAN.md. Use plan mode first, then build until the "done when" test passes.`
2. **`/clear` between steps.** Use `/compact` if a session gets long mid-step.
3. **Sonnet by default.** Switch to Opus only for step 2 (OAuth/connector) or when stuck on the same bug for 20+ minutes.
4. **Never load the reference plan whole.** Point Claude at one section: "see §6.6 of docs/reference/arena-winning-plan.md".
5. **Keep CLAUDE.md short.** Add a rule only after the same mistake happens twice.
6. **Small, testable increments.** Commit when a test passes; don't let one session sprawl across two steps.
7. **No multi-agent runs** (Arena, agent teams) on this project. Ordinary sessions are enough.
8. **Lovable credits (60) are a reserve**, e.g. for polishing one screen's design. Not used by default.

## Where work happens
- **Mac, Claude Code (default):** all building, local preview, Supabase CLI.
- **Claude chat / phone:** questions, planning, testing the connector once it exists.

## How deployment works
| What | How it deploys |
|---|---|
| Web app | `git push` to `main` → Cloudflare Pages builds and publishes automatically |
| Database | `supabase db push` (dev first, then prod) |
| Edge Functions (`mcp`, `parse-receipt`, `daily-digest`, `retention`) | `supabase functions deploy <name>` |
| Scheduler Worker | `pnpm --filter scheduler deploy` (Wrangler) |

Rule: test on `dev`, then push to `prod`. Your phone points at `prod` from step 3.

## Session checklist
- [ ] `git pull`
- [ ] Start Claude Code, give it the step prompt above
- [ ] Run the "done when" test yourself on the iPhone where it applies
- [ ] Tick the step in PLAN.md, update "Current step", commit, push
- [ ] `/clear`
