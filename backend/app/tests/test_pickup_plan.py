"""Pickup logic v2 (Oct 12 notes): the Door to Door pickup planner.

Section 7 of the notes, one test per case. The planner is pure Python
(services/pickup_planner.py), so most cases call plan() directly with a
fixed "today": Monday, Oct 12, 2026. The window covers 14 days from today
(Oct 12 to 25), CSWS pickup days only (Mon to Fri). A donation made today
waits at least one day (lead time).
The last tests go through the API: roles and "Not home".
"""
from datetime import date, datetime, timedelta

from services.pickup_planner import Donation, plan, planner_config
from tests.test_donation_batch import _report
from tests.test_pickup_days_and_runs import _door, _next
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

TODAY = date(2026, 10, 12)          # a Monday
OFFICE = (10.3300, 123.9300)
SCHOOL = (10.3400, 123.9400)        # about 1.5 km from the office
MON, TUE, WED, THU, FRI = 1, 2, 3, 4, 5
_n = 0


def _d(days, items, at=SCHOOL, **extra):
    """One donation (QR batch) with [items] as (packaging, quantity) pairs."""
    global _n
    _n += 1
    item = extra.pop("item", "Rice")
    return Donation(
        ref=f"D{_n:03d}",
        lat=None if at is None else at[0],
        lng=None if at is None else at[1],
        days=list(days),
        items=[{"item_name": item, "packaging": p, "quantity": q}
               for p, q in items],
        **{"created_at": datetime(2026, 10, 1) + timedelta(minutes=_n), **extra},
    )


def _plan(donations, vehicle="van", **cfg):
    return plan(donations, today=TODAY, office=OFFICE, pickup_days=[1, 2, 3, 4, 5],
                start_hour=9, end_hour=17, vehicle_key=vehicle,
                cfg=planner_config(cfg or None))


def _meters_east(point, m):
    return (point[0], point[1] + m / 109_500)   # ~109.5 km per degree of longitude here


def _stop(result, ref):
    return next(s for s in result["stops"]
                if ref in [d["batch_reference"] for d in s["donations"]])


# 1. Two donors 20 m apart, Mon+Wed and Tue+Wed: one stop, Wednesday only
def test_same_landmark_and_a_shared_day_is_one_stop():
    a = _d([MON, WED], [("Box", 1)])
    b = _d([TUE, WED], [("Box", 1)], at=_meters_east(SCHOOL, 20))
    r = _plan([a, b])
    assert len(r["stops"]) == 1
    s = r["stops"][0]
    assert s["donation_count"] == 2 and s["days"] == [WED]
    assert s["planned_date"] == "2026-10-14"            # the first Wednesday


# 2. Same place, Mon only and Tue only: two stops
def test_same_place_but_no_shared_day_stays_two_stops():
    a = _d([MON], [("Box", 1)])
    b = _d([TUE], [("Box", 1)], at=_meters_east(SCHOOL, 10))
    r = _plan([a, b])
    assert len(r["stops"]) == 2
    assert _stop(r, a.ref)["planned_date"] == "2026-10-12"
    assert _stop(r, b.ref)["planned_date"] == "2026-10-13"


def test_far_apart_pins_are_not_grouped():
    a = _d([MON], [("Box", 1)])
    b = _d([MON], [("Box", 1)], at=_meters_east(SCHOOL, 300))
    assert len(_plan([a, b])["stops"]) == 2


# 3. Only a 50 kg sack: reliable, large
def test_a_50kg_sack_is_reliable_and_large():
    s = _plan([_d([MON], [("Sack (50 kg)", 1)])])["stops"][0]
    assert s["size"]["class"] == "L" and s["size"]["confidence"] == "reliable"
    assert s["size"]["heavy"] is True
    assert s["donations"][0]["items"][0]["heavy"] is True


# 4. Loose / no packaging: uncertain, shown with "?", planned with a medium size
def test_loose_items_are_uncertain_and_planned_conservatively():
    s = _plan([_d([MON], [("Loose / no packaging", 1)])])["stops"][0]
    assert s["size"]["confidence"] == "uncertain" and "uncertain_size" in s["flags"]
    assert s["size"]["class"] == "M" and s["status"] == "planned"


def test_an_old_plain_sack_entry_is_treated_as_big_but_uncertain():
    s = _plan([_d([MON], [("Sack", 1)])])["stops"][0]
    assert s["size"]["class"] == "L" and s["size"]["confidence"] == "uncertain"


