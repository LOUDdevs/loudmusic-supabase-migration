-- Audio Analysis job tracking
-- Original: FastAPI app on port 8012 with async audio processing

CREATE TABLE IF NOT EXISTS analysis_jobs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID,
    audio_id        VARCHAR(255),
    track_url       TEXT,
    spotify_url     TEXT,
    status          VARCHAR(32) DEFAULT 'pending', -- pending, processing, completed, failed
    mood            VARCHAR(128),
    tempo           NUMERIC(6, 2),
    key             VARCHAR(16),
    scale           VARCHAR(16),
    energy          NUMERIC(4, 3),
    danceability    NUMERIC(4, 3),
    acousticness    NUMERIC(4, 3),
    valence         NUMERIC(4, 3),
    instrumentalness NUMERIC(4, 3),
    confidence      NUMERIC(4, 3),
    tags            JSONB DEFAULT '[]',
    raw_results     JSONB DEFAULT '{}',
    error_message   TEXT,
    processed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_analysis_jobs_status ON analysis_jobs (status);
CREATE INDEX IF NOT EXISTS idx_analysis_jobs_audio_id ON analysis_jobs (audio_id);
CREATE INDEX IF NOT EXISTS idx_analysis_jobs_spotify_url ON analysis_jobs (spotify_url);

-- RLS
ALTER TABLE analysis_jobs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Jobs readable by owner"
    ON analysis_jobs FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Jobs insertable by authenticated"
    ON analysis_jobs FOR INSERT
    WITH CHECK (auth.role() = 'authenticated');
