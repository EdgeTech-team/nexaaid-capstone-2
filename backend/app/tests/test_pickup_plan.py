"""Pickup logic v2, revised (Oct 12 afternoon): no scoring.

No size points and no report priority score. Stops are grouped by place
and shared day, sorted by urgency (fewest dates left, closest deadline,
oldest donation), limited only by pickup hours, then put in a one-way
route from the CSWS office.

Most cases call plan() directly with a fixed "today": Monday, Oct 12,
2026. The window covers 14 days from today (Oct 12 to 25), CSWS pickup
days only (Mon to Fri). The last tests go through the API.
"""
from datetime import date, datetime, timedelta

from services.pickup_planner import Donation, order_route, plan, planner_config, km_between
from tests.test_donation_batch import _report
from tests.test_pickup_days_and_runs import _door, _next
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

TODAY = date(2026, 10, 12)          # a Monday
OFFICE = (10.3300, 123.9300)
SCHOOL = (10.3400, 123.9400)        # about 1.5 km from the office
MON, TUE, WED, THU, FRI = 1, 2, 3, 4, 5
_n = 0


def _d(days, items=(("Box", 1),), at=SCHOOL, **extra):
    """One donation (QR batch) with [items] as (packaging, quantity) pairs."""
    global _n
    _n += 1
    return Donation(
        ref=f"D{_n:03d}",
        lat=None if at is None else at[0],
        lng=None if at is None else at[1],
        days=list(days),
        items=[{"item_name": "Rice", "packaging": p, "quantity": q} for p, q in items],
        **{"created_at": datetime(2026, 10, 1) + timedelta(minutes=_n), **extra},
    )


def _plan(donations, **cfg):
    return plan(donations, today=TODAY, office=OFFICE, pickup_days=[1, 2, 3, 4, 5],
                start_hour=9, end_hour=17, cfg=planner_config(cfg or None))


def _east(point, m):
    return (point[0], point[1] + m / 109_500)   # ~109.5 km per degree of longitude here


def _stop(result, ref):
    return next(s for s in result["stops"]
                if ref in [d["batch_reference"] for d in s["donations"]])


# ----- no scoring ------------------------------------------------------------
def test_the_plan_has_no_size_or_priority_scores():
    r = _plan([_d([TUE], [("Sack (50 kg)", 3)])])
    s = r["stops"][0]
    for gone in ("size", "points", "fullness_after_pct", "priority"):
        assert gone not in s
    assert "vehicle" not in r and "fullness_pct" not in r["runs"][0]
    assert s["donations"][0]["items"][0] == {
        "item_name": "Rice", "unit": "", "packaging": "Sack (50 kg)", "quantity": 3, "heavy": True}


def test_a_big_donation_is_still_planned():
    # Without size scoring nothing is ever "too big": staff judge from the items.
    s = _plan([_d([TUE], [("Sack (50 kg)", 200)])])["stops"][0]
    assert s["status"] == "planned" and s["heavy"] is True


# ----- grouping --------------------------------------------------------------
def test_same_landmark_and_a_shared_day_is_one_stop():
    a = _d([MON, WED])
    b = _d([TUE, WED], at=_east(SCHOOL, 20))
    r = _plan([a, b])
    assert len(r["stops"]) == 1
    s = r["stops"][0]
    assert s["donation_count"] == 2 and s["days"] == [WED]
    assert s["planned_date"] == "2026-10-14"


def test_same_place_but_no_shared_day_stays_two_stops():
    a = _d([MON])
    b = _d([TUE], at=_east(SCHOOL, 10))
    r = _plan([a, b])
    assert len(r["stops"]) == 2
    assert _stop(r, a.ref)["planned_date"] == "2026-10-12"
    assert _stop(r, b.ref)["planned_date"] == "2026-10-13"


def test_far_apart_pins_are_not_grouped():
    assert len(_plan([_d([MON]), _d([MON], at=_east(SCHOOL, 300))])["stops"]) == 2


# ----- urgency sorting -------------------------------------------------------
def _crowded(minutes_per_stop=240):
    # Two stops fill a day (240 + 240 minutes is past 8 hours with travel).
    return {"minutes_per_stop": minutes_per_stop}


