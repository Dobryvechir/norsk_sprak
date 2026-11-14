"""Self-registration: anyone may ask for an account, a system admin decides.

    GET  /app/signup                                   - public: HTML form that calls the two APIs below
    POST /api/captcha                              - public: "I am not a robot" proof-of-work challenge
    POST /api/checksum                             - public: checksum the form must send to /api/signup
    POST /api/signup                               - public: store a candidate user
    GET  /api/admin/candidates                     - sysadmin: review candidates
    POST /api/admin/candidates/{cid}/approve       - sysadmin: create the real user
    POST /api/admin/candidates/{cid}/reject        - sysadmin: refuse the request

Candidates live in the "candidate_users" kind until an admin decides; approving
or rejecting removes the record. After signing up the page continues to /app/plan/
(see routes/plans.py: plan choice, payment and email verification, all stored
on the candidate record; a paid Pro candidate becomes a user without approval). The password is stored only as an Argon2 hash;
on approval that hash is copied to the new user, so the person logs in with the
password they chose at signup.

Checksum: an HMAC-SHA256, keyed with the secret in <data_dir>/key/key.txt
(created with a random key on first use), over the form fields plus the
caller's IP address and short browser string. /api/signup recalculates it and
rejects the request when it differs, so a signup must come from the same IP and
browser that asked for the checksum, with exactly the same fields.

"I am not a robot": POST /api/captcha returns a random `challenge`, a
`difficulty` and a signed `token` (bound to IP + browser, with the time it was
issued). When the visitor presses the button, the page searches for a number
`solution` such that SHA-256("<challenge>:<solution>") starts with `difficulty`
zero bits (about 2**difficulty hashes, a second or two in a browser).
/api/signup then checks that the token is genuine, comes from the same IP and
browser, is at least CAPTCHA_MIN_SECONDS old (a person needs time to fill in
the form) and at most CAPTCHA_MAX_SECONDS, has not been used before, and that
the solution is correct. A hidden "website" field (a honeypot humans never see)
must stay empty. Every failure gives the same 400, so a bot can't tell which
check it failed.
"""

import hashlib
import hmac
import ipaddress
import json
import re
import secrets
import threading
import time
from pathlib import Path

from fastapi import APIRouter, Depends, Request
from fastapi.responses import FileResponse

from ..config import settings
from ..helpers import fail, new_id, utc_now_iso
from ..repository import membership_key, repo
from ..schemas import ApproveCandidateRequest, SignupFields, SignupRequest
from ..security import ROLES, current_user, password_hasher, public_user, require_system_admin
from .auth import find_user_by_email

router = APIRouter()

KIND = "candidate_users"
PENDING = "pending"
# candidate_users may hold at most this many records with the same IP address.
LIMIT_SAME_API = 50
# ...and at most this many created on the same (UTC) date with the same IP address.
LIMIT_IP_PER_DAY = 5

CAPTCHA_DIFFICULTY = 16      # leading zero bits of the proof-of-work hash
CAPTCHA_MIN_SECONDS = 3      # a signup sooner than this after the challenge is a bot
CAPTCHA_MAX_SECONDS = 15 * 60
# Challenges already used (challenge -> expiry time). In memory: one API process.
_used_challenges: dict[str, float] = {}

SIGNUP_PAGE = Path(__file__).resolve().parent.parent / "static" / "signup.html"
_key_lock = threading.Lock()


def checksum_key() -> bytes:
    """The secret from <data_dir>/key/key.txt, creating folder and a random key if missing."""
    path = Path(settings.data_dir) / "key" / "key.txt"
    with _key_lock:
        if not path.is_file():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(secrets.token_hex(32), encoding="utf-8")
        return path.read_text(encoding="utf-8").strip().encode()


def client_ip(request: Request) -> str:
    """The caller's IP address.

    The server normally runs on 127.0.0.1 behind a reverse proxy, so when the
    direct peer is local/private the proxy's X-Real-IP / X-Forwarded-For header
    is trusted (the last X-Forwarded-For entry is the one the proxy added).
    A public peer's headers are ignored, since it could forge them.
    """
    peer = request.client.host if request.client else ""
    try:
        trusted = ipaddress.ip_address(peer).is_private or ipaddress.ip_address(peer).is_loopback
    except ValueError:
        trusted = False
    if trusted:
        forwarded = request.headers.get("x-real-ip") or request.headers.get("x-forwarded-for", "").split(",")[-1]
        if forwarded.strip():
            return forwarded.strip()[:64]
    return peer[:64]


