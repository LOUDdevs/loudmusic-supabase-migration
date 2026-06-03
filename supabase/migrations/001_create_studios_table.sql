-- Studio Directory schema (migrated from SQLite studios.db)
-- Maps the core fields from the original FastAPI app

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- For fuzzy text search

CREATE TABLE IF NOT EXISTS studios (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug            VARCHAR(255) UNIQUE NOT NULL,
    name            VARCHAR(512) NOT NULL,
    address         TEXT,
    city            VARCHAR(128),
    state           VARCHAR(64),
    zip             VARCHAR(20),
    phone           VARCHAR(50),
    email           VARCHAR(255),
    website         TEXT,
    description     TEXT,
    genres          JSONB DEFAULT '[]',
    moods           JSONB DEFAULT '[]',
    photos          JSONB DEFAULT '[]',
    lat             NUMERIC(10, 7),
    lng             NUMERIC(10, 7),
    google_place_id VARCHAR(255),
    rating          NUMERIC(3, 2),
    review_count    INTEGER DEFAULT 0,
    price_level     INTEGER,
    hours           JSONB DEFAULT '{}',
    amenities       JSONB DEFAULT '[]',
    equipment       JSONB DEFAULT '[]',
    social_urls     JSONB DEFAULT '{}',
    contact_data    JSONB DEFAULT '{}',
    enrichment_status VARCHAR(32) DEFAULT 'pending',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_studios_city ON studios (city);
CREATE INDEX IF NOT EXISTS idx_studios_state ON studios (state);
CREATE INDEX IF NOT EXISTS idx_studios_enrichment ON studios (enrichment_status);
CREATE INDEX IF NOT EXISTS idx_studios_name_trgm ON studios USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_studios_location ON studios (lat, lng);

-- Full-text search
ALTER TABLE studios ADD COLUMN IF NOT EXISTS search_vector tsvector
    GENERATED ALWAYS AS (
        setweight(to_tsvector('english', COALESCE(name, '')), 'A') ||
        setweight(to_tsvector('english', COALESCE(city, '')), 'B') ||
        setweight(to_tsvector('english', COALESCE(description, '')), 'C')
    ) STORED;

CREATE INDEX IF NOT EXISTS idx_studios_search ON studios USING gin (search_vector);

-- RLS policies
ALTER TABLE studios ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Studios are publicly readable"
    ON studios FOR SELECT
    USING (true);

CREATE POLICY "Only authenticated users can insert studios"
    ON studios FOR INSERT
    WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Only owners can update their studios"
    ON studios FOR UPDATE
    USING (auth.uid() = owner_id)
    WITH CHECK (auth.uid() = owner_id);
