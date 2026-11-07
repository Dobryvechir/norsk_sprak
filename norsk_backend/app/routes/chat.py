"""Chat endpoints. The rules live in chat.py; docs/chat.md describes the feature."""

import base64
import binascii
import datetime
from urllib.parse import urlparse

from fastapi import APIRouter, Depends, Response

from .. import chat
from ..chat import conversation, iso, now_utc, public_person, require_photo
from ..helpers import fail, new_id
from ..repository import repo
from ..schemas import (ChatMessageRequest, ChatProfileRequest, CreateSubgroupRequest,
                       DirectChatRequest, InviteRequest, LocationRequest)
from ..security import current_user

router = APIRouter()

MAX_PHOTO_BYTES = 64 * 1024
PHOTO_TYPES = {b"\x89PNG\r\n\x1a\n": "image/png", b"\xff\xd8\xff": "image/jpeg"}
# Attachments must be links to Google Drive (the files never come to this server).
DRIVE_HOSTS = {"drive.google.com", "docs.google.com"}
MAX_SEARCH_RESULTS = 20


# --- Profile, photo, status -----------------------------------------------------

@router.get("/api/chat/status")
def status(user=Depends(current_user)):
    """The user's chat profile, pending invitations, and whether a family member
    is waiting for this user's location (the app then sends it: PUT /api/chat/location)."""
    chat.purge_expired()
    location = repo.get("chat_locations", user["id"]) or {}
    requested = location.get("requestedAt")
    waiting = bool(requested) and requested > iso(now_utc() - datetime.timedelta(seconds=chat.LOCATION_REQUEST_SECONDS)) \
        and (location.get("updatedAt") or "") < requested
    return {**public_person(user["id"]), "invitations": len(_invitations(user)), "locationRequested": waiting}


@router.put("/api/chat/profile")
def set_profile(data: ChatProfileRequest, user=Depends(current_user)):
    """Set the name shown in Chat and (optionally) a new small photo."""
    with repo.lock:
        current = chat.profile(user["id"])
        updated = {**current, "userId": user["id"], "displayName": data.displayName.strip() or chat.display_name(user["id"])}
        if data.photo is not None:
            try:
                raw = base64.b64decode(data.photo, validate=True)
            except (binascii.Error, ValueError):
                fail(422, "Invalid photo")
            mime = next((t for magic, t in PHOTO_TYPES.items() if raw.startswith(magic)), None)
            if not mime or len(raw) > MAX_PHOTO_BYTES:
                fail(422, "The photo must be a PNG or JPEG of at most 64 kB")
            updated.update(photo=data.photo, photoType=mime, photoVersion=current.get("photoVersion", 0) + 1)
        repo.put("chat_profiles", user["id"], updated)
    return public_person(user["id"])


@router.get("/api/chat/photos/{uid}")
def photo(uid: str, user=Depends(current_user)):
    """The user's photo, for users who share a non-anonymous group with them."""
    p = chat.profile(uid)
    if not p.get("photo") or not chat.shares_chat_group(user, uid):
        fail(404, "No photo")
    return Response(base64.b64decode(p["photo"]), media_type=p["photoType"],
                    headers={"Cache-Control": "private, max-age=3600"})


# --- Search ------------------------------------------------------------------------

@router.get("/api/chat/users")
def search_users(q: str = "", user=Depends(current_user)):
    """Users who share a non-anonymous group with the caller, whose name or email
    contains `q` (at least 2 characters), each with the groups they share."""
    q = q.strip().lower()
    if len(q) < 2:
        return []
    found = {}
    for group in chat.chat_groups(user):
        for uid in chat.group_member_ids(group["id"]):
            if uid == user["id"]:
                continue
            if uid not in found:
                other = repo.get("users", uid)
                if q not in chat.display_name(uid).lower() and q not in other["email"]:
                    continue
                found[uid] = {**public_person(uid), "groups": []}
            found[uid]["groups"].append({"id": group["id"], "name": group["name"]})
    return sorted(found.values(), key=lambda p: p["displayName"].lower())[:MAX_SEARCH_RESULTS]


# --- Conversations and messages ------------------------------------------------------

def _try_conversation(user, cid):
    try:
        return conversation(user, cid)
    except Exception:  # no longer allowed (left the group, group became anonymous, ...)
        return None


@router.get("/api/chat/conversations")
def list_conversations(user=Depends(current_user)):
    """Every chat the user takes part in: their non-anonymous groups, their
    subgroups and their direct chats."""
    ids = [f"g-{g['id']}" for g in chat.chat_groups(user)]
    ids += [f"s-{s['id']}" for s in repo.list("subgroups") if user["id"] in s["members"]]
    ids += (repo.get("chat_inbox", user["id"]) or {}).get("directs", [])
    convs = [c for c in (_try_conversation(user, cid) for cid in ids) if c]
    return [chat.summary(c, user["id"]) for c in convs]


