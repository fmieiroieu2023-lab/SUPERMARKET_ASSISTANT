-- Step 1 "done when" tests. Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

-- helpers ---------------------------------------------------------------------
-- err(sql): run a statement, return its error message (first line) or 'OK'. Rolls the statement back on error.
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return 'OK';
exception when others then return split_part(sqlerrm, E'\n', 1); end $$;
create function pg_temp.as_user(u uuid, client text default null) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    jsonb_strip_nulls(jsonb_build_object('sub', u, 'role', 'authenticated', 'client_id', client))::text, true);
end $$;
create function pg_temp.hh(u uuid) returns uuid language sql as
  $$ select household_id from public.household_members where user_id = u $$;
grant execute on function pg_temp.err(text), pg_temp.as_user(uuid, text), pg_temp.hh(uuid) to public;

-- setup (as superuser): two users; the signup trigger creates their households ---------------
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@test.local'),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'b@test.local');

create temp table ctx as select
  (select household_id from public.household_members where user_id = 'aaaaaaaa-0000-0000-0000-000000000001') as ha,
  (select household_id from public.household_members where user_id = 'bbbbbbbb-0000-0000-0000-000000000001') as hb;
grant select on ctx to public;

select isnt((select ha from ctx), (select hb from ctx), 'signup creates a separate household per user');

insert into public.products (id, household_id, name, category_id, unit, pack_size, unit_weight_g, source) values
  ('a0000000-0000-0000-0000-000000000001', (select ha from ctx), 'LECHE',        'milk_uht',    'ml',   1000, null, 'manual'),
  ('a0000000-0000-0000-0000-000000000002', (select ha from ctx), 'HARINA',       'dry_goods',   'g',    null, null, 'manual'),
  ('a0000000-0000-0000-0000-000000000003', (select ha from ctx), 'MANZANA',      'fresh_fruit', 'unit', null, 120,  'manual'),
  ('a0000000-0000-0000-0000-000000000004', (select ha from ctx), 'PERA',         'fresh_fruit', 'unit', null, null, 'manual'),
  ('a0000000-0000-0000-0000-000000000005', (select ha from ctx), 'YOGUR USE BY', 'yogurt_dessert', 'unit', null, null, 'manual'),
  ('b0000000-0000-0000-0000-000000000001', (select hb from ctx), 'B PRODUCT',    'fresh_fruit', 'unit', null, null, 'manual');
update public.products set expiry_kind = 'use_by', shelf_life_days = 5
 where id = 'a0000000-0000-0000-0000-000000000005';

-- 1. isolation ------------------------------------------------------------------
select pg_temp.as_user('bbbbbbbb-0000-0000-0000-000000000001');
select is((select count(*)::int from public.products where household_id = (select ha from ctx)), 0, 'B sees 0 of A''s products');
select is((select count(*)::int from public.households where id = (select ha from ctx)), 0, 'B cannot see A''s household');
select is(pg_temp.err(format($$insert into public.products (id, household_id, name, category_id, unit, source)
  values (gen_random_uuid(), %L, 'X', 'fresh_fruit', 'unit', 'manual')$$, (select ha from ctx))) <> 'OK', true,
  'B cannot write into A''s household');
reset role;

select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select is((select count(*)::int from public.products), 5, 'A sees exactly their 5 products');
select is(pg_temp.err(format($$insert into public.pantry_lots (id, household_id, product_id, location, initial_qty, expires_on, expiry_kind, expiry_source)
  values (gen_random_uuid(), %L, 'b0000000-0000-0000-0000-000000000001', 'fridge', 1, current_date, 'estimate', 'user')$$, (select ha from ctx))) <> 'OK',
  true, 'a lot pointing at B''s product is rejected');
reset role;

-- 2. category rules -------------------------------------------------------------
select is(pg_temp.err($$insert into public.categories (id, name_es, is_food, default_location, shelf_life_days, expiry_kind)
  values ('t1', 't', false, 'pantry', 30, 'none')$$) <> 'OK', true, 'expiry_kind none with a shelf life is rejected');
select is(pg_temp.err($$insert into public.categories (id, name_es, is_food, default_location, shelf_life_days, expiry_kind)
  values ('t2', 't', true, 'pantry', 30, 'best_before')$$) <> 'OK', true, 'best_before without check_grace_days is rejected');
select is((select expiry_kind from public.categories where id = 'yogurt_dessert'), 'best_before', 'yogurt category is best_before');

