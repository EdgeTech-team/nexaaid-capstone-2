"""Adding and removing items in a pledged donation (Oct 23, Dave).

A donation (one QR, one batch_reference) can grow: the donor adds items
later and they join the SAME donation, so the QR the donor already saved
shows everything when CSWS scans it. Each addition is a batch:
physical_donations.addition_no 1 = the original pledge, 2+ = added later.

The donor may also remove items, with a reason. A removed item is never
deleted: it is closed as Cancelled with close_reason "Removed by donor:
<reason>", so CSWS sees the note when scanning and in the entry lists, and
the audit log keeps who did it and when.

Rules (Dave, Oct 23):
  * The donor can add or remove only while the report still accepts
    donations (Validated, not deleted) and before CSWS picked up or received
    the donation (no item Received / Confirmed yet).
  * Removing never leaves a donation with no items: the last open item
    cannot be removed (cancelling the whole donation is a separate action).
  * Only items still waiting (Pending) can be removed.
"""
from typing import Optional

from models.physical_donation_model import PhysicalDonation
from models.report import DisasterReport

REMOVED_PREFIX = "Removed by donor: "
OPEN_ITEM = ("Pending", "Received", "Confirmed")   # not closed
HANDED_OVER = ("Received", "Confirmed")             # CSWS has the goods


def is_removed(row: PhysicalDonation) -> bool:
    return (row.status == "Cancelled"
            and (row.close_reason or "").startswith(REMOVED_PREFIX))


def removed_reason(row: PhysicalDonation) -> Optional[str]:
    return row.close_reason[len(REMOVED_PREFIX):] if is_removed(row) else None


def change_blocked(report: Optional[DisasterReport], rows: list) -> Optional[str]:
    """Why the donor can no longer add or remove items, or None if they can."""
    if report is None or report.status != "Validated" or report.deleted_at is not None:
        return "This report is closed, so this donation can no longer be changed."
    if any(r.status in HANDED_OVER for r in rows):
        return ("CSWS has already picked up or received this donation, so it can no "
                "longer be changed. You can make a new donation instead.")
    if not any(r.status == "Pending" for r in rows):
        return "This donation is closed, so it can no longer be changed."
    return None


def next_addition_no(rows: list) -> int:
    return max((r.addition_no or 1 for r in rows), default=0) + 1


def next_item_number(rows: list) -> int:
    """The n of the next item reference "<batch_reference>-<n>"."""
    nums = [int(r.qr_reference.rsplit("-", 1)[-1]) for r in rows
            if r.qr_reference.rsplit("-", 1)[-1].isdigit()]
    return max(nums, default=len(rows)) + 1


def summary(rows: list) -> dict:
    """Counts for "3 items received, 2 pending" (per item, not per donation)."""
    return {
        "items": len(rows),
        "pending": sum(1 for r in rows if r.status == "Pending"),
        "received": sum(1 for r in rows if r.status == "Received"),
        "acknowledged": sum(1 for r in rows if r.status == "Confirmed"),
        "removed": sum(1 for r in rows if is_removed(r)),
        "closed": sum(1 for r in rows if r.status in ("Expired", "Cancelled") and not is_removed(r)),
        "batches": len({r.addition_no or 1 for r in rows}),
    }


def summary_text(s: dict) -> str:
    """"3 received · 2 pending · 1 removed" (only the parts that are not 0)."""
    parts = [
        (s["acknowledged"], "acknowledged"),
        (s["received"], "received"),
        (s["pending"], "pending"),
        (s["removed"], "removed"),
        (s["closed"], "closed"),
    ]
    return " · ".join(f"{n} {label}" for n, label in parts if n) or "No items"


def removed_notes(rows: list) -> list:
    """[{"item_id", "donation_id", "reason", "removed_at", "addition_no"}]."""
    return [
        {
            "donation_id": r.donation_id,
            "item_id": r.item_id,
            "addition_no": r.addition_no or 1,
            "reason": removed_reason(r),
            "removed_at": r.closed_at,
        }
        for r in rows if is_removed(r)
    ]
