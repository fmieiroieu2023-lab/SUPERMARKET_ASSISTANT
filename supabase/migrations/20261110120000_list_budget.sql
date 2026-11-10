-- First slice of steps 7 (budget) and 8 (shopping list). Names match the planned Claude tools
-- (get_shopping_list, update_shopping_list, set_budget, budget_status) so step 10 can expose them as they are.
-- Not yet: the automatic list rules (below par, runs out soon, usual purchase) in refresh_shopping_list.

-- The caller's household (one per user for now).
create function public.my_household() returns uuid
language sql stable set search_path = '' as $$
  select household_id from public.household_members where user_id = (select auth.uid()) order by household_id limit 1;
$$;
revoke all on function public.my_household() from public, anon;
grant execute on function public.my_household() to authenticated;

-- ── Shopping list ─────────────────────────────────────────────────────────────
-- Stock key (§6.6): an ingredient if the item has one (any brand, any shop), else the product, else the label.
create function public.list_key(p_ingredient text, p_product uuid, p_label text) returns text
language sql immutable set search_path = '' as $$
  select coalesce('i:' || p_ingredient, 'p:' || p_product::text, 'l:' || lower(p_label));
$$;
grant execute on function public.list_key(text, uuid, text) to authenticated;

-- Open items, items ticked in the last 3 days (in the basket, not logged yet), suggestions, and the cost estimate.
create function public.get_shopping_list()
returns jsonb language plpgsql stable set search_path = '' as $$
declare h uuid := public.my_household(); tz text; items jsonb; basket jsonb; sugg jsonb; est bigint; budget jsonb;
begin
  if h is null then raise exception 'NO_HOUSEHOLD'; end if;
  select timezone into tz from public.households where id = h;

  -- last time each key was bought: shop, product, price (the estimate uses that price once per item).
  -- Every product is findable by its product key, and by its ingredient key when it has one.
  with bought as (
    select pr.id as product_id, pr.ingredient_id, ch.name as chain, pr.name as product, i.line_total_cents as price_cents,
           (p.purchased_at at time zone tz)::date as on_date, p.purchased_at
      from public.purchase_items i
      join public.purchases p on p.id = i.purchase_id and p.status = 'confirmed'
      join public.products pr on pr.id = i.product_id
      join public.chains ch on ch.id = p.chain_id
     where i.household_id = h and i.kind = 'item'),
  keyed as (
    select 'p:' || product_id::text as k, * from bought
    union all
    select 'i:' || ingredient_id, * from bought where ingredient_id is not null),
  last as (
    select distinct on (k) k, chain, product, price_cents, on_date from keyed order by k, purchased_at desc)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'label', s.label, 'quantity', s.quantity, 'unit', s.unit, 'reasons', to_jsonb(s.reasons),
           'ingredient_id', s.ingredient_id, 'product_id', s.product_id, 'added_via', s.added_via,
           'last', case when l.k is not null then jsonb_build_object('chain', l.chain, 'product', l.product, 'price_cents', l.price_cents, 'on', l.on_date) end)
         order by s.created_at), '[]'::jsonb),
         coalesce(sum(l.price_cents), 0)
    into items, est
    from public.shopping_list_items s
    left join last l on l.k = public.list_key(s.ingredient_id, s.product_id, s.label)
   where s.household_id = h and s.status = 'open' and (s.snoozed_until is null or s.snoozed_until <= (now() at time zone tz)::date);

  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'label', s.label, 'bought_at', s.bought_at) order by s.bought_at desc), '[]'::jsonb)
    into basket
    from public.shopping_list_items s
   where s.household_id = h and s.status = 'bought' and s.reconciled_at is null and s.bought_at > now() - interval '3 days';

  -- Suggestions: things you finished or that went off in the last 30 days and have none of now.
  with lots as (
    select v.*, public.list_key(v.ingredient_id, v.product_id, null) as k from public.pantry v where v.household_id = h),
  keys as (
    select k, (array_agg(name order by created_at desc))[1] as label, max(ingredient_id) as ingredient_id,
           (array_agg(product_id order by created_at desc))[1] as product_id,
           sum(case when state in ('ok', 'check') then qty_left else 0 end) as on_hand,
           max((select max(m.occurred_at) from public.stock_movements m
                 where m.lot_id = lots.id and m.reason in ('consume', 'discard') and m.reverses is null
                   and not exists (select 1 from public.stock_movements u where u.reverses = m.id))) as last_used,
           bool_or(state = 'expired' and effective_expires_on > (now() at time zone tz)::date - 14) as went_off
      from lots group by k)
  select coalesce(jsonb_agg(jsonb_build_object('label', label, 'ingredient_id', ingredient_id, 'product_id', product_id,
                                               'why', case when went_off then 'went off' else 'finished' end) order by label), '[]'::jsonb)
    into sugg
    from keys
   where on_hand <= 0 and (last_used > now() - interval '30 days' or went_off)
     and not exists (select 1 from public.shopping_list_items s where s.household_id = h
                       and public.list_key(s.ingredient_id, s.product_id, s.label) = keys.k
                       and (s.status = 'open' or (s.status = 'bought' and s.reconciled_at is null and s.bought_at > now() - interval '3 days')));

  budget := public.budget_status();
  return jsonb_build_object('items', items, 'basket', basket, 'suggestions', sugg,
    'estimate_cents', est, 'estimate_unknown', (select count(*) from jsonb_array_elements(items) x where x->'last' is null),
    'budget_left_cents', budget->'left_cents');
