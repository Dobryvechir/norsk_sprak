"""After signup: choosing a plan, paying for Pro, and verifying the email address.

    GET  /app/plan/                          - public: "Choose plan: Basic (free) / Pro"
    GET  /app/shop/                          - public: pay for Pro with Apple Pay / Google Pay (Stripe) or Vipps
    GET  /app/verify/?token=...              - public: confirms the email address (link in the email)
    GET  /app/upgrade/?u=...&t=...           - public: a Basic user's "Change to Pro plan" page (link from the app)
    GET  /app/terms_of_sale, /app/privacy_policy - public: terms of sale and privacy policy
    GET  /app/norsk-audio                     - public: Norsk Audio's features (linked from the main site)
    GET  /app/plan/pro-info.js               - script that shows what Pro gives (used by /app/plan/ and /app/upgrade/)
    GET  /api/plan/pro-info              - public: Pro prices and the Advanced group's limits
    POST /api/me/upgrade-link            - logged-in Basic user: the /app/upgrade/ link for the browser
    GET  /api/plan/state                 - the candidate's (or upgrading user's) plan / payment state
    POST /api/plan                       - choose "basic" or "pro"
    GET  /api/shop/config                - prices and payment-method settings for /app/shop/
    POST /api/shop/stripe/start          - Apple Pay / Google Pay: create the Stripe PaymentIntent
    POST /api/shop/stripe/status         - after stripe.confirmPayment: check the PaymentIntent
    POST /api/shop/stripe/webhook        - Stripe webhook (signed)
    POST /api/shop/vipps/start           - start a Vipps payment (returns the Vipps URL)
    POST /api/shop/vipps/status          - after returning from Vipps: check / capture the payment
    POST /api/shop/vipps/webhook         - Vipps webhook (HMAC-signed)
    POST /api/verify                     - confirm an email address with the token from the email
    GET  /.well-known/apple-developer-merchantid-domain-association

All extra information lives on the candidate's record in "candidate_users":
    plan               "basic" | "pro" (missing until chosen)
    payment            {"status": "processing" | "paid" | "failed",
                        "method": "vipps" | "applepay" | "googlepay" | "card" | "stripe" (not yet known),
                        "provider": "vipps" | "stripe", "currency", "amount", "reference",
                        "intent_id" (Stripe), "transaction_id", "paid_at"}
    email_verified     bool, email_verified_at
    verify_token_hash  SHA-256 of the emailed token, verify_sent_at

Basic: the verification email is sent and the candidate waits for a system
admin, whose approval dialog suggests the "Basic" group. Pro: once paid, the
candidate becomes a user at once (no approval) and joins the "Advanced" group;
then the verification email is sent. Both groups are created at startup.

The plan token is an HMAC of the candidate id (see signup.plan_token), handed
out by POST /api/signup and carried in the /app/plan/ and /app/shop/ URLs.

Upgrading: a user in a group with privilege 0 ("Basic") gets a "Change to Pro plan"
entry in the app, which opens /app/upgrade/?u=<user id>&t=<upgrade token> in the browser
(the token is an HMAC of the user id and an expiry time, valid UPGRADE_LINK_TTL). The
shop then works for that user (`u` instead of `c`); the payment is kept on the user's
record, and once paid the user leaves the privilege-0 groups and joins "Advanced".
No new user is created.
"""

import datetime
import hashlib
import hmac
import logging
import secrets
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, Request
from fastapi.responses import FileResponse, RedirectResponse

from .. import mailer
from ..chat import GROUP_CHAT_DEFAULTS, group_chat_settings
from ..config import settings
from ..helpers import fail, new_id, utc_now_iso
from ..payments import PRO_PRICES, PaymentError, stripe_api, vipps
from ..repository import membership_key, repo
from ..schemas import CandidateRef, ChoosePlanRequest, StartPaymentRequest, VerifyEmailRequest
from ..security import current_user
from .admin import DEFAULT_AI_CONFIG
from .signup import KIND, checksum_key, plan_token

log = logging.getLogger("norsk.plans")
router = APIRouter()

