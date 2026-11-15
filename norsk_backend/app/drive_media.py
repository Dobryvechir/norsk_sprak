"""
Recording audio that stays on the uploader's own Google Drive.

The app never uploads a recording's audio to us. The user picks an audio or
video file saved through Media (`/media/audio` or `/media/videos` on their
Drive), the app shares it with "anyone with the link", and sends us its Drive
file ID. The audio entry then has `"drive_id"` instead of `"audio_key"`:

    media_duration(drive_id)       - its length in seconds (ffprobe reads it over HTTPS)
    download_to_temp(drive_id)     - a temporary local copy, for the transcription worker
    stream_response(drive_id, ...) - the file passed through to a player (with Range support)

Nothing is ever deleted on Drive: the file belongs to the user.
"""

import pathlib
import re
import tempfile

import httpx
from fastapi.responses import Response, StreamingResponse
from starlette.background import BackgroundTask

from .config import settings
from .helpers import fail
from .transcription import get_duration

# drive.usercontent.google.com serves the file itself, also for large files
# (no "can't scan for viruses" page with confirm=t), and honours Range.
DRIVE_MEDIA_URL = "https://drive.usercontent.google.com/download?id={id}&export=download&confirm=t"
DRIVE_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{10,200}$")
TIMEOUT_SECONDS = 60
CHUNK_SIZE = 1024 * 1024
PASSED_HEADERS = ("content-type", "content-length", "content-range", "accept-ranges")
NOT_SHARED = "Could not read the media file on Google Drive. Is it shared with anyone who has the link?"


def check_drive_id(drive_id: str) -> str:
    if not DRIVE_ID_PATTERN.match(drive_id or ""):
        fail(422, "Invalid Google Drive file ID")
    return drive_id


def media_url(drive_id: str) -> str:
    return DRIVE_MEDIA_URL.format(id=check_drive_id(drive_id))


def is_media(response: httpx.Response) -> bool:
    """Drive answers with an HTML page when the file isn't public (or is gone)."""
    content_type = response.headers.get("content-type", "").split(";")[0].strip().lower()
    return response.is_success and not content_type.startswith("text/")


def media_duration(drive_id: str) -> float:
    """Length of the shared Drive file in seconds; 422 when it can't be read."""
    try:
        return get_duration(media_url(drive_id))
    except Exception:
        fail(422, NOT_SHARED)


def http_client() -> httpx.Client:
    """Client for Drive downloads (a function so tests can swap the transport)."""
    return httpx.Client(follow_redirects=True, timeout=TIMEOUT_SECONDS)


def download_to_temp(drive_id: str) -> pathlib.Path:
    """Download the shared Drive file into data/temp. The caller deletes it."""
    temp_dir = pathlib.Path(settings.data_dir) / "temp"
    temp_dir.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=temp_dir)
    path = pathlib.Path(name)
    try:
        with open(fd, "wb") as out, http_client() as client, client.stream("GET", media_url(drive_id)) as response:
            if not is_media(response):
                raise RuntimeError(NOT_SHARED)
            for chunk in response.iter_bytes(CHUNK_SIZE):
                out.write(chunk)
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return path


def stream_response(drive_id: str, range_header: str | None, mime_type: str | None = None) -> Response:
    """The Drive file passed through to the client, honouring a Range header."""
    client = http_client()
    try:
        request = client.build_request("GET", media_url(drive_id), headers={"Range": range_header} if range_header else {})
        upstream = client.send(request, stream=True)
    except httpx.HTTPError:
        client.close()
        fail(502, "Could not download the media from Google Drive")
    if upstream.status_code == 416:
        upstream.close(); client.close()
        return Response(status_code=416, headers={"Content-Range": upstream.headers.get("content-range", "")})
    if not is_media(upstream):
        upstream.close(); client.close()
        fail(502, NOT_SHARED)

    def close():
        upstream.close()
        client.close()

    headers = {name: upstream.headers[name] for name in PASSED_HEADERS if name in upstream.headers}
    headers.setdefault("accept-ranges", "bytes")
    if mime_type and headers.get("content-type", "").startswith("application/octet-stream"):
        headers["content-type"] = mime_type
    return StreamingResponse(upstream.iter_raw(CHUNK_SIZE), status_code=upstream.status_code,
                             headers=headers, background=BackgroundTask(close))
