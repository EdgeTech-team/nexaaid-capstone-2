"""Base units and packaging conversion (per-item fulfillment, Oct 2026).

Rule: every quantity of an item (report needs, donations, received goods,
inventory, deliveries) is a WHOLE NUMBER in the item's base unit,
items.unit_of_measure. Packaging only describes how it arrives.

Three kinds of base unit:
  weight  kg     custom sizes may be given in g or kg
  volume  L      custom sizes may be given in ml, L or gallon
  count   pcs, cans, packs, kits, boxes... (anything else)
                 a custom size is a number of that same unit

A donor describes a line as   pack_count x per_pack x size
    3 boxes x 16 bottles x 1.5 L  = 72 L
    4 x 1 x 25 kg sack            = 100 kg
    10 x 6 x 1 can                = 60 cans
and the total is rounded to a whole base unit (3 x 500 ml = 1.5 L -> 2 L).
The exact breakdown is kept on the donation, so nothing is lost.
"""
from decimal import ROUND_HALF_UP, Decimal
from typing import Optional

from fastapi import HTTPException

WEIGHT = "weight"
VOLUME = "volume"
COUNT = "count"

# How many base units one of each unit is.
FACTORS = {
    WEIGHT: {"kg": Decimal("1"), "g": Decimal("0.001")},
    VOLUME: {"l": Decimal("1"), "ml": Decimal("0.001"), "gallon": Decimal("3.785411784")},
}
_ALIASES = {
    "kgs": "kg", "kilo": "kg", "kilos": "kg", "kilogram": "kg", "kilograms": "kg",
    "gram": "g", "grams": "g",
    "liter": "l", "liters": "l", "litre": "l", "litres": "l",
    "milliliter": "ml", "milliliters": "ml", "mL": "ml",
    "gal": "gallon", "gallons": "gallon",
}


def _norm(unit: Optional[str]) -> str:
    u = (unit or "").strip()
    return _ALIASES.get(u, _ALIASES.get(u.lower(), u.lower()))


def dimension(base_unit: Optional[str]) -> str:
    """weight / volume / count, from an item's unit_of_measure."""
    u = _norm(base_unit)
    if u == "kg":
        return WEIGHT
    if u == "l":
        return VOLUME
    return COUNT


def units_for(base_unit: Optional[str]) -> list:
    """Units a custom size of this item may be typed in (for the app)."""
    dim = dimension(base_unit)
    if dim == WEIGHT:
        return ["kg", "g"]
    if dim == VOLUME:
        return ["L", "ml", "gallon"]
    return [base_unit or "pcs"]


def to_base(amount: Decimal, unit: Optional[str], base_unit: Optional[str]) -> Decimal:
    """Convert `amount unit` to the item's base unit. 422 when the unit does
    not fit the item (e.g. "ml" for rice)."""
    dim = dimension(base_unit)
    u = _norm(unit) if unit else _norm(base_unit)
    if dim == COUNT:
        if u not in (_norm(base_unit), ""):
            raise HTTPException(
                status_code=422,
                detail=f"This item is counted in {base_unit}, so a size must be in {base_unit}.",
            )
        return Decimal(amount)
    factor = FACTORS[dim].get(u)
    if factor is None:
        allowed = ", ".join(units_for(base_unit))
        raise HTTPException(status_code=422, detail=f"Use one of: {allowed} for this item.")
    return Decimal(amount) * factor


def whole(amount: Decimal) -> int:
    return int(Decimal(amount).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def fmt(amount) -> str:
    """1.5000 -> '1.5', 25.0000 -> '25'."""
    d = Decimal(amount).normalize()
    return format(d, "f")


def line_amounts(db, item, line) -> dict:
    """Quantity and packaging for one donation line.

    Older apps send `quantity` (already in the base unit) and a
    `packaging` label: kept exactly as sent. Newer apps send
    pack_count (+ per_pack, + size_id or size_amount/size_unit): the
    server works out the total. Returns the PhysicalDonation fields.
    """
    from models.item_model import ItemSize

    if getattr(line, "pack_count", None) is None:
        if not line.quantity:
            raise HTTPException(status_code=422, detail="Enter the quantity, or the number of packs.")
        return {
            "quantity": line.quantity,
            "packaging": line.packaging or f"{item.unit_of_measure}",
            "pack_count": None, "per_pack": None, "size_amount": None, "size_label": None,
        }

    per_pack = line.per_pack or 1
    if line.size_id is not None:
        size = db.get(ItemSize, line.size_id)
        if size is None or size.item_id != item.item_id:
            raise HTTPException(status_code=422, detail="Choose a size of this item.")
        amount, label = Decimal(size.amount), size.label
    elif line.size_amount is not None:
        amount = to_base(Decimal(str(line.size_amount)), line.size_unit, item.unit_of_measure)
        label = f"{fmt(Decimal(str(line.size_amount)))} {line.size_unit or item.unit_of_measure}"
    else:
        amount, label = Decimal(1), f"1 {item.unit_of_measure}"

    total = Decimal(line.pack_count) * per_pack * amount
    quantity = whole(total)
    if quantity < 1:
        raise HTTPException(
            status_code=422,
            detail=f"That comes to less than 1 {item.unit_of_measure}. Add more packs or a bigger size.",
        )
    if line.packaging:
        packaging = line.packaging
    elif per_pack > 1:
        packaging = f"Pack of {per_pack} x {label}"
    else:
        packaging = label
    return {
        "quantity": quantity,
        "packaging": packaging[:100],
        "pack_count": line.pack_count,
        "per_pack": per_pack,
        "size_amount": amount,
        "size_label": label[:60],
    }


def describe(row, unit: str) -> str:
    """'3 x 16 x 1.5 L bottle = 72 L' or '72 L' for a donation row."""
    if row.pack_count:
        per = f" x {row.per_pack}" if (row.per_pack or 1) > 1 else ""
        return f"{row.pack_count}{per} x {row.size_label} = {row.quantity} {unit}"
    return f"{row.quantity} {unit}"
