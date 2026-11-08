-- Step 1, part 1: schema. Source: docs/reference/arena-winning-plan.md section 5.
-- Money = integer cents. Expiry = date. Events = timestamptz. Every household table has household_id.

create extension if not exists pg_trgm with schema extensions;
create extension if not exists fuzzystrmatch with schema extensions;   -- levenshtein() for near-match ticket numbers
create extension if not exists unaccent with schema extensions;

-- ── Global reference data (read-only to users, seeded by migrations) ─────────
create table public.chains (id text primary key, name text not null);

create table public.categories (
  id                     text primary key,
  name_es                text not null,
  is_food                boolean not null,
  default_location       text not null check (default_location in ('fridge','freezer','pantry')),
  shelf_life_days        int,
  opened_shelf_life_days int,
  freezer_life_days      int,
  expiry_kind            text not null check (expiry_kind in ('use_by','best_before','estimate','none')),
  ask_printed_date       boolean not null default false,
  check_grace_days       int check (check_grace_days >= 0),
  check ((expiry_kind = 'none') = (shelf_life_days is null)),
  check ((expiry_kind in ('best_before','estimate')) = (check_grace_days is not null))
);

create table public.ingredients (
  id             text primary key,
  name_es        text not null,
  name_en        text not null,
  is_basic       boolean not null default false,
  typical_unit_g numeric(8,1) check (typical_unit_g > 0)
);

create table public.ingredient_aliases (
  alias         text primary key,
  kind          text not null check (kind in ('name','off_tag')),
  ingredient_id text not null references public.ingredients
);
create index ingredient_aliases_trg on public.ingredient_aliases using gin (alias extensions.gin_trgm_ops);
create index ingredient_aliases_ingredient_idx on public.ingredient_aliases (ingredient_id);

-- ── Tenancy ──────────────────────────────────────────────────────────────────
create table public.households (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null default 'Casa',
  timezone             text not null default 'Europe/Madrid',
  currency             char(3) not null default 'EUR',
  monthly_budget_cents int check (monthly_budget_cents > 0),
  mcp_write_enabled    boolean not null default true,
  created_at           timestamptz not null default now()
);

create table public.household_members (
  household_id uuid not null references public.households on delete cascade,
  user_id      uuid not null references auth.users on delete cascade,
  role         text not null default 'owner' check (role in ('owner','member')),
  primary key (household_id, user_id)
);
create index household_members_user_idx on public.household_members (user_id);

-- ── Products and receipt learning ────────────────────────────────────────────
create table public.products (
  id                     uuid primary key default gen_random_uuid(),
  household_id           uuid not null references public.households on delete cascade,
  gtin                   text check (gtin ~ '^([0-9]{8}|[0-9]{12,14})$'),
  name                   text not null,
  brand                  text,
  category_id            text not null references public.categories,
  ingredient_id          text references public.ingredients,
  unit                   text not null check (unit in ('unit','g','ml')),
  pack_size              numeric(10,3) check (pack_size > 0),
  unit_weight_g          numeric(8,1) check (unit_weight_g > 0),
  shelf_life_days        int,
  opened_shelf_life_days int,
  expiry_kind            text check (expiry_kind in ('use_by','best_before','estimate')),
  kind_confirmed         boolean not null default false,
  source                 text not null check (source in ('off','manual','receipt','claude')),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  check (unit_weight_g is null or unit = 'unit'),
  unique (id, household_id)
);
create unique index products_gtin_uq  on public.products (household_id, gtin) where gtin is not null;
create index        products_name_trg on public.products using gin (name extensions.gin_trgm_ops);
create index        products_category_idx   on public.products (category_id);
create index        products_ingredient_idx on public.products (ingredient_id);

