#!/usr/bin/env python3
"""Process pending service_ai_jobs for the marketing dashboard.

Polls marketing.service_ai_jobs where status='pending', runs OpenRouter via
the Hermes openrouter skill, and writes output_json back to Supabase.

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
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from supabase import create_client

from ._common import configure_logging, getenv_required

log = configure_logging("process_ai_jobs")

OPENROUTER_SCRIPT = Path.home() / ".hermes/skills/openclaw-imports/openrouter/scripts/chat.py"
FALLBACK_OPENROUTER = Path.home() / ".openclaw/skills/openrouter/scripts/chat.py"

TASK_TO_OPENROUTER = {
    "summarize": ("summarize", "Summarize this LinkedIn conversation thread concisely."),
    "draft_reply": ("voice", "Draft a LinkedIn DM reply in a professional but warm tone."),
    "improve_draft": ("rewrite", "Improve this email draft reply."),
    "classify_intent": ("classify", "Classify the intent of this email thread."),
    "rewrite_shorter": ("rewrite", "Rewrite this draft to be shorter while keeping the key point."),
    "rewrite_warmer": ("rewrite", "Rewrite this draft to sound warmer and more personable."),
    "rewrite_direct": ("rewrite", "Rewrite this draft to be more direct and concise."),
    "rewrite_professional": ("rewrite", "Rewrite this draft to be more professional."),
    "follow_up": ("voice", "Write a brief LinkedIn follow-up message."),
    "next_action": ("classify", "What is the single best next action for this conversation?"),
    "risk_check": ("classify", "Flag any risky, unclear, too aggressive, or low-quality aspects of this draft."),
}

EMAIL_TASK_TO_OPENROUTER = {
    "summarize": ("summarize", "Summarize this email thread for CRM review."),
    "draft_reply": ("voice", "Draft a professional email reply. Do not invent facts."),
    "improve_draft": ("rewrite", "Improve this email draft per user instructions."),
    "classify_intent": ("classify", "Classify email intent, urgency, and suggested CRM action."),
}


def _openrouter_script() -> Path:
    if OPENROUTER_SCRIPT.exists():
        return OPENROUTER_SCRIPT
    if FALLBACK_OPENROUTER.exists():
        return FALLBACK_OPENROUTER
    raise FileNotFoundError("openrouter chat.py not found in Hermes skills")


def build_prompt(task_type: str, input_json: dict, service: str = "sendpilot") -> str:
    mapping = EMAIL_TASK_TO_OPENROUTER if service == "email" else TASK_TO_OPENROUTER
    _, instruction = mapping.get(task_type, ("rewrite", "Assist with this message."))
    current = input_json.get("currentDraft") or ""
    conv = input_json.get("conversation") or input_json.get("thread") or {}
    messages = input_json.get("messages") or []
    user_instructions = input_json.get("userInstructions") or ""

    label = "Email thread" if service == "email" else "Contact"
    lines = [instruction, ""]
    if user_instructions:
        lines.append(f"User instructions: {user_instructions}")
        lines.append("")
    lines.append(f"=== {label} ===")
    for k, v in conv.items():
        if v:
            lines.append(f"{k}: {v}")

    lines.append("\n=== Thread ===")
    for m in messages[-20:]:
        direction = m.get("direction", "?")
        body = (m.get("body") or "")[:500]
        lines.append(f"[{direction}] {body}")

    if current:
        lines.append("\n=== Current draft ===")
        lines.append(current)

    lines.append("\nRespond with only the message text (or summary/action), no preamble.")
    return "\n".join(lines)


def run_openrouter(task: str, prompt: str) -> str:
    script = _openrouter_script()
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        f.write(prompt)
        prompt_path = f.name

    try:
        result = subprocess.run(
            ["python3", str(script), "--task", task, "--prompt-file", prompt_path],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr or result.stdout or "openrouter failed")
        return result.stdout.strip()
    finally:
        Path(prompt_path).unlink(missing_ok=True)


def _write_email_draft(sb, job: dict, text: str, task_type: str) -> None:
    thread_id = job.get("email_thread_id")
    if not thread_id:
        return
    thread = sb.table("email_threads").select("account_id, subject").eq("id", thread_id).maybe_single().execute()
    thread_row = thread.data or {}
    account_id = thread_row.get("account_id")
    if not account_id:
        return
    status = "needs_review" if task_type == "draft_reply" else "generated"
    draft_res = sb.table("email_drafts").insert({
        "thread_id": thread_id,
        "email_id": job.get("email_id"),
        "account_id": account_id,
        "status": status,
        "draft_body": text,
        "reason_summary": f"AI {task_type}",
        "generated_by": "cron",
    }).execute()
    sb.table("email_threads").update({"has_ai_draft": True}).eq("id", thread_id).execute()

    draft_id = (draft_res.data or [{}])[0].get("id")
    link = sb.table("email_contact_links").select("contact_id").eq("thread_id", thread_id).maybe_single().execute()
    contact_id = (link.data or {}).get("contact_id")
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
            prompt = build_prompt(task_type, input_json, service=service)
            text = run_openrouter(or_task, prompt)

            output = {"text": text}
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

            sb.table("service_ai_jobs").update({
                "status": "done",
                "output_json": output,
                "finished_at": datetime.now(timezone.utc).isoformat(),
            }).eq("id", job_id).execute()

            if service == "email" and task_type in ("draft_reply", "improve_draft"):
                _write_email_draft(sb, job, text, task_type)

            processed += 1
            log.info(f"job {job_id} done ({service}/{task_type})")
        except Exception as e:
            log.exception(f"job {job_id} failed: {e}")
            sb.table("service_ai_jobs").update({
                "status": "failed",
                "error": str(e)[:1000],
                "finished_at": datetime.now(timezone.utc).isoformat(),
            }).eq("id", job_id).execute()

    log.info(f"processed {processed}/{len(jobs)} jobs")
    return 0


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
