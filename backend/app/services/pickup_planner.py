"""Door to Door pickup planner (Oct 12 notes, pickup logic v2, revised).

Decision support for CSWS Main Office (manuscript UC-D2 alt 7c, UC-CM1 for
Door to Door). The planner sorts; CSWS confirms. Nothing here asks the donor
for anything new.

Revision (Oct 12, afternoon): no scoring. There is no size or points
estimate and no report priority score. A stop is planned by plain rules
that staff can check by hand:

  1. Group:  donations whose pins are within GROUP_RADIUS_M of each other
             AND share at least one day become one stop (the stop keeps
             only the shared days).
  2. Dates:  CSWS pickup days from today, for window_days. A donation is
             never planned earlier than lead_days after it was made, nor on
             or before a day the picker found nobody home. A stop already
             in an open DRRMO pickup run keeps that run's date.
  3. Urgency (who goes first on a day), in this order:
             a. fewest allowed dates left in the window (a donor with one
                day left goes before a donor with four),
             b. closest handover deadline (days_left from donation_expiry),
             c. oldest donation first.
  4. Fill:   add stops in that order while the run still finishes within
             pickup hours; a stop that does not fit is tried on its next
             allowed day.
  5. Route:  one way from the CSWS office, nearest stop next, then remove
             crossings (2-opt) and move single stops to a better place
             (or-opt). Straight-line distance, not road distance
             (manuscript limitation: no live traffic or tracking).
  6. Left over: "no feasible day" with the reason, never silently lost.

Terms: donation = one QR code (one or more items); stop = one place the
picker visits; run = one trip on one date.

Pure Python (no database, no FastAPI) so every rule can be unit tested.
api/v1/pickup_plan_routes.py loads the rows and calls plan(). The time
settings below are placeholders; change them without code in .env:
    PICKUP_PLANNER_CONFIG='{"minutes_per_stop": 20, "speed_kmh": 15}'
"""
from __future__ import annotations

import json
import math
import os
from copy import deepcopy
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Optional

# ---------------------------------------------------------------------------
# Settings (placeholders until CSWS confirms them)
# ---------------------------------------------------------------------------
DEFAULTS: dict = {
    # Same landmark: pins closer than this become one stop (if a day matches).
    "group_radius_m": 50,
    # Plan window from today; a donation waits at least lead_days.
    "lead_days": 1,
    "window_days": 14,
    # Time model for "finishes within pickup hours"
    # (straight-line km x road_factor at speed_kmh, plus time at each stop).
    "speed_kmh": 20,
    "road_factor": 1.4,
    "minutes_per_stop": 15,
    "minutes_per_extra_donation": 5,
    # Open decision: does the 5:00 PM limit include driving back to CSWS?
    "include_return_trip": False,
    # Waiting this close to the handover deadline: staff should call.
    "call_donor_days_left": 3,
    # Packaging words that mean "load these first" (a label only, no score).
    "heavy_words": ["sack", "gallon"],
}


def planner_config(overrides: Optional[dict] = None) -> dict:
    """DEFAULTS, then PICKUP_PLANNER_CONFIG from .env, then [overrides]."""
    cfg = deepcopy(DEFAULTS)
    raw = os.getenv("PICKUP_PLANNER_CONFIG")
    if raw:
        try:
            cfg.update({k: v for k, v in json.loads(raw).items() if k in DEFAULTS})
        except (ValueError, TypeError, AttributeError):
            pass  # a typo in .env must not take the pickup map down
    if overrides:
        cfg.update(overrides)
    return cfg


def is_heavy(item: dict, cfg: dict) -> bool:
    text = (item.get("packaging") or "").lower()
    return any(w in text for w in cfg["heavy_words"])


