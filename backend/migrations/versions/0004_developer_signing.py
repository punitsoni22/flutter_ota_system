# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""developer-signed dbc-v1 patches: trust roots, key certificates, revocation lists,
baseline identity on releases, container metadata on patch artifacts (Phase 4, D4/D5)

Revision ID: 0004
Revises: 0003

Additive. Existing rows keep their values; every new column is nullable. The server signature
columns of patch_artifacts become nullable because dbc-v1 artifacts carry no server signature.
"""

import sqlalchemy as sa
from alembic import op

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "trust_roots",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("application_id", sa.String(length=36), nullable=False),
        sa.Column("key_id", sa.String(length=64), nullable=False),
        sa.Column("public_key", sa.String(length=120), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["application_id"], ["applications.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("application_id", "key_id"),
    )
    op.create_index("ix_trust_roots_application_id", "trust_roots", ["application_id"])

    op.create_table(
        "key_certificates",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("application_id", sa.String(length=36), nullable=False),
        sa.Column("serial", sa.BigInteger(), nullable=False),
        sa.Column("key_id", sa.String(length=64), nullable=False),
        sa.Column("roles", sa.String(length=64), nullable=False),
        sa.Column("environment", sa.String(length=64), nullable=False),
        sa.Column("not_before", sa.DateTime(timezone=True), nullable=False),
        sa.Column("not_after", sa.DateTime(timezone=True), nullable=False),
        sa.Column("root_key_id", sa.String(length=64), nullable=False),
        sa.Column("certificate", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["application_id"], ["applications.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("application_id", "serial"),
    )
    op.create_index("ix_key_certificates_application_id", "key_certificates", ["application_id"])

    op.create_table(
        "revocation_lists",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("application_id", sa.String(length=36), nullable=False),
        sa.Column("release_id", sa.String(length=36), nullable=True),
        sa.Column("sequence", sa.BigInteger(), nullable=False),
        sa.Column("data", sa.LargeBinary(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["application_id"], ["applications.id"]),
        sa.ForeignKeyConstraint(["release_id"], ["releases.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("application_id", "sequence"),
    )
    op.create_index("ix_revocation_lists_application_id", "revocation_lists", ["application_id"])
    op.create_index("ix_revocation_lists_release_id", "revocation_lists", ["release_id"])

    with op.batch_alter_table("releases") as batch:
        batch.add_column(sa.Column("toolchain_id", sa.String(length=64), nullable=True))
        batch.add_column(sa.Column("dart_revision", sa.String(length=64), nullable=True))
        batch.add_column(sa.Column("bytecode_format", sa.Integer(), nullable=True))
        batch.add_column(sa.Column("interface_sha256", sa.String(length=64), nullable=True))
        batch.add_column(sa.Column("trust_environment", sa.String(length=64), nullable=True))

    with op.batch_alter_table("patch_artifacts") as batch:
        batch.alter_column("signature", existing_type=sa.String(length=200), nullable=True)
        batch.alter_column("key_id", existing_type=sa.String(length=64), nullable=True)
        batch.add_column(sa.Column("manifest", sa.Text(), nullable=True))
        batch.add_column(sa.Column("manifest_sha256", sa.String(length=64), nullable=True))
        batch.add_column(sa.Column("manifest_patch_id", sa.String(length=36), nullable=True))
        batch.add_column(sa.Column("sequence", sa.BigInteger(), nullable=True))
        batch.add_column(sa.Column("signer_key_id", sa.String(length=64), nullable=True))
        batch.add_column(sa.Column("cert_serial", sa.BigInteger(), nullable=True))
        batch.add_column(sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True))
        batch.create_index("ix_patch_artifacts_manifest_patch_id", ["manifest_patch_id"])


def downgrade() -> None:
    # dbc-v1 artifacts have no server signature. Old code needs a value: an empty one never
    # verifies, and old clients never ask for dbc-v1 anyway.
    op.execute("UPDATE patch_artifacts SET signature = '' WHERE signature IS NULL")
    op.execute("UPDATE patch_artifacts SET key_id = '' WHERE key_id IS NULL")
    with op.batch_alter_table("patch_artifacts") as batch:
        batch.drop_index("ix_patch_artifacts_manifest_patch_id")
        for column in (
            "expires_at", "cert_serial", "signer_key_id", "sequence", "manifest_patch_id",
            "manifest_sha256", "manifest",
        ):
            batch.drop_column(column)
        batch.alter_column("key_id", existing_type=sa.String(length=64), nullable=False)
        batch.alter_column("signature", existing_type=sa.String(length=200), nullable=False)

    with op.batch_alter_table("releases") as batch:
        for column in ("trust_environment", "interface_sha256", "bytecode_format", "dart_revision", "toolchain_id"):
            batch.drop_column(column)

    op.drop_index("ix_revocation_lists_release_id", table_name="revocation_lists")
    op.drop_index("ix_revocation_lists_application_id", table_name="revocation_lists")
    op.drop_table("revocation_lists")
    op.drop_index("ix_key_certificates_application_id", table_name="key_certificates")
    op.drop_table("key_certificates")
    op.drop_index("ix_trust_roots_application_id", table_name="trust_roots")
    op.drop_table("trust_roots")
