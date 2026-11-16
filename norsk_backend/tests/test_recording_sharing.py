"""Sharing recordings: the group's monthly share limit, who sees queued recordings,
who may delete, and AI recordings translated by the worker."""

from fastapi.testclient import TestClient

from app import worker
from app.helpers import new_id, utc_now_iso
from app.main import app
from app.quotas import share_limit
from app.repository import membership_key, repo
from app.routes import plans
from app.security import create_token
from tests.test_recording_lifecycle import DRIVE_ID, drive_media, make_admin_headers, make_group

client = TestClient(app)


def make_member(group, role="viewer"):
    user = {"id": new_id(), "email": f"{new_id()}@test.no", "password_hash": "-", "enabled": True}
    repo.put("users", user["id"], user)
    repo.put("memberships", membership_key(group["id"], user["id"]),
             {"group_id": group["id"], "user_id": user["id"], "role": role, "enabled": True, "quota": {}})
    return user, {"Authorization": "Bearer " + create_token(user)}


def own_texts(name="Leksjon"):
    return {"name": name, "language": "nb", "drive_id": DRIVE_ID, "mode": "manual", "size_bytes": 2_000_000,
            "start_ms": [0, 1000], "end_ms": [1000, 2000], "sentences": {"nb": ["Hei.", "Ha det."], "en": ["Hi.", "Bye."]}}


def test_share_limit_defaults_by_privilege():
    assert share_limit({"privilege": 0}) == 0
    assert share_limit({"privilege": 1}) == 100
    assert share_limit({"privilege": 7, "shareRecords": 5}) == 5

    basic = {"id": new_id(), "name": "B", "privilege": 0}
    other = {"id": new_id(), "name": "O", "privilege": 7}
    for g in (basic, other):
        repo.put("groups", g["id"], g)
    plans.ensure_group_share_records()
    assert repo.get("groups", basic["id"])["shareRecords"] == 0
    assert repo.get("groups", other["id"])["shareRecords"] == 100


def test_viewer_shares_within_the_monthly_limit(monkeypatch):
    drive_media(monkeypatch)
    group = make_group()
    group["shareRecords"] = 1
    repo.put("groups", group["id"], group)
    user, headers = make_member(group)
    url = f"/api/groups/{group['id']}/recordings"

    assert client.get(f"/api/groups/{group['id']}/share-allowance", headers=headers).json() == {
        "enabled": True, "limit": 1, "used": 0, "remaining": 1}
    response = client.post(url, headers=headers, json=own_texts())
    assert response.status_code == 202
    response = client.post(url, headers=headers, json=own_texts("Second"))
    assert response.status_code == 403 and response.json()["detail"] == "Monthly sharing quota exceeded"

    # Viewers can't use AI.
    assert client.post(url, headers=headers, json={**own_texts(), "mode": "ai"}).status_code == 403

    listed = client.get(url, headers=headers).json()
    assert len(listed) == 1
    assert listed[0]["author"] == user["email"].split("@")[0]
    assert listed[0]["size_bytes"] > 2_000_000
    assert listed[0]["source"] == "file"


def test_basic_group_can_not_share(monkeypatch):
    drive_media(monkeypatch)
    group = make_group()
    group.update(privilege=0, shareRecords=0)
    repo.put("groups", group["id"], group)
    _, headers = make_member(group)
    response = client.post(f"/api/groups/{group['id']}/recordings", headers=headers, json=own_texts())
    assert response.status_code == 403
    assert response.json()["detail"] == "Sharing recordings is not allowed in this group"


def test_author_or_admin_deletes(monkeypatch):
    drive_media(monkeypatch)
    group = make_group()
    _, author = make_member(group)
    _, other = make_member(group)
    _, group_admin = make_member(group, "admin")
    url = f"/api/groups/{group['id']}/recordings"

    rid = client.post(url, headers=author, json=own_texts()).json()["id"]
    assert client.delete(f"/api/recordings/{rid}", headers=other).status_code == 403
    assert client.delete(f"/api/recordings/{rid}", headers=author).status_code == 200

    rid = client.post(url, headers=author, json=own_texts()).json()["id"]
    assert client.delete(f"/api/recordings/{rid}", headers=group_admin).status_code == 200


def test_ai_recording_is_queued_translated_then_shown(monkeypatch):
    drive_media(monkeypatch)
    group = make_group()
    _, uploader = make_member(group, "uploader")
    _, viewer = make_member(group)
    url = f"/api/groups/{group['id']}/recordings"

    response = client.post(url, headers=uploader, json={
        "name": "AI", "language": "nb", "drive_id": DRIVE_ID, "mode": "ai", "translations": ["en", "nb", "uk"]})
    assert response.status_code == 202
    rid = response.json()["id"]
    assert repo.get("recordings", rid)["audio"]["nb"]["translate_to"] == ["en", "uk"]

    # Queued: only its author sees it.
    assert [r["id"] for r in client.get(url, headers=uploader).json()] == [rid]
    assert client.get(url, headers=viewer).json() == []
    assert client.get(f"/api/recordings/{rid}", headers=viewer).status_code == 404

    monkeypatch.setattr(worker, "transcribe", lambda path, provider, model, language: [
        {"index": 0, "text": "Hei.", "start_ms": 0, "end_ms": 900},
        {"index": 1, "text": "Ha det.", "start_ms": 1000, "end_ms": 2000}])
    monkeypatch.setattr(worker, "translate_sentences",
                        lambda texts, source, target: [f"{target}:{t}" for t in texts])
    while worker.run_once():
        pass

    shown = client.get(url, headers=viewer).json()
    assert [r["id"] for r in shown] == [rid]
    assert shown[0]["audio"]["nb"]["status"] == "ready"
    assert shown[0]["sentences"] == {"nb": ["Hei.", "Ha det."], "en": ["en:Hei.", "en:Ha det."],
                                     "uk": ["uk:Hei.", "uk:Ha det."]}
    usage = repo.get("usage", f"{rid}_nb")
    assert usage["translated_to"] == ["en", "uk"]


def test_translation_retries_missing_sentences():
    from app.translation import translate_sentences

    class Reply:
        def __init__(self, content):
            self.choices = [type("C", (), {"message": type("M", (), {"content": content})()})()]

    class FakeClient:
        def __init__(self):
            self.calls = 0
            self.chat = type("Chat", (), {"completions": self})()

        def create(self, model, response_format, temperature, messages):
            self.calls += 1
            if self.calls == 1:  # the batch: sentence "1" left out
                return Reply('{"0": "Hi."}')
            return Reply('{"0": "Bye."}')

    fake = FakeClient()
    assert translate_sentences(["Hei.", "Ha det."], "nb", "en", client=fake, model="m") == ["Hi.", "Bye."]
    assert fake.calls == 2
    assert translate_sentences(["Hei."], "nb", "nb", client=fake) == ["Hei."]
