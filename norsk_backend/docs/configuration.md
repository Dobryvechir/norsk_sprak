# Configuration

Settings come from environment variables or a `.env` file in the folder you
start the server from (normally `norsk_backend/`). Real environment variables
win over `.env`. Defined in `app/config.py`. Copy `.env.example` to start.

| Variable | Default | Meaning |
|---|---|---|
| `APP_SECRET` | *(required)* | Signs login tokens. **≥ 32 random characters**, or the server refuses to start. Changing it logs everyone out. |
| `DATA_DIR` | `./data` | Where metadata (JSON mode), audio (local mode), temp and cache files go. |
| `METADATA_BACKEND` | `json` | `json` (files) or anything else = PostgreSQL. |
| `DATABASE_URL` | | PostgreSQL connection string, e.g. `postgresql://user:pass@localhost/norsk`. |
| `AUDIO_BACKEND` | `local` | `local` (disk) or anything else = Google Drive. |
| `GOOGLE_DRIVE_CREDENTIALS_FILE` | | Path to an OAuth *authorized user* JSON file. |
| `GOOGLE_DRIVE_ROOT_FOLDER_ID` | | Drive folder ID to upload into. |
| `OPENAI_API_KEY` | | Needed by the worker to transcribe. Shared by all groups. |
| `BOOTSTRAP_ADMIN_EMAIL` | | With the password below, creates the first system admin at startup if that email doesn't exist yet. |
| `BOOTSTRAP_ADMIN_PASSWORD` | | ≥ 12 characters. Remove both after the first start. |
| `MAX_UPLOAD_MB` | `150` | Largest accepted upload. |
| `ALLOWED_ORIGINS` | *(none)* | Comma-separated web origins allowed to call the API from a browser (CORS), e.g. `localhost,https://app.example.com`. A full origin must match exactly; a bare host such as `localhost` allows it over http/https on any port. Empty = no browser origins allowed (mobile/desktop apps don't need CORS). |
| `PUBLIC_BASE_URL` | *(from the request)* | Public address of the server, e.g. `https://norsk.example.com/` (include a proxy prefix). Used for the link in the verification email and the Vipps return URL. **Set it in production.** |
| `SMTP_HOST` | | SMTP server for the verification email. Empty = no email is sent; the link is written to the log. |
| `SMTP_PORT` | `587` | |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | | SMTP login (skipped when the user name is empty). |
| `SMTP_FROM` | `SMTP_USERNAME` | Sender, e.g. `Norsk Audio <no-reply@example.com>`. |
| `SMTP_SECURITY` | `starttls` | `starttls`, `ssl` (port 465) or `none`. |
| `PAYMENT_ENVIRONMENT` | `test` | Vipps: `test` (apitest.vipps.no) or `production` (api.vipps.no). Stripe's mode follows its keys. |
| `VIPPS_CLIENT_ID`, `VIPPS_CLIENT_SECRET`, `VIPPS_SUBSCRIPTION_KEY`, `VIPPS_MERCHANT_SERIAL_NUMBER` | | Vipps MobilePay API keys (merchant portal → *Utvikler*). Vipps is hidden until all four are set. |
| `VIPPS_WEBHOOK_SECRET` | | Secret returned when the webhook is registered; webhooks are refused without it (the return page still works). |
| `STRIPE_SECRET_KEY` / `STRIPE_PUBLISHABLE_KEY` | | Stripe API keys (Dashboard → Developers → API keys) for Apple Pay and Google Pay. `sk_test_`/`pk_test_` = test mode, `sk_live_`/`pk_live_` = real money. Apple Pay / Google Pay are hidden until both are set. |
| `STRIPE_WEBHOOK_SECRET` | | Signing secret (`whsec_…`) of the webhook endpoint `<PUBLIC_BASE_URL>api/shop/stripe/webhook`; webhooks are refused without it (the shop page still works). |
| `APPLE_PAY_DOMAIN_ASSOCIATION_FILE` | | Only if Stripe asks you to host Apple's domain verification file: it is served at `/.well-known/apple-developer-merchantid-domain-association`. |

Generate a good secret:

```bash
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Both the API server and the worker read the same settings, so start both from
the same folder (or with the same environment).
