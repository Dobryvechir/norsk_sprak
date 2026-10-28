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
  "uploader_id": "…",                  // who created the recording
  "created_at": "2026-10-16T12:00:00+00:00",
  "audio": {                           // language code → that language's audio
    "nb": {
      "audio_key": "3aa0…/<id>_nb_1a2b3c4d.mp3",  // where it is stored; hidden from clients
      "status": "ready",               // pending | processing | ready | failed
      "error": null,                   // error message when status is "failed"
      "duration_seconds": 1834.2,
      "uploader_id": "…",              // who uploaded this language's audio
      "created_at": "…",
      "start_ms": [0, 1450],           // timing of sentence i in this audio
      "end_ms": [1440, 2750]
    }
  },
  "sentences": {                       // language code → sentence texts
    "nb": ["Hei og velkommen.", "Hvordan har du det?"],
    "en": ["Hello and welcome.", "How are you?"]
  }
}
```

Neither map needs every language. Index `i` is the same sentence in every
language: `sentences.en[i]` is the translation of `sentences.nb[i]`, and
`audio.nb.start_ms[i]`/`end_ms[i]` is where it is spoken in the Norwegian audio.
Transcribing a language's audio replaces `sentences[lang]` and that audio's
timings. A language may have sentences without audio (a translation typed in
via the edit endpoint). Language codes are listed in `helpers.LANGUAGES`.

With Google Drive storage, `audio_key` is the Drive file ID instead of a path.

Recordings saved in the older single-language format (top-level `audio_key`,
`status`, `sentences` as a list of objects) are converted at startup by
`migrations.upgrade_recordings`, as language `nb`.

## `books`  (key: book id)

Read-only through the API. A sample "Bible" (id `bible`) with one section
(`bible-genesis`) and one chapter (`bible-genesis-1`, text only, no audio) is
created at startup if missing (`routes/books.py: seed_sample_books`); other
books are added to the store directly.

```json
{
  "id": "bible",
  "name": {"en": "Bible", "nb": "Bibelen", "uk": "Біблія"},   // not every language needed
  "author": "",
  "audioLanguages": ["en", "nb", "uk"],   // languages the book has audio in
  "groups": [],                           // group IDs; empty = visible to everyone
  "icon": "https://example.com/bible.png" // may be empty; may also be a path on this server
}
```

## `sections`  (key: section id)

A part of a book. Same fields as a book, plus `bookId`, and an optional integer
`order` that decides the listing order within the book.

```json
{"id": "genesis", "bookId": "bible", "order": 1,
 "name": {"en": "Genesis", "nb": "Første Mosebok"}, "author": "",
 "audioLanguages": ["en", "nb"], "groups": [], "icon": ""}
```

## `chapters`  (key: chapter id)

A part of a section, shaped like a recording without `group_id`, `uploader_id`
and `created_at` (also not in the audio entries), plus `sectionId` and an
optional `order`.

```json
{
  "id": "genesis-1", "sectionId": "genesis", "order": 1,
  "name": "Genesis 1",
  "audio": {"nb": {"audio_key": "chapters/genesis-1_nb.mp3", "status": "ready", "error": null,
                   "duration_seconds": 310.5, "start_ms": [0, 5200], "end_ms": [5100, 9800]}},
  "sentences": {"nb": ["I begynnelsen skapte Gud himmelen og jorden.", "…"],
                "en": ["In the beginning God created the heaven and the earth.", "…"]}
}
```

Chapter audio is read through the same storage backend as recordings, using
`audio_key`; put the files there yourself (e.g. under `data/audio/chapters/`).

## `usage`  (key: `<recording_id>_<lang>`)

Written by the worker after each successful transcription of one language's audio.

```json
{
  "id": "<recording id>_<lang>",
  "recording_id": "…",
  "language": "nb",
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
  metadata/users/*.json  groups/  memberships/  recordings/  usage/  books/  sections/  chapters/
  audio/<group_id>/<recording_id>_<lang>_<random>.<ext>   (local audio backend)
  cache/                                  (Drive downloads)
  temp/                                   (uploads in progress)
```

Back up the whole `data/` folder. Switching `METADATA_BACKEND` or `AUDIO_BACKEND`
does **not** move existing data.
