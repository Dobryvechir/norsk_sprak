"""Books, sections and chapters: visibility, search in every language, ordering, paging, sample data."""

from pathlib import Path

from fastapi.testclient import TestClient

from app.config import settings
from app.helpers import LANGUAGES, new_id, utc_now_iso
from app.main import app
from app.repository import membership_key, repo
from app.routes.books import seed_sample_books
from app.security import create_token

client = TestClient(app)


def make_user(system_admin=False):
    user = {"id": new_id(), "email": f"{new_id()}@test.no", "password_hash": "-",
            "system_admin": system_admin, "enabled": True}
    repo.put("users", user["id"], user)
    return user, {"Authorization": "Bearer " + create_token(user)}


def make_group(member=None):
    group = {"id": new_id(), "name": "G", "created_at": utc_now_iso(), "ai": {}}
    repo.put("groups", group["id"], group)
    if member:
        repo.put("memberships", membership_key(group["id"], member["id"]),
                 {"group_id": group["id"], "user_id": member["id"], "role": "viewer", "enabled": True, "quota": {}})
    return group


def make_book(names, groups=()):
    book = {"id": new_id(), "name": names, "author": "A", "audioLanguages": ["nb"], "groups": list(groups), "icon": ""}
    repo.put("books", book["id"], book)
    return book


def search(headers, **params):
    response = client.get("/api/books", headers=headers, params=params)
    assert response.status_code == 200
    return response.json()


def test_group_books_are_visible_to_members_and_system_admins_only():
    user, headers = make_user()
    _, admin_headers = make_user(system_admin=True)
    tag = new_id()
    mine = make_book({"en": f"Mine {tag}"}, [make_group(member=user)["id"]])
    other = make_book({"en": f"Other {tag}"}, [make_group()["id"]])
    public = make_book({"en": f"Public {tag}"})

    assert {b["id"] for b in search(headers, q=tag)["items"]} == {mine["id"], public["id"]}
    assert {b["id"] for b in search(admin_headers, q=tag)["items"]} == {mine["id"], other["id"], public["id"]}
    assert client.get(f"/api/books/{other['id']}", headers=headers).status_code == 404
    assert client.get(f"/api/books/{public['id']}", headers=headers).status_code == 200


def test_search_matches_any_language_case_insensitively():
    _, headers = make_user()
    tag = new_id()
    book = make_book({"en": "Peace", "nb": f"Fred {tag}", "uk": f"МИР {tag}"})

    assert [b["id"] for b in search(headers, q=f"fred {tag}")["items"]] == [book["id"]]
    assert [b["id"] for b in search(headers, q=f"мир {tag}")["items"]] == [book["id"]]


def test_pagination_and_sorting_by_name_in_reader_language():
    _, headers = make_user()
    tag = new_id()
    for letter in "edcba":
        make_book({"en": f"{tag} {letter}", "nb": f"{tag} {'abcde'['abcde'.index(letter) * -1 - 1]}"})

    first = search(headers, q=tag, page=1, page_size=2, lang="en")
    assert first["total"] == 5 and first["page"] == 1 and first["page_size"] == 2
    assert [b["name"]["en"] for b in first["items"]] == [f"{tag} a", f"{tag} b"]
    last = search(headers, q=tag, page=3, page_size=2, lang="en")
    assert [b["name"]["en"] for b in last["items"]] == [f"{tag} e"]
    # Sorted by the Norwegian names when the reader's language is nb.
    assert search(headers, q=tag, page_size=1, lang="nb")["items"][0]["name"]["nb"] == f"{tag} a"


def test_books_are_read_only():
    _, headers = make_user(system_admin=True)
    for method in ("post", "put", "patch", "delete"):
        assert getattr(client, method)("/api/books/bible", headers=headers).status_code == 405


def test_sample_bible_has_every_language():
    seed_sample_books()
    _, headers = make_user()
    bible = client.get("/api/books/bible", headers=headers).json()
    assert set(bible["name"]) == set(LANGUAGES)
    assert set(bible["audioLanguages"]) == set(LANGUAGES)
    assert bible["groups"] == []

    sections = client.get("/api/books/bible/sections", headers=headers).json()["items"]
    assert sections[0]["id"] == "bible-genesis" and set(sections[0]["name"]) == set(LANGUAGES)
    chapters = client.get("/api/sections/bible-genesis/chapters", headers=headers).json()["items"]
    assert chapters[0]["name"] == "Genesis 1"
    assert set(chapters[0]["sentences"]) == set(LANGUAGES)
    assert len(chapters[0]["sentences"]["nb"]) == 3


