"""Stripe: Apple Pay and Google Pay through the Express Checkout Element.

Stripe is the payment provider for both wallets: Stripe.js shows the Apple Pay /
Google Pay buttons, does Apple's merchant validation, receives the wallet token
(encrypted for Stripe, so this server never sees card numbers), runs 3-D Secure
when the bank asks for it and charges the card.

    1. The payer presses Apple Pay / Google Pay; the page calls POST /api/shop/stripe/start
       and we create a PaymentIntent (amount, currency) -> client_secret.
    2. The page calls stripe.confirmPayment(client_secret).
    3. We read the PaymentIntent (POST /api/shop/stripe/status, or the
       payment_intent.* webhook); "succeeded" -> the Pro plan is paid.

Plain HTTPS calls to https://api.stripe.com (form-encoded), like vipps.py.
https://docs.stripe.com/elements/express-checkout-element
"""

import hashlib
import hmac
import time

import httpx

from ..config import settings
from . import PaymentError

API = "https://api.stripe.com/v1"
API_VERSION = "2024-06-20"
WEBHOOK_TOLERANCE_SECONDS = 300
# charge.payment_method_details.card.wallet.type -> our payment "method"
WALLETS = {"apple_pay": "applepay", "google_pay": "googlepay"}


def configured() -> bool:
    return bool(settings.stripe_secret_key and settings.stripe_publishable_key)


def _request(method: str, path: str, data: dict | None = None, idempotency_key: str | None = None) -> dict:
    if not configured():
        raise PaymentError("Stripe is not configured")
    headers = {"Authorization": f"Bearer {settings.stripe_secret_key}", "Stripe-Version": API_VERSION}
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key
    try:
        response = httpx.request(method, f"{API}{path}", data=data if method == "POST" else None,
                                 params=data if method == "GET" else None, headers=headers, timeout=20)
    except httpx.HTTPError as e:
        raise PaymentError("Stripe is not reachable") from e
    if response.status_code >= 300:
        try:
            message = response.json()["error"]["message"]
        except (ValueError, KeyError):
            message = f"status {response.status_code}"
        raise PaymentError(f"Stripe refused the request: {message}")
    return response.json()


def create_payment_intent(reference: str, amount: int, currency: str, metadata: dict, description: str) -> dict:
    """A new PaymentIntent for a card wallet payment; returns {"id", "client_secret", "status", ...}.

    Apple Pay and Google Pay are both the "card" payment method type at Stripe.
    """
    return _request("POST", "/payment_intents", idempotency_key=reference, data={
        "amount": amount,
        "currency": currency.lower(),
        "payment_method_types[]": "card",
        "description": description,
        **{f"metadata[{key}]": value for key, value in metadata.items()},
        "metadata[reference]": reference,
    })


def get_payment_intent(intent_id: str) -> dict:
    """The PaymentIntent with its latest charge (to see which wallet paid).

    status: requires_payment_method | requires_confirmation | requires_action |
            processing | requires_capture | succeeded | canceled
    """
    return _request("GET", f"/payment_intents/{intent_id}", data={"expand[]": "latest_charge"})


def wallet_of(intent: dict) -> str:
    """"applepay", "googlepay" or "card", from the intent's latest charge."""
    charge = intent.get("latest_charge") or {}
    if not isinstance(charge, dict):
        return "card"
    wallet = ((charge.get("payment_method_details") or {}).get("card") or {}).get("wallet") or {}
    return WALLETS.get(wallet.get("type"), "card")


def verify_webhook(payload: bytes, signature_header: str, now: float | None = None) -> bool:
    """Check the Stripe-Signature header ("t=<time>,v1=<hex HMAC-SHA256 of '<t>.<body>'>")
    with STRIPE_WEBHOOK_SECRET, and that it is at most 5 minutes old."""
    if not settings.stripe_webhook_secret:
        return False
    parts = [p.split("=", 1) for p in signature_header.split(",") if "=" in p]
    timestamps = [v for k, v in parts if k == "t"]
    signatures = [v for k, v in parts if k == "v1"]
    if not timestamps or not signatures or not timestamps[0].isdigit():
        return False
    now = time.time() if now is None else now
    if abs(now - int(timestamps[0])) > WEBHOOK_TOLERANCE_SECONDS:
        return False
    expected = hmac.new(settings.stripe_webhook_secret.encode(), timestamps[0].encode() + b"." + payload,
                        hashlib.sha256).hexdigest()
    return any(hmac.compare_digest(expected, s) for s in signatures)
