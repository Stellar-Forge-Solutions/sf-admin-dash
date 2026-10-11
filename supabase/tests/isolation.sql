-- Run after migrations on a scratch database. Any "LEAK" exception means isolation is broken.
begin;
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000001','a@x.com'), ('bbbbbbbb-0000-0000-0000-000000000002','b@x.com');
insert into shops (id, owner_id, email, email_normalized, name, owner_name, mobile, whatsapp, status) values
 ('a0000000-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','a@x.com','a@x.com','Shop A','A','1','1','approved'),
 ('b0000000-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000002','b@x.com','b@x.com','Shop B','B','2','2','approved');
insert into entitlements (shop_id, product, trial_ends_at) values
 ('a0000000-0000-0000-0000-00000000000a','billing', now() + interval '1 day'), ('b0000000-0000-0000-0000-00000000000b','billing', now() + interval '1 day');
insert into bills (shop_id, customer_name) values ('a0000000-0000-0000-0000-00000000000a','secret A');
insert into transactions (shop_id, type, amount) values ('a0000000-0000-0000-0000-00000000000a','sale',500);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated"}', true);
do $$
declare n int;
begin
  if (select count(*) from bills) <> 0 then raise exception 'LEAK: B can read A bills'; end if;
  if (select count(*) from shops) <> 1 then raise exception 'LEAK: B can read other shops'; end if;
  if (select count(*) from transactions) <> 0 then raise exception 'LEAK: B can read A transactions'; end if;
  if (select count(*) from v_monthly_summary) <> 0 then raise exception 'LEAK: B sees A in summary view'; end if;
  begin insert into transactions (shop_id, type, amount) values ('a0000000-0000-0000-0000-00000000000a','sale',1); raise exception 'LEAK: B inserted a transaction into A';
  exception when insufficient_privilege or check_violation then null; end;
  begin insert into transactions (type, amount, source) values ('sale',1,'billing'); raise exception 'BUG: forged billing row';
  exception when insufficient_privilege or check_violation then null; end;
  begin insert into bills (customer_name, shop_id) values ('x','a0000000-0000-0000-0000-00000000000a'); raise exception 'LEAK: B inserted into A';
  exception when insufficient_privilege or check_violation then null; end;
  update shops set name = 'hacked' where id = 'a0000000-0000-0000-0000-00000000000a';
  get diagnostics n = row_count; if n <> 0 then raise exception 'LEAK: B edited shop A'; end if;
  begin update shops set status = 'approved' where id = 'b0000000-0000-0000-0000-00000000000b'; raise exception 'LEAK: B changed own status';
  exception when insufficient_privilege then null; end;
  begin perform approve_shop('b0000000-0000-0000-0000-00000000000b','b'); raise exception 'LEAK: B ran approve_shop';
  exception when insufficient_privilege then null; end;
end $$;
do $$ declare n bigint; begin
  insert into bills (customer_name, status, total_amount) values ('mine','final',10) returning bill_no into n;
  if n is distinct from 1 then raise exception 'BUG: first bill number is %', n; end if;
  begin update bills set total_amount = 99 where bill_no = 1; raise exception 'BUG: printed bill is editable';
  exception when raise_exception then if sqlerrm like 'BUG%' then raise; end if; end;
end $$;
rollback;
