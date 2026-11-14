"""
Application settings.

All configuration is read from environment variables, or from a `.env` file in
the directory the server is started from. Variable names are the upper-case
versions of the field names below, e.g. `app_secret` <- `APP_SECRET`.

See docs/configuration.md for what each setting does.
"""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Secret key used to sign login tokens (JWT). Must be long and random.
    app_secret: str = ""

    # Folder where metadata (JSON mode), audio (local mode) and temp files live.
    data_dir: str = "./data"

    # Where users/groups/recordings are stored: "json" or "postgresql".
    metadata_backend: str = "json"

    # Where audio files are stored: "local" or "google_drive".
    audio_backend: str = "local"

    # Connection string, only used when metadata_backend == "postgresql".
    database_url: str = ""

    # Key for OpenAI Whisper transcription (shared by all groups).
    openai_api_key: str = ""

    # Google Drive settings, only used when audio_backend == "google_drive".
    google_drive_credentials_file: str = ""
    google_drive_root_folder_id: str = ""

    # If both are set, a system admin with these credentials is created at
    # startup (only if no user with that email exists yet).
    bootstrap_admin_email: str = ""
    bootstrap_admin_password: str = ""

    # Largest audio upload accepted, in megabytes.
    max_upload_mb: int = 150

    # Web origins allowed to call the API from a browser (CORS), comma-separated.
    # An entry is a full origin ("https://app.example.com") or a bare host name
    # ("localhost"), which allows that host over http/https on any port.
    allowed_origins: str = ""

    # Public address of this server, used for links in emails and for payment
    # return URLs, e.g. "https://norsk.example.com/" (with a trailing path if
    # the server is behind a proxy prefix). Empty: taken from the request.
    public_base_url: str = ""

    # --- Email (verification links after signup) ---
    # Without SMTP_HOST no email is sent; the link is written to the log instead.
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_username: str = ""
    smtp_password: str = ""
    smtp_from: str = ""
    # "starttls" (port 587), "ssl" (port 465) or "none".
    smtp_security: str = "starttls"

    # --- Payments for the Pro plan ---
    # Vipps: "test" uses the Vipps test API (apitest.vipps.no), "production" real money.
    # (Stripe's mode follows its keys: sk_test_/pk_test_ or sk_live_/pk_live_.)
    payment_environment: str = "test"

    # Vipps MobilePay ePayment API (portal.vippsmobilepay.com -> Utvikler).
    vipps_client_id: str = ""
    vipps_client_secret: str = ""
    vipps_subscription_key: str = ""
    vipps_merchant_serial_number: str = ""
    # The secret Vipps returns when the webhook is registered (see docs/payments.md).
    vipps_webhook_secret: str = ""

    # Stripe: Apple Pay and Google Pay (dashboard.stripe.com -> Developers -> API keys).
    stripe_secret_key: str = ""
    stripe_publishable_key: str = ""
    # Signing secret of the webhook endpoint <PUBLIC_BASE_URL>api/shop/stripe/webhook.
    stripe_webhook_secret: str = ""
    # Apple's domain verification file, served at
    # /.well-known/apple-developer-merchantid-domain-association (only if Stripe asks
    # you to host it when registering the domain for Apple Pay).
    apple_pay_domain_association_file: str = ""

    @property
    def allowed_origin_list(self) -> list[str]:
        return [o.strip().rstrip("/") for o in self.allowed_origins.split(",") if o.strip()]


settings = Settings()

# Refuse to start with a weak secret: anyone who knows it can forge login tokens.
if len(settings.app_secret) < 32:
    raise RuntimeError("APP_SECRET must be at least 32 characters")
