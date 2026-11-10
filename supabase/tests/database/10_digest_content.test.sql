-- The approved digest content: quantities on items, and the shopping list line.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to public;
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000101', 'c1@test.local');
create temp table _o(t text); grant all on _o to public;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000101');

select is(((public.my_digest())->>'empty')::boolean, true, 'nothing at all -> empty (no notification)');
insert into _o select public.update_shopping_list(p_add => '[{"id":"a1000000-0000-0000-0000-000000000001","label":"Papel de cocina"}]')::text;
select is(((public.my_digest())->'list'->>'count')::int, 1, 'list line: 1 item');
select is(((public.my_digest())->>'empty')::boolean, false, 'a list alone is worth a (quiet) notification');
insert into _o select public.add_item(gen_random_uuid(), 'Pollo', 'fresh_poultry', 512, 'g', (now() at time zone 'Europe/Madrid')::date)::text;
select is((public.my_digest())->'today'->0->>'qty', '512.000', 'today items carry their quantity');
select is((public.my_digest())->'today'->0->>'location', 'fridge', 'and where they are');

reset role;
select * from finish();
rollback;
