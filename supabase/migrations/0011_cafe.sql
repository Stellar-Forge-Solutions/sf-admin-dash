-- ==============================================================================
-- 0011_cafe.sql  ·  Stellar Forge Cafe (QR ordering + billing for restaurants)
--
-- Runs on the SHARED Stellar Forge database (the one owned by sf-admin-dash).
--   * NO new shop/cafe table: shops.id IS the cafe id. Owner = shops.owner_id,
--     staff = shop_staff (max 2, from 0007_staff.sql). current_shop_id() is reused.
--   * All new tables are prefixed cafe_ so nothing clashes with the existing
--     billing (bills/items) and orders (orders/order_*) products.
--   * Needs: 0001_core.sql and 0007_staff.sql already applied.
--   * Safe to re-run (idempotent).
-- ==============================================================================

-- 0) Plan columns the app relies on (already present on most deployments)
alter table shops
  add column if not exists plan text not null default 'free',
  add column if not exists plan_renewal_date timestamptz,
  add column if not exists custom_order_limit integer,              -- Custom plan: NULL = unlimited
  add column if not exists overage_limit_rupees numeric not null default 300;
grant update (overage_limit_rupees) on shops to authenticated;

-- 1) Helpers --------------------------------------------------------------
create or replace function cafe_is_owner(p_shop uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from shops where id = p_shop and owner_id = auth.uid() and deleted_at is null) $$;

-- Writes are allowed for approved shops. Plan limits are enforced by cafe_usage_check().
create or replace function cafe_can_write(p_shop uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from shops where id = p_shop and status = 'approved' and deleted_at is null) $$;

-- 2) Tables ---------------------------------------------------------------
create table if not exists cafe_settings (
  shop_id uuid primary key default current_shop_id() references shops(id) on delete cascade,
  tax_enabled boolean not null default false,
  cgst_pct numeric(5,2) not null default 2.5 check (cgst_pct >= 0 and cgst_pct <= 50),
  sgst_pct numeric(5,2) not null default 2.5 check (sgst_pct >= 0 and sgst_pct <= 50),
  round_off boolean not null default false,
  next_bill_no bigint not null default 1,
  updated_at timestamptz default now()
);

create table if not exists cafe_categories (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  name text not null, sort int not null default 0, created_at timestamptz default now()
);
create unique index if not exists cafe_categories_name on cafe_categories (shop_id, lower(name));

create table if not exists cafe_items (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  category_id uuid not null references cafe_categories(id) on delete cascade,
  name text not null, price numeric(10,2) not null check (price >= 0),
  image_path text, is_active boolean not null default true, created_at timestamptz default now()
);
create unique index if not exists cafe_items_name on cafe_items (shop_id, category_id, lower(name));

create table if not exists cafe_tables (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  name text not null,
  -- Unguessable per-table secret used in the QR link (/m/<token>). Never client-writable.
  token text not null unique default encode(gen_random_bytes(18), 'hex'),
  created_at timestamptz default now()
);
create unique index if not exists cafe_tables_name on cafe_tables (shop_id, lower(name));

create table if not exists cafe_bills (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  table_id uuid references cafe_tables(id) on delete set null,
  table_name text not null,
  bill_no bigint,
  status text not null default 'open' check (status in ('open','final','cancelled')),
  source text not null default 'staff' check (source in ('staff','customer')),   -- who initialised the bill
  customer_name text, customer_phone text,
  subtotal numeric(12,2) not null default 0, discount_amount numeric(12,2) not null default 0,
  tax_enabled boolean not null default false,
  cgst_pct numeric(5,2) not null default 0, sgst_pct numeric(5,2) not null default 0,
  cgst_amt numeric(12,2) not null default 0, sgst_amt numeric(12,2) not null default 0,
  round_off numeric(6,2) not null default 0,
  total numeric(12,2) not null default 0,
  payment_mode text check (payment_mode in ('cash','upi','card','other')),
  created_by text, finalized_by text,
  snapshot jsonb, cancel_reason text, cancelled_at timestamptz,
  created_at timestamptz not null default now(), finalized_at timestamptz,
  unique (shop_id, bill_no)
);
create unique index if not exists cafe_one_open_bill_per_table on cafe_bills (table_id) where status = 'open';
create index if not exists cafe_bills_shop_created on cafe_bills (shop_id, created_at desc);
create index if not exists cafe_bills_shop_final on cafe_bills (shop_id, finalized_at) where status = 'final';

