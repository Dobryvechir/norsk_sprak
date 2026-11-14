"""Notifications: admin create/list/delete and who receives which notification."""

import datetime

from fastapi.testclient import TestClient

from app.helpers import new_id, utc_now_iso
from app.main import app
from app.repository import membership_key, repo
from app.routes.notifications import KIND, version_key
from app.security import create_token

client = TestClient(app)


def make_user(system_admin=False):
    user = {"id": new_id(), "email": f"{new_id()}@test.no", "password_hash": "-",
            "system_admin": system_admin, "enabled": True}
    repo.put("users", user["id"], user)
    return user, {"Authorization": "Bearer " + create_token(user)}


def make_group(privilege, *members):
    group = {"id": new_id(), "name": "G" + new_id()[:6], "created_at": utc_now_iso(), "privilege": privilege}
    repo.put("groups", group["id"], group)
    for user in members:
        repo.put("memberships", membership_key(group["id"], user["id"]),
                 {"group_id": group["id"], "user_id": user["id"], "role": "viewer", "enabled": True, "quota": {}})
    return group


def clear():
    for n in repo.list(KIND):
        repo.delete(KIND, n["id"])


def create(admin_headers, **fields):
    r = client.post("/api/admin/notifications", json={"text": "Hello", "severity": 1, **fields}, headers=admin_headers)
    assert r.status_code == 201, r.text
    return r.json()


def mine(headers, version=None):
    r = client.get("/api/me/notifications", params={"version": version} if version else {}, headers=headers)
    assert r.status_code == 200
    return [n["id"] for n in r.json()]


def test_version_key():
    assert version_key("0.1.0+1") == version_key("0.1") == (0, 1)
    assert version_key("1.10.0") > version_key("1.9.5")
    assert version_key("2.0.0-beta") == (2,)


def test_only_system_admin_manages():
    _, user_headers = make_user()
    assert client.get("/api/admin/notifications", headers=user_headers).status_code == 403
    assert client.post("/api/admin/notifications", json={"text": "x", "severity": 1}, headers=user_headers).status_code == 403


def test_create_list_delete():
    clear()
    _, admin = make_user(system_admin=True)
    created = create(admin, text="  Maintenance  ", severity=12, versionFrom="", datetimeTo="2030-01-01T10:00")
    assert created["text"] == "Maintenance"
    assert created["versionFrom"] is None
    assert created["datetimeTo"] == "2030-01-01T10:00:00+00:00"
    assert [n["id"] for n in client.get("/api/admin/notifications", headers=admin).json()] == [created["id"]]
    assert client.delete(f"/api/admin/notifications/{created['id']}", headers=admin).status_code == 200
    assert client.get("/api/admin/notifications", headers=admin).json() == []
    assert client.delete(f"/api/admin/notifications/{created['id']}", headers=admin).status_code == 404


def test_validation():
    _, admin = make_user(system_admin=True)
    post = lambda **f: client.post("/api/admin/notifications", json={"text": "x", "severity": 1, **f}, headers=admin)
    assert post(userId="nobody").status_code == 404
    assert post(groupId="nogroup").status_code == 404
    assert post(versionFrom="abc").status_code == 422
    assert post(versionFrom="2.0", versionTo="1.5").status_code == 422
    assert post(privilegeFrom=3, privilegeTo=1).status_code == 422
    assert post(datetimeFrom="tomorrow").status_code == 422
    assert post(text="   ").status_code == 422
    assert post(severity=-1).status_code == 422


def test_user_id_may_be_an_email():
    clear()
    _, admin = make_user(system_admin=True)
    user, _ = make_user()
    assert create(admin, userId=user["email"].upper())["userId"] == user["id"]


def test_targeting():
    clear()
    _, admin = make_user(system_admin=True)
    alice, alice_h = make_user()
    bob, bob_h = make_user()
    basic = make_group(0, alice)
    make_group(5, bob)
    everyone = create(admin)["id"]
    to_bob = create(admin, userId=bob["id"])["id"]
    to_basic = create(admin, groupId=basic["id"])["id"]
    low_privilege = create(admin, privilegeTo=1)["id"]
    high_privilege = create(admin, privilegeFrom=3, privilegeTo=7)["id"]
    # userId wins over groupId: only Bob, even though the group is Alice's.
    bob_in_basic = create(admin, userId=bob["id"], groupId=basic["id"])["id"]
    assert set(mine(alice_h)) == {everyone, to_basic, low_privilege}
    assert set(mine(bob_h)) == {everyone, to_bob, high_privilege, bob_in_basic}


def test_time_and_version_limits():
    clear()
    _, admin = make_user(system_admin=True)
    _, user_h = make_user()
    now = datetime.datetime.now(datetime.timezone.utc)
    iso = lambda delta: (now + delta).isoformat()
    current = create(admin, datetimeFrom=iso(-datetime.timedelta(hours=1)), datetimeTo=iso(datetime.timedelta(hours=1)))["id"]
    create(admin, datetimeTo=iso(-datetime.timedelta(minutes=1)))  # expired
    create(admin, datetimeFrom=iso(datetime.timedelta(minutes=5)))  # not yet
    old_apps = create(admin, versionTo="0.9")["id"]
    new_apps = create(admin, versionFrom="1.0", versionTo="1.2")["id"]
    assert set(mine(user_h, "0.1.0+1")) == {current, old_apps}
    assert set(mine(user_h, "1.2.0")) == {current, new_apps}
    assert set(mine(user_h, "1.3")) == {current}
    # Without a version only the time limits apply.
    assert set(mine(user_h)) == {current, old_apps, new_apps}


def test_most_severe_first():
    clear()
    _, admin = make_user(system_admin=True)
    _, user_h = make_user()
    ids = [create(admin, severity=s)["id"] for s in (2, 31, 15)]
    assert mine(user_h) == [ids[1], ids[2], ids[0]]
