#!/usr/bin/env python3
"""ReachInbox ingestion for the marketing dashboard.

Syncs mailboxes, campaigns, Onebox threads, and warmup snapshots from the
ReachInbox API into Supabase marketing.reachinbox_* tables.

Env (from ~/.hermes/.env):
  REACHINBOX_API_KEY
  SUPABASE_URL
  SUPABASE_SERVICE_ROLE_KEY
"""
from __future__ import annotations

import json
import logging
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any, Optional

from supabase import create_client

from ._common import configure_logging, finish_run, getenv_required, parse_iso8601, start_run, to_iso, utcnow

log = configure_logging("ingest_reachinbox")

API_BASE = "https://api.reachinbox.ai/api/v1"
SOURCE = "reachinbox"
ONEBOX_LIMIT = 100
WARMED_THRESHOLD = int(__import__("os").environ.get("REACHINBOX_WARMED_THRESHOLD", "70"))


def api_request(method: str, path: str, body: dict | None = None, params: dict | None = None) -> dict:
    api_key = getenv_required("REACHINBOX_API_KEY")
    url = API_BASE + path
    if params:
        qs = "&".join(f"{k}={urllib.request.quote(str(v))}" for k, v in params.items())
        url = f"{url}?{qs}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "LOUDmusic-Marketing-Ingest/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"status": e.code, "message": raw}


def extract_domain(email: str) -> str:
    return email.split("@")[-1].lower() if "@" in email else ""


def sync_accounts(sb, now_iso: str) -> tuple[int, set[int]]:
    data = api_request("GET", "/account/all", params={"limit": 200})
    if data.get("status") != 200:
        raise RuntimeError(data.get("message", "failed to list accounts"))
    accounts = data.get("data", {}).get("emailsConnected", [])
    rows = []
    account_ids: set[int] = set()
    for acct in accounts:
        email = acct.get("email") or ""
        acct_id = int(acct["id"])
        account_ids.add(acct_id)
        rows.append({
            "id": acct_id,
            "email": email,
            "domain": extract_domain(email),
            "warmup_enabled": bool(acct.get("warmupEnabled")),
            "health_score": acct.get("warmupHealthScore"),
            "mails_sent_today": int(acct.get("mailsSentToday") or 0),
            "is_active": bool(acct.get("isActive", True)),
            "is_disconnected": bool(acct.get("isDisconnected")),
            "raw_metadata": acct,
            "last_synced_at": now_iso,
            "updated_at": now_iso,
        })
    if rows:
        sb.table("reachinbox_accounts").upsert(rows, on_conflict="id").execute()
    return len(rows), account_ids


def sync_warmup_snapshots(sb, now_iso: str, known_account_ids: set[int]) -> int:
    data = api_request("GET", "/analytics/warmup-analytics")
    if data.get("status") != 200:
        log.warning("warmup analytics unavailable: %s", data.get("message"))
        return 0
    items = data.get("data") or []
    if isinstance(items, dict):
        items = items.get("rows", []) or [items]
    rows = []
    for item in items:
        ec_id = item.get("ecId") or item.get("id")
        if ec_id is None:
            continue
        account_id = int(ec_id)
        if account_id not in known_account_ids:
            continue
        rows.append({
            "account_id": account_id,
            "health_score": item.get("healthScore"),
            "warmup_emails_sent": item.get("warmupEmailSentCount"),
            "landed_inbox": item.get("landedOnInboxCount"),
            "landed_spam": item.get("landedOnSpamCount"),
            "mails_sent_today": item.get("mailsSentToday"),
            "snapshot_at": now_iso,
        })
    if rows:
        sb.table("reachinbox_warmup_snapshots").insert(rows).execute()
    return len(rows)


def sync_campaigns(sb, now_iso: str) -> tuple[int, set[int]]:
    data = api_request("GET", "/campaigns/all", params={"limit": 100, "offset": 0, "sort": "newest"})
    if data.get("status") != 200:
        log.warning("campaigns unavailable: %s", data.get("message"))
        return 0, set()
    payload = data.get("data", {})
    campaigns = payload.get("rows", []) if isinstance(payload, dict) else payload or []
    rows = []
    campaign_ids: set[int] = set()
    for c in campaigns:
        campaign_id = int(c["id"])
        campaign_ids.add(campaign_id)
        rows.append({
            "id": campaign_id,
            "name": c.get("name") or f"Campaign {c['id']}",
            "status": c.get("status") or "Draft",
            "total_email_sent": int(c.get("totalEmailSent") or 0),
            "total_email_opened": int(c.get("totalEmailOpened") or 0),
            "total_email_replied": int(c.get("totalEmailReplied") or 0),
            "total_email_bounced": int(c.get("totalEmailBounced") or 0),
            "daily_limit": c.get("dailyLimit"),
            "raw_metadata": c,
            "last_synced_at": now_iso,
            "updated_at": now_iso,
        })
    if rows:
        sb.table("reachinbox_campaigns").upsert(rows, on_conflict="id").execute()
    return len(rows), campaign_ids


