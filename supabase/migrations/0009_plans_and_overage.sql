-- ==============================================================================
-- Migration: 0009_plans_and_overage.sql
-- Description: Adds plan, billing cycle, overage limits, and verified badge to shops.
-- Note: Do NOT execute on production without explicit user confirmation.
-- ==============================================================================

-- 1. Add plan and overage fields to shops table
ALTER TABLE shops 
  ADD COLUMN IF NOT EXISTS plan text NOT NULL DEFAULT 'free',
  ADD COLUMN IF NOT EXISTS plan_start timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS plan_renewal_date timestamptz,
  ADD COLUMN IF NOT EXISTS billing_cycle text DEFAULT 'monthly',
  ADD COLUMN IF NOT EXISTS monthly_overage_limit numeric NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS verified_badge boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS custom_order_limit integer;

-- 2. Add constraint for valid plan types
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'shops_plan_check'
  ) THEN
    ALTER TABLE shops ADD CONSTRAINT shops_plan_check CHECK (plan IN ('free', 'basic', 'pro'));
  END IF;
END $$;

-- 3. Backfill existing approved shops to 'free' plan if currently null/unset
UPDATE shops 
SET plan = 'free'
WHERE plan IS NULL;

-- 4. Create an index on (shop_id, created_at) in orders for superfast monthly counting
CREATE INDEX IF NOT EXISTS idx_orders_shop_created_at 
  ON orders (shop_id, created_at);
