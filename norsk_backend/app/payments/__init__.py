"""Payments for the Pro plan.

    vipps.py      - Vipps MobilePay ePayment API, direct integration: create, poll, capture, webhook
    stripe_api.py - Stripe, the payment provider for Apple Pay and Google Pay
                    (Express Checkout Element + PaymentIntents + webhook)

See docs/payments.md.
"""

# The Pro plan's price in each supported currency, in minor units (cents/øre).
PRO_PRICES = {"EUR": 3000, "USD": 3200, "NOK": 32000}


class PaymentError(Exception):
    """A payment could not be made; the message is safe to show to the payer."""
