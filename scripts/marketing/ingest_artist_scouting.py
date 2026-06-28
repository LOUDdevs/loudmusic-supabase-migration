#!/usr/bin/env python3
"""Ingest artist scouting CSV from Hermes into Supabase."""
from __future__ import annotations

import csv
import sys
from datetime import datetime, timezone
from pathlib import Path

from supabase import create_client

from ._common import configure_logging, getenv_required

log = configure_logging("ingest_artist_scouting")

DEFAULT_CSV = Path.home() / "Hermes" / "scouting" / "loudmusic_daily_artist_scouting_latest.csv"

INT_FIELDS = ("spotify_monthly_listeners",)


def _num(val: str | None):
    if val is None or val == "":
        return None
    try:
        return float(val)
    except ValueError:
        return None


def _int(val: str | None):
    n = _num(val)
    return int(n) if n is not None else None


def ingest(csv_path: Path) -> int:
    if not csv_path.exists():
        log.warning(f"CSV not found: {csv_path}")
        return 0

    sb = create_client(getenv_required("SUPABASE_URL"), getenv_required("SUPABASE_SERVICE_ROLE_KEY"))

    with csv_path.open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))

    run = sb.table("artist_scouting_runs").insert({
        "source_file": str(csv_path),
        "candidate_count": len(rows),
        "ingested_at": datetime.now(timezone.utc).isoformat(),
    }).execute()
    run_id = (run.data or [{}])[0].get("id")

    upserted = 0
    for row in rows:
        cm_id = (row.get("chartmetric_id") or "").strip()
        name = (row.get("artist") or row.get("artist_name") or "").strip()
        if not cm_id or not name:
            continue
        payload = {
            "run_id": run_id,
            "chartmetric_id": cm_id,
            "artist_name": name,
            "fit_score": _num(row.get("fit_score")),
            "recommended_action": row.get("recommended_action") or None,
            "independence_class": row.get("independence_class") or None,
            "genres": row.get("genres") or None,
            "country": row.get("country") or None,
            "city": row.get("city") or None,
            "career_stage": row.get("career_stage") or None,
            "spotify_url": row.get("spotify_url") or None,
            "instagram_url": row.get("instagram_url") or None,
            "tiktok_url": row.get("tiktok_url") or None,
            "youtube_url": row.get("youtube_url") or None,
            "soundcloud_url": row.get("soundcloud_url") or None,
            "chartmetric_url": row.get("chartmetric_url") or None,
            "growth_30d_pct": _num(row.get("growth_30d_pct")),
            "spotify_monthly_listeners": _int(row.get("spotify_monthly_listeners")),
            "raw_data": row,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        sb.table("artist_scouting_candidates").upsert(payload, on_conflict="chartmetric_id").execute()
        upserted += 1

    log.info(f"upserted {upserted} scouting candidates from {csv_path.name}")
    return upserted


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV)
    args = parser.parse_args()
    try:
        ingest(args.csv)
        return 0
    except Exception as e:
        log.exception(f"ingest failed: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
