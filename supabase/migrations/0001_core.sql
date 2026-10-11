-- Stellar Forge core: shops, trials, admin, billing tables with per-shop isolation.
create extension if not exists pgcrypto;

create function normalize_email(e text) returns text language sql immutable as $$
  with s as (select split_part(lower(trim(e)),'@',1) l, split_part(lower(trim(e)),'@',2) d)
  select case when d in ('gmail.com','googlemail.com')
    then replace(split_part(l,'+',1),'.','') || '@gmail.com'
    else split_part(l,'+',1) || '@' || d end from s $$;

create table shops (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid unique references auth.users(id) on delete cascade,
  email text not null,
  email_normalized text not null unique,
  name text not null, owner_name text not null,
  mobile text not null, whatsapp text not null,
  city text, business_type text, ref_link text,
  tagline text, address text, gst_no text, upi_id text, website text,
  thank_you text not null default 'Thank you!',
  bill_prefix text not null default 'SF-',
  paper_width int not null default 58 check (paper_width in (58,80)),
  logo_path text,
  show_upi_qr boolean not null default false,
  status text not null default 'pending_review'
    check (status in ('pending_review','approved','rejected','suspended')),
  review_due_at timestamptz, reviewed_by text, reviewed_at timestamptz, review_note text,
  deleted_at timestamptz, created_at timestamptz not null default now(),
  constraint upi_required check (not show_upi_qr or coalesce(upi_id ~ '^[A-Za-z0-9._-]{2,}@[A-Za-z]{2,}$', false))
);

create table entitlements (
  shop_id uuid references shops(id) on delete cascade,
  product text check (product in ('billing','expenses')),
  plan text not null default 'basic' check (plan in ('basic','pro')),
  trial_started_at timestamptz, trial_ends_at timestamptz, paid_until timestamptz,
  primary key (shop_id, product)
);
create table trial_ledger (email_normalized text, product text, started_at timestamptz default now(), primary key (email_normalized, product));
create table blocklist (kind text check (kind in ('email','mobile')), value text, primary key (kind, value));
create table platform_admins (email text primary key, password_salt text not null, password_hash text not null);
create table admin_login_codes (id uuid primary key default gen_random_uuid(), email text not null, code_hash text not null,
  expires_at timestamptz not null, attempts int not null default 0, used_at timestamptz, created_at timestamptz default now());
create table audit_log (id bigserial primary key, actor text, action text, shop_id uuid, detail jsonb, created_at timestamptz default now());
create table bill_counters (shop_id uuid primary key references shops(id) on delete cascade, next_no bigint not null default 1);

-- Admin-only tables: RLS on, no policies => only the service role can touch them.
alter table entitlements enable row level security;  alter table trial_ledger enable row level security;
alter table blocklist enable row level security;     alter table platform_admins enable row level security;
alter table admin_login_codes enable row level security; alter table audit_log enable row level security;
alter table bill_counters enable row level security;

create function current_shop_id() returns uuid language sql stable security definer set search_path = public as
$$ select id from shops where owner_id = auth.uid() and deleted_at is null $$;

-- True only if shop is approved AND this product's trial or paid period is still running.
create function shop_can_write(p_shop uuid, p_product text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from shops s join entitlements e on e.shop_id = s.id and e.product = p_product
    where s.id = p_shop and s.status = 'approved' and s.deleted_at is null
      and (coalesce(e.trial_ends_at,'-infinity') > now() or coalesce(e.paid_until,'-infinity') > now())) $$;

create policy "own entitlements" on entitlements for select using (shop_id = current_shop_id());
revoke all on entitlements from anon, authenticated;
grant select on entitlements to authenticated;

-- Shops: owners read and edit only profile columns. Status/review fields are admin-only.
alter table shops enable row level security;
revoke all on shops from anon, authenticated;
grant select on shops to authenticated;
grant update (name, tagline, address, mobile, whatsapp, gst_no, upi_id, website, thank_you,
              bill_prefix, paper_width, logo_path, show_upi_qr) on shops to authenticated;
create policy "own shop read" on shops for select using (owner_id = auth.uid());
create policy "own shop edit" on shops for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Billing tables
create table items (id uuid primary key default gen_random_uuid(), shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  name text not null, created_at timestamptz default now());
create unique index items_shop_name on items (shop_id, lower(name));
create table bills (id uuid primary key default gen_random_uuid(), shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  customer_name text not null, total_amount numeric(10,2) not null default 0,
  status text not null default 'draft' check (status in ('draft','final','cancelled')),
  billing_date date default current_date, bill_no bigint, discount_percent numeric default 0, discount_amount numeric default 0,
  cancel_reason text, cancelled_at timestamptz, created_by text default (auth.jwt() ->> 'email'),
  snapshot jsonb, created_at timestamptz default now(), unique (shop_id, bill_no));
create table bill_items (id uuid primary key default gen_random_uuid(), bill_id uuid not null references bills(id) on delete cascade,
  shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  item_name text not null, item_price numeric(10,2) not null, quantity int not null default 1, created_at timestamptz default now());

alter table items enable row level security; alter table bills enable row level security; alter table bill_items enable row level security;
revoke all on items, bills, bill_items from anon, authenticated;
grant select, delete on items, bills, bill_items to authenticated;
grant insert (name), update (name) on items to authenticated;
grant insert (customer_name,total_amount,billing_date,discount_percent,discount_amount),
      update (customer_name,total_amount,billing_date,discount_percent,discount_amount) on bills to authenticated;