create table if not exists cafe_bill_items (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null references cafe_bills(id) on delete cascade,
  shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  item_id uuid references cafe_items(id) on delete set null,
  name text not null, category_name text,
  price numeric(10,2) not null check (price >= 0), qty int not null check (qty between 1 and 99),
  source text not null default 'staff' check (source in ('staff','customer')),
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (bill_id, item_id)
);
create index if not exists cafe_bill_items_bill on cafe_bill_items (bill_id);

-- 3) Visibility helper: owners see everything; staff see open bills + the last 2 days ----
create or replace function cafe_bill_visible(p_bill uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from cafe_bills b where b.id = p_bill and b.shop_id = current_shop_id()
    and (cafe_is_owner(b.shop_id) or b.status = 'open' or b.created_at > now() - interval '2 days')) $$;

-- 4) RLS + grants ---------------------------------------------------------
alter table cafe_settings enable row level security;   alter table cafe_categories enable row level security;
alter table cafe_items enable row level security;      alter table cafe_tables enable row level security;
alter table cafe_bills enable row level security;      alter table cafe_bill_items enable row level security;
revoke all on cafe_settings, cafe_categories, cafe_items, cafe_tables, cafe_bills, cafe_bill_items from anon, authenticated;

-- Menu, tables and settings: everyone in the shop reads, only the OWNER writes.
do $$ declare t text; begin
  foreach t in array array['cafe_settings','cafe_categories','cafe_items','cafe_tables'] loop
    execute format('drop policy if exists %I on %I', t||'_r', t);
    execute format('drop policy if exists %I on %I', t||'_i', t);
    execute format('drop policy if exists %I on %I', t||'_u', t);
    execute format('drop policy if exists %I on %I', t||'_d', t);
    execute format('create policy %I on %I for select using (shop_id = current_shop_id())', t||'_r', t);
    execute format('create policy %I on %I for insert with check (shop_id = current_shop_id() and cafe_is_owner(shop_id) and cafe_can_write(shop_id))', t||'_i', t);
    execute format('create policy %I on %I for update using (shop_id = current_shop_id() and cafe_is_owner(shop_id) and cafe_can_write(shop_id)) with check (shop_id = current_shop_id())', t||'_u', t);
    execute format('create policy %I on %I for delete using (shop_id = current_shop_id() and cafe_is_owner(shop_id) and cafe_can_write(shop_id))', t||'_d', t);
  end loop;
end $$;
grant select on cafe_settings, cafe_categories, cafe_items, cafe_tables to authenticated;
grant insert (shop_id, tax_enabled, cgst_pct, sgst_pct, round_off, updated_at), update (tax_enabled, cgst_pct, sgst_pct, round_off, updated_at) on cafe_settings to authenticated;
grant insert (name, sort), update (name, sort) on cafe_categories to authenticated;
grant delete on cafe_categories to authenticated;
grant insert (category_id, name, price, image_path, is_active), update (category_id, name, price, image_path, is_active) on cafe_items to authenticated;
grant delete on cafe_items to authenticated;
grant insert (name), update (name) on cafe_tables to authenticated;   -- token is NOT writable
grant delete on cafe_tables to authenticated;

-- Bills: read-only for clients. All writes go through the SECURITY DEFINER functions below.
drop policy if exists cafe_bills_r on cafe_bills;
create policy cafe_bills_r on cafe_bills for select
  using (shop_id = current_shop_id() and (cafe_is_owner(shop_id) or status = 'open' or created_at > now() - interval '2 days'));
drop policy if exists cafe_bill_items_r on cafe_bill_items;
create policy cafe_bill_items_r on cafe_bill_items for select using (shop_id = current_shop_id() and cafe_bill_visible(bill_id));
grant select on cafe_bills, cafe_bill_items to authenticated;

