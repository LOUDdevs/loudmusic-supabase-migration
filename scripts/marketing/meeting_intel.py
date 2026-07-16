"""Meeting-booking intelligence for the LinkedIn auto-draft pipeline.

This module slots into the existing sendpilot draft cron. It does three things:

  1. ``detect_meeting_signals(text)`` runs deterministic regex checks on the
     latest received message so the prompt builder can pre-fill flags the LLM
     would otherwise have to infer (cheaper, more reliable, auditable).

  2. ``preclassify_stage(conv, messages, state, signals)`` produces a *prior*
     on the conversation stage and synergy score. The LLM still owns the
     final judgement, but this prior shapes the prompt and lets us fetch
     calendar availability only when it's actually likely to be needed.

  3. ``fetch_calendar_availability(sb)`` pulls the next ~3 business-day
     window from ``marketing.calendar_events`` and proposes 2-3 concrete
     time slots in America/New_York business hours. The script never
     invents availability — if the calendar has no data, it returns
     ``None`` and the prompt instructs the model to fall back to the
     meeting link only.

The structured-output contract:

  The model is asked to return a metadata block followed by the actual
  message text. ``parse_structured_output(raw)`` recovers both halves.

This module does not import the supabase client at import time; the
caller passes the client. That keeps it import-safe from the enqueue
script, the processor, and from offline test harnesses.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable, Optional

log = logging.getLogger("meeting_intel")

# ---------------------------------------------------------------------------
# Public constants
# ---------------------------------------------------------------------------

MEETING_LINK = "https://loudmusic.io/meet-derrick"

STAGE_ORDER = [
    "initial_connection",
    "discovery",
    "synergy_identified",
    "meeting_interest",
    "meeting_coordination",
    "meeting_booked",
    "not_qualified",
    "dormant",
]

# ---------------------------------------------------------------------------
# 1. Deterministic signal detection
# ---------------------------------------------------------------------------

# Phrases that strongly imply the *recipient* wants to talk. Match on the
# latest inbound message in the thread.
RECIPIENT_REQUEST_PATTERNS = [
    r"\b(love to|would like to|want to|wanna|let'?s|i'?d like to|i would like to)\b"
    r".{0,40}\b(connect|call|chat|talk|meet|speak|schedule|zoom|set (?:up|something)|hop on|jump on)\b",
    r"\b(schedule|set up|book)\b.{0,30}\b(call|meeting|chat|zoom|time)\b",
    r"\b(are you free|are you available|do you have time|got time|open to)\b",
    r"\b(quick call|quick chat|quick meeting|hop on a call|jump on a call|jump on zoom|hop on zoom)\b",
    r"\bnext (week|monday|tuesday|wednesday|thursday|friday)\b",
    r"\b(my calendar|here'?s my calendar|grab a (?:time|slot))\b",
    r"\b(works for me|i'?m open|i'?m free|that works|let'?s lock|let'?s get|let'?s find)\b",
]

RECIPIENT_ACCEPT_PATTERNS = [
    r"\b(booked|on (?:my|the) calendar|i'?ll (?:block|save)|i just booked|"
    r"i'?ve booked|reservation confirmed|see you (?:on|at|tomorrow|next)|"
    r"looking forward to (?:speaking|chatting|talking|meeting|connecting))\b",
    r"\b(works for me|that works|let'?s do it|i'?m in|confirmed|"
    r"sounds good|let'?s (?:lock|go))\b.{0,30}\b(time|slot|call|meeting)\b",
    r"\b\d{1,2}\s*(?:am|pm)\b.*\b(booked|confirmed|works|see you)\b",
]

# Synergy-adjacent keywords. Used as a soft signal in preclassify_score.
SYNERGY_KEYWORDS = (
    "partnership", "collaborate", "collaboration", "partner", "integrate",
    "integration", "work together", "build together", "joint", "co-create",
    "cofounder", "co-founder", "invest", "investor", "fund", "raise",
    "investment", "platform", "saas", "b2b", "music tech", "musictech",
    "distribution", "distro", "rights", "publishing", "sync", "licensing",
    "creator economy", "audience", "fan", "community", "tech", "ai tool",
    "ai tools", "startup", "label", "marketing", "promotion", "playlists",
    "spotify", "tiktok", "instagram", "youtube", "industry",
    "complement", "overlap", "fit", "compatible", "align", "aligned",
    "stack", "tooling", "roadmap", "launch", "release", "roll out",
    "go to market", "gtm", "pipeline", "partnerships", "integration",
)

# Generic signals that strongly imply the person is in a complementary
# space (independent music / artists / creators) — not a hard rule but
# nudges the score up when paired with any other discovery signal.
COMPLEMENTARY_KEYWORDS = (
    "independent artist", "indie artist", "indie label", "music business",
    "music industry", "creator economy", "music marketing", "music tech",
    "music platform", "music rights", "music distribution", "music sync",
    "royalties", "playlist", "fan base", "audience growth", "release strategy",
    "music startup", "music company", "music team", "music side",
    "build around", "systems around", "around their music",
)

LOW_RELEVANCE_KEYWORDS = (
    "buy followers", "buy streams", "boost your", "free trial", "limited time",
    "click here", "join now", "dm me", "make money fast", "crypto", "nft drop",
    "dropshipping", "affiliate", "mlm", "guaranteed", "act now", "wire transfer",
    "loan offer", "credit score",
)

NON_ACTIONABLE_INBOUND_PATTERNS = [
    r"^\s*(?:likewise|same here|you too|thanks|thank you|thx|appreciate it|sounds good|great|perfect|ok(?:ay)?|cool|got it|nice to connect|👍|🙏|🙂)[.!\s]*$",
    r"\b(?:booked|i(?:'|’)ve booked|i booked|on (?:my|the) calendar|see you (?:on|at|then)|looking forward to (?:speaking|chatting|talking|meeting|connecting))\b",
    r"\b(?:meeting|call) (?:is )?(?:booked|confirmed|scheduled)\b",
    r"\bthat works for me\b",
]
SHORT_ACK_RE = re.compile(
    r"\b(?:likewise|same here|you too|thanks|thank you|thx|appreciate it|sounds good|great|perfect|ok(?:ay)?|cool|got it|nice to connect)\b",
    re.IGNORECASE,
)


def linkedin_reply_needs_response(text: str, state: dict | None = None) -> tuple[bool, str]:
    """Return whether latest inbound LinkedIn text deserves a generated reply."""
    if state and state.get("meeting_booked"):
        return False, "meeting already booked"
    body = (text or "").strip()
    if not body:
        return False, "empty/unknown inbound"
    lowered = body.lower()
    for pattern in NON_ACTIONABLE_INBOUND_PATTERNS:
        if re.search(pattern, lowered, re.IGNORECASE):
            return False, "non-actionable acknowledgement or booking confirmation"
    if len(body) <= 120 and "?" not in body and SHORT_ACK_RE.search(body):
        return False, "short acknowledgement does not need a reply"
    return True, "inbound may need a reply"


@dataclass
class MeetingSignals:
    recipient_requested_meeting: bool = False
    recipient_accepted_meeting: bool = False
    time_mentions: list[str] = field(default_factory=list)
    synergy_keyword_hits: list[str] = field(default_factory=list)
    complementary_keyword_hits: list[str] = field(default_factory=list)
    low_relevance_hits: list[str] = field(default_factory=list)
    raw: str = ""


_TIME_REGEX = re.compile(
    r"\b(?:"
    r"\d{1,2}(?::\d{2})?\s*(?:am|pm)"            # 2pm, 11:30 am
    r"|"
    r"(?:mon|tue|wed|thu|fri|sat|sun)\w*"         # monday, tuesday
    r"|"
    r"(?:tomorrow|today|tonight|next week|this week)"
    r"|"
    r"\b\d{1,2}/\d{1,2}(?:/\d{2,4})?"            # 7/21, 7/21/26
    r")",
    re.IGNORECASE,
)


def detect_meeting_signals(text: str) -> MeetingSignals:
    """Return deterministic flags about a single message body."""
    if not text:
        return MeetingSignals()
    lowered = text.lower()
    signals = MeetingSignals(raw=text)
    for pattern in RECIPIENT_REQUEST_PATTERNS:
        if re.search(pattern, lowered):
            signals.recipient_requested_meeting = True
            break
    for pattern in RECIPIENT_ACCEPT_PATTERNS:
        if re.search(pattern, lowered):
            signals.recipient_accepted_meeting = True
            break
    signals.time_mentions = sorted(set(_TIME_REGEX.findall(text)))
    for kw in SYNERGY_KEYWORDS:
        if kw in lowered:
            signals.synergy_keyword_hits.append(kw)
    for kw in COMPLEMENTARY_KEYWORDS:
        if kw in lowered:
            signals.complementary_keyword_hits.append(kw)
    for kw in LOW_RELEVANCE_KEYWORDS:
        if kw in lowered:
            signals.low_relevance_hits.append(kw)
    return signals


# ---------------------------------------------------------------------------
# 2. Pre-classification
# ---------------------------------------------------------------------------


def _has_meaningful_discovery(messages: Iterable[dict]) -> bool:
    """Has the recipient shared at least one substantive detail?"""
    substantive_keywords = (
        "we ", "i run", "i lead", "i manage", "i'm building", "i am building",
        "founder", "ceo", "head of", "director", "we do", "our platform",
        "our product", "our company", "our team", "company", "startup",
        "team of", "client", "customer", "users",
    )
    for msg in messages:
        if msg.get("direction") != "received":
            continue
        body = (msg.get("body") or "").lower()
        if not body or len(body) < 30:
            continue
        if any(kw in body for kw in substantive_keywords):
            return True
    return False


def _discovery_question_count(messages: Iterable[dict]) -> int:
    count = 0
    for msg in messages:
        if msg.get("direction") != "sent":
            continue
        body = (msg.get("body") or "").lower()
        if "?" in body:
            count += 1
    return count


def preclassify_stage(
    conv: dict,
    messages: list[dict],
    state: dict | None,
    signals: MeetingSignals,
) -> tuple[str, int, str]:
    """Best-guess stage + synergy score before the LLM sees the thread.

    Returns (stage, score, reason). The LLM is told this is a prior and may
    override. The pre-classification exists so we can fetch calendar only
    when there's a real chance the model will need it, and so the prompt
    can highlight the right stage rules.
    """
    if not messages:
        return "initial_connection", 1, "No inbound messages yet — treat as initial."

    inbound = [m for m in messages if m.get("direction") == "received"]
    inbound_count = len(inbound)
    inbound_total_chars = sum(len(m.get("body") or "") for m in inbound)
    outbound_questions = _discovery_question_count(messages)
    has_discovery = _has_meaningful_discovery(messages)

    # Hard overrides from deterministic signals.
    if state and state.get("meeting_booked"):
        return "meeting_booked", 9, "Conversation state shows meeting already booked."
    if signals.recipient_accepted_meeting and (
        state and (state.get("meeting_proposed") or state.get("meeting_link_sent"))
    ):
        return "meeting_coordination", 9, "Recipient confirmed a time or sent calendar."

    score = 1
    if inbound_count >= 1 and inbound_total_chars >= 30:
        score += 1
    if has_discovery:
        score += 2
    if signals.synergy_keyword_hits:
        score = min(10, score + min(3, len(signals.synergy_keyword_hits)))
    if signals.complementary_keyword_hits:
        score = min(10, score + 1)
    if signals.low_relevance_hits:
        score = max(0, score - 4)
    if signals.recipient_requested_meeting:
        score = max(score, 8)

    # Stage by signals + exchange depth.
    if signals.recipient_accepted_meeting:
        return "meeting_coordination", max(score, 8), "Recipient confirmed — move to coordination."
    if signals.recipient_requested_meeting and inbound_count >= 1:
        return "meeting_interest", max(score, 7), "Recipient explicitly asked to meet/call."
    # Hard override for low-relevance spam/pitch outreach.
    if signals.low_relevance_hits:
        return "not_qualified", score, "Low-relevance outreach — do not force a meeting."
    if has_discovery and (signals.synergy_keyword_hits or signals.complementary_keyword_hits or outbound_questions >= 1):
        if score >= 5:
            return "synergy_identified", score, "Discovery complete and signals point to overlap."
        return "discovery", score, "Discovery still in progress."
    if inbound_count >= 1 and inbound_total_chars < 30:
        return "initial_connection", max(score, 1), "Inbound is brief — treat as introduction."
    if inbound_count >= 1 and has_discovery is False:
        return "discovery", score, "Recipient has spoken but not yet shared substantive context."
    return "discovery", score, "Default: stay in discovery until clearer signals appear."


# ---------------------------------------------------------------------------
# 3. Calendar availability
# ---------------------------------------------------------------------------

NY = timezone(timedelta(hours=-4))  # America/New_York in July (EDT, UTC-4)
BUSINESS_HOURS = list(range(9, 17))  # 9am–4pm local, 1h slots
SLOT_MIN_HOURS_AHEAD = 4  # don't propose anything sooner than this
SLOT_DAYS_AHEAD = 6
MAX_SLOTS_RETURNED = 3


def _to_et(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc).astimezone(NY)
    return dt.astimezone(NY)


def fetch_calendar_availability(
    sb: Any,
    *,
    now: datetime | None = None,
    days_ahead: int = SLOT_DAYS_AHEAD,
    max_slots: int = MAX_SLOTS_RETURNED,
    min_hours_ahead: int = SLOT_MIN_HOURS_AHEAD,
) -> list[dict[str, str]] | None:
    """Query calendar_events and return up to ``max_slots`` free windows.

    Returns a list of ``{"day": ..., "start": ..., "end": ...}`` dicts
    rendered in America/New_York. Returns ``None`` when there is no
    calendar data at all (caller should fall back to meeting link only).
    """
    now = now or datetime.now(timezone.utc)
    earliest = now + timedelta(hours=min_hours_ahead)
    horizon = now + timedelta(days=days_ahead)

    try:
        res = sb.table("calendar_events").select(
            "starts_at,ends_at,lifecycle_status,status"
        ).gte("starts_at", earliest.isoformat()).lte(
            "starts_at", horizon.isoformat()
        ).order("starts_at").execute()
    except Exception as exc:  # noqa: BLE001
        log.warning("calendar_events query failed: %s", exc)
        return None
    rows = res.data or []
    if not rows:
        # No data → fall back to link only.
        return None

    # Parse busy windows.
    busy: list[tuple[datetime, datetime]] = []
    for row in rows:
        lifecycle = (row.get("lifecycle_status") or "").lower()
        status = (row.get("status") or "").lower()
        if lifecycle in {"cancelled"} or status == "cancelled":
            continue
        s = row.get("starts_at")
        e = row.get("ends_at")
        if not s:
            continue
        try:
            s_dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        except Exception:
            continue
        if e:
            try:
                e_dt = datetime.fromisoformat(e.replace("Z", "+00:00"))
            except Exception:
                e_dt = s_dt + timedelta(minutes=30)
        else:
            e_dt = s_dt + timedelta(minutes=30)
        busy.append((s_dt, e_dt))

    # Walk business hours from ``earliest`` up to ``horizon``.
    slots: list[dict[str, str]] = []
    cursor = _to_et(earliest)
    horizon_et = _to_et(horizon)
    cursor = cursor.replace(minute=0, second=0, microsecond=0)
    if cursor.hour >= 17:
        cursor = (cursor + timedelta(days=1)).replace(hour=9)
    elif cursor.hour < 9:
        cursor = cursor.replace(hour=9)
    # Skip weekends.
    while cursor.weekday() >= 5 and cursor < horizon_et:
        cursor = (cursor + timedelta(days=1)).replace(hour=9)

    def overlaps(a_start: datetime, a_end: datetime) -> bool:
        for b_start, b_end in busy:
            if a_start < b_end and a_end > b_start:
                return True
        return False

    days_walked = 0
    while cursor < horizon_et and len(slots) < max_slots and days_walked < 7:
        if cursor.weekday() < 5 and cursor.hour in BUSINESS_HOURS:
            start = cursor
            end = cursor + timedelta(hours=1)
            if not overlaps(start, end) and start >= _to_et(earliest):
                slots.append({
                    "day": start.strftime("%A, %b %d"),
                    "start": start.strftime("%-I:%M %p ET"),
                    "end": end.strftime("%-I:%M %p ET"),
                    "iso": start.astimezone(timezone.utc).isoformat(),
                })
        cursor = cursor + timedelta(hours=1)
        if cursor.hour >= 18:
            cursor = (cursor + timedelta(days=1)).replace(hour=9)
            days_walked += 1
            while cursor.weekday() >= 5 and cursor < horizon_et:
                cursor = (cursor + timedelta(days=1)).replace(hour=9)
                days_walked += 1
    return slots or None


def format_availability_for_prompt(slots: list[dict[str, str]] | None) -> str:
    if not slots:
        return (
            "Calendar: no verified availability on file. "
            f"FALL BACK to {MEETING_LINK} only — do not invent specific times."
        )
    lines = ["Calendar: verified free windows (America/New_York):"]
    for slot in slots:
        lines.append(f"- {slot['day']}, {slot['start']} – {slot['end']}")
    lines.append(
        f"You may offer one of these windows; otherwise default to {MEETING_LINK}."
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 4. State row upsert helpers
# ---------------------------------------------------------------------------


def _ensure_state_row(sb: Any, conversation_id: str) -> dict:
    """Return the conversation_state row, creating it if absent."""
    res = (
        sb.table("sendpilot_conversation_state")
        .select("*")
        .eq("conversation_id", conversation_id)
        .limit(1)
        .execute()
    )
    if res.data:
        return res.data[0]
    sb.table("sendpilot_conversation_state").insert(
        {"conversation_id": conversation_id}
    ).execute()
    res = (
        sb.table("sendpilot_conversation_state")
        .select("*")
        .eq("conversation_id", conversation_id)
        .limit(1)
        .execute()
    )
    return res.data[0] if res.data else {"conversation_id": conversation_id}


def persist_state_flags(
    sb: Any,
    conversation_id: str,
    signals: MeetingSignals,
) -> dict:
    """Write the deterministic signal flags before the LLM runs."""
    state = _ensure_state_row(sb, conversation_id)
    update: dict[str, Any] = {"updated_at": datetime.now(timezone.utc).isoformat()}
    if signals.recipient_requested_meeting:
        update["recipient_requested_meeting"] = True
        update["meeting_intent_detected"] = True
    if signals.recipient_accepted_meeting:
        update["recipient_accepted_meeting"] = True
    if update.keys() != {"updated_at"}:
        sb.table("sendpilot_conversation_state").update(update).eq(
            "conversation_id", conversation_id
        ).execute()
        state.update(update)
    return state


def persist_classification(
    sb: Any,
    conversation_id: str,
    *,
    stage: str,
    score: int | None,
    meeting_proposed: bool,
    meeting_link_sent: bool,
    objective: str,
    reason: str,
    next_action: str,
    confidence: float | None,
    calendar_event_id: str | None = None,
) -> None:
    """Write the LLM's structured output back to the conversation state."""
    now = datetime.now(timezone.utc).isoformat()
    update: dict[str, Any] = {
        "conversation_stage": stage,
        "last_draft_objective": (objective or "")[:500],
        "last_action_reason": (reason or "")[:500],
        "next_recommended_action": (next_action or "")[:500],
        "last_draft_at": now,
        "last_classified_at": now,
        "updated_at": now,
    }
    if score is not None:
        update["synergy_score"] = int(score)
    if confidence is not None:
        update["last_confidence"] = float(confidence)
    if meeting_proposed and not (meeting_proposed is False):
        update["meeting_proposed"] = True
        update["meeting_proposed_at"] = now
    if meeting_link_sent:
        update["meeting_link_sent"] = True
        update["meeting_link_sent_at"] = now
    if calendar_event_id:
        update["calendar_event_id"] = calendar_event_id
        update["meeting_booked"] = True
    sb.table("sendpilot_conversation_state").upsert(
        {"conversation_id": conversation_id, **update},
        on_conflict="conversation_id",
    ).execute()


