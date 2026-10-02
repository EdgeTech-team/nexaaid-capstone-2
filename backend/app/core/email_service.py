import smtplib
from email.message import EmailMessage

from fastapi import HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from core.config import settings


class EmailSendError(Exception):
    pass


def send_email(to: str, subject: str, body: str) -> None:
    if not (settings.SMTP_HOST and settings.SMTP_USER and settings.SMTP_PASSWORD):
        raise EmailSendError("SMTP is not configured")
    msg = EmailMessage()
    msg["From"] = f"NexaAid <{settings.SMTP_FROM}>"
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)
    try:
        with smtplib.SMTP(settings.SMTP_HOST, settings.SMTP_PORT, timeout=15) as s:
            s.starttls()
            s.login(settings.SMTP_USER, settings.SMTP_PASSWORD)
            s.send_message(msg)
    except (smtplib.SMTPException, OSError) as e:
        raise EmailSendError(str(e)) from e


def send_temp_password_email(to: str, first_name: str, temp_password: str, account_label: str) -> None:
    send_email(
        to,
        "Your NexaAid account",
        f"Hello {first_name},\n\n"
        f"A NexaAid account ({account_label}) was created for this email address.\n\n"
        f"Temporary password: {temp_password}\n\n"
        "Sign in with your email and this temporary password. You will be required to set a new "
        "password immediately. Never share this password with anyone.\n\n"
        "If you did not expect this email, you can ignore it.\n\n- NexaAid",
    )


def commit_after_email(db: Session, send_fn) -> None:
    """Call AFTER db.add()/flush(). Sends the email first; if it fails, nothing is saved
    (so nobody ends up with an account and no way to know the password)."""
    try:
        db.flush()
        send_fn()
        db.commit()
    except EmailSendError:
        db.rollback()
        raise HTTPException(status_code=502, detail="Could not send the temporary-password email. The account was not created. Try again.")
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail="Email, employee ID or registration number already exists")