-- Step 2: the two read tools of the Claude connector, as SQL so the app can reuse them (rules live in the database).
-- Both are security invoker: they run with the caller's token, so RLS shows only the caller's household.
-- get_overview is a first version (pantry facts only). Spending, staples and the shopping list join it in later steps.

create function public.get_overview() returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'today', (now() at time zone 'Europe/Madrid')::date,
    'expired',          (select count(*) from public.pantry where state = 'expired'),
    'expiring_3_days',  (select count(*) from public.pantry where state = 'ok' and days_left <= 3),
    'to_check',         (select count(*) from public.pantry where state = 'check'),
    'unconfirmed',      (select count(*) from public.pantry where state = 'unconfirmed'),
    'in_stock',         (select count(*) from public.pantry where state in ('ok', 'check')),
    'products_without_ingredient',
      (select count(*) from public.products p join public.categories c on c.id = p.category_id
        where c.is_food and p.ingredient_id is null)
  );
$$;

create function public.list_pantry(
  p_location text default null, p_category text default null, p_state text default null,
  p_expiring_within_days int default null, p_limit int default 50)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'today', (now() at time zone 'Europe/Madrid')::date,
    'lots', coalesce(jsonb_agg(row order by (row ->> 'days_left')::int, row ->> 'name'), '[]'::jsonb))
  from (
    select jsonb_build_object(
      'lot_id', v.id,
      'name', left(v.name, 120),
      'category', v.category_id,
      'location', v.location,
      'qty_left', v.qty_left,
      'unit', v.unit,
      'packs_left', case when v.pack_size is not null then round(v.qty_left / v.pack_size, 2) end,
      'expires_on', v.effective_expires_on,
      'days_left', v.days_left,
      'state', v.state,
      'expiry_kind', v.expiry_kind,
      'expiry_source', v.expiry_source) as row
    from public.pantry v
    where (p_location is null or v.location = p_location)
      and (p_category is null or v.category_id = p_category)
      and (case when p_state is null then v.state in ('ok', 'check') else v.state = p_state end)
      and (p_expiring_within_days is null or v.days_left <= p_expiring_within_days)
    order by v.days_left, v.name
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) s;
$$;

revoke all on function public.get_overview(), public.list_pantry(text, text, text, int, int) from public, anon;
grant execute on function public.get_overview(), public.list_pantry(text, text, text, int, int) to authenticated;
