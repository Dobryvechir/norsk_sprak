"""
Metadata storage ("repository").

Everything except audio files - users, groups, memberships, recordings and
usage records - is stored as plain dictionaries, addressed by:

    kind  - the type of thing, e.g. "users" or "recordings"
    key   - its ID within that kind

Two interchangeable backends implement the same five methods
(get / list / put / delete, plus a `lock`):

    JsonRepo - one JSON file per entity under <data_dir>/metadata/<kind>/<key>.json
    PgRepo   - one row per entity in a PostgreSQL table (body stored as JSONB)

The rest of the app only uses the module-level `repo` object and doesn't care
which backend is active. See docs/data-model.md for the shape of each kind.
"""

import json
import os
import tempfile
import threading
from pathlib import Path

from .config import settings


class JsonRepo:
    """Stores each entity as a JSON file on disk.

    Simple and dependency-free, but only safe for a single API process plus a
    single worker process. `lock` serialises access *within one process*.
    """

    def __init__(self, data_dir):
        self.root = Path(data_dir) / "metadata"
        self.root.mkdir(parents=True, exist_ok=True)
        # Re-entrant so code holding the lock can still call get/list/put.
        self.lock = threading.RLock()

    def _path(self, kind, key) -> Path:
        return self.root / kind / (key + ".json")

    def get(self, kind, key):
        """Return the entity as a dict, or None if it doesn't exist."""
        with self.lock:
            path = self._path(kind, key)
            if not path.is_file():
                return None
            return json.loads(path.read_text(encoding="utf-8"))

    def list(self, kind):
        """Return every entity of this kind (ordered by ID)."""
        with self.lock:
            folder = self.root / kind
            if not folder.exists():
                return []
            return [json.loads(f.read_text(encoding="utf-8")) for f in sorted(folder.glob("*.json"))]

    def put(self, kind, key, value):
        """Create or overwrite an entity.

        Writes to a temporary file first and then renames it into place, so a
        crash mid-write never leaves a half-written (corrupt) JSON file.
        """
        with self.lock:
            folder = self.root / kind
            folder.mkdir(parents=True, exist_ok=True)
            fd, tmp_path = tempfile.mkstemp(dir=folder, suffix=".tmp")
            try:
                # Always UTF-8: the platform default (cp1252 on Windows) cannot store
                # Cyrillic, Greek or Hebrew text.
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(value, f, ensure_ascii=False, indent=2)
                    f.flush()
                    os.fsync(f.fileno())  # make sure the bytes are really on disk
                os.replace(tmp_path, self._path(kind, key))  # atomic rename
            finally:
                # Only still exists if something failed before the rename.
                if os.path.exists(tmp_path):
                    os.unlink(tmp_path)

    def delete(self, kind, key):
        """Remove an entity. Does nothing if it doesn't exist."""
        with self.lock:
            self._path(kind, key).unlink(missing_ok=True)


class PgRepo:
    """Stores each entity as a row in a PostgreSQL table:

        entities(kind TEXT, id TEXT, body JSONB, PRIMARY KEY (kind, id))

    A new connection is opened for every call (simple, not the fastest).
    `psycopg` is imported lazily so it is only required in PostgreSQL mode.
    """

    def __init__(self, url):
        import psycopg

        self.url = url
        # Database writes are transactional, but quota checks read-then-write,
        # so this lock still serialises them within one API process.
        self.lock = threading.RLock()
        with psycopg.connect(url) as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS entities ("
                " kind TEXT NOT NULL, id TEXT NOT NULL, body JSONB NOT NULL,"
                " PRIMARY KEY(kind, id))"
            )

    def _connect(self):
        import psycopg

        return psycopg.connect(self.url)

    def get(self, kind, key):
        with self._connect() as conn:
            row = conn.execute(
                "SELECT body FROM entities WHERE kind=%s AND id=%s", (kind, key)
            ).fetchone()
            return row[0] if row else None

    def list(self, kind):
        with self._connect() as conn:
            rows = conn.execute("SELECT body FROM entities WHERE kind=%s", (kind,)).fetchall()
            return [row[0] for row in rows]

    def put(self, kind, key, value):
        from psycopg.types.json import Jsonb

        with self._connect() as conn:
            # "Upsert": insert, or replace the body if the row already exists.
            conn.execute(
                "INSERT INTO entities VALUES (%s, %s, %s) "
                "ON CONFLICT(kind, id) DO UPDATE SET body=EXCLUDED.body",
                (kind, key, Jsonb(value)),
            )

    def delete(self, kind, key):
        with self._connect() as conn:
            conn.execute("DELETE FROM entities WHERE kind=%s AND id=%s", (kind, key))


# The single shared repository used by the whole app, chosen by configuration.
if settings.metadata_backend == "json":
    repo = JsonRepo(settings.data_dir)
else:
    repo = PgRepo(settings.database_url)


def membership_key(group_id, user_id) -> str:
    """Memberships are stored under the key '<group_id>_<user_id>'."""
    return group_id + "_" + user_id
