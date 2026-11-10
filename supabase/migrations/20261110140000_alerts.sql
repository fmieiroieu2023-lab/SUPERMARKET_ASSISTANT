-- Step 6: alerts. The daily digest (§6.4) as one SQL function used by the app and by the scheduled job,
-- notification settings, push subscriptions, and the nightly clean-up.
-- Decision D19 (Francisco): receipt photos are never deleted; they are kept for item recognition.

-- ── The digest: what to tell you today ───────────────────────────────────────
-- Groups (§6.4): expired (first 3 days, "bin it"), check, today, soon (inside the lead window),
-- still_have (first day a best-before / estimate item stops counting). Plus budget alerts (§6.7).
create function public._digest(p_household uuid, p_user uuid, p_day date)
returns jsonb language plpgsql stable set search_path = '' as $$
declare ub int; bb int; g jsonb; b jsonb; budget jsonb; n int;
begin
  select coalesce(use_by_lead_days, 2), coalesce(best_before_lead_days, 3) into ub, bb
    from public.user_settings where user_id = p_user;
  ub := coalesce(ub, 2); bb := coalesce(bb, 3);

  with v as (
    select l.id, coalesce(pr.name_en, ing.name_en, l.name) as name, l.name as name_es, l.state, l.expiry_kind,
           l.effective_expires_on as e, l.checked_on, l.grace_days, l.location
      from public.pantry l
      left join public.products pr on pr.id = l.product_id
      left join public.ingredients ing on ing.id = l.ingredient_id
     where l.household_id = p_household and l.qty_left > 0),
  tagged as (
    select v.*, case
      when state = 'expired' and p_day - e between 1 and 3 then 'expired'
      when state = 'check' then 'check'
      when state = 'ok' and e = p_day then 'today'
      when state = 'ok' and e > p_day and e - p_day <= case when expiry_kind = 'use_by' then ub else bb end then 'soon'
      when state = 'unconfirmed' and p_day = greatest(e, coalesce(checked_on, e)) + grace_days + 1 then 'still_have'
    end as grp
    from v)
  select jsonb_build_object(
      'expired',    coalesce(jsonb_agg(jsonb_build_object('lot_id', id, 'name', name, 'name_es', name_es, 'date', e) order by e) filter (where grp = 'expired'), '[]'),
      'check',      coalesce(jsonb_agg(jsonb_build_object('lot_id', id, 'name', name, 'name_es', name_es, 'date', e) order by e) filter (where grp = 'check'), '[]'),
      'today',      coalesce(jsonb_agg(jsonb_build_object('lot_id', id, 'name', name, 'name_es', name_es, 'date', e) order by name) filter (where grp = 'today'), '[]'),
      'soon',       coalesce(jsonb_agg(jsonb_build_object('lot_id', id, 'name', name, 'name_es', name_es, 'date', e) order by e, name) filter (where grp = 'soon'), '[]'),
      'still_have', coalesce(jsonb_agg(jsonb_build_object('lot_id', id, 'name', name, 'name_es', name_es, 'date', e) order by e) filter (where grp = 'still_have'), '[]')),
         count(*) filter (where grp is not null)
    into g, n
    from tagged;

  -- budget facts: hard alerts at 80 % / 100 %, and the projection alert
  begin
    b := public.budget_status(null, p_day);
    if b->>'alert' is not null or coalesce((b->'projection'->>'alert')::boolean, false) then
      budget := jsonb_build_object('alert', b->>'alert', 'pct', b->'pct', 'spent_cents', b->'spent_cents',
                                   'budget_cents', b->'budget_cents', 'projected_cents', b->'projection'->'projected_cents',
                                   'projection_alert', coalesce((b->'projection'->>'alert')::boolean, false));
    end if;
  exception when others then budget := null;
  end;

  return g || jsonb_build_object('day', p_day, 'count', n, 'budget', budget, 'empty', n = 0 and budget is null);
end $$;
revoke all on function public._digest(uuid, uuid, date) from public, anon;
grant execute on function public._digest(uuid, uuid, date) to authenticated;

-- Your digest, now (app: home-screen badge, "send a test notification").
create function public.my_digest()
returns jsonb language sql stable set search_path = '' as $$
  select public._digest(public.my_household(), (select auth.uid()),
                        (now() at time zone (select timezone from public.households where id = public.my_household()))::date);
$$;
revoke all on function public.my_digest() from public, anon;
grant execute on function public.my_digest() to authenticated;

-- ── Settings and push subscriptions (your own row; RLS) ──────────────────────
create function public.get_notify_settings()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('digest_time', to_char(s.digest_time, 'HH24:MI'), 'email_digest', s.email_digest,
                            'use_by_lead_days', s.use_by_lead_days, 'best_before_lead_days', s.best_before_lead_days,
                            'devices', case when jsonb_typeof(s.push_subscription) = 'array' then jsonb_array_length(s.push_subscription) else 0 end,
                            'endpoints', coalesce((select jsonb_agg(x->>'endpoint') from jsonb_array_elements(
                                           case when jsonb_typeof(s.push_subscription) = 'array' then s.push_subscription else '[]'::jsonb end) x), '[]'))
    from public.user_settings s where s.user_id = (select auth.uid());
$$;

create function public.set_notify_settings(
  p_digest_time text default null, p_email_digest boolean default null,
  p_use_by_lead_days int default null, p_best_before_lead_days int default null)
returns jsonb language plpgsql set search_path = '' as $$
begin
  update public.user_settings set
    digest_time = coalesce(p_digest_time::time, digest_time),
    email_digest = coalesce(p_email_digest, email_digest),
    use_by_lead_days = coalesce(p_use_by_lead_days, use_by_lead_days),
    best_before_lead_days = coalesce(p_best_before_lead_days, best_before_lead_days)
  where user_id = (select auth.uid());
  if not found then raise exception 'NOT_FOUND'; end if;
  return public.get_notify_settings();
