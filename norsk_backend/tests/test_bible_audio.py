"""Verse audio passed through from Google Drive: lookup, Range, redirects, retries."""

import json
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app
from app.routes import bible

client = TestClient(app)
MP3 = b"ID3" + bytes(range(256)) * 4


@pytest.fixture(autouse=True)
def audio_index(monkeypatch):
    path = Path(settings.data_dir) / "metadata" / "books" / "bible_audio.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "nb/GEN/1.mp3": {"id": "file-1", "size": len(MP3), "mimeType": "audio/mpeg"},
        "nb/GEN/2.mp3": {"size": 10},
    }), encoding="utf-8")
    monkeypatch.setattr(bible, "RETRY_PAUSE_SECONDS", 0)


def use_drive(monkeypatch, handler):
    """Answer Drive requests with `handler(request, call_number)`; returns the list of requests."""
    requests = []

    def respond(request):
        requests.append(request)
        return handler(request, len(requests))

    monkeypatch.setattr(bible, "http_client", lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(respond), follow_redirects=True))
    return requests


def drive_file(request, _):
    """Drive's real behaviour: uc?export=download redirects to the content host."""
    if request.url.host == "drive.google.com":
        return httpx.Response(303, headers={"Location": "https://drive.usercontent.google.com/download?id=file-1"})
    if "range" in request.headers:
        return httpx.Response(206, content=MP3[:100], headers={
            "Content-Type": "audio/mpeg", "Content-Range": f"bytes 0-99/{len(MP3)}"})
    return httpx.Response(200, content=MP3, headers={"Content-Type": "audio/mpeg"})


def test_whole_file_follows_redirect(monkeypatch):
    requests = use_drive(monkeypatch, drive_file)
    response = client.get("/api/bible/nb/GEN/1")
    assert response.status_code == 200
    assert response.content == MP3
    assert response.headers["content-type"] == "audio/mpeg"
    assert str(requests[0].url) == "https://drive.google.com/uc?export=download&id=file-1"


def test_range_is_forwarded(monkeypatch):
    requests = use_drive(monkeypatch, drive_file)
    response = client.get("/api/bible/nb/GEN/1", headers={"Range": "bytes=0-99"})
    assert response.status_code == 206
    assert response.content == MP3[:100]
    assert response.headers["content-range"] == f"bytes 0-99/{len(MP3)}"
    assert all(r.headers["range"] == "bytes=0-99" for r in requests)


def test_unknown_key_or_record_without_id_is_404(monkeypatch):
    requests = use_drive(monkeypatch, drive_file)
    assert client.get("/api/bible/nb/GEN/99").status_code == 404
    assert client.get("/api/bible/nb/GEN/2").status_code == 404
    assert requests == []


def test_retries_until_audio(monkeypatch):
    def flaky(request, call):
        if call < 3:
            return httpx.Response(200, text="<html>Too many requests</html>", headers={"Content-Type": "text/html"})
        return httpx.Response(200, content=MP3, headers={"Content-Type": "audio/mpeg"})

    requests = use_drive(monkeypatch, flaky)
    response = client.get("/api/bible/nb/GEN/1")
    assert response.status_code == 200 and response.content == MP3
    assert len(requests) == 3


def test_gives_up_after_the_configured_attempts(monkeypatch):
    requests = use_drive(monkeypatch, lambda request, call: httpx.Response(
        200, text="<html>no</html>", headers={"Content-Type": "text/html"}))
    assert client.get("/api/bible/nb/GEN/1").status_code == 502
    assert len(requests) == bible.DOWNLOAD_ATTEMPTS


def test_other_books_use_their_own_index(monkeypatch):
    (Path(settings.data_dir) / "metadata" / "books" / "norsk_audio.json").write_text(
        json.dumps({"nb/1/1.mp3": {"id": "norsk-file"}}), encoding="utf-8")
    use_drive(monkeypatch, lambda request, call: httpx.Response(
        200, content=MP3, headers={"Content-Type": "audio/mpeg"}))
    test_app = TestClient(app.__class__())
    test_app.app.include_router(bible.book_audio_router("norsk"))
    assert test_app.get("/api/norsk/nb/1/1").content == MP3
    assert test_app.get("/api/norsk/nb/GEN/1").status_code == 404
