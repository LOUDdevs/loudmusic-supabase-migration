-- Migration: 004_create_marketing_schema.sql
-- Phase 0 task 0.3 of the Central Marketing Dashboard plan.
-- Owner: Cleo (2026-06-24). See /Hermes/central-marketing-dashboard-plan-2026-06-24_222954.md.
-- Purpose: Create the `marketing` schema namespace. Tables are added in Phase 2.1.

CREATE SCHEMA IF NOT EXISTS marketing;

COMMENT ON SCHEMA marketing IS
  'Central Marketing Dashboard — aggregates data from SendPilot, Zernio, LinkedIn, and future channels. See /Hermes/central-marketing-dashboard-plan-2026-06-24_222954.md.';

-- Grant usage to the roles that will read/write from this schema.
-- Service role writes; authenticated users read (RLS controls row-level access in Phase 2.1).
GRANT USAGE ON SCHEMA marketing TO authenticated, service_role;
GRANT USAGE, CREATE ON SCHEMA marketing TO service_role;
