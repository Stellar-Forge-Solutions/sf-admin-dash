-- 0012: FSSAI number (optional) + Rs.0.30 per extra order. Safe to re-run.
alter table shops add column if not exists fssai_no text;
grant update (overage_limit_rupees, fssai_no) on shops to authenticated;

create or replace function cafe_usage_check(p_shop uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s shops; eff text; lim int; cap numeric; n int; m_start timestamptz;
begin
  select * into s from shops where id = p_shop;
  eff := coalesce(s.plan, 'free');
  if eff = 'basic' and s.plan_renewal_date is not null and s.plan_renewal_date < now() then eff := 'free'; end if;
  if eff = 'pro' then
    if s.custom_order_limit is null then return; end if;
    lim := s.custom_order_limit;
  elsif eff = 'basic' then lim := 600; else lim := 300; end if;
  m_start := date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  select count(*) into n from cafe_bills where shop_id = p_shop and created_at >= m_start;
  cap := coalesce(s.overage_limit_rupees, 300);             -- Rs.0.30 per extra order; cap is in rupees
  if n >= lim and (cap <= 0 or n >= lim + ceil(cap / 0.30)) then raise exception 'ORDER_LIMIT_REACHED'; end if;
end $$;
create or replace function cafe_finalize_bill(p_bill uuid, p_discount numeric, p_customer text, p_phone text, p_mode text)
returns cafe_bills language plpgsql security definer set search_path = public as $$
declare v_shop uuid := current_shop_id(); b cafe_bills; s shops; cs cafe_settings;
  sub numeric; disc numeric; taxable numeric; cg numeric := 0; sg numeric := 0; tot numeric; ro numeric := 0; n bigint;
begin
  if v_shop is null or not cafe_can_write(v_shop) then raise exception 'not allowed'; end if;
  select * into b from cafe_bills where id = p_bill and shop_id = v_shop for update;
  if b.id is null then raise exception 'bill not found'; end if;
  if b.status <> 'open' then raise exception 'bill is already closed'; end if;
  select coalesce(sum(price * qty), 0) into sub from cafe_bill_items where bill_id = p_bill;
  if sub <= 0 then raise exception 'bill is empty'; end if;
  disc := least(greatest(coalesce(p_discount, 0), 0), sub);
  taxable := sub - disc;
  select * into cs from cafe_settings where shop_id = v_shop;
  if coalesce(cs.tax_enabled, false) then
    cg := round(taxable * cs.cgst_pct / 100, 2);  sg := round(taxable * cs.sgst_pct / 100, 2);
  end if;
  tot := taxable + cg + sg;
  if coalesce(cs.round_off, false) then ro := round(tot) - tot; tot := round(tot); end if;
  insert into cafe_settings (shop_id, next_bill_no) values (v_shop, 2)
    on conflict (shop_id) do update set next_bill_no = cafe_settings.next_bill_no + 1
    returning next_bill_no - 1 into n;
  select * into s from shops where id = v_shop;
  update cafe_bills set
    status = 'final', bill_no = n, subtotal = sub, discount_amount = disc,
    tax_enabled = coalesce(cs.tax_enabled, false),
    cgst_pct = case when coalesce(cs.tax_enabled, false) then cs.cgst_pct else 0 end,
    sgst_pct = case when coalesce(cs.tax_enabled, false) then cs.sgst_pct else 0 end,
    cgst_amt = cg, sgst_amt = sg, round_off = ro, total = tot,
    customer_name = nullif(left(trim(coalesce(p_customer, '')), 60), ''),
    customer_phone = nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), ''),
    payment_mode = case when p_mode in ('cash','upi','card','other') then p_mode else 'cash' end,
    finalized_at = now(), finalized_by = auth.jwt() ->> 'email',
    snapshot = jsonb_build_object('name', s.name, 'tagline', s.tagline, 'address', s.address, 'mobile', s.mobile,
      'gst_no', s.gst_no, 'fssai_no', s.fssai_no, 'website', s.website, 'thank_you', s.thank_you, 'bill_prefix', s.bill_prefix,
      'logo_path', s.logo_path, 'upi_id', s.upi_id, 'show_upi_qr', s.show_upi_qr and s.upi_id is not null)
  where id = p_bill returning * into b;
  return b;
end $$;
revoke execute on function cafe_usage_check(uuid) from public, anon, authenticated;
revoke execute on function cafe_finalize_bill(uuid, numeric, text, text, text) from public, anon;
grant execute on function cafe_finalize_bill(uuid, numeric, text, text, text) to authenticated;