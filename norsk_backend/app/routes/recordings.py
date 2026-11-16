"""
Recording endpoints: create, add a language, list, read, play audio, edit
sentences, delete, and (re)queue transcription.

A recording has a name and, per language, an audio and sentences:

    "audio":     {"nb": {"drive_id": ..., "timing": "ai", "status": "ready",
                         "start_ms": [0, 1450], "end_ms": [1440, 2750], ...},
                  "en": {...}}
    "sentences": {"nb": ["Hei.", "Hvordan har du det?"],
                  "en": ["Hi.", "How are you?"]}

Neither map has to contain every language, and a language can have sentences
without audio (a translation). Sentence i means the same sentence in every
language; audio[lang]["start_ms"][i] / ["end_ms"][i] is where it is spoken in
that language's audio.

Audio is never uploaded to us: it is an audio or video file the user saved
through Media on their own Google Drive, shared with anyone with the link, and
referred to by "drive_id" (see drive_media.py). Older entries have "audio_key"
(our own storage, AUDIO_BACKEND), and book chapters may have a "url", which
takes priority. See docs/data-model.md.

Texts and timings come either from the user ("timing": "manual", status
"ready" at once) or from AI transcription ("timing": "ai"), which only groups
that allow it get, within their quotas (quotas.py):
    1. Created          -> status "pending"  (the queue)
    2. Worker picks it  -> "processing"
    3. Worker finishes  -> "ready" (sentences[lang] and timings filled in, and
                           translated into the entry's "translate_to" languages)
                           or "failed" (error set)

Sharing: a recording made from the user's own texts ("source": "file") may be
created by any member of the group, as many per month as the group's
"shareRecords" allows (quotas.share_allowance); AI recordings ("source": "ai")
need the uploader or admin role and the AI quotas. A recording whose audio is
still in the queue (or failed) is shown only to its author and group admins:
the others see it once it is ready. It may be deleted by its author, group
admins and system admins.
"""

import json

from fastapi import APIRouter, Depends, Header
from fastapi.responses import FileResponse, RedirectResponse

from ..chat import display_name
from ..drive_media import check_drive_id, media_duration, stream_response
from ..helpers import LANGUAGES, fail, new_id, utc_now_iso
from ..quotas import ai_allowance, check_ai_quota, check_share_quota, share_allowance
from ..repository import repo
from ..schemas import NewRecordingRequest, RecordingMediaRequest, SentenceEditRequest
from ..security import ADMIN, UPLOADER, current_user, get_membership, require_role
from ..storage import get_storage

router = APIRouter()

MAX_DURATION_SECONDS = 90 * 60
MAX_SENTENCE_LENGTH = 2000
TIMESTAMP_SLACK_MS = 500  # a sentence may end this much past the end of the audio
# Language codes other programs use for one of ours.
LANGUAGE_ALIASES = {"no": "nb", "nob": "nb", "nno": "nn"}


# --- Helpers -----------------------------------------------------------------

def audio_response(entry, name, lang, range_header=None):
    """The response for one language's audio. An entry with a "url" (audio kept
    elsewhere, e.g. imported book chapters) redirects there; this takes priority.
    A "drive_id" is passed through from the user's Google Drive. Otherwise the
    file is served from the configured storage."""
    if entry.get("url"):
        return RedirectResponse(entry["url"], status_code=307)
    if entry.get("drive_id"):
        return stream_response(entry["drive_id"], range_header, entry.get("mime_type"))
    if not entry.get("audio_key"):
        fail(404, "Audio missing")
    try:
        path = get_storage().get(entry["audio_key"])
    except FileNotFoundError:
        fail(404, "Audio missing")
    return FileResponse(path, filename=f"{name} ({lang}){path.suffix}")


def delete_stored_audio(entry):
    """Remove the file of an entry kept in our own storage. Drive files are the
    user's own and are never deleted."""
    if entry and entry.get("audio_key"):
        get_storage().delete(entry["audio_key"])


def check_language(lang):
    """Fail with 422 unless `lang` is one of the supported language codes."""
    if lang not in LANGUAGES:
        fail(422, "Unsupported language")


def recording_size(recording) -> int:
    """Approximate size in bytes: the media files (as far as known) plus the texts."""
    media = sum(entry.get("size_bytes") or 0 for entry in recording["audio"].values())
    texts = len(json.dumps(recording["sentences"], ensure_ascii=False).encode("utf-8"))
    return media + texts


def is_ready(recording) -> bool:
    """Whether every audio of the recording has its texts and timings (none queued or failed)."""
    return all(entry["status"] == "ready" for entry in recording["audio"].values())


