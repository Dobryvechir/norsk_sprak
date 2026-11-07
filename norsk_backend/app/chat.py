"""
Chat: storage, permission checks and clean-up shared by routes/chat.py.

Conversations (ids are safe as file names):
    g-<group id>                     - the chat of a whole (non-anonymous) group
    s-<subgroup id>                  - a subgroup created by a user inside a group
    d-<group id>-<user id>-<user id> - two users of the same group (ids sorted)

Only text and links are stored here: pictures, audio, video and files stay on
the sender's Google Drive, shared "anyone with the link", and messages carry
links to them. Messages are kept for the group's `expirationDays` and then
deleted (see `purge_expired`). See docs/chat.md.
"""

import datetime
import json
import time

from .helpers import fail
from .repository import membership_key, repo

# Chat settings of a group; groups saved before chat existed get these defaults.
GROUP_CHAT_DEFAULTS = {
    "anonymous": False,          # anonymous groups take no part in Chat at all
    "family": False,             # members may see each other's location ("Find location")
    "subgroupLimitPerYear": 20,  # subgroups one user may create in the group per calendar year
    "chatPerDayKb": 500,         # text + links one user may send in the group per UTC day, in kB
    "expirationDays": 7,         # messages are deleted after this many days
}

# How long a "Find location" request waits for the other user's app to answer.
LOCATION_REQUEST_SECONDS = 120
# Locations are deleted after this long (only the last one is ever kept).
LOCATION_KEEP = datetime.timedelta(days=1)
# purge_expired runs at most this often when triggered by requests.
PURGE_INTERVAL_SECONDS = 600
_last_purge = 0.0


def now_utc() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def iso(moment: datetime.datetime) -> str:
    """Fixed-width ISO time, so these strings sort and compare like the times themselves."""
    return moment.astimezone(datetime.timezone.utc).isoformat(timespec="microseconds")


def parse_iso(text: str) -> datetime.datetime:
    moment = datetime.datetime.fromisoformat(text)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return moment


def day_of(moment: datetime.datetime) -> str:
    return moment.strftime("%Y%m%d")


def group_chat_settings(group) -> dict:
    return {key: group.get(key, default) for key, default in GROUP_CHAT_DEFAULTS.items()}


# --- Who belongs where ---------------------------------------------------------

def is_group_member(user_id, group_id) -> bool:
    """An enabled membership of an enabled user (system admins don't count here)."""
    membership = repo.get("memberships", membership_key(group_id, user_id))
    if not membership or not membership.get("enabled", True):
        return False
    user = repo.get("users", user_id)
    return bool(user and user.get("enabled", True))


def can_read_group(user, group) -> bool:
    return bool(group) and not group_chat_settings(group)["anonymous"] and (
        user.get("system_admin") or is_group_member(user["id"], group["id"]))


def chat_groups(user) -> list:
    """The non-anonymous groups whose chat the user may use."""
    return [g for g in repo.list("groups") if can_read_group(user, g)]


def group_member_ids(group_id) -> list:
    return sorted(
        m["user_id"] for m in repo.list("memberships")
        if m["group_id"] == group_id and is_group_member(m["user_id"], group_id)
    )


def shares_chat_group(user, other_id) -> bool:
    """Whether `user` may see `other_id` in Chat: both in one non-anonymous group."""
    if user["id"] == other_id or user.get("system_admin"):
        return True
    return any(is_group_member(other_id, g["id"]) for g in chat_groups(user))


# --- Profiles (display name and photo) ----------------------------------------

def profile(user_id) -> dict:
    return repo.get("chat_profiles", user_id) or {}


def display_name(user_id) -> str:
    name = profile(user_id).get("displayName")
    if name:
        return name
    user = repo.get("users", user_id)
    return user["email"].split("@")[0] if user else "?"


def public_person(user_id) -> dict:
    p = profile(user_id)
    return {"id": user_id, "displayName": display_name(user_id),
            "hasPhoto": bool(p.get("photo")), "photoVersion": p.get("photoVersion", 0)}


def require_photo(user):
    """Users must have a photo before they communicate in Chat."""
    if not profile(user["id"]).get("photo"):
        fail(403, "Upload your photo first")


# --- Conversations -------------------------------------------------------------

def direct_id(group_id, a, b) -> str:
    first, second = sorted((a, b))
    return f"d-{group_id}-{first}-{second}"


def conversation(user, cid) -> dict:
    """The conversation `cid` if `user` may use it, else fail (404/403).

    Returns {id, type, groupId, group, name, family, ownerId?, members?}.
    """
    kind, _, rest = cid.partition("-")
    if kind == "g":
        group = repo.get("groups", rest)
        if not group or group_chat_settings(group)["anonymous"]:
            fail(404, "Chat not found")
        if not can_read_group(user, group):
            fail(403, "Not a group member")
        return {"id": cid, "type": "group", "groupId": group["id"], "group": group,
                "name": group["name"], "family": group_chat_settings(group)["family"]}
    if kind == "s":
        sub = repo.get("subgroups", rest)
        group = sub and repo.get("groups", sub["groupId"])
        if not group or group_chat_settings(group)["anonymous"]:
            fail(404, "Chat not found")
        if user["id"] not in sub["members"] or not is_group_member(user["id"], group["id"]):
            fail(403, "Not a subgroup member")
        return {"id": cid, "type": "subgroup", "groupId": group["id"], "group": group,
                "name": sub["name"], "family": bool(sub.get("family")), "subgroup": sub}
    if kind == "d":
        parts = rest.split("-")
        group = len(parts) == 3 and repo.get("groups", parts[0])
        if not group or group_chat_settings(group)["anonymous"] or parts[1] >= parts[2]:
            fail(404, "Chat not found")
        if user["id"] not in parts[1:] or not all(is_group_member(u, group["id"]) for u in parts[1:]):
            fail(403, "Not part of this chat")
        other = parts[2] if parts[1] == user["id"] else parts[1]
        return {"id": cid, "type": "direct", "groupId": group["id"], "group": group,
                "name": display_name(other), "otherUserId": other, "family": False}
    fail(404, "Chat not found")


