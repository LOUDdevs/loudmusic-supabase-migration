-- Email → CRM auto-sync: create/enrich contacts from threads, mirror communications.

BEGIN;

-- ============================================================================
-- 1. Schema additions
-- ============================================================================

ALTER TABLE marketing.crm_communication_threads
  ADD COLUMN IF NOT EXISTS email_thread_id uuid UNIQUE
    REFERENCES marketing.email_threads (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_crm_comm_threads_email
  ON marketing.crm_communication_threads (email_thread_id)
  WHERE email_thread_id IS NOT NULL;

ALTER TABLE marketing.crm_communications
  ADD COLUMN IF NOT EXISTS email_message_id uuid UNIQUE
    REFERENCES marketing.emails (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_crm_comms_email_msg
  ON marketing.crm_communications (email_message_id)
  WHERE email_message_id IS NOT NULL;

-- ============================================================================
-- 2. Helpers
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.is_system_email(p_email text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_email text := lower(btrim(COALESCE(p_email, '')));
  v_local text;
BEGIN
  IF v_email = '' OR v_email NOT LIKE '%@%' THEN
    RETURN true;
  END IF;

  v_local := split_part(v_email, '@', 1);

  IF v_local ~* '(^mailer-daemon$|^postmaster$|^noreply$|^no-reply$|^donotreply$|^do-not-reply$|^bounce$|^bounces$|^notifications$|^notify$|^newsletter$|^news$|^support-noreply$|^account-security$)' THEN
    RETURN true;
  END IF;

  IF v_local ~* '(noreply|no-reply|donotreply|do-not-reply|mailer-daemon|postmaster)' THEN
    RETURN true;
  END IF;

  IF split_part(v_email, '@', 2) ~* '^mailer-daemon\.' THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION marketing.parse_display_name_parts(p_name text, p_email text)
RETURNS TABLE(first_name text, last_name text, display_name text)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_display text;
  v_space int;
BEGIN
  v_display := NULLIF(btrim(COALESCE(p_name, '')), '');
  IF v_display IS NULL THEN
    v_display := split_part(lower(btrim(COALESCE(p_email, ''))), '@', 1);
  END IF;
  IF v_display = '' THEN
    v_display := 'Unknown Contact';
  END IF;

  v_space := position(' ' IN v_display);
  IF v_space > 0 THEN
    first_name := btrim(substring(v_display FROM 1 FOR v_space - 1));
    last_name := NULLIF(btrim(substring(v_display FROM v_space + 1)), '');
  ELSE
    first_name := v_display;
    last_name := NULL;
  END IF;

  display_name := v_display;
  RETURN NEXT;
END;
$$;

-- ============================================================================
-- 3. Core sync RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.email_sync_contact_from_thread(p_thread_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
DECLARE
  v_contact_id uuid;
  v_counterparty_email text;
  v_sender_name text;
  v_thread_subject text;
  v_last_contacted timestamptz;
  v_lead marketing.sendpilot_leads%ROWTYPE;
  v_first_name text;
  v_last_name text;
  v_display_name text;
  v_company text;
  v_job_title text;
  v_norm_url text;
  v_prospect_type_id uuid;
  v_linkedin_type_id uuid;
  v_email_platform_id uuid;
  v_linkedin_platform_id uuid;
  v_comm_thread_id uuid;
  v_msg record;
  v_direction marketing.crm_comm_direction;
  v_messages_mirrored int := 0;
BEGIN
  SELECT t.linked_contact_id, t.subject, t.last_message_at
  INTO v_contact_id, v_thread_subject, v_last_contacted
  FROM marketing.email_threads t
  WHERE t.id = p_thread_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT lower(btrim(e.sender_email)), NULLIF(btrim(e.sender_name), '')
  INTO v_counterparty_email, v_sender_name
  FROM marketing.emails e
  WHERE e.thread_id = p_thread_id AND e.direction = 'inbound'
  ORDER BY COALESCE(e.received_at, e.sent_at) DESC NULLS LAST
  LIMIT 1;

  IF v_counterparty_email IS NULL OR v_counterparty_email = '' THEN
    SELECT lower(btrim(e.recipients->0->>'email'))
    INTO v_counterparty_email
    FROM marketing.emails e
    WHERE e.thread_id = p_thread_id
      AND e.direction = 'outbound'
      AND jsonb_array_length(COALESCE(e.recipients, '[]'::jsonb)) > 0
    ORDER BY COALESCE(e.sent_at, e.received_at) DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF v_counterparty_email IS NULL OR v_counterparty_email = '' THEN
    RETURN v_contact_id;
  END IF;

  IF marketing.is_system_email(v_counterparty_email) THEN
    RETURN NULL;
  END IF;

  IF v_contact_id IS NULL THEN
    SELECT c.id INTO v_contact_id
    FROM marketing.crm_contacts c
    WHERE c.deleted_at IS NULL
      AND lower(btrim(c.primary_email)) = v_counterparty_email
    LIMIT 1;

    IF v_contact_id IS NULL THEN
      SELECT c.id INTO v_contact_id
      FROM marketing.crm_contacts c
      WHERE c.deleted_at IS NULL
        AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(c.emails, '[]'::jsonb)) elem
          WHERE lower(btrim(
            CASE
              WHEN jsonb_typeof(elem) = 'string' THEN elem #>> '{}'
              ELSE elem->>'email'
            END
          )) = v_counterparty_email
        )
      LIMIT 1;
    END IF;

    SELECT sl.* INTO v_lead
    FROM marketing.sendpilot_leads sl
    WHERE sl.email IS NOT NULL
      AND lower(btrim(sl.email)) = v_counterparty_email
    ORDER BY sl.updated_at DESC NULLS LAST
    LIMIT 1;

    IF v_contact_id IS NULL AND v_lead.id IS NOT NULL THEN
      SELECT c.id INTO v_contact_id
      FROM marketing.crm_contacts c
      WHERE c.deleted_at IS NULL
        AND c.sendpilot_lead_id = v_lead.id
      LIMIT 1;
    END IF;

    SELECT p.first_name, p.last_name, p.display_name
    INTO v_first_name, v_last_name, v_display_name
    FROM marketing.parse_display_name_parts(v_sender_name, v_counterparty_email) p;

    IF v_lead.id IS NOT NULL THEN
      v_first_name := COALESCE(NULLIF(btrim(v_lead.first_name), ''), v_first_name);
      v_last_name := COALESCE(NULLIF(btrim(v_lead.last_name), ''), v_last_name);
      v_display_name := COALESCE(
        NULLIF(btrim(COALESCE(v_lead.first_name, '') || ' ' || COALESCE(v_lead.last_name, '')), ''),
        v_display_name
      );
      v_company := NULLIF(btrim(v_lead.company), '');
      v_job_title := NULLIF(btrim(v_lead.title), '');
      v_norm_url := marketing.normalize_linkedin_url(v_lead.linkedin_url);
    END IF;

    IF v_contact_id IS NULL THEN
      INSERT INTO marketing.crm_contacts (
        display_name, first_name, last_name, primary_email,
        linkedin_url_normalized, sendpilot_lead_id,
        lead_source, lifecycle_stage, last_contacted_at, last_synced_at
      ) VALUES (
        v_display_name,
        v_first_name,
        v_last_name,
        v_counterparty_email,
        v_norm_url,
        v_lead.id,
        'email',
        'lead',
        v_last_contacted,
        now()
      )
      RETURNING id INTO v_contact_id;
    ELSE
      UPDATE marketing.crm_contacts SET
        display_name = COALESCE(NULLIF(display_name, ''), v_display_name, display_name),
        first_name = COALESCE(v_first_name, first_name),
        last_name = COALESCE(v_last_name, last_name),
        primary_email = COALESCE(primary_email, v_counterparty_email),
        linkedin_url_normalized = COALESCE(linkedin_url_normalized, v_norm_url),
        sendpilot_lead_id = COALESCE(sendpilot_lead_id, v_lead.id),
        last_contacted_at = GREATEST(last_contacted_at, v_last_contacted),
        last_synced_at = now(),
        updated_at = now()
      WHERE id = v_contact_id;
    END IF;

    UPDATE marketing.email_threads
    SET linked_contact_id = v_contact_id, updated_at = now()
    WHERE id = p_thread_id;

    INSERT INTO marketing.email_contact_links (email_thread_id, contact_id, link_type, confidence_score)
    VALUES (p_thread_id, v_contact_id, 'auto_email_sync', 0.95)
    ON CONFLICT (email_thread_id, contact_id) DO UPDATE SET
      link_type = EXCLUDED.link_type,
      confidence_score = EXCLUDED.confidence_score;

    SELECT id INTO v_prospect_type_id FROM marketing.crm_contact_types WHERE slug = 'prospect';
    SELECT id INTO v_linkedin_type_id FROM marketing.crm_contact_types WHERE slug = 'linkedin_lead';
    SELECT id INTO v_email_platform_id FROM marketing.crm_platforms WHERE slug = 'email';

    IF v_prospect_type_id IS NOT NULL THEN
      INSERT INTO marketing.crm_contact_type_assignments (contact_id, type_id)
      VALUES (v_contact_id, v_prospect_type_id)
      ON CONFLICT DO NOTHING;
    END IF;

    IF v_lead.id IS NOT NULL AND v_linkedin_type_id IS NOT NULL THEN
      INSERT INTO marketing.crm_contact_type_assignments (contact_id, type_id)
      VALUES (v_contact_id, v_linkedin_type_id)
      ON CONFLICT DO NOTHING;
    END IF;

    IF v_company IS NOT NULL OR v_job_title IS NOT NULL THEN
      INSERT INTO marketing.crm_contact_profiles (contact_id, job_title, headline, current_company)
      VALUES (v_contact_id, v_job_title, v_job_title, v_company)
      ON CONFLICT (contact_id) DO UPDATE SET
        job_title = COALESCE(EXCLUDED.job_title, crm_contact_profiles.job_title),
        headline = COALESCE(EXCLUDED.headline, crm_contact_profiles.headline),
        current_company = COALESCE(EXCLUDED.current_company, crm_contact_profiles.current_company),
        updated_at = now();
    END IF;

    IF v_email_platform_id IS NOT NULL THEN
      INSERT INTO marketing.crm_contact_platform_accounts (
        contact_id, platform_id, profile_url, external_id, is_primary, sync_status, last_synced_at
      ) VALUES (
        v_contact_id,
        v_email_platform_id,
        'mailto:' || v_counterparty_email,
        v_counterparty_email,
        true,
        'synced',
        now()
      )
      ON CONFLICT (contact_id, platform_id, profile_url) DO UPDATE SET
        external_id = COALESCE(EXCLUDED.external_id, crm_contact_platform_accounts.external_id),
        last_synced_at = now(),
        sync_status = 'synced',
        updated_at = now();
    END IF;

    IF v_norm_url IS NOT NULL THEN
      SELECT id INTO v_linkedin_platform_id FROM marketing.crm_platforms WHERE slug = 'linkedin';
      IF v_linkedin_platform_id IS NOT NULL THEN
        INSERT INTO marketing.crm_contact_platform_accounts (
          contact_id, platform_id, profile_url, is_primary, sync_status, last_synced_at
        ) VALUES (
          v_contact_id, v_linkedin_platform_id, v_lead.linkedin_url, false, 'synced', now()
        )
        ON CONFLICT (contact_id, platform_id, profile_url) DO UPDATE SET
          last_synced_at = now(),
          sync_status = 'synced',
          updated_at = now();
      END IF;
    END IF;
  ELSE
    UPDATE marketing.crm_contacts SET
      last_contacted_at = GREATEST(last_contacted_at, v_last_contacted),
      updated_at = now()
    WHERE id = v_contact_id;
  END IF;

  INSERT INTO marketing.crm_communication_threads (
    contact_id, channel, subject, email_thread_id, updated_at
  ) VALUES (
    v_contact_id, 'email', v_thread_subject, p_thread_id, COALESCE(v_last_contacted, now())
  )
  ON CONFLICT (email_thread_id) DO UPDATE SET
    subject = COALESCE(EXCLUDED.subject, crm_communication_threads.subject),
    updated_at = COALESCE(EXCLUDED.updated_at, crm_communication_threads.updated_at);

  SELECT id INTO v_comm_thread_id
  FROM marketing.crm_communication_threads
  WHERE email_thread_id = p_thread_id;

  FOR v_msg IN
    SELECT e.*
    FROM marketing.emails e
    WHERE e.thread_id = p_thread_id
    ORDER BY COALESCE(e.received_at, e.sent_at) ASC NULLS LAST
  LOOP
    v_direction := CASE
      WHEN v_msg.direction = 'inbound' THEN 'inbound'::marketing.crm_comm_direction
      ELSE 'outbound'::marketing.crm_comm_direction
    END;

    INSERT INTO marketing.crm_communications (
      thread_id, contact_id, channel, direction, body, subject,
      sender, recipient, status, email_message_id, occurred_at
    ) VALUES (
      v_comm_thread_id,
      v_contact_id,
      'email',
      v_direction,
      COALESCE(v_msg.body_text, v_msg.snippet),
      v_msg.subject,
      v_msg.sender_email,
      CASE
        WHEN v_direction = 'inbound' THEN NULL
        ELSE v_counterparty_email
      END,
      'sent'::marketing.crm_comm_status,
      v_msg.id,
      COALESCE(v_msg.received_at, v_msg.sent_at, now())
    )
    ON CONFLICT (email_message_id) DO NOTHING;

    IF FOUND THEN
      v_messages_mirrored := v_messages_mirrored + 1;
    END IF;
  END LOOP;

  RETURN v_contact_id;
END;
$$;

-- Backward-compatible wrapper
CREATE OR REPLACE FUNCTION marketing.email_match_contact(p_thread_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
BEGIN
  RETURN marketing.email_sync_contact_from_thread(p_thread_id);
END;
$$;

-- ============================================================================
-- 4. Batch sync RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.email_sync_unlinked_contacts(p_limit int DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
DECLARE
  v_thread_id uuid;
  v_result uuid;
  v_processed int := 0;
  v_linked int := 0;
  v_skipped int := 0;
BEGIN
  FOR v_thread_id IN
    SELECT t.id
    FROM marketing.email_threads t
    WHERE t.linked_contact_id IS NULL
      AND EXISTS (
        SELECT 1
        FROM marketing.emails e
        WHERE e.thread_id = t.id
          AND e.direction = 'inbound'
          AND e.sender_email IS NOT NULL
          AND btrim(e.sender_email) <> ''
      )
    ORDER BY t.last_message_at DESC NULLS LAST
    LIMIT GREATEST(COALESCE(p_limit, 200), 1)
  LOOP
    v_processed := v_processed + 1;
    v_result := marketing.email_sync_contact_from_thread(v_thread_id);
    IF v_result IS NULL THEN
      v_skipped := v_skipped + 1;
    ELSE
      v_linked := v_linked + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'threads_processed', v_processed,
    'contacts_linked', v_linked,
    'skipped', v_skipped
  );
END;
$$;

-- ============================================================================
-- 5. Public wrappers + grants
-- ============================================================================

CREATE OR REPLACE FUNCTION public.email_sync_contact_from_thread(p_thread_id uuid)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT marketing.email_sync_contact_from_thread(p_thread_id);
$$;

CREATE OR REPLACE FUNCTION public.email_sync_unlinked_contacts(p_limit int DEFAULT 200)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT marketing.email_sync_unlinked_contacts(p_limit);
$$;

CREATE OR REPLACE FUNCTION public.email_match_contact(p_thread_id uuid)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT marketing.email_match_contact(p_thread_id);
$$;

GRANT EXECUTE ON FUNCTION public.email_sync_contact_from_thread(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.email_sync_unlinked_contacts(int) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.email_match_contact(uuid) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
