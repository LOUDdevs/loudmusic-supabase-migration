-- Tighten SendPilot/LinkedIn needs-reply classification.
-- Short acknowledgements ("likewise", "thanks"), booking confirmations, and
-- empty inbound placeholders should not stay in Derrick's Needs Reply queue.

BEGIN;

CREATE OR REPLACE FUNCTION marketing.sendpilot_inbound_needs_reply(
  p_text text,
  p_meeting_booked boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  body text := lower(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g'));
BEGIN
  body := trim(body);

  IF coalesce(p_meeting_booked, false) THEN
    RETURN false;
  END IF;

  IF body = '' THEN
    RETURN false;
  END IF;

  IF body ~ '^(likewise|same here|you too|thanks|thank you|thx|appreciate it|sounds good|great|perfect|okay|ok|cool|got it|nice to connect)[.![:space:]]*$' THEN
    RETURN false;
  END IF;

  IF length(body) <= 120
     AND position('?' in body) = 0
     AND body ~ '\m(likewise|same here|you too|thanks|thank you|thx|appreciate it|sounds good|great|perfect|okay|ok|cool|got it|nice to connect)\M' THEN
    RETURN false;
  END IF;

  IF body ~ '\m(booked|i(''|’)?ve booked|i booked|on (my|the) calendar|see you (on|at|then)|looking forward to (speaking|chatting|talking|meeting|connecting)|that works for me)\M' THEN
    RETURN false;
  END IF;

  IF body ~ '\m(meeting|call) (is )?(booked|confirmed|scheduled)\M' THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

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
      SELECT 1
      FROM marketing.sendpilot_drafts d
      WHERE d.conversation_id = c.id
        AND d.status IN ('draft', 'ready_to_send')
    ),
    has_failed_send = EXISTS (
      SELECT 1
      FROM marketing.sendpilot_outbound_messages o
      WHERE o.conversation_id = c.id
        AND o.status = 'failed'
    )
  WHERE p_conversation_id IS NULL OR c.id = p_conversation_id;

  UPDATE marketing.sendpilot_conversations c
  SET
    needs_reply = (
      NOT c.archived
      AND NOT c.completed
      AND c.last_message_direction = 'received'
      AND NOT c.has_draft
      AND marketing.sendpilot_inbound_needs_reply(c.last_message_content, coalesce(s.meeting_booked, false))
    ),
    awaiting_response = (
      NOT c.archived
      AND NOT c.completed
      AND c.last_message_direction = 'sent'
    )
  FROM marketing.sendpilot_conversations c2
  LEFT JOIN marketing.sendpilot_conversation_state s ON s.conversation_id = c2.id
  WHERE c.id = c2.id
    AND (p_conversation_id IS NULL OR c.id = p_conversation_id);
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
  WHERE status IN ('draft', 'ready_to_send');

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
    count(*) FILTER (WHERE unread_count > 0 OR needs_reply OR has_failed_send OR has_draft)::integer,
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

CREATE OR REPLACE FUNCTION marketing.sendpilot_scoped_metrics(p_account_ids text[])
RETURNS TABLE (
  total integer,
  unread integer,
  needs_reply integer,
  awaiting_response integer,
  drafts_waiting integer,
  failed integer,
  archived integer,
  completed integer,
  action_needed integer,
  sent_dir integer,
  received_dir integer,
  sent_today integer,
  last_sync_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  WITH scoped AS (
    SELECT c.*
    FROM marketing.sendpilot_conversations c
    WHERE cardinality(p_account_ids) = 0
       OR c.account_id = ANY(p_account_ids)
  )
  SELECT
    count(*)::integer AS total,
    count(*) FILTER (WHERE s.unread_count > 0)::integer AS unread,
    count(*) FILTER (WHERE s.needs_reply)::integer AS needs_reply,
    count(*) FILTER (WHERE s.awaiting_response)::integer AS awaiting_response,
    count(*) FILTER (WHERE s.has_draft)::integer AS drafts_waiting,
    count(*) FILTER (WHERE s.has_failed_send)::integer AS failed,
    count(*) FILTER (WHERE s.archived)::integer AS archived,
    count(*) FILTER (WHERE s.completed)::integer AS completed,
    count(*) FILTER (
      WHERE s.unread_count > 0 OR s.needs_reply OR s.has_failed_send OR s.has_draft
    )::integer AS action_needed,
    count(*) FILTER (
      WHERE s.last_message_direction = 'sent'
        AND NOT s.archived
        AND NOT s.completed
    )::integer AS sent_dir,
    count(*) FILTER (
      WHERE s.last_message_direction = 'received'
        AND NOT s.archived
        AND NOT s.completed
    )::integer AS received_dir,
    (
      SELECT count(*)::integer
      FROM marketing.sendpilot_outbound_messages o
      JOIN marketing.sendpilot_conversations c ON c.id = o.conversation_id
      WHERE o.status = 'sent'
        AND o.sent_at >= date_trunc('day', now() AT TIME ZONE 'UTC')
        AND (
          cardinality(p_account_ids) = 0
          OR c.account_id = ANY(p_account_ids)
        )
    ) AS sent_today,
    max(s.last_synced_at) AS last_sync_at
  FROM scoped s;
$$;

CREATE OR REPLACE FUNCTION public.sendpilot_scoped_metrics(p_account_ids text[])
RETURNS TABLE (
  total integer,
  unread integer,
  needs_reply integer,
  awaiting_response integer,
  drafts_waiting integer,
  failed integer,
  archived integer,
  completed integer,
  action_needed integer,
  sent_dir integer,
  received_dir integer,
  sent_today integer,
  last_sync_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT * FROM marketing.sendpilot_scoped_metrics(p_account_ids);
$$;

GRANT EXECUTE ON FUNCTION marketing.sendpilot_inbound_needs_reply(text, boolean) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.sendpilot_scoped_metrics(text[]) TO anon, authenticated, service_role;

SELECT marketing.refresh_conversation_inbox_flags(NULL);
SELECT marketing.refresh_inbox_stats();

COMMIT;
