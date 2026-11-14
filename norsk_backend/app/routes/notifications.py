"""Notifications: messages a system admin shows to some or all users in the app.

    GET    /api/me/notifications?version=X    - any: the notifications for the logged-in user
    GET    /api/admin/notifications           - sysadmin: all of them
    POST   /api/admin/notifications           - sysadmin: create one
    DELETE /api/admin/notifications/{nid}     - sysadmin: remove one

Stored in the "notifications" kind. Who receives a notification (first rule that applies):

    userId set                          -> only that user
    groupId set                         -> only enabled members of that group
    privilegeFrom and/or privilegeTo set -> members of any group whose privilege is in that range
    none of these                       -> everybody

Additionally, when datetimeFrom / datetimeTo are set it is only valid between
them (server time), and when versionFrom / versionTo are set it is only for app
versions between them (the app sends its version as `?version=`). All ranges
include both ends; a missing end is open.

`severity` decides how the app shows it: <=10 info, 11-20 warning, 21-30
critical, >=31 fatal (the app shows only that message and stops). For the
first three its last digit decides how often: 0 always, 1 once, otherwise
until the user chooses "Do not remind again". The app remembers that locally.
"""

import datetime
import re

from fastapi import APIRouter, Depends

from ..helpers import fail, new_id, utc_now_iso
from ..repository import membership_key, repo
from ..schemas import CreateNotificationRequest
from ..security import current_user, require_system_admin
from .auth import find_user_by_email

router = APIRouter()

KIND = "notifications"
FIELDS = ("text", "severity", "versionFrom", "versionTo", "groupId", "userId",
          "privilegeFrom", "privilegeTo", "datetimeFrom", "datetimeTo")
# "1.2", "0.1.0+1", "2.0.0-beta"
VERSION_PATTERN = re.compile(r"\d+(\.\d+)*([+\-].*)?")


# --- Comparisons ----------------------------------------------------------------

def version_key(version: str) -> tuple[int, ...]:
    """"1.2.10+5" -> (1, 2, 10): the numbers of the version, ignoring the build ("+5")
    and pre-release ("-beta") parts. Trailing zeros are dropped so "1.2" == "1.2.0"."""
    main = re.split(r"[+\-\s]", version.strip(), maxsplit=1)[0]
    numbers = [int(m.group()) if (m := re.match(r"\d+", part)) else 0 for part in main.split(".")]
    while numbers and numbers[-1] == 0:
        numbers.pop()
    return tuple(numbers)


def parse_datetime(value: str) -> datetime.datetime:
    """ISO-8601 string -> aware datetime (a value without a time zone is taken as UTC)."""
    parsed = datetime.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=datetime.timezone.utc)


def in_range(value, low, high) -> bool:
    return (low is None or low <= value) and (high is None or value <= high)


# --- Who gets what ------------------------------------------------------------------

def user_group_ids(user) -> list[str]:
    """Groups where the user has an enabled membership (system admins: only their real memberships)."""
    ids = []
    for group in repo.list("groups"):
        membership = repo.get("memberships", membership_key(group["id"], user["id"]))
        if membership and membership.get("enabled", True):
            ids.append(group["id"])
    return ids


def addressed_to(n: dict, user: dict, group_ids: list[str], privileges: dict[str, int]) -> bool:
    if n.get("userId"):
        return n["userId"] == user["id"]
    if n.get("groupId"):
        return n["groupId"] in group_ids
    low, high = n.get("privilegeFrom"), n.get("privilegeTo")
    if low is not None or high is not None:
        return any(gid in privileges and in_range(privileges[gid], low, high) for gid in group_ids)
    return True


def is_current(n: dict, now: datetime.datetime, version: str | None) -> bool:
    """Valid at `now` and, when the app told its version, for that version."""
    low, high = n.get("datetimeFrom"), n.get("datetimeTo")
    if not in_range(now, low and parse_datetime(low), high and parse_datetime(high)):
        return False
    low, high = n.get("versionFrom"), n.get("versionTo")
    if version and (low or high):
        return in_range(version_key(version), low and version_key(low), high and version_key(high))
    return True


def notifications_for(user: dict, version: str | None, now: datetime.datetime | None = None) -> list[dict]:
    """The user's current notifications, most severe first."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    group_ids = user_group_ids(user)
    privileges = {g["id"]: g["privilege"] for g in repo.list("groups") if isinstance(g.get("privilege"), int)}
    found = [n for n in repo.list(KIND) if addressed_to(n, user, group_ids, privileges) and is_current(n, now, version)]
    return sorted(found, key=lambda n: (-n["severity"], n.get("created_at", "")))


def public_notification(n: dict) -> dict:
    return {"id": n["id"], **{k: n.get(k) for k in FIELDS}, "created_at": n.get("created_at")}


# --- Endpoints ----------------------------------------------------------------------

@router.get("/api/me/notifications")
def my_notifications(version: str | None = None, user=Depends(current_user)):
    """Notifications for the logged-in user, valid now and for app `version` (if given)."""
    return [public_notification(n) for n in notifications_for(user, version)]


@router.get("/api/admin/notifications")
def list_notifications(user=Depends(current_user)):
    """Every notification, newest first."""
    require_system_admin(user)
    return [public_notification(n) for n in sorted(repo.list(KIND), key=lambda n: n.get("created_at", ""), reverse=True)]


@router.post("/api/admin/notifications", status_code=201)
def create_notification(data: CreateNotificationRequest, user=Depends(current_user)):
    """Create a notification. `userId` may also be the user's email."""
    require_system_admin(user)
    values = data.model_dump()
    for key in FIELDS:  # empty strings mean "not set"
        if isinstance(values[key], str) and key != "text":
            values[key] = values[key].strip() or None
    values["text"] = values["text"].strip()
    if not values["text"]:
        fail(422, "Text is required")
    if values["userId"]:
        target = repo.get("users", values["userId"]) or (
            find_user_by_email(values["userId"]) if "@" in values["userId"] else None)
        if not target:
            fail(404, "User not found")
        values["userId"] = target["id"]
    if values["groupId"] and not repo.get("groups", values["groupId"]):
        fail(404, "Group not found")
    for key in ("versionFrom", "versionTo"):
        if values[key] and not VERSION_PATTERN.fullmatch(values[key]):
            fail(422, f"Invalid {key}")
    for key in ("datetimeFrom", "datetimeTo"):
        if values[key]:
            try:
                values[key] = parse_datetime(values[key]).isoformat()
            except ValueError:
                fail(422, f"Invalid {key}")
    pairs = [("privilegeFrom", "privilegeTo", lambda v: v),
             ("versionFrom", "versionTo", version_key),
             ("datetimeFrom", "datetimeTo", parse_datetime)]
    for low, high, key in pairs:
        if values[low] is not None and values[high] is not None and key(values[low]) > key(values[high]):
            fail(422, f"{low} is after {high}")
    notification = {"id": new_id(), **values, "created_at": utc_now_iso(), "created_by": user["id"]}
    repo.put(KIND, notification["id"], notification)
    return public_notification(notification)


@router.delete("/api/admin/notifications/{nid}")
def delete_notification(nid: str, user=Depends(current_user)):
    require_system_admin(user)
    if not repo.get(KIND, nid):
        fail(404, "Notification not found")
    repo.delete(KIND, nid)
    return {"id": nid, "deleted": True}
