-- Step 4: receipt flow in SQL. Draft from parser output -> review -> finish (confirm) -> dates; aliases learned;
-- second receipt auto-matched; same ticket twice blocked; quota; trips list. Run: supabase test db (or pnpm --filter sqltest test 04)
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true);
end $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return 'OK'; exception when others then return split_part(sqlerrm, E'\n', 1); end $$;
-- a printed time earlier today in Madrid (never in the future, never yesterday)
create function pg_temp.today_at(minutes_ago int) returns text language sql stable as $$
  select to_char(greatest(now() - make_interval(mins => minutes_ago),
                          (date_trunc('day', now() at time zone 'Europe/Madrid')) at time zone 'Europe/Madrid')
                 at time zone 'Europe/Madrid', 'YYYY-MM-DD"T"HH24:MI') $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.err(text), pg_temp.today_at(int) to public;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000041', 'r1@test.local'),
                                          ('aaaaaaaa-0000-0000-0000-000000000042', 'r2@test.local');
create temp table ctx as select
  (select household_id from public.household_members where user_id = 'aaaaaaaa-0000-0000-0000-000000000041') as h1;
grant select on ctx to public;
create temp table _o(t text); grant all on _o to public;

select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000041');

-- 1. Parser output -> draft. Mercadona, 5 lines: milk x2 packs, weighed chicken, a discount, detergent, bananas by weight.
create temp table p1 as select jsonb_build_object(
  'chain', 'MERCADONA', 'store_label', 'C/ Alcalá 100', 'purchased_at', pg_temp.today_at(30), 'ticket_number', '2304-011-123456',
  'total_cents', 1149,
  'lines', jsonb_build_array(
    jsonb_build_object('raw_text', '2 x LECHE SEMI HACEND', 'name_guess', 'Leche semidesnatada', 'category_guess', 'milk_uht',
                       'ingredient_guess', 'milk', 'printed_qty', 2, 'printed_unit', 'pack', 'line_total_cents', 190, 'kind', 'item'),
    jsonb_build_object('raw_text', 'PECHUGA POLLO', 'name_guess', 'Pechuga de pollo', 'category_guess', 'fresh_poultry',
                       'ingredient_guess', 'not_a_real_id', 'printed_qty', 512, 'printed_unit', 'g', 'line_total_cents', 389, 'kind', 'item'),
    jsonb_build_object('raw_text', '2a UD 70%', 'name_guess', 'Descuento', 'category_guess', null,
                       'printed_qty', 1, 'printed_unit', 'pack', 'line_total_cents', 50, 'kind', 'discount'),
    jsonb_build_object('raw_text', 'DETERGENTE BOSQUE VERDE', 'name_guess', 'Detergente', 'category_guess', 'cleaning',
                       'printed_qty', 1, 'printed_unit', 'pack', 'line_total_cents', 450, 'kind', 'item'),
    jsonb_build_object('raw_text', 'PLATANO', 'name_guess', 'Plátano de Canarias', 'category_guess', 'fresh_fruit',
                       'ingredient_guess', null, 'printed_qty', 826, 'printed_unit', 'g', 'line_total_cents', 170, 'kind', 'item'))) as j;
grant select on p1 to public;

create temp table r1 as select public.save_receipt_draft('b4000000-0000-0000-0000-000000000001', (select h1 from ctx),
  array['x/b4000000-0000-0000-0000-000000000001/1.jpg'], (select j from p1)) as r;
grant select on r1 to public;