create table public.receipt_aliases (
  household_id uuid not null references public.households on delete cascade,
  chain_id     text not null references public.chains,
  alias        text not null,
  product_id   uuid not null,
  hits         int not null default 1,
  primary key (household_id, chain_id, alias),
  foreign key (product_id, household_id) references public.products (id, household_id) on delete cascade
);
create index receipt_aliases_trg on public.receipt_aliases using gin (alias extensions.gin_trgm_ops);
create index receipt_aliases_product_idx on public.receipt_aliases (product_id, household_id);

-- ── Purchases (one row per shopping trip) ────────────────────────────────────
create table public.purchases (
  id            uuid primary key,
  household_id  uuid not null references public.households on delete cascade,
  chain_id      text not null references public.chains,
  store_label   text,
  purchased_at  timestamptz not null,
  time_source   text not null default 'entered' check (time_source in ('printed','entered')),
  ticket_number text,
  ticket_norm   text generated always as
                (nullif(regexp_replace(upper(ticket_number), '[^A-Z0-9]', '', 'g'), '')) stored,
  confirmed_at  timestamptz,
  status        text not null check (status in ('draft','confirmed','void')),
  source        text not null check (source in ('receipt_photo','receipt_file','scan','manual','claude')),
  total_cents   int,
  verification  text not null default 'unverified'
                check (verification in ('sum_ok','adjusted','total_only','unverified')),
  receipt_paths text[] not null default '{}',
  parse_output  jsonb,
  created_by    uuid references auth.users on delete set null,
  created_via   text not null check (created_via in ('app','mcp')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (status <> 'confirmed' or (total_cents is not null and confirmed_at is not null)),
  check (status <> 'draft' or ticket_number is null),
  unique (id, household_id)
);
create unique index purchases_ticket_uq on public.purchases (household_id, chain_id, ticket_norm)
  where ticket_norm is not null and status = 'confirmed';
create index purchases_day_idx on public.purchases (household_id, chain_id, purchased_at) where status = 'confirmed';
create index purchases_household_idx on public.purchases (household_id, purchased_at);
create index purchases_created_by_idx on public.purchases (created_by);

create table public.purchase_items (
  id                uuid primary key,
  purchase_id       uuid not null,
  household_id      uuid not null,
  line_no           int  not null,
  kind              text not null check (kind in ('item','discount','refund','adjustment')),
  raw_text          text,
  product_id        uuid,
  category_id       text references public.categories,
  printed_qty       numeric(10,3) not null default 1 check (printed_qty > 0),
  printed_unit      text not null default 'pack' check (printed_unit in ('pack','g','ml')),
  quantity          numeric(10,3) check (quantity > 0),
  line_total_cents  int not null,
  check (kind = 'adjustment' or ((kind in ('discount','refund')) = (line_total_cents < 0))),
  unique (purchase_id, line_no),
  unique (id, household_id),
  foreign key (purchase_id, household_id) references public.purchases (id, household_id) on delete cascade,
  foreign key (product_id,  household_id) references public.products  (id, household_id)
);
create index purchase_items_product_idx  on public.purchase_items (product_id, household_id);
create index purchase_items_category_idx on public.purchase_items (category_id);

-- ── Pantry: lots + append-only movements ─────────────────────────────────────
create table public.pantry_lots (
  id               uuid primary key,
  household_id     uuid not null,
  product_id       uuid not null,
  purchase_id      uuid,
  purchase_item_id uuid,
  location         text not null check (location in ('fridge','freezer','pantry')),
  initial_qty      numeric(10,3) not null check (initial_qty > 0),
  expires_on       date not null,
  expiry_kind      text not null check (expiry_kind in ('use_by','best_before','estimate')),
  expiry_source    text not null check (expiry_source in ('printed','default','user','claude')),
  opened_on        date,
  frozen_on        date,
  checked_on       date,
  unit_cost_cents  numeric(12,4),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, household_id),
  foreign key (product_id, household_id) references public.products (id, household_id) on delete cascade,
  foreign key (purchase_id, household_id) references public.purchases (id, household_id) on delete set null (purchase_id),
  foreign key (purchase_item_id, household_id) references public.purchase_items (id, household_id)
);
create index pantry_lots_product_idx  on public.pantry_lots (product_id, household_id);
create index pantry_lots_purchase_idx on public.pantry_lots (purchase_id, household_id);
create index pantry_lots_item_idx     on public.pantry_lots (purchase_item_id, household_id);
create index pantry_lots_household_expiry_idx on public.pantry_lots (household_id, expires_on);