def increment_discovery_counter(sb: Any, conversation_id: str) -> int:
    state = _ensure_state_row(sb, conversation_id)
    current = int(state.get("number_of_discovery_questions") or 0)
    sb.table("sendpilot_conversation_state").update({
        "number_of_discovery_questions": current + 1,
        "last_meaningful_question_at": datetime.now(timezone.utc).isoformat(),
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }).eq("conversation_id", conversation_id).execute()
    return current + 1


# ---------------------------------------------------------------------------
# 5. Structured-output parser
# ---------------------------------------------------------------------------

# Accept both snake_case (Stage:) and PascalCase (MeetingProposed:) keys
# with optional underscores or hyphens, case-insensitive.
_METADATA_LINE_RE = re.compile(
    r"^(?P<key>stage|score|action|reason|confidence|calendar[_\-]?checked|"
    r"meeting[_\-]?proposed|meeting[_\-]?link[_\-]?sent|"
    r"next[_\-]?recommended[_\-]?action|objective)"
    r"\s*[:=]\s*(?P<value>.+?)\s*$",
    re.IGNORECASE,
)


# Normalise a parsed key (camelCase, snake_case, or with dashes) to the
# canonical snake_case used downstream.
_KEY_NORMALISE = {
    "calendar_checked": "calendar_checked",
    "calendar-checked": "calendar_checked",
    "calendarchecked": "calendar_checked",
    "meeting_proposed": "meeting_proposed",
    "meeting-proposed": "meeting_proposed",
    "meetingproposed": "meeting_proposed",
    "meeting_link_sent": "meeting_link_sent",
    "meeting-link-sent": "meeting_link_sent",
    "meetinglinksent": "meeting_link_sent",
    "next_recommended_action": "next_recommended_action",
    "next-recommended-action": "next_recommended_action",
    "nextrecommendedaction": "next_recommended_action",
}


