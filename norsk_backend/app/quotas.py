"""
Upload quota checks.

Before an upload is accepted, `check_upload_quota` makes sure it doesn't push
the uploader or the group over any monthly limit. Limits come from two places:

    membership["quota"]                      - per user, per group
        max_recordings_per_month
        max_audio_minutes_per_month
        max_recording_duration_minutes
    group["ai"]["monthly_audio_minutes_limit"] - whole group

A missing or null limit means "unlimited". Each uploaded audio file counts
(a recording with audio in three languages counts three times). Failed
transcriptions don't count.
"""

from .helpers import current_month, fail
from .repository import repo


def _uploads_this_month(group_id) -> list:
    """The group's audio uploads that use up quota: created this month and not failed."""
    return [
        entry
        for recording in repo.list("recordings") if recording["group_id"] == group_id
        for entry in recording["audio"].values()
        if entry["created_at"][:7] == current_month() and entry["status"] != "failed"
    ]


def check_upload_quota(group_id, user, membership, new_seconds):
    """Fail with 403 if uploading `new_seconds` of audio would exceed a quota.

    Call this while holding `repo.lock`, and save the new recording before
    releasing it - otherwise two simultaneous uploads could both pass the check.
    """
    group_uploads = _uploads_this_month(group_id)
    my_uploads = [a for a in group_uploads if a["uploader_id"] == user["id"]]
    my_seconds = sum(a["duration_seconds"] for a in my_uploads)

    # --- Per-user limits (from the membership) ---
    quota = membership.get("quota", {})

    limit = quota.get("max_recordings_per_month")
    if limit is not None and len(my_uploads) >= limit:
        fail(403, "Monthly recording quota exceeded")

    limit = quota.get("max_audio_minutes_per_month")
    if limit is not None and my_seconds + new_seconds > limit * 60:
        fail(403, "Monthly audio quota exceeded")

    limit = quota.get("max_recording_duration_minutes")
    if limit is not None and new_seconds > limit * 60:
        fail(403, "Recording too long")

    # --- Group-wide limit (from the group's AI settings) ---
    group = repo.get("groups", group_id)
    limit = group["ai"].get("monthly_audio_minutes_limit")
    if limit is not None:
        group_seconds = sum(a["duration_seconds"] for a in group_uploads)
        if group_seconds + new_seconds > limit * 60:
            fail(403, "Group AI quota exceeded")
