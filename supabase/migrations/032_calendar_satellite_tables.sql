-- Migration: 032_calendar_satellite_tables.sql
-- Satellite tables for calendar activity, Hermes, reminders, and meeting notes.

BEGIN;

CREATE TABLE IF NOT EXISTS marketing.calendar_event_links (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id          uuid NOT NULL REFERENCES marketing.calendar_events (id) ON DELETE CASCADE,
  linked_type       text NOT NULL,
  linked_id         uuid NOT NULL,
  relationship_type text NOT NULL DEFAULT 'related',
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, linked_type, linked_id)
);

CREATE TABLE IF NOT EXISTS marketing.calendar_reminders (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id      uuid NOT NULL REFERENCES marketing.calendar_events (id) ON DELETE CASCADE,
  reminder_type text NOT NULL DEFAULT 'notification',
  remind_at     timestamptz NOT NULL,
  status        text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sent', 'cancelled', 'failed')),
  channel       text NOT NULL DEFAULT 'dashboard',
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.calendar_agent_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id         uuid REFERENCES marketing.calendar_events (id) ON DELETE SET NULL,
  email_thread_id  uuid REFERENCES marketing.email_threads (id) ON DELETE SET NULL,
  action_type      text NOT NULL,
  user_input       text,
  generated_prompt text NOT NULL,
  status           text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'pending', 'sent', 'completed', 'failed')),
  agent_response   text,
  created_by       text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.calendar_sync_logs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid REFERENCES marketing.email_accounts (id) ON DELETE SET NULL,
  sync_type     text NOT NULL,
  status        text NOT NULL,
  started_at    timestamptz NOT NULL DEFAULT now(),
  completed_at  timestamptz,
  error_summary text,
  error_details jsonb,
  logs          text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.calendar_activity_logs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id    uuid NOT NULL REFERENCES marketing.calendar_events (id) ON DELETE CASCADE,
  action      text NOT NULL,
  details     jsonb NOT NULL DEFAULT '{}'::jsonb,
  actor       text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.meeting_notes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id          uuid NOT NULL REFERENCES marketing.calendar_events (id) ON DELETE CASCADE,
  notes             text,
  decisions         text,
  next_steps        text,
  follow_up_summary text,
  created_by        text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_calendar_event_links_event ON marketing.calendar_event_links (event_id);
CREATE INDEX IF NOT EXISTS idx_calendar_reminders_event ON marketing.calendar_reminders (event_id);
CREATE INDEX IF NOT EXISTS idx_calendar_agent_requests_status ON marketing.calendar_agent_requests (status, created_at);
CREATE INDEX IF NOT EXISTS idx_calendar_activity_event ON marketing.calendar_activity_logs (event_id, created_at);
CREATE INDEX IF NOT EXISTS idx_meeting_notes_event ON marketing.meeting_notes (event_id);

ALTER TABLE marketing.calendar_event_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.calendar_reminders ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.calendar_agent_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.calendar_sync_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.calendar_activity_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.meeting_notes ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'calendar_event_links', 'calendar_reminders', 'calendar_agent_requests',
    'calendar_sync_logs', 'calendar_activity_logs', 'meeting_notes'
  ]
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

CREATE OR REPLACE VIEW public.calendar_event_links AS SELECT * FROM marketing.calendar_event_links;
CREATE OR REPLACE VIEW public.calendar_reminders AS SELECT * FROM marketing.calendar_reminders;
CREATE OR REPLACE VIEW public.calendar_agent_requests AS SELECT * FROM marketing.calendar_agent_requests;
CREATE OR REPLACE VIEW public.calendar_sync_logs AS SELECT * FROM marketing.calendar_sync_logs;
CREATE OR REPLACE VIEW public.calendar_activity_logs AS SELECT * FROM marketing.calendar_activity_logs;
CREATE OR REPLACE VIEW public.meeting_notes AS SELECT * FROM marketing.meeting_notes;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.calendar_event_links TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.calendar_reminders TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.calendar_agent_requests TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.calendar_sync_logs TO anon, authenticated, service_role;
GRANT SELECT ON public.calendar_activity_logs TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.meeting_notes TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
