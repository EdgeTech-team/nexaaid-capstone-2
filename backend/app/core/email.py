"""send_email(): Gmail SMTP. Credentials come from environment variables, never code.

backend/app/.env  (loaded by core/config.py; never commit it):
    EMAIL_DEV_MODE=false              true = print emails in the uvicorn terminal instead of sending
    SMTP_HOST=smtp.gmail.com
    SMTP_PORT=587
    SMTP_USER=your.address@gmail.com
    SMTP_PASSWORD=xxxxxxxxxxxxxxxx    Google app password (SMTP_APP_PASSWORD also works)
    SMTP_FROM=your.address@gmail.com  optional, defaults to SMTP_USER

Never raises and never logs the message body outside dev mode (it may hold
a temporary password).

Check the Gmail setup on its own, from backend/app:
    python -m core.email you@example.com
"""
import logging
import os
import smtplib
import sys
from email.message import EmailMessage

import core.config  # noqa: F401  (loads backend/app/.env into os.environ)

log = logging.getLogger("uvicorn.error")


def _flag(name: str) -> bool:
    return os.getenv(name, "").strip().lower() in ("1", "true", "yes", "on")


def _password() -> str:
    return (os.getenv("SMTP_PASSWORD") or os.getenv("SMTP_APP_PASSWORD") or "").replace(" ", "")


def email_configured() -> bool:
    """True when emails can be delivered (or printed, in dev mode). Checked
    before creating a staff account, because the temporary password is only
    ever delivered by email."""
    return _flag("EMAIL_DEV_MODE") or bool(os.getenv("SMTP_USER") and _password())


def send_email(to: str, subject: str, body: str) -> bool:
    if _flag("EMAIL_DEV_MODE"):
        log.info("EMAIL_DEV_MODE: not sent.\nTo: %s\nSubject: %s\n\n%s", to, subject, body)
        return True

    host = os.getenv("SMTP_HOST", "smtp.gmail.com")
    port = int(os.getenv("SMTP_PORT", "587"))
    user = os.getenv("SMTP_USER")
    password = _password()
    if not user or not password:
        log.warning("send_email skipped: SMTP_USER or SMTP_PASSWORD not set")
        return False

    msg = EmailMessage()
    msg["From"] = f"NexaAid <{os.getenv('SMTP_FROM') or user}>"
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)
    try:
        with smtplib.SMTP(host, port, timeout=15) as s:
            s.starttls()
            s.login(user, password)
            s.send_message(msg)
        log.info("send_email ok: %r to %s", subject, to)
        return True
    except smtplib.SMTPAuthenticationError:
        log.error("send_email failed: Gmail rejected SMTP_USER/SMTP_PASSWORD. "
                  "Use a 16-letter Google app password, not your normal password.")
        return False
    except Exception:
        log.exception("send_email failed for %s", to)
        return False


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    if len(sys.argv) != 2:
        sys.exit("usage: python -m core.email you@example.com")
    ok = send_email(sys.argv[1], "NexaAid test email",
                    "If you can read this, NexaAid can send email.")
    print("SENT" if ok else "NOT SENT - see the error above")
    sys.exit(0 if ok else 1)