def member_ids(conv) -> list:
    if conv["type"] == "group":
        return group_member_ids(conv["groupId"])
    if conv["type"] == "subgroup":
        return list(conv["subgroup"]["members"])
    return sorted(conv["id"].split("-")[2:])


def summary(conv, user_id) -> dict:
    """What the conversation list shows."""
    meta = repo.get("chat_meta", conv["id"]) or {}
    result = {"id": conv["id"], "type": conv["type"], "name": conv["name"], "groupId": conv["groupId"],
              "groupName": conv["group"]["name"], "family": conv["family"], "lastAt": meta.get("lastAt")}
    if conv["type"] == "subgroup":
        result["ownerId"] = conv["subgroup"]["ownerId"]
        result["isOwner"] = conv["subgroup"]["ownerId"] == user_id
    if conv["type"] == "direct":
        result["otherUserId"] = conv["otherUserId"]
    return result


# --- Messages --------------------------------------------------------------------

def message_size(text, attachments) -> int:
    """Bytes a message counts against chatPerDayKb: its text and links as UTF-8 JSON."""
    return len(json.dumps({"text": text, "attachments": attachments}, ensure_ascii=False).encode("utf-8"))


def add_message(conv, user, text, attachments) -> dict:
    """Store a message after checking the sender's daily limit. Returns the message."""
    settings = group_chat_settings(conv["group"])
    size = message_size(text, attachments)
    now = now_utc()
    day = day_of(now)
    with repo.lock:
        usage_key = f"{conv['groupId']}_{user['id']}_{day}"
        usage = repo.get("chat_usage", usage_key) or {
            "groupId": conv["groupId"], "userId": user["id"], "day": day, "bytes": 0}
        if usage["bytes"] + size > settings["chatPerDayKb"] * 1024:
            fail(403, "Daily chat limit exceeded")
        usage["bytes"] += size
        repo.put("chat_usage", usage_key, usage)

        message = {"id": f"{int(now.timestamp() * 1e6)}-{user['id'][:8]}", "senderId": user["id"],
                   "createdAt": iso(now), "text": text, "attachments": attachments}
        key = f"{conv['id']}_{day}"
        doc = repo.get("chat_messages", key) or {
            "conversationId": conv["id"], "groupId": conv["groupId"], "day": day, "messages": []}
        doc["messages"].append(message)
        repo.put("chat_messages", key, doc)
        repo.put("chat_meta", conv["id"], {"lastAt": message["createdAt"]})
        if conv["type"] == "direct":
            for uid in member_ids(conv):
                inbox = repo.get("chat_inbox", uid) or {"directs": []}
                if conv["id"] not in inbox["directs"]:
                    inbox["directs"].append(conv["id"])
                    repo.put("chat_inbox", uid, inbox)
    return message


def list_messages(conv, since: str | None, limit=500) -> list:
    """Messages newer than `since` (and not expired), oldest first, at most `limit` (the newest)."""
    now = now_utc()
    days = group_chat_settings(conv["group"])["expirationDays"]
    cutoff = iso(now - datetime.timedelta(days=days))
    after = max(cutoff, iso(parse_iso(since))) if since else cutoff
    result = []
    for back in range(days, -1, -1):
        doc = repo.get("chat_messages", f"{conv['id']}_{day_of(now - datetime.timedelta(days=back))}")
        if doc:
            result.extend(m for m in doc["messages"] if m["createdAt"] > after)
    result.sort(key=lambda m: m["createdAt"])
    return result[-limit:]


def delete_conversation_messages(cid):
    with repo.lock:
        for doc in repo.list("chat_messages"):
            if doc["conversationId"] == cid:
                repo.delete("chat_messages", f"{cid}_{doc['day']}")
        repo.delete("chat_meta", cid)


def purge_expired(force=False) -> int:
    """Delete expired messages, old daily usage counters and old locations.

    Runs at startup and then at most every PURGE_INTERVAL_SECONDS when a chat
    request triggers it. Returns how many messages were deleted.
    """
    global _last_purge
    if not force and time.monotonic() - _last_purge < PURGE_INTERVAL_SECONDS:
        return 0
    _last_purge = time.monotonic()
    now = now_utc()
    groups = {g["id"]: g for g in repo.list("groups")}
    deleted = 0
    with repo.lock:
        for doc in repo.list("chat_messages"):
            group = groups.get(doc.get("groupId"))
            days = group_chat_settings(group)["expirationDays"] if group else 0
            cutoff = iso(now - datetime.timedelta(days=days))
            kept = [m for m in doc["messages"] if m["createdAt"] >= cutoff]
            key = f"{doc['conversationId']}_{doc['day']}"
            deleted += len(doc["messages"]) - len(kept)
            if not kept:
                repo.delete("chat_messages", key)
            elif len(kept) != len(doc["messages"]):
                repo.put("chat_messages", key, {**doc, "messages": kept})
        yesterday = day_of(now - datetime.timedelta(days=1))
        for usage in repo.list("chat_usage"):
            if usage["day"] < yesterday:
                repo.delete("chat_usage", f"{usage['groupId']}_{usage['userId']}_{usage['day']}")
        oldest = iso(now - LOCATION_KEEP)
        for location in repo.list("chat_locations"):
            if max(location.get("updatedAt") or "", location.get("requestedAt") or "") < oldest:
                repo.delete("chat_locations", location["userId"])
    return deleted
