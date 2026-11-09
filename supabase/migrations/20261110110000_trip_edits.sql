-- Step 4 (D15): trip page edits. Fix a price, add a forgotten item, delete a trip (with undo).

-- Lines must add up to the total. After an edit: drop the old "Unclassified" line, and add a new one
-- only if the lines still don't match the ticket total.
create function public._recompute_trip(p_purchase uuid)
returns text language plpgsql set search_path = '' as $$
declare p public.purchases%rowtype; s bigint; n int; v text;
begin
  select * into p from public.purchases where id = p_purchase;
  delete from public.purchase_items where purchase_id = p.id and kind = 'adjustment';
  select coalesce(sum(line_total_cents), 0), count(*) into s, n from public.purchase_items where purchase_id = p.id;
  if n = 0 then v := 'total_only';
  elsif s = p.total_cents then v := 'sum_ok';
  else
    insert into public.purchase_items (id, purchase_id, household_id, line_no, kind, raw_text, printed_qty, printed_unit, line_total_cents)
    select gen_random_uuid(), p.id, p.household_id, coalesce(max(line_no), 0) + 1, 'adjustment', 'Unclassified', 1, 'pack', (p.total_cents - s)::int
      from public.purchase_items where purchase_id = p.id;
    v := 'adjusted';
  end if;
  update public.purchases set verification = v where id = p.id;
  return v;
end $$;
revoke all on function public._recompute_trip(uuid) from public, anon;
grant execute on function public._recompute_trip(uuid) to authenticated;   -- called by the functions below as the user

-- ── Fix a price on one line. The ticket total stays; the difference goes to "Unclassified". ─
create function public.fix_line_price(p_purchase uuid, p_line_no int, p_cents int)
returns jsonb language plpgsql set search_path = '' as $$
declare p public.purchases%rowtype; li public.purchase_items%rowtype; v text;
begin
  select * into p from public.purchases where id = p_purchase for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p.status <> 'confirmed' then raise exception 'NOT_CONFIRMED'; end if;
  select * into li from public.purchase_items where purchase_id = p.id and line_no = p_line_no for update;
  if not found or li.kind = 'adjustment' then raise exception 'BAD_LINE'; end if;
  if (li.kind in ('discount', 'refund')) <> (p_cents < 0) then raise exception 'BAD_AMOUNT'; end if;
  update public.purchase_items set line_total_cents = p_cents where id = li.id;
  update public.pantry_lots set unit_cost_cents = p_cents / nullif(initial_qty, 0) where purchase_item_id = li.id;
  v := public._recompute_trip(p.id);
  return jsonb_build_object('purchase_id', p.id, 'line_no', p_line_no, 'old_cents', li.line_total_cents, 'verification', v);
end $$;
revoke all on function public.fix_line_price(uuid, int, int) from public, anon;
grant execute on function public.fix_line_price(uuid, int, int) to authenticated;

-- ── Add a forgotten item to a trip. If the trip has an "Unclassified" amount, the item comes out of it;
-- otherwise the trip total grows by the item's price. Repeat-safe on the client's line id.
create function public.add_trip_item(
  p_purchase uuid, p_line_id uuid, p_name text, p_category text, p_qty numeric, p_unit text, p_cents int)
returns jsonb language plpgsql set search_path = '' as $$
declare
  p public.purchases%rowtype; c public.categories%rowtype; tz text; prod uuid; adj int; lot uuid; nm text := btrim(coalesce(p_name, ''));
  ln int; v text;
