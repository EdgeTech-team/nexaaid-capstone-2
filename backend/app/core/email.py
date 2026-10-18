"""send_email(): Brevo HTTPS API (used on Render) or Gmail SMTP (local fallback).
Credentials come from environment variables, never code.

Render's free tier blocks SMTP ports 25/465/587, so on Render use Brevo:
    BREVO_API_KEY=xkeysib-...         (Brevo > SMTP & API > API Keys)
    EMAIL_FROM=team.nexaaid@gmail.com (a sender verified in Brevo)
    EMAIL_FROM_NAME=NexaAid           (optional)

Local fallback when BREVO_API_KEY is not set:
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

import httpx


log = logging.getLogger("uvicorn.error")


BREVO_URL = "https://api.brevo.com/v3/smtp/email"


def _brevo_key():
    return (os.getenv("BREVO_API_KEY") or "").strip()


def email_configured() -> bool:
    """True when Brevo or SMTP credentials are present. Checked before creating
    a staff account, because the temporary password is only ever delivered by
    email."""
    return bool(
        _brevo_key()
        or (
            os.getenv("SMTP_USER")
            and (os.getenv("SMTP_PASSWORD") or os.getenv("SMTP_APP_PASSWORD"))
        )
    )


def _send_via_brevo(to: str, subject: str, body: str) -> bool:
    sender = os.getenv("EMAIL_FROM") or os.getenv("SMTP_USER")
    if not sender:
        log.warning("send_email skipped: EMAIL_FROM not set (needed with BREVO_API_KEY)")
        return False
    payload = {
        "sender": {"name": os.getenv("EMAIL_FROM_NAME", "NexaAid"), "email": sender},
        "to": [{"email": to}],
        "subject": subject,
        "textContent": body,
    }
    headers = {
        "api-key": _brevo_key(),
        "accept": "application/json",
        "content-type": "application/json",
    }
    try:
        r = httpx.post(BREVO_URL, json=payload, headers=headers, timeout=15)
        r.raise_for_status()
        return True
    except httpx.HTTPStatusError as e:
        # Brevo's reply explains the problem (bad key, sender not verified...).
        # It never contains our message body.
        log.error("Brevo rejected email to %s: %s %s", to, e.response.status_code, e.response.text)
    except Exception:
        log.exception("send_email (Brevo) failed for %s", to)
    return False


def _send_via_smtp(to: str, subject: str, body: str) -> bool:
    host = os.getenv("SMTP_HOST", "smtp.gmail.com")
    port = int(os.getenv("SMTP_PORT", "587"))
    user = os.getenv("SMTP_USER")
    password = os.getenv("SMTP_PASSWORD") or os.getenv("SMTP_APP_PASSWORD")
    if not user or not password:
        log.warning("send_email skipped: set BREVO_API_KEY, or SMTP_USER and SMTP_PASSWORD")
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


def send_email(to: str, subject: str, body: str) -> bool:
    if _brevo_key():
        return _send_via_brevo(to, subject, body)
    return _send_via_smtp(to, subject, body)


# ---------------------------------------------------------------------------
# Donor / organization notifications (no passwords, notification only).
# Staff accounts above are unchanged: they still get a temporary password
# from admin_router. These are queued as background tasks by the routers,
# so a slow Gmail never delays registration or login.
# ---------------------------------------------------------------------------

_SIGN_OFF = "\n\n- The NexaAid Team"


def send_registration_notice(to: str, first_name: str, role_name: str,
                             org_name: str = None) -> bool:
    """After self-registration: UC-D1 (donor, active right away) or
    UC-A2 (organization, pending the Administrator's review)."""
    if role_name == "Relief Organization":
        subject = "NexaAid registration received - pending review"
        body = (
            f"Hello {first_name},\n\n"
            f"Thank you for registering {org_name or 'your organization'} on NexaAid "
            "as a Relief Organization.\n\n"
            f"Login email: {to}\n\n"
            "Your registration is pending review by the NexaAid Administrator. "
            "You can sign in once it is approved, and we will notify you at this "
            "email address when the review is done.\n\n"
            "If you did not submit this registration, please reply to this email."
        )
    else:
        subject = "Welcome to NexaAid - your donor account is ready"
        body = (
            f"Hello {first_name},\n\n"
            "You have successfully registered on NexaAid as an Individual Donor.\n\n"
            f"Login email: {to}\n\n"
            "You can now sign in to view validated disaster reports in Cebu City "
            "and support them. We will notify you at this email address about "
            "updates to your account and your donations.\n\n"
            "If you did not create this account, please reply to this email."
        )
    return send_email(to, subject, body + _SIGN_OFF)


def send_login_notice(to: str, first_name: str, when: str) -> bool:
    """After a donor or organization signs in: a security notice only."""
    body = (
        f"Hello {first_name},\n\n"
        f"Your NexaAid account ({to}) was signed in on {when}.\n\n"
        "If this was you, no action is needed. If it was not you, change your "
        "password right away and contact the NexaAid Administrator."
    )
    return send_email(to, "New sign-in to your NexaAid account", body + _SIGN_OFF)