def can_manage(user, membership, recording) -> bool:
    """Its author, group admins and system admins (whose membership says admin)."""
    return recording.get("uploader_id") == user["id"] or membership["role"] == ADMIN


def public_recording(recording) -> dict:
    """Copy of a recording for clients: without the internal storage keys, with
    its author's name and approximate size."""
    audio = {
        lang: {k: v for k, v in entry.items() if k != "audio_key"}
        for lang, entry in recording["audio"].items()
    }
    author_id = recording.get("uploader_id")
    return {**recording, "audio": audio, "author": display_name(author_id) if author_id else "",
            "size_bytes": recording_size(recording)}


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
    membership = get_membership(user, recording["group_id"])
    # Not ready yet (queued or failed): only for those who may manage it.
    if not is_ready(recording) and not can_manage(user, membership, recording):
        fail(404, "Recording not found")
    return recording


def get_audio_entry(recording, lang) -> dict:
    """The recording's audio in `lang`, failing with 404 if there is none."""
    check_language(lang)
    entry = recording["audio"].get(lang)
    if not entry:
        fail(404, "No audio in this language")
    return entry


def manual_timing(data: RecordingMediaRequest, lang, seconds) -> tuple[list, list, dict]:
    """Check the user's own texts and timings: (start_ms, end_ms, sentences)."""
    starts = data.start_ms or []
    if not starts:
        fail(422, "Give start_ms for every sentence")
    count = len(starts)
    ends = list(data.end_ms or [None] * count)
    if len(ends) != count:
        fail(422, "start_ms and end_ms differ in length")
    audio_end_ms = round(seconds * 1000)
    for i, start in enumerate(starts):
        if start < 0 or (i and start < starts[i - 1]):
            fail(422, f"Sentence {i + 1}: start times must be ascending and not negative")
        if ends[i] is None:
            ends[i] = starts[i + 1] if i + 1 < count and starts[i + 1] > start else audio_end_ms
        if ends[i] <= start or ends[i] > audio_end_ms + TIMESTAMP_SLACK_MS:
            fail(422, f"Sentence {i + 1}: invalid time range (the media is {seconds:.0f} s long)")

    sentences = {}
    for code, texts in (data.sentences or {}).items():
        code = LANGUAGE_ALIASES.get(code, code)
        check_language(code)
        if len(texts) != count:
            fail(422, f"{code}: {len(texts)} sentences, but {count} timings")
        if any(len(t) > MAX_SENTENCE_LENGTH for t in texts):
            fail(422, f"{code}: a sentence is too long")
        sentences[code] = [t.strip() for t in texts]
    if not any(sentences.get(lang, [])):
        fail(422, "The texts in the language of the media are missing")
    return starts, ends, sentences


def receive_media(gid, recording_id, lang, user, membership, data: RecordingMediaRequest, save,
                  share=False, translate_to=()) -> dict:
    """Shared steps: check the Drive file and the texts or the AI quota, and call
    `save(entry, sentences)` with the new audio entry and the sentences to set
    (language -> texts; empty for AI). Returns the entry.

    The lock is held from the quota check until `save` has run, so two
    simultaneous requests can't both squeeze under the same limit. `share`: a
    new recording from the user's own texts, which counts against the group's
    share limit. `translate_to`: (AI) languages to translate the sentences into.
    """
    check_language(lang)
    check_drive_id(data.drive_id)
    # ffprobe doubles as a check that the file really is audio/video and is shared.
    seconds = media_duration(data.drive_id)
    if seconds <= 0 or seconds > MAX_DURATION_SECONDS:
        fail(422, "Invalid duration (maximum 90 minutes)")
    manual = data.mode == "manual"
    starts, ends, sentences = manual_timing(data, lang, seconds) if manual else ([], [], {})

    with repo.lock:
        if manual and share:
            check_share_quota(gid, user)
        if not manual:
            check_ai_quota(gid, user, membership, seconds)
        entry = {
            "drive_id": data.drive_id,
            "media_kind": data.media_kind,
            "mime_type": data.mime_type,
            "file_name": data.file_name,
            "size_bytes": data.size_bytes,
            "timing": data.mode,
            "status": "ready" if manual else "pending",
            "error": None,
            "duration_seconds": seconds,
            "uploader_id": user["id"],
            "created_at": utc_now_iso(),
            "start_ms": starts,
            "end_ms": ends,
        }
        if not manual and translate_to:
            entry["translate_to"] = list(translate_to)
        save(entry, sentences)
    return entry


