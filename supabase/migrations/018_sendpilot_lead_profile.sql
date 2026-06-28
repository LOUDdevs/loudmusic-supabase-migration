-- Migration: 018_sendpilot_lead_profile.sql
-- Full SendPilot lead profile columns for bio, location, followers, etc.

BEGIN;

ALTER TABLE marketing.sendpilot_leads
  ADD COLUMN IF NOT EXISTS about text,
  ADD COLUMN IF NOT EXISTS location text,
  ADD COLUMN IF NOT EXISTS industry text,
  ADD COLUMN IF NOT EXISTS website_url text,
  ADD COLUMN IF NOT EXISTS profile_picture_url text,
  ADD COLUMN IF NOT EXISTS follower_count integer,
  ADD COLUMN IF NOT EXISTS connection_count integer,
  ADD COLUMN IF NOT EXISTS is_premium boolean,
  ADD COLUMN IF NOT EXISTS is_open_profile boolean,
  ADD COLUMN IF NOT EXISTS custom_lead_status text,
  ADD COLUMN IF NOT EXISTS linkedin_headline text,
  ADD COLUMN IF NOT EXISTS raw_profile jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE marketing.crm_contact_profiles
  ADD COLUMN IF NOT EXISTS industry text;

NOTIFY pgrst, 'reload schema';

COMMIT;
