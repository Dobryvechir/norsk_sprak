"""
Library endpoints: books, their sections, and the sections' chapters.
All read-only through the API; content is added to the metadata store directly
(see `seed_sample_books`, which creates a sample Bible > Genesis > Genesis 1).

    book     {"id": "bible",
              "name": {"en": "Bible", "nb": "Bibelen", ...},   # not every language needed
              "author": "...",
              "audioLanguages": ["en", "nb", ...],
              "groups": [],                                   # group IDs; empty = everyone
              "icon": "https://..."}                          # may be empty
    section  same fields as a book, plus "bookId"
    chapter  {"id", "sectionId", "name", "audio": {lang: {...}}, "sentences": {lang: [...]}}
             i.e. a recording (see routes/recordings.py) without group_id,
             uploader_id and created_at

Sections and chapters may also have an optional integer "order": they are
listed by it first (items without one come last), then by name.

Visibility: a book or section with no groups is visible to every logged-in
user; otherwise only to enabled members of one of its groups, and to system
admins. A section also needs its book to be visible, and a chapter its section.
"""

import re

from fastapi import APIRouter, Depends, Query
from fastapi.responses import FileResponse

from ..helpers import LANGUAGES, fail
from ..repository import membership_key, repo
from ..security import current_user
from ..storage import get_storage
from .recordings import public_recording

router = APIRouter()

DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100

SAMPLE_BOOKS = [{
    "id": "bible",
    "name": {
        "en": "Bible", "nb": "Bibelen", "uk": "Біблія", "ru": "Библия",
        "de": "Bibel", "da": "Bibelen", "sv": "Bibeln", "cs": "Bible",
        "bg": "Библия", "pl": "Biblia", "pt": "Bíblia", "es": "Biblia",
        "fr": "Bible", "el": "Αγία Γραφή", "he": "כתבי הקודש", "it": "Bibbia",
    },
    "author": "",
    "audioLanguages": list(LANGUAGES),
    "groups": [],
    "icon": "",
}]

SAMPLE_SECTIONS = [{
    "id": "bible-genesis",
    "bookId": "bible",
    "order": 1,
    "name": {
        "en": "Genesis", "nb": "Første Mosebok", "uk": "Буття", "ru": "Бытие",
        "de": "1. Mose", "da": "Første Mosebog", "sv": "Första Moseboken", "cs": "Genesis",
        "bg": "Битие", "pl": "Księga Rodzaju", "pt": "Génesis", "es": "Génesis",
        "fr": "Genèse", "el": "Γένεσις", "he": "בראשית", "it": "Genesi",
    },
    "author": "",
    "audioLanguages": [],  # no audio yet
    "groups": [],
    "icon": "",
}]

# Genesis 1:1-3 in public-domain translations (KJV, Norwegian 1930, Ohienko,
# Synodal); verse 1 only in the other languages. No audio yet, so it can be
# viewed but not played.
SAMPLE_CHAPTERS = [{
    "id": "bible-genesis-1",
    "sectionId": "bible-genesis",
    "order": 1,
    "name": "Genesis 1",
    "audio": {},
    "sentences": {
        "en": ["In the beginning God created the heaven and the earth.",
               "And the earth was without form, and void; and darkness was upon the face of the deep. "
               "And the Spirit of God moved upon the face of the waters.",
               "And God said, Let there be light: and there was light."],
        "nb": ["I begynnelsen skapte Gud himmelen og jorden.",
               "Og jorden var øde og tom, og det var mørke over det store dyp, og Guds Ånd svevde over vannene.",
               "Og Gud sa: Det bli lys! Og det blev lys."],
        "uk": ["На початку Бог створив небо та землю.",
               "А земля була пуста та порожня, і темрява була над безоднею, і Дух Божий ширяв над поверхнею води.",
               "І сказав Бог: Хай станеться світло! І сталося світло."],
        "ru": ["В начале сотворил Бог небо и землю.",
               "Земля же была безвидна и пуста, и тьма над бездною, и Дух Божий носился над водою.",
               "И сказал Бог: да будет свет. И стал свет."],
        "de": ["Am Anfang schuf Gott Himmel und Erde."],
        "da": ["I Begyndelsen skabte Gud Himmelen og Jorden."],
        "sv": ["I begynnelsen skapade Gud himmel och jord."],
        "cs": ["Na počátku stvořil Bůh nebe a zemi."],
        "bg": ["В началото Бог сътвори небето и земята."],
        "pl": ["Na początku stworzył Bóg niebo i ziemię."],
        "pt": ["No princípio criou Deus os céus e a terra."],
        "es": ["En el principio creó Dios los cielos y la tierra."],
        "fr": ["Au commencement, Dieu créa les cieux et la terre."],
        "el": ["Εν αρχή εποίησεν ο Θεός τον ουρανόν και την γην."],
        "he": ["בראשית ברא אלהים את השמים ואת הארץ."],
        "it": ["Nel principio Iddio creò i cieli e la terra."],
    },
}]


def seed_sample_books():
    """Create the sample book, section and chapter if they don't exist yet (runs at startup)."""
    for kind, items in (("books", SAMPLE_BOOKS), ("sections", SAMPLE_SECTIONS), ("chapters", SAMPLE_CHAPTERS)):
        for item in items:
            if repo.get(kind, item["id"]) is None:
                repo.put(kind, item["id"], item)


# --- Visibility ---------------------------------------------------------------

