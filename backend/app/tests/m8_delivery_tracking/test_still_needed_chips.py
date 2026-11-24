"""J6 / NF-011: the "still needed" chips subtract verified pledges only.

core/m8_delivery_tracking/fulfillment.py splits "pledged" into pledged_verified and
pledged_unverified with D3's pledge_is_verified (core/m4_donation_management/pledge_trust.py):
a pledge is verified once CSWS has received it, or when it comes from an
account whose email is verified. _still_needed (core/m2_disaster_reporting/disaster_events.py)
and the donate form's chips use pledged_verified; pledged_unverified_count
feeds "+ N unconfirmed pledges".

Agreement A1: the official fulfillment % and priority move only when the
Barangay Receiving Representative confirms, so unverified pledges change
neither.

Done when: a 100,000-unit guest pledge doesn't change "still needed"; it
counts once received.

The guest pledges are written straight to the table: Dave's guest limits
(D1-D2, GUEST_MAX_LINE_QTY) would refuse a 100,000-unit line from the API,
and this test is about the chips, not the limits.
"""
import uuid

from core.shared import database
from core.m4_donation_management.guest_donor_model import GuestDonor
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from core.m1_user_management.user_rbac_model import User
from core.m8_delivery_tracking import fulfillment
from core.m2_disaster_reporting.disaster_events import _still_needed
from tests.receipt_helpers import full_counts
from tests.m1_user_management.test_role_flows import api, ok  # noqa: F401  (fixture)

RICE = 1
NEED = 500
BIG = 100_000


def _report(client, t, rice=NEED):
    """A validated single-item report (Rice) for Barangay 1, inside an
    event (an event needs two barangays; only the first is validated)."""
    batch = ok(client.post("/reports/batch", headers=t["unit"], json={
        "disaster_type_id": 1, "description": "Flooded after heavy rain",
        "barangays": [{"barangay_id": b, "affected_families": 100,
                       "needs": [{"item_id": RICE, "quantity": rice}]} for b in (1, 2)],
    }), 201)
    rid = batch["reports"][0]["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    return rid, batch["event"]["event_id"]


def _guest_pledge(rid, quantity):
    """A Pending Drop Off pledge from a guest (no account). Returns its
    batch_reference."""
    db = database.SessionLocal()
    try:
        g = GuestDonor(full_name="Guest Test", contact_number="09171112222")
        db.add(g)
        db.flush()
        ref = f"G-{uuid.uuid4().hex[:10].upper()}"   # receive upper-cases it
        db.add(PhysicalDonation(
            user_id=None, guest_donor_id=g.guest_donor_id, report_id=rid, item_id=RICE,
            packaging="Sack", quantity=quantity, handover_method="Drop Off",
            status="Pending", qr_reference=f"{ref}-1", batch_reference=ref,
        ))
        db.commit()
        return ref
    finally:
        db.close()


def _donation_ids(ref):
    db = database.SessionLocal()
    try:
        return [d.donation_id for d in db.query(PhysicalDonation)
                .filter(PhysicalDonation.batch_reference == ref).all()]
    finally:
        db.close()


def _rice(client, rid):
    return ok(client.get(f"/reports/{rid}/needs"))["needs"][0]


def _event_top(client, event_id, rid):
    e = ok(client.get(f"/reports/events/{event_id}"))
    row = next(r for r in e["reports"] if r["report_id"] == rid)
    return row["top_needs"]


def _official(client, t, rid):
    """What A1 protects: the official %, the stored figure, priority."""
    p = ok(client.get(f"/reports/{rid}/needs"))
    r = ok(client.get(f"/reports/{rid}", headers=t["admin"]))
    return (p["fulfillment_percentage"], [n["delivered"] for n in p["needs"]],
            [n["delivered_percentage"] for n in p["needs"]],
            float(r["fulfillment_percentage"] or 0), r["priority_level"],
            float(r["ai_priority_score"] or 0))


# ---------------------------------------------------------------------------
# (a) Done when: a 100,000-unit guest pledge doesn't change "still needed";
#     it counts once received.
# ---------------------------------------------------------------------------
def test_big_guest_pledge_does_not_change_still_needed_until_received(api):
    client, t = api
    rid, event_id = _report(client, t)
    before = _rice(client, rid)
    assert _still_needed(before) == NEED
    assert [n["still_needed"] for n in _event_top(client, event_id, rid)] == [NEED]

    ref = _guest_pledge(rid, BIG)

    n = _rice(client, rid)
    assert n["pledged"] == BIG                       # the total is still shown
    assert (n["pledged_verified"], n["pledged_unverified"]) == (0, BIG)
    assert _still_needed(n) == NEED                  # chip unchanged
    top = _event_top(client, event_id, rid)
    assert [x["still_needed"] for x in top] == [NEED]
    assert [x["pledged_unverified_count"] for x in top] == [1]

    # CSWS receives part of it at the warehouse: now it counts.
    did = _donation_ids(ref)[0]
    ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
        "items": [{"donation_id": did, "actual_quantity": 300}]}))
    n = _rice(client, rid)
    assert (n["pledged_verified"], n["pledged_unverified"], n["pledged_unverified_count"]) == (300, 0, 0)
    assert _still_needed(n) == NEED - 300
    assert [x["still_needed"] for x in _event_top(client, event_id, rid)] == [NEED - 300]


