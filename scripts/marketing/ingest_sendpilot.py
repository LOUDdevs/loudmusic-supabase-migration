#!/usr/bin/env python3
"""SendPilot ingestion for the Central Marketing Dashboard.

Pulls conversations, messages, campaigns, and leads from the SendPilot REST API
and upserts them into the Supabase `marketing` schema.

First run: 3-month backfill (configurable via --since).
Subsequent runs: incremental — only conversations whose lastActivityAt is
newer than the max already in the DB (with 1h overlap for safety).

Env contract (from ~/.hermes/.env, auto-loaded by _common):
  SENDPILOT_API_KEY         — required
  SUPABASE_URL              — required (e.g. https://hupiguhcsmeucownlbre.supabase.co)
  SUPABASE_SERVICE_ROLE_KEY — required (service-role JWT for writes)

CLI flags:
  --since YYYY-MM-DD        — explicit incremental cutoff (overrides default)
  --backfill                — force 3-month backfill on every campaign and lead
  --skip-leads              — skip lead ingestion (faster runs for testing)
  --skip-lead-enrichment    — list leads without full=true (summary fields only)
  --skip-extractor          — skip lead extractor campaign ingestion
  --extractor-campaign-ids  — comma-separated extractor campaign IDs (overrides env registry)
  --dry-run                 — fetch from API but do not write to DB
  --limit-conversations N   — cap on conversations processed (smoke test)
  --account-ids id1,id2     — only ingest conversations for these SendPilot account IDs
                              (defaults to SENDPILOT_DASHBOARD_ACCOUNT_IDS env when set)
"""
from __future__ import annotations

import argparse
import logging
import random
import sys
import time
from datetime import datetime, timedelta, timezone
from typing import Iterator

import httpx
from supabase import Client, create_client

from ._common import (
    configure_logging,
    finish_run,
    getenv_optional,
    getenv_required,
    parse_iso8601,
    refresh_crm_extractor_from_sendpilot,
    refresh_crm_from_sendpilot,
    refresh_daily_metrics,
    refresh_inbox_derived,
    schema_preflight,
    start_run,
    utcnow,
)

log = configure_logging("ingest_sendpilot")

BASE_URL = "https://api.sendpilot.ai/v1"
DEFAULT_LOOKBACK_DAYS = 90
DERRICK_SENDPILOT_ACCOUNT_ID = "cmqm3xikx1mu02m01qark2e47"
PAGE_SIZE = 100
EXTRACTOR_PAGE_SIZE = 100
EXTRACTOR_DONE_STATUSES = frozenset(
    {"FINISHED", "finished", "completed", "COMPLETED", "Completed", "FINISHED".lower()}
)
EXTRACTOR_EXTERNAL_PREFIX = "extractor:"
MAX_CONSECUTIVE_429S = 5  # abort if SendPilot throttles us 5 times in a row
MAX_ATTEMPTS = 3          # retries for 5xx and network errors
BACKOFF_BASE_SECONDS = 2  # first retry waits ~2s, then ~4s, capped at 30s


# ---------------------------------------------------------------------------
# SendPilot HTTP client
# ---------------------------------------------------------------------------


class SendPilotError(Exception):
    """Base class for SendPilot API errors."""


class SendPilotAuthError(SendPilotError):
    """Raised on 401/403 — usually a missing or wrong API key."""


class SendPilotThrottled(SendPilotError):
    """Raised on 429 after we've exhausted our wait budget."""


def _sleep_backoff(attempt: int) -> None:
    """Exponential backoff with jitter, capped at 30s.

    attempt is 1-indexed: attempt=1 sleeps ~2s, attempt=2 sleeps ~4s.
    """
    delay = min(30, BACKOFF_BASE_SECONDS ** attempt) + random.uniform(0, 1)
    time.sleep(delay)