# ---------------------------------------------------------------------------
# Inputs and stops
# ---------------------------------------------------------------------------
@dataclass
class Donation:
    """One QR batch waiting for a Door to Door pickup."""
    ref: str
    lat: Optional[float]
    lng: Optional[float]
    days: list
    items: list                            # [{item_name, unit, packaging, quantity}]
    created_at: Optional[datetime] = None  # Philippine time, naive
    not_home_date: Optional[date] = None   # "Not home" was pressed on this date
    run_date: Optional[date] = None        # already in an open DRRMO pickup run
    too_far: bool = False
    days_left: Optional[int] = None        # to the handover deadline
    view: dict = field(default_factory=dict)   # passthrough fields for the screens
    flags: list = field(default_factory=list)  # filled in by plan()


@dataclass
class Stop:
    donations: list
    days: set
    lat: float
    lng: float

    @property
    def stop_id(self) -> str:
        return "STOP-" + self.donations[0].ref

    @property
    def not_home_date(self) -> Optional[date]:
        dates = [d.not_home_date for d in self.donations if d.not_home_date]
        return max(dates) if dates else None

    @property
    def run_date(self) -> Optional[date]:
        dates = [d.run_date for d in self.donations if d.run_date]
        return min(dates) if dates else None

    @property
    def days_left(self) -> Optional[int]:
        left = [d.days_left for d in self.donations if d.days_left is not None]
        return min(left) if left else None

    @property
    def oldest(self) -> datetime:
        return min((d.created_at or datetime.max for d in self.donations))

    @property
    def newest(self) -> Optional[datetime]:
        made = [d.created_at for d in self.donations if d.created_at]
        return max(made) if made else None


def meters_between(a_lat, a_lng, b_lat, b_lng) -> float:
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp, dl = p2 - p1, math.radians(b_lng - a_lng)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371000 * 2 * math.asin(math.sqrt(h))


def km_between(a: tuple, b: tuple) -> float:
    return meters_between(a[0], a[1], b[0], b[1]) / 1000


def build_stops(donations: list, radius_m: float) -> list:
    """Same-landmark rule: one stop per place AND shared day.

    Donor A (Mon, Wed) + donor B (Tue, Wed) at the same school -> one stop,
    plannable only on Wednesday. A (Mon) + B (Tue) -> two stops.
    Oldest donations are placed first, so they keep their stop."""
    stops: list = []
    for d in sorted(donations, key=lambda x: (x.created_at or datetime.max, x.ref)):
        days = set(d.days)
        best = None
        for s in stops:
            if not (s.days & days):
                continue
            dist = meters_between(s.lat, s.lng, d.lat, d.lng)
            if dist <= radius_m and (best is None or dist < best[0]):
                best = (dist, s)
        if best is None:
            stops.append(Stop([d], days, d.lat, d.lng))
            continue
        s = best[1]
        s.donations.append(d)
        s.days &= days
        n = len(s.donations)
        s.lat = sum(x.lat for x in s.donations) / n
        s.lng = sum(x.lng for x in s.donations) / n
    return stops


# ---------------------------------------------------------------------------
# Route order: one way from the CSWS office
# ---------------------------------------------------------------------------
def _path_km(order: list, points: list, start: tuple) -> float:
    path = [start] + [points[i] for i in order]
    return sum(km_between(path[i - 1], path[i]) for i in range(1, len(path)))


def order_route(points: list, start: tuple) -> list:
    """Indexes of [points] in visiting order. Nearest next stop, then:
      * 2-opt: reverse a section when that shortens the path (removes
        crossings),
      * or-opt: move one stop to another place in the path when shorter.
    Repeats until nothing improves (at most 50 rounds)."""
    n = len(points)
    if n <= 1:
        return list(range(n))
    left = list(range(n))
    order: list = []
    here = start
    while left:
        nxt = min(left, key=lambda i: (km_between(here, points[i]), i))
        order.append(nxt)
        left.remove(nxt)
        here = points[nxt]

    best = _path_km(order, points, start)
    for _ in range(50):
        improved = False
        # 2-opt
        for i in range(n - 1):
            for j in range(i + 1, n):
                cand = order[:i] + order[i:j + 1][::-1] + order[j + 1:]
                km = _path_km(cand, points, start)
                if km + 1e-9 < best:
                    order, best, improved = cand, km, True
        # or-opt (relocate one stop)
        for i in range(n):
            rest = order[:i] + order[i + 1:]
            for k in range(n):
                if k == i:
                    continue
                cand = rest[:k] + [order[i]] + rest[k:]
                km = _path_km(cand, points, start)
                if km + 1e-9 < best:
                    order, best, improved = cand, km, True
                    break
            if improved:
                break
        if not improved:
            break
    return order


