"""Door to Door geofence (Oct 2026): pickups only in Mandaue and its
neighbours, checked by the OSM city of the pin."""
import pytest

from services.pickup_geofence import check_pin, city_allowed, pickup_cities


def _km(lat, lng):
    return 5.0


@pytest.mark.parametrize("city", ["Mandaue", "Mandaue City", "Lapu-Lapu", "Lapu-Lapu City",
                                  "Consolacion", "Cebu City"])
def test_neighbouring_cities_are_accepted(city):
    assert city_allowed(city)


@pytest.mark.parametrize("city", ["Talisay", "Minglanilla", "Compostela", "Liloan", None, ""])
def test_other_places_are_not(city):
    assert not city_allowed(city)


def test_outside_pin_gets_a_message_naming_the_area():
    r = check_pin(10.26, 123.80, lambda lat, lng: "Minglanilla", _km, 20)
    assert r == {
        "allowed": False, "city": "Minglanilla", "checked_by": "city",
        "message": "CSWS picks up only in Mandaue, Lapu-Lapu, Consolacion, Cebu City, "
                   "not Minglanilla. Choose a landmark there, or choose Drop Off.",
    }


def test_geocoder_down_falls_back_to_distance():
    def down(lat, lng):
        raise TimeoutError

    assert check_pin(10.33, 123.93, down, lambda a, b: 8.0, 20)["allowed"]
    far = check_pin(10.9, 124.0, down, lambda a, b: 64.0, 20)
    assert not far["allowed"] and far["checked_by"] == "distance"


def test_the_list_comes_from_env(monkeypatch):
    monkeypatch.setenv("PICKUP_CITIES", "Mandaue, Liloan")
    assert pickup_cities() == ["Mandaue", "Liloan"]
    assert city_allowed("Liloan") and not city_allowed("Cebu City")


def test_donation_outside_the_area_is_refused(monkeypatch):
    """Through the API: a Door to Door pin in Minglanilla is refused with
    the message, before anything is saved."""
    import api.v1.donation_routes as routes
    from fastapi import HTTPException
    from types import SimpleNamespace

    monkeypatch.setattr(routes, "_reverse_city", lambda lat, lng: "Minglanilla")
    payload = SimpleNamespace(handover_method="Door to Door", pickup_lat=10.26, pickup_lng=123.80)
    with pytest.raises(HTTPException) as e:
        routes._check_service_area(payload)
    assert e.value.status_code == 422 and "Minglanilla" in e.value.detail

    monkeypatch.setattr(routes, "_reverse_city", lambda lat, lng: "Lapu-Lapu")
    routes._check_service_area(payload)          # accepted
    routes._check_service_area(SimpleNamespace(handover_method="Drop Off", pickup_lat=None,
                                               pickup_lng=None))
