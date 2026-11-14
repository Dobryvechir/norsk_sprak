"""After signup: choosing a plan, paying for Pro, and verifying the email address.

    GET  /plan/                          - public: "Choose plan: Basic (free) / Pro"
    GET  /shop/                          - public: pay for Pro with Apple Pay / Google Pay (Stripe) or Vipps
    GET  /verify/?token=...              - public: confirms the email address (link in the email)
    GET  /api/plan/state                 - the candidate's plan / payment / verification state
    POST /api/plan                       - choose "basic" or "pro"
    GET  /api/shop/config                - prices and payment-method settings for /shop/
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
out by POST /api/signup and carried in the /plan/ and /shop/ URLs.
"""

import datetime
import hashlib
import hmac
import logging
import secrets
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Request
from fastapi.responses import FileResponse, RedirectResponse

from .. import mailer
from ..chat import GROUP_CHAT_DEFAULTS
from ..config import settings
from ..helpers import fail, new_id, utc_now_iso
from ..payments import PRO_PRICES, PaymentError, stripe_api, vipps
from ..repository import membership_key, repo
from ..schemas import CandidateRef, ChoosePlanRequest, StartPaymentRequest, VerifyEmailRequest
from .admin import DEFAULT_AI_CONFIG
from .signup import KIND, plan_token

log = logging.getLogger("norsk.plans")
router = APIRouter()

BASIC, PRO = "basic", "pro"
# The group each plan's users go into.
PLAN_GROUPS = {BASIC: "Basic", PRO: "Advanced"}
PAID_ROLE = "viewer"  # role in the Advanced group after paying
VERIFY_TTL = datetime.timedelta(days=7)
RESEND_AFTER_SECONDS = 60
# Providers whose unfinished payment may be replaced by a new attempt (the payer
# may close the Vipps page or the Apple Pay / Google Pay sheet and try again).
RESTARTABLE = ("vipps", "stripe")

STATIC = Path(__file__).resolve().parent.parent / "static"


# --- Groups ---

def plan_group_id(plan: str) -> str:
    """Id of the group for this plan ("Basic" / "Advanced"), created if missing."""
    name = PLAN_GROUPS[plan]
    with repo.lock:
        group = next((g for g in repo.list("groups") if g["name"].lower() == name.lower()), None)
        if not group:
            group = {"id": new_id(), "name": name, "ai": dict(DEFAULT_AI_CONFIG),
                     "created_at": utc_now_iso(), **GROUP_CHAT_DEFAULTS}
            repo.put("groups", group["id"], group)
        return group["id"]


def ensure_plan_groups():
    """Create the Basic and Advanced groups at startup (if they don't exist yet)."""
    for plan in PLAN_GROUPS:
        plan_group_id(plan)


# --- Helpers ---

def base_url(request: Request) -> str:
    url = settings.public_base_url or str(request.base_url)
    return url if url.endswith("/") else url + "/"


def user_from_candidate(cid: str) -> dict | None:
    """The user a candidate became (after paying or being approved), if any."""
    return next((u for u in repo.list("users") if u.get("candidate_id") == cid), None)


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


