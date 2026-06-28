#!/usr/bin/env python3
"""Probe SendPilot full lead API field names (read-only).

Usage:
  cd loudmusic-supabase && source .venv-marketing/bin/activate
  python -m scripts.marketing.probe_sendpilot_lead_full

Prints top-level keys from summary vs full=true list responses and one GET by id.
"""
from __future__ import annotations

import json
import sys

from ._common import configure_logging, getenv_required
from .ingest_sendpilot import SendPilotClient

log = configure_logging("probe_sendpilot_lead_full")

# Keys we map to DB columns (for doc cross-check)
EXPECTED_MAP = {
    "about": ["about", "bio", "summary"],
    "location": ["location"],
    "industry": ["industry"],
    "website_url": ["website", "websiteUrl"],
    "profile_picture_url": ["profilePictureUrl", "profilePicture"],
    "follower_count": ["followers", "followerCount"],
    "connection_count": ["connections", "connectionCount"],
    "is_premium": ["isPremium", "premium"],
    "is_open_profile": ["isOpenProfile", "openProfile"],
    "custom_lead_status": ["customLeadStatus"],
    "linkedin_headline": ["headline", "linkedinHeadline"],
}


def _keys(obj: dict) -> list[str]:
    return sorted(obj.keys())


def _pick_first_campaign(client: SendPilotClient) -> str | None:
    data = client._get("/campaigns", params={"status": "all", "page": 1, "limit": 1})
    camps = data.get("campaigns") or []
    if not camps:
        return None
    return camps[0]["id"]


def _find_key(lead: dict, candidates: list[str]) -> str | None:
    for c in candidates:
        if c in lead and lead[c] not in (None, ""):
            return c
    return None


def main() -> int:
    api_key = getenv_required("SENDPILOT_API_KEY")
    with SendPilotClient(api_key) as client:
        camp_id = _pick_first_campaign(client)
        if not camp_id:
            log.error("no campaigns found")
            return 1
        log.info(f"using campaign {camp_id}")

        summary = client._get(
            "/leads", params={"campaignId": camp_id, "page": 1, "limit": 1}
        )
        full = client._get(
            "/leads",
            params={"campaignId": camp_id, "page": 1, "limit": 1, "full": "true"},
        )
        s_leads = summary.get("leads") or []
        f_leads = full.get("leads") or []
        if not f_leads:
            log.error("no leads in campaign")
            return 1

        s0 = s_leads[0] if s_leads else {}
        f0 = f_leads[0]
        lead_id = f0.get("id")
        log.info(f"summary keys: {_keys(s0)}")
        log.info(f"full=true keys: {_keys(f0)}")
        extra = set(_keys(f0)) - set(_keys(s0))
        if extra:
            log.info(f"extra in full=true: {sorted(extra)}")

        by_id = client._get(f"/leads/{lead_id}") if lead_id else {}
        if by_id:
            log.info(f"GET /leads/{{id}} keys: {_keys(by_id)}")

        print("\n--- field mapping probe ---")
        for db_col, candidates in EXPECTED_MAP.items():
            found = _find_key(f0, candidates)
            val = f0.get(found) if found else None
            preview = str(val)[:60] + "..." if val and len(str(val)) > 60 else val
            print(f"  {db_col}: api_key={found!r} sample={preview!r}")

        dynamic = f0.get("dynamicFields") or f0.get("customFields") or f0.get("dynamic")
        if dynamic:
            print(f"\n  dynamic/custom keys: {_keys(dynamic) if isinstance(dynamic, dict) else type(dynamic)}")

        print("\n--- sample full lead (redacted) ---")
        redacted = {k: v for k, v in f0.items() if k not in ("email", "linkedinUrl")}
        print(json.dumps(redacted, indent=2, default=str)[:2000])

    return 0


if __name__ == "__main__":
    sys.exit(main())