BASIC, PRO = "basic", "pro"
# The group each plan's users go into.
PLAN_GROUPS = {BASIC: "Basic", PRO: "Advanced"}
# The "privilege" of each plan group when it is created.
PLAN_PRIVILEGES = {BASIC: 0, PRO: 1}
# "privilege" of groups created before the field existed, and of admin-made groups.
DEFAULT_PRIVILEGE = 7
PAID_ROLE = "viewer"  # role in the Advanced group after paying
VERIFY_TTL = datetime.timedelta(days=7)
RESEND_AFTER_SECONDS = 60
# Providers whose unfinished payment may be replaced by a new attempt (the payer
# may close the Vipps page or the Apple Pay / Google Pay sheet and try again).
RESTARTABLE = ("vipps", "stripe")
USERS = "users"
# How long the "Change to Pro plan" link from the app works.
UPGRADE_LINK_TTL = datetime.timedelta(days=1)

# Whose payment: (KIND, candidate id) for a new sign-up, (USERS, user id) for an upgrade.
Payer = tuple[str, str]

STATIC = Path(__file__).resolve().parent.parent / "static"


# --- Groups ---

def plan_group_id(plan: str) -> str:
    """Id of the group for this plan ("Basic" / "Advanced"), created if missing."""
    name = PLAN_GROUPS[plan]
    with repo.lock:
        group = next((g for g in repo.list("groups") if g["name"].lower() == name.lower()), None)
        if not group:
            group = {"id": new_id(), "name": name, "ai": dict(DEFAULT_AI_CONFIG),
                     "created_at": utc_now_iso(), "privilege": PLAN_PRIVILEGES[plan],
                     **GROUP_CHAT_DEFAULTS}
            repo.put("groups", group["id"], group)
        return group["id"]


def ensure_group_privileges():
    """Give every group without a "privilege" field the value DEFAULT_PRIVILEGE (startup)."""
    with repo.lock:
        for group in repo.list("groups"):
            if not isinstance(group.get("privilege"), int):
                group["privilege"] = DEFAULT_PRIVILEGE
                repo.put("groups", group["id"], group)


def ensure_plan_groups():
    """Create the Basic and Advanced groups at startup (if they don't exist yet)."""
    for plan in PLAN_GROUPS:
        plan_group_id(plan)


def basic_group_ids() -> set[str]:
    """Groups whose members may buy Pro (privilege 0, normally just "Basic")."""
    return {g["id"] for g in repo.list("groups") if g.get("privilege") == 0}


def upgradable(user: dict | None) -> bool:
    """Whether this user may change to the Pro plan: an enabled, ordinary user in a
    privilege-0 group."""
    if not user or not user.get("enabled", True) or user.get("system_admin"):
        return False
    return any(repo.get("memberships", membership_key(gid, user["id"])) for gid in basic_group_ids())


def pro_info() -> dict:
    """What the Pro plan gives: prices and the Advanced group's limits."""
    group = repo.get("groups", plan_group_id(PRO)) or {}
    return {"prices": PRO_PRICES, "limits": group_chat_settings(group),
            "aiMonthlyMinutes": (group.get("ai") or {}).get("monthly_audio_minutes_limit")}


# --- Helpers ---

def base_url(request: Request) -> str:
    url = settings.public_base_url or str(request.base_url)
    return url if url.endswith("/") else url + "/"


def user_from_candidate(cid: str) -> dict | None:
    """The user a candidate became (after paying or being approved), if any."""
    return next((u for u in repo.list("users") if u.get("candidate_id") == cid), None)


def upgrade_token(uid: str, expires: int | None = None) -> str:
    """"<expiry>.<HMAC>": proof that the link was made for user `uid` (valid until `expires`)."""
    if expires is None:
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        expires = int(now + UPGRADE_LINK_TTL.total_seconds())
    mac = hmac.new(checksum_key(), f"upgrade:{uid}:{expires}".encode(), hashlib.sha256).hexdigest()
    return f"{expires}.{mac}"