def sync_onebox(sb, now_iso: str, known_campaign_ids: set[int]) -> tuple[int, int]:
    body = {
        "limit": ONEBOX_LIMIT,
        "offset": 0,
        "status": "All",
        "inbox": "Inbox",
        "campaigns": [],
        "emailIds": [],
        "excludeCampaigns": [],
        "excludeEmails": [],
        "q": "",
    }
    data = api_request("POST", "/onebox/list", body=body)
    if data.get("status") not in (200, None):
        log.warning("onebox list unavailable: %s", data.get("message"))
        return 0, 0
    threads = data.get("data") or []
    thread_rows = []
    message_count = 0
    for t in threads:
        provider_id = str(t.get("id") or t.get("messageId") or "")
        account_email = t.get("accountEmail") or t.get("fromEmail") or ""
        if not provider_id or not account_email:
            continue
        sent_at = to_iso(parse_iso8601(t.get("sentAt")))
        campaign_id = int(t["campaignId"]) if t.get("campaignId") else None
        if campaign_id is not None and campaign_id not in known_campaign_ids:
            campaign_id = None
        thread_rows.append({
            "provider_thread_id": provider_id,
            "account_email": account_email,
            "campaign_id": campaign_id,
            "from_name": t.get("fromName"),
            "from_email": t.get("fromEmail"),
            "subject": t.get("subject"),
            "status": t.get("status"),
            "inbox_folder": t.get("inbox") or "Inbox",
            "is_read": bool(t.get("isRead")),
            "last_activity_at": sent_at,
            "raw_metadata": t,
            "last_synced_at": now_iso,
            "updated_at": now_iso,
        })

    if not thread_rows:
        return 0, 0

    upserted = sb.table("reachinbox_threads").upsert(
        thread_rows, on_conflict="provider_thread_id,account_email"
    ).execute()
    thread_count = len(upserted.data or thread_rows)

    # Fetch messages for top threads (limit API calls)
    for t in (upserted.data or [])[:20]:
        thread_id = t.get("id")
        account = t.get("account_email")
        provider_id = t.get("provider_thread_id")
        if not thread_id or not account or not provider_id:
            continue
        time.sleep(0.22)  # ~5 req/s rate limit
        td = api_request("POST", "/onebox/thread", body={"account": account, "id": provider_id})
        emails = td.get("data") or []
        msg_rows = []
        for e in emails:
            msg_rows.append({
                "thread_id": thread_id,
                "provider_message_id": e.get("messageId") or e.get("id"),
                "direction": "outbound" if e.get("fromEmail") == account else "inbound",
                "from_email": e.get("fromEmail"),
                "to_email": e.get("toEmail"),
                "subject": e.get("subject"),
                "body_snippet": (e.get("body") or "")[:500],
                "body_html": e.get("body"),
                "status": e.get("status"),
                "sent_at": to_iso(parse_iso8601(e.get("sentAt"))),
                "raw_metadata": e,
            })
        if msg_rows:
            sb.table("reachinbox_messages").insert(msg_rows).execute()
            message_count += len(msg_rows)

    return thread_count, message_count


def main() -> int:
    url = getenv_required("SUPABASE_URL")
    key = getenv_required("SUPABASE_SERVICE_ROLE_KEY")
    sb = create_client(url, key)
    run_id = start_run(sb, SOURCE)
    now_iso = to_iso(utcnow()) or datetime.now(timezone.utc).isoformat()
    records = 0

    try:
        accounts, account_ids = sync_accounts(sb, now_iso)
        records += accounts
        log.info("accounts: %d", accounts)

        snapshots = sync_warmup_snapshots(sb, now_iso, account_ids)
        records += snapshots
        log.info("warmup snapshots: %d", snapshots)

        campaigns, campaign_ids = sync_campaigns(sb, now_iso)
        records += campaigns
        log.info("campaigns: %d", campaigns)

        threads, messages = sync_onebox(sb, now_iso, campaign_ids)
        records += threads + messages
        log.info("onebox threads: %d messages: %d", threads, messages)

        sb.table("reachinbox_sync_logs").insert({
            "finished_at": now_iso,
            "status": "success",
            "accounts_synced": accounts,
            "campaigns_synced": campaigns,
            "threads_synced": threads,
            "messages_synced": messages,
        }).execute()

        finish_run(sb, run_id, records_written=records)
        print(f"OK: {records} records written")
        return 0
    except Exception as exc:
        log.exception("ingest failed")
        sb.table("reachinbox_sync_logs").insert({
            "finished_at": now_iso,
            "status": "error",
            "error": str(exc)[:500],
        }).execute()
        finish_run(sb, run_id, records_written=records, error=str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
