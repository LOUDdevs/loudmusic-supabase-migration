-- Migration: 013_crm_foundation.sql
-- LOUDmusic CRM foundation: contacts, pipeline, communications, SendPilot sync.
-- Run AFTER 012_expose_tasks.sql.

BEGIN;

-- ============================================================================
-- 1. Enums
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE marketing.crm_relationship_status AS ENUM (
    'unknown', 'cold', 'warm', 'active', 'customer', 'churned', 'do_not_contact'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.crm_lifecycle_stage AS ENUM (
    'lead', 'prospect', 'qualified', 'customer', 'partner', 'inactive'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.crm_comm_channel AS ENUM (
    'linkedin', 'email', 'phone', 'sms', 'instagram', 'whatsapp', 'telegram',
    'website_chat', 'internal_note', 'manual_log'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.crm_comm_direction AS ENUM ('inbound', 'outbound');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.crm_comm_status AS ENUM (
    'drafted', 'sent', 'delivered', 'opened', 'replied', 'failed'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.crm_sync_status AS ENUM ('pending', 'syncing', 'synced', 'error');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE marketing.crm_import_status AS ENUM ('pending', 'processing', 'completed', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ============================================================================
-- 2. Helpers
-- ============================================================================

CREATE OR REPLACE FUNCTION marketing.crm_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION marketing.normalize_linkedin_url(url text)
RETURNS text
LANGUAGE sql
IMMUTABLE AS $$
  SELECT CASE
    WHEN url IS NULL OR btrim(url) = '' THEN NULL
    ELSE lower(
      regexp_replace(
        regexp_replace(btrim(url), '\?.*$', ''),
        '/+$', ''
      )
    )
  END;
$$;

-- ============================================================================
-- 3. Lookup / seed tables
-- ============================================================================

CREATE TABLE IF NOT EXISTS marketing.crm_contact_types (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text UNIQUE NOT NULL,
  label       text NOT NULL,
  sort_order  integer NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.crm_platforms (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text UNIQUE NOT NULL,
  label       text NOT NULL,
  sort_order  integer NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.crm_pipelines (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  is_default  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.crm_pipeline_stages (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pipeline_id  uuid NOT NULL REFERENCES marketing.crm_pipelines (id) ON DELETE CASCADE,
  name         text NOT NULL,
  sort_order   integer NOT NULL DEFAULT 0,
  is_won       boolean NOT NULL DEFAULT false,
  is_lost      boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pipeline_id, name)
);

CREATE TABLE IF NOT EXISTS marketing.crm_tags (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text UNIQUE NOT NULL,
  color       text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- 4. Core entities
-- ============================================================================

CREATE TABLE IF NOT EXISTS marketing.crm_contacts (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name               text NOT NULL,
  first_name                 text,
  last_name                  text,
  avatar_url                 text,
  primary_email              text,
  primary_phone              text,
  emails                     jsonb NOT NULL DEFAULT '[]'::jsonb,
  phones                     jsonb NOT NULL DEFAULT '[]'::jsonb,
  relationship_status        marketing.crm_relationship_status NOT NULL DEFAULT 'unknown',
  lifecycle_stage            marketing.crm_lifecycle_stage NOT NULL DEFAULT 'lead',
  lead_source                text,
  owner_user_id              uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  last_contacted_at          timestamptz,
  next_follow_up_at          timestamptz,
  linkedin_url_normalized    text UNIQUE,
  duplicate_of_id            uuid REFERENCES marketing.crm_contacts (id) ON DELETE SET NULL,
  sendpilot_lead_id          uuid UNIQUE REFERENCES marketing.sendpilot_leads (id) ON DELETE SET NULL,
  sendpilot_conversation_id  uuid UNIQUE REFERENCES marketing.sendpilot_conversations (id) ON DELETE SET NULL,
  custom_fields              jsonb NOT NULL DEFAULT '{}'::jsonb,
  ai_summary                 text,
  ai_scores                  jsonb NOT NULL DEFAULT '{}'::jsonb,
  deleted_at                 timestamptz,
  created_by                 uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  updated_by                 uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now(),
  last_synced_at             timestamptz
);

CREATE INDEX IF NOT EXISTS idx_crm_contacts_display_name
  ON marketing.crm_contacts (lower(display_name));
CREATE INDEX IF NOT EXISTS idx_crm_contacts_owner_follow_up
  ON marketing.crm_contacts (owner_user_id, next_follow_up_at);
CREATE INDEX IF NOT EXISTS idx_crm_contacts_lifecycle_last_contact
  ON marketing.crm_contacts (lifecycle_stage, last_contacted_at DESC);
CREATE INDEX IF NOT EXISTS idx_crm_contacts_active
  ON marketing.crm_contacts (created_at DESC)
  WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS marketing.crm_contact_profiles (
  contact_id                 uuid PRIMARY KEY REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  headline                   text,
  about                      text,
  location                   text,
  job_title                  text,
  current_company            text,
  experience                 jsonb NOT NULL DEFAULT '[]'::jsonb,
  education                  jsonb NOT NULL DEFAULT '[]'::jsonb,
  skills                     jsonb NOT NULL DEFAULT '[]'::jsonb,
  follower_count             integer,
  connection_degree          text,
  recent_activity            jsonb NOT NULL DEFAULT '[]'::jsonb,
  conversation_status        text,
  outreach_status            text,
  last_message_sent_at       timestamptz,
  last_reply_received_at     timestamptz,
  updated_at                 timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.crm_contact_type_assignments (
  contact_id   uuid NOT NULL REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  type_id      uuid NOT NULL REFERENCES marketing.crm_contact_types (id) ON DELETE CASCADE,
  assigned_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (contact_id, type_id)
);

CREATE INDEX IF NOT EXISTS idx_crm_contact_types_contact
  ON marketing.crm_contact_type_assignments (contact_id);
CREATE INDEX IF NOT EXISTS idx_crm_contact_types_type
  ON marketing.crm_contact_type_assignments (type_id);

CREATE TABLE IF NOT EXISTS marketing.crm_contact_platform_accounts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id      uuid NOT NULL REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  platform_id     uuid NOT NULL REFERENCES marketing.crm_platforms (id) ON DELETE RESTRICT,
  profile_url     text,
  external_id     text,
  username        text,
  raw_data        jsonb NOT NULL DEFAULT '{}'::jsonb,
  sync_status     marketing.crm_sync_status NOT NULL DEFAULT 'pending',
  last_synced_at  timestamptz,
  is_primary      boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contact_id, platform_id, profile_url)
);

CREATE INDEX IF NOT EXISTS idx_crm_platform_accounts_contact
  ON marketing.crm_contact_platform_accounts (contact_id);

CREATE TABLE IF NOT EXISTS marketing.crm_organizations (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  website     text,
  industry    text,
  notes       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.crm_contact_organizations (
  contact_id       uuid NOT NULL REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  organization_id  uuid NOT NULL REFERENCES marketing.crm_organizations (id) ON DELETE CASCADE,
  role             text,
  is_primary       boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (contact_id, organization_id)
);

CREATE TABLE IF NOT EXISTS marketing.crm_artists (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id  uuid UNIQUE NOT NULL REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  artist_name text NOT NULL,
  legal_name  text,
  stage_name  text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.crm_music_profiles (
  artist_id                  uuid PRIMARY KEY REFERENCES marketing.crm_artists (id) ON DELETE CASCADE,
  genre                      text,
  subgenre                   text,
  location                   text,
  language                   text,
  spotify_url                text,
  apple_music_url            text,
  youtube_url                text,
  soundcloud_url             text,
  audiomack_url              text,
  instagram_url              text,
  tiktok_url                 text,
  facebook_url               text,
  website                    text,
  distributor                text,
  label                      text,
  manager                    text,
  booking_contact            text,
  monthly_listeners          integer,
  followers                  integer,
  catalog_size               integer,
  release_frequency          text,
  top_songs                  jsonb NOT NULL DEFAULT '[]'::jsonb,
  recent_releases            jsonb NOT NULL DEFAULT '[]'::jsonb,
  audience_geography         jsonb NOT NULL DEFAULT '{}'::jsonb,
  engagement_notes           text,
  potential_service_fit      text,
  opportunity_score          numeric(5,2),
  recommended_services       jsonb NOT NULL DEFAULT '[]'::jsonb,
  distribution_interest      boolean NOT NULL DEFAULT false,
  publishing_interest        boolean NOT NULL DEFAULT false,
  playlist_interest          boolean NOT NULL DEFAULT false,
  marketing_interest         boolean NOT NULL DEFAULT false,
  sync_licensing_interest    boolean NOT NULL DEFAULT false,
  loudmusic_plan_interest    text,
  updated_at                 timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.crm_communication_threads (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id                 uuid NOT NULL REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  channel                    marketing.crm_comm_channel NOT NULL,
  subject                    text,
  external_thread_id         text,
  sendpilot_conversation_id  uuid UNIQUE REFERENCES marketing.sendpilot_conversations (id) ON DELETE SET NULL,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_threads_contact
  ON marketing.crm_communication_threads (contact_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS marketing.crm_communications (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id             uuid REFERENCES marketing.crm_communication_threads (id) ON DELETE SET NULL,
  contact_id            uuid NOT NULL REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  channel               marketing.crm_comm_channel NOT NULL,
  direction             marketing.crm_comm_direction NOT NULL,
  body                  text,
  subject               text,
  sender                text,
  recipient             text,
  status                marketing.crm_comm_status NOT NULL DEFAULT 'sent',
  attachments           jsonb NOT NULL DEFAULT '[]'::jsonb,
  deal_id               uuid,
  campaign_id           uuid,
  sendpilot_message_id  text UNIQUE,
  ai_generated          boolean NOT NULL DEFAULT false,
  is_automated          boolean NOT NULL DEFAULT false,
  created_by            uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  occurred_at           timestamptz NOT NULL DEFAULT now(),
  created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_comms_contact
  ON marketing.crm_communications (contact_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_crm_comms_thread
  ON marketing.crm_communications (thread_id, occurred_at DESC);

CREATE TABLE IF NOT EXISTS marketing.crm_deals (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id           uuid REFERENCES marketing.crm_contacts (id) ON DELETE SET NULL,
  organization_id      uuid REFERENCES marketing.crm_organizations (id) ON DELETE SET NULL,
  pipeline_id          uuid NOT NULL REFERENCES marketing.crm_pipelines (id) ON DELETE RESTRICT,
  stage_id             uuid NOT NULL REFERENCES marketing.crm_pipeline_stages (id) ON DELETE RESTRICT,
  title                text NOT NULL,
  value_cents          integer NOT NULL DEFAULT 0,
  currency             text NOT NULL DEFAULT 'USD',
  probability          integer CHECK (probability >= 0 AND probability <= 100),
  expected_close_date  date,
  source               text,
  service_interest     text[] NOT NULL DEFAULT '{}',
  owner_user_id        uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  notes                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_deals_stage
  ON marketing.crm_deals (stage_id);
CREATE INDEX IF NOT EXISTS idx_crm_deals_contact
  ON marketing.crm_deals (contact_id);

CREATE TABLE IF NOT EXISTS marketing.crm_tasks (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id    uuid REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  deal_id       uuid REFERENCES marketing.crm_deals (id) ON DELETE SET NULL,
  title         text NOT NULL,
  description   text,
  due_at        timestamptz,
  completed_at  timestamptz,
  priority      integer NOT NULL DEFAULT 0,
  owner_user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_tasks_due
  ON marketing.crm_tasks (due_at)
  WHERE completed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_crm_tasks_contact
  ON marketing.crm_tasks (contact_id);

CREATE TABLE IF NOT EXISTS marketing.crm_notes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id  uuid NOT NULL REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  deal_id     uuid REFERENCES marketing.crm_deals (id) ON DELETE SET NULL,
  body        text NOT NULL,
  pinned      boolean NOT NULL DEFAULT false,
  created_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_notes_contact
  ON marketing.crm_notes (contact_id, created_at DESC);

CREATE TABLE IF NOT EXISTS marketing.crm_contact_tags (
  contact_id  uuid NOT NULL REFERENCES marketing.crm_contacts (id) ON DELETE CASCADE,
  tag_id      uuid NOT NULL REFERENCES marketing.crm_tags (id) ON DELETE CASCADE,
  tagged_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (contact_id, tag_id)
);

CREATE TABLE IF NOT EXISTS marketing.crm_imports (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source       text NOT NULL,
  status       marketing.crm_import_status NOT NULL DEFAULT 'pending',
  file_name    text,
  stats        jsonb NOT NULL DEFAULT '{}'::jsonb,
  errors       jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_by   uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz
);

CREATE TABLE IF NOT EXISTS marketing.crm_integration_accounts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform        text NOT NULL,
  account_label   text NOT NULL,
  sync_status     marketing.crm_sync_status NOT NULL DEFAULT 'pending',
  last_synced_at  timestamptz,
  config          jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_log       jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.crm_activity_logs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type    text NOT NULL,
  entity_id      uuid NOT NULL,
  action         text NOT NULL,
  metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,
  actor_user_id  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_activity_entity
  ON marketing.crm_activity_logs (entity_type, entity_id, created_at DESC);

-- updated_at triggers
DROP TRIGGER IF EXISTS trg_crm_contacts_updated ON marketing.crm_contacts;
CREATE TRIGGER trg_crm_contacts_updated
  BEFORE UPDATE ON marketing.crm_contacts
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

DROP TRIGGER IF EXISTS trg_crm_deals_updated ON marketing.crm_deals;
CREATE TRIGGER trg_crm_deals_updated
  BEFORE UPDATE ON marketing.crm_deals
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

DROP TRIGGER IF EXISTS trg_crm_tasks_updated ON marketing.crm_tasks;
CREATE TRIGGER trg_crm_tasks_updated
  BEFORE UPDATE ON marketing.crm_tasks
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

-- ============================================================================
-- 5. Seeds
-- ============================================================================

INSERT INTO marketing.crm_contact_types (slug, label, sort_order)
VALUES
  ('linkedin_lead', 'LinkedIn Lead', 1),
  ('artist', 'Artist', 2),
  ('musician', 'Musician', 3),
  ('producer', 'Producer', 4),
  ('manager', 'Manager', 5),
  ('label_contact', 'Label Contact', 6),
  ('playlist_curator', 'Playlist Curator', 7),
  ('media_contact', 'Media Contact', 8),
  ('business_partner', 'Business Partner', 9),
  ('client', 'Client', 10),
  ('prospect', 'Prospect', 11),
  ('vendor', 'Vendor', 12),
  ('internal_team', 'Internal Team Member', 13)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO marketing.crm_platforms (slug, label, sort_order)
VALUES
  ('linkedin', 'LinkedIn', 1),
  ('email', 'Email', 2),
  ('phone', 'Phone', 3),
  ('spotify', 'Spotify', 4),
  ('apple_music', 'Apple Music', 5),
  ('youtube', 'YouTube', 6),
  ('soundcloud', 'SoundCloud', 7),
  ('audiomack', 'Audiomack', 8),
  ('instagram', 'Instagram', 9),
  ('tiktok', 'TikTok', 10),
  ('facebook', 'Facebook', 11),
  ('whatsapp', 'WhatsApp', 12),
  ('telegram', 'Telegram', 13),
  ('website', 'Website', 14)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO marketing.crm_pipelines (id, name, is_default)
SELECT gen_random_uuid(), 'Sales', true
WHERE NOT EXISTS (SELECT 1 FROM marketing.crm_pipelines WHERE is_default = true);

INSERT INTO marketing.crm_pipeline_stages (pipeline_id, name, sort_order, is_won, is_lost)
SELECT p.id, v.name, v.sort_order, v.is_won, v.is_lost
FROM marketing.crm_pipelines p
CROSS JOIN (VALUES
  ('New Lead', 1, false, false),
  ('Researched', 2, false, false),
  ('Contacted', 3, false, false),
  ('Replied', 4, false, false),
  ('Qualified', 5, false, false),
  ('Discovery Call Booked', 6, false, false),
  ('Proposal Sent', 7, false, false),
  ('Negotiation', 8, false, false),
  ('Won', 9, true, false),
  ('Lost', 10, false, true),
  ('Nurture', 11, false, false)
) AS v(name, sort_order, is_won, is_lost)
WHERE p.is_default = true
  AND NOT EXISTS (
    SELECT 1 FROM marketing.crm_pipeline_stages s WHERE s.pipeline_id = p.id
  );

-- ============================================================================
-- 6. Enriched list view
-- ============================================================================

CREATE OR REPLACE VIEW marketing.crm_contacts_list AS
SELECT
  c.id,
  c.display_name,
  c.first_name,
  c.last_name,
  c.avatar_url,
  c.primary_email,
  c.primary_phone,
  c.relationship_status,
  c.lifecycle_stage,
  c.lead_source,
  c.owner_user_id,
  c.last_contacted_at,
  c.next_follow_up_at,
  c.linkedin_url_normalized,
  c.sendpilot_lead_id,
  c.sendpilot_conversation_id,
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
  prof.current_company,
  prof.job_title,
  prof.headline
FROM marketing.crm_contacts c
LEFT JOIN marketing.crm_contact_profiles prof ON prof.contact_id = c.id
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

-- ============================================================================
-- 7. SendPilot sync RPC
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
  v_lead record;
  v_conv record;
  v_msg record;
  v_contact_id uuid;
  v_thread_id uuid;
  v_norm_url text;
  v_display_name text;
  v_direction marketing.crm_comm_direction;
  v_status marketing.crm_comm_status;
BEGIN
  SELECT id INTO v_linkedin_type_id FROM marketing.crm_contact_types WHERE slug = 'linkedin_lead';
  SELECT id INTO v_linkedin_platform_id FROM marketing.crm_platforms WHERE slug = 'linkedin';

  -- Upsert contacts from SendPilot leads
  FOR v_lead IN
    SELECT * FROM marketing.sendpilot_leads
  LOOP
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

    INSERT INTO marketing.crm_contact_profiles (contact_id, job_title, current_company)
    VALUES (v_contact_id, v_lead.title, v_lead.company)
    ON CONFLICT (contact_id) DO UPDATE SET
      job_title = COALESCE(EXCLUDED.job_title, crm_contact_profiles.job_title),
      current_company = COALESCE(EXCLUDED.current_company, crm_contact_profiles.current_company),
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

  -- Link conversations to contacts
  FOR v_conv IN
    SELECT c.* FROM marketing.sendpilot_conversations c
  LOOP
    v_norm_url := marketing.normalize_linkedin_url(v_conv.lead_profile_url);

    SELECT id INTO v_contact_id
    FROM marketing.crm_contacts
    WHERE (v_norm_url IS NOT NULL AND linkedin_url_normalized = v_norm_url)
       OR sendpilot_conversation_id = v_conv.id
    LIMIT 1;

    IF v_contact_id IS NULL AND v_conv.lead_name IS NOT NULL THEN
      INSERT INTO marketing.crm_contacts (
        display_name, avatar_url, linkedin_url_normalized,
        sendpilot_conversation_id, lead_source, lifecycle_stage, last_synced_at
      ) VALUES (
        v_conv.lead_name, v_conv.lead_profile_picture, v_norm_url,
        v_conv.id, 'sendpilot', 'lead', now()
      )
      RETURNING id INTO v_contact_id;
      v_contacts_upserted := v_contacts_upserted + 1;

      INSERT INTO marketing.crm_contact_type_assignments (contact_id, type_id)
      VALUES (v_contact_id, v_linkedin_type_id)
      ON CONFLICT DO NOTHING;
    ELSIF v_contact_id IS NOT NULL THEN
      UPDATE marketing.crm_contacts SET
        sendpilot_conversation_id = COALESCE(sendpilot_conversation_id, v_conv.id),
        avatar_url = COALESCE(avatar_url, v_conv.lead_profile_picture),
        linkedin_url_normalized = COALESCE(linkedin_url_normalized, v_norm_url),
        last_synced_at = now(),
        updated_at = now()
      WHERE id = v_contact_id;
      v_conversations_linked := v_conversations_linked + 1;
    END IF;

    IF v_contact_id IS NOT NULL THEN
      INSERT INTO marketing.crm_contact_profiles (contact_id)
      VALUES (v_contact_id)
      ON CONFLICT (contact_id) DO NOTHING;

      IF v_norm_url IS NOT NULL THEN
        INSERT INTO marketing.crm_contact_platform_accounts (
          contact_id, platform_id, profile_url, is_primary, sync_status, last_synced_at
        ) VALUES (
          v_contact_id, v_linkedin_platform_id, v_conv.lead_profile_url, true, 'synced', now()
        )
        ON CONFLICT (contact_id, platform_id, profile_url) DO UPDATE SET
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
        v_direction := CASE WHEN v_msg.direction = 'received' THEN 'inbound'::marketing.crm_comm_direction
                            ELSE 'outbound'::marketing.crm_comm_direction END;
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

      UPDATE marketing.crm_contacts SET
        last_contacted_at = v_conv.last_message_sent_at,
        updated_at = now()
      WHERE id = v_contact_id
        AND (last_contacted_at IS NULL OR last_contacted_at < v_conv.last_message_sent_at);

      UPDATE marketing.crm_contact_profiles SET
        last_message_sent_at = CASE
          WHEN v_conv.last_message_direction = 'sent' THEN v_conv.last_message_sent_at
          ELSE last_message_sent_at END,
        last_reply_received_at = CASE
          WHEN v_conv.last_message_direction = 'received' THEN v_conv.last_message_sent_at
          ELSE last_reply_received_at END,
        updated_at = now()
      WHERE contact_id = v_contact_id;
    END IF;
  END LOOP;

  INSERT INTO marketing.crm_activity_logs (entity_type, entity_id, action, metadata)
  VALUES (
    'sync', gen_random_uuid(), 'sendpilot_sync',
    jsonb_build_object(
      'contacts_upserted', v_contacts_upserted,
      'conversations_linked', v_conversations_linked,
      'messages_mirrored', v_messages_mirrored
    )
  );

  RETURN jsonb_build_object(
    'contacts_upserted', v_contacts_upserted,
    'conversations_linked', v_conversations_linked,
    'messages_mirrored', v_messages_mirrored,
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

GRANT EXECUTE ON FUNCTION public.crm_sync_from_sendpilot() TO anon, authenticated, service_role;

-- ============================================================================
-- 8. RLS
-- ============================================================================

ALTER TABLE marketing.crm_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_contact_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_contact_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_contact_type_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_platforms ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_contact_platform_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_contact_organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_artists ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_music_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_communication_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_communications ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_pipelines ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_pipeline_stages ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_deals ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_contact_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_imports ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_integration_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_activity_logs ENABLE ROW LEVEL SECURITY;

-- Read policies (anon + authenticated)
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'crm_contacts', 'crm_contact_profiles', 'crm_contact_types',
    'crm_contact_type_assignments', 'crm_platforms', 'crm_contact_platform_accounts',
    'crm_organizations', 'crm_contact_organizations', 'crm_artists', 'crm_music_profiles',
    'crm_communication_threads', 'crm_communications', 'crm_pipelines', 'crm_pipeline_stages',
    'crm_deals', 'crm_tasks', 'crm_notes', 'crm_tags', 'crm_contact_tags',
    'crm_imports', 'crm_integration_accounts', 'crm_activity_logs'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON marketing.%I', t || '_anon_read', t);
    EXECUTE format(
      'CREATE POLICY %I ON marketing.%I FOR SELECT TO anon USING (true)',
      t || '_anon_read', t
    );
    EXECUTE format('DROP POLICY IF EXISTS %I ON marketing.%I', t || '_auth_read', t);
    EXECUTE format(
      'CREATE POLICY %I ON marketing.%I FOR SELECT TO authenticated USING (true)',
      t || '_auth_read', t
    );
  END LOOP;
END $$;

-- Write policies (editor+)
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'crm_contacts', 'crm_contact_profiles', 'crm_contact_type_assignments',
    'crm_contact_platform_accounts', 'crm_organizations', 'crm_contact_organizations',
    'crm_artists', 'crm_music_profiles', 'crm_communication_threads', 'crm_communications',
    'crm_deals', 'crm_tasks', 'crm_notes', 'crm_contact_tags', 'crm_imports'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON marketing.%I', t || '_editor_write', t);
    EXECUTE format(
      'CREATE POLICY %I ON marketing.%I FOR ALL TO authenticated
       USING (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor''))
       WITH CHECK (marketing.current_user_role() IN (''super_admin'', ''admin'', ''editor''))',
      t || '_editor_write', t
    );
    EXECUTE format('DROP POLICY IF EXISTS %I ON marketing.%I', t || '_anon_write', t);
    EXECUTE format(
      'CREATE POLICY %I ON marketing.%I FOR ALL TO anon
       USING (true) WITH CHECK (true)',
      t || '_anon_write', t
    );
  END LOOP;
END $$;

-- Soft-delete filter on contacts read via view only; base table allows all for sync RPC

-- ============================================================================
-- 9. Public views + grants
-- ============================================================================

CREATE OR REPLACE VIEW public.crm_contacts AS SELECT * FROM marketing.crm_contacts;
CREATE OR REPLACE VIEW public.crm_contact_profiles AS SELECT * FROM marketing.crm_contact_profiles;
CREATE OR REPLACE VIEW public.crm_contact_types AS SELECT * FROM marketing.crm_contact_types;
CREATE OR REPLACE VIEW public.crm_contact_type_assignments AS SELECT * FROM marketing.crm_contact_type_assignments;
CREATE OR REPLACE VIEW public.crm_platforms AS SELECT * FROM marketing.crm_platforms;
CREATE OR REPLACE VIEW public.crm_contact_platform_accounts AS SELECT * FROM marketing.crm_contact_platform_accounts;
CREATE OR REPLACE VIEW public.crm_organizations AS SELECT * FROM marketing.crm_organizations;
CREATE OR REPLACE VIEW public.crm_contact_organizations AS SELECT * FROM marketing.crm_contact_organizations;
CREATE OR REPLACE VIEW public.crm_artists AS SELECT * FROM marketing.crm_artists;
CREATE OR REPLACE VIEW public.crm_music_profiles AS SELECT * FROM marketing.crm_music_profiles;
CREATE OR REPLACE VIEW public.crm_communication_threads AS SELECT * FROM marketing.crm_communication_threads;
CREATE OR REPLACE VIEW public.crm_communications AS SELECT * FROM marketing.crm_communications;
CREATE OR REPLACE VIEW public.crm_pipelines AS SELECT * FROM marketing.crm_pipelines;
CREATE OR REPLACE VIEW public.crm_pipeline_stages AS SELECT * FROM marketing.crm_pipeline_stages;
CREATE OR REPLACE VIEW public.crm_deals AS SELECT * FROM marketing.crm_deals;
CREATE OR REPLACE VIEW public.crm_tasks AS SELECT * FROM marketing.crm_tasks;
CREATE OR REPLACE VIEW public.crm_notes AS SELECT * FROM marketing.crm_notes;
CREATE OR REPLACE VIEW public.crm_tags AS SELECT * FROM marketing.crm_tags;
CREATE OR REPLACE VIEW public.crm_contact_tags AS SELECT * FROM marketing.crm_contact_tags;
CREATE OR REPLACE VIEW public.crm_imports AS SELECT * FROM marketing.crm_imports;
CREATE OR REPLACE VIEW public.crm_integration_accounts AS SELECT * FROM marketing.crm_integration_accounts;
CREATE OR REPLACE VIEW public.crm_activity_logs AS SELECT * FROM marketing.crm_activity_logs;
CREATE OR REPLACE VIEW public.crm_contacts_list AS SELECT * FROM marketing.crm_contacts_list;

DO $$
DECLARE
  v text;
BEGIN
  FOREACH v IN ARRAY ARRAY[
    'crm_contacts', 'crm_contact_profiles', 'crm_contact_types', 'crm_contact_type_assignments',
    'crm_platforms', 'crm_contact_platform_accounts', 'crm_organizations', 'crm_contact_organizations',
    'crm_artists', 'crm_music_profiles', 'crm_communication_threads', 'crm_communications',
    'crm_pipelines', 'crm_pipeline_stages', 'crm_deals', 'crm_tasks', 'crm_notes', 'crm_tags',
    'crm_contact_tags', 'crm_imports', 'crm_integration_accounts', 'crm_activity_logs', 'crm_contacts_list'
  ] LOOP
    EXECUTE format('GRANT SELECT ON public.%I TO anon, authenticated, service_role', v);
    IF v NOT IN ('crm_contacts_list', 'crm_contact_types', 'crm_platforms', 'crm_pipelines', 'crm_pipeline_stages') THEN
      EXECUTE format('GRANT INSERT, UPDATE, DELETE ON public.%I TO anon, authenticated, service_role', v);
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