create table public.stock_movements (
  id           uuid primary key,
  household_id uuid not null,
  lot_id       uuid not null,
  delta        numeric(10,3) not null check (delta <> 0),
  reason       text not null check (reason in ('purchase','consume','discard','adjust')),
  occurred_at  timestamptz not null default now(),
  actor        uuid references auth.users on delete set null,
  via          text not null check (via in ('app','mcp')),
  request_id   uuid,
  reverses     uuid references public.stock_movements,
  foreign key (lot_id, household_id) references public.pantry_lots (id, household_id) on delete cascade
);
create index stock_movements_lot_idx     on public.stock_movements (lot_id, household_id);
create index stock_movements_reverses_idx on public.stock_movements (reverses);
create index stock_movements_actor_idx   on public.stock_movements (actor);
create index stock_movements_request_idx on public.stock_movements (request_id) where request_id is not null;

create view public.pantry with (security_invoker = true) as
with b as (
  select l.*, p.name, p.category_id, p.ingredient_id, p.unit, p.pack_size,
         coalesce(c.check_grace_days, 2) as grace_days,
         (now() at time zone h.timezone)::date as today,
         coalesce((select sum(m.delta) from public.stock_movements m where m.lot_id = l.id), 0) as qty_left,
         case
           when l.frozen_on is not null
             then l.frozen_on + coalesce(c.freezer_life_days, 90)
           when l.opened_on is not null
                and coalesce(p.opened_shelf_life_days, c.opened_shelf_life_days) is not null
             then least(l.expires_on,
                        l.opened_on + coalesce(p.opened_shelf_life_days, c.opened_shelf_life_days))
           else l.expires_on
         end as effective_expires_on
  from public.pantry_lots l
  join public.products   p on p.id = l.product_id
  join public.categories c on c.id = p.category_id
  join public.households h on h.id = l.household_id
)
select b.*,
       b.effective_expires_on - b.today as days_left,
       case
         when b.qty_left <= 0                    then 'finished'
         when b.today <= b.effective_expires_on  then 'ok'
         when b.expiry_kind = 'use_by'           then 'expired'
         when b.today <= greatest(b.effective_expires_on, coalesce(b.checked_on, b.effective_expires_on))
                         + b.grace_days          then 'check'
         else                                         'unconfirmed'
       end as state
from b;

-- ── Recipes, shopping list, budget, audit, settings ──────────────────────────
create table public.recipes (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid references public.households on delete cascade,   -- null = built-in library
  title        text not null,
  servings     int,
  minutes      int,
  steps        text not null,
  source       text not null check (source in ('seed','user','claude')),
  created_at   timestamptz not null default now()
);
create index recipes_household_idx on public.recipes (household_id);

create table public.recipe_ingredients (
  recipe_id     uuid not null references public.recipes on delete cascade,
  ingredient_id text not null references public.ingredients,
  quantity      numeric(10,3),
  unit          text,
  optional      boolean not null default false,
  primary key (recipe_id, ingredient_id)
);
create index recipe_ingredients_ingredient_idx on public.recipe_ingredients (ingredient_id);

create table public.staples (
  id            uuid primary key,
  household_id  uuid not null references public.households on delete cascade,
  ingredient_id text references public.ingredients,
  product_id    uuid,
  par_qty       numeric(10,3) not null check (par_qty > 0),
  unit          text not null check (unit in ('unit','g','ml')),
  check ((ingredient_id is null) <> (product_id is null)),
  foreign key (product_id, household_id) references public.products (id, household_id) on delete cascade
);
create unique index staples_key_uq on public.staples
  (household_id, coalesce('p:' || product_id::text, 'i:' || ingredient_id));