select is((select r->>'status' from r1), 'draft', 'parser output becomes a draft');
select is((select r->>'chain_id' from r1), 'mercadona', 'chain normalised to a known id');
select is((select r->>'time_source' from r1), 'printed', 'printed time accepted');
select is((select (r->>'missing_cents')::int from r1), 0, 'lines add up (discount stored negative)');
select is((select (r->'lines'->2->>'line_total_cents')::int from r1), -50, 'discount sign fixed to negative');
select is((select r->'lines'->0->>'match' from r1), 'new', 'unknown food line is offered as new');
select is((select r->'lines'->3->>'match' from r1), 'spend', 'non-food line defaults to spend only');
select is((select r->'lines'->0->>'ingredient_id' from r1), 'milk', 'model ingredient guess kept when it is a real id');
select isnt((select r->'lines'->1->>'ingredient_id' from r1), 'not_a_real_id', 'invented ingredient id is dropped');
select is((select r->'duplicate'->>'verdict' from r1), 'new', 'no duplicate yet');
select is((select (public.save_receipt_draft('b4000000-0000-0000-0000-000000000001', (select h1 from ctx), '{}', (select j from p1)))->'lines'->0->>'line_no'), '1',
          'saving the same draft again replaces its lines (no doubles)');
select is((select count(*)::int from public.purchase_items where purchase_id = 'b4000000-0000-0000-0000-000000000001'), 5, 'still 5 lines');

-- 2. Finish: create products for food lines, spend-only for the detergent.
create temp table f1 as select public.finish_receipt('b4000000-0000-0000-0000-000000000001', jsonb_build_array(
  jsonb_build_object('line_no', 1, 'action', 'new', 'product_id', 'a4000000-0000-0000-0000-000000000001', 'name', 'Leche semidesnatada',
                     'category_id', 'milk_uht', 'ingredient_id', 'milk', 'unit', 'ml', 'pack_size', 1000),
  jsonb_build_object('line_no', 2, 'action', 'new', 'product_id', 'a4000000-0000-0000-0000-000000000002', 'name', 'Pechuga de pollo',
                     'category_id', 'fresh_poultry', 'unit', 'g'),
  jsonb_build_object('line_no', 4, 'action', 'spend', 'category_id', 'cleaning'),
  jsonb_build_object('line_no', 5, 'action', 'new', 'product_id', 'a4000000-0000-0000-0000-000000000003', 'name', 'Plátanos',
                     'category_id', 'fresh_fruit', 'unit', 'unit', 'unit_weight_g', 120))) as r;
grant select on f1 to public;

select is((select r->>'verification' from f1), 'sum_ok', 'confirmed with the sum check passing');
select is((select (r->>'lots_created')::int from f1), 3, 'three lots: milk, chicken, bananas (not the detergent)');
select is((select initial_qty from public.pantry_lots where product_id = 'a4000000-0000-0000-0000-000000000001'), 2000.000, '2 packs x 1000 ml = 2000 ml');
select is((select initial_qty from public.pantry_lots where product_id = 'a4000000-0000-0000-0000-000000000002'), 512.000, 'weighed chicken: 512 g');
select is((select initial_qty from public.pantry_lots where product_id = 'a4000000-0000-0000-0000-000000000003'), 7.000, '826 g of bananas at 120 g each = 7');
select is((select ticket_number from public.purchases where id = 'b4000000-0000-0000-0000-000000000001'), '2304-011-123456', 'ticket number copied at confirm');
select is((select count(*)::int from public.receipt_aliases where household_id = (select h1 from ctx)), 3, 'three receipt aliases learned');
select ok((select r->'check_dates' @> '[{"name": "Pechuga de pollo"}]' from f1), 'chicken is on the check-dates sheet');
select ok(not (select r->'check_dates' @> '[{"name": "Plátanos"}]' from f1), 'bananas (estimate) are not asked');
select is((public.finish_receipt('b4000000-0000-0000-0000-000000000001'))->>'repeat', 'true', 'finishing again is a no-op');

-- 3. Check dates: a printed date and the Caducidad toggle are saved; the product remembers the kind.
insert into _o select public.set_lot_expiry((select id from public.pantry_lots where product_id = 'a4000000-0000-0000-0000-000000000002'),
                                            (now() at time zone 'Europe/Madrid')::date + 4, 'use_by')::text;
