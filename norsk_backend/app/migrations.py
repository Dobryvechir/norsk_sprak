"""
One-off conversions of stored data to newer formats.

Each function is safe to run at every startup: it skips data that is already
converted. Both the API server and the worker run them when they start.
"""

from .repository import repo

# Recordings made before multi-language support were all transcribed as Norwegian.
OLD_RECORDING_LANGUAGE = "nb"


def upgrade_recordings() -> int:
    """Convert recordings from the single-language format (top-level audio_key,
    status, error, duration_seconds and a list of sentence objects) to the
    per-language `audio` and `sentences` maps. Returns how many were converted.
    """
    count = 0
    with repo.lock:
        for recording in repo.list("recordings"):
            if "audio" in recording:
                continue
            old_sentences = recording.get("sentences") or []
            recording["audio"] = {OLD_RECORDING_LANGUAGE: {
                "audio_key": recording.pop("audio_key"),
                "status": recording.pop("status"),
                "error": recording.pop("error", None),
                "duration_seconds": recording.pop("duration_seconds"),
                "uploader_id": recording["uploader_id"],
                "created_at": recording["created_at"],
                "start_ms": [s["start_ms"] for s in old_sentences],
                "end_ms": [s["end_ms"] for s in old_sentences],
            }}
            recording["sentences"] = (
                {OLD_RECORDING_LANGUAGE: [s["text"] for s in old_sentences]} if old_sentences else {}
            )
            repo.put("recordings", recording["id"], recording)
            count += 1
    return count
