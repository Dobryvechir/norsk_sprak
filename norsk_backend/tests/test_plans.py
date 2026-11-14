"""After signup: plan choice, email verification, Basic/Advanced groups, and the
two payment integrations (Stripe for Apple Pay / Google Pay, Vipps ePayment)."""

import base64
import hashlib
import hmac
import json
import time
import urllib.parse

import pytest

from app import mailer
from app.config import settings
from app.payments import PRO_PRICES, PaymentError, stripe_api, vipps
from app.repository import membership_key, repo
from app.routes import plans
from app.routes.signup import KIND
from tests.test_signup import client, make_user, signup

b64 = lambda data: base64.b64encode(data).decode()  # noqa: E731


@pytest.fixture(autouse=True)
def outbox(monkeypatch):
    """Emails 'sent' during a test: (to, subject, text)."""
    sent = []
    monkeypatch.setattr(mailer, "send", lambda to, subject, text, html=None: sent.append((to, subject, text)))
    monkeypatch.setattr(settings, "public_base_url", "https://norsk.example.com/")
    monkeypatch.setattr(settings, "payment_environment", "test")
    return sent


def new_candidate(ip):
    email = f"{time.time_ns()}@test.no"
    r = signup(email, ip=ip)
    assert r.status_code == 201
    return email, {"candidateId": r.json()["id"], "token": r.json()["planToken"]}


def choose(ref, plan):
    return client.post("/api/plan", json={**ref, "plan": plan})


def link_token(outbox):
    text = outbox[-1][2]
    assert "https://norsk.example.com/app/verify/?token=" in text
    return text.split("verify/?token=")[1].split()[0]


def test_pages_are_served():
    for path in ("/app/plan/", "/app/shop/", "/app/verify/"):
        r = client.get(path)
        assert r.status_code == 200 and "text/html" in r.headers["content-type"]
    r = client.get("/app/plan?c=1&t=2", follow_redirects=False)
    assert r.status_code == 307 and r.headers["location"] == "plan/?c=1&t=2"


def test_groups_basic_and_advanced_exist():
    plans.ensure_plan_groups()  # what the server does at startup
    plans.ensure_plan_groups()
    names = {g["name"] for g in repo.list("groups")}
    assert {"Basic", "Advanced"} <= names
    assert sum(g["name"] == "Advanced" for g in repo.list("groups")) == 1  # not created twice
    assert repo.get("groups", plans.plan_group_id("basic"))["privilege"] == 0
    assert repo.get("groups", plans.plan_group_id("pro"))["privilege"] == 1


def test_old_groups_get_privilege_7():
    repo.put("groups", "oldgroup", {"id": "oldgroup", "name": "Old"})
    plans.ensure_group_privileges()
    assert repo.get("groups", "oldgroup")["privilege"] == 7
    repo.delete("groups", "oldgroup")


def test_basic_plan_sends_email_and_verify(outbox):
    email, ref = new_candidate("10.1.0.1")
    assert client.get("/api/plan/state", params={"c": ref["candidateId"], "t": "bad"}).status_code == 403
    assert choose({**ref, "token": "0" * 64}, "basic").status_code == 403

    r = choose(ref, "basic")
    assert r.status_code == 200 and r.json()["next"] == "done"
    assert outbox[-1][0] == email
    token = link_token(outbox)
    choose(ref, "basic")  # choosing again within a minute does not send a second email
    assert len(outbox) == 1

    _, admin = make_user(system_admin=True)
    listed = next(c for c in client.get("/api/admin/candidates", headers=admin).json() if c["email"] == email)
    assert listed["plan"] == "basic" and listed["email_verified"] is False
    assert "verify_token_hash" not in listed and "password_hash" not in listed
    assert listed["default_group_id"] == plans.plan_group_id("basic")

    assert client.post("/api/verify", json={"token": "wrong-token-123"}).status_code == 404
    r = client.post("/api/verify", json={"token": token})
    assert r.status_code == 200 and r.json() == {"email": email, "emailVerified": True, "approved": False}
    assert client.post("/api/verify", json={"token": token}).status_code == 404  # used once
    listed = next(c for c in client.get("/api/admin/candidates", headers=admin).json() if c["email"] == email)
    assert listed["email_verified"] is True

    # Approval into the suggested Basic group carries the verification over to the user.
    r = client.post(f"/api/admin/candidates/{ref['candidateId']}/approve", headers=admin,
                    json={"groupId": listed["default_group_id"]})
    user = repo.get("users", r.json()["id"])
    assert user["email_verified"] and user["plan"] == "basic"
    assert repo.get("memberships", membership_key(plans.plan_group_id("basic"), user["id"]))
    assert client.get("/api/plan/state", params={"c": ref["candidateId"], "t": ref["token"]}).json()["approved"]


