-- Migration: 024_crm_sync_extractor.sql
-- Sync Lead Extractor fields (experience, education, skills) into CRM contacts.

BEGIN;

CREATE OR REPLACE FUNCTION marketing.crm_sync_extractor_leads()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
DECLARE
  v_linkedin_type_id uuid;
  v_linkedin_platform_id uuid;
  v_contacts_upserted integer := 0;
  v_lead record;
  v_contact_id uuid;
  v_norm_url text;
  v_display_name text;
  v_lead_source text;
BEGIN
  SELECT id INTO v_linkedin_type_id FROM marketing.crm_contact_types WHERE slug = 'linkedin_lead';
  SELECT id INTO v_linkedin_platform_id FROM marketing.crm_platforms WHERE slug = 'linkedin';

  FOR v_lead IN
    SELECT * FROM marketing.sendpilot_leads WHERE lead_source = 'extractor'
  LOOP
    v_norm_url := marketing.normalize_linkedin_url(v_lead.linkedin_url);
    v_display_name := NULLIF(
      btrim(COALESCE(v_lead.first_name, '') || ' ' || COALESCE(v_lead.last_name, '')),
      ''
    );
    v_lead_source := 'sendpilot_extractor';

    v_contact_id := NULL;
    IF v_norm_url IS NOT NULL THEN
      SELECT id INTO v_contact_id
      FROM marketing.crm_contacts
      WHERE linkedin_url_normalized = v_norm_url
      LIMIT 1;
    END IF;

    IF v_contact_id IS NULL AND v_lead.linkedin_identifier IS NOT NULL THEN
      SELECT id INTO v_contact_id
      FROM marketing.crm_contacts
      WHERE lead_linkedin_id = v_lead.linkedin_identifier
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
          display_name, first_name, last_name, primary_email, primary_phone, avatar_url,
          linkedin_url_normalized, lead_linkedin_id, sendpilot_lead_id, lead_source,
          lifecycle_stage, last_synced_at
        ) VALUES (
          COALESCE(v_display_name, 'Unknown Lead'),
          v_lead.first_name, v_lead.last_name, v_lead.email, v_lead.phone,
          v_lead.profile_picture_url, v_norm_url, v_lead.linkedin_identifier, v_lead.id,
          v_lead_source, 'lead', now()
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
        primary_phone = COALESCE(v_lead.phone, primary_phone),
        avatar_url = COALESCE(avatar_url, v_lead.profile_picture_url),
        lead_linkedin_id = COALESCE(lead_linkedin_id, v_lead.linkedin_identifier),
        linkedin_url_normalized = marketing.coalesce_linkedin_url(
          v_contact_id, linkedin_url_normalized, v_norm_url
        ),
        sendpilot_lead_id = COALESCE(sendpilot_lead_id, v_lead.id),
        lead_source = CASE
          WHEN lead_source IS NULL OR lead_source = 'sendpilot' THEN v_lead_source
          ELSE lead_source
        END,
        last_synced_at = now(),
        updated_at = now()
      WHERE id = v_contact_id;

      INSERT INTO marketing.crm_contact_type_assignments (contact_id, type_id)
      VALUES (v_contact_id, v_linkedin_type_id)
      ON CONFLICT DO NOTHING;

      INSERT INTO marketing.crm_contact_profiles (
        contact_id, job_title, headline, current_company, outreach_status,
        about, location, industry, follower_count, experience, education, skills
      ) VALUES (
        v_contact_id,
        v_lead.title,
        COALESCE(v_lead.linkedin_headline, v_lead.title),
        v_lead.company,
        COALESCE(v_lead.custom_lead_status, v_lead.status),
        v_lead.about,
        v_lead.location,
        v_lead.industry,
        v_lead.follower_count,
        COALESCE(v_lead.experience, '[]'::jsonb),
        COALESCE(v_lead.education, '[]'::jsonb),
        COALESCE(v_lead.skills, '[]'::jsonb)
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
        experience = CASE
          WHEN EXCLUDED.experience <> '[]'::jsonb THEN EXCLUDED.experience
          ELSE crm_contact_profiles.experience
        END,
        education = CASE
          WHEN EXCLUDED.education <> '[]'::jsonb THEN EXCLUDED.education
          ELSE crm_contact_profiles.education
        END,
        skills = CASE
          WHEN EXCLUDED.skills <> '[]'::jsonb THEN EXCLUDED.skills
          ELSE crm_contact_profiles.skills
        END,
        updated_at = now();

      IF v_norm_url IS NOT NULL OR v_lead.linkedin_url IS NOT NULL THEN
        INSERT INTO marketing.crm_contact_platform_accounts (
          contact_id, platform_id, profile_url, external_id, raw_data,
          is_primary, sync_status, last_synced_at
        ) VALUES (
          v_contact_id, v_linkedin_platform_id,
          COALESCE(v_lead.linkedin_url, v_norm_url),
          v_lead.linkedin_identifier,
          COALESCE(v_lead.raw_profile, '{}'::jsonb),
          true, 'synced', now()
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
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'contacts_upserted', v_contacts_upserted,
    'source', 'extractor'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION marketing.crm_sync_extractor_leads() TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