begin
  select * into p from public.purchases where id = p_purchase for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p.status <> 'confirmed' then raise exception 'NOT_CONFIRMED'; end if;
  if exists (select 1 from public.purchase_items where id = p_line_id) then
    return jsonb_build_object('purchase_id', p.id, 'repeat', true);
  end if;
  if nm = '' then raise exception 'NAME_REQUIRED'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'BAD_QUANTITY'; end if;
  if p_unit not in ('unit', 'g', 'ml') then raise exception 'BAD_UNIT'; end if;
  if p_cents is null or p_cents < 0 then raise exception 'BAD_AMOUNT'; end if;
  select * into c from public.categories where id = p_category;
  if not found then raise exception 'BAD_CATEGORY'; end if;
  select timezone into tz from public.households where id = p.household_id;

  select coalesce(sum(line_total_cents), 0)::int into adj from public.purchase_items where purchase_id = p.id and kind = 'adjustment';
  if adj < p_cents then
    update public.purchases set total_cents = total_cents + (p_cents - greatest(adj, 0)) where id = p.id;
  end if;

  select id into prod from public.products
   where household_id = p.household_id and lower(name) = lower(nm) and category_id = p_category and unit = p_unit
   order by created_at limit 1;
  if prod is null then
    prod := gen_random_uuid();
    insert into public.products (id, household_id, name, category_id, unit, source) values (prod, p.household_id, nm, p_category, p_unit, 'manual');
  end if;
  select coalesce(max(line_no), 0) + 1 into ln from public.purchase_items where purchase_id = p.id;
  insert into public.purchase_items (id, purchase_id, household_id, line_no, kind, raw_text, product_id, category_id, printed_qty, printed_unit, quantity, line_total_cents)
  values (p_line_id, p.id, p.household_id, ln, 'item', nm, prod, p_category, p_qty, case when p_unit = 'unit' then 'pack' else p_unit end, p_qty, p_cents);
  v := public._recompute_trip(p.id);

  if c.is_food and c.shelf_life_days is not null then
    lot := gen_random_uuid();
    insert into public.pantry_lots (id, household_id, product_id, purchase_id, purchase_item_id, location, initial_qty, expires_on, expiry_kind, expiry_source, unit_cost_cents)
    values (lot, p.household_id, prod, p.id, p_line_id, c.default_location, p_qty,
            (p.purchased_at at time zone tz)::date + c.shelf_life_days, c.expiry_kind, 'default', p_cents / p_qty);
    insert into public.stock_movements (id, household_id, lot_id, delta, reason, actor, via)
    values (gen_random_uuid(), p.household_id, lot, p_qty, 'purchase', (select auth.uid()), 'app');
    perform public.refresh_shopping_list(p.household_id);
  end if;
  return jsonb_build_object('purchase_id', p.id, 'lot_id', lot, 'verification', v, 'repeat', false);
end $$;
revoke all on function public.add_trip_item(uuid, uuid, text, text, numeric, text, int) from public, anon;
grant execute on function public.add_trip_item(uuid, uuid, text, text, numeric, text, int) to authenticated;

-- ── Delete a trip: it stops counting, and what's left of its pantry items is taken out. Undo puts both back.
-- The stock ledger is append-only, so "taking out" is an adjust movement tagged with the delete's id.
create function public.delete_trip(p_purchase uuid, p_request uuid default gen_random_uuid())
returns jsonb language plpgsql set search_path = '' as $$
declare p public.purchases%rowtype; n int := 0; l record;
begin
  select * into p from public.purchases where id = p_purchase for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p.status = 'void' then return jsonb_build_object('purchase_id', p.id, 'repeat', true); end if;
  if p.status <> 'confirmed' then raise exception 'NOT_CONFIRMED'; end if;
  for l in select v.id, v.qty_left from public.pantry v where v.purchase_id = p.id and v.qty_left > 0 loop
    insert into public.stock_movements (id, household_id, lot_id, delta, reason, actor, via, request_id)
    values (gen_random_uuid(), p.household_id, l.id, -l.qty_left, 'adjust', (select auth.uid()), 'app', p_request);
    n := n + 1;
  end loop;
  update public.purchases set status = 'void' where id = p.id;
  perform public.refresh_shopping_list(p.household_id);
  return jsonb_build_object('purchase_id', p.id, 'request_id', p_request, 'lots_cleared', n, 'repeat', false);
end $$;
revoke all on function public.delete_trip(uuid, uuid) from public, anon;
grant execute on function public.delete_trip(uuid, uuid) to authenticated;

create function public.undo_delete_trip(p_purchase uuid, p_request uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare p public.purchases%rowtype; m record;
begin
  select * into p from public.purchases where id = p_purchase for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p.status = 'confirmed' then return jsonb_build_object('purchase_id', p.id, 'repeat', true); end if;
  if p.status <> 'void' or p.confirmed_at is null then raise exception 'NOT_DELETED'; end if;
  begin
    update public.purchases set status = 'confirmed' where id = p.id;
  exception when unique_violation then
    raise exception 'ALREADY_LOGGED' using detail = 'the same ticket was logged again meanwhile';
  end;
  for m in select s.* from public.stock_movements s
            where s.request_id = p_request and s.household_id = p.household_id and s.reverses is null
              and not exists (select 1 from public.stock_movements u where u.reverses = s.id) loop
    insert into public.stock_movements (id, household_id, lot_id, delta, reason, actor, via, reverses)
    values (gen_random_uuid(), m.household_id, m.lot_id, -m.delta, 'adjust', (select auth.uid()), 'app', m.id);
  end loop;
  perform public.refresh_shopping_list(p.household_id);
  return jsonb_build_object('purchase_id', p.id, 'repeat', false);
end $$;
revoke all on function public.undo_delete_trip(uuid, uuid) from public, anon;
grant execute on function public.undo_delete_trip(uuid, uuid) to authenticated;