def check_payer(ref: CandidateRef | None = None, c: str = "", u: str = "", t: str = "") -> Payer:
    """The candidate (`c`) or upgrading user (`u`) the token `t` belongs to; 403 otherwise."""
    if ref:
        c, u, t = ref.candidateId, ref.userId, ref.token
    if u and not c:
        expires = t.partition(".")[0]
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        if (not expires.isdigit() or int(expires) < now
                or not hmac.compare_digest(t, upgrade_token(u, int(expires)))):
            fail(403, "Invalid or expired link")
        return USERS, u
    if c and not u:
        return KIND, check_token(cid=c, token=t)
    fail(403, "Invalid link")


def payer_query(payer: Payer, token: str) -> str:
    """The /app/upgrade/ and /app/shop/ URL parameters for this payer."""
    return f"{'c' if payer[0] == KIND else 'u'}={payer[1]}&t={token}"


def check_token(ref: CandidateRef | None = None, cid: str = "", token: str = "") -> str:
    cid, token = (ref.candidateId, ref.token) if ref else (cid, token)
    if not hmac.compare_digest(token, plan_token(cid)):
        fail(403, "Invalid link")
    return cid


def pending_candidate(cid: str) -> dict:
    candidate = repo.get(KIND, cid)
    if not candidate:
        fail(409, "Already registered") if user_from_candidate(cid) else fail(404, "Candidate not found")
    return candidate


def payable(payer: Payer) -> dict:
    """The record that may pay now: a candidate still waiting, or a user who may upgrade."""
    kind, pid = payer
    if kind == KIND:
        return pending_candidate(pid)
    user = repo.get(USERS, pid)
    if not user:
        fail(404, "User not found")
    if not upgradable(user):
        fail(409, "Already on the Pro plan")
    return user


def state(payer: Payer) -> dict:
    """What /app/plan/, /app/upgrade/ and /app/shop/ show: plan, payment and verification state."""
    kind, pid = payer
    record = repo.get(kind, pid) or (user_from_candidate(pid) if kind == KIND else None)
    if not record:
        fail(404, "Not found")
    payment = record.get("payment") or {}
    can_upgrade = kind == USERS and upgradable(record)
    return {
        "email": record["email"],
        "plan": record.get("plan"),
        # For an upgrade, a payment from earlier (e.g. at sign-up) doesn't count while still Basic.
        "paid": payment.get("status") == "paid" and not can_upgrade,
        "payment": {k: payment.get(k) for k in ("status", "method", "currency", "amount")} if payment else None,
        "emailVerified": bool(record.get("email_verified")),
        "approved": kind == USERS or record.get("candidate_id") == pid,  # already a user
        "upgrade": kind == USERS,
        "upgradable": can_upgrade,
        "prices": PRO_PRICES,
    }


def prepare_verification(record: dict, request: Request, background: BackgroundTasks, force=False):
    """Give `record` a fresh verification token and email the link (in the background).
    Skipped when already verified, or when a link was sent less than a minute ago."""
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    if record.get("email_verified") or (not force and now - record.get("verify_sent_at", 0) < RESEND_AFTER_SECONDS):
        return
    token = secrets.token_urlsafe(32)
    record["verify_token_hash"] = hashlib.sha256(token.encode()).hexdigest()
    record["verify_sent_at"] = now
    link = f"{base_url(request)}app/verify/?token={token}"
    text = (f"Hello,\n\nThank you for registering at Norsk Audio.\n"
            f"Please confirm your email address by opening this link:\n\n{link}\n\n"
            f"The link is valid for {VERIFY_TTL.days} days. If you did not sign up, ignore this email.\n")
    html = (f"<p>Hello,</p><p>Thank you for registering at Norsk Audio.</p>"
            f"<p><a href=\"{link}\">Confirm your email address</a></p>"
            f"<p>The link is valid for {VERIFY_TTL.days} days. If you did not sign up, ignore this email.</p>")
    background.add_task(mailer.send_quietly, record["email"], "Confirm your email – Norsk Audio", text, html)


