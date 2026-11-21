"""One Clothing item again: "Clothing – Upper" + "Clothing – Lower"

Nov 22, 2026: clothing as two items (b5e1f7a3c8d2) counted it twice in the
priority score, whose missing share is averaged per item. One "Clothing"
item in pieces is kept: Upper is renamed to it and Lower is merged into it
(report needs, donations, stock and deliveries; amounts added up per
report, so 10 Upper + 10 Lower = 20 Clothing). Which pieces they are is a
note on the donation line (physical_donations.contents), never an item.
"Clothing (packs, old)" stays retired (another unit, old records).

Same merge as the item clean-up (f3b8d1c5a9e7), whose helpers are reused.
The downgrade does nothing (merged rows cannot be told apart again).

Revision ID: c6e0a4b8d2f5
Revises: b4d8f2a6c0e3
"""
import importlib.util
from pathlib import Path
from typing import Sequence, Union

from alembic import op

revision: str = "c6e0a4b8d2f5"
down_revision: Union[str, Sequence[str], None] = "b4d8f2a6c0e3"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# En dash as in b5e1f7a3c8d2, and a plain hyphen in case one was typed.
CLOTHING_NAMES = ("Clothing – Upper", "Clothing - Upper",
                  "Clothing – Lower", "Clothing - Lower")


def _cleanup():
    path = next(Path(__file__).parent.glob("f3b8d1c5a9e7_*.py"))
    spec = importlib.util.spec_from_file_location("item_cleanup_f3b8d1c5a9e7", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def upgrade() -> None:
    bind = op.get_bind()
    m = _cleanup()
    for name in CLOTHING_NAMES:
        # The first one becomes "Clothing"; the others merge into it.
        m._fold_into(bind, name, "Clothing", rename_when_missing=True)


def downgrade() -> None:
    pass
