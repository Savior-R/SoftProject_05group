-- 步骤2已由tools.bootstrap_db替代；仅保留历史环境说明，不作为G1流程。
-- =============================================================
-- 开发环境库初始化（**不是** 3.2.0 迁移，不建业务表）
-- 用途：为一个 Docker 里的 MySQL 8 实例准备七域 database 与测试库组
-- 维护人：A        适用：A1 单机开发形态
-- 注意：真正的表结构由 Alembic 迁移创建（步骤 2），此处只建容器
-- =============================================================

CREATE DATABASE IF NOT EXISTS `identity_org`  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `task_content`  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `classroom`     CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `media`         CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `evaluation`    CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `growth_cert`   CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `platform`      CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

-- 测试库组：与开发库物理隔离，测试入口会校验 allowlist
CREATE DATABASE IF NOT EXISTS `test_identity_org` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `test_task_content` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `test_classroom`    CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `test_media`        CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `test_evaluation`   CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `test_growth_cert`  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS `test_platform`     CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

-- 此历史文件只包含空库DDL，不是当前初始化入口。
-- 步骤2起请使用tools.bootstrap_db创建全新隔离七库及独立迁移/业务账号。
-- 不得向业务账号授予DDL或测试库通配权限；platform需建表后分表授权。

SELECT SCHEMA_NAME AS `已创建库`, DEFAULT_CHARACTER_SET_NAME AS `字符集`, DEFAULT_COLLATION_NAME AS `排序规则`
FROM information_schema.SCHEMATA
WHERE SCHEMA_NAME IN (
  'identity_org','task_content','classroom','media','evaluation','growth_cert','platform',
  'test_identity_org','test_task_content','test_classroom','test_media','test_evaluation','test_growth_cert','test_platform'
)
ORDER BY SCHEMA_NAME;