class SendPilotClient:
    """Thin wrapper around the SendPilot REST API.

    Pagination: conversations and messages use cursor-based pagination
    (`continuationToken` + `hasMore`). Campaigns and leads use page-based
    pagination (`page` + `totalPages`).

    Retry semantics:
      - Network errors (RequestError): up to MAX_ATTEMPTS, exponential backoff.
      - 5xx: up to MAX_ATTEMPTS, exponential backoff.
      - 429: inline retry, max MAX_CONSECUTIVE_429S consecutive. Sleeps
        Retry-After seconds (or 60 if absent). Resets counter on any 2xx.
      - 4xx other than 429: surface immediately (caller bug).
      - 401/403: surface immediately as SendPilotAuthError.
    """

    def __init__(self, api_key: str, base_url: str = BASE_URL):
        self._api_key = api_key
        self._base_url = base_url
        self._client = httpx.Client(
            base_url=base_url,
            headers={"X-API-Key": api_key, "Accept": "application/json"},
            timeout=httpx.Timeout(30.0, connect=10.0),
        )
        self._consecutive_429s = 0

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "SendPilotClient":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def _get(self, path: str, params: dict | None = None) -> dict:
        attempt = 0
        while attempt < MAX_ATTEMPTS:
            attempt += 1
            try:
                response = self._client.get(path, params=params)
            except httpx.RequestError as e:
                log.warning(
                    f"SendPilot {path} network error attempt {attempt}/{MAX_ATTEMPTS}: {e!r}"
                )
                if attempt >= MAX_ATTEMPTS:
                    raise
                _sleep_backoff(attempt)
                continue

            # 429: respect Retry-After, count consecutive throttles
            if response.status_code == 429:
                self._consecutive_429s += 1
                if self._consecutive_429s >= MAX_CONSECUTIVE_429S:
                    raise SendPilotThrottled(
                        f"throttled {self._consecutive_429s} times in a row; aborting"
                    )
                retry_after = int(response.headers.get("Retry-After", "60"))
                log.warning(
                    f"throttled; sleeping {retry_after}s per Retry-After header "
                    f"(consec={self._consecutive_429s})"
                )
                time.sleep(retry_after)
                # Loop without incrementing the 5xx attempt counter.
                attempt -= 1
                continue

            # 5xx: retry with exponential backoff
            if response.status_code >= 500:
                log.warning(
                    f"SendPilot {path} {response.status_code} attempt {attempt}/{MAX_ATTEMPTS}"
                )
                if attempt >= MAX_ATTEMPTS:
                    response.raise_for_status()
                _sleep_backoff(attempt)
                continue

            # 401/403: surface immediately
            if response.status_code in (401, 403):
                raise SendPilotAuthError(
                    f"SendPilot auth failed ({response.status_code}); check SENDPILOT_API_KEY"
                )

            # Other 4xx: surface with body
            if response.status_code >= 400:
                try:
                    payload = response.json()
                except Exception:  # noqa: BLE001
                    payload = response.text
                raise SendPilotError(
                    f"SendPilot {path} returned {response.status_code}: {payload}"
                )

            # 2xx: success
            self._consecutive_429s = 0
            return response.json()

        # Should be unreachable — the 5xx path raises if attempts are exhausted.
        raise SendPilotError(f"SendPilot {path} exhausted retries without success")

    # --- conversations ----------------------------------------------------

    def iter_conversations(self, *, since: datetime | None = None) -> Iterator[dict]:
        """Yield every conversation (or just those active after `since`)."""
        params: dict = {"limit": PAGE_SIZE}
        continuation: str | None = None
        while True:
            if continuation:
                params = {"limit": PAGE_SIZE, "continuationToken": continuation}
            data = self._get("/inbox/conversations", params=params)
            for conv in data.get("conversations", []):
                if since is not None:
                    last = parse_iso8601(conv.get("lastActivityAt"))
                    if last is not None and last < since:
                        continue
                yield conv
            pagination = data.get("pagination", {}) or {}
            if not pagination.get("hasMore"):
                return
            continuation = pagination.get("continuationToken")
            if not continuation:
                return

    def iter_messages(self, conversation_id: str, account_id: str) -> Iterator[dict]:
        """Yield every message in a conversation."""
        params: dict = {
            "accountId": account_id,
            "limit": PAGE_SIZE,
        }
        continuation: str | None = None
        path = f"/inbox/conversations/{conversation_id}/messages"
        while True:
            if continuation:
                params["continuationToken"] = continuation
            data = self._get(path, params=params)
            for msg in data.get("messages", []):
                yield msg
            pagination = data.get("pagination", {}) or {}
            if not pagination.get("hasMore"):
                return
            continuation = pagination.get("continuationToken")
            if not continuation:
                return

    # --- campaigns + leads -----------------------------------------------

    def iter_campaigns(self, status: str = "all") -> Iterator[dict]:
        """Yield every campaign. status is the SendPilot enum string."""
        page = 1
        while True:
            data = self._get(
                "/campaigns", params={"status": status, "page": page, "limit": PAGE_SIZE}
            )
            for camp in data.get("campaigns", []):
                yield camp
            pagination = data.get("pagination", {}) or {}
            if page >= pagination.get("totalPages", 1):
                return
            page += 1

    def iter_leads(self, campaign_id: str, *, full: bool = True) -> Iterator[dict]:
        """Yield every lead in a campaign."""
        page = 1
        while True:
            params: dict = {"campaignId": campaign_id, "page": page, "limit": PAGE_SIZE}
            if full:
                params["full"] = "true"
            data = self._get("/leads", params=params)
            for lead in data.get("leads", []):
                yield lead
            pagination = data.get("pagination", {}) or {}
            if page >= pagination.get("totalPages", 1):
                return
            page += 1

    def get_extractor_status(self, campaign_id: str) -> dict:
        """Fetch status for a lead extraction campaign."""
        return self._get(f"/lead-extractor/campaigns/{campaign_id}/status")

    def iter_extractor_results(self, campaign_id: str) -> Iterator[dict]:
        """Yield extracted leads (offset/limit pagination)."""
        offset = 0
        while True:
            data = self._get(
                f"/lead-extractor/campaigns/{campaign_id}/results",
                params={"offset": offset, "limit": EXTRACTOR_PAGE_SIZE},
            )
            leads = data.get("leads") or []
            for lead in leads:
                yield lead
            pagination = data.get("pagination") or {}
            has_more = pagination.get("has_more")
            if has_more is None:
                has_more = pagination.get("hasMore")
            if not has_more or not leads:
                return
            offset += len(leads)


