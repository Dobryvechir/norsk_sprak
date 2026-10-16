# Architecture

## The big picture

The backend lets groups of people share Norwegian audio recordings. Each recording
is transcribed into sentences with start/end times, so a listening-practice app
(the Flutter app in `../norsk_flutter_app`) can play it back sentence by sentence.

It runs as **two processes** that share the same data:

```
 Flutter app ──HTTP──▶  API server (uvicorn app.main:app)
                          │  - login, permissions, quotas
                          │  - saves uploads, sets status "pending"
                          ▼
                    ┌──────────────┐        ┌─────────────┐
                    │  metadata    │        │ audio files │
                    │ (JSON / PG)  │        │(disk/Drive) │
                    └──────────────┘        └─────────────┘
                          ▲                        ▲
                          │  polls every 3 s       │ reads audio
                     Worker (python -m app.worker) ┘
                          │  - picks a "pending" recording
                          │  - ffmpeg → OpenAI Whisper → sentences
                          │  - sets status "ready" or "failed"
```

The API and the worker never talk to each other directly. They only communicate
through the recording's `status` field in the metadata store.

## Module map (`app/`)

| File | What it's for |
|---|---|
| `main.py` | Creates the FastAPI app, plugs in the routes, creates the first admin at startup. **Start here.** |
| `config.py` | Reads settings from `.env` / environment variables. |
| `helpers.py` | Tiny helpers: `new_id()`, `utc_now_iso()`, `current_month()`, `fail()`. |
| `repository.py` | Saves and loads metadata (users, groups, …). JSON files or PostgreSQL. |
| `storage.py` | Saves and loads audio files. Local disk or Google Drive. |
| `security.py` | Password hashing, login tokens, `current_user`, permission checks. |
| `schemas.py` | The shape of JSON request bodies (validated automatically). |
| `quotas.py` | Monthly upload limit checks. |
| `transcription.py` | ffprobe/ffmpeg + Whisper + sentence splitting. |
| `worker.py` | The background loop that runs transcriptions. |
| `routes/auth.py` | `/api/auth/login`, `/api/me`, `/api/me/groups` |
| `routes/admin.py` | `/api/admin/...` create users and groups (system admin) |
| `routes/groups.py` | `/api/groups/{gid}/...` members, AI config, usage (group admin) |
| `routes/recordings.py` | Upload, list, play, edit, delete, transcribe recordings |

Dependency direction (arrows mean "imports"). Lower layers never import higher ones:

```
routes/*  ──▶  security, quotas, schemas, storage, transcription
                 │
                 ▼
            repository  ──▶  config, helpers
```

## Following one request: uploading a recording

`POST /api/groups/{gid}/recordings` → `routes/recordings.py: upload_recording`

1. **Who are you?** `Depends(current_user)` reads the `Authorization: Bearer …`
   header, checks the JWT signature and loads the user (`security.py`).
2. **May you do this?** `require_role(user, gid, [UPLOADER, ADMIN])` loads the
   user's membership in that group and checks the role.
3. **Save the file.** `save_upload_to_temp_file` streams it to `data/temp/`,
   stopping with 413 if it exceeds `MAX_UPLOAD_MB`.
4. **Is it audio?** `get_duration` runs `ffprobe`. If that fails, the file isn't
   valid audio (422). It must also be 0–90 minutes.
5. **Quota.** Under `repo.lock`, `check_upload_quota` sums this month's uploads;
   then the audio is stored (`storage.py`) and the recording saved with
   `status: "pending"`. Holding the lock across both steps stops two
   simultaneous uploads from slipping past the same limit.
6. **Reply** `202 Accepted` with the new recording ID. The temp file is deleted.

Later the worker notices the pending recording and transcribes it. The app polls
`GET /api/recordings/{id}` until `status` becomes `"ready"` or `"failed"`.

## Errors

Anywhere in the code, `fail(status, message)` raises an `HTTPException`. FastAPI
turns it into a JSON response `{"detail": message}` with that status code.
Code after a `fail(...)` never runs, so it works like an early `return`.

Request body validation errors (from `schemas.py`) are handled by FastAPI
itself and come back as 422 with a list of problems.