def complete_payment(payer: Payer, payment: dict, request: Request, background: BackgroundTasks) -> dict:
    """The Pro payment succeeded: a candidate becomes a user, a Basic user moves to Advanced."""
    kind, pid = payer
    if kind == USERS:
        return upgrade_user(pid, payment)
    return complete_candidate(pid, payment, request, background)


def upgrade_user(uid: str, payment: dict) -> dict | None:
    """Mark the user's Pro payment as paid and move them from the privilege-0 group(s)
    to "Advanced": the same user, password and data, no new account.

    Idempotent: only a payment still "processing" is completed (webhook + return page)."""
    advanced = plan_group_id(PRO)
    with repo.lock:
        user = repo.get(USERS, uid)
        current = (user or {}).get("payment") or {}
        if not user or current.get("status") != "processing":
            return user
        user.update(plan=PRO, payment={**current, **payment, "status": "paid", "paid_at": utc_now_iso()})
        repo.put(USERS, uid, user)
        for gid in basic_group_ids() - {advanced}:
            repo.delete("memberships", membership_key(gid, uid))
        key = membership_key(advanced, uid)
        membership = repo.get("memberships", key) or {
            "group_id": advanced, "user_id": uid, "role": PAID_ROLE, "quota": {}}
        repo.put("memberships", key, {**membership, "enabled": True})
    log.info("User %s paid with %s and moved to the Advanced group", uid, payment.get("method"))
    return user


def complete_candidate(cid: str, payment: dict, request: Request, background: BackgroundTasks) -> dict:
    """Mark the Pro payment as paid and turn the candidate into a user in the Advanced group.

    Idempotent: a second call (webhook + return page) finds the user already created.
    """
    group_id = plan_group_id(PRO)
    with repo.lock:
        candidate = repo.get(KIND, cid)
        if not candidate:
            return user_from_candidate(cid) or fail(404, "Candidate not found")
        paid = {**(candidate.get("payment") or {}), **payment, "status": "paid", "paid_at": utc_now_iso()}
        user = {
            "id": new_id(),
            "email": candidate["email"],
            "password_hash": candidate["password_hash"],
            "system_admin": False,
            "enabled": True,
            "plan": PRO,
            "payment": paid,
            "candidate_id": cid,
            "email_verified": bool(candidate.get("email_verified")),
        }
        for key in ("email_verified_at", "verify_token_hash", "verify_sent_at"):
            if key in candidate:
                user[key] = candidate[key]
        prepare_verification(user, request, background, force=True)
        if any(u["email"] == user["email"] for u in repo.list("users")):
            # Someone created this email by hand meanwhile: keep the payment on the candidate.
            repo.put(KIND, cid, {**candidate, "plan": PRO, "payment": paid})
            log.error("Paid candidate %s has an email that already exists as a user", cid)
            return candidate
        repo.put("users", user["id"], user)
        repo.put("memberships", membership_key(group_id, user["id"]), {
            "group_id": group_id, "user_id": user["id"], "role": PAID_ROLE, "enabled": True, "quota": {},
        })
        repo.delete(KIND, cid)
    log.info("Candidate %s paid with %s and became user %s", cid, payment.get("method"), user["id"])
    return user


def check_can_pay(payer: Payer, record: dict):
    """409 unless this candidate may start a Pro payment now. (For a user, payable() already
    checked; an earlier "paid" payment, e.g. from before an admin moved them to Basic, doesn't block.)"""
    if payer[0] == KIND:
        if record.get("plan") != PRO:
            fail(409, "Choose the Pro plan first")
        if (record.get("payment") or {}).get("status") == "paid":
            fail(409, "Already paid")


def begin_payment(payer: Payer, provider: str, currency: str, reference: str, **extra) -> dict:
    """Mark a payment as in progress (the candidate's or upgrading user's current attempt)."""
    with repo.lock:
        record = payable(payer)
        check_can_pay(payer, record)
        current = record.get("payment") or {}
        if current.get("status") == "processing" and current.get("provider") not in RESTARTABLE:
            fail(409, "A payment is already in progress")
        if current.get("status") == "paid":  # a user's earlier payment: keep it
            record["payment_history"] = [*record.get("payment_history", []), current]
        payment = {"status": "processing", "method": provider, "provider": provider, "currency": currency,
                   "amount": PRO_PRICES[currency], "reference": reference, "started_at": utc_now_iso(), **extra}
        repo.put(payer[0], payer[1], {**record, "payment": payment})
        return payment