def test_verify_link_expires(outbox):
    _, ref = new_candidate("10.1.0.2")
    choose(ref, "basic")
    token = link_token(outbox)
    candidate = repo.get(KIND, ref["candidateId"])
    repo.put(KIND, ref["candidateId"], {**candidate, "verify_sent_at": time.time() - 8 * 86400})
    assert client.post("/api/verify", json={"token": token}).status_code == 410


def assert_became_paid_user(ref, email, method, outbox):
    assert repo.get(KIND, ref["candidateId"]) is None  # no admin approval needed
    user = next(u for u in repo.list("users") if u["email"] == email)
    assert user["plan"] == "pro" and user["payment"]["status"] == "paid" and user["payment"]["method"] == method
    member = repo.get("memberships", membership_key(plans.plan_group_id("pro"), user["id"]))
    assert member and member["role"] == "viewer"
    assert outbox[-1][0] == email  # verification email after payment
    token = link_token(outbox)
    r = client.post("/api/verify", json={"token": token})
    assert r.json()["approved"] is True and repo.get("users", user["id"])["email_verified"]
    state = client.get("/api/plan/state", params={"c": ref["candidateId"], "t": ref["token"]}).json()
    assert state["paid"] and state["approved"]


# --- Stripe (Apple Pay / Google Pay) ---

class FakeStripe:
    """Stands in for the Stripe API: PaymentIntents in memory."""

    def __init__(self, monkeypatch):
        self.intents = {}
        monkeypatch.setattr(stripe_api, "configured", lambda: True)
        monkeypatch.setattr(stripe_api, "create_payment_intent", self.create)
        monkeypatch.setattr(stripe_api, "get_payment_intent", lambda intent_id: dict(self.intents[intent_id]))

    def create(self, reference, amount, currency, metadata, description):
        intent_id = f"pi_{len(self.intents) + 1}"
        self.intents[intent_id] = {"id": intent_id, "client_secret": f"{intent_id}_secret_x", "amount": amount,
                                   "amount_received": 0, "currency": currency.lower(),
                                   "status": "requires_payment_method", "latest_charge": None,
                                   "metadata": {**metadata, "reference": reference}}
        return dict(self.intents[intent_id])

    def pay(self, intent_id, wallet="apple_pay", amount=None):
        """What happens at Stripe when stripe.confirmPayment succeeds."""
        intent = self.intents[intent_id]
        intent.update(status="succeeded", amount_received=intent["amount"] if amount is None else amount,
                      latest_charge={"payment_method_details": {"card": {"wallet": {"type": wallet}}}})


@pytest.fixture
def fake_stripe(monkeypatch):
    monkeypatch.setattr(settings, "stripe_publishable_key", "pk_test_x")
    return FakeStripe(monkeypatch)


@pytest.mark.parametrize("wallet,method,currency,ip", [("apple_pay", "applepay", "EUR", "10.1.0.3"),
                                                       ("google_pay", "googlepay", "USD", "10.1.0.4")])
