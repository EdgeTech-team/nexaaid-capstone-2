"""Door to Door pickup planner ("Pickup logic v2", Oct 12 notes).

Decision support for CSWS Main Office (manuscript UC-D2 alt 7c, UC-CM1 for
Door to Door). The planner does the math; CSWS confirms. Nothing here asks
the donor for anything new: the size of a pickup is worked out from the
fields the donor form already has (packaging, quantity, "What are you
giving?").

Three terms are kept apart on purpose:
    donation  one submission from the donor form: one QR code
              (batch_reference), one or more items
    stop      one place the picker visits: one or more donations whose pins
              are within GROUP_RADIUS_M of each other AND that share at
              least one day (the stop keeps only the shared days)
    run       one vehicle trip on one date: ordered stops

This module is pure Python (no database, no FastAPI) so every rule can be
unit tested. api/v1/pickup_plan_routes.py loads the rows and calls plan().

Every size and capacity number below is a PLACEHOLDER until CSWS confirms
what vehicles they use and what one "Pack" looks like. Change them without
code in .env:
    PICKUP_PLANNER_CONFIG='{"vehicles": [{"key": "van", "name": "Van",
                            "points": 20}], "fill_target": 0.8}'
Any key of DEFAULTS can be overridden; nested "packaging" entries are
merged one by one.
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
# Settings (placeholders, see the module docstring)
# ---------------------------------------------------------------------------
# "points" is a unit of space. One 50 kg sack = 5 points. A vehicle's
# capacity is in the same points. "kg" is recorded now so a weight limit
# can be added later without a redesign (it is not enforced yet).
# confidence: "reliable" (size is built into the packaging), "estimate"
# (a typical size is assumed) or "uncertain" (no size at all: planned with
# a conservative medium size and shown with a "?").
DEFAULTS: dict = {
    "packaging": {
        "Sack (50 kg)": {"points": 5.0, "kg": 50, "confidence": "reliable", "heavy": True},
        "Sack (25 kg)": {"points": 2.5, "kg": 25, "confidence": "reliable", "heavy": True},
        "Box": {"points": 1.5, "kg": 8, "confidence": "estimate", "heavy": False},
        "Pack": {"points": 0.8, "kg": 3, "confidence": "estimate", "heavy": False},
        "Plastic bag": {"points": 0.4, "kg": 2, "confidence": "estimate", "heavy": False},
        "Bottle": {"points": 0.2, "kg": 1.5, "confidence": "estimate", "heavy": False},
        "Gallon container": {"points": 1.2, "kg": 19, "confidence": "estimate", "heavy": True},
        "Loose / no packaging": {"points": 2.5, "kg": 5, "confidence": "uncertain", "heavy": False},
        "Other": {"points": 2.5, "kg": 5, "confidence": "uncertain", "heavy": False},
    },
    # "What are you giving?" is only a small hint: light but bulky goods
    # take a bit more space. Not applied to sacks (their size is fixed).
    "bulky_words": ["cloth", "blanket", "mat", "pillow", "towel", "diaper", "mattress", "jacket"],
    "bulky_factor": 1.25,
    # Size classes by the stop's total points: S < 2 <= M < 5 <= L < 15 <= XL
    "size_classes": [
        {"key": "S", "max_points": 2, "label": "Small", "hint": "Fits in a bag or the passenger seat"},
        {"key": "M", "max_points": 5, "label": "Medium", "hint": "A few boxes"},
        {"key": "L", "max_points": 15, "label": "Large", "hint": "Sacks or many boxes"},
        {"key": "XL", "max_points": None, "label": "Extra large", "hint": "Needs a truck"},
    ],
    "vehicles": [
        {"key": "car", "name": "Car", "points": 6, "kg": 400},
        {"key": "van", "name": "Van", "points": 18, "kg": 1000},
        {"key": "truck", "name": "Truck", "points": 60, "kg": 4000},
    ],
    "default_vehicle": "van",
    # Plan to about 85% of the vehicle so estimate errors don't leave
    # goods behind.
    "fill_target": 0.85,
    # Same landmark: pins closer than this become one stop (if a day matches).
    "group_radius_m": 50,
    # Plan 14 days from today; a donation waits at least 1 day (lead time).
    "lead_days": 1,
    "window_days": 14,
    # Time model for "finishes within pickup hours" (straight line x road factor).
    "speed_kmh": 20,
    "road_factor": 1.4,
    "minutes_per_stop": 15,
    "minutes_per_extra_donation": 5,
    # Open decision: does the 5:00 PM limit include driving back to CSWS?
    "include_return_trip": False,
    # Staff-side sanity flags (no form change).
    "review_quantity": 200,
    # Waiting this close to the handover deadline (donation_expiry): call the donor.
    "call_donor_days_left": 3,
}

PRIORITY_LEVELS = {"critical": 100, "high": 75, "medium": 50, "moderate": 50, "low": 25}


def _merge(base: dict, extra: dict) -> dict:
    out = deepcopy(base)
    for k, v in (extra or {}).items():
        if k == "packaging" and isinstance(v, dict):
            for name, spec in v.items():
                out["packaging"][name] = {**out["packaging"].get(name, {}), **spec}
        else:
            out[k] = v
    return out


def planner_config(overrides: Optional[dict] = None) -> dict:
    """DEFAULTS, then PICKUP_PLANNER_CONFIG from .env, then [overrides]."""
    cfg = deepcopy(DEFAULTS)
    raw = os.getenv("PICKUP_PLANNER_CONFIG")
    if raw:
        try:
            cfg = _merge(cfg, json.loads(raw))
        except (ValueError, TypeError):
            pass  # a typo in .env must not take the pickup map down
    if overrides:
        cfg = _merge(cfg, overrides)
    return cfg


# ---------------------------------------------------------------------------
# Size from the fields the donor already fills in
# ---------------------------------------------------------------------------
def packaging_spec(packaging: Optional[str], cfg: dict) -> tuple[str, dict]:
    """The packaging option this text means, and its assumed size.
    Unknown text (older entries, e.g. just "Sack") is matched loosely and
    otherwise treated like "Other": conservative and uncertain."""
    table = cfg["packaging"]
    text = (packaging or "").strip()
    for name, spec in table.items():
        if name.lower() == text.lower():
            return name, spec
    low = text.lower()
    if "sack" in low:
        if "25" in low:
            return "Sack (25 kg)", table["Sack (25 kg)"]
        # A sack with no size: plan as the big one, but say it is a guess.
        return text or "Sack", {**table["Sack (50 kg)"], "confidence": "uncertain"}
    for name, spec in table.items():
        if low and name.lower() in low:      # e.g. "Box (big)" -> Box
            return name, spec
    return "Other", table["Other"]


_RANK = {"reliable": 0, "estimate": 1, "uncertain": 2}


def worst(confidences) -> str:
    c = list(confidences)
    return max(c, key=lambda x: _RANK.get(x, 2)) if c else "reliable"


def item_size(item: dict, cfg: dict) -> dict:
    """{points, kg, confidence, heavy} for one line: packaging x quantity,
    nudged by what is being given."""
    _, spec = packaging_spec(item.get("packaging"), cfg)
    qty = max(int(item.get("quantity") or 0), 0)
    points = float(spec["points"]) * qty
    words = f"{item.get('item_name') or ''} {item.get('category') or ''}".lower()
    if "sack" not in (item.get("packaging") or "").lower() and any(w in words for w in cfg["bulky_words"]):
        points *= float(cfg["bulky_factor"])
    return {
        "points": round(points, 2),
        "kg": round(float(spec.get("kg", 0)) * qty, 1),
        "confidence": spec.get("confidence", "uncertain"),
        "heavy": bool(spec.get("heavy")),
    }


def size_class(points: float, cfg: dict) -> str:
    for c in cfg["size_classes"]:
        if c["max_points"] is None or points < c["max_points"]:
            return c["key"]
    return cfg["size_classes"][-1]["key"]


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
    items: list                        # [{item_name, unit, category, packaging, quantity}]
    created_at: Optional[datetime] = None  # Philippine time, naive
    not_home_date: Optional[date] = None   # "Not home" was pressed on this date
    run_date: Optional[date] = None        # already in an open DRRMO pickup run
    too_far: bool = False
    priority: float = 0.0
    days_left: Optional[int] = None
    view: dict = field(default_factory=dict)   # passthrough fields for the screens

    # Filled in by plan()
    size: dict = field(default_factory=dict)
    flags: list = field(default_factory=list)


@dataclass
class Stop:
    donations: list
    days: set
    lat: float
    lng: float

    @property
    def points(self) -> float:
        return round(sum(d.size["points"] for d in self.donations), 2)

    @property
    def kg(self) -> float:
        return round(sum(d.size["kg"] for d in self.donations), 1)

    @property
    def confidence(self) -> str:
        return worst(d.size["confidence"] for d in self.donations)

    @property
    def not_home_date(self) -> Optional[date]:
        dates = [d.not_home_date for d in self.donations if d.not_home_date]
        return max(dates) if dates else None

    @property
    def run_date(self) -> Optional[date]:
        dates = [d.run_date for d in self.donations if d.run_date]
        return min(dates) if dates else None

    @property
    def stop_id(self) -> str:
        return "STOP-" + self.donations[0].ref

    @property
    def priority(self) -> float:
        return max((d.priority for d in self.donations), default=0.0)

    @property
    def oldest(self) -> datetime:
        return min((d.created_at or datetime.max for d in self.donations))


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
# Route order: one way from the CSWS office, nearest next, then untangle
# (same rule as mobile/lib/ui/pickup_route.dart). Straight-line distance,
# not road distance: manuscript Limitation 5 (no live traffic or tracking).
# ---------------------------------------------------------------------------
def order_route(points: list, start: tuple) -> list:
    n = len(points)
    if n <= 1:
        return list(range(n))
    left = list(range(n))
    order: list = []
    here = start
    while left:
        nxt = min(left, key=lambda i: km_between(here, points[i]))
        order.append(nxt)
        left.remove(nxt)
        here = points[nxt]

    def at(k):
        return start if k < 0 else points[order[k]]

    improved, rounds = True, 0
    while improved and rounds < 50:
        improved, rounds = False, rounds + 1
        for i in range(0, n - 1):
            for j in range(i + 1, n):
                a, b, c = at(i - 1), at(i), at(j)
                tail = at(j + 1) if j + 1 < n else None
                before = km_between(a, b) + (km_between(c, tail) if tail else 0)
                after = km_between(a, c) + (km_between(b, tail) if tail else 0)
                if after + 1e-9 < before:
                    order[i:j + 1] = reversed(order[i:j + 1])
                    improved = True
    return order


def route_stats(stops: list, office: tuple, cfg: dict) -> dict:
    """Ordered stops plus distance and time for one run."""
    pts = [(s.lat, s.lng) for s in stops]
    order = order_route(pts, office)
    path = [office] + [pts[i] for i in order]
    km = sum(km_between(path[i - 1], path[i]) for i in range(1, len(path)))
    if cfg["include_return_trip"] and len(path) > 1:
        km += km_between(path[-1], office)
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


def _round5(pct: float) -> int:
    return int(5 * round(pct / 5))


def plan(
    donations: list,
    *,
    today: date,
    office: tuple,
    pickup_days: list,
    start_hour: int,
    end_hour: int,
    vehicle_key: Optional[str] = None,
    cfg: Optional[dict] = None,
) -> dict:
    """Suggest which stop to collect on which date, in which order.

    Rules (Pickup logic v2, section 5):
      * dates: from today for window_days, CSWS pickup days only; a
        donation is planned no earlier than lead_days after it was made
      * a stop can go on a date whose weekday all its donors allow, and only
        after the date "Not home" was pressed
      * stops already in a DRRMO run go on that run's date first
      * least flexibility first (fewest dates left), then report priority,
        then the oldest donation
      * add a stop only if the run stays within fill_target of the vehicle
        AND still finishes within pickup hours; otherwise try the next one
      * order nearest-first from the office, then untangle crossings
      * leftovers: "no feasible day" with a reason, never silently lost
    """
    cfg = cfg or planner_config()
    vehicles = cfg["vehicles"]
    vehicle = next((v for v in vehicles if v["key"] == (vehicle_key or cfg["default_vehicle"])), None)
    vehicle = vehicle or next((v for v in vehicles if v["key"] == cfg["default_vehicle"]), vehicles[0])
    cap = float(vehicle["points"])
    budget = cap * float(cfg["fill_target"])
    biggest = max(float(v["points"]) for v in vehicles)
    day_minutes = (end_hour - start_hour) * 60

    # 1. Size and staff flags per donation
    for d in donations:
        sizes = [item_size(i, cfg) for i in d.items]
        for i, s in zip(d.items, sizes):
            i["_size"] = s
        d.size = {
            "points": round(sum(s["points"] for s in sizes), 2),
            "kg": round(sum(s["kg"] for s in sizes), 1),
            "confidence": worst(s["confidence"] for s in sizes),
            "heavy": any(s["heavy"] for s in sizes),
        }
        d.flags = []
        if any(int(i.get("quantity") or 0) >= cfg["review_quantity"] for i in d.items):
            d.flags.append("needs_review_quantity")
        if d.items and all(packaging_spec(i.get("packaging"), cfg)[0] == "Other" for i in d.items):
            d.flags.append("needs_review_other")
        if d.days_left is not None and d.days_left <= cfg["call_donor_days_left"]:
            d.flags.append("call_donor")
        if d.run_date:
            d.flags.append("in_drrmo_run")

    follow_up = [d for d in donations if d.lat is None or d.lng is None]
    pinned = [d for d in donations if d.lat is not None and d.lng is not None]
    near = build_stops([d for d in pinned if not d.too_far], cfg["group_radius_m"])
    far = build_stops([d for d in pinned if d.too_far], cfg["group_radius_m"])

    # 2. Dates in the window: from today (so the picker still sees today's
    #    run while doing it) for window_days, CSWS pickup days only. The lead
    #    time applies to each donation: earliest = submitted + lead_days, so a
    #    donation made today is never planned for later today.
    dates = [
        today + timedelta(days=i)
        for i in range(int(cfg["window_days"]))
        if (today + timedelta(days=i)).isoweekday() in pickup_days
    ]
    lead = timedelta(days=int(cfg["lead_days"]))

    def earliest(s: Stop) -> date:
        made = [d.created_at.date() for d in s.donations if d.created_at]
        return (max(made) if made else today) + lead

    def feasible(s: Stop) -> list:
        skip = s.not_home_date
        start = earliest(s)
        ok = [x for x in dates
              if x.isoweekday() in s.days and x >= start and (skip is None or x > skip)]
        # Already in a DRRMO run: that run's date only (CSWS cancels the run
        # to move it).
        if s.run_date in ok:
            return [s.run_date]
        return ok

    result: dict = {}   # stop_id -> dict of plan fields
    special = [s for s in near if s.points > biggest]
    for s in special:
        result[s.stop_id] = {
            "status": "special_handling",
            "reason": f"Bigger than the biggest vehicle ({vehicle_name(vehicles, biggest)}). "
                      "Plan this pickup by hand or ask for more vehicles.",
        }
    remaining = [s for s in near if s.stop_id not in result]
    runs: list = []

    for day in dates:
        run: list = []
        used = 0.0
        forced = [s for s in remaining if s.run_date == day and day in feasible(s)]
        for s in forced:
            run.append(s)
            used += s.points
        candidates = [s for s in remaining if s not in forced and day in feasible(s)]
        candidates.sort(key=lambda s: (
            len([x for x in feasible(s) if x >= day]),   # least flexibility first
            -s.priority,                                  # report priority breaks ties
            s.oldest,
        ))
        for s in candidates:
            if used + s.points > budget + 1e-9:
                continue            # too big for what is left: try a smaller one
            if route_stats(run + [s], office, cfg)["minutes"] > day_minutes:
                continue            # would not finish within pickup hours
            run.append(s)
            used += s.points
        if not run:
            continue
        stats = route_stats(run, office, cfg)
        cum = 0.0
        stop_ids = []
        for n, s in enumerate(stats["order"], start=1):
            cum += s.points
            left = [x for x in feasible(s) if x >= day]
            result[s.stop_id] = {
                "status": "planned",
                "planned_date": day.isoformat(),
                "route_order": n,
                "fullness_after_pct": _round5(cum / cap * 100),
                "options_left": len(left),
                "last_chance": len(left) == 1 and s.run_date is None,
                "next_date": next((x.isoformat() for x in left if x > day), None),
            }
            stop_ids.append(s.stop_id)
        remaining = [s for s in remaining if s not in run]
        finish = start_hour * 60 + stats["minutes"]
        runs.append({
            "date": day.isoformat(),
            "weekday": day.isoweekday(),
            "stop_ids": stop_ids,
            "stops": len(stop_ids),
            "donations": sum(len(s.donations) for s in run),
            "points": round(used, 2),
            "kg": round(sum(s.kg for s in run), 1),
            "fullness_pct": _round5(used / cap * 100),
            "km": stats["km"],
            "minutes": stats["minutes"],
            "finish_label": _clock(finish),
            "uncertain_stops": sum(1 for s in run if s.confidence == "uncertain"),
            "heavy_stops": sum(1 for s in run if any(d.size["heavy"] for d in s.donations)),
        })

    # 3. Leftovers: say why
    for s in remaining:
        options = feasible(s)
        if not s.days:
            why = "The donors at this place share no pickup day."
        elif not options:
            why = (f"No CSWS pickup day in the next {cfg['window_days']} days matches "
                   f"{_day_names(s.days)}.")
        elif s.points > budget:
            why = (f"Too big for the {vehicle['name'].lower()} (about "
                   f"{_round5(s.points / cap * 100)}% of it). Choose a bigger vehicle.")
        else:
            why = (f"Every {_day_names(s.days)} in the next {cfg['window_days']} days is full. "
                   "Call the donor about another day.")
        result[s.stop_id] = {"status": "no_feasible_day", "reason": why}
    for s in far:
        result[s.stop_id] = {"status": "far", "reason": "Outside the pickup distance limit."}

    stops_out = [stop_view(s, result.get(s.stop_id, {}), cfg) for s in near + far]
    order_key = {"planned": 0, "no_feasible_day": 1, "special_handling": 2, "far": 3}
    stops_out.sort(key=lambda x: (order_key[x["status"]], x.get("planned_date") or "",
                                  x.get("route_order") or 0))
    return {
        "today": today.isoformat(),
        "window": {"from": dates[0].isoformat() if dates else None,
                   "to": dates[-1].isoformat() if dates else None,
                   "days": cfg["window_days"]},
        "hours": {"start_hour": start_hour, "end_hour": end_hour,
                  "label": f"{_clock(start_hour * 60)} to {_clock(end_hour * 60)}",
                  "includes_return_trip": bool(cfg["include_return_trip"])},
        "vehicle": vehicle,
        "vehicles": vehicles,
        "fill_target": cfg["fill_target"],
        "size_classes": cfg["size_classes"],
        "runs": runs,
        "stops": stops_out,
        "follow_up": [donation_view(d, cfg) for d in follow_up],
    }


def vehicle_name(vehicles: list, points: float) -> str:
    v = next((v for v in vehicles if float(v["points"]) == points), None)
    return (v or {}).get("name", "biggest vehicle").lower()


def donation_view(d: Donation, cfg: dict) -> dict:
    items = []
    for i in d.items:
        s = i.get("_size") or item_size(i, cfg)
        items.append({
            "item_name": i.get("item_name") or "Item",
            "unit": i.get("unit") or "",
            "packaging": i.get("packaging") or "",
            "quantity": i.get("quantity"),
            "heavy": s["heavy"],
            "confidence": s["confidence"],
            "points": s["points"],
        })
    return {
        **d.view,
        "batch_reference": d.ref,
        "pickup_days": sorted(d.days),
        "items": items,
        "size": {**d.size, "class": size_class(d.size.get("points", 0), cfg)},
        "flags": d.flags,
        "days_left": d.days_left,
        "not_home_date": d.not_home_date.isoformat() if d.not_home_date else None,
    }


def stop_view(s: Stop, planned: dict, cfg: dict) -> dict:
    first = s.donations[0]
    flags = sorted({f for d in s.donations for f in d.flags})
    if s.confidence == "uncertain":
        flags.append("uncertain_size")
    return {
        "stop_id": s.stop_id,
        "lat": round(s.lat, 6),
        "lng": round(s.lng, 6),
        "landmark": first.view.get("pickup_landmark") or "",
        "address": first.view.get("pickup_address") or "",
        "days": sorted(s.days),
        "donation_count": len(s.donations),
        "donations": [donation_view(d, cfg) for d in s.donations],
        "size": {
            "points": s.points,
            "kg": s.kg,
            "class": size_class(s.points, cfg),
            "confidence": s.confidence,
            "heavy": any(d.size["heavy"] for d in s.donations),
        },
        "too_far": any(d.too_far for d in s.donations),
        "distance_km": first.view.get("distance_km"),
        "flags": flags,
        "status": planned.get("status", "no_feasible_day"),
        "reason": planned.get("reason"),
        "planned_date": planned.get("planned_date"),
        "route_order": planned.get("route_order"),
        "fullness_after_pct": planned.get("fullness_after_pct"),
        "options_left": planned.get("options_left"),
        "last_chance": planned.get("last_chance", False),
        "next_date": planned.get("next_date"),
    }