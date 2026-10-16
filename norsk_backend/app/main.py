"""
Entry point of the API server.

Start it with:

    uvicorn app.main:app --host 127.0.0.1 --port 8000

Then open http://127.0.0.1:8000/docs for interactive API documentation.
Transcription runs in a separate process: `python -m app.worker`.

See docs/architecture.md for an overview of how the pieces fit together.
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI

from .config import settings
from .repository import repo
from .routes import admin, auth, groups, recordings
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
    yield


app = FastAPI(title="Norsk Audio Group API", version="0.1.0", lifespan=lifespan)

app.include_router(auth.router)
app.include_router(admin.router)
app.include_router(groups.router)
app.include_router(recordings.router)


@app.get("/health")
def health():
    """Simple check that the server is up (no login needed)."""
    return {"status": "ok"}
