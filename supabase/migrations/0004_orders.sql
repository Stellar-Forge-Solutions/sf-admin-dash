-- COPY for reference. The real file lives in the sf-admin-dash repo: supabase/migrations/0004_orders.sql (that repo owns the shared database).
-- Orders app: tables, per-shop isolation, per-product trial, order -> sales sync (Expense Tracker).
-- Same rules as billing/expense: read own shop; write only while the ORDERS trial/plan is active.

-- 1) Allow the new product everywhere a product is validated.
alter table shops        drop constraint if exists shops_signup_product_check;
alter table shops        add  constraint shops_signup_product_check check (signup_product in ('billing','expenses','orders'));
alter table entitlements drop constraint if exists entitlements_product_check;
alter table entitlements add  constraint entitlements_product_check check (product in ('billing','expenses','orders'));
alter table shops add column if not exists sync_orders_sales boolean not null default false;

create or replace function start_trial(p_shop uuid, p_product text) returns void language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  if p_product not in ('billing','expenses','orders') then raise exception 'unknown product'; end if;
  select email_normalized into v_email from shops where id = p_shop and status = 'approved' for update;
  if v_email is null then raise exception 'shop is not approved'; end if;
  if exists (select 1 from entitlements where shop_id = p_shop and product = p_product) then raise exception 'trial already used'; end if;
  insert into trial_ledger (email_normalized, product) values (v_email, p_product);
  insert into entitlements (shop_id, product, trial_started_at, trial_ends_at) values (p_shop, p_product, now(), now() + interval '15 days');
  insert into audit_log (actor, action, shop_id, detail) values ('system', 'start_trial', p_shop, jsonb_build_object('product', p_product));
end $$;

-- 2) Tables
create table order_settings (
  shop_id uuid primary key default current_shop_id() references shops(id) on delete cascade,
  stages jsonb not null default '[]', category_label text not null default 'Category',
  notify_channel text not null default 'whatsapp' check (notify_channel in ('whatsapp','email','both')),
  fields jsonb not null default '{}', tax jsonb not null default '{}',
  printer_mode text not null default 'thermal' check (printer_mode in ('thermal','normal')),
  order_prefix text not null default 'ORD-', custom_url text, brand_color text, hide_powered boolean not null default false,
  updated_at timestamptz default now());

create table order_products (
  id uuid primary key default gen_random_uuid(), shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  name text not null, category text, unit text, unit_price numeric(12,2) not null default 0 check (unit_price >= 0),
  cgst numeric(6,2), sgst numeric(6,2), igst numeric(6,2), total_price numeric(12,2), created_at timestamptz default now());
create unique index order_products_name_uq on order_products (shop_id, lower(name));

create table orders (
  id uuid primary key default gen_random_uuid(), shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  order_no int, token text not null unique default replace(gen_random_uuid()::text, '-', ''),
  customer_name text not null, customer_whatsapp text, customer_email text,
  stage_key text not null default 'received',
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','partial','paid','refunded')),
  amount_paid numeric(12,2) not null default 0, subtotal numeric(12,2) not null default 0,
  cgst_amt numeric(12,2) not null default 0, sgst_amt numeric(12,2) not null default 0, igst_amt numeric(12,2) not null default 0,
  tax_total numeric(12,2) not null default 0, freight numeric(12,2) not null default 0, total numeric(12,2) not null default 0 check (total >= 0),
  notes text, bill_path text, bill_source text check (bill_source in ('generated','uploaded')), bill_updated_at timestamptz,
  delivered_at timestamptz,                         -- set by trigger: the moment the order reached 'delivered'
  created_by text default (auth.jwt() ->> 'email'), created_at timestamptz default now(), updated_at timestamptz default now());
create index orders_shop_created on orders (shop_id, created_at desc);
create index orders_shop_stage on orders (shop_id, stage_key);
create index orders_shop_delivered on orders (shop_id, delivered_at) where delivered_at is not null;

create table order_items (
  id uuid primary key default gen_random_uuid(), order_id uuid not null references orders(id) on delete cascade,
  shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  product_id uuid references order_products(id) on delete set null,
  name text not null, category text, description text, unit text,
  quantity numeric(12,3) not null default 1 check (quantity > 0), unit_price numeric(12,2) not null default 0 check (unit_price >= 0),
  cgst_pct numeric(6,2) not null default 0, sgst_pct numeric(6,2) not null default 0, igst_pct numeric(6,2) not null default 0,
  tax_amt numeric(12,2) not null default 0, line_total numeric(12,2) not null default 0, created_at timestamptz default now());
