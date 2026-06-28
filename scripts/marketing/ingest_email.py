#!/usr/bin/env python3
"""Email IMAP ingestion for the marketing dashboard.

Syncs inbox messages from configured email_accounts into marketing.email_threads
and marketing.emails.

Exit codes:
  0 — success or no account configured
  1 — unexpected error
  2 — missing env
"""
from __future__ import annotations

import email
import imaplib
import os
import re
import ssl
import sys
from datetime import datetime, timezone
from email.header import decode_header
from email.utils import parsedate_to_datetime
from typing import Any, Optional

from supabase import create_client

from ._common import configure_logging, finish_run, getenv_required, start_run
from .calendar_ics import (
    build_attachments_metadata,
    extract_ics_blobs,
    parse_ics,
    should_upsert,
    subject_looks_like_invite,
)
from .nextcloud_caldav import sync_event_row

log = configure_logging("ingest_email")
SYNC_LIMIT = int(os.environ.get("EMAIL_SYNC_LIMIT", "50"))


def decode_str(value: Optional[str]) -> str:
    if not value:
        return ""
    parts = decode_header(value)
    out: list[str] = []
    for part, enc in parts:
        if isinstance(part, bytes):
            out.append(part.decode(enc or "utf-8", errors="replace"))
        else:
            out.append(part)
    return "".join(out)


def message_id_key(raw: Optional[str]) -> Optional[str]:
    if not raw:
        return None
    return raw.strip().strip("<>").strip() or None


def thread_key_from_msg(msg: email.message.Message) -> str:
    for header in ("References", "In-Reply-To", "Message-ID"):
        key = message_id_key(msg.get(header))
        if key:
            return key
    subject = decode_str(msg.get("Subject", "")) or "(no subject)"
    sender = decode_str(msg.get("From", "")) or "unknown"
    return f"fallback:{subject.lower()}:{sender.lower()}"


def parse_address_list(raw: Optional[str]) -> list[dict[str, str]]:
    if not raw:
        return []
    return [{"email": addr.strip(), "name": ""} for addr in raw.split(",") if addr.strip()]


def extract_sender(msg: email.message.Message) -> tuple[str, str]:
    raw = decode_str(msg.get("From", ""))
    match = re.search(r"<([^>]+)>", raw)
    if match:
        return raw.split("<")[0].strip().strip('"'), match.group(1).lower()
    return raw, raw.lower() if "@" in raw else ""


def extract_bodies(msg: email.message.Message) -> tuple[str, Optional[str]]:
    text_parts: list[str] = []
    html_parts: list[str] = []
    if msg.is_multipart():
        for part in msg.walk():
            ctype = part.get_content_type()
            disp = str(part.get("Content-Disposition") or "")
            if "attachment" in disp.lower():
                continue
            try:
                payload = part.get_payload(decode=True)
            except Exception:
                continue
            if not payload:
                continue
            charset = part.get_content_charset() or "utf-8"
            decoded = payload.decode(charset, errors="replace")
            if ctype == "text/plain":
                text_parts.append(decoded)
            elif ctype == "text/html":
                html_parts.append(decoded)
    else:
        try:
            payload = msg.get_payload(decode=True)
        except Exception:
            payload = None
        if payload:
            charset = msg.get_content_charset() or "utf-8"
            decoded = payload.decode(charset, errors="replace")
            if msg.get_content_type() == "text/html":
                html_parts.append(decoded)
            else:
                text_parts.append(decoded)
    body_text = "\n".join(text_parts).strip()
    body_html = "\n".join(html_parts).strip() or None
    return body_text, body_html


def parse_received_at(msg: email.message.Message) -> str:
    raw = msg.get("Date")
    if not raw:
        return datetime.now(timezone.utc).isoformat()
    try:
        return parsedate_to_datetime(raw).astimezone(timezone.utc).isoformat()
    except Exception:
        return datetime.now(timezone.utc).isoformat()


