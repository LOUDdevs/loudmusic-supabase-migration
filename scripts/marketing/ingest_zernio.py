#!/usr/bin/env python3
"""Zernio ingestion for the Central Marketing Dashboard.

Pulls posts and account metadata from the Zernio CLI (already authenticated
globally) and upserts them into the Supabase `marketing` schema.

Important: Zernio's analytics endpoints (impressions, reactions, comments,
follower growth) require a paid add-on. In v1 we only ingest post metadata
and DM inbox — engagement metrics are out of scope. See
/Hermes/Central Marketing Dashboard/inventory/api-feasibility.md for the
full analysis and the open question about the analytics upgrade.

Account → platform mapping (verified 2026-06-24):

  instagram          ← 6938b0def43160a0bc99aa9e (loudmusic.io)
  linkedin_org       ← 6938c494f43160a0bc99aab8 (LOUDmusic org page)
  linkedin_personal  ← 6a02a8a992b3d8e85fc95993 (Derrick McMichael II)
  facebook           ← 6938c6c3f43160a0bc99aaba (Artist Spotlight Accelerator)

Env contract (from ~/.hermes/.env, auto-loaded by _common):
  SUPABASE_URL              — required
  SUPABASE_SERVICE_ROLE_KEY — required

The `zernio` CLI is invoked directly; it carries its own auth and does not
need an env var on this side.

CLI flags:
  --since YYYY-MM-DD  — only ingest posts updated after this date
  --include-inbox     — also pull DM inbox (per-platform social DMs)
  --limit N           — cap on posts pulled (smoke test)
"""
from __future__ import annotations

import argparse
import json
import logging
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from typing import Any

from supabase import Client, create_client

from ._common import (
    configure_logging,
    finish_run,
    getenv_required,
    parse_iso8601,
    refresh_daily_metrics,
    schema_preflight,
    start_run,
    utcnow,
)

log = configure_logging("ingest_zernio")

# Account ID → our enum, from the zernio skill reference (verified 2026-06-24
# against `zernio accounts:list`).
ACCOUNT_TO_PLATFORM = {
    "6938b0def43160a0bc99aa9e": "instagram",
    "6938c494f43160a0bc99aab8": "linkedin_org",
    "6a02a8a992b3d8e85fc95993": "linkedin_personal",
    "6938c6c3f43160a0bc99aaba": "facebook",
}


# ---------------------------------------------------------------------------
# Zernio CLI wrapper
# ---------------------------------------------------------------------------


class ZernioError(Exception):
    """Raised when the zernio CLI fails or returns unparseable output."""


