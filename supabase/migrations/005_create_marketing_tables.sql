-- Migration: 005_create_marketing_tables.sql
-- Phase 2.1 of the Central Marketing Dashboard plan.
-- Owner: Steve / Anchor (review), Cleo (apply).
-- Source plan: /Hermes/central-marketing-dashboard-plan-v2-2026-06-24.md
--
-- Run order: AFTER 004_create_marketing_schema.sql has been applied.
-- Apply via: Supabase dashboard SQL editor at
--   https://supabase.com/dashboard/project/hupiguhcsmeucownlbre/sql
-- Verify:  \dt marketing.*
--
-- v1: SendPilot + Zernio + team_members + ingestion telemetry + daily rollups.
-- No direct LinkedIn / Meta / X API in v1 (Zernio is the source for socials).

BEGIN;

-- ============================================================================
-- 1. Enums
-- ============================================================================

CREATE TYPE marketing.zernio_platform AS ENUM (
  'linkedin_personal',
  'linkedin_org',
  'instagram',
  'facebook'
);

CREATE TYPE marketing.team_role AS ENUM (
  'super_admin',
  'admin',
  'editor',
  'viewer'
);

CREATE TYPE marketing.ingestion_status AS ENUM (
  'running',
  'success',
  'error'
);

-- ============================================================================
-- 2. SendPilot tables
-- ============================================================================

