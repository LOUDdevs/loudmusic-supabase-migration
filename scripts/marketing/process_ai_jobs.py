#!/usr/bin/env python3
"""Process pending service_ai_jobs for the marketing dashboard.

Polls marketing.service_ai_jobs where status='pending', runs OpenRouter via
the Hermes openrouter skill, and writes output_json back to Supabase.

For sendpilot / draft_reply jobs, the prompt body is built upstream in
``enqueue_sendpilot_drafts.py`` (which runs the meeting-intel pre-pass)
and passed through ``input_json.promptBody``. The model's reply is parsed
for a structured metadata block (Stage, Score, Action, Reason, Confidence,
MeetingProposed, MeetingLinkSent, CalendarChecked, NextRecommendedAction,
Objective). The metadata is persisted to
``marketing.sendpilot_conversation_state`` and logged to
``marketing.service_audit_log`` so the next cron run can carry state.

Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (from ~/.hermes/.env)
OpenRouter: uses ~/.hermes/skills/openclaw-imports/openrouter/scripts/chat.py

Exit codes:
  0 — processed zero or more jobs successfully
  1 — unexpected error
  2 — missing env
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from supabase import create_client

from . import meeting_intel
from ._common import configure_logging, getenv_required

log = configure_logging("process_ai_jobs")
OPENROUTER_SCRIPT = Path.home() / ".hermes/skills/openclaw-imports/openrouter/scripts/chat.py"
FALLBACK_OPENROUTER = Path.home() / ".openclaw/skills/openrouter/scripts/chat.py"
MAX_THREAD_MESSAGES = int(os.environ.get("SERVICE_AI_MAX_THREAD_MESSAGES", "200"))
MAX_THREAD_CHARS = int(os.environ.get("SERVICE_AI_MAX_THREAD_CHARS", "80000"))

TASK_TO_OPENROUTER = {
    "summarize": ("summarize", "Summarize this LinkedIn conversation thread concisely."),
    "draft_reply": ("voice", "Draft a LinkedIn DM reply in Derrick McMichael II's voice."),
    "improve_draft": ("rewrite", "Improve this email draft reply."),
    "classify_intent": ("classify", "Classify the intent of this email thread."),
    "rewrite_shorter": ("rewrite", "Rewrite this draft to be shorter while keeping the key point."),
    "rewrite_warmer": ("rewrite", "Rewrite this draft to sound warmer and more personable."),
    "rewrite_direct": ("rewrite", "Rewrite this draft to be more direct and concise."),
    "rewrite_professional": ("rewrite", "Rewrite this draft to be more professional."),
    "follow_up": ("voice", "Write a brief LinkedIn follow-up message in Derrick McMichael II's voice."),
    "next_action": ("classify", "What is the single best next action for this conversation?"),
    "risk_check": ("classify", "Flag any risky, unclear, too aggressive, or low-quality aspects of this draft."),
}

EMAIL_TASK_TO_OPENROUTER = {
    "summarize": ("summarize", "Summarize this email thread for CRM review."),
    "draft_reply": ("voice", "Draft an email reply in Derrick McMichael II's voice. Do not invent facts."),
    "improve_draft": ("rewrite", "Improve this email draft per user instructions."),
    "classify_intent": ("classify", "Classify email intent, urgency, and suggested CRM action."),
}

DERRICK_VOICE_RULES = """Derrick voice rules:
- Spoken-first, direct, warm, and specific. Write like one person replying to one person.
- Use simple language: traction, momentum, make a living from music, systems, real next step.
- No corporate filler: leverage, synergy, game-changing, next-level, I hope this finds you well, just checking in.
- No hype, emoji walls, hashtags, fake urgency, or invented proof/results.
- Avoid em dashes as a habit. Use commas, periods, and line breaks.
- If the thread lacks enough context, ask one grounded clarifying question instead of pretending.
"""

LOUDMUSIC_CONTEXT = """LOUDmusic context:
- Current phase: Phase 0 / pre-launch. Artist track is the default public motion.
- LOUDmusic helps independent artists build the system around their music, not give up ownership.
- Default positioning: artists need infrastructure after the upload, not another generic promo tactic.
- Soft CTA only unless the person explicitly asks for a call, pricing, membership, or next step.
"""

LINKEDIN_REPLY_RULES = """LinkedIn reply rules:
- Reply to the latest received message and respect the whole thread history.
- Keep it concise: usually 1-4 short sentences, no subject line, no sign-off unless natural.
- Reference a specific detail from the conversation when available.
- Do not push a call by default. Ask a small next-step question tied to what they said.
- If they shared a phone/WhatsApp, acknowledge it without immediately moving the conversation off-platform unless that is clearly the best next step.
"""

EMAIL_REPLY_RULES = """Email reply rules:
- Reply to the actual ask in the thread first. Do not write a generic outreach email.
- Keep it tight: normally 2-6 sentences plus Derrick sign-off.
- Preserve the relationship/context: partner, vendor, artist, accelerator, legal/compliance, or prospect.
- Use Derrick for casual/business replies; use Derrick McMichael II / CEO, LOUDmusic for formal legal/compliance if needed.
- Do not invent attachments, availability, numbers, prior commitments, or completed work.
"""


def _openrouter_script() -> Path:
    if OPENROUTER_SCRIPT.exists():
        return OPENROUTER_SCRIPT
    if FALLBACK_OPENROUTER.exists():
        return FALLBACK_OPENROUTER
    raise FileNotFoundError("openrouter chat.py not found in Hermes skills")


def _resolve_sendpilot_prompt(input_json: dict) -> tuple[str, dict]:
    """Pick the prompt body + meeting-intel metadata for a sendpilot job.

    If the enqueue pass already wrote ``input_json.promptBody`` we use it
    verbatim — that's the path that includes the meeting-intel system
    prompt, the deterministic signal flags, the prior stage, and the
    verified calendar block.

    For backwards compatibility (and for non-draft tasks like
    ``improve_draft`` or ``follow_up``) we fall back to the legacy
    ``build_prompt`` builder.
    """
    stored = (input_json or {}).get("promptBody")
    intel = (input_json or {}).get("meetingIntel") or {}
    if stored:
        return stored, intel
    return build_prompt("draft_reply", input_json, service="sendpilot"), intel


def build_prompt(task_type: str, input_json: dict, service: str = "sendpilot") -> str:
    mapping = EMAIL_TASK_TO_OPENROUTER if service == "email" else TASK_TO_OPENROUTER
    _, instruction = mapping.get(task_type, ("rewrite", "Assist with this message."))
    current = input_json.get("currentDraft") or ""
    conv = input_json.get("conversation") or input_json.get("thread") or {}
    messages = input_json.get("messages") or []
    user_instructions = input_json.get("userInstructions") or ""

    label = "Email thread" if service == "email" else "LinkedIn conversation"
    service_rules = EMAIL_REPLY_RULES if service == "email" else LINKEDIN_REPLY_RULES
    lines = [instruction, "", DERRICK_VOICE_RULES, LOUDMUSIC_CONTEXT, service_rules]
    if user_instructions:
        lines.append(f"User instructions: {user_instructions}")
        lines.append("")
    lines.append(f"=== {label} ===")
    for k, v in conv.items():
        if v:
            lines.append(f"{k}: {v}")

    lines.append("\n=== Thread ===")
    # Use the oldest available context plus the latest exchange instead of a
    # short recent-only slice. This preserves ancient context (2015-era threads)
    # while still protecting the model from overlong prompts.
    if len(messages) > MAX_THREAD_MESSAGES:
        head_count = min(50, MAX_THREAD_MESSAGES // 4)
        tail_count = MAX_THREAD_MESSAGES - head_count
        visible_messages = messages[:head_count] + messages[-tail_count:]
        lines.append(
            f"[context note] Showing {len(visible_messages)} of {len(messages)} stored messages: "
            f"the first {head_count} plus the latest {tail_count}."
        )
    else:
        visible_messages = messages
    thread_chars = 0
    for m in visible_messages:
        direction = m.get("direction", "?")
        when = m.get("sentAt") or m.get("sent_at") or m.get("received_at") or ""
        sender = m.get("sender") or m.get("from") or m.get("from_email") or ""
        body = (m.get("body") or m.get("body_text") or m.get("snippet") or "")[:2000]
        if not body:
            continue
        projected = thread_chars + len(body)
        if projected > MAX_THREAD_CHARS:
            lines.append(f"[context note] Additional stored thread text omitted after {thread_chars:,} chars to fit the model context.")
            break
        thread_chars = projected
        meta = " | ".join(str(x) for x in (when, sender) if x)
        prefix = f"[{direction}]" + (f" ({meta})" if meta else "")
        lines.append(f"{prefix}\n{body}")

    if current:
        lines.append("\n=== Current draft ===")
        lines.append(current)

    lines.append("\nBefore writing, silently infer: who they are, what they asked, what Derrick owes them, and the smallest useful next step. Respond with only the final message text. Do not include preamble, labels, bullet points, analysis, reasoning, or a 'Thinking Process' section.")
    return "\n".join(lines)


def _run_openai_direct(prompt: str) -> str:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("SERVICE_AI_OPENAI_MODEL set but OPENAI_API_KEY is missing")
    model = os.environ.get("SERVICE_AI_OPENAI_MODEL", "gpt-4o-mini")
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": int(os.environ.get("SERVICE_AI_MAX_TOKENS", "700")),
        "temperature": float(os.environ.get("SERVICE_AI_TEMPERATURE", "0.4")),
    }
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(
            req,
            timeout=int(os.environ.get("SERVICE_AI_OPENAI_TIMEOUT", "120")),
        ) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace") if hasattr(exc, "read") else str(exc)
        raise RuntimeError(f"OpenAI HTTP {exc.code}: {body[:500]}") from exc
    choices = data.get("choices") or []
    msg = (choices[0].get("message") if choices else {}) or {}
    text = msg.get("content") or ""
    if not text.strip():
        raise RuntimeError("OpenAI returned empty content")
    return text.strip()


def run_openrouter(task: str, prompt: str) -> str:
    script = _openrouter_script()

    # Explicit override: use OpenAI directly when configured, but do not let an
    # exhausted OpenAI account abort bulk draft rebuilds. Retry a real OpenRouter
    # free-tier model on OpenAI quota/rate-limit failures.
    if os.environ.get("SERVICE_AI_OPENAI_MODEL"):
        try:
            return _run_openai_direct(prompt)
        except RuntimeError as exc:
            msg = str(exc)
            if ("OpenAI HTTP 429" not in msg and "insufficient_quota" not in msg) or not os.environ.get("SERVICE_AI_OPENAI_429_FALLBACK", "free"):
                raise
            free_tier = os.environ.get("SERVICE_AI_OPENAI_429_FALLBACK", "free")
            log.warning("OpenAI quota/rate limit hit; retrying OpenRouter tier=%s", free_tier)
            with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
                f.write(prompt)
                fallback_prompt_path = f.name
            try:
                retry = subprocess.run(
                    [
                        "python3",
                        str(script),
                        "--tier",
                        free_tier,
                        "--max-tokens",
                        os.environ.get("SERVICE_AI_MAX_TOKENS", "700"),
                        "--prompt-file",
                        fallback_prompt_path,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=int(os.environ.get("SERVICE_AI_OPENROUTER_TIMEOUT", "120")),
                )
                if retry.returncode == 0 and retry.stdout.strip():
                    return retry.stdout.strip()
                raise RuntimeError(f"{msg}\n[openrouter] OpenAI fallback tier={free_tier} also failed:\n{retry.stderr or retry.stdout}") from exc
            finally:
                Path(fallback_prompt_path).unlink(missing_ok=True)

    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        f.write(prompt)
        prompt_path = f.name

    # Normal production path uses task-aware routing. Batch rebuilds can set
    # SERVICE_AI_OPENROUTER_TIER=free when paid OpenRouter credits are exhausted;
    # this preserves real model generation instead of falling back to fake output.
    route_args = ["--task", task]
    if os.environ.get("SERVICE_AI_OPENROUTER_TIER"):
        route_args = ["--tier", os.environ["SERVICE_AI_OPENROUTER_TIER"]]
    if os.environ.get("SERVICE_AI_OPENROUTER_MODEL"):
        route_args = ["--model", os.environ["SERVICE_AI_OPENROUTER_MODEL"]]

    try:
        result = subprocess.run(
            [
                "python3",
                str(script),
                *route_args,
                "--max-tokens",
                os.environ.get("SERVICE_AI_MAX_TOKENS", "700"),
                "--prompt-file",
                prompt_path,
            ],
            capture_output=True,
            text=True,
            timeout=int(os.environ.get("SERVICE_AI_OPENROUTER_TIMEOUT", "120")),
        )
        if result.returncode != 0:
            err = result.stderr or result.stdout or "openrouter failed"
            # OpenRouter 402 is account-level credit exhaustion. Retry the free
            # tier before failing so production draft jobs still use a real model
            # instead of deterministic fallback text.
            if "HTTP 402" in err and "OPENROUTER" in err.upper() and os.environ.get("SERVICE_AI_OPENROUTER_402_FALLBACK", "free"):
                free_tier = os.environ.get("SERVICE_AI_OPENROUTER_402_FALLBACK", "free")
                log.warning("OpenRouter credits exhausted; retrying OpenRouter tier=%s", free_tier)
                retry = subprocess.run(
                    [
                        "python3",
                        str(script),
                        "--tier",
                        free_tier,
                        "--max-tokens",
                        os.environ.get("SERVICE_AI_MAX_TOKENS", "700"),
                        "--prompt-file",
                        prompt_path,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=int(os.environ.get("SERVICE_AI_OPENROUTER_TIMEOUT", "120")),
                )
                if retry.returncode == 0 and retry.stdout.strip():
                    return retry.stdout.strip()
                err = f"{err}\n[openrouter] 402 fallback tier={free_tier} also failed:\n{retry.stderr or retry.stdout}"
            if "HTTP 402" in err and os.environ.get("OPENAI_API_KEY"):
                log.warning("OpenRouter credits exhausted; falling back to direct OpenAI for this job")
                return _run_openai_direct(prompt)
            raise RuntimeError(err)
        return result.stdout.strip()
    finally:
        Path(prompt_path).unlink(missing_ok=True)


def _fallback_sendpilot_reply(input_json: dict) -> str:
    """Deterministic SendPilot draft used only when model providers are unavailable.

    It must still respect Derrick's follow-up rules: latest inbound gets a
    reply, latest outbound gets a natural follow-up, no naked meeting links,
    and no "just following up" filler.
    """
    conv = input_json.get("conversation") or {}
    messages = input_json.get("messages") or []
    intel = input_json.get("meetingIntel") or {}
    prior = intel.get("prior_stage") or intel.get("metadata", {}).get("prior_stage") or "discovery"
    score = int(intel.get("prior_score") or 0) if str(intel.get("prior_score") or "0").isdigit() else 0
    reason = str(intel.get("prior_reason") or "").strip()
    name = (conv.get("lead_name") or "there").split()[0].strip(",") or "there"
    title = (conv.get("lead_title") or "").strip()
    company = (conv.get("lead_company") or "").strip()
    company_ref = company or ("your work" if not title else "what you’re building")

    latest_msg = {}
    latest_received = ""
    latest_sent = ""
    for msg in reversed(messages):
        body = str(msg.get("body") or "").strip()
        if not body:
            continue
        if not latest_msg:
            latest_msg = msg
        if msg.get("direction") == "received" and not latest_received:
            latest_received = body
        if msg.get("direction") == "sent" and not latest_sent:
            latest_sent = body
    latest_direction = latest_msg.get("direction") or conv.get("last_message_direction")
    lower = latest_received.lower()

    if latest_direction == "received":
        if "whatsapp" in lower or "what app" in lower or (any(ch.isdigit() for ch in latest_received) and ("+" in latest_received or len([c for c in latest_received if c.isdigit()]) >= 7)):
            return (
                f"Thanks, {name}, I saw the number. Before we move this off LinkedIn, what are you trying to move forward right now on the music or business side?"
            )
        if any(x in lower for x in ["call", "meet", "schedule", "calendar", "chat", "zoom"]):
            return (
                f"Absolutely, {name}. It would be useful to compare notes and see where there’s real overlap. You can find a time that works here: https://loudmusic.io/meet-derrick"
            )
        if "thank" in lower or "welcome" in lower or "connected" in lower or "likewise" in lower:
            if company or title:
                return (
                    f"Absolutely, {name}, glad we connected. I’m building LOUDmusic around helping artists and music teams turn attention into real momentum. What are you focused on most right now with {company_ref}?"
                )
            return (
                f"Absolutely, {name}, glad we connected. I’m building LOUDmusic around helping artists and music teams turn attention into real momentum. What are you focused on most right now?"
            )
        if "how are" in lower or "how's" in lower:
            return f"Doing well, {name}, appreciate you asking. What are you working on right now in music or media?"
        return (
            f"Thanks, {name}, I appreciate you reaching out. I’m focused on helping artists and music teams build real momentum around releases, audience growth, and business structure. What are you working on right now?"
        )

    # Latest outbound: draft a purposeful follow-up, not a fake reply.
    if prior in {"meeting_interest", "meeting_coordination", "synergy_identified"} or score >= 6:
        return (
            f"I still think there may be a useful conversation here, especially around how {company_ref} connects with what we’re building at LOUDmusic. If it feels worth comparing notes, you can grab a time here: https://loudmusic.io/meet-derrick"
        )
    if latest_sent and "pleasure to connect" in latest_sent.lower():
        if company or title:
            return (
                f"I reached out because your work with {company_ref} feels connected to the artist-growth side of what we’re building with LOUDmusic. Curious, what are you most focused on right now?"
            )
        return (
            "I reached out because I’m connecting with people who are building around music, media, and artist growth. Curious, what are you most focused on right now?"
        )
    if company or title:
        return (
            f"One thing we keep seeing is that artists often have access to tools, but not always a clear system for turning attention into long-term growth. Since your work touches {company_ref}, I’d be interested in how you’re thinking about that."
        )
    if reason:
        return (
            f"The reason I reached out is tied to {reason.rstrip('.')}. If this is relevant on your side, I’d be glad to compare notes."
        )
    return (
        "One thing I’m focused on with LOUDmusic is helping artists turn attention into real momentum, not just another one-off release push. If that overlaps with what you’re working on, I’d be interested in comparing notes."
    )


def _clean_model_text(text: str) -> str:
    cleaned = text.strip()
    lowered = cleaned.lower()
    markers = [
        "final message:",
        "final answer:",
        "draft:",
        "*draft:*",
        "**draft:**",
        "message:",
    ]
    if lowered.startswith("thinking process") or lowered.startswith("reasoning"):
        marker_positions = [(lowered.rfind(marker), marker) for marker in markers]
        marker_positions = [(pos, marker) for pos, marker in marker_positions if pos >= 0]
        if not marker_positions:
            raise RuntimeError("model returned reasoning text instead of a usable draft")
        pos, marker = max(marker_positions)
        cleaned = cleaned[pos + len(marker):].strip()
    cleaned = cleaned.strip().strip('"').strip()
    # Remove common markdown bullets around the actual reply.
    if cleaned.startswith("`"):
        cleaned = cleaned.strip("`").strip()
    if not cleaned or len(cleaned) < 8:
        raise RuntimeError("model returned an empty or unusably short draft")
    return cleaned


def _write_sendpilot_draft(sb, job: dict, text: str, task_type: str) -> None:
    if task_type not in {"draft_reply", "follow_up", "improve_draft", "rewrite_shorter", "rewrite_warmer", "rewrite_direct", "rewrite_professional"}:
        return
    input_json = job.get("input_json") or {}
    conversation_id = job.get("conversation_id") or input_json.get("conversationId") or (input_json.get("conversation") or {}).get("id")
    if not conversation_id:
        return

    existing = (
        sb.table("sendpilot_drafts")
        .select("id")
        .eq("conversation_id", conversation_id)
        .in_("status", ["draft", "ready_to_send"])
        .limit(1)
        .execute()
    )
    if existing.data:
        draft_id = existing.data[0]["id"]
        sb.table("sendpilot_drafts").update({
            "body": text,
            "ai_assisted": True,
            "edited_after_ai": False,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }).eq("id", draft_id).execute()
    else:
        draft_res = sb.table("sendpilot_drafts").insert({
            "conversation_id": conversation_id,
            "body": text,
            "status": "draft",
            "ai_assisted": True,
            "edited_after_ai": False,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }).execute()
        draft_id = (draft_res.data or [{}])[0].get("id")

    sb.table("sendpilot_conversations").update({
        "has_draft": True,
        "needs_reply": False,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }).eq("id", conversation_id).execute()
    sb.table("service_audit_log").insert({
        "service": "sendpilot",
        "action": "draft_created_by_ai_job",
        "conversation_id": conversation_id,
        "ai_assisted": True,
        "payload": {"jobId": job.get("id"), "draftId": draft_id, "taskType": task_type},
    }).execute()


def _write_email_draft(sb, job: dict, text: str, task_type: str) -> None:
    input_json = job.get("input_json") or {}
    thread_id = job.get("email_thread_id") or input_json.get("threadId") or (input_json.get("thread") or {}).get("id")
    if not thread_id:
        return
    email_id = job.get("email_id") or input_json.get("emailId")
    thread = sb.table("email_threads").select("account_id, subject").eq("id", thread_id).maybe_single().execute()
    thread_row = thread.data or {}
    account_id = thread_row.get("account_id")
    if not account_id:
        return
    status = "needs_review" if task_type == "draft_reply" else "generated"
    draft_res = sb.table("email_drafts").insert({
        "thread_id": thread_id,
        "email_id": email_id,
        "account_id": account_id,
        "status": status,
        "draft_body": text,
        "reason_summary": f"AI {task_type}",
        "generated_by": "cron",
    }).execute()
    sb.table("email_threads").update({"has_ai_draft": True}).eq("id", thread_id).execute()

    draft_id = (draft_res.data or [{}])[0].get("id")
    try:
        link = sb.table("email_contact_links").select("contact_id").eq("email_thread_id", thread_id).maybe_single().execute()
        contact_id = (link.data or {}).get("contact_id")
    except Exception as exc:  # noqa: BLE001
        log.warning("email contact link lookup skipped for %s: %s", thread_id, exc)
        contact_id = None
    if contact_id and draft_id:
        sb.table("crm_communications").insert({
            "contact_id": contact_id,
            "channel": "email",
            "direction": "outbound",
            "subject": thread_row.get("subject"),
            "body": text,
            "status": "drafted",
            "ai_generated": True,
            "email_draft_id": draft_id,
        }).execute()


def process_jobs(limit: int = 10, service_filter: str | None = None) -> int:
    supabase_url = getenv_required("SUPABASE_URL")
    supabase_key = getenv_required("SUPABASE_SERVICE_ROLE_KEY")
    sb = create_client(supabase_url, supabase_key)

    query = sb.table("service_ai_jobs").select("*").eq("status", "pending").order("created_at").limit(limit)
    if service_filter:
        query = query.eq("service", service_filter)

    pending = query.execute()
    jobs = pending.data or []
    if not jobs:
        log.info("no pending AI jobs")
        return 0

    processed = 0
    failed = 0
    for job in jobs:
        job_id = job["id"]
        task_type = job["task_type"]
        input_json = job.get("input_json") or {}
        service = job.get("service") or "sendpilot"
        mapping = EMAIL_TASK_TO_OPENROUTER if service == "email" else TASK_TO_OPENROUTER

        sb.table("service_ai_jobs").update({
            "status": "processing",
            "started_at": datetime.now(timezone.utc).isoformat(),
        }).eq("id", job_id).execute()

        try:
            or_task, _ = mapping.get(task_type, ("rewrite", ""))
            # SendPilot draft_reply uses the meeting-intel prompt body built
            # upstream in the enqueue pass. Every other task type uses the
            # legacy build_prompt builder.
            intel_meta: dict = {}
            if service == "sendpilot" and task_type == "draft_reply":
                prompt, intel_meta = _resolve_sendpilot_prompt(input_json)
            else:
                prompt = build_prompt(task_type, input_json, service=service)
            try:
                if (
                    service == "sendpilot"
                    and task_type == "draft_reply"
                    and os.environ.get("SERVICE_AI_FORCE_DETERMINISTIC_FALLBACK") == "1"
                ):
                    raw = _fallback_sendpilot_reply(input_json)
                    parsed = meeting_intel.ParsedDraft(draft=raw)
                else:
                    raw = run_openrouter(or_task, prompt)
            except Exception as model_error:  # noqa: BLE001
                if (
                    service == "sendpilot"
                    and task_type == "draft_reply"
                    and os.environ.get("SERVICE_AI_ALLOW_GENERIC_FALLBACK") == "1"
                ):
                    log.warning("job %s using deterministic SendPilot fallback after model error: %s", job_id, model_error)
                    raw = _fallback_sendpilot_reply(input_json)
                    parsed = meeting_intel.ParsedDraft(draft=raw)
                else:
                    raise

            # Parse the structured metadata block. For non-draft tasks
            # (improve_draft / follow_up / rewrite_*) the model isn't
            # expected to emit a metadata block, so we fall back to
            # wrapping the raw text in a synthetic ParsedDraft.
            if service == "sendpilot" and task_type == "draft_reply":
                try:
                    parsed = meeting_intel.parse_structured_output(raw)
                except Exception as parse_exc:  # noqa: BLE001
                    log.warning(
                        "structured-output parse failed for job %s; treating raw as draft: %s",
                        job_id, parse_exc,
                    )
                    parsed = meeting_intel.ParsedDraft(draft=raw)
            else:
                parsed = meeting_intel.ParsedDraft(draft=raw)

            text = _clean_model_text(parsed.draft or raw)
            if not text:
                raise RuntimeError("model returned an empty or unusably short draft")

            output: dict = {"text": text}
            if task_type == "summarize":
                output = {"summary": text, "text": text}
            elif task_type in ("draft_reply", "improve_draft", "rewrite_shorter", "rewrite_warmer", "rewrite_direct", "rewrite_professional", "follow_up"):
                output = {"draft": text, "text": text}
            elif task_type == "next_action":
                output = {"nextAction": text, "text": text}
            elif task_type == "risk_check":
                output = {"riskCheck": text, "text": text}
            elif task_type == "classify_intent":
                output = {"classification": text, "text": text}

            # Embed the meeting-intel reasoning alongside the user-facing
            # text so the dashboard / audit log can inspect it.
            if service == "sendpilot" and task_type == "draft_reply":
                output["meetingIntel"] = {
                    "prior": intel_meta,
                    "model": {
                        "stage": parsed.stage,
                        "score": parsed.score,
                        "confidence": parsed.confidence,
                        "objective": parsed.objective,
                        "reason": parsed.reason,
                        "next_recommended_action": parsed.next_action,
                        "meeting_proposed": parsed.meeting_proposed,
                        "meeting_link_sent": parsed.meeting_link_sent,
                        "calendar_checked": parsed.calendar_checked,
                    },
                    "raw_metadata": parsed.raw_metadata,
                }

            sb.table("service_ai_jobs").update({
                "status": "done",
                "output_json": output,
                "finished_at": datetime.now(timezone.utc).isoformat(),
            }).eq("id", job_id).execute()

            if service == "sendpilot" and task_type in ("draft_reply", "follow_up", "improve_draft", "rewrite_shorter", "rewrite_warmer", "rewrite_direct", "rewrite_professional"):
                _write_sendpilot_draft(sb, job, text, task_type)
                # Persist the LLM's final classification + audit it.
                if task_type == "draft_reply" and parsed.stage:
                    try:
                        meeting_intel.persist_classification(
                            sb,
                            conversation_id=str(job.get("conversation_id") or (input_json.get("conversationId") or "")),
                            stage=parsed.stage,
                            score=parsed.score,
                            meeting_proposed=parsed.meeting_proposed,
                            meeting_link_sent=parsed.meeting_link_sent,
                            objective=parsed.objective or "",
                            reason=parsed.reason or "",
                            next_action=parsed.next_action or "",
                            confidence=parsed.confidence,
                        )
                        sb.table("service_audit_log").insert({
                            "service": "sendpilot",
                            "action": "meeting_intel_classified",
                            "conversation_id": job.get("conversation_id"),
                            "ai_assisted": True,
                            "payload": {
                                "jobId": job_id,
                                "stage": parsed.stage,
                                "score": parsed.score,
                                "meeting_proposed": parsed.meeting_proposed,
                                "meeting_link_sent": parsed.meeting_link_sent,
                                "calendar_checked": parsed.calendar_checked,
                                "prior": intel_meta,
                                "reason": parsed.reason,
                                "next_action": parsed.next_action,
                                "confidence": parsed.confidence,
                            },
                        }).execute()
                    except Exception as persist_exc:  # noqa: BLE001
                        log.warning(
                            "classification persist failed for job %s: %s",
                            job_id, persist_exc,
                        )
            if service == "email" and task_type in ("draft_reply", "improve_draft"):
                _write_email_draft(sb, job, text, task_type)

            processed += 1
            log.info(
                "job %s done (%s/%s) stage=%s score=%s meeting_proposed=%s",
                job_id, service, task_type, parsed.stage, parsed.score, parsed.meeting_proposed,
            )
        except Exception as e:
            failed += 1
            log.exception(f"job {job_id} failed: {e}")
            sb.table("service_ai_jobs").update({
                "status": "failed",
                "error": str(e)[:1000],
                "finished_at": datetime.now(timezone.utc).isoformat(),
            }).eq("id", job_id).execute()

    log.info(f"processed {processed}/{len(jobs)} jobs; failed={failed}")
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--service", default=None, help="Filter by service (sendpilot, email)")
    args = parser.parse_args()
    try:
        return process_jobs(service_filter=args.service)
    except FileNotFoundError as e:
        log.error(str(e))
        return 1
    except Exception as e:
        log.exception(f"unexpected: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
