"""
API endpoints, grouped by area. Each module defines a FastAPI `router` that
main.py plugs into the app:

    auth.py        - logging in, "who am I", "my groups"
    admin.py       - system-admin only: create users and groups
    signup.py      - public signup + system-admin review of candidate users
    plans.py       - after signup: plan choice, Pro payment (shop), email verification
    groups.py      - group admin: members, AI settings, usage
    recordings.py  - upload, list, play, edit, delete, transcribe
    chat.py        - chat: profiles, conversations, messages, subgroups, locations

See docs/api.md for a table of every endpoint and who may call it.
"""
