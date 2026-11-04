"""Concerns Nov 4: "Other" is the last disaster type, and a report of type
"Other" must say what the disaster is. The typed name is shown instead of
"Other" on the report and on the donor cards."""
import core.database as database
from models.report import DisasterType
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

BASE = {"barangay_id": 1, "description": "Ground opened", "affected_families": 4,
        "assistance_needed": "Food", "estimated_quantity": 10}


def _other_type():
    db = database.SessionLocal()
    try:
        db.add(DisasterType(disaster_type_id=50, type_name="Other"))
        db.add(DisasterType(disaster_type_id=60, type_name="Typhoon"))
        db.commit()
    finally:
        db.close()
    return 50


def test_other_is_the_last_disaster_type(api):
    client, _ = api
    _other_type()
    names = [t["name"] for t in ok(client.get("/lookups"))["disaster_types"]]
    assert names[-1] == "Other"
    assert "Typhoon" in names


def test_other_needs_a_typed_name(api):
    client, t = api
    other = _other_type()
    r = client.post("/reports/", headers=t["unit"], json={**BASE, "disaster_type_id": other})
    assert r.status_code == 422
    r = client.post("/reports/", headers=t["unit"],
                    json={**BASE, "disaster_type_id": other, "other_disaster_type": "   "})
    assert r.status_code == 422


def test_the_typed_name_is_shown_instead_of_other(api):
    client, t = api
    other = _other_type()
    rep = ok(client.post("/reports/", headers=t["unit"], json={
        **BASE, "disaster_type_id": other, "other_disaster_type": "  Sinkhole  "}), 201)
    assert rep["other_disaster_type"] == "Sinkhole"
    assert rep["disaster_type_name"] == "Sinkhole"
    ok(client.post(f"/reports/{rep['report_id']}/validate", headers=t["admin"], json={}))
    card = next(r for r in ok(client.get("/lookups"))["validated_reports"]
                if r["id"] == rep["report_id"])
    assert card["disaster"] == "Sinkhole"
    assert "Sinkhole" in card["name"]


def test_a_named_type_drops_the_typed_name(api):
    client, t = api
    _other_type()
    rep = ok(client.post("/reports/", headers=t["unit"], json={
        **BASE, "disaster_type_id": 1, "other_disaster_type": "Sinkhole"}), 201)
    assert rep["other_disaster_type"] is None
    assert rep["disaster_type_name"] == "Flood"
