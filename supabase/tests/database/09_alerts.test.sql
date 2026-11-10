-- Step 6: the digest groups (§6.4), notification settings, push subscriptions, and the scheduled-job functions.
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
create function pg_temp.d(n int) returns date language sql stable as $$ select (now() at time zone 'Europe/Madrid')::date + n $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.err(text), pg_temp.d(int) to public;

insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000091', 'a1@test.local'),
                                          ('aaaaaaaa-0000-0000-0000-000000000092', 'a2@test.local');
create temp table _o(t text); grant all on _o to public;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-000000000091');

-- chicken use-by today, salmon use-by in 2 days (inside the 2-day lead), rice in 300 days (not alerted),
-- beef use-by yesterday (expired, day 1), yogurt best-before yesterday (check), yogurt 2 past its grace (still have?)
insert into _o select public.add_item(gen_random_uuid(), 'Pollo', 'fresh_poultry', 500, 'g', pg_temp.d(0))::text;
insert into _o select public.add_item(gen_random_uuid(), 'Salmón', 'fresh_fish', 2, 'unit', pg_temp.d(2))::text;
insert into _o select public.add_item(gen_random_uuid(), 'Arroz', 'dry_goods', 1000, 'g', pg_temp.d(300))::text;
insert into _o select public.add_item(gen_random_uuid(), 'Ternera', 'fresh_meat', 300, 'g', pg_temp.d(-1))::text;
insert into _o select public.add_item(gen_random_uuid(), 'Yogur A', 'yogurt_dessert', 4, 'unit', pg_temp.d(-1))::text;
insert into _o select public.add_item(gen_random_uuid(), 'Yogur B', 'yogurt_dessert', 4, 'unit',
  pg_temp.d(-1 - (select check_grace_days from public.categories where id = 'yogurt_dessert')))::text;

create temp table dg as select public.my_digest() as d;
grant select on dg to public;
select is((select d->'today'->0->>'name' from dg), 'Pollo', 'use-by today -> Today');
select is((select d->'soon'->0->>'name' from dg), 'Salmón', 'use-by in 2 days -> Next days');
select is((select jsonb_array_length(d->'soon') from dg), 1, 'rice far away is not alerted');
select is((select d->'expired'->0->>'name' from dg), 'Ternera', 'use-by yesterday -> Expired: bin it');
select is((select d->'check'->0->>'name' from dg), 'Yogur A', 'best-before yesterday -> Check it');
select is((select d->'still_have'->0->>'name' from dg), 'Yogur B', 'first day past the grace window -> Still have these?');
select is((select (d->>'count')::int from dg), 5, 'five alerted items');

-- settings + subscriptions
select is((public.set_notify_settings('08:30', false))->>'digest_time', '08:30', 'digest time saved');
select is(pg_temp.err($$select public.save_push_subscription('{"endpoint":"x"}')$$), 'BAD_SUBSCRIPTION', 'incomplete subscription refused');
insert into _o select public.save_push_subscription('{"endpoint":"https://push.example/1","keys":{"p256dh":"k","auth":"a"}}')::text;
insert into _o select public.save_push_subscription('{"endpoint":"https://push.example/1","keys":{"p256dh":"k2","auth":"a2"}}')::text;
insert into _o select public.save_push_subscription('{"endpoint":"https://push.example/2","keys":{"p256dh":"k","auth":"a"}}')::text;
select is(((public.get_notify_settings())->>'devices')::int, 2, 'two devices (same endpoint replaced)');
select is(((public.remove_push_subscription('https://push.example/2'))->>'devices')::int, 1, 'device removed');
select is(pg_temp.err($$select public.cron_digest('aaaaaaaa-0000-0000-0000-000000000091')$$) like 'permission denied%', true, 'users cannot call the scheduled-job functions');

-- an abandoned receipt draft (8 days old) and a fresh one
insert into public.purchases (id, household_id, chain_id, purchased_at, status, source, created_via, receipt_paths, parse_output, created_at)
values ('b9000000-0000-0000-0000-000000000001', public.my_household(), 'mercadona', now() - interval '8 days', 'draft', 'receipt_photo', 'app', array['h/b9/1.jpg'], '{"lines":[]}', now() - interval '8 days'),
       ('b9000000-0000-0000-0000-000000000002', public.my_household(), 'mercadona', now(), 'draft', 'receipt_photo', 'app', array['h/b9b/1.jpg'], '{"lines":[]}', now());
reset role;

-- the scheduled job (service role)
set local role service_role;
update public.user_settings set digest_time = (now() at time zone 'Europe/Madrid')::time where user_id = 'aaaaaaaa-0000-0000-0000-000000000091';
select is((select count(*)::int from jsonb_array_elements(public.cron_due_users()) x where x->>'email' = 'a1@test.local'), 1, 'user is due this hour');
select is(((public.cron_digest('aaaaaaaa-0000-0000-0000-000000000091'))->>'count')::int, 5, 'cron digest = what the user sees');
select is(((public.cron_digest('aaaaaaaa-0000-0000-0000-000000000092'))->>'empty')::boolean, true, 'empty pantry -> empty digest');
select public.cron_mark_sent('aaaaaaaa-0000-0000-0000-000000000091', (now() at time zone 'Europe/Madrid')::date);
select is((select count(*)::int from jsonb_array_elements(public.cron_due_users()) x where x->>'email' = 'a1@test.local'), 0, 'not due again the same day');
select is((public.cron_retention())->>'drafts_voided', '1', 'only the 8-day-old draft is voided');
select is((select receipt_paths from public.purchases where id = 'b9000000-0000-0000-0000-000000000001'), array['h/b9/1.jpg'], 'its photo path is kept (D19)');
select is((select parse_output is not null from public.purchases where id = 'b9000000-0000-0000-0000-000000000001'), true, 'and what Claude read is kept');
select is((select status from public.purchases where id = 'b9000000-0000-0000-0000-000000000002'), 'draft', 'the fresh draft is untouched');
reset role;

select * from finish();
rollback;
