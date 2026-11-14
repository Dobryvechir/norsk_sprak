"""Self-registration: checksum, signup, admin review, approve (with group) and reject."""

import hashlib
import itertools
from pathlib import Path

from fastapi.testclient import TestClient

from app.config import settings
from app.helpers import new_id, utc_now_iso
from app.main import app
from app.repository import membership_key, repo
from app.routes import signup as signup_module
from app.routes.signup import short_browser
from app.security import create_token

client = TestClient(app, client=("127.0.0.1", 50000))  # behind a local proxy
# Fast tests: easy proof of work and no "too fast" wait (tests below re-enable it).
signup_module.CAPTCHA_DIFFICULTY = 8
signup_module.CAPTCHA_MIN_SECONDS = 0
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"


def make_user(system_admin=False):
    user = {"id": new_id(), "email": f"{new_id()}@test.no", "password_hash": "-",
            "system_admin": system_admin, "enabled": True}
    repo.put("users", user["id"], user)
    return user, {"Authorization": "Bearer " + create_token(user)}


def headers(ip="10.0.0.1", ua=UA):
    return {"User-Agent": ua, "X-Forwarded-For": f"1.2.3.4, {ip}"}


def get_checksum(body, ip="10.0.0.1", ua=UA):
    r = client.post("/api/checksum", json=body, headers=headers(ip, ua))
    assert r.status_code == 200
    return r.json()["checksum"]


def solve(captcha):
    """What the page does when "I am not a robot" is pressed."""
    for n in itertools.count():
        digest = hashlib.sha256(f"{captcha['challenge']}:{n}".encode()).digest()
        if signup_module.leading_zero_bits(digest) >= captcha["difficulty"]:
            return n


def robot_fields(ip="10.0.0.1", ua=UA):
    captcha = client.post("/api/captcha", headers=headers(ip, ua)).json()
    return {"captchaToken": captcha["token"], "captchaSolution": solve(captcha)}


def signup(email, password="secret-password", info="Hello", ip="10.0.0.1"):
    body = {"email": email, "password": password, "info": info}
    return client.post("/api/signup", json={**body, "checksum": get_checksum(body, ip), **robot_fields(ip)},
                       headers=headers(ip))


def test_key_file_is_created():
    key_file = Path(settings.data_dir) / "key" / "key.txt"
    signup_module.checksum_key()
    assert key_file.is_file() and len(key_file.read_text().strip()) == 64


def test_wrong_or_foreign_checksum_is_rejected():
    body = {"email": f"{new_id()[:8]}@test.no", "password": "secret-password", "info": ""}
    good = get_checksum(body)
    bad = [
        ({**body, "checksum": "0" * 64}, headers()),
        ({**body, "info": "changed", "checksum": good}, headers()),
        ({**body, "checksum": good}, headers(ip="10.9.9.9")),             # other IP
        ({**body, "checksum": good}, headers(ua="Firefox/120 (Linux)")),  # other browser
    ]
    for payload, h in bad:
        r = client.post("/api/signup", json={**payload, "captchaToken": "x", "captchaSolution": 0}, headers=h)
        assert r.status_code == 400 and r.json()["detail"] == "Invalid checksum"
    assert client.post("/api/signup", json={**body, **robot_fields()}, headers=headers()).status_code == 422  # no checksum
    r = client.post("/api/signup", json={**body, "checksum": good, **robot_fields()}, headers=headers())
    assert r.status_code == 201


def test_robot_check():
    body = {"email": f"{new_id()[:8]}@test.no", "password": "secret-password", "info": ""}
    body["checksum"] = get_checksum(body)

    def attempt(**robot):
        return client.post("/api/signup", json={**body, **robot}, headers=headers())

    def failed(r):
        return r.status_code == 400 and r.json()["detail"] == "Robot check failed"

    captcha = client.post("/api/captcha", headers=headers()).json()
    good = {"captchaToken": captcha["token"], "captchaSolution": solve(captcha)}
    wrong = next(n for n in itertools.count() if signup_module.leading_zero_bits(
        hashlib.sha256(f"{captcha['challenge']}:{n}".encode()).digest()) < captcha["difficulty"])
    assert failed(attempt(captchaToken=captcha["token"], captchaSolution=wrong))
    assert attempt(captchaToken=captcha["token"]).status_code == 422          # no solution
    payload, signature = captcha["token"].split(".")
    assert failed(attempt(**{**good, "captchaToken": payload + "." + "0" * 64}))  # forged signature
    assert failed(attempt(**{**good, "website": "http://spam"}))                 # honeypot filled
    other_ip = robot_fields(ip="10.7.7.7")
    assert failed(attempt(**other_ip))                                            # solved elsewhere
    signup_module.CAPTCHA_MIN_SECONDS = 3
    try:
        assert failed(attempt(**robot_fields()))                                  # filled in too fast
    finally:
        signup_module.CAPTCHA_MIN_SECONDS = 0
    assert attempt(**good).status_code == 201
    body["email"] = f"{new_id()[:8]}@test.no"
    body["checksum"] = get_checksum({k: body[k] for k in ("email", "password", "info")})
    assert failed(attempt(**good))                                                # challenge reused


