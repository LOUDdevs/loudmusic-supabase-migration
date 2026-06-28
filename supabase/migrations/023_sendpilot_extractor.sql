-- Migration: 023_sendpilot_extractor.sql
-- Lead Extractor campaign registry + structured lead columns.

BEGIN;

ALTER TABLE marketing.sendpilot_campaigns
  ADD COLUMN IF NOT EXISTS campaign_type text NOT NULL DEFAULT 'outreach',
  ADD COLUMN IF NOT EXISTS extractor_progress jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS marketing.sendpilot_extractor_campaigns (
  external_id text PRIMARY KEY,
  name text,
  status text,
  progress jsonb NOT NULL DEFAULT '{}'::jsonb,
  sendpilot_campaign_id uuid REFERENCES marketing.sendpilot_campaigns (id) ON DELETE SET NULL,
  last_results_sync_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE marketing.sendpilot_leads
  ADD COLUMN IF NOT EXISTS linkedin_identifier text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS experience jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS education jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS skills jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS lead_source text NOT NULL DEFAULT 'outreach';

CREATE INDEX IF NOT EXISTS idx_sp_leads_lead_source
  ON marketing.sendpilot_leads (lead_source);

CREATE INDEX IF NOT EXISTS idx_sp_leads_linkedin_identifier
  ON marketing.sendpilot_leads (linkedin_identifier)
  WHERE linkedin_identifier IS NOT NULL;

ALTER TABLE marketing.sendpilot_extractor_campaigns ENABLE ROW LEVEL SECURITY;

CREATE POLICY "extractor_campaigns_read_team"
  ON marketing.sendpilot_extractor_campaigns FOR SELECT
  TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

DROP VIEW IF EXISTS public.sendpilot_campaigns CASCADE;
CREATE VIEW public.sendpilot_campaigns AS
  SELECT * FROM marketing.sendpilot_campaigns;

DROP VIEW IF EXISTS public.sendpilot_leads CASCADE;
CREATE VIEW public.sendpilot_leads AS
  SELECT * FROM marketing.sendpilot_leads;

DROP VIEW IF EXISTS public.sendpilot_extractor_campaigns CASCADE;
CREATE VIEW public.sendpilot_extractor_campaigns AS
  SELECT * FROM marketing.sendpilot_extractor_campaigns;

GRANT SELECT ON public.sendpilot_campaigns TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON public.sendpilot_campaigns TO service_role;

GRANT SELECT ON public.sendpilot_leads TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON public.sendpilot_leads TO service_role;

GRANT SELECT ON public.sendpilot_extractor_campaigns TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON public.sendpilot_extractor_campaigns TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