def test_pro_with_stripe_wallet(fake_stripe, outbox, wallet, method, currency, ip):
    email, ref = new_candidate(ip)
    config = client.get("/api/shop/config", params={"c": ref["candidateId"], "t": ref["token"]}).json()
    assert config["stripe"] == {"enabled": True, "publishableKey": "pk_test_x"} and config["prices"] == PRO_PRICES

    assert client.post("/api/shop/stripe/start", json={**ref, "currency": currency}).status_code == 409  # no plan
    assert choose(ref, "pro").json()["next"] == "shop"
    assert outbox == []  # Pro: the email comes after payment
    r = client.post("/api/shop/stripe/start", json={**ref, "currency": currency})
    assert r.json() == {"clientSecret": "pi_1_secret_x"}
    assert fake_stripe.intents["pi_1"]["amount"] == PRO_PRICES[currency]
    # Closing the sheet and pressing again reuses the same intent.
    assert client.post("/api/shop/stripe/start", json={**ref, "currency": currency}).json()["clientSecret"] == "pi_1_secret_x"

    state = client.post("/api/shop/stripe/status", json=ref).json()  # not confirmed yet
    assert not state["paid"] and state["payment"]["status"] == "processing"
    fake_stripe.pay("pi_1", wallet)
    assert client.post("/api/shop/stripe/status", json=ref).json()["paid"]
    assert_became_paid_user(ref, email, method, outbox)
    user = next(u for u in repo.list("users") if u["email"] == email)
    assert user["payment"]["provider"] == "stripe" and user["payment"]["transaction_id"] == "pi_1"
    assert client.post("/api/shop/stripe/start", json={**ref, "currency": currency}).status_code == 409


def test_stripe_new_intent_for_other_currency_and_underpayment(fake_stripe):
    _, ref = new_candidate("10.1.0.5")
    choose(ref, "pro")
    client.post("/api/shop/stripe/start", json={**ref, "currency": "EUR"})
    assert client.post("/api/shop/stripe/start", json={**ref, "currency": "NOK"}).json()["clientSecret"] == "pi_2_secret_x"
    fake_stripe.pay("pi_2", amount=100)  # less than the price: never accepted
    assert not client.post("/api/shop/stripe/status", json=ref).json()["paid"]
    fake_stripe.pay("pi_1")  # an abandoned intent is not the current payment
    assert not client.post("/api/shop/stripe/status", json=ref).json()["paid"]


def stripe_signature(body: bytes, secret: str, t: int) -> str:
    return f"t={t},v1=" + hmac.new(secret.encode(), f"{t}.".encode() + body, hashlib.sha256).hexdigest()


def test_stripe_webhook(fake_stripe, monkeypatch, outbox):
    monkeypatch.setattr(settings, "stripe_webhook_secret", "whsec_test")
    email, ref = new_candidate("10.1.0.6")
    choose(ref, "pro")
    client.post("/api/shop/stripe/start", json={**ref, "currency": "NOK"})
    fake_stripe.pay("pi_1", "google_pay")
    body = json.dumps({"type": "payment_intent.succeeded", "data": {"object": {
        "id": "pi_1", "metadata": {"candidate_id": ref["candidateId"]}}}}).encode()
    now = int(time.time())
    for bad in (stripe_signature(body, "whsec_other", now), stripe_signature(body, "whsec_test", now - 600), "t=1"):
        r = client.post("/api/shop/stripe/webhook", content=body, headers={"stripe-signature": bad})
        assert r.status_code == 400
    assert repo.get(KIND, ref["candidateId"])  # nothing happened yet
    r = client.post("/api/shop/stripe/webhook", content=body,
                    headers={"stripe-signature": stripe_signature(body, "whsec_test", now)})
    assert r.status_code == 200
    assert_became_paid_user(ref, email, "googlepay", outbox)


def test_stripe_wallet_of():
    assert stripe_api.wallet_of({"latest_charge": "ch_1"}) == "card"  # not expanded
    assert stripe_api.wallet_of({"latest_charge": {"payment_method_details": {"card": {"wallet": None}}}}) == "card"


def test_stripe_errors_are_reported(monkeypatch):
    monkeypatch.setattr(stripe_api, "configured", lambda: True)

    def refuse(*args):
        raise PaymentError("Stripe refused the request: Invalid API Key provided")
    monkeypatch.setattr(stripe_api, "create_payment_intent", refuse)
    _, ref = new_candidate("10.1.0.7")
    choose(ref, "pro")
    r = client.post("/api/shop/stripe/start", json={**ref, "currency": "EUR"})
    assert r.status_code == 502 and "Invalid API Key" in r.json()["detail"]


# --- Vipps ---

