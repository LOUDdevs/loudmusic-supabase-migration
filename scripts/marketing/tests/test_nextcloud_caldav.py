"""Tests for Nextcloud CalDAV calendar discovery."""
from __future__ import annotations

from unittest.mock import MagicMock, patch

from scripts.marketing.calendar_ics import sanitize_ics_for_caldav
from scripts.marketing.nextcloud_caldav import (
    _parse_calendar_multistatus,
    push_event,
    resolve_calendar_slug,
)


def test_resolve_calendar_slug_by_display_name():
    calendars = [
        {"slug": "personal", "display_name": "Personal", "href": "https://x/personal/"},
        {"slug": "loudmusic", "display_name": "LOUDmusic", "href": "https://x/loudmusic/"},
    ]
    assert resolve_calendar_slug(calendars, "LOUDmusic") == "loudmusic"
    assert resolve_calendar_slug(calendars, "loudmusic") == "loudmusic"
    assert resolve_calendar_slug(calendars, "missing") is None


@patch.dict(
    "os.environ",
    {
        "NEXTCLOUD_URL": "https://docs.example.com",
        "NEXTCLOUD_USER": "user@example.com",
        "NEXTCLOUD_APP_PASSWORD": "secret",
        "NEXTCLOUD_CALENDAR_NAME": "loudmusic",
    },
)
def test_push_event_sanitizes_body_before_put():
    captured: dict[str, str] = {}

    def fake_put(url, content, auth, headers):
        captured["body"] = content.decode("utf-8")
        captured["headers"] = str(headers)
        resp = MagicMock()
        resp.raise_for_status = MagicMock()
        return resp

    raw = """BEGIN:VCALENDAR
VERSION:2.0
METHOD:REQUEST
BEGIN:VEVENT
UID:test@example.com
DTSTAMP:20260627T120000Z
DTSTART:20260701T140000Z
DTEND:20260701T150000Z
SUMMARY:Test
END:VEVENT
END:VCALENDAR
"""

    with patch("scripts.marketing.nextcloud_caldav.httpx.Client") as mock_client:
        mock_client.return_value.__enter__.return_value.put = fake_put
        push_event("test@example.com", raw, calendar_name="loudmusic")

    body = captured["body"]
    assert "METHOD:" not in body.split("BEGIN:VEVENT")[0]
    assert sanitize_ics_for_caldav(raw) == body
    assert "If-None-Match" in captured["headers"]


def test_parse_calendar_multistatus_extracts_ics():
    xml = """<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/remote.php/dav/calendars/user/loudmusic/event-1.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"abc123"</d:getetag>
        <c:calendar-data>BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:event-1@example.com
DTSTART:20260701T140000Z
DTEND:20260701T150000Z
SUMMARY:Remote meeting
END:VEVENT
END:VCALENDAR</c:calendar-data>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>"""
    rows = _parse_calendar_multistatus(xml)
    assert len(rows) == 1
    assert rows[0]["href"].endswith("event-1.ics")
    assert rows[0]["etag"] == "abc123"
    assert "UID:event-1@example.com" in rows[0]["ics"]
