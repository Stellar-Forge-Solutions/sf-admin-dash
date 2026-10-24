-- Migration: 0008_orders_delivery_and_tracking.sql
-- Adds delivery_date and tracking_url to orders table

alter table orders add column if not exists delivery_date date;
alter table orders add column if not exists tracking_url text;

grant insert (delivery_date, tracking_url) on orders to authenticated;
grant update (delivery_date, tracking_url) on orders to authenticated;
