# Permissions and quotas

## Two kinds of power

**System admin** is a flag on the user (`"system_admin": true`). System admins can
do anything in every group, and quota limits never apply to them personally (the
group-wide limit still does). The first one is created from
`BOOTSTRAP_ADMIN_EMAIL` / `BOOTSTRAP_ADMIN_PASSWORD` at startup. Only system admins
can create users and groups.

**Group role** comes from a *membership*, one per (group, user) pair:

| Can… | viewer | uploader | admin |
|---|:-:|:-:|:-:|
| See the group, list/read recordings, play audio | ✅ | ✅ | ✅ |
| Upload recordings, edit sentences, (re)start transcription | | ✅ | ✅ |
| Manage members, change AI config, see usage, delete recordings | | | ✅ |

A membership with `"enabled": false` counts as no membership at all (403).
A user with `"enabled": false` can't log in, and their existing tokens stop working.

## How the checks work in code (`security.py`)

```python
user = Depends(current_user)              # 401 if not logged in
require_system_admin(user)                # 403 unless system admin
get_membership(user, gid)                 # 404 no group, 403 not a member
require_role(user, gid, [UPLOADER, ADMIN])  # ...and 403 if wrong role
```

For a system admin, `get_membership` returns a made-up membership
`{"role": "admin", "quota": {}}`, so all role checks pass and no personal quota applies.

## Quotas (`quotas.py`)

Checked on every upload. All limits are per calendar month (UTC). Missing or
`null` means unlimited. Recordings with status `"failed"` don't count, so a failed
transcription gives the quota back.

| Where it's set | Field | Rejects the upload when… | Error |
|---|---|---|---|
| membership `quota` | `max_recordings_per_month` | user already has this many this month | `Monthly recording quota exceeded` |
| membership `quota` | `max_audio_minutes_per_month` | user's minutes this month + new file > limit | `Monthly audio quota exceeded` |
| membership `quota` | `max_recording_duration_minutes` | the new file alone is longer | `Recording too long` |
| group `ai` | `monthly_audio_minutes_limit` | whole group's minutes this month + new file > limit | `Group AI quota exceeded` |

Example membership body:

```json
{"role": "uploader", "quota": {"max_recordings_per_month": 20, "max_audio_minutes_per_month": 600}}
```

Independently of quotas, every upload must be ≤ `MAX_UPLOAD_MB` and ≤ 90 minutes.
