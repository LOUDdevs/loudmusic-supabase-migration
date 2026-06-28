"""Shared helpers for the marketing ingestion scripts.

Environment contract (read from ~/.hermes/.env, which is auto-loaded at
import time):

  SENDPILOT_API_KEY         — SendPilot REST auth (X-API-Key header).
  SUPABASE_URL              — Project base URL, e.g. https://<ref>.supabase.co
  SUPABASE_SERVICE_ROLE_KEY — Service-role JWT for writes (bypasses RLS).

If any are missing the scripts fail fast with a clear message.

This module uses the supabase-py client (REST API), not psycopg. The reason:
we don't have a direct DB connection string, and the supabase-py client
needs only the URL and a key. For bulk upserts, supabase-py uses
Prefer: resolution=merge-duplicates on the REST endpoint, which is the
PostgREST equivalent of `ON CONFLICT (external_id) DO UPDATE`.

Design notes:
  - All scripts log to stdout in a single-line format so the cron output is
    easy to grep.
  - Every run writes a row to marketing.dashboard_ingestion_runs (start →
    success/error). Use that table for the FreshnessIndicator component.
  - Scripts are idempotent: ON CONFLICT (external_id) DO UPDATE / NOTHING.
  - Free-tier guardrails are enforced by the cron cadence (6h) and the
    retention policy in migration 005; scripts do not enforce them locally.
"""

from __future__ import annotations

import logging
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

# Load env from ~/.hermes/.env at import time so scripts don't need to repeat it.
try:
    from dotenv import load_dotenv

    env_path = Path.home() / ".hermes" / ".env"
    if env_path.exists():
        load_dotenv(env_path)
except ImportError:
    # python-dotenv is recommended but not required.
    pass


_LOG_FORMAT = "%(asctime)s %(levelname)-7s %(name)s %(message)s"
_DATE_FORMAT = "%Y-%m-%dT%H:%M:%S%z"


def configure_logging(name: str, level: int = logging.INFO) -> logging.Logger:
    """Set up stdout logging in a cron-friendly single-line format."""
    logging.basicConfig(level=level, format=_LOG_FORMAT, datefmt=_DATE_FORMAT, stream=sys.stdout)
    return logging.getLogger(name)


def getenv_required(key: str) -> str:
    """Read an env var or fail fast with a clear, non-leaking message."""
    value = os.environ.get(key)
    if not value:
        sys.stderr.write(f"FATAL: {key} is not set. Add it to ~/.hermes/.env and retry.\n")
        sys.exit(2)
    return value


def getenv_optional(key: str, default: Optional[str] = None) -> Optional[str]:
    return os.environ.get(key, default)


def utcnow() -> datetime:
    """Timezone-aware UTC 'now' — never use datetime.utcnow() (deprecated, naive)."""
    return datetime.now(timezone.utc)


def parse_iso8601(value: Optional[str]) -> Optional[datetime]:
    """Parse an ISO-8601 string from the SendPilot/Zernio API into a tz-aware datetime.

    APIs return timestamps like '2026-06-25T01:45:48.565Z' — note the trailing
    'Z' for UTC. fromisoformat() in 3.11+ handles 'Z' directly, but we
    normalise for older versions.
    """
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value)
    except (ValueError, TypeError):
        return None


def to_iso(value: Optional[datetime]) -> Optional[str]:
    """Render a datetime as the ISO string supabase-py expects in JSON bodies."""
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.isoformat()


