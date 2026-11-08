-- Step 1, part 6: explicit table privileges. Found by the tests: RLS decides WHICH rows, but the role still
-- needs the privilege first, and new tables here get none. Also removes TRUNCATE (RLS does not cover it).
-- Rule for later steps: every new table needs a grant line here-style, otherwise the app can't see it.

revoke all on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;

-- Reference data: read only.
grant select on public.chains, public.categories, public.ingredients, public.ingredient_aliases to authenticated;

-- Household data: RLS limits rows to members.
grant select, insert, update, delete on
  public.products, public.receipt_aliases, public.purchases, public.purchase_items, public.pantry_lots,
  public.staples, public.shopping_list_items, public.budgets,
  public.recipes, public.recipe_ingredients, public.user_settings
to authenticated;

-- Append-only ledger: no update, no delete.
grant select, insert on public.stock_movements to authenticated;

-- Read only for users (written by trigger / server functions).
grant select on public.household_members, public.usage_counters, public.mcp_audit, public.pantry to authenticated;
grant select, update on public.households to authenticated;