_BROWSERS = (("Edg", "Edge"), ("OPR", "Opera"), ("SamsungBrowser", "Samsung Internet"),
             ("Firefox", "Firefox"), ("CriOS", "Chrome"), ("Chrome", "Chrome"),
             ("FxiOS", "Firefox"), ("Version", "Safari"), ("Dart", "Dart"))
_SYSTEMS = (("Windows", "Windows"), ("Android", "Android"), ("iPhone", "iOS"), ("iPad", "iOS"),
            ("Mac OS X", "macOS"), ("CrOS", "ChromeOS"), ("Linux", "Linux"))


def short_browser(user_agent: str) -> str:
    """A short description like 'Chrome 131 / Windows' from a User-Agent header."""
    browser = next((f"{name} {m.group(1)}" for token, name in _BROWSERS
                    if (m := re.search(re.escape(token) + r"/(\d+)", user_agent))), "")
    system = next((name for token, name in _SYSTEMS if token in user_agent), "")
    short = " / ".join(x for x in (browser, system) if x)
    return short or user_agent[:80] or "unknown"


def normalized(data: SignupFields, request: Request) -> dict:
    """The signup fields as they are stored, plus the caller's IP and browser."""
    return {
        "email": data.email.strip().lower(),
        "password": data.password,
        "info": data.info.strip(),
        "ip": client_ip(request),
        "browser": short_browser(request.headers.get("user-agent", "")),
    }


def calculate_checksum(fields: dict) -> str:
    message = json.dumps(fields, sort_keys=True, ensure_ascii=False).encode()
    return hmac.new(checksum_key(), message, hashlib.sha256).hexdigest()


def _sign(text: str) -> str:
    return hmac.new(checksum_key(), b"captcha:" + text.encode(), hashlib.sha256).hexdigest()


def new_captcha(request: Request) -> dict:
    challenge = secrets.token_hex(16)
    payload = json.dumps({"c": challenge, "d": CAPTCHA_DIFFICULTY, "t": int(time.time()),
                          "ip": client_ip(request), "b": short_browser(request.headers.get("user-agent", ""))},
                         separators=(",", ":"), sort_keys=True)
    token = payload.encode().hex() + "." + _sign(payload)
    return {"challenge": challenge, "difficulty": CAPTCHA_DIFFICULTY, "token": token}


def leading_zero_bits(digest: bytes) -> int:
    bits = 0
    for byte in digest:
        if byte:
            return bits + 8 - byte.bit_length()
        bits += 8
    return bits


def verify_captcha(token: str, solution: int, request: Request, now: float | None = None) -> bool:
    """True when the token is genuine, fresh, unused, from this IP/browser and solved."""
    now = time.time() if now is None else now
    try:
        hex_payload, signature = token.split(".")
        payload = bytes.fromhex(hex_payload).decode()
        if not hmac.compare_digest(signature, _sign(payload)):
            return False
        data = json.loads(payload)
    except (ValueError, UnicodeDecodeError):
        return False
    age = now - data["t"]
    if not CAPTCHA_MIN_SECONDS <= age <= CAPTCHA_MAX_SECONDS:
        return False
    if data["ip"] != client_ip(request) or data["b"] != short_browser(request.headers.get("user-agent", "")):
        return False
    digest = hashlib.sha256(f"{data['c']}:{solution}".encode()).digest()
    if leading_zero_bits(digest) < data["d"]:
        return False
    with _key_lock:
        for c in [c for c, expiry in _used_challenges.items() if expiry < now]:
            del _used_challenges[c]
        if data["c"] in _used_challenges:
            return False
        _used_challenges[data["c"]] = data["t"] + CAPTCHA_MAX_SECONDS
    return True


def plan_token(cid: str) -> str:
    """Proof that the caller is the one who signed up as `cid` (used by /app/plan/ and /app/shop/)."""
    return hmac.new(checksum_key(), b"plan:" + cid.encode(), hashlib.sha256).hexdigest()


# Fields copied from the candidate to the user on approval.
CARRIED_OVER = ("plan", "payment", "email_verified", "email_verified_at", "verify_token_hash", "verify_sent_at")
HIDDEN = ("password_hash", "verify_token_hash")


def public_candidate(candidate, default_group_id: str | None = None) -> dict:
    """Everything an admin may review - all fields except the password and token hashes -
    plus whether the email is verified and the group the approval dialog should suggest."""
    public = {k: v for k, v in candidate.items() if k not in HIDDEN}
    public["email_verified"] = bool(candidate.get("email_verified"))
    if default_group_id:
        public["default_group_id"] = default_group_id
    return public