@dataclass
class ParsedDraft:
    draft: str
    stage: str | None = None
    score: int | None = None
    confidence: float | None = None
    objective: str | None = None
    reason: str | None = None
    next_action: str | None = None
    meeting_proposed: bool = False
    meeting_link_sent: bool = False
    calendar_checked: bool = False
    raw_metadata: dict[str, str] = field(default_factory=dict)


def parse_structured_output(raw: str) -> ParsedDraft:
    """Recover the metadata block + the user-facing draft from the model.

    The model is asked to write:

        Stage: <one of STAGE_ORDER>
        Score: <0-10>
        Action: <short label>
        Reason: <one short sentence>
        Confidence: <0-1>
        MeetingProposed: yes|no
        MeetingLinkSent: yes|no
        CalendarChecked: yes|no
        NextRecommendedAction: <short label>
        Objective: <one short sentence>

        <blank line>

        <the user-facing draft text>

    The parser is forgiving: it strips "Final message:" / "Draft:" prefixes,
    pulls the first contiguous block of "Key: value" lines, then returns
    whatever follows the blank line as the draft. If no metadata is found,
    the entire text is treated as the draft and metadata fields are None.
    """
    if not raw:
        return ParsedDraft(draft="")
    cleaned = raw.strip()
    # Strip leading labels some models emit.
    for prefix in ("final message:", "final answer:", "draft:", "message:"):
        if cleaned.lower().startswith(prefix):
            cleaned = cleaned[len(prefix):].strip()
    cleaned = cleaned.strip('"').strip()

    lines = cleaned.splitlines()
    metadata_lines: list[str] = []
    body_start = 0
    for idx, line in enumerate(lines):
        if not line.strip():
            # blank line separates metadata from draft
            body_start = idx + 1
            break
        if _METADATA_LINE_RE.match(line.strip()):
            metadata_lines.append(line.strip())
            body_start = idx + 1
        else:
            # First non-metadata, non-blank line — the draft begins here.
            body_start = idx
            break
    body = "\n".join(lines[body_start:]).strip()
    if not body:
        # Fallback: no separator found — treat entire cleaned text as draft.
        body = cleaned

    parsed_meta: dict[str, str] = {}
    for line in metadata_lines:
        m = _METADATA_LINE_RE.match(line)
        if not m:
            continue
        raw_key = m.group("key").lower()
        canonical = _KEY_NORMALISE.get(raw_key, raw_key)
        parsed_meta[canonical] = m.group("value").strip()

    def _bool(value: str | None) -> bool:
        if not value:
            return False
        return value.strip().lower() in {"yes", "true", "1", "y"}

    draft = body.strip().strip('"').strip()
    if draft.startswith("`") and draft.endswith("`"):
        draft = draft.strip("`").strip()

    score_val: int | None = None
    if "score" in parsed_meta:
        try:
            score_val = max(0, min(10, int(float(parsed_meta["score"]))))
        except (TypeError, ValueError):
            score_val = None
    confidence_val: float | None = None
    if "confidence" in parsed_meta:
        try:
            confidence_val = max(0.0, min(1.0, float(parsed_meta["confidence"])))
        except (TypeError, ValueError):
            confidence_val = None

    return ParsedDraft(
        draft=draft,
        stage=parsed_meta.get("stage"),
        score=score_val,
        confidence=confidence_val,
        objective=parsed_meta.get("objective"),
        reason=parsed_meta.get("reason"),
        next_action=parsed_meta.get("next_recommended_action") or parsed_meta.get("action"),
        meeting_proposed=_bool(parsed_meta.get("meeting_proposed")),
        meeting_link_sent=_bool(parsed_meta.get("meeting_link_sent")),
        calendar_checked=_bool(parsed_meta.get("calendar_checked")),
        raw_metadata=parsed_meta,
    )