end $$;

-- One subscription per device (iPhone home-screen app, Mac, ...). Same endpoint again = replaced.
create function public.save_push_subscription(p_sub jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare cur jsonb;
begin
  if p_sub->>'endpoint' is null or p_sub->'keys'->>'p256dh' is null or p_sub->'keys'->>'auth' is null then raise exception 'BAD_SUBSCRIPTION'; end if;
  select case when jsonb_typeof(push_subscription) = 'array' then push_subscription else '[]'::jsonb end into cur
    from public.user_settings where user_id = (select auth.uid()) for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.user_settings set push_subscription =
    coalesce((select jsonb_agg(x) from jsonb_array_elements(cur) x where x->>'endpoint' <> p_sub->>'endpoint'), '[]'::jsonb)
    || jsonb_build_array(jsonb_build_object('endpoint', p_sub->>'endpoint', 'keys', p_sub->'keys', 'added', now()))
  where user_id = (select auth.uid());
  return public.get_notify_settings();
end $$;

create function public.remove_push_subscription(p_endpoint text)
returns jsonb language plpgsql set search_path = '' as $$
begin
  update public.user_settings set push_subscription =
    coalesce((select jsonb_agg(x) from jsonb_array_elements(case when jsonb_typeof(push_subscription) = 'array' then push_subscription else '[]'::jsonb end) x
               where x->>'endpoint' <> p_endpoint), '[]'::jsonb)
  where user_id = (select auth.uid());
  return public.get_notify_settings();
end $$;

revoke all on function public.get_notify_settings(), public.set_notify_settings(text, boolean, int, int),
  public.save_push_subscription(jsonb), public.remove_push_subscription(text) from public, anon;
grant execute on function public.get_notify_settings(), public.set_notify_settings(text, boolean, int, int),
  public.save_push_subscription(jsonb), public.remove_push_subscription(text) to authenticated;

-- ── Scheduled job only (service role; called by the daily-digest Edge Function) ─
-- Users whose digest time falls in this hour (their household's time zone) and who haven't had today's digest.
create function public.cron_due_users(p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', s.user_id, 'email', u.email, 'household_id', m.household_id, 'email_digest', s.email_digest,
           'push', case when jsonb_typeof(s.push_subscription) = 'array' then s.push_subscription else '[]'::jsonb end,
           'day', (p_now at time zone h.timezone)::date)), '[]'::jsonb)
    from public.user_settings s
    join auth.users u on u.id = s.user_id
    join lateral (select household_id from public.household_members where user_id = s.user_id order by household_id limit 1) m on true
    join public.households h on h.id = m.household_id
   where extract(hour from (p_now at time zone h.timezone)) = extract(hour from s.digest_time)
     and coalesce(s.last_digest_on, '-infinity'::date) < (p_now at time zone h.timezone)::date;
$$;

-- One user's digest, computed as that user (so budget_status and RLS-style filters see the right household).
create function public.cron_digest(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare h uuid; tz text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  select m.household_id, hh.timezone into h, tz from public.household_members m join public.households hh on hh.id = m.household_id
   where m.user_id = p_user order by m.household_id limit 1;
  if h is null then return null; end if;
  return public._digest(h, p_user, (now() at time zone tz)::date);
end $$;

create function public.cron_mark_sent(p_user uuid, p_day date)
returns void language sql security definer set search_path = '' as $$
  update public.user_settings set last_digest_on = p_day where user_id = p_user;
$$;

create function public.cron_drop_subscription(p_user uuid, p_endpoint text)
returns void language sql security definer set search_path = '' as $$
  update public.user_settings set push_subscription =
    coalesce((select jsonb_agg(x) from jsonb_array_elements(case when jsonb_typeof(push_subscription) = 'array' then push_subscription else '[]'::jsonb end) x
               where x->>'endpoint' <> p_endpoint), '[]'::jsonb)
   where user_id = p_user;
$$;

-- Nightly clean-up: receipt drafts left unfinished for 7 days become void. Their photos and what Claude read
-- are KEPT (D19), and drafts that already hold pantry items (unpacking sessions) are never touched.
create function public.cron_retention()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.purchases p set status = 'void'
   where p.status = 'draft' and p.source in ('receipt_photo', 'receipt_file') and p.created_at < now() - interval '7 days'
     and not exists (select 1 from public.pantry_lots l where l.purchase_id = p.id);
  get diagnostics n = row_count;
  return jsonb_build_object('drafts_voided', n, 'photos_deleted', 0);
end $$;

revoke all on function public.cron_due_users(timestamptz), public.cron_digest(uuid), public.cron_mark_sent(uuid, date),
  public.cron_drop_subscription(uuid, text), public.cron_retention() from public, anon, authenticated;
grant execute on function public.cron_due_users(timestamptz), public.cron_digest(uuid), public.cron_mark_sent(uuid, date),
  public.cron_drop_subscription(uuid, text), public.cron_retention() to service_role;

-- ── App snapshot: also the items that stopped counting, for the "Still have it?" cards ─
create or replace function public.app_snapshot() returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'overview', public.get_overview(),
    'lots', coalesce(public.list_pantry(null, null, 'expired', null, 200) -> 'lots', '[]'::jsonb)
         || coalesce(public.list_pantry(null, null, 'unconfirmed', null, 200) -> 'lots', '[]'::jsonb)
         || coalesce(public.list_pantry(null, null, null, null, 200) -> 'lots', '[]'::jsonb));
$$;