# 5. Quantity multiplies the size
def test_quantity_changes_the_class():
    one = _plan([_d([MON], [("Plastic bag", 1)])])["stops"][0]
    many = _plan([_d([MON], [("Plastic bag", 15)])])["stops"][0]
    assert one["size"]["class"] == "S" and many["size"]["class"] == "L"


def test_clothing_is_a_little_bulkier():
    rice = _plan([_d([MON], [("Box", 2)], item="Rice")])["stops"][0]
    clothes = _plan([_d([MON], [("Box", 2)], item="Clothing")])["stops"][0]
    assert clothes["size"]["points"] > rice["size"]["points"]


# 6. Within capacity: included, with vehicle fullness after the stop
def test_a_stop_within_capacity_is_planned_with_fullness():
    r = _plan([_d([TUE], [("Sack (50 kg)", 1)])])
    s = r["stops"][0]
    assert s["status"] == "planned" and s["planned_date"] == "2026-10-13"
    assert s["route_order"] == 1
    assert s["fullness_after_pct"] == 30                  # 5 of 18 points, rounded to 5%
    run = r["runs"][0]
    assert run["stop_ids"] == [s["stop_id"]] and run["fullness_pct"] == 30


# 7. Three stops that each nearly fill a car: one per day
def test_stops_that_each_fill_the_vehicle_go_on_different_days():
    every_day = [MON, TUE, WED, THU, FRI]
    ds = [_d(every_day, [("Sack (50 kg)", 1)], at=_meters_east(SCHOOL, 500 * i)) for i in range(3)]
    r = _plan(ds, vehicle="car")                          # car: 6 points, plan to 85% = 5.1
    dates = sorted(s["planned_date"] for s in r["stops"])
    assert dates == ["2026-10-12", "2026-10-13", "2026-10-14"]


def test_least_flexible_stop_goes_first():
    flexible = _d([TUE, WED, THU], [("Sack (50 kg)", 1)])
    only_tue = _d([TUE], [("Sack (50 kg)", 1)], at=_meters_east(SCHOOL, 400))
    r = _plan([flexible, only_tue], vehicle="car")
    assert _stop(r, only_tue.ref)["planned_date"] == "2026-10-13"
    assert _stop(r, flexible.ref)["planned_date"] == "2026-10-14"
    assert _stop(r, only_tue.ref)["last_chance"] is False   # there is another Tuesday
    assert _stop(r, only_tue.ref)["next_date"] == "2026-10-20"


# 8. Bigger than the biggest vehicle: special handling
def test_a_stop_bigger_than_the_biggest_vehicle_needs_special_handling():
    s = _plan([_d([MON], [("Sack (50 kg)", 13)])])["stops"][0]    # 65 points > truck 60
    assert s["status"] == "special_handling" and s["planned_date"] is None
    assert s["size"]["class"] == "XL"


def test_too_big_for_the_chosen_vehicle_says_so():
    s = _plan([_d([MON], [("Sack (50 kg)", 4)])], vehicle="van")["stops"][0]   # 20 > 15.3
    assert s["status"] == "no_feasible_day" and "bigger vehicle" in s["reason"]
    assert _plan([_d([MON], [("Sack (50 kg)", 4)])], vehicle="truck")["stops"][0]["status"] == "planned"


# 9. Only Monday, and every Monday is full: "no feasible day" with a reason
def test_monday_only_and_mondays_full_is_reported_not_lost():
    ds = [_d([MON], [("Sack (50 kg)", 1)], at=_meters_east(SCHOOL, 400 * i)) for i in range(3)]
    r = _plan(ds, vehicle="car")
    statuses = sorted(s["status"] for s in r["stops"])
    assert statuses == ["no_feasible_day", "planned", "planned"]
    left = next(s for s in r["stops"] if s["status"] == "no_feasible_day")
    assert "Mon" in left["reason"] and "full" in left["reason"]
    last = next(s for s in r["stops"] if s["planned_date"] == "2026-10-19")
    assert last["last_chance"] is True                    # its only remaining Monday


# 10. Made today, today allowed: next occurrence after the lead time
def test_lead_time_skips_today():
    s = _plan([_d([MON], [("Box", 1)], created_at=datetime(2026, 10, 12, 8, 0))])["stops"][0]
    assert s["planned_date"] == "2026-10-19"              # not later today, Oct 12
    old = _plan([_d([MON], [("Box", 1)])])["stops"][0]    # made Oct 1
    assert old["planned_date"] == "2026-10-12"            # today's run still shows


