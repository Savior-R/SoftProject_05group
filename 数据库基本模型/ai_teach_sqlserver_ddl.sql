/* ============================================================================
   师范专业 AI 试讲台系统 — SQL Server 2025 物理库脚本
   唯一事实源：本文件（ai_teach_sqlserver_ddl.sql）
   由 ai_teach_mysql8_ddl.sql 机械转换生成（build/mysql2sqlserver.py），禁止手工修改；
   文档（数据项清单 / 数据库设计文档）由 build/gen.py 读取 build/_ss_model.json 派生。
   规模：52 表 · 536 字段 · 69 外键 · 100 二级索引 · 2 分区表
   ----------------------------------------------------------------------------
   【方言映射】MySQL 8 → SQL Server 2025
     CHAR(36)  → UNIQUEIDENTIFIER      VARCHAR(n) → NVARCHAR(n)
     TEXT      → NVARCHAR(MAX)         JSON       → NVARCHAR(MAX) + ISJSON CHECK
     ENUM(...) → NVARCHAR(最长值) + CHECK IN (...)
     TINYINT(1)→ BIT                   DATETIME(3)→ DATETIME2(3)
     GENERATED STORED → AS (...) PERSISTED
     可空生成列 UNIQUE → 过滤唯一索引 WHERE <列> IS NOT NULL
     ON DELETE RESTRICT → NO ACTION    ON UPDATE CASCADE → 省略（UUID 主键不更新）
     RANGE COLUMNS 分区 → PARTITION FUNCTION(RANGE RIGHT) + PARTITION SCHEME
     7 个 database → 7 个 schema（本脚本建在单一数据库内）
   ----------------------------------------------------------------------------
   【必须保留的方言偏差】
     1. 枚举由 NVARCHAR + CHECK 实现，不再是列类型；枚举约束名 ck_<缩写>_<列>。
     2. 生成列 + 过滤唯一索引替代 MySQL 的"生成列唯一键"：SQL Server 唯一索引
        视 NULL 相等，不加 WHERE 只能存在一行"已删除"记录。
     3. 外键 ON DELETE 由 RESTRICT 统一改写为 NO ACTION（同义）。
     4. MySQL 的 ON UPDATE CASCADE 全部省略：主键为 UUID，永不更新。
     5. 为兼容 SQL Server 1785（多路径级联），下列外键降级为 NO ACTION：
        - fk_tr_session：CASCADE → NO ACTION：多路径级联的唯一可切除短路边，去掉后父表删除仍能经其他路径清理（冲突 14 → 8 组）
        - fk_sg_issue：SET NULL → NO ACTION：多路径级联的唯一可切除短路边，去掉后父表删除仍能经其他路径清理（冲突 8 → 1 组）
        - fk_cg_leader：SET NULL → NO ACTION：多路径级联的唯一可切除短路边，去掉后父表删除仍能经其他路径清理（冲突 1 → 0 组）
     6. 分区表索引追加分区列 created_at 并落到分区方案 ps_month，保证索引与分区对齐。
   ----------------------------------------------------------------------------
   幂等：全部对象 IF NOT EXISTS 包裹，可重复执行。
   ============================================================================ */

IF DB_ID(N'ai_teach') IS NULL CREATE DATABASE [ai_teach];
GO
USE [ai_teach];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* 0. Schema 初始化（等价 MySQL 的 7 个 database） */
IF SCHEMA_ID(N'identity_org') IS NULL EXEC(N'CREATE SCHEMA identity_org AUTHORIZATION dbo;');
IF SCHEMA_ID(N'task_content') IS NULL EXEC(N'CREATE SCHEMA task_content AUTHORIZATION dbo;');
IF SCHEMA_ID(N'classroom') IS NULL EXEC(N'CREATE SCHEMA classroom AUTHORIZATION dbo;');
IF SCHEMA_ID(N'media') IS NULL EXEC(N'CREATE SCHEMA media AUTHORIZATION dbo;');
IF SCHEMA_ID(N'evaluation') IS NULL EXEC(N'CREATE SCHEMA evaluation AUTHORIZATION dbo;');
IF SCHEMA_ID(N'growth_cert') IS NULL EXEC(N'CREATE SCHEMA growth_cert AUTHORIZATION dbo;');
IF SCHEMA_ID(N'platform') IS NULL EXEC(N'CREATE SCHEMA platform AUTHORIZATION dbo;');
GO

/* 1. 分区函数与方案（仅 classroom.behavior_event / live_message 使用）
      MySQL: PARTITION BY RANGE COLUMNS(created_at) VALUES LESS THAN (...)
      SQL Server: RANGE RIGHT，边界值归属右侧分区，语义等价；超末期落最大分区。 */
IF NOT EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'pf_month')
BEGIN
    DECLARE @vals NVARCHAR(MAX) = N'';
    SET @vals += N', ''2026-11-01''';
    SET @vals += N', ''2026-12-01''';
    SET @vals += N', ''2027-01-01''';
    SET @vals += N', ''2027-02-01''';
    SET @vals += N', ''2027-03-01''';
    SET @vals += N', ''2027-04-01''';
    SET @vals = STUFF(@vals, 1, 2, N'');
    EXEC(N'CREATE PARTITION FUNCTION pf_month (DATETIME2(3)) AS RANGE RIGHT FOR VALUES (' + @vals + N');');
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'ps_month')
    EXEC(N'CREATE PARTITION SCHEME ps_month AS PARTITION pf_month ALL TO ([PRIMARY]);');
GO


/* ==========================================================================
   Schema identity_org（12 表）
   ========================================================================== */

