"""Door to Door, Oct 23 changes:

1. The donor picks specific dates on a calendar instead of weekdays. The
   pickup map and planner only use those dates (not every matching weekday).
2. Door to Door is only for the service areas: Mandaue City, northern Cebu
   City (Banilad, Talamban, ...), Consolacion and Lapu-Lapu City.
"""
from datetime import date, datetime, timedelta

from schemas.physical_donation_schema import (
    MANILA, in_service_area, pickup_dates_label,
)
from services.pickup_planner import Donation, plan, planner_config
from tests.test_donation_batch import LINE, _report
from tests.test_pickup_days_and_runs import _door, _next
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _dated(rid, dates, **extra):
    body = _door(rid, None, **extra)
    body.pop("pickup_days")
    body["pickup_dates"] = [d.isoformat() for d in dates]
    return body


def test_service_areas():
    assert in_service_area("12 A. Del Rosario St., Centro, Mandaue City")
    assert in_service_area("Gaisano Country Mall, Banilad, Cebu City")
    assert in_service_area("Talamban, Cebu City", None)
    assert in_service_area("Poblacion Oriental, Consolacion, Cebu")
    assert in_service_area("Marigondon, Lapu-Lapu City")
    assert in_service_area("Mactan Newtown, Lapulapu")
    assert not in_service_area("Colon St, Cebu City")          # southern Cebu City
    assert not in_service_area("Poblacion, Talisay City")
    assert not in_service_area("1 Test St")


def test_donor_picks_specific_dates(api):
    client, t = api
    rid = _report(client, t)
    post = lambda body: client.post("/donations/batch", headers=t["donor"], json=body)
    mon, wed = _next(1), _next(3)

    assert post(_dated(rid, [])).status_code == 422              # at least one date
    r = post(_dated(rid, [_next(6)]))                           # Saturday: no pickups
    assert r.status_code == 422 and "does not pick up" in r.text
    yesterday = datetime.now(MANILA).date() - timedelta(days=1)
    assert post(_dated(rid, [yesterday])).status_code == 422
    assert post(_dated(rid, [mon + timedelta(days=63)])).status_code == 422

    b = ok(post(_dated(rid, [wed, mon, mon])), 201)
    assert b["pickup_dates"] == sorted([mon.isoformat(), wed.isoformat()])
    assert b["pickup_days"] == [1, 3]                            # weekdays kept for older screens
    assert b["pickup_days_label"] == pickup_dates_label(f"{mon},{wed}")


def _fake_map(monkeypatch, city=None, down=False):
    """Stand-in for the map lookup (Photon /reverse), so tests stay offline."""
    from fastapi import HTTPException
    import api.v1.donation_routes as routes

    def fake(path, params):
        if down:
            raise HTTPException(status_code=502, detail="down")
        props = {"name": "Somewhere", "city": city, "state": "Central Visayas"}
        return {"features": [{"properties": props}]}

    monkeypatch.setattr(routes, "_geocoder", fake)


def test_door_to_door_outside_the_service_area_is_refused(api, monkeypatch):
    client, t = api
    _fake_map(monkeypatch, city="Carcar")
    rid = _report(client, t)
    body = _dated(rid, [_next(1)], landmark="Carcar Diversion Road, Dapdap, Carcar, Cebu",
                  lat=10.1060, lng=123.6400)
    body["pickup_address"] = "CarCar"
    r = client.post("/donations/batch", headers=t["donor"], json=body)
    assert r.status_code == 422
    assert "Sorry" in r.text and "Carcar" in r.text and "Drop Off" in r.text
    # Typing "Mandaue" in the address does not override the landmark's place.
    body["pickup_address"] = "Mandaue City"
    assert client.post("/donations/batch", headers=t["donor"], json=body).status_code == 422


def test_map_detects_the_area_from_the_pin(api, monkeypatch):
    client, _ = api
    # The landmark text names no town; the pin is in Mandaue: covered.
    _fake_map(monkeypatch, city="Mandaue City")
    r = ok(client.get("/donations/location/coverage",
                      params={"text": "Jollibee", "lat": 10.33, "lng": 123.94}))
    assert r["covered"] is True and r["message"] is None

    # The pin is in Carcar: not covered, with a sorry message naming it.
    _fake_map(monkeypatch, city="Carcar")
    r = ok(client.get("/donations/location/coverage",
                      params={"text": "Jollibee", "lat": 10.10, "lng": 123.64}))
    assert r["covered"] is False and r["place"] == "Carcar" and "Sorry" in r["message"]

    # Map lookup down: the landmark text alone decides.
    _fake_map(monkeypatch, down=True)
    r = ok(client.get("/donations/location/coverage",
                      params={"text": "Talamban, Cebu City", "lat": 10.36, "lng": 123.91}))
    assert r["covered"] is True


def test_planner_uses_only_the_chosen_dates():
    today = date(2026, 10, 26)                                   # a Monday
    d = Donation(ref="A", lat=10.33, lng=123.94, days=[1, 3], items=[],
                 dates=[date(2026, 11, 2)], created_at=datetime(2026, 10, 20))
    out = plan([d], today=today, office=(10.33, 123.93), pickup_days=[1, 2, 3, 4, 5],
               start_hour=9, end_hour=17, cfg=planner_config())
    stop = out["stops"][0]
    assert stop["planned_date"] == "2026-11-02"                  # not Oct 26 / 28
    assert stop["dates"] == ["2026-11-02"] and stop["days"] == [1]
