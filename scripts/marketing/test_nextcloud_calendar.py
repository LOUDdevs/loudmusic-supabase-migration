#!/usr/bin/env python3
"""Test Nextcloud CalDAV connection and list available calendars."""
from __future__ import annotations

import json
import sys

from .nextcloud_caldav import test_connection


def main() -> int:
    calendar_name = sys.argv[1] if len(sys.argv) > 1 else None
    result = test_connection(calendar_name)
    print(json.dumps(result, indent=2))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
