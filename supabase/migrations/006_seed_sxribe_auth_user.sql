-- Migration: 006_seed_sxribe_auth_user.sql
-- Seeds the first user 'sxribe' in auth.users with super_admin role.
-- Idempotent: skips if user already exists.
--
-- Apply via: mcp_supabase_apply_migration name='seed_sxribe_auth_user'
-- Verify:  SELECT id, email FROM auth.users WHERE email='sxribe@loudmusic.io';
--          SELECT * FROM marketing.team_members WHERE email='sxribe@loudmusic.io';

DO $$
DECLARE
  v_user_id uuid;
  v_email   text := 'sxribe@loudmusic.io';
BEGIN
  -- Skip if user already exists
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = v_email) THEN
    RAISE NOTICE 'User % already exists, skipping seed.', v_email;
    RETURN;
  END IF;

  -- Insert auth.users row
  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    email_change,
    email_change_token_new,
    recovery_token
  )
  VALUES (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    v_email,
    crypt('Blazers23764!', gen_salt('bf')),
    now(),
    jsonb_build_object('display_name', 'sxribe'),
    now(),
    now(),
    '',
    '',
    '',
    ''
  )
  RETURNING id INTO v_user_id;

  -- Insert corresponding auth.identities row
  INSERT INTO auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    provider_id,
    last_sign_in_at,
    created_at,
    updated_at
  )
  VALUES (
    gen_random_uuid(),
    v_user_id,
    jsonb_build_object('sub', v_user_id::text, 'email', v_email, 'email_verified', true),
    'email',
    v_email,
    now(),
    now(),
    now()
  );

  -- Insert marketing.team_members as super_admin
  INSERT INTO marketing.team_members (user_id, email, role, invited_at, joined_at)
  VALUES (v_user_id, v_email, 'super_admin'::marketing.team_role, now(), now())
  ON CONFLICT (user_id) DO NOTHING;

  RAISE NOTICE 'Seeded user % with id % as super_admin.', v_email, v_user_id;
END $$;