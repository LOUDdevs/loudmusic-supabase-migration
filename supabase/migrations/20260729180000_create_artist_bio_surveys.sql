-- Artist Bio Survey tables
-- Stores survey submissions and generated bios

-- Table for survey responses
CREATE TABLE IF NOT EXISTS artist_bio_surveys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    artist_name TEXT NOT NULL,
    pronouns TEXT NOT NULL,
    artist_email TEXT NOT NULL,
    q1_birthplace_birthdate TEXT NOT NULL,
    q2_love_for_music TEXT NOT NULL,
    q3_grow_up_listening TEXT NOT NULL,
    q4_influencers TEXT NOT NULL,
    q5_first_instrument_song TEXT NOT NULL,
    q6_formal_training TEXT NOT NULL,
    q7_mentors TEXT NOT NULL,
    q8_early_lesson TEXT NOT NULL,
    q9_education_influence TEXT NOT NULL,
    q10_school_activities TEXT NOT NULL,
    q11_pursue_music TEXT NOT NULL,
    q12_first_break TEXT NOT NULL,
    q13_challenges TEXT NOT NULL,
    q14_proudest_work TEXT NOT NULL,
    q15_awards_recognition TEXT NOT NULL,
    q16_style_genre TEXT NOT NULL,
    q17_inspirations TEXT NOT NULL,
    q18_creative_process TEXT NOT NULL,
    q19_themes_messages TEXT NOT NULL,
    q20_evolution TEXT NOT NULL,
    q21_balance TEXT NOT NULL,
    q22_causes TEXT NOT NULL,
    q23_fan_moment TEXT NOT NULL,
    q24_inspiration TEXT NOT NULL,
    q25_legacy TEXT NOT NULL,
    artist_phone TEXT,
    artist_social TEXT,
    current_city TEXT,
    ip_hash TEXT NOT NULL,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Table for generated bios and Q&A
CREATE TABLE IF NOT EXISTS artist_bio_survey_results (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    survey_id UUID REFERENCES artist_bio_surveys(id) ON DELETE CASCADE,
    bio TEXT,
    qa TEXT,
    model TEXT,
    provider TEXT,
    bio_status TEXT DEFAULT 'pending', -- 'generated', 'failed', 'pending'
    bio_error TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable Row Level Security
ALTER TABLE artist_bio_surveys ENABLE ROW LEVEL SECURITY;
ALTER TABLE artist_bio_survey_results ENABLE ROW LEVEL SECURITY;

-- Policy: Allow inserts via service_role (the Edge Function uses service_role key)
-- But we can also allow anon inserts via the Edge Function? Actually the Edge Function uses service_role key, so it bypasses RLS.
-- However, we want to restrict direct access: only service_role can insert/select? Actually we want:
-- - No one can select from these tables except authenticated admins (via service_role or specific role).
-- - The Edge Function uses service_role key, so it can insert and select.
-- We'll create a role for authenticated admins later via app_metadata.

-- For now, we'll set:
--   - No access for anon and authenticated users (by default).
--   - We'll grant usage to the service_role via the bypass (since service_role bypasses RLS).
-- Actually, service_role bypasses RLS entirely, so we don't need to grant it anything.

-- However, we want to allow authenticated admins (via Supabase Auth) to select.
-- We'll create a policy that allows select for users with admin role in app_metadata.

-- First, create a policy for artist_bio_surveys: select if user is admin.
CREATE POLICY "Admins can select artist_bio_surveys" ON artist_bio_surveys
    FOR SELECT
    USING (
        auth.role() = 'authenticated' AND
        (auth.uid() IS NOT NULL) AND
        (auth.jwt() ->> 'app_metadata'::text)::jsonb ? 'admin'
    );

-- Similarly for artist_bio_survey_results
CREATE POLICY "Admins can select artist_bio_survey_results" ON artist_bio_survey_results
    FOR SELECT
    USING (
        auth.role() = 'authenticated' AND
        (auth.uid() IS NOT NULL) AND
        (auth.jwt() ->> 'app_metadata'::text)::jsonb ? 'admin'
    );

-- Allow service_role to bypass RLS (it does by default, but we can explicitly grant all)
-- Actually, service_role bypasses RLS, so no need.

-- We also want to allow inserts via the Edge Function (service_role) which already bypasses RLS.
-- If we want to allow anon inserts via the Edge Function using anon key, we would need to allow that.
-- But the Edge Function uses service_role key, so it's fine.

-- However, note: the Edge Function uses supabase client with SERVICE_ROLE_KEY, which bypasses RLS.
-- So we don't need to grant any insert/select to anon or authenticated.

-- But we might want to allow the Edge Function to insert using the anon key? No, it uses service_role.
-- Let's double-check the Edge Function: it uses createClient(SUPABASE_URL, SERVICE_KEY, ...). So service_role.

-- Therefore, we only need to set up select policies for admins.

-- Insert trigger to update updated_at
CREATE TRIGGER update_artist_bio_surveys_updated_at
    BEFORE UPDATE ON artist_bio_surveys
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_artist_bio_survey_results_updated_at
    BEFORE UPDATE ON artist_bio_survey_results
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- We need the update_updated_at_column function if it doesn't exist.
-- Let's check if it exists; if not, create it.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'update_updated_at_column') THEN
        CREATE OR REPLACE FUNCTION update_updated_at_column()
        RETURNS TRIGGER AS $$
        BEGIN
            NEW.updated_at = NOW();
            RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
    END IF;
END
$$;

-- Grant usage on schema to authenticated? Not needed for RLS.
-- We'll leave it as is.