def test_fewest_dates_left_goes_first():
    flexible = _d([TUE, WED, THU])
    only_tue = _d([TUE], at=_east(SCHOOL, 400))
    r = _plan([flexible, only_tue], **_crowded())
    assert _stop(r, only_tue.ref)["planned_date"] == "2026-10-13"
    assert _stop(r, flexible.ref)["planned_date"] == "2026-10-14"


def test_closest_deadline_breaks_a_tie():
    later = _d([TUE], days_left=10)
    sooner = _d([TUE], at=_east(SCHOOL, 400), days_left=4)
    r = _plan([later, sooner], **_crowded())
    assert _stop(r, sooner.ref)["planned_date"] == "2026-10-13"
    assert _stop(r, later.ref)["planned_date"] == "2026-10-20"


def test_oldest_donation_breaks_the_next_tie():
    old = _d([TUE], created_at=datetime(2026, 9, 30))
    new = _d([TUE], at=_east(SCHOOL, 400), created_at=datetime(2026, 10, 5))
    r = _plan([new, old], **_crowded())
    assert _stop(r, old.ref)["planned_date"] == "2026-10-13"
    assert _stop(r, new.ref)["planned_date"] == "2026-10-20"


def test_report_priority_no_longer_matters():
    # Same urgency, the older one goes first regardless of anything else.
    a = _d([TUE], created_at=datetime(2026, 9, 30))
    b = _d([TUE], at=_east(SCHOOL, 400), created_at=datetime(2026, 10, 1))
    assert _stop(_plan([b, a], **_crowded()), a.ref)["planned_date"] == "2026-10-13"


# ----- pickup hours are the only limit ---------------------------------------
def test_runs_finish_within_pickup_hours():
    ds = [_d([TUE], at=_east(SCHOOL, 120 * i)) for i in range(40)]
    r = _plan(ds)
    tuesday = next(x for x in r["runs"] if x["date"] == "2026-10-13")
    assert tuesday["minutes"] <= 8 * 60 and tuesday["stops"] < 40
    assert all(s["status"] == "planned" for s in r["stops"])   # the rest go next Tuesday


def test_monday_only_and_mondays_full_is_reported_not_lost():
    ds = [_d([MON], at=_east(SCHOOL, 400 * i)) for i in range(3)]
    r = _plan(ds, **_crowded(300))       # one stop per day
    statuses = sorted(s["status"] for s in r["stops"])
    assert statuses == ["no_feasible_day", "planned", "planned"]
    left = next(s for s in r["stops"] if s["status"] == "no_feasible_day")
    assert "Mon" in left["reason"] and "full" in left["reason"]
    last = next(s for s in r["stops"] if s["planned_date"] == "2026-10-19")
    assert last["last_chance"] is True


# ----- route order -----------------------------------------------------------
def test_route_is_one_way_from_the_office_nearest_first():
    near = _d([TUE], at=_east(OFFICE, 500))
    mid = _d([TUE], at=_east(OFFICE, 1500))
    far_ = _d([TUE], at=_east(OFFICE, 3000))
    r = _plan([far_, near, mid])
    order = [_stop(r, x.ref)["route_order"] for x in (near, mid, far_)]
    assert order == [1, 2, 3]
    assert abs(r["runs"][0]["km"] - 3.0) < 0.1


def test_route_improvement_never_makes_the_path_longer():
    import random
    rnd = random.Random(7)
    pts = [(10.30 + rnd.random() * 0.08, 123.90 + rnd.random() * 0.08) for _ in range(12)]

    def length(order):
        path = [OFFICE] + [pts[i] for i in order]
        return sum(km_between(path[i - 1], path[i]) for i in range(1, len(path)))

    greedy, left, here = [], list(range(12)), OFFICE
    while left:
        nxt = min(left, key=lambda i: km_between(here, pts[i]))
        greedy.append(nxt)
        left.remove(nxt)
        here = pts[nxt]
    improved = order_route(pts, OFFICE)
    assert sorted(improved) == list(range(12))
    assert length(improved) <= length(greedy) + 1e-9