def payment_failed(payer: Payer, reason: str):
    with repo.lock:
        record = repo.get(*payer)
        if record and (record.get("payment") or {}).get("status") == "processing":
            repo.put(payer[0], payer[1], {**record, "payment": {**record["payment"], "status": "failed",
                                                               "error": reason[:200]}})


# --- Pages ---

def page(name: str):
    return FileResponse(STATIC / name, media_type="text/html", headers={"Cache-Control": "no-store"})


@router.get("/app/plan", include_in_schema=False)
@router.get("/app/shop", include_in_schema=False)
@router.get("/app/verify", include_in_schema=False)
@router.get("/app/upgrade", include_in_schema=False)
def add_slash(request: Request):
    # Relative, so it also works behind a proxy that serves the app under a prefix.
    name = request.url.path.rstrip("/").rsplit("/", 1)[-1]
    query = f"?{request.url.query}" if request.url.query else ""
    return RedirectResponse(f"{name}/{query}")


@router.get("/app/plan/", include_in_schema=False)
def plan_page():
    return page("plan.html")


@router.get("/app/shop/", include_in_schema=False)
def shop_page():
    return page("shop.html")


@router.get("/app/verify/", include_in_schema=False)
def verify_page():
    return page("verify.html")


@router.get("/app/upgrade/", include_in_schema=False)
def upgrade_page():
    return page("upgrade.html")


@router.get("/app/plan/pro-info.js", include_in_schema=False)
def pro_info_script():
    return FileResponse(STATIC / "pro-info.js", media_type="text/javascript",
                        headers={"Cache-Control": "no-cache"})


@router.get("/app/terms_of_sale", include_in_schema=False)
def terms_of_sale_page():
    return page("terms_of_sale.html")


@router.get("/app/privacy_policy", include_in_schema=False)
def privacy_policy_page():
    return page("privacy_policy.html")


@router.get("/app/norsk-audio", include_in_schema=False)
def norsk_audio_page():
    """What Norsk Audio does (linked from the main Movna Hatka site)."""
    return page("norsk_audio.html")


# Apple checks this exact path at the domain root, so it can't move under /app.
@router.get("/.well-known/apple-developer-merchantid-domain-association", include_in_schema=False)
def apple_domain_association():
    path = settings.apple_pay_domain_association_file
    if not path or not Path(path).is_file():
        fail(404, "Not found")
    return FileResponse(path, media_type="text/plain")


# --- Plan ---

@router.get("/api/plan/state")
def plan_state(t: str, c: str = "", u: str = ""):
    return state(check_payer(c=c, u=u, t=t))


@router.get("/api/plan/pro-info")
def plan_pro_info():
    """Public: Pro prices and the limits of the "Advanced" group (shown on /app/plan/ and /app/upgrade/)."""
    return pro_info()


@router.post("/api/me/upgrade-link")
def upgrade_link(request: Request, user=Depends(current_user)):
    """For a user in a privilege-0 ("Basic") group: the /app/upgrade/ link to open in the browser."""
    if not upgradable(user):
        fail(409, "Only Basic users can change to the Pro plan")
    payer = (USERS, user["id"])
    return {"url": f"{base_url(request)}app/upgrade/?{payer_query(payer, upgrade_token(user['id']))}"}


@router.post("/api/plan")
def choose_plan(data: ChoosePlanRequest, request: Request, background: BackgroundTasks):
    """Basic: send the verification email and wait for an admin. Pro: continue to /app/shop/."""
    cid = check_token(data)
    with repo.lock:
        candidate = pending_candidate(cid)
        if (candidate.get("payment") or {}).get("status") in ("paid", "processing") and data.plan != PRO:
            fail(409, "A payment has already been made")
        candidate["plan"] = data.plan
        if data.plan == BASIC:
            prepare_verification(candidate, request, background)
        repo.put(KIND, cid, candidate)
    return {"next": "shop" if data.plan == PRO else "done", **state((KIND, cid))}