def route_stats(stops: list, office: tuple, cfg: dict) -> dict:
    """Ordered stops plus distance and minutes for one run."""
    pts = [(s.lat, s.lng) for s in stops]
    order = order_route(pts, office)
    km = _path_km(order, pts, office)
    if cfg["include_return_trip"] and order:
        km += km_between(pts[order[-1]], office)
    drive = km * float(cfg["road_factor"]) / float(cfg["speed_kmh"]) * 60
    service = sum(
        cfg["minutes_per_stop"] + cfg["minutes_per_extra_donation"] * (len(s.donations) - 1)
        for s in stops
    )
    return {"order": [stops[i] for i in order], "km": round(km, 2), "minutes": round(drive + service)}


# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------
def _clock(minutes_after_midnight: int) -> str:
    h, m = divmod(int(minutes_after_midnight), 60)
    return f"{(h % 12) or 12}:{m:02d} {'AM' if h < 12 else 'PM'}"


def _day_names(days) -> str:
    names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    return ", ".join(names[d - 1] for d in sorted(days)) or "no day"


def plan(
    donations: list,
    *,
    today: date,
    office: tuple,
    pickup_days: list,
    start_hour: int,
    end_hour: int,
    cfg: Optional[dict] = None,
) -> dict:
    """Which stop to collect on which date, in which order (see the module
    docstring for the rules)."""
    cfg = cfg or planner_config()
    day_minutes = (end_hour - start_hour) * 60

    # Staff flags per donation (labels, not scores)
    for d in donations:
        d.flags = []
        if d.days_left is not None and d.days_left <= cfg["call_donor_days_left"]:
            d.flags.append("call_donor")
        if d.run_date:
            d.flags.append("in_drrmo_run")
        if d.not_home_date:
            d.flags.append("missed_before")

    follow_up = [d for d in donations if d.lat is None or d.lng is None]
    pinned = [d for d in donations if d.lat is not None and d.lng is not None]
    near = build_stops([d for d in pinned if not d.too_far], cfg["group_radius_m"])
    far = build_stops([d for d in pinned if d.too_far], cfg["group_radius_m"])

    dates = [
        today + timedelta(days=i)
        for i in range(int(cfg["window_days"]))
        if (today + timedelta(days=i)).isoweekday() in pickup_days
    ]
    lead = timedelta(days=int(cfg["lead_days"]))

    def feasible(s: Stop) -> list:
        start = (s.newest.date() if s.newest else today) + lead
        skip = s.not_home_date
        ok = [x for x in dates
              if x.isoweekday() in s.days and x >= start and (skip is None or x > skip)]
        if s.run_date in ok:          # in a DRRMO run: that date only
            return [s.run_date]
        return ok

    def urgency(s: Stop, day: date) -> tuple:
        return (
            len([x for x in feasible(s) if x >= day]),               # a. fewest dates left
            s.days_left if s.days_left is not None else 10 ** 6,     # b. closest deadline
            s.oldest,                                                # c. oldest first
            s.stop_id,                                               # stable order
        )

    result: dict = {}
    remaining = list(near)
    runs: list = []
    for day in dates:
        run: list = []
        forced = [s for s in remaining if s.run_date == day and day in feasible(s)]
        run.extend(forced)
        candidates = sorted(
            (s for s in remaining if s not in forced and day in feasible(s)),
            key=lambda s: urgency(s, day),
        )
        for s in candidates:
            if route_stats(run + [s], office, cfg)["minutes"] > day_minutes:
                continue              # would not finish in time: next allowed day
            run.append(s)
        if not run:
            continue
        stats = route_stats(run, office, cfg)
        stop_ids = []
        for n, s in enumerate(stats["order"], start=1):
            left = [x for x in feasible(s) if x >= day]
            result[s.stop_id] = {
                "status": "planned",
                "planned_date": day.isoformat(),
                "route_order": n,
                "options_left": len(left),
                "last_chance": len(left) == 1 and s.run_date is None,
                "next_date": next((x.isoformat() for x in left if x > day), None),
            }
            stop_ids.append(s.stop_id)
        remaining = [s for s in remaining if s not in run]
        runs.append({
            "date": day.isoformat(),
            "weekday": day.isoweekday(),
            "stop_ids": stop_ids,
            "stops": len(stop_ids),
            "donations": sum(len(s.donations) for s in run),
            "km": stats["km"],
            "minutes": stats["minutes"],
            "finish_label": _clock(start_hour * 60 + stats["minutes"]),
            "heavy_stops": sum(
                1 for s in run if any(is_heavy(i, cfg) for d in s.donations for i in d.items)
            ),
        })

    for s in remaining:
        if not s.days:
            why = "The donors at this place share no pickup day."
        elif not feasible(s):
            why = (f"No CSWS pickup day in the next {cfg['window_days']} days matches "
                   f"{_day_names(s.days)}.")
        else:
            why = (f"Every {_day_names(s.days)} in the next {cfg['window_days']} days is full "
                   "(the run would end after pickup hours). Call the donor about another day.")
        result[s.stop_id] = {"status": "no_feasible_day", "reason": why}
    for s in far:
        result[s.stop_id] = {"status": "far", "reason": "Outside the pickup distance limit."}

    stops_out = [stop_view(s, result.get(s.stop_id, {}), cfg) for s in near + far]
    rank = {"planned": 0, "no_feasible_day": 1, "far": 2}
    stops_out.sort(key=lambda x: (rank[x["status"]], x.get("planned_date") or "",
                                  x.get("route_order") or 0, x["stop_id"]))
    return {
        "today": today.isoformat(),
        "window": {"from": dates[0].isoformat() if dates else None,
                   "to": dates[-1].isoformat() if dates else None,
                   "days": cfg["window_days"]},
        "hours": {"start_hour": start_hour, "end_hour": end_hour,
                  "label": f"{_clock(start_hour * 60)} to {_clock(end_hour * 60)}",
                  "includes_return_trip": bool(cfg["include_return_trip"])},
        "runs": runs,
        "stops": stops_out,
        "follow_up": [donation_view(d, cfg) for d in follow_up],
    }