-- 3. unit conversion --------------------------------------------------------------
select is(public.to_base_qty('a0000000-0000-0000-0000-000000000001', 2, 'pack'), 2000::numeric, '2 packs of 1000 ml = 2000');
select is(pg_temp.err($$select public.to_base_qty('a0000000-0000-0000-0000-000000000002', 1, 'pack')$$), 'NEEDS_PACK_SIZE', 'pack on g without pack_size');
select is(pg_temp.err($$select public.to_base_qty('a0000000-0000-0000-0000-000000000001', 500, 'g')$$), 'UNIT_MISMATCH', 'g on an ml product');
select is(public.to_base_qty('a0000000-0000-0000-0000-000000000003', 826, 'g'), 7::numeric, '826 g of 120 g apples = 7');
select is(pg_temp.err($$select public.to_base_qty('a0000000-0000-0000-0000-000000000004', 826, 'g')$$), 'UNIT_MISMATCH', 'g on a unit product without weight');

-- 4. confirm_purchase: sum check, adjustment, lots, consume floor ---------------------------
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
insert into public.purchases (id, household_id, chain_id, purchased_at, time_source, status, source, total_cents, created_via)
  values ('c0000000-0000-0000-0000-000000000001', pg_temp.hh('aaaaaaaa-0000-0000-0000-000000000001'), 'mercadona', now(), 'entered', 'draft', 'manual', 301, 'app');
insert into public.purchase_items (id, purchase_id, household_id, line_no, kind, raw_text, product_id, printed_qty, printed_unit, line_total_cents)
  values ('d0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', pg_temp.hh('aaaaaaaa-0000-0000-0000-000000000001'),
          1, 'item', '6 PERA', 'a0000000-0000-0000-0000-000000000004', 6, 'pack', 300);

select is(pg_temp.err($$select public.confirm_purchase('c0000000-0000-0000-0000-000000000001')$$), 'SUM_MISMATCH', 'a 1-cent mismatch is rejected');
select is((select status from public.purchases where id = 'c0000000-0000-0000-0000-000000000001'), 'draft', 'a rejected confirm leaves the draft');
select is(public.confirm_purchase('c0000000-0000-0000-0000-000000000001', true) ->> 'verification', 'adjusted', 'accept_difference confirms as adjusted');
select is((select line_total_cents from public.purchase_items where purchase_id = 'c0000000-0000-0000-0000-000000000001' and kind = 'adjustment'), 1,
  'an adjustment line of 1 cent was created');
select is((select count(*)::int from public.pantry_lots where purchase_id = 'c0000000-0000-0000-0000-000000000001'), 1, 'one lot created');

create temp table lot as select id from public.pantry_lots where purchase_id = 'c0000000-0000-0000-0000-000000000001';
grant select on lot to public;
select is((select qty_left from public.pantry where id = (select id from lot)), 6::numeric, 'lot starts at 6');
select is(pg_temp.err($$update public.products set unit = 'g' where id = 'a0000000-0000-0000-0000-000000000004'$$), 'PRODUCT_HAS_HISTORY', 'unit is frozen once a lot exists');
select is((select qty_left from public.pantry where id = (select id from lot)), 6::numeric, 'lot still 6 after the refused unit change');

select is((public.consume((select id from lot), 10, 'consume', 'e0000000-0000-0000-0000-000000000001') ->> 'consumed')::numeric, 6::numeric, 'consuming 10 of 6 takes only 6');
select is((select qty_left from public.pantry where id = (select id from lot)), 0::numeric, 'quantity left is 0, never negative');
select is(public.consume((select id from lot), 10, 'consume', 'e0000000-0000-0000-0000-000000000001') ->> 'repeat', 'true', 'a repeated movement id is a no-op');
reset role;

-- 5. quick total + receipt: one trip, no double count ---------------------------------
-- Times are clamped to today (Madrid) so the test also passes just after midnight (same-day rule).
create function pg_temp.ago(i interval) returns timestamptz language sql stable as $$
  select greatest(now() - i, (date_trunc('day', now() at time zone 'Europe/Madrid')) at time zone 'Europe/Madrid') $$;
grant execute on function pg_temp.ago(interval) to public;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
insert into public.purchases (id, household_id, chain_id, purchased_at, time_source, status, source, total_cents, created_via)
  values ('c0000000-0000-0000-0000-000000000002', pg_temp.hh('aaaaaaaa-0000-0000-0000-000000000001'), 'supercor', pg_temp.ago('1 hour'), 'entered', 'draft', 'manual', 4560, 'app');
select is(public.confirm_purchase('c0000000-0000-0000-0000-000000000002') ->> 'verification', 'total_only', 'quick total confirms as total_only');

insert into public.purchases (id, household_id, chain_id, purchased_at, time_source, status, source, total_cents, created_via, parse_output)
  values ('c0000000-0000-0000-0000-000000000003', pg_temp.hh('aaaaaaaa-0000-0000-0000-000000000001'), 'supercor', pg_temp.ago('65 minutes'), 'printed', 'draft', 'receipt_photo', 4560, 'app',
          '{"ticket_number":"0123-456"}');
insert into public.purchase_items (id, purchase_id, household_id, line_no, kind, raw_text, product_id, printed_qty, printed_unit, line_total_cents)
  values ('d0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003', pg_temp.hh('aaaaaaaa-0000-0000-0000-000000000001'),
          1, 'item', 'LECHE', 'a0000000-0000-0000-0000-000000000001', 1, 'pack', 4560);
