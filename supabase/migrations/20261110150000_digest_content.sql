-- Digest content approved by Francisco (2026-11-10): per-item quantity/place for the email, and the shopping list.

create or replace function public._digest(p_household uuid, p_user uuid, p_day date)
returns jsonb language plpgsql stable set search_path = '' as $$
declare ub int; bb int; g jsonb; b jsonb; budget jsonb; n int; sl jsonb; list jsonb; list_n int := 0;
begin
  select coalesce(use_by_lead_days, 2), coalesce(best_before_lead_days, 3) into ub, bb
    from public.user_settings where user_id = p_user;
  ub := coalesce(ub, 2); bb := coalesce(bb, 3);

  with v as (
    select l.id, coalesce(pr.name_en, ing.name_en, l.name) as name, l.name as name_es, l.state, l.expiry_kind,
           l.effective_expires_on as e, l.checked_on, l.grace_days, l.location, l.qty_left, l.unit
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
      'expired',    coalesce(jsonb_agg(jsonb_build_object('lot_id', id, 'name', name, 'name_es', name_es, 'date', e, 'qty', qty_left, 'unit', unit, 'location', location, 'kind', expiry_kind) order by e) filter (where grp = 'expired'), '[]'),
      'check',      coalesce(jsonb_agg(jsonb_build_object('lot_id', id, 'name', name, 'name_es', name_es, 'date', e, 'qty', qty_left, 'unit', unit, 'location', location, 'kind', expiry_kind) order by e) filter (where grp = 'check'), '[]'),
      'today',      coalesce(jsonb_agg(jsonb_build_object('lot_id', id, 'name', name, 'name_es', name_es, 'date', e, 'qty', qty_left, 'unit', unit, 'location', location, 'kind', expiry_kind) order by name) filter (where grp = 'today'), '[]'),
      'soon',       coalesce(jsonb_agg(jsonb_build_object('lot_id', id, 'name', name, 'name_es', name_es, 'date', e, 'qty', qty_left, 'unit', unit, 'location', location, 'kind', expiry_kind) order by e, name) filter (where grp = 'soon'), '[]'),
      'still_have', coalesce(jsonb_agg(jsonb_build_object('lot_id', id, 'name', name, 'name_es', name_es, 'date', e, 'qty', qty_left, 'unit', unit, 'location', location, 'kind', expiry_kind) order by e) filter (where grp = 'still_have'), '[]')),
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

  -- the shopping list: how many things, and roughly what they'll cost (D20: it never adds by itself)
  begin
    sl := public.get_shopping_list();
    list_n := jsonb_array_length(sl->'items');
    if list_n > 0 then
      list := jsonb_build_object('count', list_n, 'estimate_cents', sl->'estimate_cents', 'unknown', sl->'estimate_unknown');
    end if;
  exception when others then list := null; list_n := 0;
  end;

  return g || jsonb_build_object('day', p_day, 'count', n, 'budget', budget, 'list', list,
                                 'empty', n = 0 and budget is null and list_n = 0);
end $$;
