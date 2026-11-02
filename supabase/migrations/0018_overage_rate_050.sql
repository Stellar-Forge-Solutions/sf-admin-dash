-- 0018: Update default overage rate from Rs.0.30 to Rs.0.50 per extra order. Safe to re-run.

-- 1. Update column defaults on entitlements and shop_monthly_metrics
ALTER TABLE entitlements ALTER COLUMN overage_rate SET DEFAULT 0.50;
ALTER TABLE shop_monthly_metrics ALTER COLUMN overage_rate SET DEFAULT 0.50;

-- 2. Update existing shops: orders → ₹0.50, cafe → ₹1.00
UPDATE entitlements SET overage_rate = 0.50 WHERE overage_rate = 0.30 AND product <> 'cafe';
UPDATE entitlements SET overage_rate = 1.00 WHERE product = 'cafe';
UPDATE shop_monthly_metrics SET overage_rate = 0.50 WHERE overage_rate = 0.30 AND product <> 'cafe';
UPDATE shop_monthly_metrics SET overage_rate = 1.00 WHERE product = 'cafe';

-- 3. Replace the orders limit trigger to use 0.50 rate
CREATE OR REPLACE FUNCTION check_order_limit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  s record; n int; lim int; cap numeric;
BEGIN
  SELECT * INTO s FROM shops WHERE id = NEW.shop_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  lim := coalesce(s.custom_order_limit, 100);
  SELECT count(*) INTO n FROM orders WHERE shop_id = NEW.shop_id;
  cap := coalesce(s.overage_limit_rupees, 300);             -- Rs.0.50 per extra order; cap is in rupees
  if n >= lim and (cap <= 0 or n >= lim + ceil(cap / 0.50)) then raise exception 'ORDER_LIMIT_REACHED'; end if;
  RETURN NEW;
END;
$$;