@router.get("/api/chat/conversations/{cid}")
def get_conversation(cid: str, user=Depends(current_user)):
    return chat.summary(conversation(user, cid), user["id"])


@router.post("/api/chat/directs")
def open_direct(data: DirectChatRequest, user=Depends(current_user)):
    """The direct chat with another member of a non-anonymous group (created when
    the first message is sent)."""
    require_photo(user)
    if data.userId == user["id"]:
        fail(422, "Cannot chat with yourself")
    return chat.summary(conversation(user, chat.direct_id(data.groupId, user["id"], data.userId)), user["id"])


@router.get("/api/chat/conversations/{cid}/messages")
def get_messages(cid: str, since: str | None = None, user=Depends(current_user)):
    """Messages of the last `expirationDays`, oldest first; with `since` (a
    message's createdAt) only newer ones."""
    chat.purge_expired()
    conv = conversation(user, cid)
    if since:
        try:
            chat.parse_iso(since)
        except ValueError:
            fail(422, "Invalid since")
    return chat.list_messages(conv, since)


@router.post("/api/chat/conversations/{cid}/messages")
def post_message(cid: str, data: ChatMessageRequest, user=Depends(current_user)):
    """Send text and/or links to files on Google Drive."""
    chat.purge_expired()
    require_photo(user)
    conv = conversation(user, cid)
    text = data.text.strip()
    attachments = [a.model_dump(exclude_none=True) for a in data.attachments]
    if not text and not attachments:
        fail(422, "Empty message")
    for a in attachments:
        url = urlparse(a["url"])
        if url.scheme != "https" or url.hostname not in DRIVE_HOSTS:
            fail(422, "Attachments must be Google Drive links")
    return chat.add_message(conv, user, text, attachments)


@router.get("/api/chat/conversations/{cid}/members")
def get_members(cid: str, user=Depends(current_user)):
    conv = conversation(user, cid)
    people = [public_person(uid) for uid in chat.member_ids(conv)]
    if conv["type"] == "subgroup":
        sub = conv["subgroup"]
        for p in people:
            p["owner"] = p["id"] == sub["ownerId"]
        people += [{**public_person(uid), "invited": True} for uid in sub.get("invited", [])]
    return people


# --- Subgroups -------------------------------------------------------------------------

def _subgroup(sid):
    sub = repo.get("subgroups", sid)
    if not sub:
        fail(404, "Subgroup not found")
    return sub


def _invitations(user) -> list:
    result = []
    for sub in repo.list("subgroups"):
        if user["id"] in sub.get("invited", []):
            group = repo.get("groups", sub["groupId"])
            if group and not chat.group_chat_settings(group)["anonymous"] \
                    and chat.is_group_member(user["id"], group["id"]):
                result.append({"id": sub["id"], "name": sub["name"], "family": bool(sub.get("family")),
                               "groupId": group["id"], "groupName": group["name"],
                               "invitedBy": public_person(sub["ownerId"])})
    return result


@router.post("/api/chat/subgroups")
def create_subgroup(data: CreateSubgroupRequest, user=Depends(current_user)):
    """Create a subgroup of a non-anonymous group the user belongs to. Each user
    may create `subgroupLimitPerYear` per group per calendar year."""
    require_photo(user)
    group = repo.get("groups", data.groupId)
    if not group or chat.group_chat_settings(group)["anonymous"]:
        fail(404, "Group not found")
    if not chat.is_group_member(user["id"], group["id"]):
        fail(403, "Not a group member")
    year = now_utc().strftime("%Y")
    with repo.lock:
        counter_key = f"{group['id']}_{user['id']}_{year}"
        counter = repo.get("chat_subgroup_counts", counter_key) or {"count": 0}
        if counter["count"] >= chat.group_chat_settings(group)["subgroupLimitPerYear"]:
            fail(403, "Yearly subgroup limit reached")
        sub = {"id": new_id(), "groupId": group["id"], "name": data.name.strip(), "family": data.family,
               "ownerId": user["id"], "members": [user["id"]], "invited": [], "createdAt": iso(now_utc())}
        repo.put("subgroups", sub["id"], sub)
        repo.put("chat_subgroup_counts", counter_key, {"count": counter["count"] + 1})
    return chat.summary(conversation(user, f"s-{sub['id']}"), user["id"])


@router.get("/api/chat/invitations")
def list_invitations(user=Depends(current_user)):
    return _invitations(user)


