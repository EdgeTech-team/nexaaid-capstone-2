"""Proof of receipt: handover code and e-signature (J2 / NF-015, team agreement Nov 18, 2026)

deliveries
  handover_code_hash        keyed hash (HMAC-SHA256 with the server's
                            SECRET_KEY) of the 6-digit handover code made
                            when the delivery arrives. The code itself is
                            never stored.
  handover_code_created_at  when that code was made
receipts
  signer_name, signer_position   typed by the Barangay Receiving
                                 Representative (NULL for older receipts;
                                 the API requires them for new ones)
  signature_file_id              the signature PNG (uploads.file_id)
  slip_photo_file_id             optional photo of the stamped paper slip
  handover_verified              the right handover code was entered

Both file columns reference uploads.file_id (unique index ix_uploads_file_id)
with ON DELETE RESTRICT, so a file is never deleted while a receipt uses it.
Additive only; downgrade removes the columns.

Revision ID: a8c3e5f7b9d1
Revises: f7b2d4e6a8c1
"""
from alembic import op


revision = "a8c3e5f7b9d1"
down_revision = "f7b2d4e6a8c1"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS handover_code_hash VARCHAR(128)")
    op.execute("ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS handover_code_created_at TIMESTAMPTZ")

    op.execute("ALTER TABLE receipts ADD COLUMN IF NOT EXISTS signer_name VARCHAR(150)")
    op.execute("ALTER TABLE receipts ADD COLUMN IF NOT EXISTS signer_position VARCHAR(100)")
    op.execute("ALTER TABLE receipts ADD COLUMN IF NOT EXISTS signature_file_id VARCHAR(36)")
    op.execute("ALTER TABLE receipts ADD COLUMN IF NOT EXISTS slip_photo_file_id VARCHAR(36)")
    op.execute(
        "ALTER TABLE receipts ADD COLUMN IF NOT EXISTS handover_verified BOOLEAN NOT NULL DEFAULT false"
    )
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_receipts_signature_file_id') THEN
                ALTER TABLE receipts ADD CONSTRAINT fk_receipts_signature_file_id
                    FOREIGN KEY (signature_file_id) REFERENCES uploads (file_id) ON DELETE RESTRICT;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_receipts_slip_photo_file_id') THEN
                ALTER TABLE receipts ADD CONSTRAINT fk_receipts_slip_photo_file_id
                    FOREIGN KEY (slip_photo_file_id) REFERENCES uploads (file_id) ON DELETE RESTRICT;
            END IF;
        END
        $$;
        """
    )
    op.execute("CREATE INDEX IF NOT EXISTS ix_receipts_signature_file_id ON receipts (signature_file_id)")
    op.execute("CREATE INDEX IF NOT EXISTS ix_receipts_slip_photo_file_id ON receipts (slip_photo_file_id)")


def downgrade() -> None:
    op.execute("ALTER TABLE receipts DROP CONSTRAINT IF EXISTS fk_receipts_slip_photo_file_id")
    op.execute("ALTER TABLE receipts DROP CONSTRAINT IF EXISTS fk_receipts_signature_file_id")
    op.execute("DROP INDEX IF EXISTS ix_receipts_slip_photo_file_id")
    op.execute("DROP INDEX IF EXISTS ix_receipts_signature_file_id")
    op.execute("ALTER TABLE receipts DROP COLUMN IF EXISTS handover_verified")
    op.execute("ALTER TABLE receipts DROP COLUMN IF EXISTS slip_photo_file_id")
    op.execute("ALTER TABLE receipts DROP COLUMN IF EXISTS signature_file_id")
    op.execute("ALTER TABLE receipts DROP COLUMN IF EXISTS signer_position")
    op.execute("ALTER TABLE receipts DROP COLUMN IF EXISTS signer_name")
    op.execute("ALTER TABLE deliveries DROP COLUMN IF EXISTS handover_code_created_at")
    op.execute("ALTER TABLE deliveries DROP COLUMN IF EXISTS handover_code_hash")
