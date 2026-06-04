# LOUDmusic Supabase API Registry

Last verified: 2026-06-04T01:10:53Z

## Project

- Project name: Hermes / LOUDmusic APIs
- Project ref: `hupiguhcsmeucownlbre`
- Base URL: `https://hupiguhcsmeucownlbre.supabase.co`
- Supabase CLI version verified: `2.104.0`
- Repo: `LOUDdevs/loudmusic-supabase-migration`

## Key rule for future work

Do not assume a database table is API-callable just because it exists. Supabase changed defaults in 2026: newly-created tables may not be automatically exposed to Data/GraphQL APIs. For each table/API, verify all of the following:

1. The schema is exposed by Supabase Data API settings.
2. The target role has table grants (`anon`, `authenticated`, or `service_role`).
3. RLS is enabled for exposed tables.
4. RLS policies match the intended public/internal access model.
5. A live smoke test returns the expected status/body.

## Authentication modes

- Public/browser clients: use publishable or legacy anon key only.
- Authenticated users: use user JWT from Supabase Auth.
- Internal agents/server-side jobs: use service role key only from secure server/agent environments.
- Never commit or paste service role/secret keys into docs, frontend code, Telegram, GitHub issues, or logs.

## Data API / REST endpoints

All REST endpoints use this base:

```text
https://hupiguhcsmeucownlbre.supabase.co/rest/v1/<table>
```

Required headers:

```http
apikey: <anon-or-service-key>
Authorization: Bearer <same-key-or-user-jwt>
```

### `public.studios`

- REST endpoint: `/rest/v1/studios`
- Current row count at verification: `16,219`
- RLS: enabled
- Current public policy: `Studios are publicly readable` (`SELECT USING true`)
- Write policies: authenticated insert/update only
- Current smoke status: `200 OK` with `limit=1`
- Primary use: studio directory/search/location data
- Important columns:
  - `id`, `slug`, `name`
  - `address`, `city`, `state`, `zip`, `lat`, `lng`
  - `phone`, `email`, `website`
  - `genres`, `moods`, `amenities`, `equipment`, `photos`, `social_urls`, `contact_data`
  - `enrichment_status`, `search_vector`

Example:

```bash
curl "$SUPABASE_URL/rest/v1/studios?select=id,slug,name,city,state&limit=5" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY"
```

### `public.artist`

- REST endpoint: `/rest/v1/artist`
- Current row count at verification: `0`
- RLS: enabled
- Current public policy: `Artists are publicly readable` (`SELECT USING true`)
- Service policy: service role can upsert artists
- Current smoke status: `200 OK`, empty list
- Primary use: enriched artist records from artist-enrichment pipeline
- Important status note: the artist-enrichment Postgres dump was extracted from server `37172`, but the extracted rows are not live in Supabase yet.
- Local extraction path:
  - `/home/derrick/artist-enrichment-exports/artist_enrichment_export_20260604T002636Z/artists.dump`
- Important columns:
  - `id`, `spotify_id`, `chartmetric_id`, `name`
  - `image_url`, `genres`, `popularity`, `followers`
  - `social_urls`, `career_stage`, `country`, `bio`, `web_url`
  - `full_data`, `contact_data`, `enhanced_at`

Example:

```bash
curl "$SUPABASE_URL/rest/v1/artist?select=id,spotify_id,name&limit=5" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY"
```

### `public.analysis_jobs`

- REST endpoint: `/rest/v1/analysis_jobs`
- Current row count at verification: `0`
- RLS: enabled
- Current policies:
  - `Jobs readable by owner` (`SELECT USING auth.uid() = user_id`)
  - `Jobs insertable by authenticated`
- Current smoke status with anon key: `200 OK`, empty list
- Primary use: queue/status table for audio analysis jobs
- Important columns:
  - `id`, `user_id`, `audio_id`, `track_url`, `spotify_url`
  - `status`, `mood`, `tempo`, `key`, `scale`
  - `energy`, `danceability`, `acousticness`, `valence`, `instrumentalness`, `confidence`
  - `tags`, `raw_results`, `error_message`, `processed_at`