def make_section(book_id, names, groups=(), order=None):
    section = {"id": new_id(), "bookId": book_id, "name": names, "author": "", "audioLanguages": ["nb"],
               "groups": list(groups), "icon": ""}
    if order is not None:
        section["order"] = order
    repo.put("sections", section["id"], section)
    return section


def make_chapter(section_id, name, with_audio=False):
    chapter = {"id": new_id(), "sectionId": section_id, "name": name, "audio": {}, "sentences": {"nb": ["I begynnelsen."]}}
    if with_audio:
        key = f"chapters/{chapter['id']}_nb.mp3"
        path = Path(settings.data_dir) / "audio" / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fake audio")
        chapter["audio"]["nb"] = {"audio_key": key, "status": "ready", "error": None, "duration_seconds": 2.0,
                                  "start_ms": [0], "end_ms": [1500]}
    repo.put("chapters", chapter["id"], chapter)
    return chapter


def test_sections_are_searched_ordered_and_paged_within_their_book():
    _, headers = make_user()
    book = make_book({"en": "B"})
    other_book = make_book({"en": "Other"})
    make_section(other_book["id"], {"en": "Genesis"})
    exodus = make_section(book["id"], {"en": "Exodus", "nb": "Andre Mosebok"}, order=2)
    genesis = make_section(book["id"], {"en": "Genesis", "nb": "Første Mosebok"}, order=1)
    appendix = make_section(book["id"], {"en": "Appendix"})  # no order: listed last

    url = f"/api/books/{book['id']}/sections"
    body = client.get(url, headers=headers).json()
    assert [s["id"] for s in body["items"]] == [genesis["id"], exodus["id"], appendix["id"]]
    assert body["items"][0]["bookId"] == book["id"]
    assert [s["id"] for s in client.get(url, headers=headers, params={"q": "mosebok"}).json()["items"]] == [genesis["id"], exodus["id"]]
    assert client.get(url, headers=headers, params={"page": 2, "page_size": 2}).json()["items"][0]["id"] == appendix["id"]


def test_sections_and_chapters_follow_book_and_section_visibility():
    user, headers = make_user()
    hidden_book = make_book({"en": "Hidden"}, [make_group()["id"]])
    section_in_hidden_book = make_section(hidden_book["id"], {"en": "S"})
    open_book = make_book({"en": "Open"})
    hidden_section = make_section(open_book["id"], {"en": "Members only"}, [make_group()["id"]])
    my_section = make_section(open_book["id"], {"en": "Mine"}, [make_group(member=user)["id"]])
    chapter = make_chapter(hidden_section["id"], "Kapittel 1")

    assert client.get(f"/api/books/{hidden_book['id']}/sections", headers=headers).status_code == 404
    assert client.get(f"/api/sections/{section_in_hidden_book['id']}", headers=headers).status_code == 404
    listed = client.get(f"/api/books/{open_book['id']}/sections", headers=headers).json()["items"]
    assert [s["id"] for s in listed] == [my_section["id"]]
    assert client.get(f"/api/sections/{hidden_section['id']}/chapters", headers=headers).status_code == 404
    assert client.get(f"/api/chapters/{chapter['id']}", headers=headers).status_code == 404


def test_chapters_are_listed_in_natural_order_and_playable():
    _, headers = make_user()
    section = make_section(make_book({"en": "B"})["id"], {"en": "Psalms"})
    for n in (10, 2, 1):
        make_chapter(section["id"], f"Salme {n}")
    playable = make_chapter(section["id"], "Salme 3", with_audio=True)

    body = client.get(f"/api/sections/{section['id']}/chapters", headers=headers).json()
    assert [c["name"] for c in body["items"]] == ["Salme 1", "Salme 2", "Salme 3", "Salme 10"]
    assert body["total"] == 4

    chapter = client.get(f"/api/chapters/{playable['id']}", headers=headers).json()
    assert chapter["sectionId"] == section["id"]
    assert "audio_key" not in chapter["audio"]["nb"] and chapter["audio"]["nb"]["end_ms"] == [1500]
    assert client.get(f"/api/chapters/{playable['id']}/audio/nb", headers=headers).status_code == 200
    assert client.get(f"/api/chapters/{playable['id']}/audio/en", headers=headers).status_code == 404


def test_sections_and_chapters_are_read_only():
    _, headers = make_user(system_admin=True)
    for path in ("/api/sections/x", "/api/chapters/x", "/api/books/bible/sections"):
        for method in ("post", "put", "patch", "delete"):
            assert getattr(client, method)(path, headers=headers).status_code == 405
