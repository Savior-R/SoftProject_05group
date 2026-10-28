-- =============================================================================
-- 迁移 U-21 ~ U-26：补齐 11-实现契约 §10.4 列出的 6 处 DDL 缺口
-- =============================================================================
-- 依据：11-实现契约 V1.1 §10.4 缺口清单 G-02/G-07/G-08/G-10
-- 前置：已执行 ai_teach_mysql8_ddl.sql 或 ai_teach_sqlserver_ddl.sql（52 表已建）
-- 适用：**已建库的存量环境**。全新环境请直接跑两份 DDL（已含这些列），勿再跑本脚本。
--
-- 变更清单：
--   U-21  trial_session  增 structured_q_id（结构化面试题目落库，修复 G-02）
--   U-22  export_task    增 error（导出失败原因，修复 G-10）
--   U-23  rubric         增 grade_bands（等级分数线可配，D11 / 修复 G-07 前半）
--   U-24  rubric_item    增 scored_by（评分主体，D12 / 修复 G-07 后半）
--   U-25  user           增 locked_until（登录锁定跨重启，修复 G-08）
--   U-26  trial_session  增 mode 与 topic/scenario/structured_q 的一致性 CHECK
--
-- 执行顺序：MySQL 段 或 SQL Server 段，二选一。
-- 全部为「加列/加约束」，向后兼容，可在线执行（大表加列注意锁）。
-- 回滚见 §3。
-- =============================================================================


-- #############################################################################
-- §1 MySQL 8
-- #############################################################################

-- -----------------------------------------------------------------------------
-- §1.0 预检：确认这些列/约束当前不存在（应全部返回 0 行）
-- -----------------------------------------------------------------------------
SELECT 'structured_q_id' AS col, COUNT(*) AS exists_cnt FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='classroom' AND TABLE_NAME='trial_session' AND COLUMN_NAME='structured_q_id'
UNION ALL
SELECT 'export_task.error', COUNT(*) FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='platform' AND TABLE_NAME='export_task' AND COLUMN_NAME='error'
UNION ALL
SELECT 'rubric.grade_bands', COUNT(*) FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='task_content' AND TABLE_NAME='rubric' AND COLUMN_NAME='grade_bands'
UNION ALL
SELECT 'rubric_item.scored_by', COUNT(*) FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='task_content' AND TABLE_NAME='rubric_item' AND COLUMN_NAME='scored_by'
UNION ALL
SELECT 'user.locked_until', COUNT(*) FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='identity_org' AND TABLE_NAME='user' AND COLUMN_NAME='locked_until';

-- -----------------------------------------------------------------------------
-- §1.1 U-21 trial_session.structured_q_id（G-02 阻断级）
-- -----------------------------------------------------------------------------
-- 影响：结构化面试模式原先无法记录「考的是哪道题」（topic_id 只能指向 trial_topic）。
-- 加列后 POST /sessions 的 structured_q_id 才真正可用。

ALTER TABLE classroom.trial_session
  ADD COLUMN structured_q_id CHAR(36) NULL DEFAULT NULL
    COMMENT '结构化面试题目ID，→task_content.structured_question；mode=structured 时必填。V1.1 新增'
    AFTER topic_id;

ALTER TABLE classroom.trial_session
  ADD KEY idx_sess_sq (structured_q_id);

ALTER TABLE classroom.trial_session
  ADD CONSTRAINT fk_sess_sq FOREIGN KEY (structured_q_id)
    REFERENCES task_content.structured_question (q_id)
    ON DELETE SET NULL ON UPDATE CASCADE;

-- -----------------------------------------------------------------------------
-- §1.2 U-26 会话模式与题目字段的一致性约束
-- -----------------------------------------------------------------------------
-- 防「结构化面试却没题目」「自由试讲却没题面」这类脏数据。
-- 注意：存量数据若已有违反（如 mode=structured 且 structured_q_id 为 NULL），
--       本步会失败。先执行下面的检查，有结果则先修数据：
--
--   SELECT session_id, mode, topic_id, scenario_id FROM classroom.trial_session
--    WHERE (mode <> 'structured' AND topic_id IS NULL)
--       OR (mode =  'structured' AND structured_q_id IS NULL)
--       OR (mode =  'scenario'   AND scenario_id  IS NULL);