def state(cid: str) -> dict:
    """What /plan/ and /shop/ show: plan, payment and verification state."""
    record = repo.get(KIND, cid) or user_from_candidate(cid)
    if not record:
        fail(404, "Candidate not found")
    payment = record.get("payment") or {}
    return {
        "email": record["email"],
        "plan": record.get("plan"),
        "paid": payment.get("status") == "paid",
        "payment": {k: payment.get(k) for k in ("status", "method", "currency", "amount")} if payment else None,
        "emailVerified": bool(record.get("email_verified")),
        "approved": record.get("candidate_id") == cid,  # already a user
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
    link = f"{base_url(request)}verify/?token={token}"
    text = (f"Hello,\n\nThank you for registering at Norsk Audio.\n"
            f"Please confirm your email address by opening this link:\n\n{link}\n\n"
            f"The link is valid for {VERIFY_TTL.days} days. If you did not sign up, ignore this email.\n")
    html = (f"<p>Hello,</p><p>Thank you for registering at Norsk Audio.</p>"
            f"<p><a href=\"{link}\">Confirm your email address</a></p>"
            f"<p>The link is valid for {VERIFY_TTL.days} days. If you did not sign up, ignore this email.</p>")
    background.add_task(mailer.send_quietly, record["email"], "Confirm your email – Norsk Audio", text, html)


def complete_payment(cid: str, payment: dict, request: Request, background: BackgroundTasks) -> dict:
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


def begin_payment(cid: str, provider: str, currency: str, reference: str, **extra) -> dict:
    """Mark a payment as in progress (the candidate's current attempt)."""
    with repo.lock:
        candidate = pending_candidate(cid)
        if candidate.get("plan") != PRO:
            fail(409, "Choose the Pro plan first")
        current = candidate.get("payment") or {}
        if current.get("status") == "paid":
            fail(409, "Already paid")
        if current.get("status") == "processing" and current.get("provider") not in RESTARTABLE:
            fail(409, "A payment is already in progress")
        payment = {"status": "processing", "method": provider, "provider": provider, "currency": currency,
                   "amount": PRO_PRICES[currency], "reference": reference, "started_at": utc_now_iso(), **extra}
        repo.put(KIND, cid, {**candidate, "payment": payment})
        return payment


def payment_failed(cid: str, reason: str):
    with repo.lock:
        candidate = repo.get(KIND, cid)
        if candidate and (candidate.get("payment") or {}).get("status") == "processing":
            repo.put(KIND, cid, {**candidate, "payment": {**candidate["payment"], "status": "failed",
                                                          "error": reason[:200]}})


# --- Pages ---

def page(name: str):
    return FileResponse(STATIC / name, media_type="text/html", headers={"Cache-Control": "no-store"})


@router.get("/plan", include_in_schema=False)
@router.get("/shop", include_in_schema=False)
@router.get("/verify", include_in_schema=False)
def add_slash(request: Request):
    # Relative, so it also works behind a proxy that serves the app under a prefix.
    name = request.url.path.rstrip("/").rsplit("/", 1)[-1]
    query = f"?{request.url.query}" if request.url.query else ""
    return RedirectResponse(f"{name}/{query}")


@router.get("/plan/", include_in_schema=False)
def plan_page():
    return page("plan.html")


@router.get("/shop/", include_in_schema=False)
def shop_page():
    return page("shop.html")


@router.get("/verify/", include_in_schema=False)
def verify_page():
    return page("verify.html")


@router.get("/.well-known/apple-developer-merchantid-domain-association", include_in_schema=False)
def apple_domain_association():
    path = settings.apple_pay_domain_association_file
    if not path or not Path(path).is_file():
        fail(404, "Not found")
    return FileResponse(path, media_type="text/plain")


# --- Plan ---

@router.get("/api/plan/state")
def plan_state(c: str, t: str):
    return state(check_token(cid=c, token=t))


@router.post("/api/plan")
def choose_plan(data: ChoosePlanRequest, request: Request, background: BackgroundTasks):
    """Basic: send the verification email and wait for an admin. Pro: continue to /shop/."""
    cid = check_token(data)
    with repo.lock:
        candidate = pending_candidate(cid)
        if (candidate.get("payment") or {}).get("status") in ("paid", "processing") and data.plan != PRO:
            fail(409, "A payment has already been made")
        candidate["plan"] = data.plan
        if data.plan == BASIC:
            prepare_verification(candidate, request, background)
        repo.put(KIND, cid, candidate)
    return {"next": "shop" if data.plan == PRO else "done", **state(cid)}


# --- Shop ---

@router.get("/api/shop/config")
def shop_config(c: str, t: str):
    check_token(cid=c, token=t)
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
    closing the sheet or a declined card), so one candidate has at most one live intent."""
    cid = check_token(data)
    candidate = pending_candidate(cid)
    current = candidate.get("payment") or {}
    # Checked before anything is created at Stripe (begin_payment checks again under the lock).
    if candidate.get("plan") != PRO:
        fail(409, "Choose the Pro plan first")
    if current.get("status") == "paid":
        fail(409, "Already paid")
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
        intent = stripe_api.create_payment_intent(reference, PRO_PRICES[data.currency], data.currency, cid,
                                                  "Norsk Audio – Pro")
    except PaymentError as e:
        fail(502, str(e))
    begin_payment(cid, "stripe", data.currency, reference, intent_id=intent["id"])
    return {"clientSecret": intent["client_secret"]}


def sync_stripe(cid: str, request: Request, background: BackgroundTasks):
    """Ask Stripe about the candidate's PaymentIntent; complete the plan once it succeeded."""
    candidate = repo.get(KIND, cid)
    payment = (candidate or {}).get("payment") or {}
    if not candidate or payment.get("provider") != "stripe" or payment.get("status") != "processing":
        return
    try:
        intent = stripe_api.get_payment_intent(payment["intent_id"])
    except PaymentError as e:
        log.warning("Stripe check for %s failed: %s", cid, e)
        return
    if intent["status"] == "succeeded":
        if intent["amount_received"] < payment["amount"] or intent["currency"] != payment["currency"].lower():
            log.error("Stripe intent %s paid %s %s, expected %s %s", intent["id"], intent["amount_received"],
                      intent["currency"], payment["amount"], payment["currency"])
            return
        complete_payment(cid, {"method": stripe_api.wallet_of(intent), "transaction_id": intent["id"]},
                         request, background)
    elif intent["status"] == "canceled":
        payment_failed(cid, "Stripe: canceled")
    # requires_payment_method after a decline: the payer may try again, so it stays "processing".