def fetch_imap_messages(account: dict[str, Any], password: str, limit: int) -> list[tuple[str, email.message.Message]]:
    config = account.get("config") or {}
    imap_cfg = config.get("imap") or {}
    host = imap_cfg.get("host")
    port = int(imap_cfg.get("port") or 993)
    user = imap_cfg.get("user") or account.get("account_email")
    if not host or not user:
        raise ValueError("IMAP host/user missing in account config")

    ctx = ssl.create_default_context()
    messages: list[tuple[str, email.message.Message]] = []
    with imaplib.IMAP4_SSL(host, port, ssl_context=ctx) as mail:
        mail.login(user, password)
        mail.select("INBOX")
        _, data = mail.search(None, "ALL")
        uids = data[0].split()
        uids = uids[-limit:][::-1]
        for uid in uids:
            _, msg_data = mail.fetch(uid, "(RFC822)")
            if not msg_data or not msg_data[0]:
                continue
            raw = msg_data[0][1]
            if isinstance(raw, bytes):
                messages.append((uid.decode(), email.message_from_bytes(raw)))
    return messages


def ensure_calendar_sync_settings(sb: Any, account_id: str) -> dict[str, Any]:
    existing = (
        sb.table("calendar_sync_settings")
        .select("*")
        .eq("account_id", account_id)
        .limit(1)
        .execute()
    )
    if existing.data:
        return existing.data[0]
    inserted = (
        sb.table("calendar_sync_settings")
        .insert({"account_id": account_id})
        .select("*")
        .execute()
    )
    return inserted.data[0]


def process_calendar_for_message(
    sb: Any,
    account_id: str,
    thread_id: str,
    email_id: str,
    msg: email.message.Message,
    settings: dict[str, Any],
) -> dict[str, int]:
    stats = {"ics_found": 0, "events_upserted": 0, "nextcloud_pushed": 0, "nextcloud_errors": 0}
    blobs = extract_ics_blobs(msg)
    stats["ics_found"] = len(blobs)
    labels: list[str] = []

    if not blobs and subject_looks_like_invite(decode_str(msg.get("Subject", ""))):
        labels.append("calendar_candidate")

    attachments_meta = build_attachments_metadata(msg)
    email_patch: dict[str, Any] = {"attachments_metadata": attachments_meta}
    if labels:
        email_patch["labels"] = labels
    sb.table("emails").update(email_patch).eq("id", email_id).execute()

    for blob in blobs:
        default_tz = str(settings.get("default_timezone") or "America/New_York")
        for draft in parse_ics(blob, default_tz=default_tz):
            existing = (
                sb.table("calendar_events")
                .select("*")
                .eq("account_id", account_id)
                .eq("ical_uid", draft.ical_uid)
                .limit(1)
                .execute()
            )
            row = (existing.data or [None])[0]
            if row and not should_upsert(row, draft):
                continue

            payload = {
                "account_id": account_id,
                "email_id": email_id,
                "thread_id": thread_id,
                "source": "email_ics",
                "ical_uid": draft.ical_uid,
                "ical_sequence": draft.ical_sequence,
                "method": draft.method,
                "status": draft.status,
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
                "sync_status": "pending",
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }
            if row:
                upserted = (
                    sb.table("calendar_events")
                    .update(payload)
                    .eq("id", row["id"])
                    .select("*")
                    .execute()
                )
                event_row = upserted.data[0]
            else:
                inserted = (
                    sb.table("calendar_events")
                    .insert(payload)
                    .select("*")
                    .execute()
                )
                event_row = inserted.data[0]
            stats["events_upserted"] += 1

            try:
                sb.rpc("calendar_match_contact", {"p_event_id": event_row["id"]}).execute()
            except Exception as exc:
                log.warning("calendar_match_contact failed: %s", exc)

            sync_status, href, sync_error = sync_event_row(event_row, settings)
            sb.table("calendar_events").update(
                {
                    "sync_status": sync_status,
                    "nextcloud_href": href,
                    "sync_error": sync_error,
                    "updated_at": datetime.now(timezone.utc).isoformat(),
                }
            ).eq("id", event_row["id"]).execute()
            if sync_status == "synced":
                stats["nextcloud_pushed"] += 1
            elif sync_status == "error":
                stats["nextcloud_errors"] += 1

    now = datetime.now(timezone.utc).isoformat()
    sb.table("calendar_sync_settings").update(
        {"last_sync_at": now, "last_error": None, "updated_at": now}
    ).eq("account_id", account_id).execute()

    return stats


