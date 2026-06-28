-- Migration: 027_dashboard_performance_rpcs.sql
-- Single-query rollups for dashboard page performance.

BEGIN;

-- ============================================================================
-- SendPilot scoped inbox metrics (replaces 11+ parallel count queries)
-- ============================================================================

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
      WHERE s.unread_count > 0 OR s.needs_reply OR s.has_failed_send
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

GRANT EXECUTE ON FUNCTION public.sendpilot_scoped_metrics(text[]) TO anon, authenticated, service_role;

-- ============================================================================
-- Email folder counts (replaces 10 parallel count queries)
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.email_inbox_folder_counts(p_account_id uuid DEFAULT NULL)
RETURNS TABLE (
  inbox integer,
  unread integer,
  needs_reply integer,
  ai_drafted integer,
  draft_review integer,
  sent integer,
  failed integer,
  archived integer,
  important integer,
  all_count integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  WITH threads AS (
    SELECT t.*
    FROM marketing.email_threads t
    WHERE p_account_id IS NULL OR t.account_id = p_account_id
  ),
  latest_drafts AS (
    SELECT DISTINCT ON (d.thread_id)
      d.thread_id,
      d.status
    FROM marketing.email_drafts d
  ),
  enriched AS (
    SELECT
      t.id,
      t.unread_count,
      t.needs_reply,
      t.has_ai_draft,
      t.is_archived,
      t.is_important,
      lm.direction AS latest_direction,
      ld.status AS latest_draft_status
    FROM threads t
    LEFT JOIN LATERAL (
      SELECT e.direction
      FROM marketing.emails e
      WHERE e.thread_id = t.id
      ORDER BY COALESCE(e.received_at, e.sent_at, e.created_at) DESC
      LIMIT 1
    ) lm ON true
    LEFT JOIN latest_drafts ld ON ld.thread_id = t.id
  )
  SELECT
    count(*) FILTER (WHERE NOT e.is_archived)::integer AS inbox,
    count(*) FILTER (WHERE e.unread_count > 0)::integer AS unread,
    count(*) FILTER (WHERE e.needs_reply)::integer AS needs_reply,
    count(*) FILTER (WHERE e.has_ai_draft)::integer AS ai_drafted,
    count(*) FILTER (
      WHERE e.latest_draft_status IN ('generated', 'needs_review')
    )::integer AS draft_review,
    count(*) FILTER (WHERE e.latest_direction = 'outbound')::integer AS sent,
    count(*) FILTER (WHERE e.latest_draft_status = 'failed')::integer AS failed,
    count(*) FILTER (WHERE e.is_archived)::integer AS archived,
    count(*) FILTER (WHERE e.is_important)::integer AS important,
    count(*)::integer AS all_count
  FROM enriched e;
$$;

CREATE OR REPLACE FUNCTION public.email_inbox_folder_counts(p_account_id uuid DEFAULT NULL)
RETURNS TABLE (
  inbox integer,
  unread integer,
  needs_reply integer,
  ai_drafted integer,
  draft_review integer,
  sent integer,
  failed integer,
  archived integer,
  important integer,
  all_count integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT * FROM marketing.email_inbox_folder_counts(p_account_id);
$$;

GRANT EXECUTE ON FUNCTION public.email_inbox_folder_counts(uuid) TO anon, authenticated, service_role;

-- ============================================================================
-- CRM open deals summary
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.crm_open_deals_summary(p_contact_ids uuid[] DEFAULT NULL)
RETURNS TABLE (
  open_deals integer,
  open_deal_value_cents bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT
    count(*)::integer AS open_deals,
    coalesce(sum(d.value_cents), 0)::bigint AS open_deal_value_cents
  FROM marketing.crm_deals d
  JOIN marketing.crm_pipeline_stages s ON s.id = d.stage_id
  WHERE NOT s.is_won
    AND NOT s.is_lost
    AND (
      p_contact_ids IS NULL
      OR cardinality(p_contact_ids) = 0
      OR d.contact_id = ANY(p_contact_ids)
    );
$$;

CREATE OR REPLACE FUNCTION public.crm_open_deals_summary(p_contact_ids uuid[] DEFAULT NULL)
RETURNS TABLE (
  open_deals integer,
  open_deal_value_cents bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT * FROM marketing.crm_open_deals_summary(p_contact_ids);
$$;

GRANT EXECUTE ON FUNCTION public.crm_open_deals_summary(uuid[]) TO anon, authenticated, service_role;

-- ============================================================================
-- Task cadence + Zernio status GROUP BY rollups
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.tasks_count_by_cadence()
RETURNS TABLE (cadence text, count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT t.cadence, count(*)::bigint
  FROM marketing.tasks t
  WHERE t.is_active = true
  GROUP BY t.cadence;
$$;

CREATE OR REPLACE FUNCTION public.tasks_count_by_cadence()
RETURNS TABLE (cadence text, count bigint)
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT * FROM marketing.tasks_count_by_cadence();
$$;

GRANT EXECUTE ON FUNCTION public.tasks_count_by_cadence() TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION marketing.zernio_posts_count_by_status()
RETURNS TABLE (status text, count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT p.status, count(*)::bigint
  FROM marketing.zernio_posts p
  GROUP BY p.status;
$$;

CREATE OR REPLACE FUNCTION public.zernio_posts_count_by_status()
RETURNS TABLE (status text, count bigint)
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT * FROM marketing.zernio_posts_count_by_status();
$$;

GRANT EXECUTE ON FUNCTION public.zernio_posts_count_by_status() TO anon, authenticated, service_role;

COMMIT;