grant insert (bill_id,item_name,item_price,quantity), update (item_name,item_price,quantity) on bill_items to authenticated;

create policy items_r on items for select using (shop_id = current_shop_id());
create policy items_i on items for insert with check (shop_id = current_shop_id() and shop_can_write(shop_id,'billing'));
create policy items_u on items for update using (shop_id = current_shop_id() and shop_can_write(shop_id,'billing')) with check (shop_id = current_shop_id());
create policy items_d on items for delete using (shop_id = current_shop_id() and shop_can_write(shop_id,'billing'));
create policy bills_r on bills for select using (shop_id = current_shop_id());
create policy bills_i on bills for insert with check (shop_id = current_shop_id() and shop_can_write(shop_id,'billing'));
create policy bills_u on bills for update using (shop_id = current_shop_id() and shop_can_write(shop_id,'billing') and status = 'draft')
  with check (shop_id = current_shop_id());
create policy bills_d on bills for delete using (shop_id = current_shop_id() and shop_can_write(shop_id,'billing') and status = 'draft');
create policy bi_r on bill_items for select using (shop_id = current_shop_id());
create policy bi_i on bill_items for insert with check (shop_id = current_shop_id() and shop_can_write(shop_id,'billing')
  and exists (select 1 from bills b where b.id = bill_id and b.shop_id = current_shop_id() and b.status = 'draft'));
create policy bi_u on bill_items for update using (shop_id = current_shop_id() and shop_can_write(shop_id,'billing')
  and exists (select 1 from bills b where b.id = bill_id and b.status = 'draft')) with check (shop_id = current_shop_id());
create policy bi_d on bill_items for delete using (shop_id = current_shop_id() and shop_can_write(shop_id,'billing')
  and exists (select 1 from bills b where b.id = bill_id and b.status = 'draft'));

-- Printed bills are locked; status moves only draft -> final -> cancelled.
create function bills_lock() returns trigger language plpgsql as $$
begin
  if old.status <> 'draft' and (new.customer_name,new.total_amount,new.billing_date,new.discount_amount,new.discount_percent,new.bill_no,new.snapshot)
     is distinct from (old.customer_name,old.total_amount,old.billing_date,old.discount_amount,old.discount_percent,old.bill_no,old.snapshot)
  then raise exception 'printed bills are locked'; end if;
  if (old.status in ('final','cancelled') and new.status = 'draft') or (old.status = 'cancelled' and new.status <> 'cancelled')
  then raise exception 'invalid status change'; end if;
  return new;
end $$;
create trigger bills_lock before update on bills for each row execute function bills_lock();

-- Print: atomic per-shop bill number + snapshot of shop details, so later profile edits never change old bills.
create function finalize_bill(p_bill uuid) returns bills language plpgsql security definer set search_path = public as $$
declare b bills; s shops; n bigint;
begin
  select * into b from bills where id = p_bill and shop_id = current_shop_id() for update;
  if b.id is null then raise exception 'bill not found'; end if;
  if b.status <> 'draft' then raise exception 'already printed'; end if;
  if not shop_can_write(b.shop_id,'billing') then raise exception 'billing not active'; end if;
  select * into s from shops where id = b.shop_id;
  insert into bill_counters (shop_id, next_no) values (b.shop_id, 2)
    on conflict (shop_id) do update set next_no = bill_counters.next_no + 1 returning next_no - 1 into n;
  update bills set status = 'final', bill_no = n, snapshot = jsonb_build_object(
    'name', s.name, 'tagline', s.tagline, 'address', s.address, 'mobile', s.mobile, 'gst_no', s.gst_no,
    'website', s.website, 'thank_you', s.thank_you, 'bill_prefix', s.bill_prefix, 'logo_path', s.logo_path,
    'upi_id', s.upi_id, 'show_upi_qr', s.show_upi_qr and s.upi_id is not null)
  where id = p_bill returning * into b;
  return b;
end $$;

create function cancel_bill(p_bill uuid, p_reason text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not shop_can_write(current_shop_id(),'billing') then raise exception 'billing not active'; end if;
  update bills set status = 'cancelled', cancel_reason = p_reason, cancelled_at = now()
    where id = p_bill and shop_id = current_shop_id() and status = 'final';
  if not found then raise exception 'cannot cancel'; end if;
end $$;
revoke execute on function finalize_bill(uuid), cancel_bill(uuid,text) from public, anon;
grant execute on function finalize_bill(uuid), cancel_bill(uuid,text) to authenticated;

-- Admin approval (service role only): starts the 15-day Billing trial now, once per email.
create function approve_shop(p_shop uuid, p_admin text, p_force boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  select email_normalized into v_email from shops where id = p_shop and status = 'pending_review' for update;
  if v_email is null then raise exception 'shop is not pending'; end if;
  if exists (select 1 from trial_ledger where email_normalized = v_email and product = 'billing') and not p_force
    then raise exception 'trial already used'; end if;
  insert into trial_ledger (email_normalized, product) values (v_email, 'billing') on conflict do nothing;
  update shops set status = 'approved', reviewed_by = p_admin, reviewed_at = now() where id = p_shop;
  insert into entitlements (shop_id, product, trial_started_at, trial_ends_at) values (p_shop, 'billing', now(), now() + interval '15 days')
    on conflict (shop_id, product) do update set trial_started_at = excluded.trial_started_at, trial_ends_at = excluded.trial_ends_at;
  insert into audit_log (actor, action, shop_id) values (p_admin, 'approve', p_shop);
end $$;
revoke execute on function approve_shop(uuid,text,boolean) from public, anon, authenticated;
