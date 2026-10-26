"""
F-15: items typed in on a donation ("Something else") wait for CSWS Main
Office or the Administrator before they are in any dropdown. The donation
keeps them either way. Items the Disaster Unit adds to a report are added
at once. Typed names are matched exactly (no LIKE wildcards), and a retired
item's name can be typed twice without a 500.
"""
import core.database as database
from models.audit_log_model import AuditLog
from models.physical_donation_model import PhysicalDonation
from tests.test_lookups_access import _validated
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _guest(client, rid, name, unit="pcs"):
    return ok(client.post("/donations/", json={
        "report_id": rid, "packaging": "Pack", "handover_method": "Drop Off", "quantity": 3,
        "other_item_name": name, "other_item_unit": unit,
        "guest_donor": {"full_name": "Gina Guest", "contact_number": "09171234567", "consent": True},
    }))


def _listed(client, headers=None):
    return [i["name"] for i in ok(client.get("/lookups", headers=headers or {}))["items"]]


def test_a_guest_item_waits_for_review_and_is_hidden(api):
    client, t = api
    rid = _validated(client, t)
    first = _guest(client, rid, "Diapers")
    again = _guest(client, rid, "diapers")
    assert first["item_id"] == again["item_id"] != 1          # reused, still waiting
    assert "Diapers (pcs)" not in _listed(client)
    assert "Diapers (pcs)" not in _listed(client, t["csws"])
    waiting = ok(client.get("/items/pending", headers=t["csws"]))
    assert [(w["item_name"], w["donation_lines"]) for w in waiting] == [("Diapers", 2)]
    # Only CSWS Main Office and the Administrator review.
    assert client.get("/items/pending").status_code == 401
    for who in ("donor", "unit", "cmo", "drrmo", "brgy"):
        assert client.get("/items/pending", headers=t[who]).status_code == 403, who
    assert ok(client.get("/items/pending", headers=t["admin"]))


def test_approve_with_a_corrected_name_lists_it_and_logs_it(api):
    client, t = api
    rid = _validated(client, t)
    item_id = _guest(client, rid, "diapers baby")["item_id"]
    bigas = _guest(client, rid, "Bigas", "kg")["item_id"]
    # A name that already exists is refused (merging is not available yet).
    r = client.post(f"/items/{bigas}/approve", headers=t["csws"], json={"item_name": "rice"})
    assert r.status_code == 409

    done = ok(client.post(f"/items/{item_id}/approve", headers=t["csws"],
                          json={"item_name": "Baby Diapers"}))
    assert done == {"item_id": item_id, "item_name": "Baby Diapers", "pending_review": False}
    assert "Baby Diapers (pcs)" in _listed(client)
    assert [w["item_name"] for w in ok(client.get("/items/pending", headers=t["admin"]))] == ["Bigas"]
    assert client.post(f"/items/{item_id}/approve", headers=t["csws"], json={}).status_code == 404
    db = database.SessionLocal()
    try:
        log = db.query(AuditLog).filter(AuditLog.action == "APPROVE ITEM").one()
        assert log.old_value["item_name"] == "diapers baby"
        assert log.new_value["item_name"] == "Baby Diapers"
    finally:
        db.close()


def test_reject_keeps_the_donation_and_a_retired_name_can_be_typed_again(api):
    client, t = api
    rid = _validated(client, t)
    gift = _guest(client, rid, "Spam Item")
    ok(client.post(f"/items/{gift['item_id']}/reject", headers=t["admin"], json={}))
    assert ok(client.get("/items/pending", headers=t["admin"])) == []
    assert "Spam Item (pcs)" not in _listed(client)
    db = database.SessionLocal()
    try:
        row = db.get(PhysicalDonation, gift["donation_id"])
        assert row.item_id == gift["item_id"]                   # the donation keeps it
    finally:
        db.close()
    # Typing the rejected name again: a new waiting item, the same one twice.
    one = _guest(client, rid, "Spam Item")["item_id"]
    two = _guest(client, rid, "Spam Item")["item_id"]
    assert one == two != gift["item_id"]


def test_wildcards_in_a_typed_name_match_nothing_else(api):
    client, t = api
    rid = _validated(client, t)
    for typed in ("Ric_", "%"):
        assert _guest(client, rid, typed)["item_id"] != 1, typed   # 1 = Rice


def test_items_the_disaster_unit_adds_to_a_report_are_listed_at_once(api):
    client, t = api
    rid = _validated(client, t)
    _guest(client, rid, "Hygiene Kit")                       # waiting
    ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "description": "Flooding",
        "affected_families": 10, "assistance_needed": "Kits",
        "needs": [
            {"other_item_name": "Tarpaulin", "other_item_unit": "pcs", "quantity": 10},
            {"other_item_name": "hygiene kit", "other_item_unit": "pcs", "quantity": 5},
        ],
    }), 201)
    listed = _listed(client)
    assert "Tarpaulin (pcs)" in listed
    assert "Hygiene Kit (pcs)" in listed                     # approved by staff use
    assert ok(client.get("/items/pending", headers=t["csws"])) == []
