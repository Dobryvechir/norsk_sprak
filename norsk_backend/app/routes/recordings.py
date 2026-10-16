"""
Recording endpoints: upload, list, read, play audio, edit sentences, delete,
and (re)queue transcription.

A recording's life:
    1. Uploaded         -> status "pending"
    2. Worker picks it  -> "processing"
    3. Worker finishes  -> "ready" (sentences filled in) or "failed" (error set)
"""

import os
import pathlib
import tempfile

from fastapi import APIRouter, Depends, File, Form, UploadFile
from fastapi.responses import FileResponse

from ..config import settings
from ..helpers import fail, new_id, utc_now_iso
from ..quotas import check_upload_quota
from ..repository import repo
from ..schemas import SentenceEditRequest
from ..security import ADMIN, UPLOADER, current_user, get_membership, require_role
from ..storage import get_storage
from ..transcription import get_duration

router = APIRouter()

ALLOWED_EXTENSIONS = (".mp3", ".m4a", ".wav", ".ogg", ".opus", ".mp4", ".aac", ".flac")
FALLBACK_EXTENSION = ".audio"  # used when the uploaded file name has another extension
MAX_DURATION_SECONDS = 90 * 60
MAX_NAME_LENGTH = 200
UPLOAD_CHUNK_SIZE = 1024 * 1024


# --- Helpers -----------------------------------------------------------------

def without_audio_key(recording) -> dict:
    """Copy of a recording without the internal storage key (not for clients)."""
    return {k: v for k, v in recording.items() if k != "audio_key"}


def get_recording_for(user, recording_id) -> dict:
    """Load a recording, failing with 404 if missing or 403 if `user` isn't a
    member of its group."""
    recording = repo.get("recordings", recording_id)
    if not recording:
        fail(404, "Recording not found")
    get_membership(user, recording["group_id"])
    return recording


def save_upload_to_temp_file(upload: UploadFile) -> str:
    """Stream the uploaded file to a temporary file and return its path.

    Fails with 413 as soon as the file exceeds MAX_UPLOAD_MB, without reading
    the rest. The caller must delete the temp file afterwards.
    """
    temp_dir = pathlib.Path(settings.data_dir) / "temp"
    temp_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=temp_dir)
    max_bytes = settings.max_upload_mb * 1024 * 1024
    try:
        with os.fdopen(fd, "wb") as out:
            size = 0
            while chunk := upload.file.read(UPLOAD_CHUNK_SIZE):
                size += len(chunk)
                if size > max_bytes:
                    fail(413, "File too large")
                out.write(chunk)
    except BaseException:
        pathlib.Path(tmp_path).unlink(missing_ok=True)
        raise
    return tmp_path


def storage_extension(filename) -> str:
    """Pick the file extension used when storing the audio."""
    ext = pathlib.Path(filename or "").suffix.lower()
    return ext if ext in ALLOWED_EXTENSIONS else FALLBACK_EXTENSION


# --- Endpoints ----------------------------------------------------------------

@router.post("/api/groups/{gid}/recordings", status_code=202)
def upload_recording(
    gid: str,
    name: str = Form(...),
    file: UploadFile = File(...),
    user=Depends(current_user),
):
    """Upload an audio file. It is queued for transcription automatically."""
    membership = require_role(user, gid, [UPLOADER, ADMIN])
    if not name.strip() or len(name) > MAX_NAME_LENGTH:
        fail(422, "Invalid name")

    tmp_path = save_upload_to_temp_file(file)
    try:
        # ffprobe doubles as a check that the file really is audio.
        try:
            seconds = get_duration(tmp_path)
        except Exception:
            fail(422, "Unsupported or invalid audio file (ffprobe required)")
        if seconds <= 0 or seconds > MAX_DURATION_SECONDS:
            fail(422, "Invalid duration (maximum 90 minutes)")

        # Hold the lock from quota check until the recording is saved, so two
        # simultaneous uploads can't both squeeze under the same limit.
        with repo.lock:
            check_upload_quota(gid, user, membership, seconds)

            recording_id = new_id()
            audio_key = f"{gid}/{recording_id}{storage_extension(file.filename)}"
            with open(tmp_path, "rb") as source:
                audio_key = get_storage().save(audio_key, source) or audio_key

            repo.put("recordings", recording_id, {
                "id": recording_id,
                "group_id": gid,
                "name": name.strip(),
                "uploader_id": user["id"],
                "created_at": utc_now_iso(),
                "duration_seconds": seconds,
                "audio_key": audio_key,
                "status": "pending",
                "sentences": [],
                "error": None,
            })
        return {"id": recording_id, "status": "pending"}
    finally:
        pathlib.Path(tmp_path).unlink(missing_ok=True)


@router.get("/api/groups/{gid}/recordings")
def list_recordings(gid: str, user=Depends(current_user)):
    """All recordings in the group (any member may list)."""
    get_membership(user, gid)
    return [without_audio_key(r) for r in repo.list("recordings") if r["group_id"] == gid]


@router.get("/api/recordings/{rid}")
def get_recording(rid: str, user=Depends(current_user)):
    """One recording, including its sentences."""
    return without_audio_key(get_recording_for(user, rid))


@router.get("/api/recordings/{rid}/audio")
def get_audio(rid: str, user=Depends(current_user)):
    """Download/stream the recording's audio file."""
    recording = get_recording_for(user, rid)
    try:
        path = get_storage().get(recording["audio_key"])
    except FileNotFoundError:
        fail(404, "Audio missing")
    return FileResponse(path, filename=recording["name"] + path.suffix)


@router.patch("/api/recordings/{rid}/sentences/{index}")
def edit_sentence(rid: str, index: int, data: SentenceEditRequest, user=Depends(current_user)):
    """Correct one sentence's text and timing."""
    recording = get_recording_for(user, rid)
    require_role(user, recording["group_id"], [UPLOADER, ADMIN])

    if index < 0 or index >= len(recording["sentences"]):
        fail(404, "Sentence not found")
    # End must be after start, and not past the end of the audio (+0.5 s slack).
    max_end_ms = recording["duration_seconds"] * 1000 + 500
    if data.end_ms <= data.start_ms or data.end_ms > max_end_ms:
        fail(422, "Invalid timestamp range")

    sentence = recording["sentences"][index]
    sentence.update(data.model_dump())
    repo.put("recordings", rid, recording)
    return sentence


@router.delete("/api/recordings/{rid}")
def delete_recording(rid: str, user=Depends(current_user)):
    """Delete the recording and its audio file. Group admins only."""
    recording = get_recording_for(user, rid)
    require_role(user, recording["group_id"], [ADMIN])
    get_storage().delete(recording["audio_key"])
    repo.delete("recordings", rid)
    return {"deleted": True}


@router.post("/api/recordings/{rid}/transcribe", status_code=202)
def queue_transcription(rid: str, user=Depends(current_user)):
    """Put a pending or failed recording (back) in the transcription queue."""
    recording = get_recording_for(user, rid)
    require_role(user, recording["group_id"], [UPLOADER, ADMIN])
    if recording["status"] not in ("pending", "failed"):
        fail(409, "Job already processed or running")

    recording["status"] = "pending"
    recording["error"] = None
    repo.put("recordings", rid, recording)
    return {"status": "pending", "id": rid}
