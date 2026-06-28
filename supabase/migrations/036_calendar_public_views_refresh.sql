-- Migration: 036_calendar_public_views_refresh.sql
-- Recreate public views so PostgREST sees columns added in 035.

BEGIN;

CREATE OR REPLACE VIEW public.calendar_sync_settings AS
SELECT * FROM marketing.calendar_sync_settings;

CREATE OR REPLACE VIEW public.calendar_events AS
SELECT * FROM marketing.calendar_events;

NOTIFY pgrst, 'reload schema';

COMMIT;