-- 5) Plan limit: Free 300 / Basic 600 orders a month, then Rs.1 per extra order, up to the shop's cap.
--    An "order" = a bill being initialised (by staff OR by a customer from the QR), counted by created_at (IST month).
create or replace function cafe_usage_check(p_shop uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s shops; eff text; lim int; cap numeric; n int; m_start timestamptz;
begin
  select * into s from shops where id = p_shop;
  eff := coalesce(s.plan, 'free');
  if eff = 'basic' and s.plan_renewal_date is not null and s.plan_renewal_date < now() then eff := 'free'; end if;
  if eff = 'pro' then
    if s.custom_order_limit is null then return; end if;
    lim := s.custom_order_limit;
  elsif eff = 'basic' then lim := 600; else lim := 300; end if;
  m_start := date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  select count(*) into n from cafe_bills where shop_id = p_shop and created_at >= m_start;
  cap := coalesce(s.overage_limit_rupees, 300);             -- Rs.1 per extra order => cap rupees = cap extra orders
  if n >= lim and (cap <= 0 or n >= lim + cap) then raise exception 'ORDER_LIMIT_REACHED'; end if;
end $$;

-- 6) Staff / owner functions ------------------------------------------------
create or replace function cafe_open_bill(p_table uuid) returns cafe_bills
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := current_shop_id(); t cafe_tables; b cafe_bills;
begin
  if v_shop is null or not cafe_can_write(v_shop) then raise exception 'not allowed'; end if;
  select * into t from cafe_tables where id = p_table and shop_id = v_shop;
  if t.id is null then raise exception 'table not found'; end if;
  perform pg_advisory_xact_lock(hashtext('cafe_open:' || t.id::text));
  select * into b from cafe_bills where table_id = t.id and status = 'open';
  if b.id is not null then return b; end if;
  perform cafe_usage_check(v_shop);
  insert into cafe_bills (shop_id, table_id, table_name, source, created_by)
    values (v_shop, t.id, t.name, 'staff', auth.jwt() ->> 'email') returning * into b;
  return b;
end $$;

create or replace function cafe_set_qty(p_bill uuid, p_item uuid, p_qty int) returns void
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := current_shop_id(); b cafe_bills; it record; q int := least(coalesce(p_qty, 0), 99);
begin
  if v_shop is null or not cafe_can_write(v_shop) then raise exception 'not allowed'; end if;
  select * into b from cafe_bills where id = p_bill and shop_id = v_shop and status = 'open' for update;
  if b.id is null then raise exception 'bill is not open'; end if;
  if q <= 0 then delete from cafe_bill_items where bill_id = p_bill and item_id = p_item; return; end if;
  select i.id, i.name, i.price, c.name as cname into it
    from cafe_items i join cafe_categories c on c.id = i.category_id
    where i.id = p_item and i.shop_id = v_shop and i.is_active;
  if it.id is null then raise exception 'item not available'; end if;
  insert into cafe_bill_items (bill_id, shop_id, item_id, name, category_name, price, qty, source)
    values (p_bill, v_shop, it.id, it.name, it.cname, it.price, q, 'staff')
    on conflict (bill_id, item_id) do update set qty = excluded.qty, updated_at = now();
end $$;

-- Final bill: totals, tax, round-off and number are computed HERE, never trusted from the browser.
create or replace function cafe_finalize_bill(p_bill uuid, p_discount numeric, p_customer text, p_phone text, p_mode text)
returns cafe_bills language plpgsql security definer set search_path = public as $$
declare v_shop uuid := current_shop_id(); b cafe_bills; s shops; cs cafe_settings;
  sub numeric; disc numeric; taxable numeric; cg numeric := 0; sg numeric := 0; tot numeric; ro numeric := 0; n bigint;
