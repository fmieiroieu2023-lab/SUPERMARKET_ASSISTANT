-- English names first, Spanish underneath (Francisco, 2026-11-10), and quantities on shopping-list items.

-- ── English names ─────────────────────────────────────────────────────────────
alter table public.categories add column name_en text;
update public.categories c set name_en = v.en from (values
  ('fresh_meat', 'Fresh meat'),
  ('fresh_poultry', 'Poultry'),
  ('fresh_fish', 'Fresh fish & seafood'),
  ('cured_meat', 'Cured meats & cold cuts'),
  ('dairy_chilled', 'Fresh dairy'),
  ('yogurt_dessert', 'Yogurts & desserts'),
  ('cheese', 'Cheese'),
  ('eggs', 'Eggs'),
  ('milk_uht', 'Milk & plant drinks'),
  ('fresh_veg', 'Fresh vegetables'),
  ('fresh_fruit', 'Fresh fruit'),
  ('salad_bagged', 'Bagged salads'),
  ('bread_fresh', 'Fresh bread'),
  ('bread_packaged', 'Sliced & packaged bread'),
  ('bakery_sweet', 'Pastries & bakery'),
  ('dry_goods', 'Pasta, rice & pulses'),
  ('canned_jarred', 'Tins & jars'),
  ('oils_condiments', 'Oils, sauces & condiments'),
  ('spices', 'Spices & dried herbs'),
  ('breakfast_snacks', 'Cereals, biscuits & snacks'),
  ('sweets_chocolate', 'Sweets & chocolate'),
  ('frozen', 'Frozen'),
  ('ready_meals', 'Ready meals'),
  ('plant_chilled', 'Tofu & plant protein'),
  ('beverages', 'Drinks'),
  ('alcohol', 'Wine, beer & spirits'),
  ('coffee_tea', 'Coffee & tea'),
  ('nuts_dried', 'Nuts & dried fruit'),
  ('cleaning', 'Cleaning'),
  ('toiletries', 'Toiletries & personal care'),
  ('household_other', 'Home & other'),
  ('pet', 'Pets')
) v(id, en) where c.id = v.id;

-- Products keep the name from the receipt (Spanish) and get an English one: from the receipt reader, or typed.
-- When it is missing, screens fall back to the ingredient's English name.
alter table public.products add column name_en text;

create or replace function public.list_pantry(
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
      'name_en', left(coalesce(pr.name_en, ing.name_en), 120),
      'product_id', v.product_id,
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
    left join public.products pr on pr.id = v.product_id
    left join public.ingredients ing on ing.id = v.ingredient_id
    where (p_location is null or v.location = p_location)
      and (p_category is null or v.category_id = p_category)
      and (case when p_state is null then v.state in ('ok', 'check') else v.state = p_state end)
      and (p_expiring_within_days is null or v.days_left <= p_expiring_within_days)
    order by v.days_left, v.name
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) s;
$$;

