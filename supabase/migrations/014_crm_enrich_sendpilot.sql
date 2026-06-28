-- Migration: 014_crm_enrich_sendpilot.sql
-- Improve CRM enrichment from SendPilot: URL normalization, better matching,
-- headline/avatar/last-contact mapping, inbox join fix.
-- Run AFTER 013_crm_foundation.sql.

BEGIN;

-- ============================================================================
-- 1. Stronger LinkedIn URL normalizer
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
          regexp_replace(
            regexp_replace(btrim(url), '^https?://(www\.)?', ''),
            '\?.*$', ''
          ),
          '/+$', ''
        ),
        '^linkedin\.com', 'linkedin.com'
      )
    )
  END;
$$;

-- ============================================================================
-- 2. New columns
-- ============================================================================

ALTER TABLE marketing.crm_contacts
  ADD COLUMN IF NOT EXISTS lead_linkedin_id text;

CREATE INDEX IF NOT EXISTS idx_crm_contacts_lead_linkedin_id
  ON marketing.crm_contacts (lead_linkedin_id)
  WHERE lead_linkedin_id IS NOT NULL;

ALTER TABLE marketing.sendpilot_conversations
  ADD COLUMN IF NOT EXISTS lead_participant jsonb NOT NULL DEFAULT '{}'::jsonb;

