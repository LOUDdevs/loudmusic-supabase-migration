#!/usr/bin/env python3
"""Probe SendPilot Lead Extractor API field names (read-only).

Usage:
  cd loudmusic-supabase && source .venv-marketing/bin/activate
  export SENDPILOT_EXTRACTOR_CAMPAIGN_IDS=camp_abc123
  python -m scripts.marketing.probe_sendpilot_extractor

Prints status + one results page and maps extractor keys to DB columns.
"""
from __future__ import annotations

import json
import sys

from ._common import configure_logging, getenv_optional, getenv_required
from .ingest_sendpilot import SendPilotClient

log = configure_logging("probe_sendpilot_extractor")

EXPECTED_MAP = {
    "external_id": ["id"],
    "linkedin_url": ["linkedin_url"],
    "linkedin_identifier": ["linkedin_identifier"],
    "first_name": ["first_name"],
    "last_name": ["last_name"],
    "linkedin_headline": ["headline"],
    "about": ["summary"],
    "title": ["job_position"],
    "company": ["company"],
    "location": ["location", "city", "country"],
    "profile_picture_url": ["profile_picture_url"],
    "follower_count": ["followers"],
    "connection_count": ["connections"],
    "email": ["email"],
    "phone": ["phone"],
    "experience": ["experience"],
    "education": ["education"],
    "skills": ["skills"],
}


def _keys(obj: dict) -> list[str]:
    return sorted(obj.keys())


def _parse_campaign_ids(raw: str | None) -> list[str]:
    if not raw or not raw.strip():
        return []
    return [s.strip() for s in raw.split(",") if s.strip()]


def _find_key(lead: dict, candidates: list[str]) -> str | None:
    for c in candidates:
        if c in lead and lead[c] not in (None, "", [], {}):
            return c
    return None


def main() -> int:
    api_key = getenv_required("SENDPILOT_API_KEY")
    campaign_ids = _parse_campaign_ids(getenv_optional("SENDPILOT_EXTRACTOR_CAMPAIGN_IDS"))
    if not campaign_ids:
        log.error("set SENDPILOT_EXTRACTOR_CAMPAIGN_IDS (comma-separated campaign IDs)")
        return 1

    camp_id = campaign_ids[0]
    with SendPilotClient(api_key) as client:
        log.info(f"probing extractor campaign {camp_id}")

        status = client.get_extractor_status(camp_id)
        log.info(f"status keys: {_keys(status)}")
        log.info(f"status={status.get('status')!r} name={status.get('name')!r}")
        progress = status.get("progress") or {}
        if progress:
            log.info(f"progress keys: {_keys(progress)}")

        results = client._get(
            f"/lead-extractor/campaigns/{camp_id}/results",
            params={"offset": 0, "limit": 1},
        )
        pagination = results.get("pagination") or {}
        log.info(f"pagination keys: {_keys(pagination)}")
        log.info(f"pagination: {pagination}")

        leads = results.get("leads") or []
        if not leads:
            log.warning("no leads in results (campaign may still be running)")
            print(json.dumps(status, indent=2, default=str))
            return 0

        lead = leads[0]
        log.info(f"lead keys: {_keys(lead)}")

        print("\n--- extractor field mapping probe ---")
        for db_col, candidates in EXPECTED_MAP.items():
            found = _find_key(lead, candidates)
            val = lead.get(found) if found else None
            if isinstance(val, list):
                preview = f"list[{len(val)}]"
            elif isinstance(val, str) and len(val) > 60:
                preview = val[:60] + "..."
            else:
                preview = val
            print(f"  {db_col}: api_key={found!r} sample={preview!r}")

        print("\n--- sample extractor lead (redacted) ---")
        redacted = {k: v for k, v in lead.items() if k not in ("email", "phone")}
        print(json.dumps(redacted, indent=2, default=str)[:2500])

    return 0


if __name__ == "__main__":
    sys.exit(main())
