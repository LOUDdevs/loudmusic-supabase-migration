-- Migration: 20260814100500_engine_scheduler.sql
-- Schedules the sequence/automation engine tick (loudmusic-v1/engine/tick)
-- every 5 minutes via pg_cron + pg_net, authenticated with a shared secret
-- generated server-side and stored only in Supabase Vault — the value never
-- appears in this file or anywhere in git history. After running this
-- migration, fetch it once via `SELECT decrypted_secret FROM
-- vault.decrypted_secrets WHERE name = 'engine_secret'` and set it as the
-- ENGINE_SECRET edge function secret so loudmusic-v1 can verify the header.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'engine_secret') THEN
    PERFORM vault.create_secret(encode(gen_random_bytes(32), 'hex'), 'engine_secret', 'Shared secret for pg_cron -> loudmusic-v1 engine tick calls');
  END IF;
END $$;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'loudmusic-engine-tick';

SELECT cron.schedule(
  'loudmusic-engine-tick',
  '*/5 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://hupiguhcsmeucownlbre.supabase.co/functions/v1/loudmusic-v1/engine/tick',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-engine-secret', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'engine_secret')
    ),
    body := '{}'::jsonb
  );
  $$
);
