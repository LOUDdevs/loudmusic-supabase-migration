#!/usr/bin/env python3
"""Test Nextcloud CalDAV connection and push path (PROPFIND + PUT/DELETE)."""
from __future__ import annotations

import json
import sys

from .nextcloud_caldav import test_caldav_push_path


def main() -> int:
    cal_name = sys.argv[1] if len(sys.argv) > 1 else None
    result = test_caldav_push_path(cal_name)
    print(json.dumps(result))
    if not result.get("ok"):
        return 2
    if not result.get("push_ok"):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