select is(pg_temp.err($$select public.confirm_purchase('c0000000-0000-0000-0000-000000000003')$$), 'POSSIBLE_DUPLICATE', 'receipt after an equal quick total asks before counting');
select is(public.confirm_purchase('c0000000-0000-0000-0000-000000000003', false, 'c0000000-0000-0000-0000-000000000002') ->> 'merged', 'true', 'merge accepted');
select is((select count(*)::int from public.purchases where chain_id = 'supercor' and status = 'confirmed'), 1, 'one confirmed trip remains');
select is((select sum(total_cents)::int from public.purchases where chain_id = 'supercor' and status = 'confirmed'), 4560, 'month total unchanged by the merge');

-- 6. a different quick total after a receipt is flagged, and merging keeps the receipt's figure ----
insert into public.purchases (id, household_id, chain_id, purchased_at, time_source, status, source, total_cents, created_via, parse_output)
  values ('c0000000-0000-0000-0000-000000000004', pg_temp.hh('aaaaaaaa-0000-0000-0000-000000000001'), 'carrefour', pg_temp.ago('2 hours'), 'printed', 'draft', 'receipt_photo', 4560, 'app',
          '{"ticket_number":"9999-001"}');
insert into public.purchase_items (id, purchase_id, household_id, line_no, kind, raw_text, product_id, printed_qty, printed_unit, line_total_cents)
  values ('d0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000004', pg_temp.hh('aaaaaaaa-0000-0000-0000-000000000001'),
          1, 'item', 'LECHE', 'a0000000-0000-0000-0000-000000000001', 1, 'pack', 4560);
select public.confirm_purchase('c0000000-0000-0000-0000-000000000004');
insert into public.purchases (id, household_id, chain_id, purchased_at, time_source, status, source, total_cents, created_via)
  values ('c0000000-0000-0000-0000-000000000005', pg_temp.hh('aaaaaaaa-0000-0000-0000-000000000001'), 'carrefour', now(), 'entered', 'draft', 'manual', 4600, 'app');
select is(pg_temp.err($$select public.confirm_purchase('c0000000-0000-0000-0000-000000000005')$$), 'POSSIBLE_DUPLICATE', 'EUR 46.00 quick total after a EUR 45.60 receipt is flagged');
select public.confirm_purchase('c0000000-0000-0000-0000-000000000005', false, 'c0000000-0000-0000-0000-000000000004');
select is((select total_cents from public.purchases where chain_id = 'carrefour' and status = 'confirmed'), 4560, 'after merging, the one trip keeps the receipt total');
reset role;

-- 7. Claude kill switch ---------------------------------------------------------------
update public.households set mcp_write_enabled = false where id = (select ha from ctx);
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001', 'claude-client');
select is(pg_temp.err(format($$insert into public.products (id, household_id, name, category_id, unit, source)
  values (gen_random_uuid(), %L, 'FROM CLAUDE', 'fresh_fruit', 'unit', 'claude')$$, (select ha from ctx))) <> 'OK', true,
  'with Claude writes off, a Claude token cannot insert');
select is(pg_temp.err(format($$select public.log_mcp_call(%L, 'add_product', gen_random_uuid(), '{}'::jsonb, false)$$, (select ha from ctx))), 'OK',
  'the audit log still works with writes off');
reset role;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select is(pg_temp.err(format($$insert into public.products (id, household_id, name, category_id, unit, source)
  values (gen_random_uuid(), %L, 'FROM APP', 'fresh_fruit', 'unit', 'manual')$$, (select ha from ctx))), 'OK',
  'the app itself can still write');
reset role;

-- 8. use_by product inside a best-before category -------------------------------------
update public.households set mcp_write_enabled = true where id = (select ha from ctx);
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000001');
insert into public.purchases (id, household_id, chain_id, purchased_at, time_source, status, source, total_cents, created_via)
  values ('c0000000-0000-0000-0000-000000000006', pg_temp.hh('aaaaaaaa-0000-0000-0000-000000000001'), 'other', now(), 'entered', 'draft', 'manual', 100, 'app');
insert into public.purchase_items (id, purchase_id, household_id, line_no, kind, raw_text, product_id, printed_qty, printed_unit, line_total_cents)
  values ('d0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000006', pg_temp.hh('aaaaaaaa-0000-0000-0000-000000000001'),
          1, 'item', 'YOGUR', 'a0000000-0000-0000-0000-000000000005', 1, 'pack', 100);
select public.confirm_purchase('c0000000-0000-0000-0000-000000000006');
select is((select expiry_kind from public.pantry_lots where purchase_id = 'c0000000-0000-0000-0000-000000000006'), 'use_by',
  'a use_by yogurt product makes use_by lots');
reset role;

select * from finish();
rollback;
