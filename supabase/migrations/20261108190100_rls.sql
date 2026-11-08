-- Step 1, part 2: row-level security. Source: arena-winning-plan.md section 5 ("Row-level security").
-- Rule: every table has RLS on. Household tables allow only members. Reference tables are read-only.

create function public.is_member(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.household_members m
                 where m.household_id = h and m.user_id = (select auth.uid()));
$$;

-- Claude kill switch, enforced in the database. OAuth tokens issued to Claude carry a client_id claim;
-- the app's own sessions don't.
create function public.oauth_write_ok(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (auth.jwt() ->> 'client_id') is null
      or coalesce((select mcp_write_enabled from public.households where id = h), false);
$$;

revoke all on function public.is_member(uuid), public.oauth_write_ok(uuid) from public, anon;
grant execute on function public.is_member(uuid), public.oauth_write_ok(uuid) to authenticated;

-- Reference tables: select-only.
do $$
declare t text;
begin
  foreach t in array array['chains','categories','ingredients','ingredient_aliases'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)', t || '_read', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
  end loop;
end $$;

-- Household tables: members only, plus the restrictive "Claude writes allowed" policies.
do $$
declare t text;
begin
  foreach t in array array['products','receipt_aliases','purchases','purchase_items','pantry_lots',
                           'stock_movements','staples','shopping_list_items','budgets'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for all to authenticated
                    using (public.is_member(household_id)) with check (public.is_member(household_id))',
                   t || '_member', t);
    execute format('create policy %I on public.%I as restrictive for insert to authenticated
                    with check (public.oauth_write_ok(household_id))', t || '_claude_insert', t);
    execute format('create policy %I on public.%I as restrictive for update to authenticated
                    using (public.oauth_write_ok(household_id))', t || '_claude_update', t);
    execute format('create policy %I on public.%I as restrictive for delete to authenticated
                    using (public.oauth_write_ok(household_id))', t || '_claude_delete', t);
  end loop;
end $$;

-- households: members read and update; created only by the signup trigger.
alter table public.households enable row level security;
create policy households_read   on public.households for select to authenticated using (public.is_member(id));
create policy households_update on public.households for update to authenticated
  using (public.is_member(id)) with check (public.is_member(id));
create policy households_claude_update on public.households as restrictive for update to authenticated
  using (public.oauth_write_ok(id));

-- household_members: you see your own memberships and your housemates'. No writes (invites come later).
alter table public.household_members enable row level security;
create policy household_members_read on public.household_members for select to authenticated
  using (user_id = (select auth.uid()) or public.is_member(household_id));

-- user_settings: your own row only.
alter table public.user_settings enable row level security;
create policy user_settings_own on public.user_settings for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- usage_counters: members can read; writes happen inside server functions later.
alter table public.usage_counters enable row level security;
create policy usage_counters_read on public.usage_counters for select to authenticated
  using (public.is_member(household_id));

-- mcp_audit: members can read. No insert/update/delete policy: only log_mcp_call() writes.
alter table public.mcp_audit enable row level security;
create policy mcp_audit_read on public.mcp_audit for select to authenticated
  using (public.is_member(household_id));

-- recipes: built-in library (household_id null) is readable by everyone; own recipes by members.
alter table public.recipes enable row level security;
create policy recipes_read   on public.recipes for select to authenticated
  using (household_id is null or public.is_member(household_id));
create policy recipes_insert on public.recipes for insert to authenticated
  with check (household_id is not null and public.is_member(household_id));
create policy recipes_update on public.recipes for update to authenticated
  using (household_id is not null and public.is_member(household_id))
  with check (household_id is not null and public.is_member(household_id));
create policy recipes_delete on public.recipes for delete to authenticated
  using (household_id is not null and public.is_member(household_id));
create policy recipes_claude_insert on public.recipes as restrictive for insert to authenticated
  with check (public.oauth_write_ok(household_id));
create policy recipes_claude_update on public.recipes as restrictive for update to authenticated
  using (public.oauth_write_ok(household_id));
create policy recipes_claude_delete on public.recipes as restrictive for delete to authenticated
  using (public.oauth_write_ok(household_id));

alter table public.recipe_ingredients enable row level security;
create policy recipe_ingredients_read on public.recipe_ingredients for select to authenticated
  using (exists (select 1 from public.recipes r where r.id = recipe_id));   -- recipes' own RLS applies
create policy recipe_ingredients_write on public.recipe_ingredients for all to authenticated
  using (exists (select 1 from public.recipes r
                 where r.id = recipe_id and r.household_id is not null and public.is_member(r.household_id)))
  with check (exists (select 1 from public.recipes r
                 where r.id = recipe_id and r.household_id is not null and public.is_member(r.household_id)));
create policy recipe_ingredients_claude_insert on public.recipe_ingredients as restrictive for insert to authenticated
  with check (public.oauth_write_ok((select r.household_id from public.recipes r where r.id = recipe_id)));
create policy recipe_ingredients_claude_update on public.recipe_ingredients as restrictive for update to authenticated
  using (public.oauth_write_ok((select r.household_id from public.recipes r where r.id = recipe_id)));
create policy recipe_ingredients_claude_delete on public.recipe_ingredients as restrictive for delete to authenticated
  using (public.oauth_write_ok((select r.household_id from public.recipes r where r.id = recipe_id)));

-- The only way to write the audit log. Works even when Claude's write access is off.
create function public.log_mcp_call(p_household uuid, p_tool text, p_request uuid, p_args jsonb, p_ok boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_member(p_household) then raise exception 'NOT_A_MEMBER'; end if;
  insert into public.mcp_audit (household_id, user_id, oauth_client_id, tool, request_id, args, ok)
  values (p_household, (select auth.uid()), auth.jwt() ->> 'client_id', p_tool, p_request,
          case when octet_length(p_args::text) <= 4096 then p_args else '{"truncated":true}'::jsonb end, p_ok);
end $$;
revoke all on function public.log_mcp_call(uuid, text, uuid, jsonb, boolean) from public, anon;
grant execute on function public.log_mcp_call(uuid, text, uuid, jsonb, boolean) to authenticated;

-- Receipt images: private bucket, first path segment = household id.
insert into storage.buckets (id, name, public) values ('receipts', 'receipts', false) on conflict (id) do nothing;
create policy receipts_member_all on storage.objects for all to authenticated
  using (bucket_id = 'receipts' and public.is_member(((storage.foldername(name))[1])::uuid))
  with check (bucket_id = 'receipts' and public.is_member(((storage.foldername(name))[1])::uuid));

-- Nothing here is for anonymous visitors.
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