select is((select expiry_source from public.pantry_lots where product_id = 'a4000000-0000-0000-0000-000000000002'), 'printed', 'changed date is marked printed');
select is((select kind_confirmed from public.products where id = 'a4000000-0000-0000-0000-000000000002'), true, 'kind confirmed on the product');
select is(pg_temp.err($$select public.set_lot_expiry(gen_random_uuid(), null, 'estimate')$$), 'BAD_KIND', 'only use_by / best_before can be set');

-- 4. Same ticket photographed again: blocked.
insert into _o select public.save_receipt_draft('b4000000-0000-0000-0000-000000000002', (select h1 from ctx), '{}', (select j from p1))::text;
select is((public.receipt_review('b4000000-0000-0000-0000-000000000002'))->'duplicate'->>'verdict', 'same_ticket', 'review shows it was already logged');
select is(pg_temp.err($$select public.finish_receipt('b4000000-0000-0000-0000-000000000002')$$), 'ALREADY_LOGGED', 'confirming the same ticket again is refused');
select is((public.void_receipt_draft('b4000000-0000-0000-0000-000000000002'))->>'repeat', 'false', 'the duplicate draft can be discarded');
select is((select status from public.purchases where id = 'b4000000-0000-0000-0000-000000000002'), 'void', 'discarded draft is void');

-- 5. Next week's receipt with the same products: lines are matched automatically (alias learning).
create temp table r3 as select public.save_receipt_draft('b4000000-0000-0000-0000-000000000003', (select h1 from ctx), '{}',
  (select j || jsonb_build_object('ticket_number', '2304-011-999999', 'purchased_at', pg_temp.today_at(5), 'total_cents', 749) from p1)) as r;
grant select on r3 to public;
select is((select count(*)::int from jsonb_array_elements((select r->'lines' from r3)) l where l->>'match' = 'matched'), 3,
          'milk, chicken and bananas matched automatically (3 of 3 food lines)');

-- 6. Sum mismatch: refused, then accepted with an adjustment line.
select is(pg_temp.err($$select public.finish_receipt('b4000000-0000-0000-0000-000000000003', '[{"line_no": 4, "action": "spend"}]', '{}', false, true)$$),
          'SUM_MISMATCH', 'lines that do not add up are refused');
select is((public.finish_receipt('b4000000-0000-0000-0000-000000000003', '[{"line_no": 4, "action": "spend"}]', '{}', true, true))->>'verification',
          'adjusted', 'accepting the difference confirms with an adjustment');
select is((select line_total_cents from public.purchase_items where purchase_id = 'b4000000-0000-0000-0000-000000000003' and kind = 'adjustment'),
          749 - 1149, 'adjustment line = ticket total - lines');

-- 7. Trips list and detail; quota.
select is(jsonb_array_length((public.list_purchases())->'trips'), 2, 'two confirmed trips listed');
select is(jsonb_array_length((public.list_purchases())->'drafts'), 0, 'no unfinished drafts');
select is((public.get_purchase('b4000000-0000-0000-0000-000000000001'))->'lines'->0->'lot'->>'qty_left', '2000.000', 'trip page links a line to its pantry item');
select is(public.take_receipt_quota((select h1 from ctx), 2), 1, 'first parse today leaves 1 of 2');
select is(public.take_receipt_quota((select h1 from ctx), 2), 0, 'second parse leaves 0');
select is(pg_temp.err(format($$select public.take_receipt_quota(%L, 2)$$, (select h1 from ctx))), 'QUOTA_EXCEEDED', 'third parse is refused');

-- 8. Another user sees none of it and cannot write a draft into this household.
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000042');
select is(jsonb_array_length((public.list_purchases())->'trips'), 0, 'user 2 sees no trips');
select is(pg_temp.err(format($$select public.save_receipt_draft(gen_random_uuid(), %L, '{}', '{}')$$, (select h1 from ctx))), 'NOT_FOUND', 'user 2 cannot write into household 1');
select is(pg_temp.err(format($$select public.take_receipt_quota(%L)$$, (select h1 from ctx))), 'NOT_FOUND', 'user 2 cannot use household 1 quota');

reset role;
select * from finish();
rollback;
