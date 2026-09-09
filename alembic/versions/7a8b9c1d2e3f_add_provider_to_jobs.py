"""add_provider_to_jobs

Revision ID: 7a8b9c1d2e3f
Revises: 53207a3266e9
Create Date: 2026-09-09 10:56:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "7a8b9c1d2e3f"
down_revision: str | Sequence[str] | None = "53207a3266e9"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column("jobs", sa.Column("provider", sa.String(length=64), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("jobs", "provider")
