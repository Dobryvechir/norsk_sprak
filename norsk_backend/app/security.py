"""
Authentication (who are you?) and authorisation (what may you do?).

Authentication:
    - Passwords are hashed with Argon2 via `password_hasher`.
    - After logging in, a client receives a JWT token valid for 7 days and
      sends it on every request as `Authorization: Bearer <token>`.
    - `current_user` is a FastAPI dependency that turns that header into the
      logged-in user's dict (or rejects the request with 401).

Authorisation - there are two levels of permission:
    - System admin: a flag on the user. Can do everything, in every group.
    - Group role: per group, via a membership. One of ROLES below.

See docs/permissions-and-quotas.md for the full permission table.
"""

import datetime

import jwt
from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pwdlib import PasswordHash

from .config import settings
from .helpers import fail
from .repository import membership_key, repo

# Group roles, from least to most powerful:
#   viewer   - can list/read recordings and play audio
#   uploader - viewer + upload, edit sentences, start transcription
#   admin    - uploader + manage members, AI config, usage, delete recordings
VIEWER, UPLOADER, ADMIN = "viewer", "uploader", "admin"
ROLES = (VIEWER, UPLOADER, ADMIN)

TOKEN_LIFETIME = datetime.timedelta(days=7)
TOKEN_ALGORITHM = "HS256"

password_hasher = PasswordHash.recommended()  # Argon2
_bearer_scheme = HTTPBearer()  # reads the "Authorization: Bearer ..." header


# --- Tokens -----------------------------------------------------------------

def create_token(user) -> str:
    """Create a signed login token for `user`, valid for TOKEN_LIFETIME."""
    expires = datetime.datetime.now(datetime.timezone.utc) + TOKEN_LIFETIME
    payload = {"sub": user["id"], "exp": expires}
    return jwt.encode(payload, settings.app_secret, algorithm=TOKEN_ALGORITHM)


def current_user(auth: HTTPAuthorizationCredentials = Depends(_bearer_scheme)):
    """FastAPI dependency: return the logged-in user, or fail with 401.

    Use in an endpoint as `user=Depends(current_user)`.
    """
    try:
        claims = jwt.decode(auth.credentials, settings.app_secret, algorithms=[TOKEN_ALGORITHM])
        user_id = claims["sub"]
    except Exception:  # bad signature, expired, malformed, missing "sub", ...
        fail(401, "Invalid token")

    user = repo.get("users", user_id)
    # A token stays valid for 7 days, so also re-check the user still exists
    # and hasn't been disabled since it was issued.
    if not user or not user.get("enabled", True):
        fail(401, "Invalid user")
    return user


def public_user(user) -> dict:
    """The user fields that are safe to send to clients (no password hash)."""
    return {k: user[k] for k in ("id", "email", "system_admin", "enabled") if k in user}


# --- Permission checks --------------------------------------------------------
# Each of these either returns normally or stops the request with an error.

def require_system_admin(user):
    """Fail with 403 unless `user` is a system admin."""
    if not user.get("system_admin"):
        fail()


def get_membership(user, group_id) -> dict:
    """Return the user's membership in the group, or fail.

    - 404 if the group doesn't exist.
    - 403 if the user isn't an (enabled) member.
    System admins are treated as an admin member of every group.
    """
    if not repo.get("groups", group_id):
        fail(404, "Group not found")
    if user.get("system_admin"):
        # Synthetic membership: full rights, no quota limits.
        return {"role": ADMIN, "enabled": True, "quota": {}}
    membership = repo.get("memberships", membership_key(group_id, user["id"]))
    if not membership or not membership.get("enabled", True):
        fail(403, "Not a group member")
    return membership


def require_role(user, group_id, allowed_roles) -> dict:
    """Like get_membership, but also fail with 403 if the user's role isn't
    one of `allowed_roles`. Returns the membership."""
    membership = get_membership(user, group_id)
    if membership["role"] not in allowed_roles:
        fail()
    return membership
