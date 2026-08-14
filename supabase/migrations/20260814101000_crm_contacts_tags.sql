-- Migration: 20260814101000_crm_contacts_tags.sql
-- crm_contacts had no tags column, so the tag_update sequence step and
-- add_tag/remove_tag automation actions (both real, user-facing options in
-- the admin UI) were silent no-ops. Adds the column the engine already
-- assumes exists.

ALTER TABLE marketing.crm_contacts ADD COLUMN IF NOT EXISTS tags text[] NOT NULL DEFAULT '{}';
CREATE INDEX IF NOT EXISTS idx_crm_contacts_tags ON marketing.crm_contacts USING gin(tags);