create index staples_ingredient_idx on public.staples (ingredient_id);
create index staples_product_idx    on public.staples (product_id, household_id);

create table public.shopping_list_items (
  id            uuid primary key,
  household_id  uuid not null references public.households on delete cascade,
  ingredient_id text references public.ingredients,
  product_id    uuid,
  label         text not null,
  quantity      numeric(10,3),
  unit          text,
  reasons       text[] not null,
  status        text not null default 'open' check (status in ('open','bought','dismissed','resolved')),
  snoozed_until date,
  bought_at     timestamptz,
  reconciled_at timestamptz,
  check ((status = 'bought') = (bought_at is not null)),
  added_via     text not null check (added_via in ('app','mcp','auto')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  foreign key (product_id, household_id) references public.products (id, household_id) on delete set null (product_id)
);
create unique index shopping_open_uq on public.shopping_list_items
  (household_id, coalesce('i:' || ingredient_id, 'p:' || product_id::text, 'l:' || lower(label)))
  where status = 'open';
create index shopping_list_ingredient_idx on public.shopping_list_items (ingredient_id);
create index shopping_list_product_idx    on public.shopping_list_items (product_id, household_id);

create table public.budgets (
  household_id uuid not null references public.households on delete cascade,
  month        date not null check (extract(day from month) = 1),
  amount_cents int  not null check (amount_cents > 0),
  primary key (household_id, month)
);

create table public.mcp_audit (
  id              bigint generated always as identity primary key,
  household_id    uuid not null references public.households on delete cascade,
  user_id         uuid not null,
  oauth_client_id text,
  tool            text not null,
  request_id      uuid,
  args            jsonb,
  ok              boolean not null,
  at              timestamptz not null default now()
);
create index mcp_audit_household_idx on public.mcp_audit (household_id, at desc);

create table public.user_settings (
  user_id               uuid primary key references auth.users on delete cascade,
  digest_time           time not null default '09:00',
  use_by_lead_days      int  not null default 2 check (use_by_lead_days between 0 and 7),
  best_before_lead_days int  not null default 3 check (best_before_lead_days between 0 and 14),
  email_digest          boolean not null default true,
  last_digest_on        date,
  push_subscription     jsonb          -- Web Push subscription (step 6); the native-app token column is not needed
);

create table public.usage_counters (
  household_id uuid not null references public.households on delete cascade,
  day          date not null,
  receipt_parses int not null default 0,
  primary key (household_id, day)
);

-- ── Triggers ─────────────────────────────────────────────────────────────────
create function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

create trigger products_touch    before update on public.products            for each row execute function public.touch_updated_at();
create trigger purchases_touch   before update on public.purchases           for each row execute function public.touch_updated_at();
create trigger pantry_lots_touch before update on public.pantry_lots         for each row execute function public.touch_updated_at();
create trigger shopping_touch    before update on public.shopping_list_items for each row execute function public.touch_updated_at();

-- A product's base unit is frozen once anything stores numbers in it.
create function public.products_unit_frozen() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.unit is distinct from old.unit and (
       exists (select 1 from public.pantry_lots l where l.product_id = old.id)
    or exists (select 1 from public.purchase_items i where i.product_id = old.id and i.quantity is not null)
    or exists (select 1 from public.staples s where s.product_id = old.id)) then
    raise exception 'PRODUCT_HAS_HISTORY';
  end if;
  return new;
end $$;
create trigger products_unit_frozen before update of unit on public.products
  for each row execute function public.products_unit_frozen();

-- Signup: one household + owner membership + default settings per new user.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare h uuid;
begin
  insert into public.households default values returning id into h;
  insert into public.household_members (household_id, user_id, role) values (h, new.id, 'owner');
  insert into public.user_settings (user_id) values (new.id);
  return new;
end $$;
revoke all on function public.handle_new_user() from public, anon, authenticated;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