begin
  if v_shop is null or not cafe_can_write(v_shop) then raise exception 'not allowed'; end if;
  select * into b from cafe_bills where id = p_bill and shop_id = v_shop for update;
  if b.id is null then raise exception 'bill not found'; end if;
  if b.status <> 'open' then raise exception 'bill is already closed'; end if;
  select coalesce(sum(price * qty), 0) into sub from cafe_bill_items where bill_id = p_bill;
  if sub <= 0 then raise exception 'bill is empty'; end if;
  disc := least(greatest(coalesce(p_discount, 0), 0), sub);
  taxable := sub - disc;
  select * into cs from cafe_settings where shop_id = v_shop;
  if coalesce(cs.tax_enabled, false) then
    cg := round(taxable * cs.cgst_pct / 100, 2);  sg := round(taxable * cs.sgst_pct / 100, 2);
  end if;
  tot := taxable + cg + sg;
  if coalesce(cs.round_off, false) then ro := round(tot) - tot; tot := round(tot); end if;
  insert into cafe_settings (shop_id, next_bill_no) values (v_shop, 2)
    on conflict (shop_id) do update set next_bill_no = cafe_settings.next_bill_no + 1
    returning next_bill_no - 1 into n;
  select * into s from shops where id = v_shop;
  update cafe_bills set
    status = 'final', bill_no = n, subtotal = sub, discount_amount = disc,
    tax_enabled = coalesce(cs.tax_enabled, false),
    cgst_pct = case when coalesce(cs.tax_enabled, false) then cs.cgst_pct else 0 end,
    sgst_pct = case when coalesce(cs.tax_enabled, false) then cs.sgst_pct else 0 end,
    cgst_amt = cg, sgst_amt = sg, round_off = ro, total = tot,
    customer_name = nullif(left(trim(coalesce(p_customer, '')), 60), ''),
    customer_phone = nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), ''),
    payment_mode = case when p_mode in ('cash','upi','card','other') then p_mode else 'cash' end,
    finalized_at = now(), finalized_by = auth.jwt() ->> 'email',
    snapshot = jsonb_build_object('name', s.name, 'tagline', s.tagline, 'address', s.address, 'mobile', s.mobile,
      'gst_no', s.gst_no, 'website', s.website, 'thank_you', s.thank_you, 'bill_prefix', s.bill_prefix,
      'logo_path', s.logo_path, 'upi_id', s.upi_id, 'show_upi_qr', s.show_upi_qr and s.upi_id is not null)
  where id = p_bill returning * into b;
  return b;
end $$;

-- Open bills can be cancelled by anyone in the shop; printed bills only by the owner.
create or replace function cafe_cancel_bill(p_bill uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := current_shop_id(); b cafe_bills;
begin
  if v_shop is null or not cafe_can_write(v_shop) then raise exception 'not allowed'; end if;
  select * into b from cafe_bills where id = p_bill and shop_id = v_shop for update;
  if b.id is null or b.status = 'cancelled' then raise exception 'cannot cancel'; end if;
  if b.status = 'final' and not cafe_is_owner(v_shop) then raise exception 'only the owner can cancel a printed bill'; end if;
  update cafe_bills set status = 'cancelled', cancelled_at = now(), cancel_reason = nullif(left(trim(coalesce(p_reason, '')), 200), '') where id = p_bill;
end $$;

-- New secret QR link for a table (e.g. if a printed QR leaked). Old QR stops working at once.
create or replace function cafe_rotate_table_token(p_table uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := current_shop_id(); tok text := encode(gen_random_bytes(18), 'hex');
begin
  if v_shop is null or not cafe_is_owner(v_shop) then raise exception 'owner only'; end if;
  update cafe_tables set token = tok where id = p_table and shop_id = v_shop;
  if not found then raise exception 'table not found'; end if;
  return tok;
end $$;


-- Exact orders-this-month for the usage meter (works for owner AND staff, who can only SELECT recent bills).
create or replace function cafe_month_orders() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from cafe_bills
  where shop_id = current_shop_id()
    and created_at >= date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata' $$;

-- 7) Owner analytics (finalised bills only, IST dates) ---------------------------
create or replace function cafe_analytics(p_from date, p_to date, p_group text default 'day') returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_shop uuid := current_shop_id(); res jsonb;
begin
  if v_shop is null or not cafe_is_owner(v_shop) then raise exception 'owner only'; end if;
  with b as (
    select *, (finalized_at at time zone 'Asia/Kolkata')::date as d from cafe_bills
    where shop_id = v_shop and status = 'final'
      and (finalized_at at time zone 'Asia/Kolkata')::date between p_from and p_to
  ), k as (
    select b.*, case p_group
      when 'month' then to_char(d, 'YYYY-MM')
      when 'year'  then to_char(d, 'YYYY')
      when 'fy'    then 'FY ' || (case when extract(month from d) >= 4 then extract(year from d)::int else extract(year from d)::int - 1 end)
                         || '-' || lpad((((case when extract(month from d) >= 4 then extract(year from d)::int else extract(year from d)::int - 1 end) + 1) % 100)::text, 2, '0')
      else to_char(d, 'YYYY-MM-DD') end as gk from b
  )
  select jsonb_build_object(
    'totals', (select jsonb_build_object('orders', count(*), 'subtotal', coalesce(sum(subtotal), 0), 'discount', coalesce(sum(discount_amount), 0),
                 'cgst', coalesce(sum(cgst_amt), 0), 'sgst', coalesce(sum(sgst_amt), 0), 'total', coalesce(sum(total), 0),
                 'avg', coalesce(round(avg(total), 2), 0)) from b),
    'cancelled', (select count(*) from cafe_bills where shop_id = v_shop and status = 'cancelled'
                  and (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to),
    'series', (select coalesce(jsonb_agg(jsonb_build_object('k', gk, 'orders', o, 'total', t) order by gk), '[]'::jsonb)
               from (select gk, count(*) o, sum(total) t from k group by gk) x),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'category', cat, 'qty', q, 'amount', a) order by a desc), '[]'::jsonb)
              from (select bi.name, coalesce(bi.category_name, 'Uncategorised') cat, sum(bi.qty) q, sum(bi.qty * bi.price) a
                    from cafe_bill_items bi join b on b.id = bi.bill_id group by bi.name, coalesce(bi.category_name, 'Uncategorised') order by sum(bi.qty * bi.price) desc limit 500) y),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('category', cat, 'qty', q, 'amount', a) order by a desc), '[]'::jsonb)
              from (select coalesce(bi.category_name, 'Uncategorised') cat, sum(bi.qty) q, sum(bi.qty * bi.price) a
                    from cafe_bill_items bi join b on b.id = bi.bill_id group by 1) z),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('mode', coalesce(payment_mode, 'cash'), 'orders', o, 'total', t)), '[]'::jsonb)
              from (select payment_mode, count(*) o, sum(total) t from b group by payment_mode) p),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('who', who, 'orders', o, 'total', t) order by t desc), '[]'::jsonb)
              from (select coalesce(split_part(finalized_by, '@', 1), '-') who, count(*) o, sum(total) t from b group by 1) s)
  ) into res;
  return res;
