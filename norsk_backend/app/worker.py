"""
Background transcription worker.

Run it as a separate process next to the API server (exactly one worker):

    python -m app.worker

It loops forever: pick the next recording with status "pending", transcribe
it, save the sentences, and record the usage. Recording status goes:

    pending -> processing -> ready     (success)
                          -> failed    (error message saved in "error")

A failed recording can be queued again with POST /api/recordings/{id}/transcribe.
"""

import time

from .helpers import utc_now_iso
from .repository import repo
from .storage import get_storage
from .transcription import transcribe

IDLE_SLEEP_SECONDS = 3  # how long to wait when there's nothing to do


def recover_interrupted_jobs() -> int:
    """Put recordings left in "processing" back to "pending".

    Only one worker runs, so at startup nothing can really be processing: any
    such recording was interrupted by a crash or restart, and would otherwise
    stay stuck forever. Returns how many were reset.
    """
    count = 0
    for recording in repo.list("recordings"):
        if recording["status"] == "processing":
            recording["status"] = "pending"
            repo.put("recordings", recording["id"], recording)
            count += 1
    return count


def save_if_still_exists(recording) -> bool:
    """Save the worker's copy of a recording, unless it was deleted meanwhile.

    The worker holds its own copy for the whole (long) transcription. Saving it
    blindly would re-create a recording an admin deleted in the meantime.
    """
    with repo.lock:
        if repo.get("recordings", recording["id"]) is None:
            return False
        repo.put("recordings", recording["id"], recording)
        return True


def run_once() -> bool:
    """Process at most one pending recording.

    Returns True if a recording was processed (successfully or not),
    False if there was nothing pending.
    """
    for recording in repo.list("recordings"):
        if recording["status"] != "pending":
            continue

        # Mark it straight away so the app shows it is being worked on.
        recording["status"] = "processing"
        if not save_if_still_exists(recording):
            continue  # deleted since we listed it

        try:
            ai = repo.get("groups", recording["group_id"])["ai"]
            audio_path = get_storage().get(recording["audio_key"])

            recording["sentences"] = transcribe(audio_path, ai["provider"], ai["model"])
            recording["status"] = "ready"
            recording["error"] = None

            # One usage record per recording (keyed by the recording ID).
            # Written even if the recording is deleted meanwhile: the AI
            # minutes were spent either way.
            repo.put("usage", recording["id"], {
                "id": recording["id"],
                "group_id": recording["group_id"],
                "user_id": recording["uploader_id"],
                "audio_minutes": recording["duration_seconds"] / 60,
                "provider": ai["provider"],
                "model": ai["model"],
                "created_at": utc_now_iso(),
            })
        except Exception as e:
            recording["status"] = "failed"
            recording["error"] = str(e)[:500]  # keep stored error messages short

        save_if_still_exists(recording)
        return True

    return False


if __name__ == "__main__":
    recovered = recover_interrupted_jobs()
    if recovered:
        print(f"Re-queued {recovered} recording(s) interrupted by a previous shutdown")
    while True:
        if not run_once():
            time.sleep(IDLE_SLEEP_SECONDS)
