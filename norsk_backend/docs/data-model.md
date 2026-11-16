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

## `candidate_users`  (key: candidate id)

People who signed up via `POST /api/signup` and wait for a system admin. Approving
or rejecting removes the record. At most `LIMIT_SAME_API` (50) records may share an IP, and at most
`LIMIT_IP_PER_DAY` (5) of them may be created on the same UTC date.

```json
{
  "id": "5e0c...",
  "email": "ola@example.no",           // lower-case
  "password_hash": "$argon2id$...",    // copied to the user on approval
  "info": "I am in Anne's class",
  "ip": "203.0.113.7",
  "browser": "Chrome 131 / Windows",   // short form of the User-Agent
  "created_at": "2026-11-14T10:00:00+00:00",
  "status": "pending",                 // always "pending" (decided records are removed)
  // Added by /app/plan/, /app/shop/ and /app/verify/ (routes/plans.py):
  "plan": "basic",                     // "basic" | "pro"; missing until chosen
  "payment": {                         // only for "pro"
    "status": "failed",                // "processing" | "paid" | "failed"
    "method": "vipps",                 // "vipps" | "applepay" | "googlepay" | "card"; "stripe" until known
    "provider": "vipps",               // "vipps" | "stripe"
    "currency": "NOK", "amount": 32000, // minor units
    "reference": "norsk-...", "intent_id": "pi_...",  // intent_id: Stripe only
    "transaction_id": "...", "paid_at": "...", "error": "..."
  },
  "email_verified": false, "email_verified_at": "...",
  "verify_token_hash": "...",          // SHA-256 of the emailed token; never sent to clients
  "verify_sent_at": 1763114400.0       // link valid 7 days
}
```

A paid Pro candidate is not kept here: it becomes a user at once (member of the
"Advanced" group). Approval and payment copy `plan`, `payment` and the
verification fields to the user, plus `candidate_id`.

## `notifications`  (key: notification id)

Messages a system admin shows in the app (see `routes/notifications.py`). Every
field except `id`, `text` and `severity` may be `null` (= no limit).

```json
{
  "id": "9b1f...",
  "text": "The server is updated tonight at 22:00.",
  "severity": 12,              // <=10 info, 11-20 warning, 21-30 critical, >=31 fatal;
                               // last digit: 0 always, 1 once, else until "Do not remind again"
  "versionFrom": "0.1.0", "versionTo": null,     // app versions, inclusive
  "groupId": null, "userId": null,               // userId wins over groupId
  "privilegeFrom": 0, "privilegeTo": 0,          // used when neither userId nor groupId is set
  "datetimeFrom": "2026-11-14T08:00:00+00:00", "datetimeTo": null,
  "created_at": "2026-11-14T07:00:00+00:00",
  "created_by": "<admin user id>"
}
```

## `groups`  (key: group id)

```json
{
  "id": "3aa0cbcf8a8b43129dd1761c29b6e38e",
  "name": "Norskkurs A2",
  "ai": {"enabled": true,            // missing = true; false: no AI transcription in this group
         "provider": "openai", "model": "whisper-1", "monthly_audio_minutes_limit": null},
  "created_at": "2026-10-16T12:00:00+00:00",
  "privilege": 7,                // int; plan groups: "Basic" 0, "Advanced" 1; others 7 by default
  "shareRecords": 100,           // recordings with own texts each member may share per month; "Basic" 0 (none)
  "anonymous": false,            // chat settings; missing ones count as these defaults
  "family": false,
  "subgroupLimitPerYear": 20,
  "chatPerDayKb": 500,
  "expirationDays": 7
}
```

## Chat kinds

`subgroups`, `chat_profiles`, `chat_messages`, `chat_meta`, `chat_inbox`, `chat_usage`,
`chat_subgroup_counts` and `chat_locations` are described in [chat.md](chat.md).

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
  "uploader_id": "…",                  // who created the recording (its author)
  "created_at": "2026-10-16T12:00:00+00:00",
  "source": "ai",                      // file (shared with own texts; counts for shareRecords) | ai; older: missing
  "audio": {                           // language code → that language's audio
    "nb": {
      "drive_id": "1AbC…",             // the file on the uploader's Google Drive (shared by link)
      "media_kind": "video",           // audio | video
      "mime_type": "video/mp4", "file_name": "Lesson 1",
      "size_bytes": 52428800,          // the media file's size, when known
      "translate_to": ["en", "uk"],    // ai: languages the worker translates the sentences into
      "timing": "ai",                  // ai (transcribed by us; counts for quotas) | manual (user's own file)
      "status": "ready",               // pending | processing | ready | failed (manual: always ready)
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

Recordings made before audio moved to the users' own Drive have `"audio_key"`
(our storage; hidden from clients) instead of `drive_id`, and no `timing`
(counted as `ai`). With Google Drive storage (`AUDIO_BACKEND`), `audio_key` is
the Drive file ID in the server's folder instead of a path. `drive_id` files are
never deleted by us.

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

An audio entry may instead (or also) have a `"url"` where the audio file can be
fetched, e.g. `{"url": "http://…/api/bible/nb/MAT/1", "start_ms": […], "end_ms": […]}`.
A `url` takes priority over `audio_key` and the storage backend: the audio
endpoint redirects to it (307), and the app downloads (Android/iOS) or plays
(web) the audio straight from it. `url` is passed to clients as is.

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
  metadata/users/*.json  candidate_users/  groups/  memberships/  recordings/  usage/  books/  sections/  chapters/
  audio/<group_id>/<recording_id>_<lang>_<random>.<ext>   (local audio backend)
  key/key.txt                             (secret for signup checksums; created automatically)
  cache/                                  (Drive downloads)
  temp/                                   (uploads in progress)
```

Back up the whole `data/` folder. Switching `METADATA_BACKEND` or `AUDIO_BACKEND`
does **not** move existing data.
