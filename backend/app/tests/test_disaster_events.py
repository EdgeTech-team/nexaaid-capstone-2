"""NF-003 (Nov 2026): one form for several barangays.

POST /reports/batch saves one disaster report per barangay, grouped by a
disaster_events row; GET /reports/events/{id} is the event page donors pick
a barangay from. See services/disaster_events.py for the visibility rules.
"""
from decimal import Decimal

import pytest

from core import database
from models.audit_log_model import AuditLog
from models.barangay_model import Barangay
from models.disaster_event_model import DisasterEvent
from models.disaster_type_model import DisasterType
from models.report import DisasterReport, ReportFulfillment
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

FLOOD, OTHER = 1, 2
B1, B2, B3 = 1, 2, 3          # Barangay Test, Barangay Two, Barangay Three


@pytest.fixture()
def ev(api):
    db = database.SessionLocal()
    db.add(DisasterType(disaster_type_id=OTHER, type_name="Other"))
    db.add(Barangay(barangay_id=B3, barangay_name="Barangay Three", city_id=1))
    db.commit()
    db.close()
    return api


def row(barangay_id, families, rice=None, **extra):
    return {"barangay_id": barangay_id, "affected_families": families,
            "needs": [{"item_id": 1, "quantity": rice if rice is not None else families * 6}],
            **extra}


def body(*rows, **extra):
    return {"disaster_type_id": FLOOD, "description": "Flooded after heavy rain",
            "barangays": list(rows), **extra}


def three(client, t):
    return ok(client.post("/reports/batch", headers=t["unit"],
                          json=body(row(B1, 120), row(B2, 80), row(B3, 40))), 201)


def test_one_submission_makes_one_event_and_one_report_per_barangay(ev):
    client, t = ev
    out = three(client, t)
    event = out["event"]
    assert event["event_name"].startswith("Flood – ")
    reports = out["reports"]
    assert [r["barangay_id"] for r in reports] == [B1, B2, B3]
    for r, fam in zip(reports, (120, 80, 40)):
        assert r["event_id"] == event["event_id"]
        assert r["event_name"] == event["event_name"]
        assert r["status"] == "Pending"
        assert r["affected_families"] == fam
        # The app computes the amounts; the server stores them exactly.
        assert [(n["item_id"], n["quantity"]) for n in r["needs"]] == [(1, fam * 6)]
        assert r["estimated_quantity"] == fam * 6
        assert r["assistance_needed"] == f"Rice: {fam * 6} kg"
        assert r["description"] == "Flooded after heavy rain"

    db = database.SessionLocal()
    try:
        assert db.query(DisasterEvent).count() == 1
        log = db.query(AuditLog).filter(AuditLog.action == "SUBMIT DISASTER EVENT").one()
        assert log.entity_id == event["event_id"]
        assert str([r["report_id"] for r in reports]) in str(log.new_value)
        # The single-report path stays as it was: no event audit row.
        assert db.query(AuditLog).count() == 1
    finally:
        db.close()


def test_event_name_can_be_typed_and_sitios_belong_to_each_barangay(ev):
    client, t = ev
    out = ok(client.post("/reports/batch", headers=t["unit"], json=body(
        row(B1, 10, sitio_ids=[1]), row(B2, 5), event_name="  Typhoon   Tino ")), 201)
    assert out["event"]["event_name"] == "Typhoon Tino"
    assert out["reports"][0]["sitio_names"] == ["Sitio Test"]
    # Sitio 1 is in Barangay Test, not Barangay Two.
    r = client.post("/reports/batch", headers=t["unit"],
                    json=body(row(B1, 10), row(B2, 5, sitio_ids=[1])))
    assert r.status_code == 422 and "Barangay Two" in r.text


def test_one_bad_barangay_saves_nothing_and_names_it(ev):
    client, t = ev
    bad = row(B2, 80)
    bad["needs"] = [{"item_id": 1, "quantity": 10}, {"item_id": 1, "quantity": 5}]  # duplicate item
    r = client.post("/reports/batch", headers=t["unit"], json=body(row(B1, 120), bad))
    assert r.status_code == 422
    assert "Barangay Two" in r.json()["detail"]
    db = database.SessionLocal()
    try:
        assert db.query(DisasterReport).count() == 0
        assert db.query(DisasterEvent).count() == 0
    finally:
        db.close()


@pytest.mark.parametrize("payload", [
    body(row(B1, 10)),                                    # one barangay: use POST /reports
    body(row(B1, 10), row(B1, 20)),                       # the same barangay twice
    body(row(B1, 10), row(99, 20)),                       # unknown barangay
    body(row(B1, 10), row(B2, 0)),                        # 0 families
    body(row(B1, 10), {**row(B2, 5), "needs": []}),       # no needs
    body(row(B1, 10), row(B2, 5, rice=0)),                # a need without quantity
    {**body(row(B1, 10), row(B2, 5)), "disaster_type_id": OTHER},   # Other without its kind
])
def test_rejected_submissions(ev, payload):
    client, t = ev
    assert client.post("/reports/batch", headers=t["unit"], json=payload).status_code == 422


