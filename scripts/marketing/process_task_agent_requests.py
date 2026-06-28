#!/usr/bin/env python3
"""Process pending task_agent_requests from the marketing dashboard ops platform.

Polls marketing.task_agent_requests where status IN ('pending', 'sent'),
runs the generated prompt through OpenRouter, and stores agent_response.

Exit codes:
  0 — processed zero or more requests
  1 — unexpected error
  2 — missing env
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone

from supabase import create_client

from ._common import configure_logging, getenv_required
from .process_ai_jobs import _openrouter_script, run_openrouter

log = configure_logging("process_task_agent_requests")


def process_requests(limit: int = 5) -> int:
    supabase_url = getenv_required("SUPABASE_URL")
    supabase_key = getenv_required("SUPABASE_SERVICE_ROLE_KEY")
    sb = create_client(supabase_url, supabase_key)

    try:
        _openrouter_script()
    except FileNotFoundError as e:
        log.error(str(e))
        return 1

    pending = (
        sb.table("task_agent_requests")
        .select("*")
        .in_("status", ["pending", "sent"])
        .order("created_at")
        .limit(limit)
        .execute()
    )
    rows = pending.data or []
    if not rows:
        log.info("no pending task agent requests")
        return 0

    processed = 0
    for row in rows:
        req_id = row["id"]
        prompt = row.get("generated_prompt") or ""
        if not prompt.strip():
            sb.table("task_agent_requests").update({
                "status": "failed",
                "agent_response": "Empty generated_prompt",
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }).eq("id", req_id).execute()
            continue

        sb.table("task_agent_requests").update({
            "status": "sent",
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }).eq("id", req_id).execute()

        try:
            response = run_openrouter("rewrite", prompt)
            sb.table("task_agent_requests").update({
                "status": "completed",
                "agent_response": response[:20000],
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }).eq("id", req_id).execute()
            processed += 1
            log.info(f"request {req_id} completed")
        except Exception as e:
            log.exception(f"request {req_id} failed: {e}")
            sb.table("task_agent_requests").update({
                "status": "failed",
                "agent_response": str(e)[:2000],
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }).eq("id", req_id).execute()

    log.info(f"processed {processed}/{len(rows)} task agent requests")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=5)
    args = parser.parse_args()
    try:
        return process_requests(limit=args.limit)
    except Exception as e:
        log.exception(f"unexpected: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
