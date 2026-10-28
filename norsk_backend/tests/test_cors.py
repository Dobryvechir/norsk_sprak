"""CORS: preflight (OPTIONS) and headers for allowed and other origins."""

import re

from fastapi.middleware.cors import CORSMiddleware
from fastapi.testclient import TestClient
from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Route

from app.main import allowed_origin_regex


def make_client(origins):
    """A tiny app with the same CORS setup as app.main, for the given ALLOWED_ORIGINS."""
    async def endpoint(request):
        return PlainTextResponse("ok")

    app = Starlette(routes=[Route("/x", endpoint, methods=["GET", "POST", "PATCH", "PUT", "DELETE"])])
    app.add_middleware(CORSMiddleware, allow_origin_regex=allowed_origin_regex(origins),
                       allow_methods=["*"], allow_headers=["*"], expose_headers=["Content-Disposition"])
    return TestClient(app)


def preflight(client, origin, method="PATCH"):
    return client.options("/x", headers={"Origin": origin, "Access-Control-Request-Method": method,
                                         "Access-Control-Request-Headers": "authorization,content-type"})


def test_bare_host_allows_any_port_and_scheme():
    pattern = allowed_origin_regex(["localhost"])
    for origin in ("http://localhost", "http://localhost:52314", "https://localhost:8443"):
        assert re.fullmatch(pattern, origin)
    for origin in ("http://localhost.evil.com", "http://evil.com", "http://notlocalhost:80"):
        assert not re.fullmatch(pattern, origin)


def test_full_origin_must_match_exactly():
    pattern = allowed_origin_regex(["https://app.example.com"])
    assert re.fullmatch(pattern, "https://app.example.com")
    assert not re.fullmatch(pattern, "http://app.example.com")
    assert not re.fullmatch(pattern, "https://app.example.com:444")


def test_preflight_for_every_non_get_method_from_allowed_origin():
    client = make_client(["localhost"])
    for method in ("POST", "PUT", "PATCH", "DELETE"):
        response = preflight(client, "http://localhost:5000", method)
        assert response.status_code == 200
        assert response.headers["access-control-allow-origin"] == "http://localhost:5000"
        assert method in response.headers["access-control-allow-methods"]


def test_other_origins_get_no_cors_headers():
    client = make_client(["localhost"])
    assert preflight(client, "https://evil.example").status_code == 400
    response = client.get("/x", headers={"Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in response.headers


def test_actual_request_from_allowed_origin_exposes_content_disposition():
    response = make_client(["localhost"]).get("/x", headers={"Origin": "http://localhost:5000"})
    assert response.headers["access-control-allow-origin"] == "http://localhost:5000"
    assert "content-disposition" in response.headers["access-control-expose-headers"].lower()


def test_no_origins_configured_allows_none():
    assert allowed_origin_regex([]) is None
    assert preflight(make_client([]), "http://localhost:5000").status_code == 400
