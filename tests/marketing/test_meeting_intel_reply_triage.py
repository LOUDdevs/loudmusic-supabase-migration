from scripts.marketing import meeting_intel


def test_linkedin_reply_needs_response_filters_likewise():
    should_reply, reason = meeting_intel.linkedin_reply_needs_response("Likewise")

    assert should_reply is False
    assert "non-actionable" in reason


def test_linkedin_reply_needs_response_filters_booked_meeting():
    should_reply, reason = meeting_intel.linkedin_reply_needs_response(
        "Booked — looking forward to speaking with you Tuesday."
    )

    assert should_reply is False
    assert "non-actionable" in reason


def test_linkedin_reply_needs_response_respects_meeting_booked_state():
    should_reply, reason = meeting_intel.linkedin_reply_needs_response(
        "Can you send the link again?", {"meeting_booked": True}
    )

    assert should_reply is False
    assert reason == "meeting already booked"


def test_linkedin_reply_needs_response_filters_likewise_with_greeting():
    should_reply, reason = meeting_intel.linkedin_reply_needs_response("Hi Jonathan Thank you! Likewise!")

    assert should_reply is False
    assert "acknowledgement" in reason


def test_linkedin_reply_needs_response_filters_empty_inbound():
    should_reply, reason = meeting_intel.linkedin_reply_needs_response("")

    assert should_reply is False
    assert "empty" in reason


def test_linkedin_reply_needs_response_allows_direct_ask():
    should_reply, reason = meeting_intel.linkedin_reply_needs_response(
        "Can you send me more details about LOUDmusic?"
    )

    assert should_reply is True
    assert reason == "inbound may need a reply"
