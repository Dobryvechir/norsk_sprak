# Norsk Audio Groups backend

FastAPI backend for shared Norwegian listening practice. Initial mode: JSON metadata, local audio, OpenAI Whisper-1. Optional PostgreSQL metadata and Google Drive audio adapters are included.

**New to the code? Read [docs/README.md](docs/README.md)** for architecture, the API reference, permissions, data model and the transcription pipeline. In the source, start at `app/main.py`.

## Quick start (Linux, Python 3.11+)

1. Install `ffmpeg` and `ffprobe`: `sudo apt install ffmpeg`.
2. Create a virtual environment: `python3 -m venv .venv && source .venv/bin/activate`.
3. Install dependencies: `pip install -r requirements.txt`.
4. Copy `.env.example` to `.env`. Set a random `APP_SECRET` of at least 32 characters, a strong bootstrap password, and `OPENAI_API_KEY`.
5. Run the API: `uvicorn app.main:app --host 127.0.0.1 --port 8000`.
6. In a separate terminal, activate the same environment and run `python -m app.worker`.
7. Open `/docs` on localhost for the OpenAPI interface. Put Nginx + HTTPS in front for remote access.

The bootstrap system administrator is created at startup if the configured email does not exist. Remove bootstrap credentials from `.env` after the first successful startup. Password hashes use Argon2. All non-login API endpoints require a Bearer JWT. Create users and groups as system administrator; add members using `PUT /api/groups/{gid}/members/{user_id}`. Newly created members default to `viewer`. Only group admins and system admins can manage memberships. Only system admins can create groups.

Example quota fields: `max_recordings_per_month`, `max_audio_minutes_per_month`, `max_recording_duration_minutes`. Missing or null means unlimited. Group AI settings include `monthly_audio_minutes_limit`.

### Storage

- `METADATA_BACKEND=json` (default) or `postgresql`; PostgreSQL uses `DATABASE_URL` and a JSONB-backed entity table. Changing the setting **does not migrate data**.
- `AUDIO_BACKEND=local` (default) or `google_drive`. Google Drive uses OAuth authorized-user credentials JSON and `GOOGLE_DRIVE_ROOT_FOLDER_ID`. It is a basic adapter; credential refresh persistence and cache cleanup are not implemented.
- Keep `data/`, `.env`, credentials and backups outside publicly served web directories. JSON storage supports one API writer process and one worker; it is not a distributed transactional database.

### Caveats / production hardening

This is a working MVP scaffold, **not a fully hardened multi-tenant production system**. It requires further work before deployment to untrusted users: transactional quota reservations across multiple processes, persistent job leases and recovery, safer processing of untrusted media, rate limiting, stronger session/revocation controls, secret management, secure Drive token refresh, storage migration and backup tooling, and comprehensive concurrency/security tests. JSON quotas are not transactional across API and worker processes. A failed transcription currently releases its upload quota and may be retried; failed uploads still occupy storage until an admin deletes them. Only OpenAI Whisper-1 transcription is implemented; other AI provider names are architectural placeholders. AI API keys are server-wide initially, not per-group. Audio downloads require authorization. Recording deletion is restricted to admins.

For Norwegian 30–60 minute recordings, ffmpeg produces 8-minute 48 kbps mono MP3 chunks, each transcribed with word timestamps. Sentence boundaries use punctuation and long pauses; edit endpoints allow corrections. Chunk boundaries can split a sentence; refine with overlap/merging before relying on exact boundaries.

### Tests

`pytest -q`
