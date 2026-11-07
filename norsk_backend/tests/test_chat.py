"""Chat: group settings, photos, visibility, messages and limits, expiry, subgroups, family location."""

import base64
import datetime

from fastapi.testclient import TestClient

from app import chat
from app.helpers import new_id, utc_now_iso
from app.main import app
from app.repository import membership_key, repo
from app.security import create_token

client = TestClient(app)
PNG = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"0" * 100).decode()
LINK = {"kind": "picture", "name": "cat.jpg", "url": "https://drive.google.com/file/d/abc_1/view", "driveId": "abc_1"}


def make_user(photo=True, name=None, system_admin=False):
    user = {"id": new_id(), "email": f"{new_id()}@test.no", "password_hash": "-",
            "system_admin": system_admin, "enabled": True}
    repo.put("users", user["id"], user)
    headers = {"Authorization": "Bearer " + create_token(user)}
    if photo:
        assert client.put("/api/chat/profile", headers=headers,
                          json={"displayName": name or user["email"][:6], "photo": PNG}).status_code == 200
    return user, headers


def make_group(*members, **settings):
    group = {"id": new_id(), "name": "G" + new_id()[:4], "created_at": utc_now_iso(), "ai": {}, **settings}
    repo.put("groups", group["id"], group)
    for m in members:
        repo.put("memberships", membership_key(group["id"], m["id"]),
                 {"group_id": group["id"], "user_id": m["id"], "role": "viewer", "enabled": True, "quota": {}})
    return group


def post(headers, cid, text="hi", attachments=()):
    return client.post(f"/api/chat/conversations/{cid}/messages", headers=headers,
                       json={"text": text, "attachments": list(attachments)})


def test_group_settings_defaults_create_and_patch():
    admin, admin_h = make_user(system_admin=True)
    r = client.post("/api/admin/groups", headers=admin_h, json={"name": "Fam", "family": True, "chatPerDayKb": 10})
    group = r.json()
    assert group["family"] is True and group["chatPerDayKb"] == 10
    assert group["anonymous"] is False and group["subgroupLimitPerYear"] == 20 and group["expirationDays"] == 7
    r = client.patch(f"/api/groups/{group['id']}/settings", headers=admin_h, json={"anonymous": True})
    assert r.json()["anonymous"] is True and r.json()["chatPerDayKb"] == 10
    member, member_h = make_user()
    repo.put("memberships", membership_key(group["id"], member["id"]),
             {"group_id": group["id"], "user_id": member["id"], "role": "viewer", "enabled": True, "quota": {}})
    assert client.patch(f"/api/groups/{group['id']}/settings", headers=member_h, json={"anonymous": False}).status_code == 403
    assert client.get(f"/api/groups/{group['id']}/settings", headers=member_h).json()["anonymous"] is True


def test_anonymous_groups_are_not_in_chat_and_search_needs_a_shared_group():
    a, a_h = make_user(name="Alice")
    b, _ = make_user(name="Bobby")
    c, _ = make_user(name="Bobcat")
    shared = make_group(a, b)
    hidden = make_group(a, c, anonymous=True)

    ids = {c["id"] for c in client.get("/api/chat/conversations", headers=a_h).json()}
    assert f"g-{shared['id']}" in ids and f"g-{hidden['id']}" not in ids
    assert client.get(f"/api/chat/conversations/g-{hidden['id']}/messages", headers=a_h).status_code == 404

    found = client.get("/api/chat/users", headers=a_h, params={"q": "bob"}).json()
    assert [p["id"] for p in found] == [b["id"]]
    assert found[0]["groups"] == [{"id": shared["id"], "name": shared["name"]}]
    assert client.get(f"/api/chat/photos/{b['id']}", headers=a_h).status_code == 200
    assert client.get(f"/api/chat/photos/{c['id']}", headers=a_h).status_code == 404


def test_photo_is_required_and_validated():
    user, headers = make_user(photo=False)
    group = make_group(user)
    assert post(headers, f"g-{group['id']}").status_code == 403
    bad = base64.b64encode(b"GIF89a....").decode()
    assert client.put("/api/chat/profile", headers=headers, json={"displayName": "X", "photo": bad}).status_code == 422
    assert client.put("/api/chat/profile", headers=headers, json={"displayName": "X", "photo": PNG}).json()["hasPhoto"]
    assert post(headers, f"g-{group['id']}").status_code == 200


def test_messages_links_only_and_daily_limit():
    a, a_h = make_user()
    b, b_h = make_user()
    outsider, out_h = make_user()
    group = make_group(a, b, chatPerDayKb=1)
    cid = f"g-{group['id']}"
    first = post(a_h, cid, "hello", [LINK]).json()
    assert first["attachments"][0]["driveId"] == "abc_1"
    assert post(a_h, cid, "x", [{**LINK, "url": "https://evil.example/x"}]).status_code == 422
    assert post(a_h, cid, "  ").status_code == 422
    assert post(out_h, cid).status_code == 403

    messages = client.get(f"/api/chat/conversations/{cid}/messages", headers=b_h).json()
    assert [m["text"] for m in messages] == ["hello"]
    assert client.get(f"/api/chat/conversations/{cid}/messages", headers=b_h,
                      params={"since": first["createdAt"]}).json() == []

    assert post(a_h, cid, "y" * 1100).status_code == 403  # over 1 kB today
    assert post(b_h, cid, "b's own limit").status_code == 200