# --- Shop ---

@router.get("/api/shop/config")
def shop_config(t: str, c: str = "", u: str = ""):
    check_payer(c=c, u=u, t=t)
    return {
        "prices": PRO_PRICES,
        "vipps": {"enabled": vipps.configured(), "currencies": list(vipps.CURRENCIES)},
        # Apple Pay and Google Pay, both through Stripe's Express Checkout Element.
        "stripe": {"enabled": stripe_api.configured(), "publishableKey": settings.stripe_publishable_key},
    }


@router.post("/api/shop/stripe/start")
def stripe_start(data: StartPaymentRequest):
    """Create the PaymentIntent for the Apple Pay / Google Pay payment the payer just approved.

    An unfinished intent for the same currency is reused (pressing the button again after
    closing the sheet or a declined card),     so one payer has at most one live intent."""
    payer = check_payer(data)
    record = payable(payer)
    current = record.get("payment") or {}
    # Checked before anything is created at Stripe (begin_payment checks again under the lock).
    check_can_pay(payer, record)
    if (current.get("provider") == "stripe" and current.get("status") == "processing"
            and current.get("currency") == data.currency and current.get("intent_id")):
        try:
            intent = stripe_api.get_payment_intent(current["intent_id"])
            if intent["status"] in ("requires_payment_method", "requires_confirmation", "requires_action"):
                return {"clientSecret": intent["client_secret"]}
        except PaymentError as e:
            log.warning("Stripe intent %s not reusable: %s", current["intent_id"], e)
    reference = "norsk-" + new_id()
    try:
        metadata = {"candidate_id" if payer[0] == KIND else "user_id": payer[1]}
        intent = stripe_api.create_payment_intent(reference, PRO_PRICES[data.currency], data.currency, metadata,
                                                  "Norsk Audio – Pro")
    except PaymentError as e:
        fail(502, str(e))
    begin_payment(payer, "stripe", data.currency, reference, intent_id=intent["id"])
    return {"clientSecret": intent["client_secret"]}


def sync_stripe(payer: Payer, request: Request, background: BackgroundTasks):
    """Ask Stripe about the payer's PaymentIntent; complete the plan once it succeeded."""
    record = repo.get(*payer)
    payment = (record or {}).get("payment") or {}
    if not record or payment.get("provider") != "stripe" or payment.get("status") != "processing":
        return
    try:
        intent = stripe_api.get_payment_intent(payment["intent_id"])
    except PaymentError as e:
        log.warning("Stripe check for %s failed: %s", payer, e)
        return
    if intent["status"] == "succeeded":
        if intent["amount_received"] < payment["amount"] or intent["currency"] != payment["currency"].lower():
            log.error("Stripe intent %s paid %s %s, expected %s %s", intent["id"], intent["amount_received"],
                      intent["currency"], payment["amount"], payment["currency"])
            return
        complete_payment(payer, {"method": stripe_api.wallet_of(intent), "transaction_id": intent["id"]},
                         request, background)
    elif intent["status"] == "canceled":
        payment_failed(payer, "Stripe: canceled")
    # requires_payment_method after a decline: the payer may try again, so it stays "processing".


@router.post("/api/shop/stripe/status")
def stripe_status(data: CandidateRef, request: Request, background: BackgroundTasks):
    payer = check_payer(data)
    sync_stripe(payer, request, background)
    return state(payer)


