"""Small general-purpose helpers used throughout the app."""

import datetime
import uuid

from fastapi import HTTPException

# Language codes (ISO 639-1) that recordings and sentences may use.
# Keep in sync with languageNames in the Flutter app (lib/l10n/l10n.dart).
LANGUAGES = ("en", "nb", "uk", "ru", "de", "da", "sv", "cs", "bg", "pl", "pt", "es", "fr", "el", "he", "it")


def new_id() -> str:
    """Return a new random ID, e.g. '3aa0cbcf8a8b43129dd1761c29b6e38e'."""
    return uuid.uuid4().hex


def utc_now_iso() -> str:
    """Current UTC time as an ISO-8601 string, e.g. '2026-10-16T12:00:00+00:00'."""
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def current_month() -> str:
    """Current UTC month as 'YYYY-MM'. Used to group quota usage per month.

    Because timestamps are ISO strings, `created_at[:7]` gives the same format,
    so "was this created this month?" is simply `created_at[:7] == current_month()`.
    """
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m")


def fail(status_code: int = 403, detail: str = "Forbidden"):
    """Stop the current request and return an HTTP error to the client.

    This raises, so code after a `fail(...)` call never runs.
    """
    raise HTTPException(status_code, detail)
