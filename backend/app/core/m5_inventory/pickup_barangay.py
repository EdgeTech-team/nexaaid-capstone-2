"""Which barangay a Door to Door pickup is in, for the pickup list's
"group by barangay" view (Oct 12 notes).

The donor form has no barangay field and nothing new is asked of the
donor, so the barangay is read from the text the donor already gave:
  1. the typed address first (the donor knows their own barangay),
  2. then the landmark they picked (OpenStreetMap text, which ends with
     "..., <district>, <city>").
Within one text the match nearest the end wins, because both texts put
the barangay just before the city ("Pilit, Cabancalan, Mandaue").

Names come from the barangays table (the same list reports use) plus
Mandaue City's 27 barangays, so it works even if the table only has the
barangays that have reports. No match -> None ("Barangay not found" on
the screen). This is a label for sorting only: it is never saved and
changes nothing else.
"""
from __future__ import annotations

import re
from typing import Callable, Iterable, Optional

# Mandaue City's 27 barangays. Extra spellings people type are aliases.
MANDAUE_BARANGAYS: dict = {
    "Alang-alang": ["alang alang", "alangalang"],
    "Bakilid": [],
    "Banilad": [],
    "Basak": [],
    "Cabancalan": [],
    "Cambaro": [],
    "Canduman": [],
    "Casili": [],
    "Casuntingan": [],
    "Centro": ["centro poblacion", "poblacion"],
    "Cubacub": [],
    "Guizo": [],
    "Ibabao-Estancia": ["ibabao estancia", "ibabao", "estancia"],
    "Jagobiao": [],
    "Labogon": [],
    "Looc": [],
    "Maguikay": [],
    "Mantuyong": [],
    "Opao": [],
    "Pagsabungan": [],
    "Pakna-an": ["pakna an", "paknaan"],
    "Subangdaku": ["subang daku"],
    "Tabok": [],
    "Tawason": [],
    "Tingub": [],
    "Tipolo": [],
    "Umapad": [],
}

_PREFIX = re.compile(r"^(brgy|barangay|bgy)\b\.?\s*", re.I)


def _norm(text: str) -> str:
    """'Brgy. Ibabao-Estancia' -> 'ibabao estancia'."""
    text = _PREFIX.sub("", (text or "").strip())
    return " ".join(re.sub(r"[^a-z0-9]+", " ", text.lower()).split())


def barangay_finder(names: Iterable[str]) -> Callable[..., Optional[str]]:
    """A function find(address, landmark) -> barangay name or None.
    [names] are the barangay names in the database; Mandaue's list is added."""
    keys: dict = {}            # normalized key -> display name
    for name, aliases in MANDAUE_BARANGAYS.items():
        for key in [_norm(name), *aliases]:
            keys.setdefault(key, name)
    for name in names:         # the database's spelling wins for display
        key = _norm(name)
        if len(key) < 4:
            continue
        old = keys.get(key)
        if old is not None:    # same barangay as a built-in one: rename it
            for k, v in list(keys.items()):
                if v == old:
                    keys[k] = name
        keys[key] = name
    # Longer keys first, so "ibabao estancia" beats "ibabao".
    ordered = sorted(keys.items(), key=lambda kv: -len(kv[0]))
    patterns = [(re.compile(rf"(?<![a-z0-9]){re.escape(k)}(?![a-z0-9])"), v) for k, v in ordered]

    def find(*texts: Optional[str]) -> Optional[str]:
        for text in texts:
            t = _norm(text or "")
            if not t:
                continue
            best = None            # (end position, -key length, name)
            for pat, name in patterns:
                for m in pat.finditer(t):
                    cand = (m.end(), m.end() - m.start(), name)
                    if best is None or cand[:2] > best[:2]:
                        best = cand
            if best:
                return best[2]
        return None

    return find