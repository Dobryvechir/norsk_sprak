"""Group-admin endpoints: membership, AI settings and usage reports."""

from fastapi import APIRouter, Depends

from ..helpers import fail
from ..repository import membership_key, repo
from ..schemas import AIConfigRequest, MemberRequest
from ..security import ADMIN, ROLES, current_user, require_role

router = APIRouter()


def is_valid_quota(quota: dict) -> bool:
    """Every quota value must be null (= unlimited) or a non-negative integer.

    `True`/`False` are rejected explicitly because Python treats them as ints.
    """
    for value in quota.values():
        if value is None:
            continue
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            return False
    return True


@router.get("/api/groups/{gid}/members")
def list_members(gid: str, user=Depends(current_user)):
    """All memberships of the group."""
    require_role(user, gid, [ADMIN])
    return [m for m in repo.list("memberships") if m["group_id"] == gid]


@router.put("/api/groups/{gid}/members/{user_id}")
def set_member(gid: str, user_id: str, data: MemberRequest, user=Depends(current_user)):
    """Add a user to the group, or replace their existing membership."""
    require_role(user, gid, [ADMIN])
    if not repo.get("users", user_id):
        fail(404, "User not found")
    if data.role not in ROLES:
        fail(422, "Invalid role")
    if not is_valid_quota(data.quota):
        fail(422, "Invalid quota")

    membership = {
        "group_id": gid,
        "user_id": user_id,
        "role": data.role,
        "enabled": data.enabled,
        "quota": data.quota,
    }
    repo.put("memberships", membership_key(gid, user_id), membership)
    return membership


@router.patch("/api/groups/{gid}/ai-config")
def set_ai_config(gid: str, data: AIConfigRequest, user=Depends(current_user)):
    """Replace the group's AI settings. Fields left out reset to their defaults."""
    require_role(user, gid, [ADMIN])
    group = repo.get("groups", gid)
    group["ai"] = data.model_dump()
    repo.put("groups", gid, group)
    return group["ai"]


@router.get("/api/groups/{gid}/usage")
def list_usage(gid: str, user=Depends(current_user)):
    """One usage record per successfully transcribed audio (recording + language) in the group."""
    require_role(user, gid, [ADMIN])
    return [u for u in repo.list("usage") if u["group_id"] == gid]