# ---------------------------------------------------------------------------
# Supabase writer
# ---------------------------------------------------------------------------


def _participant(conv: dict) -> dict:
    parts = conv.get("participants") or []
    return parts[0] if parts else {}


def _last_message(conv: dict) -> dict:
    return conv.get("lastMessage") or {}


def upsert_campaign(sb: Client, camp: dict) -> str:
    """Upsert a campaign row; return its UUID.

    Uses PostgREST's Prefer: resolution=merge-duplicates, which is the
    supabase-py equivalent of `ON CONFLICT (external_id) DO UPDATE`.
    """
    payload = {
        "external_id": camp["id"],
        "name": camp["name"],
        "status": camp["status"],
        "total_leads": camp.get("totalLeads", 0) or 0,
        "connections_sent": camp.get("connectionsSent", 0) or 0,
        "messages_sent": camp.get("messagesSent", 0) or 0,
        "replies_received": camp.get("repliesReceived", 0) or 0,
        "created_at": camp.get("createdAt"),
        "updated_at": camp.get("updatedAt"),
        "campaign_type": "outreach",
    }
    response = (
        sb.table("sendpilot_campaigns")
        .upsert(payload, on_conflict="external_id")
        .execute()
    )
    return response.data[0]["id"]


def upsert_conversation(sb: Client, conv: dict) -> str:
    p = _participant(conv)
    lm = _last_message(conv)
    payload = {
        "external_id": conv["id"],
        "account_id": conv.get("accountId"),
        "lead_linkedin_id": p.get("id"),
        "lead_name": p.get("name"),
        "lead_profile_url": p.get("profileUrl"),
        "lead_profile_picture": p.get("profilePicture"),
        "lead_participant": p if p else {},
        "last_message_content": lm.get("content"),
        "last_message_sent_at": lm.get("sentAt"),
        "last_message_direction": lm.get("direction"),
        "last_activity_at": conv.get("lastActivityAt"),
        "unread_count": conv.get("unreadCount", 0) or 0,
        "created_at": conv.get("createdAt"),
        "updated_at": conv.get("updatedAt"),
    }
    response = (
        sb.table("sendpilot_conversations")
        .upsert(payload, on_conflict="external_id")
        .execute()
    )
    return response.data[0]["id"]


