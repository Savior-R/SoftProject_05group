-- =============================================================================
-- 迁移 U-01：修正 teacher_review 的「有效主批」判定口径
-- =============================================================================
-- 依据：11-实现契约 §10.1；04-LLD V3.0 §3.4；05-数据库设计 V3.0 §12 T6
--
-- 问题：生成列 active_primary_report_id 原条件为 (is_primary=1 AND status <> 'returned')，
--       与 04-LLD 的 (is_primary=1 AND status = 'reviewed') 不等价。
--       差别在 pending 状态：教师已认领主批但未打分时，旧口径视为有效主批，
--       会让 final_score 取一个尚不存在的教师分 → 学生端「最终成绩」显示为 NULL。
--
-- 本脚本：把条件改为 status = 'reviewed'，并重建唯一约束。
-- 前置：两份 DDL 已执行过（52 表已建）。
-- 执行：先跑 §0 预检 → §1 备份 → §2 迁移 → §3 校验。
-- 回滚：§4。
--
-- 破坏性说明：
--   MySQL  —— ALTER 会重建表（MODIFY COLUMN 生成列），52 表中仅此 1 张，量表小。
--   SQL Server —— 生成列不能直接改表达式，必须 DROP 列 → ADD 列 → 重建过滤索引。
--                 其间该唯一约束暂时失效，需在维护窗口执行。
-- =============================================================================


-- =============================================================================
-- §0 预检（两种方言各跑一次，必须在迁移前确认）
-- =============================================================================

-- §0.1 【MySQL】确认当前生成列定义（应看到 status <> 'returned'）
SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, GENERATION_EXPRESSION
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'evaluation'
  AND TABLE_NAME   = 'teacher_review'
  AND COLUMN_NAME  = 'active_primary_report_id';

-- §0.2 【MySQL】冲突数据检查 —— 必须返回 0 行，否则迁移后唯一索引创建失败
--         （同一报告已有多条 status='reviewed' 且 is_primary=1 的记录）
SELECT report_id, COUNT(*) AS cnt
FROM evaluation.teacher_review
WHERE is_primary = 1 AND status = 'reviewed'
GROUP BY report_id
HAVING COUNT(*) > 1;

-- §0.3 【MySQL】影响面统计 —— 记录迁移前后的行数，供 §3 校验
SELECT
  SUM(is_primary = 1)                             AS primary_total,
  SUM(is_primary = 1 AND status = 'returned')     AS primary_returned,
  SUM(is_primary = 1 AND status = 'pending')      AS primary_pending,
  SUM(is_primary = 1 AND status = 'reviewed')     AS primary_reviewed
FROM evaluation.teacher_review;

-- §0.4 【SQL Server】确认当前生成列定义
SELECT OBJECT_SCHEMA_NAME(object_id) AS sch, OBJECT_NAME(object_id) AS tbl,
       name, definition, is_persisted
FROM sys.computed_columns
WHERE OBJECT_SCHEMA_NAME(object_id) = 'evaluation'
  AND OBJECT_NAME(object_id) = 'teacher_review';

-- §0.5 【SQL Server】确认过滤索引存在及其过滤条件
SELECT name, has_filter, filter_definition
FROM sys.indexes
WHERE object_id = OBJECT_ID(N'evaluation.teacher_review')
  AND name = 'uk_tr_active_primary';

-- §0.6 【SQL Server】冲突数据检查 —— 必须返回 0 行
SELECT report_id, COUNT(*) AS cnt
FROM evaluation.teacher_review
WHERE is_primary = 1 AND [status] = 'reviewed'
GROUP BY report_id
HAVING COUNT(*) > 1;


-- =============================================================================
-- §1 备份（迁移前必做）
-- =============================================================================

-- 【MySQL】结构与数据全备份（服务端执行，路径按实际改）
--   mysqldump -h127.0.0.1 -P3307 -uroot --single-transaction \
--     --databases evaluation > backup_evaluation_before_u01.sql

-- 【SQL Server】
--   BACKUP DATABASE ai_teach TO DISK = N'D:\backup\ai_teach_before_u01.bak'
--   WITH INIT, COMPRESSION, CHECKSUM, STATS = 10;
--   或仅备该表：
--   SELECT * INTO evaluation.teacher_review_bak_u01 FROM evaluation.teacher_review;


-- =============================================================================
-- §2 迁移
-- =============================================================================

-- -----------------------------------------------------------------------------
-- §2.1 【MySQL】
-- -----------------------------------------------------------------------------
-- 注意：生成列无法单独 ALTER 表达式，需先 DROP 索引 → MODIFY COLUMN → 重建索引。
--       MODIFY 时其余属性（NULL-able、COMMENT）须一并写出，否则会被重置。

ALTER TABLE evaluation.teacher_review
  DROP INDEX uk_tr_active_primary;

ALTER TABLE evaluation.teacher_review
  MODIFY COLUMN active_primary_report_id CHAR(36)
    GENERATED ALWAYS AS (
      CASE WHEN is_primary = 1 AND status = 'reviewed' THEN report_id ELSE NULL END
    ) STORED
    COMMENT '有效主批唯一约束辅助列（V3.0：status=reviewed）';

ALTER TABLE evaluation.teacher_review
  ADD UNIQUE KEY uk_tr_active_primary (active_primary_report_id);