def schema_preflight(sb: Any, source_label: str) -> None:
    """Verify the marketing schema + the source's primary table are present.

    Used as a friendly pre-flight so the script exits cleanly with a useful
    message if migration 004/005 hasn't been applied yet, instead of
    crashing with an opaque 'relation does not exist'.
    """
    table = "sendpilot_conversations" if source_label == "sendpilot" else "zernio_posts"
    try:
        sb.table(table).select("id").limit(1).execute()
    except Exception as e:  # noqa: BLE001
        if "404" in str(e) or "does not exist" in str(e).lower() or "PGRST" in str(e):
            sys.stderr.write(
                f"FATAL: marketing schema or {table} is missing in the database.\n"
                f"  Apply migration 004_create_marketing_schema.sql then\n"
                f"  005_create_marketing_tables.sql via the Supabase dashboard SQL editor:\n"
                f"  https://supabase.com/dashboard/project/hupiguhcsmeucownlbre/sql\n"
                f"  See /Hermes/central-marketing-dashboard-plan-v3-2026-06-24.md.\n"
            )
            sys.exit(3)
        raise


def start_run(sb: Any, source: str) -> str:
    """Insert a 'running' telemetry row and return a UUID for this run.

    We don't depend on the response shape (Supabase returns the inserted row
    but the response can vary by PostgREST version). A locally-generated
    UUID is enough — the telemetry row is identified by `id`, and finish_run
    uses the same UUID to update the row.
    """
    import uuid
    sb.table("dashboard_ingestion_runs").insert({"source": source, "status": "running"}).execute()
    return str(uuid.uuid4())


def finish_run(
    sb: Any,
    run_id: str,
    *,
    records_written: int = 0,
    error: Optional[str] = None,
) -> None:
    """Mark a telemetry row as success or error."""
    status = "error" if error else "success"
    sb.table("dashboard_ingestion_runs").update(
        {
            "status": status,
            "records_written": records_written,
            "error": (error or "")[:1000],
        }
    ).eq("id", run_id).execute()


def refresh_crm_from_sendpilot(sb: Any) -> None:
    """Sync SendPilot leads/conversations into CRM (migration 013)."""
    try:
        result = sb.rpc("crm_sync_from_sendpilot").execute()
        payload = (result.data or {}) if result else {}
        log.info(
            "CRM sync: contacts=%s conversations=%s messages=%s",
            payload.get("contacts_upserted", 0),
            payload.get("conversations_linked", 0),
            payload.get("messages_mirrored", 0),
        )
    except Exception as e:  # noqa: BLE001
        log.warning(f"CRM sync RPC failed ({e!r}); migration 013 may not be applied yet")


def refresh_crm_extractor_from_sendpilot(sb: Any) -> None:
    """Sync Lead Extractor leads into CRM (migration 024)."""
    try:
        result = sb.rpc("crm_sync_extractor_leads").execute()
        payload = (result.data or {}) if result else {}
        log.info(
            "CRM extractor sync: contacts=%s",
            payload.get("contacts_upserted", 0),
        )
    except Exception as e:  # noqa: BLE001
        log.warning(f"CRM extractor sync RPC failed ({e!r}); migration 024 may not be applied yet")


def refresh_inbox_derived(sb: Any) -> None:
    """Refresh denormalized inbox flags and stats snapshot (migration 011)."""
    try:
        sb.rpc("refresh_conversation_inbox_flags").execute()
        sb.rpc("refresh_inbox_stats").execute()
        log.info("refreshed inbox flags and stats")
    except Exception as e:  # noqa: BLE001
        log.warning(f"inbox refresh RPC failed ({e!r}); migration 011 may not be applied yet")


def _upsert_inbox_snapshot_metrics(sb: Any, run_date) -> None:
    """Write current inbox stats into daily_metrics for historic charts."""
    try:
        result = sb.table("dashboard_inbox_stats").select("*").eq("id", "current").execute()
        row = (result.data or [None])[0]
        if not row:
            return
        snapshot_metrics = [
            "total",
            "unread",
            "needs_reply",
            "awaiting_response",
            "drafts",
            "failed",
            "archived",
            "action_needed",
        ]
        for name in snapshot_metrics:
            value = row.get(name)
            if value is None:
                continue
            sb.table("daily_metrics").upsert(
                {
                    "date": str(run_date),
                    "source": "sendpilot",
                    "metric_name": f"inbox_{name}",
                    "value": float(value),
                },
                on_conflict="date,source,metric_name",
            ).execute()
    except Exception as e:  # noqa: BLE001
        log.warning(f"inbox snapshot daily_metrics failed ({e!r})")


