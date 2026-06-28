-- Migration: 025_expose_crm_sync_extractor.sql
-- Expose extractor CRM sync RPC to PostgREST (same pattern as crm_sync_from_sendpilot).

BEGIN;

CREATE OR REPLACE FUNCTION public.crm_sync_extractor_leads()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT marketing.crm_sync_extractor_leads();
$$;

GRANT EXECUTE ON FUNCTION public.crm_sync_extractor_leads() TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
