"""System-admin endpoints: creating users and groups."""

from fastapi import APIRouter, Depends

from ..helpers import fail, new_id, utc_now_iso
from ..repository import repo
from ..schemas import CreateGroupRequest, CreateUserRequest
from ..security import current_user, password_hasher, public_user, require_system_admin
from .auth import find_user_by_email

router = APIRouter()

# AI settings every new group starts with (change later via PATCH .../ai-config).
DEFAULT_AI_CONFIG = {"provider": "openai", "model": "whisper-1", "monthly_audio_minutes_limit": None}


def new_user(email, password, system_admin=False) -> dict:
    """Build a user record (not yet saved). Emails are stored lower-case."""
    return {
        "id": new_id(),
        "email": email.lower(),
        "password_hash": password_hasher.hash(password),
        "system_admin": system_admin,
        "enabled": True,
    }


@router.post("/api/admin/users")
def create_user(data: CreateUserRequest, user=Depends(current_user)):
    """Create a normal (non-admin) user account."""
    require_system_admin(user)
    if find_user_by_email(data.email):
        fail(409, "Email already exists")

    created = new_user(data.email, data.password)
    repo.put("users", created["id"], created)
    return public_user(created)


@router.post("/api/admin/groups")
def create_group(data: CreateGroupRequest, user=Depends(current_user)):
    """Create a new, empty group."""
    require_system_admin(user)
    group = {
        "id": new_id(),
        "name": data.name,
        "ai": dict(DEFAULT_AI_CONFIG),
        "created_at": utc_now_iso(),
    }
    repo.put("groups", group["id"], group)
    return group