# ---------------------------------------------------------------------------
# (b) a verified pledge still reduces "still needed"; an account whose email
#     is not verified does not (D3 / D4).
# ---------------------------------------------------------------------------
def test_verified_account_pledge_reduces_still_needed(api):
    client, t = api
    rid, _ = _report(client, t)
    ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": RICE, "quantity": 120, "packaging": "Sack",
        "handover_method": "Drop Off"}))
    n = _rice(client, rid)
    assert (n["pledged"], n["pledged_verified"], n["pledged_unverified"]) == (120, 120, 0)
    assert n["pledged_unverified_count"] == 0
    assert _still_needed(n) == NEED - 120


def test_unverified_email_pledge_does_not_reduce_still_needed(api):
    client, t = api
    rid, _ = _report(client, t)
    ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": RICE, "quantity": 80, "packaging": "Sack",
        "handover_method": "Drop Off"}))
    db = database.SessionLocal()
    try:
        donor = db.query(User).filter(User.email == "donor.test@example.com").one()
        donor.email_verified_at = None
        db.commit()
    finally:
        db.close()
    n = _rice(client, rid)
    assert (n["pledged_verified"], n["pledged_unverified"], n["pledged_unverified_count"]) == (0, 80, 1)
    assert _still_needed(n) == NEED


# ---------------------------------------------------------------------------
# (c) A1: fulfillment % and priority are identical before and after
#     unverified pledges are added.
# ---------------------------------------------------------------------------
def test_unverified_pledges_leave_fulfillment_and_priority_alone(api):
    client, t = api
    rid, _ = _report(client, t)
    # Something delivered and confirmed by the barangay, so the % is not 0.
    entry = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [{"item_id": RICE, "quantity": 100, "packaging": "Sack"}]}), 201)
    line = entry["items"][0]
    ok(client.post(f"/donations/entries/{entry['batch_reference']}/receive", headers=t["csws"],
                   json={"items": [{"donation_id": line["donation_id"], "actual_quantity": 100}]}))
    ok(client.post(f"/cmo/donations/{line['donation_id']}/confirm", headers=t["cmo"],
                   json={"status": "Confirmed"}), 201)
    did = ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-11-19T08:00:00",
        "items": [{"item_id": RICE, "quantity": 100}]}), 201)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"],
                   json=full_counts(client, did, t["brgy"])), 201)

    before = _official(client, t, rid)
    assert before[0] == 20.0                          # 100 of 500 delivered

    _guest_pledge(rid, BIG)
    _guest_pledge(rid, 250)
    after = _official(client, t, rid)
    assert after == before

    # Recalculating the stored figure gives the same answer too.
    db = database.SessionLocal()
    try:
        f = fulfillment.recalculate(db, rid, None)
        assert float(f.fulfillment_percentage) == before[0]
        assert f.total_items_delivered == 100
        db.rollback()
    finally:
        db.close()


# ---------------------------------------------------------------------------
# (d) the unconfirmed count is in every response the chips read.
# ---------------------------------------------------------------------------
def test_unconfirmed_count_reaches_the_donate_form(api):
    client, t = api
    rid, _ = _report(client, t)
    _guest_pledge(rid, BIG)
    _guest_pledge(rid, 40)
    ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": RICE, "quantity": 60, "packaging": "Sack",
        "handover_method": "Drop Off"}))

    expected = {"pledged": BIG + 100, "pledged_verified": 60,
                "pledged_unverified": BIG + 40, "pledged_unverified_count": 2}
    lk = next(r for r in ok(client.get("/lookups"))["validated_reports"] if r["id"] == rid)
    pub = next(r for r in ok(client.get("/public/reports")) if r["report_id"] == rid)
    for need in (_rice(client, rid), lk["needs"][0], pub["needs"][0]):
        assert {k: need[k] for k in expected} == expected
        assert _still_needed(need) == NEED - 60


def test_old_rows_without_the_split_keep_needed_minus_pledged():
    assert _still_needed({"needed": 500, "pledged": 120}) == 380
    assert _still_needed({"needed": 500, "pledged": 900, "pledged_verified": 100}) == 400
    assert _still_needed({"needed": 50, "pledged_verified": 80}) == 0
