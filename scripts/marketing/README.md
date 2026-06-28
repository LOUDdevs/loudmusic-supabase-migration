# Marketing Ingestion Scripts

Two Python scripts that pull data from SendPilot and Zernio into the Supabase `marketing` schema.

## Files

- `ingest_sendpilot.py` — pulls conversations, messages, campaigns, and leads
- `ingest_zernio.py` — pulls posts and account metadata (engagement metrics are a paid Zernio add-on; out of scope for v1)
- `_common.py` — shared env loading, logging, telemetry, daily-metrics rollups
- `requirements.txt` — pinned dependency versions

## Setup

```bash
# 1. Install dependencies
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 2. Add env vars to ~/.hermes/.env (auto-loaded at import time)
echo 'SUPABASE_URL=https://hupiguhcsmeucownlbre.supabase.co' >> ~/.hermes/.env
echo 'SUPABASE_SERVICE_ROLE_KEY=***' >> ~/.hermes/.env
# SENDPILOT_API_KEY is already in ~/.hermes/.env

# 3. Apply schema migrations 004 and 005 via the Supabase dashboard SQL editor
#    https://supabase.com/dashboard/project/hupiguhcsmeucownlbre/sql
```

## Running

```bash
# SendPilot: incremental (uses max(last_activity_at) from DB)
python -m scripts.marketing.ingest_sendpilot

# SendPilot: 3-month backfill
python -m scripts.marketing.ingest_sendpilot --backfill

# SendPilot: explicit cutoff
python -m scripts.marketing.ingest_sendpilot --since 2026-06-01

# SendPilot: skip lead ingestion (faster)
python -m scripts.marketing.ingest_sendpilot --skip-leads

# SendPilot: smoke test, 5 conversations only
python -m scripts.marketing.ingest_sendpilot --limit-conversations 5

# Zernio: incremental
python -m scripts.marketing.ingest_zernio

# Zernio: also pull DM inbox
python -m scripts.marketing.ingest_zernio --include-inbox
```

## Tests

```bash
cd /home/derrick/loudmusic-supabase
python -m pytest tests/marketing/ -v
```

## Cron (after Phase 4.1 wiring)

```bash
# Every 6 hours, staggered so they don't collide
0 */6 * * *  cd /home/derrick/loudmusic-supabase && /home/derrick/loudmusic-supabase/.venv/bin/python -m scripts.marketing.ingest_sendpilot --skip-leads >> /var/log/marketing-sendpilot.log 2>&1
15 */6 * * * cd /home/derrick/loudmusic-supabase && /home/derrick/loudmusic-supabase/.venv/bin/python -m scripts.marketing.ingest_zernio >> /var/log/marketing-zernio.log 2>&1
```

The `--skip-leads` flag on the 6h cadence is intentional: lead sets are big (1k+ per campaign) and rarely change materially between refreshes. A daily 4 AM lead pull covers the rest:

```bash
0 4 * * * cd /home/derrick/loudmusic-supabase && /home/derrick/loudmusic-supabase/.venv/bin/python -m scripts.marketing.ingest_sendpilot --skip-leads=false >> /var/log/marketing-sendpilot-leads.log 2>&1
```

## Exit codes

Both scripts use a shared exit-code vocabulary:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Unexpected exception |
| 2 | Required env var missing |
| 3 | `marketing` schema or required table missing (apply migrations) |
| 4 | SendPilot / Zernio auth failed (4xx 401/403) |
| 5 | SendPilot throttled beyond the max consecutive 429 limit |
| 6 | SendPilot API error (4xx other than 429, or 5xx after retries) |
| 7 | Zernio CLI error |

## Free-tier guardrails

These scripts respect Supabase free-tier limits by design:

- **Idempotency:** every upsert uses `ON CONFLICT (external_id) DO UPDATE / DO NOTHING`, so repeated runs don't double-write.
- **Retention:** migration 005 has a `marketing.schema_size_estimate_mb()` helper; the cron logs the size weekly. If > 400 MB, archive to `marketing_archive_*` (out of scope for v1).
- **Cadence:** 6 hours. Don't go below 4 hours — egress at 15-minute cadence would burn the 2 GB/mo free tier in days.
- **No realtime subscriptions, no SELECT *.**

## Zernio analytics (open question)

If engagement metrics become a priority (impressions, reactions, comments per post, follower growth), upgrade Zernio to the analytics add-on. After upgrade, expand `ingest_zernio.py` to also call `zernio analytics:posts --from YYYY-MM-DD` and upsert into a new `marketing.zernio_post_metrics` table.
