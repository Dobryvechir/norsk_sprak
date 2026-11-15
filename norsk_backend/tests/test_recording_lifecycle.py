"""Regression tests for recordings: media on Google Drive, languages, editing, deleting, and the worker."""

from pathlib import Path

import httpx
from fastapi.testclient import TestClient

from app import drive_media as drive_media_module
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


DRIVE_ID = "1AbCdEfGhIjKlMnOp_qrstuv"


def drive_media(monkeypatch, seconds=3.0):
    """Pretend every Drive file is shared and `seconds` long, and serve b"media" for it."""
    monkeypatch.setattr(recordings, "media_duration", lambda drive_id: seconds)

    def handler(request):
        assert request.url.params["id"] == DRIVE_ID
        return httpx.Response(200, stream=httpx.ByteStream(b"media"), headers={"content-type": "audio/mp4"})

    monkeypatch.setattr(drive_media_module, "http_client",
                        lambda: httpx.Client(transport=httpx.MockTransport(handler)))


def test_create_from_drive_with_ai_then_add_language_with_own_texts(monkeypatch):
    drive_media(monkeypatch)
    headers = make_admin_headers()
    group = make_group()

    response = client.post(f"/api/groups/{group['id']}/recordings", headers=headers, json={
        "name": "Leksjon 1", "language": "nb", "drive_id": DRIVE_ID, "media_kind": "video", "mode": "ai"})
    assert response.status_code == 202
    assert response.json()["status"] == "pending"
    rid = response.json()["id"]

    response = client.put(f"/api/recordings/{rid}/audio/en", headers=headers, json={
        "drive_id": DRIVE_ID, "mode": "manual", "start_ms": [0, 1500], "end_ms": [1400, None],
        "sentences": {"en": ["Hi.", "Good day."], "no": ["Hei.", "God dag."]}})
    assert response.status_code == 202
    assert response.json()["status"] == "ready"

    body = client.get(f"/api/recordings/{rid}", headers=headers).json()
    assert set(body["audio"]) == {"nb", "en"}
    assert body["audio"]["nb"]["timing"] == "ai" and body["audio"]["nb"]["media_kind"] == "video"
    assert body["audio"]["en"]["start_ms"] == [0, 1500]
    assert body["audio"]["en"]["end_ms"] == [1400, 3000]  # a missing end: the end of the media
    assert body["sentences"] == {"en": ["Hi.", "Good day."], "nb": ["Hei.", "God dag."]}
    response = client.get(f"/api/recordings/{rid}/audio/en", headers=headers)
    assert response.status_code == 200 and response.content == b"media"
    assert client.get(f"/api/recordings/{rid}/audio/de", headers=headers).status_code == 404

    # Deleting leaves the user's Drive file alone (nothing in our storage to delete).
    assert client.delete(f"/api/recordings/{rid}", headers=headers).status_code == 200


def test_manual_texts_are_checked(monkeypatch):
    drive_media(monkeypatch)
    headers = make_admin_headers()
    url = f"/api/groups/{make_group()['id']}/recordings"
    base = {"name": "X", "language": "nb", "drive_id": DRIVE_ID, "mode": "manual"}

    def post(**fields):
        return client.post(url, headers=headers, json={**base, **fields})

    assert post(start_ms=[0], sentences={"en": ["Hi."]}).status_code == 422          # no Norwegian text
    assert post(start_ms=[0, 1000], sentences={"nb": ["Hei."]}).status_code == 422   # counts differ
    assert post(start_ms=[1000, 0], sentences={"nb": ["A", "B"]}).status_code == 422  # not ascending
    assert post(start_ms=[0], end_ms=[9000], sentences={"nb": ["A"]}).status_code == 422  # past the end
    assert post(start_ms=[0], sentences={"xx": ["A"], "nb": ["A"]}).status_code == 422
    assert post(start_ms=[0, 1000], sentences={"nb": ["A", "B"]}).status_code == 202


def test_ai_needs_the_group_allowance_and_quota(monkeypatch):
    drive_media(monkeypatch, seconds=120.0)
    headers = make_admin_headers()
    group = make_group()
    body = {"name": "X", "language": "nb", "drive_id": DRIVE_ID, "mode": "ai"}
    url = f"/api/groups/{group['id']}/recordings"

    group["ai"]["monthly_audio_minutes_limit"] = 3
    repo.put("groups", group["id"], group)
    allowance = client.get(f"/api/groups/{group['id']}/ai-allowance", headers=headers).json()
    assert allowance["enabled"] is True and allowance["remaining_minutes"] == 3
    assert client.post(url, headers=headers, json=body).status_code == 202
    response = client.post(url, headers=headers, json=body)  # 2 + 2 minutes > 3
    assert response.status_code == 403 and response.json()["detail"] == "Group AI quota exceeded"

    # Own texts don't use AI, so they don't count and aren't limited.
    manual = {**body, "mode": "manual", "start_ms": [0], "sentences": {"nb": ["Hei."]}}
    assert client.post(url, headers=headers, json=manual).status_code == 202

    group["ai"]["enabled"] = False
    repo.put("groups", group["id"], group)
    allowance = client.get(f"/api/groups/{group['id']}/ai-allowance", headers=headers).json()
    assert allowance == {**allowance, "enabled": False, "reason": "disabled"}
    assert client.post(url, headers=headers, json=body).status_code == 403


def test_worker_transcribes_audio_from_drive(monkeypatch):
    drive_media(monkeypatch)
    group = make_group()
    recording_id = new_id()
    entry = {**make_audio_entry(group["id"], recording_id, "nb", with_audio_file=False), "drive_id": DRIVE_ID}
    del entry["audio_key"]
    repo.put("recordings", recording_id, {"id": recording_id, "group_id": group["id"], "name": "D",
                                          "uploader_id": "someone", "created_at": utc_now_iso(),
                                          "audio": {"nb": entry}, "sentences": {}})
    seen = []

    def fake_transcribe(path, provider, model, language):
        seen.append(Path(path).read_bytes())
        return [{"index": 0, "text": "Hei.", "start_ms": 0, "end_ms": 400}]

    monkeypatch.setattr(worker, "transcribe", fake_transcribe)
    while worker.run_once():
        pass

    assert b"media" in seen
    saved = repo.get("recordings", recording_id)
    assert saved["audio"]["nb"]["status"] == "ready" and saved["sentences"] == {"nb": ["Hei."]}


def test_create_rejects_unknown_language(monkeypatch):
    drive_media(monkeypatch)
    group = make_group()
    response = client.post(f"/api/groups/{group['id']}/recordings", headers=make_admin_headers(),
                           json={"name": "X", "language": "xx", "drive_id": DRIVE_ID, "mode": "ai"})
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