def test_pro_with_vipps(monkeypatch, outbox):
    calls = []
    states = iter(["CREATED", "AUTHORIZED"])
    monkeypatch.setattr(vipps, "configured", lambda: True)
    monkeypatch.setattr(vipps, "create_payment", lambda ref, amount, cur, url, text:
                        calls.append(("create", ref, amount, cur, url)) or "https://vipps.example/pay")
    monkeypatch.setattr(vipps, "get_payment", lambda ref: {"state": next(states), "pspReference": "psp-1",
                                                           "aggregate": {"capturedAmount": {"value": 0}}})
    monkeypatch.setattr(vipps, "capture", lambda ref, amount, cur: calls.append(("capture", ref, amount, cur)))

    email, ref = new_candidate("10.1.0.6")
    choose(ref, "pro")
    assert client.post("/api/shop/vipps/start", json={**ref, "currency": "USD"}).status_code == 422
    r = client.post("/api/shop/vipps/start", json={**ref, "currency": "NOK"})
    assert r.json() == {"redirectUrl": "https://vipps.example/pay"}
    _, reference, amount, currency, return_url = calls[0]
    assert (amount, currency) == (32000, "NOK")
    assert return_url.startswith("https://norsk.example.com/app/shop/?c=") and return_url.endswith("&vipps=1")

    first = client.post("/api/shop/vipps/status", json=ref).json()
    assert not first["paid"] and first["payment"]["status"] == "processing"
    assert client.post("/api/shop/vipps/status", json=ref).json()["paid"]
    assert calls[1] == ("capture", reference, 32000, "NOK")
    assert_became_paid_user(ref, email, "vipps", outbox)


def test_vipps_aborted(monkeypatch):
    monkeypatch.setattr(vipps, "configured", lambda: True)
    monkeypatch.setattr(vipps, "create_payment", lambda *a: "https://vipps.example/pay")
    monkeypatch.setattr(vipps, "get_payment", lambda ref: {"state": "ABORTED"})
    _, ref = new_candidate("10.1.0.10")
    choose(ref, "pro")
    client.post("/api/shop/vipps/start", json={**ref, "currency": "EUR"})
    state = client.post("/api/shop/vipps/status", json=ref).json()
    assert state["payment"]["status"] == "failed" and not state["paid"]
    assert choose(ref, "basic").status_code == 200  # may still fall back to Basic


def test_vipps_webhook_signature(monkeypatch):
    monkeypatch.setattr(settings, "vipps_webhook_secret", "webhook-secret")
    synced = []
    monkeypatch.setattr(plans, "sync_vipps", lambda payer, request, background: synced.append(payer))
    _, ref = new_candidate("10.1.0.8")
    candidate = repo.get(KIND, ref["candidateId"])
    repo.put(KIND, ref["candidateId"], {**candidate, "plan": "pro", "payment": {
        "status": "processing", "method": "vipps", "provider": "vipps", "reference": "norsk-abc", "currency": "NOK", "amount": 32000}})

    body = json.dumps({"reference": "norsk-abc", "name": "AUTHORIZED"}).encode()
    date = "Thu, 12 Nov 2026 10:00:00 GMT"
    content_hash = b64(hashlib.sha256(body).digest())
    to_sign = f"POST\n/api/shop/vipps/webhook\n{date};testserver;{content_hash}"
    signature = b64(hmac.new(b"webhook-secret", to_sign.encode(), hashlib.sha256).digest())
    good = {"x-ms-date": date, "x-ms-content-sha256": content_hash, "content-type": "application/json",
            "authorization": f"HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature={signature}"}
    bad = {**good, "authorization": good["authorization"][:-4] + "AAA="}
    assert client.post("/api/shop/vipps/webhook", content=body, headers=bad).status_code == 401
    assert client.post("/api/shop/vipps/webhook", content=body, headers=good).status_code == 200
    assert synced == [(KIND, ref["candidateId"])]


def test_unconfigured_payment_methods_are_disabled(monkeypatch):
    monkeypatch.setattr(settings, "stripe_secret_key", "")
    monkeypatch.setattr(settings, "vipps_client_id", "")
    _, ref = new_candidate("10.1.0.9")
    config = client.get("/api/shop/config", params={"c": ref["candidateId"], "t": ref["token"]}).json()
    assert not config["stripe"]["enabled"] and not config["vipps"]["enabled"]


