"""NF-004: barangays prone to a location-specific disaster type."""
from core import database
from models.report import Barangay, BarangayHazard, DisasterType
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _seed(extra=()):
    db = database.SessionLocal()
    try:
        db.add_all([
            DisasterType(disaster_type_id=80, type_name="Landslide", is_location_specific=True),
            DisasterType(disaster_type_id=81, type_name="General test type"),
            Barangay(barangay_id=40, barangay_name="Casili", city_id=1),
            Barangay(barangay_id=41, barangay_name="Bakilid", city_id=1),
        ])
        db.flush()
        db.add(BarangayHazard(barangay_id=40, disaster_type_id=80, source="test"))
        db.add_all(extra)
        db.commit()
    finally:
        db.close()


def test_lookups_say_which_disaster_types_are_location_specific(api):
    client, _ = api
    _seed()
    types = {t["id"]: t for t in ok(client.get("/lookups"))["disaster_types"]}
    assert types[80]["is_location_specific"] is True
    assert types[81]["is_location_specific"] is False


def test_without_a_type_no_barangay_is_flagged(api):
    client, _ = api
    _seed()
    rows = ok(client.get("/lookups/barangays"))
    assert not any(r["is_hazard_prone"] for r in rows)
    names = [r["name"] for r in rows]
    assert names == sorted(names)


def test_prone_barangays_come_first_for_a_location_specific_type(api):
    client, _ = api
    _seed()
    rows = ok(client.get("/lookups/barangays", params={"disaster_type_id": 80}))
    assert rows[0] == {"id": 40, "name": "Casili", "is_hazard_prone": True}
    assert 41 in {r["id"] for r in rows[1:]}             # still offered
    assert not any(r["is_hazard_prone"] for r in rows[1:])


def test_a_general_type_flags_nothing(api):
    client, _ = api
    _seed(extra=[BarangayHazard(barangay_id=41, disaster_type_id=81)])
    rows = ok(client.get("/lookups/barangays", params={"disaster_type_id": 81}))
    assert not any(r["is_hazard_prone"] for r in rows)


def test_an_unknown_disaster_type_is_404(api):
    client, _ = api
    assert client.get("/lookups/barangays",
                      params={"disaster_type_id": 99999}).status_code == 404
