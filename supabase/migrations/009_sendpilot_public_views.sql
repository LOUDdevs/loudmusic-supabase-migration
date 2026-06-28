-- Migration: 009_sendpilot_public_views.sql
-- Expose new workflow tables via public views (PostgREST pattern used by existing sendpilot_* views).

BEGIN;

CREATE OR REPLACE VIEW public.sendpilot_drafts AS
  SELECT * FROM marketing.sendpilot_drafts;

CREATE OR REPLACE VIEW public.sendpilot_outbound_messages AS
  SELECT * FROM marketing.sendpilot_outbound_messages;

CREATE OR REPLACE VIEW public.sendpilot_conversation_state AS
  SELECT * FROM marketing.sendpilot_conversation_state;

CREATE OR REPLACE VIEW public.service_audit_log AS
  SELECT * FROM marketing.service_audit_log;

CREATE OR REPLACE VIEW public.service_ai_jobs AS
  SELECT * FROM marketing.service_ai_jobs;

CREATE OR REPLACE VIEW public.sendpilot_inbox_enriched AS
  SELECT * FROM marketing.sendpilot_inbox_enriched;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.sendpilot_drafts TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sendpilot_outbound_messages TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sendpilot_conversation_state TO anon, authenticated, service_role;
GRANT SELECT, INSERT ON public.service_audit_log TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.service_ai_jobs TO anon, authenticated, service_role;
GRANT SELECT ON public.sendpilot_inbox_enriched TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
