-- Migration: 20260809070000_funnel_builder_conversations.sql
-- Conversational Fletcher Method funnel builder: replaces the manual
-- variables form with a chat session that asks one question at a time,
-- then instantiates the full funnel (all pages) from the gathered answers.

CREATE TABLE IF NOT EXISTS marketing.funnel_builder_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES marketing.workspaces(id) ON DELETE CASCADE,
  template_key text NOT NULL CHECK (template_key IN ('zss','ww')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed','abandoned')),
  messages jsonb NOT NULL DEFAULT '[]'::jsonb,
  collected_variables jsonb NOT NULL DEFAULT '{}'::jsonb,
  funnel_id uuid REFERENCES marketing.funnel_funnels(id) ON DELETE SET NULL,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_funnel_builder_conversations_workspace ON marketing.funnel_builder_conversations(workspace_id, created_at DESC);

DROP TRIGGER IF EXISTS trg_funnel_builder_conversations_updated ON marketing.funnel_builder_conversations;
CREATE TRIGGER trg_funnel_builder_conversations_updated BEFORE UPDATE ON marketing.funnel_builder_conversations FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

ALTER TABLE marketing.funnel_builder_conversations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS funnel_builder_conversations_team_access ON marketing.funnel_builder_conversations;
CREATE POLICY funnel_builder_conversations_team_access ON marketing.funnel_builder_conversations FOR ALL TO authenticated USING (marketing.workspace_access(workspace_id)) WITH CHECK (marketing.workspace_access(workspace_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON marketing.funnel_builder_conversations TO service_role;

COMMENT ON TABLE marketing.funnel_builder_conversations IS 'Chat-driven Fletcher Method funnel setup: one row per conversation, full message history + extracted variables, until the funnel is created.';
