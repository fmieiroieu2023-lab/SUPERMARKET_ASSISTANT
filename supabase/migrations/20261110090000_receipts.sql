-- Step 4: receipt photos. Storage bucket, quota, draft from the parser, review data, finish (confirm), dates, trips.
-- Reference: arena-winning-plan.md §6.1. Business rules stay here; the parse-receipt function only calls Claude.

-- ── Storage: the private "receipts" bucket and its member-only policy already exist (step 1, rls.sql).
-- Paths: receipts/{household_id}/{purchase_id}/{n}.jpg. Here we only cap size and file types.
update storage.buckets set file_size_limit = 10485760,
       allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf']
 where id = 'receipts';

-- ── Daily parse quota (protects the Anthropic spend cap) ─────────────────────
-- SECURITY DEFINER because users can only read usage_counters; it checks membership itself.
create function public.take_receipt_quota(p_household uuid, p_limit int default 20)
returns int language plpgsql security definer set search_path = '' as $$
declare n int; tz text;
begin
  if not public.is_member(p_household) then raise exception 'NOT_FOUND'; end if;
  select timezone into tz from public.households where id = p_household;
  insert into public.usage_counters as u (household_id, day, receipt_parses)
  values (p_household, (now() at time zone tz)::date, 1)
  on conflict (household_id, day) do update set receipt_parses = u.receipt_parses + 1
  returning receipt_parses into n;
  if n > p_limit then raise exception 'QUOTA_EXCEEDED' using detail = format('%s receipts today, limit %s', n - 1, p_limit); end if;
  return p_limit - n;
end $$;
revoke all on function public.take_receipt_quota(uuid, int) from public, anon;
grant execute on function public.take_receipt_quota(uuid, int) to authenticated;

-- ── Review data for a draft: lines + matches + suggestions + duplicate verdict ─
create function public.receipt_review(p_purchase uuid)
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
revoke all on function public.receipt_review(uuid) from public, anon;
grant execute on function public.receipt_review(uuid) to authenticated;

-- ── Draft from the parser's output. Repeat-safe on the client's purchase id. ─
create function public.save_receipt_draft(
  p_purchase uuid, p_household uuid, p_paths text[], p_parse jsonb, p_source text default 'receipt_photo')
returns jsonb language plpgsql set search_path = '' as $$
declare
  tz text; st text; chain text; at_local timestamp; at_ts timestamptz; tsrc text := 'printed';
  ln jsonb; k text; amt int; q numeric; u text; cat text; n int := 0; prod uuid; raw text;
begin
  if not public.is_member(p_household) then raise exception 'NOT_FOUND'; end if;
  if p_source not in ('receipt_photo', 'receipt_file') then raise exception 'BAD_SOURCE'; end if;
  select status into st from public.purchases where id = p_purchase;
  if st is not null and st <> 'draft' then return public.receipt_review(p_purchase); end if;
  select timezone into tz from public.households where id = p_household;

  -- (d) chain is a known id, else 'other'
  chain := coalesce((select id from public.chains where id = lower(p_parse->>'chain')), 'other');
  -- (b) printed time: not in the future, at most 90 days old; else "now, entered"
  begin at_local := (p_parse->>'purchased_at')::timestamp; exception when others then at_local := null; end;
  at_ts := case when at_local is null then null else at_local at time zone tz end;
  if at_ts is null or at_ts > now() + interval '10 minutes' or at_ts < now() - interval '90 days' then
    at_ts := now(); tsrc := 'entered';
  end if;

  insert into public.purchases (id, household_id, chain_id, store_label, purchased_at, time_source, status, source,
                                total_cents, receipt_paths, parse_output, created_by, created_via)
  values (p_purchase, p_household, chain, nullif(trim(p_parse->>'store_label'), ''), at_ts, tsrc, 'draft', p_source,
          nullif(p_parse->>'total_cents', '')::int, coalesce(p_paths, '{}'), p_parse, (select auth.uid()), 'app')
  on conflict (id) do update set chain_id = excluded.chain_id, store_label = excluded.store_label,
    purchased_at = excluded.purchased_at, time_source = excluded.time_source, total_cents = excluded.total_cents,
    receipt_paths = excluded.receipt_paths, parse_output = excluded.parse_output
  where public.purchases.status = 'draft';

  delete from public.purchase_items where purchase_id = p_purchase;
  for ln in select value from jsonb_array_elements(coalesce(p_parse->'lines', '[]'::jsonb)) loop
    n := n + 1;
    amt := coalesce(nullif(ln->>'line_total_cents', '')::int, 0);
    k := coalesce(ln->>'kind', 'item');
    if k not in ('item', 'discount', 'refund') then k := 'item'; end if;
    -- sign follows the kind: discounts and refunds are negative, items are not
    if k = 'item' and amt < 0 then k := 'discount'; end if;
    if k in ('discount', 'refund') and amt > 0 then amt := -amt; end if;
    if k in ('discount', 'refund') and amt = 0 then k := 'item'; end if;
    -- (c) quantities > 0; units from the schema only
    begin q := (ln->>'printed_qty')::numeric; exception when others then q := null; end;
    if q is null or q <= 0 then q := 1; end if;
    u := coalesce(ln->>'printed_unit', 'pack'); if u not in ('pack', 'g', 'ml') then u := 'pack'; end if;
    -- (e) unknown category becomes null instead of failing
    cat := (select id from public.categories where id = ln->>'category_guess');
    raw := nullif(trim(ln->>'raw_text'), '');
    -- (i) exact alias for this chain → automatic match
    prod := case when k = 'item' and raw is not null then
      (select a.product_id from public.receipt_aliases a
        where a.household_id = p_household and a.chain_id = chain and a.alias = public.normalise_alias(raw)) end;
    insert into public.purchase_items (id, purchase_id, household_id, line_no, kind, raw_text, product_id, category_id,
                                       printed_qty, printed_unit, line_total_cents)
    values (gen_random_uuid(), p_purchase, p_household, n, k, raw, prod,
            coalesce(cat, (select category_id from public.products where id = prod)), q, u, amt);
  end loop;

  return public.receipt_review(p_purchase);
