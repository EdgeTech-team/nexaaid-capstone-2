"""Disaster type "Other" (Oct 2026): listed last in the dropdown, and a
report of that type says what kind of disaster it was (disaster_type_other,
migration e2b6d4a8c1f9). The screens show the typed name instead of Other."""
import pytest

from core import database
from models.disaster_type_model import DisasterType
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

FLOOD, OTHER, TYPHOON = 1, 2, 3
NEW = {"disaster_type_id": OTHER, "barangay_id": 1, "estimated_quantity": 50,
       "affected_families": 10, "assistance_needed": "Rice: 50 kg", "description": "Leak near the market"}


@pytest.fixture()
def types(api):
    db = database.SessionLocal()
    db.add_all([DisasterType(disaster_type_id=OTHER, type_name="Other"),
                DisasterType(disaster_type_id=TYPHOON, type_name="Typhoon")])
    db.commit()
    db.close()
    return api


def test_other_is_listed_last(types):
    client, _ = types
    names = [t["name"] for t in ok(client.get("/lookups"))["disaster_types"]]
    assert names == ["Flood", "Typhoon", "Other"]


def test_other_needs_the_kind_of_disaster(types):
    client, t = types
    assert client.post("/reports/", headers=t["unit"], json=NEW).status_code == 422
    assert client.post("/reports/", headers=t["unit"],
                       json={**NEW, "disaster_type_other": "  "}).status_code == 422
    assert client.post("/reports/", headers=t["unit"],
                       json={**NEW, "disaster_type_other": "x"}).status_code == 422

    r = ok(client.post("/reports/", headers=t["unit"],
                       json={**NEW, "disaster_type_other": "  Gas   leak "}), 201)
    assert r["disaster_type_id"] == OTHER
    assert r["disaster_type_other"] == "Gas leak"
    assert r["disaster_type_name"] == "Gas leak"


def test_any_other_type_clears_the_typed_kind(types):
    client, t = types
    r = ok(client.post("/reports/", headers=t["unit"],
                       json={**NEW, "disaster_type_id": FLOOD, "disaster_type_other": "Gas leak"}), 201)
    assert r["disaster_type_other"] is None and r["disaster_type_name"] == "Flood"

    # Edited to Other: the kind is required; edited back: it is cleared.
    rid = r["report_id"]
    assert client.put(f"/reports/{rid}/mine", headers=t["unit"], json=NEW).status_code == 422
    r = ok(client.put(f"/reports/{rid}/mine", headers=t["unit"],
                      json={**NEW, "disaster_type_other": "Gas leak"}))
    assert r["disaster_type_name"] == "Gas leak"
    r = ok(client.put(f"/reports/{rid}/mine", headers=t["unit"],
                      json={**NEW, "disaster_type_id": TYPHOON, "disaster_type_other": "Gas leak"}))
    assert r["disaster_type_other"] is None and r["disaster_type_name"] == "Typhoon"


def test_sms_report_of_type_other(types):
    client, t = types
    sms = {**NEW, "contact_number": "09171234567", "raw_message": "NEXAAID REPORT\nTYPE: Other - Gas leak"}
    assert client.post("/reports/sms", headers=t["admin"], json=sms).status_code == 422
    r = ok(client.post("/reports/sms", headers=t["admin"],
                       json={**sms, "disaster_type_other": "Gas leak"}), 201)
    assert r["report"]["disaster_type_other"] == "Gas leak"


def test_validated_report_shows_the_typed_kind(types):
    client, t = types
    rid = ok(client.post("/reports/", headers=t["unit"],
                         json={**NEW, "disaster_type_other": "Gas leak"}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))

    published = {r["id"]: r for r in ok(client.get("/lookups"))["validated_reports"]}
    assert published[rid]["disaster"] == "Gas leak"
    assert published[rid]["name"].startswith(f"#{rid} Gas leak - Barangay Test")
    public = {r["id"]: r for r in ok(client.get("/public/reports"))}
    assert public[rid]["disaster"] == "Gas leak"
