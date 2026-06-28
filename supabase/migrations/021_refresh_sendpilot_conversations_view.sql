-- Migration: 021_refresh_sendpilot_conversations_view.sql
-- lead_participant added in 014; industry on crm_contact_profiles in 018.
-- public views with SELECT * do not pick up new columns on REPLACE.

BEGIN;

DROP VIEW IF EXISTS public.sendpilot_conversations CASCADE;
CREATE VIEW public.sendpilot_conversations AS
  SELECT * FROM marketing.sendpilot_conversations;

GRANT SELECT ON public.sendpilot_conversations TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON public.sendpilot_conversations TO service_role;

DROP VIEW IF EXISTS public.crm_contact_profiles CASCADE;
CREATE VIEW public.crm_contact_profiles AS
  SELECT * FROM marketing.crm_contact_profiles;

GRANT SELECT ON public.crm_contact_profiles TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON public.crm_contact_profiles TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
