"""
F-15 / Concerns Nov 4: items typed in on a donation ("Something else") are
saved on that donation only. There is no review step: they are in no
dropdown, so a guest cannot add names to everyone's list. Items the Disaster Unit adds to a report are added
at once. Typed names are matched exactly (no LIKE wildcards), and a retired
item's name can be typed twice without a 500.
"""
import core.database as database
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


def test_a_typed_item_stays_on_the_donation_and_out_of_every_list(api):
    """Concerns Nov 4: no review step. The typed item is saved on the
    donation and reused by the next donation with the same name, but it is
    never offered in anyone's dropdown or suggested needs."""
    client, t = api
    rid = _validated(client, t)
    first = _guest(client, rid, "Diapers")
    again = _guest(client, rid, "diapers")
    assert first["item_id"] == again["item_id"] != 1          # reused
    assert "Diapers (pcs)" not in _listed(client)
    assert "Diapers (pcs)" not in _listed(client, t["csws"])
    db = database.SessionLocal()
    try:
        row = db.get(PhysicalDonation, first["donation_id"])
        assert row.item_id == first["item_id"]                  # the donation keeps it
    finally:
        db.close()


def test_the_review_endpoints_are_gone(api):
    client, t = api
    assert client.get("/items/pending", headers=t["csws"]).status_code == 404
    assert client.post("/items/1/approve", headers=t["admin"], json={}).status_code == 404


def test_wildcards_in_a_typed_name_match_nothing_else(api):
    client, t = api
    rid = _validated(client, t)
    for typed in ("Ric_", "%"):
        assert _guest(client, rid, typed)["item_id"] != 1, typed   # 1 = Rice


def test_items_the_disaster_unit_adds_to_a_report_are_listed_at_once(api):
    client, t = api
    rid = _validated(client, t)
    _guest(client, rid, "Hygiene Kit")                       # typed by a guest
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
    assert "Hygiene Kit (pcs)" in listed                     # listed once staff use it
