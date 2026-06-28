BEGIN;

CREATE TYPE marketing.artist_scouting_status AS ENUM ('new', 'reviewing', 'added', 'passed');

CREATE TABLE marketing.artist_scouting_runs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_file     text,
  notes_path      text,
  candidate_count integer NOT NULL DEFAULT 0,
  ingested_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE marketing.artist_scouting_candidates (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id              uuid REFERENCES marketing.artist_scouting_runs (id) ON DELETE SET NULL,
  chartmetric_id      text NOT NULL,
  artist_name         text NOT NULL,
  fit_score           numeric,
  recommended_action  text,
  independence_class  text,
  genres              text,
  country             text,
  city                text,
  career_stage        text,
  spotify_url         text,
  instagram_url       text,
  tiktok_url          text,
  youtube_url         text,
  soundcloud_url      text,
  chartmetric_url     text,
  growth_30d_pct      numeric,
  spotify_monthly_listeners bigint,
  status              marketing.artist_scouting_status NOT NULL DEFAULT 'new',
  crm_artist_id       uuid REFERENCES marketing.crm_artists (id) ON DELETE SET NULL,
  raw_data            jsonb NOT NULL DEFAULT '{}'::jsonb,
  discovered_at       timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (chartmetric_id)
);

CREATE INDEX idx_artist_scouting_status ON marketing.artist_scouting_candidates (status, fit_score DESC NULLS LAST);
CREATE INDEX idx_artist_scouting_run ON marketing.artist_scouting_candidates (run_id);

CREATE OR REPLACE VIEW public.artist_scouting_runs AS SELECT * FROM marketing.artist_scouting_runs;
CREATE OR REPLACE VIEW public.artist_scouting_candidates AS SELECT * FROM marketing.artist_scouting_candidates;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.artist_scouting_runs TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.artist_scouting_candidates TO anon, authenticated, service_role;

ALTER TABLE marketing.artist_scouting_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing.artist_scouting_candidates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "artist_scouting_runs_read" ON marketing.artist_scouting_runs FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "artist_scouting_runs_write" ON marketing.artist_scouting_runs FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "artist_scouting_candidates_read" ON marketing.artist_scouting_candidates FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "artist_scouting_candidates_write" ON marketing.artist_scouting_candidates FOR ALL TO anon USING (true) WITH CHECK (true);

NOTIFY pgrst, 'reload schema';

COMMIT;
