-- LOUDapp API foundation
-- Staged migration only. Apply through the approved Supabase migration workflow after review.
-- All user authorization is based on auth.uid() and workspace membership.

CREATE SCHEMA IF NOT EXISTS loudapp;

CREATE OR REPLACE FUNCTION loudapp.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = loudapp, pg_catalog
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS loudapp.workspaces (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,63}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS loudapp.workspace_members (
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, user_id)
);

CREATE TABLE IF NOT EXISTS loudapp.profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text CHECK (display_name IS NULL OR length(display_name) <= 160),
  avatar_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS loudapp.settings (
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  section text NOT NULL CHECK (section ~ '^[a-z][a-z0-9-]{0,63}$'),
  value jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, section)
);

CREATE TABLE IF NOT EXISTS loudapp.playlist_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  submitted_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  track_url text NOT NULL CHECK (length(trim(track_url)) BETWEEN 1 AND 2048),
  track_title text NOT NULL DEFAULT '' CHECK (length(track_title) <= 500),
  playlist_ids jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(playlist_ids) = 'array'),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS loudapp.playlist_submission_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id uuid NOT NULL REFERENCES loudapp.playlist_submissions(id) ON DELETE CASCADE,
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  from_status text,
  to_status text NOT NULL CHECK (to_status IN ('pending', 'approved', 'rejected')),
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS loudapp.website_sites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  site_name text NOT NULL CHECK (site_name ~ '^[A-Za-z0-9-]{2,64}$'),
  template_slug text,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'archived')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS loudapp.distribution_releases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'submitted', 'approved', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS loudapp.storage_files (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  uploaded_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  bucket text NOT NULL CHECK (bucket ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  storage_path text NOT NULL CHECK (length(storage_path) BETWEEN 1 AND 1024),
  original_name text NOT NULL CHECK (length(original_name) BETWEEN 1 AND 512),
  mime_type text,
  byte_size bigint CHECK (byte_size IS NULL OR byte_size >= 0),
  scope text NOT NULL DEFAULT 'private' CHECK (scope IN ('private', 'shared')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (bucket, storage_path)
);

CREATE TABLE IF NOT EXISTS loudapp.api_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  environment text NOT NULL DEFAULT 'live' CHECK (environment IN ('test', 'live')),
  key_prefix text NOT NULL CHECK (length(key_prefix) BETWEEN 8 AND 32),
  key_digest text NOT NULL UNIQUE,
  scopes text[] NOT NULL DEFAULT ARRAY[]::text[],
  expires_at timestamptz,
  last_used_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS loudapp.user_secrets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  provider text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_-]{1,63}$'),
  encrypted_payload text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, provider)
);

CREATE TABLE IF NOT EXISTS loudapp.oauth_states (
  state_digest text PRIMARY KEY,
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider text NOT NULL,
  return_to text NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS loudapp.webhook_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_-]{1,63}$'),
  event_id text NOT NULL CHECK (length(event_id) BETWEEN 1 AND 255),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'received' CHECK (status IN ('received', 'processed', 'failed')),
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  UNIQUE (provider, event_id)
);

CREATE TABLE IF NOT EXISTS loudapp.idempotency_keys (
  workspace_id uuid NOT NULL REFERENCES loudapp.workspaces(id) ON DELETE CASCADE,
  idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 200),
  route text NOT NULL CHECK (length(route) BETWEEN 1 AND 200),
  response_status integer,
  response_body jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, idempotency_key, route)
);

CREATE TABLE IF NOT EXISTS loudapp.audit_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id uuid REFERENCES loudapp.workspaces(id) ON DELETE SET NULL,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  action text NOT NULL CHECK (length(action) BETWEEN 1 AND 120),
  resource text NOT NULL CHECK (length(resource) BETWEEN 1 AND 160),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION loudapp.is_workspace_admin(target_workspace_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = loudapp, pg_catalog
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM loudapp.workspace_members m
    WHERE m.workspace_id = target_workspace_id
      AND m.user_id = (SELECT auth.uid())
      AND m.role IN ('owner', 'admin')
  );
$$;

