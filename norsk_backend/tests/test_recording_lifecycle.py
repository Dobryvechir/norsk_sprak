"""Regression tests for deleting recordings and worker recovery."""

from pathlib import Path

from fastapi.testclient import TestClient

from app import worker
from app.config import settings
from app.helpers import new_id, utc_now_iso
from app.main import app
from app.repository import repo
from app.security import create_token

client = TestClient(app)


def make_admin_headers():
    admin = {"id": new_id(), "email": f"{new_id()}@test.no", "password_hash": "-",
             "system_admin": True, "enabled": True}
    repo.put("users", admin["id"], admin)
    return {"Authorization": "Bearer " + create_token(admin)}


def make_recording(status="pending", with_audio_file=True):
    """Save a group + recording directly in the repository (no upload/ffprobe)."""
    group = {"id": new_id(), "name": "Test", "created_at": utc_now_iso(),
             "ai": {"provider": "openai", "model": "whisper-1", "monthly_audio_minutes_limit": None}}
    repo.put("groups", group["id"], group)

    recording_id = new_id()
    audio_key = f"{group['id']}/{recording_id}.wav"
    if with_audio_file:
        path = Path(settings.data_dir) / "audio" / audio_key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fake audio")

    recording = {"id": recording_id, "group_id": group["id"], "name": "Opptak",
                 "uploader_id": "someone", "created_at": utc_now_iso(),
                 "duration_seconds": 3.0, "audio_key": audio_key, "status": status,
                 "sentences": [], "error": None}
    repo.put("recordings", recording_id, recording)
    return recording


def test_delete_recording_whose_audio_file_is_missing():
    recording = make_recording(with_audio_file=False)

    response = client.delete(f"/api/recordings/{recording['id']}", headers=make_admin_headers())

    assert response.status_code == 200
    assert repo.get("recordings", recording["id"]) is None


def test_worker_does_not_recreate_recording_deleted_during_transcription(monkeypatch):
    recording = make_recording()

    def transcribe_while_admin_deletes(path, provider, model):
        repo.delete("recordings", recording["id"])  # deleted mid-transcription
        return [{"index": 0, "text": "Hei.", "start_ms": 0, "end_ms": 400}]

    monkeypatch.setattr(worker, "transcribe", transcribe_while_admin_deletes)
    worker.run_once()

    assert repo.get("recordings", recording["id"]) is None


def test_worker_startup_requeues_interrupted_recordings():
    stuck = make_recording(status="processing")
    done = make_recording(status="ready")

    worker.recover_interrupted_jobs()

    assert repo.get("recordings", stuck["id"])["status"] == "pending"
    assert repo.get("recordings", done["id"])["status"] == "ready"
