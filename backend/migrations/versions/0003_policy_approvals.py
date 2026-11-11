# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""policy approval history with reasons (KI-2)

Revision ID: 0003
Revises: 0002
"""

import uuid
from datetime import datetime, timezone

import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "policy_approvals",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("application_id", sa.String(length=36), nullable=False),
        sa.Column("approved", sa.Boolean(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["application_id"], ["applications.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_policy_approvals_application_id", "policy_approvals", ["application_id"])

    # Apps approved before reasons were stored get one record saying so.
    conn = op.get_bind()
    approved = conn.execute(sa.text("SELECT id FROM applications WHERE aot_policy_approved")).scalars().all()
    table = sa.table(
        "policy_approvals",
        sa.column("id", sa.String), sa.column("application_id", sa.String), sa.column("approved", sa.Boolean),
        sa.column("reason", sa.Text), sa.column("created_at", sa.DateTime(timezone=True)),
    )
    now = datetime.now(timezone.utc)
    if approved:
        op.bulk_insert(table, [
            {"id": str(uuid.uuid4()), "application_id": app_id, "approved": True,
             "reason": "(approved before Punit stored reasons; reason unknown)", "created_at": now}
            for app_id in approved
        ])


def downgrade() -> None:
    op.drop_index("ix_policy_approvals_application_id", table_name="policy_approvals")
    op.drop_table("policy_approvals")
