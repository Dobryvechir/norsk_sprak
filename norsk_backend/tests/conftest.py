"""Shared test setup.

Settings are read when `app` is first imported, so the environment is set here,
before any test module imports it. Tests therefore use a throwaway data folder
and never touch the real `data/` or `.env` values.
"""

import os
import tempfile

os.environ.update(
    APP_SECRET="test-secret-" + "x" * 32,
    DATA_DIR=tempfile.mkdtemp(prefix="norsk-test-"),
    METADATA_BACKEND="json",
    AUDIO_BACKEND="local",
    BOOTSTRAP_ADMIN_EMAIL="",
    BOOTSTRAP_ADMIN_PASSWORD="",
    OPENAI_API_KEY="",
)
