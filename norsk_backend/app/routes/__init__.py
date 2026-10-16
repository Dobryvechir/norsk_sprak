"""
API endpoints, grouped by area. Each module defines a FastAPI `router` that
main.py plugs into the app:

    auth.py        - logging in, "who am I", "my groups"
    admin.py       - system-admin only: create users and groups
    groups.py      - group admin: members, AI settings, usage
    recordings.py  - upload, list, play, edit, delete, transcribe

See docs/api.md for a table of every endpoint and who may call it.
"""
