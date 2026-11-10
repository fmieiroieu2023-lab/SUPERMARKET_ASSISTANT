-- English names (categories, products, ingredient fallback) and shopping-list quantities.
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

select is((select count(*)::int from public.categories where name_en is null), 0, 'every category has an English name');

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000081', 'n1@test.local');
create temp table _o(t text); grant all on _o to public;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000081');

insert into _o select public.save_receipt_draft('b8000000-0000-0000-0000-000000000001', public.my_household(), '{}', jsonb_build_object(
  'chain', 'mercadona', 'purchased_at', null, 'total_cents', 300, 'lines', jsonb_build_array(
    jsonb_build_object('raw_text', 'LECHE SEMI', 'name_guess', 'Leche semidesnatada', 'name_en', 'Semi-skimmed milk', 'category_guess', 'milk_uht',
                       'ingredient_guess', 'milk', 'printed_qty', 1, 'printed_unit', 'pack', 'line_total_cents', 100, 'kind', 'item'),
    jsonb_build_object('raw_text', 'PLATANO', 'name_guess', 'Plátano', 'category_guess', 'fresh_fruit',
                       'ingredient_guess', 'banana', 'printed_qty', 1, 'printed_unit', 'pack', 'line_total_cents', 200, 'kind', 'item'))))::text;
select is((public.receipt_review('b8000000-0000-0000-0000-000000000001'))->'lines'->0->>'name_en', 'Semi-skimmed milk', 'review carries the English name');
insert into _o select public.finish_receipt('b8000000-0000-0000-0000-000000000001', '[
  {"line_no":1,"action":"new","name":"Leche semidesnatada","name_en":"Semi-skimmed milk","category_id":"milk_uht","ingredient_id":"milk","unit":"unit"},
  {"line_no":2,"action":"new","name":"Plátano","category_id":"fresh_fruit","ingredient_id":"banana","unit":"unit"}]')::text;
select is((select name_en from public.products where name = 'Leche semidesnatada'), 'Semi-skimmed milk', 'new product keeps the English name');
select is((select x->>'name_en' from jsonb_array_elements((public.list_pantry())->'lots') x where x->>'name' = 'Leche semidesnatada'), 'Semi-skimmed milk', 'pantry shows the product''s English name');
select is((select x->>'name_en' from jsonb_array_elements((public.list_pantry())->'lots') x where x->>'name' = 'Plátano'), 'Banana', 'no English name: falls back to the ingredient');

insert into _o select public.update_shopping_list(p_add => '[{"id":"a8000000-0000-0000-0000-000000000001","ingredient_id":"eggs"}]')::text;
select is(((public.set_list_quantity('a8000000-0000-0000-0000-000000000001', 2, 'pack'))->'items'->0->>'quantity')::numeric, 2::numeric, 'quantity set');
select is((public.get_shopping_list())->'items'->0->>'unit', 'pack', 'unit set');
select is(pg_temp.err($$select public.set_list_quantity('a8000000-0000-0000-0000-000000000001', 0)$$), 'BAD_QUANTITY', 'zero refused');
select is(pg_temp.err($$select public.set_list_quantity('a8000000-0000-0000-0000-000000000001', 1, 'cups')$$), 'BAD_UNIT', 'unknown unit refused');
insert into _o select public.set_list_quantity('a8000000-0000-0000-0000-000000000001', null)::text;
select is((public.get_shopping_list())->'items'->0->'quantity', 'null'::jsonb, 'quantity cleared');

reset role;
select * from finish();
rollback;
