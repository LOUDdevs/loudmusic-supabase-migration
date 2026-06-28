#!/usr/bin/env python3
"""Pull calendar events from Nextcloud CalDAV into Supabase."""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from supabase import create_client

from ._common import configure_logging, getenv_required
from .calendar_ics import should_upsert
from .nextcloud_caldav import (
    RemoteCalendarEvent,
    default_pull_window,
    is_nextcloud_configured,
    query_calendar_events,
    resolve_calendar_for_settings,
    test_connection,
)

log = configure_logging("pull_calendar_sync")

CRM_PRESERVE_FIELDS = (
    "agenda",
    "outcome",
    "linked_contact_id",
    "related_deal_id",
    "related_organization_id",
    "related_artist_id",
    "related_task_id",
    "event_type",
    "follow_up_required",
    "follow_up_due_at",
    "created_by",
)


def _lifecycle_from_status(status: str) -> str:
    if status == "cancelled":
        return "cancelled"
    if status == "confirmed":
        return "confirmed"
    return "scheduled"


def _should_pull_update(existing: Optional[dict[str, Any]], remote: RemoteCalendarEvent) -> bool:
    if not existing:
        return True
    if existing.get("nextcloud_etag") and remote.etag and existing.get("nextcloud_etag") == remote.etag:
        return False
    draft = remote.draft
    if existing.get("source") == "nextcloud":
        return True
    if draft.is_cancelled:
        return True
    if int(draft.ical_sequence) > int(existing.get("ical_sequence") or 0):
        return True
    if existing.get("nextcloud_href") == remote.href and remote.etag != existing.get("nextcloud_etag"):
        return True
    if (existing.get("sync_status") or "") == "error":
        return True
    return should_upsert(existing, draft)


def _base_payload(
    account_id: str,
    remote: RemoteCalendarEvent,
    *,
    source: str,
) -> dict[str, Any]:
    draft = remote.draft
    status = draft.status
    return {
        "account_id": account_id,
        "ical_uid": draft.ical_uid,
        "ical_sequence": draft.ical_sequence,
        "method": draft.method,
        "status": status,
        "lifecycle_status": _lifecycle_from_status(status),
        "summary": draft.summary,
        "description": draft.description,
        "location": draft.location,
        "organizer_email": draft.organizer_email,
        "organizer_name": draft.organizer_name,
        "attendees": draft.attendees,
        "starts_at": draft.starts_at,
        "ends_at": draft.ends_at,
        "all_day": draft.all_day,
        "timezone": draft.timezone,
        "rrule": draft.rrule,
        "raw_ics": draft.raw_ics,
        "nextcloud_href": remote.href,
        "nextcloud_etag": remote.etag,
        "sync_status": "synced",
        "sync_error": None,
        "source": source,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }


def upsert_remote_event(
    sb: Any,
    account_id: str,
    remote: RemoteCalendarEvent,
    existing: Optional[dict[str, Any]],
) -> str:
    """Returns action: inserted | updated | skipped."""
    if existing and not _should_pull_update(existing, remote):
        return "skipped"

    source = "nextcloud"
    if existing and existing.get("source") in ("manual", "email_manual", "email_ics"):
        source = str(existing.get("source"))

    payload = _base_payload(account_id, remote, source=source)
    if existing:
        for field in CRM_PRESERVE_FIELDS:
            if existing.get(field) is not None:
                payload[field] = existing[field]
        sb.table("calendar_events").update(payload).eq("id", existing["id"]).execute()
        return "updated"

    payload["source"] = "nextcloud"
    inserted = sb.table("calendar_events").insert(payload).select("id").execute()
    new_id = inserted.data[0]["id"] if inserted.data else None
    if new_id:
        try:
            sb.rpc("calendar_match_contact", {"p_event_id": new_id}).execute()
        except Exception as exc:
            log.debug("calendar_match_contact skipped: %s", exc)
    return "inserted"