def upsert_message(sb: Client, msg: dict, conversation_uuid: str) -> bool:
    """Insert a message; return True iff a new row was created."""
    payload = {
        "sendpilot_message_id": msg.get("id"),
        "conversation_id": conversation_uuid,
        "direction": msg.get("direction"),
        "body": msg.get("body") or msg.get("content"),
        "sent_at": msg.get("sentAt"),
    }
    # supabase-py upsert always returns the row; for "insert if absent" we use
    # a tiny RPC. Until that's wired, we use an explicit insert + catch
    # the unique-violation error.
    try:
        sb.table("sendpilot_messages").insert(payload).execute()
        return True
    except Exception as e:  # noqa: BLE001
        # supabase-py raises a fresh exception class; the simplest reliable
        # check is to look for "duplicate" in the message. If we ever move
        # off supabase-py, replace this with psycopg + ON CONFLICT DO NOTHING.
        if "duplicate" in str(e).lower() or "unique" in str(e).lower() or "23505" in str(e):
            return False
        raise


def _lead_data_blob(lead: dict) -> dict:
    data = lead.get("data")
    return data if isinstance(data, dict) else {}


def _extract_lead_profile_fields(lead: dict) -> dict:
    """Map SendPilot full=true lead payload to sendpilot_leads profile columns."""
    data = _lead_data_blob(lead)
    industry = lead.get("industry") or data.get("industry")
    linkedin_headline = lead.get("headline") or data.get("headline") or data.get("linkedinHeadline")
    return {
        "about": lead.get("about"),
        "location": lead.get("location"),
        "industry": industry,
        "website_url": lead.get("website") or lead.get("websiteUrl"),
        "profile_picture_url": lead.get("profilePictureUrl") or lead.get("profilePicture"),
        "follower_count": lead.get("followerCount") if lead.get("followerCount") is not None else lead.get("followers"),
        "connection_count": lead.get("connectionCount") if lead.get("connectionCount") is not None else lead.get("connections"),
        "is_premium": lead.get("isPremium"),
        "is_open_profile": lead.get("isOpenProfile"),
        "custom_lead_status": lead.get("customLeadStatus"),
        "linkedin_headline": linkedin_headline,
        "raw_profile": lead,
    }


def upsert_lead(sb: Client, lead: dict, campaign_uuid: str) -> bool:
    profile = _extract_lead_profile_fields(lead)
    title = lead.get("title") or _lead_data_blob(lead).get("title")
    payload = {
        "external_id": lead["id"],
        "campaign_id": campaign_uuid,
        "linkedin_url": lead.get("linkedinUrl"),
        "first_name": lead.get("firstName"),
        "last_name": lead.get("lastName"),
        "email": lead.get("email"),
        "company": lead.get("company"),
        "title": title,
        "status": lead.get("status", "PENDING"),
        "created_at": lead.get("createdAt"),
        "updated_at": lead.get("updatedAt"),
        **profile,
    }
    try:
        sb.table("sendpilot_leads").upsert(payload, on_conflict="external_id").execute()
        return True
    except Exception as e:  # noqa: BLE001
        if "duplicate" in str(e).lower() or "23505" in str(e):
            return False
        raise


def _json_array(value: object) -> list:
    if isinstance(value, list):
        return value
    return []


def _compose_extractor_location(lead: dict) -> str | None:
    location = lead.get("location")
    if location:
        return str(location)
    parts = [lead.get("city"), lead.get("country")]
    joined = ", ".join(str(p) for p in parts if p)
    return joined or None


