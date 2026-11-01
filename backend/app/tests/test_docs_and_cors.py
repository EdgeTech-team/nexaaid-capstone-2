"""F-20: API documentation only when APP_ENV=development, and CORS without
credentials (the app sends a Bearer token, never cookies)."""
from fastapi import FastAPI
from fastapi.testclient import TestClient

import main
from main import api_docs_settings

DOCS = ("/docs", "/redoc", "/openapi.json")


def test_docs_are_hidden_unless_development():
    assert api_docs_settings("production") == {
        "docs_url": None, "redoc_url": None, "openapi_url": None}
    assert api_docs_settings("staging")["openapi_url"] is None
    prod = TestClient(FastAPI(**api_docs_settings("production")))
    for path in DOCS:
        assert prod.get(path).status_code == 404
    dev = TestClient(FastAPI(**api_docs_settings("development")))
    for path in DOCS:
        assert dev.get(path).status_code == 200


def test_cors_allows_the_site_and_localhost_without_credentials():
    client = TestClient(main.app)
    for origin in ("https://nexaaid1.netlify.app", "http://localhost:5555",
                   "http://127.0.0.1:8080"):
        r = client.get("/", headers={"Origin": origin})
        assert r.headers["access-control-allow-origin"] == origin
        assert "access-control-allow-credentials" not in r.headers
        pre = client.options("/reports/", headers={
            "Origin": origin, "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization,content-type"})
        assert pre.status_code == 200
        assert "access-control-allow-credentials" not in pre.headers
    r = client.get("/", headers={"Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in r.headers