def in_allowed_group(user, item) -> bool:
    """True if `item` (a book or section) has no groups, or `user` is a system
    admin or an enabled member of one of them."""
    groups = item.get("groups") or []
    if not groups or user.get("system_admin"):
        return True
    for group_id in groups:
        membership = repo.get("memberships", membership_key(group_id, user["id"]))
        if membership and membership.get("enabled", True):
            return True
    return False


def visible_book(user, book_id) -> dict:
    """The book, or 404 if it doesn't exist or `user` may not see it."""
    book = repo.get("books", book_id)
    if not book or not in_allowed_group(user, book):
        fail(404, "Book not found")
    return book


def visible_section(user, section_id) -> dict:
    """The section, or 404 if it doesn't exist or `user` may not see it or its book."""
    section = repo.get("sections", section_id)
    if not section or not in_allowed_group(user, section):
        fail(404, "Section not found")
    book = repo.get("books", section["bookId"])
    if not book or not in_allowed_group(user, book):
        fail(404, "Section not found")
    return section


def visible_chapter(user, chapter_id) -> dict:
    """The chapter, or 404 if it doesn't exist or `user` may not see its section."""
    chapter = repo.get("chapters", chapter_id)
    if not chapter:
        fail(404, "Chapter not found")
    visible_section(user, chapter["sectionId"])
    return chapter


# --- Searching, sorting, paging -------------------------------------------------

def display_name(item, lang) -> str:
    """A book's or section's name in `lang`, else English, else its first name."""
    names = item.get("name") or {}
    return names.get(lang) or names.get("en") or next(iter(names.values()), "")


def natural_key(text: str) -> list:
    """Sort key that orders numbers by value: "Psalm 2" before "Psalm 10"."""
    return [int(part) if part.isdigit() else part.casefold() for part in re.split(r"(\d+)", text)]


def sort_key(item, name: str):
    """Items with an "order" first (by it), then the rest; ties by name, then ID."""
    order = item.get("order")
    return (order is None, order if order is not None else 0, natural_key(name), item["id"])


def name_matches(item, needle: str) -> bool:
    """True if `needle` (already casefolded) is part of the item's name in any language."""
    return not needle or any(needle in name.casefold() for name in (item.get("name") or {}).values())


def page_of(items, page, page_size) -> dict:
    start = (page - 1) * page_size
    return {"items": items[start:start + page_size], "total": len(items), "page": page, "page_size": page_size}


PageParam = Query(1, ge=1)
PageSizeParam = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE)


# --- Books --------------------------------------------------------------------

@router.get("/api/books")
def list_books(q: str = "", lang: str = "en", page: int = PageParam, page_size: int = PageSizeParam,
               user=Depends(current_user)):
    """Books the user may see, one page at a time.

    `q` matches (case-insensitively) part of the book's name in any language.
    `lang` is the reader's UI language; books are sorted by their name in it.
    """
    needle = q.strip().casefold()
    # "id" check: the books folder also holds non-book files such as bible_audio.json.
    books = [b for b in repo.list("books") if "id" in b and in_allowed_group(user, b) and name_matches(b, needle)]
    books.sort(key=lambda b: (display_name(b, lang).casefold(), b["id"]))
    return page_of(books, page, page_size)


@router.get("/api/books/{book_id}")
def get_book(book_id: str, user=Depends(current_user)):
    """One book. 404 if it doesn't exist or the user may not see it."""
    return visible_book(user, book_id)


# --- Sections -----------------------------------------------------------------

@router.get("/api/books/{book_id}/sections")
def list_sections(book_id: str, q: str = "", lang: str = "en", page: int = PageParam,
                  page_size: int = PageSizeParam, user=Depends(current_user)):
    """The book's sections the user may see, searched and paged like books;
    sorted by "order", then by name in `lang`."""
    visible_book(user, book_id)
    needle = q.strip().casefold()
    sections = [
        s for s in repo.list("sections")
        if s["bookId"] == book_id and in_allowed_group(user, s) and name_matches(s, needle)
    ]
    sections.sort(key=lambda s: sort_key(s, display_name(s, lang)))
    return page_of(sections, page, page_size)


@router.get("/api/sections/{section_id}")
def get_section(section_id: str, user=Depends(current_user)):
    """One section. 404 if it doesn't exist or the user may not see it."""
    return visible_section(user, section_id)


# --- Chapters -----------------------------------------------------------------

@router.get("/api/sections/{section_id}/chapters")
def list_chapters(section_id: str, page: int = PageParam, page_size: int = PageSizeParam,
                  user=Depends(current_user)):
    """The section's chapters, paged; sorted by "order", then by name
    (numbers by value). Without storage keys, like recordings."""
    visible_section(user, section_id)
    chapters = [c for c in repo.list("chapters") if c["sectionId"] == section_id]
    chapters.sort(key=lambda c: sort_key(c, c.get("name", "")))
    result = page_of(chapters, page, page_size)
    result["items"] = [public_recording(c) for c in result["items"]]
    return result


@router.get("/api/chapters/{chapter_id}")
def get_chapter(chapter_id: str, user=Depends(current_user)):
    """One chapter, including its sentences in every language."""
    return public_recording(visible_chapter(user, chapter_id))


@router.get("/api/chapters/{chapter_id}/audio/{lang}")
def get_chapter_audio(chapter_id: str, lang: str, user=Depends(current_user)):
    """Download/stream the chapter's audio file in `lang`."""
    chapter = visible_chapter(user, chapter_id)
    entry = chapter["audio"].get(lang)
    if not entry:
        fail(404, "No audio in this language")
    try:
        path = get_storage().get(entry["audio_key"])
    except FileNotFoundError:
        fail(404, "Audio missing")
    return FileResponse(path, filename=f"{chapter['name']} ({lang}){path.suffix}")