def _extract_extractor_lead_fields(lead: dict) -> dict:
    """Map Lead Extractor API payload to sendpilot_leads columns."""
    return {
        "about": lead.get("summary"),
        "location": _compose_extractor_location(lead),
        "profile_picture_url": lead.get("profile_picture_url"),
        "follower_count": lead.get("followers"),
        "connection_count": lead.get("connections"),
        "linkedin_headline": lead.get("headline"),
        "linkedin_identifier": lead.get("linkedin_identifier"),
        "phone": lead.get("phone"),
        "experience": _json_array(lead.get("experience")),
        "education": _json_array(lead.get("education")),
        "skills": _json_array(lead.get("skills")),
        "lead_source": "extractor",
        "raw_profile": lead,
    }


def upsert_extractor_campaign(sb: Client, status: dict) -> str:
    """Upsert extractor campaign metadata; return sendpilot_campaigns UUID."""
    external_id = status["id"]
    progress = status.get("progress") or {}
    now = utcnow().isoformat()
    payload = {
        "external_id": external_id,
        "name": status.get("name") or external_id,
        "status": status.get("status") or "unknown",
        "total_leads": progress.get("extracted") or progress.get("requested") or 0,
        "connections_sent": 0,
        "messages_sent": 0,
        "replies_received": 0,
        "created_at": status.get("created_at") or now,
        "updated_at": now,
        "campaign_type": "extractor",
        "extractor_progress": progress,
    }
    response = (
        sb.table("sendpilot_campaigns")
        .upsert(payload, on_conflict="external_id")
        .execute()
    )
    camp_uuid = response.data[0]["id"]
    sb.table("sendpilot_extractor_campaigns").upsert(
        {
            "external_id": external_id,
            "name": status.get("name"),
            "status": status.get("status"),
            "progress": progress,
            "sendpilot_campaign_id": camp_uuid,
            "updated_at": now,
        },
        on_conflict="external_id",
    ).execute()
    return camp_uuid


def upsert_extractor_lead(sb: Client, lead: dict, campaign_uuid: str) -> bool:
    profile = _extract_extractor_lead_fields(lead)
    lead_id = lead.get("id")
    if not lead_id:
        return False
    now = utcnow().isoformat()
    payload = {
        "external_id": f"{EXTRACTOR_EXTERNAL_PREFIX}{lead_id}",
        "campaign_id": campaign_uuid,
        "linkedin_url": lead.get("linkedin_url"),
        "first_name": lead.get("first_name"),
        "last_name": lead.get("last_name"),
        "email": lead.get("email"),
        "company": lead.get("company"),
        "title": lead.get("job_position"),
        "status": "EXTRACTED",
        "created_at": now,
        "updated_at": now,
        **profile,
    }
    try:
        sb.table("sendpilot_leads").upsert(payload, on_conflict="external_id").execute()
        return True
    except Exception as e:  # noqa: BLE001
        if "duplicate" in str(e).lower() or "23505" in str(e):
            return False
        raise


BATCH_SIZE = 100


def bulk_upsert_leads(
    sb: Client, lead_tuples: list[tuple[dict, str]]
) -> int:
    """Bulk upsert outreach leads into sendpilot_leads.

    Accepts a list of (lead_dict, campaign_uuid) tuples, builds payloads
    using the same _extract_lead_profile_fields() pattern as upsert_lead(),
    and does a single .upsert(rows, on_conflict='external_id').execute()
    per batch of BATCH_SIZE.  Returns the count of records written.
    """
    rows: list[dict] = []
    for lead, campaign_uuid in lead_tuples:
        profile = _extract_lead_profile_fields(lead)
        title = lead.get("title") or _lead_data_blob(lead).get("title")
        rows.append(
            {
                "external_id": lead["id"],
                "campaign_id": campaign_uuid,
                "linkedin_url": lead.get("linkedinUrl"),
                "first_name": lead.get("firstName"),
                "last_name": lead.get("lastName"),
                "email": lead.get("email"),
                "company": lead.get("company"),
                "title": title,
                "status": lead.get("status", "PENDING"),
                "created_at": lead.get("createdAt"),
                "updated_at": lead.get("updatedAt"),
                **profile,
            }
        )

    written = 0
    for i in range(0, len(rows), BATCH_SIZE):
        batch = rows[i : i + BATCH_SIZE]
        sb.table("sendpilot_leads").upsert(batch, on_conflict="external_id").execute()
        written += len(batch)
    return written