@router.post("/api/shop/stripe/status")
def stripe_status(data: CandidateRef, request: Request, background: BackgroundTasks):
    cid = check_token(data)
    sync_stripe(cid, request, background)
    return state(cid)


@router.post("/api/shop/stripe/webhook", include_in_schema=False)
async def stripe_webhook(request: Request, background: BackgroundTasks):
    """payment_intent.succeeded / .payment_failed / .canceled: re-read the intent from Stripe."""
    body = await request.body()
    if not stripe_api.verify_webhook(body, request.headers.get("stripe-signature", "")):
        fail(400, "Invalid signature")
    event = await request.json()
    intent = (event.get("data") or {}).get("object") or {}
    if event.get("type", "").startswith("payment_intent.") and intent.get("id"):
        cid = (intent.get("metadata") or {}).get("candidate_id")
        payment = ((repo.get(KIND, cid) if cid else None) or {}).get("payment") or {}
        if payment.get("intent_id") == intent["id"]:
            sync_stripe(cid, request, background)  # never trust the body: ask Stripe
    return {"received": True}


@router.post("/api/shop/vipps/start")
def vipps_start(data: StartPaymentRequest, request: Request):
    cid = check_token(data)
    if data.currency not in vipps.CURRENCIES:
        fail(422, "Vipps does not support this currency")
    payment = begin_payment(cid, "vipps", data.currency, vipps.new_reference())
    return_url = f"{base_url(request)}shop/?c={cid}&t={data.token}&vipps=1"
    try:
        url = vipps.create_payment(payment["reference"], payment["amount"], data.currency, return_url,
                                   "Norsk Audio – Pro")
    except PaymentError as e:
        payment_failed(cid, str(e))
        fail(502, str(e))
    return {"redirectUrl": url}


def sync_vipps(cid: str, request: Request, background: BackgroundTasks):
    """Ask Vipps about the candidate's payment; capture and complete it once authorized."""
    candidate = repo.get(KIND, cid)
    payment = (candidate or {}).get("payment") or {}
    if not candidate or payment.get("provider") != "vipps" or payment.get("status") != "processing":
        return
    try:
        info = vipps.get_payment(payment["reference"])
        if info["state"] == "AUTHORIZED":
            captured = info.get("aggregate", {}).get("capturedAmount", {}).get("value", 0)
            if captured < payment["amount"]:
                vipps.capture(payment["reference"], payment["amount"], payment["currency"])
            complete_payment(cid, {"transaction_id": info.get("pspReference", payment["reference"])},
                             request, background)
        elif info["state"] in ("ABORTED", "EXPIRED", "TERMINATED"):
            payment_failed(cid, f"Vipps: {info['state'].lower()}")
    except PaymentError as e:
        log.warning("Vipps check for %s failed: %s", cid, e)


@router.post("/api/shop/vipps/status")
def vipps_status(data: CandidateRef, request: Request, background: BackgroundTasks):
    cid = check_token(data)
    sync_vipps(cid, request, background)
    return state(cid)


@router.post("/api/shop/vipps/webhook", include_in_schema=False)
async def vipps_webhook(request: Request, background: BackgroundTasks):
    body = await request.body()
    path = request.url.path + (f"?{request.url.query}" if request.url.query else "")
    if not vipps.verify_webhook("POST", path, request.headers.get("host", ""), request.headers, body):
        fail(401, "Invalid signature")
    reference = (await request.json()).get("reference")
    cid = next((c["id"] for c in repo.list(KIND) if (c.get("payment") or {}).get("reference") == reference), None)
    if cid:
        sync_vipps(cid, request, background)  # never trust the body: ask Vipps for the state
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