def donation_view(d: Donation, cfg: dict) -> dict:
    return {
        **d.view,
        "batch_reference": d.ref,
        "pickup_days": sorted(d.days),
        "items": [
            {
                "item_name": i.get("item_name") or "Item",
                "unit": i.get("unit") or "",
                "packaging": i.get("packaging") or "",
                "quantity": i.get("quantity"),
                "heavy": is_heavy(i, cfg),
            }
            for i in d.items
        ],
        "flags": d.flags,
        "days_left": d.days_left,
        "not_home_date": d.not_home_date.isoformat() if d.not_home_date else None,
    }


def stop_view(s: Stop, planned: dict, cfg: dict) -> dict:
    first = s.donations[0]
    return {
        "stop_id": s.stop_id,
        "lat": round(s.lat, 6),
        "lng": round(s.lng, 6),
        "landmark": first.view.get("pickup_landmark") or "",
        "barangay": first.view.get("barangay"),
        "address": first.view.get("pickup_address") or "",
        "days": sorted(s.days),
        "donation_count": len(s.donations),
        "donations": [donation_view(d, cfg) for d in s.donations],
        "heavy": any(is_heavy(i, cfg) for d in s.donations for i in d.items),
        "days_left": s.days_left,
        "too_far": any(d.too_far for d in s.donations),
        "distance_km": first.view.get("distance_km"),
        "flags": sorted({f for d in s.donations for f in d.flags}),
        "status": planned.get("status", "no_feasible_day"),
        "reason": planned.get("reason"),
        "planned_date": planned.get("planned_date"),
        "route_order": planned.get("route_order"),
        "options_left": planned.get("options_left"),
        "last_chance": planned.get("last_chance", False),
        "next_date": planned.get("next_date"),
    }