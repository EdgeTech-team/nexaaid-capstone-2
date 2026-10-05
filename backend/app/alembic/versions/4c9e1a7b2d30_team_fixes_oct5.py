"""team fixes Oct 5: org registration no. optional (D4), org rejection reason (D6, I3),
users.terms_accepted_at (D3)

Revision ID: 4c9e1a7b2d30
Revises: c4f2a9d1e7b3
Create Date: 2026-10-05

Not needed here:
  - D1 users.id_type: already nullable (migration f3dd12dbc3d7).
  - I4 logistics: the counts go into logistics_requests.notes.
  - J3 QR codes: a7c3e91b5d24 already adds barangay donation methods.
  - J5 SMS limit: count sms_report_metadata rows by contact_number and encoded_at.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "4c9e1a7b2d30"
down_revision: Union[str, Sequence[str], None] = "c4f2a9d1e7b3"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # D4: organizations can register with only the supporting document.
    # The UNIQUE constraint stays; Postgres allows many NULLs under UNIQUE.
    op.alter_column("organizations", "registration_no",
                    existing_type=sa.String(100), nullable=True)

    # D6 / I3: latest rejection reason, shown to the admin and at login.
    op.add_column("organizations", sa.Column("rejection_reason", sa.Text(), nullable=True))

    # D3: when the user ticked Terms and Conditions at registration.
    op.add_column("users", sa.Column("terms_accepted_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "terms_accepted_at")
    op.drop_column("organizations", "rejection_reason")
    # Give rows without a number a placeholder so NOT NULL can come back.
    op.execute("UPDATE organizations SET registration_no = 'NONE-' || organization_id "
               "WHERE registration_no IS NULL")
    op.alter_column("organizations", "registration_no",
                    existing_type=sa.String(100), nullable=False)