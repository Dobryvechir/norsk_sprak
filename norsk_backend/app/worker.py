"""
Background transcription worker.

Run it as a separate process next to the API server (exactly one worker):

    python -m app.worker

It loops forever: pick the next audio with status "pending" (any recording,
any language), transcribe it in its language, save the sentences and timings,
and record the usage. The audio's status goes:

    pending -> processing -> ready     (success)
                          -> failed    (error message saved in "error")

A failed audio can be queued again with POST /api/recordings/{id}/transcribe/{lang}.
"""

import time

from .helpers import utc_now_iso
from .migrations import upgrade_recordings
from .repository import repo
from .storage import get_storage
from .transcription import transcribe

IDLE_SLEEP_SECONDS = 3  # how long to wait when there's nothing to do


def recover_interrupted_jobs() -> int:
    """Put audio left in "processing" back to "pending".

    Only one worker runs, so at startup nothing can really be processing: any
    such audio was interrupted by a crash or restart, and would otherwise
    stay stuck forever. Returns how many were reset.
    """
    count = 0
    for recording in repo.list("recordings"):
        stuck = [entry for entry in recording["audio"].values() if entry["status"] == "processing"]
        for entry in stuck:
            entry["status"] = "pending"
        if stuck:
            repo.put("recordings", recording["id"], recording)
            count += len(stuck)
    return count


def save_result(recording_id, lang, audio_key, changes, sentences=None) -> bool:
    """Apply the worker's results to the current copy of the recording.

    Transcription takes long, and meanwhile the recording may have been
    deleted, the audio replaced (new audio_key), or other languages edited.
    So only this language's audio entry (and sentences) are changed, and only
    if it is still the same audio. Returns False if it is gone.
    """
    with repo.lock:
        recording = repo.get("recordings", recording_id)
        entry = recording and recording["audio"].get(lang)
        if not entry or entry["audio_key"] != audio_key:
            return False
        entry.update(changes)
        if sentences is not None:
            recording["sentences"][lang] = sentences
        repo.put("recordings", recording_id, recording)
        return True


def next_pending():
    """(recording, language) of the next audio to transcribe, or (None, None)."""
    for recording in repo.list("recordings"):
        for lang, entry in recording["audio"].items():
            if entry["status"] == "pending":
                return recording, lang
    return None, None


def run_once() -> bool:
    """Process at most one pending audio.

    Returns True if something was picked up (successfully or not),
    False if there was nothing pending.
    """
    recording, lang = next_pending()
    if recording is None:
        return False
    entry = recording["audio"][lang]
    audio_key = entry["audio_key"]

    # Mark it straight away so the app shows it is being worked on.
    if not save_result(recording["id"], lang, audio_key, {"status": "processing"}):
        return True  # deleted or replaced since we listed it

    try:
        ai = repo.get("groups", recording["group_id"])["ai"]
        audio_path = get_storage().get(audio_key)
        sentences = transcribe(audio_path, ai["provider"], ai["model"], language=lang)

        save_result(recording["id"], lang, audio_key, {
            "status": "ready",
            "error": None,
            "start_ms": [s["start_ms"] for s in sentences],
            "end_ms": [s["end_ms"] for s in sentences],
        }, sentences=[s["text"] for s in sentences])

        # One usage record per transcribed audio. Written even if the
        # recording is deleted meanwhile: the AI minutes were spent either way.
        usage_id = f"{recording['id']}_{lang}"
        repo.put("usage", usage_id, {
            "id": usage_id,
            "recording_id": recording["id"],
            "language": lang,
            "group_id": recording["group_id"],
            "user_id": entry["uploader_id"],
            "audio_minutes": entry["duration_seconds"] / 60,
            "provider": ai["provider"],
            "model": ai["model"],
            "created_at": utc_now_iso(),
        })
    except Exception as e:
        # Keep stored error messages short.
        save_result(recording["id"], lang, audio_key, {"status": "failed", "error": str(e)[:500]})

    return True


if __name__ == "__main__":
    upgraded = upgrade_recordings()
    if upgraded:
        print(f"Converted {upgraded} recording(s) to the multi-language format")
    recovered = recover_interrupted_jobs()
    if recovered:
        print(f"Re-queued {recovered} audio file(s) interrupted by a previous shutdown")
    while True:
        if not run_once():
            time.sleep(IDLE_SLEEP_SECONDS)