end $$;
revoke all on function public.save_receipt_draft(uuid, uuid, text[], jsonb, text) from public, anon;
grant execute on function public.save_receipt_draft(uuid, uuid, text[], jsonb, text) to authenticated;

-- ── Finish: apply the review edits, then confirm_purchase. One transaction. ──
-- p_lines: [{line_no, action: 'match'|'new'|'spend', product_id, name, category_id, ingredient_id, unit,
--            pack_size, unit_weight_g, line_total_cents}]
-- p_header: {chain_id, total_cents, purchased_at (local "YYYY-MM-DDTHH:MM")} — only the keys you change.
create function public.finish_receipt(
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
        ingredient_id = coalesce(ingredient_id, (select id from public.ingredients where id = e->>'ingredient_id'))
      where id = prod;
      update public.purchase_items set product_id = prod,
        category_id = (select category_id from public.products where id = prod) where id = li.id;
    elsif a = 'new' then
      cat := (select id from public.categories where id = e->>'category_id');
      if cat is null then raise exception 'BAD_CATEGORY'; end if;
      prod := coalesce((e->>'product_id')::uuid, gen_random_uuid());
      insert into public.products (id, household_id, name, category_id, ingredient_id, unit, pack_size, unit_weight_g, source)
      values (prod, p.household_id, coalesce(nullif(trim(e->>'name'), ''), li.raw_text, 'Product'), cat,
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
revoke all on function public.finish_receipt(uuid, jsonb, jsonb, boolean, boolean, uuid) from public, anon;
grant execute on function public.finish_receipt(uuid, jsonb, jsonb, boolean, boolean, uuid) to authenticated;

-- ── Discard an unfinished draft (its images are deleted by the app through Storage) ─
create function public.void_receipt_draft(p_purchase uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare p public.purchases%rowtype;
begin
  select * into p from public.purchases where id = p_purchase for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p.status = 'void' then return jsonb_build_object('purchase_id', p.id, 'repeat', true, 'paths', '[]'::jsonb); end if;
  if p.status <> 'draft' then raise exception 'NOT_A_DRAFT'; end if;
  if exists (select 1 from public.pantry_lots where purchase_id = p.id) then raise exception 'DRAFT_HAS_LOTS'; end if;
  update public.purchases set status = 'void', receipt_paths = '{}', parse_output = null where id = p.id;
  return jsonb_build_object('purchase_id', p.id, 'repeat', false, 'paths', to_jsonb(p.receipt_paths));
end $$;
revoke all on function public.void_receipt_draft(uuid) from public, anon;
grant execute on function public.void_receipt_draft(uuid) to authenticated;

-- ── Check-dates sheet: printed date and Caducidad / Consumir pref. ───────────
create function public.set_lot_expiry(p_lot uuid, p_expires_on date default null, p_kind text default null, p_via text default 'app')
returns jsonb language plpgsql set search_path = '' as $$
declare l public.pantry_lots%rowtype;
begin
  if p_kind is not null and p_kind not in ('use_by', 'best_before') then raise exception 'BAD_KIND'; end if;
  if p_via not in ('app', 'mcp') then raise exception 'BAD_VIA'; end if;
  select * into l from public.pantry_lots where id = p_lot for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.pantry_lots set
    expires_on = coalesce(p_expires_on, expires_on),
    expiry_source = case when p_expires_on is not null and p_expires_on <> l.expires_on
                         then case when p_via = 'mcp' then 'claude' else 'printed' end else expiry_source end,
    expiry_kind = coalesce(p_kind, expiry_kind)
  where id = l.id;
  -- accepting the sheet confirms the kind on the product, so the next lot of it is right without asking
  update public.products set expiry_kind = coalesce(p_kind, expiry_kind, l.expiry_kind), kind_confirmed = true
   where id = l.product_id and household_id = l.household_id
     and (p_kind is not null or not kind_confirmed) and coalesce(p_kind, l.expiry_kind) in ('use_by', 'best_before');
  return jsonb_build_object('lot_id', l.id, 'expires_on', coalesce(p_expires_on, l.expires_on));
end $$;
revoke all on function public.set_lot_expiry(uuid, date, text, text) from public, anon;
grant execute on function public.set_lot_expiry(uuid, date, text, text) to authenticated;

-- ── Trips: list and detail (Spending tab; Claude gets the same in step 10) ───
create function public.list_purchases(p_limit int default 100)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'trips', coalesce((select jsonb_agg(t order by t->>'purchased_at' desc) from (
      select jsonb_build_object(
        'purchase_id', p.id, 'chain_id', p.chain_id, 'chain', ch.name, 'store_label', p.store_label,
        'purchased_at', p.purchased_at, 'local_date', (p.purchased_at at time zone h.timezone)::date,
        'month', to_char(p.purchased_at at time zone h.timezone, 'YYYY-MM'),
        'total_cents', p.total_cents, 'verification', p.verification, 'source', p.source,
        'items', (select count(*) from public.purchase_items i where i.purchase_id = p.id and i.kind = 'item'),
        'lots', (select count(*) from public.pantry_lots l where l.purchase_id = p.id)) as t
      from public.purchases p
      join public.households h on h.id = p.household_id
      join public.chains ch on ch.id = p.chain_id
      where p.status = 'confirmed'
      order by p.purchased_at desc
      limit least(greatest(coalesce(p_limit, 100), 1), 500)) x), '[]'::jsonb),
    'drafts', coalesce((select jsonb_agg(jsonb_build_object(
        'purchase_id', p.id, 'chain_id', p.chain_id, 'purchased_at', p.purchased_at, 'total_cents', p.total_cents,
        'created_at', p.created_at) order by p.created_at desc)
      from public.purchases p
      where p.status = 'draft' and p.source in ('receipt_photo', 'receipt_file') and p.parse_output is not null
        and not exists (select 1 from public.pantry_lots l where l.purchase_id = p.id)), '[]'::jsonb));
$$;
revoke all on function public.list_purchases(int) from public, anon;
grant execute on function public.list_purchases(int) to authenticated;

create function public.get_purchase(p_purchase uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'purchase_id', p.id, 'status', p.status, 'chain_id', p.chain_id, 'chain', ch.name, 'store_label', p.store_label,
    'purchased_at', p.purchased_at, 'local_date', (p.purchased_at at time zone h.timezone)::date,
    'time_source', p.time_source, 'total_cents', p.total_cents, 'verification', p.verification,
    'ticket_number', p.ticket_number, 'receipt_paths', to_jsonb(p.receipt_paths),
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
        'line_no', i.line_no, 'kind', i.kind, 'raw_text', i.raw_text, 'product_id', i.product_id,
        'name', coalesce(pr.name, i.raw_text, case i.kind when 'adjustment' then 'Unclassified' end),
        'category_id', coalesce(pr.category_id, i.category_id), 'is_food', coalesce(c.is_food, false),
        'printed_qty', i.printed_qty, 'printed_unit', i.printed_unit, 'quantity', i.quantity,
        'line_total_cents', i.line_total_cents,
        'lot', (select jsonb_build_object('lot_id', v.id, 'qty_left', v.qty_left, 'unit', v.unit, 'state', v.state,
                                          'days_left', v.days_left, 'expires_on', v.effective_expires_on)
                  from public.pantry v where v.purchase_item_id = i.id limit 1)) order by i.line_no)
      from public.purchase_items i
      left join public.products pr on pr.id = i.product_id and pr.household_id = i.household_id
      left join public.categories c on c.id = coalesce(pr.category_id, i.category_id)
      where i.purchase_id = p.id), '[]'::jsonb))
  from public.purchases p
  join public.households h on h.id = p.household_id
  join public.chains ch on ch.id = p.chain_id
  where p.id = p_purchase;
$$;
revoke all on function public.get_purchase(uuid) from public, anon;
grant execute on function public.get_purchase(uuid) to authenticated;
