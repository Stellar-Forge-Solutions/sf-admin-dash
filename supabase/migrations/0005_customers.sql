-- Customers table for Orders app: customer master with per-shop isolation.
create table if not exists order_customers (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default current_shop_id() references shops(id) on delete cascade,
  name text not null,
  whatsapp text,
  email text,
  address text,
  created_at timestamptz default now()
);

create unique index if not exists order_customers_name_uq on order_customers (shop_id, lower(name));

alter table order_customers enable row level security;
revoke all on order_customers from anon, authenticated;

create policy order_customers_r on order_customers for select
  using (shop_id = current_shop_id());

create policy order_customers_i on order_customers for insert
  with check (shop_id = current_shop_id() and shop_can_write(shop_id, 'orders'));

create policy order_customers_u on order_customers for update
  using (shop_id = current_shop_id() and shop_can_write(shop_id, 'orders'))
  with check (shop_id = current_shop_id());

create policy order_customers_d on order_customers for delete
  using (shop_id = current_shop_id() and shop_can_write(shop_id, 'orders'));

grant select, insert, update, delete on order_customers to authenticated;
