# LOUDmusic APIs → Supabase Migration

## Setup

1. Sign up at [supabase.com](https://supabase.com) with `api@loudmusic.io`
2. Create a new project named `loudmusic-apis`
3. Go to Project Settings → API → copy:
   - `Project URL`
   - `anon public` key
   - `service_role` key (secret — keep safe)
4. Copy `.env.example` → `.env` and fill in the values
5. Run edge functions: `supabase functions deploy`

## API Registry + Smoke Tests

Canonical API record:

- [`docs/supabase-api-registry.md`](docs/supabase-api-registry.md)

Run live smoke tests:

```bash
python3 scripts/smoke_test_supabase_apis.py
```

The smoke-test script uses local environment credentials when present, otherwise it uses the linked Supabase project + Supabase CLI to retrieve anon/service credentials without printing secrets. It validates semantic responses: required fields, record counts, auth behavior, nearby distance filtering, create/read/delete flows, and cleanup.

## Edge Functions

| Function | Original Port | Status |
|----------|---------------|--------|
| `studio-directory` | 8020 | Deployed + semantic-tested; `/api/nearby` performs radius filtering and returns `distance_miles` |
| `audio-analysis` | 8012 | Deployed + semantic-tested; unauthenticated queueing is denied, authenticated/service queue/results flow works; worker wiring pending |
| `artist-enrichment` | 3010 | Deployed + semantic-tested; 77 artists imported; public reads work; write/enrich routes require auth/service role |

## Database Migrations

Run in Supabase SQL Editor:

1. `001_create_studios_table.sql` — Studio Directory
2. `002_create_analysis_jobs_table.sql` — Audio Analysis Jobs
3. `003_create_artist_table.sql` — Artist Enrichment

## Architecture Notes

- **studio-directory**: SQLite → PostgreSQL, full-text search via tsvector
- **audio-analysis**: Heavy processing (musicnn/essentia) stays on external worker; Edge Function queues jobs
- **artist-enrichment**: Chartmetric/Soundcharts API calls from Edge Functions; results upserted to `artist` table
