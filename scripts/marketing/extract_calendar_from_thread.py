#!/usr/bin/env python3
"""Re-scan a thread's emails from IMAP for ICS invites and upsert calendar events."""
from __future__ import annotations

import email
import imaplib
import os
import ssl
import sys
from typing import Any, Optional

from supabase import create_client

from ._common import configure_logging, getenv_required
from .ingest_email import ensure_calendar_sync_settings, process_calendar_for_message

log = configure_logging("extract_calendar_from_thread")


def fetch_imap_message(account: dict[str, Any], password: str, provider_message_id: str) -> Optional[email.message.Message]:
    config = account.get("config") or {}
    imap_cfg = config.get("imap") or {}
    host = imap_cfg.get("host")
    port = int(imap_cfg.get("port") or 993)
    user = imap_cfg.get("user") or account.get("account_email")
    if not host or not user:
        raise ValueError("IMAP host/user missing in account config")

    ctx = ssl.create_default_context()
    with imaplib.IMAP4_SSL(host, port, ssl_context=ctx) as mail:
        mail.login(user, password)
        mail.select("INBOX")

        if provider_message_id.startswith("imap-uid:"):
            uid = provider_message_id.split(":", 1)[1]
            _, msg_data = mail.fetch(uid.encode(), "(RFC822)")
        else:
            search_id = provider_message_id
            if not search_id.startswith("<"):
                search_id = f"<{search_id}>"
            _, data = mail.search(None, "HEADER", "Message-ID", search_id)
            uids = data[0].split()
            if not uids:
                return None
            _, msg_data = mail.fetch(uids[-1], "(RFC822)")

        if not msg_data or not msg_data[0]:
            return None
        raw = msg_data[0][1]
        if isinstance(raw, bytes):
            return email.message_from_bytes(raw)
    return None


def extract_thread(thread_id: str) -> dict[str, int]:
    sb = create_client(getenv_required("SUPABASE_URL"), getenv_required("SUPABASE_SERVICE_ROLE_KEY"))

    thread_row = sb.table("email_threads").select("*").eq("id", thread_id).limit(1).execute()
    if not thread_row.data:
        raise ValueError(f"thread not found: {thread_id}")
    thread = thread_row.data[0]
    account_id = thread["account_id"]

    account_row = sb.table("email_accounts").select("*").eq("id", account_id).limit(1).execute()
    if not account_row.data:
        raise ValueError(f"account not found: {account_id}")
    account = account_row.data[0]
    cred_key = account.get("credentials_env_key") or "EMAIL_SMTP_PASSWORD"
    password = os.environ.get(cred_key)
    if not password:
        raise ValueError(f"credentials env key {cred_key} not set")

    emails = (
        sb.table("emails")
        .select("id, provider_message_id")
        .eq("thread_id", thread_id)
        .order("received_at", desc=False)
        .execute()
    )

    settings = ensure_calendar_sync_settings(sb, account_id)
    totals = {"ics_found": 0, "events_upserted": 0, "nextcloud_pushed": 0, "nextcloud_errors": 0}

    for row in emails.data or []:
        provider_id = row.get("provider_message_id")
        if not provider_id:
            continue
        try:
            msg = fetch_imap_message(account, password, provider_id)
        except Exception as exc:
            log.warning("imap fetch failed email=%s: %s", row["id"], exc)
            continue
        if not msg:
            continue
        stats = process_calendar_for_message(sb, account_id, thread_id, row["id"], msg, settings)
        for key in totals:
            totals[key] += stats.get(key, 0)

    return totals


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: extract_calendar_from_thread.py <thread_id>", file=sys.stderr)
        return 2
    thread_id = sys.argv[1]
    try:
        totals = extract_thread(thread_id)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(
        f"OK: ics_found={totals['ics_found']} events_upserted={totals['events_upserted']} "
        f"nextcloud_pushed={totals['nextcloud_pushed']} nextcloud_errors={totals['nextcloud_errors']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
