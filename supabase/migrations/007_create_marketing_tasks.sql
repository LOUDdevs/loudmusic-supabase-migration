CREATE TABLE marketing.tasks (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title             text NOT NULL,
  description       text,
  owner             text NOT NULL,
  cadence           text NOT NULL CHECK (cadence IN ('daily','weekly','monthly','quarterly')),
  interval_count    integer NOT NULL DEFAULT 1,
  last_completed_at timestamptz,
  next_due_at       timestamptz NOT NULL DEFAULT now(),
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_tasks_cadence  ON marketing.tasks (cadence);
CREATE INDEX idx_tasks_active   ON marketing.tasks (is_active);
CREATE INDEX idx_tasks_next_due ON marketing.tasks (next_due_at);

-- Trigger: auto-compute next_due_at on insert or when last_completed_at changes
CREATE OR REPLACE FUNCTION marketing.compute_next_due()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.last_completed_at IS NULL THEN
    NEW.next_due_at := now();
  ELSE
    NEW.next_due_at := NEW.last_completed_at
      + (NEW.interval_count || CASE NEW.cadence
          WHEN 'daily'    THEN ' days'
          WHEN 'weekly'   THEN ' weeks'
          WHEN 'monthly'  THEN ' months'
          WHEN 'quarterly' THEN ' months'
        END)::interval;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tasks_next_due
  BEFORE INSERT OR UPDATE OF last_completed_at
  ON marketing.tasks
  FOR EACH ROW
  EXECUTE FUNCTION marketing.compute_next_due();

ALTER TABLE marketing.tasks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tasks_authenticated_read" ON marketing.tasks
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "tasks_authenticated_update" ON marketing.tasks
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

-- Seed recurring jobs Derrick already runs (real cadence from cron + skills)
INSERT INTO marketing.tasks (title, description, owner, cadence, interval_count) VALUES
  ('LinkedIn daily posts (Scribe)', 'Generate + queue 1 LinkedIn post via Scribe', 'scribe', 'daily', 1),
  ('Spotify outreach weekly batch', 'Pull 25 fresh A&R contacts, draft via Prospector', 'prospector', 'weekly', 1),
  ('YouTube indie research', 'Scan 5 indie-perspective channels, summarize', 'researcher', 'weekly', 1),
  ('SendPilot inbox triage', 'Reply to unread conversations within 24h', 'derrick', 'daily', 1),
  ('Weekly metrics digest', 'Roll up SendPilot + Zernio weekly into digest doc', 'derrick', 'weekly', 1),
  ('Monthly revenue forecast', 'Recompute MRR from Supabase + Stripe', 'derrick', 'monthly', 1),
  ('Quarterly strategy review', 'Refresh LOUDmusic GTM strategy doc', 'derrick', 'quarterly', 1),
  ('Daily news sweep', 'Pull Music Business Worldwide + Indie feeds', 'researcher', 'daily', 1),
  ('Weekly A&R pipeline sync', 'Move leads in/out of active A&R campaigns', 'derrick', 'weekly', 1),
  ('Monthly content audit', 'Audit published posts; flag underperformers', 'scribe', 'monthly', 1);
