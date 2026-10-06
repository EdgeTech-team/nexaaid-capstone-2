"""Donation entries: one donor submission = one batch_reference.

physical_donations stays one row per item. This module groups those rows
into ENTRIES (one per batch_reference) and entries into REPORTS, so every
screen can show Report -> Entries -> Items instead of one row per item.

Used by GET /donations/entries. Other modules (donor records, admin and CMO
summaries) should reuse build_entries() / group_by_report().
"""
from typing import Iterable

from sqlalchemy.orm import Session

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


def build_entries(db: Session, rows: list, include_donor: bool = False) -> list:
    """PhysicalDonation rows -> entries (one per batch_reference), oldest first."""
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
                    "status": l.status,
                    "actual_quantity_received": received.get(l.donation_id),
                }
                for l in lines
            ],
        }
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