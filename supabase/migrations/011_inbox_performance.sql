-- Migration: 011_inbox_performance.sql
-- Denormalize inbox flags on conversations, precomputed stats snapshot,
-- SQL refresh functions, and faster enriched inbox view.
-- Run AFTER 008_sendpilot_workflow_tables.sql and 010_expose_core_marketing_views.sql.

BEGIN;

-- ============================================================================
-- 1. Denormalized columns on conversations
-- ============================================================================

ALTER TABLE marketing.sendpilot_conversations
  ADD COLUMN IF NOT EXISTS has_draft boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS has_failed_send boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS needs_reply boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS awaiting_response boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS archived boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS completed boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS lead_company text,
  ADD COLUMN IF NOT EXISTS lead_title text,
  ADD COLUMN IF NOT EXISTS campaign_id uuid REFERENCES marketing.sendpilot_campaigns (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS campaign_name text;

-- ============================================================================
-- 2. Singleton inbox stats (O(1) metrics reads)
-- ============================================================================

CREATE TABLE IF NOT EXISTS marketing.dashboard_inbox_stats (
  id              text PRIMARY KEY DEFAULT 'current',
  total           integer NOT NULL DEFAULT 0,
  unread          integer NOT NULL DEFAULT 0,
  needs_reply     integer NOT NULL DEFAULT 0,
  awaiting_response integer NOT NULL DEFAULT 0,
  drafts          integer NOT NULL DEFAULT 0,
  failed          integer NOT NULL DEFAULT 0,
  archived        integer NOT NULL DEFAULT 0,
  completed       integer NOT NULL DEFAULT 0,
  action_needed   integer NOT NULL DEFAULT 0,
  last_sync_at    timestamptz,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE marketing.dashboard_inbox_stats ENABLE ROW LEVEL SECURITY;

CREATE POLICY "inbox_stats_read_team"
  ON marketing.dashboard_inbox_stats FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

-- ============================================================================
-- 3. Refresh functions
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.refresh_conversation_inbox_flags(p_conversation_id uuid DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
BEGIN
  UPDATE marketing.sendpilot_conversations c
  SET
    has_draft = EXISTS (
      SELECT 1 FROM marketing.sendpilot_drafts d
      WHERE d.conversation_id = c.id AND d.status = 'draft'
    ),
    has_failed_send = EXISTS (
      SELECT 1 FROM marketing.sendpilot_outbound_messages o
      WHERE o.conversation_id = c.id AND o.status = 'failed'
    ),
    archived = COALESCE((
      SELECT cs.archived FROM marketing.sendpilot_conversation_state cs
      WHERE cs.conversation_id = c.id
    ), false),
    completed = COALESCE((
      SELECT cs.completed FROM marketing.sendpilot_conversation_state cs
      WHERE cs.conversation_id = c.id
    ), false),
    lead_company = sub.lead_company,
    lead_title = sub.lead_title,
    campaign_id = sub.campaign_id,
    campaign_name = sub.campaign_name
  FROM (
    SELECT
      c2.id AS conversation_id,
      l.company AS lead_company,
      l.title AS lead_title,
      camp.id AS campaign_id,
      camp.name AS campaign_name
    FROM marketing.sendpilot_conversations c2
    LEFT JOIN marketing.sendpilot_leads l
      ON l.linkedin_url IS NOT NULL
      AND c2.lead_profile_url IS NOT NULL
      AND l.linkedin_url = c2.lead_profile_url
    LEFT JOIN marketing.sendpilot_campaigns camp ON camp.id = l.campaign_id
    WHERE p_conversation_id IS NULL OR c2.id = p_conversation_id
  ) sub
  WHERE c.id = sub.conversation_id
    AND (p_conversation_id IS NULL OR c.id = p_conversation_id);

  UPDATE marketing.sendpilot_conversations c
  SET
    needs_reply = (
      NOT c.archived
      AND NOT c.completed
      AND c.last_message_direction = 'received'
      AND NOT c.has_draft
    ),
    awaiting_response = (
      NOT c.archived
      AND NOT c.completed
      AND c.last_message_direction = 'sent'
    )
  WHERE p_conversation_id IS NULL OR c.id = p_conversation_id;
END;
$$;

CREATE OR REPLACE FUNCTION marketing.refresh_inbox_stats()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
DECLARE
  v_drafts integer;
  v_last_sync timestamptz;
BEGIN
  SELECT count(*)::integer INTO v_drafts
  FROM marketing.sendpilot_drafts
  WHERE status = 'draft';

  SELECT max(last_synced_at) INTO v_last_sync
  FROM marketing.sendpilot_conversations;

  INSERT INTO marketing.dashboard_inbox_stats (
    id, total, unread, needs_reply, awaiting_response,
    drafts, failed, archived, completed, action_needed,
    last_sync_at, updated_at
  )
  SELECT
    'current',
    count(*)::integer,
    count(*) FILTER (WHERE unread_count > 0)::integer,
    count(*) FILTER (WHERE needs_reply)::integer,
    count(*) FILTER (WHERE awaiting_response)::integer,
    v_drafts,
    count(*) FILTER (WHERE has_failed_send)::integer,
    count(*) FILTER (WHERE archived)::integer,
    count(*) FILTER (WHERE completed)::integer,
    count(*) FILTER (WHERE unread_count > 0 OR needs_reply OR has_failed_send)::integer,
    v_last_sync,
    now()
  FROM marketing.sendpilot_conversations
  ON CONFLICT (id) DO UPDATE SET
    total = EXCLUDED.total,
    unread = EXCLUDED.unread,
    needs_reply = EXCLUDED.needs_reply,
    awaiting_response = EXCLUDED.awaiting_response,
    drafts = EXCLUDED.drafts,
    failed = EXCLUDED.failed,
    archived = EXCLUDED.archived,
    completed = EXCLUDED.completed,
    action_needed = EXCLUDED.action_needed,
    last_sync_at = EXCLUDED.last_sync_at,
    updated_at = EXCLUDED.updated_at;
END;
$$;

-- Public RPC wrappers for PostgREST / supabase-js
CREATE OR REPLACE FUNCTION public.refresh_conversation_inbox_flags(p_conversation_id uuid DEFAULT NULL)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT marketing.refresh_conversation_inbox_flags(p_conversation_id);
$$;

CREATE OR REPLACE FUNCTION public.refresh_inbox_stats()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT marketing.refresh_inbox_stats();
$$;

GRANT EXECUTE ON FUNCTION public.refresh_conversation_inbox_flags(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.refresh_inbox_stats() TO service_role;

-- ============================================================================
-- 4. Rewrite enriched inbox view (no EXISTS subqueries)
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
  COALESCE(l.id, NULL::uuid) AS lead_id,
  l.external_id AS lead_external_id,
  COALESCE(c.lead_company, l.company) AS lead_company,
  COALESCE(c.lead_title, l.title) AS lead_title,
  l.linkedin_url AS lead_linkedin_url,
  l.status AS lead_status,
  COALESCE(c.campaign_id, camp.id) AS campaign_id,
  COALESCE(c.campaign_name, camp.name) AS campaign_name,
  c.archived,
  c.completed,
  COALESCE(cs.tags, '{}'::text[]) AS tags,
  COALESCE(cs.priority, 0) AS priority,
  cs.notes,
  c.has_draft,
  c.has_failed_send,
  c.needs_reply,
  c.awaiting_response
FROM marketing.sendpilot_conversations c
LEFT JOIN marketing.sendpilot_leads l
  ON l.linkedin_url IS NOT NULL
  AND c.lead_profile_url IS NOT NULL
  AND l.linkedin_url = c.lead_profile_url
LEFT JOIN marketing.sendpilot_campaigns camp ON camp.id = l.campaign_id
LEFT JOIN marketing.sendpilot_conversation_state cs ON cs.conversation_id = c.id;

-- Recreate public view (010 used SELECT * which picks up new columns automatically,
-- but inbox_enriched is defined in 009 — replace explicitly)
CREATE OR REPLACE VIEW public.sendpilot_inbox_enriched AS
  SELECT * FROM marketing.sendpilot_inbox_enriched;

CREATE OR REPLACE VIEW public.sendpilot_conversations AS
  SELECT * FROM marketing.sendpilot_conversations;

CREATE OR REPLACE VIEW public.dashboard_inbox_stats AS
  SELECT * FROM marketing.dashboard_inbox_stats;

GRANT SELECT ON public.dashboard_inbox_stats TO anon, authenticated, service_role;

-- ============================================================================
-- 5. Indexes for filtered inbox queries
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_sp_conv_inbox_list
  ON marketing.sendpilot_conversations (last_activity_at DESC);

CREATE INDEX IF NOT EXISTS idx_sp_conv_unread
  ON marketing.sendpilot_conversations (unread_count DESC)
  WHERE unread_count > 0;

CREATE INDEX IF NOT EXISTS idx_sp_conv_needs_reply
  ON marketing.sendpilot_conversations (last_activity_at DESC)
  WHERE needs_reply;

CREATE INDEX IF NOT EXISTS idx_sp_conv_archived
  ON marketing.sendpilot_conversations (last_activity_at DESC)
  WHERE archived OR completed;

CREATE INDEX IF NOT EXISTS idx_sp_conv_has_draft
  ON marketing.sendpilot_conversations (last_activity_at DESC)
  WHERE has_draft;

CREATE INDEX IF NOT EXISTS idx_sp_conv_action_needed
  ON marketing.sendpilot_conversations (last_activity_at DESC)
  WHERE unread_count > 0 OR needs_reply OR has_failed_send;

-- ============================================================================
-- 6. Backfill
-- ============================================================================

SELECT marketing.refresh_conversation_inbox_flags();
SELECT marketing.refresh_inbox_stats();

NOTIFY pgrst, 'reload schema';

COMMIT;