def pull_calendar_events(
    sb: Any,
    account_id: str,
    settings: dict[str, Any],
    *,
    start: Optional[datetime] = None,
    end: Optional[datetime] = None,
) -> dict[str, Any]:
    if not settings.get("auto_pull", True):
        return {"ok": True, "skipped": True, "reason": "auto_pull disabled"}

    cal_name, cal_url = resolve_calendar_for_settings(settings)
    conn = test_connection(cal_name)
    if not conn.get("ok"):
        return {"ok": False, "error": conn.get("error"), "connection": conn}

    window_start, window_end = start, end
    if window_start is None or window_end is None:
        window_start, window_end = default_pull_window()

    remote_events = query_calendar_events(
        cal_name,
        window_start,
        window_end,
        calendar_url=cal_url,
    )

    summary: dict[str, Any] = {
        "ok": True,
        "scanned": len(remote_events),
        "inserted": 0,
        "updated": 0,
        "skipped": 0,
        "errors": 0,
        "sample_errors": [],
        "connection": {"resolved_slug": conn.get("resolved_slug")},
        "window": {
            "start": window_start.isoformat(),
            "end": window_end.isoformat(),
        },
    }

    for remote in remote_events:
        try:
            existing = (
                sb.table("calendar_events")
                .select("*")
                .eq("account_id", account_id)
                .eq("ical_uid", remote.draft.ical_uid)
                .limit(1)
                .execute()
            )
            row = (existing.data or [None])[0]
            if not row and remote.href:
                by_href = (
                    sb.table("calendar_events")
                    .select("*")
                    .eq("account_id", account_id)
                    .eq("nextcloud_href", remote.href)
                    .limit(1)
                    .execute()
                )
                row = (by_href.data or [None])[0]

            action = upsert_remote_event(sb, account_id, remote, row)
            summary[action] = int(summary.get(action, 0)) + 1

            if action == "updated" and row:
                try:
                    sb.rpc("calendar_match_contact", {"p_event_id": row["id"]}).execute()
                except Exception as exc:
                    log.debug("calendar_match_contact skipped: %s", exc)
        except Exception as exc:
            summary["errors"] += 1
            if len(summary["sample_errors"]) < 5:
                summary["sample_errors"].append(
                    {"uid": remote.draft.ical_uid, "error": str(exc)[:300]}
                )

    now = datetime.now(timezone.utc).isoformat()
    sb.table("calendar_sync_settings").update(
        {
            "last_pull_at": now,
            "last_sync_at": now,
            "last_error": None if summary["errors"] == 0 else json.dumps(summary["sample_errors"][:1]),
            "updated_at": now,
        }
    ).eq("account_id", account_id).execute()

    if summary["errors"] > 0:
        summary["ok"] = False
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Pull calendar events from Nextcloud CalDAV")
    parser.add_argument("account_id", nargs="?", help="Email account UUID (default: first settings row)")
    parser.add_argument("--account-id", dest="account_id_flag", help="Email account UUID")
    parser.add_argument("--days-back", type=int, default=60)
    parser.add_argument("--days-forward", type=int, default=365)
    args = parser.parse_args()

    if not is_nextcloud_configured():
        print("Nextcloud credentials not configured", file=sys.stderr)
        return 2

    sb = create_client(getenv_required("SUPABASE_URL"), getenv_required("SUPABASE_SERVICE_ROLE_KEY"))
    settings_rows = sb.table("calendar_sync_settings").select("*").execute().data or []
    if not settings_rows:
        print(json.dumps({"ok": False, "error": "no calendar_sync_settings row"}))
        return 2

    account_id = args.account_id_flag or args.account_id or settings_rows[0]["account_id"]
    settings = next((r for r in settings_rows if str(r["account_id"]) == str(account_id)), settings_rows[0])

    now = datetime.now(timezone.utc)
    start = now - timedelta(days=args.days_back)
    end = now + timedelta(days=args.days_forward)

    summary = pull_calendar_events(sb, str(account_id), settings, start=start, end=end)
    print(json.dumps(summary))
    return 0 if summary.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
