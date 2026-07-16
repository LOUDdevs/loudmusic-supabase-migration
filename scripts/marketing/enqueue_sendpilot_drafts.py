#!/usr/bin/env python3
"""Queue SendPilot/LinkedIn AI draft jobs for conversations that need replies.

The dashboard stores generated LinkedIn replies in sendpilot_drafts. This script
bridges the gap between ingested needs_reply conversations and the generic
service_ai_jobs processor.

It also runs the **meeting-booking intelligence** pre-classification pass
before queuing the job:

  * Detects deterministic signals on the latest inbound message
    (meeting request, acceptance, time mentions, synergy keywords,
    low-relevance spam).
  * Pre-classifies the conversation stage and synergy score so the LLM
    starts from a prior it can agree with, override, or refine.
  * Fetches verified calendar availability only when the prior stage is
    ``meeting_interest`` or ``meeting_coordination`` — never wastes tokens
    on cold intros.
  * Persists the signal flags and the prior on
    ``marketing.sendpilot_conversation_state`` so the next cron run has
    continuity (already-proposed, already-sent-link, discovery-question
    counter, etc.).

The processor picks up ``input_json.prompt_body`` and runs it through
OpenRouter as before, then parses the structured metadata block out of
the model output and writes the final classification back to the state
row.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from supabase import create_client

from . import meeting_intel
from ._common import configure_logging, getenv_required

log = configure_logging("enqueue_sendpilot_drafts")
DEFAULT_LIMIT = int(os.environ.get("SENDPILOT_DRAFT_ENQUEUE_LIMIT", "5"))
# Default follows the dashboard triage queue: unread, explicit needs_reply, or
# failed-send conversations all need attention. Set SENDPILOT_DRAFT_SCOPE=all
# for explicit rebuilds where Derrick wants every live LinkedIn conversation
# evaluated, not only action-needed rows.
DEFAULT_SCOPE = os.environ.get("SENDPILOT_DRAFT_SCOPE", "action_needed").strip().lower()
DERRICK_SENDPILOT_ACCOUNT_ID = "cmqm3xikx1mu02m01qark2e47"
MESSAGE_PAGE_SIZE = 1000


def _load_env() -> None:
    for candidate in ("/home/derrick/.hermes/.env", ".env"):
        path = Path(candidate)
        if not path.exists():
            continue
        for line in path.read_text(errors="ignore").splitlines():
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"\''))


def _has_active_job(sb: Any, conversation_id: str) -> bool:
    res = (
        sb.table("service_ai_jobs")
        .select("id")
        .eq("service", "sendpilot")
        .eq("conversation_id", conversation_id)
        .eq("task_type", "draft_reply")
        .in_("status", ["pending", "processing"])
        .limit(1)
        .execute()
    )
    return bool(res.data)


def _has_open_draft(sb: Any, conversation_id: str, last_activity_at: str | None = None) -> bool:
    res = (
        sb.table("sendpilot_drafts")
        .select("id,updated_at")
        .eq("conversation_id", conversation_id)
        .in_("status", ["draft", "ready_to_send"])
        .order("updated_at", desc=True)
        .limit(1)
        .execute()
    )
    rows = res.data or []
    if not rows:
        return False
    draft = rows[0]
    draft_at = _parse_dt(draft.get("updated_at"))
    latest_at = _parse_dt(last_activity_at)
    if draft_at and latest_at and latest_at > draft_at:
        sb.table("sendpilot_drafts").update({
            "status": "discarded",
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }).eq("id", draft["id"]).execute()
        log.info("discarded stale SendPilot draft=%s after newer inbound conversation=%s", draft["id"], conversation_id)
        return False
    return True


def _conversation_messages(sb: Any, conversation_id: str) -> list[dict[str, Any]]:
    """Return the full stored thread context for the reply model.

    Supabase/PostgREST caps a single response at 1,000 rows by default, so page
    manually. This lets ancient/high-volume LinkedIn threads keep their old
    messages instead of only feeding the model a recent slice.
    """
    rows: list[dict[str, Any]] = []
    start = 0
    while True:
        batch = (
            sb.table("sendpilot_messages")
            .select("direction,body,sent_at")
            .eq("conversation_id", conversation_id)
            .order("sent_at", desc=False)
            .range(start, start + MESSAGE_PAGE_SIZE - 1)
            .execute()
            .data
            or []
        )
        rows.extend(batch)
        if len(batch) < MESSAGE_PAGE_SIZE:
            break
        start += MESSAGE_PAGE_SIZE
    messages = []
    for row in rows:
        messages.append({
            "direction": row.get("direction"),
            "body": row.get("body"),
            "sentAt": row.get("sent_at"),
        })
    return messages


def _load_existing_state(sb: Any, conversation_id: str) -> dict:
    res = (
        sb.table("sendpilot_conversation_state")
        .select("*")
        .eq("conversation_id", conversation_id)
        .limit(1)
        .execute()
    )
    return (res.data or [{}])[0] if res.data else {}


def _parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None


def _natural_to_queue(conv: dict, messages: list[dict[str, Any]], state: dict | None) -> tuple[bool, str]:
    """Whether a draft would feel natural now in scope='all'.

    Derrick asked to evaluate all LinkedIn conversations, but not to create
    weird same-day bumps. Latest inbound threads are direct replies. Latest
    outbound threads are follow-ups only when enough time has passed or the
    prior state implies a scheduling follow-up is due.
    """
    if conv.get("archived") or conv.get("completed"):
        return False, "conversation archived/completed"
    if state and state.get("meeting_booked"):
        return False, "meeting already booked"

    latest_direction = conv.get("last_message_direction")
    latest_at = _parse_dt(conv.get("last_activity_at") or conv.get("last_message_sent_at"))
    if latest_direction == "received":
        return True, "latest inbound needs a reply"
    if latest_direction != "sent":
        return True, "unknown latest direction; allow model to decide"

    # Latest outbound. Follow-up only after a natural wait.
    now = datetime.now(timezone.utc)
    age_hours = ((now - latest_at).total_seconds() / 3600) if latest_at else 999
    sent_count = sum(1 for m in messages or [] if m.get("direction") == "sent")
    received_count = sum(1 for m in messages or [] if m.get("direction") == "received")

    if state and (state.get("meeting_proposed") or state.get("meeting_link_sent")):
        if age_hours >= 48:
            return True, "meeting was proposed and enough time has passed"
        return False, "meeting follow-up would be too soon"

    if received_count == 0:
        # Cold Touch 2 should not happen minutes/hours after the first outreach.
        if age_hours >= 48:
            return True, "cold follow-up due after first outreach"
        return False, "cold follow-up too soon after initial outreach"

    if sent_count >= 5 and age_hours < 24 * 30:
        return False, "outreach limit reached; wait for nurture trigger"
    if age_hours >= 48:
        return True, "warm/contextual follow-up due"
    return False, "follow-up would be too soon"


def _candidate_query(sb: Any, *, scope: str, limit: int) -> list[dict[str, Any]]:
    """Return SendPilot conversations eligible for draft-job evaluation.

    ``action_needed`` is the normal cron scope. ``all`` is an explicit rebuild
    mode for Derrick's instruction to draft every live LinkedIn conversation,
    including threads where Derrick was the last sender and the next best
    message is a purposeful follow-up rather than a reply.
    """
    query = (
        sb.table("sendpilot_conversations")
        .select(
            "id,lead_name,lead_title,lead_company,lead_profile_url,"
            "last_message_content,last_message_direction,last_activity_at,"
            "campaign_name,needs_reply,unread_count,has_failed_send,has_draft,"
            "archived,completed,awaiting_response"
        )
        .eq("account_id", DERRICK_SENDPILOT_ACCOUNT_ID)
        .eq("archived", False)
        .eq("completed", False)
        .order("last_activity_at", desc=True)
        .limit(limit * 4)
    )
    if scope == "needs_reply":
        query = query.or_("needs_reply.eq.true,has_draft.eq.true")
    elif scope == "action_needed":
        query = query.or_("needs_reply.eq.true,unread_count.gt.0,has_failed_send.eq.true,has_draft.eq.true")
    return query.execute().data or []


def enqueue(limit: int = DEFAULT_LIMIT, scope: str = DEFAULT_SCOPE) -> dict[str, int]:
    _load_env()
    scope = (scope or "action_needed").strip().lower()
    if scope not in {"needs_reply", "action_needed", "all"}:
        raise ValueError(f"unsupported SendPilot draft scope: {scope!r}")
    sb = create_client(getenv_required("SUPABASE_URL"), getenv_required("SUPABASE_SERVICE_ROLE_KEY"))
    rows = _candidate_query(sb, scope=scope, limit=limit)

    scanned = enqueued = skipped_existing = skipped_empty = skipped_intel_error = skipped_not_due = 0
    for conv in rows:
        if enqueued >= limit:
            break
        scanned += 1
        conversation_id = conv["id"]
        if _has_open_draft(sb, conversation_id, conv.get("last_activity_at") or conv.get("last_message_sent_at")) or _has_active_job(sb, conversation_id):
            skipped_existing += 1
            continue
        messages = _conversation_messages(sb, conversation_id)
        if not messages and not conv.get("last_message_content"):
            skipped_empty += 1
            continue
        state = _load_existing_state(sb, conversation_id)
        if conv.get("last_message_direction") == "received":
            latest_inbound = next(
                (str(m.get("body") or "") for m in reversed(messages) if m.get("direction") == "received" and m.get("body")),
                str(conv.get("last_message_content") or ""),
            )
            should_reply, no_reply_reason = meeting_intel.linkedin_reply_needs_response(latest_inbound, state)
            if not should_reply:
                skipped_not_due += 1
                log.info(
                    "skipped SendPilot conversation=%s lead=%r reason=%s",
                    conversation_id, conv.get("lead_name"), no_reply_reason,
                )
                continue
        if scope == "all":
            should_queue, scheduler_reason = _natural_to_queue(conv, messages, state)
            if not should_queue:
                skipped_not_due += 1
                log.info(
                    "skipped SendPilot conversation=%s lead=%r reason=%s",
                    conversation_id, conv.get("lead_name"), scheduler_reason,
                )
                continue

        # ------------------------------------------------------------------
        # Meeting-booking intelligence pre-pass.
        # ------------------------------------------------------------------
        try:
            state = _load_existing_state(sb, conversation_id)
            payload = meeting_intel.prepare_job_payload(
                sb=sb, conv=conv, messages=messages, state=state
            )
            meeting_intel.persist_state_flags(sb, conversation_id, payload["signals"])
            # Persist the prior so the next run has continuity.
            try:
                meeting_intel.persist_classification(
                    sb,
                    conversation_id,
                    stage=payload["metadata"]["prior_stage"],
                    score=payload["metadata"]["prior_score"],
                    meeting_proposed=False,
                    meeting_link_sent=False,
                    objective=f"prior: {payload['metadata']['prior_reason']}",
                    reason=payload["metadata"]["prior_reason"],
                    next_action="queue_draft_job",
                    confidence=None,
                )
            except Exception as persist_exc:  # noqa: BLE001
                log.warning(
                    "prior classification persist failed for %s: %s",
                    conversation_id, persist_exc,
                )
        except Exception as intel_exc:  # noqa: BLE001
            log.exception(
                "meeting_intel pre-pass failed for %s; falling back to legacy prompt: %s",
                conversation_id, intel_exc,
            )
            skipped_intel_error += 1
            # Fallback: build a legacy prompt so we never block the queue.
            payload = {
                "prompt_body": _legacy_prompt_body(conv, messages),
                "signals": meeting_intel.MeetingSignals(),
                "metadata": {
                    "prior_stage": "discovery",
                    "prior_score": 0,
                    "prior_reason": "fallback (intel pre-pass failed)",
                    "calendar_block": meeting_intel.format_availability_for_prompt(None),
                    "calendar_slots": [],
                },
            }

        job = {
            "service": "sendpilot",
            "task_type": "draft_reply",
            "conversation_id": conversation_id,
            "input_json": {
                "conversationId": conversation_id,
                "conversation": conv,
                "messages": messages,
                "userInstructions": (
                    "Use the full thread context below before drafting. Do not make a generic reply. "
                    "Draft a concise LinkedIn reply in Derrick McMichael II's voice: warm, direct, specific to what they said, "
                    "and tied to the smallest useful next step. Do not promise a call, discount, or external action unless the contact explicitly asked for it. "
                    "If they shared a phone number or asked for WhatsApp, acknowledge it and only move off-platform if it clearly serves the conversation. "
                    "Return only the message text."
                ),
                "promptBody": payload["prompt_body"],
                "meetingIntel": payload["metadata"],
            },
        }
        sb.table("service_ai_jobs").insert(job).execute()
        enqueued += 1
        log.info(
            "queued SendPilot draft job conversation=%s lead=%r stage=%s score=%s",
            conversation_id,
            conv.get("lead_name"),
            payload["metadata"].get("prior_stage"),
            payload["metadata"].get("prior_score"),
        )

    result = {
        "scope": scope,
        "scanned": scanned,
        "enqueued": enqueued,
        "skipped_existing": skipped_existing,
        "skipped_empty": skipped_empty,
        "skipped_not_due": skipped_not_due,
        "skipped_intel_error": skipped_intel_error,
    }
    print(result)
    return result


def _legacy_prompt_body(conv: dict, messages: list[dict]) -> str:
    """Fallback prompt body when meeting_intel pre-pass raises.

    Mirrors the legacy openrouter prompt so we never block the queue.
    """
    parts = [
        "Draft a LinkedIn DM reply in Derrick McMichael II's voice.",
        "",
        "Use the full thread context below. Do not make a generic reply. "
        "Draft a concise LinkedIn reply in Derrick McMichael II's voice: warm, "
        "direct, specific to what they said, and tied to the smallest useful "
        "next step. Do not promise a call, discount, or external action unless "
        "the contact explicitly asked for it. Return only the message text.",
        "",
        f"=== LinkedIn conversation ===\n{json.dumps(conv, default=str)}",
        "\n=== Thread ===",
    ]
    for m in messages or []:
        direction = m.get("direction", "?")
        when = m.get("sentAt") or ""
        body = m.get("body") or ""
        if not body:
            continue
        parts.append(f"[{direction}] ({when})\n{body}")
    parts.append(
        "\nBefore writing, silently infer: who they are, what they asked, "
        "what Derrick owes them, and the smallest useful next step. Respond "
        "with only the final message text."
    )
    return "\n".join(parts)


def main() -> int:
    limit = int(os.environ.get("SENDPILOT_DRAFT_ENQUEUE_LIMIT", str(DEFAULT_LIMIT)))
    scope = os.environ.get("SENDPILOT_DRAFT_SCOPE", DEFAULT_SCOPE)
    enqueue(limit, scope=scope)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