Example:

```bash
curl "$SUPABASE_URL/rest/v1/analysis_jobs?select=id,status&limit=5" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY"
```

## Edge Function APIs

All Edge Function endpoints use this base:

```text
https://hupiguhcsmeucownlbre.supabase.co/functions/v1/<function-slug>
```

Required headers for current smoke tests:

```http
apikey: <anon-key>
Authorization: Bearer <anon-key-or-user-jwt>
```

### `studio-directory`

- Function URL: `/functions/v1/studio-directory`
- Status: deployed and smoke-tested
- Current deployment status: ACTIVE
- Current smoke status: `200 OK` for `/api/studios`
- Routes:
  - `GET /api/studios` — list studios, currently capped at 100 in function
  - `GET /api/studio/{slug}` — single studio by slug
  - `GET /api/search?q=<query>` — name search
  - `GET /api/nearby?lat=<lat>&lng=<lng>&radius=<radius>` — placeholder; currently returns capped studio list, not true geospatial search yet

Example:

```bash
curl "$SUPABASE_URL/functions/v1/studio-directory/api/studios" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY"
```

### `audio-analysis`

- Function URL: `/functions/v1/audio-analysis`
- Status: deployed and smoke-tested
- Current deployment status: ACTIVE
- Current smoke status: `200 OK` for `/health`
- Routes:
  - `GET /health` — health check; returns `{ "status": "ok", "version": "0.2.0" }`
  - `POST /api/analyze` — creates a pending analysis job; heavy processing still needs external worker wiring
  - `POST /api/analyze/spotify` — placeholder; returns `not_implemented`
  - `GET /api/results?job_id=<uuid>` — fetch one analysis job

Example:

```bash
curl "$SUPABASE_URL/functions/v1/audio-analysis/health" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY"
```

### `artist-enrichment`

- Function URL: `/functions/v1/artist-enrichment`
- Status: deployed and smoke-tested
- Current deployment status: ACTIVE
- Current smoke status: `200 OK` for `/api/artists`, empty list because table has 0 rows
- Routes:
  - `GET /api/artists` — list artists, currently capped at 100
  - `GET /api/artists/search?q=<query>` — search artists by name
  - `POST /api/artists/enrich` — placeholder; returns queued response, external APIs not wired yet
  - `POST /api/artists` — direct service-role upsert from enrichment pipeline

Example:

```bash
curl "$SUPABASE_URL/functions/v1/artist-enrichment/api/artists" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY"
```

## Verification commands

Use the committed script:

```bash
cd /home/derrick/loudmusic-supabase
python3 scripts/smoke_test_supabase_apis.py
```

The script fetches anon credentials via Supabase CLI when available and does not print secrets.

## Current smoke-test summary

- REST `/studios`: `200 OK`, list returned
- REST `/artist`: `200 OK`, empty list
- REST `/analysis_jobs`: `200 OK`, empty list
- Edge `audio-analysis /health`: `200 OK`
- Edge `studio-directory /api/studios`: `200 OK`, list returned
- Edge `artist-enrichment /api/artists`: `200 OK`, empty list

## Known gaps / next hardening steps

1. Import artist extraction into `public.artist` if we want artist API data live in Supabase.
2. Replace broad table grants with least-privilege grants before public launch.
3. Replace deprecated `auth.role()` policy checks with explicit `TO authenticated` / `TO service_role` policies in a reviewed migration.
4. Add pagination parameters to Edge Function list routes before exposing to production clients.
5. Wire `audio-analysis` to the external audio worker or Supabase queue before treating analysis as fully functional.
6. Wire `artist-enrichment` to Chartmetric/Soundcharts/Spotify before treating enrichment as fully functional.
7. Consider public-safe views for `studios` and `artist` so private/contact-heavy columns are not exposed directly through public REST endpoints.
