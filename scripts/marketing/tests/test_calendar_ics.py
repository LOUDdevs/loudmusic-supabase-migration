from __future__ import annotations

import email
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

from scripts.marketing.calendar_ics import (
    build_attachments_metadata,
    extract_ics_blobs,
    parse_ics,
    should_upsert,
    subject_looks_like_invite,
)

SAMPLE_ICS = b"""BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//EN
METHOD:REQUEST
BEGIN:VEVENT
UID:test-meeting-123@example.com
SEQUENCE:0
DTSTAMP:20260627T120000Z
DTSTART:20260701T140000Z
DTEND:20260701T150000Z
SUMMARY:Team sync
LOCATION:Zoom
ORGANIZER;CN=Alex:mailto:alex@example.com
ATTENDEE;CN=Derrick:mailto:dmcmichael@loudmusic.io
STATUS:CONFIRMED
END:VEVENT
END:VCALENDAR
"""


def _build_message_with_ics() -> email.message.Message:
    msg = MIMEMultipart()
    msg["Subject"] = "Invitation: Team sync"
    msg.attach(MIMEText("Please join the meeting."))
    part = MIMEApplication(SAMPLE_ICS, _subtype="ics")
    part.add_header("Content-Disposition", "attachment", filename="invite.ics")
    msg.attach(part)
    return msg


def _build_calendly_inline_calendar_message() -> email.message.Message:
    msg = MIMEMultipart("alternative")
    msg["Subject"] = "Your event has been scheduled"
    msg.attach(MIMEText("<p>Monday, June 29, 2026</p>", "html"))
    cal = MIMEText(SAMPLE_ICS.decode(), "calendar", "utf-8")
    msg.attach(cal)
    return msg


def test_extract_ics_from_attachment():
    msg = _build_message_with_ics()
    blobs = extract_ics_blobs(msg)
    assert len(blobs) == 1
    drafts = parse_ics(blobs[0])
    assert len(drafts) == 1
    assert drafts[0].ical_uid == "test-meeting-123@example.com"
    assert drafts[0].summary == "Team sync"
    assert drafts[0].status == "confirmed"
    assert drafts[0].organizer_email == "alex@example.com"


def test_build_attachments_metadata_flags_calendar():
    msg = _build_message_with_ics()
    meta = build_attachments_metadata(msg)
    assert len(meta) == 1
    assert meta[0]["is_calendar"] is True


def test_build_attachments_metadata_flags_inline_calendar():
    msg = _build_calendly_inline_calendar_message()
    meta = build_attachments_metadata(msg)
    calendar_parts = [m for m in meta if m["is_calendar"]]
    assert len(calendar_parts) == 1
    assert calendar_parts[0]["mime_type"] == "text/calendar"
    blobs = extract_ics_blobs(msg)
    assert len(blobs) == 1


def test_build_attachments_metadata_includes_named_inline_file():
    msg = MIMEMultipart()
    msg.attach(MIMEText("body"))
    part = MIMEApplication(b"pdf-bytes", _subtype="pdf")
    part.add_header("Content-Disposition", "inline", filename="brief.pdf")
    msg.attach(part)
    meta = build_attachments_metadata(msg)
    assert len(meta) == 1
    assert meta[0]["filename"] == "brief.pdf"
    assert meta[0]["is_calendar"] is False


def test_should_upsert_sequence():
    draft = parse_ics(SAMPLE_ICS)[0]
    assert should_upsert({"ical_sequence": 0, "sync_status": "synced"}, draft) is False
    newer = parse_ics(SAMPLE_ICS.replace(b"SEQUENCE:0", b"SEQUENCE:1"))[0]
    assert should_upsert({"ical_sequence": 0, "sync_status": "synced"}, newer) is True


def test_subject_heuristic():
    assert subject_looks_like_invite("Invitation: Quarterly review") is True
    assert subject_looks_like_invite("Your event has been scheduled") is True
    assert subject_looks_like_invite("Hello there") is False


def test_sanitize_ics_for_caldav_strips_method():
    from scripts.marketing.calendar_ics import sanitize_ics_for_caldav

    sanitized = sanitize_ics_for_caldav(SAMPLE_ICS.decode("utf-8"))
    assert "METHOD:" not in sanitized.upper().split("BEGIN:VEVENT")[0]
    assert "UID:test-meeting-123@example.com" in sanitized
    assert "SUMMARY:Team sync" in sanitized