# ---------------------------------------------------------------------------
# 6. System prompt — stage rules + tone + meeting-link rules
# ---------------------------------------------------------------------------

MEETING_INTEL_SYSTEM_PROMPT = f"""\
You are drafting a LinkedIn message for Derrick McMichael II. The message itself
must contain ONLY the user-facing LinkedIn text — no preamble, no labels, no
scoring, no reasoning visible to the recipient.

The latest thread state determines the job:
- If the latest message is RECEIVED, draft a direct reply to that inbound.
- If the latest message is SENT by Derrick, draft the next natural follow-up
  only if one would feel useful and human in this conversation. Do not pretend
  the recipient sent a new message.

Every message has a purpose. Classify the conversation stage and pick the
smallest useful next step before writing. Then output a metadata block followed
by the draft on a new line.

DERICK'S VOICE
- Spoken-first, direct, warm, specific. One person replying to one person.
- Use simple language: traction, momentum, make a living from music, systems,
  real next step.
- No corporate filler: leverage, synergy, game-changing, next-level, I hope
  this finds you well, just checking in, picking your brain.
- No hype, emoji walls, hashtags, fake urgency, or invented proof.
- Avoid em dashes as a habit. Use commas, periods, and line breaks.
- If the thread lacks enough context, ask one grounded clarifying question
  instead of pretending.

LINKEDIN MESSAGE RULES
- Respect the latest thread direction. If Derrick was the last sender, write a
  purposeful follow-up, not a fake reply.
- Keep it concise: usually 1-4 short sentences, no subject line, no sign-off
  unless natural.
- Reference a specific detail from the conversation when available.
- One purpose per message: start conversation, ask one useful question, add
  value, clarify interest, suggest/coordinate a meeting, close the loop, or
  move the lead into nurture.
- Avoid duplicate follow-ups. Do not restate the same question, meeting invite,
  or value point from the previous outbound unless the recipient explicitly
  asked for it.
- Avoid "just following up," "just checking in," "circling back," "bumping
  this," "wanted to touch base," "not sure if you saw my last message,"
  "picking your brain," "explore synergies," and fake urgency.
- Persistence should be professional, not annoying. Focus on the recipient's
  goals and make the response easy.

CONVERSATION STAGES — pick exactly one
1. initial_connection
   The conversation has just started, or the person has only sent a brief
   greeting ("thanks for connecting," "great to meet you," "learning more
   about LOUDmusic"). Respond warmly, establish relevance, ask one useful
   natural question. Do NOT include the meeting link.

2. discovery
   The person has shared some information about their company, role,
   project, or goal — but no clear alignment yet. Acknowledge specifics,
   ask one focused follow-up question. Do NOT propose a meeting.

3. synergy_identified
   There is real overlap — shared industry, complementary product, mutual
   interest in partnership, investment, distribution, audience, or
   technology. Acknowledge the alignment, suggest a short call, and
   include {MEETING_LINK}.

4. meeting_interest
   The person has said or implied they want to talk ("let's connect,"
   "we should chat," "I would love to learn more," "can we schedule a
   call"). Do NOT ask another discovery question. Move directly to
   scheduling: offer 1-3 verified time windows OR default to the meeting
   link. Always include {MEETING_LINK} as the easy alternative.

5. meeting_coordination
   The conversation is already discussing dates, times, or time zones.
   Use Derrick's verified calendar availability — never invent a time.
   Offer 2-3 specific options from the calendar block. Include
   {MEETING_LINK} as backup. Do NOT restart discovery or sales talk.

6. meeting_booked
   A meeting is already confirmed or appears on the calendar. Acknowledge
   the booking, mention the date/time when shown, and express genuine
   interest. Do NOT include the meeting link again unless rescheduling.

7. not_qualified
   The conversation is vague, unrelated, or pure sales outreach. Be
   polite, ask one question only if it could uncover relevance, and do
   not force a meeting. A single polite reply is fine.

SYNERGY SCORING (0-10)
- 0-2  Low relevance. No meeting. Polite reply only.
- 3-5  Possible relevance. One focused discovery question.
- 6-8  Strong synergy. Propose a meeting, include the link.
- 9-10 Explicit meeting intent. Move directly to scheduling.
Score guides the response, but explicit language from the person
overrides the score.

WHEN TO PROPOSE A MEETING (any one of these is enough)
- The person asked to meet, call, or schedule.
- Clear mutual business value is on the table.
- The conversation has enough detail that LinkedIn is now inefficient.
- Derrick and the person have discussed two or more alignment points.
- The conversation has stayed engaged for several messages with no
  forward motion.
- The person is geographically close and is expressing interest.

WHEN NOT TO PROPOSE
- The conversation is still an introduction.
- The person is sending generic sales outreach and has not engaged.
- A meeting was already proposed and ignored — do not paste the link
  in every reply. Wait for a new trigger.

MEETING LINK RULES
- Use the link only when proposing, scheduling, or confirming a meeting.
- Never send the link by itself. Always include a natural sentence
  explaining why a conversation would be useful.
- Do not include the link in initial greetings, before relevance is
  established, or after a meeting is already booked.

CALENDAR AVAILABILITY
- When calendar slots are provided, you may offer one of those specific
  windows for stage 4 or stage 5 drafts.
- When the calendar block says "no verified availability," fall back to
  the meeting link only. NEVER invent a time.
- Always offer 2-3 options when proposing specific times, and include
  the link as an alternative.

CONVERSATION MOMENTUM
- If the conversation has clear alignment and at least one meaningful
  exchange, favor proposing a meeting over asking another broad
  question.
- If a meeting was already proposed and the person ignored it, do not
  paste the link again. Continue the conversation naturally and
  reintroduce the meeting only when a new trigger appears.

PURPOSEFUL FOLLOW-UP SCHEDULER GUIDANCE
Use these as judgment guidelines, not rigid templates. The message should feel
natural in the current thread.
- Cold/no-reply threads: follow up with a new reason to respond. Add context,
  value, a narrower question, a credible opportunity, or a respectful close.
  Do not resend the original message with minor wording changes.
- Warm threads: continue from the specific topic already being discussed. Make
  the next step easy; do not treat them like strangers.
- Meeting link sent but not booked: mention the specific reason the meeting
  would be useful, keep it low-pressure, and do not repeat the link unless
  scheduling is the actual purpose of this message.
- Explicit future timing: if they said to reconnect later and that time has not
  arrived, do not force urgency. If the time has arrived, reference their timing.
- Declines, do-not-contact, or obvious irrelevance: write a brief respectful
  close or decline, not a sales message.
- Long-term nurture: only re-engage when there is a real reason or trigger.
  Avoid generic "hope all is well" style messages.
- Always ask: what new value, reason, specificity, or lower-friction next step
  does this message add compared to Derrick's last outbound?

OUTPUT FORMAT — REQUIRED
Write the metadata block first, ONE field per line, in this order. Then a
blank line, then the user-facing draft on its own.

Stage: <one of initial_connection|discovery|synergy_identified|meeting_interest|meeting_coordination|meeting_booked|not_qualified>
Score: <0-10>
Objective: <one short sentence describing the goal of this reply>
Action: <short label e.g. "warm greeting + one discovery question">
Reason: <one short sentence explaining why this action is appropriate>
Confidence: <0.0-1.0>
MeetingProposed: <yes|no>
MeetingLinkSent: <yes|no>
CalendarChecked: <yes|no>
NextRecommendedAction: <short label e.g. "send draft for review">

<the user-facing draft text only — no labels, no preamble, no quotes>
"""