/* user：A1 用户账号：全平台唯一身份主体 */
IF OBJECT_ID(N'identity_org.[user]', N'U') IS NULL
CREATE TABLE identity_org.[user] (
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 用户ID，UUID v4，全局唯一
    real_name                NVARCHAR(50)       NOT NULL,   -- 姓名，2-20 字符，中文/字母
    role                     NVARCHAR(9)        NOT NULL,   -- 角色：student 师范生/teacher 指导教师/org_admin 教研管理员/sys_admin 系统管理员  [枚举: student/teacher/org_admin/sys_admin]
    permission_codes         NVARCHAR(MAX)      NOT NULL,   -- 权限码数组，由 role 展开，如 task:publish / review:batch
    phone                    NVARCHAR(11)       NOT NULL,   -- 手机号，^1[3-9]\d{9}$，登录凭据
    password_hash            NVARCHAR(60)       NOT NULL,   -- bcrypt 摘要（cost=12），禁止明文
    avatar_url               NVARCHAR(512)      NULL,   -- 头像对象存储 URL，jpg/png ≤2MB
    [status]                 NVARCHAR(8)        NOT NULL  CONSTRAINT df_user_status DEFAULT 'active',   -- 账号状态：active 正常/disabled 停用/locked 锁定  [枚举: active/disabled/locked]
    locked_until             DATETIME2(3)       NULL,   -- 锁定截止时间（UTC）；V1.1 新增，登录失败 5 次写入 now+15min，到期自动解锁，跨重启有效
    must_change_password     BIT                NOT NULL  CONSTRAINT df_user_must_change_passwo DEFAULT 0,   -- 是否强制改密：1 是。V1.1 新增；管理员创建账号或重置密码后置 1，首次登录成功后置 0
    last_login_at            DATETIME2(3)       NULL,   -- 最近登录时间，保留 90 天
    school_id                UNIQUEIDENTIFIER   NULL,   -- 所属学校/院系ID，单校部署预留，V2 多校启用
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_user_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_user_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    active_phone             AS (CASE WHEN deleted_at IS NULL THEN phone ELSE NULL END) PERSISTED,   -- 生成列，只读；软删唯一约束载体：有效行=phone，已删行=NULL；禁止直接读写
    CONSTRAINT pk_user PRIMARY KEY (user_id),
    CONSTRAINT ck_user_phone CHECK (phone LIKE '1[3-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'),
    CONSTRAINT ck_user_realname CHECK (LEN(real_name) BETWEEN 2 AND 20),
    CONSTRAINT ck_user_role CHECK (role IN ('student', 'teacher', 'org_admin', 'sys_admin')),
    CONSTRAINT ck_user_status CHECK ([status] IN ('active', 'disabled', 'locked'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_user_phone' AND object_id = OBJECT_ID(N'identity_org.[user]'))
    CREATE UNIQUE INDEX uk_user_phone ON identity_org.[user](active_phone) WHERE active_phone IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_user_role_status' AND object_id = OBJECT_ID(N'identity_org.[user]'))
    CREATE INDEX idx_user_role_status ON identity_org.[user](role, [status]);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_user_school' AND object_id = OBJECT_ID(N'identity_org.[user]'))
    CREATE INDEX idx_user_school ON identity_org.[user](school_id);
GO

/* dim_grade：年级/届次维度：排行榜 scope=grade 的真实范围实体 */
IF OBJECT_ID(N'identity_org.dim_grade', N'U') IS NULL
CREATE TABLE identity_org.dim_grade (
    grade_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 年级/届次维度ID，UUID v4
    grade_code               NVARCHAR(20)       NOT NULL,   -- 届次代码，如 2023
    grade_name               NVARCHAR(50)       NOT NULL,   -- 展示名称，如 2023级
    cohort_year              SMALLINT           NOT NULL,   -- 入学年份/届次
    sort_no                  SMALLINT           NOT NULL  CONSTRAINT df_dim_grade_sort_no DEFAULT 0,   -- 排序号
    [status]                 NVARCHAR(8)        NOT NULL  CONSTRAINT df_dim_grade_status DEFAULT 'enabled',   -- 启用状态  [枚举: enabled/disabled]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_dim_grade_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_dim_grade_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_dim_grade PRIMARY KEY (grade_id),
    CONSTRAINT ck_dim_grade_year CHECK (cohort_year BETWEEN 2000 AND 2100),
    CONSTRAINT ck_dim_grade_status CHECK ([status] IN ('enabled', 'disabled'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_dim_grade_code' AND object_id = OBJECT_ID(N'identity_org.dim_grade'))
    CREATE UNIQUE INDEX uk_dim_grade_code ON identity_org.dim_grade(grade_code);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_dim_grade_year' AND object_id = OBJECT_ID(N'identity_org.dim_grade'))
    CREATE UNIQUE INDEX uk_dim_grade_year ON identity_org.dim_grade(cohort_year);
GO

/* student_profile：A2 师范生档案：学生特有属性，与 user 1:1 */
IF OBJECT_ID(N'identity_org.student_profile', N'U') IS NULL
CREATE TABLE identity_org.student_profile (
    profile_id               UNIQUEIDENTIFIER   NOT NULL,   -- 档案ID，UUID v4
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 用户ID，→identity_org.user
    student_no               NVARCHAR(30)       NOT NULL,   -- 学号，校内唯一
    major_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 专业ID，→identity_org.major
    grade                    NVARCHAR(9)        NOT NULL,   -- 年级：freshman 大一/sophomore 大二/junior 大三/senior 大四/graduate 研究生  [枚举: freshman/sophomore/junior/senior/graduate]
    class_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 班级ID，→identity_org.class
    subject_id               UNIQUEIDENTIFIER   NOT NULL,   -- 学科方向ID，→identity_org.subject
    stage_pref               NVARCHAR(11)       NOT NULL,   -- 目标学段：preschool 幼教/primary 小学/junior_high 初中/senior_high 高中/vocational 中职  [枚举: preschool/primary/junior_high/senior_high/vocational]
    target_cert              NVARCHAR(12)       NULL,   -- 目标资格证：幼儿园/小学/初级中学/高级中学/中职/none 无  [枚举: kindergarten/primary/junior_high/senior_high/vocational/none]
    practice_school          NVARCHAR(100)      NULL,   -- 实习学校，≤50 字符；数据项清单标记待确认，V2 启用
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sp_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sp_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_student_profile PRIMARY KEY (profile_id),
    CONSTRAINT ck_sp_grade CHECK (grade IN ('freshman', 'sophomore', 'junior', 'senior', 'graduate')),
    CONSTRAINT ck_sp_stage_pref CHECK (stage_pref IN ('preschool', 'primary', 'junior_high', 'senior_high', 'vocational')),
    CONSTRAINT ck_sp_target_cert CHECK (target_cert IS NULL OR target_cert IN ('kindergarten', 'primary', 'junior_high', 'senior_high', 'vocational', 'none'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_sp_user' AND object_id = OBJECT_ID(N'identity_org.student_profile'))
    CREATE UNIQUE INDEX uk_sp_user ON identity_org.student_profile(user_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_sp_student_no' AND object_id = OBJECT_ID(N'identity_org.student_profile'))
    CREATE UNIQUE INDEX uk_sp_student_no ON identity_org.student_profile(student_no);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sp_class' AND object_id = OBJECT_ID(N'identity_org.student_profile'))
    CREATE INDEX idx_sp_class ON identity_org.student_profile(class_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sp_major' AND object_id = OBJECT_ID(N'identity_org.student_profile'))
    CREATE INDEX idx_sp_major ON identity_org.student_profile(major_id);
GO

/* teacher_profile：A3 教师档案：教师特有属性，与 user 1:1 */
IF OBJECT_ID(N'identity_org.teacher_profile', N'U') IS NULL
CREATE TABLE identity_org.teacher_profile (
    teacher_id               UNIQUEIDENTIFIER   NOT NULL,   -- 教师档案ID，UUID v4
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 用户ID，→identity_org.user
    title                    NVARCHAR(19)       NULL,   -- 职称：助教/讲师/副教授/教授/教研员/校外导师  [枚举: assistant/lecturer/associate_professor/professor/researcher/external_mentor]
    is_examiner              BIT                NOT NULL  CONSTRAINT df_tp_is_examiner DEFAULT 0,   -- 考官资格：1 具备模拟考核评分资格
    review_quota             SMALLINT           NULL,   -- 待批上限，1-200 默认 50；数据项清单标记待确认，V2 启用
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_tp_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_tp_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_teacher_profile PRIMARY KEY (teacher_id),
    CONSTRAINT ck_tp_title CHECK (title IS NULL OR title IN ('assistant', 'lecturer', 'associate_professor', 'professor', 'researcher', 'external_mentor'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_tp_user' AND object_id = OBJECT_ID(N'identity_org.teacher_profile'))
    CREATE UNIQUE INDEX uk_tp_user ON identity_org.teacher_profile(user_id);
GO

/* major：A4 专业：院系下的培养单位 */
IF OBJECT_ID(N'identity_org.major', N'U') IS NULL
CREATE TABLE identity_org.major (
    major_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 专业ID，UUID v4
    major_name               NVARCHAR(50)       NOT NULL,   -- 专业名称，如「汉语言文学（师范）」，全局唯一
    school_id                UNIQUEIDENTIFIER   NULL,   -- 所属院系ID；院系实体未在 43 实体中定义，暂为逻辑引用
    [status]                 NVARCHAR(8)        NOT NULL  CONSTRAINT df_major_status DEFAULT 'enabled',   -- 状态：enabled 启用/disabled 停用  [枚举: enabled/disabled]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_major_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_major_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    active_major_name        AS (CASE WHEN deleted_at IS NULL THEN major_name ELSE NULL END) PERSISTED,   -- 生成列，只读；软删唯一约束载体，禁止直接读写
    CONSTRAINT pk_major PRIMARY KEY (major_id),
    CONSTRAINT ck_major_status CHECK ([status] IN ('enabled', 'disabled'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_major_name' AND object_id = OBJECT_ID(N'identity_org.major'))
    CREATE UNIQUE INDEX uk_major_name ON identity_org.major(active_major_name) WHERE active_major_name IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_major_school' AND object_id = OBJECT_ID(N'identity_org.major'))
    CREATE INDEX idx_major_school ON identity_org.major(school_id);
GO

/* subject：A5 学科：可试讲学科方向与评测策略入口 */
IF OBJECT_ID(N'identity_org.subject', N'U') IS NULL
CREATE TABLE identity_org.subject (
    subject_id               UNIQUEIDENTIFIER   NOT NULL,   -- 学科ID，UUID v4
    subject_name             NVARCHAR(30)       NOT NULL,   -- 学科名称：语文/数学/英语/物理/化学/生物/政治/历史/地理/思政/音乐/体育/美术/信息技术/幼教/其他
    stage_range              NVARCHAR(MAX)      NOT NULL,   -- 适用学段数组，取值 preschool/primary/junior_high/senior_high/vocational 子集
    ai_prompt_key            NVARCHAR(50)       NULL,   -- 学科评测提示词键，映射 LLM 策略模板
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_subject_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_subject_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    active_subject_name      AS (CASE WHEN deleted_at IS NULL THEN subject_name ELSE NULL END) PERSISTED,   -- 生成列，只读；软删唯一约束载体，禁止直接读写
    CONSTRAINT pk_subject PRIMARY KEY (subject_id),
    CONSTRAINT ck_subject_stage CHECK (ISJSON(stage_range) = 1 AND (stage_range <> '[]'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_subject_name' AND object_id = OBJECT_ID(N'identity_org.subject'))
    CREATE UNIQUE INDEX uk_subject_name ON identity_org.subject(active_subject_name) WHERE active_subject_name IS NOT NULL;
GO

/* class：A6 班级：教学组织与数据可见范围边界 */
IF OBJECT_ID(N'identity_org.[class]', N'U') IS NULL
CREATE TABLE identity_org.[class] (
    class_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 班级ID，UUID v4
    class_name               NVARCHAR(50)       NOT NULL,   -- 班级名称，如「2023级汉语言文学1班」
    student_count            SMALLINT           NOT NULL  CONSTRAINT df_class_student_count DEFAULT 0,   -- 学生数，0-200，由 student_profile 聚合刷新的冗余值
    enroll_year              SMALLINT           NOT NULL,   -- 入学年份，2000-当前年
    [status]                 NVARCHAR(9)        NOT NULL  CONSTRAINT df_class_status DEFAULT 'active',   -- 状态：active 在读/graduated 已毕业/archived 归档  [枚举: active/graduated/archived]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_class_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_class_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_class PRIMARY KEY (class_id),
    CONSTRAINT ck_class_student_count CHECK (student_count BETWEEN 0 AND 200),
    CONSTRAINT ck_class_enroll_year CHECK (enroll_year BETWEEN 2000 AND 2100),
    CONSTRAINT ck_class_status CHECK ([status] IN ('active', 'graduated', 'archived'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_class_enroll_status' AND object_id = OBJECT_ID(N'identity_org.[class]'))
    CREATE INDEX idx_class_enroll_status ON identity_org.[class](enroll_year, [status]);
GO

/* class_group：A7 训练小组：班级内实训分组（沿用 md 实体名 group） */
IF OBJECT_ID(N'identity_org.class_group', N'U') IS NULL
CREATE TABLE identity_org.class_group (
    group_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 小组ID，UUID v4；物理表名 class_group 规避 SQL 保留字 GROUP
    class_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 所属班级ID，→identity_org.class
    group_name               NVARCHAR(30)       NOT NULL,   -- 组名，如「第3实训组」
    leader_id                UNIQUEIDENTIFIER   NULL,   -- 组长档案ID，→student_profile，须为本组成员
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_cg_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_cg_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_class_group PRIMARY KEY (group_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_cg_class' AND object_id = OBJECT_ID(N'identity_org.class_group'))
    CREATE INDEX idx_cg_class ON identity_org.class_group(class_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_cg_leader' AND object_id = OBJECT_ID(N'identity_org.class_group'))
    CREATE INDEX idx_cg_leader ON identity_org.class_group(leader_id);
GO

/* consent_record：R1 采集授权记录：肖像/声音使用的合规凭据，不可删除仅可撤回 */
IF OBJECT_ID(N'identity_org.consent_record', N'U') IS NULL
CREATE TABLE identity_org.consent_record (
    consent_id               UNIQUEIDENTIFIER   NOT NULL,   -- 授权记录ID，UUID v4
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 授权主体，→identity_org.user
    consent_text_version     NVARCHAR(20)       NOT NULL,   -- 授权文本版本号，如 v1.0-2026-10
    consent_scope            NVARCHAR(MAX)      NOT NULL,   -- 授权范围数组：portrait 人像/voice 声音/analysis AI 分析/archive 存档
    signed_at                DATETIME2(3)       NOT NULL,   -- 签署时间（UTC），开课时须校验存在且未撤回
    revoked_at               DATETIME2(3)       NULL,   -- 撤回时间，NULL=未撤回
    signed_ip                NVARCHAR(45)       NULL,   -- 签署 IP，支持 IPv6
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_consent_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_consent_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_consent_record PRIMARY KEY (consent_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_consent_user' AND object_id = OBJECT_ID(N'identity_org.consent_record'))
    CREATE INDEX idx_consent_user ON identity_org.consent_record(user_id, signed_at);
GO

/* class_teacher：R2 班级-教师关系：承载数组型外键，relation_type 区分指导教师与管理班级 */
IF OBJECT_ID(N'identity_org.class_teacher', N'U') IS NULL
CREATE TABLE identity_org.class_teacher (
    class_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 班级ID，→identity_org.class
    teacher_id               UNIQUEIDENTIFIER   NOT NULL,   -- 教师档案ID，→identity_org.teacher_profile
    relation_type            NVARCHAR(7)        NOT NULL,   -- 关系类型：advisor 指导教师（对应 A6.teacher_ids）/manager 管理班级（对应 A3.managed_class_ids）  [枚举: advisor/manager]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ct_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    CONSTRAINT pk_class_teacher PRIMARY KEY (class_id, teacher_id, relation_type),
    CONSTRAINT ck_ct_relation CHECK (relation_type IN ('advisor', 'manager'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_ct_teacher' AND object_id = OBJECT_ID(N'identity_org.class_teacher'))
    CREATE INDEX idx_ct_teacher ON identity_org.class_teacher(teacher_id, relation_type);
GO

/* teacher_subject：R3 教师-可评学科关系：承载 A3.subject_ids，1-5 条 */
IF OBJECT_ID(N'identity_org.teacher_subject', N'U') IS NULL
CREATE TABLE identity_org.teacher_subject (
    teacher_id               UNIQUEIDENTIFIER   NOT NULL,   -- 教师档案ID，→identity_org.teacher_profile
    subject_id               UNIQUEIDENTIFIER   NOT NULL,   -- 学科ID，→identity_org.subject
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ts_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    CONSTRAINT pk_teacher_subject PRIMARY KEY (teacher_id, subject_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_ts_subject' AND object_id = OBJECT_ID(N'identity_org.teacher_subject'))
    CREATE INDEX idx_ts_subject ON identity_org.teacher_subject(subject_id);
GO

/* class_group_member：R4 小组成员关系：承载 A7.member_ids，2-10 条 */
IF OBJECT_ID(N'identity_org.class_group_member', N'U') IS NULL
CREATE TABLE identity_org.class_group_member (
    group_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 小组ID，→identity_org.class_group
    profile_id               UNIQUEIDENTIFIER   NOT NULL,   -- 学生档案ID，→identity_org.student_profile
    is_leader                BIT                NOT NULL  CONSTRAINT df_cgm_is_leader DEFAULT 0,   -- 是否组长：1 是
    joined_at                DATETIME2(3)       NOT NULL  CONSTRAINT df_cgm_joined_at DEFAULT SYSUTCDATETIME(),   -- 入组时间，用于组员变动留痕
    CONSTRAINT pk_class_group_member PRIMARY KEY (group_id, profile_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_cgm_profile' AND object_id = OBJECT_ID(N'identity_org.class_group_member'))
    CREATE INDEX idx_cgm_profile ON identity_org.class_group_member(profile_id);
GO


/* ==========================================================================
   Schema task_content（9 表）
   ========================================================================== */

/* rubric：B2 评分标准：版本化口径，报告按 rubric_id+version 追溯 */
IF OBJECT_ID(N'task_content.rubric', N'U') IS NULL
CREATE TABLE task_content.rubric (
    rubric_id                UNIQUEIDENTIFIER   NOT NULL,   -- 评分标准ID，UUID v4；每个版本一行
    root_rubric_id           UNIQUEIDENTIFIER   NOT NULL,   -- 版本链根ID（v1 的 rubric_id），同一标准的所有版本共享
    rubric_name              NVARCHAR(50)       NOT NULL,   -- 名称，如「教资面试通用评分表」
    scope                    NVARCHAR(7)        NOT NULL,   -- 适用范围：system 系统预置/school 校级/teacher 教师自定义  [枚举: system/school/teacher]
    subject_id               UNIQUEIDENTIFIER   NULL,   -- 适用学科ID，→identity_org.subject，NULL=通用
    stage                    NVARCHAR(11)       NULL,   -- 适用学段，NULL=通用  [枚举: preschool/primary/junior_high/senior_high/vocational]
    total_score              DECIMAL(5,2)       NOT NULL  CONSTRAINT df_rubric_total_score DEFAULT 100.00,   -- 总分，固定 100.00
    dimension_weights        NVARCHAR(MAX)      NOT NULL,   -- 六维权重对象：content/expression/posture/interaction/board_ppt/time_management，六项之和=1
    grade_bands              NVARCHAR(MAX)      NULL,   -- 等级分数线：{"excellent":90,"good":80,"pass":60}；NULL 时用系统默认。V1.1 新增（决议 D11）
    version                  INT                NOT NULL  CONSTRAINT df_rubric_version DEFAULT 1,   -- 版本号，自 1 递增，不可回改
    is_template              BIT                NOT NULL  CONSTRAINT df_rubric_is_template DEFAULT 0,   -- 是否系统模板：1 是
    [status]                 NVARCHAR(9)        NOT NULL  CONSTRAINT df_rubric_status DEFAULT 'draft',   -- 状态：draft 草稿/published 已发布/disabled 已停用；已发布不可 UPDATE，仅可停用或发新版  [枚举: draft/published/disabled]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_rubric_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_rubric_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效；业务上禁止删除，仅停用
    CONSTRAINT pk_rubric PRIMARY KEY (rubric_id),
    CONSTRAINT ck_rubric_total CHECK (total_score = 100.00),
    CONSTRAINT ck_rubric_version CHECK (version >= 1),
    CONSTRAINT ck_rubric_weights CHECK (ISJSON(dimension_weights) = 1),
    CONSTRAINT ck_rubric_bands CHECK (grade_bands IS NULL OR ISJSON(grade_bands) = 1),
    CONSTRAINT ck_rubric_scope CHECK (scope IN ('system', 'school', 'teacher')),
    CONSTRAINT ck_rubric_stage CHECK (stage IS NULL OR stage IN ('preschool', 'primary', 'junior_high', 'senior_high', 'vocational')),
    CONSTRAINT ck_rubric_status CHECK ([status] IN ('draft', 'published', 'disabled'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_rubric_root_version' AND object_id = OBJECT_ID(N'task_content.rubric'))
    CREATE UNIQUE INDEX uk_rubric_root_version ON task_content.rubric(root_rubric_id, version);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_rubric_scope' AND object_id = OBJECT_ID(N'task_content.rubric'))
    CREATE INDEX idx_rubric_scope ON task_content.rubric(scope, [status]);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_rubric_subject_stage' AND object_id = OBJECT_ID(N'task_content.rubric'))
    CREATE INDEX idx_rubric_subject_stage ON task_content.rubric(subject_id, stage);
GO

/* rubric_item：B3 评分细则项：六维下的可打分项 */
IF OBJECT_ID(N'task_content.rubric_item', N'U') IS NULL
CREATE TABLE task_content.rubric_item (
    item_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 细则项ID，UUID v4
    rubric_id                UNIQUEIDENTIFIER   NOT NULL,   -- 所属标准ID，→task_content.rubric
    dimension                NVARCHAR(15)       NOT NULL,   -- 所属维度：教学内容/教学表达/教姿教态/互动控场/板书PPT/时间管理  [枚举: content/expression/posture/interaction/board_ppt/time_management]
    item_name                NVARCHAR(50)       NOT NULL,   -- 评分项名，如「知识点准确性」
    max_score                DECIMAL(5,2)       NOT NULL,   -- 该项满分，0-100
    scoring_desc             NVARCHAR(MAX)      NULL,   -- 评分描述，优秀/良好/合格/待改进四档说明
    ai_enabled               BIT                NOT NULL  CONSTRAINT df_ri_ai_enabled DEFAULT 1,   -- 是否允许 AI 评分：1 是/0 仅人工
    scored_by                NVARCHAR(13)       NOT NULL  CONSTRAINT df_ri_scored_by DEFAULT 'ai',   -- 评分主体：ai 仅AI/human 仅人工/ai_then_human AI初评可人工覆盖。V1.1 新增（决议 D12）  [枚举: ai/human/ai_then_human]
    weight_in_dimension      DECIMAL(4,3)       NOT NULL,   -- 维度内权重，0-1，同维度求和=1
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ri_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ri_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_rubric_item PRIMARY KEY (item_id),
    CONSTRAINT ck_ri_max_score CHECK (max_score BETWEEN 0 AND 100),
    CONSTRAINT ck_ri_weight CHECK (weight_in_dimension >= 0 AND weight_in_dimension <= 1),
    CONSTRAINT ck_ri_dimension CHECK (dimension IN ('content', 'expression', 'posture', 'interaction', 'board_ppt', 'time_management')),
    CONSTRAINT ck_ri_scored_by CHECK (scored_by IN ('ai', 'human', 'ai_then_human'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_ri_rubric_dim' AND object_id = OBJECT_ID(N'task_content.rubric_item'))
    CREATE INDEX idx_ri_rubric_dim ON task_content.rubric_item(rubric_id, dimension);
GO

/* trial_task：B1 试讲任务：教师发布的练习/考核单元 */
IF OBJECT_ID(N'task_content.trial_task', N'U') IS NULL
CREATE TABLE task_content.trial_task (
    task_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 任务ID，UUID v4
    title                    NVARCHAR(100)      NOT NULL,   -- 任务名称，2-50 字符
    publisher_id             UNIQUEIDENTIFIER   NOT NULL,   -- 发布教师档案ID，→identity_org.teacher_profile
    subject_id               UNIQUEIDENTIFIER   NOT NULL,   -- 学科ID，→identity_org.subject
    stage                    NVARCHAR(11)       NOT NULL,   -- 学段：幼教/小学/初中/高中/中职  [枚举: preschool/primary/junior_high/senior_high/vocational]
    textbook_version         NVARCHAR(50)       NOT NULL,   -- 教材版本，如 部编版/人教版/北师大版
    [mode]                   NVARCHAR(10)       NOT NULL,   -- 试讲模式：free 自由试讲/scenario 情景模拟/structured 结构化面试  [枚举: free/scenario/structured]
    duration_limit_s         INT                NOT NULL  CONSTRAINT df_task_duration_limit_s DEFAULT 600,   -- 时长上限（秒），300-2700，默认 600=10 分钟
    rubric_id                UNIQUEIDENTIFIER   NOT NULL,   -- 评分标准ID，→task_content.rubric，版本化引用
    allow_retry              TINYINT            NOT NULL  CONSTRAINT df_task_allow_retry DEFAULT 3,   -- 允许重做次数，0-10，默认 3
    require_video            BIT                NOT NULL  CONSTRAINT df_task_require_video DEFAULT 1,   -- 必须录像：1 是/0 否
    deadline                 DATETIME2(3)       NOT NULL,   -- 截止时间（UTC），须晚于 created_at
    [status]                 NVARCHAR(9)        NOT NULL  CONSTRAINT df_task_status DEFAULT 'draft',   -- 任务状态：draft 草稿/published 已发布/ongoing 进行中/closed 已截止/reviewed 已批阅  [枚举: draft/published/ongoing/closed/reviewed]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_task_created_at DEFAULT SYSUTCDATETIME(),   -- 创建（发布）时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_task_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_trial_task PRIMARY KEY (task_id),
    CONSTRAINT ck_task_duration CHECK (duration_limit_s BETWEEN 300 AND 2700),
    CONSTRAINT ck_task_retry CHECK (allow_retry BETWEEN 0 AND 10),
    CONSTRAINT ck_task_deadline CHECK (deadline > created_at),
    CONSTRAINT ck_task_stage CHECK (stage IN ('preschool', 'primary', 'junior_high', 'senior_high', 'vocational')),
    CONSTRAINT ck_task_mode CHECK ([mode] IN ('free', 'scenario', 'structured')),
    CONSTRAINT ck_task_status CHECK ([status] IN ('draft', 'published', 'ongoing', 'closed', 'reviewed'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_task_deadline_status' AND object_id = OBJECT_ID(N'task_content.trial_task'))
    CREATE INDEX idx_task_deadline_status ON task_content.trial_task(deadline, [status]);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_task_publisher' AND object_id = OBJECT_ID(N'task_content.trial_task'))
    CREATE INDEX idx_task_publisher ON task_content.trial_task(publisher_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_task_subject_stage' AND object_id = OBJECT_ID(N'task_content.trial_task'))
    CREATE INDEX idx_task_subject_stage ON task_content.trial_task(subject_id, stage);
GO

/* trial_topic：B4 试讲题目：题库最小检索单元 */
IF OBJECT_ID(N'task_content.trial_topic', N'U') IS NULL
CREATE TABLE task_content.trial_topic (
    topic_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 题目ID，UUID v4
    subject_id               UNIQUEIDENTIFIER   NOT NULL,   -- 学科ID，→identity_org.subject
    stage                    NVARCHAR(11)       NOT NULL,   -- 学段：幼教/小学/初中/高中/中职  [枚举: preschool/primary/junior_high/senior_high/vocational]
    textbook_version         NVARCHAR(50)       NOT NULL,   -- 教材版本
    book_volume              NVARCHAR(20)       NULL,   -- 册次，如「七年级上册」
    chapter                  NVARCHAR(100)      NULL,   -- 章节，如「第三单元第2课」
    topic_title              NVARCHAR(200)      NOT NULL,   -- 题目标题
    content_text             NVARCHAR(MAX)      NOT NULL,   -- 题面内容，≤5000 字符，可含公式/图片
    requirements             NVARCHAR(MAX)      NULL,   -- 试讲要求，如「含板书设计、体现启发式」
    difficulty               TINYINT            NOT NULL,   -- 难度 1-5
    [source]                 NVARCHAR(17)       NOT NULL,   -- 来源：teacher_cert_exam 教资真题/skill_competition 技能大赛真题/platform 平台题库/teacher_created 教师自建  [枚举: teacher_cert_exam/skill_competition/platform/teacher_created]
    exam_year                SMALLINT           NULL,   -- 真题年份，2015-当前年；source 为真题时必填
    usage_count              INT                NOT NULL  CONSTRAINT df_topic_usage_count DEFAULT 0,   -- 使用次数，冗余计数
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_topic_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_topic_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_trial_topic PRIMARY KEY (topic_id),
    CONSTRAINT ck_topic_difficulty CHECK (difficulty BETWEEN 1 AND 5),
    CONSTRAINT ck_topic_exam_year CHECK (exam_year IS NULL OR exam_year BETWEEN 2015 AND 2100),
    CONSTRAINT ck_topic_exam_year_req CHECK ([source] <> 'teacher_cert_exam' OR exam_year IS NOT NULL),
    CONSTRAINT ck_topic_stage CHECK (stage IN ('preschool', 'primary', 'junior_high', 'senior_high', 'vocational')),
    CONSTRAINT ck_topic_source CHECK ([source] IN ('teacher_cert_exam', 'skill_competition', 'platform', 'teacher_created'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_topic_filter' AND object_id = OBJECT_ID(N'task_content.trial_topic'))
    CREATE INDEX idx_topic_filter ON task_content.trial_topic(subject_id, stage, textbook_version, difficulty);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_topic_usage' AND object_id = OBJECT_ID(N'task_content.trial_topic'))
    CREATE INDEX idx_topic_usage ON task_content.trial_topic(usage_count DESC);
GO

/* structured_question：B5 结构化面试题库：10 类抽题来源 */
IF OBJECT_ID(N'task_content.structured_question', N'U') IS NULL
CREATE TABLE task_content.structured_question (
    q_id                     UNIQUEIDENTIFIER   NOT NULL,   -- 题目ID，UUID v4
    category                 NVARCHAR(18)       NOT NULL,   -- 类别：职业认知/心理素质/仪表仪态/言语表达/思维品质/教育教学/应急应变/人际沟通/组织管理/时政热点  [枚举: career_cognition/psychology/appearance/verbal_expression/thinking_quality/education_teaching/emergency_response/interpersonal/organization/topical]
    q_text                   NVARCHAR(MAX)      NOT NULL,   -- 题干，≤1000 字符
    answer_outline           NVARCHAR(MAX)      NULL,   -- 参考要点，≤2000 字符
    [source]                 NVARCHAR(17)       NOT NULL,   -- 来源：teacher_cert_exam 教资真题/mock 模拟题  [枚举: teacher_cert_exam/mock]
    exam_year                SMALLINT           NULL,   -- 真题年份，2015-当前年；source=teacher_cert_exam 时必填
    region                   NVARCHAR(30)       NULL,   -- 考区，如「四川」
    difficulty               TINYINT            NOT NULL,   -- 难度 1-5
    tags                     NVARCHAR(MAX)      NULL,   -- 标签数组，如 ["课堂突发","家校沟通"]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sq_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sq_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_structured_question PRIMARY KEY (q_id),
    CONSTRAINT ck_sq_difficulty CHECK (difficulty BETWEEN 1 AND 5),
    CONSTRAINT ck_sq_exam_year_req CHECK ([source] <> 'teacher_cert_exam' OR exam_year IS NOT NULL),
    CONSTRAINT ck_sq_category CHECK (category IN ('career_cognition', 'psychology', 'appearance', 'verbal_expression', 'thinking_quality', 'education_teaching', 'emergency_response', 'interpersonal', 'organization', 'topical')),
    CONSTRAINT ck_sq_source CHECK ([source] IN ('teacher_cert_exam', 'mock'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sq_category_diff' AND object_id = OBJECT_ID(N'task_content.structured_question'))
    CREATE INDEX idx_sq_category_diff ON task_content.structured_question(category, difficulty);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sq_year_region' AND object_id = OBJECT_ID(N'task_content.structured_question'))
    CREATE INDEX idx_sq_year_region ON task_content.structured_question(exam_year, region);
GO

/* lesson_template：B6 教案/板书模板：可复用教学资源 */
IF OBJECT_ID(N'task_content.lesson_template', N'U') IS NULL
CREATE TABLE task_content.lesson_template (
    template_id              UNIQUEIDENTIFIER   NOT NULL,   -- 模板ID，UUID v4
    template_type            NVARCHAR(13)       NOT NULL,   -- 模板类型：lesson_plan 教案/board_design 板书设计/teaching_plan 说课稿  [枚举: lesson_plan/board_design/teaching_plan]
    subject_id               UNIQUEIDENTIFIER   NULL,   -- 学科ID，NULL=通用
    stage                    NVARCHAR(11)       NULL,   -- 学段，NULL=通用  [枚举: preschool/primary/junior_high/senior_high/vocational]
    template_name            NVARCHAR(50)       NOT NULL,   -- 模板名
    content_json             NVARCHAR(MAX)      NOT NULL,   -- 模板内容，结构化章节：教学目标/重难点/教学过程/板书
    file_url                 NVARCHAR(512)      NULL,   -- 附件 URL，docx/pdf ≤20MB
    usage_count              INT                NOT NULL  CONSTRAINT df_lt_usage_count DEFAULT 0,   -- 使用次数，冗余计数
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_lt_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_lt_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_lesson_template PRIMARY KEY (template_id),
    CONSTRAINT ck_lt_content CHECK (ISJSON(content_json) = 1),
    CONSTRAINT ck_lt_template CHECK (template_type IN ('lesson_plan', 'board_design', 'teaching_plan')),
    CONSTRAINT ck_lt_stage CHECK (stage IS NULL OR stage IN ('preschool', 'primary', 'junior_high', 'senior_high', 'vocational'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_lt_type_subject' AND object_id = OBJECT_ID(N'task_content.lesson_template'))
    CREATE INDEX idx_lt_type_subject ON task_content.lesson_template(template_type, subject_id, stage);
GO

/* exemplar：B7 优秀试讲范例：同题对照与目标锚定 */
IF OBJECT_ID(N'task_content.exemplar', N'U') IS NULL
CREATE TABLE task_content.exemplar (
    exemplar_id              UNIQUEIDENTIFIER   NOT NULL,   -- 范例ID，UUID v4
    topic_id                 UNIQUEIDENTIFIER   NULL,   -- 关联题目ID，→task_content.trial_topic，NULL=通用范例
    video_url                NVARCHAR(512)      NOT NULL,   -- 范例视频 URL，mp4 ≤2GB
    transcript               NVARCHAR(MAX)      NULL,   -- 逐字稿，带时间戳
    highlight_tags           NVARCHAR(MAX)      NULL,   -- 亮点标签数组，如 ["导入巧妙","追问设计"]
    ref_score                DECIMAL(5,2)       NULL,   -- 参考得分，0-100，专家评分
    [status]                 NVARCHAR(7)        NOT NULL  CONSTRAINT df_ex_status DEFAULT 'online',   -- 状态：online 上架/offline 下架  [枚举: online/offline]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ex_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ex_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_exemplar PRIMARY KEY (exemplar_id),
    CONSTRAINT ck_ex_ref_score CHECK (ref_score IS NULL OR ref_score BETWEEN 0 AND 100),
    CONSTRAINT ck_ex_status CHECK ([status] IN ('online', 'offline'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_ex_topic' AND object_id = OBJECT_ID(N'task_content.exemplar'))
    CREATE INDEX idx_ex_topic ON task_content.exemplar(topic_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_ex_status' AND object_id = OBJECT_ID(N'task_content.exemplar'))
    CREATE INDEX idx_ex_status ON task_content.exemplar([status]);
GO

/* task_class：R5 任务-班级关系：承载 B1.class_ids，为空表示未发布 */
IF OBJECT_ID(N'task_content.task_class', N'U') IS NULL
CREATE TABLE task_content.task_class (
    task_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 任务ID，→task_content.trial_task
    class_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 目标班级ID，→identity_org.class，至少 1 条
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_tc_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    CONSTRAINT pk_task_class PRIMARY KEY (task_id, class_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_tc_class' AND object_id = OBJECT_ID(N'task_content.task_class'))
    CREATE INDEX idx_tc_class ON task_content.task_class(class_id);
GO

/* task_topic：R6 任务-指定题目关系：承载 B1.topic_ids */
IF OBJECT_ID(N'task_content.task_topic', N'U') IS NULL
CREATE TABLE task_content.task_topic (
    task_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 任务ID，→task_content.trial_task
    topic_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 指定题目ID，→task_content.trial_topic；无记录=学生自选
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_tt_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    CONSTRAINT pk_task_topic PRIMARY KEY (task_id, topic_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_tt_topic' AND object_id = OBJECT_ID(N'task_content.task_topic'))
    CREATE INDEX idx_tt_topic ON task_content.task_topic(topic_id);
GO


/* ==========================================================================
   Schema classroom（5 表）
   ========================================================================== */

/* scenario：C4 情景脚本：可运营扩展的突发事件时间轴 */
IF OBJECT_ID(N'classroom.scenario', N'U') IS NULL
CREATE TABLE classroom.scenario (
    scenario_id              UNIQUEIDENTIFIER   NOT NULL,   -- 情景ID，UUID v4
    scenario_name            NVARCHAR(50)       NOT NULL,   -- 名称，如「学生当众质疑结论」
    scenario_type            NVARCHAR(20)       NOT NULL,   -- 类型：normal 常规课堂/emergency 突发情景/structured_interview 结构化面试  [枚举: normal/emergency/structured_interview]
    difficulty               TINYINT            NOT NULL,   -- 难度 1-5
    event_script             NVARCHAR(MAX)      NOT NULL,   -- 事件时间轴数组：[{offset_ms, event_type, payload}]，按 offset_ms 升序
    expected_skill           NVARCHAR(22)       NOT NULL,   -- 考察能力：控场/应变/引导/表达/专业知识  [枚举: control/adaptability/guidance/expression/professional_knowledge]
    subject_id               UNIQUEIDENTIFIER   NULL,   -- 适用学科ID，NULL=通用
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sc_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sc_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_scenario PRIMARY KEY (scenario_id),
    CONSTRAINT ck_sc_difficulty CHECK (difficulty BETWEEN 1 AND 5),
    CONSTRAINT ck_sc_script CHECK (ISJSON(event_script) = 1),
    CONSTRAINT ck_sc_scenario CHECK (scenario_type IN ('normal', 'emergency', 'structured_interview')),
    CONSTRAINT ck_sc_expected_skill CHECK (expected_skill IN ('control', 'adaptability', 'guidance', 'expression', 'professional_knowledge'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sc_type_diff' AND object_id = OBJECT_ID(N'classroom.scenario'))
    CREATE INDEX idx_sc_type_diff ON classroom.scenario(scenario_type, difficulty);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sc_subject' AND object_id = OBJECT_ID(N'classroom.scenario'))
    CREATE INDEX idx_sc_subject ON classroom.scenario(subject_id);
GO

/* trial_session：C1 虚拟课堂会话：一次试讲的完整生命周期 */
IF OBJECT_ID(N'classroom.trial_session', N'U') IS NULL
CREATE TABLE classroom.trial_session (
    session_id               UNIQUEIDENTIFIER   NOT NULL,   -- 场次ID，UUID v4
    task_id                  UNIQUEIDENTIFIER   NULL,   -- 关联任务ID，→task_content.trial_task，自由练习为 NULL
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 试讲人用户ID，→identity_org.user
    [mode]                   NVARCHAR(10)       NOT NULL,   -- 模式：free 自由试讲/scenario 情景模拟/structured 结构化面试  [枚举: free/scenario/structured]
    scenario_id              UNIQUEIDENTIFIER   NULL,   -- 情景脚本ID，→classroom.scenario；mode=scenario 时必填
    topic_id                 UNIQUEIDENTIFIER   NULL,   -- 试讲题目ID，→task_content.trial_topic；mode<>structured 时必填
    structured_q_id          UNIQUEIDENTIFIER   NULL,   -- 结构化面试题目ID，→task_content.structured_question；mode=structured 时必填。V1.1 新增，修复结构化面试无法落库题目的缺口
    student_count            TINYINT            NOT NULL  CONSTRAINT df_sess_student_count DEFAULT 30,   -- 虚拟学生人数，1-60，默认 30
    behavior_intensity       NVARCHAR(4)        NOT NULL  CONSTRAINT df_sess_behavior_intensity DEFAULT 'mid',   -- 行为强度：low 低/mid 中/high 高  [枚举: low/mid/high]
    classroom_theme          NVARCHAR(12)       NOT NULL  CONSTRAINT df_sess_classroom_theme DEFAULT 'blackboard',   -- 课堂环境：黑板/PPT投影/多媒体教室/幼儿园活动室  [枚举: blackboard/ppt/multimedia/kindergarten]
    bgm_level                NVARCHAR(8)        NOT NULL  CONSTRAINT df_sess_bgm_level DEFAULT 'light',   -- 氛围音：off 关闭/light 轻微/standard 标准  [枚举: off/light/standard]
    planned_duration_s       INT                NOT NULL,   -- 计划时长（秒），300-2700，对应 5-45 分钟
    actual_duration_s        INT                NULL,   -- 实际时长（秒），服务端权威计时，结束后 >0
    start_at                 DATETIME2(3)       NULL,   -- 开始时间（UTC），状态机进入 running 时写入
    end_at                   DATETIME2(3)       NULL,   -- 结束时间（UTC），须晚于 start_at
    [status]                 NVARCHAR(11)       NOT NULL  CONSTRAINT df_sess_status DEFAULT 'not_started',   -- 状态：未开始/进行中/已暂停/已完成/异常中断  [枚举: not_started/running/paused/finished/aborted]
    device_info              NVARCHAR(MAX)      NULL,   -- 设备信息：browser/camera/mic/resolution，用于质量归因
    consent_id               UNIQUEIDENTIFIER   NOT NULL,   -- 采集授权ID，→identity_org.consent_record；无有效授权拒绝开课
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sess_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sess_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_trial_session PRIMARY KEY (session_id),
    CONSTRAINT ck_sess_students CHECK (student_count BETWEEN 1 AND 60),
    CONSTRAINT ck_sess_planned CHECK (planned_duration_s BETWEEN 300 AND 2700),
    CONSTRAINT ck_sess_actual CHECK (actual_duration_s IS NULL OR actual_duration_s >= 0),
    CONSTRAINT ck_sess_time CHECK (end_at IS NULL OR start_at IS NULL OR end_at >= start_at),
    CONSTRAINT ck_sess_mode_topic CHECK ([mode] = 'structured' OR topic_id IS NOT NULL),
    CONSTRAINT ck_sess_mode_sq CHECK ([mode] <> 'structured' OR structured_q_id IS NOT NULL),
    CONSTRAINT ck_sess_mode_sc CHECK ([mode] <> 'scenario' OR scenario_id IS NOT NULL),
    CONSTRAINT ck_sess_mode CHECK ([mode] IN ('free', 'scenario', 'structured')),
    CONSTRAINT ck_sess_behavior_intensity CHECK (behavior_intensity IN ('low', 'mid', 'high')),
    CONSTRAINT ck_sess_classroom_theme CHECK (classroom_theme IN ('blackboard', 'ppt', 'multimedia', 'kindergarten')),
    CONSTRAINT ck_sess_bgm_level CHECK (bgm_level IN ('off', 'light', 'standard')),
    CONSTRAINT ck_sess_status CHECK ([status] IN ('not_started', 'running', 'paused', 'finished', 'aborted'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sess_user_start' AND object_id = OBJECT_ID(N'classroom.trial_session'))
    CREATE INDEX idx_sess_user_start ON classroom.trial_session(user_id, start_at);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sess_task' AND object_id = OBJECT_ID(N'classroom.trial_session'))
    CREATE INDEX idx_sess_task ON classroom.trial_session(task_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sess_status_created' AND object_id = OBJECT_ID(N'classroom.trial_session'))
    CREATE INDEX idx_sess_status_created ON classroom.trial_session([status], created_at);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sess_topic' AND object_id = OBJECT_ID(N'classroom.trial_session'))
    CREATE INDEX idx_sess_topic ON classroom.trial_session(topic_id);
GO

/* virtual_student：C2 虚拟学生实例：场次级对象，随场次销毁 */
IF OBJECT_ID(N'classroom.virtual_student', N'U') IS NULL
CREATE TABLE classroom.virtual_student (
    vs_id                    UNIQUEIDENTIFIER   NOT NULL,   -- 虚拟学生ID，UUID v4
    session_id               UNIQUEIDENTIFIER   NOT NULL,   -- 所属场次ID，→classroom.trial_session
    seat_no                  TINYINT            NOT NULL,   -- 座位号，1-60，场内唯一
    vs_name                  NVARCHAR(20)       NOT NULL,   -- 姓名，从姓名库随机，场内不重复
    persona                  NVARCHAR(10)       NOT NULL,   -- 人设：focused 专注型/active 活跃型/distracted 走神型/challenger 质疑型/quiet 沉默型/naughty 调皮型  [枚举: focused/active/distracted/challenger/quiet/naughty]
    engagement_base          TINYINT            NOT NULL,   -- 基础专注度，0-100，行为引擎初值
    avatar_key               NVARCHAR(50)       NOT NULL,   -- 形象资源键，映射前端形象包
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_vs_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    CONSTRAINT pk_virtual_student PRIMARY KEY (vs_id),
    CONSTRAINT ck_vs_seat CHECK (seat_no BETWEEN 1 AND 60),
    CONSTRAINT ck_vs_engagement CHECK (engagement_base BETWEEN 0 AND 100),
    CONSTRAINT ck_vs_persona CHECK (persona IN ('focused', 'active', 'distracted', 'challenger', 'quiet', 'naughty'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_vs_seat' AND object_id = OBJECT_ID(N'classroom.virtual_student'))
    CREATE UNIQUE INDEX uk_vs_seat ON classroom.virtual_student(session_id, seat_no);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_vs_name' AND object_id = OBJECT_ID(N'classroom.virtual_student'))
    CREATE UNIQUE INDEX uk_vs_name ON classroom.virtual_student(session_id, vs_name);
GO

/* behavior_event：C3 课堂行为事件：原始事实，只追加不更新 */
IF OBJECT_ID(N'classroom.behavior_event', N'U') IS NULL
CREATE TABLE classroom.behavior_event (
    event_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 事件ID，UUID v7（按时间有序，降低页分裂）
    session_id               UNIQUEIDENTIFIER   NOT NULL,   -- 所属场次ID，→classroom.trial_session（逻辑外键）
    vs_id                    UNIQUEIDENTIFIER   NULL,   -- 触发学生ID，→classroom.virtual_student（逻辑外键）；系统事件为 NULL
    event_type               NVARCHAR(14)       NOT NULL,   -- 事件类型：举手/提问/回答正确/回答错误/回答不完整/走神/小声说话/吵闹/质疑老师/设备故障  [枚举: raise_hand/ask/answer_right/answer_wrong/answer_partial/distracted/whisper/noisy/challenge/device_fault]
    offset_ms                INT                NOT NULL,   -- 相对场次起点的毫秒偏移，≥0，全表时间轴唯一基准
    payload                  NVARCHAR(MAX)      NULL,   -- 事件内容：提问文本/答案文本/正确标记/音量等级
    handled                  BIT                NOT NULL  CONSTRAINT df_beh_handled DEFAULT 0,   -- 是否被教师处理：1 是，用于控场响应率
    response_ms              INT                NULL,   -- 教师响应时延（毫秒），未处理为 NULL
    teacher_utterance        NVARCHAR(MAX)      NULL,   -- 该时段教师应对话术，ASR 转写结果
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_beh_created_at DEFAULT SYSUTCDATETIME(),   -- 入库时间（UTC），分区键；与 offset_ms 的分工见边界规则 E-B3
    CONSTRAINT pk_behavior_event PRIMARY KEY (event_id, created_at) ON ps_month(created_at),
    CONSTRAINT ck_beh_offset CHECK (offset_ms >= 0),
    CONSTRAINT ck_beh_response CHECK (response_ms IS NULL OR response_ms >= 0),
    CONSTRAINT ck_beh_event CHECK (event_type IN ('raise_hand', 'ask', 'answer_right', 'answer_wrong', 'answer_partial', 'distracted', 'whisper', 'noisy', 'challenge', 'device_fault'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_beh_session_offset' AND object_id = OBJECT_ID(N'classroom.behavior_event'))
    CREATE INDEX idx_beh_session_offset ON classroom.behavior_event(session_id, offset_ms, created_at) ON ps_month(created_at);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_beh_type_time' AND object_id = OBJECT_ID(N'classroom.behavior_event'))
    CREATE INDEX idx_beh_type_time ON classroom.behavior_event(event_type, created_at, created_at) ON ps_month(created_at);
GO

/* live_message：C5 实时消息：场次内聊天与指导流，只追加 */
IF OBJECT_ID(N'classroom.live_message', N'U') IS NULL
CREATE TABLE classroom.live_message (
    msg_id                   UNIQUEIDENTIFIER   NOT NULL,   -- 消息ID，UUID v7
    session_id               UNIQUEIDENTIFIER   NOT NULL,   -- 所属场次ID，→classroom.trial_session（逻辑外键）
    sender_type              NVARCHAR(15)       NOT NULL,   -- 发送方类型：虚拟学生/系统/指导教师/AI教练  [枚举: virtual_student/system/teacher/ai_coach]
    sender_id                UNIQUEIDENTIFIER   NULL,   -- 发送方ID：虚拟学生为 vs_id，教师/用户为 user_id，系统为 NULL
    msg_type                 NVARCHAR(8)        NOT NULL,   -- 消息类型：文本/语音/事件/提示/指导  [枚举: text/voice/event/hint/guidance]
    content                  NVARCHAR(2000)     NOT NULL,   -- 内容，≤2000 字符
    sent_at                  DATETIME2(3)       NOT NULL,   -- 发送时间（UTC），业务时间轴
    is_read                  BIT                NOT NULL  CONSTRAINT df_lm_is_read DEFAULT 0,   -- 是否已读：1 是，用于指导触达统计
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_lm_created_at DEFAULT SYSUTCDATETIME(),   -- 入库时间（UTC），分区键
    CONSTRAINT pk_live_message PRIMARY KEY (msg_id, created_at) ON ps_month(created_at),
    CONSTRAINT ck_lm_sender CHECK (sender_type IN ('virtual_student', 'system', 'teacher', 'ai_coach')),
    CONSTRAINT ck_lm_msg CHECK (msg_type IN ('text', 'voice', 'event', 'hint', 'guidance'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_lm_session_sent' AND object_id = OBJECT_ID(N'classroom.live_message'))
    CREATE INDEX idx_lm_session_sent ON classroom.live_message(session_id, sent_at, created_at) ON ps_month(created_at);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_lm_sender' AND object_id = OBJECT_ID(N'classroom.live_message'))
    CREATE INDEX idx_lm_sender ON classroom.live_message(sender_type, sender_id, created_at) ON ps_month(created_at);
GO


/* ==========================================================================
   Schema media（3 表）
   ========================================================================== */

/* recording：D1 录制文件：一轨一行，合成轨单独一行 */
IF OBJECT_ID(N'media.recording', N'U') IS NULL
CREATE TABLE media.recording (
    recording_id             UNIQUEIDENTIFIER   NOT NULL,   -- 录制ID，UUID v4
    session_id               UNIQUEIDENTIFIER   NOT NULL,   -- 所属场次ID，→classroom.trial_session
    track_type               NVARCHAR(8)        NOT NULL,   -- 轨道类型：portrait 人像/screen 屏幕PPT/board 板书/audio 音频/merged 合成  [枚举: portrait/screen/board/audio/merged]
    file_url                 NVARCHAR(512)      NOT NULL,   -- 文件地址，对象存储 key 或预签名 URL
    duration_ms              INT                NOT NULL,   -- 时长（毫秒），>0，与场次实际时长偏差 ≤5s
    size_mb                  DECIMAL(10,2)      NULL,   -- 文件大小（MB），单轨 ≤2048
    resolution               NVARCHAR(20)       NULL,   -- 分辨率，如 1920x1080
    [format]                 NVARCHAR(10)       NULL,   -- 封装格式：mp4/webm/m4a
    storage_region           NVARCHAR(5)        NOT NULL  CONSTRAINT df_rec_storage_region DEFAULT 'cloud',   -- 存储位置：local 本地/cloud 云端  [枚举: local/cloud]
    upload_status            NVARCHAR(10)       NOT NULL  CONSTRAINT df_rec_upload_status DEFAULT 'uploading',   -- 上传状态：上传中/成功/失败/已转码  [枚举: uploading/success/failed/transcoded]
    [checksum]               CHAR(64)           NULL,   -- SHA-256 校验值，64 位十六进制，防篡改与续传校验
    retention_until          DATE               NOT NULL,   -- 保留到期日，默认创建日 +180 天，可续期至 3 年
    merged_url               NVARCHAR(512)      NULL,   -- 合成产物 URL，track_type=merged 时必填
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_rec_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_rec_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_recording PRIMARY KEY (recording_id),
    CONSTRAINT ck_rec_duration CHECK (duration_ms > 0),
    CONSTRAINT ck_rec_size CHECK (size_mb IS NULL OR size_mb <= 2048),
    CONSTRAINT ck_rec_merged CHECK (track_type <> 'merged' OR merged_url IS NOT NULL),
    CONSTRAINT ck_rec_track CHECK (track_type IN ('portrait', 'screen', 'board', 'audio', 'merged')),
    CONSTRAINT ck_rec_storage_region CHECK (storage_region IN ('local', 'cloud')),
    CONSTRAINT ck_rec_upload_status CHECK (upload_status IN ('uploading', 'success', 'failed', 'transcoded'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_rec_session_track' AND object_id = OBJECT_ID(N'media.recording'))
    CREATE UNIQUE INDEX uk_rec_session_track ON media.recording(session_id, track_type);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_rec_retention' AND object_id = OBJECT_ID(N'media.recording'))
    CREATE INDEX idx_rec_retention ON media.recording(retention_until);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_rec_status' AND object_id = OBJECT_ID(N'media.recording'))
    CREATE INDEX idx_rec_status ON media.recording(upload_status);
GO

/* playback_marker：D2 回放标记：问题点与视频片段的互跳锚点 */
IF OBJECT_ID(N'media.playback_marker', N'U') IS NULL
CREATE TABLE media.playback_marker (
    marker_id                UNIQUEIDENTIFIER   NOT NULL,   -- 标记ID，UUID v4
    recording_id             UNIQUEIDENTIFIER   NOT NULL,   -- 关联录制ID，→media.recording
    offset_ms                INT                NOT NULL,   -- 时间锚点（毫秒），≥0 且 ≤ 所属录制 duration_ms
    marker_type              NVARCHAR(15)       NOT NULL,   -- 标记类型：AI问题点/教师批注/学生自评/亮点  [枚举: ai_issue/teacher_comment/self_review/highlight]
    [comment]                NVARCHAR(500)      NULL,   -- 批注内容，≤500 字符
    author_id                UNIQUEIDENTIFIER   NULL,   -- 批注人用户ID；AI 生成时为 NULL
    linked_issue_id          UNIQUEIDENTIFIER   NULL,   -- 关联问题项ID，→evaluation.issue_item；跨库逻辑外键
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_pmk_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_pmk_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_playback_marker PRIMARY KEY (marker_id),
    CONSTRAINT ck_pm_offset CHECK (offset_ms >= 0),
    CONSTRAINT ck_pmk_marker CHECK (marker_type IN ('ai_issue', 'teacher_comment', 'self_review', 'highlight'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_pm_recording_offset' AND object_id = OBJECT_ID(N'media.playback_marker'))
    CREATE INDEX idx_pm_recording_offset ON media.playback_marker(recording_id, offset_ms);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_pm_issue' AND object_id = OBJECT_ID(N'media.playback_marker'))
    CREATE INDEX idx_pm_issue ON media.playback_marker(linked_issue_id);
GO

/* observation：D3 观摩记录：教师在场时长与指导活跃度 */
IF OBJECT_ID(N'media.observation', N'U') IS NULL
CREATE TABLE media.observation (
    observation_id           UNIQUEIDENTIFIER   NOT NULL,   -- 观摩ID，UUID v4
    session_id               UNIQUEIDENTIFIER   NOT NULL,   -- 观摩场次ID，→classroom.trial_session
    teacher_id               UNIQUEIDENTIFIER   NOT NULL,   -- 观摩教师档案ID，→identity_org.teacher_profile
    join_at                  DATETIME2(3)       NOT NULL,   -- 进入时间（UTC）
    leave_at                 DATETIME2(3)       NULL,   -- 离开时间（UTC），须 ≥ join_at
    watch_duration_ms        INT                NOT NULL  CONSTRAINT df_ob_watch_duration_ms DEFAULT 0,   -- 观看时长（毫秒），≥0
    guidance_count           SMALLINT           NOT NULL  CONSTRAINT df_ob_guidance_count DEFAULT 0,   -- 实时指导条数，≥0，冗余自 live_message
    is_live                  BIT                NOT NULL  CONSTRAINT df_ob_is_live DEFAULT 1,   -- 是否直播观摩：1 直播/0 回看
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ob_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ob_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_observation PRIMARY KEY (observation_id),
    CONSTRAINT ck_ob_time CHECK (leave_at IS NULL OR leave_at >= join_at)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_ob_session' AND object_id = OBJECT_ID(N'media.observation'))
    CREATE INDEX idx_ob_session ON media.observation(session_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_ob_teacher_join' AND object_id = OBJECT_ID(N'media.observation'))
    CREATE INDEX idx_ob_teacher_join ON media.observation(teacher_id, join_at);
GO


/* ==========================================================================
   Schema evaluation（11 表）
   ========================================================================== */

/* evaluation_report：E1 评测报告：不可变主体 + 可追加复核字段 */
IF OBJECT_ID(N'evaluation.evaluation_report', N'U') IS NULL
CREATE TABLE evaluation.evaluation_report (
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 报告ID，UUID v4
    session_id               UNIQUEIDENTIFIER   NOT NULL,   -- 所属场次ID，→classroom.trial_session，1:1 唯一
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 试讲人用户ID，→identity_org.user，冗余以便按人查
    rubric_id                UNIQUEIDENTIFIER   NOT NULL,   -- 采用标准ID，→task_content.rubric
    rubric_version           INT                NOT NULL,   -- 标准版本快照，口径追溯用
    topic_snapshot           NVARCHAR(MAX)      NULL,   -- 题面快照，防题目变更导致历史报告变形；结构化面试无题面时为 NULL
    ai_total_score           DECIMAL(5,2)       NULL,   -- AI 总分，0-100，六维加权；计算中为 NULL
    grade                    NVARCHAR(9)        NULL,   -- 等级：excellent ≥90/good 80-89/pass 60-79/fail <60；分数线由 rubric 配置  [枚举: excellent/good/pass/fail]
    teacher_score            DECIMAL(5,2)       NULL,   -- 有效主批教师总分，0-100；无有效主批时为 NULL，AI 分独立保存在 ai_total_score
    final_score              DECIMAL(5,2)       NULL,   -- 最终分：有效主批教师分优先，否则取 ai_total_score
    ai_model_version         NVARCHAR(30)       NOT NULL,   -- AI 模型版本，如 eval-v2.3，随报告留痕
    asr_status               NVARCHAR(MAX)      NULL,   -- ASR 各路状态：{asr,pron,vision,ocr,interaction: pending|running|done|failed}
    ai_task_status           NVARCHAR(MAX)      NULL,   -- 流水线任务状态：{step, attempts, last_error, updated_at}
    retry_count              SMALLINT           NOT NULL  CONSTRAINT df_report_retry_count DEFAULT 0,   -- 重算次数，0 起，每次重算 +1
    [status]                 NVARCHAR(16)       NOT NULL  CONSTRAINT df_report_status DEFAULT 'calculating',   -- 状态：计算中/已完成/失败/已教师复核  [枚举: calculating/finished/failed/teacher_reviewed]
    generated_at             DATETIME2(3)       NULL,   -- 报告生成完成时间（UTC）；status=finished 时必填
    reviewed_at              DATETIME2(3)       NULL,   -- 教师复核时间（UTC）
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_report_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_report_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_evaluation_report PRIMARY KEY (report_id),
    CONSTRAINT ck_report_ai_score CHECK (ai_total_score IS NULL OR ai_total_score BETWEEN 0 AND 100),
    CONSTRAINT ck_report_t_score CHECK (teacher_score IS NULL OR teacher_score BETWEEN 0 AND 100),
    CONSTRAINT ck_report_f_score CHECK (final_score IS NULL OR final_score BETWEEN 0 AND 100),
    CONSTRAINT ck_report_rubric_ver CHECK (rubric_version >= 1),
    CONSTRAINT ck_report_retry CHECK (retry_count >= 0),
    CONSTRAINT ck_report_final CHECK ([status] IN ('calculating','failed') OR (final_score IS NOT NULL AND grade IS NOT NULL AND generated_at IS NOT NULL)),
    CONSTRAINT ck_report_reviewed CHECK ([status] <> 'teacher_reviewed' OR reviewed_at IS NOT NULL),
    CONSTRAINT ck_report_snapshot CHECK (topic_snapshot IS NULL OR ISJSON(topic_snapshot) = 1),
    CONSTRAINT ck_report_grade CHECK (grade IS NULL OR grade IN ('excellent', 'good', 'pass', 'fail')),
    CONSTRAINT ck_report_status CHECK ([status] IN ('calculating', 'finished', 'failed', 'teacher_reviewed'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_report_session' AND object_id = OBJECT_ID(N'evaluation.evaluation_report'))
    CREATE UNIQUE INDEX uk_report_session ON evaluation.evaluation_report(session_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_report_user_time' AND object_id = OBJECT_ID(N'evaluation.evaluation_report'))
    CREATE INDEX idx_report_user_time ON evaluation.evaluation_report(user_id, generated_at DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_report_status' AND object_id = OBJECT_ID(N'evaluation.evaluation_report'))
    CREATE INDEX idx_report_status ON evaluation.evaluation_report([status], created_at);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_report_rubric' AND object_id = OBJECT_ID(N'evaluation.evaluation_report'))
    CREATE INDEX idx_report_rubric ON evaluation.evaluation_report(rubric_id, rubric_version);
GO

/* dimension_score：E2 六维得分：雷达图与维度明细数据源 */
IF OBJECT_ID(N'evaluation.dimension_score', N'U') IS NULL
CREATE TABLE evaluation.dimension_score (
    score_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 得分ID，UUID v4
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 所属报告ID，→evaluation.evaluation_report
    dimension                NVARCHAR(15)       NOT NULL,   -- 维度：教学内容/教学表达/教姿教态/互动控场/板书PPT/时间管理  [枚举: content/expression/posture/interaction/board_ppt/time_management]
    score                    DECIMAL(5,2)       NOT NULL,   -- 维度得分，0-100
    max_score                DECIMAL(5,2)       NOT NULL  CONSTRAINT df_ds_max_score DEFAULT 100.00,   -- 维度满分，固定 100.00
    weight                   DECIMAL(4,3)       NOT NULL,   -- 权重，来自 rubric.dimension_weights，六维之和=1
    ai_confidence            DECIMAL(4,3)       NULL,   -- AI 置信度，0-1，低于阈值提示人工复核
    evidence                 NVARCHAR(MAX)      NULL,   -- 证据片段：[{offset_ms, text, reason}]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ds_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ds_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_dimension_score PRIMARY KEY (score_id),
    CONSTRAINT ck_ds_score CHECK (score BETWEEN 0 AND 100),
    CONSTRAINT ck_ds_weight CHECK (weight >= 0 AND weight <= 1),
    CONSTRAINT ck_ds_conf CHECK (ai_confidence IS NULL OR (ai_confidence >= 0 AND ai_confidence <= 1)),
    CONSTRAINT ck_ds_evidence CHECK (evidence IS NULL OR ISJSON(evidence) = 1),
    CONSTRAINT ck_ds_dimension CHECK (dimension IN ('content', 'expression', 'posture', 'interaction', 'board_ppt', 'time_management'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_ds_report_dim' AND object_id = OBJECT_ID(N'evaluation.dimension_score'))
    CREATE UNIQUE INDEX uk_ds_report_dim ON evaluation.dimension_score(report_id, dimension);
GO

/* issue_item：E3 问题项：带时间段锚点，支持视频跳转 */
IF OBJECT_ID(N'evaluation.issue_item', N'U') IS NULL
CREATE TABLE evaluation.issue_item (
    issue_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 问题ID，UUID v4
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 所属报告ID，→evaluation.evaluation_report
    dimension                NVARCHAR(15)       NOT NULL,   -- 所属维度：六维之一  [枚举: content/expression/posture/interaction/board_ppt/time_management]
    issue_type               NVARCHAR(24)       NOT NULL,   -- 问题类型：语速过快/语速过慢/口头禅/知识点错误/讲解不完整/逻辑不清/互动不足/提问设计差/反馈缺失/纪律未处理/板书混乱/字迹潦草/PPT依赖过度/环节超时/环节缺失/眼神回避/站姿不稳/音量过低  [枚举: fast_speech/slow_speech/filler_word/wrong_knowledge/incomplete_explanation/unclear_logic/insufficient_interaction/poor_questioning/missing_feedback/undisciplined/unclear_board/poor_handwriting/ppt_overreliance/segment_overtime/segment_missing/eye_avoidance/unstable_posture/low_volume]
    severity                 NVARCHAR(4)        NOT NULL,   -- 严重程度：high 高/mid 中/low 低；枚举顺序即排序序  [枚举: high/mid/low]
    offset_start_ms          INT                NOT NULL,   -- 问题起始偏移（毫秒），0 ≤ start < end
    offset_end_ms            INT                NOT NULL,   -- 问题结束偏移（毫秒），用于播放器跳转
    description              NVARCHAR(300)      NOT NULL,   -- 问题描述，≤300 字符
    evidence_text            NVARCHAR(MAX)      NULL,   -- 原文证据，ASR 转写片段
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ii_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_ii_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_issue_item PRIMARY KEY (issue_id),
    CONSTRAINT ck_ii_offset CHECK (offset_start_ms >= 0 AND offset_end_ms > offset_start_ms),
    CONSTRAINT ck_ii_dimension CHECK (dimension IN ('content', 'expression', 'posture', 'interaction', 'board_ppt', 'time_management')),
    CONSTRAINT ck_ii_issue CHECK (issue_type IN ('fast_speech', 'slow_speech', 'filler_word', 'wrong_knowledge', 'incomplete_explanation', 'unclear_logic', 'insufficient_interaction', 'poor_questioning', 'missing_feedback', 'undisciplined', 'unclear_board', 'poor_handwriting', 'ppt_overreliance', 'segment_overtime', 'segment_missing', 'eye_avoidance', 'unstable_posture', 'low_volume')),
    CONSTRAINT ck_ii_severity CHECK (severity IN ('high', 'mid', 'low'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_ii_report_sev' AND object_id = OBJECT_ID(N'evaluation.issue_item'))
    CREATE INDEX idx_ii_report_sev ON evaluation.issue_item(report_id, severity, offset_start_ms);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_ii_type' AND object_id = OBJECT_ID(N'evaluation.issue_item'))
    CREATE INDEX idx_ii_type ON evaluation.issue_item(issue_type);
GO

/* filler_word_hit：E4 口头禅命中：频次词表统计 */
IF OBJECT_ID(N'evaluation.filler_word_hit', N'U') IS NULL
CREATE TABLE evaluation.filler_word_hit (
    hit_id                   UNIQUEIDENTIFIER   NOT NULL,   -- 命中ID，UUID v4
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 所属报告ID，→evaluation.evaluation_report
    word                     NVARCHAR(20)       NOT NULL,   -- 口头禅词，如 嗯/啊/那个/这个/就是/然后/对吧/是吧/怎么说；支持班级自定义词表
    cnt                      INT                NOT NULL,   -- 出现次数，≥0；列名避开 COUNT 函数
    per_minute               DECIMAL(5,2)       NOT NULL,   -- 每分钟频次，次/分钟
    offsets_ms               NVARCHAR(MAX)      NOT NULL,   -- 命中时刻数组（毫秒），用于逐次跳转
    is_custom                BIT                NOT NULL  CONSTRAINT df_fwh_is_custom DEFAULT 0,   -- 是否自定义词：1 是/0 系统词表
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_fwh_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    CONSTRAINT pk_filler_word_hit PRIMARY KEY (hit_id),
    CONSTRAINT ck_fwh_cnt CHECK (cnt >= 0),
    CONSTRAINT ck_fwh_per_min CHECK (per_minute >= 0),
    CONSTRAINT ck_fwh_offsets CHECK (ISJSON(offsets_ms) = 1)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_fwh_report_word' AND object_id = OBJECT_ID(N'evaluation.filler_word_hit'))
    CREATE UNIQUE INDEX uk_fwh_report_word ON evaluation.filler_word_hit(report_id, word);
GO

/* speech_metric：E5 语音表达指标：普通话/语速/停顿/音量/流畅度 */
IF OBJECT_ID(N'evaluation.speech_metric', N'U') IS NULL
CREATE TABLE evaluation.speech_metric (
    metric_id                UNIQUEIDENTIFIER   NOT NULL,   -- 指标ID，UUID v4
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 所属报告ID，→evaluation.evaluation_report，1:1
    mandarin_score           DECIMAL(5,2)       NULL,   -- 普通话标准度，0-100
    speed_wpm                SMALLINT           NULL,   -- 语速，60-400 字/分钟
    pause_count              INT                NULL,   -- 停顿次数，≥0
    avg_pause_ms             INT                NULL,   -- 平均停顿时长（毫秒）
    volume_avg_db            DECIMAL(5,2)       NULL,   -- 平均音量（dB）
    volume_stability         DECIMAL(5,2)       NULL,   -- 音量稳定性，0-100
    fluency_score            DECIMAL(5,2)       NULL,   -- 流畅度，0-100
    asr_text                 NVARCHAR(MAX)      NULL,   -- 全量转写文本，带时间戳 JSON 行
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sm_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sm_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_speech_metric PRIMARY KEY (metric_id),
    CONSTRAINT ck_sm_wpm CHECK (speed_wpm IS NULL OR speed_wpm BETWEEN 60 AND 400)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_sm_report' AND object_id = OBJECT_ID(N'evaluation.speech_metric'))
    CREATE UNIQUE INDEX uk_sm_report ON evaluation.speech_metric(report_id);
GO

/* posture_metric：E6 教姿教态指标：站姿/手势/眼神/微笑/走动 */
IF OBJECT_ID(N'evaluation.posture_metric', N'U') IS NULL
CREATE TABLE evaluation.posture_metric (
    metric_id                UNIQUEIDENTIFIER   NOT NULL,   -- 指标ID，UUID v4
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 所属报告ID，1:1
    stand_stability          DECIMAL(5,2)       NULL,   -- 站姿稳定性，0-100
    gesture_score            DECIMAL(5,2)       NULL,   -- 手势自然度，0-100
    eye_contact_ratio        DECIMAL(5,2)       NULL,   -- 眼神注视率，0-1
    smile_ratio              DECIMAL(5,2)       NULL,   -- 微笑占比，0-1
    movement_score           DECIMAL(5,2)       NULL,   -- 走动合理性，0-100
    frames_analyzed          INT                NULL,   -- 分析帧数，≥0
    detect_confidence        DECIMAL(4,3)       NULL,   -- 检测置信度，0-1
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_pm_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_pm_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_posture_metric PRIMARY KEY (metric_id),
    CONSTRAINT ck_pm_eye CHECK (eye_contact_ratio IS NULL OR (eye_contact_ratio >= 0 AND eye_contact_ratio <= 1)),
    CONSTRAINT ck_pm_smile CHECK (smile_ratio IS NULL OR (smile_ratio >= 0 AND smile_ratio <= 1))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_pm_report' AND object_id = OBJECT_ID(N'evaluation.posture_metric'))
    CREATE UNIQUE INDEX uk_pm_report ON evaluation.posture_metric(report_id);
GO

/* visual_aid_metric：E7 板书/PPT 呈现指标：结构/字迹/页数/时间占比 */
IF OBJECT_ID(N'evaluation.visual_aid_metric', N'U') IS NULL
CREATE TABLE evaluation.visual_aid_metric (
    metric_id                UNIQUEIDENTIFIER   NOT NULL,   -- 指标ID，UUID v4
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 所属报告ID，1:1
    board_structure_score    DECIMAL(5,2)       NULL,   -- 板书结构分，0-100
    handwriting_score        DECIMAL(5,2)       NULL,   -- 字迹工整度，0-100；未开启 OCR 时为 NULL
    ocr_enabled              BIT                NOT NULL  CONSTRAINT df_vam_ocr_enabled DEFAULT 0,   -- 是否启用 OCR：1 是
    ocr_text                 NVARCHAR(MAX)      NULL,   -- 板书识别文本；ocr_enabled=1 时必填
    ppt_slide_count          SMALLINT           NULL,   -- PPT 页数，≥0
    ppt_rationality_score    DECIMAL(5,2)       NULL,   -- PPT 合理性，0-100
    board_time_ratio         DECIMAL(4,3)       NULL,   -- 板书时间占比，0-1
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_vam_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_vam_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_visual_aid_metric PRIMARY KEY (metric_id),
    CONSTRAINT ck_vam_ocr CHECK (ocr_enabled = 0 OR ocr_text IS NOT NULL),
    CONSTRAINT ck_vam_ratio CHECK (board_time_ratio IS NULL OR (board_time_ratio >= 0 AND board_time_ratio <= 1))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_vam_report' AND object_id = OBJECT_ID(N'evaluation.visual_aid_metric'))
    CREATE UNIQUE INDEX uk_vam_report ON evaluation.visual_aid_metric(report_id);
GO

/* interaction_metric：E8 互动控场指标：提问/候答/反馈/纪律/节奏 */
IF OBJECT_ID(N'evaluation.interaction_metric', N'U') IS NULL
CREATE TABLE evaluation.interaction_metric (
    metric_id                UNIQUEIDENTIFIER   NOT NULL,   -- 指标ID，UUID v4
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 所属报告ID，1:1
    question_count           SMALLINT           NULL,   -- 提问次数，≥0
    open_question_ratio      DECIMAL(4,3)       NULL,   -- 开放性问题占比，0-1
    wait_time_avg_ms         INT                NULL,   -- 平均候答时长（毫秒）
    feedback_quality_score   DECIMAL(5,2)       NULL,   -- 反馈评价质量，0-100
    encourage_count          SMALLINT           NULL,   -- 鼓励性语言次数，≥0
    discipline_events        SMALLINT           NULL,   -- 纪律事件数，≥0
    discipline_handled_ratio DECIMAL(4,3)       NULL,   -- 纪律处理率，0-1
    pacing_score             DECIMAL(5,2)       NULL,   -- 节奏把控分，0-100
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_im_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_im_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_interaction_metric PRIMARY KEY (metric_id),
    CONSTRAINT ck_im_open CHECK (open_question_ratio IS NULL OR (open_question_ratio >= 0 AND open_question_ratio <= 1)),
    CONSTRAINT ck_im_disc CHECK (discipline_handled_ratio IS NULL OR (discipline_handled_ratio >= 0 AND discipline_handled_ratio <= 1))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_im_report' AND object_id = OBJECT_ID(N'evaluation.interaction_metric'))
    CREATE UNIQUE INDEX uk_im_report ON evaluation.interaction_metric(report_id);
GO

/* segment_timing：E9 环节时长：教学流程切分与偏差标记 */
IF OBJECT_ID(N'evaluation.segment_timing', N'U') IS NULL
CREATE TABLE evaluation.segment_timing (
    timing_id                UNIQUEIDENTIFIER   NOT NULL,   -- 计时ID，UUID v4
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 所属报告ID，→evaluation.evaluation_report
    segment                  NVARCHAR(10)       NOT NULL,   -- 环节：导入/新授/练习/小结/作业/其他  [枚举: intro/new_lesson/practice/summary/homework/other]
    start_ms                 INT                NOT NULL,   -- 起始偏移（毫秒）
    end_ms                   INT                NOT NULL,   -- 结束偏移（毫秒），须 > start_ms
    duration_ms              INT                NOT NULL,   -- 环节时长（毫秒），>0
    actual_ratio             DECIMAL(4,3)       NOT NULL,   -- 实际占比，0-1，同报告各环节求和=1
    plan_ratio               DECIMAL(4,3)       NULL,   -- 建议占比，0-1，来自 rubric 或学段模板
    deviation_flag           NVARCHAR(12)       NOT NULL  CONSTRAINT df_st_deviation_flag DEFAULT 'normal',   -- 偏差：normal 正常/overtime 超时/insufficient 不足/missing 缺失  [枚举: normal/overtime/insufficient/missing]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_st_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_st_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_segment_timing PRIMARY KEY (timing_id),
    CONSTRAINT ck_st_range CHECK (start_ms >= 0 AND end_ms > start_ms),
    CONSTRAINT ck_st_dur CHECK (duration_ms > 0),
    CONSTRAINT ck_st_ratio CHECK (actual_ratio >= 0 AND actual_ratio <= 1),
    CONSTRAINT ck_st_segment CHECK (segment IN ('intro', 'new_lesson', 'practice', 'summary', 'homework', 'other')),
    CONSTRAINT ck_st_deviation_flag CHECK (deviation_flag IN ('normal', 'overtime', 'insufficient', 'missing'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_st_report_segment' AND object_id = OBJECT_ID(N'evaluation.segment_timing'))
    CREATE UNIQUE INDEX uk_st_report_segment ON evaluation.segment_timing(report_id, segment);
GO

/* suggestion：E10 改进建议：四类建议与采纳回流 */
IF OBJECT_ID(N'evaluation.suggestion', N'U') IS NULL
CREATE TABLE evaluation.suggestion (
    suggestion_id            UNIQUEIDENTIFIER   NOT NULL,   -- 建议ID，UUID v4
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 所属报告ID，→evaluation.evaluation_report
    issue_id                 UNIQUEIDENTIFIER   NULL,   -- 关联问题ID，→evaluation.issue_item；整体建议为 NULL
    suggestion_type          NVARCHAR(14)       NOT NULL,   -- 类型：wording 优化话术/example_clip 示范片段/sentence_level 逐句建议/drill 专项练习  [枚举: wording/example_clip/sentence_level/drill]
    content_text             NVARCHAR(1000)     NOT NULL,   -- 建议内容，≤1000 字符
    original_text            NVARCHAR(MAX)      NULL,   -- ASR 原句；type=sentence_level 时必填
    optimized_text           NVARCHAR(MAX)      NULL,   -- AI 优化句；type∈(wording,sentence_level) 时必填
    sample_audio_url         NVARCHAR(512)      NULL,   -- TTS 示范音频 URL
    priority                 TINYINT            NOT NULL  CONSTRAINT df_sg_priority DEFAULT 3,   -- 优先级，1-5，1 最高
    is_accepted              BIT                NULL,   -- 学生是否采纳：1 是/0 否/NULL 未反馈
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sg_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_sg_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_suggestion PRIMARY KEY (suggestion_id),
    CONSTRAINT ck_sg_priority CHECK (priority BETWEEN 1 AND 5),
    CONSTRAINT ck_sg_opt CHECK (suggestion_type NOT IN ('wording','sentence_level') OR optimized_text IS NOT NULL),
    CONSTRAINT ck_sg_suggestion CHECK (suggestion_type IN ('wording', 'example_clip', 'sentence_level', 'drill'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sg_report_priority' AND object_id = OBJECT_ID(N'evaluation.suggestion'))
    CREATE INDEX idx_sg_report_priority ON evaluation.suggestion(report_id, priority);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_sg_issue' AND object_id = OBJECT_ID(N'evaluation.suggestion'))
    CREATE INDEX idx_sg_issue ON evaluation.suggestion(issue_id);
GO

/* teacher_review：F1 教师批阅：多教师批阅；仅有效主批分进入报告最终成绩 */
IF OBJECT_ID(N'evaluation.teacher_review', N'U') IS NULL
CREATE TABLE evaluation.teacher_review (
    review_id                UNIQUEIDENTIFIER   NOT NULL,   -- 批阅ID，UUID v4
    session_id               UNIQUEIDENTIFIER   NOT NULL,   -- 被批场次ID，→classroom.trial_session，冗余便于按场次查
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 关联报告ID，→evaluation.evaluation_report
    teacher_id               UNIQUEIDENTIFIER   NOT NULL,   -- 批阅教师档案ID，→identity_org.teacher_profile
    item_scores              NVARCHAR(MAX)      NULL,   -- 细则项得分对象 {item_id: score}，须覆盖 rubric_item；批量批阅可为 NULL
    total_score              DECIMAL(5,2)       NOT NULL,   -- 教师总分，0-100
    comment_text             NVARCHAR(2000)     NULL,   -- 文字点评，≤2000 字符
    voice_comment_url        NVARCHAR(512)      NULL,   -- 语音点评 URL，m4a ≤10MB，时长 ≤5 分钟
    [status]                 NVARCHAR(8)        NOT NULL  CONSTRAINT df_tr_status DEFAULT 'pending',   -- 状态：pending 待批阅/reviewed 已批阅/returned 退回重做  [枚举: pending/reviewed/returned]
    reviewed_at              DATETIME2(3)       NULL,   -- 批阅时间（UTC）；status=reviewed 时必填
    is_batch                 BIT                NOT NULL  CONSTRAINT df_tr_is_batch DEFAULT 0,   -- 是否批量批阅：1 是
    is_primary               BIT                NOT NULL  CONSTRAINT df_tr_is_primary DEFAULT 0,   -- 是否主批教师：1 是；每报告最多一名有效主批
    active_primary_report_id AS (CASE WHEN is_primary = 1 AND status <> 'returned' THEN report_id ELSE NULL END) PERSISTED,   -- 生成列，只读；有效主批唯一约束辅助列
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_tr_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_tr_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_teacher_review PRIMARY KEY (review_id),
    CONSTRAINT ck_tr_score CHECK (total_score BETWEEN 0 AND 100),
    CONSTRAINT ck_tr_time CHECK ([status] <> 'reviewed' OR reviewed_at IS NOT NULL),
    CONSTRAINT ck_tr_items CHECK (item_scores IS NULL OR ISJSON(item_scores) = 1),
    CONSTRAINT ck_tr_status CHECK ([status] IN ('pending', 'reviewed', 'returned'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_tr_report_teacher' AND object_id = OBJECT_ID(N'evaluation.teacher_review'))
    CREATE UNIQUE INDEX uk_tr_report_teacher ON evaluation.teacher_review(report_id, teacher_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_tr_active_primary' AND object_id = OBJECT_ID(N'evaluation.teacher_review'))
    CREATE UNIQUE INDEX uk_tr_active_primary ON evaluation.teacher_review(active_primary_report_id) WHERE active_primary_report_id IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_tr_teacher_status' AND object_id = OBJECT_ID(N'evaluation.teacher_review'))
    CREATE INDEX idx_tr_teacher_status ON evaluation.teacher_review(teacher_id, [status]);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_tr_session' AND object_id = OBJECT_ID(N'evaluation.teacher_review'))
    CREATE INDEX idx_tr_session ON evaluation.teacher_review(session_id);
GO


/* ==========================================================================
   Schema growth_cert（10 表）
   ========================================================================== */

/* training_record：G1 训练记录：阶梯训练完成留痕与推荐回流 */
IF OBJECT_ID(N'growth_cert.training_record', N'U') IS NULL
CREATE TABLE growth_cert.training_record (
    train_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 训练ID，UUID v4
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 训练人用户ID，→identity_org.user
    train_mode               NVARCHAR(10)       NOT NULL,   -- 训练模式：shadowing 跟读训练/full_trial 无提示完整试讲/scenario 突发情景模拟/mock_exam 模拟考核  [枚举: shadowing/full_trial/scenario/mock_exam]
    [level]                  NVARCHAR(12)       NOT NULL,   -- 阶梯层级：entry 入门/intermediate 进阶/advanced 高阶/exam 考核  [枚举: entry/intermediate/advanced/exam]
    material_type            NVARCHAR(12)       NULL,   -- 素材类型，配合 material_id 实现多态引用  [枚举: follow_along/trial_topic/scenario]
    material_id              UNIQUEIDENTIFIER   NULL,   -- 训练素材ID：→follow_along_material / trial_topic / scenario；跟读与情景模式必填
    duration_ms              INT                NOT NULL,   -- 训练时长（毫秒），>0
    score                    DECIMAL(5,2)       NULL,   -- 训练得分，0-100；跟读训练为发音分
    session_id               UNIQUEIDENTIFIER   NULL,   -- 关联场次ID，→classroom.trial_session；完整试讲/情景/考核时写入
    completed_at             DATETIME2(3)       NOT NULL,   -- 完成时间（UTC）
    next_recommend           NVARCHAR(MAX)      NULL,   -- 下一步推荐：{train_mode, material_id, reason}
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_train_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_train_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_training_record PRIMARY KEY (train_id),
    CONSTRAINT ck_train_duration CHECK (duration_ms > 0),
    CONSTRAINT ck_train_score CHECK (score IS NULL OR score BETWEEN 0 AND 100),
    CONSTRAINT ck_train_material CHECK (train_mode = 'full_trial' OR (material_type IS NOT NULL AND material_id IS NOT NULL)),
    CONSTRAINT ck_train_train_mode CHECK (train_mode IN ('shadowing', 'full_trial', 'scenario', 'mock_exam')),
    CONSTRAINT ck_train_level CHECK ([level] IN ('entry', 'intermediate', 'advanced', 'exam')),
    CONSTRAINT ck_train_material_enum CHECK (material_type IS NULL OR material_type IN ('follow_along', 'trial_topic', 'scenario'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_tr_user_time' AND object_id = OBJECT_ID(N'growth_cert.training_record'))
    CREATE INDEX idx_tr_user_time ON growth_cert.training_record(user_id, completed_at DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_tr_material' AND object_id = OBJECT_ID(N'growth_cert.training_record'))
    CREATE INDEX idx_tr_material ON growth_cert.training_record(material_type, material_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_tr_session' AND object_id = OBJECT_ID(N'growth_cert.training_record'))
    CREATE INDEX idx_tr_session ON growth_cert.training_record(session_id);
GO

/* follow_along_material：G2 跟读训练素材：入门级训练内容源 */
IF OBJECT_ID(N'growth_cert.follow_along_material', N'U') IS NULL
CREATE TABLE growth_cert.follow_along_material (
    material_id              UNIQUEIDENTIFIER   NOT NULL,   -- 素材ID，UUID v4
    subject_id               UNIQUEIDENTIFIER   NULL,   -- 学科ID，→identity_org.subject，NULL=通用
    stage                    NVARCHAR(11)       NULL,   -- 学段，NULL=通用  [枚举: preschool/primary/junior_high/senior_high/vocational]
    material_text            NVARCHAR(1000)     NOT NULL,   -- 跟读文本，≤1000 字符
    audio_url                NVARCHAR(512)      NOT NULL,   -- 标准音频 URL，m4a/mp3
    focus                    NVARCHAR(13)       NOT NULL,   -- 训练重点：语音/语调/语速/停顿/重音  [枚举: pronunciation/intonation/speed/pause/stress]
    difficulty               TINYINT            NOT NULL,   -- 难度 1-5
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_fam_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_fam_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    deleted_at               DATETIME2(3)       NULL,   -- 软删除时间，NULL=有效
    CONSTRAINT pk_follow_along_material PRIMARY KEY (material_id),
    CONSTRAINT ck_fam_difficulty CHECK (difficulty BETWEEN 1 AND 5),
    CONSTRAINT ck_fam_stage CHECK (stage IS NULL OR stage IN ('preschool', 'primary', 'junior_high', 'senior_high', 'vocational')),
    CONSTRAINT ck_fam_focus CHECK (focus IN ('pronunciation', 'intonation', 'speed', 'pause', 'stress'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_fam_subject_stage' AND object_id = OBJECT_ID(N'growth_cert.follow_along_material'))
    CREATE INDEX idx_fam_subject_stage ON growth_cert.follow_along_material(subject_id, stage, difficulty);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_fam_focus' AND object_id = OBJECT_ID(N'growth_cert.follow_along_material'))
    CREATE INDEX idx_fam_focus ON growth_cert.follow_along_material(focus);
GO

/* mock_exam：G3 模拟考核：全真计时考核与发证资格判定 */
IF OBJECT_ID(N'growth_cert.mock_exam', N'U') IS NULL
CREATE TABLE growth_cert.mock_exam (
    exam_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 考核ID，UUID v4
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 考生用户ID，→identity_org.user
    task_id                  UNIQUEIDENTIFIER   NULL,   -- 关联任务ID，→task_content.trial_task，NULL=自主考核
    countdown_s              INT                NOT NULL,   -- 倒计时（秒）：备课 1200/试讲 600/答辩 300
    examiner_rubric_id       UNIQUEIDENTIFIER   NOT NULL,   -- 考官评分表ID，→task_content.rubric
    full_video_required      BIT                NOT NULL  CONSTRAINT df_me_full_video_require DEFAULT 1,   -- 须全程录像：1 是
    final_score              DECIMAL(5,2)       NULL,   -- 考核得分，0-100；未评分为 NULL
    result                   NVARCHAR(4)        NULL,   -- 考核结果：pass 通过/fail 不通过；未评分为 NULL  [枚举: pass/fail]
    cert_eligible            BIT                NOT NULL  CONSTRAINT df_me_cert_eligible DEFAULT 0,   -- 是否具备发证资格：1 是
    exam_at                  DATETIME2(3)       NOT NULL,   -- 考核时间（UTC）
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_me_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_me_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_mock_exam PRIMARY KEY (exam_id),
    CONSTRAINT ck_me_countdown CHECK (countdown_s > 0),
    CONSTRAINT ck_me_score CHECK (final_score IS NULL OR final_score BETWEEN 0 AND 100),
    CONSTRAINT ck_me_result CHECK (result IS NULL OR result IN ('pass', 'fail'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_me_user_time' AND object_id = OBJECT_ID(N'growth_cert.mock_exam'))
    CREATE INDEX idx_me_user_time ON growth_cert.mock_exam(user_id, exam_at DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_me_task' AND object_id = OBJECT_ID(N'growth_cert.mock_exam'))
    CREATE INDEX idx_me_task ON growth_cert.mock_exam(task_id);
GO

/* mock_exam_question：R7 考核-题目关系：承载 G3.question_ids，支持混合抽题 */
IF OBJECT_ID(N'growth_cert.mock_exam_question', N'U') IS NULL
CREATE TABLE growth_cert.mock_exam_question (
    exam_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 考核ID，→growth_cert.mock_exam
    question_type            NVARCHAR(10)       NOT NULL,   -- 题目类型：structured 结构化题/topic 试讲题  [枚举: structured/topic]
    question_id              UNIQUEIDENTIFIER   NOT NULL,   -- 题目ID：→task_content.structured_question 或 trial_topic
    seq                      TINYINT            NOT NULL  CONSTRAINT df_meq_seq DEFAULT 1,   -- 抽题顺序，1 起
    CONSTRAINT pk_mock_exam_question PRIMARY KEY (exam_id, question_type, question_id),
    CONSTRAINT ck_meq_seq CHECK (seq >= 1),
    CONSTRAINT ck_meq_question CHECK (question_type IN ('structured', 'topic'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_meq_question' AND object_id = OBJECT_ID(N'growth_cert.mock_exam_question'))
    CREATE INDEX idx_meq_question ON growth_cert.mock_exam_question(question_type, question_id);
GO

/* class_stats：H1 班级统计：T+1 物化，支撑班级看板 */
IF OBJECT_ID(N'growth_cert.class_stats', N'U') IS NULL
CREATE TABLE growth_cert.class_stats (
    stat_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 统计ID，UUID v4
    class_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 班级ID，→identity_org.class
    period_type              NVARCHAR(5)        NOT NULL,   -- 统计周期：日/周/月/学期  [枚举: day/week/month/term]
    period_key               NVARCHAR(20)       NOT NULL,   -- 周期键：2026-10-25 / 2026-W43 / 2026-10 / 2026-S1
    avg_score                DECIMAL(5,2)       NULL,   -- 平均分，0-100
    dimension_avgs           NVARCHAR(MAX)      NULL,   -- 六维均值对象 {dimension: score}
    weakest_dimension        NVARCHAR(15)       NULL,   -- 最薄弱维度：六维之一  [枚举: content/expression/posture/interaction/board_ppt/time_management]
    submission_rate          DECIMAL(4,3)       NULL,   -- 提交率，0-1
    active_count             SMALLINT           NOT NULL  CONSTRAINT df_cs_active_count DEFAULT 0,   -- 活跃人数，≥0
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_cs_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_cs_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_class_stats PRIMARY KEY (stat_id),
    CONSTRAINT ck_cs_rate CHECK (submission_rate IS NULL OR (submission_rate >= 0 AND submission_rate <= 1)),
    CONSTRAINT ck_cs_period CHECK (period_type IN ('day', 'week', 'month', 'term')),
    CONSTRAINT ck_cs_weakest_dimension CHECK (weakest_dimension IS NULL OR weakest_dimension IN ('content', 'expression', 'posture', 'interaction', 'board_ppt', 'time_management'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_cs_class_period' AND object_id = OBJECT_ID(N'growth_cert.class_stats'))
    CREATE UNIQUE INDEX uk_cs_class_period ON growth_cert.class_stats(class_id, period_type, period_key);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_cs_period' AND object_id = OBJECT_ID(N'growth_cert.class_stats'))
    CREATE INDEX idx_cs_period ON growth_cert.class_stats(period_type, period_key);
GO

/* leaderboard：H2 排行榜：周期重建，Redis ZSet 为实时镜像 */
IF OBJECT_ID(N'growth_cert.leaderboard', N'U') IS NULL
CREATE TABLE growth_cert.leaderboard (
    lb_id                    UNIQUEIDENTIFIER   NOT NULL,   -- 榜单记录ID，UUID v4
    scope                    NVARCHAR(6)        NOT NULL,   -- 榜单范围：class 班级/grade 年级/major 专业/school 全校  [枚举: class/grade/major/school]
    scope_id                 UNIQUEIDENTIFIER   NOT NULL,   -- 范围ID：class→class_id，major→major_id，school→school_id，grade→identity_org.dim_grade.grade_id（按入学届次）
    period_key               NVARCHAR(20)       NOT NULL,   -- 周期键：2026-W43 / 2026-10 / 2026-S1
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 上榜人用户ID，→identity_org.user
    rank_no                  SMALLINT           NOT NULL,   -- 名次，≥1；列名避开 RANK 窗口函数关键字
    score                    DECIMAL(5,2)       NOT NULL,   -- 榜单分数，0-100
    improvement_delta        DECIMAL(5,2)       NULL,   -- 进步幅度，可正可负，与上一周期对比
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_lb_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_lb_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_leaderboard PRIMARY KEY (lb_id),
    CONSTRAINT ck_lb_rank CHECK (rank_no >= 1),
    CONSTRAINT ck_lb_score CHECK (score BETWEEN 0 AND 100),
    CONSTRAINT ck_lb_scope CHECK (scope IN ('class', 'grade', 'major', 'school'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_lb_member' AND object_id = OBJECT_ID(N'growth_cert.leaderboard'))
    CREATE UNIQUE INDEX uk_lb_member ON growth_cert.leaderboard(scope, scope_id, period_key, user_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_lb_rank' AND object_id = OBJECT_ID(N'growth_cert.leaderboard'))
    CREATE INDEX idx_lb_rank ON growth_cert.leaderboard(scope, scope_id, period_key, rank_no);
GO

/* certificate：H3 达标证书：永久留存，仅可撤销不可删除 */
IF OBJECT_ID(N'growth_cert.certificate', N'U') IS NULL
CREATE TABLE growth_cert.certificate (
    cert_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 证书ID，UUID v4
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 持证人用户ID，→identity_org.user
    skill                    NVARCHAR(13)       NOT NULL,   -- 认证技能：教学表达/课堂互动/课堂控场/时间管理/板书呈现/综合教学能力  [枚举: expression/interaction/control/timing/board/comprehensive]
    [level]                  NVARCHAR(9)        NOT NULL,   -- 等级：pass 达标/good 良好/excellent 优秀  [枚举: pass/good/excellent]
    threshold_score          DECIMAL(5,2)       NOT NULL,   -- 达标分数线，0-100，管理员可配
    serial_no                NVARCHAR(30)       NOT NULL,   -- 证书编号，CERT-YYYYMM-8位随机，全局唯一，永不复用
    issue_date               DATE               NOT NULL,   -- 发证日期
    expire_date              DATE               NULL,   -- 有效期至，默认发证日 +2 年；NULL=长期有效
    verify_url               NVARCHAR(512)      NOT NULL,   -- 公开验真地址，扫码可查
    [status]                 NVARCHAR(7)        NOT NULL  CONSTRAINT df_cert_status DEFAULT 'valid',   -- 状态：valid 有效/expired 已过期/revoked 已撤销  [枚举: valid/expired/revoked]
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_cert_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_cert_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_certificate PRIMARY KEY (cert_id),
    CONSTRAINT ck_cert_threshold CHECK (threshold_score BETWEEN 0 AND 100),
    CONSTRAINT ck_cert_expire CHECK (expire_date IS NULL OR expire_date > issue_date),
    CONSTRAINT ck_cert_skill CHECK (skill IN ('expression', 'interaction', 'control', 'timing', 'board', 'comprehensive')),
    CONSTRAINT ck_cert_level CHECK ([level] IN ('pass', 'good', 'excellent')),
    CONSTRAINT ck_cert_status CHECK ([status] IN ('valid', 'expired', 'revoked'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_cert_serial' AND object_id = OBJECT_ID(N'growth_cert.certificate'))
    CREATE UNIQUE INDEX uk_cert_serial ON growth_cert.certificate(serial_no);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_cert_user_status' AND object_id = OBJECT_ID(N'growth_cert.certificate'))
    CREATE INDEX idx_cert_user_status ON growth_cert.certificate(user_id, [status]);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_cert_verify' AND object_id = OBJECT_ID(N'growth_cert.certificate'))
    CREATE INDEX idx_cert_verify ON growth_cert.certificate(serial_no, [status]);
GO

/* certificate_report：R8 证书-佐证报告关系：承载 H3.evidence_report_ids */
IF OBJECT_ID(N'growth_cert.certificate_report', N'U') IS NULL
CREATE TABLE growth_cert.certificate_report (
    cert_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 证书ID，→growth_cert.certificate
    report_id                UNIQUEIDENTIFIER   NOT NULL,   -- 佐证报告ID，→evaluation.evaluation_report，至少 1 条
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_cr_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    CONSTRAINT pk_certificate_report PRIMARY KEY (cert_id, report_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_cr_report' AND object_id = OBJECT_ID(N'growth_cert.certificate_report'))
    CREATE INDEX idx_cr_report ON growth_cert.certificate_report(report_id);
GO

/* progress_record：H4 进步曲线：按维度按日的得分快照 */
IF OBJECT_ID(N'growth_cert.progress_record', N'U') IS NULL
CREATE TABLE growth_cert.progress_record (
    progress_id              UNIQUEIDENTIFIER   NOT NULL,   -- 记录ID，UUID v4
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 用户ID，→identity_org.user
    dimension                NVARCHAR(15)       NOT NULL,   -- 维度：六维之一，overall 为综合  [枚举: content/expression/posture/interaction/board_ppt/time_management/overall]
    stat_date                DATE               NOT NULL,   -- 统计日期
    score                    DECIMAL(5,2)       NOT NULL,   -- 得分，0-100，当日均分或综合分
    session_count            INT                NOT NULL  CONSTRAINT df_pr_session_count DEFAULT 0,   -- 累计试讲次数，≥0
    delta_vs_last            DECIMAL(5,2)       NULL,   -- 环比变化，可正可负，与上一统计日对比
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_pr_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    CONSTRAINT pk_progress_record PRIMARY KEY (progress_id),
    CONSTRAINT ck_pr_score CHECK (score BETWEEN 0 AND 100),
    CONSTRAINT ck_pr_count CHECK (session_count >= 0),
    CONSTRAINT ck_pr_dimension CHECK (dimension IN ('content', 'expression', 'posture', 'interaction', 'board_ppt', 'time_management', 'overall'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uk_pr_user_dim_date' AND object_id = OBJECT_ID(N'growth_cert.progress_record'))
    CREATE UNIQUE INDEX uk_pr_user_dim_date ON growth_cert.progress_record(user_id, dimension, stat_date);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_pr_user_date' AND object_id = OBJECT_ID(N'growth_cert.progress_record'))
    CREATE INDEX idx_pr_user_date ON growth_cert.progress_record(user_id, stat_date DESC);
GO

/* weakness_push：H5 薄弱项与专项推送：训练闭环的推与评 */
IF OBJECT_ID(N'growth_cert.weakness_push', N'U') IS NULL
CREATE TABLE growth_cert.weakness_push (
    push_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 推送ID，UUID v4
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 用户ID，→identity_org.user
    dimension                NVARCHAR(15)       NOT NULL,   -- 薄弱维度：六维之一  [枚举: content/expression/posture/interaction/board_ppt/time_management]
    issue_type               NVARCHAR(24)       NULL,   -- 薄弱问题类型，取值同 issue_item.issue_type  [枚举: fast_speech/slow_speech/filler_word/wrong_knowledge/incomplete_explanation/unclear_logic/insufficient_interaction/poor_questioning/missing_feedback/undisciplined/unclear_board/poor_handwriting/ppt_overreliance/segment_overtime/segment_missing/eye_avoidance/unstable_posture/low_volume]
    severity                 NVARCHAR(4)        NOT NULL  CONSTRAINT df_wp_severity DEFAULT 'mid',   -- 严重程度：high/mid/low  [枚举: high/mid/low]
    recommend_train_mode     NVARCHAR(10)       NOT NULL,   -- 推荐训练模式：跟读训练/无提示完整试讲/突发情景模拟  [枚举: shadowing/full_trial/scenario]
    recommend_material_type  NVARCHAR(12)       NULL,   -- 推荐素材类型，配合 recommend_material_id  [枚举: follow_along/trial_topic/scenario]
    recommend_material_id    UNIQUEIDENTIFIER   NULL,   -- 推荐素材ID
    pushed_at                DATETIME2(3)       NOT NULL,   -- 推送时间（UTC），频次控制与防骚扰依据
    is_clicked               BIT                NOT NULL  CONSTRAINT df_wp_is_clicked DEFAULT 0,   -- 是否点击：1 是
    is_resolved              BIT                NOT NULL  CONSTRAINT df_wp_is_resolved DEFAULT 0,   -- 是否改善：1 是
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_wp_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_wp_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_weakness_push PRIMARY KEY (push_id),
    CONSTRAINT ck_wp_material CHECK (recommend_material_type IS NULL OR recommend_material_id IS NOT NULL),
    CONSTRAINT ck_wp_dimension CHECK (dimension IN ('content', 'expression', 'posture', 'interaction', 'board_ppt', 'time_management')),
    CONSTRAINT ck_wp_issue CHECK (issue_type IS NULL OR issue_type IN ('fast_speech', 'slow_speech', 'filler_word', 'wrong_knowledge', 'incomplete_explanation', 'unclear_logic', 'insufficient_interaction', 'poor_questioning', 'missing_feedback', 'undisciplined', 'unclear_board', 'poor_handwriting', 'ppt_overreliance', 'segment_overtime', 'segment_missing', 'eye_avoidance', 'unstable_posture', 'low_volume')),
    CONSTRAINT ck_wp_severity CHECK (severity IN ('high', 'mid', 'low')),
    CONSTRAINT ck_wp_recommend_train_mode CHECK (recommend_train_mode IN ('shadowing', 'full_trial', 'scenario')),
    CONSTRAINT ck_wp_recommend_material CHECK (recommend_material_type IS NULL OR recommend_material_type IN ('follow_along', 'trial_topic', 'scenario'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_wp_user_time' AND object_id = OBJECT_ID(N'growth_cert.weakness_push'))
    CREATE INDEX idx_wp_user_time ON growth_cert.weakness_push(user_id, pushed_at DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_wp_user_dim' AND object_id = OBJECT_ID(N'growth_cert.weakness_push'))
    CREATE INDEX idx_wp_user_dim ON growth_cert.weakness_push(user_id, dimension, is_resolved);
GO


/* ==========================================================================
   Schema platform（2 表）
   ========================================================================== */

/* export_task：I1 导出任务：异步入队生成，产物 7 天过期 */
IF OBJECT_ID(N'platform.export_task', N'U') IS NULL
CREATE TABLE platform.export_task (
    export_id                UNIQUEIDENTIFIER   NOT NULL,   -- 导出ID，UUID v4
    operator_id              UNIQUEIDENTIFIER   NOT NULL,   -- 操作人用户ID，→identity_org.user（教师/管理员）
    export_scope             NVARCHAR(15)       NOT NULL,   -- 导出范围：班级成绩/训练报告/排行榜/学生个人档案/评测明细  [枚举: class_score/training_report/leaderboard/student_profile/eval_detail]
    filter_cond              NVARCHAR(MAX)      NULL,   -- 过滤条件：{class_id, date_from, date_to, task_id, dimension}；列名避开 FILTER 关键字
    export_format            NVARCHAR(4)        NOT NULL,   -- 导出格式：xlsx/csv/pdf；列名避开 FORMAT 函数名  [枚举: xlsx/csv/pdf]
    file_url                 NVARCHAR(512)      NULL,   -- 结果文件 URL；status=success 时必填
    [status]                 NVARCHAR(10)       NOT NULL  CONSTRAINT df_et_status DEFAULT 'queued',   -- 状态：queued 排队中/generating 生成中/success 成功/failed 失败  [枚举: queued/generating/success/failed]
    error                    NVARCHAR(500)      NULL,   -- 失败原因；status=failed 时必填。V1.1 新增（对应 11 §2.7 响应字段）
    expire_at                DATETIME2(3)       NOT NULL,   -- 过期时间（UTC），默认生成时间 +7 天
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_et_created_at DEFAULT SYSUTCDATETIME(),   -- 创建时间（UTC）
    updated_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_et_updated_at DEFAULT SYSUTCDATETIME(),   -- 更新时间（UTC）
    CONSTRAINT pk_export_task PRIMARY KEY (export_id),
    CONSTRAINT ck_et_file CHECK ([status] <> 'success' OR file_url IS NOT NULL),
    CONSTRAINT ck_et_error CHECK ([status] <> 'failed' OR error IS NOT NULL),
    CONSTRAINT ck_et_filter CHECK (filter_cond IS NULL OR ISJSON(filter_cond) = 1),
    CONSTRAINT ck_et_export_scope CHECK (export_scope IN ('class_score', 'training_report', 'leaderboard', 'student_profile', 'eval_detail')),
    CONSTRAINT ck_et_export_format CHECK (export_format IN ('xlsx', 'csv', 'pdf')),
    CONSTRAINT ck_et_status CHECK ([status] IN ('queued', 'generating', 'success', 'failed'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_et_operator_time' AND object_id = OBJECT_ID(N'platform.export_task'))
    CREATE INDEX idx_et_operator_time ON platform.export_task(operator_id, created_at DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_et_status' AND object_id = OBJECT_ID(N'platform.export_task'))
    CREATE INDEX idx_et_status ON platform.export_task([status]);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_et_expire' AND object_id = OBJECT_ID(N'platform.export_task'))
    CREATE INDEX idx_et_expire ON platform.export_task(expire_at);
GO

/* audit_log：I2 审计日志：只追加，不可篡改，保留 180 天 */
IF OBJECT_ID(N'platform.audit_log', N'U') IS NULL
CREATE TABLE platform.audit_log (
    log_id                   UNIQUEIDENTIFIER   NOT NULL,   -- 日志ID，UUID v7
    user_id                  UNIQUEIDENTIFIER   NOT NULL,   -- 操作人用户ID，→identity_org.user
    [action]                 NVARCHAR(17)       NOT NULL,   -- 操作类型：登录/发布任务/修改评分/批阅/导出/删除录制/撤销证书/变更权限  [枚举: login/publish_task/modify_score/review/export/delete_recording/revoke_cert/change_permission]
    target_type              NVARCHAR(30)       NOT NULL,   -- 对象类型，如 trial_task / certificate / recording
    target_id                UNIQUEIDENTIFIER   NOT NULL,   -- 对象ID
    ip                       NVARCHAR(45)       NULL,   -- 客户端 IP，支持 IPv6
    user_agent               NVARCHAR(255)      NULL,   -- 客户端 UA，环境追溯
    created_at               DATETIME2(3)       NOT NULL  CONSTRAINT df_al_created_at DEFAULT SYSUTCDATETIME(),   -- 操作时间（UTC）
    CONSTRAINT pk_audit_log PRIMARY KEY (log_id),
    CONSTRAINT ck_al_action CHECK ([action] IN ('login', 'publish_task', 'modify_score', 'review', 'export', 'delete_recording', 'revoke_cert', 'change_permission'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_al_user_time' AND object_id = OBJECT_ID(N'platform.audit_log'))
    CREATE INDEX idx_al_user_time ON platform.audit_log(user_id, created_at DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_al_target' AND object_id = OBJECT_ID(N'platform.audit_log'))
    CREATE INDEX idx_al_target ON platform.audit_log(target_type, target_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_al_action_time' AND object_id = OBJECT_ID(N'platform.audit_log'))
    CREATE INDEX idx_al_action_time ON platform.audit_log([action], created_at);
GO


/* 外键（统一在建表后 ALTER 添加，便于依赖排序与级联降级） */

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sp_user')
    ALTER TABLE identity_org.student_profile ADD CONSTRAINT fk_sp_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sp_major')
    ALTER TABLE identity_org.student_profile ADD CONSTRAINT fk_sp_major FOREIGN KEY (major_id) REFERENCES identity_org.major(major_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sp_class')
    ALTER TABLE identity_org.student_profile ADD CONSTRAINT fk_sp_class FOREIGN KEY (class_id) REFERENCES identity_org.[class](class_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sp_subj')
    ALTER TABLE identity_org.student_profile ADD CONSTRAINT fk_sp_subj FOREIGN KEY (subject_id) REFERENCES identity_org.subject(subject_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_tp_user')
    ALTER TABLE identity_org.teacher_profile ADD CONSTRAINT fk_tp_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cg_class')
    ALTER TABLE identity_org.class_group ADD CONSTRAINT fk_cg_class FOREIGN KEY (class_id) REFERENCES identity_org.[class](class_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cg_leader')
    ALTER TABLE identity_org.class_group ADD CONSTRAINT fk_cg_leader FOREIGN KEY (leader_id) REFERENCES identity_org.student_profile(profile_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_consent_user')
    ALTER TABLE identity_org.consent_record ADD CONSTRAINT fk_consent_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_ct_class')
    ALTER TABLE identity_org.class_teacher ADD CONSTRAINT fk_ct_class FOREIGN KEY (class_id) REFERENCES identity_org.[class](class_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_ct_teacher')
    ALTER TABLE identity_org.class_teacher ADD CONSTRAINT fk_ct_teacher FOREIGN KEY (teacher_id) REFERENCES identity_org.teacher_profile(teacher_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_ts_teacher')
    ALTER TABLE identity_org.teacher_subject ADD CONSTRAINT fk_ts_teacher FOREIGN KEY (teacher_id) REFERENCES identity_org.teacher_profile(teacher_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_ts_subject')
    ALTER TABLE identity_org.teacher_subject ADD CONSTRAINT fk_ts_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject(subject_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cgm_group')
    ALTER TABLE identity_org.class_group_member ADD CONSTRAINT fk_cgm_group FOREIGN KEY (group_id) REFERENCES identity_org.class_group(group_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cgm_profile')
    ALTER TABLE identity_org.class_group_member ADD CONSTRAINT fk_cgm_profile FOREIGN KEY (profile_id) REFERENCES identity_org.student_profile(profile_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_rubric_subject')
    ALTER TABLE task_content.rubric ADD CONSTRAINT fk_rubric_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject(subject_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_ri_rubric')
    ALTER TABLE task_content.rubric_item ADD CONSTRAINT fk_ri_rubric FOREIGN KEY (rubric_id) REFERENCES task_content.rubric(rubric_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_task_publisher')
    ALTER TABLE task_content.trial_task ADD CONSTRAINT fk_task_publisher FOREIGN KEY (publisher_id) REFERENCES identity_org.teacher_profile(teacher_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_task_subject')
    ALTER TABLE task_content.trial_task ADD CONSTRAINT fk_task_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject(subject_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_task_rubric')
    ALTER TABLE task_content.trial_task ADD CONSTRAINT fk_task_rubric FOREIGN KEY (rubric_id) REFERENCES task_content.rubric(rubric_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_topic_subject')
    ALTER TABLE task_content.trial_topic ADD CONSTRAINT fk_topic_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject(subject_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_lt_subject')
    ALTER TABLE task_content.lesson_template ADD CONSTRAINT fk_lt_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject(subject_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_ex_topic')
    ALTER TABLE task_content.exemplar ADD CONSTRAINT fk_ex_topic FOREIGN KEY (topic_id) REFERENCES task_content.trial_topic(topic_id) ON DELETE SET NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_tc_task')
    ALTER TABLE task_content.task_class ADD CONSTRAINT fk_tc_task FOREIGN KEY (task_id) REFERENCES task_content.trial_task(task_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_tc_class')
    ALTER TABLE task_content.task_class ADD CONSTRAINT fk_tc_class FOREIGN KEY (class_id) REFERENCES identity_org.[class](class_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_tt_task')
    ALTER TABLE task_content.task_topic ADD CONSTRAINT fk_tt_task FOREIGN KEY (task_id) REFERENCES task_content.trial_task(task_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_tt_topic')
    ALTER TABLE task_content.task_topic ADD CONSTRAINT fk_tt_topic FOREIGN KEY (topic_id) REFERENCES task_content.trial_topic(topic_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sc_subject')
    ALTER TABLE classroom.scenario ADD CONSTRAINT fk_sc_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject(subject_id) ON DELETE SET NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sess_task')
    ALTER TABLE classroom.trial_session ADD CONSTRAINT fk_sess_task FOREIGN KEY (task_id) REFERENCES task_content.trial_task(task_id) ON DELETE SET NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sess_user')
    ALTER TABLE classroom.trial_session ADD CONSTRAINT fk_sess_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sess_scenario')
    ALTER TABLE classroom.trial_session ADD CONSTRAINT fk_sess_scenario FOREIGN KEY (scenario_id) REFERENCES classroom.scenario(scenario_id) ON DELETE SET NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sess_topic')
    ALTER TABLE classroom.trial_session ADD CONSTRAINT fk_sess_topic FOREIGN KEY (topic_id) REFERENCES task_content.trial_topic(topic_id) ON DELETE SET NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sess_sq')
    ALTER TABLE classroom.trial_session ADD CONSTRAINT fk_sess_sq FOREIGN KEY (structured_q_id) REFERENCES task_content.structured_question(q_id) ON DELETE SET NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sess_consent')
    ALTER TABLE classroom.trial_session ADD CONSTRAINT fk_sess_consent FOREIGN KEY (consent_id) REFERENCES identity_org.consent_record(consent_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_vs_session')
    ALTER TABLE classroom.virtual_student ADD CONSTRAINT fk_vs_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session(session_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_rec_session')
    ALTER TABLE media.recording ADD CONSTRAINT fk_rec_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session(session_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_recording')
    ALTER TABLE media.playback_marker ADD CONSTRAINT fk_pm_recording FOREIGN KEY (recording_id) REFERENCES media.recording(recording_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_ob_session')
    ALTER TABLE media.observation ADD CONSTRAINT fk_ob_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session(session_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_ob_teacher')
    ALTER TABLE media.observation ADD CONSTRAINT fk_ob_teacher FOREIGN KEY (teacher_id) REFERENCES identity_org.teacher_profile(teacher_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_report_session')
    ALTER TABLE evaluation.evaluation_report ADD CONSTRAINT fk_report_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session(session_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_report_user')
    ALTER TABLE evaluation.evaluation_report ADD CONSTRAINT fk_report_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_report_rubric')
    ALTER TABLE evaluation.evaluation_report ADD CONSTRAINT fk_report_rubric FOREIGN KEY (rubric_id) REFERENCES task_content.rubric(rubric_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_ds_report')
    ALTER TABLE evaluation.dimension_score ADD CONSTRAINT fk_ds_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_ii_report')
    ALTER TABLE evaluation.issue_item ADD CONSTRAINT fk_ii_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_fwh_report')
    ALTER TABLE evaluation.filler_word_hit ADD CONSTRAINT fk_fwh_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sm_report')
    ALTER TABLE evaluation.speech_metric ADD CONSTRAINT fk_sm_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm2_report')
    ALTER TABLE evaluation.posture_metric ADD CONSTRAINT fk_pm2_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_vam_report')
    ALTER TABLE evaluation.visual_aid_metric ADD CONSTRAINT fk_vam_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_im_report')
    ALTER TABLE evaluation.interaction_metric ADD CONSTRAINT fk_im_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_st_report')
    ALTER TABLE evaluation.segment_timing ADD CONSTRAINT fk_st_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sg_report')
    ALTER TABLE evaluation.suggestion ADD CONSTRAINT fk_sg_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_sg_issue')
    ALTER TABLE evaluation.suggestion ADD CONSTRAINT fk_sg_issue FOREIGN KEY (issue_id) REFERENCES evaluation.issue_item(issue_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_tr_report')
    ALTER TABLE evaluation.teacher_review ADD CONSTRAINT fk_tr_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_tr_session')
    ALTER TABLE evaluation.teacher_review ADD CONSTRAINT fk_tr_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session(session_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_tr_teacher')
    ALTER TABLE evaluation.teacher_review ADD CONSTRAINT fk_tr_teacher FOREIGN KEY (teacher_id) REFERENCES identity_org.teacher_profile(teacher_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_train_user')
    ALTER TABLE growth_cert.training_record ADD CONSTRAINT fk_train_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_train_session')
    ALTER TABLE growth_cert.training_record ADD CONSTRAINT fk_train_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session(session_id) ON DELETE SET NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_fam_subject')
    ALTER TABLE growth_cert.follow_along_material ADD CONSTRAINT fk_fam_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject(subject_id) ON DELETE SET NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_me_user')
    ALTER TABLE growth_cert.mock_exam ADD CONSTRAINT fk_me_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_me_task')
    ALTER TABLE growth_cert.mock_exam ADD CONSTRAINT fk_me_task FOREIGN KEY (task_id) REFERENCES task_content.trial_task(task_id) ON DELETE SET NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_me_rubric')
    ALTER TABLE growth_cert.mock_exam ADD CONSTRAINT fk_me_rubric FOREIGN KEY (examiner_rubric_id) REFERENCES task_content.rubric(rubric_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_meq_exam')
    ALTER TABLE growth_cert.mock_exam_question ADD CONSTRAINT fk_meq_exam FOREIGN KEY (exam_id) REFERENCES growth_cert.mock_exam(exam_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cs_class')
    ALTER TABLE growth_cert.class_stats ADD CONSTRAINT fk_cs_class FOREIGN KEY (class_id) REFERENCES identity_org.[class](class_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_lb_user')
    ALTER TABLE growth_cert.leaderboard ADD CONSTRAINT fk_lb_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cert_user')
    ALTER TABLE growth_cert.certificate ADD CONSTRAINT fk_cert_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cr_cert')
    ALTER TABLE growth_cert.certificate_report ADD CONSTRAINT fk_cr_cert FOREIGN KEY (cert_id) REFERENCES growth_cert.certificate(cert_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cr_report')
    ALTER TABLE growth_cert.certificate_report ADD CONSTRAINT fk_cr_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report(report_id) ON DELETE NO ACTION;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pr_user')
    ALTER TABLE growth_cert.progress_record ADD CONSTRAINT fk_pr_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_wp_user')
    ALTER TABLE growth_cert.weakness_push ADD CONSTRAINT fk_wp_user FOREIGN KEY (user_id) REFERENCES identity_org.[user](user_id) ON DELETE CASCADE;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_et_operator')
    ALTER TABLE platform.export_task ADD CONSTRAINT fk_et_operator FOREIGN KEY (operator_id) REFERENCES identity_org.[user](user_id) ON DELETE NO ACTION;
GO

PRINT N'ai_teach SQL Server DDL 执行完成';
GO
