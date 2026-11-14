"""Sending email (the verification link after signup) over SMTP.

Configured with SMTP_HOST, SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, SMTP_FROM
and SMTP_SECURITY. Without SMTP_HOST nothing is sent and the message is written
to the log instead, which is handy during development.
"""

import logging
import smtplib
import ssl
from email.message import EmailMessage

from .config import settings

log = logging.getLogger("norsk.mailer")


def send(to: str, subject: str, text: str, html: str | None = None):
    """Send one email. Raises on SMTP errors (callers running in the background log them)."""
    if not settings.smtp_host:
        log.warning("SMTP_HOST is not set; email to %s not sent:\n%s\n%s", to, subject, text)
        return
    message = EmailMessage()
    message["From"] = settings.smtp_from or settings.smtp_username
    message["To"] = to
    message["Subject"] = subject
    message.set_content(text)
    if html:
        message.add_alternative(html, subtype="html")
    context = ssl.create_default_context()
    security = settings.smtp_security.lower()
    if security == "ssl":
        server = smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, context=context, timeout=30)
    else:
        server = smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=30)
    with server:
        if security == "starttls":
            server.starttls(context=context)
        if settings.smtp_username:
            server.login(settings.smtp_username, settings.smtp_password)
        server.send_message(message)


def send_quietly(to: str, subject: str, text: str, html: str | None = None):
    """send(), but errors are logged instead of raised (for background tasks)."""
    try:
        send(to, subject, text, html)
    except Exception:  # noqa: BLE001 - a failed email must not break the request
        log.exception("Could not send email to %s", to)
