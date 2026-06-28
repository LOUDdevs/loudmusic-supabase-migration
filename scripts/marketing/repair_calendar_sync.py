#!/usr/bin/env python3
"""Batch repair: re-push pending/error calendar events to Nextcloud CalDAV."""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from typing import Any

from supabase import create_client

from ._common import configure_logging, getenv_required
from .nextcloud_caldav import is_nextcloud_configured, sync_event_row, test_connection
from .pull_calendar_sync import pull_calendar_events

log = configure_logging("repair_calendar_sync")


def main() -> int:
    parser = argparse.ArgumentParser(description="Repair calendar Nextcloud sync")
    parser.add_argument("--dry-run", action="store_true", help="Scan only, do not push")
    parser.add_argument("--limit", type=int, default=500, help="Max events to process")
    args = parser.parse_args()

    if not is_nextcloud_configured():
        print("Nextcloud credentials not configured", file=sys.stderr)
        return 2

    sb = create_client(getenv_required("SUPABASE_URL"), getenv_required("SUPABASE_SERVICE_ROLE_KEY"))

    settings_rows = sb.table("calendar_sync_settings").select("*").execute().data or []
    settings_by_account = {str(r["account_id"]): r for r in settings_rows}

    cal_name = None
    if settings_rows:
        cal_name = settings_rows[0].get("nextcloud_calendar_name")
    conn = test_connection(cal_name)
    if not conn.get("ok"):
        print(json.dumps({"ok": False, "error": conn.get("error"), "connection": conn}))
        return 2

    query = (
        sb.table("calendar_events")
        .select("*")
        .in_("sync_status", ["pending", "error"])
        .is_("deleted_at", "null")
        .neq("status", "cancelled")
        .order("updated_at", desc=False)
        .limit(args.limit)
    )
    rows = query.execute().data or []

    summary: dict[str, Any] = {
        "ok": True,
        "dry_run": args.dry_run,
        "scanned": 0,
        "synced": 0,
        "skipped": 0,
        "errors": 0,
        "sample_errors": [],
        "connection": {"resolved_slug": conn.get("resolved_slug")},
        "pull": None,
    }

    account_last_error: dict[str, str | None] = {}

    if not args.dry_run and settings_rows:
        primary = settings_rows[0]
        account_id = str(primary["account_id"])
        try:
            summary["pull"] = pull_calendar_events(sb, account_id, primary)
        except Exception as exc:
            summary["pull"] = {"ok": False, "error": str(exc)[:500]}

    summary["scanned"] = len(rows)

    for row in rows:
        event_id = str(row["id"])
        account_id = str(row["account_id"])
        settings = settings_by_account.get(account_id, {})
        if args.dry_run:
            summary["skipped"] += 1
            continue

        row["_force"] = True
        sync_status, href, sync_error = sync_event_row(row, settings)
        update = {
            "sync_status": sync_status,
            "nextcloud_href": href,
            "sync_error": sync_error,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        sb.table("calendar_events").update(update).eq("id", event_id).execute()

        if sync_status == "synced":
            summary["synced"] += 1
            account_last_error[account_id] = None
        elif sync_status == "skipped":
            summary["skipped"] += 1
        else:
            summary["errors"] += 1
            account_last_error[account_id] = sync_error
            if len(summary["sample_errors"]) < 5 and sync_error:
                summary["sample_errors"].append({"event_id": event_id, "error": sync_error})

    now = datetime.now(timezone.utc).isoformat()
    for account_id, last_err in account_last_error.items():
        sb.table("calendar_sync_settings").update(
            {
                "last_sync_at": now,
                "last_error": last_err,
                "updated_at": now,
            }
        ).eq("account_id", account_id).execute()

    if summary["errors"] > 0:
        summary["ok"] = False

    print(json.dumps(summary))
    if summary["errors"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
