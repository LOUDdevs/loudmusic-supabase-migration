-- Migration: 015_crm_contacts_list_performance.sql
-- Fix crm_contacts_list view timeout (remove expensive lateral conversation scan).
-- Backfill normalized LinkedIn URLs. Use FK join only for conversation coalesce.

BEGIN;

-- ============================================================================
-- 1. Fix URL normalizer (strip protocol/www reliably)
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.normalize_linkedin_url(url text)
RETURNS text
LANGUAGE sql
IMMUTABLE AS $$
  SELECT CASE
    WHEN url IS NULL OR btrim(url) = '' THEN NULL
    ELSE lower(
      regexp_replace(
        regexp_replace(
          regexp_replace(btrim(url), '^https?://(www\.)?', ''),
          '\?.*$', ''
        ),
        '/+$', ''
      )
    )
  END;
$$;

-- Backfill contacts with malformed normalized URLs
UPDATE marketing.crm_contacts c
SET linkedin_url_normalized = marketing.normalize_linkedin_url(
  COALESCE(c.linkedin_url_normalized, l.linkedin_url)
)
FROM marketing.sendpilot_leads l
WHERE l.id = c.sendpilot_lead_id
  AND (
    c.linkedin_url_normalized IS NULL
    OR c.linkedin_url_normalized LIKE 'http%'
  );

UPDATE marketing.crm_contacts c
SET linkedin_url_normalized = marketing.normalize_linkedin_url(c.linkedin_url_normalized)
WHERE c.linkedin_url_normalized IS NOT NULL
  AND c.linkedin_url_normalized LIKE 'http%';

UPDATE marketing.crm_contacts c
SET linkedin_url_normalized = marketing.normalize_linkedin_url(sp.lead_profile_url)
FROM marketing.sendpilot_conversations sp
WHERE sp.id = c.sendpilot_conversation_id
  AND c.linkedin_url_normalized IS NULL
  AND sp.lead_profile_url IS NOT NULL;

-- ============================================================================
-- 2. Indexes for list sort/filter
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_crm_contacts_last_contacted
  ON marketing.crm_contacts (last_contacted_at DESC NULLS LAST)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_crm_contacts_created
  ON marketing.crm_contacts (created_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_crm_contacts_sp_conv
  ON marketing.crm_contacts (sendpilot_conversation_id)
  WHERE sendpilot_conversation_id IS NOT NULL;

-- ============================================================================
-- 3. Fast list view (FK join only — no lateral conversation scan)
-- ============================================================================

DROP VIEW IF EXISTS public.crm_contacts_list CASCADE;
DROP VIEW IF EXISTS marketing.crm_contacts_list;

CREATE VIEW marketing.crm_contacts_list AS
SELECT
  c.id,
  c.display_name,
  c.first_name,
  c.last_name,
  COALESCE(c.avatar_url, sp.lead_profile_picture) AS avatar_url,
  c.primary_email,
  c.primary_phone,
  c.relationship_status,
  c.lifecycle_stage,
  c.lead_source,
  c.owner_user_id,
  COALESCE(c.last_contacted_at, sp.last_message_sent_at, sp.last_activity_at) AS last_contacted_at,
  c.next_follow_up_at,
  c.linkedin_url_normalized,
  c.sendpilot_lead_id,
  c.sendpilot_conversation_id,
  c.lead_linkedin_id,
  c.ai_summary,
  c.created_at,
  c.updated_at,
  c.last_synced_at,
  COALESCE(types.type_slugs, ARRAY[]::text[]) AS type_slugs,
  COALESCE(types.type_labels, ARRAY[]::text[]) AS type_labels,
  COALESCE(tags.tag_names, ARRAY[]::text[]) AS tag_names,
  COALESCE(deals.open_deal_value_cents, 0) AS open_deal_value_cents,
  deals.primary_pipeline_stage,
  plat.primary_platform_slug,
  COALESCE(prof.current_company, sp.lead_company, l.company) AS current_company,
  COALESCE(prof.job_title, sp.lead_title, l.title) AS job_title,
  COALESCE(prof.headline, prof.job_title, sp.lead_title, l.title) AS headline
FROM marketing.crm_contacts c
LEFT JOIN marketing.crm_contact_profiles prof ON prof.contact_id = c.id
LEFT JOIN marketing.sendpilot_leads l ON l.id = c.sendpilot_lead_id
LEFT JOIN marketing.sendpilot_conversations sp ON sp.id = c.sendpilot_conversation_id
LEFT JOIN LATERAL (
  SELECT
    array_agg(DISTINCT ct.slug ORDER BY ct.slug) AS type_slugs,
    array_agg(DISTINCT ct.label ORDER BY ct.label) AS type_labels
  FROM marketing.crm_contact_type_assignments cta
  JOIN marketing.crm_contact_types ct ON ct.id = cta.type_id
  WHERE cta.contact_id = c.id
) types ON true
LEFT JOIN LATERAL (
  SELECT array_agg(DISTINCT t.name ORDER BY t.name) AS tag_names
  FROM marketing.crm_contact_tags ctg
  JOIN marketing.crm_tags t ON t.id = ctg.tag_id
  WHERE ctg.contact_id = c.id
) tags ON true
LEFT JOIN LATERAL (
  SELECT
    COALESCE(SUM(d.value_cents), 0)::integer AS open_deal_value_cents,
    (
      SELECT ps.name
      FROM marketing.crm_deals d2
      JOIN marketing.crm_pipeline_stages ps ON ps.id = d2.stage_id
      WHERE d2.contact_id = c.id AND ps.is_won = false AND ps.is_lost = false
      ORDER BY d2.value_cents DESC NULLS LAST
      LIMIT 1
    ) AS primary_pipeline_stage
  FROM marketing.crm_deals d
  JOIN marketing.crm_pipeline_stages ps ON ps.id = d.stage_id
  WHERE d.contact_id = c.id AND ps.is_won = false AND ps.is_lost = false
) deals ON true
LEFT JOIN LATERAL (
  SELECT p.slug AS primary_platform_slug
  FROM marketing.crm_contact_platform_accounts cpa
  JOIN marketing.crm_platforms p ON p.id = cpa.platform_id
  WHERE cpa.contact_id = c.id
  ORDER BY cpa.is_primary DESC, cpa.created_at ASC
  LIMIT 1
) plat ON true
WHERE c.deleted_at IS NULL;

CREATE VIEW public.crm_contacts_list AS
  SELECT * FROM marketing.crm_contacts_list;

GRANT SELECT ON public.crm_contacts_list TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