DROP TRIGGER IF EXISTS workspaces_touch_updated_at ON loudapp.workspaces;
CREATE TRIGGER workspaces_touch_updated_at BEFORE UPDATE ON loudapp.workspaces FOR EACH ROW EXECUTE FUNCTION loudapp.touch_updated_at();
DROP TRIGGER IF EXISTS workspace_members_touch_updated_at ON loudapp.workspace_members;
CREATE TRIGGER workspace_members_touch_updated_at BEFORE UPDATE ON loudapp.workspace_members FOR EACH ROW EXECUTE FUNCTION loudapp.touch_updated_at();
DROP TRIGGER IF EXISTS profiles_touch_updated_at ON loudapp.profiles;
CREATE TRIGGER profiles_touch_updated_at BEFORE UPDATE ON loudapp.profiles FOR EACH ROW EXECUTE FUNCTION loudapp.touch_updated_at();
DROP TRIGGER IF EXISTS settings_touch_updated_at ON loudapp.settings;
CREATE TRIGGER settings_touch_updated_at BEFORE UPDATE ON loudapp.settings FOR EACH ROW EXECUTE FUNCTION loudapp.touch_updated_at();
DROP TRIGGER IF EXISTS playlist_submissions_touch_updated_at ON loudapp.playlist_submissions;
CREATE TRIGGER playlist_submissions_touch_updated_at BEFORE UPDATE ON loudapp.playlist_submissions FOR EACH ROW EXECUTE FUNCTION loudapp.touch_updated_at();
DROP TRIGGER IF EXISTS website_sites_touch_updated_at ON loudapp.website_sites;
CREATE TRIGGER website_sites_touch_updated_at BEFORE UPDATE ON loudapp.website_sites FOR EACH ROW EXECUTE FUNCTION loudapp.touch_updated_at();
DROP TRIGGER IF EXISTS distribution_releases_touch_updated_at ON loudapp.distribution_releases;
CREATE TRIGGER distribution_releases_touch_updated_at BEFORE UPDATE ON loudapp.distribution_releases FOR EACH ROW EXECUTE FUNCTION loudapp.touch_updated_at();
DROP TRIGGER IF EXISTS storage_files_touch_updated_at ON loudapp.storage_files;
CREATE TRIGGER storage_files_touch_updated_at BEFORE UPDATE ON loudapp.storage_files FOR EACH ROW EXECUTE FUNCTION loudapp.touch_updated_at();
DROP TRIGGER IF EXISTS user_secrets_touch_updated_at ON loudapp.user_secrets;
CREATE TRIGGER user_secrets_touch_updated_at BEFORE UPDATE ON loudapp.user_secrets FOR EACH ROW EXECUTE FUNCTION loudapp.touch_updated_at();

CREATE INDEX IF NOT EXISTS idx_loudapp_members_user ON loudapp.workspace_members(user_id, workspace_id);
CREATE INDEX IF NOT EXISTS idx_loudapp_settings_workspace ON loudapp.settings(workspace_id, section);
CREATE INDEX IF NOT EXISTS idx_loudapp_playlist_workspace_created ON loudapp.playlist_submissions(workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loudapp_playlist_workspace_status ON loudapp.playlist_submissions(workspace_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loudapp_playlist_events_submission ON loudapp.playlist_submission_events(submission_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loudapp_sites_workspace ON loudapp.website_sites(workspace_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loudapp_releases_workspace ON loudapp.distribution_releases(workspace_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loudapp_storage_workspace ON loudapp.storage_files(workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loudapp_keys_workspace ON loudapp.api_keys(workspace_id, revoked_at, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_loudapp_oauth_expiry ON loudapp.oauth_states(expires_at);
CREATE INDEX IF NOT EXISTS idx_loudapp_webhooks_received ON loudapp.webhook_events(received_at DESC);
CREATE INDEX IF NOT EXISTS idx_loudapp_idempotency_created ON loudapp.idempotency_keys(created_at);
CREATE INDEX IF NOT EXISTS idx_loudapp_audit_workspace_created ON loudapp.audit_log(workspace_id, created_at DESC);

-- The schema is used by the server-side API function. It is not exposed to anon clients.
GRANT USAGE ON SCHEMA loudapp TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA loudapp TO authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA loudapp TO authenticated, service_role;
REVOKE ALL ON loudapp.user_secrets FROM authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON loudapp.user_secrets TO service_role;
REVOKE ALL ON loudapp.oauth_states FROM authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON loudapp.oauth_states TO service_role;
REVOKE ALL ON loudapp.webhook_events FROM authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON loudapp.webhook_events TO service_role;
REVOKE ALL ON loudapp.idempotency_keys FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON loudapp.idempotency_keys TO authenticated, service_role;
REVOKE ALL ON loudapp.audit_log FROM anon;
GRANT EXECUTE ON FUNCTION loudapp.is_workspace_admin(uuid) TO authenticated, service_role;

ALTER TABLE loudapp.workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.workspace_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.playlist_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.playlist_submission_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.website_sites ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.distribution_releases ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.storage_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.api_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.user_secrets ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.oauth_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE loudapp.audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY workspaces_member_select ON loudapp.workspaces FOR SELECT TO authenticated
  USING (owner_id = (SELECT auth.uid()) OR EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = id AND m.user_id = (SELECT auth.uid())));
CREATE POLICY workspaces_owner_insert ON loudapp.workspaces FOR INSERT TO authenticated
  WITH CHECK (owner_id = (SELECT auth.uid()));
CREATE POLICY workspaces_owner_update ON loudapp.workspaces FOR UPDATE TO authenticated
  USING (owner_id = (SELECT auth.uid())) WITH CHECK (owner_id = (SELECT auth.uid()));
CREATE POLICY workspaces_owner_delete ON loudapp.workspaces FOR DELETE TO authenticated
  USING (owner_id = (SELECT auth.uid()));

CREATE POLICY workspace_members_self_or_admin_select ON loudapp.workspace_members FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()) OR loudapp.is_workspace_admin(workspace_id));
CREATE POLICY workspace_members_owner_insert ON loudapp.workspace_members FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM loudapp.workspaces w WHERE w.id = workspace_id AND w.owner_id = (SELECT auth.uid())));
CREATE POLICY workspace_members_admin_update ON loudapp.workspace_members FOR UPDATE TO authenticated
  USING (loudapp.is_workspace_admin(workspace_id))
  WITH CHECK (loudapp.is_workspace_admin(workspace_id));
CREATE POLICY workspace_members_owner_delete ON loudapp.workspace_members FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspaces w WHERE w.id = workspace_id AND w.owner_id = (SELECT auth.uid())));

