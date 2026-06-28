-- Migration: 033_calendar_events_in_range_fix.sql
-- Recreate range RPC after 031 added columns (fixes SETOF row type mismatch).

BEGIN;

DROP FUNCTION IF EXISTS public.calendar_events_in_range(timestamptz, timestamptz, uuid);
DROP FUNCTION IF EXISTS marketing.calendar_events_in_range(timestamptz, timestamptz, uuid);

CREATE OR REPLACE VIEW public.calendar_events AS SELECT * FROM marketing.calendar_events;

CREATE FUNCTION marketing.calendar_events_in_range(
  p_start timestamptz,
  p_end timestamptz,
  p_account_id uuid DEFAULT NULL
)
RETURNS SETOF marketing.calendar_events
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT e.*
  FROM marketing.calendar_events e
  WHERE e.starts_at IS NOT NULL
    AND e.starts_at < p_end
    AND coalesce(e.ends_at, e.starts_at) >= p_start
    AND (p_account_id IS NULL OR e.account_id = p_account_id)
    AND e.deleted_at IS NULL
    AND e.lifecycle_status NOT IN ('cancelled')
    AND e.status <> 'cancelled'
  ORDER BY e.starts_at ASC;
$$;

CREATE FUNCTION public.calendar_events_in_range(
  p_start timestamptz,
  p_end timestamptz,
  p_account_id uuid DEFAULT NULL
)
RETURNS SETOF public.calendar_events
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = marketing, public
AS $$
  SELECT * FROM marketing.calendar_events_in_range(p_start, p_end, p_account_id);
$$;

GRANT EXECUTE ON FUNCTION public.calendar_events_in_range(timestamptz, timestamptz, uuid) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