def test_other_type_keeps_the_typed_kind(ev):
    client, t = ev
    out = ok(client.post("/reports/batch", headers=t["unit"], json={
        **body(row(B1, 10), row(B2, 5)), "disaster_type_id": OTHER,
        "disaster_type_other": "Gas leak"}), 201)
    assert out["event"]["event_name"].startswith("Gas leak – ")
    assert {r["disaster_type_name"] for r in out["reports"]} == {"Gas leak"}


@pytest.mark.parametrize("who", ["admin", "csws", "donor", "brgy", "cmo", "drrmo"])
def test_only_the_disaster_unit_submits(ev, who):
    client, t = ev
    payload = body(row(B1, 10), row(B2, 5))
    assert client.post("/reports/batch", headers=t[who], json=payload).status_code == 403
    assert client.post("/reports/batch", json=payload).status_code == 401


def test_single_reports_are_unchanged(ev):
    client, t = ev
    r = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": FLOOD, "barangay_id": B1, "affected_families": 3,
        "needs": [{"item_id": 1, "quantity": 18}]}), 201)
    assert r["event_id"] is None and r["event_name"] is None


def _set_percent(report_id, pct):
    db = database.SessionLocal()
    try:
        f = db.query(ReportFulfillment).filter_by(report_id=report_id).one()
        f.fulfillment_percentage = Decimal(pct)
        db.commit()
    finally:
        db.close()


def test_event_percentage_is_weighted_by_families(ev):
    client, t = ev
    ids = [r["report_id"] for r in three(client, t)["reports"]]
    for rid in ids:
        ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    for rid, pct in zip(ids, (100, 25, 0)):
        _set_percent(rid, pct)

    event_id = ok(client.get(f"/reports/{ids[0]}", headers=t["admin"]))["event_id"]
    e = ok(client.get(f"/reports/events/{event_id}"))
    # (100 x 120 + 25 x 80 + 0 x 40) / 240 = 58.33, not the plain average 41.67.
    assert e["fulfillment_percentage"] == 58.33
    assert e["barangay_count"] == 3 and e["total_families"] == 240
    # Lowest fulfillment first; only reports under 100% take donations.
    assert [r["barangay"] for r in e["reports"]] == ["Barangay Three", "Barangay Two", "Barangay Test"]
    assert [r["donatable"] for r in e["reports"]] == [True, True, False]


def test_donors_and_guests_see_no_details_of_unvalidated_reports(ev):
    client, t = ev
    out = three(client, t)
    ids = [r["report_id"] for r in out["reports"]]
    ok(client.post(f"/reports/{ids[0]}/validate", headers=t["admin"], json={}))
    ok(client.post(f"/reports/{ids[1]}/validate", headers=t["admin"], json={}))
    event_id = out["event"]["event_id"]

    for headers in ({}, t["donor"]):
        e = ok(client.get(f"/reports/events/{event_id}", headers=headers))
        # Totals from the 2 validated reports only.
        assert e["barangay_count"] == 2 and e["total_families"] == 200
        assert e["awaiting_count"] == 1
        placeholder = [r for r in e["reports"] if r["status"] != "Validated"]
        assert placeholder == [{"barangay": "Barangay Three", "status": "Awaiting validation"}]
        for key in ("report_id", "affected_families", "sitios", "needs", "description"):
            assert key not in placeholder[0]

    # The reporter and CSWS staff see the pending report in full.
    for who in ("unit", "csws", "admin"):
        e = ok(client.get(f"/reports/events/{event_id}", headers=t[who]))
        pending = next(r for r in e["reports"] if r["status"] == "Pending")
        assert pending["report_id"] == ids[2] and pending["affected_families"] == 40
        assert pending["donatable"] is False

    assert client.get("/reports/events/999").status_code == 404


def test_withdrawn_reports_leave_the_event_page_for_donors(ev):
    client, t = ev
    out = three(client, t)
    rid = out["reports"][2]["report_id"]
    ok(client.post(f"/reports/{rid}/withdraw", headers=t["unit"], json={}))
    e = ok(client.get(f"/reports/events/{out['event']['event_id']}"))
    assert len(e["reports"]) == 2 and e["awaiting_count"] == 2


def test_lookups_publish_the_event_of_each_validated_report(ev):
    client, t = ev
    out = three(client, t)
    rid = out["reports"][0]["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    published = {r["id"]: r for r in ok(client.get("/lookups"))["validated_reports"]}
    assert published[rid]["event_id"] == out["event"]["event_id"]
    assert published[rid]["event_name"] == out["event"]["event_name"]
    # The guest landing page gets it too (GET /public/reports).
    public = {r["id"]: r for r in ok(client.get("/public/reports"))}
    assert public[rid]["event_id"] == out["event"]["event_id"]
    assert public[rid]["event_name"] == out["event"]["event_name"]


def test_a_donation_counts_only_for_its_own_report(ev):
    client, t = ev
    ids = [r["report_id"] for r in three(client, t)["reports"]]
    for rid in ids:
        ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": ids[1], "item_id": 1, "quantity": 60, "packaging": "Box",
        "handover_method": "Drop Off"}))
    pledged = {rid: ok(client.get(f"/reports/{rid}/needs"))["needs"][0]["pledged"] for rid in ids}
    assert pledged == {ids[0]: 0, ids[1]: 60, ids[2]: 0}
