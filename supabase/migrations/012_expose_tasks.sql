-- Migration: 012_expose_tasks.sql
-- Ensure marketing.tasks exists with seed data, expose via public.tasks view,
-- and grant anon/authenticated access for dashboard reads + Mark Done updates.
-- Run AFTER 007_create_marketing_tasks.sql (idempotent if 007 was skipped).

BEGIN;

-- ============================================================================
-- 1. Idempotent table + trigger (from 007)
-- ============================================================================

CREATE TABLE IF NOT EXISTS marketing.tasks (
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

CREATE INDEX IF NOT EXISTS idx_tasks_cadence  ON marketing.tasks (cadence);
CREATE INDEX IF NOT EXISTS idx_tasks_active   ON marketing.tasks (is_active);
CREATE INDEX IF NOT EXISTS idx_tasks_next_due ON marketing.tasks (next_due_at);

CREATE OR REPLACE FUNCTION marketing.compute_next_due()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.last_completed_at IS NULL THEN
    NEW.next_due_at := now();
  ELSE
    NEW.next_due_at := NEW.last_completed_at
      + (NEW.interval_count || CASE NEW.cadence
          WHEN 'daily'     THEN ' days'
          WHEN 'weekly'    THEN ' weeks'
          WHEN 'monthly'   THEN ' months'
          WHEN 'quarterly' THEN ' months'
        END)::interval;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tasks_next_due ON marketing.tasks;
CREATE TRIGGER trg_tasks_next_due
  BEFORE INSERT OR UPDATE OF last_completed_at
  ON marketing.tasks
  FOR EACH ROW
  EXECUTE FUNCTION marketing.compute_next_due();

ALTER TABLE marketing.tasks ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- 2. Seed recurring checklist (only when table is empty)
-- ============================================================================

INSERT INTO marketing.tasks (title, description, owner, cadence, interval_count)
SELECT v.title, v.description, v.owner, v.cadence, v.interval_count
FROM (VALUES
  ('LinkedIn daily posts (Scribe)', 'Generate + queue 1 LinkedIn post via Scribe', 'scribe', 'daily', 1),
  ('Spotify outreach weekly batch', 'Pull 25 fresh A&R contacts, draft via Prospector', 'prospector', 'weekly', 1),
  ('YouTube indie research', 'Scan 5 indie-perspective channels, summarize', 'researcher', 'weekly', 1),
  ('SendPilot inbox triage', 'Reply to unread conversations within 24h', 'derrick', 'daily', 1),
  ('Weekly metrics digest', 'Roll up SendPilot + Zernio weekly into digest doc', 'derrick', 'weekly', 1),
  ('Monthly revenue forecast', 'Recompute MRR from Supabase + Stripe', 'derrick', 'monthly', 1),
  ('Quarterly strategy review', 'Refresh LOUDmusic GTM strategy doc', 'derrick', 'quarterly', 1),
  ('Daily news sweep', 'Pull Music Business Worldwide + Indie feeds', 'researcher', 'daily', 1),
  ('Weekly A&R pipeline sync', 'Move leads in/out of active A&R campaigns', 'derrick', 'weekly', 1),
  ('Monthly content audit', 'Audit published posts; flag underperformers', 'scribe', 'monthly', 1)
) AS v(title, description, owner, cadence, interval_count)
WHERE NOT EXISTS (SELECT 1 FROM marketing.tasks LIMIT 1);

-- ============================================================================
-- 3. RLS — extend beyond authenticated-only (007)
-- ============================================================================

DROP POLICY IF EXISTS "tasks_authenticated_read" ON marketing.tasks;
DROP POLICY IF EXISTS "tasks_authenticated_update" ON marketing.tasks;
DROP POLICY IF EXISTS "tasks_anon_read" ON marketing.tasks;
DROP POLICY IF EXISTS "tasks_anon_update" ON marketing.tasks;

CREATE POLICY "tasks_authenticated_read" ON marketing.tasks
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "tasks_authenticated_update" ON marketing.tasks
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "tasks_anon_read" ON marketing.tasks
  FOR SELECT TO anon USING (true);
CREATE POLICY "tasks_anon_update" ON marketing.tasks
  FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- ============================================================================
-- 4. Public view + grants (PostgREST / supabase-js)
-- ============================================================================

-- Replace legacy public.tasks table (if any) with a view over marketing.tasks
DROP TABLE IF EXISTS public.tasks CASCADE;

CREATE OR REPLACE VIEW public.tasks AS
  SELECT * FROM marketing.tasks;

GRANT SELECT, UPDATE ON public.tasks TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
