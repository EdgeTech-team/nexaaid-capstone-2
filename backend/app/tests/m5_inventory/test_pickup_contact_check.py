"""NF-007 (D5): call to confirm every Door to Door pickup stop.

POST /donations/entries/{ref}/contact-check (CSWS Main Office and DRRMO)
records Reached / No answer / Wrong number. A pickup run cannot be sent
while one of its stops has no Reached call (409 listing them). Wrong number
cancels the entry; a second No answer moves the stop to the donor's next
available date."""
import core.shared.database as database
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from tests.m4_donation_management.test_donation_batch import _report
from tests.m5_inventory.test_pickup_days_and_runs import _activate_everyone, _door, _next
from tests.m1_user_management.test_role_flows import api, ok  # noqa: F401  (fixture)


def _check(client, t, ref, outcome, who="csws", **extra):
    return client.post(f"/donations/entries/{ref}/contact-check", headers=t[who],
                       json={"outcome": outcome, **extra})


def _run(client, t, refs, day):
    return client.post("/logistics/pickup-requests", headers=t["csws"], json={
        "pickup_date": day.isoformat(), "batch_references": refs, "trucks": 1})


def _rows(ref):
    db = database.SessionLocal()
    try:
        return db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == ref).all()
    finally:
        db.close()


def test_a_run_with_an_unconfirmed_stop_is_refused_with_the_list(api):
    client, t = api
    rid = _report(client, t)
    a = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [3])), 201)["batch_reference"]
    b = ok(client.post("/donations/batch", headers=t["donor"],
                       json=_door(rid, [3], landmark="Tipolo", lat=10.335, lng=123.95)), 201)["batch_reference"]
    wed = _next(3)
    r = _run(client, t, [a, b], wed)
    assert r.status_code == 409
    assert a in r.json()["detail"] and b in r.json()["detail"]
    assert set(r.headers["X-Unconfirmed-Stops"].split(",")) == {a, b}

    ok(_check(client, t, a, "Reached"))
    r = _run(client, t, [a, b], wed)
    assert r.status_code == 409 and b in r.json()["detail"] and a not in r.json()["detail"]
    ok(_check(client, t, b, "Reached", who="drrmo"))      # DRRMO may record the call too
    ok(_run(client, t, [a, b], wed), 201)


def test_wrong_number_cancels_the_entry_with_the_reason(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    a = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [3])), 201)["batch_reference"]
    res = ok(_check(client, t, a, "Wrong number"))
    assert res["cancelled"] is True
    rows = _rows(a)
    assert {r.status for r in rows} == {"Cancelled"}
    assert rows[0].close_reason == "Contact number not reachable"
    assert rows[0].contact_outcome == "Wrong number" and rows[0].contact_confirmed_by_user_id
    board = {x["batch_reference"] for x in ok(client.get("/donations/pickups", headers=t["csws"]))}
    assert a not in board
    assert _check(client, t, a, "Reached").status_code == 409     # nothing left to pick up


def test_second_no_answer_moves_the_stop_to_the_next_date(api):
    client, t = api
    rid = _report(client, t)
    a = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [1, 3])),
           201)["batch_reference"]
    first = ok(_check(client, t, a, "No answer"))
    assert first["moved"] is False and _rows(a)[0].contact_outcome == "No answer"
    assert _rows(a)[0].pickup_not_home_date is None

    day = _next(1)
    second = ok(_check(client, t, a, "No answer", planned_date=day.isoformat()))
    assert second["moved"] is True and second["not_home_date"] == day.isoformat()
    row = _rows(a)[0]
    assert row.pickup_not_home_date == day
    assert row.contact_outcome is None                 # the new date needs a new call
    plan = ok(client.get("/donations/pickup-plan", headers=t["csws"]))
    stop = next(s for s in plan["stops"] if any(d["batch_reference"] == a for d in s["donations"]))
    if stop["planned_date"]:
        assert stop["planned_date"] > day.isoformat()


def test_plan_shows_which_stops_still_need_a_call(api):
    client, t = api
    rid = _report(client, t)
    a = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [3])), 201)["batch_reference"]

    def stop():
        plan = ok(client.get("/donations/pickup-plan", headers=t["csws"]))
        return next(s for s in plan["stops"] if any(d["batch_reference"] == a for d in s["donations"]))

    s = stop()
    assert s["contact_confirmed"] is False and "call_to_confirm" in s["flags"]
    assert s["donations"][0]["donor_contact"] == "09170000000"
    ok(_check(client, t, a, "Reached"))
    s = stop()
    assert s["contact_confirmed"] is True and "call_to_confirm" not in s["flags"]
    assert s["donations"][0]["contact_outcome"] == "Reached"


def test_only_csws_main_office_drrmo_and_admin_record_calls(api):
    client, t = api
    rid = _report(client, t)
    a = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [3])), 201)["batch_reference"]
    for who in ("donor", "unit", "cmo", "brgy"):
        assert _check(client, t, a, "Reached", who=who).status_code == 403, who
    assert _check(client, t, a, "Maybe").status_code == 422
    ok(_check(client, t, a, "Reached", who="admin"))


def test_changing_the_pickup_needs_a_new_call(api):
    client, t = api
    rid = _report(client, t)
    body = _door(rid, [3])
    a = ok(client.post("/donations/batch", headers=t["donor"], json=body), 201)["batch_reference"]
    ok(_check(client, t, a, "Reached"))
    ok(client.put(f"/donations/entries/{a}", headers=t["donor"],
                  json={k: v for k, v in {**body, "pickup_days": [4]}.items() if k != "report_id"}))
    assert _rows(a)[0].contact_outcome is None
    r = _run(client, t, [a], _next(4))
    assert r.status_code == 409 and a in r.json()["detail"]