def test_old_messages_expire():
    a, a_h = make_user()
    group = make_group(a, expirationDays=1)
    cid = f"g-{group['id']}"
    post(a_h, cid, "new")
    old_day = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=2)
    repo.put("chat_messages", f"{cid}_{chat.day_of(old_day)}", {
        "conversationId": cid, "groupId": group["id"], "day": chat.day_of(old_day),
        "messages": [{"id": "1", "senderId": a["id"], "createdAt": chat.iso(old_day), "text": "old", "attachments": []}]})
    assert [m["text"] for m in client.get(f"/api/chat/conversations/{cid}/messages", headers=a_h).json()] == ["new"]
    assert chat.purge_expired(force=True) >= 1
    assert repo.get("chat_messages", f"{cid}_{chat.day_of(old_day)}") is None


def test_direct_chat_between_group_members():
    a, a_h = make_user()
    b, b_h = make_user()
    c, _ = make_user()
    group = make_group(a, b)
    conv = client.post("/api/chat/directs", headers=a_h, json={"groupId": group["id"], "userId": b["id"]}).json()
    assert conv["type"] == "direct" and conv["otherUserId"] == b["id"]
    assert client.post("/api/chat/directs", headers=a_h, json={"groupId": group["id"], "userId": c["id"]}).status_code == 403
    post(a_h, conv["id"], "psst")
    assert conv["id"] in {x["id"] for x in client.get("/api/chat/conversations", headers=b_h).json()}


def test_subgroups_invitations_and_yearly_limit():
    owner, owner_h = make_user()
    friend, friend_h = make_user()
    stranger, _ = make_user()
    group = make_group(owner, friend, subgroupLimitPerYear=1)
    sub = client.post("/api/chat/subgroups", headers=owner_h, json={"groupId": group["id"], "name": "Us"}).json()
    assert sub["isOwner"] and sub["type"] == "subgroup"
    assert client.post("/api/chat/subgroups", headers=owner_h,
                       json={"groupId": group["id"], "name": "More"}).status_code == 403
    sid = sub["id"][2:]
    assert client.post(f"/api/chat/subgroups/{sid}/invite", headers=owner_h,
                       json={"userIds": [stranger["id"]]}).status_code == 422
    assert client.post(f"/api/chat/subgroups/{sid}/invite", headers=friend_h,
                       json={"userIds": [friend["id"]]}).status_code == 403
    client.post(f"/api/chat/subgroups/{sid}/invite", headers=owner_h, json={"userIds": [friend["id"]]})
    assert post(friend_h, sub["id"]).status_code == 403  # not yet accepted
    assert [i["id"] for i in client.get("/api/chat/invitations", headers=friend_h).json()] == [sid]
    client.post(f"/api/chat/subgroups/{sid}/accept", headers=friend_h)
    assert post(friend_h, sub["id"]).status_code == 200
    # Deleting doesn't give the yearly allowance back.
    assert client.delete(f"/api/chat/subgroups/{sid}", headers=owner_h).status_code == 200
    assert client.post("/api/chat/subgroups", headers=owner_h,
                       json={"groupId": group["id"], "name": "Again"}).status_code == 403


def test_find_location_only_in_family_chats():
    mom, mom_h = make_user()
    kid, kid_h = make_user()
    group = make_group(mom, kid)
    plain = client.post("/api/chat/subgroups", headers=mom_h, json={"groupId": group["id"], "name": "P"}).json()
    family = client.post("/api/chat/subgroups", headers=mom_h,
                         json={"groupId": group["id"], "name": "F", "family": True}).json()
    for sub in (plain, family):
        client.post(f"/api/chat/subgroups/{sub['id'][2:]}/invite", headers=mom_h, json={"userIds": [kid["id"]]})
        client.post(f"/api/chat/subgroups/{sub['id'][2:]}/accept", headers=kid_h)

    path = f"/api/chat/conversations/{{}}/members/{kid['id']}/location"
    assert client.post(path.format(plain["id"]), headers=mom_h).status_code == 403
    assert client.post(path.format(family["id"]), headers=mom_h).json()["location"] is None
    assert client.get("/api/chat/status", headers=kid_h).json()["locationRequested"] is True
    client.put("/api/chat/location", headers=kid_h, json={"lat": 59.91, "lng": 10.75, "accuracy": 12})
    assert client.get("/api/chat/status", headers=kid_h).json()["locationRequested"] is False
    location = client.get(path.format(family["id"]), headers=mom_h).json()["location"]
    assert (location["lat"], location["lng"]) == (59.91, 10.75)