# ---------------------------------------------------------------------------
# 7. Convenience: build the full prompt the processor will pass to the model
# ---------------------------------------------------------------------------


def build_meeting_intel_prompt(
    *,
    conv: dict,
    messages: list[dict],
    state: dict | None,
    signals: MeetingSignals,
    prior_stage: str,
    prior_score: int,
    prior_reason: str,
    calendar_block: str,
    user_instructions: str = "",
) -> str:
    """Assemble the full prompt body for the LLM (system + payload).

    Mirrors ``process_ai_jobs.build_prompt`` shape but adds the meeting
    intelligence header and pre-classified context.
    """
    label = "LinkedIn conversation"
    parts: list[str] = []
    parts.append(MEETING_INTEL_SYSTEM_PROMPT.rstrip())
    parts.append("")

    if user_instructions:
        parts.append(f"USER INSTRUCTIONS: {user_instructions.strip()}")
        parts.append("")

    # Pre-classification prior — tells the LLM what we think so it can
    # agree, override, or refine. This is cheaper and more reliable than
    # asking the LLM to start from zero.
    latest_direction = "unknown"
    latest_at = ""
    latest_body = ""
    for msg in reversed(messages or []):
        if msg.get("body"):
            latest_direction = str(msg.get("direction") or "unknown")
            latest_at = str(msg.get("sentAt") or msg.get("sent_at") or "")
            latest_body = str(msg.get("body") or "")[:500]
            break
    sent_count = sum(1 for m in messages or [] if m.get("direction") == "sent")
    received_count = sum(1 for m in messages or [] if m.get("direction") == "received")
    parts.append("THREAD MOMENTUM CONTEXT:")
    parts.append(f"  Latest message direction: {latest_direction}")
    if latest_at:
        parts.append(f"  Latest message at: {latest_at}")
    if latest_body:
        parts.append(f"  Latest message snippet: {latest_body}")
    parts.append(f"  Total Derrick outbound messages: {sent_count}")
    parts.append(f"  Total recipient inbound messages: {received_count}")
    if latest_direction == "sent":
        parts.append(
            "  Job type: write the next natural follow-up to Derrick's last outbound; "
            "do not answer as if the recipient just replied."
        )
    elif latest_direction == "received":
        parts.append("  Job type: reply directly to the recipient's latest inbound message.")
    parts.append("")

    parts.append("PRE-CLASSIFIED CONTEXT (a prior — agree, override, or refine):")
    parts.append(f"  Prior stage: {prior_stage}")
    parts.append(f"  Prior score: {prior_score}/10")
    parts.append(f"  Prior reason: {prior_reason}")
    parts.append("")

    parts.append("DETERMINISTIC SIGNAL FLAGS (from regex on the latest received message):")
    parts.append(
        f"  recipient_requested_meeting: {signals.recipient_requested_meeting}"
    )
    parts.append(
        f"  recipient_accepted_meeting:  {signals.recipient_accepted_meeting}"
    )
    if signals.time_mentions:
        parts.append(f"  time_mentions: {', '.join(signals.time_mentions)}")
    if signals.synergy_keyword_hits:
        parts.append(
            f"  synergy_keyword_hits: {', '.join(signals.synergy_keyword_hits)}"
        )
    if signals.low_relevance_hits:
        parts.append(
            f"  low_relevance_hits: {', '.join(signals.low_relevance_hits)}"
        )
    parts.append("")

    parts.append(calendar_block)
    parts.append("")

    if state:
        if state.get("meeting_proposed"):
            parts.append("PRIOR MEETING STATE: a meeting has already been proposed in this thread.")
        if state.get("meeting_link_sent"):
            parts.append("PRIOR MEETING STATE: the meeting link has already been sent.")
        if state.get("meeting_booked"):
            parts.append("PRIOR MEETING STATE: a meeting is already booked on the calendar.")
        if state.get("recipient_accepted_meeting"):
            parts.append("PRIOR MEETING STATE: recipient has accepted a meeting.")
        if state.get("number_of_discovery_questions"):
            parts.append(
                f"PRIOR MEETING STATE: Derrick has asked "
                f"{int(state.get('number_of_discovery_questions') or 0)} "
                f"discovery question(s) in this thread so far."
            )
        if state.get("last_draft_objective"):
            parts.append(
                "PRIOR MEETING STATE: last draft objective — "
                f"{state.get('last_draft_objective')}"
            )

    parts.append("")
    parts.append(f"=== {label} ===")
    for k, v in (conv or {}).items():
        if v:
            parts.append(f"{k}: {v}")
    parts.append("")
    parts.append("=== Thread ===")
    for m in messages or []:
        direction = m.get("direction", "?")
        when = m.get("sentAt") or m.get("sent_at") or ""
        body = (m.get("body") or m.get("body_text") or m.get("snippet") or "").strip()
        if not body:
            continue
        meta = " | ".join(str(x) for x in (when,) if x)
        prefix = f"[{direction}]" + (f" ({meta})" if meta else "")
        parts.append(f"{prefix}\n{body}")
    parts.append("")
    parts.append(
        "Output the metadata block first (one field per line), then a blank "
        "line, then ONLY the user-facing message text."
    )
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# 8. Public entry point used by the enqueue script
# ---------------------------------------------------------------------------


