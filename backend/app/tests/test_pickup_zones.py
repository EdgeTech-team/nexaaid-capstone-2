"""Fixed pickup zones (testing, Oct 31): "cluster first, route second".

A Door to Door donation is placed in a fixed zone (services/pickup_zones.py)
and the planner fills a day zone by zone: must-go stops first (last allowed
date, deadline close), then the zone of the day, then the nearest zones.
The order inside a day is the shortest route from the CSWS office.
"""
from services.pickup_zones import ZONES, zone_of
from tests.test_pickup_plan import OFFICE, TUE, WED, _d, _east, _plan, _stop

WEST = _east(OFFICE, -3000)          # about 3 km west of the office
EAST = _east(OFFICE, 3000)           # about 3 km east


# ----- which zone ------------------------------------------------------------
def test_the_barangay_in_the_text_decides_the_zone():
    assert zone_of("Pilit, Canduman, Mandaue City", None) == "Mandaue North"
    assert zone_of("Parkmall, Subangdaku, Mandaue City", None) == "Mandaue West"
    assert zone_of("Centro, Mandaue City", None) == "Mandaue East"
    assert zone_of("Ayala Center, Lahug, Cebu City", None) == "Cebu City North"
    assert zone_of("Bulacao, Cebu City", None) == "Cebu City South"
    assert zone_of("Mactan Newtown, Lapu-Lapu", None) == "Lapu-Lapu (Mactan)"
    assert zone_of("Poblacion, Consolacion", None) == "Consolacion"


def test_banilad_follows_the_city_written():
    assert zone_of("Banilad, Mandaue City", None) == "Mandaue West"
    assert zone_of("Banilad, Cebu City", None) == "Cebu City North"


def test_the_landmark_is_used_when_the_address_says_nothing():
    assert zone_of("Blue gate near the store", "Pilit, Canduman, Mandaue") == "Mandaue North"


def test_a_city_without_a_barangay_uses_the_pin():
    # SM City Cebu is in Mabolo (North), but its address names no barangay.
    sm = (10.3117, 123.9185)
    assert zone_of("SM City Cebu, North Reclamation Area, Cebu City", None, *sm) == "Cebu City North"


def test_no_city_or_barangay_uses_the_nearest_zone_to_the_pin():
    canduman = next(z for z in ZONES if z["name"] == "Mandaue North")["center"]
    assert zone_of("near the chapel", None, *canduman) == "Mandaue North"
    assert zone_of("near the chapel", None) is None


# ----- a day stays in one zone -----------------------------------------------
def _crowded():
    # Two stops fill a day: 2 x 200 minutes fit in 8 hours, 3 do not.
    return {"minutes_per_stop": 200}


def test_a_day_stays_in_one_zone_instead_of_following_donation_time():
    # Donated in this order: west, east, west, east. All home Tue and Wed.
    w1 = _d([TUE, WED], at=WEST, zone="Mandaue West")
    e1 = _d([TUE, WED], at=EAST, zone="Mandaue East")
    w2 = _d([TUE, WED], at=_east(WEST, 300), zone="Mandaue West")
    e2 = _d([TUE, WED], at=_east(EAST, 300), zone="Mandaue East")
    r = _plan([w1, e1, w2, e2], **_crowded())
    tue = {_stop(r, x.ref)["zone"] for x in (w1, e1, w2, e2)
           if _stop(r, x.ref)["planned_date"] == "2026-10-13"}
    wed = {_stop(r, x.ref)["zone"] for x in (w1, e1, w2, e2)
           if _stop(r, x.ref)["planned_date"] == "2026-10-14"}
    assert tue == {"Mandaue West"} and wed == {"Mandaue East"}
    runs = {run["date"]: run["zones"] for run in r["runs"]}
    assert runs["2026-10-13"] == ["Mandaue West"] and runs["2026-10-14"] == ["Mandaue East"]
    assert _stop(r, w1.ref)["zone"] == "Mandaue West"


def test_a_last_chance_stop_is_never_left_out_for_the_zone():
    # The east donor is home only on Tuesday: it goes Tuesday even though
    # the west zone has more donors.
    last = _d([TUE], at=EAST, zone="Mandaue East")
    w1 = _d([TUE, WED], at=WEST, zone="Mandaue West")
    w2 = _d([TUE, WED], at=_east(WEST, 300), zone="Mandaue West")
    r = _plan([w1, w2, last], **_crowded())
    assert _stop(r, last.ref)["planned_date"] == "2026-10-13"
    assert {_stop(r, w1.ref)["status"], _stop(r, w2.ref)["status"]} == {"planned"}


def test_the_order_inside_a_day_is_the_shortest_route():
    # Same zone, same day, donated far first: the nearest is still stop 1.
    far_ = _d([TUE], at=_east(OFFICE, 2500), zone="Mandaue East")
    near = _d([TUE], at=_east(OFFICE, 500), zone="Mandaue East")
    mid = _d([TUE], at=_east(OFFICE, 1500), zone="Mandaue East")
    r = _plan([far_, near, mid])
    assert [_stop(r, x.ref)["route_order"] for x in (near, mid, far_)] == [1, 2, 3]


def test_a_neighbour_across_the_zone_line_joins_but_far_zones_wait():
    # Plenty of time in the day: the west donors and an east donor 1 km away
    # go together; a far east donor waits for the east zone's day.
    w1 = _d([TUE, WED], at=WEST, zone="Mandaue West")
    w2 = _d([TUE, WED], at=_east(WEST, 300), zone="Mandaue West")
    neighbour = _d([TUE, WED], at=_east(WEST, 1300), zone="Mandaue East")
    far_east = _d([TUE, WED], at=_east(EAST, 3000), zone="Mandaue East")
    r = _plan([w1, w2, neighbour, far_east])
    day = {x.ref: _stop(r, x.ref)["planned_date"] for x in (w1, w2, neighbour, far_east)}
    assert day[w1.ref] == day[w2.ref] == day[neighbour.ref] == "2026-10-13"
    assert day[far_east.ref] == "2026-10-14"
