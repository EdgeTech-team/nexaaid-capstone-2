"""J2 / NF-015 (team agreement A2): the read-only Acknowledgment Receipt of
a delivery the barangay confirmed (GET /deliveries/{id}/acknowledgment).

Full view: CSWS Main Office, the Disaster Unit, the Administrator, and the
Barangay Receiving Representative of that barangay. Reference no.,
barangay, report, items with packaging and sent / received counts, the
signer's name and position, links to the signature and the optional slip
photo, the date and time, and whether the handover code was verified.

Donor view: a donor (Individual Donor or Relief Organization) whose goods
were on the delivery sees the items, the barangay, the reference no. and
the date only: no signer, signature, report, code status, remarks or other
donors. The handover code itself is in neither view.
"""
from collections import defaultdict

from fastapi import HTTPException
from sqlalchemy.orm import Session

from core.m1_user_management.auth import barangay_scope, has_role
from core.m8_delivery_tracking.delivery_model import Delivery, DeliveryAllocation, Receipt
from core.reference_data.item_model import Item
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from core.shared.upload_model import Upload
from core.m8_delivery_tracking.delivery_schema import (
    Acknowledgment,
    AcknowledgmentFullLine,
    AcknowledgmentLine,
    DonorAcknowledgment,
)
from core.m8_delivery_tracking.delivery_notices import donor_entries
from core.m8_delivery_tracking.delivery_views import report_labels

STAFF_READERS = ("csws_main_office", "csws_disaster_unit", "admin")
DONOR_ROLES = ("Individual Donor", "Relief Organization")
# Route guards in core/m8_delivery_tracking/deliveries.py.
FULL_READERS = STAFF_READERS + ("barangay_receiving_rep",)
READERS = FULL_READERS + DONOR_ROLES


def viewer(db: Session, user, delivery: Delivery) -> str:
    """'full' or 'donor', or an error: 404 for a rep of another barangay
    (as GET /deliveries/{id}), 403 for anyone else."""
    if has_role(user, "barangay_receiving_rep"):
        if barangay_scope(user) != delivery.destination_barangay_id:
            raise HTTPException(status_code=404, detail="Delivery not found")
        return "full"
    if has_role(user, *STAFF_READERS):
        return "full"
    if has_role(user, *DONOR_ROLES) and user.user_id in donor_entries(db, delivery.delivery_id):
        return "donor"
    raise HTTPException(
        status_code=403,
        detail=("Only CSWS, the Administrator, the barangay, and the donors whose goods were "
                "on this delivery can see its Acknowledgment Receipt."),
    )


def _receipt(delivery: Delivery) -> Receipt:
    if delivery.receipt is None:
        raise HTTPException(
            status_code=404,
            detail="No Acknowledgment Receipt yet: the barangay has not confirmed this delivery.",
        )
    return delivery.receipt


def _lines(db: Session, delivery: Delivery, full: bool) -> list:
    """Each delivery line: item, packaging of the donations on it, what
    CSWS sent and what the barangay counted (None before J1 counting)."""
    lines = sorted(delivery.items, key=lambda line: line.delivery_item_id)
    ids = [line.delivery_item_id for line in lines]
    items = {i.item_id: i for i in db.query(Item).filter(
        Item.item_id.in_({line.item_id for line in lines} or {-1})).all()}
    packs = defaultdict(set)
    for line_id, packaging in (
        db.query(DeliveryAllocation.delivery_item_id, PhysicalDonation.packaging)
        .join(PhysicalDonation, PhysicalDonation.donation_id == DeliveryAllocation.donation_id)
        .filter(DeliveryAllocation.delivery_item_id.in_(ids or [-1]))
    ):
        if packaging and packaging.strip():
            packs[line_id].add(packaging.strip())
    out = []
    for line in lines:
        counted = line.receipt_item
        item = items.get(line.item_id)
        base = {
            "item_id": line.item_id,
            "item_name": item.item_name if item else f"Item #{line.item_id}",
            "unit": item.unit_of_measure if item else None,
            "packaging": ", ".join(sorted(packs[line.delivery_item_id])) or None,
            "expected_quantity": counted.expected_quantity if counted else line.quantity,
            "received_quantity": counted.received_quantity if counted else None,
            "discrepancy_reason": counted.discrepancy_reason if counted else None,
        }
        if full:
            out.append(AcknowledgmentFullLine(
                **base, discrepancy_note=counted.discrepancy_note if counted else None))
        else:
            out.append(AcknowledgmentLine(**base))
    return out


def build(db: Session, delivery: Delivery, user):
    """The Acknowledgment Receipt as this user may see it."""
    view = viewer(db, user, delivery)
    receipt = _receipt(delivery)
    barangay = (delivery.destination_barangay.barangay_name
                if delivery.destination_barangay else "Barangay")
    if view == "donor":
        return DonorAcknowledgment(
            reference_no=receipt.reference_no,
            delivery_id=delivery.delivery_id,
            barangay_name=barangay,
            received_at=receipt.received_at,
            items=_lines(db, delivery, full=False),
        )
    base_url = f"/deliveries/{delivery.delivery_id}/acknowledgment"
    return Acknowledgment(
        reference_no=receipt.reference_no,
        delivery_id=delivery.delivery_id,
        barangay_name=barangay,
        received_at=receipt.received_at,
        items=_lines(db, delivery, full=True),
        report_id=delivery.report_id,
        report_label=report_labels(db, [delivery.report_id]).get(delivery.report_id),
        signer_name=receipt.signer_name,
        signer_position=receipt.signer_position,
        signature_url=f"{base_url}/signature" if receipt.signature_file_id else None,
        slip_photo_url=f"{base_url}/slip-photo" if receipt.slip_photo_file_id else None,
        handover_verified=bool(receipt.handover_verified),
        has_discrepancy=receipt.has_discrepancy,
        remarks=receipt.remarks,
    )


def receipt_file(db: Session, user, delivery: Delivery, which: str) -> Upload:
    """The signature ('signature') or slip photo ('slip-photo') upload of
    the receipt, for full-view readers only. Never donors."""
    if viewer(db, user, delivery) != "full":
        raise HTTPException(status_code=403, detail="You cannot see this file.")
    receipt = _receipt(delivery)
    file_id = receipt.signature_file_id if which == "signature" else receipt.slip_photo_file_id
    up = db.query(Upload).filter(Upload.file_id == file_id).first() if file_id else None
    if up is None:
        raise HTTPException(status_code=404, detail="File not found")
    return up