CREATE POLICY profiles_self_select ON loudapp.profiles FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY profiles_self_insert ON loudapp.profiles FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY profiles_self_update ON loudapp.profiles FOR UPDATE TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY settings_member_select ON loudapp.settings FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));
CREATE POLICY settings_member_insert ON loudapp.settings FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));
CREATE POLICY settings_member_update ON loudapp.settings FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())))
  WITH CHECK (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));
CREATE POLICY settings_member_delete ON loudapp.settings FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));

CREATE POLICY playlist_member_select ON loudapp.playlist_submissions FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));
CREATE POLICY playlist_member_insert ON loudapp.playlist_submissions FOR INSERT TO authenticated
  WITH CHECK (submitted_by = (SELECT auth.uid()) AND EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));
CREATE POLICY playlist_admin_update ON loudapp.playlist_submissions FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid()) AND m.role IN ('owner', 'admin')))
  WITH CHECK (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid()) AND m.role IN ('owner', 'admin')));

CREATE POLICY playlist_events_member_select ON loudapp.playlist_submission_events FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));
CREATE POLICY playlist_events_member_insert ON loudapp.playlist_submission_events FOR INSERT TO authenticated
  WITH CHECK (actor_id = (SELECT auth.uid()) AND EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));

CREATE POLICY sites_member_all ON loudapp.website_sites FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())))
  WITH CHECK (created_by = (SELECT auth.uid()) AND EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));
CREATE POLICY releases_member_all ON loudapp.distribution_releases FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())))
  WITH CHECK (created_by = (SELECT auth.uid()) AND EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));
CREATE POLICY storage_member_all ON loudapp.storage_files FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())))
  WITH CHECK (uploaded_by = (SELECT auth.uid()) AND EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));
CREATE POLICY api_keys_member_all ON loudapp.api_keys FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid()) AND m.role IN ('owner', 'admin')))
  WITH CHECK (created_by = (SELECT auth.uid()) AND EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid()) AND m.role IN ('owner', 'admin')));

CREATE POLICY idempotency_member_all ON loudapp.idempotency_keys FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())))
  WITH CHECK (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));

CREATE POLICY audit_member_select ON loudapp.audit_log FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM loudapp.workspace_members m WHERE m.workspace_id = workspace_id AND m.user_id = (SELECT auth.uid())));

COMMENT ON SCHEMA loudapp IS 'LOUDapp user/workspace API data. Server-side API boundary with workspace authorization.';
COMMENT ON TABLE loudapp.user_secrets IS 'Server-only encrypted provider tokens. No anon or authenticated table access.';
COMMENT ON TABLE loudapp.api_keys IS 'Only key digests are stored. Plaintext keys are returned once at generation.';
