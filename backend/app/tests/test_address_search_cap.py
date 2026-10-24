"""F-19: at most 60 calls a minute go to the free public Photon server,
across all users. Cached answers are not counted, /location/reverse shares
the cap, and searches work again after the minute."""
import httpx

from api.v1 import donation_routes
from tests.test_donation_batch import _FakeResponse
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _fake_photon(monkeypatch):
    calls = []

    def fake_request(method, url, **kwargs):
        calls.append(url)
        return _FakeResponse({"features": []})

    monkeypatch.setattr(httpx, "request", fake_request)
    return calls


def _clock(monkeypatch, start=1000.0):
    now = [start]
    monkeypatch.setattr(donation_routes, "_geo_clock", lambda: now[0])
    return now


def test_photon_calls_stop_at_the_cap_and_resume_after_a_minute(api, monkeypatch):
    client, _ = api
    calls = _fake_photon(monkeypatch)
    now = _clock(monkeypatch)
    for i in range(donation_routes._GEO_CALLS_PER_MINUTE):
        ok(client.get(f"/donations/location/autocomplete?q=street {i}"))
    assert len(calls) == 60

    r = client.get("/donations/location/autocomplete?q=one more street")
    assert r.status_code == 503 and r.headers["Retry-After"]
    assert "Type the full address yourself" in r.json()["detail"]
    assert client.get("/donations/location/reverse?lat=10.3&lng=123.9").status_code == 503
    assert len(calls) == 60                              # Photon was not called

    now[0] += 61
    ok(client.get("/donations/location/autocomplete?q=one more street"))
    ok(client.get("/donations/location/reverse?lat=10.3&lng=123.9"))
    assert len(calls) == 62


def test_cached_answers_are_not_counted(api, monkeypatch):
    client, _ = api
    calls = _fake_photon(monkeypatch)
    _clock(monkeypatch)
    for _ in range(100):
        ok(client.get("/donations/location/autocomplete?q=ayala center"))
    assert len(calls) == 1
    # Even with the cap used up, a cached search is still answered.
    for i in range(59):
        ok(client.get(f"/donations/location/autocomplete?q=street {i}"))
    assert client.get("/donations/location/autocomplete?q=new place").status_code == 503
    ok(client.get("/donations/location/autocomplete?q=ayala center"))


def test_reverse_shares_the_cap(api, monkeypatch):
    client, _ = api
    calls = _fake_photon(monkeypatch)
    _clock(monkeypatch)
    for i in range(60):
        ok(client.get(f"/donations/location/reverse?lat=10.{i:02d}&lng=123.9"))
    assert client.get("/donations/location/autocomplete?q=ayala").status_code == 503
    assert len(calls) == 60