end $$;

-- Add, tick (bought), untick, dismiss. Adds carry client ids (repeat-safe); an item already on the list is merged.
create function public.update_shopping_list(
  p_request uuid default gen_random_uuid(), p_add jsonb default '[]', p_bought uuid[] default '{}',
  p_reopen uuid[] default '{}', p_dismiss uuid[] default '{}', p_via text default 'app')
returns jsonb language plpgsql set search_path = '' as $$
declare h uuid := public.my_household(); a jsonb; ing text; prod uuid; lbl text; k text; ex uuid; r uuid; reason text;
begin
  if h is null then raise exception 'NO_HOUSEHOLD'; end if;
  if p_via not in ('app', 'mcp') then raise exception 'BAD_VIA'; end if;
  reason := case when p_via = 'mcp' then 'claude' else 'manual' end;

  for a in select value from jsonb_array_elements(coalesce(p_add, '[]'::jsonb)) loop
    if (a->>'id') is null then raise exception 'ID_REQUIRED'; end if;
    continue when exists (select 1 from public.shopping_list_items where id = (a->>'id')::uuid);
    prod := (select id from public.products where id = nullif(a->>'product_id', '')::uuid and household_id = h);
    ing := coalesce((select id from public.ingredients where id = a->>'ingredient_id'),
                    (select ingredient_id from public.products where id = prod));
    lbl := coalesce(nullif(btrim(a->>'label'), ''), (select name from public.products where id = prod),
                    (select name_es from public.ingredients where id = ing));
    if lbl is null then raise exception 'LABEL_REQUIRED'; end if;
    k := public.list_key(ing, prod, lbl);
    select id into ex from public.shopping_list_items
     where household_id = h and status = 'open' and public.list_key(ingredient_id, product_id, label) = k;
    if ex is not null then
      update public.shopping_list_items set
        reasons = case when reason = any(reasons) then reasons else reasons || reason end,
        quantity = greatest(quantity, nullif(a->>'quantity', '')::numeric)
      where id = ex;
    else
      insert into public.shopping_list_items (id, household_id, ingredient_id, product_id, label, quantity, unit, reasons, added_via)
      values ((a->>'id')::uuid, h, ing, prod, lbl, nullif(a->>'quantity', '')::numeric, nullif(a->>'unit', ''), array[reason], p_via);
    end if;
  end loop;

  update public.shopping_list_items set status = 'bought', bought_at = now()
   where household_id = h and id = any(coalesce(p_bought, '{}')) and status = 'open';
  update public.shopping_list_items set status = 'dismissed', bought_at = null
   where household_id = h and id = any(coalesce(p_dismiss, '{}')) and status in ('open', 'bought');
  foreach r in array coalesce(p_reopen, '{}') loop
    begin
      update public.shopping_list_items set status = 'open', bought_at = null
       where household_id = h and id = r and status in ('bought', 'dismissed');
    exception when unique_violation then null;   -- the same thing is already back on the list
    end;
  end loop;
  return public.get_shopping_list();
end $$;

