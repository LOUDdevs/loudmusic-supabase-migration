-- Migration: 028_reachinbox_foundation.sql
-- ReachInbox cold email: accounts, warmup snapshots, campaigns, Onebox threads/messages.
-- Run AFTER 027_dashboard_performance_rpcs.sql.

BEGIN;

-- ============================================================================
-- 1. Tables
-- ============================================================================

CREATE TABLE marketing.reachinbox_accounts (
  id                  bigint PRIMARY KEY,
  email               text NOT NULL UNIQUE,
  domain              text NOT NULL,
  warmup_enabled      boolean NOT NULL DEFAULT false,
  health_score        integer,
  mails_sent_today    integer NOT NULL DEFAULT 0,
  is_active           boolean NOT NULL DEFAULT true,
  is_disconnected     boolean NOT NULL DEFAULT false,
  raw_metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_synced_at      timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_reachinbox_accounts_domain ON marketing.reachinbox_accounts (domain);
CREATE INDEX idx_reachinbox_accounts_warmup ON marketing.reachinbox_accounts (warmup_enabled);

CREATE TABLE marketing.reachinbox_warmup_snapshots (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id            bigint NOT NULL REFERENCES marketing.reachinbox_accounts (id) ON DELETE CASCADE,
  health_score          integer,
  warmup_emails_sent    integer,
  landed_inbox          integer,
  landed_spam           integer,
  mails_sent_today      integer,
  snapshot_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_reachinbox_warmup_snapshots_account ON marketing.reachinbox_warmup_snapshots (account_id, snapshot_at DESC);

CREATE TABLE marketing.reachinbox_campaigns (
  id                    bigint PRIMARY KEY,
  name                  text NOT NULL,
  status                text NOT NULL DEFAULT 'Draft',
  total_email_sent      integer NOT NULL DEFAULT 0,
  total_email_opened    integer NOT NULL DEFAULT 0,
  total_email_replied   integer NOT NULL DEFAULT 0,
  total_email_bounced   integer NOT NULL DEFAULT 0,
  daily_limit           integer,
  raw_metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_synced_at        timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_reachinbox_campaigns_status ON marketing.reachinbox_campaigns (status);

CREATE TABLE marketing.reachinbox_threads (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_thread_id    text NOT NULL,
  account_email         text NOT NULL,
  campaign_id           bigint REFERENCES marketing.reachinbox_campaigns (id) ON DELETE SET NULL,
  from_name             text,
  from_email            text,
  subject               text,
  status                text,
  inbox_folder          text NOT NULL DEFAULT 'Inbox',
  is_read               boolean NOT NULL DEFAULT false,
  last_activity_at      timestamptz,
  linked_contact_id     uuid REFERENCES marketing.crm_contacts (id) ON DELETE SET NULL,
  raw_metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_synced_at        timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider_thread_id, account_email)
);

CREATE INDEX idx_reachinbox_threads_activity ON marketing.reachinbox_threads (last_activity_at DESC NULLS LAST);
CREATE INDEX idx_reachinbox_threads_status ON marketing.reachinbox_threads (status);
CREATE INDEX idx_reachinbox_threads_account ON marketing.reachinbox_threads (account_email);

CREATE TABLE marketing.reachinbox_messages (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id             uuid NOT NULL REFERENCES marketing.reachinbox_threads (id) ON DELETE CASCADE,
  provider_message_id   text,
  direction             text NOT NULL DEFAULT 'inbound',
  from_email            text,
  to_email              text,
  subject               text,
  body_snippet          text,
  body_html             text,
  status                text,
  sent_at               timestamptz,
  raw_metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_reachinbox_messages_thread ON marketing.reachinbox_messages (thread_id, sent_at DESC NULLS LAST);

CREATE TABLE marketing.reachinbox_sync_logs (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at            timestamptz NOT NULL DEFAULT now(),
  finished_at           timestamptz,
  status                text NOT NULL DEFAULT 'running',
  accounts_synced       integer NOT NULL DEFAULT 0,
  campaigns_synced      integer NOT NULL DEFAULT 0,
  threads_synced        integer NOT NULL DEFAULT 0,
  messages_synced       integer NOT NULL DEFAULT 0,
  error                 text
);

-- ============================================================================
-- 2. Views
-- ============================================================================

CREATE OR REPLACE VIEW marketing.reachinbox_inbox_enriched AS
SELECT
  t.id,
  t.provider_thread_id,
  t.account_email,
  t.campaign_id,
  t.from_name,
  t.from_email,
  t.subject,
  t.status,
  t.inbox_folder,
  t.is_read,
  t.last_activity_at,
  t.linked_contact_id,
  t.created_at,
  t.updated_at,
  c.name AS campaign_name,
  lm.body_snippet AS latest_snippet,
  lm.from_email AS latest_from_email,
  lm.sent_at AS latest_sent_at,
  lm.direction AS latest_direction
FROM marketing.reachinbox_threads t
LEFT JOIN marketing.reachinbox_campaigns c ON c.id = t.campaign_id
LEFT JOIN LATERAL (
  SELECT m.body_snippet, m.from_email, m.sent_at, m.direction
  FROM marketing.reachinbox_messages m
  WHERE m.thread_id = t.id
  ORDER BY m.sent_at DESC NULLS LAST
  LIMIT 1
) lm ON true;

CREATE OR REPLACE VIEW marketing.reachinbox_warmup_summary AS
SELECT
  domain,
  count(*)::integer AS total,
  count(*) FILTER (WHERE warmup_enabled)::integer AS enabled,
  count(*) FILTER (WHERE warmup_enabled AND health_score >= 70)::integer AS warmed,
  count(*) FILTER (WHERE warmup_enabled AND (health_score IS NULL OR health_score < 70))::integer AS warming,
  count(*) FILTER (WHERE NOT warmup_enabled)::integer AS pending,
  coalesce(sum(mails_sent_today), 0)::integer AS sent_today
FROM marketing.reachinbox_accounts
WHERE is_active AND NOT is_disconnected
GROUP BY domain;

-- ============================================================================
-- 3. RLS
-- ============================================================================

ALTER TABLE marketing.reachinbox_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.reachinbox_warmup_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.reachinbox_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.reachinbox_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.reachinbox_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.reachinbox_sync_logs ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'reachinbox_accounts', 'reachinbox_warmup_snapshots', 'reachinbox_campaigns',
    'reachinbox_threads', 'reachinbox_messages', 'reachinbox_sync_logs'
  ]
  LOOP
    EXECUTE format(
      'CREATE POLICY "reachinbox_%s_select_team" ON marketing.%I FOR SELECT TO authenticated
       USING (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor'', ''viewer''))',
      tbl, tbl
    );
    EXECUTE format(
      'CREATE POLICY "reachinbox_%s_write_team" ON marketing.%I FOR ALL TO authenticated
       USING (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor''))
       WITH CHECK (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor''))',
      tbl, tbl
    );
  END LOOP;
