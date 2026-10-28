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

-- 日常 DML 账户（最小权限：只在这七域与测试库组内有权限）
-- 口令不写进本文件，由 init-dev-databases.ps1 在执行时用 runtime/local-db.env 注入
-- CREATE USER IF NOT EXISTS 'ai_teach'@'%' IDENTIFIED BY '<由脚本注入>';
-- GRANT ALL PRIVILEGES ON `identity_org`.* TO 'ai_teach'@'%';
-- GRANT ALL PRIVILEGES ON `task_content`.* TO 'ai_teach'@'%';
-- GRANT ALL PRIVILEGES ON `classroom`.*    TO 'ai_teach'@'%';
-- GRANT ALL PRIVILEGES ON `media`.*        TO 'ai_teach'@'%';
-- GRANT ALL PRIVILEGES ON `evaluation`.*   TO 'ai_teach'@'%';
-- GRANT ALL PRIVILEGES ON `growth_cert`.*  TO 'ai_teach'@'%';
-- GRANT ALL PRIVILEGES ON `platform`.*     TO 'ai_teach'@'%';
-- GRANT ALL PRIVILEGES ON `test\_%`.*      TO 'ai_teach'@'%';
-- FLUSH PRIVILEGES;

SELECT SCHEMA_NAME AS `已创建库`, DEFAULT_CHARACTER_SET_NAME AS `字符集`, DEFAULT_COLLATION_NAME AS `排序规则`
FROM information_schema.SCHEMATA
WHERE SCHEMA_NAME IN (
  'identity_org','task_content','classroom','media','evaluation','growth_cert','platform',
  'test_identity_org','test_task_content','test_classroom','test_media','test_evaluation','test_growth_cert','test_platform'
)
ORDER BY SCHEMA_NAME;