-- ── Budget (§6.7) ─────────────────────────────────────────────────────────────
-- p_month null: the budget for every month. A month: only that month.
create function public.set_budget(p_amount_cents int, p_month date default null, p_request uuid default null)
returns jsonb language plpgsql set search_path = '' as $$
declare h uuid := public.my_household();
begin
  if h is null then raise exception 'NO_HOUSEHOLD'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'BAD_AMOUNT'; end if;
  if p_month is null then
    update public.households set monthly_budget_cents = p_amount_cents where id = h;
  else
    insert into public.budgets (household_id, month, amount_cents) values (h, date_trunc('month', p_month)::date, p_amount_cents)
    on conflict (household_id, month) do update set amount_cents = excluded.amount_cents;
  end if;
  return public.budget_status(p_month);
end $$;

-- Spent, left, breakdowns, waste, last 6 months, and the projection from shopping days (§6.7).
-- p_today exists for tests; normal callers leave it out.
create function public.budget_status(p_month date default null, p_today date default null)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  h uuid := public.my_household(); tz text; today date; m date; m_end date; bud int; spent bigint; trips int;
  k int; span int; r numeric; g numeric; last_day date; n_day date; u int; proj numeric; tol numeric; med_total numeric;
  days date[]; day_cents bigint[]; projection jsonb; cats jsonb; chains jsonb; hist jsonb; waste numeric; food bigint; nonfood bigint; no_total int;