end $$;

-- 8) PUBLIC (QR) functions: called ONLY by the Cloudflare Functions with the service key ---
--    The customer page never talks to the database directly. The secret table token decides
--    which table a request belongs to, so changing /m/<token> to anything else finds nothing.
create or replace function cafe_public_bill_lines(p_bill uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'qty', qty, 'price', price) order by created_at), '[]'::jsonb)
  from cafe_bill_items where bill_id = p_bill $$;

create or replace function cafe_public_menu(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t cafe_tables; s shops; cs cafe_settings; b cafe_bills; cats jsonb;
begin
  if p_token is null or length(p_token) < 20 then return null; end if;
  select * into t from cafe_tables where token = p_token;
  if t.id is null then return null; end if;
  select * into s from shops where id = t.shop_id and status = 'approved' and deleted_at is null;
  if s.id is null then return null; end if;
  select * into cs from cafe_settings where shop_id = t.shop_id;
  select * into b from cafe_bills where table_id = t.id and status = 'open';
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items',
      (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'price', i.price, 'image', i.image_path) order by i.name), '[]'::jsonb)
         from cafe_items i where i.category_id = c.id and i.is_active)) order by c.sort, c.name), '[]'::jsonb)
    into cats from cafe_categories c
    where c.shop_id = t.shop_id and exists (select 1 from cafe_items i where i.category_id = c.id and i.is_active);
  return jsonb_build_object(
    'shop', jsonb_build_object('name', s.name, 'tagline', s.tagline, 'thank_you', s.thank_you, 'logo', s.logo_path),
    'table', t.name,
    'tax', jsonb_build_object('enabled', coalesce(cs.tax_enabled, false), 'cgst', coalesce(cs.cgst_pct, 0), 'sgst', coalesce(cs.sgst_pct, 0)),
    'categories', cats,
    'lines', case when b.id is null then '[]'::jsonb else cafe_public_bill_lines(b.id) end);
end $$;

