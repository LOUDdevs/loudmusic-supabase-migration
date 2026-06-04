#!/usr/bin/env python3
"""Smoke-test LOUDmusic Supabase REST and Edge Function APIs.

This script intentionally does not print API keys.
Credential lookup order:
1. SUPABASE_URL + SUPABASE_ANON_KEY from environment
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
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PROJECT_REF_FILE = ROOT / "supabase" / ".temp" / "project-ref"


@dataclass
class Check:
    name: str
    method: str
    url: str
    body: dict[str, Any] | None = None
    expect_status: int = 200


def load_credentials() -> tuple[str, str]:
    env_url = os.environ.get("SUPABASE_URL")
    env_key = os.environ.get("SUPABASE_ANON_KEY")
    if env_url and env_key:
        return env_url.rstrip("/"), env_key

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
    if not anon:
        raise RuntimeError("Could not locate anon/publishable Supabase API key via CLI")
    return f"https://{ref}.supabase.co", anon


def summarize_response(raw: bytes, content_type: str) -> str:
    if "json" in content_type:
        try:
            parsed = json.loads(raw.decode())
        except Exception:
            return raw[:160].decode(errors="replace")
        if isinstance(parsed, list):
            return f"list_len={len(parsed)}"
        if isinstance(parsed, dict):
            return "keys=" + ",".join(list(parsed.keys())[:8])
        return type(parsed).__name__
    return raw[:160].decode(errors="replace")


def run_check(check: Check, anon_key: str) -> tuple[bool, str]:
    headers = {
        "apikey": anon_key,
        "Authorization": f"Bearer {anon_key}",
    }
    data = None
    if check.body is not None:
        data = json.dumps(check.body).encode()
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(check.url, data=data, headers=headers, method=check.method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read(5000)
            detail = summarize_response(raw, resp.headers.get("content-type", ""))
            ok = resp.status == check.expect_status
            return ok, f"{resp.status} {detail}"
    except urllib.error.HTTPError as exc:
        raw = exc.read(1000).decode(errors="replace").replace(anon_key, "[REDACTED]")
        ok = exc.code == check.expect_status
        return ok, f"{exc.code} {raw[:240]}"
    except Exception as exc:
        return False, repr(exc)


def main() -> int:
    base_url, anon_key = load_credentials()
    checks = [
        Check("REST studios select", "GET", f"{base_url}/rest/v1/studios?select=id,slug,name&limit=1"),
        Check("REST artist select", "GET", f"{base_url}/rest/v1/artist?select=id,spotify_id,name&limit=1"),
        Check("REST analysis_jobs select", "GET", f"{base_url}/rest/v1/analysis_jobs?select=id,status&limit=1"),
        Check("Edge audio-analysis health", "GET", f"{base_url}/functions/v1/audio-analysis/health"),
        Check("Edge studio-directory list", "GET", f"{base_url}/functions/v1/studio-directory/api/studios"),
        Check("Edge artist-enrichment list", "GET", f"{base_url}/functions/v1/artist-enrichment/api/artists"),
    ]

    failures = 0
    print(f"Supabase API smoke test: {base_url}")
    for check in checks:
        ok, detail = run_check(check, anon_key)
        marker = "PASS" if ok else "FAIL"
        print(f"{marker}\t{check.name}\t{detail}")
        failures += 0 if ok else 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
