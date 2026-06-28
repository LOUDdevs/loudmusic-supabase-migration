#!/usr/bin/env python3
"""Cancel/delete a calendar event from Nextcloud and update DB."""
from __future__ import annotations

import sys

from supabase import create_client

from ._common import configure_logging, getenv_required
from .nextcloud_caldav import delete_event, sync_event_row

log = configure_logging("cancel_calendar_event")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: cancel_calendar_event.py <event_id>", file=sys.stderr)
        return 2
    event_id = sys.argv[1]
    sb = create_client(getenv_required("SUPABASE_URL"), getenv_required("SUPABASE_SERVICE_ROLE_KEY"))
    row = sb.table("calendar_events").select("*").eq("id", event_id).limit(1).execute()
    if not row.data:
        print(f"event not found: {event_id}", file=sys.stderr)
        return 1
    event = row.data[0]
    href = event.get("nextcloud_href")
    if href:
        try:
            delete_event(href)
        except Exception as exc:
            log.warning("delete failed: %s", exc)
    sb.table("calendar_events").update(
        {
            "sync_status": "cancelled",
            "status": "cancelled",
            "lifecycle_status": "cancelled",
            "sync_error": None,
        }
    ).eq("id", event_id).execute()
    print("OK: cancelled")
    return 0


if __name__ == "__main__":
    sys.exit(main())