def test_stripe_http_requests(monkeypatch):
    """What stripe_api actually sends to api.stripe.com, and how errors come back."""
    import httpx
    monkeypatch.setattr(settings, "stripe_secret_key", "sk_test_abc")
    monkeypatch.setattr(settings, "stripe_publishable_key", "pk_test_abc")
    calls = []

    def fake_request(method, url, data=None, params=None, headers=None, timeout=None):
        calls.append((method, url, data, params, headers))
        if url.endswith("/payment_intents/pi_bad"):
            return httpx.Response(404, json={"error": {"message": "No such payment_intent: 'pi_bad'"}})
        return httpx.Response(200, json={"id": "pi_1", "client_secret": "s", "status": "requires_payment_method"})
    monkeypatch.setattr(httpx, "request", fake_request)

    stripe_api.create_payment_intent("norsk-ref", 32000, "NOK", {"candidate_id": "cand1"}, "Norsk Audio – Pro")
    method, url, data, _, sent_headers = calls[0]
    assert (method, url) == ("POST", "https://api.stripe.com/v1/payment_intents")
    assert data == {"amount": 32000, "currency": "nok", "payment_method_types[]": "card",
                    "description": "Norsk Audio – Pro", "metadata[candidate_id]": "cand1",
                    "metadata[reference]": "norsk-ref"}
    assert sent_headers["Authorization"] == "Bearer sk_test_abc" and sent_headers["Idempotency-Key"] == "norsk-ref"
    assert sent_headers["Stripe-Version"] == stripe_api.API_VERSION

    stripe_api.get_payment_intent("pi_1")
    assert calls[1][:4] == ("GET", "https://api.stripe.com/v1/payment_intents/pi_1", None, {"expand[]": "latest_charge"})
    with pytest.raises(PaymentError, match="No such payment_intent"):
        stripe_api.get_payment_intent("pi_bad")


# --- Upgrade: a Basic user changes to Pro ---

def basic_user(*other_groups):
    """A user in the Basic group (and in `other_groups`); returns (user, auth headers)."""
    user, auth = make_user()
    for gid in (plans.plan_group_id("basic"), *other_groups):
        repo.put("memberships", membership_key(gid, user["id"]),
                 {"group_id": gid, "user_id": user["id"], "role": "viewer", "enabled": True, "quota": {}})
    return user, auth


def upgrade_ref(auth):
    """The {userId, token} of the link POST /api/me/upgrade-link gives the app."""
    r = client.post("/api/me/upgrade-link", headers=auth)
    assert r.status_code == 200
    url = urllib.parse.urlsplit(r.json()["url"])
    assert url.geturl().startswith("https://norsk.example.com/app/upgrade/?u=")
    query = urllib.parse.parse_qs(url.query)
    return {"userId": query["u"][0], "token": query["t"][0]}


def test_upgrade_link_only_for_basic_users():
    plain, plain_auth = make_user()  # in no privilege-0 group
    assert client.post("/api/me/upgrade-link", headers=plain_auth).status_code == 409
    _, admin_auth = make_user(system_admin=True)
    assert client.post("/api/me/upgrade-link", headers=admin_auth).status_code == 409
    assert client.post("/api/me/upgrade-link").status_code == 401

    user, auth = basic_user()
    ref = upgrade_ref(auth)
    assert ref["userId"] == user["id"]
    state = client.get("/api/plan/state", params={"u": ref["userId"], "t": ref["token"]}).json()
    assert state["upgrade"] and state["upgradable"] and not state["paid"] and state["email"] == user["email"]
    # The token belongs to this user only, and expires.
    bad = [{"u": plain["id"], "t": ref["token"]}, {"u": user["id"], "t": "123.abc"},
           {"u": user["id"], "t": plans.upgrade_token(user["id"], expires=int(time.time()) - 1)},
           {"u": user["id"], "c": "x", "t": ref["token"]}]
    for params in bad:
        assert client.get("/api/plan/state", params=params).status_code == 403
    # A user can't choose a sign-up plan.
    assert client.post("/api/plan", json={**ref, "plan": "pro"}).status_code == 403
    for path in ("/app/upgrade/", "/app/plan/pro-info.js", "/app/terms_of_sale", "/app/privacy_policy", "/app/norsk-audio"):
        assert client.get(path).status_code == 200


