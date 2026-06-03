-- Artist Enrichment schema
-- Matches the existing supabase-migrate.js from artist-enrichment service

CREATE TABLE IF NOT EXISTS artist (
    id              BIGSERIAL PRIMARY KEY,
    spotify_id      VARCHAR(64) UNIQUE,
    chartmetric_id  VARCHAR(64) UNIQUE,
    name            VARCHAR(512),
    image_url       TEXT,
    genres          JSONB DEFAULT '[]',
    popularity      INTEGER,
    followers       BIGINT,
    social_urls     JSONB DEFAULT '{}',
    career_stage    VARCHAR(128),
    country         VARCHAR(8),
    bio             TEXT,
    web_url         TEXT,
    full_data       JSONB DEFAULT '{}',
    contact_data    JSONB DEFAULT '{}',
    enhanced_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_artist_enhanced_at ON artist (enhanced_at);
CREATE INDEX IF NOT EXISTS idx_artist_name ON artist (name);
CREATE INDEX IF NOT EXISTS idx_artist_spotify_id ON artist (spotify_id);
CREATE INDEX IF NOT EXISTS idx_artist_chartmetric_id ON artist (chartmetric_id);

-- Triggers for updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER artist_updated_at
    BEFORE UPDATE ON artist
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- RLS
ALTER TABLE artist ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Artists are publicly readable"
    ON artist FOR SELECT
    USING (true);

CREATE POLICY "Service role can upsert artists"
    ON artist FOR ALL
    USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');
