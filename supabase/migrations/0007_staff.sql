-- 0007_staff.sql: Staff and Owner accounts management with 1 owner + max 2 staff limit per shop.

-- 1) Table for staff members linked to a shop
create table if not exists shop_staff (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  name text not null,
  role text not null default 'staff' check (role in ('staff')),
  created_at timestamptz default now(),
  constraint uq_shop_staff_user unique (shop_id, user_id),
  constraint uq_staff_single_shop unique (user_id)
);

create index if not exists idx_shop_staff_shop on shop_staff (shop_id);
create index if not exists idx_shop_staff_user on shop_staff (user_id);

-- 2) Limit to at most 2 staff per shop
create or replace function check_shop_staff_limit() returns trigger language plpgsql as $$
begin
  if (select count(*) from shop_staff where shop_id = new.shop_id) >= 2 then
    raise exception 'Limit reached: A shop can have a maximum of 2 staff accounts.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_shop_staff_limit on shop_staff;
create trigger trg_shop_staff_limit
before insert on shop_staff
for each row execute function check_shop_staff_limit();

-- 3) Update current_shop_id() to support both Owner and Staff
create or replace function current_shop_id() returns uuid language sql stable security definer set search_path = public as $$
  select coalesce(
    (select id from shops where owner_id = auth.uid() and deleted_at is null),
    (select shop_id from shop_staff where user_id = auth.uid())
  );
$$;

-- 4) Allow staff to read their shop profile and settings
drop policy if exists "own shop read" on shops;
create policy "own shop read" on shops for select
  using (owner_id = auth.uid() or exists (select 1 from shop_staff where user_id = auth.uid() and shop_id = shops.id));

-- 5) RLS and permissions on shop_staff
alter table shop_staff enable row level security;
revoke all on shop_staff from anon, authenticated;

-- Owner can read all staff of their shop; Staff can read their own record
create policy shop_staff_select on shop_staff for select
  using (
    exists (select 1 from shops s where s.id = shop_staff.shop_id and s.owner_id = auth.uid())
    or user_id = auth.uid()
  );

-- Only Owner can insert or delete staff for their shop
create policy shop_staff_insert on shop_staff for insert
  with check (
    exists (select 1 from shops s where s.id = shop_staff.shop_id and s.owner_id = auth.uid())
  );

create policy shop_staff_delete on shop_staff for delete
  using (
    exists (select 1 from shops s where s.id = shop_staff.shop_id and s.owner_id = auth.uid())
  );

grant select, insert, delete on shop_staff to authenticated;

-- FIX: Break the circular RLS shops <-> shop_staff
-- ============================================================
-- RECOVERY: Restore shop access + ensure staff migration is clean
-- ============================================================

-- Step 1: Restore simple current_shop_id() first (in case it's broken)
create or replace function current_shop_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from shops where owner_id = auth.uid() and deleted_at is null;
$$;

-- Step 2: Create shop_staff table (safe if already exists)
create table if not exists shop_staff (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  name text not null,
  role text not null default 'staff' check (role in ('staff')),
  created_at timestamptz default now(),
  constraint uq_shop_staff_user unique (shop_id, user_id),
  constraint uq_staff_single_shop unique (user_id)
);
create index if not exists idx_shop_staff_shop on shop_staff (shop_id);
create index if not exists idx_shop_staff_user on shop_staff (user_id);

-- Step 3: Now update current_shop_id() to support staff (table now guaranteed to exist)
create or replace function current_shop_id() returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select id from shops where owner_id = auth.uid() and deleted_at is null),
    (select shop_id from shop_staff where user_id = auth.uid())
  );
$$;

-- Step 4: Recreate the shops read policy (this is the main fix)
drop policy if exists "own shop read" on shops;
create policy "own shop read" on shops for select
  using (
    owner_id = auth.uid()
    or exists (select 1 from shop_staff where user_id = auth.uid() and shop_id = shops.id)
  );

-- Step 5: Ensure shop_staff RLS is clean
alter table shop_staff enable row level security;
revoke all on shop_staff from anon, authenticated;

drop policy if exists shop_staff_select on shop_staff;
create policy shop_staff_select on shop_staff for select
  using (
    exists (select 1 from shops s where s.id = shop_staff.shop_id and s.owner_id = auth.uid())
    or user_id = auth.uid()
  );

drop policy if exists shop_staff_insert on shop_staff;
create policy shop_staff_insert on shop_staff for insert
  with check (
    exists (select 1 from shops s where s.id = shop_staff.shop_id and s.owner_id = auth.uid())
  );

drop policy if exists shop_staff_delete on shop_staff;
create policy shop_staff_delete on shop_staff for delete
  using (
    exists (select 1 from shops s where s.id = shop_staff.shop_id and s.owner_id = auth.uid())
  );

grant select, insert, delete on shop_staff to authenticated;

-- Fix: break the circular RLS shops <-> shop_staff

-- 1. Create a SECURITY DEFINER helper that reads shop_staff without RLS
create or replace function is_shop_staff(p_shop_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from shop_staff
    where user_id = auth.uid() and shop_id = p_shop_id
  );
$$;

-- 2. Replace shops SELECT policy using the helper (no circular reference)
drop policy if exists "own shop read" on shops;
create policy "own shop read" on shops for select
  using (owner_id = auth.uid() or is_shop_staff(id));