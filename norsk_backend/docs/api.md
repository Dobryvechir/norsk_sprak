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
| POST | `/api/admin/groups` | sysadmin | `{name (1–100 chars), anonymous?, family?, subgroupLimitPerYear?, chatPerDayKb?, expirationDays?}` → group with default AI config and chat settings (see chat.md) |

## Self-registration (`routes/signup.py`)

| Method | Path | Who | Body → Response |
|---|---|---|---|
| GET | `/app/signup` | anyone (no login) | → HTML sign-up form (`app/static/signup.html`); calls `/api/checksum`, then `/api/signup`. Opened by the app's "Not registered? Sign up" link |
| POST | `/api/captcha` | anyone (no login) | → `{challenge, difficulty, token}` for the "I am not a robot" button (see below) |
| POST | `/api/checksum` | anyone (no login) | `{email, password, info?}` (same rules as signup) → `{checksum}` |
| POST | `/api/signup` | anyone (no login) | `{email, password (10–200 chars), info? (≤2000 chars), checksum, captchaToken, captchaSolution, website?}` → `201 {id, status: "pending"}`. `400 Invalid checksum` if it differs from the recalculated one, `400 Robot check failed` (see below), `409` if the email is a user or already pending, `422` invalid email, `429` when `candidate_users` already holds `LIMIT_SAME_API` (50) records from this IP, or `LIMIT_IP_PER_DAY` (5) from this IP created on the same UTC date |
| GET | `/api/admin/candidates` | sysadmin | → candidates waiting for a decision, newest first, without the password hash |
| POST | `/api/admin/candidates/{cid}/approve` | sysadmin | `{groupId?, role? ("viewer")}` → public user. Copies the candidate (with its password hash) to `users`, with `groupId` also adds the membership, and **removes** the candidate. `404` if not found, `409` if email taken |
| POST | `/api/admin/candidates/{cid}/reject` | sysadmin | → the candidate with `status: "rejected"`; it is **removed**. `404` if not found |

`/api/signup` also returns `planToken`; the form then opens `/app/plan/?c=<id>&t=<planToken>`.
The shop calls take either `{candidateId, token}` (a sign-up) or `{userId, token}` (a Basic user
upgrading with the token from `/api/me/upgrade-link`).
`/api/admin/candidates` includes `email_verified`, `plan`, `payment` and `default_group_id`
(the "Basic" group, which the approval dialog suggests).

## Plan, shop and email verification (`routes/plans.py`)

`c` / `candidateId` is the candidate id and `t` / `token` the plan token; a wrong token gives `403`.
Groups **Basic** and **Advanced** are created at startup. See [payments.md](payments.md).

| Method | Path | Who | Body / result |
|---|---|---|---|
| GET | `/app/plan/`, `/app/shop/`, `/app/verify/`, `/app/upgrade/` | anyone | HTML pages (`app/static/`). Without the slash: relative redirect |
| GET | `/app/terms_of_sale`, `/app/privacy_policy` | anyone | Terms of sale and privacy policy (`app/static/`) |
| GET | `/app/norsk-audio` | anyone | Norsk Audio's features, with links to sign-up, the web app and the legal pages; linked from the main Movna Hatka site |
| GET | `/app/plan/pro-info.js` | anyone | Script that shows what Pro gives (used by `/app/plan/` and `/app/upgrade/`) |
| GET | `/api/plan/pro-info` | anyone | → `{prices, limits: {anonymous, family, subgroupLimitPerYear, chatPerDayKb, expirationDays}, aiMonthlyMinutes}` of the "Advanced" group |
| POST | `/api/me/upgrade-link` | logged in | → `{url}`: `<PUBLIC_BASE_URL>upgrade/?u=<user id>&t=<upgrade token>` (valid 1 day). `409` unless the user is in a privilege-0 group (system admins never) |
| GET | `/api/plan/state?c=&t=` or `?u=&t=` | plan or upgrade token | → `{email, plan, paid, payment, emailVerified, approved, upgrade, upgradable, prices}` |
| POST | `/api/plan` | plan token | `{candidateId, token, plan: "basic"\|"pro"}` → `{next: "done"\|"shop", ...state}`. Basic emails the verification link (at most once a minute). `409` once paid / already a user |
| GET | `/api/shop/config?c=&t=` or `?u=&t=` | plan or upgrade token | → `{prices, vipps: {enabled, currencies}, stripe: {enabled, publishableKey}}` |
| POST | `/api/shop/stripe/start` | plan token | `{..., currency}` → `{clientSecret}` of a Stripe PaymentIntent for Apple Pay / Google Pay. An unfinished intent for the same currency is reused. `409` no Pro plan / already paid, `502` Stripe error |
| POST | `/api/shop/stripe/status` | plan token | → state, after reading the PaymentIntent from Stripe (`succeeded` → paid) |
| POST | `/api/shop/stripe/webhook` | Stripe (signed) | `payment_intent.*` events; `400` on a bad `Stripe-Signature`. The intent is always re-read from Stripe |
| POST | `/api/shop/vipps/start` | plan token | `{..., currency: "NOK"\|"EUR"}` → `{redirectUrl}` |
| POST | `/api/shop/vipps/status` | plan token | → state, after asking Vipps (captures when `AUTHORIZED`) |
| POST | `/api/shop/vipps/webhook` | Vipps (HMAC) | `401` on a bad signature; the state is always re-read from Vipps |
| POST | `/api/verify` | anyone | `{token}` → `{email, emailVerified: true, approved}`. `404` unknown/used, `410` older than 7 days |

