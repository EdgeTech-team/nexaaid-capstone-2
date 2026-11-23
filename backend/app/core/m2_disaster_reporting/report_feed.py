"""
NF-003 (Donor, Organization, guest): the validated reports feed.

The donor Reports tab and the guest Donate page used to get every validated
report through GET /lookups (`validated_reports`) and filter / sort them in
the app (mobile/lib/core/m4_donation_management/donor_screens.dart, ReportsFeed). GET
/public/reports/feed does the same filtering and sorting on the server and
sends 20 at a time; the row shape is the same one /lookups sends.
"""
from typing import Optional

from fastapi import HTTPException

QUICK = ("all", "urgent", "needs", "fulfilled")
SORTS = ("urgent", "least_fulfilled", "most_fulfilled", "most_families", "newest")
URGENT = ("Critical", "High")
_RANK = ("critical", "high", "medium", "low")


def pct(r) -> float:
    return float(r.fulfillment.fulfillment_percentage) if r.fulfillment else 0.0


def feed_row(r, types: dict, barangays: dict, progress: dict, label) -> dict:
    """One validated report as the donor screens show it (UC-D2 step 2:
    needs, priority guidance and fulfillment status). Shared with /lookups."""
    return {
        "id": r.report_id,
        "name": f"{label(r)} - {r.priority_level or 'No priority'}",
        "disaster": r.disaster_label(types),
        "barangay": barangays.get(r.barangay_id, "Barangay"),
        "barangay_id": r.barangay_id,
        # NF-003: reports created together for several barangays share an
        # event; the donor screens show them as one card.
        "event_id": r.event_id,
        "event_name": r.event_name,
        "sitio": ", ".join(r.sitio_names) or None,
        "sitios": r.sitio_names,
        "priority_level": r.priority_level,
        "assistance_needed": r.assistance_needed,
        "affected_families": r.affected_families,
        "description": r.description,
        "total_items_needed": r.fulfillment.total_items_needed if r.fulfillment else r.estimated_quantity,
        "total_items_delivered": r.fulfillment.total_items_delivered if r.fulfillment else 0,
        "fulfillment_percentage": pct(r),
        # Per need: needed / pledged / confirmed / delivered, so the donate
        # screen can say what is still missing.
        "needs": progress[r.report_id]["needs"],
        # Ivan (donor feed): "New validated report · 2h".
        "created_at": r.created_at.isoformat() if r.created_at else None,
    }


def select(reports: list, types: dict, barangays: dict, *, done: Optional[bool] = None,
           q: Optional[str] = None, barangay: Optional[str] = None, disaster: Optional[str] = None,
           priority: Optional[str] = None, quick: str = "all", sort: str = "urgent",
           with_sitio: bool = False) -> list:
    """Filter and sort like the app did. `reports` come newest first; ties
    keep that order. with_sitio: signed-in users also search sitio names
    (4.2: guests search by barangay only)."""
    if quick not in QUICK:
        raise HTTPException(status_code=422, detail=f"quick must be one of: {', '.join(QUICK)}")
    if sort not in SORTS:
        raise HTTPException(status_code=422, detail=f"sort must be one of: {', '.join(SORTS)}")
    text = (q or "").strip().lower()

    def keep(r) -> bool:
        p = pct(r)
        if done is not None and (p >= 100) != done:
            return False
        if quick == "urgent" and r.priority_level not in URGENT:
            return False
        if quick == "needs" and p >= 100:
            return False
        if quick == "fulfilled" and p < 100:
            return False
        if barangay and barangays.get(r.barangay_id, "Barangay") != barangay:
            return False
        if disaster and r.disaster_label(types) != disaster:
            return False
        if priority and r.priority_level != priority:
            return False
        if text:
            words = [barangays.get(r.barangay_id, "Barangay"),
                     ", ".join(r.sitio_names) if with_sitio else "",
                     r.disaster_label(types), r.assistance_needed or "", r.description or ""]
            if text not in " ".join(str(w) for w in words).lower():
                return False
        return True

    rows = [r for r in reports if keep(r)]

    def rank(r) -> int:
        p = (r.priority_level or "").strip().lower()
        return _RANK.index(p) if p in _RANK else len(_RANK)

    key = {
        "urgent": lambda r: (1 if pct(r) >= 100 else 0, rank(r), pct(r)),
        "least_fulfilled": lambda r: pct(r),
        "most_fulfilled": lambda r: -pct(r),
        "most_families": lambda r: -(r.affected_families or 0),
        "newest": lambda r: -r.report_id,
    }[sort]
    return sorted(rows, key=key)  # stable
