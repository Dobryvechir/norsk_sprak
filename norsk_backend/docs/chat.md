# Chat

Code: `app/chat.py` (rules, storage, clean-up) and `app/routes/chat.py` (endpoints).
The app side is `lib/screens/chat_*.dart` and `lib/services/chat_api.dart`.

## Group settings

Every group has these chat settings (groups made before Chat get the defaults):

| Field | Default | Meaning |
|---|---|---|
| `anonymous` | `false` | Anonymous groups take no part in Chat: no group chat, no subgroups, members can't find each other through it. |
| `family` | `false` | Members of the group chat may use "Find location" on each other. |
| `subgroupLimitPerYear` | `20` | Subgroups one user may create in the group per calendar year (deleting one doesn't give it back; system admins are exempt). |
| `chatPerDayKb` | `500` | Text + links one user may send in the group (its chat, its subgroups and direct chats in it) per UTC day, in kB, measured as the UTF-8 JSON of text and attachments. |
| `expirationDays` | `7` | Messages are deleted after this many days. |

Set them when creating the group (`POST /api/admin/groups`), or later as group admin
with `PATCH /api/groups/{gid}/settings` (fields left out keep their value).
Any member can read them with `GET /api/groups/{gid}/settings`.

## Conversations

| Id | What | Who |
|---|---|---|
| `g-<group id>` | the whole group, shown by the group's name | enabled members (and system admins) of a non-anonymous group |
| `s-<subgroup id>` | a subgroup created by a user | its members (who must still be members of the group) |
| `d-<group id>-<user>-<user>` | two members of a non-anonymous group (user ids sorted) | those two |

Subgroups: the creator (owner) invites members of the parent group; an invited user
joins only after accepting. A subgroup created as `family` lets its members use "Find
location" on each other, so invitations to it say so. The owner can remove members
and delete the subgroup (with its messages); others can leave.

## Photos

Each user must upload a small photo (PNG or JPEG, ≤ 64 kB; the app sends a 96 px PNG)
before sending messages, creating subgroups, inviting or accepting. It is stored on
this server in `chat_profiles` and only shown to users sharing a non-anonymous group.

## Files are never sent here

Pictures, audio, video and other files are uploaded by the app to the sender's own
Google Drive (folder `chat`, or an existing file from `media`), shared as "anyone with
the link can view", and only the link is sent. The server accepts attachment URLs only
on `https://drive.google.com` / `https://docs.google.com`. Sending attachments needs the
user's Google Drive token in the app's Settings; everybody can open the links.
Deleting a message's Drive file is up to its owner; expiry only deletes the message.

## Find location

Only in family chats (a `family` group's chat or a `family` subgroup), between two
members of that chat:

1. `POST /api/chat/conversations/{cid}/members/{uid}/location` marks a request and
   returns the last known location.
2. The other user's app asks `GET /api/chat/status` every 30 s while it is open after
   sign-in; when `locationRequested` is true (a request in the last 2 minutes not yet
   answered) it sends its position with `PUT /api/chat/location`.
3. The asker polls `GET …/location` and opens the coordinates in Google Maps.

Only the last location is kept, and it is deleted after a day. Nothing is sent unless
someone asked, and only while the app is open.

## Expiry and clean-up

Messages are stored per conversation and UTC day (`chat_messages`, key
`<cid>_<YYYYMMDD>`). Reading never returns messages older than `expirationDays`.
`purge_expired` deletes them for good, together with old daily usage counters and
old locations; it runs at startup and then at most every 10 minutes when chat
endpoints are used.

## Endpoints

| Method | Path | Body → Response |
|---|---|---|
| GET | `/api/chat/status` | → `{id, displayName, hasPhoto, photoVersion, invitations, locationRequested}` |
| PUT | `/api/chat/profile` | `{displayName, photo?: base64}` → person |
| GET | `/api/chat/photos/{uid}` | → image bytes |
| GET | `/api/chat/users?q=` | → people (≥ 2 chars; name or email) sharing a non-anonymous group, each with `groups` |
| GET | `/api/chat/conversations` | → `[{id, type, name, groupId, groupName, family, lastAt, isOwner?, otherUserId?}]` |
| GET | `/api/chat/conversations/{cid}` | → one conversation |
| POST | `/api/chat/directs` | `{groupId, userId}` → direct conversation |
| GET | `/api/chat/conversations/{cid}/messages?since=` | → messages, oldest first |
| POST | `/api/chat/conversations/{cid}/messages` | `{text, attachments: [{kind, name, url, driveId?, mimeType?, size?}]}` → message. `403 Daily chat limit exceeded` |
| GET | `/api/chat/conversations/{cid}/members` | → people (`owner` / `invited` flags in subgroups) |
| POST | `/api/chat/subgroups` | `{groupId, name, family}` → conversation. `403 Yearly subgroup limit reached` |
| GET | `/api/chat/invitations` | → `[{id, name, family, groupId, groupName, invitedBy}]` |
| POST | `/api/chat/subgroups/{sid}/invite` | `{userIds}` (owner) |
| POST | `/api/chat/subgroups/{sid}/accept` · `/decline` · `/leave` | |
| DELETE | `/api/chat/subgroups/{sid}/members/{uid}` | owner removes a member or withdraws an invitation |
| DELETE | `/api/chat/subgroups/{sid}` | owner or system admin |
| POST / GET | `/api/chat/conversations/{cid}/members/{uid}/location` | request / read a family member's location → `{userId, location: {lat, lng, accuracy, updatedAt} \| null}` |
| PUT | `/api/chat/location` | `{lat, lng, accuracy?}` |

## Stored kinds

`subgroups`, `chat_profiles`, `chat_messages`, `chat_meta` (last activity per
conversation), `chat_inbox` (a user's direct chats), `chat_usage` (bytes per group,
user and day), `chat_subgroup_counts` (per group, user and year), `chat_locations`.
