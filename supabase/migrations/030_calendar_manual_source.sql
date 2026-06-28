-- Migration: 030_calendar_manual_source.sql
-- Track event source: auto ICS ingest, manual from email, or standalone manual.

BEGIN;

ALTER TABLE marketing.calendar_events
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'email_ics'
    CHECK (source IN ('email_ics', 'email_manual', 'manual'));

DROP VIEW IF EXISTS public.calendar_events_enriched;
DROP VIEW IF EXISTS marketing.calendar_events_enriched;

CREATE VIEW marketing.calendar_events_enriched AS
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

CREATE VIEW public.calendar_events_enriched AS SELECT * FROM marketing.calendar_events_enriched;

GRANT SELECT ON public.calendar_events_enriched TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