def prepare_job_payload(
    sb: Any,
    conv: dict,
    messages: list[dict],
    state: dict | None,
) -> dict:
    """Build the meeting-intel input for a draft job.

    Returns a dict suitable for ``service_ai_jobs.input_json`` augmentation
    and a separate ``metadata`` dict for the enqueue-side audit log.
    """
    latest_received = ""
    for msg in reversed(messages or []):
        if msg.get("direction") == "received" and msg.get("body"):
            latest_received = str(msg.get("body") or "")
            break
    signals = detect_meeting_signals(latest_received)
    prior_stage, prior_score, prior_reason = preclassify_stage(conv, messages, state, signals)
    # Calendar: only fetch for stages that are likely to propose specific times.
    calendar_block = ""
    calendar_payload: list[dict[str, str]] | None = None
    if prior_stage in {"meeting_interest", "meeting_coordination"}:
        calendar_payload = fetch_calendar_availability(sb)
    calendar_block = format_availability_for_prompt(calendar_payload)

    user_instructions = (
        f"Draft a concise LinkedIn message in Derrick McMichael II's voice. "
        f"Use the full thread context below. If the latest message is inbound, "
        f"reply to it. If Derrick was the last sender, write the next natural, "
        f"purposeful follow-up without sounding automated, repetitive, or pushy. "
        f"The prior stage is '{prior_stage}' with synergy {prior_score}/10. "
        f"Honour the stage and follow-up scheduler rules in the system prompt. "
        f"Use {MEETING_LINK} only when stage rules permit, and only offer "
        f"specific times from the calendar block when the block lists verified "
        f"windows — never invent a time."
    )
    prompt_body = build_meeting_intel_prompt(
        conv=conv,
        messages=messages,
        state=state,
        signals=signals,
        prior_stage=prior_stage,
        prior_score=prior_score,
        prior_reason=prior_reason,
        calendar_block=calendar_block,
        user_instructions=user_instructions,
    )
    return {
        "prompt_body": prompt_body,
        "signals": signals,
        "metadata": {
            "prior_stage": prior_stage,
            "prior_score": prior_score,
            "prior_reason": prior_reason,
            "recipient_requested_meeting": signals.recipient_requested_meeting,
            "recipient_accepted_meeting": signals.recipient_accepted_meeting,
            "time_mentions": signals.time_mentions,
            "synergy_keyword_hits": signals.synergy_keyword_hits,
            "complementary_keyword_hits": signals.complementary_keyword_hits,
            "low_relevance_hits": signals.low_relevance_hits,
            "calendar_slots": calendar_payload or [],
            "calendar_block": calendar_block,
        },
    }
