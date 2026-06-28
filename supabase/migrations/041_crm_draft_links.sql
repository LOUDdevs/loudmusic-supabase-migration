BEGIN;

ALTER TABLE marketing.crm_communications
  ADD COLUMN IF NOT EXISTS email_draft_id uuid REFERENCES marketing.email_drafts (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS sendpilot_draft_id uuid REFERENCES marketing.sendpilot_drafts (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_crm_comms_email_draft ON marketing.crm_communications (email_draft_id);
CREATE INDEX IF NOT EXISTS idx_crm_comms_sendpilot_draft ON marketing.crm_communications (sendpilot_draft_id);

CREATE OR REPLACE VIEW public.crm_communications AS SELECT * FROM marketing.crm_communications;

NOTIFY pgrst, 'reload schema';

COMMIT;
