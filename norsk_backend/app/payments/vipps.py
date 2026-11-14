"""Vipps MobilePay ePayment API, direct integration.

    1. POST /accesstoken/get                 -> access token (cached until it expires)
    2. POST /epayment/v1/payments            -> redirectUrl: the payer approves in the Vipps app
    3. Vipps sends the payer back to our returnUrl; the page asks us for the state:
       GET  /epayment/v1/payments/{ref}      -> CREATED / AUTHORIZED / ABORTED / EXPIRED / TERMINATED
    4. POST /epayment/v1/payments/{ref}/capture once AUTHORIZED (the plan is delivered at once).
    Webhooks (POST /api/shop/vipps/webhook) speed up step 3; they are HMAC-signed.

https://developer.vippsmobilepay.com/docs/APIs/epayment-api/
"""

import base64
import hashlib
import hmac
import threading
import time
import uuid

import httpx

from ..config import settings
from . import PaymentError

BASE_URL = {"test": "https://apitest.vipps.no", "production": "https://api.vipps.no"}
CURRENCIES = ("NOK", "EUR")  # what the ePayment API accepts for a Norwegian merchant
_token: dict = {"value": "", "expires": 0.0}
_lock = threading.Lock()


def base_url() -> str:
    return BASE_URL["production" if settings.payment_environment == "production" else "test"]


def configured() -> bool:
    return bool(settings.vipps_client_id and settings.vipps_client_secret
                and settings.vipps_subscription_key and settings.vipps_merchant_serial_number)


def _common_headers() -> dict:
    return {
        "Ocp-Apim-Subscription-Key": settings.vipps_subscription_key,
        "Merchant-Serial-Number": settings.vipps_merchant_serial_number,
        "Vipps-System-Name": "norsk-audio",
        "Vipps-System-Version": "1.0",
        "Vipps-System-Plugin-Name": "norsk-audio-backend",
        "Vipps-System-Plugin-Version": "1.0",
    }


def access_token() -> str:
    if not configured():
        raise PaymentError("Vipps is not configured")
    with _lock:
        if _token["value"] and _token["expires"] > time.time() + 60:
            return _token["value"]
        response = httpx.post(f"{base_url()}/accesstoken/get", timeout=20, headers={
            **_common_headers(),
            "client_id": settings.vipps_client_id,
            "client_secret": settings.vipps_client_secret,
        })
        if response.status_code != 200:
            raise PaymentError("Vipps login failed")
        data = response.json()
        _token.update(value=data["access_token"], expires=time.time() + int(data.get("expires_in", 3600)))
        return _token["value"]


def _request(method: str, path: str, json: dict | None = None, idempotency_key: str | None = None) -> dict:
    headers = {**_common_headers(), "Authorization": f"Bearer {access_token()}"}
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key
    try:
        response = httpx.request(method, f"{base_url()}{path}", json=json, headers=headers, timeout=20)
    except httpx.HTTPError as e:
        raise PaymentError("Vipps is not reachable") from e
    if response.status_code >= 300:
        raise PaymentError(f"Vipps refused the request ({response.status_code})")
    return response.json() if response.content else {}


def new_reference() -> str:
    """A payment reference: 8-64 characters of [a-zA-Z0-9-], unique per payment."""
    return "norsk-" + uuid.uuid4().hex


def create_payment(reference: str, amount: int, currency: str, return_url: str, description: str) -> str:
    """Start a payment; returns the URL to send the payer to."""
    if currency not in CURRENCIES:
        raise PaymentError("Vipps does not support this currency")
    data = _request("POST", "/epayment/v1/payments", idempotency_key=reference, json={
        "amount": {"currency": currency, "value": amount},
        "paymentMethod": {"type": "WALLET"},
        "reference": reference,
        "userFlow": "WEB_REDIRECT",
        "returnUrl": return_url,
        "paymentDescription": description,
    })
    return data["redirectUrl"]


def get_payment(reference: str) -> dict:
    """{"state": "CREATED" | "AUTHORIZED" | "ABORTED" | "EXPIRED" | "TERMINATED",
        "aggregate": {"capturedAmount": {...}, ...}, "pspReference": ..., ...}"""
    return _request("GET", f"/epayment/v1/payments/{reference}")


def capture(reference: str, amount: int, currency: str) -> dict:
    return _request("POST", f"/epayment/v1/payments/{reference}/capture",
                    idempotency_key=f"capture-{reference}",
                    json={"modificationAmount": {"currency": currency, "value": amount}})


def verify_webhook(method: str, path_and_query: str, host: str, headers, body: bytes) -> bool:
    """Check a webhook's HMAC-SHA256 signature (Authorization header) with VIPPS_WEBHOOK_SECRET.

    String to sign: "<METHOD>\\n<path and query>\\n<x-ms-date>;<host>;<x-ms-content-sha256>"
    """
    if not settings.vipps_webhook_secret:
        return False
    content_hash = base64.b64encode(hashlib.sha256(body).digest()).decode()
    if not hmac.compare_digest(content_hash, headers.get("x-ms-content-sha256", "")):
        return False
    to_sign = f"{method}\n{path_and_query}\n{headers.get('x-ms-date', '')};{host};{content_hash}"
    signature = base64.b64encode(hmac.new(settings.vipps_webhook_secret.encode(), to_sign.encode(),
                                          hashlib.sha256).digest()).decode()
    expected = f"HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature={signature}"
    return hmac.compare_digest(expected, headers.get("authorization", ""))