create or replace function cafe_public_order(p_token text, p_lines jsonb, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t cafe_tables; s shops; b cafe_bills; ln jsonb; it record; q int; tq int;
begin
  if p_token is null or length(p_token) < 20 then raise exception 'INVALID_TABLE'; end if;
  select * into t from cafe_tables where token = p_token;
  if t.id is null then raise exception 'INVALID_TABLE'; end if;
  select * into s from shops where id = t.shop_id and status = 'approved' and deleted_at is null;
  if s.id is null then raise exception 'CLOSED'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 or jsonb_array_length(p_lines) > 30 then
    raise exception 'BAD_ORDER'; end if;

  perform pg_advisory_xact_lock(hashtext('cafe_open:' || t.id::text));
  select * into b from cafe_bills where table_id = t.id and status = 'open';
  if b.id is null then
    perform cafe_usage_check(t.shop_id);                                   -- counts as one order for the monthly meter
    insert into cafe_bills (shop_id, table_id, table_name, source, created_by, customer_name)
      values (t.shop_id, t.id, t.name, 'customer', 'customer', nullif(left(trim(coalesce(p_name, '')), 40), ''))
      returning * into b;
  elsif exists (select 1 from cafe_bill_items where bill_id = b.id and source = 'customer' and updated_at > now() - interval '2 seconds') then
    raise exception 'SLOW_DOWN';
  end if;

  for ln in select value from jsonb_array_elements(p_lines) loop
    q := least(greatest(coalesce((ln ->> 'qty')::int, 0), 0), 20);
    continue when q = 0;
    select i.id, i.name, i.price, c.name as cname into it
      from cafe_items i join cafe_categories c on c.id = i.category_id
      where i.id = (ln ->> 'item_id')::uuid and i.shop_id = t.shop_id and i.is_active;   -- price ALWAYS read from the DB
    if it.id is null then raise exception 'ITEM_UNAVAILABLE'; end if;
    insert into cafe_bill_items (bill_id, shop_id, item_id, name, category_name, price, qty, source)
      values (b.id, t.shop_id, it.id, it.name, it.cname, it.price, q, 'customer')
      on conflict (bill_id, item_id) do update set qty = least(cafe_bill_items.qty + excluded.qty, 99), updated_at = now();
  end loop;

  select coalesce(sum(qty), 0) into tq from cafe_bill_items where bill_id = b.id;
  if tq > 200 then raise exception 'TOO_MANY_ITEMS'; end if;
  return jsonb_build_object('lines', cafe_public_bill_lines(b.id));
end $$;

-- 9) Lock down function execution ---------------------------------------------
revoke execute on function cafe_public_menu(text), cafe_public_order(text, jsonb, text), cafe_public_bill_lines(uuid) from public, anon, authenticated;
grant  execute on function cafe_public_menu(text), cafe_public_order(text, jsonb, text), cafe_public_bill_lines(uuid) to service_role;
revoke execute on function cafe_usage_check(uuid) from public, anon, authenticated;
revoke execute on function cafe_open_bill(uuid), cafe_set_qty(uuid, uuid, int), cafe_finalize_bill(uuid, numeric, text, text, text),
  cafe_cancel_bill(uuid, text), cafe_rotate_table_token(uuid), cafe_analytics(date, date, text), cafe_month_orders() from public, anon;
grant  execute on function cafe_open_bill(uuid), cafe_set_qty(uuid, uuid, int), cafe_finalize_bill(uuid, numeric, text, text, text),
  cafe_cancel_bill(uuid, text), cafe_rotate_table_token(uuid), cafe_analytics(date, date, text), cafe_month_orders() to authenticated;
grant  execute on function cafe_is_owner(uuid), cafe_can_write(uuid), cafe_bill_visible(uuid) to authenticated;

-- 10) Storage ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('cafe-menu', 'cafe-menu', true), ('cafe-bills', 'cafe-bills', true) on conflict (id) do nothing;
drop policy if exists "cafe-menu insert" on storage.objects;  drop policy if exists "cafe-menu delete" on storage.objects;
drop policy if exists "cafe-bills insert" on storage.objects; drop policy if exists "logos insert cafe" on storage.objects;
create policy "cafe-menu insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'cafe-menu' and (storage.foldername(name))[1] = current_shop_id()::text and cafe_is_owner(current_shop_id()) and cafe_can_write(current_shop_id()));
create policy "cafe-menu delete" on storage.objects for delete to authenticated
  using (bucket_id = 'cafe-menu' and (storage.foldername(name))[1] = current_shop_id()::text and cafe_is_owner(current_shop_id()));
create policy "cafe-bills insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'cafe-bills' and (storage.foldername(name))[1] = current_shop_id()::text and cafe_can_write(current_shop_id()));
create policy "logos insert cafe" on storage.objects for insert to authenticated
  with check (bucket_id = 'logos' and (storage.foldername(name))[1] = current_shop_id()::text and cafe_is_owner(current_shop_id()) and cafe_can_write(current_shop_id()));

-- 11) Realtime: staff see QR orders land on the table's bill instantly ----------------
do $$ begin alter publication supabase_realtime add table cafe_bills;      exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table cafe_bill_items; exception when duplicate_object then null; end $$;
