#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

npx --yes esbuild supabase/functions/loudapp-api-v1/index.ts --bundle=false --format=esm --outfile=/tmp/loudapp-api-v1.js >/dev/null
npx --yes esbuild supabase/functions/loudapp-webhooks-v1/index.ts --bundle=false --format=esm --outfile=/tmp/loudapp-webhooks-v1.js >/dev/null
node --check deploy/cloudflare/loudapp-api-gateway.js

python3 - <<'PY'
from pathlib import Path
import re
import tomllib

migration = Path("supabase/migrations/20260814180001_create_loudapp_schema.sql").read_text()
checks = {
    "portable_uuid": "gen_random_uuid()" in migration and "uuid_generate_v4" not in migration,
    "all_loudapp_tables_rls": all(
        f"ALTER TABLE loudapp.{name} ENABLE ROW LEVEL SECURITY" in migration
        for name in (
            "workspaces", "workspace_members", "profiles", "settings",
            "playlist_submissions", "playlist_submission_events", "website_sites",
            "distribution_releases", "storage_files", "api_keys", "user_secrets",
            "oauth_states", "webhook_events", "idempotency_keys", "audit_log",
        )
    ),
    "secrets_not_readable_by_auth": not re.search(r"CREATE POLICY .* ON loudapp\\.user_secrets", migration),
    "hashed_api_keys": "key_digest text NOT NULL UNIQUE" in migration,
    "webhook_replay_key": "UNIQUE (provider, event_id)" in migration,
    "idempotency_key": "PRIMARY KEY (workspace_id, idempotency_key, route)" in migration,
}
for name, passed in checks.items():
    print(f"{name}={'PASS' if passed else 'FAIL'}")
if not all(checks.values()):
    raise SystemExit(1)
with Path("deploy/cloudflare/wrangler.toml.example").open("rb") as handle:
    tomllib.load(handle)
print("wrangler_toml=PASS")
PY

git diff --check -- supabase/config.toml supabase/functions/loudapp-api-v1 supabase/functions/loudapp-webhooks-v1 supabase/migrations/20260814180001_create_loudapp_schema.sql deploy/cloudflare docs/loudapp-api-platform.md docs/loudapp-api-v1.openapi.yaml scripts/validate_loudapp_api.sh
printf 'validate_loudapp_api=PASS\n'
