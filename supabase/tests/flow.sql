-- End-to-end rules: approval, numbering, snapshots, locks, billing->sales sync, per-product expiry. Any "BUG" means a broken rule.
begin;
insert into auth.users (id, email) values ('c0000000-0000-0000-0000-00000000000c','c@x.com'), ('d0000000-0000-0000-0000-00000000000d','d@x.com');
insert into shops (id, owner_id, email, email_normalized, name, owner_name, mobile, whatsapp, upi_id, show_upi_qr, bill_prefix) values
 ('c1000000-0000-0000-0000-0000000000c1','c0000000-0000-0000-0000-00000000000c','c@x.com','c@x.com','Shop C','C','1','1','shopc@upi',true,'CC-'),
 ('d1000000-0000-0000-0000-0000000000d1','d0000000-0000-0000-0000-00000000000d','d@x.com','d@x.com','Shop D','D','2','2',null,false,'DD-');
select approve_shop('c1000000-0000-0000-0000-0000000000c1','test');
select approve_shop('d1000000-0000-0000-0000-0000000000d1','test');
select start_trial('c1000000-0000-0000-0000-0000000000c1','expenses');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-00000000000c","email":"c@x.com","role":"authenticated"}',true) \gset
do $$ declare b bills; b2 bills; tot numeric; begin
  insert into bills (customer_name,status,total_amount,created_by) values ('x','final',100,'c@x.com') returning * into b;
  if b.bill_no <> 1 or b.snapshot->>'bill_prefix' <> 'CC-' or (b.snapshot->>'show_upi_qr')::boolean is not true then raise exception 'BUG numbering/snapshot %', b; end if;
  insert into bill_items (bill_id,item_name,item_price,quantity) values (b.id,'Haldi',100,1);
  update shops set name = 'Renamed C' where owner_id = auth.uid();
  if (select snapshot->>'name' from bills where id = b.id) <> 'Shop C' then raise exception 'BUG: old bill changed with profile'; end if;

  insert into bills (customer_name,status,total_amount) values ('y','draft',50) returning * into b2;
  insert into bill_items (bill_id,item_name,item_price,quantity) values (b2.id,'a',50,1);
  update bills set status='final', total_amount=60 where id = b2.id;
  delete from bill_items where bill_id = b2.id;
  insert into bill_items (bill_id,item_name,item_price,quantity) values (b2.id,'a',60,1);
  if (select bill_no from bills where id = b2.id) <> 2 then raise exception 'BUG: second bill number'; end if;
  begin update bills set bill_no = 99 where id = b2.id; raise exception 'BUG: bill_no editable';
  exception when insufficient_privilege then null; end;
  update bills set status='cancelled', cancel_reason='r', cancelled_at=now() where id = b2.id;
  begin update bills set status='final' where id = b2.id; raise exception 'BUG: cancelled bill revived';
  exception when raise_exception then if sqlerrm like 'BUG%' then raise; end if; end;

  perform set_sales_sync(true);
  select amount into tot from transactions where source='billing' and txn_date = current_date;
  if tot is distinct from 100 then raise exception 'BUG: sync backfill total % (want 100)', tot; end if;
  insert into bills (customer_name,status,total_amount) values ('z','final',40);
  select amount into tot from transactions where source='billing' and txn_date = current_date;
  if tot is distinct from 140 then raise exception 'BUG: live sync total % (want 140)', tot; end if;
  begin delete from transactions where source='billing'; if (select count(*) from transactions where source='billing') = 0 then raise exception 'BUG: billing sale deletable'; end if; end;
end $$;

select set_config('request.jwt.claims','{"sub":"d0000000-0000-0000-0000-00000000000d","email":"d@x.com","role":"authenticated"}',true) \gset
do $$ declare b bills; begin
  insert into bills (customer_name,status,total_amount) values ('q','final',10) returning * into b;
  if b.bill_no <> 1 or b.snapshot->>'bill_prefix' <> 'DD-' then raise exception 'BUG: shop D numbering %', b; end if;
  begin perform set_sales_sync(true); raise exception 'BUG: D synced without expense plan';
  exception when raise_exception then if sqlerrm like 'BUG%' then raise; end if; end;
end $$;

reset role;
update entitlements set trial_ends_at = now() - interval '1 day' where shop_id = 'c1000000-0000-0000-0000-0000000000c1' and product = 'expenses';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-00000000000c","email":"c@x.com","role":"authenticated"}',true) \gset
do $$ begin
  begin insert into transactions (type, amount) values ('expense', 5); raise exception 'BUG: expense write after expiry';
  exception when insufficient_privilege then null; end;
  insert into bills (customer_name,status,total_amount) values ('still-ok','final',1);   -- billing trial is separate and still active
  if (select count(*) from transactions) = 0 then raise exception 'BUG: expired shop cannot read its data'; end if;
end $$;
rollback;
