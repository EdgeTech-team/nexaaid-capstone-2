"""Door to Door service area: geofencing by city (Oct 2026, Module 7).

CSWS only picks up donations in Mandaue City and the cities and
municipalities next to it. Everyone else chooses Drop Off.

How a pin is checked:
  1. Reverse geocode the pin with OpenStreetMap (Photon, the same
     geocoder the landmark search uses). Its `city` field comes from
     OSM's official city/municipal boundaries, so the fence follows the
     real borders without us drawing polygons.
  2. Accepted if that city is in PICKUP_CITIES.
  3. Geocoder down: fall back to distance, accepted when the pin is
     within PICKUP_MAX_KM of the CSWS office (never blocks a donor
     because a free server was slow).

Set the list in .env (comma-separated, OSM spellings):
    PICKUP_CITIES=Mandaue,Lapu-Lapu,Consolacion,Cebu City
"""
from __future__ import annotations

import os
import re
from typing import Callable, Optional

DEFAULT_PICKUP_CITIES = "Mandaue,Lapu-Lapu,Consolacion,Cebu City"

# Other spellings people (and OSM) use for the same place.
_ALIASES = {
    "mandaue city": "mandaue",
    "lapu lapu city": "lapu lapu",
    "lapulapu": "lapu lapu",
    "opon": "lapu lapu",
    "cebu": "cebu city",
}


def _norm(name: Optional[str]) -> str:
    """'Lapu-Lapu City' -> 'lapu lapu' (so spellings compare equal)."""
    key = " ".join(re.sub(r"[^a-z0-9]+", " ", (name or "").lower()).split())
    key = _ALIASES.get(key, key)
    if key.endswith(" city") and key != "cebu city":
        key = _ALIASES.get(key[: -len(" city")], key[: -len(" city")])
    return key


def pickup_cities() -> list:
    """The accepted cities, for display ("Mandaue, Lapu-Lapu, ...")."""
    raw = os.getenv("PICKUP_CITIES", DEFAULT_PICKUP_CITIES)
    return [c.strip() for c in raw.split(",") if c.strip()]


def city_allowed(city: Optional[str]) -> bool:
    allowed = {_norm(c) for c in pickup_cities()}
    return bool(city) and _norm(city) in allowed


def check_pin(
    lat: float,
    lng: float,
    reverse_city: Callable[[float, float], Optional[str]],
    km_from_office: Callable[[float, float], Optional[float]],
    max_km: float,
) -> dict:
    """{allowed, city, checked_by: "city" | "distance", message}.
    [reverse_city] returns the OSM city of a pin or raises on failure."""
    try:
        city = reverse_city(lat, lng)
    except Exception:
        city = None
        km = km_from_office(lat, lng)
        allowed = km is not None and km <= max_km
        return {
            "allowed": allowed, "city": None, "checked_by": "distance",
            "message": None if allowed else (
                f"This pin is about {km} km from the CSWS office, outside the "
                f"Door to Door area ({', '.join(pickup_cities())}). Choose Drop Off."),
        }
    allowed = city_allowed(city)
    return {
        "allowed": allowed, "city": city, "checked_by": "city",
        "message": None if allowed else (
            f"CSWS picks up only in {', '.join(pickup_cities())}"
            f"{f', not {city}' if city else ''}. Choose a landmark there, or choose Drop Off."),
    }
