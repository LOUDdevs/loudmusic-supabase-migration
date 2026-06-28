"""ICS extraction and parsing from email MIME messages."""
from __future__ import annotations

import email
import re
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from email.message import Message
from typing import Any, Optional

from icalendar import Calendar, Event

INVITE_SUBJECT_RE = re.compile(
    r"invitation:|accepted:|declined:|canceled:|cancelled:|updated invitation|"
    r"your event has been scheduled|event has been scheduled|new event:|calendly",
    re.IGNORECASE,
)

ICS_CONTENT_TYPES = {
    "text/calendar",
    "application/ics",
    "application/octet-stream",
}


@dataclass
class CalendarEventDraft:
    ical_uid: str
    ical_sequence: int = 0
    method: Optional[str] = None
    status: str = "tentative"
    summary: Optional[str] = None
    description: Optional[str] = None
    location: Optional[str] = None
    organizer_email: Optional[str] = None
    organizer_name: Optional[str] = None
    attendees: list[dict[str, str]] = field(default_factory=list)
    starts_at: Optional[str] = None
    ends_at: Optional[str] = None
    all_day: bool = False
    timezone: Optional[str] = None
    rrule: Optional[str] = None
    raw_ics: str = ""
    is_cancelled: bool = False


def _part_filename(part: Message) -> str:
    raw = part.get_filename()
    return (raw or "").lower()


def _is_ics_part(part: Message) -> bool:
    ctype = (part.get_content_type() or "").lower()
    fname = _part_filename(part)
    if fname.endswith(".ics"):
        return True
    if ctype in ICS_CONTENT_TYPES:
        if ctype == "application/octet-stream" and not fname.endswith(".ics"):
            return False
        return True
    return False


def extract_ics_blobs(msg: Message) -> list[bytes]:
    blobs: list[bytes] = []
    if msg.is_multipart():
        for part in msg.walk():
            if not _is_ics_part(part):
                continue
            try:
                payload = part.get_payload(decode=True)
            except Exception:
                continue
            if payload:
                blobs.append(payload)
    elif _is_ics_part(msg):
        try:
            payload = msg.get_payload(decode=True)
            if payload:
                blobs.append(payload)
        except Exception:
            pass
    return blobs


def build_attachments_metadata(msg: Message) -> list[dict[str, Any]]:
    meta: list[dict[str, Any]] = []
    if not msg.is_multipart():
        return meta
    for part in msg.walk():
        if part.get_content_maintype() == "multipart":
            continue
        disp = str(part.get("Content-Disposition") or "").lower()
        is_calendar = _is_ics_part(part)
        fname = part.get_filename()
        is_attachment = "attachment" in disp
        # Named files, explicit attachments, and inline calendar parts (e.g. Calendly text/calendar)
        if not is_attachment and not is_calendar and not fname:
            continue
        try:
            payload = part.get_payload(decode=True) or b""
        except Exception:
            payload = b""
        meta.append(
            {
                "filename": fname or ("invite.ics" if is_calendar else "attachment"),
                "mime_type": part.get_content_type(),
                "size": len(payload),
                "is_calendar": is_calendar,
            }
        )
    return meta


def _parse_address(value: Any) -> tuple[Optional[str], Optional[str]]:
    if value is None:
        return None, None
    raw = str(value)
    if raw.upper().startswith("MAILTO:"):
        raw = raw[7:]
    match = re.search(r"mailto:([^;>\s]+)", str(value), re.IGNORECASE)
    email_addr = match.group(1).lower() if match else raw.split(";")[0].strip().lower()
    name = None
    if "CN=" in str(value).upper():
        cn = re.search(r"CN=([^;:]+)", str(value), re.IGNORECASE)
        if cn:
            name = cn.group(1).strip().strip('"')
    return email_addr if "@" in email_addr else None, name


WINDOWS_TZ = {
    "Eastern Standard Time": "America/New_York",
    "Central Standard Time": "America/Chicago",
    "Mountain Standard Time": "America/Denver",
    "Pacific Standard Time": "America/Los_Angeles",
    "GMT Standard Time": "Europe/London",
    "W. Europe Standard Time": "Europe/Paris",
}


def _resolve_tzid(tz_name: Optional[str]) -> Optional[str]:
    if not tz_name:
        return None
    raw = str(tz_name).strip()
    return WINDOWS_TZ.get(raw, raw)


def _to_utc_iso(
    dt: Any,
    dt_prop: Any = None,
    default_tz: str = "America/New_York",
    fallback_tz: Optional[str] = None,
) -> tuple[Optional[str], bool, Optional[str]]:
    if dt is None:
        return None, False, None
    if isinstance(dt, date) and not isinstance(dt, datetime):
        start = datetime(dt.year, dt.month, dt.day, tzinfo=timezone.utc)
        return start.isoformat(), True, None
    if isinstance(dt, datetime):
        tz_name = None
        if dt_prop is not None and hasattr(dt_prop, "params"):
            tzid = dt_prop.params.get("TZID")
            if tzid:
                tz_name = _resolve_tzid(str(tzid))
        if not tz_name and fallback_tz:
            tz_name = _resolve_tzid(fallback_tz)
        if dt.tzinfo is None and tz_name:
            try:
                from zoneinfo import ZoneInfo

                dt = dt.replace(tzinfo=ZoneInfo(tz_name))
            except Exception:
                pass
        if dt.tzinfo is None:
            try:
                from zoneinfo import ZoneInfo

                dt = dt.replace(tzinfo=ZoneInfo(default_tz))
                tz_name = default_tz
            except Exception:
                return dt.replace(tzinfo=timezone.utc).isoformat(), False, tz_name
        resolved = tz_name or str(dt.tzinfo)
        return dt.astimezone(timezone.utc).isoformat(), False, resolved
    return None, False, None


