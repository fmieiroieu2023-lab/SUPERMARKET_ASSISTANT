-- Step 4b: pantry flow. Undo (D16), opened / frozen / still-have marks, and the item page's data.

-- ── Undo a stock movement: append the opposite movement (the ledger is append-only) ─
-- p_undo_id is client-generated, so a double tap undoes once.
create function public.undo_movement(p_movement uuid, p_undo_id uuid default gen_random_uuid(), p_via text default 'app')
returns jsonb language plpgsql set search_path = '' as $$
declare m public.stock_movements%rowtype; left_qty numeric;
begin
  if p_via not in ('app', 'mcp') then raise exception 'BAD_VIA'; end if;
  select * into m from public.stock_movements where id = p_movement;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform 1 from public.pantry_lots where id = m.lot_id for update;
  if m.reverses is not null then raise exception 'CANNOT_UNDO_AN_UNDO'; end if;
  if exists (select 1 from public.stock_movements where reverses = p_movement) or exists (select 1 from public.stock_movements where id = p_undo_id) then
    select coalesce(sum(delta), 0) into left_qty from public.stock_movements where lot_id = m.lot_id;
    return jsonb_build_object('lot_id', m.lot_id, 'qty_left', left_qty, 'repeat', true);
  end if;
  insert into public.stock_movements (id, household_id, lot_id, delta, reason, actor, via, reverses)
  values (p_undo_id, m.household_id, m.lot_id, -m.delta, 'adjust', (select auth.uid()), p_via, m.id);
  perform public.refresh_shopping_list(m.household_id);
  select coalesce(sum(delta), 0) into left_qty from public.stock_movements where lot_id = m.lot_id;
  return jsonb_build_object('lot_id', m.lot_id, 'qty_left', left_qty, 'repeat', false);
end $$;
revoke all on function public.undo_movement(uuid, uuid, text) from public, anon;
grant execute on function public.undo_movement(uuid, uuid, text) to authenticated;

-- ── Marks on a lot. The pantry view turns opened_on / frozen_on into the effective date. ─
-- Returns the previous marks so the app can undo with p_action = 'restore', p_prev = that object.
create function public.mark_lot(p_lot uuid, p_action text, p_prev jsonb default null)
returns jsonb language plpgsql set search_path = '' as $$
declare l public.pantry_lots%rowtype; tz text; today date; prev jsonb; loc text;
begin
  select * into l from public.pantry_lots where id = p_lot for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select timezone into tz from public.households where id = l.household_id;
  today := (now() at time zone tz)::date;
  prev := jsonb_build_object('opened_on', l.opened_on, 'frozen_on', l.frozen_on, 'location', l.location, 'checked_on', l.checked_on);

  if p_action = 'opened' then
    update public.pantry_lots set opened_on = coalesce(opened_on, today) where id = l.id;
  elsif p_action = 'frozen' then
    update public.pantry_lots set frozen_on = coalesce(frozen_on, today), location = 'freezer' where id = l.id;
  elsif p_action = 'thawed' then
    -- back to the category's usual place; the opened-life rule then applies from today
    select c.default_location into loc from public.products p join public.categories c on c.id = p.category_id where p.id = l.product_id;
    update public.pantry_lots set frozen_on = null, location = case when loc = 'freezer' then 'fridge' else loc end,
                                  opened_on = coalesce(opened_on, today) where id = l.id;
  elsif p_action = 'still_have' then
    update public.pantry_lots set checked_on = today where id = l.id;
  elsif p_action = 'restore' then
    if p_prev is null then raise exception 'BAD_ACTION'; end if;
    update public.pantry_lots set opened_on = (p_prev->>'opened_on')::date, frozen_on = (p_prev->>'frozen_on')::date,
           location = coalesce(p_prev->>'location', location), checked_on = (p_prev->>'checked_on')::date where id = l.id;
  else
    raise exception 'BAD_ACTION';
  end if;
  return jsonb_build_object('lot_id', l.id, 'prev', prev);
end $$;
revoke all on function public.mark_lot(uuid, text, jsonb) from public, anon;
grant execute on function public.mark_lot(uuid, text, jsonb) to authenticated;

-- ── Item page: the lot, where and when it was bought, and its history ────────
create function public.get_lot(p_lot uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'lot_id', v.id, 'name', v.name, 'category_id', v.category_id, 'category', c.name_es,
    'ingredient_id', v.ingredient_id, 'ingredient', (select name_es from public.ingredients where id = v.ingredient_id),
    'unit', v.unit, 'location', v.location, 'initial_qty', v.initial_qty, 'qty_left', v.qty_left,
    'expires_on', v.expires_on, 'effective_expires_on', v.effective_expires_on, 'days_left', v.days_left, 'state', v.state,
    'expiry_kind', v.expiry_kind, 'expiry_source', v.expiry_source, 'opened_on', v.opened_on, 'frozen_on', v.frozen_on,
    'can_open', coalesce(pr.opened_shelf_life_days, c.opened_shelf_life_days) is not null,
    'can_freeze', c.freezer_life_days is not null or v.category_id = 'frozen',
    'bought', (select jsonb_build_object('purchase_id', p.id, 'chain', ch.name, 'local_date', (p.purchased_at at time zone h.timezone)::date,
                                         'line_total_cents', i.line_total_cents, 'printed_qty', i.printed_qty, 'printed_unit', i.printed_unit)
                 from public.purchases p
                 join public.chains ch on ch.id = p.chain_id
                 left join public.purchase_items i on i.id = v.purchase_item_id
                where p.id = v.purchase_id and p.status = 'confirmed'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'delta', m.delta, 'reason', m.reason,
                                                            'at', m.occurred_at, 'via', m.via, 'undone', exists (select 1 from public.stock_movements u where u.reverses = m.id),
                                                            'is_undo', m.reverses is not null) order by m.occurred_at desc)
                          from public.stock_movements m where m.lot_id = v.id), '[]'::jsonb))
  from public.pantry v
  join public.products pr on pr.id = v.product_id
  join public.categories c on c.id = v.category_id
  join public.households h on h.id = v.household_id
  where v.id = p_lot;
$$;
revoke all on function public.get_lot(uuid) from public, anon;
grant execute on function public.get_lot(uuid) to authenticated;