create or replace function public.receipt_review(p_purchase uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  p public.purchases%rowtype; tz text; lines jsonb; dup record; s bigint;
begin
  select * into p from public.purchases where id = p_purchase;
  if not found then raise exception 'NOT_FOUND'; end if;
  select timezone into tz from public.households where id = p.household_id;

  select coalesce(sum(line_total_cents), 0) into s from public.purchase_items where purchase_id = p.id;

  select coalesce(jsonb_agg(x order by (x->>'line_no')::int), '[]'::jsonb) into lines from (
    select jsonb_build_object(
      'line_no', i.line_no, 'kind', i.kind, 'raw_text', i.raw_text,
      'name_guess', coalesce(g->>'name_guess', i.raw_text),
      'name_en', coalesce(pr.name_en, nullif(g->>'name_en', '')),
      'category_id', coalesce(pr.category_id, i.category_id),
      'is_food', coalesce(c.is_food, true),
      'printed_qty', i.printed_qty, 'printed_unit', i.printed_unit,
      'line_total_cents', i.line_total_cents,
      'product_id', i.product_id, 'product_name', pr.name, 'product_unit', pr.unit,
      'match', case when i.kind <> 'item' then 'none'
                    when i.product_id is not null then 'matched'
                    when sug.product_id is not null then 'suggested'
                    when c.is_food is false then 'spend'
                    else 'new' end,
      'suggestion', case when i.product_id is null and sug.product_id is not null
                         then jsonb_build_object('product_id', sug.product_id, 'name', sug.name, 'score', round(sug.score::numeric, 2)) end,
      'ingredient_id', coalesce(pr.ingredient_id, ing.ingredient_id),
      'ingredient_name', (select name_es from public.ingredients where id = coalesce(pr.ingredient_id, ing.ingredient_id))
    ) as x
    from public.purchase_items i
    left join public.products pr on pr.id = i.product_id and pr.household_id = i.household_id
    left join public.categories c on c.id = coalesce(pr.category_id, i.category_id)
    left join lateral (select p.parse_output->'lines'->(i.line_no - 1) as g) gg on true
    -- (ii) trigram suggestion from this chain's aliases and from product names
    left join lateral (
      select * from (
        select a.product_id, pp.name, extensions.similarity(a.alias, public.normalise_alias(i.raw_text)) as score
          from public.receipt_aliases a join public.products pp on pp.id = a.product_id
         where a.household_id = p.household_id and a.chain_id = p.chain_id
        union all
        select pp.id, pp.name, extensions.similarity(public.normalise_alias(pp.name), public.normalise_alias(coalesce(gg.g->>'name_guess', i.raw_text)))
          from public.products pp where pp.household_id = p.household_id
      ) cand where cand.score >= 0.6 order by cand.score desc limit 1
    ) sug on i.product_id is null and i.kind = 'item'
    -- (iii) ingredient: the model's guess if it is a real id, else the best alias match ≥ 0.5
    left join lateral (
      select coalesce(
        (select id from public.ingredients where id = gg.g->>'ingredient_guess'),
        (select a.ingredient_id from public.ingredient_aliases a
          where extensions.similarity(public.normalise_alias(a.alias), public.normalise_alias(coalesce(gg.g->>'name_guess', i.raw_text))) >= 0.5
          order by extensions.similarity(public.normalise_alias(a.alias), public.normalise_alias(coalesce(gg.g->>'name_guess', i.raw_text))) desc limit 1)
      ) as ingredient_id
    ) ing on coalesce(c.is_food, true)
    where i.purchase_id = p.id
  ) t;

  select * into dup from public.classify_duplicate(
    p.household_id, p.chain_id, p.purchased_at, p.time_source, p.total_cents,
    nullif(trim(p.parse_output->>'ticket_number'), ''), now(), p.id);

  return jsonb_build_object(
    'purchase_id', p.id, 'status', p.status, 'chain_id', p.chain_id, 'store_label', p.store_label,
    'purchased_at', p.purchased_at, 'local_date', (p.purchased_at at time zone tz)::date,
    'time_source', p.time_source, 'total_cents', p.total_cents, 'lines_sum_cents', s,
    'missing_cents', coalesce(p.total_cents, 0) - s,
    'ticket_number', p.parse_output->>'ticket_number', 'model', p.parse_output->'_meta'->>'model',
    'duplicate', jsonb_build_object('verdict', dup.verdict, 'rule', dup.rule, 'other_purchase_id', dup.other_purchase_id,
                                    'preselect', dup.preselect, 'evidence', dup.evidence, 'notice', dup.notice),
    'lines', lines);
end $$;

create or replace function public.finish_receipt(
  p_purchase uuid, p_lines jsonb default '[]', p_header jsonb default '{}',
  p_accept_difference boolean default false, p_force_new boolean default false, p_merge_into uuid default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  p public.purchases%rowtype; tz text; e jsonb; a text; prod uuid; cat text; res jsonb; dates jsonb; li public.purchase_items%rowtype;
begin
  select * into p from public.purchases where id = p_purchase for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p.status = 'confirmed' then return jsonb_build_object('purchase_id', p.id, 'repeat', true); end if;
  if p.status = 'void' then raise exception 'NOT_A_DRAFT'; end if;
  select timezone into tz from public.households where id = p.household_id;

  update public.purchases set
    chain_id = coalesce((select id from public.chains where id = p_header->>'chain_id'), chain_id),
    total_cents = coalesce(nullif(p_header->>'total_cents', '')::int, total_cents),
    purchased_at = coalesce(((p_header->>'purchased_at')::timestamp at time zone tz), purchased_at),
    time_source = case when p_header ? 'purchased_at' then 'entered' else time_source end
  where id = p.id;

  for e in select value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    select * into li from public.purchase_items where purchase_id = p.id and line_no = (e->>'line_no')::int;
    if not found then raise exception 'BAD_LINE' using detail = e->>'line_no'; end if;
    a := e->>'action';
    if e ? 'line_total_cents' then
      update public.purchase_items set line_total_cents = (e->>'line_total_cents')::int where id = li.id;
    end if;
    if a = 'match' then
      prod := (e->>'product_id')::uuid;
      if not exists (select 1 from public.products where id = prod and household_id = p.household_id) then
        raise exception 'PRODUCT_NOT_FOUND';
      end if;
      -- answers to "how much is one pack?" / "about how much does one weigh?" are saved once on the product
      update public.products set
        pack_size = coalesce(nullif(e->>'pack_size', '')::numeric, pack_size),
        unit_weight_g = coalesce(nullif(e->>'unit_weight_g', '')::numeric, unit_weight_g),
        ingredient_id = coalesce(ingredient_id, (select id from public.ingredients where id = e->>'ingredient_id')),
        name_en = coalesce(name_en, nullif(trim(e->>'name_en'), ''))
      where id = prod;
      update public.purchase_items set product_id = prod,
        category_id = (select category_id from public.products where id = prod) where id = li.id;
    elsif a = 'new' then
      cat := (select id from public.categories where id = e->>'category_id');
      if cat is null then raise exception 'BAD_CATEGORY'; end if;
      prod := coalesce((e->>'product_id')::uuid, gen_random_uuid());
      insert into public.products (id, household_id, name, name_en, category_id, ingredient_id, unit, pack_size, unit_weight_g, source)
      values (prod, p.household_id, coalesce(nullif(trim(e->>'name'), ''), li.raw_text, 'Product'), nullif(trim(e->>'name_en'), ''), cat,
              (select id from public.ingredients where id = e->>'ingredient_id'),
              coalesce(e->>'unit', case when li.printed_unit = 'pack' then 'unit' else li.printed_unit end),
              nullif(e->>'pack_size', '')::numeric, nullif(e->>'unit_weight_g', '')::numeric, 'receipt')
      on conflict (id) do nothing;
      update public.purchase_items set product_id = prod, category_id = cat where id = li.id;
    elsif a = 'spend' then
      update public.purchase_items set product_id = null,
        category_id = coalesce((select id from public.categories where id = e->>'category_id'), category_id) where id = li.id;
    elsif a is not null then
      raise exception 'BAD_ACTION' using detail = a;
    end if;
  end loop;

  res := public.confirm_purchase(p.id, p_accept_difference, p_merge_into, p_force_new);

  -- Lots that need a printed date: category asks for one, or a short-life product whose kind isn't confirmed yet.
  select coalesce(jsonb_agg(jsonb_build_object(
           'lot_id', l.id, 'name', pr.name, 'expires_on', l.expires_on, 'expiry_kind', l.expiry_kind,
           'ask', c.ask_printed_date) order by l.expires_on), '[]'::jsonb)
    into dates
    from public.pantry_lots l
    join public.products pr on pr.id = l.product_id and pr.household_id = l.household_id
    join public.categories c on c.id = pr.category_id
   where l.purchase_id = (res->>'purchase_id')::uuid and l.expiry_source = 'default'
     and (c.ask_printed_date or (not pr.kind_confirmed and c.shelf_life_days <= 60 and c.expiry_kind <> 'estimate'));

  return res || jsonb_build_object('check_dates', dates);
end $$;

-- ── Quantities on the shopping list ───────────────────────────────────────────
create function public.set_list_quantity(p_item uuid, p_quantity numeric, p_unit text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare h uuid := public.my_household();
begin
  if p_quantity is not null and p_quantity <= 0 then raise exception 'BAD_QUANTITY'; end if;
  if p_unit is not null and p_unit not in ('pack', 'g', 'kg', 'ml', 'l') then raise exception 'BAD_UNIT'; end if;
  update public.shopping_list_items set quantity = p_quantity, unit = case when p_quantity is null then null else p_unit end
   where id = p_item and household_id = h and status = 'open';
  if not found then raise exception 'NOT_FOUND'; end if;
  return public.get_shopping_list();
end $$;
revoke all on function public.set_list_quantity(uuid, numeric, text) from public, anon;
grant execute on function public.set_list_quantity(uuid, numeric, text) to authenticated;