create index order_items_order on order_items (order_id);

create table order_events (
  id uuid primary key default gen_random_uuid(), order_id uuid not null references orders(id) on delete cascade,
  shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  stage_key text not null, stage_label text not null, note text, created_at timestamptz default now());
create index order_events_order on order_events (order_id, created_at);

-- Per-shop order number (1, 2, 3 ...) and the delivered timestamp. Neither can be set by the app.
create function orders_before() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext('order_no:' || new.shop_id::text));
    select coalesce(max(order_no), 0) + 1 into new.order_no from orders where shop_id = new.shop_id;
    new.delivered_at := case when new.stage_key = 'delivered' then now() end;
  else
    new.order_no := old.order_no; new.token := old.token; new.shop_id := old.shop_id;
    new.delivered_at := case when new.stage_key = 'delivered' then coalesce(old.delivered_at, now()) end;
  end if;
  return new;
end $$;
create trigger orders_before before insert or update on orders for each row execute function orders_before();

-- 3) Row level security + grants (same pattern as billing)
do $$ declare t text; begin
  foreach t in array array['order_settings','order_products','orders','order_items','order_events'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('create policy %I on %I for select using (shop_id = current_shop_id())', t||'_r', t);
    execute format('create policy %I on %I for insert with check (shop_id = current_shop_id() and shop_can_write(shop_id, ''orders''))', t||'_i', t);
    execute format('create policy %I on %I for update using (shop_id = current_shop_id() and shop_can_write(shop_id, ''orders'')) with check (shop_id = current_shop_id())', t||'_u', t);
    execute format('create policy %I on %I for delete using (shop_id = current_shop_id() and shop_can_write(shop_id, ''orders''))', t||'_d', t);
  end loop;
end $$;
grant select, insert, update, delete on order_settings, order_products, order_items, order_events to authenticated;
grant select, delete on orders to authenticated;
grant insert (shop_id, customer_name, customer_whatsapp, customer_email, stage_key, payment_status, amount_paid, subtotal, cgst_amt, sgst_amt, igst_amt,
              tax_total, freight, total, notes, created_by, updated_at) on orders to authenticated;
grant update (customer_name, customer_whatsapp, customer_email, stage_key, payment_status, amount_paid, subtotal, cgst_amt, sgst_amt, igst_amt,
              tax_total, freight, total, notes, bill_path, bill_source, bill_updated_at, updated_at) on orders to authenticated;

-- Items and history can only be attached to an order of your own shop.
drop policy order_items_i on order_items; drop policy order_events_i on order_events;
create policy order_items_i on order_items for insert with check (shop_id = current_shop_id() and shop_can_write(shop_id, 'orders')
  and exists (select 1 from orders o where o.id = order_id and o.shop_id = current_shop_id()));
create policy order_events_i on order_events for insert with check (shop_id = current_shop_id() and shop_can_write(shop_id, 'orders')
  and exists (select 1 from orders o where o.id = order_id and o.shop_id = current_shop_id()));

-- Home page totals (security invoker: only the caller's shop is visible).
create function orders_summary(p_from timestamptz, p_to timestamptz) returns table (stage_key text, n bigint, total numeric, paid numeric)
language sql stable as $$
  select stage_key, count(*), coalesce(sum(total), 0), coalesce(sum(amount_paid), 0) from orders
  where shop_id = current_shop_id() and (p_from is null or created_at >= p_from) and (p_to is null or created_at < p_to) group by stage_key $$;
revoke execute on function orders_summary(timestamptz, timestamptz) from public, anon; grant execute on function orders_summary(timestamptz, timestamptz) to authenticated;

-- 4) Storage: bills are private (customers get them through the app's signed link); logos upload also works for Orders shops.
insert into storage.buckets (id, name, public) values ('order-bills', 'order-bills', false) on conflict (id) do nothing;
create policy "order-bills read own" on storage.objects for select to authenticated
  using (bucket_id = 'order-bills' and (storage.foldername(name))[1] = current_shop_id()::text);
create policy "order-bills write own" on storage.objects for insert to authenticated
  with check (bucket_id = 'order-bills' and (storage.foldername(name))[1] = current_shop_id()::text and shop_can_write(current_shop_id(), 'orders'));
create policy "order-bills delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'order-bills' and (storage.foldername(name))[1] = current_shop_id()::text and shop_can_write(current_shop_id(), 'orders'));
create policy "logos write orders folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'logos' and (storage.foldername(name))[1] = current_shop_id()::text and shop_can_write(current_shop_id(), 'orders'));

-- 5) Orders -> Expense Tracker sales. One auto-managed sale row per shop per day = that day's DELIVERED orders (value incl. tax and freight).
--    An order that leaves 'delivered' (e.g. returned) drops out of the day's sale. Only runs when the shop switched it on and Expense is active.
create unique index uq_transactions_orders_day on transactions (shop_id, txn_date) where source = 'orders';
drop policy tx_nobilling_i on transactions; drop policy tx_nobilling_u on transactions; drop policy tx_nobilling_d on transactions;
create policy tx_nobilling_i on transactions as restrictive for insert with check (source not in ('billing','orders'));
create policy tx_nobilling_u on transactions as restrictive for update using (source not in ('billing','orders')) with check (source not in ('billing','orders'));
create policy tx_nobilling_d on transactions as restrictive for delete using (source not in ('billing','orders'));

create function sync_orders_sales(p_shop uuid, p_day date) returns void language plpgsql security definer set search_path = public as $$
declare v_total numeric(12,2); v_count int;
begin
  if p_day is null then return; end if;
  if not exists (select 1 from shops where id = p_shop and sync_orders_sales) or not shop_can_write(p_shop, 'expenses') then return; end if;
  perform pg_advisory_xact_lock(hashtext('orders_sales:' || p_shop::text || p_day::text));
  select coalesce(sum(total), 0), count(*) into v_total, v_count from orders
    where shop_id = p_shop and stage_key = 'delivered' and (delivered_at at time zone 'Asia/Kolkata')::date = p_day;
  if v_count = 0 then delete from transactions where shop_id = p_shop and source = 'orders' and txn_date = p_day;
  else
    insert into transactions (shop_id, type, amount, category, description, txn_date, source, created_by)
    values (p_shop, 'sale', v_total, 'Orders', v_count || case when v_count = 1 then ' delivered order' else ' delivered orders' end || ' from orders app', p_day, 'orders', 'orders-app')
    on conflict (shop_id, txn_date) where source = 'orders' do update set amount = excluded.amount, description = excluded.description;
  end if;
end $$;

create function trg_orders_sync_sales() returns trigger language plpgsql security definer set search_path = public as $$
declare v_old date; v_new date;
begin
  if tg_op in ('UPDATE','DELETE') and old.delivered_at is not null then
    v_old := (old.delivered_at at time zone 'Asia/Kolkata')::date; perform sync_orders_sales(old.shop_id, v_old);
  end if;
  if tg_op in ('INSERT','UPDATE') and new.delivered_at is not null then
    v_new := (new.delivered_at at time zone 'Asia/Kolkata')::date;
    if v_new is distinct from v_old then perform sync_orders_sales(new.shop_id, v_new); end if;
  end if;
  return null;
end $$;
create trigger orders_sync_sales after insert or delete or update on orders for each row execute function trg_orders_sync_sales();

create function set_orders_sales_sync(p_on boolean) returns void language plpgsql security definer set search_path = public as $$
declare v_shop uuid := current_shop_id(); d date;
begin
  if v_shop is null then raise exception 'no shop'; end if;
  if p_on then
    if not shop_can_write(v_shop, 'expenses') then raise exception 'Expense Tracker is not active'; end if;
    if not exists (select 1 from entitlements where shop_id = v_shop and product = 'orders') then raise exception 'Orders is not enabled for this shop'; end if;
    update shops set sync_orders_sales = true where id = v_shop;
    for d in select distinct (delivered_at at time zone 'Asia/Kolkata')::date from orders where shop_id = v_shop and stage_key = 'delivered' and delivered_at is not null
    loop perform sync_orders_sales(v_shop, d); end loop;
  else
    update shops set sync_orders_sales = false where id = v_shop;
    delete from transactions where shop_id = v_shop and source = 'orders';
  end if;
end $$;
revoke execute on function set_orders_sales_sync(boolean) from public, anon; grant execute on function set_orders_sales_sync(boolean) to authenticated;
revoke execute on function sync_orders_sales(uuid, date), trg_orders_sync_sales() from public, anon, authenticated;
