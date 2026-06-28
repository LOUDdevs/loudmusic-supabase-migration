"""Nextcloud CalDAV push/delete for calendar events."""
from __future__ import annotations

import os
import re
import uuid
import urllib.parse
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

import httpx

from ._common import configure_logging
from .calendar_ics import CalendarEventDraft, parse_ics, sanitize_ics_for_caldav

log = configure_logging("nextcloud_caldav")


def _env(name: str, default: Optional[str] = None) -> Optional[str]:
    return os.environ.get(name) or default


def is_nextcloud_configured() -> bool:
    return bool(_env("NEXTCLOUD_URL") and _env("NEXTCLOUD_USER") and _env("NEXTCLOUD_APP_PASSWORD"))


def _base_url() -> str:
    url = (_env("NEXTCLOUD_URL") or "").rstrip("/")
    if not url:
        raise ValueError("NEXTCLOUD_URL not set")
    return url


def _auth() -> tuple[str, str]:
    user = _env("NEXTCLOUD_USER")
    password = _env("NEXTCLOUD_APP_PASSWORD")
    if not user or not password:
        raise ValueError("NEXTCLOUD_USER or NEXTCLOUD_APP_PASSWORD not set")
    return user, password


def _safe_uid(uid: str) -> str:
    return re.sub(r"[^\w\-.@]", "_", uid) + ".ics"


PROPFIND_BODY = """<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop>
    <D:displayname/>
    <C:calendar-description/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>"""

CALENDAR_QUERY_BODY = """<?xml version="1.0" encoding="utf-8" ?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop>
    <D:getetag/>
    <C:calendar-data/>
  </D:prop>
  <C:filter>
    <C:comp-filter name="VCALENDAR">
      <C:comp-filter name="VEVENT">
        <C:time-range start="{start}" end="{end}"/>
      </C:comp-filter>
    </C:comp-filter>
  </C:filter>
</C:calendar-query>"""


@dataclass
class RemoteCalendarEvent:
    href: str
    etag: Optional[str]
    draft: CalendarEventDraft


def _calendars_collection_url(user: Optional[str] = None) -> str:
    user = user or _env("NEXTCLOUD_USER") or ""
    usr = urllib.parse.quote(user, safe="")
    return f"{_base_url()}/remote.php/dav/calendars/{usr}/"


def _local_name(tag: str) -> str:
    return tag.split("}", 1)[-1] if "}" in tag else tag


def list_calendars(user: Optional[str] = None) -> list[dict[str, str]]:
    """PROPFIND on the user's calendar home; returns slug, display_name, href."""
    user, password = _auth()
    collection = _calendars_collection_url(user)
    headers = {"Depth": "1", "Content-Type": "application/xml; charset=utf-8"}
    with httpx.Client(timeout=60) as client:
        resp = client.request(
            "PROPFIND",
            collection,
            content=PROPFIND_BODY.encode("utf-8"),
            auth=(user, password),
            headers=headers,
        )
        resp.raise_for_status()
        root = ET.fromstring(resp.text)

    calendars: list[dict[str, str]] = []
    collection_norm = collection.rstrip("/")
    for response in root.iter():
        if _local_name(response.tag) != "response":
            continue
        href = display = None
        for child in response.iter():
            name = _local_name(child.tag)
            if name == "href" and href is None and child.text:
                href = child.text.strip()
            elif name == "displayname" and child.text is not None:
                display = child.text.strip()
        if not href:
            continue
        full_href = href if href.startswith("http") else f"{_base_url()}{href}"
        if full_href.rstrip("/") == collection_norm:
            continue
        if "/calendars/" not in href:
            continue
        if any(x in href for x in ("/inbox", "/outbox", "/trashbin")):
            continue
        slug = href.rstrip("/").split("/")[-1]
        if not slug:
            continue
        calendars.append(
            {
                "slug": slug,
                "display_name": display or slug,
                "href": full_href.rstrip("/") + "/",
            }
        )
    return calendars


def resolve_calendar_slug(calendars: list[dict[str, str]], configured_name: str) -> Optional[str]:
    target = configured_name.strip().lower()
    for cal in calendars:
        if cal["slug"].lower() == target or cal["display_name"].lower() == target:
            return cal["slug"]
    return None


def _calendar_collection_href(
    calendar_name: str,
    *,
    calendar_url: Optional[str] = None,
    user: Optional[str] = None,
) -> str:
    if calendar_url:
        return calendar_url.rstrip("/") + "/"
    user = user or _env("NEXTCLOUD_USER") or ""
    cal = urllib.parse.quote(calendar_name, safe="")
    usr = urllib.parse.quote(user, safe="")
    return f"{_base_url()}/remote.php/dav/calendars/{usr}/{cal}/"