def test_captcha_expires():
    captcha = client.post("/api/captcha", headers=headers()).json()

    class FakeRequest:
        client = type("C", (), {"host": "127.0.0.1"})()
        headers = headers()

    late = int(bytes.fromhex(captcha["token"].split(".")[0]).decode().split('"t":')[1].split("}")[0])         + signup_module.CAPTCHA_MAX_SECONDS + 1
    assert not signup_module.verify_captcha(captcha["token"], solve(captcha), FakeRequest(), now=late)


def test_signup_review_approve_into_group_and_login():
    email = f"New.{new_id()[:8]}@Test.no"
    r = signup(email, ip="203.0.113.7")
    assert r.status_code == 201 and r.json()["status"] == "pending"
    cid = r.json()["id"]
    assert signup(email.lower()).status_code == 409  # already pending

    admin, admin_h = make_user(system_admin=True)
    _, plain_h = make_user()
    assert client.get("/api/admin/candidates", headers=plain_h).status_code == 403
    listed = next(c for c in client.get("/api/admin/candidates", headers=admin_h).json() if c["id"] == cid)
    assert listed["email"] == email.lower() and listed["info"] == "Hello"
    assert listed["ip"] == "203.0.113.7" and listed["browser"] == "Chrome 131 / Windows"
    assert listed["created_at"] and listed["status"] == "pending"
    assert "password_hash" not in listed and "password" not in listed

    group = {"id": new_id(), "name": "G", "created_at": utc_now_iso(), "ai": {}}
    repo.put("groups", group["id"], group)
    r = client.post(f"/api/admin/candidates/{cid}/approve", headers=admin_h,
                    json={"groupId": group["id"], "role": "uploader"})
    assert r.status_code == 200
    user_id = r.json()["id"]
    assert repo.get("candidate_users", cid) is None  # removed on approval
    assert repo.get("memberships", membership_key(group["id"], user_id))["role"] == "uploader"
    assert client.post(f"/api/admin/candidates/{cid}/approve", headers=admin_h).status_code == 404

    login = client.post("/api/auth/login", json={"email": email, "password": "secret-password"})
    assert login.status_code == 200 and login.json()["user"]["id"] == user_id
    assert signup(email).status_code == 409  # now a real user


def test_reject_removes_and_validation():
    admin, admin_h = make_user(system_admin=True)
    cid = signup(f"{new_id()[:8]}@test.no").json()["id"]
    r = client.post(f"/api/admin/candidates/{cid}/reject", headers=admin_h)
    assert r.status_code == 200 and r.json()["status"] == "rejected"
    assert repo.get("candidate_users", cid) is None
    assert client.post(f"/api/admin/candidates/{cid}/reject", headers=admin_h).status_code == 404
    assert signup("not-an-email").status_code == 422
    assert client.post("/api/checksum", json={"email": "a@b.no", "password": "short"}).status_code == 422


def test_limit_same_ip(monkeypatch):
    monkeypatch.setattr(signup_module, "LIMIT_SAME_API", 3)
    ip = "198.51.100.9"
    codes = [signup(f"{new_id()[:8]}@test.no", ip=ip).status_code for _ in range(4)]
    assert codes == [201] * 3 + [429]


def test_short_browser():
    assert short_browser("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Version/17.0 Mobile Safari/604.1") == "Safari 17 / iOS"
    assert short_browser("Dart/3.5 (dart:io)") == "Dart 3"
    assert short_browser("") == "unknown"


def test_signup_page_is_served():
    r = client.get("/signup")
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/html")
    assert all(p in r.text for p in ("api/signup", "api/checksum", "api/captcha"))


def test_limit_ip_per_day():
    ip = "198.51.100.77"
    # Two records from this IP on an earlier date don't count towards today's limit.
    for _ in range(2):
        cid = new_id()
        repo.put("candidate_users", cid, {"id": cid, "email": f"{cid[:8]}@test.no", "ip": ip,
                 "created_at": "2020-01-01T10:00:00+00:00", "status": "pending"})
    codes = [signup(f"{new_id()[:8]}@test.no", ip=ip).status_code for _ in range(6)]
    assert codes == [201] * signup_module.LIMIT_IP_PER_DAY + [429]
