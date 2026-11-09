-- Step 3 "done when": add 3 items + consume 1 -> 3 lots and 4 movements. Plus the expiry rule and repeat safety.
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

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000003', 'qa@test.local');
create temp table _o(t text);
grant all on _o to public;

select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000003');
insert into _o select (public.add_item('c0000000-0000-0000-0000-000000000001', 'Pollo', 'fresh_poultry', 450, 'g'))::text;
insert into _o select (public.add_item('c0000000-0000-0000-0000-000000000002', 'Plátanos', 'fresh_fruit', 5, 'unit', '2026-12-24'))::text;
insert into _o select (public.add_item('c0000000-0000-0000-0000-000000000003', 'Leche', 'milk_uht', 1000, 'ml'))::text;
insert into _o select (public.consume('c0000000-0000-0000-0000-000000000001', 100))::text;

select is((select count(*)::int from public.pantry_lots), 3, '3 lots');
select is((select count(*)::int from public.stock_movements), 4, '4 movements');
select is((select qty_left from public.pantry where id = 'c0000000-0000-0000-0000-000000000001'), 350.000::numeric, 'chicken has 350 left');
select is((select expiry_source from public.pantry_lots where id = 'c0000000-0000-0000-0000-000000000002'), 'user', 'typed date wins');
select is((select expires_on from public.pantry_lots where id = 'c0000000-0000-0000-0000-000000000002'), '2026-12-24'::date, 'typed date stored');
select is((select expiry_source from public.pantry_lots where id = 'c0000000-0000-0000-0000-000000000001'), 'default', 'no date -> category default');
select is((select expires_on - ((now() at time zone 'Europe/Madrid')::date) from public.pantry_lots where id = 'c0000000-0000-0000-0000-000000000001'),
          (select shelf_life_days from public.categories where id = 'fresh_poultry'), 'default = today + shelf life');
select is((public.add_item('c0000000-0000-0000-0000-000000000001', 'Pollo', 'fresh_poultry', 450, 'g'))->>'repeat', 'true', 'same lot id again is a no-op');
select is((select count(*)::int from public.pantry_lots), 3, 'still 3 lots after the repeat');
select is((select count(*)::int from public.products where lower(name) = 'pollo'), 1, 'one product for Pollo');
select is(pg_temp.err($$select public.add_item(gen_random_uuid(), 'Jabón', 'cleaning', 1)$$), 'NOT_FOOD', 'non-food is refused');
select is(pg_temp.err($$select public.add_item(gen_random_uuid(), '  ', 'fresh_fruit', 1)$$), 'NAME_REQUIRED', 'blank name refused');
select is(pg_temp.err($$select public.add_item(gen_random_uuid(), 'X', 'fresh_fruit', 0)$$), 'BAD_QUANTITY', 'zero quantity refused');

select is((public.app_snapshot() -> 'lots') is not null, true, 'app_snapshot returns lots');
select is(jsonb_array_length(public.app_snapshot() -> 'lots'), 3, 'app_snapshot lists the 3 lots');
select is((public.app_snapshot() -> 'overview' ->> 'in_stock')::int, 3, 'overview counts 3 in stock');
select is((public.get_overview() ->> 'expiring_3_days')::int, 1, 'fresh chicken (short shelf life) counts as expiring within 3 days');

select * from finish();
rollback;
