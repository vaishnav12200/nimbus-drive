"""encryption parameters

Records *how* a user's key is derived, not just the salt.

The original schema stored `encryption_salt` alone, which implicitly hard-codes
one KDF and one set of cost parameters forever. Raising Argon2's cost — or
moving off PBKDF2 — would then change every derived key without any way to know
which files predated the change, and an encrypted file whose key cannot be
reproduced is gone for good.

Storing the algorithm and its parameters per user makes that upgradeable: new
accounts get stronger defaults while existing ones keep deriving the key that
actually opens their files.

`encryption_verifier` holds an opaque client-produced blob (AES-GCM over a known
plaintext). GCM already fails closed on a wrong key, but only once a file has
been downloaded; this lets a freshly installed app reject a wrong password up
front.

Revision ID: dd357b77137a
Revises: a9ecf7a576e8
Create Date: 2026-08-02 14:12:43.750491
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "dd357b77137a"
down_revision: str | None = "a9ecf7a576e8"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # All nullable: every existing account has encryption disabled, and these
    # are populated only when a user opts in. No backfill, no table rewrite.
    op.add_column(
        "users", sa.Column("encryption_kdf", sa.String(length=32), nullable=True)
    )
    op.add_column(
        "users",
        sa.Column(
            "encryption_kdf_params",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=True,
        ),
    )
    op.add_column(
        "users", sa.Column("encryption_verifier", sa.LargeBinary(), nullable=True)
    )


def downgrade() -> None:
    # Destructive by nature: dropping these leaves any encrypted files
    # underivable, since nothing then records which KDF produced their key.
    op.drop_column("users", "encryption_verifier")
    op.drop_column("users", "encryption_kdf_params")
    op.drop_column("users", "encryption_kdf")
