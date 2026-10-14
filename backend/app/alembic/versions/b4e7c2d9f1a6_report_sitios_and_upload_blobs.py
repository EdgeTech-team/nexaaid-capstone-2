"""Several sitios per report, and uploads shared between machines (problema_napud)

1. report_sitios (problema_napud 2.2): a disaster report can name several
   sitios of its barangay, e.g. only 2 of its sitios were hit. Every
   existing report with disaster_reports.sitio_id gets that sitio here.
   disaster_reports.sitio_id stays and keeps the first sitio, so nothing
   that reads it today changes.

2. upload_blobs (problema_napud 2.1, "QR image unavailable"): a copy of each
   uploaded file's bytes. The team runs one shared Neon database from
   several machines, and a file saved on one machine's disk was missing on
   every other one. Files uploaded before this revision are copied in the
   first time the machine that has them serves them
   (core/uploads.local_path), or right away with
   scripts/backfill_upload_blobs.py.

Additive only. Safe to re-run (IF NOT EXISTS / ON CONFLICT DO NOTHING).

Revision ID: b4e7c2d9f1a6
Revises: e5b2c8d4a917
"""
from alembic import op


revision = "b4e7c2d9f1a6"
down_revision = "e5b2c8d4a917"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS report_sitios (
            report_id INTEGER NOT NULL,
            sitio_id INTEGER NOT NULL,
            CONSTRAINT pk_report_sitios PRIMARY KEY (report_id, sitio_id),
            CONSTRAINT fk_report_sitios_report_id FOREIGN KEY (report_id)
                REFERENCES disaster_reports (report_id) ON DELETE CASCADE,
            CONSTRAINT fk_report_sitios_sitio_id FOREIGN KEY (sitio_id)
                REFERENCES sitios (sitio_id) ON DELETE CASCADE
        )
        """
    )
    op.execute(
        """
        INSERT INTO report_sitios (report_id, sitio_id)
        SELECT report_id, sitio_id FROM disaster_reports WHERE sitio_id IS NOT NULL
        ON CONFLICT DO NOTHING
        """
    )
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS upload_blobs (
            upload_id INTEGER NOT NULL,
            data BYTEA NOT NULL,
            CONSTRAINT pk_upload_blobs PRIMARY KEY (upload_id),
            CONSTRAINT fk_upload_blobs_upload_id FOREIGN KEY (upload_id)
                REFERENCES uploads (upload_id) ON DELETE CASCADE
        )
        """
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS upload_blobs")
    op.execute("DROP TABLE IF EXISTS report_sitios")
