-- Migration: 031_calendar_crm_fields.sql
-- Extend calendar_events for CRM integration and full lifecycle.

BEGIN;

ALTER TABLE marketing.calendar_events
  ADD COLUMN IF NOT EXISTS event_type text NOT NULL DEFAULT 'meeting'
    CHECK (event_type IN (
      'meeting', 'sales_call', 'discovery_call', 'follow_up', 'artist_onboarding',
      'client_checkin', 'internal_task', 'deadline', 'reminder', 'email_follow_up',
      'release_planning', 'campaign_milestone', 'studio_session', 'consultation', 'custom'
    )),
  ADD COLUMN IF NOT EXISTS lifecycle_status text NOT NULL DEFAULT 'scheduled'
    CHECK (lifecycle_status IN (
      'scheduled', 'confirmed', 'tentative', 'completed', 'cancelled',
      'no_show', 'rescheduled', 'needs_follow_up'
    )),
  ADD COLUMN IF NOT EXISTS priority text NOT NULL DEFAULT 'normal'
    CHECK (priority IN ('low', 'normal', 'high')),
  ADD COLUMN IF NOT EXISTS meeting_url text,
  ADD COLUMN IF NOT EXISTS visibility text NOT NULL DEFAULT 'team'
    CHECK (visibility IN ('team', 'private')),
  ADD COLUMN IF NOT EXISTS related_deal_id uuid REFERENCES marketing.crm_deals (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS related_organization_id uuid REFERENCES marketing.crm_organizations (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS related_artist_id uuid REFERENCES marketing.crm_artists (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS related_task_id uuid REFERENCES marketing.crm_tasks (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS agenda text,
  ADD COLUMN IF NOT EXISTS outcome text,
  ADD COLUMN IF NOT EXISTS follow_up_required boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS follow_up_due_at timestamptz,
  ADD COLUMN IF NOT EXISTS created_by text,
  ADD COLUMN IF NOT EXISTS updated_by text,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_calendar_events_event_type ON marketing.calendar_events (event_type);
CREATE INDEX IF NOT EXISTS idx_calendar_events_lifecycle ON marketing.calendar_events (lifecycle_status);
CREATE INDEX IF NOT EXISTS idx_calendar_events_deleted ON marketing.calendar_events (deleted_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_calendar_events_deal ON marketing.calendar_events (related_deal_id);
CREATE INDEX IF NOT EXISTS idx_calendar_events_follow_up ON marketing.calendar_events (follow_up_required) WHERE follow_up_required = true;

CREATE OR REPLACE FUNCTION marketing.calendar_events_in_range(
  p_start timestamptz,
  p_end timestamptz,
  p_account_id uuid DEFAULT NULL
)
RETURNS SETOF marketing.calendar_events
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT e.*
  FROM marketing.calendar_events e
  WHERE e.starts_at IS NOT NULL
    AND e.starts_at < p_end
    AND coalesce(e.ends_at, e.starts_at) >= p_start
    AND (p_account_id IS NULL OR e.account_id = p_account_id)
    AND e.deleted_at IS NULL
    AND e.lifecycle_status NOT IN ('cancelled')
    AND e.status <> 'cancelled'
  ORDER BY e.starts_at ASC;
$$;

DROP VIEW IF EXISTS public.calendar_events_enriched;
DROP VIEW IF EXISTS marketing.calendar_events_enriched;

CREATE VIEW marketing.calendar_events_enriched AS
SELECT
  e.*,
  t.subject AS thread_subject,
  em.subject AS email_subject,
  a.account_email,
  c.display_name AS contact_name,
  c.primary_email AS contact_email,
  d.title AS deal_title,
  o.name AS organization_name,
  ar.artist_name AS artist_name
FROM marketing.calendar_events e
JOIN marketing.email_accounts a ON a.id = e.account_id
LEFT JOIN marketing.email_threads t ON t.id = e.thread_id
LEFT JOIN marketing.emails em ON em.id = e.email_id
LEFT JOIN marketing.crm_contacts c ON c.id = e.linked_contact_id
LEFT JOIN marketing.crm_deals d ON d.id = e.related_deal_id
LEFT JOIN marketing.crm_organizations o ON o.id = e.related_organization_id
LEFT JOIN marketing.crm_artists ar ON ar.id = e.related_artist_id
WHERE e.deleted_at IS NULL;

CREATE VIEW public.calendar_events_enriched AS SELECT * FROM marketing.calendar_events_enriched;
GRANT SELECT ON public.calendar_events_enriched TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
