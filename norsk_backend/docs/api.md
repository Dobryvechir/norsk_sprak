# API reference

Every endpoint except login and `/health` needs the header
`Authorization: Bearer <access_token>` (from login). Errors look like
`{"detail": "message"}`.

When the server runs, an interactive version of this page (where you can try
requests) is at **`/docs`**.

**Who** column: **any** = any logged-in user · **member** = any enabled member of the
group · **uploader** = role uploader or admin · **admin** = group admin ·
**sysadmin** = system admin. System admins pass every check.

## Auth & self (`routes/auth.py`)

| Method | Path | Who | Body → Response |
|---|---|---|---|
| POST | `/api/auth/login` | nobody | `{email, password}` → `{access_token, token_type: "bearer", user}` |
| GET | `/api/me` | any | → `{id, email, system_admin, enabled}` |
| GET | `/api/me/groups` | any | → list of groups the user belongs to (all groups for sysadmin), each with `my_role` (`viewer`/`uploader`/`admin`; sysadmin is `admin`) |

Login errors: `401 Invalid credentials` (wrong email, wrong password, or disabled
account; deliberately indistinguishable).

## System admin (`routes/admin.py`)

| Method | Path | Who | Body → Response |
|---|---|---|---|
| POST | `/api/admin/users` | sysadmin | `{email, password (≥10 chars)}` → public user. `409` if email taken |
| POST | `/api/admin/groups` | sysadmin | `{name (1–100 chars)}` → group with default AI config |

## Group management (`routes/groups.py`)

| Method | Path | Who | Body → Response |
|---|---|---|---|
| GET | `/api/groups/{gid}/members` | admin | → list of memberships |
| PUT | `/api/groups/{gid}/members/{user_id}` | admin | `{role?, enabled?, quota?}` → membership. Creates or **replaces** |
| PATCH | `/api/groups/{gid}/ai-config` | admin | `{provider?, model?, monthly_audio_minutes_limit?}` → new AI config |
| GET | `/api/groups/{gid}/usage` | admin | → list of usage records |

Notes:
- `role` defaults to `"viewer"`; must be `viewer`, `uploader` or `admin` (else 422).
- `quota` values must be non-negative integers or `null` (else 422).
- PUT replaces the whole membership: omitted fields go back to defaults.
- Despite being PATCH, `ai-config` also replaces the whole config: omitted fields reset to defaults.

## Recordings (`routes/recordings.py`)

| Method | Path | Who | Body → Response |
|---|---|---|---|
| POST | `/api/groups/{gid}/recordings` | uploader | multipart form: `name`, `language`, `file` → `202 {id, language, status: "pending"}` |
| PUT | `/api/recordings/{rid}/audio/{lang}` | uploader | multipart form: `file` → `202 {id, language, status: "pending"}`. Adds audio in `lang`, or replaces it |
| GET | `/api/groups/{gid}/recordings` | member | → list of recordings |
| GET | `/api/recordings/{rid}` | member | → one recording with its `audio` and `sentences` maps |
| GET | `/api/recordings/{rid}/audio/{lang}` | member | → the audio file in `lang` |
| PATCH | `/api/recordings/{rid}/sentences/{lang}/{index}` | uploader | `{text?, start_ms?, end_ms?}` → `{index, language, text, start_ms, end_ms}` |
| DELETE | `/api/recordings/{rid}` | admin | → `{deleted: true}`. Deletes the audio in every language. Works even if a file is already missing |
| POST | `/api/recordings/{rid}/transcribe/{lang}` | uploader | → `202 {status: "pending", id, language}`. Only if that audio is pending/failed, else 409 |

`language` / `lang` is one of `en nb uk ru de da sv cs bg pl pt es fr el he it`
(`helpers.LANGUAGES`); anything else gives `422 Unsupported language`. A recording
only has entries for the languages that were uploaded or written; see
data-model.md for its shape.

