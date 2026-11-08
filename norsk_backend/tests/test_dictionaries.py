"""Dictionary list and content, from the files in data/dictionaries."""

import json
import shutil
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

client = TestClient(app)
FOLDER = Path(settings.data_dir) / "dictionaries"
NB = {"a": {"or": "a", "tr": {"uk": "а"}}}


@pytest.fixture(autouse=True)
def empty_folder():
    shutil.rmtree(FOLDER, ignore_errors=True)
    FOLDER.mkdir(parents=True)


def test_list_has_only_dictionary_files_sorted_by_language():
    (FOLDER / "dict_nb.json").write_bytes(b'{"a": 1}')
    (FOLDER / "dict_en.json").write_bytes(b"{}")
    (FOLDER / "dict_.json").write_bytes(b"{}")
    (FOLDER / "dict_uk.txt").write_bytes(b"{}")
    (FOLDER / "other.json").write_bytes(b"{}")
    (FOLDER / "dict_de.json").mkdir()

    response = client.get("/api/dictionaries")

    assert response.status_code == 200
    assert response.json() == [
        {"lang": "en", "url": "/api/dictionary/en", "size": 2},
        {"lang": "nb", "url": "/api/dictionary/nb", "size": 8},
    ]


def test_list_is_empty_without_the_folder():
    shutil.rmtree(FOLDER)
    response = client.get("/api/dictionaries")
    assert response.status_code == 200
    assert response.json() == []


def test_listed_url_returns_the_file_as_json():
    (FOLDER / "dict_nb.json").write_text(json.dumps(NB, ensure_ascii=False), encoding="utf-8")

    url = client.get("/api/dictionaries").json()[0]["url"]
    response = client.get(url)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/json")
    assert response.json() == NB


def test_unknown_language_is_404():
    assert client.get("/api/dictionary/xx").status_code == 404


@pytest.mark.parametrize("path, status", [
    ("/api/dictionaries", 200),
    ("/api/dictionary/nb", 200),
    ("/api/dictionary/xx", 404),
])
def test_any_origin_can_read_without_login(path, status):
    (FOLDER / "dict_nb.json").write_bytes(b"{}")
    response = client.get(path, headers={"Origin": "https://anywhere.example"})
    assert response.status_code == status
    assert response.headers["access-control-allow-origin"] == "*"


@pytest.mark.parametrize("code", ["..%5C..%5Csecret", "..%2F..%2Fsecret", "nb.json", ".."])
def test_code_cannot_leave_the_folder(code):
    (FOLDER.parent / "secret.json").write_text("{}", encoding="utf-8")
    assert client.get(f"/api/dictionary/{code}").status_code == 404
