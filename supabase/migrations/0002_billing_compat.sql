-- Lets the original billing screens work unchanged: the app sets status draft/final/cancelled,
-- the database assigns the per-shop bill number + shop snapshot and locks printed bills.
alter table bill_items add column if not exists item_id uuid;
alter table bills add column if not exists finalized_at timestamptz;
alter table shops add column if not exists reminded_soon boolean not null default false,
                  add column if not exists reminded_overdue boolean not null default false;

drop trigger if exists bills_lock on bills;
drop function if exists bills_lock();
drop function if exists finalize_bill(uuid);
drop function if exists cancel_bill(uuid, text);

revoke insert, update on bills from authenticated;
grant insert (customer_name, total_amount, status, billing_date, discount_percent, discount_amount, created_by) on bills to authenticated;
grant update (customer_name, total_amount, status, billing_date, discount_percent, discount_amount, cancel_reason, cancelled_at) on bills to authenticated;
revoke insert, update on bill_items from authenticated;
grant insert (bill_id, item_id, item_name, item_price, quantity) on bill_items to authenticated;
grant update (item_name, item_price, quantity) on bill_items to authenticated;

drop policy if exists bills_u on bills;
create policy bills_u on bills for update using (shop_id = current_shop_id() and shop_can_write(shop_id, 'billing'))
  with check (shop_id = current_shop_id());

create function bills_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare s shops; n bigint;
begin
  if tg_op = 'INSERT' then
    if new.status = 'cancelled' then raise exception 'cannot create a cancelled bill'; end if;
    new.bill_no := null; new.snapshot := null; new.finalized_at := null; new.cancel_reason := null; new.cancelled_at := null;
  else
    if old.status <> 'draft' and (new.customer_name, new.total_amount, new.billing_date, new.discount_amount, new.discount_percent)
       is distinct from (old.customer_name, old.total_amount, old.billing_date, old.discount_amount, old.discount_percent)
      then raise exception 'printed bills are locked'; end if;
    if (old.status in ('final','cancelled') and new.status = 'draft') or (old.status = 'cancelled' and new.status <> 'cancelled')
      then raise exception 'invalid status change'; end if;
    new.bill_no := old.bill_no; new.snapshot := old.snapshot; new.finalized_at := old.finalized_at;
    if new.status <> 'cancelled' then new.cancel_reason := old.cancel_reason; new.cancelled_at := old.cancelled_at; end if;
  end if;
  if new.status = 'final' and (tg_op = 'INSERT' or old.status <> 'final') then
    select * into s from shops where id = new.shop_id;
    insert into bill_counters (shop_id, next_no) values (new.shop_id, 2)
      on conflict (shop_id) do update set next_no = bill_counters.next_no + 1 returning next_no - 1 into n;
    new.bill_no := n; new.finalized_at := now();
    new.snapshot := jsonb_build_object('name', s.name, 'tagline', s.tagline, 'address', s.address, 'mobile', s.mobile, 'gst_no', s.gst_no,
      'website', s.website, 'thank_you', s.thank_you, 'bill_prefix', s.bill_prefix, 'logo_path', s.logo_path,
      'upi_id', s.upi_id, 'show_upi_qr', s.show_upi_qr and s.upi_id is not null);
  end if;
  return new;
end $$;
create trigger bills_guard before insert or update on bills for each row execute function bills_guard();

-- Items of a bill can change while it is a draft, or in the first minute after printing (the app saves items right after the bill).
create function bill_open(p_bill uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from bills b where b.id = p_bill and b.shop_id = current_shop_id()
    and (b.status = 'draft' or (b.status = 'final' and b.finalized_at > now() - interval '1 minute'))) $$;
drop policy if exists bi_i on bill_items; drop policy if exists bi_u on bill_items; drop policy if exists bi_d on bill_items;
create policy bi_i on bill_items for insert with check (shop_id = current_shop_id() and shop_can_write(shop_id, 'billing') and bill_open(bill_id));
create policy bi_u on bill_items for update using (shop_id = current_shop_id() and shop_can_write(shop_id, 'billing') and bill_open(bill_id))
  with check (shop_id = current_shop_id());
create policy bi_d on bill_items for delete using (shop_id = current_shop_id() and shop_can_write(shop_id, 'billing') and bill_open(bill_id));

-- Storage: public buckets for shared PDFs and shop logos, writable only inside the shop's own folder.
insert into storage.buckets (id, name, public) values ('bills', 'bills', true), ('logos', 'logos', true) on conflict (id) do nothing;
create policy "bills write own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'bills' and (storage.foldername(name))[1] = current_shop_id()::text and shop_can_write(current_shop_id(), 'billing'));
create policy "logos write own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'logos' and (storage.foldername(name))[1] = current_shop_id()::text and shop_can_write(current_shop_id(), 'billing'));
create policy "logos delete own folder" on storage.objects for delete to authenticated
  using (bucket_id = 'logos' and (storage.foldername(name))[1] = current_shop_id()::text);

alter publication supabase_realtime add table bills;
