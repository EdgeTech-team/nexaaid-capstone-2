"""send_email(): Gmail SMTP. Credentials come from environment variables, never code.

.env:
    SMTP_HOST=smtp.gmail.com          (optional)
    SMTP_PORT=587                     (optional)
    SMTP_USER=team.nexaaid@gmail.com
    SMTP_PASSWORD=xxxx xxxx xxxx xxxx (Google app password; SMTP_APP_PASSWORD also works)

Never raises and never logs the message body (it may hold a temporary password).
"""
import logging
import os
import smtplib
from email.message import EmailMessage


log = logging.getLogger("uvicorn.error")


def email_configured() -> bool:
    """True when SMTP credentials are present. Checked before creating a staff
    account, because the temporary password is only ever delivered by email."""
    return bool(
        os.getenv("SMTP_USER")
        and (os.getenv("SMTP_PASSWORD") or os.getenv("SMTP_APP_PASSWORD"))
    )


def send_email(to: str, subject: str, body: str) -> bool:
    host = os.getenv("SMTP_HOST", "smtp.gmail.com")
    port = int(os.getenv("SMTP_PORT", "587"))
    user = os.getenv("SMTP_USER")
    password = os.getenv("SMTP_PASSWORD") or os.getenv("SMTP_APP_PASSWORD")
    if not user or not password:
        log.warning("send_email skipped: SMTP_USER or SMTP_PASSWORD not set")
        return False

    msg = EmailMessage()
    msg["From"] = f"NexaAid <{user}>"
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)
    try:
        with smtplib.SMTP(host, port, timeout=10) as s:
            s.starttls()
            s.login(user, password.replace(" ", ""))
            s.send_message(msg)
        return True
    except Exception:
        log.exception("send_email failed for %s", to)
        return False