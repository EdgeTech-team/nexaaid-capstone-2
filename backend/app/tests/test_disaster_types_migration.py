"""Migration d3f8b2a61c47: the Mandaue City disaster types.

Runs only when TEST_POSTGRES_URL points at a throwaway local Postgres, like
test_models_match_migrations.py (it refuses Neon). Builds the schema up to
the revision before, adds the old types (and reports using them), then
checks the upgrade, the downgrade, and the upgrade again.
"""
import os
import secrets
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

import main  # noqa: F401  (imports every router, so every model is registered)
from core.config import settings

APP_DIR = Path(__file__).resolve().parents[1]
BASELINE = APP_DIR / "tests" / "sql" / "baseline_e837b545b195.sql"
TEST_URL = os.getenv("TEST_POSTGRES_URL")
BEFORE, REVISION = "b7d3e9f1a2c4", "d3f8b2a61c47"

pytestmark = pytest.mark.skipif(
    not TEST_URL, reason="Set TEST_POSTGRES_URL to a throwaway local Postgres")

NEW = {
    "Typhoon": "Tropical cyclone with strong winds and heavy rain",
    "Flood": "Urban flooding, flash flood, or river overflow",
    "Storm Surge": "Coastal flooding caused by a typhoon's storm surge",
    "Earthquake": "Ground shaking from a seismic event, including damage from aftershocks",
    "Fire": "Residential, commercial, or industrial fire",
    "Tsunami": "Coastal flooding caused by a seismic event",
    "Other": "Disaster not covered by the listed types; details go in the report description",
}
OLD = {
    "Typhoon": "Tropical cyclone with strong winds and heavy rain",
    "Earthquake": "Ground shaking and structural damage",
    "Tsunami": "Sea waves caused by an undersea earthquake",
    "Landslide": "Soil or rock sliding down slopes",
    "Flash Flood": "Sudden flooding within hours of heavy rain",
    "Fire": "Residential or commercial fire",
    "Flood": "Rising water from heavy rain or overflowing rivers",
    "Volcanic Eruption": "Ashfall or eruption affecting the area",
    "Disease Outbreak": "Epidemic needing medical and hygiene supplies",
    "Drought": "Long dry spell affecting water and food supply",
    "Storm Surge": "Coastal flooding pushed in by a typhoon",
}


@pytest.fixture()
def migrated(monkeypatch):
    """(engine, alembic config) of a new database at the revision before."""
    if "neon.tech" in TEST_URL.lower():
        pytest.fail("TEST_POSTGRES_URL points at Neon. Use a throwaway local Postgres.")
    server = create_engine(TEST_URL, isolation_level="AUTOCOMMIT")
    name = f"nexaaid_typetest_{secrets.token_hex(4)}"
    with server.connect() as conn:
        conn.exec_driver_sql(f'CREATE DATABASE "{name}"')
    url = make_url(TEST_URL).set(database=name)
    engine = create_engine(url)
    cfg = Config()
    cfg.set_main_option("script_location", str(APP_DIR / "alembic"))
    monkeypatch.setattr(settings, "DIRECT_URL", url.render_as_string(hide_password=False))
    try:
        with engine.begin() as conn:
            conn.exec_driver_sql(BASELINE.read_text())
        command.stamp(cfg, "e837b545b195")
        command.upgrade(cfg, BEFORE)
        with engine.begin() as conn:
            for type_name, description in OLD.items():
                conn.execute(text("INSERT INTO disaster_types (type_name, description) "
                                  "VALUES (:n, :d)"), {"n": type_name, "d": description})
        yield engine, cfg
    finally:
        engine.dispose()
        with server.connect() as conn:
            conn.exec_driver_sql(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        server.dispose()


def _types(engine) -> dict:
    with engine.connect() as conn:
        return dict(conn.execute(text("SELECT type_name, description FROM disaster_types")).all())


def _report_types(engine) -> dict:
    with engine.connect() as conn:
        return dict(conn.execute(text(
            "SELECT r.report_id, t.type_name FROM disaster_reports r "
            "JOIN disaster_types t USING (disaster_type_id)")).all())


def _reports(engine, *type_names) -> dict:
    """One Pending report per type name -> {type name: report_id}."""
    with engine.begin() as conn:
        conn.execute(text("INSERT INTO cities (city_name) VALUES ('Mandaue City')"))
        conn.execute(text("INSERT INTO barangays (barangay_name, city_id) "
                          "SELECT 'Centro', city_id FROM cities"))
        conn.execute(text("INSERT INTO roles (role_name) VALUES ('CSWS Disaster Unit')"))
        conn.execute(text(
            "INSERT INTO users (first_name, last_name, email, password_hash, contact_number, role_id) "
            "SELECT 'Test', 'Unit', 'unit@example.com', 'x', '09171234567', role_id FROM roles"))
        return {
            t: conn.execute(text(
                "INSERT INTO disaster_reports (user_id, disaster_type_id, barangay_id, source) "
                "SELECT u.user_id, d.disaster_type_id, b.barangay_id, 'Web' "
                "FROM users u, disaster_types d, barangays b WHERE d.type_name = :t "
                "RETURNING report_id"), {"t": t}).scalar_one()
            for t in type_names
        }


def test_upgrade_leaves_the_seven_types_with_their_descriptions(migrated):
    engine, cfg = migrated
    command.upgrade(cfg, REVISION)
    assert _types(engine) == NEW


def test_reports_of_removed_types_move_to_the_closest_new_one(migrated):
    engine, cfg = migrated
    ids = _reports(engine, "Flood", "Flash Flood", "Landslide", "Drought")
    command.upgrade(cfg, REVISION)
    assert _report_types(engine) == {
        ids["Flood"]: "Flood",
        ids["Flash Flood"]: "Flood",
        ids["Landslide"]: "Other",
        ids["Drought"]: "Other",
    }
    assert set(_types(engine)) == set(NEW)  # the moved-from types are gone
    # Downgrade keeps Other while reports use it; the old types come back.
    command.downgrade(cfg, BEFORE)
    assert set(_types(engine)) == set(OLD) | {"Other"}


def test_upgrade_updates_a_type_that_already_exists(migrated):
    engine, cfg = migrated
    with engine.begin() as conn:
        conn.execute(text("INSERT INTO disaster_types (type_name, description) "
                          "VALUES ('Other', 'Old wording')"))
    command.upgrade(cfg, REVISION)
    assert _types(engine)["Other"] == NEW["Other"]


def test_downgrade_restores_the_old_types_and_upgrade_runs_again(migrated):
    engine, cfg = migrated
    command.upgrade(cfg, REVISION)
    command.downgrade(cfg, BEFORE)
    assert _types(engine) == OLD          # old descriptions back, Other gone
    command.upgrade(cfg, REVISION)
    assert _types(engine) == NEW
