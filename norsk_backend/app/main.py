"""
Entry point of the API server.

Start it with:
    Windows
    uvicorn app.main:app --host 127.0.0.1 --port 8500

nohup ./venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8500 > app.log 2>&1 < /dev/null &
Then open http://127.0.0.1:8000/docs for interactive API documentation.
Transcription runs in a separate process: `python -m app.worker`.

See docs/architecture.md for an overview of how the pieces fit together.
"""

import re
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .migrations import upgrade_recordings
from .repository import repo
from .routes import admin, auth, bible, books, groups, recordings
from .routes.admin import new_user
from .routes.auth import find_user_by_email

MIN_BOOTSTRAP_PASSWORD_LENGTH = 12


def create_bootstrap_admin():
    """Create the first system admin from BOOTSTRAP_ADMIN_EMAIL/PASSWORD.

    Runs at every startup but only creates the user if the email isn't taken,
    so it's safe to leave configured (though removing it afterwards is wiser).
    """
    email, password = settings.bootstrap_admin_email, settings.bootstrap_admin_password
    if not (email and password):
        return
    if len(password) < MIN_BOOTSTRAP_PASSWORD_LENGTH:
        raise RuntimeError("Bootstrap password too short")
    if not find_user_by_email(email):
        admin_user = new_user(email, password, system_admin=True)
        repo.put("users", admin_user["id"], admin_user)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Code before `yield` runs once when the server starts.
    create_bootstrap_admin()
    upgrade_recordings()
    books.seed_sample_books()
    yield


def allowed_origin_regex(origins) -> str | None:
    """One regex matching every allowed origin from ALLOWED_ORIGINS.

    A full origin ("https://app.example.com") must match exactly; a bare host
    ("localhost") matches http:// or https:// on any port, because browser
    origins always include the scheme and port, and dev servers (Flutter web)
    pick a random port.
    """
    patterns = [
        re.escape(o) if "://" in o else rf"https?://{re.escape(o)}(:\d+)?"
        for o in origins
    ]
    return "|".join(patterns) or None


app = FastAPI(title="Norsk Audio Group API", version="0.1.0", lifespan=lifespan)

# CORS: lets the web version of the app call the API from an allowed origin.
# The middleware answers the browser's OPTIONS preflight requests (sent before
# non-GET requests and requests with an Authorization header) for every route,
# and adds the Access-Control-* headers only when the Origin is allowed.
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=allowed_origin_regex(settings.allowed_origin_list),
    allow_methods=["*"],
    allow_headers=["*"],
    # The app reads the audio file name (for its extension) from this header.
    expose_headers=["Content-Disposition"],
    max_age=600,  # browsers may cache a preflight answer for 10 minutes
)

app.include_router(auth.router)
app.include_router(admin.router)
app.include_router(groups.router)
app.include_router(recordings.router)
app.include_router(books.router)
app.include_router(bible.router)


@app.get("/api/health")
def health():
    """Simple check that the server is up (no login needed)."""
    return {"status": "ok"}
