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

Generate a good secret:

```bash
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Both the API server and the worker read the same settings, so start both from
the same folder (or with the same environment).
