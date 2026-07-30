-- Harden Artist Bio Survey persistence and admin access.
-- Public intake is performed by the no-JWT Edge Function with service_role.
-- Browser admin access is authenticated Supabase Auth + app_metadata.admin=true.

ALTER TABLE public.artist_bio_survey_results
  ADD COLUMN IF NOT EXISTS generated_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS generation_attempt INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS raw_response JSONB;

CREATE INDEX IF NOT EXISTS artist_bio_surveys_created_at_idx
  ON public.artist_bio_surveys (created_at DESC);
CREATE INDEX IF NOT EXISTS artist_bio_surveys_artist_name_lower_idx
  ON public.artist_bio_surveys (lower(artist_name));
CREATE INDEX IF NOT EXISTS artist_bio_surveys_artist_email_lower_idx
  ON public.artist_bio_surveys (lower(artist_email));
CREATE INDEX IF NOT EXISTS artist_bio_survey_results_survey_id_created_at_idx
  ON public.artist_bio_survey_results (survey_id, created_at DESC);
CREATE INDEX IF NOT EXISTS artist_bio_survey_results_status_idx
  ON public.artist_bio_survey_results (bio_status, created_at DESC);

REVOKE ALL ON TABLE public.artist_bio_surveys FROM anon, authenticated;
REVOKE ALL ON TABLE public.artist_bio_survey_results FROM anon, authenticated;
GRANT SELECT ON TABLE public.artist_bio_surveys, public.artist_bio_survey_results TO authenticated;

DROP POLICY IF EXISTS "Admins can select artist_bio_surveys" ON public.artist_bio_surveys;
DROP POLICY IF EXISTS "Allow derrick to select artist_bio_surveys" ON public.artist_bio_surveys;
DROP POLICY IF EXISTS "Admins can select artist_bio_survey_results" ON public.artist_bio_survey_results;
DROP POLICY IF EXISTS "Allow derrick to select artist_bio_survey_results" ON public.artist_bio_survey_results;

CREATE POLICY "artist_bio_admin_select_surveys"
  ON public.artist_bio_surveys
  FOR SELECT TO authenticated
  USING ((auth.jwt() -> 'app_metadata' ->> 'admin') = 'true');

CREATE POLICY "artist_bio_admin_select_results"
  ON public.artist_bio_survey_results
  FOR SELECT TO authenticated
  USING ((auth.jwt() -> 'app_metadata' ->> 'admin') = 'true');

ALTER TABLE public.artist_bio_surveys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.artist_bio_survey_results ENABLE ROW LEVEL SECURITY;
