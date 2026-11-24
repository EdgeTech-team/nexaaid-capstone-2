"""NF-003 (Nov 2026): what an event page shows.

An event is one disaster that hit several barangays; each barangay is its
own disaster report. This builds GET /reports/events/{event_id}:

- every row is one barangay report, lowest fulfillment first, so donors
  see who needs help most;
- a Validated report shows its progress, top unmet needs and whether it can
  still take donations (`donatable`: Validated and under 100%);
- a report that is not validated yet shows in full only to the people who
  may open it (core.m1_user_management.auth.can_view_unvalidated_report: the reporter, CSWS
  staff, the Administrator, the barangay's own representative). Donors,
  organizations and guests get a placeholder with only the barangay name
  and "Awaiting validation". Withdrawn (Cancelled) and deleted reports are
  left out for them;
- the event's barangay count, families, % and priority come from the
  VALIDATED reports only. Event % = the reports' official %
  (core/m8_delivery_tracking/fulfillment.py) weighted by affected families, computed on read.
"""
from typing import Optional

from sqlalchemy.orm import Session, joinedload

from core.m1_user_management.auth import can_view_unvalidated_report
from core.m2_disaster_reporting.disaster_event_model import DisasterEvent
from core.reference_data.disaster_type_model import DisasterType
from core.m2_disaster_reporting.report_model import DisasterReport
from core.m8_delivery_tracking.fulfillment import progress_for_reports

AWAITING = "Awaiting validation"
_PRIORITY_ORDER = ("Critical", "High", "Medium", "Low")


def event_percentage(reports: list) -> float:
    """Family-weighted average of the reports' official fulfillment %.
    e.g. 120/80/40 families at 100/25/0% -> 58.33."""
    weight = sum(r.affected_families or 0 for r in reports)
    if weight <= 0:
        return 0.0
    total = sum(float(r.fulfillment.fulfillment_percentage if r.fulfillment else 0)
                * (r.affected_families or 0) for r in reports)
    return round(total / weight, 2)


def highest_priority(reports: list) -> Optional[str]:
    levels = {r.priority_level for r in reports}
    return next((p for p in _PRIORITY_ORDER if p in levels), None)


def _still_needed(n: dict) -> int:
    """J6 / NF-011: needed minus VERIFIED pledges (core/m4_donation_management/pledge_trust.py).
    A guest pledge counts once CSWS receives it. Falls back to "pledged"
    for a row without the split."""
    verified = n.get("pledged_verified", n.get("pledged"))
    return max(0, int(n.get("needed") or 0) - int(verified or 0))


def _full_row(r: DisasterReport, progress: Optional[dict]) -> dict:
    pct = float(r.fulfillment.fulfillment_percentage) if r.fulfillment else 0.0
    needs = progress["needs"] if progress else []
    top = sorted((n for n in needs if _still_needed(n) > 0), key=_still_needed, reverse=True)[:3]
    validated = r.status == "Validated"
    return {
        "report_id": r.report_id,
        "barangay_id": r.barangay_id,
        "barangay": r.barangay_name,
        "status": r.status,
        "affected_families": r.affected_families,
        "sitios": r.sitio_names,
        "description": r.description,
        "priority_level": r.priority_level,
        "fulfillment_percentage": pct,
        # Same rule as the donate form's chips: needed minus verified
        # pledges, plus how many pledges are not confirmed yet (J6).
        "top_needs": [{"item_name": n["item_name"], "unit": n.get("unit"),
                       "still_needed": _still_needed(n),
                       "pledged_unverified_count": int(n.get("pledged_unverified_count") or 0)}
                      for n in top],
        "needs": needs,
        "donatable": validated and pct < 100,
    }


def event_view(db: Session, event: DisasterEvent, user) -> dict:
    reports = (db.query(DisasterReport)
               .options(joinedload(DisasterReport.fulfillment))
               .filter(DisasterReport.event_id == event.event_id,
                       DisasterReport.deleted_at.is_(None))
               .all())
    validated = [r for r in reports if r.status == "Validated"]
    progress = progress_for_reports(db, validated) if validated else {}

    rows = []
    for r in reports:
        if r.status == "Validated" or (user is not None and can_view_unvalidated_report(user, r)):
            rows.append(_full_row(r, progress.get(r.report_id)))
        elif r.status in ("Pending", "Rejected"):
            # Placeholder: nothing but the barangay and that it is coming.
            rows.append({"barangay": r.barangay_name, "status": AWAITING})
    # Lowest % first; placeholders and other unvalidated rows last.
    rows.sort(key=lambda x: (x["status"] != "Validated",
                             x.get("fulfillment_percentage", 0), x["barangay"] or ""))

    t = db.get(DisasterType, event.disaster_type_id)
    return {
        "event_id": event.event_id,
        "event_name": event.event_name,
        "disaster": event.disaster_type_other or (t.type_name if t else "Disaster"),
        "disaster_type_id": event.disaster_type_id,
        "created_at": event.created_at.isoformat() if event.created_at else None,
        "barangay_count": len(validated),
        "total_families": sum(r.affected_families or 0 for r in validated),
        "fulfillment_percentage": event_percentage(validated),
        "priority_level": highest_priority(validated),
        "awaiting_count": sum(1 for r in reports if r.status in ("Pending", "Rejected")),
        "reports": rows,
    }
