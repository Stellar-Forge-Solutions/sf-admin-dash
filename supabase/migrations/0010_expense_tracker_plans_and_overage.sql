-- ==============================================================================
-- Migration: 0010_expense_tracker_plans_and_overage.sql
-- Description: Implement Free/Basic/Pro plan system and overage tracking for Expense Tracker
-- Note: Do NOT execute on production without explicit user confirmation.
-- ==============================================================================

-- 1. Ensure shops has plan and overage fields (compatible with 0009_plans_and_overage.sql)
ALTER TABLE shops 
  ADD COLUMN IF NOT EXISTS plan text NOT NULL DEFAULT 'free',
  ADD COLUMN IF NOT EXISTS plan_start timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS plan_renewal_date timestamptz,
  ADD COLUMN IF NOT EXISTS billing_cycle text DEFAULT 'monthly',
  ADD COLUMN IF NOT EXISTS monthly_overage_limit numeric NOT NULL DEFAULT 50,
  ADD COLUMN IF NOT EXISTS pro_admin_notes text;

-- Add check constraint for valid plan types on shops
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'shops_plan_check'
  ) THEN
    ALTER TABLE shops ADD CONSTRAINT shops_plan_check CHECK (plan IN ('free', 'basic', 'pro'));
  END IF;
END $$;

-- 2. Add plan fields to entitlements table
ALTER TABLE entitlements
  ADD COLUMN IF NOT EXISTS plan_tier text DEFAULT 'free' CHECK (plan_tier IN ('free', 'basic', 'pro')),
  ADD COLUMN IF NOT EXISTS plan_start timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS plan_renewal_date timestamptz,
  ADD COLUMN IF NOT EXISTS billing_cycle text DEFAULT 'monthly';

-- 3. Monthly entry counter and overage tracking table
CREATE TABLE IF NOT EXISTS shop_usage (
  id              bigserial PRIMARY KEY,
  shop_id         uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  year_month      text NOT NULL, -- Format: 'YYYY-MM' in IST
  manual_entries  int NOT NULL DEFAULT 0,
  overage_entries int NOT NULL DEFAULT 0,
  overage_amount  numeric(10,2) NOT NULL DEFAULT 0,
  overage_limit   numeric(10,2) NOT NULL DEFAULT 50, -- Default ₹50 cap (0 = block new entries)
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id, year_month)
);

-- Index for instant lookup of monthly usage
CREATE INDEX IF NOT EXISTS idx_shop_usage_lookup ON shop_usage (shop_id, year_month);

-- Row Level Security on shop_usage
ALTER TABLE shop_usage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON shop_usage FROM anon;
GRANT SELECT, INSERT, UPDATE ON shop_usage TO authenticated;

DROP POLICY IF EXISTS "shop_usage_select" ON shop_usage;
CREATE POLICY "shop_usage_select" ON shop_usage
  FOR SELECT USING (shop_id = current_shop_id());

DROP POLICY IF EXISTS "shop_usage_insert" ON shop_usage;
CREATE POLICY "shop_usage_insert" ON shop_usage
  FOR INSERT WITH CHECK (shop_id = current_shop_id());

DROP POLICY IF EXISTS "shop_usage_update" ON shop_usage;
CREATE POLICY "shop_usage_update" ON shop_usage
  FOR UPDATE USING (shop_id = current_shop_id()) WITH CHECK (shop_id = current_shop_id());

-- 4. Fast counting index on transactions (shop_id, txn_date, source)
CREATE INDEX IF NOT EXISTS idx_transactions_monthly_count 
  ON transactions (shop_id, txn_date) 
  WHERE source <> 'billing';

-- 5. Fast counting index on lending (shop_id, date, type)
CREATE INDEX IF NOT EXISTS idx_lending_monthly_count 
  ON lending (shop_id, date) 
  WHERE type = 'lend';

-- Fast counting indexes on sale_vendors and purchase_vendors (shop_id, date)
CREATE INDEX IF NOT EXISTS idx_sale_vendors_monthly_count
  ON sale_vendors (shop_id, date);

CREATE INDEX IF NOT EXISTS idx_purchase_vendors_monthly_count
  ON purchase_vendors (shop_id, date);

-- 6. Update shop_can_write function:
-- Free plan users can now always write in the Expense Tracker as long as shop is approved!
-- (Limits are enforced at the application level; existing paid users continue working without downgrade)
CREATE OR REPLACE FUNCTION shop_can_write(p_shop uuid, p_product text) 
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM shops s 
    LEFT JOIN entitlements e ON e.shop_id = s.id AND e.product = p_product
    WHERE s.id = p_shop 
      AND s.status = 'approved' 
      AND s.deleted_at IS NULL
      AND (
        -- For expenses: approved shop on free, basic, or pro plan can write
        (p_product = 'expenses' AND (
          s.plan IN ('free', 'basic', 'pro')
          OR e.plan_tier IN ('free', 'basic', 'pro')
          OR coalesce(e.trial_ends_at, '-infinity') > now()
          OR coalesce(e.paid_until, '-infinity') > now()
        ))
        -- For billing and orders: keep original time-bounded logic
        OR (p_product <> 'expenses' AND (
          coalesce(e.trial_ends_at, '-infinity') > now() 
          OR coalesce(e.paid_until, '-infinity') > now()
        ))
      )
  )
$$;

-- 7. Existing user migration / backfill:
-- Existing ₹99 Expense Tracker paid users keep full basic access until their paid_until ends
UPDATE entitlements
SET plan_tier = 'basic',
    plan_renewal_date = paid_until
WHERE product = 'expenses'
  AND paid_until IS NOT NULL
  AND paid_until > now();

-- Sync shop.plan to basic for shops that have active paid expenses entitlement
UPDATE shops s
SET plan = 'basic',
    plan_renewal_date = e.paid_until
FROM entitlements e
WHERE e.shop_id = s.id
  AND e.product = 'expenses'
  AND e.paid_until IS NOT NULL
  AND e.paid_until > now();

-- Default remaining shops to 'free' plan if unset
UPDATE shops
SET plan = 'free'
WHERE plan IS NULL;

UPDATE entitlements
SET plan_tier = 'free'
WHERE product = 'expenses'
  AND plan_tier IS NULL;

-- Index for fast approved-shop count (used by auto-approval gate in signup API)
CREATE INDEX IF NOT EXISTS idx_shops_status_deleted
  ON shops (status, deleted_at)
  WHERE deleted_at IS NULL;
