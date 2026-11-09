-- Trip page edits: fix a price, add a forgotten item, delete a trip and undo it.
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
grant execute on function pg_temp.as_user(uuid), pg_temp.err(text) to public;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000061', 't1@test.local');
create temp table ctx as select (select household_id from public.household_members where user_id = 'aaaaaaaa-0000-0000-0000-000000000061') as h;
grant select on ctx to public;
create temp table _o(t text); grant all on _o to public;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000061');

-- A €10.00 trip: yogurt €3.00 + rice €7.00
insert into _o select public.save_receipt_draft('b6000000-0000-0000-0000-000000000001', (select h from ctx), '{}', jsonb_build_object(
  'chain', 'mercadona', 'purchased_at', null, 'ticket_number', 'T-6', 'total_cents', 1000,
  'lines', jsonb_build_array(
    jsonb_build_object('raw_text', 'YOGUR', 'category_guess', 'yogurt_dessert', 'printed_qty', 1, 'printed_unit', 'pack', 'line_total_cents', 300, 'kind', 'item'),
    jsonb_build_object('raw_text', 'ARROZ', 'category_guess', 'dry_goods', 'printed_qty', 1, 'printed_unit', 'pack', 'line_total_cents', 700, 'kind', 'item'))))::text;
insert into _o select public.finish_receipt('b6000000-0000-0000-0000-000000000001', '[
  {"line_no": 1, "action": "new", "name": "Yogur", "category_id": "yogurt_dessert", "unit": "unit"},
  {"line_no": 2, "action": "new", "name": "Arroz", "category_id": "dry_goods", "unit": "unit"}]')::text;

-- Fix a price: rice was €6.50 -> the €0.50 goes to Unclassified, total stays €10.00
select is((public.fix_line_price('b6000000-0000-0000-0000-000000000001', 2, 650))->>'verification', 'adjusted', 'price fixed, difference unclassified');
select is((select line_total_cents from public.purchase_items where purchase_id = 'b6000000-0000-0000-0000-000000000001' and kind = 'adjustment'), 50, 'unclassified = 0.50');
select is((select total_cents from public.purchases where id = 'b6000000-0000-0000-0000-000000000001'), 1000, 'ticket total unchanged');
select is(pg_temp.err($$select public.fix_line_price('b6000000-0000-0000-0000-000000000001', 1, -5)$$), 'BAD_AMOUNT', 'an item cannot be negative');

-- Forgotten item €0.40 comes out of the €0.50 unclassified
select is((public.add_trip_item('b6000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000001', 'Perejil', 'fresh_veg', 1, 'unit', 40))->>'verification', 'adjusted', 'forgotten item added');
select is((select line_total_cents from public.purchase_items where purchase_id = 'b6000000-0000-0000-0000-000000000001' and kind = 'adjustment'), 10, 'unclassified shrinks to 0.10');
select is((select total_cents from public.purchases where id = 'b6000000-0000-0000-0000-000000000001'), 1000, 'total still 10.00');
select is((public.add_trip_item('b6000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000001', 'Perejil', 'fresh_veg', 1, 'unit', 40))->>'repeat', 'true', 'same line id again is a no-op');
-- A bigger one (€2.00) grows the total by what the unclassified can't cover
select is((public.add_trip_item('b6000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000002', 'Queso', 'cheese', 1, 'unit', 200))->>'verification', 'sum_ok', 'lines add up again');
select is((select total_cents from public.purchases where id = 'b6000000-0000-0000-0000-000000000001'), 1190, 'total grows by 2.00 - 0.10');
select is((select count(*)::int from public.pantry_lots where purchase_id = 'b6000000-0000-0000-0000-000000000001'), 4, 'forgotten items are in the pantry');

-- Delete the trip, then undo
insert into _o select public.consume((select id from public.pantry_lots where purchase_item_id = 'd6000000-0000-0000-0000-000000000002'), 1)::text;
select is((public.delete_trip('b6000000-0000-0000-0000-000000000001', 'f6000000-0000-0000-0000-000000000001'))->>'lots_cleared', '3', 'three items still had stock and are taken out');
select is((select status from public.purchases where id = 'b6000000-0000-0000-0000-000000000001'), 'void', 'trip no longer counts');
select is((select count(*)::int from public.pantry where purchase_id = 'b6000000-0000-0000-0000-000000000001' and qty_left > 0), 0, 'nothing left from that trip');
select is(jsonb_array_length((public.list_purchases())->'trips'), 0, 'trip gone from the list');
select is((public.undo_delete_trip('b6000000-0000-0000-0000-000000000001', 'f6000000-0000-0000-0000-000000000001'))->>'repeat', 'false', 'undo delete');
select is((select status from public.purchases where id = 'b6000000-0000-0000-0000-000000000001'), 'confirmed', 'trip counts again');
select is((select count(*)::int from public.pantry where purchase_id = 'b6000000-0000-0000-0000-000000000001' and qty_left > 0), 3, 'stock is back (the eaten cheese stays eaten)');
select is((public.undo_delete_trip('b6000000-0000-0000-0000-000000000001', 'f6000000-0000-0000-0000-000000000001'))->>'repeat', 'true', 'undo twice is a no-op');

reset role;
select * from finish();
rollback;
