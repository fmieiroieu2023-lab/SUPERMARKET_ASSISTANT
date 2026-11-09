-- Step 4b: undo within the same ledger, opened / frozen / restore, and the item page data.
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

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000051', 'p1@test.local'),
                                          ('aaaaaaaa-0000-0000-0000-000000000052', 'p2@test.local');
create temp table _o(t text); grant all on _o to public;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000051');

insert into _o select public.add_item('c5000000-0000-0000-0000-000000000001', 'Pollo', 'fresh_poultry', 500, 'g')::text;
insert into _o select public.add_item('c5000000-0000-0000-0000-000000000002', 'Leche', 'dairy_chilled', 1000, 'ml')::text;

-- Undo: used 200 g, undo -> back to 500; undo twice is a no-op; an undo can't be undone.
insert into _o select public.consume('c5000000-0000-0000-0000-000000000001', 200, 'consume', 'e5000000-0000-0000-0000-000000000001')::text;
select is((select qty_left from public.pantry where id = 'c5000000-0000-0000-0000-000000000001'), 300::numeric, '200 g used, 300 left');
select is((public.undo_movement('e5000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000002'))->>'qty_left', '500.000', 'undo puts it back');
select is((public.undo_movement('e5000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000003'))->>'repeat', 'true', 'undoing again is a no-op');
select is((select qty_left from public.pantry where id = 'c5000000-0000-0000-0000-000000000001'), 500::numeric, 'still 500 after the repeat');
select is(pg_temp.err($$select public.undo_movement('e5000000-0000-0000-0000-000000000002')$$), 'CANNOT_UNDO_AN_UNDO', 'an undo cannot be undone');
select is((select reverses from public.stock_movements where id = 'e5000000-0000-0000-0000-000000000002'), 'e5000000-0000-0000-0000-000000000001'::uuid, 'the undo row points at what it reverses');

-- Opened: milk's effective date shortens; restore puts the marks back.
create temp table m1 as select public.mark_lot('c5000000-0000-0000-0000-000000000002', 'opened') as r;
grant select on m1 to public;
select ok((select opened_on is not null from public.pantry_lots where id = 'c5000000-0000-0000-0000-000000000002'), 'opened date set');
select ok((select effective_expires_on <= expires_on from public.pantry where id = 'c5000000-0000-0000-0000-000000000002'), 'opened never extends the date');
insert into _o select public.mark_lot('c5000000-0000-0000-0000-000000000002', 'restore', (select r->'prev' from m1))::text;
select is((select opened_on from public.pantry_lots where id = 'c5000000-0000-0000-0000-000000000002'), null::date, 'undo of opened clears it');

-- Frozen: moves to the freezer and the date follows the freezer life.
insert into _o select public.mark_lot('c5000000-0000-0000-0000-000000000001', 'frozen')::text;
select is((select location from public.pantry_lots where id = 'c5000000-0000-0000-0000-000000000001'), 'freezer', 'frozen chicken is in the freezer');
select ok((select effective_expires_on > expires_on from public.pantry where id = 'c5000000-0000-0000-0000-000000000001'), 'freezing extends the date');
insert into _o select public.mark_lot('c5000000-0000-0000-0000-000000000001', 'thawed')::text;
select is((select location from public.pantry_lots where id = 'c5000000-0000-0000-0000-000000000001'), 'fridge', 'thawed goes back to the fridge');
select is(pg_temp.err($$select public.mark_lot('c5000000-0000-0000-0000-000000000001', 'eaten')$$), 'BAD_ACTION', 'unknown action refused');

-- Item page data
select is((public.get_lot('c5000000-0000-0000-0000-000000000001'))->>'name', 'Pollo', 'item page has the name');
select is(jsonb_array_length((public.get_lot('c5000000-0000-0000-0000-000000000001'))->'history'), 3, 'history: added, used, undo');
select is((public.get_lot('c5000000-0000-0000-0000-000000000001'))->>'can_freeze', 'true', 'chicken can be frozen');

-- Another user can't touch it
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000052');
select is(pg_temp.err($$select public.mark_lot('c5000000-0000-0000-0000-000000000001', 'opened')$$), 'NOT_FOUND', 'user 2 cannot mark user 1''s lot');
select is(pg_temp.err($$select public.undo_movement('e5000000-0000-0000-0000-000000000001')$$), 'NOT_FOUND', 'user 2 cannot undo user 1''s movement');
select is(public.get_lot('c5000000-0000-0000-0000-000000000001'), null::jsonb, 'user 2 sees no item page');

reset role;
select * from finish();
rollback;
