#!/usr/bin/env python3
"""Send email via SMTP (new message or reply with threading headers)."""
from __future__ import annotations

import argparse
import json
import smtplib
import ssl
import sys
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders
from email.utils import formatdate, make_msgid


def send_reply(
    *,
    smtp_host: str,
    smtp_port: int,
    user: str,
    password: str,
    to: str,
    subject: str,
    body: str,
    from_name: str = "",
    cc: str = "",
    in_reply_to: str | None = None,
    references: str | None = None,
    ics_attachment: str | None = None,
    ics_method: str = "REPLY",
) -> dict[str, str]:
    recipients = [addr.strip() for addr in to.split(",") if addr.strip()]
    if not recipients:
        raise ValueError("At least one recipient is required")

    cc_list = [addr.strip() for addr in cc.split(",") if addr.strip()]
    message_id = make_msgid(domain=user.split("@")[-1] if "@" in user else "local")
    from_addr = f"{from_name} <{user}>" if from_name else user

    msg = MIMEMultipart("mixed" if ics_attachment else "alternative")
    msg["Subject"] = subject
    msg["From"] = from_addr
    msg["To"] = ", ".join(recipients)
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = message_id
    if cc_list:
        msg["Cc"] = ", ".join(cc_list)
    if in_reply_to:
        msg["In-Reply-To"] = in_reply_to if in_reply_to.startswith("<") else f"<{in_reply_to}>"
    if references:
        msg["References"] = references

    msg.attach(MIMEText(body, "plain"))
    html_body = "<html><body>" + "".join(f"<p>{line}</p>" for line in body.splitlines()) + "</body></html>"
    msg.attach(MIMEText(html_body, "html"))

    if ics_attachment:
        part = MIMEBase("text", "calendar", method=ics_method.upper())
        part.set_payload(ics_attachment.encode("utf-8"))
        encoders.encode_base64(part)
        part.add_header("Content-Type", f'text/calendar; charset="UTF-8"; method={ics_method.upper()}')
        part.add_header("Content-Disposition", "inline; filename=invite.ics")
        msg.attach(part)

    all_recipients = recipients + cc_list
    ctx = ssl.create_default_context()
    with smtplib.SMTP_SSL(smtp_host, smtp_port, context=ctx) as server:
        server.login(user, password)
        server.sendmail(user, all_recipients, msg.as_string())

    return {
        "message_id": message_id.strip("<>"),
        "to": ", ".join(recipients),
        "subject": subject,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Send SMTP email")
    parser.add_argument("--json", required=True, help="JSON payload file path")
    args = parser.parse_args()

    payload = json.loads(open(args.json, encoding="utf-8").read())
    try:
        result = send_reply(
            smtp_host=payload["smtpHost"],
            smtp_port=int(payload.get("smtpPort", 465)),
            user=payload["user"],
            password=payload["password"],
            to=payload["to"],
            subject=payload["subject"],
            body=payload["body"],
            from_name=payload.get("fromName", ""),
            cc=payload.get("cc", ""),
            in_reply_to=payload.get("inReplyTo"),
            references=payload.get("references"),
            ics_attachment=payload.get("icsAttachment"),
            ics_method=str(payload.get("icsMethod") or "REPLY"),
        )
        print(json.dumps({"ok": True, **result}))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)[:500]}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
