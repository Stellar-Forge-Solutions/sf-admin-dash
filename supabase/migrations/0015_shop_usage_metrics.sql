-- ==============================================================================
-- Migration: 0015_shop_usage_metrics.sql
-- Description: Store per-shop per-product overage rate + monthly billing metrics
--              (orders processed, revenue, overage) so you can bill each shop
--              accurately based on actual usage.
-- Note: Do NOT execute on production without explicit user confirmation.
-- ==============================================================================

-- 1. Store the custom overage rate per shop per product on entitlements
--    Default 0.30 keeps existing behaviour; admin can set a custom rate per row.
ALTER TABLE entitlements
  ADD COLUMN IF NOT EXISTS overage_rate numeric(6,4) NOT NULL DEFAULT 0.30;

-- 2. Monthly usage + revenue snapshot table
--    One row per (shop_id, product, year_month).
--    Written / updated at the end of each month (or on-demand via admin script).
CREATE TABLE IF NOT EXISTS shop_monthly_metrics (
  id                bigserial PRIMARY KEY,
  shop_id           uuid        NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  product           text        NOT NULL DEFAULT 'orders',  -- 'orders' | 'billing' | 'expenses'
  year_month        text        NOT NULL,                   -- 'YYYY-MM' e.g. '2024-10'

  -- Plan snapshot (captured at billing time so history is immutable)
  plan_tier         text        NOT NULL DEFAULT 'free',    -- 'free' | 'basic' | 'pro'
  included_orders   integer     NOT NULL DEFAULT 0,         -- quota from the plan
  overage_rate      numeric(6,4) NOT NULL DEFAULT 0.30,     -- rate at time of billing (Rs per extra order)
  overage_limit     numeric(10,2) NOT NULL DEFAULT 100,     -- monthly cap in Rs

  -- Order volume
  orders_created    integer     NOT NULL DEFAULT 0,         -- total orders placed this month
  orders_delivered  integer     NOT NULL DEFAULT 0,         -- subset that reached 'delivered'

  -- Revenue (from orders.total / amount_paid)
  gross_revenue     numeric(14,2) NOT NULL DEFAULT 0,       -- sum of orders.total
  collected_revenue numeric(14,2) NOT NULL DEFAULT 0,       -- sum of orders.amount_paid
  outstanding       numeric(14,2) NOT NULL DEFAULT 0,       -- gross - collected

  -- Overage billing to you (platform fee owed by this shop to Stellar Forge)
  overage_orders    integer     NOT NULL DEFAULT 0,         -- orders beyond included quota
  overage_amount    numeric(10,2) NOT NULL DEFAULT 0,       -- overage_orders * overage_rate

  -- Metadata
  is_billed         boolean     NOT NULL DEFAULT false,     -- mark true when you've raised the invoice
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  UNIQUE (shop_id, product, year_month)
);

-- Fast lookup
CREATE INDEX IF NOT EXISTS idx_shop_monthly_metrics_lookup
  ON shop_monthly_metrics (shop_id, product, year_month);

CREATE INDEX IF NOT EXISTS idx_shop_monthly_metrics_month
  ON shop_monthly_metrics (year_month, product);

-- Row Level Security: shops can read their own metrics; you (service role) write them
ALTER TABLE shop_monthly_metrics ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON shop_monthly_metrics FROM anon;
GRANT SELECT ON shop_monthly_metrics TO authenticated;

DROP POLICY IF EXISTS "shop_monthly_metrics_select" ON shop_monthly_metrics;
CREATE POLICY "shop_monthly_metrics_select" ON shop_monthly_metrics
  FOR SELECT USING (shop_id = current_shop_id());

