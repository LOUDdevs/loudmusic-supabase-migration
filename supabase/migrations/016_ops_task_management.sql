-- Migration: 016_ops_task_management.sql
-- Ops automation task registry, runs, logs, fixes, agent requests, prompt templates.
-- Run AFTER 015_crm_contacts_list_performance.sql.

BEGIN;

-- ============================================================================
-- 1. Enums
-- ============================================================================

CREATE TYPE marketing.ops_task_status AS ENUM (
  'unknown',
  'pending',
  'running',
  'success',
  'failed',
  'paused'
);

CREATE TYPE marketing.task_run_status AS ENUM (
  'pending',
  'running',
  'success',
  'failed',
  'cancelled'
);

CREATE TYPE marketing.task_trigger_type AS ENUM (
  'cron',
  'manual',
  'test',
  'quick_fix',
  'sync'
);

CREATE TYPE marketing.task_fix_status AS ENUM (
  'suggested',
  'applied',
  'failed',
  'skipped'
);

CREATE TYPE marketing.task_agent_request_status AS ENUM (
  'draft',
  'pending',
  'sent',
  'completed',
  'failed'
);

CREATE TYPE marketing.task_agent_action_type AS ENUM (
  'fix_failed',
  'update_task',
  'test_task',
  'explain_task',
  'improve_reliability',
  'add_logging',
  'add_error_handling',
  'add_retry_logic',
  'add_integration',
  'create_related_task'
);

-- ============================================================================
-- 2. Registry
-- ============================================================================

