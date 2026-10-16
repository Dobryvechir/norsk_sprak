# Data model

All metadata is stored as JSON objects, grouped by **kind**. In JSON mode each
object is a file: `data/metadata/<kind>/<key>.json`. In PostgreSQL mode it's a
row in the `entities(kind, id, body)` table. Audio files are stored separately
(see `storage.py`).

```
users ──< memberships >── groups ──< recordings ──1:1── usage
```

## `users`  (key: user id)

```json
{
  "id": "9cf99287fb864a8f99444ceb966e0407",
  "email": "anne@example.no",          // always lower-case
  "password_hash": "$argon2id$...",    // never sent to clients
  "system_admin": false,
  "enabled": true
}
```

## `groups`  (key: group id)

```json
{
  "id": "3aa0cbcf8a8b43129dd1761c29b6e38e",
  "name": "Norskkurs A2",
  "ai": {"provider": "openai", "model": "whisper-1", "monthly_audio_minutes_limit": null},
  "created_at": "2026-10-16T12:00:00+00:00"
}
```

## `memberships`  (key: `<group_id>_<user_id>`)

```json
{
  "group_id": "3aa0…",
  "user_id": "9cf9…",
  "role": "uploader",                 // viewer | uploader | admin
  "enabled": true,
  "quota": {"max_recordings_per_month": 10}
}
```

## `recordings`  (key: recording id)

```json
{
  "id": "…",
  "group_id": "…",
  "name": "Lesson 1",
  "uploader_id": "…",
  "created_at": "2026-10-16T12:00:00+00:00",
  "duration_seconds": 1834.2,
  "audio_key": "3aa0…/<id>.mp3",      // where the audio is stored; hidden from clients
  "status": "ready",                   // pending | processing | ready | failed
  "error": null,                       // error message when status is "failed"
  "sentences": [
    {"index": 0, "text": "Hei og velkommen.", "start_ms": 0, "end_ms": 1450}
  ]
}
```

With Google Drive storage, `audio_key` is the Drive file ID instead of a path.

## `usage`  (key: recording id)

Written by the worker after each successful transcription.

```json
{
  "id": "<recording id>",
  "group_id": "…",
  "user_id": "<uploader id>",
  "audio_minutes": 30.57,
  "provider": "openai",
  "model": "whisper-1",
  "created_at": "…"
}
```

## On-disk layout (default settings)

```
data/
  metadata/users/*.json  groups/  memberships/  recordings/  usage/
  audio/<group_id>/<recording_id>.<ext>   (local audio backend)
  cache/                                  (Drive downloads)
  temp/                                   (uploads in progress)
```

Back up the whole `data/` folder. Switching `METADATA_BACKEND` or `AUDIO_BACKEND`
does **not** move existing data.