def _to_caldav_time(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _abs_href(href: str) -> str:
    if href.startswith("http"):
        return href
    return f"{_base_url()}{href}"


def _parse_calendar_multistatus(xml_text: str) -> list[dict[str, Optional[str]]]:
    root = ET.fromstring(xml_text)
    rows: list[dict[str, Optional[str]]] = []
    for response in root.iter():
        if _local_name(response.tag) != "response":
            continue
        href = etag = cal_data = status = None
        for el in response.iter():
            name = _local_name(el.tag)
            if name == "href" and href is None and el.text:
                href = el.text.strip()
            elif name == "status" and el.text:
                status = el.text.strip()
            elif name == "getetag" and el.text:
                etag = el.text.strip().strip('"')
            elif name == "calendar-data" and el.text:
                cal_data = el.text
        if status and "404" in status:
            continue
        if not href or not cal_data:
            continue
        if not href.rstrip("/").endswith(".ics"):
            continue
        rows.append({"href": _abs_href(href), "etag": etag, "ics": cal_data})
    return rows


def query_calendar_events(
    calendar_name: str,
    start: datetime,
    end: datetime,
    *,
    calendar_url: Optional[str] = None,
) -> list[RemoteCalendarEvent]:
    """CalDAV REPORT calendar-query for VEVENTs in a time range."""
    collection = _calendar_collection_href(calendar_name, calendar_url=calendar_url)
    body = CALENDAR_QUERY_BODY.format(start=_to_caldav_time(start), end=_to_caldav_time(end))
    user, password = _auth()
    headers = {
        "Depth": "1",
        "Content-Type": "application/xml; charset=utf-8",
    }
    with httpx.Client(timeout=120) as client:
        resp = client.request(
            "REPORT",
            collection,
            content=body.encode("utf-8"),
            auth=(user, password),
            headers=headers,
        )
        resp.raise_for_status()
        xml_text = resp.text

    remote: list[RemoteCalendarEvent] = []
    for row in _parse_calendar_multistatus(xml_text):
        try:
            drafts = parse_ics(row["ics"].encode("utf-8"))
        except Exception as exc:
            log.debug("skip unparsable ICS at %s: %s", row["href"], exc)
            continue
        if not drafts:
            continue
        draft = drafts[0]
        draft.raw_ics = row["ics"]
        remote.append(
            RemoteCalendarEvent(
                href=row["href"],
                etag=row.get("etag"),
                draft=draft,
            )
        )
    return remote


def default_pull_window() -> tuple[datetime, datetime]:
    now = datetime.now(timezone.utc)
    return now - timedelta(days=60), now + timedelta(days=365)


def resolve_calendar_for_settings(settings: Optional[dict[str, Any]] = None) -> tuple[str, Optional[str]]:
    settings = settings or {}
    cal_name = settings.get("nextcloud_calendar_name") or _env("NEXTCLOUD_CALENDAR_NAME", "personal") or "personal"
    cal_url = settings.get("nextcloud_calendar_url")
    try:
        resolved = resolve_calendar_slug(list_calendars(), cal_name)
        if resolved:
            cal_name = resolved
    except Exception as exc:
        log.debug("calendar slug resolve skipped: %s", exc)
    return cal_name, cal_url


def test_connection(calendar_name: Optional[str] = None) -> dict[str, Any]:
    """Auth check + list calendars + verify target calendar exists."""
    cal_name = calendar_name or _env("NEXTCLOUD_CALENDAR_NAME", "personal") or "personal"
    if not is_nextcloud_configured():
        return {
            "ok": False,
            "error": "Nextcloud credentials not configured",
            "calendars": [],
            "configured_calendar_found": False,
            "configured_calendar_name": cal_name,
            "resolved_slug": None,
        }
    try:
        calendars = list_calendars()
        resolved = resolve_calendar_slug(calendars, cal_name)
        return {
            "ok": resolved is not None,
            "error": None if resolved else f'Calendar "{cal_name}" not found',
            "calendars": calendars,
            "configured_calendar_found": resolved is not None,
            "configured_calendar_name": cal_name,
            "resolved_slug": resolved,
        }
    except Exception as exc:
        return {
            "ok": False,
            "error": str(exc)[:500],
            "calendars": [],
            "configured_calendar_found": False,
            "configured_calendar_name": cal_name,
            "resolved_slug": None,
        }


def event_href(
    calendar_name: str,
    ical_uid: str,
    *,
    calendar_url: Optional[str] = None,
    user: Optional[str] = None,
) -> str:
    user = user or _env("NEXTCLOUD_USER") or ""
    base = _base_url()
    if calendar_url:
        return f"{calendar_url.rstrip('/')}/{_safe_uid(ical_uid)}"
    cal = urllib.parse.quote(calendar_name, safe="")
    usr = urllib.parse.quote(user, safe="")
    return f"{base}/remote.php/dav/calendars/{usr}/{cal}/{_safe_uid(ical_uid)}"


def push_event(
    ical_uid: str,
    raw_ics: str,
    *,
    calendar_name: Optional[str] = None,
    calendar_url: Optional[str] = None,
    existing_href: Optional[str] = None,
) -> str:
    cal_name = calendar_name or _env("NEXTCLOUD_CALENDAR_NAME", "personal") or "personal"
    href = existing_href or event_href(cal_name, ical_uid, calendar_url=calendar_url)
    user, password = _auth()
    sanitized = sanitize_ics_for_caldav(raw_ics)
    headers: dict[str, str] = {"Content-Type": "text/calendar; charset=utf-8"}
    if not existing_href:
        headers["If-None-Match"] = "*"
    with httpx.Client(timeout=60) as client:
        resp = client.put(
            href,
            content=sanitized.encode("utf-8"),
            auth=(user, password),
            headers=headers,
        )
        resp.raise_for_status()
    log.info("pushed event %s -> %s", ical_uid, href)
    return href


def test_caldav_push_path(calendar_name: Optional[str] = None) -> dict[str, Any]:
    """PROPFIND + sanitized PUT/DELETE of a throwaway event (proves push path)."""
    cal_name = calendar_name or _env("NEXTCLOUD_CALENDAR_NAME", "personal") or "personal"
    conn = test_connection(cal_name)
    if not conn.get("ok"):
        return {**conn, "push_ok": False}

    resolved = conn.get("resolved_slug") or cal_name
    test_uid = f"hermes-caldav-test-{uuid.uuid4()}@loudmusic.io"
    test_ics = sanitize_ics_for_caldav(
        f"""BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//LOUDmusic Test//EN
CALSCALE:GREGORIAN
BEGIN:VEVENT
UID:{test_uid}
DTSTAMP:20260627T120000Z
DTSTART:20300101T120000Z
DTEND:20300101T130000Z
SUMMARY:Hermes CalDAV connectivity test
STATUS:CONFIRMED
END:VEVENT
END:VCALENDAR
"""
    )
    href = None
    try:
        href = push_event(test_uid, test_ics, calendar_name=str(resolved))
        return {**conn, "push_ok": True, "test_href": href}
    except Exception as exc:
        return {**conn, "push_ok": False, "error": str(exc)[:500]}
    finally:
        if href:
            try:
                delete_event(href)
            except Exception as exc:
                log.debug("cleanup test event failed: %s", exc)


def delete_event(href: str) -> None:
    user, password = _auth()
    with httpx.Client(timeout=60) as client:
        resp = client.delete(href, auth=(user, password))
        if resp.status_code not in (200, 204, 404):
            resp.raise_for_status()
    log.info("deleted event at %s", href)


def sync_event_row(
    row: dict[str, Any],
    settings: Optional[dict[str, Any]] = None,
) -> tuple[str, Optional[str], Optional[str]]:
    """Returns (sync_status, nextcloud_href, sync_error)."""
    if not is_nextcloud_configured():
        return "skipped", row.get("nextcloud_href"), "Nextcloud credentials not configured"

    settings = settings or {}
    if not settings.get("auto_push", True):
        return "skipped", row.get("nextcloud_href"), None

    status = row.get("status")
    sync_status = row.get("sync_status")
    href = row.get("nextcloud_href")
    seq = int(row.get("ical_sequence") or 0)
    method = (row.get("method") or "").upper()

    if status == "cancelled" or method == "CANCEL":
        if href:
            try:
                delete_event(href)
            except Exception as exc:
                return "error", href, str(exc)[:500]
        return "cancelled", href, None

    if sync_status == "synced" and row.get("raw_ics") and not row.get("_force"):
        return "synced", href, None

    if row.get("source") == "nextcloud" and sync_status == "synced" and not row.get("_force"):
        return "synced", href, None

    raw = row.get("raw_ics")
    if not raw:
        return "error", href, "missing raw_ics"

    cal_name, cal_url = resolve_calendar_for_settings(settings)
    try:
        new_href = push_event(
            row["ical_uid"],
            raw,
            calendar_name=cal_name,
            calendar_url=cal_url,
            existing_href=href,
        )
        return "synced", new_href, None
    except Exception as exc:
        log.warning("push failed uid=%s seq=%s: %s", row.get("ical_uid"), seq, exc)
        return "error", href, str(exc)[:500]
