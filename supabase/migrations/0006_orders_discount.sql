-- Add discount columns to orders table
alter table orders add column if not exists discount_percent numeric(6,2) not null default 0;
alter table orders add column if not exists discount_amount numeric(12,2) not null default 0;

grant insert (discount_percent, discount_amount) on orders to authenticated;
grant update (discount_percent, discount_amount) on orders to authenticated;
