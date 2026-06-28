-- Migration: 034_calendar_enriched_left_join.sql
-- Use LEFT JOIN on email_accounts so events still appear if account row is missing.

BEGIN;

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
LEFT JOIN marketing.email_accounts a ON a.id = e.account_id
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