-- 若 §0.2 返回了冲突数据，上面 ADD UNIQUE KEY 会报 Duplicate entry。
-- 处置：先按 11 §3.4 保留 reviewed_at 最新的一条，其余置 is_primary=0，再重建索引。
--   UPDATE evaluation.teacher_review tr
--     JOIN (SELECT report_id, MAX(reviewed_at) AS keep_at
--             FROM evaluation.teacher_review
--            WHERE is_primary=1 AND status='reviewed'
--            GROUP BY report_id HAVING COUNT(*)>1) k
--       ON tr.report_id = k.report_id
--    SET tr.is_primary = 0
--    WHERE tr.is_primary = 1 AND tr.status = 'reviewed'
--      AND (tr.reviewed_at IS NULL OR tr.reviewed_at < k.keep_at);


-- -----------------------------------------------------------------------------
-- §2.2 【SQL Server】
-- -----------------------------------------------------------------------------
-- 生成列不可 ALTER，必须 DROP 重建。过滤索引随列一起 DROP。
-- 整个批次放在显式事务里，失败即回滚。

SET XACT_ABORT ON;
BEGIN TRY
  BEGIN TRANSACTION;

  -- 1) 删过滤索引（依赖生成列，必须先删）
  IF EXISTS (SELECT 1 FROM sys.indexes
             WHERE name = 'uk_tr_active_primary'
               AND object_id = OBJECT_ID(N'evaluation.teacher_review'))
    DROP INDEX uk_tr_active_primary ON evaluation.teacher_review;

  -- 2) 删生成列
  IF EXISTS (SELECT 1 FROM sys.computed_columns
             WHERE name = 'active_primary_report_id'
               AND object_id = OBJECT_ID(N'evaluation.teacher_review'))
    ALTER TABLE evaluation.teacher_review DROP COLUMN active_primary_report_id;

  -- 3) 重建生成列（条件改为 status = 'reviewed'）
  ALTER TABLE evaluation.teacher_review
    ADD active_primary_report_id AS (
      CASE WHEN is_primary = 1 AND [status] = 'reviewed' THEN report_id END
    ) PERSISTED;

  -- 4) 重建过滤唯一索引
  CREATE UNIQUE INDEX uk_tr_active_primary
    ON evaluation.teacher_review(active_primary_report_id)
    WHERE active_primary_report_id IS NOT NULL;

  COMMIT TRANSACTION;
  PRINT 'U-01 迁移成功';
END TRY
BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
  PRINT 'U-01 迁移失败，已回滚：' + ERROR_MESSAGE();
  THROW;
END CATCH;
GO


-- =============================================================================
-- §3 校验（迁移后必跑，三条都要过）
-- =============================================================================

-- §3.1 【MySQL】生成列表达式应为 status = 'reviewed'
SELECT COLUMN_NAME, GENERATION_EXPRESSION
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='evaluation' AND TABLE_NAME='teacher_review'
  AND COLUMN_NAME='active_primary_report_id';
-- 期望：GENERATION_EXPRESSION 含 "status = 'reviewed'"，不含 "<> 'returned'"

-- §3.2 【MySQL】唯一索引仍在
SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA='evaluation' AND TABLE_NAME='teacher_review'
  AND INDEX_NAME='uk_tr_active_primary';
-- 期望：NON_UNIQUE = 0

-- §3.3 【MySQL】行为验证 —— pending 不应占位，reviewed 应占位
--   取一条 is_primary=1 且 status='pending' 的记录，其 active_primary_report_id 应为 NULL
SELECT review_id, report_id, is_primary, status, active_primary_report_id
FROM evaluation.teacher_review
WHERE is_primary = 1
ORDER BY FIELD(status,'reviewed','pending','returned'), reviewed_at DESC
LIMIT 10;
-- 期望：status='pending' 或 'returned' 的行 → active_primary_report_id IS NULL
--       status='reviewed' 的行 → active_primary_report_id = report_id

-- §3.4 【SQL Server】同上三项（用 sys.computed_columns / sys.indexes 查询，见 §0.4/§0.5）


-- =============================================================================
-- §4 回滚（仅当必须退回旧口径时使用）
-- =============================================================================

-- §4.1 【MySQL】
-- ALTER TABLE evaluation.teacher_review DROP INDEX uk_tr_active_primary;
-- ALTER TABLE evaluation.teacher_review
--   MODIFY COLUMN active_primary_report_id CHAR(36)
--     GENERATED ALWAYS AS (
--       CASE WHEN is_primary = 1 AND status <> 'returned' THEN report_id ELSE NULL END
--     ) STORED
--     COMMENT '有效主批唯一约束辅助列';
-- ALTER TABLE evaluation.teacher_review
--   ADD UNIQUE KEY uk_tr_active_primary (active_primary_report_id);

-- §4.2 【SQL Server】同 §2.2 结构，把 CASE 条件换回 [status] <> 'returned'


-- =============================================================================
-- §5 应用层改动清单（DDL 之外必须同步的部分）
-- =============================================================================
-- 1. evaluation-service 计算 final_score / final_score_source 时：
--      有效主批 = is_primary=1 AND status='reviewed'      ← 不是 <> 'returned'
-- 2. report 状态机：只有存在有效主批才置 teacher_reviewed（11 §3.3 第 5 条）
-- 3. POST /teacher-reviews 提交时若 is_primary=1 但 status='pending'：
--      不写 teacher_score、不置 report.teacher_reviewed、不改 final_score
-- 4. 批阅工作台 UI：pending 状态下显示「已认领，未打分」，不显示「主批已生效」
-- 5. 回归用例：08 TC-070（第二个有效主批）、TC-073（退回释放资格）、TC-074（事务一致性）
-- 6. 新增用例建议：教师设主批 → 不提交分数 → 查学生端最终成绩，应为 AI 分而非空