When a payment succeeds the candidate becomes a user at once (role `viewer` in **Advanced**,
no admin approval) and gets the verification email.

The checksum is HMAC-SHA256 over `{email (lower-case), password, info (trimmed), ip, browser}`,
keyed with `<DATA_DIR>/key/key.txt` (created with a random 256-bit key on first use).
Since IP and browser are included, the checksum and the signup must come from the same
IP and browser. The form shows "System error, try again" when either step fails.

**"I am not a robot"** (proof of work). Pressing the button calls `/api/captcha` and
searches for `captchaSolution` such that `SHA-256("<challenge>:<solution>")` starts with
`difficulty` (16) zero bits, about 65 000 hashes. `/api/signup` answers `400 Robot check failed`
unless the token is genuinely signed (with the same key file), was issued to the same IP
and browser at least `CAPTCHA_MIN_SECONDS` (3 s) and at most `CAPTCHA_MAX_SECONDS` (15 min)
ago, has not been used before, the solution is correct, and the hidden honeypot field
`website` is empty. Used challenges are remembered in memory (one API process).

The IP is the direct peer, or `X-Real-IP` / the last `X-Forwarded-For` entry
when the peer is a loopback/private address (i.e. the reverse proxy).

## Notifications (`routes/notifications.py`)

| Method | Path | Who | Body → Response |
|---|---|---|---|
| GET | `/api/me/notifications?version=` | any | → the notifications for this user that are valid now and (when `version` is given) for that app version, most severe first. The app calls it after login |
| GET | `/api/admin/notifications` | sysadmin | → every notification, newest first |
| POST | `/api/admin/notifications` | sysadmin | `{text, severity (≥0), versionFrom?, versionTo?, groupId?, userId? (id or email), privilegeFrom?, privilegeTo?, datetimeFrom?, datetimeTo? (ISO-8601, no zone = UTC)}` → `201` notification. Empty strings mean "not set". `404` unknown user/group, `422` bad version/date or a range whose start is after its end |
| DELETE | `/api/admin/notifications/{nid}` | sysadmin | → `{id, deleted: true}`. `404` if not found |

Recipient: `userId` set → only that user; else `groupId` → enabled members of that group; else
`privilegeFrom`/`privilegeTo` → members of any group whose `privilege` is in the range; else everybody.
Date and version limits apply on top. All ranges include both ends. Versions compare by their
numbers (`0.1.0+1` = `0.1`). How the app shows a notification (by `severity`) is described in
`routes/notifications.py`.

## Group management (`routes/groups.py`)

| Method | Path | Who | Body → Response |
|---|---|---|---|
| GET | `/api/groups/{gid}/members` | admin | → list of memberships |
| PUT | `/api/groups/{gid}/members/{user_id}` | admin | `{role?, enabled?, quota?}` → membership. Creates or **replaces** |
| PATCH | `/api/groups/{gid}/ai-config` | admin | `{enabled?, provider?, model?, monthly_audio_minutes_limit?}` → new AI config. `enabled: false` turns AI transcription off for the group |
| GET | `/api/groups/{gid}/usage` | admin | → list of usage records |
| GET | `/api/groups/{gid}/settings` | member | → chat settings `{anonymous, family, subgroupLimitPerYear, chatPerDayKb, expirationDays}` |
| PATCH | `/api/groups/{gid}/settings` | admin | any of those fields → new chat settings (fields left out are kept) |

Notes:
- `role` defaults to `"viewer"`; must be `viewer`, `uploader` or `admin` (else 422).
- `quota` values must be non-negative integers or `null` (else 422).
- PUT replaces the whole membership: omitted fields go back to defaults.
- Despite being PATCH, `ai-config` also replaces the whole config: omitted fields reset to defaults.

## Recordings (`routes/recordings.py`)

