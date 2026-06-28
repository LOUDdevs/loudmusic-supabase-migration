#!/usr/bin/env python3
"""Sync Nextcloud Deck cards with marketing dashboard ops task fix lifecycle."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Any

BOARD_ID = 43
STACK_TRIAGE = 149
STACK_READY = 151
STACK_IN_PROGRESS = 152
STACK_BLOCKED = 153
STACK_DONE = 150

OPEN_STACKS = [STACK_TRIAGE, STACK_READY, STACK_IN_PROGRESS, STACK_BLOCKED]
SEARCH_STACKS = OPEN_STACKS + [STACK_DONE]

MCP_PYTHON = "/home/derrick/.hermes/hermes-agent/venv/bin/python3"
MCP_SCRIPT = (
    "/home/derrick/.hermes/skills/loudmusic/loudmusic-mcp-api-router/scripts/call_mcp_tool.py"
)


def call_mcp(tool: str, args: dict[str, Any]) -> dict[str, Any]:
    proc = subprocess.run(
        [MCP_PYTHON, MCP_SCRIPT, tool, json.dumps(args)],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or f"MCP {tool} failed")

    payload = json.loads(proc.stdout)
    structured = payload.get("structuredContent")
    if isinstance(structured, dict):
        return structured

    content = payload.get("content") or []
    if content and content[0].get("type") == "text":
        return json.loads(content[0]["text"])

    return payload


def list_cards(stack_id: int) -> list[dict[str, Any]]:
    result = call_mcp("deck_get_cards", {"board_id": BOARD_ID, "stack_id": stack_id})
    cards = result.get("cards") or []
    return cards if isinstance(cards, list) else []


def find_card(task_key: str, task_name: str | None = None) -> dict[str, Any] | None:
    needles = [task_key.lower()]
    if task_name:
        needles.append(task_name.lower())
    needles.append(f"ops-task:{task_key.lower()}")

    for stack_id in SEARCH_STACKS:
        for card in list_cards(stack_id):
            hay = " ".join(
                [
                    str(card.get("title") or ""),
                    str(card.get("description") or ""),
                ]
            ).lower()
            if any(n in hay for n in needles):
                return {
                    "id": int(card["id"]),
                    "stack_id": stack_id,
                    "title": card.get("title") or "",
                }
    return None


def add_comment(card_id: int, message: str) -> None:
    call_mcp("deck_create_card_comment", {"card_id": card_id, "message": message})


def move_card(card_id: int, from_stack: int, to_stack: int) -> None:
    if from_stack == to_stack:
        return
    call_mcp(
        "deck_reorder_card",
        {
            "card_id": card_id,
            "board_id": BOARD_ID,
            "stack_id": from_stack,
            "target_stack_id": to_stack,
            "order": 0,
        },
    )


def sync_action(
    action: str,
    *,
    task_key: str,
    task_name: str | None = None,
    commit: str | None = None,
) -> dict[str, Any]:
    card = find_card(task_key, task_name)
    if not card:
        return {"ok": False, "skipped": True, "reason": "no_matching_deck_card", "task_key": task_key}

    card_id = card["id"]
    stack_id = card["stack_id"]

    if action == "fix-queued":
        msg = (
            f"🔧 **Fix queued** from dashboard for `{task_key}`.\n"
            "Hermes agent is working on it — card moved to **In Progress**."
        )
        add_comment(card_id, msg)
        move_card(card_id, stack_id, STACK_IN_PROGRESS)
        return {"ok": True, "card_id": card_id, "action": action, "stack_id": STACK_IN_PROGRESS}

    if action == "fix-pushed":
        commit_line = f" Commit `{commit}`." if commit else ""
        msg = f"✅ **Fix pushed** for `{task_key}`.{commit_line} Deploying / verifying."
        add_comment(card_id, msg)
        move_card(card_id, stack_id, STACK_IN_PROGRESS)
        return {"ok": True, "card_id": card_id, "action": action, "stack_id": STACK_IN_PROGRESS}

    if action == "fix-completed":
        msg = f"✓ **Fix verified** — `{task_key}` is healthy again."
        add_comment(card_id, msg)
        move_card(card_id, stack_id, STACK_DONE)
        return {"ok": True, "card_id": card_id, "action": action, "stack_id": STACK_DONE}

    raise ValueError(f"Unknown action: {action}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Deck ↔ ops task fix sync")
    parser.add_argument(
        "action",
        choices=["fix-queued", "fix-pushed", "fix-completed", "find"],
    )
    parser.add_argument("--task-key", required=True)
    parser.add_argument("--task-name", default="")
    parser.add_argument("--commit", default="")
    args = parser.parse_args()

    try:
        if args.action == "find":
            card = find_card(args.task_key, args.task_name or None)
            print(json.dumps({"ok": bool(card), "card": card}))
            return 0

        result = sync_action(
            args.action,
            task_key=args.task_key,
            task_name=args.task_name or None,
            commit=args.commit or None,
        )
        print(json.dumps(result))
        return 0 if result.get("ok") or result.get("skipped") else 1
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
