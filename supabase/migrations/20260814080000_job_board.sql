BEGIN;

-- ============================================================================
-- Job Board schema. Employers/companies reuse the existing CRM organizations
-- table (marketing.crm_organizations) rather than duplicating a "company"
-- concept. Everything else lives in new marketing.jobs_* tables, following
-- the same workspace_id + marketing.workspace_access() pattern already used
-- by the CRM/funnel tables. There is no external employer/candidate account
-- system in this codebase today (confirmed: auth is staff-only via
-- marketing.workspace_members) so:
--   - Job/company management is done by internal staff via the admin app,
--     exactly like Companies/Deals/Funnels already are.
--   - Candidates apply without an account (same anonymous-submission pattern
--     already used by the artist bio survey and funnel lead capture).
--   - "Saved jobs" and "job alerts" are keyed by a client-generated visitor_id
--     (stored in localStorage) or, for alerts, an email address — real,
--     persisted rows, just not gated behind a login.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Extend the existing Companies model with employer-directory fields.
-- ---------------------------------------------------------------------------
ALTER TABLE marketing.crm_organizations
  ADD COLUMN IF NOT EXISTS logo_url text,
  ADD COLUMN IF NOT EXISTS cover_image_url text,
  ADD COLUMN IF NOT EXISTS industry text,
  ADD COLUMN IF NOT EXISTS company_size text,
  ADD COLUMN IF NOT EXISTS founded_year integer,
  ADD COLUMN IF NOT EXISTS headquarters text,
  ADD COLUMN IF NOT EXISTS social_links jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS benefits jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS culture text,
  ADD COLUMN IF NOT EXISTS photos jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS verified boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS is_employer boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS public_slug text;

CREATE UNIQUE INDEX IF NOT EXISTS idx_crm_organizations_public_slug
  ON marketing.crm_organizations (lower(public_slug))
  WHERE public_slug IS NOT NULL AND archived_at IS NULL;

-- Public read of employer-flagged, non-archived companies (job board company pages).
DROP POLICY IF EXISTS crm_organizations_public_employer_read ON marketing.crm_organizations;
CREATE POLICY crm_organizations_public_employer_read ON marketing.crm_organizations
  FOR SELECT TO anon, authenticated
  USING (is_employer = true AND archived_at IS NULL);

GRANT SELECT ON marketing.crm_organizations TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lookups: categories, departments, hiring stages.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marketing.jobs_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  name text NOT NULL,
  slug text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_categories_workspace_slug ON marketing.jobs_categories (workspace_id, slug);

CREATE TABLE IF NOT EXISTS marketing.jobs_departments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  name text NOT NULL,
  slug text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_departments_workspace_slug ON marketing.jobs_departments (workspace_id, slug);

CREATE TABLE IF NOT EXISTS marketing.jobs_hiring_stages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  key text NOT NULL,
  label text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  is_terminal boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_hiring_stages_workspace_key ON marketing.jobs_hiring_stages (workspace_id, key);

-- ---------------------------------------------------------------------------
-- Core job postings.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marketing.jobs_postings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  company_id uuid NOT NULL REFERENCES marketing.crm_organizations(id) ON DELETE CASCADE,
  department_id uuid REFERENCES marketing.jobs_departments(id) ON DELETE SET NULL,
  category_id uuid REFERENCES marketing.jobs_categories(id) ON DELETE SET NULL,

  title text NOT NULL,
  slug text NOT NULL,
  description text NOT NULL DEFAULT '',
  responsibilities text NOT NULL DEFAULT '',
  requirements text NOT NULL DEFAULT '',
  preferred_qualifications text NOT NULL DEFAULT '',
  skills text[] NOT NULL DEFAULT '{}',
  experience_level text,
  education_requirement text,
  openings integer NOT NULL DEFAULT 1 CHECK (openings >= 1),

  employment_type text NOT NULL DEFAULT 'full_time',
  workplace_type text NOT NULL DEFAULT 'on_site' CHECK (workplace_type IN ('remote', 'hybrid', 'on_site')),
  city text,
  state text,
  country text,
  address text,
  additional_locations jsonb NOT NULL DEFAULT '[]'::jsonb,

  salary_min numeric(12, 2),
  salary_max numeric(12, 2),
  salary_period text CHECK (salary_period IN ('hourly', 'annual', 'project', 'commission') OR salary_period IS NULL),
  currency text NOT NULL DEFAULT 'USD',
  salary_visible boolean NOT NULL DEFAULT true,
  commission_details text,
  bonus_info text,
  equity_info text,
  compensation_notes text,
  benefits text[] NOT NULL DEFAULT '{}',

  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_approval', 'scheduled', 'published', 'paused', 'filled', 'expired', 'rejected', 'archived')),
  publish_at timestamptz,
  expires_at timestamptz,
  application_deadline timestamptz,
  featured boolean NOT NULL DEFAULT false,
  urgent boolean NOT NULL DEFAULT false,
  is_private boolean NOT NULL DEFAULT false,
  promoted_rank integer NOT NULL DEFAULT 0,

  seo_title text,
  seo_description text,
  social_image_url text,

  view_count integer NOT NULL DEFAULT 0,
  application_count integer NOT NULL DEFAULT 0,

  owner_id uuid,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  archived_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_postings_workspace_slug ON marketing.jobs_postings (workspace_id, slug);