def bulk_upsert_extractor_leads(
    sb: Client, lead_tuples: list[tuple[dict, str]]
) -> int:
    """Bulk upsert extractor leads into sendpilot_leads.

    Same pattern as bulk_upsert_leads but uses _extract_extractor_lead_fields()
    and the extractor payload shape from upsert_extractor_lead().
    """
    now = utcnow().isoformat()
    rows: list[dict] = []
    for lead, campaign_uuid in lead_tuples:
        profile = _extract_extractor_lead_fields(lead)
        lead_id = lead.get("id")
        if not lead_id:
            continue
        rows.append(
            {
                "external_id": f"{EXTRACTOR_EXTERNAL_PREFIX}{lead_id}",
                "campaign_id": campaign_uuid,
                "linkedin_url": lead.get("linkedin_url"),
                "first_name": lead.get("first_name"),
                "last_name": lead.get("last_name"),
                "email": lead.get("email"),
                "company": lead.get("company"),
                "title": lead.get("job_position"),
                "status": "EXTRACTED",
                "created_at": now,
                "updated_at": now,
                **profile,
            }
        )

    written = 0
    for i in range(0, len(rows), BATCH_SIZE):
        batch = rows[i : i + BATCH_SIZE]
        sb.table("sendpilot_leads").upsert(batch, on_conflict="external_id").execute()
        written += len(batch)
    return written


def _parse_extractor_campaign_ids(raw: str | None) -> list[str]:
    if not raw or not raw.strip():
        return []
    return [s.strip() for s in raw.split(",") if s.strip()]


def _bootstrap_extractor_registry(sb: Client, campaign_ids: list[str]) -> None:
    now = utcnow().isoformat()
    for ext_id in campaign_ids:
        sb.table("sendpilot_extractor_campaigns").upsert(
            {"external_id": ext_id, "updated_at": now},
            on_conflict="external_id",
        ).execute()


def _list_extractor_campaign_ids(sb: Client) -> list[str]:
    rows = sb.table("sendpilot_extractor_campaigns").select("external_id").execute()
    return [r["external_id"] for r in (rows.data or [])]


def _extractor_is_done(status: str | None) -> bool:
    if not status:
        return False
    return status.upper() in {"FINISHED", "COMPLETED"}


def _should_sync_campaign(
    sb: Client, external_id: str, api_updated_at: str | None
) -> bool:
    """Check if a campaign has changed since the last sync.

    Returns True if the campaign should be synced (either it has never been
    synced, or the API's updatedAt is newer than last_synced_at).
    """
    if not api_updated_at:
        return True
    rows = (
        sb.table("sendpilot_campaigns")
        .select("last_synced_at")
        .eq("external_id", external_id)
        .execute()
    )
    if not rows.data:
        return True
    last_synced = rows.data[0].get("last_synced_at")
    if not last_synced:
        return True
    api_dt = parse_iso8601(api_updated_at)
    sync_dt = parse_iso8601(last_synced)
    if api_dt is None or sync_dt is None:
        return True
    return api_dt > sync_dt


