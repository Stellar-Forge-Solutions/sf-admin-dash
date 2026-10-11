-- Expense Tracker tables, per-shop isolation, billing->sales sync, per-product trials.
alter table shops add column if not exists signup_product text not null default 'billing' check (signup_product in ('billing','expenses')),
                  add column if not exists sync_sales boolean not null default false;

create type txn_type as enum ('sale', 'purchase', 'expense');

create table transactions (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  type txn_type not null, amount numeric(12,2) not null check (amount >= 0),
  category text, description text, txn_date date not null default current_date,
  source text not null default 'web', created_by text, created_at timestamptz not null default now());
create index idx_transactions_shop on transactions (shop_id, type, txn_date);
create unique index uq_transactions_billing_day on transactions (shop_id, txn_date) where source = 'billing';

create table staff (id uuid primary key default gen_random_uuid(), shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  name text not null, active boolean not null default true, created_at timestamptz not null default now());
create table attendance (id uuid primary key default gen_random_uuid(), shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  staff_id uuid not null references staff(id) on delete cascade, date date not null,
  status text not null default 'present' check (status in ('present','absent')), created_at timestamptz not null default now(), unique (staff_id, date));
create table lending (id uuid primary key default gen_random_uuid(), shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  person_name text not null, whatsapp_number text, amount numeric(12,2) not null check (amount > 0), paid_amount numeric(12,2) default 0,
  type text not null check (type in ('lend','settle')), date date not null default current_date, created_by text, created_at timestamptz not null default now());
create table sale_vendors (id uuid primary key default gen_random_uuid(), shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  vendor_name text not null, whatsapp_number text, description text, bill_no text, amount numeric(12,2) not null check (amount >= 0),
  paid_amount numeric(12,2) default 0, status text not null default 'unpaid' check (status in ('paid','unpaid','partial')),
  date date not null default current_date, created_by text, created_at timestamptz not null default now());
create table purchase_vendors (like sale_vendors including defaults including constraints);
alter table purchase_vendors add primary key (id);
alter table purchase_vendors add foreign key (shop_id) references shops(id) on delete cascade;
create index on staff (shop_id); create index on attendance (shop_id, date); create index on lending (shop_id, person_name);
create index on sale_vendors (shop_id, vendor_name); create index on purchase_vendors (shop_id, vendor_name);

