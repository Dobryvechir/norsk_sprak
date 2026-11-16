"""
AI transcription allowance and quota checks.

A recording's texts and timings either come from the uploader (a file they
made: "manual") or from our AI transcription ("ai"). Only "ai" costs us, so
only it is limited. Limits come from two places:

    group["ai"]["enabled"]                     - false: the group may not use AI at all
    group["ai"]["monthly_audio_minutes_limit"] - whole group, per month
    membership["quota"]                        - per user, per group, per month
        max_recordings_per_month
        max_audio_minutes_per_month
        max_recording_duration_minutes

A missing or null limit means "unlimited"; a missing "enabled" means true.
Each AI-transcribed audio counts (a recording with AI audio in three languages
counts three times). Failed transcriptions and manual timings don't count.
"""

from .helpers import current_month, fail
from .repository import repo

# Why AI can't be used, as returned by ai_allowance (the app translates them).
REASON_MESSAGES = {
    "disabled": "AI transcription is not enabled for this group",
    "recordings": "Monthly recording quota exceeded",
    "minutes": "Monthly audio quota exceeded",
    "group_minutes": "Group AI quota exceeded",
    "duration": "Recording too long",
}


def uses_ai(entry) -> bool:
    return entry.get("timing", "ai") == "ai"


def _ai_uploads_this_month(group_id) -> list:
    """The group's AI audio that uses up quota: created this month and not failed."""
    return [
        entry
        for recording in repo.list("recordings") if recording["group_id"] == group_id
        for entry in recording["audio"].values()
        if uses_ai(entry) and entry["created_at"][:7] == current_month() and entry["status"] != "failed"
    ]


def ai_allowance(group_id, user, membership) -> dict:
    """What `user` may still have transcribed by AI in the group this month.

        {"enabled": bool, "reason": None | "disabled" | "recordings" | "minutes" | "group_minutes",
         "remaining_recordings": int | None, "remaining_minutes": float | None,
         "max_duration_minutes": int | None}

    None means unlimited. remaining_minutes is the smaller of the user's and the group's.
    """
    group = repo.get("groups", group_id)
    ai = group.get("ai") or {}
    result = {"enabled": True, "reason": None, "remaining_recordings": None,
              "remaining_minutes": None, "max_duration_minutes": None}
    if not ai.get("enabled", True):
        return {**result, "enabled": False, "reason": "disabled"}

    group_uploads = _ai_uploads_this_month(group_id)
    my_uploads = [a for a in group_uploads if a["uploader_id"] == user["id"]]
    quota = membership.get("quota", {})

    limit = quota.get("max_recordings_per_month")
    if limit is not None:
        result["remaining_recordings"] = max(0, limit - len(my_uploads))
        if len(my_uploads) >= limit:
            result.update(enabled=False, reason="recordings")

    remaining = []
    limit = quota.get("max_audio_minutes_per_month")
    if limit is not None:
        remaining.append(("minutes", limit - sum(a["duration_seconds"] for a in my_uploads) / 60))
    limit = ai.get("monthly_audio_minutes_limit")
    if limit is not None:
        remaining.append(("group_minutes", limit - sum(a["duration_seconds"] for a in group_uploads) / 60))
    if remaining:
        reason, minutes = min(remaining, key=lambda r: r[1])
        result["remaining_minutes"] = max(0.0, round(minutes, 2))
        if minutes <= 0 and result["enabled"]:
            result.update(enabled=False, reason=reason)

    result["max_duration_minutes"] = quota.get("max_recording_duration_minutes")
    return result


def check_ai_quota(group_id, user, membership, new_seconds):
    """Fail with 403 if AI transcription of `new_seconds` of audio isn't allowed.

    Call this while holding `repo.lock`, and save the new audio entry before
    releasing it - otherwise two simultaneous requests could both pass the check.
    """
    allowance = ai_allowance(group_id, user, membership)
    if not allowance["enabled"]:
        fail(403, REASON_MESSAGES[allowance["reason"]])
    if allowance["max_duration_minutes"] is not None and new_seconds > allowance["max_duration_minutes"] * 60:
        fail(403, REASON_MESSAGES["duration"])

    # Which limit is hit decides the message, so check them one by one.
    group = repo.get("groups", group_id)
    group_uploads = _ai_uploads_this_month(group_id)
    my_seconds = sum(a["duration_seconds"] for a in group_uploads if a["uploader_id"] == user["id"])
    limit = membership.get("quota", {}).get("max_audio_minutes_per_month")
    if limit is not None and my_seconds + new_seconds > limit * 60:
        fail(403, REASON_MESSAGES["minutes"])
    limit = (group.get("ai") or {}).get("monthly_audio_minutes_limit")
    if limit is not None and sum(a["duration_seconds"] for a in group_uploads) + new_seconds > limit * 60:
        fail(403, REASON_MESSAGES["group_minutes"])


# --- Sharing recordings made from the user's own texts ------------------------
#
# group["shareRecords"]: how many recordings with their own texts (a JSON or ODT
# file, "manual" timing) each member may share in the group per month. 0 means
# members can't share at all (the "Basic" group). AI recordings don't count:
# they are limited by the AI quotas above.

DEFAULT_SHARE_RECORDS = 100


def share_limit(group) -> int:
    """The group's monthly share limit per member (see above). Groups saved before
    the field existed get 0 if they are privilege-0 ("Basic"), else DEFAULT_SHARE_RECORDS."""
    value = group.get("shareRecords")
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    return 0 if group.get("privilege") == 0 else DEFAULT_SHARE_RECORDS


def is_shared_file(recording) -> bool:
    """Whether the recording was shared with the user's own texts (not made by AI)."""
    source = recording.get("source")
    if source:
        return source == "file"
    return any(not uses_ai(entry) for entry in recording["audio"].values())


def share_allowance(group_id, user) -> dict:
    """How many recordings `user` may still share in the group this month:
        {"enabled": bool, "limit": int | None, "used": int, "remaining": int | None}
    None means unlimited (system admins)."""
    group = repo.get("groups", group_id)
    used = sum(
        1 for r in repo.list("recordings")
        if r["group_id"] == group_id and r.get("uploader_id") == user["id"]
        and r.get("created_at", "")[:7] == current_month() and is_shared_file(r)
    )
    if user.get("system_admin"):
        return {"enabled": True, "limit": None, "used": used, "remaining": None}
    limit = share_limit(group)
    remaining = max(0, limit - used)
    return {"enabled": remaining > 0, "limit": limit, "used": used, "remaining": remaining}


def check_share_quota(group_id, user):
    """Fail with 403 unless `user` may share one more recording in the group.
    Call it holding `repo.lock` and save the recording before releasing it."""
    allowance = share_allowance(group_id, user)
    if not allowance["enabled"]:
        fail(403, "Sharing recordings is not allowed in this group" if allowance["limit"] == 0
             else "Monthly sharing quota exceeded")
