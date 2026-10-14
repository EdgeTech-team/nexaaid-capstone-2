"""Oct 11 notes (Daniel): the CSWS Disaster Unit edits or withdraws its own
report before the Administrator validates it."""
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

NEW = {"disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": 50,
       "affected_families": 10, "assistance_needed": "Rice: 50 kg", "description": "Flood"}


def test_unit_edits_and_withdraws_its_pending_report(api):
    client, t = api
    rid = ok(client.post("/reports/", headers=t["unit"], json=NEW), 201)["report_id"]
    assert [r["report_id"] for r in ok(client.get("/reports/mine", headers=t["unit"]))] == [rid]

    edit = {**NEW, "barangay_id": 2, "affected_families": 25, "estimated_quantity": 80,
            "assistance_needed": "Rice: 80 kg"}
    assert client.put(f"/reports/{rid}/mine", headers=t["csws"], json=edit).status_code == 403  # not theirs
    r = ok(client.put(f"/reports/{rid}/mine", headers=t["unit"], json=edit))
    assert r["barangay_id"] == 2 and r["affected_families"] == 25 and r["status"] == "Pending"

    w = ok(client.post(f"/reports/{rid}/withdraw", headers=t["unit"], json={"reason": "Duplicate"}))
    assert w["status"] == "Cancelled"
    # Kept for the record, out of the validation queue, cannot be validated
    pending = ok(client.get("/reports/", headers=t["admin"], params={"status": "Pending"}))
    assert rid not in [x["report_id"] for x in pending]
    assert client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}).status_code == 409
    assert client.put(f"/reports/{rid}/mine", headers=t["unit"], json=NEW).status_code == 409
    assert ok(client.get("/reports/mine", headers=t["unit"]))[0]["status"] == "Cancelled"


def test_validated_reports_are_locked_and_rejected_ones_can_be_fixed(api):
    client, t = api
    rid = ok(client.post("/reports/", headers=t["unit"], json=NEW), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/reject", headers=t["admin"], json={"rejection_reason": "Wrong barangay"}))
    fixed = ok(client.put(f"/reports/{rid}/mine", headers=t["unit"], json={**NEW, "barangay_id": 2}))
    assert fixed["status"] == "Pending" and fixed["rejection_reason"] is None

    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    assert client.put(f"/reports/{rid}/mine", headers=t["unit"], json=NEW).status_code == 409
    assert client.post(f"/reports/{rid}/withdraw", headers=t["unit"], json={}).status_code == 409
