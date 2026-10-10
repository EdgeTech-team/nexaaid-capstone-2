"""TEMPORARY stand-in for a teammate's migration that is already on Neon.

Revision c4a91f27d3b8 was run on Neon from a teammate's PC, but the file
is not pushed yet. This empty stand-in only lets alembic find the ID.
It changes nothing in the database.

DELETE THIS FILE as soon as the teammate's real c4a91f27d3b8 file is
pulled, otherwise alembic will see the same revision twice.

Revision ID: c4a91f27d3b8
Revises: 7a2c4e6b8d10
"""

revision = "c4a91f27d3b8"
down_revision = "7a2c4e6b8d10"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Already applied on Neon by the teammate's real migration.
    pass


def downgrade() -> None:
    pass