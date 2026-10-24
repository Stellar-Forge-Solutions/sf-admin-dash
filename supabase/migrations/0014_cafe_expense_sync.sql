-- ==============================================================================
-- 0014_cafe_expense_sync.sql · Sync SF Cafe sales into Expense Tracker
--
-- Mirrors billing sync (0003_expense.sql) and orders sync (0004_orders.sql).
-- One auto-managed sale row per shop per day = that day's finalized cafe bills.
-- ==============================================================================

-- 1) Shop sync toggle column
alter table shops add column if not exists sync_cafe_sales boolean not null default false;

-- 2) Unique index on transactions for cafe source
create unique index if not exists uq_transactions_cafe_day on transactions (shop_id, txn_date) where source = 'cafe';

-- 3) Restrictive RLS policies on transactions: ensure only internal triggers/procedures insert 'cafe' source
drop policy if exists tx_nobilling_i on transactions;
drop policy if exists tx_nobilling_u on transactions;
drop policy if exists tx_nobilling_d on transactions;

create policy tx_nobilling_i on transactions as restrictive for insert with check (source not in ('billing','orders','cafe'));
create policy tx_nobilling_u on transactions as restrictive for update using (source not in ('billing','orders','cafe')) with check (source not in ('billing','orders','cafe'));
create policy tx_nobilling_d on transactions as restrictive for delete using (source not in ('billing','orders','cafe'));

-- 4) Daily cafe sales calculation and sync function
create or replace function sync_cafe_sales(p_shop uuid, p_day date) returns void
language plpgsql security definer set search_path = public as $$
declare v_total numeric(12,2); v_count int;
begin
  if p_day is null then return; end if;
  if not exists (select 1 from shops where id = p_shop and sync_cafe_sales) or not shop_can_write(p_shop, 'expenses') then return; end if;

  perform pg_advisory_xact_lock(hashtext('cafe_sales:' || p_shop::text || p_day::text));

  select coalesce(sum(total), 0), count(*) into v_total, v_count from cafe_bills
    where shop_id = p_shop and status = 'final' and (finalized_at at time zone 'Asia/Kolkata')::date = p_day;

  if v_count = 0 then
    delete from transactions where shop_id = p_shop and source = 'cafe' and txn_date = p_day;
  else
    insert into transactions (shop_id, type, amount, category, description, txn_date, source, created_by)
    values (p_shop, 'sale', v_total, 'Cafe', v_count || case when v_count = 1 then ' bill' else ' bills' end || ' from cafe app', p_day, 'cafe', 'cafe-app')
    on conflict (shop_id, txn_date) where source = 'cafe' do update set amount = excluded.amount, description = excluded.description;
  end if;
end $$;

-- 5) Trigger on cafe_bills to keep transactions updated in real time
create or replace function trg_cafe_bills_sync_sales() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_old date; v_new date;
begin
  if tg_op in ('UPDATE','DELETE') and old.finalized_at is not null then
    v_old := (old.finalized_at at time zone 'Asia/Kolkata')::date;
    perform sync_cafe_sales(old.shop_id, v_old);
  end if;
  if tg_op in ('INSERT','UPDATE') and new.finalized_at is not null then
    v_new := (new.finalized_at at time zone 'Asia/Kolkata')::date;
    if tg_op = 'INSERT' or v_new is distinct from v_old or new.total is distinct from old.total or new.status is distinct from old.status then
      perform sync_cafe_sales(new.shop_id, v_new);
    end if;
  end if;
  return null;
end $$;

drop trigger if exists cafe_bills_sync_sales on cafe_bills;
create trigger cafe_bills_sync_sales
  after insert or delete or update of status, total, finalized_at
  on cafe_bills
  for each row execute function trg_cafe_bills_sync_sales();

-- 6) User-facing RPC to toggle sync on or off (Expense Tracker sync in Settings)
create or replace function set_cafe_sales_sync(p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := current_shop_id(); d date;
begin
  if v_shop is null then raise exception 'no shop'; end if;
  if p_on then
    if not shop_can_write(v_shop, 'expenses') then raise exception 'Expense Tracker is not active'; end if;
    update shops set sync_cafe_sales = true where id = v_shop;
    for d in select distinct (finalized_at at time zone 'Asia/Kolkata')::date from cafe_bills where shop_id = v_shop and status = 'final' and finalized_at is not null
    loop
      perform sync_cafe_sales(v_shop, d);
    end loop;
  else
    update shops set sync_cafe_sales = false where id = v_shop;
    delete from transactions where shop_id = v_shop and source = 'cafe';
  end if;
end $$;

revoke execute on function set_cafe_sales_sync(boolean) from public, anon;
grant execute on function set_cafe_sales_sync(boolean) to authenticated;
revoke execute on function sync_cafe_sales(uuid, date), trg_cafe_bills_sync_sales() from public, anon, authenticated;
