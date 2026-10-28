"""Login and information about the logged-in user."""

from fastapi import APIRouter, Depends

from ..helpers import fail
from ..repository import membership_key, repo
from ..schemas import LoginRequest
from ..security import ADMIN, create_token, current_user, password_hasher, public_user

router = APIRouter()


def find_user_by_email(email):
    """Return the user with this email (case-insensitive), or None."""
    email = email.lower()
    return next((u for u in repo.list("users") if u["email"] == email), None)


@router.post("/api/auth/login")
def login(data: LoginRequest):
    """Exchange email + password for a login token."""
    user = find_user_by_email(data.email)
    # Same error for every failure, so attackers can't tell which part was wrong.
    if (
        not user
        or not password_hasher.verify(data.password, user["password_hash"])
        or not user.get("enabled", True)
    ):
        fail(401, "Invalid credentials")
    return {"access_token": create_token(user), "token_type": "bearer", "user": public_user(user)}


@router.get("/api/me")
def me(user=Depends(current_user)):
    """The logged-in user's own profile."""
    return public_user(user)


@router.get("/api/me/groups")
def my_groups(user=Depends(current_user)):
    """Groups the logged-in user can see: all of them for a system admin,
    otherwise those where they have an enabled membership.

    Each group gets an extra "my_role" field with the user's role in it
    (system admins count as "admin" everywhere)."""
    if user.get("system_admin"):
        return [{**group, "my_role": ADMIN} for group in repo.list("groups")]

    visible = []
    for group in repo.list("groups"):
        membership = repo.get("memberships", membership_key(group["id"], user["id"]))
        if membership and membership.get("enabled", True):
            visible.append({**group, "my_role": membership["role"]})
    return visible
