"""3.2.0全新61表初始修订；只执行经A审查冻结的不可变DDL。"""

from alembic import op

from common.database_config import DOMAINS
from tools.freeze_baseline import load_snapshot

revision = "0001_baseline_320"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    snapshot = load_snapshot()
    group = op.get_context().opts["schema_group"]
    connection = op.get_bind()
    for statement in snapshot["statements"]:
        for domain in DOMAINS:
            statement = statement.replace(f"__db_{domain}__", group.mapping[domain])
        connection.exec_driver_sql(statement)


def downgrade():
    raise RuntimeError("不提供自动删库回退或旧52表降级；请使用已验证的新基线备份恢复。")
