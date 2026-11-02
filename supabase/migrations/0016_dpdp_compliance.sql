-- ==============================================================================
-- Migration: 0016_dpdp_compliance.sql
-- Description: DPDP (Digital Personal Data Protection Act, 2023) Compliance schema updates.
--              Adds consent tracking, customer anonymisation (Right to be Forgotten),
--              and audit support for privacy requests.
-- ==============================================================================

-- 1. Consent tracking on shops (for shop owners & staff as Data Principals)
ALTER TABLE shops
  ADD COLUMN IF NOT EXISTS consent_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS consent_version text DEFAULT '2023-dpdp-v1',
  ADD COLUMN IF NOT EXISTS data_retention_days integer DEFAULT 1095; -- 3 years default retention

-- 2. Anonymisation flag on orders and customers
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS anonymized_at timestamptz,
  ADD COLUMN IF NOT EXISTS customer_consent_given boolean DEFAULT true;

ALTER TABLE order_customers
  ADD COLUMN IF NOT EXISTS anonymized_at timestamptz;

-- 3. Stored Procedure for Customer Anonymisation (Right to Erasure / Right to be Forgotten)
--    Strips Customer PII (name, whatsapp, email) while preserving order financial figures
--    (tax, totals, order_no) so shop tax & statutory audit accounting is not broken.
CREATE OR REPLACE FUNCTION anonymize_customer_pii(
  p_shop uuid,
  p_identifier text -- phone number, email, or exact customer name
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
  v_clean_phone text;
  v_clean_email text;
  v_clean_name text;
BEGIN
  -- Normalize identifier
  v_clean_phone := regexp_replace(coalesce(p_identifier, ''), '\D', '', 'g');
  v_clean_email := lower(trim(coalesce(p_identifier, '')));
  v_clean_name  := trim(coalesce(p_identifier, ''));

  -- Anonymize matching orders
  UPDATE orders
  SET
    customer_name = 'Customer [Anonymized]',
    customer_whatsapp = NULL,
    customer_email = NULL,
    anonymized_at = now()
  WHERE shop_id = p_shop
    AND (
      (length(v_clean_phone) >= 10 AND customer_whatsapp LIKE '%' || right(v_clean_phone, 10))
      OR (v_clean_email LIKE '%@%' AND lower(customer_email) = v_clean_email)
      OR (lower(customer_name) = lower(v_clean_name))
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Anonymize or remove from order_customers directory
  UPDATE order_customers
  SET
    name = 'Customer [Anonymized]',
    whatsapp = NULL,
    email = NULL,
    address = NULL,
    anonymized_at = now()
  WHERE shop_id = p_shop
    AND (
      (length(v_clean_phone) >= 10 AND whatsapp LIKE '%' || right(v_clean_phone, 10))
      OR (v_clean_email LIKE '%@%' AND lower(email) = v_clean_email)
      OR (lower(name) = lower(v_clean_name))
    );

  RETURN v_count;
END;
$$;
