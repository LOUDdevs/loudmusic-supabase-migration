-- Migration: 029_calendar_from_email.sql
-- Meeting invites from IMAP email → calendar_events + Nextcloud CalDAV sync.
-- Run AFTER 028_reachinbox_foundation.sql.

BEGIN;

-- ============================================================================
-- 1. Enums
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE marketing.calendar_event_status AS ENUM ('confirmed', 'tentative', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.calendar_sync_status AS ENUM ('pending', 'synced', 'error', 'cancelled', 'skipped');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ============================================================================
-- 2. Tables
-- ============================================================================

CREATE TABLE marketing.calendar_sync_settings (
  account_id                uuid PRIMARY KEY REFERENCES marketing.email_accounts (id) ON DELETE CASCADE,
  nextcloud_calendar_name   text NOT NULL DEFAULT 'personal',
  nextcloud_calendar_url    text,
  auto_push                 boolean NOT NULL DEFAULT true,
  default_timezone          text NOT NULL DEFAULT 'America/New_York',
  last_sync_at              timestamptz,
  last_error                text,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE marketing.calendar_events (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id        uuid NOT NULL REFERENCES marketing.email_accounts (id) ON DELETE CASCADE,
  email_id          uuid REFERENCES marketing.emails (id) ON DELETE SET NULL,
  thread_id         uuid REFERENCES marketing.email_threads (id) ON DELETE SET NULL,
  ical_uid          text NOT NULL,
  ical_sequence     integer NOT NULL DEFAULT 0,
  method            text,
  status            marketing.calendar_event_status NOT NULL DEFAULT 'tentative',
  summary           text,
  description       text,
  location          text,
  organizer_email   text,
  organizer_name    text,
  attendees         jsonb NOT NULL DEFAULT '[]'::jsonb,
  starts_at         timestamptz,
  ends_at           timestamptz,
  all_day           boolean NOT NULL DEFAULT false,
  timezone          text,
  rrule             text,
  raw_ics           text,
  nextcloud_href    text,
  sync_status       marketing.calendar_sync_status NOT NULL DEFAULT 'pending',
  sync_error        text,
  linked_contact_id uuid REFERENCES marketing.crm_contacts (id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, ical_uid)
);

CREATE INDEX idx_calendar_events_account ON marketing.calendar_events (account_id);
CREATE INDEX idx_calendar_events_thread ON marketing.calendar_events (thread_id);
CREATE INDEX idx_calendar_events_starts ON marketing.calendar_events (starts_at);
CREATE INDEX idx_calendar_events_sync ON marketing.calendar_events (sync_status);

-- ============================================================================
-- 3. RPCs
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.calendar_match_contact(p_event_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
DECLARE
  v_contact_id uuid;
  v_organizer_email text;
BEGIN
  SELECT lower(btrim(organizer_email)) INTO v_organizer_email
  FROM marketing.calendar_events
  WHERE id = p_event_id;

  IF v_organizer_email IS NULL OR v_organizer_email = '' THEN
    RETURN NULL;
  END IF;

  SELECT c.id INTO v_contact_id
  FROM marketing.crm_contacts c
  WHERE lower(btrim(c.primary_email)) = v_organizer_email
    AND c.deleted_at IS NULL
  LIMIT 1;

  IF v_contact_id IS NOT NULL THEN
    UPDATE marketing.calendar_events
    SET linked_contact_id = v_contact_id, updated_at = now()
    WHERE id = p_event_id AND linked_contact_id IS NULL;
  END IF;

  RETURN v_contact_id;
END;
$$;

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
    AND e.status <> 'cancelled'
  ORDER BY e.starts_at ASC;
$$;

-- ============================================================================
-- 4. Enriched view
-- ============================================================================

CREATE OR REPLACE VIEW marketing.calendar_events_enriched AS
SELECT
  e.*,
  t.subject AS thread_subject,
  em.subject AS email_subject,
  a.account_email,
  c.display_name AS contact_name,
  c.primary_email AS contact_email
FROM marketing.calendar_events e
JOIN marketing.email_accounts a ON a.id = e.account_id
LEFT JOIN marketing.email_threads t ON t.id = e.thread_id
LEFT JOIN marketing.emails em ON em.id = e.email_id
LEFT JOIN marketing.crm_contacts c ON c.id = e.linked_contact_id;

-- ============================================================================
-- 5. Triggers
-- ============================================================================

CREATE TRIGGER calendar_sync_settings_updated_at
  BEFORE UPDATE ON marketing.calendar_sync_settings
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

CREATE TRIGGER calendar_events_updated_at
  BEFORE UPDATE ON marketing.calendar_events
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

-- ============================================================================
-- 6. RLS
-- ============================================================================

ALTER TABLE marketing.calendar_sync_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.calendar_events ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['calendar_sync_settings', 'calendar_events']
  LOOP
    EXECUTE format(
      'CREATE POLICY "calendar_%s_select_team" ON marketing.%I FOR SELECT TO authenticated
       USING (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor'', ''viewer''))',
      tbl, tbl
    );
    EXECUTE format(
      'CREATE POLICY "calendar_%s_write_team" ON marketing.%I FOR ALL TO authenticated
       USING (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor''))
       WITH CHECK (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor''))',
      tbl, tbl
    );
  END LOOP;
END $$;

-- ============================================================================
-- 7. Public views + grants
-- ============================================================================

CREATE OR REPLACE VIEW public.calendar_sync_settings AS SELECT * FROM marketing.calendar_sync_settings;
CREATE OR REPLACE VIEW public.calendar_events AS SELECT * FROM marketing.calendar_events;
CREATE OR REPLACE VIEW public.calendar_events_enriched AS SELECT * FROM marketing.calendar_events_enriched;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.calendar_sync_settings TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.calendar_events TO anon, authenticated, service_role;
GRANT SELECT ON public.calendar_events_enriched TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.calendar_events_in_range(
  p_start timestamptz,
  p_end timestamptz,
  p_account_id uuid DEFAULT NULL
)
RETURNS SETOF public.calendar_events
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT * FROM marketing.calendar_events_in_range(p_start, p_end, p_account_id);
$$;

GRANT EXECUTE ON FUNCTION public.calendar_events_in_range(timestamptz, timestamptz, uuid) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.calendar_match_contact(p_event_id uuid)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT marketing.calendar_match_contact(p_event_id);
$$;

GRANT EXECUTE ON FUNCTION public.calendar_match_contact(uuid) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
