"""G-002 (D8, agreement A7): packaging and quantities wherever a donated
item appears.

Every user who can see a donated item sees its packaging and its readable
amount ("10 packs x 5 kg"), plus the quantities that exist:
    declared_quantity           what the donor pledged (physical_donations.quantity)
    counted_quantity            what CSWS counted at receipt (received_goods.actual_quantity)
    barangay_received_quantity  what the barangay counted at receipt (J1,
                                receipt_items.received_quantity); None until
                                Jenises's J1 is merged (see barangay_received)
All in the item's base unit (kg, L, pcs ...).

One helper so the donor, organization, CSWS, CMO, DRRMO and dashboard
answers say the same thing.
"""
from typing import Iterable


def _num(v) -> str:
    f = float(v)
    return str(int(f)) if f == int(f) else f"{f:g}"


def readable_amount(row, unit: str) -> str:
    """'10 packs x 5 kg', '3 packs x 16 x 1.5 L bottle', or '72 L' for
    donations from older apps (total only)."""
    unit = (unit or "").strip()
    packs = getattr(row, "pack_count", None)
    size = (getattr(row, "size_label", None) or "").strip()
    if packs:
        per = getattr(row, "per_pack", None) or 1
        word = "pack" if packs == 1 else "packs"
        parts = [f"{packs} {word}"]
        if per > 1:
            parts.append(str(per))
        parts.append(size or unit)
        return " x ".join(p for p in parts if p)
    return f"{_num(row.quantity)} {unit}".strip()


def quantity_summary(unit: str, declared, counted=None, received=None) -> str:
    """'Declared 50 kg · Counted 48 kg · Received by barangay 48 kg'."""
    unit = (unit or "").strip()
    parts = [f"Declared {_num(declared)} {unit}".strip()]
    if counted is not None:
        parts.append(f"Counted {_num(counted)} {unit}".strip())
    if received is not None:
        parts.append(f"Received by barangay {_num(received)} {unit}".strip())
    return " · ".join(parts)


def donated_item_fields(row, unit: str, counted=None, received=None) -> dict:
    """The packaging and quantity fields of one physical_donations row."""
    return {
        "packaging": row.packaging,
        "amount_text": readable_amount(row, unit),
        "declared_quantity": row.quantity,
        "counted_quantity": counted,
        "barangay_received_quantity": received,
        "quantity_summary": quantity_summary(unit, row.quantity, counted, received),
    }


def delivered_item_fields(quantity, unit: str, received=None) -> dict:
    """A delivery line: goods from CSWS stock (no donor packaging)."""
    unit = (unit or "").strip()
    return {
        "amount_text": f"{_num(quantity)} {unit}".strip(),
        "barangay_received_quantity": received,
        "quantity_summary": (f"Sent {_num(quantity)} {unit}".strip()
                             + (f" · Received by barangay {_num(received)} {unit}".rstrip()
                                if received is not None else "")),
    }


def barangay_received(db, donation_ids: Iterable[int]) -> dict:
    """{donation_id: quantity the barangay counted} for donated items.

    TODO(J1, Jenises): receipt_items.received_quantity does not exist on
    this branch yet. After J1 is merged, fill this from receipt_items
    joined through delivery_allocations (donation -> delivery item), and
    delivery_received below from receipt_items per delivery item. Until
    then every screen shows Declared and Counted only."""
    return {}


def delivery_received(db, delivery_item_ids: Iterable[int]) -> dict:
    """{delivery_item_id: quantity the barangay counted}. See barangay_received."""
    return {}


def goods_line(row, item_name: str, unit: str) -> str:
    """'Rice: 10 packs x 5 kg (Sack)' for lists of strings (DRRMO goods,
    the pickup board)."""
    pack = (row.packaging or "").strip()
    return f"{item_name}: {readable_amount(row, unit)}" + (f" ({pack})" if pack else "")


