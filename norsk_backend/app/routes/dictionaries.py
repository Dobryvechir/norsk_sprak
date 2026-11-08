"""
Dictionaries: one JSON file per language, data/dictionaries/dict_<language_code>.json.

    GET /api/dictionaries                  which dictionaries exist, with their sizes
    GET /api/dictionary/{language_code}    the content of one of them

Neither needs a login, and a page on any site may read them (CORS), independently
of ALLOWED_ORIGINS. Adding a language only takes dropping its file in the folder.
"""

import re
from pathlib import Path

from fastapi import APIRouter
from fastapi.responses import FileResponse, JSONResponse

from ..config import settings
from .bible import PUBLIC_CORS, fail

router = APIRouter()

# Also what keeps a requested language code from pointing outside the folder.
LANGUAGE_CODE = r"[A-Za-z0-9_-]+"
DICTIONARY_FILE = re.compile(rf"dict_({LANGUAGE_CODE})\.json")


def dictionaries_dir() -> Path:
    return Path(settings.data_dir) / "dictionaries"


@router.get("/api/dictionaries")
def list_dictionaries():
    """One item per dictionary file, sorted by language code."""
    folder = dictionaries_dir()
    items = []
    for path in folder.iterdir() if folder.is_dir() else ():
        match = DICTIONARY_FILE.fullmatch(path.name)
        if match and path.is_file():
            lang = match.group(1)
            items.append({"lang": lang, "url": f"/api/dictionary/{lang}", "size": path.stat().st_size})
    items.sort(key=lambda item: item["lang"])
    return JSONResponse(items, headers=PUBLIC_CORS)


@router.get("/api/dictionary/{language_code}")
def get_dictionary(language_code: str):
    """The dictionary file as it is on disk, served as JSON."""
    path = dictionaries_dir() / f"dict_{language_code}.json"
    if not re.fullmatch(LANGUAGE_CODE, language_code) or not path.is_file():
        fail(404, "Dictionary not found")
    return FileResponse(path, media_type="application/json", headers=PUBLIC_CORS)
