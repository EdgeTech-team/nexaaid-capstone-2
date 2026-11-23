"""database/seeds/demo_seed.sql must not bring back retired items (NF-006)
and must mirror the hazard migrations (NF-004).

The suite runs on SQLite and cannot execute the seed (Postgres-only SQL),
so these tests read the file. Running it twice on Postgres is a manual
test step (PR #110 follow-ups)."""
import re
from pathlib import Path

SEED = (Path(__file__).resolve().parents[4] / "database" / "seeds" / "demo_seed.sql").read_text(
    encoding="utf-8")


def _section(start: str, end: str) -> str:
    return SEED[SEED.index(start):SEED.index(end)]


def _sql(text: str) -> str:
    """The text without -- comments, so a comment may still name a removed item."""
    return re.sub(r"--[^\n]*", "", text)


def test_the_seed_does_not_bring_back_removed_items():
    sql = _sql(SEED)
    assert "Municipal Water" not in sql
    assert "MC Water" not in sql
    items = _sql(_section("INSERT INTO items", "INSERT INTO item_sizes"))
    assert not re.search(r"'Clothing'\s*,\s*'Clothing'\s*,\s*'packs'", items)   # old Clothing (packs)

def test_the_seed_adds_one_clothing_item_once():
    items = _section("INSERT INTO items", "INSERT INTO item_sizes")
    # Nov 22 (c6e0a4b8d2f5): one Clothing item in pieces, not Upper / Lower.
    assert items.count("('Clothing',         'Clothing', 'pcs')") == 1
    assert "Upper" not in items and "Lower" not in items
    # Insert-if-missing, so running the seed twice adds nothing.
    assert "WHERE NOT EXISTS (SELECT 1 FROM items i WHERE lower(i.item_name) = lower(v.item_name))" in items



def test_the_seed_mirrors_the_hazard_migrations():
    hazards = _section("-- 2b-1. NF-004", "-- 2c.")
    assert "'Landslide', 'Storm Surge', 'Tsunami'" in hazards
    for barangay in ("Paknaan", "Umapad", "Opao", "Looc"):
        assert re.search(rf"\('Tsunami',\s+'{barangay}',\s+'Mandaue CDRRMO", hazards), barangay
    for type_name in ("Storm Surge", "Tsunami"):
        for barangay in ("Subangdaku", "Tipolo", "Centro", "Labogon"):
            assert re.search(rf"\('{type_name}',\s+'{barangay}',\s+'PENDING CDRRMO confirmation'\)",
                             hazards), (type_name, barangay)
