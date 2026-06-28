#!/usr/bin/env python3
"""Push a single calendar event to Nextcloud CalDAV by event id."""
from __future__ import annotations

import sys

from supabase import create_client

from ._common import configure_logging, getenv_required
from .nextcloud_caldav import sync_event_row

log = configure_logging("push_calendar_event")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: push_calendar_event.py <event_id>", file=sys.stderr)
        return 2
    event_id = sys.argv[1]
    sb = create_client(getenv_required("SUPABASE_URL"), getenv_required("SUPABASE_SERVICE_ROLE_KEY"))
    row = sb.table("calendar_events").select("*").eq("id", event_id).limit(1).execute()
    if not row.data:
        print(f"event not found: {event_id}", file=sys.stderr)
        return 1
    event = row.data[0]
    event["_force"] = True
    settings_row = (
        sb.table("calendar_sync_settings")
        .select("*")
        .eq("account_id", event["account_id"])
        .limit(1)
        .execute()
    )
    settings = (settings_row.data or [{}])[0]
    sync_status, href, sync_error = sync_event_row(event, settings)
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc).isoformat()
    sb.table("calendar_events").update(
        {
            "sync_status": sync_status,
            "nextcloud_href": href,
            "sync_error": sync_error,
            "updated_at": now,
        }
    ).eq("id", event_id).execute()

    if settings:
        sb.table("calendar_sync_settings").update(
            {
                "last_sync_at": now,
                "last_error": sync_error if sync_status == "error" else None,
                "updated_at": now,
            }
        ).eq("account_id", event["account_id"]).execute()
    if sync_status == "error":
        print(sync_error or "push failed", file=sys.stderr)
        return 1
    print(f"OK: {sync_status} {href or ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