-- ============================================================================
-- 3. Fix inbox refresh + enriched view joins (normalized URLs)
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.refresh_conversation_inbox_flags(p_conversation_id uuid DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
BEGIN
  UPDATE marketing.sendpilot_conversations c
  SET
    has_draft = EXISTS (
      SELECT 1 FROM marketing.sendpilot_drafts d
      WHERE d.conversation_id = c.id AND d.status = 'draft'
    ),
    has_failed_send = EXISTS (
      SELECT 1 FROM marketing.sendpilot_outbound_messages o
      WHERE o.conversation_id = c.id AND o.status = 'failed'
    ),
    archived = COALESCE((
      SELECT cs.archived FROM marketing.sendpilot_conversation_state cs
      WHERE cs.conversation_id = c.id
    ), false),
    completed = COALESCE((
      SELECT cs.completed FROM marketing.sendpilot_conversation_state cs
      WHERE cs.conversation_id = c.id
    ), false),
    lead_company = sub.lead_company,
    lead_title = sub.lead_title,
    campaign_id = sub.campaign_id,
    campaign_name = sub.campaign_name
  FROM (
    SELECT
      c2.id AS conversation_id,
      l.company AS lead_company,
      l.title AS lead_title,
      camp.id AS campaign_id,
      camp.name AS campaign_name
    FROM marketing.sendpilot_conversations c2
    LEFT JOIN marketing.sendpilot_leads l
      ON marketing.normalize_linkedin_url(l.linkedin_url)
       = marketing.normalize_linkedin_url(c2.lead_profile_url)
      OR (c2.lead_linkedin_id IS NOT NULL AND l.external_id = c2.lead_linkedin_id)
    LEFT JOIN marketing.sendpilot_campaigns camp ON camp.id = l.campaign_id
    WHERE p_conversation_id IS NULL OR c2.id = p_conversation_id
  ) sub
  WHERE c.id = sub.conversation_id
    AND (p_conversation_id IS NULL OR c.id = p_conversation_id);

  UPDATE marketing.sendpilot_conversations c
  SET
    needs_reply = (
      c.last_message_direction = 'received'
      AND NOT COALESCE(c.archived, false)
      AND NOT COALESCE(c.completed, false)
      AND NOT EXISTS (
        SELECT 1 FROM marketing.sendpilot_drafts d
        WHERE d.conversation_id = c.id AND d.status = 'draft'
      )
    ),
    awaiting_response = (
      c.last_message_direction = 'sent'
      AND NOT COALESCE(c.archived, false)
      AND NOT COALESCE(c.completed, false)
    )
  WHERE p_conversation_id IS NULL OR c.id = p_conversation_id;
END;
$$;

CREATE OR REPLACE VIEW marketing.sendpilot_inbox_enriched AS
SELECT
  c.id,
  c.external_id,
  c.account_id,
  c.lead_linkedin_id,
  c.lead_name,
  c.lead_profile_url,
  c.lead_profile_picture,
  c.last_message_content,
  c.last_message_sent_at,
  c.last_message_direction,
  c.last_activity_at,
  c.unread_count,
  c.last_synced_at,
  COALESCE(l.id, NULL::uuid) AS lead_id,
  l.external_id AS lead_external_id,
  COALESCE(c.lead_company, l.company) AS lead_company,
  COALESCE(c.lead_title, l.title) AS lead_title,
  l.linkedin_url AS lead_linkedin_url,
  l.status AS lead_status,
  COALESCE(c.campaign_id, camp.id) AS campaign_id,
  COALESCE(c.campaign_name, camp.name) AS campaign_name,
  c.archived,
  c.completed,
  COALESCE(cs.tags, '{}'::text[]) AS tags,
  COALESCE(cs.priority, 0) AS priority,
  cs.notes,
  c.has_draft,
  c.has_failed_send,
  c.needs_reply,
  c.awaiting_response
FROM marketing.sendpilot_conversations c
LEFT JOIN marketing.sendpilot_leads l
  ON marketing.normalize_linkedin_url(l.linkedin_url)
   = marketing.normalize_linkedin_url(c.lead_profile_url)
  OR (c.lead_linkedin_id IS NOT NULL AND l.external_id = c.lead_linkedin_id)
LEFT JOIN marketing.sendpilot_campaigns camp ON camp.id = l.campaign_id
LEFT JOIN marketing.sendpilot_conversation_state cs ON cs.conversation_id = c.id;

CREATE OR REPLACE VIEW public.sendpilot_inbox_enriched AS
  SELECT * FROM marketing.sendpilot_inbox_enriched;

-- ============================================================================
-- 4. Enriched CRM contacts list (coalesce SendPilot display fields)
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
  COALESCE(c.sendpilot_conversation_id, sp.id) AS sendpilot_conversation_id,
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
LEFT JOIN LATERAL (
  SELECT
    sp2.id,
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

-- ============================================================================
-- 5. Rewritten SendPilot → CRM sync
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.crm_sync_from_sendpilot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
DECLARE
  v_linkedin_type_id uuid;
  v_linkedin_platform_id uuid;
  v_contacts_upserted integer := 0;
  v_messages_mirrored integer := 0;
  v_conversations_linked integer := 0;
  v_reconciled integer := 0;
  v_lead record;
  v_conv record;
  v_msg record;
  v_joined_lead record;
  v_contact_id uuid;
  v_thread_id uuid;
  v_norm_url text;
  v_display_name text;
  v_direction marketing.crm_comm_direction;
  v_status marketing.crm_comm_status;
  v_name_match_count integer;
BEGIN
  SELECT id INTO v_linkedin_type_id FROM marketing.crm_contact_types WHERE slug = 'linkedin_lead';
  SELECT id INTO v_linkedin_platform_id FROM marketing.crm_platforms WHERE slug = 'linkedin';

  -- Phase 1: Upsert contacts from SendPilot leads
  FOR v_lead IN SELECT * FROM marketing.sendpilot_leads LOOP
    v_norm_url := marketing.normalize_linkedin_url(v_lead.linkedin_url);
    v_display_name := NULLIF(btrim(COALESCE(v_lead.first_name, '') || ' ' || COALESCE(v_lead.last_name, '')), '');

    SELECT id INTO v_contact_id
    FROM marketing.crm_contacts
    WHERE sendpilot_lead_id = v_lead.id
       OR (v_norm_url IS NOT NULL AND linkedin_url_normalized = v_norm_url)
    LIMIT 1;

    IF v_contact_id IS NULL THEN
      INSERT INTO marketing.crm_contacts (
        display_name, first_name, last_name, primary_email,
        linkedin_url_normalized, sendpilot_lead_id, lead_source,
        lifecycle_stage, last_synced_at
      ) VALUES (
        COALESCE(v_display_name, 'Unknown Lead'),
        v_lead.first_name, v_lead.last_name, v_lead.email,
        v_norm_url, v_lead.id, 'sendpilot',
        'lead', now()
      )
      RETURNING id INTO v_contact_id;
      v_contacts_upserted := v_contacts_upserted + 1;
    ELSE
      UPDATE marketing.crm_contacts SET
        display_name = COALESCE(NULLIF(display_name, 'Unknown Lead'), v_display_name, display_name),
        first_name = COALESCE(v_lead.first_name, first_name),
        last_name = COALESCE(v_lead.last_name, last_name),
        primary_email = COALESCE(v_lead.email, primary_email),
        linkedin_url_normalized = COALESCE(v_norm_url, linkedin_url_normalized),
        sendpilot_lead_id = COALESCE(sendpilot_lead_id, v_lead.id),
        last_synced_at = now(),
        updated_at = now()
      WHERE id = v_contact_id;
    END IF;

    INSERT INTO marketing.crm_contact_type_assignments (contact_id, type_id)
    VALUES (v_contact_id, v_linkedin_type_id)
    ON CONFLICT DO NOTHING;

    INSERT INTO marketing.crm_contact_profiles (
      contact_id, job_title, headline, current_company, outreach_status
    ) VALUES (
      v_contact_id, v_lead.title, v_lead.title, v_lead.company, v_lead.status
    )
    ON CONFLICT (contact_id) DO UPDATE SET
      job_title = COALESCE(EXCLUDED.job_title, crm_contact_profiles.job_title),
      headline = COALESCE(EXCLUDED.headline, crm_contact_profiles.headline),
      current_company = COALESCE(EXCLUDED.current_company, crm_contact_profiles.current_company),
      outreach_status = COALESCE(EXCLUDED.outreach_status, crm_contact_profiles.outreach_status),
      updated_at = now();

    IF v_norm_url IS NOT NULL THEN
      INSERT INTO marketing.crm_contact_platform_accounts (
        contact_id, platform_id, profile_url, is_primary, sync_status, last_synced_at
      ) VALUES (
        v_contact_id, v_linkedin_platform_id, v_lead.linkedin_url, true, 'synced', now()
      )
      ON CONFLICT (contact_id, platform_id, profile_url) DO UPDATE SET
        last_synced_at = now(),
        sync_status = 'synced',
        updated_at = now();
    END IF;
  END LOOP;

  -- Phase 2: Link and enrich from conversations
  FOR v_conv IN SELECT * FROM marketing.sendpilot_conversations LOOP
    v_norm_url := marketing.normalize_linkedin_url(v_conv.lead_profile_url);
    v_contact_id := NULL;

    SELECT id INTO v_contact_id
    FROM marketing.crm_contacts
    WHERE sendpilot_conversation_id = v_conv.id
    LIMIT 1;

    IF v_contact_id IS NULL AND v_norm_url IS NOT NULL THEN
      SELECT id INTO v_contact_id
      FROM marketing.crm_contacts
      WHERE linkedin_url_normalized = v_norm_url
      LIMIT 1;
    END IF;

    IF v_contact_id IS NULL AND v_conv.lead_linkedin_id IS NOT NULL THEN
      SELECT id INTO v_contact_id
      FROM marketing.crm_contacts
      WHERE lead_linkedin_id = v_conv.lead_linkedin_id
      LIMIT 1;
    END IF;

    IF v_contact_id IS NULL AND v_norm_url IS NOT NULL THEN
      SELECT cc.id INTO v_contact_id
      FROM marketing.crm_contacts cc
      JOIN marketing.sendpilot_leads sl ON sl.id = cc.sendpilot_lead_id
      WHERE marketing.normalize_linkedin_url(sl.linkedin_url) = v_norm_url
      LIMIT 1;
    END IF;

    IF v_contact_id IS NULL AND v_conv.lead_name IS NOT NULL THEN
      SELECT count(*) INTO v_name_match_count
      FROM marketing.crm_contacts
      WHERE deleted_at IS NULL
        AND lower(btrim(display_name)) = lower(btrim(v_conv.lead_name));

      IF v_name_match_count = 1 THEN
        SELECT id INTO v_contact_id
        FROM marketing.crm_contacts
        WHERE deleted_at IS NULL
          AND lower(btrim(display_name)) = lower(btrim(v_conv.lead_name))
        LIMIT 1;
      END IF;
    END IF;

    SELECT sl.* INTO v_joined_lead
    FROM marketing.sendpilot_leads sl
    WHERE marketing.normalize_linkedin_url(sl.linkedin_url) = v_norm_url
       OR (v_conv.lead_linkedin_id IS NOT NULL AND sl.external_id = v_conv.lead_linkedin_id)
    LIMIT 1;

    IF v_contact_id IS NULL AND v_conv.lead_name IS NOT NULL THEN
      INSERT INTO marketing.crm_contacts (
        display_name, avatar_url, linkedin_url_normalized, lead_linkedin_id,
        sendpilot_conversation_id, lead_source, lifecycle_stage, last_synced_at,
        last_contacted_at
      ) VALUES (
        v_conv.lead_name,
        v_conv.lead_profile_picture,
        v_norm_url,
        v_conv.lead_linkedin_id,
        v_conv.id,
        'sendpilot',
        'lead',
        now(),
        COALESCE(v_conv.last_message_sent_at, v_conv.last_activity_at)
      )
      RETURNING id INTO v_contact_id;
      v_contacts_upserted := v_contacts_upserted + 1;

      INSERT INTO marketing.crm_contact_type_assignments (contact_id, type_id)
      VALUES (v_contact_id, v_linkedin_type_id)
      ON CONFLICT DO NOTHING;
    ELSIF v_contact_id IS NOT NULL THEN
      UPDATE marketing.crm_contacts SET
        sendpilot_conversation_id = COALESCE(sendpilot_conversation_id, v_conv.id),
        lead_linkedin_id = COALESCE(lead_linkedin_id, v_conv.lead_linkedin_id),
        avatar_url = COALESCE(avatar_url, v_conv.lead_profile_picture),
        linkedin_url_normalized = COALESCE(linkedin_url_normalized, v_norm_url),
        display_name = CASE
          WHEN display_name IN ('Unknown Lead', '') OR display_name IS NULL
          THEN COALESCE(v_conv.lead_name, display_name)
          ELSE display_name
        END,
        sendpilot_lead_id = COALESCE(
          sendpilot_lead_id,
          v_joined_lead.id
        ),
        last_contacted_at = GREATEST(
          last_contacted_at,
          v_conv.last_message_sent_at,
          v_conv.last_activity_at
        ),
        last_synced_at = now(),
        updated_at = now()
      WHERE id = v_contact_id;
      v_conversations_linked := v_conversations_linked + 1;
    END IF;

    IF v_contact_id IS NOT NULL THEN
      INSERT INTO marketing.crm_contact_profiles (
        contact_id, job_title, headline, current_company,
        last_message_sent_at, last_reply_received_at, conversation_status, outreach_status
      ) VALUES (
        v_contact_id,
        COALESCE(v_conv.lead_title, v_joined_lead.title),
        COALESCE(v_conv.lead_title, v_joined_lead.title),
        COALESCE(v_conv.lead_company, v_joined_lead.company),
        CASE WHEN v_conv.last_message_direction = 'sent' THEN v_conv.last_message_sent_at ELSE NULL END,
        CASE WHEN v_conv.last_message_direction = 'received' THEN v_conv.last_message_sent_at ELSE NULL END,
        v_conv.last_message_direction,
        v_joined_lead.status
      )
      ON CONFLICT (contact_id) DO UPDATE SET
        job_title = COALESCE(EXCLUDED.job_title, crm_contact_profiles.job_title),
        headline = COALESCE(EXCLUDED.headline, crm_contact_profiles.headline),
        current_company = COALESCE(EXCLUDED.current_company, crm_contact_profiles.current_company),
        last_message_sent_at = COALESCE(EXCLUDED.last_message_sent_at, crm_contact_profiles.last_message_sent_at),
        last_reply_received_at = COALESCE(EXCLUDED.last_reply_received_at, crm_contact_profiles.last_reply_received_at),
        conversation_status = COALESCE(EXCLUDED.conversation_status, crm_contact_profiles.conversation_status),
        outreach_status = COALESCE(EXCLUDED.outreach_status, crm_contact_profiles.outreach_status),
        updated_at = now();

      IF v_norm_url IS NOT NULL OR v_conv.lead_profile_url IS NOT NULL THEN
        INSERT INTO marketing.crm_contact_platform_accounts (
          contact_id, platform_id, profile_url, external_id, raw_data,
          is_primary, sync_status, last_synced_at
        ) VALUES (
          v_contact_id,
          v_linkedin_platform_id,
          COALESCE(v_conv.lead_profile_url, v_norm_url),
          v_conv.lead_linkedin_id,
          COALESCE(v_conv.lead_participant, '{}'::jsonb),
          true,
          'synced',
          now()
        )
        ON CONFLICT (contact_id, platform_id, profile_url) DO UPDATE SET
          external_id = COALESCE(EXCLUDED.external_id, crm_contact_platform_accounts.external_id),
          raw_data = CASE
            WHEN EXCLUDED.raw_data <> '{}'::jsonb THEN EXCLUDED.raw_data
            ELSE crm_contact_platform_accounts.raw_data
          END,
          last_synced_at = now(),
          sync_status = 'synced',
          updated_at = now();
      END IF;

      INSERT INTO marketing.crm_communication_threads (
        contact_id, channel, sendpilot_conversation_id, updated_at
      ) VALUES (
        v_contact_id, 'linkedin', v_conv.id, COALESCE(v_conv.last_activity_at, now())
      )
      ON CONFLICT (sendpilot_conversation_id) DO UPDATE SET
        updated_at = COALESCE(EXCLUDED.updated_at, crm_communication_threads.updated_at);

      SELECT id INTO v_thread_id
      FROM marketing.crm_communication_threads
      WHERE sendpilot_conversation_id = v_conv.id;

      FOR v_msg IN
        SELECT * FROM marketing.sendpilot_messages
        WHERE conversation_id = v_conv.id
        ORDER BY sent_at ASC
      LOOP
        v_direction := CASE
          WHEN v_msg.direction = 'received' THEN 'inbound'::marketing.crm_comm_direction
          ELSE 'outbound'::marketing.crm_comm_direction
        END;
        v_status := 'sent'::marketing.crm_comm_status;

        INSERT INTO marketing.crm_communications (
          thread_id, contact_id, channel, direction, body, status,
          sendpilot_message_id, is_automated, occurred_at
        ) VALUES (
          v_thread_id, v_contact_id, 'linkedin', v_direction, v_msg.body, v_status,
          v_msg.sendpilot_message_id, true, v_msg.sent_at
        )
        ON CONFLICT (sendpilot_message_id) DO NOTHING;

        IF FOUND THEN
          v_messages_mirrored := v_messages_mirrored + 1;
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  -- Phase 3: Reconcile orphan contacts missing conversation link or avatar
  WITH reconciled AS (
    UPDATE marketing.crm_contacts cc
    SET
      sendpilot_conversation_id = COALESCE(cc.sendpilot_conversation_id, sp.id),
      lead_linkedin_id = COALESCE(cc.lead_linkedin_id, sp.lead_linkedin_id),
      avatar_url = COALESCE(cc.avatar_url, sp.lead_profile_picture),
      last_contacted_at = GREATEST(
        cc.last_contacted_at,
        sp.last_message_sent_at,
        sp.last_activity_at
      ),
      last_synced_at = now(),
      updated_at = now()
    FROM marketing.sendpilot_conversations sp
    WHERE cc.deleted_at IS NULL
      AND (cc.sendpilot_conversation_id IS NULL OR cc.avatar_url IS NULL OR cc.last_contacted_at IS NULL)
      AND (
        cc.sendpilot_conversation_id = sp.id
        OR (
          cc.linkedin_url_normalized IS NOT NULL
          AND marketing.normalize_linkedin_url(sp.lead_profile_url) = cc.linkedin_url_normalized
        )
        OR (
          cc.lead_linkedin_id IS NOT NULL
          AND sp.lead_linkedin_id = cc.lead_linkedin_id
        )
      )
    RETURNING cc.id
  )
  SELECT count(*) INTO v_reconciled FROM reconciled;

  UPDATE marketing.crm_contact_profiles prof
  SET
    job_title = COALESCE(prof.job_title, sp.lead_title, l.title),
    headline = COALESCE(prof.headline, sp.lead_title, l.title),
    current_company = COALESCE(prof.current_company, sp.lead_company, l.company),
    outreach_status = COALESCE(prof.outreach_status, l.status),
    updated_at = now()
  FROM marketing.crm_contacts cc
  LEFT JOIN marketing.sendpilot_conversations sp ON sp.id = cc.sendpilot_conversation_id
  LEFT JOIN marketing.sendpilot_leads l ON l.id = cc.sendpilot_lead_id
  WHERE prof.contact_id = cc.id
    AND cc.deleted_at IS NULL
    AND (
      prof.headline IS NULL
      OR prof.job_title IS NULL
      OR prof.current_company IS NULL
    );

  INSERT INTO marketing.crm_activity_logs (entity_type, entity_id, action, metadata)
  VALUES (
    'sync', gen_random_uuid(), 'sendpilot_sync',
    jsonb_build_object(
      'contacts_upserted', v_contacts_upserted,
      'conversations_linked', v_conversations_linked,
      'messages_mirrored', v_messages_mirrored,
      'reconciled', v_reconciled
    )
  );

  RETURN jsonb_build_object(
    'contacts_upserted', v_contacts_upserted,
    'conversations_linked', v_conversations_linked,
    'messages_mirrored', v_messages_mirrored,
    'reconciled', v_reconciled,
    'errors', '[]'::jsonb
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.crm_sync_from_sendpilot()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT marketing.crm_sync_from_sendpilot();
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
