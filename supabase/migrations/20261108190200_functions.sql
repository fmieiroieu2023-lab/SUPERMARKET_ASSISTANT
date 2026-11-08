-- Step 1, part 3: business rules in SQL (security invoker: RLS applies to the caller).
-- The app and the MCP server both call these. Source: arena-winning-plan.md sections 6.1, 6.3, 7.3.
-- Errors are raised as short codes (NEEDS_PACK_SIZE, UNIT_MISMATCH, SUM_MISMATCH, ...).

-- ── Text helper ──────────────────────────────────────────────────────────────
create function public.normalise_alias(p text) returns text
language sql immutable set search_path = '' as $$
  select upper(extensions.unaccent(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g')));
$$;

-- ── Unit conversion: one rule for receipts, scans, manual entry and Claude ───
create function public.to_base_qty(p_product uuid, p_qty numeric, p_unit text)
returns numeric language plpgsql stable set search_path = '' as $$
declare p public.products%rowtype;
begin
  select * into p from public.products where id = p_product;
  if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'BAD_QUANTITY'; end if;

  if p_unit in ('g', 'ml') and p_unit = p.unit then return p_qty; end if;

  if p_unit = 'pack' then
    if p.unit = 'unit' then return p_qty * coalesce(p.pack_size, 1); end if;
    if p.pack_size is null then raise exception 'NEEDS_PACK_SIZE'; end if;
    return p_qty * p.pack_size;
  end if;

  if p_unit = 'g' and p.unit = 'unit' and p.unit_weight_g is not null then
    return greatest(1, round(p_qty / p.unit_weight_g));
  end if;

  raise exception 'UNIT_MISMATCH';   -- g vs ml, unit vs g/ml, or a weighed line with no unit_weight_g
end $$;

-- ── Duplicate classification ─────────────────────────────────────────────────
-- Classifies ONE pair of trips (a, b). Symmetric: it talks about "the typed trip" and "the receipt",
-- never about which was logged first. Rules C1-C6 are the table in section 6.1 step 3(f).
--   receipt   = time_source 'printed'      (its minute was read from a ticket)
--   typed     = time_source 'entered' and no ticket number
--   receipt with no printed time = time_source 'entered' and a ticket number
create function public._dup_pair(
  a_src text, a_ticket text, a_at timestamptz, a_total int, a_typed timestamptz,
  b_src text, b_ticket text, b_at timestamptz, b_total int, b_typed timestamptz)
returns table (rule text, preselect text, evidence text)
language plpgsql immutable set search_path = '' as $$
declare
  a_is_typed boolean := a_src = 'entered' and a_ticket is null;
  b_is_typed boolean := b_src = 'entered' and b_ticket is null;
  a_printed  boolean := a_src = 'printed';
  b_printed  boolean := b_src = 'printed';
  lev int;
  ev text;
begin
  if a_ticket is not null and b_ticket is not null then
    lev := extensions.levenshtein(a_ticket, b_ticket);
  end if;

  -- C1: same normalised ticket number
  if a_ticket is not null and a_ticket = b_ticket then
    return query select 'C1', null::text, null::text; return;
  end if;

  -- C2: both receipts, same printed minute, same total
  if a_printed and b_printed and date_trunc('minute', a_at) = date_trunc('minute', b_at) and a_total = b_total then
    return query select 'C2', null::text, null::text; return;
  end if;

  -- C3: same total. "Same ticket" is preselected unless something shows the two are different.
  if a_total = b_total then
    if lev is not null and lev >= 3 then
      ev := 'ticket numbers ' || lev || ' characters apart';
    elsif a_is_typed and b_printed and b_at > a_typed + interval '10 minutes' then
      ev := 'ticket printed ' || to_char(b_at - a_typed, 'HH24:MI') || ' after the total was typed';
    elsif b_is_typed and a_printed and a_at > b_typed + interval '10 minutes' then
      ev := 'ticket printed ' || to_char(a_at - b_typed, 'HH24:MI') || ' after the total was typed';
    end if;
    return query select 'C3', case when ev is null then 'same' end, ev; return;
  end if;

  -- C4: near-match ticket numbers, or two receipts with the same printed minute. Nothing preselected.
  if (lev is not null and lev between 1 and 2)
     or (a_printed and b_printed and date_trunc('minute', a_at) = date_trunc('minute', b_at)) then
    return query select 'C4', null::text, null::text; return;
  end if;

  -- C5: one is a typed trip, the other is typed, has no printed time, or was printed no later than typed + 10 min
  if a_is_typed and (b_is_typed or not b_printed or b_at <= a_typed + interval '10 minutes') then
    return query select 'C5', null::text, null::text; return;
  end if;
  if b_is_typed and (a_is_typed or not a_printed or a_at <= b_typed + interval '10 minutes') then
    return query select 'C5', null::text, null::text; return;
  end if;

  return query select 'C6', null::text, null::text;
end $$;

create function public.classify_duplicate(
  p_household uuid, p_chain text, p_purchased_at timestamptz, p_time_source text,
  p_total_cents int, p_ticket_number text default null,
  p_typed_at timestamptz default now(), p_exclude uuid default null)
returns table (verdict text, rule text, other_purchase_id uuid, preselect text, evidence text, notice text)
language plpgsql stable set search_path = '' as $$
declare
  tz text;
  n_ticket text := nullif(regexp_replace(upper(coalesce(p_ticket_number, '')), '[^A-Z0-9]', '', 'g'), '');
  n_date date;
  e record; r record;
  rk int; best_rk int := 0;
  b_rule text; b_other uuid; b_pre text; b_ev text; b_notice text;
  chain_name text;
begin
  select timezone into tz from public.households where id = p_household;
  if tz is null then raise exception 'NOT_FOUND'; end if;
  n_date := (p_purchased_at at time zone tz)::date;
  select name into chain_name from public.chains where id = p_chain;

  for e in
    select id, time_source, ticket_norm, purchased_at, total_cents, confirmed_at
    from public.purchases
    where household_id = p_household and chain_id = p_chain and status = 'confirmed'
      and (p_exclude is null or id <> p_exclude)
      and (purchased_at at time zone tz)::date = n_date
  loop
    select * into r from public._dup_pair(
      p_time_source, n_ticket, p_purchased_at, p_total_cents, p_typed_at,
      e.time_source, e.ticket_norm, e.purchased_at, e.total_cents, e.confirmed_at);
    rk := case r.rule when 'C1' then 6 when 'C2' then 5 when 'C3' then 4
                      when 'C4' then 3 when 'C5' then 2 else 1 end;
    if rk > best_rk then
      best_rk := rk; b_rule := r.rule; b_other := e.id; b_pre := r.preselect; b_ev := r.evidence;
      if r.rule = 'C6' then
        b_notice := format('Also at %s on %s: EUR %s %s at %s. Treated as a separate trip. Same trip? You can undo.',
          coalesce(chain_name, p_chain), to_char(n_date, 'DD Mon'),
          replace(to_char(e.total_cents / 100.0, 'FM999999990.00'), '.', ','),
          case when e.time_source = 'entered' and e.ticket_norm is null then 'typed' else 'on a ticket' end,
          to_char((case when e.time_source = 'entered' and e.ticket_norm is null then e.confirmed_at
                        else e.purchased_at end) at time zone tz, 'HH24:MI'));
      else
        b_notice := null;
      end if;
    end if;
  end loop;

  if best_rk = 0 then
    return query select 'new'::text, null::text, null::uuid, null::text, null::text, null::text;
  else
    return query select
      case b_rule when 'C1' then 'same_ticket' when 'C2' then 'same_receipt'
                  when 'C3' then 'possible_duplicate' when 'C4' then 'possible_duplicate'
                  when 'C5' then 'mergeable' else 'new' end,
      b_rule, b_other, b_pre, b_ev, b_notice;
  end if;
end $$;

-- ── Shopping list refresh: real logic arrives in step 8. Stock-changing functions already call it. ──
create function public.refresh_shopping_list(p_household uuid) returns void
language sql set search_path = '' as $$ select 1; $$;

-- ── confirm_purchase ─────────────────────────────────────────────────────────
-- One transaction for receipts, quick totals, finished unpacking sessions and Claude's log_purchase.
--   p_accept_difference : insert an 'adjustment' line when the lines don't add up to the total
--   p_merge_into        : the confirmed trip the user says this draft is the same as
--   p_force_new         : "it's a different trip" (does not override a same-ticket block)
--   p_keep_total_cents  : typed+typed merge only: which total to keep (default: the newer one)
-- The parsed ticket number is read from parse_output->>'ticket_number' and copied to the trip only here.
create function public.confirm_purchase(
  p_purchase uuid,
  p_accept_difference boolean default false,
  p_merge_into uuid default null,
  p_force_new boolean default false,
  p_keep_total_cents int default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  n public.purchases%rowtype;
  e public.purchases%rowtype;
  tp public.purchases%rowtype;
  tz text; ldate date;
  n_ticket text; n_ticket_raw text;
  v record; pr record;
  t_id uuid;
  notice text;
  merged boolean := false;
  n_receipt boolean; e_receipt boolean;
  off int;
  sum_lines bigint; line_count int; diff bigint;
  li record; lot_id uuid; lots_created int := 0;
  new_verification text;
  scan record; z record; target_line uuid;
begin
  select * into n from public.purchases where id = p_purchase;
  if not found then raise exception 'NOT_FOUND'; end if;
  select timezone into tz from public.households where id = n.household_id;
  ldate := (n.purchased_at at time zone tz)::date;

  -- Same chain + same Madrid day: one confirmation at a time (app and Claude at once, double taps).
  perform pg_advisory_xact_lock(hashtextextended(n.household_id::text || n.chain_id || ldate::text, 0));

  select * into n from public.purchases where id = p_purchase for update;
  if n.status <> 'draft' then raise exception 'NOT_A_DRAFT'; end if;
  if n.total_cents is null then raise exception 'TOTAL_REQUIRED'; end if;

  n_ticket_raw := nullif(trim(n.parse_output ->> 'ticket_number'), '');
  n_ticket := nullif(regexp_replace(upper(coalesce(n_ticket_raw, '')), '[^A-Z0-9]', '', 'g'), '');
  t_id := n.id;

  if p_merge_into is null then
    select * into v from public.classify_duplicate(
      n.household_id, n.chain_id, n.purchased_at, n.time_source, n.total_cents, n_ticket_raw, now(), n.id);
    if v.verdict = 'same_ticket' then
      raise exception 'ALREADY_LOGGED' using hint = v.other_purchase_id::text;
    elsif v.verdict = 'same_receipt' and not p_force_new then
      raise exception 'ALREADY_LOGGED' using hint = v.other_purchase_id::text;
    elsif v.verdict in ('possible_duplicate', 'mergeable') and not p_force_new then
      raise exception 'POSSIBLE_DUPLICATE' using hint = v.other_purchase_id::text, detail = coalesce(v.evidence, '');
    end if;
    notice := v.notice;
  else
    -- ── merge into an existing confirmed trip ─────────────────────────────────
    select * into e from public.purchases where id = p_merge_into for update;
    if not found or e.status <> 'confirmed' or e.household_id <> n.household_id or e.chain_id <> n.chain_id
       or (e.purchased_at at time zone tz)::date <> ldate then
      raise exception 'INVALID_MERGE_TARGET';
    end if;
    select * into pr from public._dup_pair(
      n.time_source, n_ticket, n.purchased_at, n.total_cents, now(),
      e.time_source, e.ticket_norm, e.purchased_at, e.total_cents, e.confirmed_at);
    if pr.rule not in ('C3', 'C4', 'C5') then raise exception 'INVALID_MERGE_TARGET'; end if;

    n_receipt := n.time_source = 'printed' or n_ticket is not null;
    e_receipt := e.time_source = 'printed' or e.ticket_norm is not null;
    merged := true;

    if n_receipt and e_receipt then
      -- "same ticket" answer: nothing new is counted
      update public.purchases set status = 'void' where id = n.id;
      return jsonb_build_object('purchase_id', e.id, 'merged', true, 'case', 'receipt_receipt');

    elsif not n_receipt and e_receipt then
      -- typed N, receipt E (receipt first): the quick total is not created. Scanned lots move onto E.
      for scan in select * from public.pantry_lots where purchase_id = n.id order by created_at loop
        select i.id as line_id, l.id as zlot into z
        from public.purchase_items i
        join public.pantry_lots l on l.purchase_item_id = i.id
        where i.purchase_id = e.id and i.kind = 'item' and i.product_id = scan.product_id
          and l.purchase_id = e.id
          and (select count(*) from public.stock_movements m where m.lot_id = l.id) = 1
          and (select coalesce(sum(m.delta), 0) from public.stock_movements m where m.lot_id = l.id) > 0
        order by i.line_no limit 1;
        if found then
          insert into public.stock_movements (id, household_id, lot_id, delta, reason, actor, via)
          select gen_random_uuid(), e.household_id, z.zlot,
                 -(select sum(m.delta) from public.stock_movements m where m.lot_id = z.zlot),
                 'adjust', (select auth.uid()), 'app';
          update public.pantry_lots set purchase_item_id = null where id = z.zlot;
          update public.pantry_lots set purchase_item_id = z.line_id where id = scan.id;
        end if;
      end loop;
      update public.pantry_lots set purchase_id = e.id where purchase_id = n.id;
      update public.purchases set status = 'void' where id = n.id;
      return jsonb_build_object('purchase_id', e.id, 'merged', true, 'case', 'typed_into_receipt');

    elsif n_receipt and not e_receipt then
      -- receipt N, typed E (typed first): the receipt's lines replace E's lines; its data wins
      select coalesce(max(line_no), 0) into off from public.purchase_items where purchase_id = e.id;
      update public.purchase_items set purchase_id = e.id, line_no = line_no + off where purchase_id = n.id;
      with pairs as (
        select l.id as lot_id,
               (select i2.id from public.purchase_items i2
                 where i2.purchase_id = e.id and i2.line_no > off and i2.kind = 'item'
                   and i2.product_id = io.product_id
                   and not exists (select 1 from public.pantry_lots l2 where l2.purchase_item_id = i2.id)
                 order by i2.line_no limit 1) as new_line
        from public.pantry_lots l
        join public.purchase_items io on io.id = l.purchase_item_id
        where io.purchase_id = e.id and io.line_no <= off)
      update public.pantry_lots l set purchase_item_id = pairs.new_line from pairs where l.id = pairs.lot_id;
      delete from public.purchase_items where purchase_id = e.id and line_no <= off;
      update public.purchases set
        total_cents = n.total_cents, purchased_at = n.purchased_at, time_source = n.time_source,
        parse_output = n.parse_output, source = n.source,
        receipt_paths = e.receipt_paths || n.receipt_paths
      where id = e.id;
      update public.purchases set status = 'void', receipt_paths = '{}' where id = n.id;
      t_id := e.id;

    else
      -- typed N, typed E: keep the earlier trip, pool the lines, keep one total
      select coalesce(max(line_no), 0) into off from public.purchase_items where purchase_id = e.id;
      update public.purchase_items set purchase_id = e.id, line_no = line_no + off where purchase_id = n.id;
      delete from public.purchase_items where purchase_id = e.id and kind = 'adjustment';
      update public.pantry_lots set purchase_id = e.id where purchase_id = n.id;
      update public.purchases set
        total_cents = coalesce(p_keep_total_cents, n.total_cents),
        receipt_paths = e.receipt_paths || n.receipt_paths
      where id = e.id;
      update public.purchases set status = 'void', receipt_paths = '{}' where id = n.id;
      t_id := e.id;
    end if;
    -- from here on the kept trip is the one being confirmed
    if merged and not (n_receipt and not e_receipt) then n_ticket := null; n_ticket_raw := null; end if;
  end if;

  select * into tp from public.purchases where id = t_id;

  -- Quantity conversion: the only place printed quantities become base quantities.
  update public.purchase_items i
     set quantity = public.to_base_qty(i.product_id, i.printed_qty, i.printed_unit)
   where i.purchase_id = t_id and i.product_id is not null and i.kind = 'item';

  -- Sum check
  select coalesce(sum(line_total_cents), 0), count(*) into sum_lines, line_count
    from public.purchase_items where purchase_id = t_id;
  if line_count = 0 then
    new_verification := 'total_only';
  elsif sum_lines = tp.total_cents then
    new_verification := 'sum_ok';
  elsif p_accept_difference or (merged and p_merge_into is not null and not (n_receipt and not e_receipt)) then
    diff := tp.total_cents - sum_lines;
    insert into public.purchase_items (id, purchase_id, household_id, line_no, kind, raw_text, printed_qty, printed_unit, line_total_cents)
    select gen_random_uuid(), t_id, tp.household_id, coalesce(max(line_no), 0) + 1, 'adjustment',
           'Unclassified', 1, 'pack', diff::int
      from public.purchase_items where purchase_id = t_id;
    new_verification := 'adjusted';
  else
    raise exception 'SUM_MISMATCH' using detail = format('lines add up to %s cents, ticket says %s', sum_lines, tp.total_cents);
  end if;

  -- Lots: one per priced item line whose category has a shelf life. A scanned lot of the same product
  -- on this trip is linked instead of stocking the item twice.
  for li in
    select i.id, i.product_id, i.quantity, i.line_total_cents, p.shelf_life_days as p_shelf, p.expiry_kind as p_kind,
           c.shelf_life_days as c_shelf, c.expiry_kind as c_kind, c.default_location
    from public.purchase_items i
    join public.products p on p.id = i.product_id and p.household_id = i.household_id
    join public.categories c on c.id = p.category_id
    where i.purchase_id = t_id and i.kind = 'item' and c.shelf_life_days is not null
      and not exists (select 1 from public.pantry_lots l where l.purchase_item_id = i.id)
    order by i.line_no
  loop
    select l.id into lot_id from public.pantry_lots l
     where l.purchase_id = t_id and l.product_id = li.product_id and l.purchase_item_id is null
       and (select coalesce(sum(m.delta), 0) from public.stock_movements m where m.lot_id = l.id) > 0
     order by l.created_at limit 1;
    if found then
      update public.pantry_lots
         set purchase_item_id = li.id,
             unit_cost_cents = coalesce(unit_cost_cents, li.line_total_cents / nullif(li.quantity, 0))
       where id = lot_id;
    else
      lot_id := gen_random_uuid();
      insert into public.pantry_lots (id, household_id, product_id, purchase_id, purchase_item_id, location, initial_qty,
                                      expires_on, expiry_kind, expiry_source, unit_cost_cents)
      values (lot_id, tp.household_id, li.product_id, t_id, li.id, li.default_location, li.quantity,
              (tp.purchased_at at time zone tz)::date + coalesce(li.p_shelf, li.c_shelf),
              coalesce(li.p_kind, li.c_kind), 'default', li.line_total_cents / nullif(li.quantity, 0));
      insert into public.stock_movements (id, household_id, lot_id, delta, reason, actor, via)
      values (gen_random_uuid(), tp.household_id, lot_id, li.quantity, 'purchase', (select auth.uid()), 'app');
      lots_created := lots_created + 1;
    end if;
  end loop;

  -- Receipt-text learning
  insert into public.receipt_aliases (household_id, chain_id, alias, product_id)
  select distinct on (public.normalise_alias(i.raw_text)) tp.household_id, tp.chain_id,
         public.normalise_alias(i.raw_text), i.product_id
    from public.purchase_items i
   where i.purchase_id = t_id and i.product_id is not null and nullif(trim(i.raw_text), '') is not null
   order by public.normalise_alias(i.raw_text), i.line_no
  on conflict (household_id, chain_id, alias)
  do update set hits = public.receipt_aliases.hits + 1, product_id = excluded.product_id;

  -- Ticket number: copied only now, together with the status (a draft may not carry one).
  -- The unique index is the last line of defence against two confirmations of the same ticket.
  begin
    update public.purchases
       set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), verification = new_verification,
           ticket_number = coalesce(n_ticket_raw, ticket_number)
     where id = t_id;
  exception when unique_violation then
    raise exception 'ALREADY_LOGGED' using detail = 'ticket number already confirmed';
  end;

  -- Bought-but-unlogged shopping rows whose stock key appears on this trip are now reconciled.
  update public.shopping_list_items s set reconciled_at = now()
   where s.household_id = tp.household_id and s.status = 'bought' and s.reconciled_at is null
     and (s.product_id in (select i.product_id from public.purchase_items i where i.purchase_id = t_id and i.product_id is not null)
       or s.ingredient_id in (select p.ingredient_id from public.purchase_items i
                              join public.products p on p.id = i.product_id and p.household_id = i.household_id
                              where i.purchase_id = t_id and p.ingredient_id is not null));

  perform public.refresh_shopping_list(tp.household_id);

  return jsonb_build_object('purchase_id', t_id, 'merged', merged, 'verification', new_verification,
                            'lots_created', lots_created, 'notice', notice);
end $$;

-- ── consume: append a movement, never go below zero, repeat-safe ─────────────
create function public.consume(
  p_lot uuid, p_qty numeric, p_reason text default 'consume',
  p_movement_id uuid default gen_random_uuid(), p_via text default 'app', p_request_id uuid default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  l public.pantry_lots%rowtype;
  left_qty numeric; take numeric;
begin
  if p_reason not in ('consume', 'discard') then raise exception 'BAD_REASON'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'BAD_QUANTITY'; end if;

  select * into l from public.pantry_lots where id = p_lot for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if exists (select 1 from public.stock_movements where id = p_movement_id) then   -- a repeat is a no-op
    select coalesce(sum(delta), 0) into left_qty from public.stock_movements where lot_id = p_lot;
    return jsonb_build_object('consumed', 0, 'qty_left', left_qty, 'repeat', true);
  end if;

  select coalesce(sum(delta), 0) into left_qty from public.stock_movements where lot_id = p_lot;
  take := least(p_qty, left_qty);
  if take > 0 then
    insert into public.stock_movements (id, household_id, lot_id, delta, reason, actor, via, request_id)
    values (p_movement_id, l.household_id, p_lot, -take, p_reason, (select auth.uid()), p_via, p_request_id);
    perform public.refresh_shopping_list(l.household_id);
  end if;
  return jsonb_build_object('consumed', take, 'qty_left', left_qty - take, 'repeat', false);
end $$;

-- Only signed-in users may call these; anonymous visitors may not.
revoke all on function
  public.normalise_alias(text), public.to_base_qty(uuid, numeric, text),
  public._dup_pair(text, text, timestamptz, int, timestamptz, text, text, timestamptz, int, timestamptz),
  public.classify_duplicate(uuid, text, timestamptz, text, int, text, timestamptz, uuid),
  public.refresh_shopping_list(uuid),
  public.confirm_purchase(uuid, boolean, uuid, boolean, int),
  public.consume(uuid, numeric, text, uuid, text, uuid)
from public, anon;
grant execute on function
  public.normalise_alias(text), public.to_base_qty(uuid, numeric, text),
  public._dup_pair(text, text, timestamptz, int, timestamptz, text, text, timestamptz, int, timestamptz),
  public.classify_duplicate(uuid, text, timestamptz, text, int, text, timestamptz, uuid),
  public.refresh_shopping_list(uuid),
  public.confirm_purchase(uuid, boolean, uuid, boolean, int),
  public.consume(uuid, numeric, text, uuid, text, uuid)
to authenticated;
