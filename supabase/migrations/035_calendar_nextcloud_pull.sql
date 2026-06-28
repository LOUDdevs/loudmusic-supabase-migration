-- Migration: 035_calendar_nextcloud_pull.sql
-- Bidirectional Nextcloud CalDAV: pull remote events into calendar_events.

BEGIN;

ALTER TABLE marketing.calendar_events
  DROP CONSTRAINT IF EXISTS calendar_events_source_check;

ALTER TABLE marketing.calendar_events
  ADD CONSTRAINT calendar_events_source_check
  CHECK (source IN ('email_ics', 'email_manual', 'manual', 'nextcloud'));

ALTER TABLE marketing.calendar_events
  ADD COLUMN IF NOT EXISTS nextcloud_etag text;

CREATE INDEX IF NOT EXISTS idx_calendar_events_nextcloud_href
  ON marketing.calendar_events (nextcloud_href)
  WHERE nextcloud_href IS NOT NULL;

ALTER TABLE marketing.calendar_sync_settings
  ADD COLUMN IF NOT EXISTS auto_pull boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS last_pull_at timestamptz,
  ADD COLUMN IF NOT EXISTS caldav_sync_token text;

NOTIFY pgrst, 'reload schema';

COMMIT;
