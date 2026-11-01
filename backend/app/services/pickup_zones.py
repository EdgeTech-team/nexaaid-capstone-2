"""Fixed pickup zones for Door to Door (testing, Oct 31).

CSWS collects Door to Door donations zone by zone, so one day's run stays
in one part of the service area instead of crossing it ("cluster first,
route second": services/pickup_planner.py groups a day by zone, then
orders it by the shortest route).

A donation's zone is read from what the donor already gave, in order:
  1. the city in the address or landmark text (Lapu-Lapu, Consolacion,
     Cebu City, Mandaue);
  2. for Mandaue and Cebu City, the barangay in that text decides the zone
     (Cebu City follows its North and South districts);
  3. a city but no barangay in the text (e.g. "SM City Cebu, North
     Reclamation Area, Cebu City"): that city's zone nearest the map pin;
  4. nothing in the text: the zone whose centre is nearest the map pin.

Change the zones here only (names, barangays, centres). Mandaue's split
is the team's proposal for CSWS to confirm; Cebu City follows its two
congressional districts.
"""
from __future__ import annotations

import math
import re
from typing import Optional

from services.pickup_barangay import barangay_finder

# name, short code, the city it belongs to, its barangays (empty = every
# barangay of that city not in another zone), and a rough centre (lat, lng)
# used when the text names no city or barangay.
ZONES: list = [
    {
        "name": "Mandaue North",
        "code": "MN",
        "city": "Mandaue",
        "barangays": ["Canduman", "Casili", "Cabancalan", "Pagsabungan", "Tingub",
                      "Tawason", "Cubacub", "Jagobiao"],
        "center": (10.372, 123.938),
    },
    {
        "name": "Mandaue West",
        "code": "MW",
        "city": "Mandaue",
        "barangays": ["Banilad", "Bakilid", "Subangdaku", "Tipolo", "Casuntingan",
                      "Maguikay", "Guizo"],
        "center": (10.336, 123.930),
    },
    {
        "name": "Mandaue East",
        "code": "ME",
        "city": "Mandaue",
        "barangays": ["Centro", "Mantuyong", "Ibabao-Estancia", "Alang-alang", "Looc",
                      "Cambaro", "Opao", "Tabok", "Basak", "Umapad", "Labogon", "Pakna-an"],
        "center": (10.335, 123.953),
    },
    {
        "name": "Cebu City North",
        "code": "CN",
        "city": "Cebu City",
        "barangays": ["Adlaon", "Agsungot", "Apas", "Bacayan", "Banilad", "Binaliw",
                      "Budla-an", "Busay", "Cambinocot", "Capitol Site", "Carreta",
                      "Cogon Ramos", "Day-as", "Ermita", "Guba", "Hipodromo", "Kalubihan",
                      "Kamagayan", "Kamputhaw", "Kasambagan", "Lahug", "Lorega San Miguel",
                      "Lusaran", "Luz", "Mabini", "Mabolo", "Malubog", "Pahina Central",
                      "Parian", "Paril", "Pit-os", "Pulangbato", "Sambag I", "Sambag II",
                      "San Antonio", "San Jose", "San Roque", "Santa Cruz", "Santo Niño",
                      "Sirao", "T. Padilla", "Talamban", "Taptap", "Tejero", "Tinago",
                      "Zapatera"],
        "center": (10.335, 123.905),
    },
    {
        "name": "Cebu City South",
        "code": "CS",
        "city": "Cebu City",
        "barangays": ["Babag", "Basak Pardo", "Basak San Nicolas", "Bonbon", "Buhisan",
                      "Bulacao", "Buot-Taup Pardo", "Calamba", "Cogon Pardo", "Duljo Fatima",
                      "Guadalupe", "Inayawan", "Kalunasan", "Kinasang-an Pardo", "Labangon",
                      "Mambaling", "Pahina San Nicolas", "Pamutan", "Pardo", "Pasil",
                      "Poblacion Pardo", "Pung-ol Sibugay", "Punta Princesa", "Quiot Pardo",
                      "San Nicolas Proper", "Sapangdaku", "Sawang Calero", "Sinsin", "Suba",
                      "Sudlon I", "Sudlon II", "Tabunan", "Tagba-o", "Tisa", "Toong"],
        "center": (10.290, 123.875),
    },
    {
        "name": "Lapu-Lapu (Mactan)",
        "code": "LL",
        "city": "Lapu-Lapu",
        "barangays": [],
        "center": (10.310, 123.965),
    },
    {
        "name": "Consolacion",
        "code": "CO",
        "city": "Consolacion",
        "barangays": [],
        "center": (10.378, 123.958),
    },
]

# How a city is written in addresses and OpenStreetMap text.
_CITY_WORDS = {
    "Lapu-Lapu": ["lapu lapu", "lapulapu", "mactan", "opon"],
    "Consolacion": ["consolacion"],
    "Cebu City": ["cebu city", "lungsod sa sugbo"],
    "Mandaue": ["mandaue"],
}


def _norm(text: Optional[str]) -> str:
    return " ".join(re.sub(r"[^a-z0-9ñ]+", " ", (text or "").lower()).split())


def _has(text: str, word: str) -> bool:
    return re.search(rf"(?<![a-z0-9]){re.escape(word)}(?![a-z0-9])", text) is not None


def _km(a: tuple, b: tuple) -> float:
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(h))


_MANDAUE = barangay_finder([])


def _nearest(zones: list, lat: Optional[float], lng: Optional[float]) -> Optional[str]:
    if lat is None or lng is None or not zones:
        return None
    return min(zones, key=lambda z: _km(z["center"], (lat, lng)))["name"]


def zone_names() -> list:
    return [z["name"] for z in ZONES]


def zone_of(address: Optional[str], landmark: Optional[str],
            lat: Optional[float] = None, lng: Optional[float] = None) -> Optional[str]:
    """The zone of one pickup (see the module docstring for the rules)."""
    for raw in (address, landmark):
        text = _norm(raw)
        if not text:
            continue
        city = next((c for c, words in _CITY_WORDS.items()
                     if any(_has(text, w) for w in words)), None)
        if city == "Cebu City":
            cebu = [z for z in ZONES if z["city"] == city]
            for z in cebu:
                if any(_has(text, _norm(b)) for b in z["barangays"]):
                    return z["name"]
            return _nearest(cebu, lat, lng) or "Cebu City South"
        if city in ("Lapu-Lapu", "Consolacion"):
            return next(z["name"] for z in ZONES if z["city"] == city)
        # Mandaue, or no city written: a Mandaue barangay decides.
        brgy = _MANDAUE(raw)
        if brgy:
            for z in ZONES:
                if z["city"] == "Mandaue" and brgy in z["barangays"]:
                    return z["name"]
        if city == "Mandaue":
            near = _nearest([z for z in ZONES if z["city"] == city], lat, lng)
            if near:
                return near
    return _nearest(ZONES, lat, lng)


def zone_center(name: Optional[str]) -> Optional[tuple]:
    return next((z["center"] for z in ZONES if z["name"] == name), None)
