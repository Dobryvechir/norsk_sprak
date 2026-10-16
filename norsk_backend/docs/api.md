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
| GET | `/api/me/groups` | any | → list of groups the user belongs to (all groups for sysadmin) |

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
| POST | `/api/groups/{gid}/recordings` | uploader | multipart form: `name`, `file` → `202 {id, status: "pending"}` |
| GET | `/api/groups/{gid}/recordings` | member | → list of recordings |
| GET | `/api/recordings/{rid}` | member | → one recording with `sentences` |
| GET | `/api/recordings/{rid}/audio` | member | → the audio file |
| PATCH | `/api/recordings/{rid}/sentences/{index}` | uploader | `{text, start_ms, end_ms}` → updated sentence |
| DELETE | `/api/recordings/{rid}` | admin | → `{deleted: true}`. Works even if the audio file is already missing |
| POST | `/api/recordings/{rid}/transcribe` | uploader | → `202 {status: "pending", id}`. Only if pending/failed, else 409 |

Upload errors: `422 Invalid name` (blank or >200 chars) · `413 File too large` ·
`422 Unsupported or invalid audio file` · `422 Invalid duration` (>90 min) ·
`403 … quota exceeded` / `Recording too long` (see permissions-and-quotas.md).

Sentence edit errors: `404 Sentence not found` · `422 Invalid timestamp range`
(end must be after start and at most 0.5 s past the end of the audio).

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
  -H "Authorization: Bearer $TOKEN" -F name="Lesson 1" -F file=@lesson1.mp3
```
