-- Shopping list (manual slice of step 8) and budget (step 7), incl. the §6.7 second worked check.
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

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000071', 'l1@test.local'),
                                          ('aaaaaaaa-0000-0000-0000-000000000072', 'l2@test.local');
create temp table _o(t text); grant all on _o to public;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000071');

-- ── List: add, merge, repeat, tick, untick, dismiss ──
insert into _o select public.update_shopping_list(p_add => '[{"id":"a7000000-0000-0000-0000-000000000001","label":"Leche","ingredient_id":"milk"}]')::text;
select is(jsonb_array_length((public.get_shopping_list())->'items'), 1, 'one item on the list');
select is((public.get_shopping_list())->'items'->0->>'ingredient_id', 'milk', 'linked to the milk ingredient');
insert into _o select public.update_shopping_list(p_add => '[{"id":"a7000000-0000-0000-0000-000000000002","label":"Leche entera","ingredient_id":"milk"}]')::text;
select is(jsonb_array_length((public.get_shopping_list())->'items'), 1, 'same ingredient again is merged, not doubled');
insert into _o select public.update_shopping_list(p_add => '[{"id":"a7000000-0000-0000-0000-000000000001","label":"Leche"}]')::text;
select is((select count(*)::int from public.shopping_list_items), 1, 'same id again is a no-op');
insert into _o select public.update_shopping_list(p_add => '[{"id":"a7000000-0000-0000-0000-000000000003","label":"Papel de cocina"}]')::text;
select is(jsonb_array_length((public.get_shopping_list())->'items'), 2, 'free text item added');
select is(pg_temp.err($$select public.update_shopping_list(p_add => '[{"id":"a7000000-0000-0000-0000-000000000009","label":"  "}]')$$), 'LABEL_REQUIRED', 'blank item refused');

insert into _o select public.update_shopping_list(p_bought => array['a7000000-0000-0000-0000-000000000001']::uuid[])::text;
select is(jsonb_array_length((public.get_shopping_list())->'items'), 1, 'ticked item leaves the open list');
select is(jsonb_array_length((public.get_shopping_list())->'basket'), 1, 'and sits in the basket');
insert into _o select public.update_shopping_list(p_reopen => array['a7000000-0000-0000-0000-000000000001']::uuid[])::text;
select is(jsonb_array_length((public.get_shopping_list())->'items'), 2, 'untick puts it back');
insert into _o select public.update_shopping_list(p_dismiss => array['a7000000-0000-0000-0000-000000000003']::uuid[])::text;
select is(jsonb_array_length((public.get_shopping_list())->'items'), 1, 'dismissed item is gone');

-- ── Suggestions: a finished item with nothing left is suggested; the cost estimate uses the last price ──
insert into _o select public.save_receipt_draft('b7000000-0000-0000-0000-000000000001', public.my_household(), '{}', jsonb_build_object(
  'chain', 'mercadona', 'purchased_at', null, 'total_cents', 250, 'lines', jsonb_build_array(
    jsonb_build_object('raw_text', 'HUEVOS', 'category_guess', 'eggs', 'printed_qty', 1, 'printed_unit', 'pack', 'line_total_cents', 250, 'kind', 'item'))))::text;
insert into _o select public.finish_receipt('b7000000-0000-0000-0000-000000000001',
  '[{"line_no":1,"action":"new","name":"Huevos","category_id":"eggs","ingredient_id":"eggs","unit":"unit","pack_size":12}]')::text;
insert into _o select public.consume((select id from public.pantry_lots where purchase_id = 'b7000000-0000-0000-0000-000000000001'), 12)::text;
select is((public.get_shopping_list())->'suggestions'->0->>'label', 'Huevos', 'finished eggs are suggested');
insert into _o select public.update_shopping_list(p_add => '[{"id":"a7000000-0000-0000-0000-000000000004","ingredient_id":"eggs"}]')::text;
select is(jsonb_array_length((public.get_shopping_list())->'suggestions'), 0, 'once on the list, no longer suggested');
select is(((public.get_shopping_list())->>'estimate_cents')::int, 250, 'estimate = last price of the eggs');
select is((select x->'last'->>'chain' from jsonb_array_elements((public.get_shopping_list())->'items') x where x->>'ingredient_id' = 'eggs'), 'Mercadona', 'shows where you last bought it');

-- ── Budget ──
select is((public.budget_status())->'budget_cents', 'null'::jsonb, 'no budget yet');
select is(pg_temp.err($$select public.set_budget(0)$$), 'BAD_AMOUNT', 'zero budget refused');
select is(((public.set_budget(25000))->>'budget_cents')::int, 25000, 'monthly budget set');
select is(((public.budget_status())->>'spent_cents')::int, 250, 'spent this month = the egg trip');
select is(((public.budget_status())->>'left_cents')::int, 24750, 'left');

reset role;
-- §6.7 second worked check: Nov 2026, budget €250, no earlier history.
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000072');
insert into _o select public.set_budget(25000)::text;
insert into public.purchases (id, household_id, chain_id, purchased_at, time_source, status, source, total_cents, confirmed_at, created_via)
select gen_random_uuid(), public.my_household(), c, (d || ' 12:00')::timestamp at time zone 'Europe/Madrid', 'entered', 'confirmed', 'manual', t, now(), 'app'
  from (values ('mercadona', '2026-11-01', 3000), ('carrefour', '2026-11-01', 1500), ('supercor', '2026-11-02', 1000)) v(c, d, t);
select is((public.budget_status(null, '2026-11-02'))->'projection'->>'needs', 'Needs 3 shopping days over 2 weeks', 'two shopping days: no projection');
select is(((public.budget_status(null, '2026-11-02'))->>'pct')::int, 22, 'only the hard figure: 22% of budget');
insert into public.purchases (id, household_id, chain_id, purchased_at, time_source, status, source, total_cents, confirmed_at, created_via)
select gen_random_uuid(), public.my_household(), 'mercadona', (d || ' 12:00')::timestamp at time zone 'Europe/Madrid', 'entered', 'confirmed', 'manual', t, now(), 'app'
  from (values ('2026-11-08', 4000), ('2026-11-15', 5000)) v(d, t);
select is(((public.budget_status(null, '2026-11-15'))->'projection'->>'projected_cents')::int, 21286, 'projection on 15 Nov = €213 (212.86)');
select is((public.budget_status(null, '2026-11-15'))->'projection'->>'next_shop', '2026-11-21', 'next shop expected 21 Nov');
select is((public.budget_status(null, '2026-11-15'))->'projection'->>'alert', 'false', 'no projection alert under €271.25');
select is(((public.budget_status(null, '2026-11-15'))->>'spent_cents')::int, 14500, 'spent €145');
select is(jsonb_array_length((public.get_shopping_list())->'items'), 0, 'user 2 sees none of user 1''s list');

reset role;
select * from finish();
rollback;
