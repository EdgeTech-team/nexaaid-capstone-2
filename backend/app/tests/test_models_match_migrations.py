"""
The SQLAlchemy models must match the schema the Alembic migrations build.

Why: a model column that the database doesn't have only fails at runtime,
on Neon, usually as a 500. Example: a misplaced parenthesis in
models/upload_model.py renamed uploads.owner_user_id to
"fk_uploads_owner_user_id" (fixed in #19). The SQLite tests didn't notice,
because they build their tables from the models themselves.

How: load tests/sql/baseline_e837b545b195.sql (the schema before the first
migration) into a NEW temporary database on a throwaway local Postgres,
run every migration to head, then compare with Base.metadata using
alembic's compare_metadata (the same comparison autogenerate uses).

Runs only when TEST_POSTGRES_URL points at a local Postgres, e.g.
    TEST_POSTGRES_URL=postgresql://postgres:postgres@localhost:5432/postgres
Otherwise it is skipped. Never point it at Neon: it refuses any URL
containing "neon.tech" (migrations are applied to Neon only by Mark).
"""
import os
import secrets
from pathlib import Path

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.migration import MigrationContext
from sqlalchemy import create_engine
from sqlalchemy.engine import make_url

import main  # noqa: F401  (imports every router, so every model is registered)
from core.config import settings
from core.database import Base

APP_DIR = Path(__file__).resolve().parents[1]
BASELINE = APP_DIR / "tests" / "sql" / "baseline_e837b545b195.sql"
BASELINE_REVISION = "e837b545b195"
TEST_URL = os.getenv("TEST_POSTGRES_URL")

pytestmark = pytest.mark.skipif(
    not TEST_URL,
    reason="Set TEST_POSTGRES_URL to a throwaway local Postgres to compare models with migrations",
)


@pytest.fixture()
def migrated_engine(monkeypatch):
    if "neon.tech" in TEST_URL.lower():
        pytest.fail("TEST_POSTGRES_URL points at Neon. Use a throwaway local Postgres.")

    server = create_engine(TEST_URL, isolation_level="AUTOCOMMIT")
    name = f"nexaaid_migtest_{secrets.token_hex(4)}"
    with server.connect() as conn:
        conn.exec_driver_sql(f'CREATE DATABASE "{name}"')
    url = make_url(TEST_URL).set(database=name)
    engine = create_engine(url)
    try:
        with engine.begin() as conn:
            conn.exec_driver_sql(BASELINE.read_text())

        # No alembic.ini file: alembic/env.py would otherwise re-configure
        # logging for the whole test run. env.py takes the URL from
        # settings.DIRECT_URL, so point that at the temporary database.
        cfg = Config()
        cfg.set_main_option("script_location", str(APP_DIR / "alembic"))
        monkeypatch.setattr(settings, "DIRECT_URL", url.render_as_string(hide_password=False))
        command.stamp(cfg, BASELINE_REVISION)
        command.upgrade(cfg, "head")
        yield engine
    finally:
        engine.dispose()
        with server.connect() as conn:
            conn.exec_driver_sql(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        server.dispose()


def _flat(diffs):
    """compare_metadata nests column 'modify_*' changes in lists."""
    for d in diffs:
        if isinstance(d, list):
            yield from d
        else:
            yield d


def _diffs(engine):
    with engine.connect() as conn:
        ctx = MigrationContext.configure(conn, opts={"compare_type": True})
        return list(_flat(compare_metadata(ctx, Base.metadata)))


def test_every_model_table_and_column_exists_after_migrations(migrated_engine):
    missing = []
    for d in _diffs(migrated_engine):
        if d[0] == "add_table":
            missing.append(f"table {d[1].name}")
        elif d[0] == "add_column":
            missing.append(f"column {d[2]}.{d[3].name}")
    assert not missing, (
        "These model tables/columns do not exist after running all migrations. "
        "Fix the model, or add a hand-written migration:\n  " + "\n  ".join(missing)
    )


def test_model_column_types_and_nullability_match(migrated_engine):
    """A column that exists but with another type or NULL rule, e.g. a model
    VARCHAR(30) where the migration made VARCHAR(20)."""
    mismatches = []
    for d in _diffs(migrated_engine):
        if d[0] == "modify_type":
            _, _, table, column, _, db_type, model_type = d
            mismatches.append(f"{table}.{column}: database {db_type}, model {model_type}")
        elif d[0] == "modify_nullable":
            _, _, table, column, _, db_null, model_null = d
            mismatches.append(f"{table}.{column}: database nullable={db_null}, model nullable={model_null}")
    assert not mismatches, (
        "Model and migrated schema disagree:\n  " + "\n  ".join(mismatches)
    )
