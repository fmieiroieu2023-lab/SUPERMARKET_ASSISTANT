-- Minimal stand-ins for what Supabase provides, so the migrations run in PGlite.
-- Only what our SQL uses: roles, auth.uid()/jwt(), auth.users, storage.buckets/objects/foldername, a tiny pgTAP.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists extensions;
create schema if not exists auth;
create schema if not exists storage;
grant usage on schema public, extensions, auth, storage to anon, authenticated, service_role;

create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb, created_at timestamptz default now());
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as $$ select nullif(auth.jwt()->>'sub', '')::uuid $$;
create function auth.role() returns text language sql stable as $$ select auth.jwt()->>'role' $$;
grant execute on all functions in schema auth to anon, authenticated, service_role;

create table storage.buckets (id text primary key, name text, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets,
  name text, owner uuid, created_at timestamptz default now());
alter table storage.objects enable row level security;
grant select, insert, update, delete on storage.objects to authenticated;
create function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;
grant execute on function storage.foldername(text) to anon, authenticated;

-- Tiny pgTAP: each assertion returns one "ok - ..." / "not ok - ..." row; the runner counts them.
create schema tap;
grant usage on schema tap to public;
create function tap.no_plan() returns setof text language sql as $$ select null::text where false $$;
create function tap.finish() returns setof text language sql as $$ select null::text where false $$;
create function tap.ok(b boolean, d text default '') returns text language sql as $$
  select case when b then 'ok - ' else 'not ok - ' end || coalesce(d, '') $$;
create function tap.is(a anyelement, b anyelement, d text default '') returns text language sql as $$
  select case when a is not distinct from b then 'ok - ' || coalesce(d, '')
         else 'not ok - ' || coalesce(d, '') || ' # got: ' || coalesce(a::text, 'NULL') || ' expected: ' || coalesce(b::text, 'NULL') end $$;
create function tap.isnt(a anyelement, b anyelement, d text default '') returns text language sql as $$
  select case when a is distinct from b then 'ok - ' else 'not ok - ' end || coalesce(d, '') $$;
create function tap.pass(d text default '') returns text language sql as $$ select 'ok - ' || coalesce(d, '') $$;
grant execute on all functions in schema tap to public;
