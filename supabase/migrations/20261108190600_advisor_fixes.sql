-- Step 1, part 7: fixes from the Supabase security/performance advisors.

-- Foreign keys without a covering index.
create index if not exists purchases_chain_idx        on public.purchases (chain_id);
create index if not exists receipt_aliases_chain_idx  on public.receipt_aliases (chain_id);
create index if not exists purchase_items_purchase_idx on public.purchase_items (purchase_id, household_id);

-- recipe_ingredients: the "for all" write policy also covered SELECT, so SELECT had two permissive policies.
drop policy recipe_ingredients_write on public.recipe_ingredients;
create policy recipe_ingredients_insert on public.recipe_ingredients for insert to authenticated
  with check (exists (select 1 from public.recipes r
                      where r.id = recipe_id and r.household_id is not null and public.is_member(r.household_id)));
create policy recipe_ingredients_update on public.recipe_ingredients for update to authenticated
  using (exists (select 1 from public.recipes r
                 where r.id = recipe_id and r.household_id is not null and public.is_member(r.household_id)))
  with check (exists (select 1 from public.recipes r
                      where r.id = recipe_id and r.household_id is not null and public.is_member(r.household_id)));
create policy recipe_ingredients_delete on public.recipe_ingredients for delete to authenticated
  using (exists (select 1 from public.recipes r
                 where r.id = recipe_id and r.household_id is not null and public.is_member(r.household_id)));

-- Supabase's own auto-RLS helper should not be callable through the API.
do $$ begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke all on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end $$;

-- Not changed on purpose: is_member / oauth_write_ok / log_mcp_call are security definer and callable by signed-in
-- users. RLS needs the first two; log_mcp_call is the audit door and checks membership itself.
