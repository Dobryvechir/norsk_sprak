"""Regression tests for recordings: upload, languages, editing, deleting, and the worker."""

from pathlib import Path

from fastapi.testclient import TestClient

from app import worker
from app.config import settings
from app.helpers import new_id, utc_now_iso
from app.main import app
from app.migrations import upgrade_recordings
from app.repository import repo
from app.routes import recordings
from app.security import create_token

client = TestClient(app)


def make_admin_headers():
    admin = {"id": new_id(), "email": f"{new_id()}@test.no", "password_hash": "-",
             "system_admin": True, "enabled": True}
    repo.put("users", admin["id"], admin)
    return {"Authorization": "Bearer " + create_token(admin)}


def make_group():
    group = {"id": new_id(), "name": "Test", "created_at": utc_now_iso(),
             "ai": {"provider": "openai", "model": "whisper-1", "monthly_audio_minutes_limit": None}}
    repo.put("groups", group["id"], group)
    return group


def make_audio_entry(group_id, recording_id, lang, status="pending", with_audio_file=True, timings=0):
    audio_key = f"{group_id}/{recording_id}_{lang}.wav"
    if with_audio_file:
        path = Path(settings.data_dir) / "audio" / audio_key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fake audio")
    return {"audio_key": audio_key, "status": status, "error": None, "duration_seconds": 3.0,
            "uploader_id": "someone", "created_at": utc_now_iso(),
            "start_ms": [i * 1000 for i in range(timings)], "end_ms": [i * 1000 + 900 for i in range(timings)]}


def make_recording(status="pending", with_audio_file=True, lang="nb", sentences=None):
    """Save a group + recording directly in the repository (no upload/ffprobe)."""
    group = make_group()
    recording_id = new_id()
    sentences = sentences or {}
    timings = len(sentences.get(lang, []))
    recording = {"id": recording_id, "group_id": group["id"], "name": "Opptak",
                 "uploader_id": "someone", "created_at": utc_now_iso(),
                 "audio": {lang: make_audio_entry(group["id"], recording_id, lang, status, with_audio_file, timings)},
                 "sentences": sentences}
    repo.put("recordings", recording_id, recording)
    return recording


def test_delete_recording_whose_audio_file_is_missing():
    recording = make_recording(with_audio_file=False)

    response = client.delete(f"/api/recordings/{recording['id']}", headers=make_admin_headers())

    assert response.status_code == 200
    assert repo.get("recordings", recording["id"]) is None


def test_worker_does_not_recreate_recording_deleted_during_transcription(monkeypatch):
    recording = make_recording()

    def transcribe_while_admin_deletes(path, provider, model, language):
        repo.delete("recordings", recording["id"])  # deleted mid-transcription
        return [{"index": 0, "text": "Hei.", "start_ms": 0, "end_ms": 400}]

    monkeypatch.setattr(worker, "transcribe", transcribe_while_admin_deletes)
    worker.run_once()

    assert repo.get("recordings", recording["id"]) is None


def test_worker_saves_sentences_and_timings_for_the_audio_language(monkeypatch):
    recording = make_recording(lang="en", sentences={"nb": ["Hei.", "God dag."]})
    calls = []

    def fake_transcribe(path, provider, model, language):
        calls.append(language)
        return [{"index": 0, "text": "Hi.", "start_ms": 0, "end_ms": 400},
                {"index": 1, "text": "Good day.", "start_ms": 500, "end_ms": 1200}]

    monkeypatch.setattr(worker, "transcribe", fake_transcribe)
    while worker.run_once():  # other tests may have left pending audio too
        pass

    saved = repo.get("recordings", recording["id"])
    assert "en" in calls
    assert saved["audio"]["en"]["status"] == "ready"
    assert saved["audio"]["en"]["start_ms"] == [0, 500]
    assert saved["audio"]["en"]["end_ms"] == [400, 1200]
    assert saved["sentences"] == {"nb": ["Hei.", "God dag."], "en": ["Hi.", "Good day."]}