begin
  if h is null then raise exception 'NO_HOUSEHOLD'; end if;
  select timezone into tz from public.households where id = h;
  today := coalesce(p_today, (now() at time zone tz)::date);
  m := date_trunc('month', coalesce(p_month, today))::date;
  m_end := (m + interval '1 month')::date - 1;
  bud := coalesce((select amount_cents from public.budgets where household_id = h and month = m),
                  (select monthly_budget_cents from public.households where id = h));

  select coalesce(sum(total_cents), 0), count(*) into spent, trips
    from public.purchases where household_id = h and status = 'confirmed'
     and (purchased_at at time zone tz)::date between m and m_end;

  -- by category, from the lines (adjustments = Unclassified, discounts separate), so totals always reconcile
  with l as (
    select case when i.kind = 'adjustment' then 'unclassified' when i.kind in ('discount', 'refund') then 'discounts'
                else coalesce(pr.category_id, i.category_id, 'unclassified') end as cat,
           i.line_total_cents as cents
      from public.purchase_items i
      join public.purchases p on p.id = i.purchase_id and p.status = 'confirmed'
      left join public.products pr on pr.id = i.product_id
     where i.household_id = h and (p.purchased_at at time zone tz)::date between m and m_end)
  select coalesce(jsonb_agg(jsonb_build_object('category_id', cat, 'name', coalesce(c.name_es, initcap(cat)), 'is_food', c.is_food, 'cents', s)
                            order by s desc), '[]'::jsonb),
         coalesce(sum(s) filter (where c.is_food), 0), coalesce(sum(s) filter (where c.is_food is false), 0)
    into cats, food, nonfood
    from (select cat, sum(cents) s from l group by cat) x left join public.categories c on c.id = x.cat;

  select coalesce(jsonb_agg(jsonb_build_object('chain', ch.name, 'cents', s, 'trips', n) order by s desc), '[]'::jsonb) into chains
    from (select chain_id, sum(total_cents) s, count(*) n from public.purchases
           where household_id = h and status = 'confirmed' and (purchased_at at time zone tz)::date between m and m_end
           group by chain_id) x join public.chains ch on ch.id = x.chain_id;

  -- waste in €: thrown-away quantities × what they cost (undone throws don't count)
  select coalesce(sum(-mv.delta * l.unit_cost_cents), 0) into waste
    from public.stock_movements mv join public.pantry_lots l on l.id = mv.lot_id
   where mv.household_id = h and mv.reason = 'discard' and mv.reverses is null
     and not exists (select 1 from public.stock_movements u where u.reverses = mv.id)
     and (mv.occurred_at at time zone tz)::date between m and m_end;

  select coalesce(jsonb_agg(jsonb_build_object('month', to_char(mm, 'YYYY-MM'), 'cents', coalesce(s, 0)) order by mm), '[]'::jsonb) into hist
    from generate_series(m - interval '5 months', m, interval '1 month') mm
    left join lateral (select sum(total_cents) s from public.purchases
                        where household_id = h and status = 'confirmed'
                          and date_trunc('month', purchased_at at time zone tz) = mm) z on true;

  select count(*) into no_total from public.purchases
   where household_id = h and status = 'draft' and source in ('scan', 'manual') and total_cents is null;

  -- Projection, current month only, from shopping days (one Madrid date = one shopping day) of the last 90 days.
  if m = date_trunc('month', today)::date then
    select coalesce(array_agg(d order by d), '{}'), coalesce(array_agg(cents order by d), '{}') into days, day_cents
      from (select (purchased_at at time zone tz)::date d, sum(total_cents) cents from public.purchases
             where household_id = h and status = 'confirmed'
               and (purchased_at at time zone tz)::date between today - 90 and today
             group by 1) x;
    k := coalesce(array_length(days, 1), 0);
    span := case when k > 0 then days[k] - days[1] else 0 end;
    last_day := case when k > 0 then days[k] end;
    if k >= 3 and span >= 14 then
      r := (select sum(c) from unnest(day_cents[1:k - 1]) c)::numeric / span;
      g := least(14, greatest(3, (select percentile_cont(0.5) within group (order by days[i] - days[i - 1])
                                    from generate_series(2, k) i)));
      n_day := last_day + ceil(g)::int;
      u := greatest(0, m_end - greatest(today, n_day) + 1);
      proj := spent + r * u;
      select percentile_cont(0.5) within group (order by c) into med_total from unnest(day_cents) c;
      tol := greatest(coalesce(bud, 0) * 0.05, med_total / 2);
      projection := jsonb_build_object('projected_cents', round(proj)::int, 'daily_cents', round(r)::int, 'gap_days', g,
                                       'next_shop', n_day, 'alert', bud is not null and proj > bud + tol);
    else
      projection := jsonb_build_object('needs', 'Needs 3 shopping days over 2 weeks', 'shopping_days', k);
    end if;
  end if;

  return jsonb_build_object(
    'month', to_char(m, 'YYYY-MM'), 'budget_cents', bud, 'spent_cents', spent, 'trips', trips,
    'left_cents', case when bud is null then null else bud - spent end,
    'pct', case when bud is null then null else round(100.0 * spent / bud) end,
    'alert', case when bud is null then null when spent >= bud then 'over' when spent >= bud * 0.8 then 'near' end,
    'days_left', greatest(0, m_end - today + case when m = date_trunc('month', today)::date then 1 else 0 end),
    'by_category', cats, 'by_chain', chains, 'food_cents', food, 'nonfood_cents', nonfood,
    'waste_cents', round(waste)::int, 'history', hist, 'trips_without_total', no_total, 'projection', projection);
end $$;

revoke all on function public.get_shopping_list(), public.update_shopping_list(uuid, jsonb, uuid[], uuid[], uuid[], text),
  public.set_budget(int, date, uuid), public.budget_status(date, date) from public, anon;
grant execute on function public.get_shopping_list(), public.update_shopping_list(uuid, jsonb, uuid[], uuid[], uuid[], text),
  public.set_budget(int, date, uuid), public.budget_status(date, date) to authenticated;

-- Item page: add the product id, so "Add to shopping list" can link the exact product.
create or replace function public.get_lot(p_lot uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'lot_id', v.id, 'product_id', v.product_id, 'name', v.name, 'category_id', v.category_id, 'category', c.name_es,
    'ingredient_id', v.ingredient_id, 'ingredient', (select name_es from public.ingredients where id = v.ingredient_id),
    'unit', v.unit, 'location', v.location, 'initial_qty', v.initial_qty, 'qty_left', v.qty_left,
    'expires_on', v.expires_on, 'effective_expires_on', v.effective_expires_on, 'days_left', v.days_left, 'state', v.state,
    'expiry_kind', v.expiry_kind, 'expiry_source', v.expiry_source, 'opened_on', v.opened_on, 'frozen_on', v.frozen_on,
    'can_open', coalesce(pr.opened_shelf_life_days, c.opened_shelf_life_days) is not null,
    'can_freeze', c.freezer_life_days is not null or v.category_id = 'frozen',
    'on_list', exists (select 1 from public.shopping_list_items s where s.household_id = v.household_id and s.status = 'open'
                        and public.list_key(s.ingredient_id, s.product_id, s.label) = public.list_key(v.ingredient_id, v.product_id, null)),
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
