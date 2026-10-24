-- ==============================================================================
-- Migration: 0010_password_resets.sql
-- Description: Creates table for storing temporary password reset OTP tokens.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS password_reset_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  otp_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  used boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_password_reset_email ON password_reset_tokens (email, expires_at);

-- Enable RLS and restrict access strictly to service role
ALTER TABLE password_reset_tokens ENABLE ROW LEVEL SECURITY;
