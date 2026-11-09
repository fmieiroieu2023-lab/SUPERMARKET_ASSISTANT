-- Step 3: add one item by hand ("quick add"). One transaction: product (found or created), lot, opening stock movement.
-- The expiry rule is here, not in the app: a typed date wins, otherwise today + the category's shelf life (Madrid day).
-- A repeat with the same p_lot_id is a no-op. Runs as the caller (security invoker), so RLS and the Claude kill switch apply.
create function public.add_item(
  p_lot_id uuid, p_name text, p_category text, p_qty numeric,
  p_unit text default 'unit', p_expires_on date default null, p_via text default 'app')
returns jsonb language plpgsql set search_path = '' as $$
declare
  hh uuid; tz text; today date;
  c public.categories%rowtype;
  prod uuid; exp_on date; src text;
  nm text := btrim(coalesce(p_name, ''));
begin
  if nm = '' then raise exception 'NAME_REQUIRED'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'BAD_QUANTITY'; end if;
  if p_unit not in ('unit', 'g', 'ml') then raise exception 'BAD_UNIT'; end if;
  if p_via not in ('app', 'mcp') then raise exception 'BAD_VIA'; end if;

  select m.household_id, h.timezone into hh, tz
    from public.household_members m join public.households h on h.id = m.household_id
   where m.user_id = (select auth.uid()) order by m.household_id limit 1;
  if hh is null then raise exception 'NO_HOUSEHOLD'; end if;

  if exists (select 1 from public.pantry_lots where id = p_lot_id) then          -- a repeat is a no-op
    return jsonb_build_object('lot_id', p_lot_id, 'repeat', true);
  end if;

  select * into c from public.categories where id = p_category;
  if not found then raise exception 'BAD_CATEGORY'; end if;
  if not c.is_food or c.shelf_life_days is null then raise exception 'NOT_FOOD'; end if;

  today := (now() at time zone tz)::date;
  if p_expires_on is not null then exp_on := p_expires_on; src := 'user';
  else exp_on := today + c.shelf_life_days; src := 'default'; end if;

  select id into prod from public.products
   where household_id = hh and lower(name) = lower(nm) and category_id = p_category and unit = p_unit
   order by created_at limit 1;
  if prod is null then
    prod := gen_random_uuid();
    insert into public.products (id, household_id, name, category_id, unit, source)
    values (prod, hh, nm, p_category, p_unit, 'manual');
  end if;

  insert into public.pantry_lots (id, household_id, product_id, location, initial_qty, expires_on, expiry_kind, expiry_source)
  values (p_lot_id, hh, prod, c.default_location, p_qty, exp_on, c.expiry_kind, src);
  insert into public.stock_movements (id, household_id, lot_id, delta, reason, actor, via)
  values (gen_random_uuid(), hh, p_lot_id, p_qty, 'adjust', (select auth.uid()), p_via);
  perform public.refresh_shopping_list(hh);

  return jsonb_build_object('lot_id', p_lot_id, 'expires_on', exp_on, 'expiry_source', src, 'repeat', false);
end $$;

revoke all on function public.add_item(uuid, text, text, numeric, text, date, text) from public, anon;
grant execute on function public.add_item(uuid, text, text, numeric, text, date, text) to authenticated;
