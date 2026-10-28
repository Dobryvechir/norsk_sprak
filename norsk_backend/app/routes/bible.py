"""
Verse audio for books whose audio files live on Google Drive.

Each such book has an index file data/metadata/books/<book>_audio.json that maps
"<language>/<chapter>/<verse>.mp3" to the Drive file:

    {"bg/1CH/1.mp3": {"id": "1i-dU0E_...", "size": 1570797, "mimeType": "audio/mpeg"}, ...}

`book_audio_router(book)` builds the endpoint
GET /api/<book>/{language_code}/{chapter_id}/{verse_id}, which looks the file up
in the index and passes it through from Drive, including a Range request
(so players can seek). Another book is one line, e.g. in main.py:

    app.include_router(bible.book_audio_router("norsk"))   # uses norsk_audio.json
"""

import asyncio
import json
import threading
from pathlib import Path

import httpx
from fastapi import APIRouter, Header
from fastapi.responses import Response

from ..config import settings
from ..helpers import fail

# Drive sometimes answers with an HTML page (rate limit, "can't scan for
# viruses" notice, ...) instead of the file; such answers are retried.
DOWNLOAD_ATTEMPTS = 7
RETRY_PAUSE_SECONDS = 0.5
DOWNLOAD_TIMEOUT_SECONDS = 30
DRIVE_DOWNLOAD_URL = "https://drive.google.com/uc?export=download&id={id}"

# Response headers from Drive that are passed on to the client.
PASSED_HEADERS = ("content-range", "accept-ranges", "content-type")

_index_cache: dict[str, tuple[float, dict]] = {}  # book -> (file mtime, parsed index)
_index_lock = threading.Lock()


def audio_index_path(book: str) -> Path:
    return Path(settings.data_dir) / "books" / f"{book}_audio.json"


def audio_index(book: str) -> dict:
    """The book's audio index, or {} if it has none. Re-read only when the file changes."""
    path = audio_index_path(book)
    try:
        mtime = path.stat().st_mtime
    except FileNotFoundError:
        return {}
    with _index_lock:
        cached = _index_cache.get(book)
        if cached and cached[0] == mtime:
            return cached[1]
        index = json.loads(path.read_text(encoding="utf-8"))
        _index_cache[book] = (mtime, index)
        return index


def drive_file_id(book: str, key: str):
    """The Drive file ID stored for `key` in the book's index, or None."""
    record = audio_index(book).get(key)
    return record.get("id") if isinstance(record, dict) else None


def http_client() -> httpx.AsyncClient:
    """Client for Drive downloads (a function so tests can swap the transport)."""
    return httpx.AsyncClient(follow_redirects=True, timeout=DOWNLOAD_TIMEOUT_SECONDS)


def is_audio(response: httpx.Response) -> bool:
    content_type = response.headers.get("content-type", "").split(";")[0].strip().lower()
    return response.is_success and (content_type.startswith("audio/") or content_type == "application/octet-stream")


async def fetch_drive_audio(file_id: str, range_header: str | None = None) -> httpx.Response:
    """Download a Drive file (following redirects), retrying until the answer is
    audio. Returns the last response; check it with `is_audio`."""
    headers = {"Range": range_header} if range_header else {}
    url = DRIVE_DOWNLOAD_URL.format(id=file_id)
    response = None
    async with http_client() as client:
        for attempt in range(DOWNLOAD_ATTEMPTS):
            if attempt:
                await asyncio.sleep(RETRY_PAUSE_SECONDS)
            try:
                response = await client.get(url, headers=headers)
            except httpx.HTTPError:
                continue
            # 416: the requested range is outside the file; retrying won't help.
            if is_audio(response) or response.status_code == 416:
                return response
    return response


def book_audio_router(book: str) -> APIRouter:
    """A router serving GET /api/<book>/{language_code}/{chapter_id}/{verse_id}
    from data/books/<book>_audio.json."""
    router = APIRouter()

    @router.get(f"/api/{book}/{{language_code}}/{{chapter_id}}/{{verse_id}}")
    async def get_verse_audio(language_code: str, chapter_id: str, verse_id: str,
                              range_header: str | None = Header(None, alias="Range")):
        """The verse's MP3. Honours an optional `Range: bytes=...` header (answers 206)."""
        file_id = drive_file_id(book, f"{language_code}/{chapter_id}/{verse_id}.mp3")
        if not file_id:
            fail(404, "Audio not found")
        upstream = await fetch_drive_audio(file_id, range_header)
        if upstream is not None and upstream.status_code == 416:
            return Response(status_code=416, headers={"Content-Range": upstream.headers.get("content-range", "")})
        if upstream is None or not is_audio(upstream):
            fail(502, "Could not download the audio")
        headers = {name: upstream.headers[name] for name in PASSED_HEADERS if name in upstream.headers}
        headers.setdefault("accept-ranges", "bytes")
        if headers.get("content-type", "").startswith("application/octet-stream"):
            headers["content-type"] = "audio/mpeg"
        return Response(upstream.content, status_code=upstream.status_code, headers=headers)

    return router


router = book_audio_router("bible")