END $$;

-- ============================================================================
-- 4. Public views
-- ============================================================================

CREATE OR REPLACE VIEW public.reachinbox_accounts AS SELECT * FROM marketing.reachinbox_accounts;
CREATE OR REPLACE VIEW public.reachinbox_warmup_snapshots AS SELECT * FROM marketing.reachinbox_warmup_snapshots;
CREATE OR REPLACE VIEW public.reachinbox_campaigns AS SELECT * FROM marketing.reachinbox_campaigns;
CREATE OR REPLACE VIEW public.reachinbox_threads AS SELECT * FROM marketing.reachinbox_threads;
CREATE OR REPLACE VIEW public.reachinbox_messages AS SELECT * FROM marketing.reachinbox_messages;
CREATE OR REPLACE VIEW public.reachinbox_sync_logs AS SELECT * FROM marketing.reachinbox_sync_logs;
CREATE OR REPLACE VIEW public.reachinbox_inbox_enriched AS SELECT * FROM marketing.reachinbox_inbox_enriched;
CREATE OR REPLACE VIEW public.reachinbox_warmup_summary AS SELECT * FROM marketing.reachinbox_warmup_summary;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.reachinbox_accounts TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.reachinbox_warmup_snapshots TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.reachinbox_campaigns TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.reachinbox_threads TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.reachinbox_messages TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.reachinbox_sync_logs TO anon, authenticated, service_role;
GRANT SELECT ON public.reachinbox_inbox_enriched TO anon, authenticated, service_role;
GRANT SELECT ON public.reachinbox_warmup_summary TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