def ingest_extractor_campaigns(
    sb: Client, client: SendPilotClient, args: argparse.Namespace
) -> int:
    """Pull lead extractor campaigns from registry; return records written."""
    env_ids = _parse_extractor_campaign_ids(getenv_optional("SENDPILOT_EXTRACTOR_CAMPAIGN_IDS"))
    cli_ids = _parse_extractor_campaign_ids(getattr(args, "extractor_campaign_ids", None))
    seed_ids = cli_ids or env_ids
    if seed_ids:
        _bootstrap_extractor_registry(sb, seed_ids)

    campaign_ids = _list_extractor_campaign_ids(sb)
    if not campaign_ids:
        log.info("no extractor campaigns registered (set SENDPILOT_EXTRACTOR_CAMPAIGN_IDS)")
        return 0

    written = 0
    for ext_id in campaign_ids:
        try:
            status = client.get_extractor_status(ext_id)
        except SendPilotError as e:
            log.warning(f"extractor status failed for {ext_id}: {e}")
            continue

        camp_uuid = upsert_extractor_campaign(sb, status)
        written += 1

        if not _extractor_is_done(status.get("status")):
            log.info(f"extractor {ext_id} status={status.get('status')!r}; skipping results")
            continue

        lead_count = 0
        leads_for_campaign: list[tuple[dict, str]] = []
        for lead in client.iter_extractor_results(ext_id):
            leads_for_campaign.append((lead, camp_uuid))
        if leads_for_campaign:
            written += bulk_upsert_extractor_leads(sb, leads_for_campaign)
            lead_count = len(leads_for_campaign)

        sb.table("sendpilot_extractor_campaigns").update(
            {"last_results_sync_at": utcnow().isoformat(), "updated_at": utcnow().isoformat()}
        ).eq("external_id", ext_id).execute()
        log.info(f"extractor {ext_id}: synced {lead_count} leads")

    refresh_crm_extractor_from_sendpilot(sb)
    return written


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------


def _parse_account_ids(raw: str | None) -> set[str] | None:
    if not raw or not raw.strip():
        return None
    ids = {s.strip() for s in raw.split(",") if s.strip()}
    return ids or None


def _resolve_account_filter(args: argparse.Namespace) -> set[str] | None:
    """Account IDs to ingest.

    Default is Derrick McMichael II's connected LinkedIn inbox/profile only.
    The SendPilot API key can see multiple synced accounts; do not ingest the
    org-wide inbox unless a human intentionally passes --account-ids for a
    one-off diagnostic run.
    """
    if args.account_ids:
        return _parse_account_ids(args.account_ids)
    env = getenv_optional("SENDPILOT_DASHBOARD_ACCOUNT_IDS")
    return _parse_account_ids(env) or {DERRICK_SENDPILOT_ACCOUNT_ID}


def _resolve_since(sb: Client, args: argparse.Namespace) -> datetime | None:
    """Decide the incremental cutoff.

    Priority: --since flag > --backfill flag (None) > max(last_activity_at) - 1h.
    """
    if args.since:
        return datetime.fromisoformat(args.since).replace(tzinfo=timezone.utc)
    if args.backfill:
        return utcnow() - timedelta(days=DEFAULT_LOOKBACK_DAYS)
    # Default: incremental from the most recent activity, with 1h overlap.
    response = (
        sb.table("sendpilot_conversations")
        .select("last_activity_at")
        .order("last_activity_at", desc=True)
        .limit(1)
        .execute()
    )
    if response.data:
        most_recent = parse_iso8601(response.data[0].get("last_activity_at"))
        if most_recent is not None:
            return most_recent - timedelta(hours=1)
    # Empty table — fall back to backfill
    log.info("no existing conversations; defaulting to 3-month backfill")
    return utcnow() - timedelta(days=DEFAULT_LOOKBACK_DAYS)