def _map_status(raw: Optional[str], method: Optional[str], is_cancelled: bool) -> str:
    if is_cancelled or (method or "").upper() == "CANCEL":
        return "cancelled"
    if raw:
        upper = raw.upper()
        if upper == "CONFIRMED":
            return "confirmed"
        if upper == "CANCELLED":
            return "cancelled"
    return "tentative"


def parse_ics(blob: bytes, default_tz: str = "America/New_York") -> list[CalendarEventDraft]:
    cal = Calendar.from_ical(blob)
    method = None
    if cal.get("method"):
        method = str(cal.get("method")).upper()
    drafts: list[CalendarEventDraft] = []
    for component in cal.walk():
        if component.name != "VEVENT":
            continue
        uid = str(component.get("uid") or "").strip()
        if not uid:
            continue
        seq = int(component.get("sequence") or 0)
        status_raw = str(component.get("status") or "") or None
        starts_at, all_day, tz_name = _to_utc_iso(
            component.get("dtstart").dt if component.get("dtstart") else None,
            component.get("dtstart"),
            default_tz,
        )
        ends_at, _, _ = _to_utc_iso(
            component.get("dtend").dt if component.get("dtend") else None,
            component.get("dtend"),
            default_tz,
            fallback_tz=tz_name,
        )
        organizer_email, organizer_name = _parse_address(component.get("organizer"))
        attendees: list[dict[str, str]] = []
        att_val = component.get("attendee")
        att_list = att_val if isinstance(att_val, list) else ([att_val] if att_val else [])
        for item in att_list:
            email_addr, name = _parse_address(item)
            if email_addr:
                partstat = "NEEDS-ACTION"
                if hasattr(item, "params") and item.params.get("PARTSTAT"):
                    partstat = str(item.params.get("PARTSTAT")).upper()
                attendees.append({"email": email_addr, "name": name or "", "partstat": partstat})
        rrule = None
        if component.get("rrule"):
            rrule = str(component.get("rrule"))
        is_cancelled = (method or "").upper() == "CANCEL" or (status_raw or "").upper() == "CANCELLED"
        drafts.append(
            CalendarEventDraft(
                ical_uid=uid,
                ical_sequence=seq,
                method=method,
                status=_map_status(status_raw, method, is_cancelled),
                summary=str(component.get("summary") or "") or None,
                description=str(component.get("description") or "") or None,
                location=str(component.get("location") or "") or None,
                organizer_email=organizer_email,
                organizer_name=organizer_name,
                attendees=attendees,
                starts_at=starts_at,
                ends_at=ends_at,
                all_day=all_day,
                timezone=tz_name,
                rrule=rrule,
                raw_ics=blob.decode("utf-8", errors="replace"),
                is_cancelled=is_cancelled,
            )
        )
    return drafts


def should_upsert(existing: dict[str, Any], draft: CalendarEventDraft) -> bool:
    if not existing:
        return True
    old_seq = int(existing.get("ical_sequence") or 0)
    if draft.is_cancelled:
        return True
    if draft.ical_sequence > old_seq:
        return True
    if (existing.get("sync_status") or "") == "error":
        return True
    return False


def subject_looks_like_invite(subject: Optional[str]) -> bool:
    if not subject:
        return False
    return bool(INVITE_SUBJECT_RE.search(subject))


def _sanitize_ics_lines(raw: str) -> str:
    """Line-based fallback: drop METHOD and empty lines, preserve CRLF folding."""
    out: list[str] = []
    for line in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if not line.strip():
            continue
        if line.upper().startswith("METHOD:"):
            continue
        out.append(line.rstrip())
    if not out:
        raise ValueError("ICS has no content after sanitization")
    body = "\r\n".join(out) + "\r\n"
    return body


def sanitize_ics_for_caldav(raw: str) -> str:
    """Rebuild CalDAV-safe ICS: no METHOD, single VEVENT, no VALARM subcomponents."""
    if not raw or not str(raw).strip():
        raise ValueError("empty ICS")

    text = str(raw)
    try:
        cal = Calendar.from_ical(text.encode("utf-8"))
    except Exception:
        return _sanitize_ics_lines(text)

    vevents = [c for c in cal.walk() if c.name == "VEVENT"]
    if not vevents:
        return _sanitize_ics_lines(text)

    src = vevents[0]
    new_cal = Calendar()
    new_cal.add("version", "2.0")
    new_cal.add("prodid", "-//LOUDmusic Dashboard//Calendar//EN")
    new_cal.add("calscale", "GREGORIAN")

    new_event = Event()
    skip_props = {"method"}
    for key in src.sorted_keys():
        if key.lower() in skip_props:
            continue
        new_event.add(key, src.get(key))

    if not new_event.get("uid"):
        raise ValueError("ICS VEVENT missing UID")
    if not new_event.get("dtstamp"):
        from datetime import datetime, timezone

        new_event.add("dtstamp", datetime.now(timezone.utc))

    new_cal.add_component(new_event)
    sanitized = new_cal.to_ical().decode("utf-8")
    return _sanitize_ics_lines(sanitized)
