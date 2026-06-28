-- Migration: 026_email_inbox_foundation.sql
-- Email inbox foundation: accounts, threads, messages, drafts, agent requests, sync logs.
-- Run AFTER 025_expose_crm_sync_extractor.sql.

BEGIN;

-- ============================================================================
-- 1. Enums
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE marketing.email_provider AS ENUM ('smtp', 'gmail', 'outlook', 'imap');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.email_account_status AS ENUM ('active', 'inactive', 'error');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.email_sync_status AS ENUM ('never', 'syncing', 'synced', 'error');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.email_thread_status AS ENUM (
    'open', 'needs_reply', 'replied', 'archived', 'spam'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.email_direction AS ENUM ('inbound', 'outbound');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.email_draft_status AS ENUM (
    'none', 'pending', 'generated', 'needs_review', 'approved', 'rejected', 'failed', 'sent'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.email_agent_request_status AS ENUM (
    'draft', 'pending', 'sent', 'processing', 'completed', 'failed'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.email_sync_log_status AS ENUM ('running', 'success', 'error');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ============================================================================
-- 2. Tables
-- ============================================================================

CREATE TABLE marketing.email_accounts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  provider          marketing.email_provider NOT NULL DEFAULT 'smtp',
  account_email     text NOT NULL,
  display_name      text,
  status            marketing.email_account_status NOT NULL DEFAULT 'inactive',
  sync_status       marketing.email_sync_status NOT NULL DEFAULT 'never',
  last_synced_at    timestamptz,
  config            jsonb NOT NULL DEFAULT '{}'::jsonb,
  credentials_env_key text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_email_accounts_user ON marketing.email_accounts (user_id);
CREATE INDEX idx_email_accounts_status ON marketing.email_accounts (status);

CREATE TABLE marketing.email_threads (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id              uuid NOT NULL REFERENCES marketing.email_accounts (id) ON DELETE CASCADE,
  provider_thread_id      text,
  subject                 text,
  participants            jsonb NOT NULL DEFAULT '[]'::jsonb,
  last_message_at         timestamptz,
  status                  marketing.email_thread_status NOT NULL DEFAULT 'open',
  unread_count            integer NOT NULL DEFAULT 0,
  has_ai_draft            boolean NOT NULL DEFAULT false,
  needs_reply             boolean NOT NULL DEFAULT false,
  is_important            boolean NOT NULL DEFAULT false,
  is_archived             boolean NOT NULL DEFAULT false,
  priority                integer NOT NULL DEFAULT 0,
  tags                    text[] NOT NULL DEFAULT '{}',
  linked_contact_id       uuid REFERENCES marketing.crm_contacts (id) ON DELETE SET NULL,
  linked_deal_id          uuid REFERENCES marketing.crm_deals (id) ON DELETE SET NULL,
  linked_organization_id  uuid REFERENCES marketing.crm_organizations (id) ON DELETE SET NULL,
  raw_metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, provider_thread_id)
);

CREATE INDEX idx_email_threads_account ON marketing.email_threads (account_id);
CREATE INDEX idx_email_threads_last_msg ON marketing.email_threads (last_message_at DESC NULLS LAST);
CREATE INDEX idx_email_threads_contact ON marketing.email_threads (linked_contact_id);
CREATE INDEX idx_email_threads_needs_reply ON marketing.email_threads (needs_reply) WHERE needs_reply = true;

CREATE TABLE marketing.emails (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id             uuid NOT NULL REFERENCES marketing.email_threads (id) ON DELETE CASCADE,
  account_id            uuid NOT NULL REFERENCES marketing.email_accounts (id) ON DELETE CASCADE,
  provider_message_id   text,
  direction             marketing.email_direction NOT NULL DEFAULT 'inbound',
  sender_name           text,
  sender_email          text,
  recipients            jsonb NOT NULL DEFAULT '[]'::jsonb,
  cc                    jsonb NOT NULL DEFAULT '[]'::jsonb,
  bcc                   jsonb NOT NULL DEFAULT '[]'::jsonb,
  subject               text,
  body_text             text,
  body_html             text,
  snippet               text,
  received_at           timestamptz,
  sent_at               timestamptz,
  is_read               boolean NOT NULL DEFAULT false,
  is_archived           boolean NOT NULL DEFAULT false,
  is_important          boolean NOT NULL DEFAULT false,
  labels                text[] NOT NULL DEFAULT '{}',
  attachments_metadata  jsonb NOT NULL DEFAULT '[]'::jsonb,
  raw_payload           jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, provider_message_id)
);

CREATE INDEX idx_emails_thread ON marketing.emails (thread_id, received_at DESC NULLS LAST);
CREATE INDEX idx_emails_sender ON marketing.emails (sender_email);
CREATE INDEX idx_emails_account ON marketing.emails (account_id);

CREATE TABLE marketing.email_drafts (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id                 uuid NOT NULL REFERENCES marketing.email_threads (id) ON DELETE CASCADE,
  email_id                  uuid REFERENCES marketing.emails (id) ON DELETE SET NULL,
  account_id                uuid NOT NULL REFERENCES marketing.email_accounts (id) ON DELETE CASCADE,
  status                    marketing.email_draft_status NOT NULL DEFAULT 'pending',
  draft_body                text,
  draft_subject             text,
  tone                      text,
  confidence_score          numeric(5, 4),
  reason_summary            text,
  user_instructions         text,
  generated_by              text NOT NULL DEFAULT 'manual',
  generated_by_task_id      uuid,
  generated_by_task_run_id  uuid,
  provider_draft_id         text,
  approved_by               uuid REFERENCES auth.users (id),
  approved_at               timestamptz,
  rejected_by               uuid REFERENCES auth.users (id),
  rejected_at               timestamptz,
  sent_at                   timestamptz,
  error_summary             text,
  error_details             jsonb,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_email_drafts_thread ON marketing.email_drafts (thread_id);
CREATE INDEX idx_email_drafts_status ON marketing.email_drafts (status);
CREATE INDEX idx_email_drafts_review ON marketing.email_drafts (status, created_at DESC)
  WHERE status IN ('generated', 'needs_review');

CREATE TABLE marketing.email_draft_versions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  draft_id          uuid NOT NULL REFERENCES marketing.email_drafts (id) ON DELETE CASCADE,
  version_number    integer NOT NULL,
  draft_body        text NOT NULL,
  user_instructions text,
  generated_by      text NOT NULL DEFAULT 'manual',
  change_summary    text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (draft_id, version_number)
);

CREATE INDEX idx_email_draft_versions_draft ON marketing.email_draft_versions (draft_id, version_number DESC);

CREATE TABLE marketing.email_contact_links (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email_thread_id   uuid NOT NULL REFERENCES marketing.email_threads (id) ON DELETE CASCADE,
  contact_id        uuid NOT NULL REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  link_type         text NOT NULL DEFAULT 'manual',
  confidence_score  numeric(5, 4),
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (email_thread_id, contact_id)
);

CREATE INDEX idx_email_contact_links_contact ON marketing.email_contact_links (contact_id);

CREATE TABLE marketing.email_agent_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id         uuid REFERENCES marketing.email_threads (id) ON DELETE SET NULL,
  email_id          uuid REFERENCES marketing.emails (id) ON DELETE SET NULL,
  draft_id          uuid REFERENCES marketing.email_drafts (id) ON DELETE SET NULL,
  action_type       text NOT NULL,
  user_input        text,
  generated_prompt  text NOT NULL,
  status            marketing.email_agent_request_status NOT NULL DEFAULT 'draft',
  agent_response    text,
  created_by        uuid REFERENCES auth.users (id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_email_agent_requests_status ON marketing.email_agent_requests (status, created_at);

CREATE TABLE marketing.email_sync_logs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id        uuid NOT NULL REFERENCES marketing.email_accounts (id) ON DELETE CASCADE,
  sync_type         text NOT NULL DEFAULT 'inbox',
  status            marketing.email_sync_log_status NOT NULL DEFAULT 'running',
  started_at        timestamptz NOT NULL DEFAULT now(),
  completed_at      timestamptz,
  error_summary     text,
  error_details     jsonb,
  logs              jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_email_sync_logs_account ON marketing.email_sync_logs (account_id, started_at DESC);

-- Extend service_ai_jobs for email threads
ALTER TABLE marketing.service_ai_jobs
  ADD COLUMN IF NOT EXISTS email_thread_id uuid REFERENCES marketing.email_threads (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS email_id uuid REFERENCES marketing.emails (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_ai_jobs_email_thread ON marketing.service_ai_jobs (email_thread_id)
  WHERE email_thread_id IS NOT NULL;

-- ============================================================================
-- 3. Updated_at triggers
-- ============================================================================

CREATE TRIGGER email_accounts_updated_at
  BEFORE UPDATE ON marketing.email_accounts
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

CREATE TRIGGER email_threads_updated_at
  BEFORE UPDATE ON marketing.email_threads
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

CREATE TRIGGER emails_updated_at
  BEFORE UPDATE ON marketing.emails
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

CREATE TRIGGER email_drafts_updated_at
  BEFORE UPDATE ON marketing.email_drafts
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

CREATE TRIGGER email_agent_requests_updated_at
  BEFORE UPDATE ON marketing.email_agent_requests
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

-- ============================================================================
-- 4. Contact matching RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.email_match_contact(p_thread_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = marketing, public
AS $$
DECLARE
  v_contact_id uuid;
  v_sender_email text;
BEGIN
  SELECT lower(btrim(e.sender_email)) INTO v_sender_email
  FROM marketing.emails e
  WHERE e.thread_id = p_thread_id AND e.direction = 'inbound'
  ORDER BY e.received_at DESC NULLS LAST
  LIMIT 1;

  IF v_sender_email IS NULL OR v_sender_email = '' THEN
    RETURN NULL;
  END IF;

  SELECT c.id INTO v_contact_id
  FROM marketing.crm_contacts c
  WHERE lower(btrim(c.primary_email)) = v_sender_email
    AND c.deleted_at IS NULL
  LIMIT 1;

  IF v_contact_id IS NOT NULL THEN
    UPDATE marketing.email_threads
    SET linked_contact_id = v_contact_id, updated_at = now()
    WHERE id = p_thread_id AND linked_contact_id IS NULL;

    INSERT INTO marketing.email_contact_links (email_thread_id, contact_id, link_type, confidence_score)
    VALUES (p_thread_id, v_contact_id, 'auto_email_match', 0.9)
    ON CONFLICT (email_thread_id, contact_id) DO NOTHING;
  END IF;

  RETURN v_contact_id;
END;
$$;

-- ============================================================================
-- 5. Enriched views
-- ============================================================================

CREATE OR REPLACE VIEW marketing.email_inbox_enriched AS
SELECT
  t.id,
  t.account_id,
  t.provider_thread_id,
  t.subject,
  t.participants,
  t.last_message_at,
  t.status,
  t.unread_count,
  t.has_ai_draft,
  t.needs_reply,
  t.is_important,
  t.is_archived,
  t.priority,
  t.tags,
  t.linked_contact_id,
  t.linked_deal_id,
  t.linked_organization_id,
  t.created_at,
  t.updated_at,
  a.account_email,
  a.provider AS account_provider,
  a.display_name AS account_display_name,
  a.sync_status AS account_sync_status,
  a.last_synced_at AS account_last_synced_at,
  c.display_name AS contact_name,
  c.primary_email AS contact_email,
  d.title AS deal_title,
  o.name AS organization_name,
  lm.sender_name AS latest_sender_name,
  lm.sender_email AS latest_sender_email,
  lm.snippet AS latest_snippet,
  lm.direction AS latest_direction,
  lm.received_at AS latest_received_at,
  ed.id AS latest_draft_id,
  ed.status AS latest_draft_status,
  ed.confidence_score AS latest_draft_confidence,
  ed.reason_summary AS latest_draft_reason
FROM marketing.email_threads t
JOIN marketing.email_accounts a ON a.id = t.account_id
LEFT JOIN marketing.crm_contacts c ON c.id = t.linked_contact_id
LEFT JOIN marketing.crm_deals d ON d.id = t.linked_deal_id
LEFT JOIN marketing.crm_organizations o ON o.id = t.linked_organization_id
LEFT JOIN LATERAL (
  SELECT e.sender_name, e.sender_email, e.snippet, e.direction, e.received_at
  FROM marketing.emails e
  WHERE e.thread_id = t.id
  ORDER BY COALESCE(e.received_at, e.sent_at, e.created_at) DESC
  LIMIT 1
) lm ON true
LEFT JOIN LATERAL (
  SELECT ed2.id, ed2.status, ed2.confidence_score, ed2.reason_summary
  FROM marketing.email_drafts ed2
  WHERE ed2.thread_id = t.id
  ORDER BY ed2.created_at DESC
  LIMIT 1
) ed ON true;

CREATE OR REPLACE VIEW marketing.email_draft_review_queue AS
SELECT
  ed.*,
  t.subject AS thread_subject,
  t.linked_contact_id,
  c.display_name AS contact_name,
  lm.sender_name,
  lm.sender_email,
  lm.snippet AS email_snippet
FROM marketing.email_drafts ed
JOIN marketing.email_threads t ON t.id = ed.thread_id
LEFT JOIN marketing.crm_contacts c ON c.id = t.linked_contact_id
LEFT JOIN LATERAL (
  SELECT e.sender_name, e.sender_email, e.snippet
  FROM marketing.emails e
  WHERE e.thread_id = t.id
  ORDER BY COALESCE(e.received_at, e.sent_at, e.created_at) DESC
  LIMIT 1
) lm ON true
WHERE ed.status IN ('generated', 'needs_review');

-- ============================================================================
-- 6. RLS
-- ============================================================================

ALTER TABLE marketing.email_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.email_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.emails ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.email_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.email_draft_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.email_contact_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.email_agent_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.email_sync_logs ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'email_accounts', 'email_threads', 'emails', 'email_drafts',
    'email_draft_versions', 'email_contact_links', 'email_agent_requests', 'email_sync_logs'
  ]
  LOOP
    EXECUTE format(
      'CREATE POLICY "email_%s_select_team" ON marketing.%I FOR SELECT TO authenticated
       USING (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor'', ''viewer''))',
      tbl, tbl
    );
    EXECUTE format(
      'CREATE POLICY "email_%s_write_team" ON marketing.%I FOR ALL TO authenticated
       USING (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor''))
       WITH CHECK (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor''))',
      tbl, tbl
    );
  END LOOP;
END $$;

-- ============================================================================
-- 7. Public views
-- ============================================================================

CREATE OR REPLACE VIEW public.email_accounts AS SELECT * FROM marketing.email_accounts;
CREATE OR REPLACE VIEW public.email_threads AS SELECT * FROM marketing.email_threads;
CREATE OR REPLACE VIEW public.emails AS SELECT * FROM marketing.emails;
CREATE OR REPLACE VIEW public.email_drafts AS SELECT * FROM marketing.email_drafts;
CREATE OR REPLACE VIEW public.email_draft_versions AS SELECT * FROM marketing.email_draft_versions;
CREATE OR REPLACE VIEW public.email_contact_links AS SELECT * FROM marketing.email_contact_links;
CREATE OR REPLACE VIEW public.email_agent_requests AS SELECT * FROM marketing.email_agent_requests;
CREATE OR REPLACE VIEW public.email_sync_logs AS SELECT * FROM marketing.email_sync_logs;
CREATE OR REPLACE VIEW public.email_inbox_enriched AS SELECT * FROM marketing.email_inbox_enriched;
CREATE OR REPLACE VIEW public.email_draft_review_queue AS SELECT * FROM marketing.email_draft_review_queue;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_accounts TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_threads TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.emails TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_drafts TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_draft_versions TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_contact_links TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_agent_requests TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.email_sync_logs TO anon, authenticated, service_role;
GRANT SELECT ON public.email_inbox_enriched TO anon, authenticated, service_role;
GRANT SELECT ON public.email_draft_review_queue TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
