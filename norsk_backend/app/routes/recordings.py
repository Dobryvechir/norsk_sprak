"""
Recording endpoints: upload, list, read, play audio, edit sentences, delete,
and (re)queue transcription.

A recording has a name and, per language, an audio file and sentences:

    "audio":     {"nb": {"audio_key": ..., "status": "ready",
                         "start_ms": [0, 1450], "end_ms": [1440, 2750], ...},
                  "en": {...}}
    "sentences": {"nb": ["Hei.", "Hvordan har du det?"],
                  "en": ["Hi.", "How are you?"]}

Neither map has to contain every language, and a language can have sentences
without audio (a translation). Sentence i means the same sentence in every
language; audio[lang]["start_ms"][i] / ["end_ms"][i] is where it is spoken in
that language's audio. See docs/data-model.md.

The life of one language's audio:
    1. Uploaded         -> status "pending"
    2. Worker picks it  -> "processing"
    3. Worker finishes  -> "ready" (sentences[lang] and timings filled in)
                           or "failed" (error set)
"""

import os
import pathlib
import tempfile

from fastapi import APIRouter, Depends, File, Form, UploadFile
from fastapi.responses import FileResponse

from ..config import settings
from ..helpers import LANGUAGES, fail, new_id, utc_now_iso
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
TIMESTAMP_SLACK_MS = 500  # a sentence may end this much past the end of the audio


# --- Helpers -----------------------------------------------------------------

def check_language(lang):
    """Fail with 422 unless `lang` is one of the supported language codes."""
    if lang not in LANGUAGES:
        fail(422, "Unsupported language")


def public_recording(recording) -> dict:
    """Copy of a recording for clients: without the internal storage keys."""
    audio = {
        lang: {k: v for k, v in entry.items() if k != "audio_key"}
        for lang, entry in recording["audio"].items()
    }
    return {**recording, "audio": audio}


def sentence_count(recording) -> int:
    """Number of sentences: the longest sentence list or timing list of any language."""
    lengths = [len(texts) for texts in recording["sentences"].values()]
    lengths += [len(entry["start_ms"]) for entry in recording["audio"].values()]
    return max(lengths, default=0)


def get_recording_for(user, recording_id) -> dict:
    """Load a recording, failing with 404 if missing or 403 if `user` isn't a
    member of its group."""
    recording = repo.get("recordings", recording_id)
    if not recording:
        fail(404, "Recording not found")
    get_membership(user, recording["group_id"])
    return recording


def get_audio_entry(recording, lang) -> dict:
    """The recording's audio in `lang`, failing with 404 if there is none."""
    check_language(lang)
    entry = recording["audio"].get(lang)
    if not entry:
        fail(404, "No audio in this language")
    return entry


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


def receive_audio(gid, recording_id, lang, user, membership, file: UploadFile, save) -> dict:
    """Shared upload steps: check the file, check quotas, store the audio, and
    call `save(entry)` with the new audio entry so the caller can put it into
    the recording. Returns the entry.

    The lock is held from the quota check until `save` has run, so two
    simultaneous uploads can't both squeeze under the same limit.
    """
    tmp_path = save_upload_to_temp_file(file)
    try:
        # ffprobe doubles as a check that the file really is audio.
        try:
            seconds = get_duration(tmp_path)
        except Exception:
            fail(422, "Unsupported or invalid audio file (ffprobe required)")
        if seconds <= 0 or seconds > MAX_DURATION_SECONDS:
            fail(422, "Invalid duration (maximum 90 minutes)")

        with repo.lock:
            check_upload_quota(gid, user, membership, seconds)

            # A fresh key per upload, so a replaced file never shares its key
            # with the new one (the worker uses the key to spot replacements).
            audio_key = f"{gid}/{recording_id}_{lang}_{new_id()[:8]}{storage_extension(file.filename)}"
            with open(tmp_path, "rb") as source:
                audio_key = get_storage().save(audio_key, source) or audio_key

            entry = {
                "audio_key": audio_key,
                "status": "pending",
                "error": None,
                "duration_seconds": seconds,
                "uploader_id": user["id"],
                "created_at": utc_now_iso(),
                "start_ms": [],
                "end_ms": [],
            }
            save(entry)
        return entry
    finally:
        pathlib.Path(tmp_path).unlink(missing_ok=True)


# --- Endpoints ----------------------------------------------------------------

@router.post("/api/groups/{gid}/recordings", status_code=202)
def upload_recording(
    gid: str,
    name: str = Form(...),
    language: str = Form(...),
    file: UploadFile = File(...),
    user=Depends(current_user),
):
    """Create a recording from an audio file in `language`. It is queued for
    transcription automatically."""
    membership = require_role(user, gid, [UPLOADER, ADMIN])
    if not name.strip() or len(name) > MAX_NAME_LENGTH:
        fail(422, "Invalid name")
    check_language(language)

    recording_id = new_id()

    def save(entry):
        repo.put("recordings", recording_id, {
            "id": recording_id,
            "group_id": gid,
            "name": name.strip(),
            "uploader_id": user["id"],
            "created_at": utc_now_iso(),
            "audio": {language: entry},
            "sentences": {},
        })

    receive_audio(gid, recording_id, language, user, membership, file, save)
    return {"id": recording_id, "language": language, "status": "pending"}