-- 3. Convenience function: snapshot a single shop's current month metrics
--    Call this at month-end via a cron job or admin script.
--    Parameters:
--      p_shop      - shop UUID
--      p_product   - 'orders'
--      p_yearmonth - 'YYYY-MM' e.g. '2024-10'
CREATE OR REPLACE FUNCTION snapshot_shop_metrics(
  p_shop      uuid,
  p_product   text,
  p_yearmonth text          -- 'YYYY-MM'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from          timestamptz;
  v_to            timestamptz;
  v_plan_tier     text;
  v_included      integer;
  v_overage_rate  numeric(6,4);
  v_overage_limit numeric(10,2);
  v_created       integer;
  v_delivered     integer;
  v_gross         numeric(14,2);
  v_collected     numeric(14,2);
  v_overage_orders integer;
  v_overage_amt   numeric(10,2);
BEGIN
  -- Date bounds (start of month in IST = UTC-5:30 offset)
  v_from := (p_yearmonth || '-01')::date;
  v_to   := v_from + interval '1 month';

  -- Pull plan tier, overage limit, and custom allowance from shops
  SELECT
    COALESCE(s.plan, 'free'),
    COALESCE(s.monthly_overage_limit, 100),
    s.custom_order_limit
  INTO v_plan_tier, v_overage_limit, v_included
  FROM shops s
  WHERE s.id = p_shop;

  -- Get per-product overage_rate from entitlements (falls back to 0.30)
  SELECT COALESCE(e.overage_rate, 0.30)
  INTO v_overage_rate
  FROM entitlements e
  WHERE e.shop_id = p_shop AND e.product = p_product
  LIMIT 1;

  -- Included orders: custom_order_limit set by admin wins; otherwise use plan tier default
  v_included := COALESCE(
    NULLIF(v_included, 0),          -- admin custom allowance (non-zero overrides)
    CASE v_plan_tier
      WHEN 'free'  THEN 100
      WHEN 'basic' THEN 300
      WHEN 'pro'   THEN 2147483647  -- effectively unlimited
      ELSE 100
    END
  );

  -- Count orders and revenue for the month
  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE stage_key = 'delivered'),
    COALESCE(SUM(total), 0),
    COALESCE(SUM(amount_paid), 0)
  INTO v_created, v_delivered, v_gross, v_collected
  FROM orders
  WHERE shop_id = p_shop
    AND created_at >= v_from
    AND created_at <  v_to;

  -- Calculate overage
  v_overage_orders := GREATEST(0, v_created - v_included);
  v_overage_amt    := ROUND(v_overage_orders * v_overage_rate, 2);

  -- Upsert the snapshot row
  INSERT INTO shop_monthly_metrics (
    shop_id, product, year_month,
    plan_tier, included_orders, overage_rate, overage_limit,
    orders_created, orders_delivered,
    gross_revenue, collected_revenue, outstanding,
    overage_orders, overage_amount,
    updated_at
  ) VALUES (
    p_shop, p_product, p_yearmonth,
    v_plan_tier, v_included, v_overage_rate, v_overage_limit,
    v_created, v_delivered,
    v_gross, v_collected, v_gross - v_collected,
    v_overage_orders, v_overage_amt,
    now()
  )
  ON CONFLICT (shop_id, product, year_month)
  DO UPDATE SET
    plan_tier         = EXCLUDED.plan_tier,
    included_orders   = EXCLUDED.included_orders,
    overage_rate      = EXCLUDED.overage_rate,
    overage_limit     = EXCLUDED.overage_limit,
    orders_created    = EXCLUDED.orders_created,
    orders_delivered  = EXCLUDED.orders_delivered,
    gross_revenue     = EXCLUDED.gross_revenue,
    collected_revenue = EXCLUDED.collected_revenue,
    outstanding       = EXCLUDED.outstanding,
    overage_orders    = EXCLUDED.overage_orders,
    overage_amount    = EXCLUDED.overage_amount,
    updated_at        = now();
END;
$$;

-- 4. Admin overview view: all shops, current month metrics
--    Use via service role (bypasses RLS)
CREATE OR REPLACE VIEW v_shop_metrics_latest AS
SELECT
  s.id              AS shop_id,
  s.name            AS shop_name,
  s.mobile          AS shop_mobile,
  s.plan            AS shop_plan,
  m.product,
  m.year_month,
  m.plan_tier,
  m.included_orders,
  m.overage_rate,
  m.overage_limit,
  m.orders_created,
  m.orders_delivered,
  m.gross_revenue,
  m.collected_revenue,
  m.outstanding,
  m.overage_orders,
  m.overage_amount,
  m.is_billed,
  m.notes,
  m.updated_at
FROM shops s
LEFT JOIN shop_monthly_metrics m
  ON m.shop_id   = s.id
  AND m.product  = 'orders'
  AND m.year_month = to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM')
WHERE s.deleted_at IS NULL
ORDER BY s.name;