# ----- dates, misses, follow-up ----------------------------------------------
def test_lead_time_skips_today():
    s = _plan([_d([MON], created_at=datetime(2026, 10, 12, 8, 0))])["stops"][0]
    assert s["planned_date"] == "2026-10-19"
    assert _plan([_d([MON])])["stops"][0]["planned_date"] == "2026-10-12"


def test_not_home_moves_to_the_next_allowed_day():
    s = _plan([_d([WED], not_home_date=date(2026, 10, 14))])["stops"][0]
    assert s["planned_date"] == "2026-10-21" and "missed_before" in s["flags"]


def test_a_stop_in_a_drrmo_run_keeps_the_run_date():
    s = _plan([_d([TUE, THU], run_date=date(2026, 10, 15))])["stops"][0]
    assert s["planned_date"] == "2026-10-15" and "in_drrmo_run" in s["flags"]
    assert s["last_chance"] is False


def test_donation_close_to_its_deadline_is_flagged_to_call():
    assert "call_donor" in _plan([_d([TUE], days_left=2)])["stops"][0]["flags"]


def test_no_pin_goes_to_follow_up():
    r = _plan([_d([MON], at=None)])
    assert r["stops"] == [] and len(r["follow_up"]) == 1


def test_far_pickups_are_shown_but_not_planned():
    s = _plan([_d([MON], too_far=True)])["stops"][0]
    assert s["status"] == "far" and s["planned_date"] is None


def test_no_matching_weekday_says_why():
    s = _plan([_d([6])])["stops"][0]        # Saturday only; CSWS picks up Mon to Fri
    assert s["status"] == "no_feasible_day" and "Sat" in s["reason"]


# ----- through the API -------------------------------------------------------
def test_only_main_office_and_admin_see_the_plan(api):
    client, t = api
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [1, 3])), 201)
    for who in ("donor", "drrmo", "unit", "brgy", "cmo"):
        assert client.get("/donations/pickup-plan", headers=t[who]).status_code == 403
    assert client.get("/donations/pickup-plan").status_code == 401
    ok(client.get("/donations/pickup-plan", headers=t["admin"]))
    s = _stop(ok(client.get("/donations/pickup-plan", headers=t["csws"])), b["batch_reference"])
    assert s["status"] == "planned" and s["days"] == [1, 3]
    item = s["donations"][0]["items"][0]
    assert item["packaging"] == "Box" and item["quantity"] == 2 and item["item_name"] == "Rice"
    assert s["donations"][0]["donor"]


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


# ----- barangay label for the pickup list -----------------------------------
def test_barangay_is_read_from_the_address_then_the_landmark():
    from services.pickup_barangay import barangay_finder
    find = barangay_finder(["Barangay Test", "Banilad"])
    # Typed address first (the donor knows their barangay)
    assert find("Pilit, Cabancalan Mandaue",
                "Cabancalan I Elementary School, Lupa, Casuntingan, Mandaue, Cebu") == "Cabancalan"
    # No barangay in the address: the landmark's district (nearest the city)
    assert find("P. Remedio St.", "Oakridge IT Center, Banilad, Mandaue, Central Visayas") == "Banilad"
    assert find("", "Cabancalan I Elementary School, Lupa, Casuntingan, Mandaue, Cebu") == "Casuntingan"
    # Other spellings
    assert find("Brgy. Ibabao-Estancia, Mandaue") == "Ibabao-Estancia"
    assert find("near Paknaan market") == "Pakna-an"
    assert find("Centro (Poblacion), Mandaue City") == "Centro"
    # Not part of another word, and nothing found -> None
    assert find("Basakan Street") is None
    assert find("Somewhere, Cebu City", None) is None


def test_the_plan_gives_each_stop_its_barangay(api):
    client, t = api
    rid = _report(client, t)
    body = _door(rid, [1, 3])
    body["pickup_address"] = "12 A. Del Rosario St., Banilad"
    b = ok(client.post("/donations/batch", headers=t["donor"], json=body), 201)
    s = _stop(ok(client.get("/donations/pickup-plan", headers=t["csws"])), b["batch_reference"])
    assert s["barangay"] == "Banilad" and s["donations"][0]["barangay"] == "Banilad"