#!/usr/bin/env python3
"""Semantic live tests for LOUDmusic Supabase REST and Edge Function APIs.

This script validates response correctness, not just HTTP liveness. It does not
print API keys.

Credential lookup order:
1. SUPABASE_URL + SUPABASE_ANON_KEY (+ optional SUPABASE_SERVICE_ROLE_KEY)
2. Linked Supabase project ref + `supabase projects api-keys` via CLI

Run:
  cd /home/derrick/loudmusic-supabase
  python3 scripts/smoke_test_supabase_apis.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
PROJECT_REF_FILE = ROOT / "supabase" / ".temp" / "project-ref"


def load_credentials() -> tuple[str, str, str | None]:
    env_url = os.environ.get("SUPABASE_URL")
    env_anon = os.environ.get("SUPABASE_ANON_KEY")
    env_service = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or os.environ.get("SUPABASE_SERVICE_KEY")
    if env_url and env_anon:
        return env_url.rstrip("/"), env_anon, env_service

    if not PROJECT_REF_FILE.exists():
        raise RuntimeError(
            "Missing SUPABASE_URL/SUPABASE_ANON_KEY and no linked project ref at "
            f"{PROJECT_REF_FILE}"
        )

    ref = PROJECT_REF_FILE.read_text().strip()
    raw = subprocess.check_output(
        ["supabase", "projects", "api-keys", "--project-ref", ref, "-o", "json"],
        cwd=ROOT,
        text=True,
    )
    keys = json.loads(raw)
    anon = next((k["api_key"] for k in keys if k.get("name") == "anon"), None)
    if not anon:
        anon = next((k["api_key"] for k in keys if k.get("type") in {"publishable", "legacy"}), None)
    service = next(
        (
            k["api_key"]
            for k in keys
            if (k.get("name") or "").lower().replace(" ", "_") == "service_role"
            or k.get("type") == "secret"
        ),
        None,
    )
    if not anon:
        raise RuntimeError("Could not locate anon/publishable Supabase API key via CLI")
    return f"https://{ref}.supabase.co", anon, service


def request(
    method: str,
    url: str,
    key: str,
    body: dict[str, Any] | list[dict[str, Any]] | None = None,
    extra_headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    if extra_headers:
        headers.update(extra_headers)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            text = resp.read().decode(errors="replace")
            return {
                "status": resp.status,
                "json": json.loads(text) if text else None,
                "text": text,
                "headers": dict(resp.headers),
            }
    except urllib.error.HTTPError as exc:
        text = exc.read().decode(errors="replace")
        try:
            parsed = json.loads(text) if text else None
        except Exception:
            parsed = text
        return {"status": exc.code, "json": parsed, "text": text, "headers": dict(exc.headers)}


def require_keys(row: dict[str, Any], keys: list[str]) -> None:
    missing = [key for key in keys if key not in row]
    assert not missing, f"missing keys {missing}; got keys={list(row)[:20]}"


def run_check(name: str, fn: Callable[[], str]) -> bool:
    try:
        detail = fn()
        print(f"PASS\t{name}\t{detail}")
        return True
    except AssertionError as exc:
        print(f"FAIL\t{name}\t{exc}")
        return False
    except Exception as exc:
        print(f"FAIL\t{name}\t{type(exc).__name__}: {exc}")
        return False


def main() -> int:
    base_url, anon_key, service_key = load_credentials()
    failures = 0
    print(f"Supabase semantic API test: {base_url}")

    def check(name: str, fn: Callable[[], str]) -> None:
        nonlocal failures
        if not run_check(name, fn):
            failures += 1

    def rest_studios_valid() -> str:
        resp = request(
            "GET",
            f"{base_url}/rest/v1/studios?select=id,slug,name,city,state,lat,lng&limit=5",
            anon_key,
            extra_headers={"Prefer": "count=exact"},
        )
        assert resp["status"] in {200, 206}, f"status={resp['status']} body={resp['text'][:300]}"
        data = resp["json"]
        assert isinstance(data, list) and data, "expected non-empty studio list"
        for row in data:
            require_keys(row, ["id", "slug", "name", "city", "state", "lat", "lng"])
            assert row["id"] and row["slug"] and row["name"], f"invalid identity fields: {row}"
            assert isinstance(row["lat"], (int, float)) and isinstance(row["lng"], (int, float)), row
        content_range = resp["headers"].get("content-range") or resp["headers"].get("Content-Range")
        assert content_range and "/" in content_range, f"missing count header: {resp['headers']}"
        count = int(content_range.rsplit("/", 1)[1])
        assert count > 10000, f"expected full studio dataset, got count={count}"
        return f"sample={len(data)} count={count} first={data[0]['slug']}"

    check("REST studios returns real records with required fields", rest_studios_valid)

    def edge_studio_directory_valid() -> str:
        list_resp = request("GET", f"{base_url}/functions/v1/studio-directory/api/studios", anon_key)
        assert list_resp["status"] == 200, f"status={list_resp['status']} body={list_resp['text'][:300]}"
        data = list_resp["json"]
        assert isinstance(data, list) and 0 < len(data) <= 100, f"bad list length: {len(data) if isinstance(data, list) else type(data)}"
        require_keys(data[0], ["id", "slug", "name", "city", "state"])

        slug = data[0]["slug"]
        single = request("GET", f"{base_url}/functions/v1/studio-directory/api/studio/{slug}", anon_key)
        assert single["status"] == 200, f"single status={single['status']} body={single['text'][:300]}"
        assert single["json"].get("id") == data[0]["id"] and single["json"].get("slug") == slug, "single route mismatch"

        q = urllib.parse.quote(data[0]["name"].split()[0])
        search = request("GET", f"{base_url}/functions/v1/studio-directory/api/search?q={q}", anon_key)
        assert search["status"] == 200, f"search status={search['status']} body={search['text'][:300]}"
        assert isinstance(search["json"], list) and search["json"], "expected query-relevant search results"
        return f"list={len(data)} single={slug} search={len(search['json'])}"

    check("Edge studio-directory list/single/search are semantically valid", edge_studio_directory_valid)

    def edge_nearby_real_filter() -> str:
        resp = request(
            "GET",
            f"{base_url}/functions/v1/studio-directory/api/nearby?lat=32.714512&lng=-117.155999&radius=5&limit=10",
            anon_key,
        )
        assert resp["status"] == 200, f"status={resp['status']} body={resp['text'][:300]}"
        data = resp["json"]
        assert isinstance(data, list), f"expected list, got {type(data).__name__}"
        assert data, "expected nearby studios around San Diego sample point"
        for row in data:
            require_keys(row, ["id", "slug", "name", "lat", "lng", "distance_miles"])
            assert row["distance_miles"] <= 5, f"row outside radius: {row['distance_miles']} > 5"
        distances = [row["distance_miles"] for row in data]
        assert distances == sorted(distances), f"nearby results not sorted by distance: {distances}"
        bad = request("GET", f"{base_url}/functions/v1/studio-directory/api/nearby?lat=bad&lng=-117&radius=5", anon_key)
        assert bad["status"] == 400, f"invalid coordinates should return 400, got {bad['status']}"
        return f"nearby={len(data)} closest={data[0]['slug']} distance={data[0]['distance_miles']}"

    check("Edge studio-directory nearby performs real radius filtering", edge_nearby_real_filter)

    def audio_health_and_placeholders() -> str:
        health = request("GET", f"{base_url}/functions/v1/audio-analysis/health", anon_key)
        assert health["status"] == 200 and health["json"] == {"status": "ok", "version": "0.2.0"}, health
        spotify = request(
            "POST",
            f"{base_url}/functions/v1/audio-analysis/api/analyze/spotify",
            anon_key,
            {"spotify_url": "https://open.spotify.com/track/test-smoke"},
        )
        assert spotify["status"] == 200, spotify
        require_keys(spotify["json"], ["spotify_url", "status", "message"])
        assert spotify["json"]["status"] == "not_implemented", spotify["json"]
        return "health exact; spotify placeholder exact"

    check("Edge audio-analysis health and Spotify placeholder are correct", audio_health_and_placeholders)

    def audio_analyze_auth_behavior() -> str:
        anon = request(
            "POST",
            f"{base_url}/functions/v1/audio-analysis/api/analyze",
            anon_key,
            {"track_url": "https://example.com/anon.mp3", "audio_id": "anon"},
        )
        assert anon["status"] == 401, f"anonymous analyze should be 401, got {anon['status']} {anon['text'][:300]}"
        if not service_key:
            return "anon denied with 401; service flow skipped because service key unavailable"
        audio_id = f"cleo-smoke-{uuid.uuid4().hex[:10]}"
        queued = request(
            "POST",
            f"{base_url}/functions/v1/audio-analysis/api/analyze",
            service_key,
            {"track_url": "https://example.com/cleo-smoke.mp3", "audio_id": audio_id},
        )
        assert queued["status"] == 200, f"service analyze status={queued['status']} body={queued['text'][:500]}"
        require_keys(queued["json"], ["job_id", "status", "message"])
        assert queued["json"]["status"] == "pending", queued["json"]
        job_id = queued["json"]["job_id"]
        result = request("GET", f"{base_url}/functions/v1/audio-analysis/api/results?job_id={job_id}", service_key)
        assert result["status"] == 200, f"result status={result['status']} body={result['text'][:500]}"
        require_keys(result["json"], ["id", "status", "audio_id", "track_url"])
        assert result["json"]["id"] == job_id and result["json"]["audio_id"] == audio_id, result["json"]
        deleted = request(
            "DELETE",
            f"{base_url}/rest/v1/analysis_jobs?id=eq.{job_id}",
            service_key,
            extra_headers={"Prefer": "return=representation"},
        )
        assert deleted["status"] in {200, 204}, f"cleanup status={deleted['status']} body={deleted['text'][:300]}"
        return f"anon denied; service queued/read/deleted job={job_id}"

    check("Edge audio-analysis analyze/results enforce auth and return correct job", audio_analyze_auth_behavior)

    def artist_rest_populated() -> str:
        resp = request(
            "GET",
            f"{base_url}/rest/v1/artist?select=id,spotify_id,chartmetric_id,name,genres,popularity,followers&limit=5",
            anon_key,
            extra_headers={"Prefer": "count=exact"},
        )
        assert resp["status"] in {200, 206}, f"status={resp['status']} body={resp['text'][:300]}"
        data = resp["json"]
        assert isinstance(data, list) and data, "artist table should be populated"
        for row in data:
            require_keys(row, ["id", "spotify_id", "chartmetric_id", "name", "genres", "popularity", "followers"])
            assert row["spotify_id"] and row["name"], f"bad artist identity: {row}"
        content_range = resp["headers"].get("content-range") or resp["headers"].get("Content-Range")
        assert content_range and content_range.endswith("/77"), f"expected 77 imported artists, got range={content_range}"
        return f"count=77 sample={data[0]['name']}"

    check("REST artist is populated with valid artist records", artist_rest_populated)

    def artist_edge_auth_behavior() -> str:
        listed = request("GET", f"{base_url}/functions/v1/artist-enrichment/api/artists", anon_key)
        assert listed["status"] == 200, f"list status={listed['status']} body={listed['text'][:300]}"
        data = listed["json"]
        assert isinstance(data, list) and data, "expected populated artist list"
        require_keys(data[0], ["id", "spotify_id", "name", "enhanced_at"])

        query = urllib.parse.quote(data[0]["name"].split()[0])
        searched = request("GET", f"{base_url}/functions/v1/artist-enrichment/api/artists/search?q={query}", anon_key)
        assert searched["status"] == 200 and isinstance(searched["json"], list) and searched["json"], searched

        forbidden = request(
            "POST",
            f"{base_url}/functions/v1/artist-enrichment/api/artists",
            anon_key,
            {"spotify_id": "forbidden-smoke", "name": "Forbidden Smoke"},
        )
        assert forbidden["status"] == 403, f"anon artist upsert should be 403, got {forbidden['status']} {forbidden['text'][:300]}"

        enrich = request(
            "POST",
            f"{base_url}/functions/v1/artist-enrichment/api/artists/enrich",
            anon_key,
            {"spotify_id": "anon-enrich", "chartmetric_id": "anon-enrich"},
        )
        assert enrich["status"] == 401, f"anon enrich should be 401, got {enrich['status']} {enrich['text'][:300]}"

        if not service_key:
            return "list/search populated; anon writes denied; service upsert skipped"
        smoke_id = f"cleo_smoke_{uuid.uuid4().hex[:12]}"
        upserted = request(
            "POST",
            f"{base_url}/functions/v1/artist-enrichment/api/artists",
            service_key,
            {"spotify_id": smoke_id, "chartmetric_id": f"cm_{smoke_id}", "name": "Cleo Smoke Test Artist"},
        )
        assert upserted["status"] == 200, f"service upsert status={upserted['status']} body={upserted['text'][:500]}"
        assert isinstance(upserted["json"], list) and upserted["json"][0]["spotify_id"] == smoke_id, upserted["json"]
        cleanup = request(
            "DELETE",
            f"{base_url}/rest/v1/artist?spotify_id=eq.{smoke_id}",
            service_key,
            extra_headers={"Prefer": "return=representation"},
        )
        assert cleanup["status"] in {200, 204}, f"cleanup status={cleanup['status']} body={cleanup['text'][:300]}"
        return f"list={len(data)} search={len(searched['json'])}; anon denied; service upsert cleanup={smoke_id}"

    check("Edge artist-enrichment is populated and write routes are protected", artist_edge_auth_behavior)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