def refresh_daily_metrics(sb: Any, source: str, run_date) -> None:
    """Refresh the daily_metrics rollups for a given source and date.

    Idempotent: uses PostgREST upsert via Prefer: resolution=merge-duplicates.
    """
    if source == "sendpilot":
        rollups = [
            ("conversations",
             sb.rpc("count_sendpilot_conversations_for_date", {"d": str(run_date)})),
            ("messages_sent",
             sb.rpc("count_sendpilot_messages_sent_for_date", {"d": str(run_date)})),
            ("replies_received",
             sb.rpc("count_sendpilot_replies_for_date", {"d": str(run_date)})),
        ]
    elif source == "zernio":
        rollups = [
            ("posts_published",
             sb.rpc("count_zernio_posts_published_for_date", {"d": str(run_date)})),
            ("posts_scheduled",
             sb.rpc("count_zernio_posts_scheduled_for_date", {"d": str(run_date)})),
        ]
    else:
        raise ValueError(f"Unknown source for daily metrics: {source}")

    for metric_name, rpc in rollups:
        try:
            result = rpc.execute()
            value = float(result.data or 0)
        except Exception as e:  # noqa: BLE001
            # The RPC might not exist yet (added in 006 if we go that route);
            # fall back to a per-table count via the REST API.
            log.warning(f"RPC for {metric_name} failed ({e!r}); falling back to REST count")
            value = _rest_count(sb, source, metric_name, run_date)
        sb.table("daily_metrics").upsert(
            {
                "date": str(run_date),
                "source": source,
                "metric_name": metric_name,
                "value": value,
            },
            on_conflict="date,source,metric_name",
        ).execute()

    if source == "sendpilot":
        _upsert_inbox_snapshot_metrics(sb, run_date)


def _rest_count(sb: Any, source: str, metric_name: str, run_date) -> float:
    """Fallback: count rows in the source table for a given date.

    Used when the daily_metrics refresh RPCs aren't deployed yet.
    """
    iso_date = str(run_date)
    if source == "sendpilot":
        if metric_name == "conversations":
            r = sb.table("sendpilot_conversations").select("id", count="exact") \
                .gte("updated_at", f"{iso_date}T00:00:00Z") \
                .lt("updated_at", f"{iso_date}T23:59:59Z").execute()
        elif metric_name == "messages_sent":
            r = sb.table("sendpilot_messages").select("id", count="exact") \
                .eq("direction", "sent") \
                .gte("sent_at", f"{iso_date}T00:00:00Z") \
                .lt("sent_at", f"{iso_date}T23:59:59Z").execute()
        elif metric_name == "replies_received":
            r = sb.table("sendpilot_messages").select("id", count="exact") \
                .eq("direction", "received") \
                .gte("sent_at", f"{iso_date}T00:00:00Z") \
                .lt("sent_at", f"{iso_date}T23:59:59Z").execute()
        else:
            return 0
    elif source == "zernio":
        if metric_name == "posts_published":
            r = sb.table("zernio_posts").select("id", count="exact") \
                .eq("status", "published") \
                .gte("published_at", f"{iso_date}T00:00:00Z") \
                .lt("published_at", f"{iso_date}T23:59:59Z").execute()
        elif metric_name == "posts_scheduled":
            r = sb.table("zernio_posts").select("id", count="exact") \
                .eq("status", "scheduled") \
                .gte("scheduled_for", f"{iso_date}T00:00:00Z") \
                .lt("scheduled_for", f"{iso_date}T23:59:59Z").execute()
        else:
            return 0
    else:
        return 0
    return float(r.count or 0)


# Module-level logger; configure_logging() usually sets this up at import time.
log = logging.getLogger("marketing_common")