@router.post("/api/chat/subgroups/{sid}/invite")
def invite(sid: str, data: InviteRequest, user=Depends(current_user)):
    """The owner invites members of the parent group; they join when they accept."""
    require_photo(user)
    with repo.lock:
        sub = _subgroup(sid)
        conversation(user, f"s-{sid}")
        if sub["ownerId"] != user["id"]:
            fail(403, "Only the owner can invite")
        for uid in data.userIds:
            if not chat.is_group_member(uid, sub["groupId"]):
                fail(422, "Only members of the group can be invited")
            if uid not in sub["members"] and uid not in sub["invited"]:
                sub["invited"].append(uid)
        repo.put("subgroups", sid, sub)
    return {"invited": sub["invited"]}


@router.post("/api/chat/subgroups/{sid}/accept")
def accept(sid: str, user=Depends(current_user)):
    require_photo(user)
    with repo.lock:
        sub = _subgroup(sid)
        if user["id"] not in sub.get("invited", []) or not chat.is_group_member(user["id"], sub["groupId"]):
            fail(404, "No invitation")
        sub["invited"].remove(user["id"])
        sub["members"].append(user["id"])
        repo.put("subgroups", sid, sub)
    return chat.summary(conversation(user, f"s-{sid}"), user["id"])


@router.post("/api/chat/subgroups/{sid}/decline")
def decline(sid: str, user=Depends(current_user)):
    with repo.lock:
        sub = _subgroup(sid)
        if user["id"] in sub.get("invited", []):
            sub["invited"].remove(user["id"])
            repo.put("subgroups", sid, sub)
    return {"declined": True}


@router.post("/api/chat/subgroups/{sid}/leave")
def leave(sid: str, user=Depends(current_user)):
    with repo.lock:
        sub = _subgroup(sid)
        if sub["ownerId"] == user["id"]:
            fail(409, "The owner cannot leave; delete the subgroup instead")
        if user["id"] in sub["members"]:
            sub["members"].remove(user["id"])
            repo.put("subgroups", sid, sub)
    return {"left": True}


@router.delete("/api/chat/subgroups/{sid}/members/{uid}")
def remove_member(sid: str, uid: str, user=Depends(current_user)):
    """The owner removes a member, or withdraws an invitation."""
    with repo.lock:
        sub = _subgroup(sid)
        if sub["ownerId"] != user["id"]:
            fail(403, "Only the owner can remove members")
        if uid == user["id"]:
            fail(409, "The owner cannot be removed")
        sub["members"] = [m for m in sub["members"] if m != uid]
        sub["invited"] = [m for m in sub.get("invited", []) if m != uid]
        repo.put("subgroups", sid, sub)
    return {"removed": True}


@router.delete("/api/chat/subgroups/{sid}")
def delete_subgroup(sid: str, user=Depends(current_user)):
    """The owner (or a system admin) deletes the subgroup and its messages.
    It still counts towards the owner's yearly limit."""
    sub = _subgroup(sid)
    if sub["ownerId"] != user["id"] and not user.get("system_admin"):
        fail(403, "Only the owner can delete the subgroup")
    chat.delete_conversation_messages(f"s-{sid}")
    repo.delete("subgroups", sid)
    return {"deleted": True}


# --- Family location ------------------------------------------------------------------

@router.put("/api/chat/location")
def put_location(data: LocationRequest, user=Depends(current_user)):
    """The app sends the user's location when a family member asked for it
    (GET /api/chat/status says so). Only the last one is kept, for one day."""
    with repo.lock:
        location = repo.get("chat_locations", user["id"]) or {"userId": user["id"]}
        location.update(lat=data.lat, lng=data.lng, accuracy=data.accuracy, updatedAt=iso(now_utc()))
        repo.put("chat_locations", user["id"], location)
    return {"saved": True}


def _family_target(user, cid, uid):
    conv = conversation(user, cid)
    if not conv["family"]:
        fail(403, "Not a family chat")
    members = chat.member_ids(conv)
    if user["id"] not in members or uid not in members or uid == user["id"]:
        fail(403, "Not a member of this family chat")


def _location(uid):
    location = repo.get("chat_locations", uid) or {}
    if "lat" not in location:
        return {"userId": uid, "location": None, "requestedAt": location.get("requestedAt")}
    return {"userId": uid, "requestedAt": location.get("requestedAt"),
            "location": {k: location.get(k) for k in ("lat", "lng", "accuracy", "updatedAt")}}


@router.post("/api/chat/conversations/{cid}/members/{uid}/location")
def request_location(cid: str, uid: str, user=Depends(current_user)):
    """"Find location": asks the member's app for its current location and returns
    the last one known. Poll GET on the same path for the fresh one."""
    _family_target(user, cid, uid)
    with repo.lock:
        location = repo.get("chat_locations", uid) or {"userId": uid}
        location["requestedAt"] = iso(now_utc())
        repo.put("chat_locations", uid, location)
    return _location(uid)


@router.get("/api/chat/conversations/{cid}/members/{uid}/location")
def get_location(cid: str, uid: str, user=Depends(current_user)):
    _family_target(user, cid, uid)
    return _location(uid)
