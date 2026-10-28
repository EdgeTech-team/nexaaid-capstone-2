"""Per-item fulfillment (Module 3 / 8.4, Oct 2026 team decision).

A report lists its needs per item (report_needs), each a whole number in
the item's base unit. For every need three meters are worked out:

  pledged    donations not expired/cancelled (the received amount once
             CSWS has counted it, the donor's declared amount before)
  confirmed  received by CSWS AND acknowledged by the CMO ("in stock";
             stays counted after the goods are delivered)
  delivered  on deliveries the barangay confirmed receiving (Confirmed)

Each meter is capped at 100% of the need, so extra rice never makes up for
missing water. The report's OFFICIAL fulfillment percentage is the average
of the needs' DELIVERED percentages (equal weight per need); it is what
report_fulfillments stores and what priority uses.

"General needs" (item_id NULL) is the single total of an older report. It
counts every delivered item that no other need of the report asks for,
which is exactly how fulfillment worked before, so old reports keep
their percentage. Goods that match no need are listed as additional goods
and never raise the percentage.
"""
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal
from types import SimpleNamespace
from typing import Iterable, Optional

from fastapi import HTTPException
from sqlalchemy import func
from sqlalchemy.orm import Session

from models.delivery import Delivery, DeliveryItem
from models.item_model import Item
from models.physical_donation_model import PhysicalDonation
from models.received_goods_model import ReceivedGoods
from models.report import DisasterReport, ReportFulfillment, ReportNeed

GENERAL = "General needs"
OPEN_DONATION = ("Pending", "Received", "Confirmed")


# ---------------------------------------------------------------------------
# Writing needs
# ---------------------------------------------------------------------------
def set_needs(db: Session, report: DisasterReport, needs: Optional[list],
              estimated_quantity: Optional[int], resolve_item) -> None:
    """Replace the report's needs.

    needs given (newer apps): one row per item; estimated_quantity becomes
    their sum (kept for older screens) and assistance_needed a readable
    summary when the reporter left it empty.
    needs not given (older apps / SMS): one "General needs" row with
    estimated_quantity, like before.
    resolve_item(item_id, other_name, other_unit) -> item_id (donation
    routes' helper: "Other" items are added to the list).
    """
    rows = []
    if needs:
        seen = set()
        for n in needs:
            item_id = resolve_item(n.item_id, n.other_item_name, n.other_item_unit)
            if item_id in seen:
                raise HTTPException(status_code=422, detail="Each item can be listed only once in the needs.")
            seen.add(item_id)
            rows.append(ReportNeed(item_id=item_id, quantity=n.quantity))
        # Kept for older screens; capped at the column's integer range
        # (no limit on needs since testing, Oct 28).
        report.estimated_quantity = min(sum(r.quantity for r in rows), 2_147_483_647)
        if not (report.assistance_needed or "").strip():
            items = {i.item_id: i for i in db.query(Item).filter(Item.item_id.in_(seen)).all()}
            report.assistance_needed = ", ".join(
                f"{items[r.item_id].item_name}: {r.quantity} {items[r.item_id].unit_of_measure}"
                for r in rows
            )
    elif estimated_quantity:
        rows.append(ReportNeed(item_id=None, quantity=estimated_quantity))
    # Old rows go first: inserting before deleting would hit
    # uq_report_needs_report_item when an item stays in the list.
    report.needs.clear()
    db.flush()
    report.needs.extend(rows)
    db.flush()


# ---------------------------------------------------------------------------
# Reading meters
# ---------------------------------------------------------------------------
def _needs_of(report: DisasterReport) -> list:
    if report.needs:
        return list(report.needs)
    if report.estimated_quantity:
        # Not saved yet (e.g. a report from before the backfill): same rule.
        return [SimpleNamespace(need_id=None, item_id=None, quantity=report.estimated_quantity, item=None)]
    return []


def _totals(db: Session, report_ids: Iterable[int]) -> dict:
    """{report_id: {item_id: {"pledged", "confirmed", "delivered"}}} in base units."""
    ids = list(set(report_ids))
    out: dict = defaultdict(lambda: defaultdict(lambda: {"pledged": 0, "confirmed": 0, "delivered": 0}))
    if not ids:
        return out
    received = dict(
        db.query(ReceivedGoods.donation_id, func.sum(ReceivedGoods.actual_quantity))
        .join(PhysicalDonation, PhysicalDonation.donation_id == ReceivedGoods.donation_id)
        .filter(PhysicalDonation.report_id.in_(ids))
        .group_by(ReceivedGoods.donation_id).all()
    )
    for d in (db.query(PhysicalDonation)
              .filter(PhysicalDonation.report_id.in_(ids),
                      PhysicalDonation.status.in_(OPEN_DONATION)).all()):
        got = received.get(d.donation_id)
        t = out[d.report_id][d.item_id]
        t["pledged"] += int(got if got is not None else d.quantity)
        if d.status == "Confirmed" and got is not None:
            t["confirmed"] += int(got)
    for report_id, item_id, qty in (
        db.query(Delivery.report_id, DeliveryItem.item_id, func.sum(DeliveryItem.quantity))
        .join(DeliveryItem, DeliveryItem.delivery_id == Delivery.delivery_id)
        .filter(Delivery.report_id.in_(ids), Delivery.status == "Confirmed")
        .group_by(Delivery.report_id, DeliveryItem.item_id).all()
    ):
        out[report_id][item_id]["delivered"] += int(qty or 0)
    return out


