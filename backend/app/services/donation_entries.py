"""Donation entries: one donor submission = one batch_reference.

physical_donations stays one row per item. This module groups those rows
into ENTRIES (one per batch_reference) and entries into REPORTS, so every
screen can show Report -> Entries -> Items instead of one row per item.

Used by GET /donations/entries, GET /donations/records (Appendix H 4.4 /
4.5) and GET /donations/mine (UC-D3 / UC-R3). Other modules should reuse
build_entries() / group_by_report() / filter_and_sort().
"""
from typing import Iterable, Optional

from sqlalchemy.orm import Session

from models.donation_confirmation_model import DonationConfirmation
from models.guest_donor_model import GuestDonor
from models.item_model import Item
from models.received_goods_model import ReceivedGoods
from models.report import Barangay, DisasterReport, DisasterType
from models.user_rbac_model import User


def entry_status(statuses: Iterable[str]) -> str:
    s = set(statuses)
    if len(s) == 1:
        return next(iter(s))
    return "Partly Received" if "Pending" in s else "Received"


def _report_labels(db: Session, report_ids) -> dict:
    if not report_ids:
        return {}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    return {
        r.report_id: f"#{r.report_id} {types.get(r.disaster_type_id, 'Disaster')} - {brgys.get(r.barangay_id, 'Barangay')}"
        for r in db.query(DisasterReport).filter(DisasterReport.report_id.in_(report_ids)).all()
    }


def _latest_decisions(db: Session, donation_ids) -> dict:
    """donation_id -> latest CMO decision row (same rule as cmo_router)."""
    if not donation_ids:
        return {}
    latest = {}
    for row in (
        db.query(DonationConfirmation)
        .filter(DonationConfirmation.donation_id.in_(donation_ids))
        .order_by(DonationConfirmation.confirmation_id)
        .all()
    ):
        latest[row.donation_id] = row
    return latest


def _donor_names(db: Session, rows) -> tuple:
    user_ids = {r.user_id for r in rows if r.user_id}
    guest_ids = {r.guest_donor_id for r in rows if r.guest_donor_id}
    users = {}
    if user_ids:
        users = {
            u.user_id: f"{u.first_name or ''} {u.last_name or ''}".strip() or u.email
            for u in db.query(User).filter(User.user_id.in_(user_ids)).all()
        }
    guests = {}
    if guest_ids:
        guests = {
            g.guest_donor_id: g.full_name
            for g in db.query(GuestDonor).filter(GuestDonor.guest_donor_id.in_(guest_ids)).all()
        }
    return users, guests


def build_entries(
    db: Session, rows: list, include_donor: bool = False, include_cmo: bool = False
) -> list:
    """PhysicalDonation rows -> entries (one per batch_reference), oldest first.

    include_cmo adds each item's latest CMO decision (6.2: the hold reason is
    shown only while the item is On Hold) and the entry's on_hold_items.
    """
    if not rows:
        return []
    items = {
        i.item_id: i
        for i in db.query(Item).filter(Item.item_id.in_({r.item_id for r in rows})).all()
    }
    received = {
        g.donation_id: g.actual_quantity
        for g in db.query(ReceivedGoods)
        .filter(ReceivedGoods.donation_id.in_([r.donation_id for r in rows]))
        .all()
    }
    labels = _report_labels(db, {r.report_id for r in rows})
    users, guests = _donor_names(db, rows) if include_donor else ({}, {})
    decisions = _latest_decisions(db, [r.donation_id for r in rows]) if include_cmo else {}

    by_ref: dict = {}
    for r in sorted(rows, key=lambda r: r.donation_id):
        by_ref.setdefault(r.batch_reference, []).append(r)

    entries = []
    for ref, lines in by_ref.items():
        first = lines[0]
        entry = {
            "batch_reference": ref,
            "report_id": first.report_id,
            "report_label": labels.get(first.report_id),
            "status": entry_status(l.status for l in lines),
            "handover_method": first.handover_method,
            "created_at": first.created_at,
            "total_items": len(lines),
            "total_quantity": sum(l.quantity or 0 for l in lines),
            "pending_items": sum(1 for l in lines if l.status == "Pending"),
            "items": [
                {
                    "donation_id": l.donation_id,
                    "qr_reference": l.qr_reference,
                    "item_id": l.item_id,
                    "item_name": items[l.item_id].item_name if l.item_id in items else "Item",
                    "unit": items[l.item_id].unit_of_measure if l.item_id in items else "",
                    "quantity": l.quantity,
                    "packaging": l.packaging,
                    "estimated_value": float(l.estimated_value) if l.estimated_value is not None else None,
                    "status": l.status,
                    "actual_quantity_received": received.get(l.donation_id),
                }
                for l in lines
            ],
        }
        if include_cmo:
            for item in entry["items"]:
                dec = decisions.get(item["donation_id"])
                item["cmo_decision"] = dec.status if dec else None
                item["hold_reason"] = dec.notes if dec and dec.status == "On Hold" and item["status"] != "Confirmed" else None
            entry["on_hold_items"] = sum(1 for i in entry["items"] if i["hold_reason"] is not None)
        if include_donor:
            entry["donor"] = (
                users.get(first.user_id, "Donor")
                if first.user_id
                else f"{guests.get(first.guest_donor_id, 'Guest')} (guest)"
            )
        entries.append(entry)
    return entries


def group_by_report(entries: list, pending_only: bool = False) -> list:
    """Entries -> reports (newest report first), each holding its entries.

    entry_no counts per report from 1 (Donation 1, Donation 2 ...) and is
    assigned before pending_only filtering, so numbers never shift.
    """
    groups: dict = {}
    for e in entries:
        g = groups.setdefault(
            e["report_id"],
            {"report_id": e["report_id"], "report_label": e["report_label"], "entries": []},
        )
        e["entry_no"] = len(g["entries"]) + 1
        g["entries"].append(e)

    out = []
    for g in sorted(groups.values(), key=lambda g: g["report_id"], reverse=True):
        if pending_only:
            g["entries"] = [e for e in g["entries"] if e["pending_items"] > 0]
        if not g["entries"]:
            continue
        g["total_entries"] = len(g["entries"])
        g["total_items"] = sum(e["total_items"] for e in g["entries"])
        out.append(g)
    return out

ENTRY_SORTS = ("newest", "oldest", "most_items", "fewest_items")


def filter_and_sort(
    entries: list,
    status: Optional[str] = None,
    handover_method: Optional[str] = None,
    search: Optional[str] = None,
    sort: str = "newest",
) -> list:
    """Filtering and sorting of entries for the record screens (4.4 / 4.5).

    status is the entry status (Pending, Partly Received, Received,
    Confirmed); search matches the QR reference, the donor or an item name.
    """
    out = entries
    if status:
        out = [e for e in out if e["status"].lower() == status.strip().lower()]
    if handover_method:
        out = [e for e in out if (e["handover_method"] or "").lower() == handover_method.strip().lower()]
    if search and search.strip():
        q = search.strip().lower()
        out = [
            e for e in out
            if q in (e["batch_reference"] or "").lower()
            or q in (e.get("donor") or "").lower()
            or any(q in (i["item_name"] or "").lower() for i in e["items"])
        ]

    def first_id(e):
        return e["items"][0]["donation_id"]

    if sort == "oldest":
        return sorted(out, key=first_id)
    if sort == "most_items":
        return sorted(out, key=lambda e: (-e["total_items"], -first_id(e)))
    if sort == "fewest_items":
        return sorted(out, key=lambda e: (e["total_items"], -first_id(e)))
    return sorted(out, key=first_id, reverse=True)