CREATE TABLE marketing.sendpilot_conversations (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  external_id              text UNIQUE NOT NULL,
  account_id               text,
  lead_linkedin_id         text,
  lead_name                text,
  lead_profile_url         text,
  lead_profile_picture     text,
  last_message_content     text,
  last_message_sent_at     timestamptz,
  last_message_direction   text CHECK (last_message_direction IN ('sent', 'received')),
  last_activity_at         timestamptz,
  unread_count             integer NOT NULL DEFAULT 0,
  created_at               timestamptz NOT NULL,
  updated_at               timestamptz NOT NULL,
  last_synced_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sp_conv_external_id    ON marketing.sendpilot_conversations (external_id);
CREATE INDEX idx_sp_conv_last_activity  ON marketing.sendpilot_conversations (last_activity_at DESC);
CREATE INDEX idx_sp_conv_lead           ON marketing.sendpilot_conversations (lead_linkedin_id);

CREATE TABLE marketing.sendpilot_messages (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sendpilot_message_id     text UNIQUE NOT NULL,
  conversation_id          uuid NOT NULL REFERENCES marketing.sendpilot_conversations (id) ON DELETE CASCADE,
  direction                text NOT NULL CHECK (direction IN ('sent', 'received')),
  body                     text,
  sent_at                  timestamptz NOT NULL,
  last_synced_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sp_msg_conv  ON marketing.sendpilot_messages (conversation_id, sent_at DESC);
CREATE INDEX idx_sp_msg_sent  ON marketing.sendpilot_messages (sent_at DESC);

CREATE TABLE marketing.sendpilot_campaigns (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  external_id              text UNIQUE NOT NULL,
  name                     text NOT NULL,
  status                   text NOT NULL,
  total_leads              integer NOT NULL DEFAULT 0,
  connections_sent         integer NOT NULL DEFAULT 0,
  messages_sent            integer NOT NULL DEFAULT 0,
  replies_received         integer NOT NULL DEFAULT 0,
  created_at               timestamptz NOT NULL,
  updated_at               timestamptz NOT NULL,
  last_synced_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sp_camp_external  ON marketing.sendpilot_campaigns (external_id);
CREATE INDEX idx_sp_camp_status    ON marketing.sendpilot_campaigns (status);

CREATE TABLE marketing.sendpilot_leads (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  external_id              text UNIQUE NOT NULL,
  campaign_id              uuid NOT NULL REFERENCES marketing.sendpilot_campaigns (id) ON DELETE CASCADE,
  linkedin_url             text,
  first_name               text,
  last_name                text,
  email                    text,
  company                  text,
  title                    text,
  status                   text NOT NULL,
  created_at               timestamptz NOT NULL,
  updated_at               timestamptz NOT NULL,
  last_synced_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sp_leads_campaign  ON marketing.sendpilot_leads (campaign_id);
CREATE INDEX idx_sp_leads_status    ON marketing.sendpilot_leads (status);

-- ============================================================================
-- 3. Zernio tables
-- ============================================================================

CREATE TABLE marketing.zernio_posts (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  external_post_id         text NOT NULL,
  platform                 marketing.zernio_platform NOT NULL,
  account_external_id      text NOT NULL,
  account_display_name     text,
  content                  text,
  media_urls               text[],
  status                   text NOT NULL,
  scheduled_for            timestamptz,
  published_at             timestamptz,
  created_at               timestamptz NOT NULL,
  updated_at               timestamptz NOT NULL,
  last_synced_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (platform, external_post_id)
);

CREATE INDEX idx_zernio_posts_platform   ON marketing.zernio_posts (platform);
CREATE INDEX idx_zernio_posts_published  ON marketing.zernio_posts (published_at DESC);
CREATE INDEX idx_zernio_posts_status     ON marketing.zernio_posts (status);

-- ============================================================================
-- 4. Team & access control
-- ============================================================================

CREATE TABLE marketing.team_members (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                  uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  email                    text NOT NULL,
  role                     marketing.team_role NOT NULL DEFAULT 'viewer',
  invited_at               timestamptz NOT NULL DEFAULT now(),
  joined_at                timestamptz,
  invited_by               uuid REFERENCES auth.users (id),
  UNIQUE (user_id)
);

CREATE INDEX idx_team_members_user  ON marketing.team_members (user_id);
CREATE INDEX idx_team_members_role  ON marketing.team_members (role);

-- ============================================================================
-- 5. Ingestion telemetry
-- ============================================================================

CREATE TABLE marketing.dashboard_ingestion_runs (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source                   text NOT NULL,
  started_at               timestamptz NOT NULL DEFAULT now(),
  finished_at              timestamptz,
  status                   marketing.ingestion_status NOT NULL DEFAULT 'running',
  records_written          integer NOT NULL DEFAULT 0,
  error                    text
);

CREATE INDEX idx_ingestion_runs_source  ON marketing.dashboard_ingestion_runs (source, started_at DESC);
CREATE INDEX idx_ingestion_runs_status  ON marketing.dashboard_ingestion_runs (status);

-- ============================================================================
-- 6. Pre-aggregated daily metrics (populated by ingestion scripts)
-- ============================================================================
-- This is a regular table, not a view, so viewers can read it via RLS without
-- needing SELECT on the underlying source tables.

CREATE TABLE marketing.daily_metrics (
  date                     date NOT NULL,
  source                   text NOT NULL,
  metric_name              text NOT NULL,
  value                    numeric NOT NULL DEFAULT 0,
  updated_at               timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (date, source, metric_name)
);

CREATE INDEX idx_daily_metrics_date  ON marketing.daily_metrics (date DESC);

-- ============================================================================
-- 7. RLS — enable on every table
-- ============================================================================

ALTER TABLE marketing.sendpilot_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.sendpilot_messages    ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.sendpilot_campaigns    ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.sendpilot_leads       ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.zernio_posts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.team_members          ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.dashboard_ingestion_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.daily_metrics         ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- Helper: a SECURITY DEFINER function so policies don't recurse on team_members.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION marketing.current_user_role()
RETURNS marketing.team_role
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = marketing, public
AS $$
  SELECT role
  FROM marketing.team_members
  WHERE user_id = auth.uid()
  LIMIT 1;
$$;

-- ----------------------------------------------------------------------------
-- Source-table policies: editor and above can SELECT; service role bypasses RLS
-- for INSERT/UPDATE/DELETE (no policy for those roles on these tables).
-- ----------------------------------------------------------------------------

CREATE POLICY "sp_conv_read_team"
  ON marketing.sendpilot_conversations FOR SELECT
  TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "sp_msg_read_team"
  ON marketing.sendpilot_messages FOR SELECT
  TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "sp_camp_read_team"
  ON marketing.sendpilot_campaigns FOR SELECT
  TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "sp_leads_read_team"
  ON marketing.sendpilot_leads FOR SELECT
  TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "zernio_read_team"
  ON marketing.zernio_posts FOR SELECT
  TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

-- ----------------------------------------------------------------------------
-- Ingestion telemetry: editor and above.
-- ----------------------------------------------------------------------------

CREATE POLICY "ingestion_runs_read_team"
  ON marketing.dashboard_ingestion_runs FOR SELECT
  TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

-- ----------------------------------------------------------------------------
-- Daily metrics: ALL roles including viewer (this is the v1 viewer surface).
-- ----------------------------------------------------------------------------

CREATE POLICY "daily_metrics_read_all_roles"
  ON marketing.daily_metrics FOR SELECT
  TO authenticated
  USING (marketing.current_user_role() IS NOT NULL);

-- ----------------------------------------------------------------------------
-- Team members: self-read for everyone; admin/super_admin sees all;
-- super_admin can write.
-- ----------------------------------------------------------------------------

CREATE POLICY "team_members_self_read"
  ON marketing.team_members FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "team_members_admin_read"
  ON marketing.team_members FOR SELECT
  TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin'));

CREATE POLICY "team_members_super_admin_write"
  ON marketing.team_members FOR ALL
  TO authenticated
  USING (marketing.current_user_role() = 'super_admin')
  WITH CHECK (marketing.current_user_role() = 'super_admin');

-- ============================================================================
-- 8. Grants for service role (the ingestion scripts use service_role key)
-- ============================================================================

GRANT USAGE ON SCHEMA marketing TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA marketing TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA marketing TO service_role;

-- ============================================================================
-- 9. Seed: Derrick as super_admin (idempotent)
-- ============================================================================

INSERT INTO marketing.team_members (user_id, email, role, invited_at, joined_at)
SELECT id, email, 'super_admin'::marketing.team_role, now(), now()
FROM auth.users
WHERE email = 'dmcmichael@loudmusic.io'
ON CONFLICT (user_id) DO NOTHING;

-- If Derrick's auth.users row doesn't exist yet (no first login), the seed
-- silently skips. Once he signs in for the first time, run:
--   INSERT INTO marketing.team_members (user_id, email, role, invited_at, joined_at)
--   SELECT id, email, 'super_admin', now(), now() FROM auth.users
--   WHERE email = 'dmcmichael@loudmusic.io'
--   ON CONFLICT (user_id) DO UPDATE SET role = 'super_admin';

-- ============================================================================
-- 10. View helpers for the dashboard (so the front-end never reads raw tables)
-- ============================================================================

-- Conversation summary (one row per conversation with computed reply flag)
CREATE OR REPLACE VIEW marketing.v_conversation_summary AS
SELECT
  c.id,
  c.external_id,
  c.lead_name,
  c.lead_profile_url,
  c.last_message_direction,
  c.last_message_content,
  c.last_activity_at,
  c.unread_count,
  COALESCE(rm.reply_count, 0) AS total_replies,
  COALESCE(sm.sent_count, 0)  AS total_sent
FROM marketing.sendpilot_conversations c
LEFT JOIN (
  SELECT conversation_id, count(*) AS reply_count
  FROM marketing.sendpilot_messages
  WHERE direction = 'received'
  GROUP BY conversation_id
) rm ON rm.conversation_id = c.id
LEFT JOIN (
  SELECT conversation_id, count(*) AS sent_count
  FROM marketing.sendpilot_messages
  WHERE direction = 'sent'
  GROUP BY conversation_id
) sm ON sm.conversation_id = c.id;

GRANT SELECT ON marketing.v_conversation_summary TO authenticated;

-- Recent ingestion run (one row per source) — used by the FreshnessIndicator
CREATE OR REPLACE VIEW marketing.v_latest_ingestion AS
SELECT DISTINCT ON (source)
  source,
  started_at,
  finished_at,
  status,
  records_written,
  error,
  EXTRACT(EPOCH FROM (now() - finished_at))::int AS seconds_since_finished
FROM marketing.dashboard_ingestion_runs
WHERE status IN ('success', 'error')
ORDER BY source, finished_at DESC;

GRANT SELECT ON marketing.v_latest_ingestion TO authenticated;

-- ============================================================================
-- 11. Storage budget guard (optional but cheap)
-- ============================================================================
-- Supabase free tier is 500 MB. Add a function that estimates current usage
-- of the marketing schema. Call periodically; if > 400 MB, archive to a cold
-- `marketing_archive` schema (out of scope for v1).

CREATE OR REPLACE FUNCTION marketing.schema_size_estimate_mb()
RETURNS numeric
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT pg_total_relation_size('marketing.sendpilot_conversations')
       + pg_total_relation_size('marketing.sendpilot_messages')
       + pg_total_relation_size('marketing.sendpilot_campaigns')
       + pg_total_relation_size('marketing.sendpilot_leads')
       + pg_total_relation_size('marketing.zernio_posts')
       + pg_total_relation_size('marketing.dashboard_ingestion_runs')
       + pg_total_relation_size('marketing.daily_metrics')
       + pg_total_relation_size('marketing.team_members') AS bytes
$$;

COMMIT;

-- ============================================================================
-- Post-apply verification (run after the migration completes):
-- ============================================================================
-- \dt marketing.*             -- should list 8 tables
-- SELECT count(*) FROM marketing.team_members;   -- 0 or 1 (Derrick if he's logged in)
-- SELECT * FROM marketing.v_latest_ingestion;    -- empty until first run
-- SELECT marketing.schema_size_estimate_mb();    -- small number, < 1 MB initially