ALTER TABLE classroom.trial_session
  ADD CONSTRAINT ck_sess_mode_topic CHECK (mode = 'structured' OR topic_id IS NOT NULL),
  ADD CONSTRAINT ck_sess_mode_sq    CHECK (mode <> 'structured' OR structured_q_id IS NOT NULL),
  ADD CONSTRAINT ck_sess_mode_sc    CHECK (mode <> 'scenario'   OR scenario_id IS NOT NULL);

-- -----------------------------------------------------------------------------
-- §1.3 U-22 export_task.error（G-10）
-- -----------------------------------------------------------------------------

ALTER TABLE platform.export_task
  ADD COLUMN error VARCHAR(500) NULL DEFAULT NULL
    COMMENT '失败原因；status=failed 时必填。V1.1 新增（对应 11 §2.7 响应字段）'
    AFTER status;

ALTER TABLE platform.export_task
  ADD CONSTRAINT ck_et_error CHECK (status <> 'failed' OR error IS NOT NULL);

-- -----------------------------------------------------------------------------
-- §1.4 U-23 rubric.grade_bands（D11 / G-07 前半）
-- -----------------------------------------------------------------------------
-- 存 JSON：{"excellent":90,"good":80,"pass":60}；NULL 时服务层用系统默认。
-- 加列后，等级判定不再硬编码（11 §4.4）。

ALTER TABLE task_content.rubric
  ADD COLUMN grade_bands JSON NULL DEFAULT NULL
    COMMENT '等级分数线：{"excellent":90,"good":80,"pass":60}；NULL 时用系统默认。V1.1 新增（决议 D11）'
    AFTER dimension_weights;

ALTER TABLE task_content.rubric
  ADD CONSTRAINT ck_rubric_bands CHECK (grade_bands IS NULL OR JSON_VALID(grade_bands));

-- -----------------------------------------------------------------------------
-- §1.5 U-24 rubric_item.scored_by（D12 / G-07 后半）
-- -----------------------------------------------------------------------------
-- ai=仅 AI；human=仅人工；ai_then_human=AI 初评可人工覆盖。
-- 默认 ai 以兼容存量数据（原行为即「ai_enabled=1 视为 AI 可评」）。

ALTER TABLE task_content.rubric_item
  ADD COLUMN scored_by ENUM('ai','human','ai_then_human') NOT NULL DEFAULT 'ai'
    COMMENT '评分主体：ai 仅AI/human 仅人工/ai_then_human AI初评可人工覆盖。V1.1 新增（决议 D12）'
    AFTER ai_enabled;

-- 存量数据迁移：ai_enabled=0 的行原本是「仅人工」，语义应落到 scored_by='human'
UPDATE task_content.rubric_item
   SET scored_by = 'human'
 WHERE ai_enabled = 0;

-- -----------------------------------------------------------------------------
-- §1.6 U-25 user.locked_until（G-08）
-- -----------------------------------------------------------------------------
-- 登录失败 5 次写 now+15min；到期自动解锁；不再依赖 Redis，重启不丢。

ALTER TABLE identity_org.`user`
  ADD COLUMN locked_until DATETIME(3) NULL DEFAULT NULL
    COMMENT '锁定截止时间（UTC）；登录失败 5 次写入 now+15min，到期自动解锁，跨重启有效。V1.1 新增'
    AFTER status;

-- -----------------------------------------------------------------------------
-- §1.7 U-27 user.must_change_password（配合 G-01 新增的用户管理端点）
-- -----------------------------------------------------------------------------
-- 管理员创建账号或重置密码后置 1，首次登录成功后置 0，前端据此强制跳改密页。

ALTER TABLE identity_org.`user`
  ADD COLUMN must_change_password TINYINT(1) NOT NULL DEFAULT 0
    COMMENT '是否强制改密：1 是。V1.1 新增；管理员创建账号或重置密码后置 1，首次登录成功后置 0'
    AFTER locked_until;