def _run_zernio(args: list[str], *, timeout: int = 120) -> Any:
    """Invoke the zernio CLI and return parsed JSON.

    Raises ZernioError on non-zero exit, timeout, or unparseable output.
    The CLI is interactive only via auth flow — every other subcommand is
    non-interactive and safe to call from a cron.
    """
    cmd = ["zernio", *args]
    log.debug(f"$ {' '.join(cmd)}")
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as e:
        raise ZernioError(
            "`zernio` CLI not found on PATH. Install via `npm i -g zernio` or check PATH."
        ) from e
    except subprocess.TimeoutExpired as e:
        raise ZernioError(f"zernio {' '.join(args)} timed out after {timeout}s") from e

    if result.returncode != 0:
        raise ZernioError(
            f"zernio {' '.join(args)} exited {result.returncode}: "
            f"stderr={result.stderr.strip()[:300]}"
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise ZernioError(
            f"zernio {' '.join(args)} returned non-JSON output: {result.stdout[:300]!r}"
        ) from e


def fetch_accounts() -> list[dict]:
    """List Zernio's connected social accounts."""
    return _run_zernio(["accounts:list"]).get("accounts", [])


def fetch_posts(
    *,
    since: datetime | None = None,
    status: str | None = None,
    page: int = 1,
    limit: int = 50,
) -> list[dict]:
    """Fetch one page of posts. Caller is responsible for paging."""
    args = ["posts:list", "--limit", str(limit), "--page", str(page)]
    if status:
        args += ["--status", status]
    if since:
        # Zernio expects ISO 8601; we use UTC with offset.
        args += ["--from", since.isoformat()]
    return _run_zernio(args).get("posts", [])


def fetch_inbox_conversations() -> list[dict]:
    """List DM conversations across all social platforms."""
    # The zernio CLI returns a list directly, not wrapped in an object.
    raw = _run_zernio(["inbox:conversations"])
    if isinstance(raw, list):
        return raw
    return raw.get("conversations", [])


# ---------------------------------------------------------------------------
# Supabase writer
# ---------------------------------------------------------------------------


def upsert_post(sb: Client, post: dict) -> bool:
    """Upsert one Zernio post. Returns True if a new row was written.

    A Zernio post can target multiple platforms (the `platforms` array).
    We split it into one row per platform because our schema is keyed on
    (platform, external_post_id) — different platforms may publish the
    same post content under different status / timing.
    """
    external_id = post.get("_id")
    if not external_id:
        log.warning(f"post missing _id; skipping: {post.get('title', '')[:60]!r}")
        return False

    content = post.get("content")
    media_urls = [m.get("url") for m in (post.get("mediaItems") or []) if m.get("url")]
    scheduled_for = parse_iso8601(post.get("scheduledFor"))
    # If the post has no per-platform publishedAt, fall back to updatedAt
    # for the "published" timestamp.
    default_published = parse_iso8601(post.get("updatedAt"))

    written = False
    for plat in post.get("platforms") or []:
        account = plat.get("accountId") or {}
        account_external_id = account.get("_id")
        if not account_external_id:
            continue
        platform = ACCOUNT_TO_PLATFORM.get(account_external_id)
        if not platform:
            log.debug(f"unknown zernio account {account_external_id}; skipping platform")
            continue
        # Per-platform status: prefer the platform row's `status`, fall back
        # to the post-level status field if present.
        per_platform_status = plat.get("status") or post.get("status", "unknown")
        published_at = (
            parse_iso8601(plat.get("publishedAt"))
            or default_published
            if per_platform_status == "published"
            else None
        )
        payload = {
            "external_post_id": external_id,
            "platform": platform,
            "account_external_id": account_external_id,
            "account_display_name": account.get("displayName"),
            "content": content,
            "media_urls": media_urls or None,
            "status": per_platform_status,
            "scheduled_for": scheduled_for.isoformat() if scheduled_for else None,
            "published_at": published_at.isoformat() if published_at else None,
            "created_at": post.get("createdAt"),
            "updated_at": post.get("updatedAt"),
        }
        try:
            sb.table("zernio_posts").upsert(payload, on_conflict="platform,external_post_id").execute()
            written = True
        except Exception as e:  # noqa: BLE001
            if "duplicate" in str(e).lower() or "23505" in str(e):
                continue
            raise
    return written


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------


def _resolve_since(sb: Client, args: argparse.Namespace) -> datetime | None:
    if args.since:
        return datetime.fromisoformat(args.since).replace(tzinfo=timezone.utc)
    # Default: incremental — last_synced_at in the DB, with 1h overlap.
    response = (
        sb.table("zernio_posts")
        .select("last_synced_at")
        .order("last_synced_at", desc=True)
        .limit(1)
        .execute()
    )
    if response.data:
        most_recent = parse_iso8601(response.data[0].get("last_synced_at"))
        if most_recent is not None:
            return most_recent - timedelta(hours=1)
    # No prior runs — pull last 30 days
    log.info("no existing zernio_posts; defaulting to 30-day backfill")
    return utcnow() - timedelta(days=30)


def run(args: argparse.Namespace) -> int:
    supabase_url = getenv_required("SUPABASE_URL")
    supabase_key = getenv_required("SUPABASE_SERVICE_ROLE_KEY")

    log.info("starting Zernio ingestion")
    sb = create_client(supabase_url, supabase_key)

    # Pre-flight: confirm the schema/table exist (exit 3 with helpful message if not).
    schema_preflight(sb, "zernio")

    # Always write a telemetry row so failures are visible in the dashboard.
    # start_run before the CLI check ensures even early failures land in
    # marketing.dashboard_ingestion_runs (visible to the FreshnessIndicator).
    run_id = start_run(sb, "zernio")

    try:
        accounts = fetch_accounts()
    except ZernioError as e:
        finish_run(sb, run_id, error=f"zernio CLI unavailable: {e}")
        log.error(f"zernio CLI unavailable: {e}")
        return 7
    log.info(f"zernio reports {len(accounts)} connected accounts")
    if not accounts:
        finish_run(sb, run_id, records_written=0)
        log.warning("zernio returned 0 accounts; nothing to ingest")
        return 0

    written = 0

    try:
        since = _resolve_since(sb, args)
        log.info(f"pulling posts since {since.isoformat() if since else 'beginning'}")

        # Page through all posts that match the filter. Zernio doesn't
        # expose a stable "updatedSince" parameter; we use --from (which
        # appears to filter on createdAt) and then filter client-side on
        # updatedAt for safety.
        page = 1
        page_size = 50
        total_pages = None
        while True:
            if args.limit and written >= args.limit:
                log.info(f"--limit {args.limit} hit; stopping")
                break
            try:
                posts = fetch_posts(since=since, page=page, limit=page_size)
            except ZernioError as e:
                log.error(f"zernio posts:list failed at page {page}: {e}")
                break
            if not posts:
                break
            for post in posts:
                updated_at = parse_iso8601(post.get("updatedAt"))
                if since is not None and updated_at is not None and updated_at < since:
                    continue
                if upsert_post(sb, post):
                    written += 1
                if args.limit and written >= args.limit:
                    break
            log.info(f"page {page}: {len(posts)} posts processed; total written: {written}")
            if len(posts) < page_size:
                break
            page += 1
            if total_pages is not None and page > total_pages:
                break

        # Optional: pull inbox conversations (DMs across all platforms)
        if args.include_inbox:
            try:
                convs = fetch_inbox_conversations()
                log.info(f"zernio inbox: {len(convs)} conversations (not persisted in v1)")
                # Future: persist into marketing.zernio_inbox table.
            except ZernioError as e:
                log.warning(f"zernio inbox failed (non-fatal): {e}")

        # Daily metrics for today
        refresh_daily_metrics(sb, "zernio", utcnow().date())

        finish_run(sb, run_id, records_written=written)
        log.info(f"OK: {written} records written")
        return 0
    except ZernioError as e:
        log.error(f"zernio CLI error: {e}")
        finish_run(sb, run_id, error=f"zernio: {e}")
        return 7
    except Exception as e:  # noqa: BLE001
        log.exception(f"unexpected error: {e}")
        finish_run(sb, run_id, error=f"unexpected: {e}")
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--since", help="ISO date (YYYY-MM-DD) for incremental cutoff")
    parser.add_argument("--include-inbox", action="store_true", help="also pull DM inbox")
    parser.add_argument("--limit", type=int, help="cap on posts ingested (smoke test)")
    args = parser.parse_args()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())

