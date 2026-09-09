# LOUDapp API platform

This repository now contains the staged API foundation for the future web and Flutter clients.

## Runtime topology

```text
Flutter / web
  -> Cloudflare Worker: api.loudmusic.io
  -> Supabase Edge Function: loudapp-api-v1
  -> Postgres schema: loudapp (RLS enabled)
  -> Supabase Storage / provider workers
```

`loudapp-webhooks-v1` is separate from the user API. It accepts provider callbacks only after raw-body HMAC verification and persists a unique `(provider, event_id)` before asynchronous processing.

## Authentication

- Human users: `Authorization: Bearer <Supabase user JWT>`.
- Machine integrations: `Authorization: Bearer lm_test_*` or `lm_live_*`.
- User API keys are generated once, hashed with SHA-256, and never returned again.
- Supabase service-role credentials remain function secrets and are never shipped to clients.
- `x-user-id`, `x-admin-role`, and similar caller-controlled identity headers are not authorization.

## API routes

The first protected v1 slice is:

- `GET /v1/workspace`
- `GET/PATCH /v1/profile`
- `GET/PATCH /v1/settings/{section}`
- `GET/POST /v1/playlist/submissions`
- `GET/POST/DELETE /v1/api-keys[/{id}]`
- `GET/POST /v1/storage/files`
- `GET /health` and `GET /v1/health`

All successful responses include `{ success: true, data, request_id }`. All errors include `{ success: false, error: { code, message }, request_id }`. The contract is `docs/loudapp-api-v1.openapi.yaml`.

## Database boundary

The staged migration is `supabase/migrations/20260814180001_create_loudapp_schema.sql`.

It creates:

- Workspace and membership records
- User profiles and workspace settings
- Playlist submissions and status events
- Websites and distribution release records
- Storage metadata
- Hashed API keys
- Server-only provider secret and OAuth-state tables
- Webhook replay records
- Idempotency records and audit logs

The `loudapp` schema is exposed to the Supabase API role configuration for server-side use, but `user_secrets`, `oauth_states`, and `webhook_events` are explicitly restricted to `service_role`. RLS policies authorize user access through `auth.uid()` and workspace membership.

## Staging deployment

Do not use production credentials in a client or commit them to Git. Configure Supabase function secrets in the Supabase project secret manager:

```text
SUPABASE_SERVICE_ROLE_KEY
LOUDAPP_ALLOWED_ORIGINS=https://staging-app.example
LOUDAPP_WEBHOOK_SECRET_LATE=<provider secret>
LOUDAPP_WEBHOOK_SECRET_SOUNDRAW=<provider secret>
```

Deploy only after migration review and staging verification. The project reference must be supplied explicitly; do not rely on the repository's currently linked project:

```bash
export SUPABASE_STAGING_PROJECT_REF=REPLACE_WITH_STAGING_PROJECT_REF
supabase functions deploy loudapp-api-v1 --project-ref "$SUPABASE_STAGING_PROJECT_REF" --no-verify-jwt --use-api
supabase functions deploy loudapp-webhooks-v1 --project-ref "$SUPABASE_STAGING_PROJECT_REF" --no-verify-jwt --use-api
```

The `--no-verify-jwt` setting is intentional: the API supports both user JWTs and `lm_*` API keys, while the webhook function uses provider HMAC signatures. The functions perform their own authentication and authorization.

The Cloudflare Worker template is `deploy/cloudflare/loudapp-api-gateway.js`; copy and fill `deploy/cloudflare/wrangler.toml.example` per environment. Configure the Cloudflare rate-limit binding before production. The Worker must point to the exact staged function URL and allow only the app origins for that environment.

## Local checks

Deno is not installed on the current host, so local function execution requires the Supabase CLI/Deno toolchain or CI. The source is independently parsed with esbuild, and repository whitespace checks must pass before commit:

```bash
npx --yes esbuild supabase/functions/loudapp-api-v1/index.ts --bundle=false --format=esm --outfile=/tmp/loudapp-api-v1.js
npx --yes esbuild supabase/functions/loudapp-webhooks-v1/index.ts --bundle=false --format=esm --outfile=/tmp/loudapp-webhooks-v1.js
git diff --check
```

Before applying the migration, run it against an isolated Supabase branch or staging project, then verify:

1. Schema/table existence and grants.
2. RLS enabled on every `loudapp` table.
3. Authenticated user can only read their own workspace.
4. A second workspace cannot be read by the first user.
5. `user_secrets` is inaccessible to authenticated and anon roles.
6. API-key plaintext is returned only on creation.
7. Webhook signatures reject stale, invalid, and replayed events.
8. Storage signed upload URL and metadata record agree.

Production cutover is a separate approval step. Keep the existing Express `/api` compatibility server available until the client migration and rollback test pass.