-- 4. Keep Cafe usage check rate at Rs. 1.00 per extra order (cap in rupees / 1.00)
CREATE OR REPLACE FUNCTION cafe_usage_check(p_shop uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s shops; eff text; lim int; cap numeric; n int; m_start timestamptz;
BEGIN
  SELECT * INTO s FROM shops WHERE id = p_shop;
  eff := coalesce(s.plan, 'free');
  IF eff = 'basic' AND s.plan_renewal_date IS NOT NULL AND s.plan_renewal_date < now() THEN eff := 'free'; END IF;
  IF eff = 'pro' THEN
    IF s.custom_order_limit IS NULL THEN RETURN; END IF;
    lim := s.custom_order_limit;
  ELSIF eff = 'basic' THEN lim := 600; ELSE lim := 300; END IF;
  m_start := date_trunc('month', now() AT TIME ZONE 'Asia/Kolkata') AT TIME ZONE 'Asia/Kolkata';
  SELECT count(*) INTO n FROM cafe_bills WHERE shop_id = p_shop AND created_at >= m_start;
  cap := coalesce(s.overage_limit_rupees, 300);             -- Rs.1.00 per extra order; cap is in rupees
  IF n >= lim AND (cap <= 0 OR n >= lim + ceil(cap / 1.00)) THEN RAISE EXCEPTION 'ORDER_LIMIT_REACHED'; END IF;
END $$;

-- 5. Update the billing snapshot function to fall back to product-specific rate (1.00 for cafe, 0.50 for others)
CREATE OR REPLACE FUNCTION snapshot_shop_monthly_metrics(
  p_shop_id uuid,
  p_product  text DEFAULT 'orders',
  p_month    date DEFAULT date_trunc('month', now())::date
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_plan_tier     text;
  v_overage_rate  numeric(6,4);
  v_overage_limit numeric(10,2);
  v_included      integer;
  v_start         timestamptz;
  v_end           timestamptz;
  v_created       integer;
  v_delivered      integer;
  v_returned      integer;
  v_cancelled     integer;
  v_revenue       numeric(10,2);
  v_overage_orders integer;
  v_overage_amt   numeric(10,2);
  v_default_rate  numeric(6,4);
BEGIN
  v_start := p_month::timestamptz;
  v_end   := (p_month + interval '1 month')::timestamptz;

  v_default_rate := CASE WHEN p_product = 'cafe' THEN 1.00 ELSE 0.50 END;

  -- Pull plan tier, overage limit, and custom allowance from shops
  SELECT s.plan,
    COALESCE(s.monthly_overage_limit, 100),
    COALESCE(s.custom_order_limit, 100)
  INTO v_plan_tier, v_overage_limit, v_included
  FROM shops s WHERE s.id = p_shop_id;

  -- Get per-product overage_rate from entitlements (falls back to v_default_rate)
  SELECT COALESCE(e.overage_rate, v_default_rate)
  INTO v_overage_rate
  FROM entitlements e
  WHERE e.shop_id = p_shop_id AND e.product = p_product
  LIMIT 1;

  IF v_overage_rate IS NULL THEN v_overage_rate := v_default_rate; END IF;

  -- Count orders created in month
  SELECT count(*)
  INTO v_created
  FROM orders o
  WHERE o.shop_id = p_shop_id
    AND o.created_at >= v_start AND o.created_at < v_end;

  -- Delivered
  SELECT count(*)
  INTO v_delivered
  FROM orders o
  WHERE o.shop_id = p_shop_id
    AND o.stage_key = 'delivered'
    AND o.updated_at >= v_start AND o.updated_at < v_end;

  -- Returned
  SELECT count(*)
  INTO v_returned
  FROM orders o
  WHERE o.shop_id = p_shop_id
    AND o.stage_key = 'returned'
    AND o.updated_at >= v_start AND o.updated_at < v_end;

  -- Cancelled
  SELECT count(*)
  INTO v_cancelled
  FROM orders o
  WHERE o.shop_id = p_shop_id
    AND o.stage_key = 'cancelled'
    AND o.updated_at >= v_start AND o.updated_at < v_end;

  -- Revenue (from delivered only, exclude returned/cancelled)
  SELECT COALESCE(SUM(o.grand_total), 0)
  INTO v_revenue
  FROM orders o
  WHERE o.shop_id = p_shop_id
    AND o.stage_key = 'delivered'
    AND o.updated_at >= v_start AND o.updated_at < v_end;

  -- Calculate overage
  v_overage_orders := GREATEST(0, v_created - v_included);
  v_overage_amt    := ROUND(v_overage_orders * v_overage_rate, 2);

  INSERT INTO shop_monthly_metrics (
    shop_id, product, month,
    plan_tier, included_orders, overage_rate, overage_limit,
    orders_created, orders_delivered, orders_returned, orders_cancelled,
    revenue,
    overage_orders, overage_amount,
    updated_at
  ) VALUES (
    p_shop_id, p_product, p_month,
    v_plan_tier, v_included, v_overage_rate, v_overage_limit,
    v_created, v_delivered, v_returned, v_cancelled,
    v_revenue,
    v_overage_orders, v_overage_amt,
    now()
  )
  ON CONFLICT (shop_id, product, month) DO UPDATE SET
    plan_tier         = EXCLUDED.plan_tier,
    included_orders   = EXCLUDED.included_orders,
    overage_rate      = EXCLUDED.overage_rate,
    overage_limit     = EXCLUDED.overage_limit,
    orders_created    = EXCLUDED.orders_created,
    orders_delivered  = EXCLUDED.orders_delivered,
    orders_returned   = EXCLUDED.orders_returned,
    orders_cancelled  = EXCLUDED.orders_cancelled,
    revenue           = EXCLUDED.revenue,
    overage_orders    = EXCLUDED.overage_orders,
    overage_amount    = EXCLUDED.overage_amount,
    updated_at        = now();
END;
$$;