@router.put("/api/recordings/{rid}/audio/{lang}", status_code=202)
def upload_audio(rid: str, lang: str, file: UploadFile = File(...), user=Depends(current_user)):
    """Add the audio in another language to a recording, or replace the audio
    of a language. It is queued for transcription automatically."""
    recording = get_recording_for(user, rid)
    check_language(lang)
    gid = recording["group_id"]
    membership = require_role(user, gid, [UPLOADER, ADMIN])
    replaced = {}

    def save(entry):
        current = repo.get("recordings", rid)  # fresh copy: we are under the lock now
        if not current:
            fail(404, "Recording not found")
        replaced["entry"] = current["audio"].get(lang)
        current["audio"][lang] = entry
        repo.put("recordings", rid, current)

    receive_audio(gid, rid, lang, user, membership, file, save)
    if replaced.get("entry"):
        get_storage().delete(replaced["entry"]["audio_key"])
    return {"id": rid, "language": lang, "status": "pending"}


@router.get("/api/groups/{gid}/recordings")
def list_recordings(gid: str, user=Depends(current_user)):
    """All recordings in the group (any member may list)."""
    get_membership(user, gid)
    return [public_recording(r) for r in repo.list("recordings") if r["group_id"] == gid]


@router.get("/api/recordings/{rid}")
def get_recording(rid: str, user=Depends(current_user)):
    """One recording, including its sentences in every language."""
    return public_recording(get_recording_for(user, rid))


@router.get("/api/recordings/{rid}/audio/{lang}")
def get_audio(rid: str, lang: str, user=Depends(current_user)):
    """Download/stream the recording's audio file in `lang`."""
    recording = get_recording_for(user, rid)
    entry = get_audio_entry(recording, lang)
    try:
        path = get_storage().get(entry["audio_key"])
    except FileNotFoundError:
        fail(404, "Audio missing")
    return FileResponse(path, filename=f"{recording['name']} ({lang}){path.suffix}")


@router.patch("/api/recordings/{rid}/sentences/{lang}/{index}")
def edit_sentence(rid: str, lang: str, index: int, data: SentenceEditRequest, user=Depends(current_user)):
    """Correct one sentence in `lang`: its text and/or its timing in that
    language's audio.

    Text can be set for any language, which is how translations are added;
    the language's list is padded with empty strings up to `index`.
    """
    recording = get_recording_for(user, rid)
    require_role(user, recording["group_id"], [UPLOADER, ADMIN])
    check_language(lang)

    has_timing = data.start_ms is not None or data.end_ms is not None
    if data.text is None and not has_timing:
        fail(422, "Nothing to change")
    if index < 0 or index >= sentence_count(recording):
        fail(404, "Sentence not found")

    entry = recording["audio"].get(lang)
    if has_timing:
        if data.start_ms is None or data.end_ms is None:
            fail(422, "Give both start_ms and end_ms")
        if not entry or index >= len(entry["start_ms"]):
            fail(404, "No timing for this sentence in this language")
        max_end_ms = entry["duration_seconds"] * 1000 + TIMESTAMP_SLACK_MS
        if data.end_ms <= data.start_ms or data.end_ms > max_end_ms:
            fail(422, "Invalid timestamp range")
        entry["start_ms"][index] = data.start_ms
        entry["end_ms"][index] = data.end_ms

    if data.text is not None:
        texts = recording["sentences"].setdefault(lang, [])
        texts.extend([""] * (index + 1 - len(texts)))
        texts[index] = data.text

    repo.put("recordings", rid, recording)
    texts = recording["sentences"].get(lang, [])
    has_entry_timing = bool(entry) and index < len(entry["start_ms"])
    return {
        "index": index,
        "language": lang,
        "text": texts[index] if index < len(texts) else "",
        "start_ms": entry["start_ms"][index] if has_entry_timing else None,
        "end_ms": entry["end_ms"][index] if has_entry_timing else None,
    }


@router.delete("/api/recordings/{rid}")
def delete_recording(rid: str, user=Depends(current_user)):
    """Delete the recording and its audio files in every language. Group admins only."""
    recording = get_recording_for(user, rid)
    require_role(user, recording["group_id"], [ADMIN])
    for entry in recording["audio"].values():
        get_storage().delete(entry["audio_key"])
    repo.delete("recordings", rid)
    return {"deleted": True}


@router.post("/api/recordings/{rid}/transcribe/{lang}", status_code=202)
def queue_transcription(rid: str, lang: str, user=Depends(current_user)):
    """Put a pending or failed audio (back) in the transcription queue."""
    recording = get_recording_for(user, rid)
    require_role(user, recording["group_id"], [UPLOADER, ADMIN])
    entry = get_audio_entry(recording, lang)
    if entry["status"] not in ("pending", "failed"):
        fail(409, "Job already processed or running")

    entry["status"] = "pending"
    entry["error"] = None
    repo.put("recordings", rid, recording)
    return {"status": "pending", "id": rid, "language": lang}