-- Same rule for all six tables: read own shop; write only while the Expense trial/plan is active.
do $$ declare t text; begin
  foreach t in array array['transactions','staff','attendance','lending','sale_vendors','purchase_vendors'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon', t);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
    execute format('create policy %I on %I for select using (shop_id = current_shop_id())', t||'_r', t);
    execute format('create policy %I on %I for insert with check (shop_id = current_shop_id() and shop_can_write(shop_id, ''expenses''))', t||'_i', t);
    execute format('create policy %I on %I for update using (shop_id = current_shop_id() and shop_can_write(shop_id, ''expenses'')) with check (shop_id = current_shop_id())', t||'_u', t);
    execute format('create policy %I on %I for delete using (shop_id = current_shop_id() and shop_can_write(shop_id, ''expenses''))', t||'_d', t);
  end loop;
end $$;
-- Rows created by the billing sync cannot be forged, edited or deleted by users.
create policy tx_nobilling_i on transactions as restrictive for insert with check (source <> 'billing');
create policy tx_nobilling_u on transactions as restrictive for update using (source <> 'billing') with check (source <> 'billing');
create policy tx_nobilling_d on transactions as restrictive for delete using (source <> 'billing');

create function fin_year(d date) returns text language sql immutable as $$
  select case when extract(month from d) >= 4 then extract(year from d)::text || '-' || (extract(year from d)::int + 1)::text
  else (extract(year from d)::int - 1)::text || '-' || extract(year from d)::text end $$;

-- security_invoker: views obey the caller's row-level security, so one shop can never sum another shop's data.
create view v_monthly_summary with (security_invoker = true) as
select date_trunc('month', date)::date as period, type, sum(amount) as total, count(*) as txn_count from (
  select txn_date as date, 'sale' as type, amount from transactions where type = 'sale'
  union all select date::date, 'purchase', amount from purchase_vendors
  union all select txn_date, 'expense', amount from transactions where type = 'expense') c group by period, type;
create view v_yearly_summary with (security_invoker = true) as
select date_trunc('year', date)::date as period, type, sum(amount) as total, count(*) as txn_count from (
  select txn_date as date, 'sale' as type, amount from transactions where type = 'sale'
  union all select date::date, 'purchase', amount from purchase_vendors
  union all select txn_date, 'expense', amount from transactions where type = 'expense') c group by period, type;
create view v_fy_summary with (security_invoker = true) as
select fin_year(date) as fin_year, type, sum(amount) as total, count(*) as txn_count from (
  select txn_date as date, 'sale' as type, amount from transactions where type = 'sale'
  union all select date::date, 'purchase', amount from purchase_vendors
  union all select txn_date, 'expense', amount from transactions where type = 'expense') c group by fin_year, type;
create view v_today_summary with (security_invoker = true) as
select type, sum(amount) as total, count(*) as txn_count from transactions where txn_date = current_date group by 1;
revoke all on v_monthly_summary, v_yearly_summary, v_fy_summary, v_today_summary from anon;
grant select on v_monthly_summary, v_yearly_summary, v_fy_summary, v_today_summary to authenticated;

-- One auto-managed sale row per shop per day = that day's printed bills. Only runs when the shop switched sync on
-- and its Expense Tracker trial/plan is active.
create function sync_billing_sales(p_shop uuid, p_day date) returns void language plpgsql security definer set search_path = public as $$
declare v_total numeric(12,2); v_count int;
begin
  if p_day is null then return; end if;
  if not exists (select 1 from shops where id = p_shop and sync_sales) or not shop_can_write(p_shop, 'expenses') then return; end if;
  perform pg_advisory_xact_lock(hashtext('billing_sales:' || p_shop::text || p_day::text));
  select coalesce(sum(total_amount), 0), count(*) into v_total, v_count from bills
    where shop_id = p_shop and status = 'final' and coalesce(billing_date::date, (created_at at time zone 'Asia/Kolkata')::date) = p_day;
  if v_count = 0 then delete from transactions where shop_id = p_shop and source = 'billing' and txn_date = p_day;
  else
    insert into transactions (shop_id, type, amount, category, description, txn_date, source, created_by)
    values (p_shop, 'sale', v_total, 'Billing', v_count || case when v_count = 1 then ' bill' else ' bills' end || ' from billing app', p_day, 'billing', 'billing-app')
    on conflict (shop_id, txn_date) where source = 'billing' do update set amount = excluded.amount, description = excluded.description;
  end if;
end $$;

create function trg_bills_sync_sales() returns trigger language plpgsql security definer set search_path = public as $$
declare v_old date; v_new date;
begin
  if tg_op in ('UPDATE','DELETE') then
    v_old := coalesce(old.billing_date::date, (old.created_at at time zone 'Asia/Kolkata')::date); perform sync_billing_sales(old.shop_id, v_old);
  end if;
  if tg_op in ('INSERT','UPDATE') then
    v_new := coalesce(new.billing_date::date, (new.created_at at time zone 'Asia/Kolkata')::date);
    if tg_op = 'INSERT' or v_new is distinct from v_old then perform sync_billing_sales(new.shop_id, v_new); end if;
  end if;
  return null;
end $$;
create trigger bills_sync_sales after insert or delete or update of status, total_amount, billing_date on bills for each row execute function trg_bills_sync_sales();

-- Shop owner switches the billing -> sales link on/off (Expense Tracker > Settings). Turning on back-fills past bills.
create function set_sales_sync(p_on boolean) returns void language plpgsql security definer set search_path = public as $$
declare v_shop uuid := current_shop_id(); d date;
begin
  if v_shop is null then raise exception 'no shop'; end if;
  if p_on then
    if not shop_can_write(v_shop, 'expenses') then raise exception 'Expense Tracker is not active'; end if;
    if not exists (select 1 from entitlements where shop_id = v_shop and product = 'billing') then raise exception 'Billing is not enabled for this shop'; end if;
    update shops set sync_sales = true where id = v_shop;
    for d in select distinct coalesce(billing_date::date, (created_at at time zone 'Asia/Kolkata')::date) from bills where shop_id = v_shop and status = 'final'
    loop perform sync_billing_sales(v_shop, d); end loop;
  else
    update shops set sync_sales = false where id = v_shop;
    delete from transactions where shop_id = v_shop and source = 'billing';
  end if;
end $$;
revoke execute on function set_sales_sync(boolean) from public, anon; grant execute on function set_sales_sync(boolean) to authenticated;

-- Approval now starts the trial of the product the shop signed up for.
create or replace function approve_shop(p_shop uuid, p_admin text, p_force boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare v_email text; v_prod text;
begin
  select email_normalized, signup_product into v_email, v_prod from shops where id = p_shop and status = 'pending_review' for update;
  if v_email is null then raise exception 'shop is not pending'; end if;
  if exists (select 1 from trial_ledger where email_normalized = v_email and product = v_prod) and not p_force then raise exception 'trial already used'; end if;
  insert into trial_ledger (email_normalized, product) values (v_email, v_prod) on conflict do nothing;
  update shops set status = 'approved', reviewed_by = p_admin, reviewed_at = now() where id = p_shop;
  insert into entitlements (shop_id, product, trial_started_at, trial_ends_at) values (p_shop, v_prod, now(), now() + interval '15 days')
    on conflict (shop_id, product) do update set trial_started_at = excluded.trial_started_at, trial_ends_at = excluded.trial_ends_at;
  insert into audit_log (actor, action, shop_id, detail) values (p_admin, 'approve', p_shop, jsonb_build_object('product', v_prod));
end $$;

-- An approved shop starts its other product's own 15-day trial (service role only; called by the app's API).
create function start_trial(p_shop uuid, p_product text) returns void language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  if p_product not in ('billing','expenses') then raise exception 'unknown product'; end if;
  select email_normalized into v_email from shops where id = p_shop and status = 'approved' for update;
  if v_email is null then raise exception 'shop is not approved'; end if;
  if exists (select 1 from entitlements where shop_id = p_shop and product = p_product) then raise exception 'trial already used'; end if;
  insert into trial_ledger (email_normalized, product) values (v_email, p_product);
  insert into entitlements (shop_id, product, trial_started_at, trial_ends_at) values (p_shop, p_product, now(), now() + interval '15 days');
  insert into audit_log (actor, action, shop_id, detail) values ('system', 'start_trial', p_shop, jsonb_build_object('product', p_product));
end $$;
revoke execute on function start_trial(uuid, text) from public, anon, authenticated;