CREATE TABLE marketing.ops_automation_tasks (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  external_key          text NOT NULL UNIQUE,
  name                  text NOT NULL,
  description           text,
  type                  text NOT NULL DEFAULT 'cron',
  status                marketing.ops_task_status NOT NULL DEFAULT 'unknown',
  schedule_display      text,
  cron_expression       text,
  timezone              text DEFAULT 'America/New_York',
  service_key           text,
  module_key            text,
  handler_name          text,
  source                text NOT NULL CHECK (source IN ('hermes', 'marketing')),
  last_run_at           timestamptz,
  next_run_at           timestamptz,
  last_success_at       timestamptz,
  last_failure_at       timestamptz,
  failure_count         integer NOT NULL DEFAULT 0,
  last_error_summary    text,
  last_error_details    jsonb,
  is_enabled            boolean NOT NULL DEFAULT true,
  supports_dry_run      boolean NOT NULL DEFAULT true,
  supports_quick_fix    boolean NOT NULL DEFAULT false,
  quick_fix_type        text,
  metadata              jsonb NOT NULL DEFAULT '{}',
  created_by            uuid REFERENCES auth.users (id),
  updated_by            uuid REFERENCES auth.users (id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_ops_tasks_status ON marketing.ops_automation_tasks (status);
CREATE INDEX idx_ops_tasks_last_run ON marketing.ops_automation_tasks (last_run_at DESC NULLS LAST);
CREATE INDEX idx_ops_tasks_next_run ON marketing.ops_automation_tasks (next_run_at NULLS LAST);
CREATE INDEX idx_ops_tasks_service ON marketing.ops_automation_tasks (service_key);
CREATE INDEX idx_ops_tasks_enabled ON marketing.ops_automation_tasks (is_enabled);

-- ============================================================================
-- 3. Runs, logs, fixes, agent requests
-- ============================================================================

CREATE TABLE marketing.task_runs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id         uuid NOT NULL REFERENCES marketing.ops_automation_tasks (id) ON DELETE CASCADE,
  status          marketing.task_run_status NOT NULL DEFAULT 'pending',
  started_at      timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz,
  duration_ms     integer,
  trigger_type    marketing.task_trigger_type NOT NULL DEFAULT 'manual',
  triggered_by    uuid REFERENCES auth.users (id),
  dry_run         boolean NOT NULL DEFAULT false,
  input_payload   jsonb,
  output_payload  jsonb,
  error_summary   text,
  error_details   jsonb,
  logs            text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_task_runs_task_started ON marketing.task_runs (task_id, started_at DESC);
CREATE INDEX idx_task_runs_status ON marketing.task_runs (status);

CREATE TABLE marketing.task_logs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id         uuid NOT NULL REFERENCES marketing.ops_automation_tasks (id) ON DELETE CASCADE,
  task_run_id     uuid REFERENCES marketing.task_runs (id) ON DELETE SET NULL,
  level           text NOT NULL DEFAULT 'info',
  message         text NOT NULL,
  context         jsonb,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_task_logs_run ON marketing.task_logs (task_run_id, created_at);
CREATE INDEX idx_task_logs_task ON marketing.task_logs (task_id, created_at DESC);

CREATE TABLE marketing.task_fixes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id         uuid NOT NULL REFERENCES marketing.ops_automation_tasks (id) ON DELETE CASCADE,
  task_run_id     uuid REFERENCES marketing.task_runs (id) ON DELETE SET NULL,
  fix_type        text NOT NULL,
  status          marketing.task_fix_status NOT NULL DEFAULT 'suggested',
  explanation     text,
  suggested_fix   text,
  applied_fix     text,
  applied_by        uuid REFERENCES auth.users (id),
  applied_at      timestamptz,
  result          jsonb,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_task_fixes_task ON marketing.task_fixes (task_id, created_at DESC);

CREATE TABLE marketing.task_prompt_templates (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key             text NOT NULL UNIQUE,
  name            text NOT NULL,
  description     text,
  template        text NOT NULL,
  action_type     marketing.task_agent_action_type NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE marketing.task_agent_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id           uuid NOT NULL REFERENCES marketing.ops_automation_tasks (id) ON DELETE CASCADE,
  task_run_id       uuid REFERENCES marketing.task_runs (id) ON DELETE SET NULL,
  action_type       marketing.task_agent_action_type NOT NULL,
  user_input        text,
  generated_prompt  text NOT NULL,
  status            marketing.task_agent_request_status NOT NULL DEFAULT 'draft',
  agent_response    text,
  created_by        uuid REFERENCES auth.users (id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_task_agent_req_task ON marketing.task_agent_requests (task_id, created_at DESC);
CREATE INDEX idx_task_agent_req_status ON marketing.task_agent_requests (status);

-- ============================================================================
-- 4. Public view for ingestion runs (dashboard queries this today)
-- ============================================================================

CREATE OR REPLACE VIEW public.dashboard_ingestion_runs AS
  SELECT * FROM marketing.dashboard_ingestion_runs;

GRANT SELECT ON public.dashboard_ingestion_runs TO anon, authenticated, service_role;

-- ============================================================================
-- 5. Public views for ops tables
-- ============================================================================

CREATE OR REPLACE VIEW public.ops_automation_tasks AS
  SELECT * FROM marketing.ops_automation_tasks;

CREATE OR REPLACE VIEW public.task_runs AS
  SELECT * FROM marketing.task_runs;

CREATE OR REPLACE VIEW public.task_logs AS
  SELECT * FROM marketing.task_logs;

CREATE OR REPLACE VIEW public.task_fixes AS
  SELECT * FROM marketing.task_fixes;

CREATE OR REPLACE VIEW public.task_prompt_templates AS
  SELECT * FROM marketing.task_prompt_templates;

CREATE OR REPLACE VIEW public.task_agent_requests AS
  SELECT * FROM marketing.task_agent_requests;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.ops_automation_tasks TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.task_runs TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.task_logs TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.task_fixes TO anon, authenticated, service_role;
GRANT SELECT ON public.task_prompt_templates TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.task_agent_requests TO anon, authenticated, service_role;

-- ============================================================================
-- 6. RLS
-- ============================================================================

ALTER TABLE marketing.ops_automation_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.task_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.task_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.task_fixes ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.task_prompt_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.task_agent_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ops_tasks_read_team" ON marketing.ops_automation_tasks
  FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

CREATE POLICY "ops_tasks_write_editor" ON marketing.ops_automation_tasks
  FOR ALL TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'))
  WITH CHECK (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "ops_tasks_anon_read" ON marketing.ops_automation_tasks
  FOR SELECT TO anon USING (true);

CREATE POLICY "ops_tasks_anon_write" ON marketing.ops_automation_tasks
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY "task_runs_read_team" ON marketing.task_runs
  FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

CREATE POLICY "task_runs_write_editor" ON marketing.task_runs
  FOR ALL TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'))
  WITH CHECK (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "task_runs_anon_all" ON marketing.task_runs
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY "task_logs_read_team" ON marketing.task_logs
  FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

CREATE POLICY "task_logs_write_editor" ON marketing.task_logs
  FOR INSERT TO authenticated
  WITH CHECK (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "task_logs_anon_all" ON marketing.task_logs
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY "task_fixes_read_team" ON marketing.task_fixes
  FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

CREATE POLICY "task_fixes_write_editor" ON marketing.task_fixes
  FOR ALL TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'))
  WITH CHECK (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "task_fixes_anon_all" ON marketing.task_fixes
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY "task_templates_read" ON marketing.task_prompt_templates
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY "task_agent_read_team" ON marketing.task_agent_requests
  FOR SELECT TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer'));

CREATE POLICY "task_agent_write_editor" ON marketing.task_agent_requests
  FOR ALL TO authenticated
  USING (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'))
  WITH CHECK (marketing.current_user_role() IN ('super_admin', 'admin', 'editor'));

CREATE POLICY "task_agent_anon_all" ON marketing.task_agent_requests
  FOR ALL TO anon USING (true) WITH CHECK (true);

-- ============================================================================
-- 7. Seed prompt templates
-- ============================================================================

INSERT INTO marketing.task_prompt_templates (key, name, description, action_type, template)
VALUES
(
  'fix_failed_task',
  'Fix failed task',
  'Debug and repair a failed scheduled task',
  'fix_failed',
  E'You are my senior debugging engineer for the LOUDmusic Hermes dashboard.\n\nA scheduled task/cronjob has failed. Analyze the task, identify the root cause, and propose the safest fix.\n\nTask details:\n- Name: {{name}}\n- ID: {{id}}\n- External key: {{external_key}}\n- Type: {{type}}\n- Schedule: {{schedule_display}}\n- Service/module: {{service_key}} / {{module_key}}\n- Source: {{source}}\n- Last successful run: {{last_success_at}}\n- Last failed run: {{last_failure_at}}\n- Current status: {{status}}\n- Error summary: {{last_error_summary}}\n- Error details: {{last_error_details}}\n- Related integration: {{ingestion_source}}\n- Recent logs: {{recent_logs}}\n\nFailure classification:\n- Category: {{failure_category}}\n- Likely cause: {{failure_explanation}}\n- Risk level: {{risk_level}}\n\nUser goal:\n{{user_input}}\n\nRequirements:\n- Explain the likely root cause.\n- Identify exact files/functions likely involved.\n- Propose a safe fix.\n- Add better error handling if needed.\n- Add retry logic if appropriate.\n- Add logging if missing.\n- Preserve existing behavior.\n- Avoid destructive changes.\n- Add or update tests where possible.\n- Provide a summary of files changed and how to test.'
),
(
  'update_task',
  'Update task',
  'Expand or change an existing scheduled task',
  'update_task',
  E'You are my senior product engineer for the LOUDmusic Hermes dashboard.\n\nI want to update or expand an existing scheduled task/cronjob.\n\nCurrent task:\n- Name: {{name}}\n- ID: {{id}}\n- External key: {{external_key}}\n- Type: {{type}}\n- Schedule: {{schedule_display}}\n- Current behavior: {{description}}\n- Related service/module: {{service_key}} / {{module_key}}\n- Related integrations: {{ingestion_source}}\n- Metadata: {{metadata}}\n\nRequested update:\n{{user_input}}\n\nDesired outcome: {{desired_outcome}}\n\nRequirements:\n- Preserve the current task unless explicitly asked to replace it.\n- Add new behavior modularly.\n- Update the UI if needed.\n- Update the database schema only if necessary.\n- Add validation and error handling.\n- Add logging.\n- Add dry-run/test support.\n- Summarize changes and next steps.'
),
(
  'test_task',
  'Test task',
  'Safely test a scheduled task',
  'test_task',
  E'You are my QA engineer for the LOUDmusic Hermes dashboard.\n\nI need to test this scheduled task/cronjob safely.\n\nTask:\n- Name: {{name}}\n- ID: {{id}}\n- Type: {{type}}\n- Schedule: {{schedule_display}}\n- Current behavior: {{description}}\n- Related service/module: {{service_key}}\n- Side effects: {{side_effects}}\n- Dry run available: {{supports_dry_run}}\n\nTesting goal:\n{{user_input}}\n\nRequirements:\n- Create a safe test plan.\n- Prefer dry-run mode.\n- Do not send real outbound messages unless explicitly allowed.\n- Do not mutate production data unless explicitly allowed.\n- Show expected vs actual result.\n- Capture logs.\n- Report pass/fail.\n- Recommend next action.'
),
(
  'explain_task',
  'Explain task',
  'Explain what a task does and how it behaves',
  'explain_task',
  E'Explain this scheduled task in plain language for an operator.\n\nTask: {{name}} ({{external_key}})\nSchedule: {{schedule_display}}\nStatus: {{status}}\nDescription: {{description}}\nLast run: {{last_run_at}}\nMetadata: {{metadata}}\n\nUser question: {{user_input}}'
),
(
  'improve_reliability',
  'Improve reliability',
  'Harden task against failures',
  'improve_reliability',
  E'Improve reliability for task {{name}} ({{external_key}}).\nCurrent failures: {{failure_count}}\nLast error: {{last_error_summary}}\n\n{{user_input}}'
),
(
  'add_logging',
  'Add logging',
  'Add structured logging to a task',
  'add_logging',
  E'Add structured logging for task {{name}} ({{external_key}}).\nCurrent behavior: {{description}}\n\n{{user_input}}'
),
(
  'add_error_handling',
  'Add error handling',
  'Improve error handling for a task',
  'add_error_handling',
  E'Add error handling for task {{name}} ({{external_key}}).\nLast error: {{last_error_summary}}\n\n{{user_input}}'
),
(
  'add_retry_logic',
  'Add retry logic',
  'Add retries with backoff',
  'add_retry_logic',
  E'Add retry logic for task {{name}} ({{external_key}}).\nFailure category: {{failure_category}}\n\n{{user_input}}'
),
(
  'add_integration',
  'Add integration',
  'Extend task with new integration',
  'add_integration',
  E'Add integration support for task {{name}} ({{external_key}}).\nCurrent integrations: {{ingestion_source}}\n\n{{user_input}}'
),
(
  'create_related_task',
  'Create related task',
  'Propose a new related scheduled task',
  'create_related_task',
  E'Create a new related scheduled task based on {{name}} ({{external_key}}).\n\n{{user_input}}'
)
ON CONFLICT (key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

COMMIT;