def take_candidate(cid) -> dict:
    """Return the candidate and remove it from candidate_users (call under repo.lock)."""
    candidate = repo.get(KIND, cid)
    if not candidate:
        fail(404, "Candidate not found")
    repo.delete(KIND, cid)
    return candidate


@router.get("/app/signup", include_in_schema=False)
def signup_page():
    """The sign-up form opened from the app's login screen ("Not registered? Sign up")."""
    return FileResponse(SIGNUP_PAGE, media_type="text/html")


@router.post("/api/captcha")
def captcha(request: Request):
    """A new "I am not a robot" challenge (see the module docstring)."""
    return new_captcha(request)


@router.post("/api/checksum")
def checksum(data: SignupFields, request: Request):
    """The checksum to send as `checksum` with the same fields to POST /api/signup."""
    return {"checksum": calculate_checksum(normalized(data, request))}


@router.post("/api/signup", status_code=201)
def signup(data: SignupRequest, request: Request):
    """Ask for an account. Needs no login; a system admin must approve it."""
    fields = normalized(data, request)
    if not hmac.compare_digest(data.checksum, calculate_checksum(fields)):
        fail(400, "Invalid checksum")
    if data.website or not verify_captcha(data.captchaToken, data.captchaSolution, request):
        fail(400, "Robot check failed")
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", fields["email"]):
        fail(422, "Invalid email")
    with repo.lock:
        candidates = repo.list(KIND)
        if find_user_by_email(fields["email"]) or any(c["email"] == fields["email"] for c in candidates):
            fail(409, "Email already registered")
        same_ip = [c for c in candidates if c.get("ip") == fields["ip"]]
        today = utc_now_iso()[:10]  # 'YYYY-MM-DD', same format as created_at[:10]
        if (len(same_ip) >= LIMIT_SAME_API
                or sum(c["created_at"][:10] == today for c in same_ip) >= LIMIT_IP_PER_DAY):
            fail(429, "Too many signups, try again later")
        candidate = {
            "id": new_id(),
            "email": fields["email"],
            "password_hash": password_hasher.hash(fields["password"]),
            "info": fields["info"],
            "ip": fields["ip"],
            "browser": fields["browser"],
            "created_at": utc_now_iso(),
            "status": PENDING,
        }
        repo.put(KIND, candidate["id"], candidate)
    return {"id": candidate["id"], "status": PENDING, "planToken": plan_token(candidate["id"])}


@router.get("/api/admin/candidates")
def list_candidates(user=Depends(current_user)):
    """Candidates waiting for a decision, newest first."""
    require_system_admin(user)
    from .plans import BASIC, plan_group_id  # plans imports this module
    basic = plan_group_id(BASIC)  # people who did not pay go to "Basic" by default
    candidates = sorted(repo.list(KIND), key=lambda c: c["created_at"], reverse=True)
    return [public_candidate(c, basic) for c in candidates]


@router.post("/api/admin/candidates/{cid}/approve")
def approve_candidate(cid: str, data: ApproveCandidateRequest | None = None, user=Depends(current_user)):
    """Copy the candidate into `users` (removing it from candidate_users) and, if
    `groupId` is given, add the new user to that group with `role`. Returns the public user."""
    require_system_admin(user)
    data = data or ApproveCandidateRequest()
    if data.role not in ROLES:
        fail(422, "Invalid role")
    if data.groupId and not repo.get("groups", data.groupId):
        fail(404, "Group not found")
    with repo.lock:
        candidate = repo.get(KIND, cid)
        if not candidate:
            fail(404, "Candidate not found")
        if find_user_by_email(candidate["email"]):
            fail(409, "Email already exists")
        created = {
            "id": new_id(),
            "email": candidate["email"],
            "password_hash": candidate["password_hash"],
            "system_admin": False,
            "enabled": True,
            "candidate_id": cid,
            **{k: candidate[k] for k in CARRIED_OVER if k in candidate},
        }
        repo.put("users", created["id"], created)
        if data.groupId:
            repo.put("memberships", membership_key(data.groupId, created["id"]), {
                "group_id": data.groupId, "user_id": created["id"], "role": data.role,
                "enabled": True, "quota": {},
            })
        take_candidate(cid)
    return public_user(created)


@router.post("/api/admin/candidates/{cid}/reject")
def reject_candidate(cid: str, user=Depends(current_user)):
    """Refuse the request and remove it from candidate_users."""
    require_system_admin(user)
    with repo.lock:
        candidate = take_candidate(cid)
    return {**public_candidate(candidate), "status": "rejected"}