def test_pro_info_shows_the_advanced_limits():
    advanced = repo.get("groups", plans.plan_group_id("pro"))
    repo.put("groups", advanced["id"], {**advanced, "chatPerDayKb": 750})
    try:
        info = client.get("/api/plan/pro-info").json()
        assert info["prices"] == PRO_PRICES
        assert info["limits"]["chatPerDayKb"] == 750 and info["limits"]["expirationDays"] == advanced["expirationDays"]
    finally:
        repo.put("groups", advanced["id"], advanced)


def test_upgrade_with_stripe_moves_the_user_to_advanced(fake_stripe, monkeypatch):
    monkeypatch.setattr(settings, "stripe_webhook_secret", "whsec_test")
    other = {"id": "othergroup", "name": "Other", "privilege": 7}
    repo.put("groups", other["id"], other)
    user, auth = basic_user(other["id"])
    users_before = len(repo.list("users"))
    ref = upgrade_ref(auth)
    assert client.get("/api/shop/config", params={"u": ref["userId"], "t": ref["token"]}).json()["stripe"]["enabled"]
    assert client.post("/api/shop/stripe/start", json={**ref, "currency": "NOK"}).json() == {"clientSecret": "pi_1_secret_x"}
    assert fake_stripe.intents["pi_1"]["metadata"]["user_id"] == user["id"]
    fake_stripe.pay("pi_1", "google_pay")
    # The webhook (metadata.user_id) completes it; the page's status call then sees it paid.
    body = json.dumps({"type": "payment_intent.succeeded", "data": {"object": {
        "id": "pi_1", "metadata": {"user_id": user["id"]}}}}).encode()
    r = client.post("/api/shop/stripe/webhook", content=body,
                    headers={"stripe-signature": stripe_signature(body, "whsec_test", int(time.time()))})
    assert r.status_code == 200
    state = client.post("/api/shop/stripe/status", json=ref).json()
    assert state["paid"] and not state["upgradable"]

    assert len(repo.list("users")) == users_before  # the same user, no new account
    upgraded = repo.get("users", user["id"])
    assert upgraded["plan"] == "pro" and upgraded["payment"]["method"] == "googlepay"
    assert upgraded["password_hash"] == user["password_hash"]
    assert repo.get("memberships", membership_key(plans.plan_group_id("basic"), user["id"])) is None
    assert repo.get("memberships", membership_key(plans.plan_group_id("pro"), user["id"]))["role"] == "viewer"
    assert repo.get("memberships", membership_key(other["id"], user["id"]))  # other groups are kept
    # Now Pro: no more upgrade link or payment.
    assert client.post("/api/me/upgrade-link", headers=auth).status_code == 409
    assert client.post("/api/shop/stripe/start", json={**ref, "currency": "NOK"}).status_code == 409
    repo.delete("groups", other["id"])


def test_upgrade_with_vipps(monkeypatch):
    calls = []
    monkeypatch.setattr(vipps, "configured", lambda: True)
    monkeypatch.setattr(vipps, "create_payment", lambda ref, amount, cur, url, text:
                        calls.append(url) or "https://vipps.example/pay")
    monkeypatch.setattr(vipps, "get_payment", lambda ref: {"state": "AUTHORIZED", "pspReference": "psp-9",
                                                           "aggregate": {"capturedAmount": {"value": 0}}})
    monkeypatch.setattr(vipps, "capture", lambda ref, amount, cur: calls.append("capture"))
    user, auth = basic_user()
    ref = upgrade_ref(auth)
    assert client.post("/api/shop/vipps/start", json={**ref, "currency": "EUR"}).status_code == 200
    assert calls[0].startswith(f"https://norsk.example.com/app/shop/?u={user['id']}&t=") and calls[0].endswith("&vipps=1")
    state = client.post("/api/shop/vipps/status", json=ref).json()
    assert state["paid"] and calls[1] == "capture"
    assert repo.get("users", user["id"])["payment"]["transaction_id"] == "psp-9"
    assert repo.get("memberships", membership_key(plans.plan_group_id("pro"), user["id"]))
    assert repo.get("memberships", membership_key(plans.plan_group_id("basic"), user["id"])) is None