def test_worker_ignores_result_for_audio_replaced_during_transcription(monkeypatch):
    recording = make_recording()

    def transcribe_while_replaced(path, provider, model, language):
        current = repo.get("recordings", recording["id"])
        current["audio"]["nb"] = {**current["audio"]["nb"], "audio_key": "new-key", "status": "pending"}
        repo.put("recordings", recording["id"], current)
        return [{"index": 0, "text": "Gammel.", "start_ms": 0, "end_ms": 400}]

    monkeypatch.setattr(worker, "transcribe", transcribe_while_replaced)
    worker.run_once()

    saved = repo.get("recordings", recording["id"])
    assert saved["audio"]["nb"]["status"] == "pending"
    assert saved["sentences"] == {}


def test_worker_startup_requeues_interrupted_audio():
    stuck = make_recording(status="processing")
    done = make_recording(status="ready")

    worker.recover_interrupted_jobs()

    assert repo.get("recordings", stuck["id"])["audio"]["nb"]["status"] == "pending"
    assert repo.get("recordings", done["id"])["audio"]["nb"]["status"] == "ready"


def test_upload_and_add_audio_in_another_language(monkeypatch):
    monkeypatch.setattr(recordings, "get_duration", lambda path: 3.0)
    headers = make_admin_headers()
    group = make_group()

    response = client.post(f"/api/groups/{group['id']}/recordings", headers=headers,
                           data={"name": "Leksjon 1", "language": "nb"},
                           files={"file": ("leksjon.mp3", b"fake", "audio/mpeg")})
    assert response.status_code == 202
    rid = response.json()["id"]

    response = client.put(f"/api/recordings/{rid}/audio/en", headers=headers,
                          files={"file": ("lesson.mp3", b"fake", "audio/mpeg")})
    assert response.status_code == 202

    body = client.get(f"/api/recordings/{rid}", headers=headers).json()
    assert set(body["audio"]) == {"nb", "en"}
    assert body["audio"]["en"]["status"] == "pending"
    assert all("audio_key" not in entry for entry in body["audio"].values())
    assert client.get(f"/api/recordings/{rid}/audio/en", headers=headers).status_code == 200
    assert client.get(f"/api/recordings/{rid}/audio/de", headers=headers).status_code == 404


def test_upload_rejects_unknown_language():
    group = make_group()
    response = client.post(f"/api/groups/{group['id']}/recordings", headers=make_admin_headers(),
                           data={"name": "X", "language": "xx"},
                           files={"file": ("x.mp3", b"fake", "audio/mpeg")})
    assert response.status_code == 422


def test_edit_sentence_text_adds_translation_and_timing_is_per_language():
    recording = make_recording(status="ready", sentences={"nb": ["Hei.", "God dag."]})
    headers = make_admin_headers()
    url = f"/api/recordings/{recording['id']}/sentences"

    response = client.patch(f"{url}/en/1", headers=headers, json={"text": "Good day."})
    assert response.status_code == 200
    assert repo.get("recordings", recording["id"])["sentences"]["en"] == ["", "Good day."]

    response = client.patch(f"{url}/nb/0", headers=headers, json={"start_ms": 100, "end_ms": 800})
    assert response.status_code == 200
    assert repo.get("recordings", recording["id"])["audio"]["nb"]["start_ms"][0] == 100

    # No English audio, so no English timing.
    assert client.patch(f"{url}/en/0", headers=headers, json={"start_ms": 0, "end_ms": 500}).status_code == 404
    assert client.patch(f"{url}/en/5", headers=headers, json={"text": "Too far"}).status_code == 404


def test_old_single_language_recordings_are_upgraded():
    group = make_group()
    old = {"id": new_id(), "group_id": group["id"], "name": "Gammel", "uploader_id": "u1",
           "created_at": utc_now_iso(), "duration_seconds": 3.0, "audio_key": "k.mp3",
           "status": "ready", "error": None,
           "sentences": [{"index": 0, "text": "Hei.", "start_ms": 0, "end_ms": 400}]}
    repo.put("recordings", old["id"], old)

    upgrade_recordings()

    new = repo.get("recordings", old["id"])
    assert new["sentences"] == {"nb": ["Hei."]}
    assert new["audio"]["nb"]["audio_key"] == "k.mp3"
    assert new["audio"]["nb"]["start_ms"] == [0] and new["audio"]["nb"]["end_ms"] == [400]
    assert "status" not in new and "audio_key" not in new
