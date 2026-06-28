-- Migration: 010_expose_core_marketing_views.sql
-- Expose core marketing tables via public views (PostgREST / supabase-js pattern).
-- Run AFTER 005_create_marketing_tables.sql and 009_sendpilot_public_views.sql.

BEGIN;

CREATE OR REPLACE VIEW public.sendpilot_conversations AS
  SELECT * FROM marketing.sendpilot_conversations;

CREATE OR REPLACE VIEW public.sendpilot_messages AS
  SELECT * FROM marketing.sendpilot_messages;

CREATE OR REPLACE VIEW public.sendpilot_campaigns AS
  SELECT * FROM marketing.sendpilot_campaigns;

CREATE OR REPLACE VIEW public.sendpilot_leads AS
  SELECT * FROM marketing.sendpilot_leads;

CREATE OR REPLACE VIEW public.zernio_posts AS
  SELECT * FROM marketing.zernio_posts;

CREATE OR REPLACE VIEW public.zernio_accounts AS
  SELECT * FROM marketing.zernio_accounts;

GRANT SELECT ON public.sendpilot_conversations TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sendpilot_messages TO anon, authenticated, service_role;
GRANT SELECT ON public.sendpilot_campaigns TO anon, authenticated, service_role;
GRANT SELECT ON public.sendpilot_leads TO anon, authenticated, service_role;
GRANT SELECT ON public.zernio_posts TO anon, authenticated, service_role;
GRANT SELECT ON public.zernio_accounts TO anon, authenticated, service_role;

GRANT INSERT, UPDATE, DELETE ON public.sendpilot_conversations TO service_role;
GRANT INSERT, UPDATE, DELETE ON public.sendpilot_campaigns TO service_role;
GRANT INSERT, UPDATE, DELETE ON public.sendpilot_leads TO service_role;
GRANT INSERT, UPDATE, DELETE ON public.zernio_posts TO service_role;
GRANT INSERT, UPDATE, DELETE ON public.zernio_accounts TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