| Method | Path | Who | Body → Response |
|---|---|---|---|
| GET | `/api/groups/{gid}/ai-allowance` | uploader | → `{enabled, reason, remaining_recordings, remaining_minutes, max_duration_minutes}`: whether the user may use AI transcription now (`reason`: `disabled`, `recordings`, `minutes`, `group_minutes`; `null` values = unlimited) |
| POST | `/api/groups/{gid}/recordings` | uploader | JSON: `name`, `language` + the media fields below → `202 {id, language, status}` (`"pending"` for AI, `"ready"` for manual) |
| PUT | `/api/recordings/{rid}/audio/{lang}` | uploader | JSON: the media fields below → `202 {id, language, status}`. Adds audio in `lang`, or replaces it; with manual texts, the languages in `sentences` are replaced |
| GET | `/api/groups/{gid}/recordings` | member | → list of recordings |
| GET | `/api/recordings/{rid}` | member | → one recording with its `audio` and `sentences` maps |
| GET | `/api/recordings/{rid}/audio/{lang}` | member | → the audio (or video) file in `lang`; a Drive file is passed through, honouring `Range` |
| PATCH | `/api/recordings/{rid}/sentences/{lang}/{index}` | uploader | `{text?, start_ms?, end_ms?}` → `{index, language, text, start_ms, end_ms}` |
| DELETE | `/api/recordings/{rid}` | admin | → `{deleted: true}`. Deletes audio kept in our storage (never the user's Drive files). Works even if a file is already missing |
| POST | `/api/recordings/{rid}/transcribe/{lang}` | uploader | → `202 {status: "pending", id, language}`. Only if that audio is pending/failed, else 409 |

`language` / `lang` is one of `en nb uk ru de da sv cs bg pl pt es fr el he it`
(`helpers.LANGUAGES`); anything else gives `422 Unsupported language`. A recording
only has entries for the languages that were uploaded or written; see
data-model.md for its shape.

Audio is never uploaded. The app sends a file the user saved through Media on
their own Google Drive (`/media/audio` or `/media/videos`), after sharing it with
anyone who has the link. Media fields:

| Field | |
|---|---|
| `drive_id` | the Drive file ID (required) |
| `media_kind` | `"audio"` (default) or `"video"` |
| `mime_type`, `file_name` | optional, as Drive reports them |
| `mode` | `"ai"`: transcribed by the worker (group must allow it, quotas apply) · `"manual"`: the user's own texts and timings |
| `start_ms` | manual: start of every sentence in the media, ascending |
| `end_ms` | manual, optional: same length; a `null` (or missing list) is the next start, or the end of the media |
| `sentences` | manual: `{language code: [text per sentence]}`, each list as long as `start_ms`; must include `language`. `no` is read as `nb` |

The app reads the manual texts from JSON (`[{"nb": "Hei.", "en": "Hi.", "timeMs": 0, "endMs": 900}, …]`),
SRT or WebVTT files (`lib/services/recording_texts.dart`) and sends them in this form.

Errors: `422 Invalid name` · `422 Invalid Google Drive file ID` · `422 Could not
read the media file on Google Drive…` (not shared, or not audio/video) ·
`422 Invalid duration` (>90 min) · `422` for texts that don't fit the media ·
AI only: `403 AI transcription is not enabled…` / `… quota exceeded` /
`Recording too long` (see permissions-and-quotas.md).

Sentence edit: `text` sets the sentence in `lang`, for any language, which is
how translations are added (the list is padded with `""` up to `index`).
`start_ms` + `end_ms` (both or neither) change the timing in that language's
audio. Errors: `404 Sentence not found` (index ≥ number of sentences) ·
`404 No timing for this sentence in this language` (no audio in `lang`, or it has
no timing at `index`) · `422 Invalid timestamp range` (end must be after start
and at most 0.5 s past the end of the audio) · `422 Nothing to change`.

## Chat (`routes/chat.py`)

Any logged-in user; what each user may see and do is described in [chat.md](chat.md),
which also lists the endpoints.

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
| GET | `/api/chapters/{id}/audio/{lang}` | any | → the chapter's audio file in `lang`, or a `307` redirect to the audio's `url` if it has one |

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
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Lesson 1","language":"nb","drive_id":"<shared Drive file id>","mode":"ai"}'
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

## Dictionaries (`routes/dictionaries.py`)

One file per language, `data/dictionaries/dict_<language_code>.json`. No login needed,
and readable from any origin (`Access-Control-Allow-Origin: *`), independently of `ALLOWED_ORIGINS`.

| Method | Path | Who | Response |
|---|---|---|---|
| GET | `/api/dictionaries` | nobody | → `[{lang, url: "/api/dictionary/<lang>", size}]`, sorted by `lang`; `size` is the file size in bytes |
| GET | `/api/dictionary/{language_code}` | nobody | → the content of that file, as JSON. `404 Dictionary not found` |