@router.post("/api/shop/stripe/webhook", include_in_schema=False)
async def stripe_webhook(request: Request, background: BackgroundTasks):
    """payment_intent.succeeded / .payment_failed / .canceled: re-read the intent from Stripe."""
    body = await request.body()
    if not stripe_api.verify_webhook(body, request.headers.get("stripe-signature", "")):
        fail(400, "Invalid signature")
    event = await request.json()
    intent = (event.get("data") or {}).get("object") or {}
    if event.get("type", "").startswith("payment_intent.") and intent.get("id"):
        metadata = intent.get("metadata") or {}
        payer = ((KIND, metadata["candidate_id"]) if metadata.get("candidate_id")
                 else (USERS, metadata["user_id"]) if metadata.get("user_id") else None)
        payment = ((repo.get(*payer) if payer else None) or {}).get("payment") or {}
        if payment.get("intent_id") == intent["id"]:
            sync_stripe(payer, request, background)  # never trust the body: ask Stripe
    return {"received": True}


@router.post("/api/shop/vipps/start")
def vipps_start(data: StartPaymentRequest, request: Request):
    payer = check_payer(data)
    if data.currency not in vipps.CURRENCIES:
        fail(422, "Vipps does not support this currency")
    payment = begin_payment(payer, "vipps", data.currency, vipps.new_reference())
    return_url = f"{base_url(request)}app/shop/?{payer_query(payer, data.token)}&vipps=1"
    try:
        url = vipps.create_payment(payment["reference"], payment["amount"], data.currency, return_url,
                                   "Norsk Audio – Pro")
    except PaymentError as e:
        payment_failed(payer, str(e))
        fail(502, str(e))
    return {"redirectUrl": url}


def sync_vipps(payer: Payer, request: Request, background: BackgroundTasks):
    """Ask Vipps about the payer's payment; capture and complete it once authorized."""
    record = repo.get(*payer)
    payment = (record or {}).get("payment") or {}
    if not record or payment.get("provider") != "vipps" or payment.get("status") != "processing":
        return
    try:
        info = vipps.get_payment(payment["reference"])
        if info["state"] == "AUTHORIZED":
            captured = info.get("aggregate", {}).get("capturedAmount", {}).get("value", 0)
            if captured < payment["amount"]:
                vipps.capture(payment["reference"], payment["amount"], payment["currency"])
            complete_payment(payer, {"transaction_id": info.get("pspReference", payment["reference"])},
                             request, background)
        elif info["state"] in ("ABORTED", "EXPIRED", "TERMINATED"):
            payment_failed(payer, f"Vipps: {info['state'].lower()}")
    except PaymentError as e:
        log.warning("Vipps check for %s failed: %s", payer, e)


@router.post("/api/shop/vipps/status")
def vipps_status(data: CandidateRef, request: Request, background: BackgroundTasks):
    payer = check_payer(data)
    sync_vipps(payer, request, background)
    return state(payer)


@router.post("/api/shop/vipps/webhook", include_in_schema=False)
async def vipps_webhook(request: Request, background: BackgroundTasks):
    body = await request.body()
    path = request.url.path + (f"?{request.url.query}" if request.url.query else "")
    if not vipps.verify_webhook("POST", path, request.headers.get("host", ""), request.headers, body):
        fail(401, "Invalid signature")
    reference = (await request.json()).get("reference")
    payer = next(((kind, r["id"]) for kind in (KIND, USERS) for r in repo.list(kind)
                  if reference and (r.get("payment") or {}).get("reference") == reference), None)
    if payer:
        sync_vipps(payer, request, background)  # never trust the body: ask Vipps for the state
    return {"ok": True}


# --- Email verification ---

@router.post("/api/verify")
def verify_email(data: VerifyEmailRequest):
    """Confirm the email address of a candidate (or of the user it became)."""
    token_hash = hashlib.sha256(data.token.encode()).hexdigest()
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    with repo.lock:
        for kind in (KIND, "users"):
            for record in repo.list(kind):
                if hmac.compare_digest(record.get("verify_token_hash", ""), token_hash):
                    if now - record.get("verify_sent_at", 0) > VERIFY_TTL.total_seconds():
                        fail(410, "The link has expired")
                    record.update(email_verified=True, email_verified_at=utc_now_iso())
                    record.pop("verify_token_hash", None)
                    repo.put(kind, record["id"], record)
                    return {"email": record["email"], "emailVerified": True,
                            "approved": kind == "users"}
    fail(404, "Invalid or already used link")