CREATE INDEX IF NOT EXISTS idx_jobs_postings_workspace_status ON marketing.jobs_postings (workspace_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_postings_company ON marketing.jobs_postings (company_id);
CREATE INDEX IF NOT EXISTS idx_jobs_postings_category ON marketing.jobs_postings (category_id);
CREATE INDEX IF NOT EXISTS idx_jobs_postings_department ON marketing.jobs_postings (department_id);
CREATE INDEX IF NOT EXISTS idx_jobs_postings_featured ON marketing.jobs_postings (workspace_id, featured, promoted_rank DESC) WHERE status = 'published';
CREATE INDEX IF NOT EXISTS idx_jobs_postings_skills ON marketing.jobs_postings USING gin (skills);
CREATE INDEX IF NOT EXISTS idx_jobs_postings_location_trgm ON marketing.jobs_postings USING gin ((coalesce(city, '') || ' ' || coalesce(state, '') || ' ' || coalesce(country, '')) gin_trgm_ops);

-- Note: skills is intentionally excluded from the tsvector below —
-- array_to_string() is not treated as immutable on this Postgres instance,
-- which STORED generated columns require. Skill search/filtering instead
-- uses the separate GIN index on the skills array (idx_jobs_postings_skills).
ALTER TABLE marketing.jobs_postings ADD COLUMN IF NOT EXISTS search_vector tsvector
  GENERATED ALWAYS AS (
    setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(city, '') || ' ' || coalesce(state, '') || ' ' || coalesce(country, '')), 'B') ||
    setweight(to_tsvector('english', coalesce(description, '')), 'C')
  ) STORED;
CREATE INDEX IF NOT EXISTS idx_jobs_postings_search ON marketing.jobs_postings USING gin (search_vector);

-- Publicly-visible published jobs are directly readable (fast public directory
-- queries without round-tripping every page view through the edge function).
-- Drafts, paused, private, and unpublished-future jobs are never exposed here.
DROP POLICY IF EXISTS jobs_postings_public_read ON marketing.jobs_postings;
CREATE POLICY jobs_postings_public_read ON marketing.jobs_postings
  FOR SELECT TO anon, authenticated
  USING (
    status = 'published'
    AND is_private = false
    AND (publish_at IS NULL OR publish_at <= now())
    AND (expires_at IS NULL OR expires_at > now())
  );

GRANT SELECT ON marketing.jobs_postings TO anon, authenticated;
-- Writes only via the edge function (service role), same convention as crm_organizations.
REVOKE INSERT, UPDATE, DELETE ON marketing.jobs_postings FROM anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON marketing.jobs_postings TO service_role;

GRANT SELECT ON marketing.jobs_categories, marketing.jobs_departments TO anon, authenticated;
ALTER TABLE marketing.jobs_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_departments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS jobs_categories_public_read ON marketing.jobs_categories;
CREATE POLICY jobs_categories_public_read ON marketing.jobs_categories FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS jobs_departments_public_read ON marketing.jobs_departments;
CREATE POLICY jobs_departments_public_read ON marketing.jobs_departments FOR SELECT TO anon, authenticated USING (true);

-- ---------------------------------------------------------------------------
-- Custom application questions per posting.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marketing.jobs_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  posting_id uuid NOT NULL REFERENCES marketing.jobs_postings(id) ON DELETE CASCADE,
  label text NOT NULL,
  question_type text NOT NULL DEFAULT 'short_text' CHECK (question_type IN ('short_text', 'long_text', 'multiple_choice', 'checkbox', 'yes_no', 'number', 'date', 'file_upload')),
  options jsonb NOT NULL DEFAULT '[]'::jsonb,
  required boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_jobs_questions_posting ON marketing.jobs_questions (posting_id, sort_order);

