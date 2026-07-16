-- Migration: 046_sendpilot_meeting_state.sql
-- Extend sendpilot_conversation_state with per-conversation meeting-intel metadata
-- so the LinkedIn auto-draft cron can carry stage, synergy score, meeting proposals,
-- and last-draft reasoning across runs without creating a duplicate storage layer.
--
-- All columns are nullable / default to false so existing rows stay valid and the
-- ingestion path can fill them in incrementally. The state row is created on first
-- enqueue when absent; subsequent runs upsert.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Enums
-- ---------------------------------------------------------------------------

DO $$ BEGIN
  CREATE TYPE marketing.sendpilot_meeting_stage AS ENUM (
    'initial_connection',
    'discovery',
    'synergy_identified',
    'meeting_interest',
    'meeting_coordination',
    'meeting_booked',
    'not_qualified',
    'dormant'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Columns
-- ---------------------------------------------------------------------------

ALTER TABLE marketing.sendpilot_conversation_state
  ADD COLUMN IF NOT EXISTS conversation_stage       marketing.sendpilot_meeting_stage,
  ADD COLUMN IF NOT EXISTS synergy_score            smallint
    CHECK (synergy_score IS NULL OR synergy_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS meeting_intent_detected  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS meeting_proposed         boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS meeting_proposed_at      timestamptz,
  ADD COLUMN IF NOT EXISTS meeting_link_sent        boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS meeting_link_sent_at     timestamptz,
  ADD COLUMN IF NOT EXISTS recipient_requested_meeting  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS recipient_accepted_meeting   boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS meeting_booked           boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS calendar_event_id        uuid REFERENCES marketing.calendar_events (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS last_meaningful_question_at  timestamptz,
  ADD COLUMN IF NOT EXISTS number_of_discovery_questions  integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_draft_objective     text,
  ADD COLUMN IF NOT EXISTS last_draft_at            timestamptz,
  ADD COLUMN IF NOT EXISTS last_action_reason       text,
  ADD COLUMN IF NOT EXISTS next_recommended_action  text,
  ADD COLUMN IF NOT EXISTS last_confidence          numeric(3,2)
    CHECK (last_confidence IS NULL OR last_confidence BETWEEN 0 AND 1),
  ADD COLUMN IF NOT EXISTS last_classified_at       timestamptz;

-- ---------------------------------------------------------------------------
-- 3. Indexes
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_sp_conv_state_stage
  ON marketing.sendpilot_conversation_state (conversation_stage)
  WHERE conversation_stage IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sp_conv_state_meeting_proposed
  ON marketing.sendpilot_conversation_state (meeting_proposed, meeting_proposed_at DESC)
  WHERE meeting_proposed = true;

CREATE INDEX IF NOT EXISTS idx_sp_conv_state_meeting_booked
  ON marketing.sendpilot_conversation_state (meeting_booked, calendar_event_id)
  WHERE meeting_booked = true;

-- ---------------------------------------------------------------------------
-- 4. Refresh public view to expose new columns
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.sendpilot_conversation_state CASCADE;
CREATE VIEW public.sendpilot_conversation_state AS
  SELECT * FROM marketing.sendpilot_conversation_state;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.sendpilot_conversation_state
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Helpful RPC: stage rollup for dashboard
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sendpilot_meeting_stage_counts(p_account_id text)
RETURNS TABLE (stage text, count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT s.conversation_stage::text AS stage, count(*) AS count
  FROM marketing.sendpilot_conversation_state s
  JOIN marketing.sendpilot_conversations c ON c.id = s.conversation_id
  WHERE c.account_id = p_account_id
  GROUP BY s.conversation_stage
  ORDER BY s.conversation_stage;
$$;

GRANT EXECUTE ON FUNCTION public.sendpilot_meeting_stage_counts(text) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
