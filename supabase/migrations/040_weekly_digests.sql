BEGIN;

CREATE TABLE marketing.weekly_digests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  week_start    date NOT NULL,
  file_path     text,
  summary_json  jsonb NOT NULL DEFAULT '{}'::jsonb,
  generated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_weekly_digests_week ON marketing.weekly_digests (week_start DESC);

CREATE OR REPLACE VIEW public.weekly_digests AS SELECT * FROM marketing.weekly_digests;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.weekly_digests TO anon, authenticated, service_role;

ALTER TABLE marketing.weekly_digests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "weekly_digests_read" ON marketing.weekly_digests FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "weekly_digests_write" ON marketing.weekly_digests FOR ALL TO anon USING (true) WITH CHECK (true);

NOTIFY pgrst, 'reload schema';

COMMIT;
