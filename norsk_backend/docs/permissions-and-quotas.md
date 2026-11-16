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
| Share recordings with their own texts (within `shareRecords`), delete their own | ✅ | ✅ | ✅ |
| AI recordings, add audio languages, edit sentences, (re)start transcription | | ✅ | ✅ |
| Manage members, change AI config, see usage, delete any recording | | | ✅ |

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

Only AI transcription is limited: audio whose texts and timings the user provides
(`"timing": "manual"`) never counts and is never refused for quota. A group admin
can turn AI off for the whole group with `ai.enabled: false`
(`PATCH /api/groups/{gid}/ai-config`). The app asks
`GET /api/groups/{gid}/ai-allowance` to show whether AI can be chosen.

All limits are per calendar month (UTC). Missing or `null` means unlimited. Every
AI-transcribed audio counts, so a recording with AI audio in two languages counts
as two. Audio whose transcription `"failed"` doesn't count, so a failed
transcription gives the quota back.

| Where it's set | Field | Rejects the upload when… | Error |
|---|---|---|---|
| group `ai` | `enabled: false` | always | `AI transcription is not enabled for this group` |
| membership `quota` | `max_recordings_per_month` | user already has this many this month | `Monthly recording quota exceeded` |
| membership `quota` | `max_audio_minutes_per_month` | user's minutes this month + new file > limit | `Monthly audio quota exceeded` |
| membership `quota` | `max_recording_duration_minutes` | the new file alone is longer | `Recording too long` |
| group `ai` | `monthly_audio_minutes_limit` | whole group's minutes this month + new file > limit | `Group AI quota exceeded` |

Example membership body:

```json
{"role": "uploader", "quota": {"max_recordings_per_month": 20, "max_audio_minutes_per_month": 600}}
```

Independently of quotas, every media file must be ≤ 90 minutes.

## Sharing recordings (`shareRecords`)

A recording made from the user's own texts (`"source": "file"`) is limited by the
group's `shareRecords`: how many each member may create per calendar month (UTC).
`0` means members can't share at all; the "Basic" group (privilege 0) has `0`,
every other group `100` (set at startup for groups without the field, and when a
group is created; a system admin may pass another value to
`POST /api/admin/groups`). System admins are not limited. AI recordings don't
count here: the AI quotas above apply to them. The app asks
`GET /api/groups/{gid}/share-allowance` to show whether "Share" can be used, and
over the limit `POST /api/groups/{gid}/recordings` answers
`403 Monthly sharing quota exceeded` (`403 Sharing recordings is not allowed in
this group` when the limit is 0).
