# Plans, shop and email verification

Code: `app/routes/plans.py`, `app/payments/`, `app/mailer.py`, pages in `app/static/`
(`plan.html`, `shop.html`, `verify.html`). Endpoints are listed in [api.md](api.md).

Payment providers (decision 2026-11-14, after comparing Stripe, Mollie, Vipps, Nexi and Swedbank Pay):
**Vipps** through its own API (direct integration), **Apple Pay and Google Pay through Stripe**.
Neither charges a monthly fee, only fees per transaction.

## Flow

```
/signup ──► /plan/ ──Basic──► "Thank you for registration, check your email"
                  │            candidate waits for a system admin (dialog suggests group "Basic")
                  └─Pro────► /shop/ ── Apple Pay / Google Pay (Stripe) or Vipps ──► paid
                                         candidate becomes a user at once, role viewer in "Advanced"
email link ──► /verify/?token=… ──► email_verified = true (candidate or user)
```

* Prices (`payments/__init__.py`): **30 EUR / 32 USD / 320 NOK**. Vipps takes NOK and EUR only.
  NOK is the cheapest for you: other currencies cost conversion fees on payout.
* The `/plan/` and `/shop/` URLs carry `c` (candidate id) and `t`, an HMAC of the id keyed with
  `<DATA_DIR>/key/key.txt`, so only the person who signed up can choose the plan or pay.
* Basic sends the verification email when chosen. Pro sends it right after payment.
* The verification page confirms only on a button press, so mail scanners that open links
  don't verify the address by accident. Links are valid for 7 days and work once.
* The admin screen (app → Admin → Sign-up requests) shows "Email verified / not verified"
  and the plan ("Basic (free)", "Pro – not paid"). Paid people never show up there,
  since they are users already.
* The candidate's `payment` is the current attempt. A payer may close the Vipps page or the
  wallet sheet and try again; only the current attempt's success completes the plan.

## Vipps MobilePay (direct, ePayment API)

`payments/vipps.py`: access token → create payment (`WEB_REDIRECT`) → the payer approves in Vipps
→ returns to `/shop/?…&vipps=1`, which polls `/api/shop/vipps/status` → the server reads the
payment and **captures** it when `AUTHORIZED` (the plan is delivered at once).

Setup:
1. Order "Vipps på nett" in the merchant portal (portal.vippsmobilepay.com); you need a Norwegian
   organization number. Under *Utvikler* get the test keys: `VIPPS_CLIENT_ID`,
   `VIPPS_CLIENT_SECRET`, `VIPPS_SUBSCRIPTION_KEY` (Ocp-Apim primary key),
   `VIPPS_MERCHANT_SERIAL_NUMBER`.
2. Optional but recommended: register a webhook for
   `epayments.payment.authorized.v1`, `.aborted.v1`, `.expired.v1`, `.terminated.v1` with
   `POST https://apitest.vipps.no/webhooks/v1/webhooks` and url
   `<PUBLIC_BASE_URL>api/shop/vipps/webhook`; put the returned `secret` in `VIPPS_WEBHOOK_SECRET`.
   Webhooks are HMAC-SHA256-signed and only trigger a re-read of the payment from Vipps.
3. Test with the Vipps test app (MT) and a test user from the portal.
4. Production keys + `PAYMENT_ENVIRONMENT=production` switch to `api.vipps.no`.

## Apple Pay and Google Pay (Stripe)

`payments/stripe_api.py` + Stripe's **Express Checkout Element** on `/shop/`:

1. Stripe.js (loaded from `js.stripe.com`, as Stripe requires) shows the Apple Pay button in
   Safari on Apple devices and the Google Pay button in Chrome/Android, whichever the browser supports.
2. When the payer approves in the wallet sheet, the page calls `POST /api/shop/stripe/start`;
   the server creates a **PaymentIntent** (amount and currency from `PRO_PRICES`,
   `payment_method_types=card`, `metadata.candidate_id`) and returns its `client_secret`.
3. The page calls `stripe.confirmPayment(...)`. Stripe receives the wallet token (encrypted for
   Stripe, so this server never sees card numbers), runs 3-D Secure if the bank wants it and
   charges the card. A 3-D Secure redirect comes back to `/shop/?…&stripe=1`.
4. The page polls `POST /api/shop/stripe/status`; the server reads the intent from Stripe.
   When it has `succeeded` with the full amount in the right currency, the candidate becomes a
   user. The wallet (`applepay` / `googlepay`) is read from the charge.
5. The `payment_intent.*` webhook does the same if the page was closed early.

Setup:
1. Create a Stripe account (stripe.com, country Norway). Verify the business (organization
   number, ID, Norwegian bank account) and have the website show prices, terms, refund policy,
   contact details and a privacy policy.
2. Dashboard → Developers → API keys: `STRIPE_SECRET_KEY` (`sk_test_…`) and
   `STRIPE_PUBLISHABLE_KEY` (`pk_test_…`). Keep the secret key out of git (`.env` only).
3. Dashboard → Settings → Payment methods: make sure **Cards**, **Apple Pay** and **Google Pay**
   are on.
4. Dashboard → Settings → **Payment method domains**: add the domain that serves `/shop/`
   (needed for Apple Pay; Apple Pay works only over HTTPS on a registered domain). If Stripe
   asks you to host Apple's verification file, put it in `APPLE_PAY_DOMAIN_ASSOCIATION_FILE`; it is
   served at `/.well-known/apple-developer-merchantid-domain-association`.
5. Dashboard → Developers → Webhooks: add the endpoint `<PUBLIC_BASE_URL>api/shop/stripe/webhook`
   with the events `payment_intent.succeeded`, `payment_intent.payment_failed`,
   `payment_intent.canceled`; put its signing secret in `STRIPE_WEBHOOK_SECRET`.
6. Test: Google Pay shows in Chrome with a Google account that has a card saved (test mode never
   charges real cards). Apple Pay needs Safari with a card in Wallet; in test mode Stripe
   accepts the real card without charging it.
7. Going live: switch to the `sk_live_` / `pk_live_` keys and a live-mode webhook secret, and
   register the domain again in live mode if Stripe asks.

Fees (Norwegian Stripe account, checked 2026-11): 2.4% + 2 NOK for Norwegian/EEA cards,
3.25% + 2 NOK for other cards, +2% when currency conversion is needed. No monthly fee.

## Email

`mailer.py` sends over SMTP (`SMTP_*` settings). Without `SMTP_HOST` the message, including
the link, is written to the log, which is handy locally. Set `PUBLIC_BASE_URL` so links point to
the public address rather than `127.0.0.1`.