-- #############################################################################
-- §2 SQL Server 2025
-- #############################################################################

/*
-- §2.0 预检
SELECT 'structured_q_id' AS col, COUNT(*) AS exists_cnt FROM sys.columns
 WHERE object_id = OBJECT_ID(N'classroom.trial_session') AND name = 'structured_q_id'
UNION ALL
SELECT 'export_task.error', COUNT(*) FROM sys.columns
 WHERE object_id = OBJECT_ID(N'platform.export_task') AND name = 'error'
UNION ALL
SELECT 'rubric.grade_bands', COUNT(*) FROM sys.columns
 WHERE object_id = OBJECT_ID(N'task_content.rubric') AND name = 'grade_bands'
UNION ALL
SELECT 'rubric_item.scored_by', COUNT(*) FROM sys.columns
 WHERE object_id = OBJECT_ID(N'task_content.rubric_item') AND name = 'scored_by'
UNION ALL
SELECT 'user.locked_until', COUNT(*) FROM sys.columns
 WHERE object_id = OBJECT_ID(N'identity_org.[user]') AND name = 'locked_until';

SET XACT_ABORT ON;
BEGIN TRY
  BEGIN TRANSACTION;

  -- §2.1 U-21
  ALTER TABLE classroom.trial_session
    ADD structured_q_id UNIQUEIDENTIFIER NULL;
  EXEC sp_addextendedproperty N'MS_Description',
    N'结构化面试题目ID，→task_content.structured_question；mode=structured 时必填。V1.1 新增',
    N'SCHEMA', N'classroom', N'TABLE', N'trial_session', N'COLUMN', N'structured_q_id';

  ALTER TABLE classroom.trial_session
    ADD CONSTRAINT fk_sess_sq FOREIGN KEY (structured_q_id)
      REFERENCES task_content.structured_question (q_id) ON DELETE SET NULL;

  CREATE INDEX idx_sess_sq ON classroom.trial_session(structured_q_id);

  -- §2.2 U-26
  ALTER TABLE classroom.trial_session
    ADD CONSTRAINT ck_sess_mode_topic CHECK ([mode] = 'structured' OR topic_id IS NOT NULL),
        CONSTRAINT ck_sess_mode_sq    CHECK ([mode] <> 'structured' OR structured_q_id IS NOT NULL),
        CONSTRAINT ck_sess_mode_sc    CHECK ([mode] <> 'scenario'   OR scenario_id IS NOT NULL);

  -- §2.3 U-22
  ALTER TABLE platform.export_task ADD [error] NVARCHAR(500) NULL;
  ALTER TABLE platform.export_task
    ADD CONSTRAINT ck_et_error CHECK ([status] <> 'failed' OR [error] IS NOT NULL);

  -- §2.4 U-23
  ALTER TABLE task_content.rubric ADD grade_bands NVARCHAR(MAX) NULL;
  ALTER TABLE task_content.rubric
    ADD CONSTRAINT ck_rubric_bands CHECK (grade_bands IS NULL OR ISJSON(grade_bands) = 1);

  -- §2.5 U-24（SQL Server 的 ENUM 落为 NVARCHAR + CHECK）
  ALTER TABLE task_content.rubric_item
    ADD scored_by NVARCHAR(14) NOT NULL CONSTRAINT df_ri_scored_by DEFAULT 'ai';
  ALTER TABLE task_content.rubric_item
    ADD CONSTRAINT ck_ri_scored_by CHECK (scored_by IN ('ai','human','ai_then_human'));
  UPDATE task_content.rubric_item SET scored_by = 'human' WHERE ai_enabled = 0;

  -- §2.6 U-25
  ALTER TABLE identity_org.[user] ADD locked_until DATETIME2(3) NULL;

  -- §2.7 U-27
  ALTER TABLE identity_org.[user]
    ADD must_change_password BIT NOT NULL CONSTRAINT df_user_mcp DEFAULT 0;

  COMMIT TRANSACTION;
  PRINT 'U-21~U-26 迁移成功';
END TRY
BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
  PRINT '迁移失败，已回滚：' + ERROR_MESSAGE();
  THROW;
END CATCH;
GO
*/


