-- Migration: 20260814100000_admin_sections_pipeline_sequences_automations.sql
-- Real backends for 5 admin sections whose UI existed with no server
-- implementation: Pipeline, Sequences, Message Templates, Automations,
-- Reports. All new/extended tables live in the marketing schema and follow
-- the workspace_access()/crm_set_updated_at() conventions established in
-- 20260801090000_crm_funnel_phase1.sql.

-- ============================================================================
-- 1. Pipeline: extend existing crm_pipelines/crm_pipeline_stages, add
--    win/loss reasons, opportunities (new — crm_deals has an incompatible
--    shape), and opportunity stage history.
-- ============================================================================

ALTER TABLE marketing.crm_pipelines ADD COLUMN IF NOT EXISTS description text;
ALTER TABLE marketing.crm_pipelines ADD COLUMN IF NOT EXISTS position integer NOT NULL DEFAULT 0;
ALTER TABLE marketing.crm_pipelines ADD COLUMN IF NOT EXISTS is_archived boolean NOT NULL DEFAULT false;

ALTER TABLE marketing.crm_pipeline_stages ADD COLUMN IF NOT EXISTS color text;
ALTER TABLE marketing.crm_pipeline_stages ADD COLUMN IF NOT EXISTS probability integer NOT NULL DEFAULT 0 CHECK (probability >= 0 AND probability <= 100);
ALTER TABLE marketing.crm_pipeline_stages ADD COLUMN IF NOT EXISTS required_fields jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE marketing.crm_pipeline_stages ADD COLUMN IF NOT EXISTS stale_after_days integer;
ALTER TABLE marketing.crm_pipeline_stages ADD COLUMN IF NOT EXISTS default_tasks jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE marketing.crm_pipeline_stages ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE IF NOT EXISTS marketing.crm_pipeline_win_loss_reasons (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pipeline_id  uuid NOT NULL REFERENCES marketing.crm_pipelines(id) ON DELETE CASCADE,
  type         text NOT NULL CHECK (type IN ('win','loss')),
  label        text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketing.crm_opportunities (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id         uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  name                 text NOT NULL,
  contact_id           uuid REFERENCES marketing.crm_contacts(id) ON DELETE SET NULL,
  company_id           uuid REFERENCES marketing.crm_organizations(id) ON DELETE SET NULL,
  pipeline_id          uuid NOT NULL REFERENCES marketing.crm_pipelines(id) ON DELETE RESTRICT,
  stage_id             uuid NOT NULL REFERENCES marketing.crm_pipeline_stages(id) ON DELETE RESTRICT,
  owner_id             uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  team_id              uuid,
  value                numeric(14,2) NOT NULL DEFAULT 0,
  currency             text NOT NULL DEFAULT 'USD',
  expected_close_date  date,
  product              text,
  source               text,
  funnel_id            uuid REFERENCES marketing.funnel_funnels(id) ON DELETE SET NULL,
  campaign_id          uuid,
  next_step            text,
  competitors          jsonb NOT NULL DEFAULT '[]'::jsonb,
  win_reason_id        uuid REFERENCES marketing.crm_pipeline_win_loss_reasons(id) ON DELETE SET NULL,
  loss_reason_id       uuid REFERENCES marketing.crm_pipeline_win_loss_reasons(id) ON DELETE SET NULL,
  custom_fields        jsonb NOT NULL DEFAULT '{}'::jsonb,
  status               text NOT NULL DEFAULT 'open' CHECK (status IN ('open','won','lost')),
  probability          integer CHECK (probability >= 0 AND probability <= 100),
  is_archived          boolean NOT NULL DEFAULT false,
  last_activity_at     timestamptz,
  next_activity_at     timestamptz,
  closed_at            timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_opportunities_workspace ON marketing.crm_opportunities(workspace_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_crm_opportunities_pipeline_stage ON marketing.crm_opportunities(pipeline_id, stage_id);
CREATE INDEX IF NOT EXISTS idx_crm_opportunities_contact ON marketing.crm_opportunities(contact_id);
CREATE INDEX IF NOT EXISTS idx_crm_opportunities_company ON marketing.crm_opportunities(company_id);

CREATE TABLE IF NOT EXISTS marketing.crm_opportunity_stage_history (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  opportunity_id    uuid NOT NULL REFERENCES marketing.crm_opportunities(id) ON DELETE CASCADE,
  from_stage_id     uuid REFERENCES marketing.crm_pipeline_stages(id) ON DELETE SET NULL,
  to_stage_id       uuid NOT NULL REFERENCES marketing.crm_pipeline_stages(id) ON DELETE CASCADE,
  changed_by        uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  entered_at        timestamptz NOT NULL DEFAULT now(),
  duration_seconds  integer
);

CREATE INDEX IF NOT EXISTS idx_crm_opp_stage_history_opp ON marketing.crm_opportunity_stage_history(opportunity_id, entered_at DESC);

ALTER TABLE marketing.crm_tasks ADD COLUMN IF NOT EXISTS opportunity_id uuid REFERENCES marketing.crm_opportunities(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_crm_tasks_opportunity ON marketing.crm_tasks(opportunity_id);

-- ============================================================================
-- 2. Message Templates (created before Sequences since sequence steps and
--    the outbound queue reference it).
-- ============================================================================

CREATE TABLE IF NOT EXISTS marketing.crm_message_templates (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id       uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  name               text NOT NULL,
  channel            text NOT NULL CHECK (channel IN ('email','sms')),
  subject            text,
  preview_text       text,
  body_html          text,
  body_text          text,
  variable_defaults  jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_message_templates_workspace ON marketing.crm_message_templates(workspace_id, updated_at DESC);

-- ============================================================================
-- 3. Sequences
-- ============================================================================

CREATE TABLE IF NOT EXISTS marketing.crm_sequences (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id          uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  name                  text NOT NULL,
  description           text,
  status                text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','archived')),
  goal_event_type       text,
  default_sender_id     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  from_name             text,
  business_hours_only   boolean NOT NULL DEFAULT false,
  use_contact_timezone  boolean NOT NULL DEFAULT false,
  send_on_weekends      boolean NOT NULL DEFAULT false,
  re_entry_allowed      boolean NOT NULL DEFAULT false,
  exit_on_events        jsonb NOT NULL DEFAULT '[]'::jsonb,
  published_version_id  uuid,
  owner_id              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  team_id               uuid,
  created_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_sequences_workspace ON marketing.crm_sequences(workspace_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS marketing.crm_sequence_versions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sequence_id     uuid NOT NULL REFERENCES marketing.crm_sequences(id) ON DELETE CASCADE,
  version_number  integer NOT NULL,
  status          text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','archived')),
  published_at    timestamptz,
  published_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sequence_id, version_number)
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'crm_sequences_published_version_fk') THEN
    ALTER TABLE marketing.crm_sequences ADD CONSTRAINT crm_sequences_published_version_fk FOREIGN KEY (published_version_id) REFERENCES marketing.crm_sequence_versions(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS marketing.crm_sequence_steps (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sequence_version_id   uuid NOT NULL REFERENCES marketing.crm_sequence_versions(id) ON DELETE CASCADE,
  position              integer NOT NULL DEFAULT 0,
  step_type             text NOT NULL CHECK (step_type IN (
    'automated_email','manual_email_task','sms','phone_call_task','social_task','general_task',
    'internal_notification','wait_period','wait_until_date','wait_until_business_hours',
    'wait_for_contact_action','conditional_branch','field_update','tag_update','owner_assignment',
    'pipeline_update','webhook','sequence_enrollment','sequence_removal'
  )),
  name                  text,
  message_template_id   uuid REFERENCES marketing.crm_message_templates(id) ON DELETE SET NULL,
  config                jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_sequence_steps_version ON marketing.crm_sequence_steps(sequence_version_id, position ASC);

CREATE TABLE IF NOT EXISTS marketing.crm_enrollments (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sequence_id          uuid NOT NULL REFERENCES marketing.crm_sequences(id) ON DELETE CASCADE,
  sequence_version_id  uuid NOT NULL REFERENCES marketing.crm_sequence_versions(id) ON DELETE CASCADE,
  contact_id           uuid NOT NULL REFERENCES marketing.crm_contacts(id) ON DELETE CASCADE,
  status               text NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','completed','exited','failed')),
  current_step_id      uuid REFERENCES marketing.crm_sequence_steps(id) ON DELETE SET NULL,
  enrollment_source    text,
  enrolled_at          timestamptz NOT NULL DEFAULT now(),
  next_step_at         timestamptz,
  paused_at            timestamptz,
  completed_at         timestamptz,
  exited_at            timestamptz,
  exit_reason          text,
  goal_completed_at    timestamptz
);

CREATE INDEX IF NOT EXISTS idx_crm_enrollments_sequence ON marketing.crm_enrollments(sequence_id, status);
CREATE INDEX IF NOT EXISTS idx_crm_enrollments_due ON marketing.crm_enrollments(status, next_step_at) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_crm_enrollments_contact ON marketing.crm_enrollments(contact_id);

-- ============================================================================
-- 4. Automations
-- ============================================================================

CREATE TABLE IF NOT EXISTS marketing.crm_automations (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id          uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  name                  text NOT NULL,
  description           text,
  status                text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','paused','archived')),
  published_version_id  uuid,
  max_runs_per_record   integer,
  cooldown_seconds      integer,
  owner_id              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  team_id               uuid,
  created_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_automations_workspace ON marketing.crm_automations(workspace_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS marketing.crm_automation_versions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  automation_id   uuid NOT NULL REFERENCES marketing.crm_automations(id) ON DELETE CASCADE,
  version_number  integer NOT NULL,
  status          text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','archived')),
  trigger_type    text NOT NULL DEFAULT 'event',
  trigger_config  jsonb NOT NULL DEFAULT '{}'::jsonb,
  conditions      jsonb NOT NULL DEFAULT '{}'::jsonb,
  actions         jsonb NOT NULL DEFAULT '[]'::jsonb,
  published_at    timestamptz,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (automation_id, version_number)
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'crm_automations_published_version_fk') THEN
    ALTER TABLE marketing.crm_automations ADD CONSTRAINT crm_automations_published_version_fk FOREIGN KEY (published_version_id) REFERENCES marketing.crm_automation_versions(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS marketing.crm_automation_executions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  automation_id        uuid NOT NULL REFERENCES marketing.crm_automations(id) ON DELETE CASCADE,
  automation_version_id uuid NOT NULL REFERENCES marketing.crm_automation_versions(id) ON DELETE CASCADE,
  trigger_entity_type  text,
  trigger_entity_id    uuid,
  status               text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','completed','failed','skipped','dead_letter')),
  next_action_index    integer NOT NULL DEFAULT 0,
  next_run_at          timestamptz DEFAULT now(),
  retry_count          integer NOT NULL DEFAULT 0,
  error_message        text,
  started_at           timestamptz,
  ended_at             timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_automation_executions_automation ON marketing.crm_automation_executions(automation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_crm_automation_executions_due ON marketing.crm_automation_executions(status, next_run_at) WHERE status IN ('pending','running');

CREATE TABLE IF NOT EXISTS marketing.crm_automation_execution_steps (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  execution_id   uuid NOT NULL REFERENCES marketing.crm_automation_executions(id) ON DELETE CASCADE,
  action_index   integer NOT NULL,
  action_type    text NOT NULL,
  status         text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed','skipped','failed')),
  input          jsonb NOT NULL DEFAULT '{}'::jsonb,
  output         jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_message  text,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_automation_execution_steps_execution ON marketing.crm_automation_execution_steps(execution_id, action_index ASC);

-- ============================================================================
-- 5. Outbound queue: extend the existing provider-neutral review queue
--    (funnel_outbound_queue) so message-template test-sends, sequence email/
--    sms steps, and automation send_email/send_sms actions all funnel
--    through one real, already-RLS'd table instead of a parallel one.
-- ============================================================================

ALTER TABLE marketing.funnel_outbound_queue ADD COLUMN IF NOT EXISTS message_template_id uuid REFERENCES marketing.crm_message_templates(id) ON DELETE SET NULL;
ALTER TABLE marketing.funnel_outbound_queue ADD COLUMN IF NOT EXISTS crm_enrollment_id uuid REFERENCES marketing.crm_enrollments(id) ON DELETE SET NULL;
ALTER TABLE marketing.funnel_outbound_queue ADD COLUMN IF NOT EXISTS automation_execution_id uuid REFERENCES marketing.crm_automation_executions(id) ON DELETE SET NULL;

-- ============================================================================
-- 6. Triggers
-- ============================================================================

DROP TRIGGER IF EXISTS trg_crm_pipelines_updated ON marketing.crm_pipelines;
CREATE TRIGGER trg_crm_pipelines_updated BEFORE UPDATE ON marketing.crm_pipelines FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();
DROP TRIGGER IF EXISTS trg_crm_pipeline_stages_updated ON marketing.crm_pipeline_stages;
CREATE TRIGGER trg_crm_pipeline_stages_updated BEFORE UPDATE ON marketing.crm_pipeline_stages FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();
DROP TRIGGER IF EXISTS trg_crm_opportunities_updated ON marketing.crm_opportunities;
CREATE TRIGGER trg_crm_opportunities_updated BEFORE UPDATE ON marketing.crm_opportunities FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();
DROP TRIGGER IF EXISTS trg_crm_message_templates_updated ON marketing.crm_message_templates;
CREATE TRIGGER trg_crm_message_templates_updated BEFORE UPDATE ON marketing.crm_message_templates FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();
DROP TRIGGER IF EXISTS trg_crm_sequences_updated ON marketing.crm_sequences;
CREATE TRIGGER trg_crm_sequences_updated BEFORE UPDATE ON marketing.crm_sequences FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();
DROP TRIGGER IF EXISTS trg_crm_sequence_steps_updated ON marketing.crm_sequence_steps;
CREATE TRIGGER trg_crm_sequence_steps_updated BEFORE UPDATE ON marketing.crm_sequence_steps FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();
DROP TRIGGER IF EXISTS trg_crm_automations_updated ON marketing.crm_automations;
CREATE TRIGGER trg_crm_automations_updated BEFORE UPDATE ON marketing.crm_automations FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

-- ============================================================================
-- 7. RLS
-- ============================================================================

ALTER TABLE marketing.crm_pipeline_win_loss_reasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_opportunities ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_opportunity_stage_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_message_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_sequences ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_sequence_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_sequence_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_automations ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_automation_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_automation_executions ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.crm_automation_execution_steps ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS crm_pipeline_win_loss_reasons_team_access ON marketing.crm_pipeline_win_loss_reasons;
CREATE POLICY crm_pipeline_win_loss_reasons_team_access ON marketing.crm_pipeline_win_loss_reasons FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM marketing.crm_pipelines p WHERE p.id = pipeline_id AND marketing.workspace_access(p.workspace_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM marketing.crm_pipelines p WHERE p.id = pipeline_id AND marketing.workspace_access(p.workspace_id)));

DROP POLICY IF EXISTS crm_opportunities_team_access ON marketing.crm_opportunities;
CREATE POLICY crm_opportunities_team_access ON marketing.crm_opportunities FOR ALL TO authenticated
  USING (marketing.workspace_access(workspace_id)) WITH CHECK (marketing.workspace_access(workspace_id));

DROP POLICY IF EXISTS crm_opportunity_stage_history_team_access ON marketing.crm_opportunity_stage_history;
CREATE POLICY crm_opportunity_stage_history_team_access ON marketing.crm_opportunity_stage_history FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM marketing.crm_opportunities o WHERE o.id = opportunity_id AND marketing.workspace_access(o.workspace_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM marketing.crm_opportunities o WHERE o.id = opportunity_id AND marketing.workspace_access(o.workspace_id)));

DROP POLICY IF EXISTS crm_message_templates_team_access ON marketing.crm_message_templates;
CREATE POLICY crm_message_templates_team_access ON marketing.crm_message_templates FOR ALL TO authenticated
  USING (marketing.workspace_access(workspace_id)) WITH CHECK (marketing.workspace_access(workspace_id));

DROP POLICY IF EXISTS crm_sequences_team_access ON marketing.crm_sequences;
CREATE POLICY crm_sequences_team_access ON marketing.crm_sequences FOR ALL TO authenticated
  USING (marketing.workspace_access(workspace_id)) WITH CHECK (marketing.workspace_access(workspace_id));

DROP POLICY IF EXISTS crm_sequence_versions_team_access ON marketing.crm_sequence_versions;
CREATE POLICY crm_sequence_versions_team_access ON marketing.crm_sequence_versions FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM marketing.crm_sequences s WHERE s.id = sequence_id AND marketing.workspace_access(s.workspace_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM marketing.crm_sequences s WHERE s.id = sequence_id AND marketing.workspace_access(s.workspace_id)));

DROP POLICY IF EXISTS crm_sequence_steps_team_access ON marketing.crm_sequence_steps;
CREATE POLICY crm_sequence_steps_team_access ON marketing.crm_sequence_steps FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM marketing.crm_sequence_versions v JOIN marketing.crm_sequences s ON s.id = v.sequence_id WHERE v.id = sequence_version_id AND marketing.workspace_access(s.workspace_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM marketing.crm_sequence_versions v JOIN marketing.crm_sequences s ON s.id = v.sequence_id WHERE v.id = sequence_version_id AND marketing.workspace_access(s.workspace_id)));

DROP POLICY IF EXISTS crm_enrollments_team_access ON marketing.crm_enrollments;
CREATE POLICY crm_enrollments_team_access ON marketing.crm_enrollments FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM marketing.crm_sequences s WHERE s.id = sequence_id AND marketing.workspace_access(s.workspace_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM marketing.crm_sequences s WHERE s.id = sequence_id AND marketing.workspace_access(s.workspace_id)));

DROP POLICY IF EXISTS crm_automations_team_access ON marketing.crm_automations;
CREATE POLICY crm_automations_team_access ON marketing.crm_automations FOR ALL TO authenticated
  USING (marketing.workspace_access(workspace_id)) WITH CHECK (marketing.workspace_access(workspace_id));

DROP POLICY IF EXISTS crm_automation_versions_team_access ON marketing.crm_automation_versions;
CREATE POLICY crm_automation_versions_team_access ON marketing.crm_automation_versions FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM marketing.crm_automations a WHERE a.id = automation_id AND marketing.workspace_access(a.workspace_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM marketing.crm_automations a WHERE a.id = automation_id AND marketing.workspace_access(a.workspace_id)));

DROP POLICY IF EXISTS crm_automation_executions_team_access ON marketing.crm_automation_executions;
CREATE POLICY crm_automation_executions_team_access ON marketing.crm_automation_executions FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM marketing.crm_automations a WHERE a.id = automation_id AND marketing.workspace_access(a.workspace_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM marketing.crm_automations a WHERE a.id = automation_id AND marketing.workspace_access(a.workspace_id)));

DROP POLICY IF EXISTS crm_automation_execution_steps_team_access ON marketing.crm_automation_execution_steps;
CREATE POLICY crm_automation_execution_steps_team_access ON marketing.crm_automation_execution_steps FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM marketing.crm_automation_executions e JOIN marketing.crm_automations a ON a.id = e.automation_id WHERE e.id = execution_id AND marketing.workspace_access(a.workspace_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM marketing.crm_automation_executions e JOIN marketing.crm_automations a ON a.id = e.automation_id WHERE e.id = execution_id AND marketing.workspace_access(a.workspace_id)));

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA marketing TO service_role;

-- Seed a default pipeline + stages for the loudmusic workspace if none exists yet.
DO $$
DECLARE
  ws_id uuid;
  pipe_id uuid;
BEGIN
  SELECT id INTO ws_id FROM marketing.workspaces WHERE slug = 'loudmusic';
  IF ws_id IS NULL THEN RETURN; END IF;

  SELECT id INTO pipe_id FROM marketing.crm_pipelines WHERE workspace_id = ws_id AND is_default = true LIMIT 1;
  IF pipe_id IS NULL THEN
    INSERT INTO marketing.crm_pipelines (workspace_id, name, is_default, position)
    VALUES (ws_id, 'Sales Pipeline', true, 0)
    RETURNING id INTO pipe_id;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM marketing.crm_pipeline_stages WHERE pipeline_id = pipe_id) THEN
    INSERT INTO marketing.crm_pipeline_stages (pipeline_id, name, sort_order, probability, is_won, is_lost) VALUES
      (pipe_id, 'New', 0, 10, false, false),
      (pipe_id, 'Qualified', 1, 25, false, false),
      (pipe_id, 'Proposal', 2, 50, false, false),
      (pipe_id, 'Negotiation', 3, 75, false, false),
      (pipe_id, 'Won', 4, 100, true, false),
      (pipe_id, 'Lost', 5, 0, false, true);

    INSERT INTO marketing.crm_pipeline_win_loss_reasons (pipeline_id, type, label)
    VALUES
      (pipe_id, 'win', 'Good fit'),
      (pipe_id, 'win', 'Competitive pricing'),
      (pipe_id, 'loss', 'Went with a competitor'),
      (pipe_id, 'loss', 'Budget'),
      (pipe_id, 'loss', 'No response');
  END IF;
END $$;