def run(args: argparse.Namespace) -> int:
    api_key = getenv_required("SENDPILOT_API_KEY")
    supabase_url = getenv_required("SUPABASE_URL")
    supabase_key = getenv_required("SUPABASE_SERVICE_ROLE_KEY")

    log.info("starting SendPilot ingestion")
    sb = create_client(supabase_url, supabase_key)

    # Pre-flight: ensure the schema + table exist (exit 3 with helpful message if not).
    schema_preflight(sb, "sendpilot")

    run_id = start_run(sb, "sendpilot")
    written = 0

    try:
        with SendPilotClient(api_key) as client:
            # 1. Campaigns + their leads
            for camp in client.iter_campaigns():
                camp_uuid = upsert_campaign(sb, camp)
                written += 1
                if not args.skip_leads:
                    if not _should_sync_campaign(sb, camp["id"], camp.get("updatedAt")):
                        log.info(
                            f"campaign {camp['id']} unchanged since last sync; "
                            "skipping lead fetch"
                        )
                    else:
                        lead_full = not args.skip_lead_enrichment
                        leads_for_campaign: list[tuple[dict, str]] = []
                        for lead in client.iter_leads(camp["id"], full=lead_full):
                            leads_for_campaign.append((lead, camp_uuid))
                        if leads_for_campaign:
                            written += bulk_upsert_leads(sb, leads_for_campaign)
                    # Mark the campaign as synced regardless (even if skipped,
                    # the campaign row itself was upserted above).
                    sb.table("sendpilot_campaigns").update(
                        {"last_synced_at": utcnow().isoformat()}
                    ).eq("external_id", camp["id"]).execute()

            # 1b. Lead extractor campaigns
            if not args.skip_extractor:
                written += ingest_extractor_campaigns(sb, client, args)

            # 2. Conversations + their messages
            since = _resolve_since(sb, args)
            account_filter = _resolve_account_filter(args)
            if account_filter:
                log.info(f"account filter active: {sorted(account_filter)}")
            log.info(f"pulling conversations since {since.isoformat() if since else 'beginning'}")
            conv_count = 0
            skipped_accounts = 0
            for conv in client.iter_conversations(since=since):
                if args.limit_conversations and conv_count >= args.limit_conversations:
                    log.info(f"--limit-conversations hit ({args.limit_conversations}); stopping")
                    break
                account_id = conv.get("accountId")
                if account_filter and account_id not in account_filter:
                    skipped_accounts += 1
                    continue
                conv_uuid = upsert_conversation(sb, conv)
                written += 1
                conv_count += 1
                if account_id:
                    for msg in client.iter_messages(conv["id"], account_id):
                        if upsert_message(sb, msg, conv_uuid):
                            written += 1
            if skipped_accounts:
                log.info(f"skipped {skipped_accounts} conversations outside account filter")

        # 3. Inbox denormalized flags + stats snapshot (migration 011)
        refresh_inbox_derived(sb)

        # 4. CRM contact sync from SendPilot (migration 013)
        refresh_crm_from_sendpilot(sb)

        # 5. Daily metrics for today
        today = utcnow().date()
        refresh_daily_metrics(sb, "sendpilot", today)

        finish_run(sb, run_id, records_written=written)
        log.info(f"OK: {written} records written")
        return 0
    except SendPilotAuthError as e:
        log.error(f"auth failed: {e}")
        finish_run(sb, run_id, error=f"auth: {e}")
        return 4
    except SendPilotThrottled as e:
        log.error(f"throttled: {e}")
        finish_run(sb, run_id, error=f"throttle: {e}")
        return 5
    except (SendPilotError, httpx.HTTPError) as e:
        log.exception(f"SendPilot API error: {e}")
        finish_run(sb, run_id, error=f"api: {e}")
        return 6
    except Exception as e:  # noqa: BLE001
        log.exception(f"unexpected error: {e}")
        finish_run(sb, run_id, error=f"unexpected: {e}")
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--since", help="ISO date (YYYY-MM-DD) for incremental backfill")
    parser.add_argument("--backfill", action="store_true", help="force 3-month backfill on every run")
    parser.add_argument("--skip-leads", action="store_true", help="skip lead ingestion")
    parser.add_argument(
        "--skip-lead-enrichment",
        action="store_true",
        help="fetch leads without full=true profile enrichment",
    )
    parser.add_argument("--limit-conversations", type=int, help="cap on conversations processed")
    parser.add_argument(
        "--account-ids",
        help="comma-separated SendPilot account IDs to ingest (overrides SENDPILOT_DASHBOARD_ACCOUNT_IDS env)",
    )
    parser.add_argument("--skip-extractor", action="store_true", help="skip lead extractor ingestion")
    parser.add_argument(
        "--extractor-campaign-ids",
        help="comma-separated lead extractor campaign IDs (seeds registry for this run)",
    )
    args = parser.parse_args()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
