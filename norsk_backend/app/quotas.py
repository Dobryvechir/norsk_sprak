"""
Upload quota checks.

Before an upload is accepted, `check_upload_quota` makes sure it doesn't push
the uploader or the group over any monthly limit. Limits come from two places:

    membership["quota"]                      - per user, per group
        max_recordings_per_month
        max_audio_minutes_per_month
        max_recording_duration_minutes
    group["ai"]["monthly_audio_minutes_limit"] - whole group

A missing or null limit means "unlimited". Failed recordings don't count.
"""

from .helpers import current_month, fail
from .repository import repo


def _counts_this_month(recording) -> bool:
    """True if a recording uses up quota: created this month and not failed."""
    return recording["created_at"][:7] == current_month() and recording["status"] != "failed"


def check_upload_quota(group_id, user, membership, new_seconds):
    """Fail with 403 if uploading `new_seconds` of audio would exceed a quota.

    Call this while holding `repo.lock`, and save the new recording before
    releasing it - otherwise two simultaneous uploads could both pass the check.
    """
    group_recordings = [
        r for r in repo.list("recordings")
        if r["group_id"] == group_id and _counts_this_month(r)
    ]
    my_recordings = [r for r in group_recordings if r["uploader_id"] == user["id"]]
    my_seconds = sum(r["duration_seconds"] for r in my_recordings)

    # --- Per-user limits (from the membership) ---
    quota = membership.get("quota", {})

    limit = quota.get("max_recordings_per_month")
    if limit is not None and len(my_recordings) >= limit:
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
        group_seconds = sum(r["duration_seconds"] for r in group_recordings)
        if group_seconds + new_seconds > limit * 60:
            fail(403, "Group AI quota exceeded")
