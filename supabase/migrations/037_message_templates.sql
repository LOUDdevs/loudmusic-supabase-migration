-- Migration: 037_message_templates.sql
-- Reusable message templates with merge fields for email and SendPilot.

BEGIN;

CREATE TABLE marketing.message_templates (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  channel       text NOT NULL DEFAULT 'both'
    CHECK (channel IN ('email', 'sendpilot', 'both')),
  scope         text NOT NULL DEFAULT 'personal'
    CHECK (scope IN ('personal', 'team')),
  created_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  subject       text,
  body          text NOT NULL,
  description   text,
  tags          text[] NOT NULL DEFAULT '{}',
  is_archived   boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_message_templates_channel ON marketing.message_templates (channel) WHERE is_archived = false;
CREATE INDEX idx_message_templates_scope ON marketing.message_templates (scope, created_by) WHERE is_archived = false;

CREATE TRIGGER message_templates_updated_at
  BEFORE UPDATE ON marketing.message_templates
  FOR EACH ROW EXECUTE FUNCTION marketing.crm_set_updated_at();

ALTER TABLE marketing.message_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "message_templates_select" ON marketing.message_templates
  FOR SELECT TO authenticated
  USING (
    marketing.current_user_role() IN ('super_admin', 'admin', 'editor', 'viewer')
    AND (
      scope = 'team'
      OR (scope = 'personal' AND created_by = auth.uid())
    )
  );

CREATE POLICY "message_templates_write" ON marketing.message_templates
  FOR ALL TO authenticated
  USING (
    marketing.current_user_role() IN ('super_admin', 'admin', 'editor')
    AND (
      scope = 'team'
      OR (scope = 'personal' AND created_by = auth.uid())
    )
  )
  WITH CHECK (
    marketing.current_user_role() IN ('super_admin', 'admin', 'editor')
    AND (
      scope = 'team'
      OR (scope = 'personal' AND created_by = auth.uid())
    )
  );

CREATE OR REPLACE VIEW public.message_templates AS
SELECT * FROM marketing.message_templates;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.message_templates TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