def upsert_thread_and_email(
    sb: Any,
    account_id: str,
    account_email: str,
    uid: str,
    msg: email.message.Message,
    calendar_settings: dict[str, Any],
) -> tuple[bool, bool, dict[str, int]]:
    provider_thread_id = thread_key_from_msg(msg)
    provider_message_id = message_id_key(msg.get("Message-ID")) or f"imap-uid:{uid}"
    sender_name, sender_email = extract_sender(msg)
    direction = "outbound" if sender_email == account_email.lower() else "inbound"
    subject = decode_str(msg.get("Subject", "")) or None
    body_text, body_html = extract_bodies(msg)
    snippet = (body_text or subject or "")[:240] or None
    received_at = parse_received_at(msg)

    existing_thread = (
        sb.table("email_threads")
        .select("id")
        .eq("account_id", account_id)
        .eq("provider_thread_id", provider_thread_id)
        .limit(1)
        .execute()
    )
    thread_rows = existing_thread.data or []
    if thread_rows:
        thread_id = thread_rows[0]["id"]
        thread_created = False
    else:
        insert_thread = (
            sb.table("email_threads")
            .insert(
                {
                    "account_id": account_id,
                    "provider_thread_id": provider_thread_id,
                    "subject": subject,
                    "participants": [{"email": sender_email, "name": sender_name}],
                    "last_message_at": received_at,
                    "unread_count": 1 if direction == "inbound" else 0,
                    "needs_reply": direction == "inbound",
                    "status": "open",
                }
            )
            .select("id")
            .execute()
        )
        thread_id = insert_thread.data[0]["id"]
        thread_created = True

    sb.table("email_threads").update(
        {
            "subject": subject,
            "last_message_at": received_at,
            "needs_reply": direction == "inbound",
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
    ).eq("id", thread_id).execute()

    existing_email = (
        sb.table("emails")
        .select("id, attachments_metadata")
        .eq("account_id", account_id)
        .eq("provider_message_id", provider_message_id)
        .limit(1)
        .execute()
    )
    if existing_email.data:
        email_id = existing_email.data[0]["id"]
        meta = existing_email.data[0].get("attachments_metadata")
        stale = not meta or (isinstance(meta, list) and len(meta) == 0)
        if stale and (extract_ics_blobs(msg) or subject_looks_like_invite(subject or "")):
            cal_stats = process_calendar_for_message(
                sb, account_id, thread_id, email_id, msg, calendar_settings
            )
            return thread_created, False, cal_stats
        return thread_created, False, {"ics_found": 0, "events_upserted": 0, "nextcloud_pushed": 0, "nextcloud_errors": 0}

    attachments_meta = build_attachments_metadata(msg)
    inserted_email = sb.table("emails").insert(
        {
            "thread_id": thread_id,
            "account_id": account_id,
            "provider_message_id": provider_message_id,
            "direction": direction,
            "sender_name": sender_name,
            "sender_email": sender_email,
            "recipients": parse_address_list(msg.get("To")),
            "cc": parse_address_list(msg.get("Cc")),
            "bcc": parse_address_list(msg.get("Bcc")),
            "subject": subject,
            "body_text": body_text or None,
            "body_html": body_html,
            "snippet": snippet,
            "received_at": received_at,
            "is_read": direction == "outbound",
            "attachments_metadata": attachments_meta,
        }
    ).select("id").execute()
    email_id = inserted_email.data[0]["id"]

    cal_stats = process_calendar_for_message(sb, account_id, thread_id, email_id, msg, calendar_settings)

    if direction == "inbound":
        try:
            sb.rpc("email_sync_contact_from_thread", {"p_thread_id": thread_id}).execute()
        except Exception as exc:
            log.warning("email_sync_contact_from_thread failed for %s: %s", thread_id, exc)

    return thread_created, True, cal_stats


def sync_account(sb: Any, account: dict[str, Any]) -> dict[str, Any]:
    account_id = account["id"]
    cred_key = account.get("credentials_env_key") or "EMAIL_SMTP_PASSWORD"
    password = os.environ.get(cred_key)
    if not password:
        raise ValueError(f"credentials env key {cred_key} not set")

    sb.table("email_accounts").update({"sync_status": "syncing"}).eq("id", account_id).execute()

    calendar_settings = ensure_calendar_sync_settings(sb, account_id)
    messages = fetch_imap_messages(account, password, SYNC_LIMIT)
    threads_created = 0
    emails_written = 0
    cal_totals = {"ics_found": 0, "events_upserted": 0, "nextcloud_pushed": 0, "nextcloud_errors": 0}
    for uid, msg in messages:
        t_new, e_new, cal_stats = upsert_thread_and_email(
            sb, account_id, account["account_email"], uid, msg, calendar_settings
        )
        if t_new:
            threads_created += 1
        if e_new:
            emails_written += 1
        for k in cal_totals:
            cal_totals[k] += cal_stats.get(k, 0)

    try:
        sb.rpc("email_sync_unlinked_contacts", {"p_limit": 200}).execute()
    except Exception as exc:
        log.warning("email_sync_unlinked_contacts failed: %s", exc)

    now = datetime.now(timezone.utc).isoformat()
    sb.table("email_accounts").update(
        {
            "sync_status": "synced",
            "last_synced_at": now,
            "updated_at": now,
        }
    ).eq("id", account_id).execute()

    return {
        "threads_created": threads_created,
        "emails_written": emails_written,
        "messages_fetched": len(messages),
        **cal_totals,
    }


def main() -> int:
    supabase_url = getenv_required("SUPABASE_URL")
    supabase_key = getenv_required("SUPABASE_SERVICE_ROLE_KEY")
    sb = create_client(supabase_url, supabase_key)

    run_id = start_run(sb, "email")

    accounts = (
        sb.table("email_accounts")
        .select("*")
        .eq("status", "active")
        .limit(1)
        .execute()
    )
    rows = accounts.data or []

    if not rows:
        log.info("no active email account configured — skipping sync")
        finish_run(sb, run_id, records_written=0)
        return 0

    account = rows[0]
    try:
        stats = sync_account(sb, account)
        log.info(
            "email sync complete: fetched=%s emails_written=%s threads_created=%s "
            "ics_found=%s events_upserted=%s nextcloud_pushed=%s nextcloud_errors=%s",
            stats["messages_fetched"],
            stats["emails_written"],
            stats["threads_created"],
            stats.get("ics_found", 0),
            stats.get("events_upserted", 0),
            stats.get("nextcloud_pushed", 0),
            stats.get("nextcloud_errors", 0),
        )
        finish_run(
            sb,
            run_id,
            records_written=stats["emails_written"] + stats.get("events_upserted", 0),
        )
        return 0
    except Exception as exc:
        log.exception("email sync failed: %s", exc)
        sb.table("email_accounts").update(
            {"sync_status": "error", "updated_at": datetime.now(timezone.utc).isoformat()}
        ).eq("id", account["id"]).execute()
        finish_run(sb, run_id, error=str(exc)[:1000], records_written=0)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit as e:
        raise e
    except Exception as e:
        log.exception(f"unexpected: {e}")
        sys.exit(1)