def _pct(part: int, whole: int) -> float:
    if whole <= 0:
        return 0.0
    return round(min(part, whole) * 100.0 / whole, 2)


def _progress(report: DisasterReport, totals: dict, items: dict) -> dict:
    needs = _needs_of(report)
    explicit = {n.item_id for n in needs if n.item_id is not None}
    general_items = [i for i in totals if i not in explicit]
    rows = []
    for n in needs:
        if n.item_id is None:
            sums = {k: sum(totals[i][k] for i in general_items) for k in ("pledged", "confirmed", "delivered")}
            name, unit = GENERAL, None
        else:
            sums = dict(totals.get(n.item_id, {"pledged": 0, "confirmed": 0, "delivered": 0}))
            item = items.get(n.item_id)
            name = item.item_name if item else "Item"
            unit = item.unit_of_measure if item else None
        rows.append({
            "need_id": n.need_id,
            "item_id": n.item_id,
            "item_name": name,
            "unit": unit,
            "needed": n.quantity,
            **sums,
            "pledged_percentage": _pct(sums["pledged"], n.quantity),
            "confirmed_percentage": _pct(sums["confirmed"], n.quantity),
            "delivered_percentage": _pct(sums["delivered"], n.quantity),
        })
    has_general = any(n.item_id is None for n in needs)
    extra = [] if has_general else [
        {"item_id": i, "item_name": items[i].item_name if i in items else "Item",
         "unit": items[i].unit_of_measure if i in items else None, **totals[i]}
        for i in general_items if any(totals[i].values())
    ]
    avg = round(sum(r["delivered_percentage"] for r in rows) / len(rows), 2) if rows else 0.0
    return {
        "report_id": report.report_id,
        "fulfillment_percentage": avg,
        "pledged_percentage": round(sum(r["pledged_percentage"] for r in rows) / len(rows), 2) if rows else 0.0,
        "confirmed_percentage": round(sum(r["confirmed_percentage"] for r in rows) / len(rows), 2) if rows else 0.0,
        "needs": rows,
        "additional_goods": extra,
    }


def progress_for_reports(db: Session, reports: list) -> dict:
    """{report_id: progress} for many reports in a few queries (donor feed)."""
    totals = _totals(db, [r.report_id for r in reports])
    item_ids = {i for t in totals.values() for i in t} | {
        n.item_id for r in reports for n in r.needs if n.item_id is not None}
    items = {i.item_id: i for i in db.query(Item).filter(Item.item_id.in_(item_ids)).all()} if item_ids else {}
    return {r.report_id: _progress(r, totals.get(r.report_id, {}), items) for r in reports}


def progress(db: Session, report: DisasterReport) -> dict:
    return progress_for_reports(db, [report])[report.report_id]


# ---------------------------------------------------------------------------
# Updating the stored figure (official = delivered)
# ---------------------------------------------------------------------------
def status_for(pct) -> str:
    pct = Decimal(str(pct))
    if pct <= 0:
        return "Not Started"
    if pct >= 100:
        return "Complete"
    return "Partial"


def recalculate(db: Session, report_id: int, verified_by_user_id: Optional[int]) -> ReportFulfillment:
    """Store the report's delivered percentage in report_fulfillments.

    total_items_needed / total_items_delivered stay as plain sums for older
    screens (delivered capped per need); the percentage is the average of
    the needs. The caller recomputes priority."""
    fulfillment = db.query(ReportFulfillment).filter(ReportFulfillment.report_id == report_id).first()
    if not fulfillment:
        raise HTTPException(
            status_code=409,
            detail="This report has no fulfillment record yet; it may not have been validated.",
        )
    report = db.get(DisasterReport, report_id)
    p = progress(db, report)
    fulfillment.total_items_needed = sum(n["needed"] for n in p["needs"])
    fulfillment.total_items_delivered = sum(min(n["delivered"], n["needed"]) for n in p["needs"])
    fulfillment.fulfillment_percentage = Decimal(str(p["fulfillment_percentage"]))
    fulfillment.verification_status = status_for(p["fulfillment_percentage"])
    if verified_by_user_id is not None:
        fulfillment.verified_by_user_id = verified_by_user_id
        fulfillment.verified_at = datetime.now(timezone.utc)
    db.flush()
    return fulfillment
