-- Migration: 022_crm_sync_linkedin_dedupe.sql
-- Avoid unique violations when syncing leads whose normalized URL belongs to another contact.

BEGIN;

CREATE OR REPLACE FUNCTION marketing.coalesce_linkedin_url(
  p_contact_id uuid,
  p_current text,
  p_new text
) RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = marketing, public
AS $$
BEGIN
  IF p_new IS NULL OR btrim(p_new) = '' THEN
    RETURN p_current;
  END IF;
  IF p_current IS NOT DISTINCT FROM p_new THEN
    RETURN p_current;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM marketing.crm_contacts c
    WHERE c.linkedin_url_normalized = p_new
      AND c.id <> p_contact_id
  ) THEN
    RETURN p_current;
  END IF;
  RETURN p_new;
END;
$$;

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

    v_contact_id := NULL;
    IF v_norm_url IS NOT NULL THEN
      SELECT id INTO v_contact_id
      FROM marketing.crm_contacts
      WHERE linkedin_url_normalized = v_norm_url
      LIMIT 1;
    END IF;

    IF v_contact_id IS NULL THEN
      SELECT id INTO v_contact_id
      FROM marketing.crm_contacts
      WHERE sendpilot_lead_id = v_lead.id
      LIMIT 1;
    END IF;

    IF v_contact_id IS NULL THEN
      BEGIN
        INSERT INTO marketing.crm_contacts (
          display_name, first_name, last_name, primary_email, avatar_url,
          linkedin_url_normalized, sendpilot_lead_id, lead_source,
          lifecycle_stage, last_synced_at
        ) VALUES (
          COALESCE(v_display_name, 'Unknown Lead'),
          v_lead.first_name, v_lead.last_name, v_lead.email, v_lead.profile_picture_url,
          v_norm_url, v_lead.id, 'sendpilot',
          'lead', now()
        )
        RETURNING id INTO v_contact_id;
        v_contacts_upserted := v_contacts_upserted + 1;
      EXCEPTION WHEN unique_violation THEN
        IF v_norm_url IS NOT NULL THEN
          SELECT id INTO v_contact_id
          FROM marketing.crm_contacts
          WHERE linkedin_url_normalized = v_norm_url
          LIMIT 1;
        END IF;
      END;
    END IF;

    IF v_contact_id IS NOT NULL THEN
      UPDATE marketing.crm_contacts SET
        display_name = COALESCE(NULLIF(display_name, 'Unknown Lead'), v_display_name, display_name),
        first_name = COALESCE(v_lead.first_name, first_name),
        last_name = COALESCE(v_lead.last_name, last_name),
        primary_email = COALESCE(v_lead.email, primary_email),
        avatar_url = COALESCE(avatar_url, v_lead.profile_picture_url),
        linkedin_url_normalized = marketing.coalesce_linkedin_url(
          v_contact_id, linkedin_url_normalized, v_norm_url
        ),
        sendpilot_lead_id = COALESCE(sendpilot_lead_id, v_lead.id),
        last_synced_at = now(),
        updated_at = now()
      WHERE id = v_contact_id;

      INSERT INTO marketing.crm_contact_type_assignments (contact_id, type_id)
      VALUES (v_contact_id, v_linkedin_type_id)
      ON CONFLICT DO NOTHING;

      INSERT INTO marketing.crm_contact_profiles (
        contact_id, job_title, headline, current_company, outreach_status,
        about, location, industry, follower_count
      ) VALUES (
        v_contact_id,
        v_lead.title,
        COALESCE(v_lead.linkedin_headline, v_lead.title),
        v_lead.company,
        COALESCE(v_lead.custom_lead_status, v_lead.status),
        v_lead.about,
        v_lead.location,
        v_lead.industry,
        v_lead.follower_count
      )
      ON CONFLICT (contact_id) DO UPDATE SET
        job_title = COALESCE(EXCLUDED.job_title, crm_contact_profiles.job_title),
        headline = COALESCE(EXCLUDED.headline, crm_contact_profiles.headline),
        current_company = COALESCE(EXCLUDED.current_company, crm_contact_profiles.current_company),
        outreach_status = COALESCE(EXCLUDED.outreach_status, crm_contact_profiles.outreach_status),
        about = COALESCE(EXCLUDED.about, crm_contact_profiles.about),
        location = COALESCE(EXCLUDED.location, crm_contact_profiles.location),
        industry = COALESCE(EXCLUDED.industry, crm_contact_profiles.industry),
        follower_count = COALESCE(EXCLUDED.follower_count, crm_contact_profiles.follower_count),
        updated_at = now();

      IF v_norm_url IS NOT NULL THEN
        INSERT INTO marketing.crm_contact_platform_accounts (
          contact_id, platform_id, profile_url, raw_data, is_primary, sync_status, last_synced_at
        ) VALUES (
          v_contact_id, v_linkedin_platform_id, v_lead.linkedin_url,
          COALESCE(v_lead.raw_profile, '{}'::jsonb), true, 'synced', now()
        )
        ON CONFLICT (contact_id, platform_id, profile_url) DO UPDATE SET
          raw_data = CASE
            WHEN EXCLUDED.raw_data <> '{}'::jsonb THEN EXCLUDED.raw_data
            ELSE crm_contact_platform_accounts.raw_data
          END,
          last_synced_at = now(),
          sync_status = 'synced',
          updated_at = now();
      END IF;
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
      BEGIN
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
      EXCEPTION WHEN unique_violation THEN
        IF v_norm_url IS NOT NULL THEN
          SELECT id INTO v_contact_id
          FROM marketing.crm_contacts
          WHERE linkedin_url_normalized = v_norm_url
          LIMIT 1;
        END IF;
      END;
    ELSIF v_contact_id IS NOT NULL THEN
      UPDATE marketing.crm_contacts SET
        sendpilot_conversation_id = COALESCE(sendpilot_conversation_id, v_conv.id),
        lead_linkedin_id = COALESCE(lead_linkedin_id, v_conv.lead_linkedin_id),
        avatar_url = COALESCE(avatar_url, v_conv.lead_profile_picture),
        linkedin_url_normalized = marketing.coalesce_linkedin_url(
          v_contact_id, linkedin_url_normalized, v_norm_url
        ),
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
        last_message_sent_at, last_reply_received_at, conversation_status, outreach_status,
        about, location, industry, follower_count
      ) VALUES (
        v_contact_id,
        COALESCE(v_conv.lead_title, v_joined_lead.title),
        COALESCE(v_joined_lead.linkedin_headline, v_conv.lead_title, v_joined_lead.title),
        COALESCE(v_conv.lead_company, v_joined_lead.company),
        CASE WHEN v_conv.last_message_direction = 'sent' THEN v_conv.last_message_sent_at ELSE NULL END,
        CASE WHEN v_conv.last_message_direction = 'received' THEN v_conv.last_message_sent_at ELSE NULL END,
        v_conv.last_message_direction,
        COALESCE(v_joined_lead.custom_lead_status, v_joined_lead.status),
        v_joined_lead.about,
        v_joined_lead.location,
        v_joined_lead.industry,
        v_joined_lead.follower_count
      )
      ON CONFLICT (contact_id) DO UPDATE SET
        job_title = COALESCE(EXCLUDED.job_title, crm_contact_profiles.job_title),
        headline = COALESCE(EXCLUDED.headline, crm_contact_profiles.headline),
        current_company = COALESCE(EXCLUDED.current_company, crm_contact_profiles.current_company),
        last_message_sent_at = COALESCE(EXCLUDED.last_message_sent_at, crm_contact_profiles.last_message_sent_at),
        last_reply_received_at = COALESCE(EXCLUDED.last_reply_received_at, crm_contact_profiles.last_reply_received_at),
        conversation_status = COALESCE(EXCLUDED.conversation_status, crm_contact_profiles.conversation_status),
        outreach_status = COALESCE(EXCLUDED.outreach_status, crm_contact_profiles.outreach_status),
        about = COALESCE(EXCLUDED.about, crm_contact_profiles.about),
        location = COALESCE(EXCLUDED.location, crm_contact_profiles.location),
        industry = COALESCE(EXCLUDED.industry, crm_contact_profiles.industry),
        follower_count = COALESCE(EXCLUDED.follower_count, crm_contact_profiles.follower_count),
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
    headline = COALESCE(prof.headline, l.linkedin_headline, sp.lead_title, l.title),
    current_company = COALESCE(prof.current_company, sp.lead_company, l.company),
    outreach_status = COALESCE(prof.outreach_status, l.custom_lead_status, l.status),
    about = COALESCE(prof.about, l.about),
    location = COALESCE(prof.location, l.location),
    industry = COALESCE(prof.industry, l.industry),
    follower_count = COALESCE(prof.follower_count, l.follower_count),
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
      OR prof.about IS NULL
      OR prof.location IS NULL
      OR prof.industry IS NULL
      OR prof.follower_count IS NULL
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

DROP VIEW IF EXISTS public.crm_contacts CASCADE;
CREATE VIEW public.crm_contacts AS
  SELECT * FROM marketing.crm_contacts;

GRANT SELECT ON public.crm_contacts TO anon, authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON public.crm_contacts TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
