-- Migration: 017_crm_sendpilot_account_scope.sql
-- Expose SendPilot account_id on CRM list view for Derrick-only dashboard scoping.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_sp_conv_account
  ON marketing.sendpilot_conversations (account_id);

DROP VIEW IF EXISTS public.crm_contacts_list CASCADE;
DROP VIEW IF EXISTS marketing.crm_contacts_list CASCADE;

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
  COALESCE(c.sendpilot_conversation_id, sp.id) AS sendpilot_conversation_id,
  c.lead_linkedin_id,
  c.ai_summary,
  c.created_at,
  c.updated_at,
  c.last_synced_at,
  sp.account_id AS sendpilot_account_id,
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
LEFT JOIN LATERAL (
  SELECT
    sp2.id,
    sp2.account_id,
    sp2.lead_profile_picture,
    sp2.lead_title,
    sp2.lead_company,
    sp2.last_message_sent_at,
    sp2.last_activity_at
  FROM marketing.sendpilot_conversations sp2
  WHERE sp2.id = c.sendpilot_conversation_id
     OR (
       c.linkedin_url_normalized IS NOT NULL
       AND marketing.normalize_linkedin_url(sp2.lead_profile_url) = c.linkedin_url_normalized
     )
     OR (
       c.lead_linkedin_id IS NOT NULL
       AND sp2.lead_linkedin_id = c.lead_linkedin_id
     )
  ORDER BY
    CASE WHEN sp2.id = c.sendpilot_conversation_id THEN 0 ELSE 1 END,
    sp2.last_activity_at DESC NULLS LAST
  LIMIT 1
) sp ON true
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

CREATE OR REPLACE VIEW public.crm_contacts_list AS
  SELECT * FROM marketing.crm_contacts_list;

GRANT SELECT ON public.crm_contacts_list TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