# 11. Waiting almost two weeks: staff should call
def test_donation_close_to_its_deadline_is_flagged_to_call():
    s = _plan([_d([TUE], [("Box", 1)], days_left=2)])["stops"][0]
    assert "call_donor" in s["flags"]


# 12. No usable pin: needs follow-up, the donor is not blocked
def test_no_pin_goes_to_follow_up():
    r = _plan([_d([MON], [("Box", 1)], at=None)])
    assert r["stops"] == [] and len(r["follow_up"]) == 1


def test_far_pickups_are_shown_but_not_planned():
    s = _plan([_d([MON], [("Box", 1)], too_far=True)])["stops"][0]
    assert s["status"] == "far" and s["planned_date"] is None


# 14. "Not home": the stop moves to the next allowed day
def test_not_home_moves_to_the_next_allowed_day():
    s = _plan([_d([WED], [("Box", 1)], not_home_date=date(2026, 10, 14))])["stops"][0]
    assert s["planned_date"] == "2026-10-21"


def test_a_stop_in_a_drrmo_run_keeps_the_run_date():
    s = _plan([_d([TUE, THU], [("Box", 1)], run_date=date(2026, 10, 15))])["stops"][0]
    assert s["planned_date"] == "2026-10-15" and "in_drrmo_run" in s["flags"]


def test_runs_finish_within_pickup_hours():
    ds = [_d([TUE], [("Bottle", 1)], at=_meters_east(SCHOOL, 120 * i)) for i in range(40)]
    r = _plan(ds, vehicle="truck")
    tuesday = next(x for x in r["runs"] if x["date"] == "2026-10-13")
    assert tuesday["minutes"] <= 8 * 60 and tuesday["stops"] < 40
    assert all(s["status"] == "planned" for s in r["stops"])   # the rest go on the next Tuesday


def test_sanity_flags_for_staff():
    big = _plan([_d([MON], [("Box", 500)])])["stops"][0]
    other = _plan([_d([MON], [("Other", 1)])])["stops"][0]
    assert "needs_review_quantity" in big["flags"]
    assert "needs_review_other" in other["flags"]


def test_capacities_are_settings():
    s = _plan([_d([TUE], [("Sack (50 kg)", 1)])], vehicles=[
        {"key": "van", "name": "Van", "points": 10, "kg": 1000}])["stops"][0]
    assert s["fullness_after_pct"] == 50


# ---------------------------------------------------------------------------
# Through the API
# ---------------------------------------------------------------------------
def test_only_main_office_and_admin_see_the_plan(api):
    client, t = api
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [1, 3])), 201)
    for who in ("donor", "drrmo", "unit", "brgy", "cmo"):
        assert client.get("/donations/pickup-plan", headers=t[who]).status_code == 403
    assert client.get("/donations/pickup-plan").status_code == 401
    r = ok(client.get("/donations/pickup-plan", headers=t["csws"]))
    assert ok(client.get("/donations/pickup-plan", headers=t["admin"]))["vehicle"]["key"] == "van"
    s = _stop(r, b["batch_reference"])
    assert s["status"] == "planned" and s["days"] == [1, 3]
    item = s["donations"][0]["items"][0]
    assert item["packaging"] == "Box" and item["quantity"] == 2 and item["item_name"] == "Rice"
    assert s["donations"][0]["donor"]                       # staff see who to call
    assert client.get("/donations/pickup-plan?vehicle=bike", headers=t["csws"]).status_code == 422
    assert ok(client.get("/donations/pickup-plan?vehicle=truck", headers=t["csws"]))["vehicle"]["key"] == "truck"


def test_not_home_moves_the_stop_and_tells_the_donor(api):
    client, t = api
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [3])), 201)
    ref = b["batch_reference"]
    first = _stop(ok(client.get("/donations/pickup-plan", headers=t["csws"])), ref)["planned_date"]
    assert first == _next(3).isoformat()

    post = lambda who, body: client.post("/donations/pickup-plan/not-home", headers=t[who], json=body)
    assert post("donor", {"batch_references": [ref]}).status_code == 403
    assert post("csws", {"batch_references": ["NOPE"]}).status_code == 404
    ok(post("csws", {"batch_references": [ref.lower()], "visited_on": first}))

    after = _stop(ok(client.get("/donations/pickup-plan", headers=t["csws"])), ref)["planned_date"]
    assert after == (_next(3) + timedelta(days=7)).isoformat()
    titles = [n["title"] for n in ok(client.get("/notifications/", headers=t["donor"]))["items"]]
    assert "We missed you" in titles