GRANT SELECT ON marketing.jobs_questions TO anon, authenticated;
ALTER TABLE marketing.jobs_questions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS jobs_questions_public_read ON marketing.jobs_questions;
CREATE POLICY jobs_questions_public_read ON marketing.jobs_questions
  FOR SELECT TO anon, authenticated
  USING (EXISTS (SELECT 1 FROM marketing.jobs_postings p WHERE p.id = posting_id AND p.status = 'published'));

-- ---------------------------------------------------------------------------
-- Applications (anonymous submission, same trust model as artist-bio-survey).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marketing.jobs_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  posting_id uuid NOT NULL REFERENCES marketing.jobs_postings(id) ON DELETE CASCADE,
  workspace_id uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,

  first_name text NOT NULL,
  last_name text NOT NULL,
  email text NOT NULL,
  phone text,
  location text,

  resume_path text,
  resume_filename text,
  cover_letter text,
  linkedin_url text,
  portfolio_url text,
  website_url text,

  source text,
  visitor_id uuid,

  current_stage text NOT NULL DEFAULT 'new',
  rating integer CHECK (rating IS NULL OR (rating BETWEEN 1 AND 5)),
  tags text[] NOT NULL DEFAULT '{}',
  assigned_to uuid,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_jobs_applications_posting ON marketing.jobs_applications (posting_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_applications_workspace ON marketing.jobs_applications (workspace_id, current_stage);
CREATE INDEX IF NOT EXISTS idx_jobs_applications_email ON marketing.jobs_applications (lower(email));
-- Prevent obvious accidental double-submits (same person, same job, same day).
-- Uses date_trunc(...AT TIME ZONE 'UTC') rather than created_at::date because
-- the timestamptz->date cast is timezone-dependent (STABLE, not IMMUTABLE)
-- and can't be used in an index expression.
CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_applications_dedupe
  ON marketing.jobs_applications (posting_id, lower(email), date_trunc('day', created_at AT TIME ZONE 'UTC'));

-- No direct anon/authenticated access at all — resumes and applicant PII are
-- only ever readable by the edge function under the service role, after it
-- has verified the caller is staff. This mirrors crm_organizations.
REVOKE ALL ON marketing.jobs_applications FROM anon, authenticated;
GRANT INSERT, SELECT, UPDATE ON marketing.jobs_applications TO service_role;

CREATE TABLE IF NOT EXISTS marketing.jobs_application_answers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL REFERENCES marketing.jobs_applications(id) ON DELETE CASCADE,
  question_id uuid NOT NULL REFERENCES marketing.jobs_questions(id) ON DELETE CASCADE,
  answer text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_jobs_application_answers_application ON marketing.jobs_application_answers (application_id);
REVOKE ALL ON marketing.jobs_application_answers FROM anon, authenticated;
GRANT INSERT, SELECT ON marketing.jobs_application_answers TO service_role;

CREATE TABLE IF NOT EXISTS marketing.jobs_application_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL REFERENCES marketing.jobs_applications(id) ON DELETE CASCADE,
  file_path text NOT NULL,
  file_name text NOT NULL,
  file_type text,
  file_size integer,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_jobs_application_attachments_application ON marketing.jobs_application_attachments (application_id);
REVOKE ALL ON marketing.jobs_application_attachments FROM anon, authenticated;
GRANT INSERT, SELECT, DELETE ON marketing.jobs_application_attachments TO service_role;

CREATE TABLE IF NOT EXISTS marketing.jobs_application_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL REFERENCES marketing.jobs_applications(id) ON DELETE CASCADE,
  author_id uuid NOT NULL,
  note text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_jobs_application_notes_application ON marketing.jobs_application_notes (application_id, created_at DESC);
REVOKE ALL ON marketing.jobs_application_notes FROM anon, authenticated;
GRANT INSERT, SELECT ON marketing.jobs_application_notes TO service_role;

CREATE TABLE IF NOT EXISTS marketing.jobs_application_stage_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL REFERENCES marketing.jobs_applications(id) ON DELETE CASCADE,
  from_stage text,
  to_stage text NOT NULL,
  changed_by uuid,
  changed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_jobs_application_stage_history_application ON marketing.jobs_application_stage_history (application_id, changed_at DESC);
REVOKE ALL ON marketing.jobs_application_stage_history FROM anon, authenticated;
GRANT INSERT, SELECT ON marketing.jobs_application_stage_history TO service_role;

-- ---------------------------------------------------------------------------
-- Saved jobs (anonymous, keyed by a client-generated visitor id) and alerts.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marketing.jobs_saved (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  visitor_id uuid NOT NULL,
  posting_id uuid NOT NULL REFERENCES marketing.jobs_postings(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (visitor_id, posting_id)
);
CREATE INDEX IF NOT EXISTS idx_jobs_saved_visitor ON marketing.jobs_saved (visitor_id, created_at DESC);
REVOKE ALL ON marketing.jobs_saved FROM anon, authenticated;
GRANT INSERT, SELECT, DELETE ON marketing.jobs_saved TO service_role;

CREATE TABLE IF NOT EXISTS marketing.jobs_alerts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  label text,
  query jsonb NOT NULL DEFAULT '{}'::jsonb,
  frequency text NOT NULL DEFAULT 'daily' CHECK (frequency IN ('immediate', 'daily', 'weekly')),
  active boolean NOT NULL DEFAULT true,
  unsubscribe_token uuid NOT NULL DEFAULT gen_random_uuid(),
  last_sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_jobs_alerts_email ON marketing.jobs_alerts (lower(email));
CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_alerts_unsubscribe_token ON marketing.jobs_alerts (unsubscribe_token);
REVOKE ALL ON marketing.jobs_alerts FROM anon, authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE ON marketing.jobs_alerts TO service_role;

-- ---------------------------------------------------------------------------
-- Analytics events (impression, view, apply_click, apply_start,
-- apply_complete, save, share) and moderation / audit trails.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marketing.jobs_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  posting_id uuid REFERENCES marketing.jobs_postings(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN ('impression', 'view', 'apply_click', 'apply_start', 'apply_complete', 'save', 'unsave', 'share')),
  visitor_id uuid,
  source text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_jobs_events_posting_type ON marketing.jobs_events (posting_id, event_type, created_at DESC);
REVOKE ALL ON marketing.jobs_events FROM anon, authenticated;
GRANT INSERT, SELECT ON marketing.jobs_events TO service_role;

CREATE TABLE IF NOT EXISTS marketing.jobs_moderation_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  posting_id uuid NOT NULL REFERENCES marketing.jobs_postings(id) ON DELETE CASCADE,
  reviewer_id uuid,
  action text NOT NULL CHECK (action IN ('approved', 'rejected', 'changes_requested', 'paused', 'removed', 'flagged')),
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_jobs_moderation_log_posting ON marketing.jobs_moderation_log (posting_id, created_at DESC);
REVOKE ALL ON marketing.jobs_moderation_log FROM anon, authenticated;
GRANT INSERT, SELECT ON marketing.jobs_moderation_log TO service_role;

CREATE TABLE IF NOT EXISTS marketing.jobs_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  actor_id uuid,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  before jsonb,
  after jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_jobs_audit_log_workspace ON marketing.jobs_audit_log (workspace_id, created_at DESC);
REVOKE ALL ON marketing.jobs_audit_log FROM anon, authenticated;
GRANT INSERT, SELECT ON marketing.jobs_audit_log TO service_role;

CREATE TABLE IF NOT EXISTS marketing.jobs_settings (
  workspace_id uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  key text NOT NULL,
  value jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, key)
);
REVOKE ALL ON marketing.jobs_settings FROM anon, authenticated;
GRANT INSERT, SELECT, UPDATE ON marketing.jobs_settings TO service_role;

-- ---------------------------------------------------------------------------
-- Row Level Security + updated_at triggers on everything else.
-- ---------------------------------------------------------------------------
ALTER TABLE marketing.jobs_postings ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_application_answers ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_application_attachments ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_application_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_application_stage_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_saved ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_moderation_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.jobs_hiring_stages ENABLE ROW LEVEL SECURITY;

-- Staff (workspace members) can read hiring stages directly; everything else
-- with no policy defined above defaults to "no access" for anon/authenticated
-- since RLS is enabled and only service_role (which bypasses RLS) can act.
DROP POLICY IF EXISTS jobs_hiring_stages_team_read ON marketing.jobs_hiring_stages;
CREATE POLICY jobs_hiring_stages_team_read ON marketing.jobs_hiring_stages
  FOR SELECT TO authenticated
  USING (marketing.workspace_access(workspace_id));
GRANT SELECT ON marketing.jobs_hiring_stages TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON marketing.jobs_hiring_stages FROM anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON marketing.jobs_hiring_stages TO service_role;

DROP TRIGGER IF EXISTS trg_jobs_postings_updated ON marketing.jobs_postings;
CREATE TRIGGER trg_jobs_postings_updated BEFORE UPDATE ON marketing.jobs_postings FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();
DROP TRIGGER IF EXISTS trg_jobs_applications_updated ON marketing.jobs_applications;
CREATE TRIGGER trg_jobs_applications_updated BEFORE UPDATE ON marketing.jobs_applications FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

-- ---------------------------------------------------------------------------
-- Seed default categories, departments, and hiring stages for the loudmusic
-- workspace so the admin UI and public filters have real data immediately.
-- ---------------------------------------------------------------------------
INSERT INTO marketing.jobs_categories (workspace_id, name, slug, sort_order)
SELECT w.id, v.name, v.slug, v.sort_order
FROM marketing.workspaces w
CROSS JOIN (VALUES
  ('Audio Engineering', 'audio-engineering', 1),
  ('Artist & Label Services', 'artist-label-services', 2),
  ('Marketing & Growth', 'marketing-growth', 3),
  ('Product & Engineering', 'product-engineering', 4),
  ('Operations', 'operations', 5),
  ('Sales & Partnerships', 'sales-partnerships', 6),
  ('Customer Support', 'customer-support', 7)
) AS v(name, slug, sort_order)
WHERE w.slug = 'loudmusic'
ON CONFLICT (workspace_id, slug) DO NOTHING;

INSERT INTO marketing.jobs_departments (workspace_id, name, slug, sort_order)
SELECT w.id, v.name, v.slug, v.sort_order
FROM marketing.workspaces w
CROSS JOIN (VALUES
  ('Engineering', 'engineering', 1),
  ('Marketing', 'marketing', 2),
  ('Artist Relations', 'artist-relations', 3),
  ('Operations', 'operations', 4),
  ('Sales', 'sales', 5),
  ('Support', 'support', 6),
  ('Executive', 'executive', 7)
) AS v(name, slug, sort_order)
WHERE w.slug = 'loudmusic'
ON CONFLICT (workspace_id, slug) DO NOTHING;

INSERT INTO marketing.jobs_hiring_stages (workspace_id, key, label, sort_order, is_terminal)
SELECT w.id, v.key, v.label, v.sort_order, v.is_terminal
FROM marketing.workspaces w
CROSS JOIN (VALUES
  ('new', 'New', 1, false),
  ('screening', 'Screening', 2, false),
  ('qualified', 'Qualified', 3, false),
  ('interview', 'Interview', 4, false),
  ('final_interview', 'Final Interview', 5, false),
  ('offer', 'Offer', 6, false),
  ('hired', 'Hired', 7, true),
  ('rejected', 'Rejected', 8, true)
) AS v(key, label, sort_order, is_terminal)
WHERE w.slug = 'loudmusic'
ON CONFLICT (workspace_id, key) DO NOTHING;

-- Default job board settings.
INSERT INTO marketing.jobs_settings (workspace_id, key, value)
SELECT w.id, 'listing', '{"default_expiration_days": 60, "approval_required": false, "allowed_employment_types": ["full_time","part_time","contract","freelance","temporary","internship","apprenticeship"]}'::jsonb
FROM marketing.workspaces w WHERE w.slug = 'loudmusic'
ON CONFLICT (workspace_id, key) DO NOTHING;

INSERT INTO marketing.jobs_settings (workspace_id, key, value)
SELECT w.id, 'candidate', '{"resume_required": true, "allowed_file_types": ["pdf","doc","docx"], "max_file_size_mb": 10}'::jsonb
FROM marketing.workspaces w WHERE w.slug = 'loudmusic'
ON CONFLICT (workspace_id, key) DO NOTHING;

INSERT INTO marketing.jobs_settings (workspace_id, key, value)
SELECT w.id, 'application', '{"confirmation_message": "Thanks for applying. Our hiring team will review your application and follow up by email.", "duplicate_behavior": "reject"}'::jsonb
FROM marketing.workspaces w WHERE w.slug = 'loudmusic'
ON CONFLICT (workspace_id, key) DO NOTHING;

INSERT INTO marketing.jobs_settings (workspace_id, key, value)
SELECT w.id, 'seo', '{"directory_title": "Careers at LOUDmusic", "directory_description": "Open roles at LOUDmusic and the artists, labels, and partners we work with.", "default_social_image": ""}'::jsonb
FROM marketing.workspaces w WHERE w.slug = 'loudmusic'
ON CONFLICT (workspace_id, key) DO NOTHING;

COMMIT;
