-- Migration: 020_refresh_sendpilot_leads_view.sql
-- PostgREST views with SELECT * do not pick up new columns on REPLACE; recreate.

BEGIN;

DROP VIEW IF EXISTS public.sendpilot_leads CASCADE;
CREATE VIEW public.sendpilot_leads AS
  SELECT * FROM marketing.sendpilot_leads;

GRANT SELECT ON public.sendpilot_leads TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON public.sendpilot_leads TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