-- #############################################################################
-- §3 回滚（仅当必须退回旧结构）
-- #############################################################################

/*
-- MySQL
ALTER TABLE classroom.trial_session
  DROP CHECK ck_sess_mode_topic,
  DROP CHECK ck_sess_mode_sq,
  DROP CHECK ck_sess_mode_sc,
  DROP FOREIGN KEY fk_sess_sq,
  DROP KEY idx_sess_sq,
  DROP COLUMN structured_q_id;

ALTER TABLE platform.export_task
  DROP CHECK ck_et_error, DROP COLUMN error;

ALTER TABLE task_content.rubric
  DROP CHECK ck_rubric_bands, DROP COLUMN grade_bands;

ALTER TABLE task_content.rubric_item
  DROP COLUMN scored_by;

ALTER TABLE identity_org.`user`
  DROP COLUMN locked_until;

ALTER TABLE identity_org.`user`
  DROP COLUMN must_change_password;
*/


-- #############################################################################
-- §4 迁移后校验（三条都要过）
-- #############################################################################

-- §4.1 列数应为 6 个新增列全部存在
SELECT 'structured_q_id' AS col, COUNT(*) AS c FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='classroom' AND TABLE_NAME='trial_session' AND COLUMN_NAME='structured_q_id'
UNION ALL SELECT 'export_task.error', COUNT(*) FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='platform' AND TABLE_NAME='export_task' AND COLUMN_NAME='error'
UNION ALL SELECT 'rubric.grade_bands', COUNT(*) FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='task_content' AND TABLE_NAME='rubric' AND COLUMN_NAME='grade_bands'
UNION ALL SELECT 'rubric_item.scored_by', COUNT(*) FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='task_content' AND TABLE_NAME='rubric_item' AND COLUMN_NAME='scored_by'
UNION ALL SELECT 'user.locked_until', COUNT(*) FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='identity_org' AND TABLE_NAME='user' AND COLUMN_NAME='locked_until'
UNION ALL SELECT 'user.must_change_password', COUNT(*) FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA='identity_org' AND TABLE_NAME='user' AND COLUMN_NAME='must_change_password';
-- 期望：6 行，c 全部 = 1

-- §4.2 外键数应从 68 增至 69
SELECT COUNT(*) AS fk_total FROM information_schema.TABLE_CONSTRAINTS
 WHERE CONSTRAINT_SCHEMA IN ('identity_org','task_content','classroom','media','evaluation','growth_cert','platform')
   AND CONSTRAINT_TYPE = 'FOREIGN KEY';
-- 期望：69

-- §4.3 scored_by 存量回填正确（ai_enabled=0 的行应为 human）
SELECT scored_by, ai_enabled, COUNT(*) FROM task_content.rubric_item
GROUP BY scored_by, ai_enabled;
-- 期望：没有 (scored_by='ai', ai_enabled=0) 的行


-- #############################################################################
-- §5 应用层改动清单（DDL 之外必须同步）
-- #############################################################################
-- 1. POST /sessions：mode=structured 时校验 structured_q_id 存在，写入该列；
--    响应 topic_snapshot 对结构化面试应返回题目快照（q_text 而非 title/content_text）
-- 2. 报告生成：structured 模式取 structured_question.q_text 作为 LLM 输入
-- 3. 等级判定：读 rubric.grade_bands，为 NULL 时回退默认 {90,80,60}（11 §4.4）
-- 4. 批阅打分：按 rubric_item.scored_by 决定该细则是否允许 AI 给分
-- 5. 登录：失败 5 次写 user.locked_until=now+15min；登录前检查 locked_until > now()
--    原来的 Redis 计数键 ai_teach:{env}:identity:login_fail:{phone} 可保留作辅助，但判定以 DB 为准
-- 6. 导出：失败时写 export_task.error，GET /admin/exports/{id} 直接返回该字段
-- 7. 回归用例：08 TC-029（60 人满座）、TC-050（报告 SLA）不受影响；
--    新增用例建议：结构化面试开课→出报告→报告含题目快照
