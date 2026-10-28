"""
Audio file storage.

Two interchangeable backends with the same three methods:

    save(key, source)  - store the bytes read from file-like `source`.
                         Returns a new key to use from now on, or None to keep `key`.
    get(key)           - return a local Path to the audio file.
    delete(key)        - remove the file. Does nothing if it is already gone.

`key` is chosen by the upload endpoint as '<group_id>/<recording_id>_<lang>_<random><ext>'
and saved in the recording's audio entry for that language as `audio_key`.

    LocalAudio - files under <data_dir>/audio/<key>
    DriveAudio - files in a Google Drive folder. Drive assigns its own file ID,
                 so `save` returns that ID and it becomes the audio_key.
                 `get` downloads into <data_dir>/cache/ (never cleaned up).

Use `get_storage()` to obtain the configured backend.
"""

from pathlib import Path

from .config import settings

CHUNK_SIZE = 1024 * 1024  # copy files 1 MB at a time


class LocalAudio:
    def __init__(self):
        self.root = Path(settings.data_dir) / "audio"
        self.root.mkdir(parents=True, exist_ok=True)

    def save(self, key, source):
        dest = self.root / key
        dest.parent.mkdir(parents=True, exist_ok=True)
        with dest.open("wb") as out:
            while chunk := source.read(CHUNK_SIZE):
                out.write(chunk)
        return None  # key unchanged

    def get(self, key) -> Path:
        path = (self.root / key).resolve()
        # Safety: refuse keys like '../../etc/passwd' that escape the audio folder.
        if not path.is_relative_to(self.root.resolve()) or not path.is_file():
            raise FileNotFoundError(key)
        return path

    def delete(self, key):
        try:
            path = self.get(key)
        except FileNotFoundError:
            return  # already gone - nothing to delete
        path.unlink(missing_ok=True)


class DriveAudio:
    """Google Drive backend. Google libraries are imported lazily so they are
    only needed when this backend is actually used."""

    def __init__(self):
        import json

        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from googleapiclient.discovery import build

        info = json.loads(Path(settings.google_drive_credentials_file).read_text())
        creds = Credentials.from_authorized_user_info(
            info, scopes=["https://www.googleapis.com/auth/drive.file"]
        )
        # Note: a refreshed token is not written back to the credentials file.
        if creds.expired and creds.refresh_token:
            creds.refresh(Request())
        self.service = build("drive", "v3", credentials=creds, cache_discovery=False)

    def save(self, key, source):
        import mimetypes

        from googleapiclient.http import MediaIoBaseUpload

        mimetype = mimetypes.guess_type(key)[0] or "application/octet-stream"
        media = MediaIoBaseUpload(source, mimetype=mimetype, resumable=True)
        request = self.service.files().create(
            body={"name": key.split("/")[-1], "parents": [settings.google_drive_root_folder_id]},
            media_body=media,
            fields="id",
        )
        # Resumable upload: send chunk by chunk until Drive returns the result.
        response = None
        while response is None:
            _, response = request.next_chunk()
        return response["id"]  # the Drive file ID becomes the new key

    def get(self, key) -> Path:
        import io

        from googleapiclient.http import MediaIoBaseDownload

        dest = Path(settings.data_dir) / "cache" / key
        dest.parent.mkdir(parents=True, exist_ok=True)

        buffer = io.BytesIO()
        downloader = MediaIoBaseDownload(buffer, self.service.files().get_media(fileId=key))
        done = False
        while not done:
            _, done = downloader.next_chunk()

        dest.write_bytes(buffer.getvalue())
        return dest

    def delete(self, key):
        from googleapiclient.errors import HttpError

        try:
            self.service.files().delete(fileId=key).execute()
        except HttpError as e:
            if e.resp.status != 404:  # 404 = already gone - nothing to delete
                raise


def get_storage():
    """Return the audio backend selected by AUDIO_BACKEND.

    A new instance is created on every call (for Drive this re-reads credentials).
    """
    if settings.audio_backend == "local":
        return LocalAudio()
    return DriveAudio()
