-- Migration: 008_sendpilot_workflow_tables.sql
-- SendPilot messaging workflow: drafts, outbound queue, conversation state, audit, AI jobs.
-- Run AFTER 005_create_marketing_tables.sql.

BEGIN;

-- ============================================================================
-- 1. Enums
-- ============================================================================

CREATE TYPE marketing.outbound_message_status AS ENUM (
  'pending',
  'sending',
  'sent',
  'failed'
);

CREATE TYPE marketing.draft_status AS ENUM (
  'draft',
  'ready_to_send',
  'discarded'
);

CREATE TYPE marketing.ai_job_status AS ENUM (
  'pending',
  'processing',
  'done',
  'failed'
);

-- ============================================================================
-- 2. Workflow tables
-- ============================================================================

CREATE TABLE marketing.sendpilot_drafts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id   uuid NOT NULL REFERENCES marketing.sendpilot_conversations (id) ON DELETE CASCADE,
  body              text NOT NULL,
  status            marketing.draft_status NOT NULL DEFAULT 'draft',
  ai_assisted       boolean NOT NULL DEFAULT false,
  edited_after_ai   boolean NOT NULL DEFAULT false,
  created_by        uuid REFERENCES auth.users (id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_sp_drafts_conv ON marketing.sendpilot_drafts (conversation_id);
CREATE INDEX idx_sp_drafts_status ON marketing.sendpilot_drafts (status);

CREATE TABLE marketing.sendpilot_outbound_messages (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id   uuid NOT NULL REFERENCES marketing.sendpilot_conversations (id) ON DELETE CASCADE,
  draft_id          uuid REFERENCES marketing.sendpilot_drafts (id) ON DELETE SET NULL,
  body              text NOT NULL,
  status            marketing.outbound_message_status NOT NULL DEFAULT 'pending',
  idempotency_key   text UNIQUE NOT NULL,
  sendpilot_message_id text,
  failure_reason    text,
  ai_assisted       boolean NOT NULL DEFAULT false,
  edited_after_ai   boolean NOT NULL DEFAULT false,
  created_by        uuid REFERENCES auth.users (id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  sent_at           timestamptz
);

CREATE INDEX idx_sp_outbound_conv ON marketing.sendpilot_outbound_messages (conversation_id);
CREATE INDEX idx_sp_outbound_status ON marketing.sendpilot_outbound_messages (status);

CREATE TABLE marketing.sendpilot_conversation_state (
  conversation_id   uuid PRIMARY KEY REFERENCES marketing.sendpilot_conversations (id) ON DELETE CASCADE,
  archived          boolean NOT NULL DEFAULT false,
  completed         boolean NOT NULL DEFAULT false,
  tags              text[] NOT NULL DEFAULT '{}',
  priority          integer NOT NULL DEFAULT 0,
  assigned_user_id  uuid REFERENCES auth.users (id),
  notes             text,
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE marketing.service_audit_log (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service           text NOT NULL,
  action            text NOT NULL,
  actor_user_id     uuid REFERENCES auth.users (id),
  conversation_id   uuid,
  recipient_ref     text,
  message_ref       text,
  payload           jsonb,
  ai_assisted       boolean NOT NULL DEFAULT false,
  edited_after_ai   boolean NOT NULL DEFAULT false,
  idempotency_key   text,
  provider_status   text,
  error             text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_service ON marketing.service_audit_log (service, created_at DESC);
CREATE INDEX idx_audit_conv ON marketing.service_audit_log (conversation_id, created_at DESC);

CREATE TABLE marketing.service_ai_jobs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service           text NOT NULL DEFAULT 'sendpilot',
  task_type         text NOT NULL,
  status            marketing.ai_job_status NOT NULL DEFAULT 'pending',
  conversation_id   uuid,
  input_json        jsonb NOT NULL DEFAULT '{}',
  output_json       jsonb,
  error             text,
  created_by        uuid REFERENCES auth.users (id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  started_at        timestamptz,
  finished_at       timestamptz
);

CREATE INDEX idx_ai_jobs_pending ON marketing.service_ai_jobs (status, created_at)
  WHERE status = 'pending';

-- ============================================================================
-- 3. Enriched inbox view
-- ============================================================================

CREATE OR REPLACE VIEW marketing.sendpilot_inbox_enriched AS
SELECT
  c.id,
  c.external_id,
  c.account_id,
  c.lead_linkedin_id,
  c.lead_name,
  c.lead_profile_url,
  c.lead_profile_picture,
  c.last_message_content,
  c.last_message_sent_at,
  c.last_message_direction,
  c.last_activity_at,
  c.unread_count,
  c.last_synced_at,
  l.id AS lead_id,
  l.external_id AS lead_external_id,
  l.company AS lead_company,
  l.title AS lead_title,
  l.linkedin_url AS lead_linkedin_url,
  l.status AS lead_status,
  camp.id AS campaign_id,
  camp.name AS campaign_name,
  COALESCE(cs.archived, false) AS archived,
  COALESCE(cs.completed, false) AS completed,
  COALESCE(cs.tags, '{}'::text[]) AS tags,
  COALESCE(cs.priority, 0) AS priority,
  cs.notes,
  EXISTS (
    SELECT 1 FROM marketing.sendpilot_drafts d
    WHERE d.conversation_id = c.id AND d.status = 'draft'
  ) AS has_draft,
  EXISTS (
    SELECT 1 FROM marketing.sendpilot_outbound_messages o
    WHERE o.conversation_id = c.id AND o.status = 'failed'
  ) AS has_failed_send
FROM marketing.sendpilot_conversations c
LEFT JOIN marketing.sendpilot_leads l
  ON l.linkedin_url IS NOT NULL
  AND c.lead_profile_url IS NOT NULL
  AND l.linkedin_url = c.lead_profile_url
LEFT JOIN marketing.sendpilot_campaigns camp ON camp.id = l.campaign_id
LEFT JOIN marketing.sendpilot_conversation_state cs ON cs.conversation_id = c.id;

-- ============================================================================
-- 4. RLS
-- ============================================================================

ALTER TABLE marketing.sendpilot_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.sendpilot_outbound_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.sendpilot_conversation_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.service_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.service_ai_jobs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sp_drafts_read_team"
  ON marketing.sendpilot_drafts FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

CREATE POLICY "sp_drafts_write_editor"
  ON marketing.sendpilot_drafts FOR ALL TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'))
  WITH CHECK (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "sp_outbound_read_team"
  ON marketing.sendpilot_outbound_messages FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

CREATE POLICY "sp_outbound_write_editor"
  ON marketing.sendpilot_outbound_messages FOR ALL TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'))
  WITH CHECK (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "sp_conv_state_read_team"
  ON marketing.sendpilot_conversation_state FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

CREATE POLICY "sp_conv_state_write_editor"
  ON marketing.sendpilot_conversation_state FOR ALL TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'))
  WITH CHECK (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "audit_read_team"
  ON marketing.service_audit_log FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

CREATE POLICY "audit_write_editor"
  ON marketing.service_audit_log FOR INSERT TO authenticated
  WITH CHECK (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "ai_jobs_read_team"
  ON marketing.service_ai_jobs FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

CREATE POLICY "ai_jobs_write_editor"
  ON marketing.service_ai_jobs FOR ALL TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'))
  WITH CHECK (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

COMMIT;