Upload errors: `422 Invalid name` (blank or >200 chars) · `413 File too large` ·
`422 Unsupported or invalid audio file` · `422 Invalid duration` (>90 min) ·
`403 … quota exceeded` / `Recording too long` (see permissions-and-quotas.md).

Sentence edit: `text` sets the sentence in `lang`, for any language, which is
how translations are added (the list is padded with `""` up to `index`).
`start_ms` + `end_ms` (both or neither) change the timing in that language's
audio. Errors: `404 Sentence not found` (index ≥ number of sentences) ·
`404 No timing for this sentence in this language` (no audio in `lang`, or it has
no timing at `index`) · `422 Invalid timestamp range` (end must be after start
and at most 0.5 s past the end of the audio) · `422 Nothing to change`.

## Books, sections, chapters (`routes/books.py`)

Read-only: there are no endpoints to create, change or delete them.

| Method | Path | Who | Response |
|---|---|---|---|
| GET | `/api/books?q=&lang=en&page=1&page_size=20` | any | → `{items: [book…], total, page, page_size}` |
| GET | `/api/books/{id}` | any | → one book. `404 Book not found` if missing or not visible |
| GET | `/api/books/{id}/sections?q=&lang=en&page=1&page_size=20` | any | → `{items: [section…], total, page, page_size}`. 404 if the book isn't visible |
| GET | `/api/sections/{id}` | any | → one section. `404 Section not found` |
| GET | `/api/sections/{id}/chapters?page=1&page_size=20` | any | → `{items: [chapter…], total, page, page_size}` |
| GET | `/api/chapters/{id}` | any | → one chapter with its `audio` and `sentences` maps. `404 Chapter not found` |
| GET | `/api/chapters/{id}/audio/{lang}` | any | → the chapter's audio file in `lang` |

- Only what the user may see is returned: a book or section with empty `groups`
  is visible to everyone; otherwise only to enabled members of one of its
  groups, and to system admins. A section also needs its book to be visible,
  and a chapter its section.
- Sections and chapters are sorted by their optional `order` (those without one
  come last), then by name; chapter names sort numbers by value
  ("Salme 2" before "Salme 10"). Chapters are returned like recordings,
  without storage keys.
- `q` matches part of the book's name in **any** language, case-insensitively.
- `lang` is the reader's UI language. Books are sorted by their name in it
  (falling back to English, then the first name), so pages are stable.
- `page` starts at 1; `page_size` is 1–100 (default 20). A page past the end has
  empty `items`. Pages = `ceil(total / page_size)`.

## Misc

| Method | Path | Who | Response |
|---|---|---|---|
| GET | `/health` | nobody | `{status: "ok"}` |

## Example session (curl)

```bash
TOKEN=$(curl -s -X POST localhost:8000/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@example.com","password":"..."}' | jq -r .access_token)

curl -s localhost:8000/api/me/groups -H "Authorization: Bearer $TOKEN"

curl -s -X POST localhost:8000/api/groups/<gid>/recordings \
  -H "Authorization: Bearer $TOKEN" -F name="Lesson 1" -F language=nb -F file=@lesson1.mp3
```

## Verse audio from Google Drive (`routes/bible.py`)

`GET /api/bible/{language_code}/{chapter_id}/{verse_id}` — no login needed.
Looks up `"{language_code}/{chapter_id}/{verse_id}.mp3"` in
`data/metadata/books/bible_audio.json`; 404 if the key is missing or has no `id`.
Otherwise downloads `https://drive.google.com/uc?export=download&id=<id>`
(following redirects) and returns it. An optional `Range: bytes=...` header is
forwarded, and the answer is then `206` with `Content-Range`. A response that
isn't audio is retried (`DOWNLOAD_ATTEMPTS` = 7, `RETRY_PAUSE_SECONDS` = 0.5 at
the top of the file); if every attempt fails, the answer is `502`.

Another book with its own index (`<book>_audio.json`) needs one line in `main.py`:
`app.include_router(bible.book_audio_router("norsk"))`.
