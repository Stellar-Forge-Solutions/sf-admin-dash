-- 0017: append-only order ledger. Deleting or cancelling orders can no longer lower usage.

create table if not exists order_usage_ledger (
  shop_id uuid primary key references shops(id) on delete cascade,
  lifetime_count bigint not null default 0,
  last_order_no int not null default 0
);
create table if not exists order_usage_monthly (
  shop_id uuid references shops(id) on delete cascade,
  year_month text,
  orders int not null default 0,
  primary key (shop_id, year_month)
);
create table if not exists order_delete_log (
  id bigserial primary key,
  shop_id uuid, order_id uuid, order_no int, customer_name text,
  total numeric, stage_key text, order_created_at timestamptz,
  deleted_at timestamptz default now(), deleted_by text
);

alter table order_usage_ledger  enable row level security;
alter table order_usage_monthly enable row level security;
alter table order_delete_log    enable row level security;   -- no policy: service role only
revoke all on order_usage_ledger, order_usage_monthly, order_delete_log from anon, authenticated;
grant select on order_usage_ledger, order_usage_monthly to authenticated;
create policy oul_r on order_usage_ledger  for select using (shop_id = current_shop_id());
create policy oum_r on order_usage_monthly for select using (shop_id = current_shop_id());

-- Backfill from existing orders
insert into order_usage_ledger (shop_id, lifetime_count, last_order_no)
select shop_id, count(*), coalesce(max(order_no), 0) from orders group by shop_id
on conflict (shop_id) do update
  set lifetime_count = excluded.lifetime_count, last_order_no = excluded.last_order_no;

insert into order_usage_monthly (shop_id, year_month, orders)
select shop_id, to_char(created_at at time zone 'Asia/Kolkata', 'YYYY-MM'), count(*)
from orders group by 1, 2
on conflict (shop_id, year_month) do update set orders = excluded.orders;

-- order_no and usage now come from the ledger (never reused, never decreases)
create or replace function orders_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare ym text := to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM');
begin
  if tg_op = 'INSERT' then
    insert into order_usage_ledger (shop_id, lifetime_count, last_order_no)
      values (new.shop_id, 1, 1)
      on conflict (shop_id) do update
        set lifetime_count = order_usage_ledger.lifetime_count + 1,
            last_order_no  = order_usage_ledger.last_order_no + 1
      returning last_order_no into new.order_no;
    insert into order_usage_monthly (shop_id, year_month, orders)
      values (new.shop_id, ym, 1)
      on conflict (shop_id, year_month) do update set orders = order_usage_monthly.orders + 1;
    new.delivered_at := case when new.stage_key = 'delivered' then now() end;
  else
    new.order_no := old.order_no; new.token := old.token; new.shop_id := old.shop_id;
    new.delivered_at := case when new.stage_key = 'delivered' then coalesce(old.delivered_at, now()) end;
  end if;
  return new;
end $$;

-- Audit every delete from now on
create or replace function trg_orders_delete_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into order_delete_log (shop_id, order_id, order_no, customer_name, total, stage_key, order_created_at, deleted_by)
  values (old.shop_id, old.id, old.order_no, old.customer_name, old.total, old.stage_key, old.created_at, auth.jwt() ->> 'email');
  return old;
end $$;
drop trigger if exists orders_delete_log on orders;
create trigger orders_delete_log before delete on orders for each row execute function trg_orders_delete_log();

revoke execute on function orders_before(), trg_orders_delete_log() from public, anon, authenticated;