"""Weekly marketing digest generator.

Runs every Monday at 09:00 EST (scheduled via Hermes cron). Aggregates the
last 7 days of SendPilot + Zernio data from Supabase and produces a
markdown digest saved to Nextcloud `/Hermes/Central Marketing Dashboard/reports/`.

Usage:
    python -m scripts.marketing.weekly_digest [--week-of YYYY-MM-DD]

Reads SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY from ~/.hermes/.env.
Writes the markdown report to Nextcloud via the WebDAV MCP API.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from supabase import create_client

from scripts.marketing._common import configure_logging, getenv_required, parse_iso8601

log = configure_logging("weekly_digest")

NEXTCLOUD_REPORTS_PATH = "/Hermes/Central Marketing Dashboard/reports"


def _monday_of(week_of: datetime) -> datetime:
    """Return the Monday (00:00 UTC) of the ISO week containing `week_of`."""
    return (week_of - timedelta(days=week_of.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0, tzinfo=timezone.utc
    )


def _query_sendpilot_week(sb, week_start: datetime) -> dict:
    """Aggregate SendPilot activity between week_start and week_start+7d."""
    week_end = week_start + timedelta(days=7)
    iso_start = week_start.isoformat()
    iso_end = week_end.isoformat()

    campaigns = sb.table("sendpilot_campaigns").select("id,name,status,total_leads,connections_sent,messages_sent,replies_received").execute().data or []
    convos_7d = (
        sb.table("sendpilot_conversations")
        .select("id", count="exact")
        .gte("last_activity_at", iso_start)
        .lt("last_activity_at", iso_end)
        .execute()
    )
    replies_7d = (
        sb.table("sendpilot_messages")
        .select("id", count="exact")
        .eq("direction", "received")
        .gte("sent_at", iso_start)
        .lt("sent_at", iso_end)
        .execute()
    )
    sent_7d = (
        sb.table("sendpilot_messages")
        .select("id", count="exact")
        .eq("direction", "sent")
        .gte("sent_at", iso_start)
        .lt("sent_at", iso_end)
        .execute()
    )

    return {
        "campaigns": campaigns,
        "conversations_7d": convos_7d.count or 0,
        "replies_7d": replies_7d.count or 0,
        "messages_sent_7d": sent_7d.count or 0,
        "reply_rate": (replies_7d.count or 0) / max(1, convos_7d.count or 0),
        "campaign_count_active": sum(1 for c in campaigns if c.get("status") == "started"),
    }


def _query_zernio_week(sb, week_start: datetime) -> dict:
    week_end = week_start + timedelta(days=7)
    iso_start = week_start.isoformat()
    iso_end = week_end.isoformat()

    accounts = sb.table("zernio_accounts").select("external_id,platform,display_name,is_active").eq("is_active", True).execute().data or []
    published = (
        sb.table("zernio_posts")
        .select("id,platform", count="exact")
        .eq("status", "published")
        .gte("published_at", iso_start)
        .lt("published_at", iso_end)
        .execute()
    )
    scheduled = (
        sb.table("zernio_posts")
        .select("id,platform", count="exact")
        .eq("status", "scheduled")
        .gte("scheduled_for", iso_start)
        .lt("scheduled_for", iso_end)
        .execute()
    )
    failed = (
        sb.table("zernio_posts")
        .select("id", count="exact")
        .eq("status", "failed")
        .gte("updated_at", iso_start)
        .lt("updated_at", iso_end)
        .execute()
    )

    by_platform_published: dict[str, int] = {}
    for row in published.data or []:
        by_platform_published[row["platform"]] = by_platform_published.get(row["platform"], 0) + 1

    return {
        "connected_accounts": accounts,
        "published_7d": published.count or 0,
        "scheduled_7d": scheduled.count or 0,
        "failed_7d": failed.count or 0,
        "by_platform_published": by_platform_published,
    }


def _query_reachinbox_week(sb, week_start: datetime) -> dict:
    """Aggregate ReachInbox warmup + campaign replies for the week."""
    week_end = week_start + timedelta(days=7)
    iso_start = week_start.isoformat()
    iso_end = week_end.isoformat()

    accounts = (
        sb.table("reachinbox_accounts")
        .select("id,email,domain,warmup_enabled,health_score")
        .execute()
        .data
        or []
    )
    campaigns = (
        sb.table("reachinbox_campaigns")
        .select("id,name,status,total_email_sent,total_email_replied")
        .execute()
        .data
        or []
    )
    replies_7d = (
        sb.table("reachinbox_messages")
        .select("id", count="exact")
        .eq("direction", "inbound")
        .gte("sent_at", iso_start)
        .lt("sent_at", iso_end)
        .execute()
    )

    warmed = sum(1 for a in accounts if a.get("warmup_enabled") and (a.get("health_score") or 0) >= 70)
    warming = sum(
        1
        for a in accounts
        if a.get("warmup_enabled") and (a.get("health_score") is None or (a.get("health_score") or 0) < 70)
    )

    return {
        "accounts": accounts,
        "campaigns": campaigns,
        "mailbox_count": len(accounts),
        "warmed": warmed,
        "warming": warming,
        "replies_7d": replies_7d.count or 0,
        "campaign_count_active": sum(1 for c in campaigns if c.get("status") == "started"),
        "total_sent": sum(c.get("total_email_sent") or 0 for c in campaigns),
        "total_replied": sum(c.get("total_email_replied") or 0 for c in campaigns),
    }


def _render_markdown(week_start: datetime, sendpilot: dict, zernio: dict, reachinbox: dict) -> str:
    week_end = week_start + timedelta(days=6)
    pct = lambda x: f"{(x * 100):.1f}%"
    md = [
        f"# Weekly Marketing Digest · {week_start.strftime('%Y-%m-%d')} → {week_end.strftime('%Y-%m-%d')}",
        "",
        f"_Generated {datetime.now(timezone.utc).isoformat()}_",
        "",
        "## SendPilot (last 7 days)",
        "",
        f"- **Active campaigns:** {sendpilot['campaign_count_active']}",
        f"- **Conversations (active):** {sendpilot['conversations_7d']:,}",
        f"- **Messages sent:** {sendpilot['messages_sent_7d']:,}",
        f"- **Replies received:** {sendpilot['replies_7d']:,}",
        f"- **Reply rate:** {pct(sendpilot['reply_rate'])}",
        "",
        "### Top campaigns by replies",
        "",
        "| Campaign | Leads | Sent | Replies | Reply rate |",
        "|---|---:|---:|---:|---:|",
    ]
    top = sorted(sendpilot["campaigns"], key=lambda c: c.get("replies_received") or 0, reverse=True)[:10]
    for c in top:
        conns = c.get("messages_sent") or 0
        reps = c.get("replies_received") or 0
        rate = reps / max(1, conns)
        md.append(
            f"| {c.get('name', '—')} | {c.get('total_leads', 0):,} | {conns:,} | {reps:,} | {pct(rate)} |"
        )
    md += [
        "",
        "## Zernio (last 7 days)",
        "",
        f"- **Connected accounts:** {len(zernio['connected_accounts'])}",
        f"- **Published:** {zernio['published_7d']}",
        f"- **Scheduled for next 7d:** {zernio['scheduled_7d']}",
        f"- **Failed posts:** {zernio['failed_7d']}",
        "",
        "### Published by platform",
        "",
    ]
    if zernio["by_platform_published"]:
        for platform, count in sorted(zernio["by_platform_published"].items(), key=lambda x: -x[1]):
            md.append(f"- **{platform}**: {count}")
    else:
        md.append("_Nothing published this week._")
    md += [
        "",
        "## ReachInbox (last 7 days)",
        "",
        f"- **Mailboxes:** {reachinbox['mailbox_count']}",
        f"- **Warmed / warming:** {reachinbox['warmed']} / {reachinbox['warming']}",
        f"- **Active campaigns:** {reachinbox['campaign_count_active']}",
        f"- **Onebox replies (7d):** {reachinbox['replies_7d']:,}",
        f"- **Campaign replies (lifetime):** {reachinbox['total_replied']:,}",
        "",
        "## Next 7 days outlook",
        "",
        f"- SendPilot: {sendpilot['campaign_count_active']} active campaigns continue running.",
        f"- ReachInbox: {reachinbox['warmed']} warmed mailboxes; Hermes ramp cron continues daily batches.",
        f"- Zernio: {zernio['scheduled_7d']} posts scheduled.",
        "",
        "---",
        "",
        f"Open the live dashboard: https://dashboard.loudmusic.io",
    ]
    return "\n".join(md) + "\n"


def _write_to_nextcloud_via_local(path: str, content: str) -> None:
    """Write the digest to a local path that the Nextcloud sync daemon picks up.

    The Nextcloud desktop client keeps `/home/derrick/Nextcloud/` in sync with
    the server. Writing to the matching local path is more reliable than
    going through WebDAV from a cron context (no credentials to manage).

    If the local sync directory doesn't exist, we fall back to writing to
    /tmp and printing the path for manual upload.
    """
    home = Path.home()
    candidates = [
        home / "Nextcloud" / path.lstrip("/"),
        home / "nextcloud" / path.lstrip("/"),
    ]
    for c in candidates:
        if c.parent.exists():
            c.parent.mkdir(parents=True, exist_ok=True)
            c.write_text(content, encoding="utf-8")
            log.info(f"wrote digest to {c}")
            return
    fallback = Path("/tmp") / Path(path).name
    fallback.write_text(content, encoding="utf-8")
    log.warning(
        f"No Nextcloud local sync dir found. Wrote digest to {fallback} — copy it manually."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate weekly marketing digest.")
    parser.add_argument(
        "--week-of",
        default=datetime.now(timezone.utc).date().isoformat(),
        help="Any date inside the target week (ISO YYYY-MM-DD). Default: today.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Render to stdout instead of writing to Nextcloud.",
    )
    args = parser.parse_args()

    week_of_dt = datetime.fromisoformat(args.week_of).replace(tzinfo=timezone.utc)
    week_start = _monday_of(week_of_dt)
    log.info(f"Generating digest for week starting {week_start.date().isoformat()}")

    supabase_url = getenv_required("SUPABASE_URL")
    supabase_key = getenv_required("SUPABASE_SERVICE_ROLE_KEY")
    sb = create_client(supabase_url, supabase_key)

    sendpilot = _query_sendpilot_week(sb, week_start)
    zernio = _query_zernio_week(sb, week_start)
    reachinbox = _query_reachinbox_week(sb, week_start)
    md = _render_markdown(week_start, sendpilot, zernio, reachinbox)

    if args.dry_run:
        sys.stdout.write(md)
        return 0

    filename = f"weekly-digest-{week_start.strftime('%Y-%m-%d')}.md"
    report_path = f"{NEXTCLOUD_REPORTS_PATH}/{filename}"
    _write_to_nextcloud_via_local(report_path, md)

    summary = {
        "total_conversations": sendpilot.get("conversations_7d", 0),
        "reply_rate": sendpilot.get("reply_rate", 0),
        "posts_published": zernio.get("by_platform_published", {}),
    }
    sb.table("weekly_digests").insert({
        "week_start": week_start.date().isoformat(),
        "file_path": report_path,
        "summary_json": summary,
    }).execute()
    log.info(f"recorded weekly digest metadata for {week_start.date().isoformat()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())