# --- Endpoints ----------------------------------------------------------------

@router.get("/api/groups/{gid}/ai-allowance")
def get_ai_allowance(gid: str, user=Depends(current_user)):
    """Whether the user may have a recording transcribed by AI in this group now,
    and how much is left this month (see quotas.ai_allowance)."""
    membership = require_role(user, gid, [UPLOADER, ADMIN])
    return ai_allowance(gid, user, membership)


@router.get("/api/groups/{gid}/share-allowance")
def get_share_allowance(gid: str, user=Depends(current_user)):
    """How many recordings with their own texts the user may still share in
    this group this month (see quotas.share_allowance)."""
    get_membership(user, gid)
    return share_allowance(gid, user)


@router.post("/api/groups/{gid}/recordings", status_code=202)
def create_recording(gid: str, data: NewRecordingRequest, user=Depends(current_user)):
    """Create a recording from a media file on the user's Google Drive, spoken
    in `language`. With mode "manual" (the user's own texts) any member may
    share it, within the group's share limit. With mode "ai" (uploaders and
    admins) it is queued for transcription and translation into `translations`,
    and shown to the rest of the group once ready."""
    manual = data.mode == "manual"
    membership = get_membership(user, gid) if manual else require_role(user, gid, [UPLOADER, ADMIN])
    if not data.name.strip():
        fail(422, "Invalid name")
    check_language(data.language)
    translate_to = []
    for code in data.translations:
        code = LANGUAGE_ALIASES.get(code, code)
        check_language(code)
        if code != data.language and code not in translate_to:
            translate_to.append(code)
    recording_id = new_id()

    def save(entry, sentences):
        repo.put("recordings", recording_id, {
            "id": recording_id,
            "group_id": gid,
            "name": data.name.strip(),
            "uploader_id": user["id"],
            "created_at": utc_now_iso(),
            "source": "file" if manual else "ai",
            "audio": {data.language: entry},
            "sentences": sentences,
        })

    entry = receive_media(gid, recording_id, data.language, user, membership, data, save,
                          share=manual, translate_to=translate_to)
    return {"id": recording_id, "language": data.language, "status": entry["status"]}


@router.put("/api/recordings/{rid}/audio/{lang}", status_code=202)
def set_audio(rid: str, lang: str, data: RecordingMediaRequest, user=Depends(current_user)):
    """Add the audio in another language to a recording, or replace the audio of
    a language. With mode "manual" the given languages' sentences are replaced."""
    recording = get_recording_for(user, rid)
    gid = recording["group_id"]
    membership = require_role(user, gid, [UPLOADER, ADMIN])
    replaced = {}

    def save(entry, sentences):
        current = repo.get("recordings", rid)  # fresh copy: we are under the lock now
        if not current:
            fail(404, "Recording not found")
        replaced["entry"] = current["audio"].get(lang)
        current["audio"][lang] = entry
        current["sentences"].update(sentences)
        repo.put("recordings", rid, current)

    entry = receive_media(gid, rid, lang, user, membership, data, save)
    delete_stored_audio(replaced.get("entry"))
    return {"id": rid, "language": lang, "status": entry["status"]}


@router.get("/api/groups/{gid}/recordings")
def list_recordings(gid: str, user=Depends(current_user)):
    """The group's recordings (any member may list): the ready ones, and those
    still queued or failed that the user may manage (their own; all of them
    for group admins)."""
    membership = get_membership(user, gid)
    return [public_recording(r) for r in repo.list("recordings")
            if r["group_id"] == gid and (is_ready(r) or can_manage(user, membership, r))]


@router.get("/api/recordings/{rid}")
def get_recording(rid: str, user=Depends(current_user)):
    """One recording, including its sentences in every language."""
    return public_recording(get_recording_for(user, rid))


@router.get("/api/recordings/{rid}/audio/{lang}")
def get_audio(rid: str, lang: str, user=Depends(current_user),
              range_header: str | None = Header(None, alias="Range")):
    """Download/stream the recording's audio (or video) file in `lang`."""
    recording = get_recording_for(user, rid)
    return audio_response(get_audio_entry(recording, lang), recording["name"], lang, range_header)


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
    """Delete the recording, and its audio files kept in our storage (files on
    the user's Google Drive stay there). Its author, group admins and system admins."""
    recording = get_recording_for(user, rid)
    if not can_manage(user, get_membership(user, recording["group_id"]), recording):
        fail()
    for entry in recording["audio"].values():
        delete_stored_audio(entry)
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
