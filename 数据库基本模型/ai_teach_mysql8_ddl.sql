-- =============================================================================
-- 【归档说明 · 2026-10-25】
-- 本文件是 V2.0 的 MySQL 8 物理模型，现已作为方言转换的**输入**归档保留，
-- 仅用于回归比对，不再作为交付事实源。
-- 当前唯一事实源：ai_teach_sqlserver_ddl.sql（由 build/mysql2sqlserver.py 自本文件机械转换）
-- 设计文档：build/gen.py 读取 build/_ss_model.json 生成，禁止手工修改。
-- =============================================================================

-- =====================================================================
-- 师范专业 AI 试讲台系统 · 数据库物理模型（MySQL 8.0.32+）
-- 上游基线：01-SRS v2.0 / 03-HLD v2.0 / 04-LLD v2.0 / 数据项清单与实体边界 v2.0
-- 物理事实源：本文件。文档、数据字典、迁移脚本均由本文件派生，不得单独修改。
-- 约定：库 = 限界上下文；表名 snake_case 单数；主键 <实体>_id；全库 time_zone='+00:00'
-- =====================================================================

SET NAMES utf8mb4;
SET SESSION time_zone = '+00:00';
SET FOREIGN_KEY_CHECKS = 0;

CREATE DATABASE IF NOT EXISTS identity_org  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS task_content  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS classroom     DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS media         DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS evaluation    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS growth_cert   DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS platform        DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

USE identity_org;

-- A1 用户账号：全平台唯一身份，role 决定权限码集合
CREATE TABLE IF NOT EXISTS `user` (
  user_id          CHAR(36)      NOT NULL                    COMMENT '用户ID，UUID v4，全局唯一',
  real_name        VARCHAR(50)   NOT NULL                    COMMENT '姓名，2-20 字符，中文/字母',
  role             ENUM('student','teacher','org_admin','sys_admin') NOT NULL COMMENT '角色：student 师范生/teacher 指导教师/org_admin 教研管理员/sys_admin 系统管理员',
  permission_codes JSON          NOT NULL                    COMMENT '权限码数组，由 role 展开，如 task:publish / review:batch',
  phone            VARCHAR(11)   NOT NULL                    COMMENT '手机号，^1[3-9]\\d{9}$，登录凭据',
  password_hash    VARCHAR(60)   NOT NULL                    COMMENT 'bcrypt 摘要（cost=12），禁止明文',
  avatar_url       VARCHAR(512)  NULL     DEFAULT NULL       COMMENT '头像对象存储 URL，jpg/png ≤2MB',
  status           ENUM('active','disabled','locked') NOT NULL DEFAULT 'active' COMMENT '账号状态：active 正常/disabled 停用/locked 锁定',
  locked_until     DATETIME(3)   NULL     DEFAULT NULL       COMMENT '锁定截止时间（UTC）；V1.1 新增，登录失败 5 次写入 now+15min，到期自动解锁，跨重启有效',
  must_change_password TINYINT(1) NOT NULL DEFAULT 0        COMMENT '是否强制改密：1 是。V1.1 新增；管理员创建账号或重置密码后置 1，首次登录成功后置 0',
  last_login_at    DATETIME(3)   NULL     DEFAULT NULL       COMMENT '最近登录时间，保留 90 天',
  school_id        CHAR(36)      NULL     DEFAULT NULL       COMMENT '所属学校/院系ID，单校部署预留，V2 多校启用',
  created_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)   NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  active_phone     VARCHAR(11)   GENERATED ALWAYS AS (IF(deleted_at IS NULL, phone, NULL)) STORED COMMENT '软删唯一约束载体：有效行=phone，已删行=NULL；禁止直接读写',
  PRIMARY KEY (user_id),
  UNIQUE KEY uk_user_phone (active_phone),
  KEY idx_user_role_status (role, status),
  KEY idx_user_school (school_id),
  CONSTRAINT ck_user_phone CHECK (REGEXP_LIKE(phone, '^1[3-9][0-9]{9}$')),
  CONSTRAINT ck_user_realname CHECK (CHAR_LENGTH(real_name) BETWEEN 2 AND 20)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='A1 用户账号：全平台唯一身份主体';

-- A2 师范生档案：学生特有属性，与 user 1:1
CREATE TABLE IF NOT EXISTS dim_grade (
  grade_id CHAR(36) NOT NULL COMMENT '年级/届次维度ID，UUID v4',
  grade_code VARCHAR(20) NOT NULL COMMENT '届次代码，如 2023',
  grade_name VARCHAR(50) NOT NULL COMMENT '展示名称，如 2023级',
  cohort_year SMALLINT NOT NULL COMMENT '入学年份/届次',
  sort_no SMALLINT NOT NULL DEFAULT 0 COMMENT '排序号',
  status ENUM('enabled','disabled') NOT NULL DEFAULT 'enabled' COMMENT '启用状态',
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (grade_id),
  UNIQUE KEY uk_dim_grade_code (grade_code),
  UNIQUE KEY uk_dim_grade_year (cohort_year),
  CONSTRAINT ck_dim_grade_year CHECK (cohort_year BETWEEN 2000 AND 2100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='年级/届次维度：排行榜 scope=grade 的真实范围实体';

CREATE TABLE IF NOT EXISTS student_profile (
  profile_id       CHAR(36)     NOT NULL                    COMMENT '档案ID，UUID v4',
  user_id          CHAR(36)     NOT NULL                    COMMENT '用户ID，→identity_org.user',
  student_no       VARCHAR(30)  NOT NULL                    COMMENT '学号，校内唯一',
  major_id         CHAR(36)     NOT NULL                    COMMENT '专业ID，→identity_org.major',
  grade            ENUM('freshman','sophomore','junior','senior','graduate') NOT NULL COMMENT '年级：freshman 大一/sophomore 大二/junior 大三/senior 大四/graduate 研究生',
  class_id         CHAR(36)     NOT NULL                    COMMENT '班级ID，→identity_org.class',
  subject_id       CHAR(36)     NOT NULL                    COMMENT '学科方向ID，→identity_org.subject',
  stage_pref       ENUM('preschool','primary','junior_high','senior_high','vocational') NOT NULL COMMENT '目标学段：preschool 幼教/primary 小学/junior_high 初中/senior_high 高中/vocational 中职',
  target_cert      ENUM('kindergarten','primary','junior_high','senior_high','vocational','none') NULL DEFAULT NULL COMMENT '目标资格证：幼儿园/小学/初级中学/高级中学/中职/none 无',
  practice_school  VARCHAR(100) NULL DEFAULT NULL           COMMENT '实习学校，≤50 字符；数据项清单标记待确认，V2 启用',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (profile_id),
  UNIQUE KEY uk_sp_user (user_id),
  UNIQUE KEY uk_sp_student_no (student_no),
  KEY idx_sp_class (class_id),
  KEY idx_sp_major (major_id),
  CONSTRAINT fk_sp_user   FOREIGN KEY (user_id)    REFERENCES identity_org.`user` (user_id)  ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_sp_major  FOREIGN KEY (major_id)   REFERENCES identity_org.major (major_id)  ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_sp_class  FOREIGN KEY (class_id)   REFERENCES identity_org.class (class_id)  ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_sp_subj   FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='A2 师范生档案：学生特有属性，与 user 1:1';

-- A3 教师档案：教师特有属性，与 user 1:1
CREATE TABLE IF NOT EXISTS teacher_profile (
  teacher_id       CHAR(36)     NOT NULL                    COMMENT '教师档案ID，UUID v4',
  user_id          CHAR(36)     NOT NULL                    COMMENT '用户ID，→identity_org.user',
  title            ENUM('assistant','lecturer','associate_professor','professor','researcher','external_mentor') NULL DEFAULT NULL COMMENT '职称：助教/讲师/副教授/教授/教研员/校外导师',
  is_examiner      TINYINT(1)   NOT NULL DEFAULT 0          COMMENT '考官资格：1 具备模拟考核评分资格',
  review_quota     SMALLINT     NULL     DEFAULT NULL       COMMENT '待批上限，1-200 默认 50；数据项清单标记待确认，V2 启用',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (teacher_id),
  UNIQUE KEY uk_tp_user (user_id),
  CONSTRAINT fk_tp_user FOREIGN KEY (user_id) REFERENCES identity_org.`user` (user_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='A3 教师档案：教师特有属性，与 user 1:1';

-- A4 专业：院系下的培养单位
CREATE TABLE IF NOT EXISTS major (
  major_id         CHAR(36)     NOT NULL                    COMMENT '专业ID，UUID v4',
  major_name       VARCHAR(50)  NOT NULL                    COMMENT '专业名称，如「汉语言文学（师范）」，全局唯一',
  school_id        CHAR(36)     NULL     DEFAULT NULL       COMMENT '所属院系ID；院系实体未在 43 实体中定义，暂为逻辑引用',
  status           ENUM('enabled','disabled') NOT NULL DEFAULT 'enabled' COMMENT '状态：enabled 启用/disabled 停用',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  active_major_name VARCHAR(50) GENERATED ALWAYS AS (IF(deleted_at IS NULL, major_name, NULL)) STORED COMMENT '软删唯一约束载体，禁止直接读写',
  PRIMARY KEY (major_id),
  UNIQUE KEY uk_major_name (active_major_name),
  KEY idx_major_school (school_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='A4 专业：院系下的培养单位';

-- A5 学科：可试讲的学科方向与评测策略入口
CREATE TABLE IF NOT EXISTS subject (
  subject_id       CHAR(36)     NOT NULL                    COMMENT '学科ID，UUID v4',
  subject_name     VARCHAR(30)  NOT NULL                    COMMENT '学科名称：语文/数学/英语/物理/化学/生物/政治/历史/地理/思政/音乐/体育/美术/信息技术/幼教/其他',
  stage_range      JSON         NOT NULL                    COMMENT '适用学段数组，取值 preschool/primary/junior_high/senior_high/vocational 子集',
  ai_prompt_key    VARCHAR(50)  NULL     DEFAULT NULL       COMMENT '学科评测提示词键，映射 LLM 策略模板',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  active_subject_name VARCHAR(30) GENERATED ALWAYS AS (IF(deleted_at IS NULL, subject_name, NULL)) STORED COMMENT '软删唯一约束载体，禁止直接读写',
  PRIMARY KEY (subject_id),
  UNIQUE KEY uk_subject_name (active_subject_name),
  CONSTRAINT ck_subject_stage CHECK (JSON_VALID(stage_range) AND JSON_LENGTH(stage_range) >= 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='A5 学科：可试讲学科方向与评测策略入口';

-- A6 班级：教学组织与数据可见范围的边界
CREATE TABLE IF NOT EXISTS class (
  class_id         CHAR(36)     NOT NULL                    COMMENT '班级ID，UUID v4',
  class_name       VARCHAR(50)  NOT NULL                    COMMENT '班级名称，如「2023级汉语言文学1班」',
  student_count    SMALLINT     NOT NULL DEFAULT 0          COMMENT '学生数，0-200，由 student_profile 聚合刷新的冗余值',
  enroll_year      SMALLINT     NOT NULL                    COMMENT '入学年份，2000-当前年',
  status           ENUM('active','graduated','archived') NOT NULL DEFAULT 'active' COMMENT '状态：active 在读/graduated 已毕业/archived 归档',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (class_id),
  KEY idx_class_enroll_status (enroll_year, status),
  CONSTRAINT ck_class_student_count CHECK (student_count BETWEEN 0 AND 200),
  CONSTRAINT ck_class_enroll_year CHECK (enroll_year BETWEEN 2000 AND 2100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='A6 班级：教学组织与数据可见范围边界';

-- A7 训练小组：班级内的实训分组
CREATE TABLE IF NOT EXISTS class_group (
  group_id         CHAR(36)     NOT NULL                    COMMENT '小组ID，UUID v4；物理表名 class_group 规避 MySQL 保留字 GROUP',
  class_id         CHAR(36)     NOT NULL                    COMMENT '所属班级ID，→identity_org.class',
  group_name       VARCHAR(30)  NOT NULL                    COMMENT '组名，如「第3实训组」',
  leader_id        CHAR(36)     NULL     DEFAULT NULL       COMMENT '组长档案ID，→student_profile，须为本组成员',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (group_id),
  KEY idx_cg_class (class_id),
  KEY idx_cg_leader (leader_id),
  CONSTRAINT fk_cg_class  FOREIGN KEY (class_id)  REFERENCES identity_org.class (class_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_cg_leader FOREIGN KEY (leader_id) REFERENCES identity_org.student_profile (profile_id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='A7 训练小组：班级内实训分组（沿用 md 实体名 group）';

-- 工程新增：肖像/声音采集授权（SRS NFR-8、附录 A-12，合规硬性要求）
CREATE TABLE IF NOT EXISTS consent_record (
  consent_id           CHAR(36)    NOT NULL                  COMMENT '授权记录ID，UUID v4',
  user_id              CHAR(36)    NOT NULL                  COMMENT '授权主体，→identity_org.user',
  consent_text_version VARCHAR(20) NOT NULL                  COMMENT '授权文本版本号，如 v1.0-2026-10',
  consent_scope        JSON        NOT NULL                  COMMENT '授权范围数组：portrait 人像/voice 声音/analysis AI 分析/archive 存档',
  signed_at            DATETIME(3) NOT NULL                  COMMENT '签署时间（UTC），开课时须校验存在且未撤回',
  revoked_at           DATETIME(3) NULL     DEFAULT NULL     COMMENT '撤回时间，NULL=未撤回',
  signed_ip            VARCHAR(45) NULL     DEFAULT NULL     COMMENT '签署 IP，支持 IPv6',
  created_at           DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at           DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (consent_id),
  KEY idx_consent_user (user_id, signed_at),
  CONSTRAINT fk_consent_user FOREIGN KEY (user_id) REFERENCES identity_org.`user` (user_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='R1 采集授权记录：肖像/声音使用的合规凭据，不可删除仅可撤回';

-- 关联表：A6 class.teacher_ids 与 A3 teacher_profile.managed_class_ids 的规范化载体
CREATE TABLE IF NOT EXISTS class_teacher (
  class_id      CHAR(36) NOT NULL                           COMMENT '班级ID，→identity_org.class',
  teacher_id    CHAR(36) NOT NULL                           COMMENT '教师档案ID，→identity_org.teacher_profile',
  relation_type ENUM('advisor','manager') NOT NULL          COMMENT '关系类型：advisor 指导教师（对应 A6.teacher_ids）/manager 管理班级（对应 A3.managed_class_ids）',
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  PRIMARY KEY (class_id, teacher_id, relation_type),
  KEY idx_ct_teacher (teacher_id, relation_type),
  CONSTRAINT fk_ct_class   FOREIGN KEY (class_id)   REFERENCES identity_org.class (class_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_ct_teacher FOREIGN KEY (teacher_id) REFERENCES identity_org.teacher_profile (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='R2 班级-教师关系：承载数组型外键，relation_type 区分指导教师与管理班级';

-- 关联表：A3 teacher_profile.subject_ids
CREATE TABLE IF NOT EXISTS teacher_subject (
  teacher_id CHAR(36) NOT NULL                              COMMENT '教师档案ID，→identity_org.teacher_profile',
  subject_id CHAR(36) NOT NULL                              COMMENT '学科ID，→identity_org.subject',
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  PRIMARY KEY (teacher_id, subject_id),
  KEY idx_ts_subject (subject_id),
  CONSTRAINT fk_ts_teacher FOREIGN KEY (teacher_id) REFERENCES identity_org.teacher_profile (teacher_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_ts_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='R3 教师-可评学科关系：承载 A3.subject_ids，1-5 条';

-- 关联表：A7 class_group.member_ids
CREATE TABLE IF NOT EXISTS class_group_member (
  group_id   CHAR(36)   NOT NULL                            COMMENT '小组ID，→identity_org.class_group',
  profile_id CHAR(36)   NOT NULL                            COMMENT '学生档案ID，→identity_org.student_profile',
  is_leader  TINYINT(1) NOT NULL DEFAULT 0                  COMMENT '是否组长：1 是',
  joined_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '入组时间，用于组员变动留痕',
  PRIMARY KEY (group_id, profile_id),
  KEY idx_cgm_profile (profile_id),
  CONSTRAINT fk_cgm_group   FOREIGN KEY (group_id)   REFERENCES identity_org.class_group (group_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_cgm_profile FOREIGN KEY (profile_id) REFERENCES identity_org.student_profile (profile_id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='R4 小组成员关系：承载 A7.member_ids，2-10 条';
USE task_content;

-- B2 评分标准：版本化，发布后不可改，只能发新版
CREATE TABLE IF NOT EXISTS rubric (
  rubric_id         CHAR(36)     NOT NULL                   COMMENT '评分标准ID，UUID v4；每个版本一行',
  root_rubric_id    CHAR(36)     NOT NULL                   COMMENT '版本链根ID（v1 的 rubric_id），同一标准的所有版本共享',
  rubric_name       VARCHAR(50)  NOT NULL                   COMMENT '名称，如「教资面试通用评分表」',
  scope             ENUM('system','school','teacher') NOT NULL COMMENT '适用范围：system 系统预置/school 校级/teacher 教师自定义',
  subject_id        CHAR(36)     NULL     DEFAULT NULL      COMMENT '适用学科ID，→identity_org.subject，NULL=通用',
  stage             ENUM('preschool','primary','junior_high','senior_high','vocational') NULL DEFAULT NULL COMMENT '适用学段，NULL=通用',
  total_score       DECIMAL(5,2) NOT NULL DEFAULT 100.00    COMMENT '总分，固定 100.00',
  dimension_weights JSON         NOT NULL                   COMMENT '六维权重对象：content/expression/posture/interaction/board_ppt/time_management，六项之和=1',
  grade_bands       JSON         NULL     DEFAULT NULL      COMMENT '等级分数线：{"excellent":90,"good":80,"pass":60}；NULL 时用系统默认。V1.1 新增（决议 D11）',
  version           INT          NOT NULL DEFAULT 1         COMMENT '版本号，自 1 递增，不可回改',
  is_template       TINYINT(1)   NOT NULL DEFAULT 0         COMMENT '是否系统模板：1 是',
  status            ENUM('draft','published','disabled') NOT NULL DEFAULT 'draft' COMMENT '状态：draft 草稿/published 已发布/disabled 已停用；已发布不可 UPDATE，仅可停用或发新版',
  created_at        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at        DATETIME(3)  NULL     DEFAULT NULL      COMMENT '软删除时间，NULL=有效；业务上禁止删除，仅停用',
  PRIMARY KEY (rubric_id),
  UNIQUE KEY uk_rubric_root_version (root_rubric_id, version),
  KEY idx_rubric_scope (scope, status),
  KEY idx_rubric_subject_stage (subject_id, stage),
  CONSTRAINT fk_rubric_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_rubric_total   CHECK (total_score = 100.00),
  CONSTRAINT ck_rubric_version CHECK (version >= 1),
  CONSTRAINT ck_rubric_weights CHECK (JSON_VALID(dimension_weights)),
  CONSTRAINT ck_rubric_bands   CHECK (grade_bands IS NULL OR JSON_VALID(grade_bands))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='B2 评分标准：版本化口径，报告按 rubric_id+version 追溯';

-- B3 评分细则项：六维下的可打分项
CREATE TABLE IF NOT EXISTS rubric_item (
  item_id             CHAR(36)     NOT NULL                 COMMENT '细则项ID，UUID v4',
  rubric_id           CHAR(36)     NOT NULL                 COMMENT '所属标准ID，→task_content.rubric',
  dimension           ENUM('content','expression','posture','interaction','board_ppt','time_management') NOT NULL COMMENT '所属维度：教学内容/教学表达/教姿教态/互动控场/板书PPT/时间管理',
  item_name           VARCHAR(50)  NOT NULL                 COMMENT '评分项名，如「知识点准确性」',
  max_score           DECIMAL(5,2) NOT NULL                 COMMENT '该项满分，0-100',
  scoring_desc        TEXT         NULL     DEFAULT NULL    COMMENT '评分描述，优秀/良好/合格/待改进四档说明',
  ai_enabled          TINYINT(1)   NOT NULL DEFAULT 1       COMMENT '是否允许 AI 评分：1 是/0 仅人工',
  scored_by           ENUM('ai','human','ai_then_human') NOT NULL DEFAULT 'ai' COMMENT '评分主体：ai 仅AI/human 仅人工/ai_then_human AI初评可人工覆盖。V1.1 新增（决议 D12）',
  weight_in_dimension DECIMAL(4,3) NOT NULL                 COMMENT '维度内权重，0-1，同维度求和=1',
  created_at          DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at          DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at          DATETIME(3)  NULL     DEFAULT NULL    COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (item_id),
  KEY idx_ri_rubric_dim (rubric_id, dimension),
  CONSTRAINT fk_ri_rubric FOREIGN KEY (rubric_id) REFERENCES task_content.rubric (rubric_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_ri_max_score CHECK (max_score BETWEEN 0 AND 100),
  CONSTRAINT ck_ri_weight CHECK (weight_in_dimension >= 0 AND weight_in_dimension <= 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='B3 评分细则项：六维下的可打分项';

-- B1 试讲任务：教师发布的练习/考核单元，任务状态机见 LLD §4
CREATE TABLE IF NOT EXISTS trial_task (
  task_id          CHAR(36)     NOT NULL                    COMMENT '任务ID，UUID v4',
  title            VARCHAR(100) NOT NULL                    COMMENT '任务名称，2-50 字符',
  publisher_id     CHAR(36)     NOT NULL                    COMMENT '发布教师档案ID，→identity_org.teacher_profile',
  subject_id       CHAR(36)     NOT NULL                    COMMENT '学科ID，→identity_org.subject',
  stage            ENUM('preschool','primary','junior_high','senior_high','vocational') NOT NULL COMMENT '学段：幼教/小学/初中/高中/中职',
  textbook_version VARCHAR(50)  NOT NULL                    COMMENT '教材版本，如 部编版/人教版/北师大版',
  mode             ENUM('free','scenario','structured') NOT NULL COMMENT '试讲模式：free 自由试讲/scenario 情景模拟/structured 结构化面试',
  duration_limit_s INT          NOT NULL DEFAULT 600        COMMENT '时长上限（秒），300-2700，默认 600=10 分钟',
  rubric_id        CHAR(36)     NOT NULL                    COMMENT '评分标准ID，→task_content.rubric，版本化引用',
  allow_retry      TINYINT      NOT NULL DEFAULT 3          COMMENT '允许重做次数，0-10，默认 3',
  require_video    TINYINT(1)   NOT NULL DEFAULT 1          COMMENT '必须录像：1 是/0 否',
  deadline         DATETIME(3)  NOT NULL                    COMMENT '截止时间（UTC），须晚于 created_at',
  status           ENUM('draft','published','ongoing','closed','reviewed') NOT NULL DEFAULT 'draft' COMMENT '任务状态：draft 草稿/published 已发布/ongoing 进行中/closed 已截止/reviewed 已批阅',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建（发布）时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (task_id),
  KEY idx_task_deadline_status (deadline, status),
  KEY idx_task_publisher (publisher_id),
  KEY idx_task_subject_stage (subject_id, stage),
  CONSTRAINT fk_task_publisher FOREIGN KEY (publisher_id) REFERENCES identity_org.teacher_profile (teacher_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_task_subject   FOREIGN KEY (subject_id)   REFERENCES identity_org.subject (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_task_rubric    FOREIGN KEY (rubric_id)    REFERENCES task_content.rubric (rubric_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_task_duration  CHECK (duration_limit_s BETWEEN 300 AND 2700),
  CONSTRAINT ck_task_retry     CHECK (allow_retry BETWEEN 0 AND 10),
  CONSTRAINT ck_task_deadline  CHECK (deadline > created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='B1 试讲任务：教师发布的练习/考核单元';

-- B4 试讲题目：题库最小检索单元
CREATE TABLE IF NOT EXISTS trial_topic (
  topic_id         CHAR(36)     NOT NULL                    COMMENT '题目ID，UUID v4',
  subject_id       CHAR(36)     NOT NULL                    COMMENT '学科ID，→identity_org.subject',
  stage            ENUM('preschool','primary','junior_high','senior_high','vocational') NOT NULL COMMENT '学段：幼教/小学/初中/高中/中职',
  textbook_version VARCHAR(50)  NOT NULL                    COMMENT '教材版本',
  book_volume      VARCHAR(20)  NULL     DEFAULT NULL       COMMENT '册次，如「七年级上册」',
  chapter          VARCHAR(100) NULL     DEFAULT NULL       COMMENT '章节，如「第三单元第2课」',
  topic_title      VARCHAR(200) NOT NULL                    COMMENT '题目标题',
  content_text     TEXT         NOT NULL                    COMMENT '题面内容，≤5000 字符，可含公式/图片',
  requirements     TEXT         NULL     DEFAULT NULL       COMMENT '试讲要求，如「含板书设计、体现启发式」',
  difficulty       TINYINT      NOT NULL                    COMMENT '难度 1-5',
  source           ENUM('teacher_cert_exam','skill_competition','platform','teacher_created') NOT NULL COMMENT '来源：teacher_cert_exam 教资真题/skill_competition 技能大赛真题/platform 平台题库/teacher_created 教师自建',
  exam_year        SMALLINT     NULL     DEFAULT NULL       COMMENT '真题年份，2015-当前年；source 为真题时必填',
  usage_count      INT          NOT NULL DEFAULT 0          COMMENT '使用次数，冗余计数',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (topic_id),
  KEY idx_topic_filter (subject_id, stage, textbook_version, difficulty),
  KEY idx_topic_usage (usage_count DESC),
  CONSTRAINT fk_topic_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_topic_difficulty CHECK (difficulty BETWEEN 1 AND 5),
  CONSTRAINT ck_topic_exam_year CHECK (exam_year IS NULL OR exam_year BETWEEN 2015 AND 2100),
  CONSTRAINT ck_topic_exam_year_req CHECK (source <> 'teacher_cert_exam' OR exam_year IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='B4 试讲题目：题库最小检索单元';

-- B5 结构化/教资面试题库：10 类抽题来源
CREATE TABLE IF NOT EXISTS structured_question (
  q_id             CHAR(36)     NOT NULL                    COMMENT '题目ID，UUID v4',
  category         ENUM('career_cognition','psychology','appearance','verbal_expression','thinking_quality','education_teaching','emergency_response','interpersonal','organization','topical') NOT NULL COMMENT '类别：职业认知/心理素质/仪表仪态/言语表达/思维品质/教育教学/应急应变/人际沟通/组织管理/时政热点',
  q_text           TEXT         NOT NULL                    COMMENT '题干，≤1000 字符',
  answer_outline   TEXT         NULL     DEFAULT NULL       COMMENT '参考要点，≤2000 字符',
  source           ENUM('teacher_cert_exam','mock') NOT NULL COMMENT '来源：teacher_cert_exam 教资真题/mock 模拟题',
  exam_year        SMALLINT     NULL     DEFAULT NULL       COMMENT '真题年份，2015-当前年；source=teacher_cert_exam 时必填',
  region           VARCHAR(30)  NULL     DEFAULT NULL       COMMENT '考区，如「四川」',
  difficulty       TINYINT      NOT NULL                    COMMENT '难度 1-5',
  tags             JSON         NULL     DEFAULT NULL       COMMENT '标签数组，如 ["课堂突发","家校沟通"]',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (q_id),
  KEY idx_sq_category_diff (category, difficulty),
  KEY idx_sq_year_region (exam_year, region),
  CONSTRAINT ck_sq_difficulty CHECK (difficulty BETWEEN 1 AND 5),
  CONSTRAINT ck_sq_exam_year_req CHECK (source <> 'teacher_cert_exam' OR exam_year IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='B5 结构化面试题库：10 类抽题来源';

-- B6 教案/板书/说课模板：可复用教学资源
CREATE TABLE IF NOT EXISTS lesson_template (
  template_id      CHAR(36)     NOT NULL                    COMMENT '模板ID，UUID v4',
  template_type    ENUM('lesson_plan','board_design','teaching_plan') NOT NULL COMMENT '模板类型：lesson_plan 教案/board_design 板书设计/teaching_plan 说课稿',
  subject_id       CHAR(36)     NULL     DEFAULT NULL       COMMENT '学科ID，NULL=通用',
  stage            ENUM('preschool','primary','junior_high','senior_high','vocational') NULL DEFAULT NULL COMMENT '学段，NULL=通用',
  template_name    VARCHAR(50)  NOT NULL                    COMMENT '模板名',
  content_json     JSON         NOT NULL                    COMMENT '模板内容，结构化章节：教学目标/重难点/教学过程/板书',
  file_url         VARCHAR(512) NULL     DEFAULT NULL       COMMENT '附件 URL，docx/pdf ≤20MB',
  usage_count      INT          NOT NULL DEFAULT 0          COMMENT '使用次数，冗余计数',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (template_id),
  KEY idx_lt_type_subject (template_type, subject_id, stage),
  CONSTRAINT fk_lt_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_lt_content CHECK (JSON_VALID(content_json))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='B6 教案/板书模板：可复用教学资源';

-- B7 优秀试讲范例：目标锚定与对照
CREATE TABLE IF NOT EXISTS exemplar (
  exemplar_id      CHAR(36)     NOT NULL                    COMMENT '范例ID，UUID v4',
  topic_id         CHAR(36)     NULL     DEFAULT NULL       COMMENT '关联题目ID，→task_content.trial_topic，NULL=通用范例',
  video_url        VARCHAR(512) NOT NULL                    COMMENT '范例视频 URL，mp4 ≤2GB',
  transcript       MEDIUMTEXT   NULL     DEFAULT NULL       COMMENT '逐字稿，带时间戳',
  highlight_tags   JSON         NULL     DEFAULT NULL       COMMENT '亮点标签数组，如 ["导入巧妙","追问设计"]',
  ref_score        DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '参考得分，0-100，专家评分',
  status           ENUM('online','offline') NOT NULL DEFAULT 'online' COMMENT '状态：online 上架/offline 下架',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (exemplar_id),
  KEY idx_ex_topic (topic_id),
  KEY idx_ex_status (status),
  CONSTRAINT fk_ex_topic FOREIGN KEY (topic_id) REFERENCES task_content.trial_topic (topic_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT ck_ex_ref_score CHECK (ref_score IS NULL OR ref_score BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='B7 优秀试讲范例：同题对照与目标锚定';

-- 关联表：B1 trial_task.class_ids
CREATE TABLE IF NOT EXISTS task_class (
  task_id  CHAR(36) NOT NULL                                COMMENT '任务ID，→task_content.trial_task',
  class_id CHAR(36) NOT NULL                                COMMENT '目标班级ID，→identity_org.class，至少 1 条',
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  PRIMARY KEY (task_id, class_id),
  KEY idx_tc_class (class_id),
  CONSTRAINT fk_tc_task  FOREIGN KEY (task_id)  REFERENCES task_content.trial_task (task_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_tc_class FOREIGN KEY (class_id) REFERENCES identity_org.class (class_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='R5 任务-班级关系：承载 B1.class_ids，为空表示未发布';

-- 关联表：B1 trial_task.topic_ids
CREATE TABLE IF NOT EXISTS task_topic (
  task_id  CHAR(36) NOT NULL                                COMMENT '任务ID，→task_content.trial_task',
  topic_id CHAR(36) NOT NULL                                COMMENT '指定题目ID，→task_content.trial_topic；无记录=学生自选',
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  PRIMARY KEY (task_id, topic_id),
  KEY idx_tt_topic (topic_id),
  CONSTRAINT fk_tt_task  FOREIGN KEY (task_id)  REFERENCES task_content.trial_task (task_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_tt_topic FOREIGN KEY (topic_id) REFERENCES task_content.trial_topic (topic_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='R6 任务-指定题目关系：承载 B1.topic_ids';
USE classroom;

-- C4 情景脚本：可运营扩展的突发事件时间轴
CREATE TABLE IF NOT EXISTS scenario (
  scenario_id      CHAR(36)     NOT NULL                    COMMENT '情景ID，UUID v4',
  scenario_name    VARCHAR(50)  NOT NULL                    COMMENT '名称，如「学生当众质疑结论」',
  scenario_type    ENUM('normal','emergency','structured_interview') NOT NULL COMMENT '类型：normal 常规课堂/emergency 突发情景/structured_interview 结构化面试',
  difficulty       TINYINT      NOT NULL                    COMMENT '难度 1-5',
  event_script     JSON         NOT NULL                    COMMENT '事件时间轴数组：[{offset_ms, event_type, payload}]，按 offset_ms 升序',
  expected_skill   ENUM('control','adaptability','guidance','expression','professional_knowledge') NOT NULL COMMENT '考察能力：控场/应变/引导/表达/专业知识',
  subject_id       CHAR(36)     NULL     DEFAULT NULL       COMMENT '适用学科ID，NULL=通用',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (scenario_id),
  KEY idx_sc_type_diff (scenario_type, difficulty),
  KEY idx_sc_subject (subject_id),
  CONSTRAINT fk_sc_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT ck_sc_difficulty CHECK (difficulty BETWEEN 1 AND 5),
  CONSTRAINT ck_sc_script CHECK (JSON_VALID(event_script))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='C4 情景脚本：可运营扩展的突发事件时间轴';

-- C1 虚拟课堂会话：一次试讲的完整生命周期，Redis 仅为运行态镜像
CREATE TABLE IF NOT EXISTS trial_session (
  session_id        CHAR(36)     NOT NULL                   COMMENT '场次ID，UUID v4',
  task_id           CHAR(36)     NULL     DEFAULT NULL      COMMENT '关联任务ID，→task_content.trial_task，自由练习为 NULL',
  user_id           CHAR(36)     NOT NULL                   COMMENT '试讲人用户ID，→identity_org.user',
  mode              ENUM('free','scenario','structured') NOT NULL COMMENT '模式：free 自由试讲/scenario 情景模拟/structured 结构化面试',
  scenario_id       CHAR(36)     NULL     DEFAULT NULL      COMMENT '情景脚本ID，→classroom.scenario；mode=scenario 时必填',
  topic_id          CHAR(36)     NULL     DEFAULT NULL      COMMENT '试讲题目ID，→task_content.trial_topic；mode<>structured 时必填',
  structured_q_id   CHAR(36)     NULL     DEFAULT NULL      COMMENT '结构化面试题目ID，→task_content.structured_question；mode=structured 时必填。V1.1 新增，修复结构化面试无法落库题目的缺口',
  student_count     TINYINT      NOT NULL DEFAULT 30        COMMENT '虚拟学生人数，1-60，默认 30',
  behavior_intensity ENUM('low','mid','high') NOT NULL DEFAULT 'mid' COMMENT '行为强度：low 低/mid 中/high 高',
  classroom_theme   ENUM('blackboard','ppt','multimedia','kindergarten') NOT NULL DEFAULT 'blackboard' COMMENT '课堂环境：黑板/PPT投影/多媒体教室/幼儿园活动室',
  bgm_level         ENUM('off','light','standard') NOT NULL DEFAULT 'light' COMMENT '氛围音：off 关闭/light 轻微/standard 标准',
  planned_duration_s INT         NOT NULL                   COMMENT '计划时长（秒），300-2700，对应 5-45 分钟',
  actual_duration_s INT          NULL     DEFAULT NULL      COMMENT '实际时长（秒），服务端权威计时，结束后 >0',
  start_at          DATETIME(3)  NULL     DEFAULT NULL      COMMENT '开始时间（UTC），状态机进入 running 时写入',
  end_at            DATETIME(3)  NULL     DEFAULT NULL      COMMENT '结束时间（UTC），须晚于 start_at',
  status            ENUM('not_started','running','paused','finished','aborted') NOT NULL DEFAULT 'not_started' COMMENT '状态：未开始/进行中/已暂停/已完成/异常中断',
  device_info       JSON         NULL     DEFAULT NULL      COMMENT '设备信息：browser/camera/mic/resolution，用于质量归因',
  consent_id        CHAR(36)     NOT NULL                   COMMENT '采集授权ID，→identity_org.consent_record；无有效授权拒绝开课',
  created_at        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at        DATETIME(3)  NULL     DEFAULT NULL      COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (session_id),
  KEY idx_sess_user_start (user_id, start_at),
  KEY idx_sess_task (task_id),
  KEY idx_sess_status_created (status, created_at),
  KEY idx_sess_topic (topic_id),
  CONSTRAINT fk_sess_task     FOREIGN KEY (task_id)     REFERENCES task_content.trial_task (task_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_sess_user     FOREIGN KEY (user_id)     REFERENCES identity_org.`user` (user_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_sess_scenario FOREIGN KEY (scenario_id) REFERENCES classroom.scenario (scenario_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_sess_topic    FOREIGN KEY (topic_id)    REFERENCES task_content.trial_topic (topic_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_sess_sq       FOREIGN KEY (structured_q_id) REFERENCES task_content.structured_question (q_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_sess_consent  FOREIGN KEY (consent_id)  REFERENCES identity_org.consent_record (consent_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_sess_students CHECK (student_count BETWEEN 1 AND 60),
  CONSTRAINT ck_sess_planned  CHECK (planned_duration_s BETWEEN 300 AND 2700),
  CONSTRAINT ck_sess_actual   CHECK (actual_duration_s IS NULL OR actual_duration_s >= 0),
  CONSTRAINT ck_sess_time     CHECK (end_at IS NULL OR start_at IS NULL OR end_at >= start_at),
  CONSTRAINT ck_sess_mode_topic CHECK (mode = 'structured' OR topic_id IS NOT NULL),
  CONSTRAINT ck_sess_mode_sq    CHECK (mode <> 'structured' OR structured_q_id IS NOT NULL),
  CONSTRAINT ck_sess_mode_sc    CHECK (mode <> 'scenario'   OR scenario_id IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='C1 虚拟课堂会话：一次试讲的完整生命周期';

-- C2 虚拟学生实例：每场次按配置生成，随场次销毁
CREATE TABLE IF NOT EXISTS virtual_student (
  vs_id            CHAR(36)     NOT NULL                    COMMENT '虚拟学生ID，UUID v4',
  session_id       CHAR(36)     NOT NULL                    COMMENT '所属场次ID，→classroom.trial_session',
  seat_no          TINYINT      NOT NULL                    COMMENT '座位号，1-60，场内唯一',
  vs_name          VARCHAR(20)  NOT NULL                    COMMENT '姓名，从姓名库随机，场内不重复',
  persona          ENUM('focused','active','distracted','challenger','quiet','naughty') NOT NULL COMMENT '人设：focused 专注型/active 活跃型/distracted 走神型/challenger 质疑型/quiet 沉默型/naughty 调皮型',
  engagement_base  TINYINT      NOT NULL                    COMMENT '基础专注度，0-100，行为引擎初值',
  avatar_key       VARCHAR(50)  NOT NULL                    COMMENT '形象资源键，映射前端形象包',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  PRIMARY KEY (vs_id),
  UNIQUE KEY uk_vs_seat (session_id, seat_no),
  UNIQUE KEY uk_vs_name (session_id, vs_name),
  CONSTRAINT fk_vs_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_vs_seat CHECK (seat_no BETWEEN 1 AND 60),
  CONSTRAINT ck_vs_engagement CHECK (engagement_base BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='C2 虚拟学生实例：场次级对象，随场次销毁';

-- C3 课堂行为事件：原始事实、不可变、按月分区
-- 分区表限制：InnoDB 分区表不支持外键，session_id / vs_id 为逻辑引用，由应用写入保证 + 每日对账
CREATE TABLE IF NOT EXISTS behavior_event (
  event_id          CHAR(36)     NOT NULL                   COMMENT '事件ID，UUID v7（按时间有序，降低页分裂）',
  session_id        CHAR(36)     NOT NULL                   COMMENT '所属场次ID，→classroom.trial_session（逻辑外键）',
  vs_id             CHAR(36)     NULL     DEFAULT NULL      COMMENT '触发学生ID，→classroom.virtual_student（逻辑外键）；系统事件为 NULL',
  event_type        ENUM('raise_hand','ask','answer_right','answer_wrong','answer_partial','distracted','whisper','noisy','challenge','device_fault') NOT NULL COMMENT '事件类型：举手/提问/回答正确/回答错误/回答不完整/走神/小声说话/吵闹/质疑老师/设备故障',
  offset_ms         INT          NOT NULL                   COMMENT '相对场次起点的毫秒偏移，≥0，全表时间轴唯一基准',
  payload           JSON         NULL     DEFAULT NULL      COMMENT '事件内容：提问文本/答案文本/正确标记/音量等级',
  handled           TINYINT(1)   NOT NULL DEFAULT 0         COMMENT '是否被教师处理：1 是，用于控场响应率',
  response_ms       INT          NULL     DEFAULT NULL      COMMENT '教师响应时延（毫秒），未处理为 NULL',
  teacher_utterance MEDIUMTEXT   NULL     DEFAULT NULL      COMMENT '该时段教师应对话术，ASR 转写结果',
  created_at        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '入库时间（UTC），分区键；与 offset_ms 的分工见边界规则 E-B3',
  PRIMARY KEY (event_id, created_at),
  KEY idx_beh_session_offset (session_id, offset_ms),
  KEY idx_beh_type_time (event_type, created_at),
  CONSTRAINT ck_beh_offset CHECK (offset_ms >= 0),
  CONSTRAINT ck_beh_response CHECK (response_ms IS NULL OR response_ms >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='C3 课堂行为事件：原始事实，只追加不更新'
PARTITION BY RANGE COLUMNS(created_at) (
  PARTITION p202610 VALUES LESS THAN ('2026-11-01'),
  PARTITION p202611 VALUES LESS THAN ('2026-12-01'),
  PARTITION p202612 VALUES LESS THAN ('2027-01-01'),
  PARTITION p202701 VALUES LESS THAN ('2027-02-01'),
  PARTITION p202702 VALUES LESS THAN ('2027-03-01'),
  PARTITION p202703 VALUES LESS THAN ('2027-04-01'),
  PARTITION pmax    VALUES LESS THAN (MAXVALUE)
);

-- C5 实时消息：场次内聊天/指导流，按月分区、只追加
CREATE TABLE IF NOT EXISTS live_message (
  msg_id            CHAR(36)     NOT NULL                   COMMENT '消息ID，UUID v7',
  session_id        CHAR(36)     NOT NULL                   COMMENT '所属场次ID，→classroom.trial_session（逻辑外键）',
  sender_type       ENUM('virtual_student','system','teacher','ai_coach') NOT NULL COMMENT '发送方类型：虚拟学生/系统/指导教师/AI教练',
  sender_id         CHAR(36)     NULL     DEFAULT NULL      COMMENT '发送方ID：虚拟学生为 vs_id，教师/用户为 user_id，系统为 NULL',
  msg_type          ENUM('text','voice','event','hint','guidance') NOT NULL COMMENT '消息类型：文本/语音/事件/提示/指导',
  content           VARCHAR(2000) NOT NULL                  COMMENT '内容，≤2000 字符',
  sent_at           DATETIME(3)  NOT NULL                   COMMENT '发送时间（UTC），业务时间轴',
  is_read           TINYINT(1)   NOT NULL DEFAULT 0         COMMENT '是否已读：1 是，用于指导触达统计',
  created_at        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '入库时间（UTC），分区键',
  PRIMARY KEY (msg_id, created_at),
  KEY idx_lm_session_sent (session_id, sent_at),
  KEY idx_lm_sender (sender_type, sender_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='C5 实时消息：场次内聊天与指导流，只追加'
PARTITION BY RANGE COLUMNS(created_at) (
  PARTITION p202610 VALUES LESS THAN ('2026-11-01'),
  PARTITION p202611 VALUES LESS THAN ('2026-12-01'),
  PARTITION p202612 VALUES LESS THAN ('2027-01-01'),
  PARTITION p202701 VALUES LESS THAN ('2027-02-01'),
  PARTITION p202702 VALUES LESS THAN ('2027-03-01'),
  PARTITION p202703 VALUES LESS THAN ('2027-04-01'),
  PARTITION pmax    VALUES LESS THAN (MAXVALUE)
);

USE media;

-- D1 录制文件：一轨一行，合成轨单独一行
CREATE TABLE IF NOT EXISTS recording (
  recording_id     CHAR(36)     NOT NULL                    COMMENT '录制ID，UUID v4',
  session_id       CHAR(36)     NOT NULL                    COMMENT '所属场次ID，→classroom.trial_session',
  track_type       ENUM('portrait','screen','board','audio','merged') NOT NULL COMMENT '轨道类型：portrait 人像/screen 屏幕PPT/board 板书/audio 音频/merged 合成',
  file_url         VARCHAR(512) NOT NULL                    COMMENT '文件地址，对象存储 key 或预签名 URL',
  duration_ms      INT          NOT NULL                    COMMENT '时长（毫秒），>0，与场次实际时长偏差 ≤5s',
  size_mb          DECIMAL(10,2) NULL    DEFAULT NULL       COMMENT '文件大小（MB），单轨 ≤2048',
  resolution       VARCHAR(20)  NULL     DEFAULT NULL       COMMENT '分辨率，如 1920x1080',
  format           VARCHAR(10)  NULL     DEFAULT NULL       COMMENT '封装格式：mp4/webm/m4a',
  storage_region   ENUM('local','cloud') NOT NULL DEFAULT 'cloud' COMMENT '存储位置：local 本地/cloud 云端',
  upload_status    ENUM('uploading','success','failed','transcoded') NOT NULL DEFAULT 'uploading' COMMENT '上传状态：上传中/成功/失败/已转码',
  checksum         CHAR(64)     NULL     DEFAULT NULL       COMMENT 'SHA-256 校验值，64 位十六进制，防篡改与续传校验',
  retention_until  DATE         NOT NULL                    COMMENT '保留到期日，默认创建日 +180 天，可续期至 3 年',
  merged_url       VARCHAR(512) NULL     DEFAULT NULL       COMMENT '合成产物 URL，track_type=merged 时必填',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (recording_id),
  UNIQUE KEY uk_rec_session_track (session_id, track_type),
  KEY idx_rec_retention (retention_until),
  KEY idx_rec_status (upload_status),
  CONSTRAINT fk_rec_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_rec_duration CHECK (duration_ms > 0),
  CONSTRAINT ck_rec_size CHECK (size_mb IS NULL OR size_mb <= 2048),
  CONSTRAINT ck_rec_merged CHECK (track_type <> 'merged' OR merged_url IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='D1 录制文件：一轨一行，合成轨单独一行';

-- D2 回放标记：AI 问题点/教师批注/自评/亮点的时间锚
CREATE TABLE IF NOT EXISTS playback_marker (
  marker_id        CHAR(36)     NOT NULL                    COMMENT '标记ID，UUID v4',
  recording_id     CHAR(36)     NOT NULL                    COMMENT '关联录制ID，→media.recording',
  offset_ms        INT          NOT NULL                    COMMENT '时间锚点（毫秒），≥0 且 ≤ 所属录制 duration_ms',
  marker_type      ENUM('ai_issue','teacher_comment','self_review','highlight') NOT NULL COMMENT '标记类型：AI问题点/教师批注/学生自评/亮点',
  comment          VARCHAR(500) NULL     DEFAULT NULL       COMMENT '批注内容，≤500 字符',
  author_id        CHAR(36)     NULL     DEFAULT NULL      COMMENT '批注人用户ID；AI 生成时为 NULL',
  linked_issue_id  CHAR(36)     NULL     DEFAULT NULL      COMMENT '关联问题项ID，→evaluation.issue_item；跨库逻辑外键',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (marker_id),
  KEY idx_pm_recording_offset (recording_id, offset_ms),
  KEY idx_pm_issue (linked_issue_id),
  CONSTRAINT fk_pm_recording FOREIGN KEY (recording_id) REFERENCES media.recording (recording_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_pm_offset CHECK (offset_ms >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='D2 回放标记：问题点与视频片段的互跳锚点';

-- D3 观摩记录：教师实时/回看观摩的在场与指导统计
CREATE TABLE IF NOT EXISTS observation (
  observation_id   CHAR(36)     NOT NULL                    COMMENT '观摩ID，UUID v4',
  session_id       CHAR(36)     NOT NULL                    COMMENT '观摩场次ID，→classroom.trial_session',
  teacher_id       CHAR(36)     NOT NULL                    COMMENT '观摩教师档案ID，→identity_org.teacher_profile',
  join_at          DATETIME(3)  NOT NULL                    COMMENT '进入时间（UTC）',
  leave_at         DATETIME(3)  NULL     DEFAULT NULL       COMMENT '离开时间（UTC），须 ≥ join_at',
  watch_duration_ms INT         NOT NULL DEFAULT 0          COMMENT '观看时长（毫秒），≥0',
  guidance_count   SMALLINT     NOT NULL DEFAULT 0          COMMENT '实时指导条数，≥0，冗余自 live_message',
  is_live          TINYINT(1)   NOT NULL DEFAULT 1          COMMENT '是否直播观摩：1 直播/0 回看',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (observation_id),
  KEY idx_ob_session (session_id),
  KEY idx_ob_teacher_join (teacher_id, join_at),
  CONSTRAINT fk_ob_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_ob_teacher FOREIGN KEY (teacher_id) REFERENCES identity_org.teacher_profile (teacher_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_ob_time CHECK (leave_at IS NULL OR leave_at >= join_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='D3 观摩记录：教师在场时长与指导活跃度';
USE evaluation;

-- E1 评测报告：1 场次 1 报告，生成后不可变，复核只追加
CREATE TABLE IF NOT EXISTS evaluation_report (
  report_id        CHAR(36)     NOT NULL                    COMMENT '报告ID，UUID v4',
  session_id       CHAR(36)     NOT NULL                    COMMENT '所属场次ID，→classroom.trial_session，1:1 唯一',
  user_id          CHAR(36)     NOT NULL                    COMMENT '试讲人用户ID，→identity_org.user，冗余以便按人查',
  rubric_id        CHAR(36)     NOT NULL                    COMMENT '采用标准ID，→task_content.rubric',
  rubric_version   INT          NOT NULL                    COMMENT '标准版本快照，口径追溯用',
  topic_snapshot   JSON         NULL     DEFAULT NULL       COMMENT '题面快照，防题目变更导致历史报告变形；结构化面试无题面时为 NULL',
  ai_total_score   DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT 'AI 总分，0-100，六维加权；计算中为 NULL',
  grade            ENUM('excellent','good','pass','fail') NULL DEFAULT NULL COMMENT '等级：excellent ≥90/good 80-89/pass 60-79/fail <60；分数线由 rubric 配置',
  teacher_score    DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '有效主批教师总分，0-100；无有效主批时为 NULL，AI 分独立保存在 ai_total_score',
  final_score      DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '最终分：有效主批教师分优先，否则取 ai_total_score',
  ai_model_version VARCHAR(30)  NOT NULL                    COMMENT 'AI 模型版本，如 eval-v2.3，随报告留痕',
  asr_status       JSON         NULL     DEFAULT NULL       COMMENT 'ASR 各路状态：{asr,pron,vision,ocr,interaction: pending|running|done|failed}',
  ai_task_status   JSON         NULL     DEFAULT NULL       COMMENT '流水线任务状态：{step, attempts, last_error, updated_at}',
  retry_count      SMALLINT     NOT NULL DEFAULT 0          COMMENT '重算次数，0 起，每次重算 +1',
  status           ENUM('calculating','finished','failed','teacher_reviewed') NOT NULL DEFAULT 'calculating' COMMENT '状态：计算中/已完成/失败/已教师复核',
  generated_at     DATETIME(3)  NULL     DEFAULT NULL       COMMENT '报告生成完成时间（UTC）；status=finished 时必填',
  reviewed_at      DATETIME(3)  NULL     DEFAULT NULL       COMMENT '教师复核时间（UTC）',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (report_id),
  UNIQUE KEY uk_report_session (session_id),
  KEY idx_report_user_time (user_id, generated_at DESC),
  KEY idx_report_status (status, created_at),
  KEY idx_report_rubric (rubric_id, rubric_version),
  CONSTRAINT fk_report_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_report_user    FOREIGN KEY (user_id)    REFERENCES identity_org.`user` (user_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_report_rubric  FOREIGN KEY (rubric_id)  REFERENCES task_content.rubric (rubric_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_report_ai_score   CHECK (ai_total_score IS NULL OR ai_total_score BETWEEN 0 AND 100),
  CONSTRAINT ck_report_t_score    CHECK (teacher_score  IS NULL OR teacher_score  BETWEEN 0 AND 100),
  CONSTRAINT ck_report_f_score    CHECK (final_score    IS NULL OR final_score    BETWEEN 0 AND 100),
  CONSTRAINT ck_report_rubric_ver CHECK (rubric_version >= 1),
  CONSTRAINT ck_report_retry      CHECK (retry_count >= 0),
  CONSTRAINT ck_report_final      CHECK (status IN ('calculating','failed')
                                     OR (final_score IS NOT NULL AND grade IS NOT NULL AND generated_at IS NOT NULL)),
  CONSTRAINT ck_report_reviewed   CHECK (status <> 'teacher_reviewed' OR reviewed_at IS NOT NULL),
  CONSTRAINT ck_report_snapshot   CHECK (topic_snapshot IS NULL OR JSON_VALID(topic_snapshot))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='E1 评测报告：不可变主体 + 可追加复核字段';

-- E2 六维得分：雷达图数据源，1 报告 6 行
CREATE TABLE IF NOT EXISTS dimension_score (
  score_id         CHAR(36)     NOT NULL                    COMMENT '得分ID，UUID v4',
  report_id        CHAR(36)     NOT NULL                    COMMENT '所属报告ID，→evaluation.evaluation_report',
  dimension        ENUM('content','expression','posture','interaction','board_ppt','time_management') NOT NULL COMMENT '维度：教学内容/教学表达/教姿教态/互动控场/板书PPT/时间管理',
  score            DECIMAL(5,2) NOT NULL                    COMMENT '维度得分，0-100',
  max_score        DECIMAL(5,2) NOT NULL DEFAULT 100.00     COMMENT '维度满分，固定 100.00',
  weight           DECIMAL(4,3) NOT NULL                    COMMENT '权重，来自 rubric.dimension_weights，六维之和=1',
  ai_confidence    DECIMAL(4,3) NULL     DEFAULT NULL       COMMENT 'AI 置信度，0-1，低于阈值提示人工复核',
  evidence         JSON         NULL     DEFAULT NULL       COMMENT '证据片段：[{offset_ms, text, reason}]',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (score_id),
  UNIQUE KEY uk_ds_report_dim (report_id, dimension),
  CONSTRAINT fk_ds_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_ds_score  CHECK (score BETWEEN 0 AND 100),
  CONSTRAINT ck_ds_weight CHECK (weight >= 0 AND weight <= 1),
  CONSTRAINT ck_ds_conf   CHECK (ai_confidence IS NULL OR (ai_confidence >= 0 AND ai_confidence <= 1)),
  CONSTRAINT ck_ds_evidence CHECK (evidence IS NULL OR JSON_VALID(evidence))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='E2 六维得分：雷达图与维度明细数据源';

-- E3 问题项：可跳转视频时间段的具体问题
CREATE TABLE IF NOT EXISTS issue_item (
  issue_id         CHAR(36)     NOT NULL                    COMMENT '问题ID，UUID v4',
  report_id        CHAR(36)     NOT NULL                    COMMENT '所属报告ID，→evaluation.evaluation_report',
  dimension        ENUM('content','expression','posture','interaction','board_ppt','time_management') NOT NULL COMMENT '所属维度：六维之一',
  issue_type       ENUM('fast_speech','slow_speech','filler_word','wrong_knowledge','incomplete_explanation','unclear_logic','insufficient_interaction','poor_questioning','missing_feedback','undisciplined','unclear_board','poor_handwriting','ppt_overreliance','segment_overtime','segment_missing','eye_avoidance','unstable_posture','low_volume') NOT NULL COMMENT '问题类型：语速过快/语速过慢/口头禅/知识点错误/讲解不完整/逻辑不清/互动不足/提问设计差/反馈缺失/纪律未处理/板书混乱/字迹潦草/PPT依赖过度/环节超时/环节缺失/眼神回避/站姿不稳/音量过低',
  severity         ENUM('high','mid','low') NOT NULL        COMMENT '严重程度：high 高/mid 中/low 低；枚举顺序即排序序',
  offset_start_ms  INT          NOT NULL                    COMMENT '问题起始偏移（毫秒），0 ≤ start < end',
  offset_end_ms    INT          NOT NULL                    COMMENT '问题结束偏移（毫秒），用于播放器跳转',
  description      VARCHAR(300) NOT NULL                    COMMENT '问题描述，≤300 字符',
  evidence_text    TEXT         NULL     DEFAULT NULL       COMMENT '原文证据，ASR 转写片段',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (issue_id),
  KEY idx_ii_report_sev (report_id, severity, offset_start_ms),
  KEY idx_ii_type (issue_type),
  CONSTRAINT fk_ii_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_ii_offset CHECK (offset_start_ms >= 0 AND offset_end_ms > offset_start_ms)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='E3 问题项：带时间段锚点，支持视频跳转';

-- E4 口头禅命中：按词聚合，1 报告 N 词
CREATE TABLE IF NOT EXISTS filler_word_hit (
  hit_id           CHAR(36)     NOT NULL                    COMMENT '命中ID，UUID v4',
  report_id        CHAR(36)     NOT NULL                    COMMENT '所属报告ID，→evaluation.evaluation_report',
  word             VARCHAR(20)  NOT NULL                    COMMENT '口头禅词，如 嗯/啊/那个/这个/就是/然后/对吧/是吧/怎么说；支持班级自定义词表',
  cnt              INT          NOT NULL                    COMMENT '出现次数，≥0；列名避开 COUNT 函数',
  per_minute       DECIMAL(5,2) NOT NULL                    COMMENT '每分钟频次，次/分钟',
  offsets_ms       JSON         NOT NULL                    COMMENT '命中时刻数组（毫秒），用于逐次跳转',
  is_custom        TINYINT(1)   NOT NULL DEFAULT 0          COMMENT '是否自定义词：1 是/0 系统词表',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  PRIMARY KEY (hit_id),
  UNIQUE KEY uk_fwh_report_word (report_id, word),
  CONSTRAINT fk_fwh_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_fwh_cnt CHECK (cnt >= 0),
  CONSTRAINT ck_fwh_per_min CHECK (per_minute >= 0),
  CONSTRAINT ck_fwh_offsets CHECK (JSON_VALID(offsets_ms))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='E4 口头禅命中：频次词表统计';

-- E5 语音表达指标：1 报告 1 行
CREATE TABLE IF NOT EXISTS speech_metric (
  metric_id        CHAR(36)     NOT NULL                    COMMENT '指标ID，UUID v4',
  report_id        CHAR(36)     NOT NULL                    COMMENT '所属报告ID，→evaluation.evaluation_report，1:1',
  mandarin_score   DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '普通话标准度，0-100',
  speed_wpm        SMALLINT     NULL     DEFAULT NULL       COMMENT '语速，60-400 字/分钟',
  pause_count      INT          NULL     DEFAULT NULL       COMMENT '停顿次数，≥0',
  avg_pause_ms     INT          NULL     DEFAULT NULL       COMMENT '平均停顿时长（毫秒）',
  volume_avg_db    DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '平均音量（dB）',
  volume_stability DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '音量稳定性，0-100',
  fluency_score    DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '流畅度，0-100',
  asr_text         MEDIUMTEXT   NULL     DEFAULT NULL       COMMENT '全量转写文本，带时间戳 JSON 行',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (metric_id),
  UNIQUE KEY uk_sm_report (report_id),
  CONSTRAINT fk_sm_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_sm_wpm CHECK (speed_wpm IS NULL OR speed_wpm BETWEEN 60 AND 400)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='E5 语音表达指标：普通话/语速/停顿/音量/流畅度';

-- E6 教姿教态指标：1 报告 1 行，视觉模型输出
CREATE TABLE IF NOT EXISTS posture_metric (
  metric_id        CHAR(36)     NOT NULL                    COMMENT '指标ID，UUID v4',
  report_id        CHAR(36)     NOT NULL                    COMMENT '所属报告ID，1:1',
  stand_stability  DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '站姿稳定性，0-100',
  gesture_score    DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '手势自然度，0-100',
  eye_contact_ratio DECIMAL(5,2) NULL    DEFAULT NULL       COMMENT '眼神注视率，0-1',
  smile_ratio      DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '微笑占比，0-1',
  movement_score   DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '走动合理性，0-100',
  frames_analyzed  INT          NULL     DEFAULT NULL       COMMENT '分析帧数，≥0',
  detect_confidence DECIMAL(4,3) NULL    DEFAULT NULL       COMMENT '检测置信度，0-1',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (metric_id),
  UNIQUE KEY uk_pm_report (report_id),
  CONSTRAINT fk_pm2_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_pm_eye   CHECK (eye_contact_ratio IS NULL OR (eye_contact_ratio >= 0 AND eye_contact_ratio <= 1)),
  CONSTRAINT ck_pm_smile CHECK (smile_ratio IS NULL OR (smile_ratio >= 0 AND smile_ratio <= 1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='E6 教姿教态指标：站姿/手势/眼神/微笑/走动';

-- E7 板书与 PPT 呈现指标：1 报告 1 行
CREATE TABLE IF NOT EXISTS visual_aid_metric (
  metric_id            CHAR(36)     NOT NULL                COMMENT '指标ID，UUID v4',
  report_id            CHAR(36)     NOT NULL                COMMENT '所属报告ID，1:1',
  board_structure_score DECIMAL(5,2) NULL DEFAULT NULL      COMMENT '板书结构分，0-100',
  handwriting_score    DECIMAL(5,2) NULL DEFAULT NULL       COMMENT '字迹工整度，0-100；未开启 OCR 时为 NULL',
  ocr_enabled          TINYINT(1)   NOT NULL DEFAULT 0      COMMENT '是否启用 OCR：1 是',
  ocr_text             MEDIUMTEXT   NULL DEFAULT NULL       COMMENT '板书识别文本；ocr_enabled=1 时必填',
  ppt_slide_count      SMALLINT     NULL DEFAULT NULL       COMMENT 'PPT 页数，≥0',
  ppt_rationality_score DECIMAL(5,2) NULL DEFAULT NULL      COMMENT 'PPT 合理性，0-100',
  board_time_ratio     DECIMAL(4,3) NULL DEFAULT NULL       COMMENT '板书时间占比，0-1',
  created_at           DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at           DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (metric_id),
  UNIQUE KEY uk_vam_report (report_id),
  CONSTRAINT fk_vam_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_vam_ocr CHECK (ocr_enabled = 0 OR ocr_text IS NOT NULL),
  CONSTRAINT ck_vam_ratio CHECK (board_time_ratio IS NULL OR (board_time_ratio >= 0 AND board_time_ratio <= 1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='E7 板书/PPT 呈现指标：结构/字迹/页数/时间占比';

-- E8 互动控场指标：1 报告 1 行，行为事件聚合而来
CREATE TABLE IF NOT EXISTS interaction_metric (
  metric_id               CHAR(36)     NOT NULL             COMMENT '指标ID，UUID v4',
  report_id               CHAR(36)     NOT NULL             COMMENT '所属报告ID，1:1',
  question_count          SMALLINT     NULL DEFAULT NULL    COMMENT '提问次数，≥0',
  open_question_ratio     DECIMAL(4,3) NULL DEFAULT NULL    COMMENT '开放性问题占比，0-1',
  wait_time_avg_ms        INT          NULL DEFAULT NULL    COMMENT '平均候答时长（毫秒）',
  feedback_quality_score  DECIMAL(5,2) NULL DEFAULT NULL    COMMENT '反馈评价质量，0-100',
  encourage_count         SMALLINT     NULL DEFAULT NULL    COMMENT '鼓励性语言次数，≥0',
  discipline_events       SMALLINT     NULL DEFAULT NULL    COMMENT '纪律事件数，≥0',
  discipline_handled_ratio DECIMAL(4,3) NULL DEFAULT NULL   COMMENT '纪律处理率，0-1',
  pacing_score            DECIMAL(5,2) NULL DEFAULT NULL    COMMENT '节奏把控分，0-100',
  created_at              DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at              DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (metric_id),
  UNIQUE KEY uk_im_report (report_id),
  CONSTRAINT fk_im_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_im_open  CHECK (open_question_ratio IS NULL OR (open_question_ratio >= 0 AND open_question_ratio <= 1)),
  CONSTRAINT ck_im_disc  CHECK (discipline_handled_ratio IS NULL OR (discipline_handled_ratio >= 0 AND discipline_handled_ratio <= 1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='E8 互动控场指标：提问/候答/反馈/纪律/节奏';

-- E9 环节时长：1 报告 N 环节，占比之和=1
CREATE TABLE IF NOT EXISTS segment_timing (
  timing_id        CHAR(36)     NOT NULL                    COMMENT '计时ID，UUID v4',
  report_id        CHAR(36)     NOT NULL                    COMMENT '所属报告ID，→evaluation.evaluation_report',
  segment          ENUM('intro','new_lesson','practice','summary','homework','other') NOT NULL COMMENT '环节：导入/新授/练习/小结/作业/其他',
  start_ms         INT          NOT NULL                    COMMENT '起始偏移（毫秒）',
  end_ms           INT          NOT NULL                    COMMENT '结束偏移（毫秒），须 > start_ms',
  duration_ms      INT          NOT NULL                    COMMENT '环节时长（毫秒），>0',
  actual_ratio     DECIMAL(4,3) NOT NULL                    COMMENT '实际占比，0-1，同报告各环节求和=1',
  plan_ratio       DECIMAL(4,3) NULL DEFAULT NULL           COMMENT '建议占比，0-1，来自 rubric 或学段模板',
  deviation_flag   ENUM('normal','overtime','insufficient','missing') NOT NULL DEFAULT 'normal' COMMENT '偏差：normal 正常/overtime 超时/insufficient 不足/missing 缺失',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (timing_id),
  UNIQUE KEY uk_st_report_segment (report_id, segment),
  CONSTRAINT fk_st_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_st_range CHECK (start_ms >= 0 AND end_ms > start_ms),
  CONSTRAINT ck_st_dur   CHECK (duration_ms > 0),
  CONSTRAINT ck_st_ratio CHECK (actual_ratio >= 0 AND actual_ratio <= 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='E9 环节时长：教学流程切分与偏差标记';

-- E10 改进建议：四类建议，可回采是否采纳
CREATE TABLE IF NOT EXISTS suggestion (
  suggestion_id    CHAR(36)     NOT NULL                    COMMENT '建议ID，UUID v4',
  report_id        CHAR(36)     NOT NULL                    COMMENT '所属报告ID，→evaluation.evaluation_report',
  issue_id         CHAR(36)     NULL     DEFAULT NULL       COMMENT '关联问题ID，→evaluation.issue_item；整体建议为 NULL',
  suggestion_type  ENUM('wording','example_clip','sentence_level','drill') NOT NULL COMMENT '类型：wording 优化话术/example_clip 示范片段/sentence_level 逐句建议/drill 专项练习',
  content_text     VARCHAR(1000) NOT NULL                   COMMENT '建议内容，≤1000 字符',
  original_text    TEXT         NULL     DEFAULT NULL       COMMENT 'ASR 原句；type=sentence_level 时必填',
  optimized_text   TEXT         NULL     DEFAULT NULL       COMMENT 'AI 优化句；type∈(wording,sentence_level) 时必填',
  sample_audio_url VARCHAR(512) NULL     DEFAULT NULL       COMMENT 'TTS 示范音频 URL',
  priority         TINYINT      NOT NULL DEFAULT 3          COMMENT '优先级，1-5，1 最高',
  is_accepted      TINYINT(1)   NULL     DEFAULT NULL       COMMENT '学生是否采纳：1 是/0 否/NULL 未反馈',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (suggestion_id),
  KEY idx_sg_report_priority (report_id, priority),
  KEY idx_sg_issue (issue_id),
  CONSTRAINT fk_sg_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_sg_issue  FOREIGN KEY (issue_id)  REFERENCES evaluation.issue_item (issue_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT ck_sg_priority CHECK (priority BETWEEN 1 AND 5),
  CONSTRAINT ck_sg_opt CHECK (suggestion_type NOT IN ('wording','sentence_level') OR optimized_text IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='E10 改进建议：四类建议与采纳回流';

-- F1 教师批阅：多教师可各自批阅；仅有效主批分进入报告最终成绩，否则沿用 AI 分
CREATE TABLE IF NOT EXISTS teacher_review (
  review_id        CHAR(36)     NOT NULL                    COMMENT '批阅ID，UUID v4',
  session_id       CHAR(36)     NOT NULL                    COMMENT '被批场次ID，→classroom.trial_session，冗余便于按场次查',
  report_id        CHAR(36)     NOT NULL                    COMMENT '关联报告ID，→evaluation.evaluation_report',
  teacher_id       CHAR(36)     NOT NULL                    COMMENT '批阅教师档案ID，→identity_org.teacher_profile',
  item_scores      JSON         NULL     DEFAULT NULL       COMMENT '细则项得分对象 {item_id: score}，须覆盖 rubric_item；批量批阅可为 NULL',
  total_score      DECIMAL(5,2) NOT NULL                    COMMENT '教师总分，0-100',
  comment_text     VARCHAR(2000) NULL    DEFAULT NULL       COMMENT '文字点评，≤2000 字符',
  voice_comment_url VARCHAR(512) NULL    DEFAULT NULL       COMMENT '语音点评 URL，m4a ≤10MB，时长 ≤5 分钟',
  status           ENUM('pending','reviewed','returned') NOT NULL DEFAULT 'pending' COMMENT '状态：pending 待批阅/reviewed 已批阅/returned 退回重做',
  reviewed_at      DATETIME(3)  NULL     DEFAULT NULL       COMMENT '批阅时间（UTC）；status=reviewed 时必填',
  is_batch         TINYINT(1)   NOT NULL DEFAULT 0          COMMENT '是否批量批阅：1 是',
  is_primary       TINYINT(1)   NOT NULL DEFAULT 0          COMMENT '是否主批教师：1 是；每报告最多一名有效主批',
  active_primary_report_id CHAR(36) GENERATED ALWAYS AS (CASE WHEN is_primary = 1 AND status <> 'returned' THEN report_id ELSE NULL END) STORED COMMENT '有效主批唯一约束辅助列',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (review_id),
  UNIQUE KEY uk_tr_report_teacher (report_id, teacher_id),
  UNIQUE KEY uk_tr_active_primary (active_primary_report_id),
  KEY idx_tr_teacher_status (teacher_id, status),
  KEY idx_tr_session (session_id),
  CONSTRAINT fk_tr_report  FOREIGN KEY (report_id)  REFERENCES evaluation.evaluation_report (report_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_tr_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_tr_teacher FOREIGN KEY (teacher_id) REFERENCES identity_org.teacher_profile (teacher_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_tr_score  CHECK (total_score BETWEEN 0 AND 100),
  CONSTRAINT ck_tr_time   CHECK (status <> 'reviewed' OR reviewed_at IS NOT NULL),
  CONSTRAINT ck_tr_items  CHECK (item_scores IS NULL OR JSON_VALID(item_scores))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='F1 教师批阅：多教师批阅；仅有效主批分进入报告最终成绩';
USE growth_cert;

-- G1 训练记录：阶梯训练每一次完成的留痕
CREATE TABLE IF NOT EXISTS training_record (
  train_id         CHAR(36)     NOT NULL                    COMMENT '训练ID，UUID v4',
  user_id          CHAR(36)     NOT NULL                    COMMENT '训练人用户ID，→identity_org.user',
  train_mode       ENUM('shadowing','full_trial','scenario','mock_exam') NOT NULL COMMENT '训练模式：shadowing 跟读训练/full_trial 无提示完整试讲/scenario 突发情景模拟/mock_exam 模拟考核',
  level            ENUM('entry','intermediate','advanced','exam') NOT NULL COMMENT '阶梯层级：entry 入门/intermediate 进阶/advanced 高阶/exam 考核',
  material_type    ENUM('follow_along','trial_topic','scenario') NULL DEFAULT NULL COMMENT '素材类型，配合 material_id 实现多态引用',
  material_id      CHAR(36)     NULL     DEFAULT NULL       COMMENT '训练素材ID：→follow_along_material / trial_topic / scenario；跟读与情景模式必填',
  duration_ms      INT          NOT NULL                    COMMENT '训练时长（毫秒），>0',
  score            DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '训练得分，0-100；跟读训练为发音分',
  session_id       CHAR(36)     NULL     DEFAULT NULL       COMMENT '关联场次ID，→classroom.trial_session；完整试讲/情景/考核时写入',
  completed_at     DATETIME(3)  NOT NULL                    COMMENT '完成时间（UTC）',
  next_recommend   JSON         NULL     DEFAULT NULL       COMMENT '下一步推荐：{train_mode, material_id, reason}',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (train_id),
  KEY idx_tr_user_time (user_id, completed_at DESC),
  KEY idx_tr_material (material_type, material_id),
  KEY idx_tr_session (session_id),
  CONSTRAINT fk_train_user    FOREIGN KEY (user_id)    REFERENCES identity_org.`user` (user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_train_session FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT ck_train_duration CHECK (duration_ms > 0),
  CONSTRAINT ck_train_score CHECK (score IS NULL OR score BETWEEN 0 AND 100),
  CONSTRAINT ck_train_material CHECK (train_mode = 'full_trial' OR (material_type IS NOT NULL AND material_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='G1 训练记录：阶梯训练完成留痕与推荐回流';

-- G2 跟读训练素材：入门级训练的内容源
CREATE TABLE IF NOT EXISTS follow_along_material (
  material_id      CHAR(36)     NOT NULL                    COMMENT '素材ID，UUID v4',
  subject_id       CHAR(36)     NULL     DEFAULT NULL       COMMENT '学科ID，→identity_org.subject，NULL=通用',
  stage            ENUM('preschool','primary','junior_high','senior_high','vocational') NULL DEFAULT NULL COMMENT '学段，NULL=通用',
  material_text    VARCHAR(1000) NOT NULL                   COMMENT '跟读文本，≤1000 字符',
  audio_url        VARCHAR(512) NOT NULL                    COMMENT '标准音频 URL，m4a/mp3',
  focus            ENUM('pronunciation','intonation','speed','pause','stress') NOT NULL COMMENT '训练重点：语音/语调/语速/停顿/重音',
  difficulty       TINYINT      NOT NULL                    COMMENT '难度 1-5',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  deleted_at       DATETIME(3)  NULL     DEFAULT NULL       COMMENT '软删除时间，NULL=有效',
  PRIMARY KEY (material_id),
  KEY idx_fam_subject_stage (subject_id, stage, difficulty),
  KEY idx_fam_focus (focus),
  CONSTRAINT fk_fam_subject FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT ck_fam_difficulty CHECK (difficulty BETWEEN 1 AND 5)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='G2 跟读训练素材：入门级训练内容源';

-- G3 模拟考核：全真计时考核场次，结果计入考核档案
CREATE TABLE IF NOT EXISTS mock_exam (
  exam_id              CHAR(36)     NOT NULL                COMMENT '考核ID，UUID v4',
  user_id              CHAR(36)     NOT NULL                COMMENT '考生用户ID，→identity_org.user',
  task_id              CHAR(36)     NULL     DEFAULT NULL   COMMENT '关联任务ID，→task_content.trial_task，NULL=自主考核',
  countdown_s          INT          NOT NULL                COMMENT '倒计时（秒）：备课 1200/试讲 600/答辩 300',
  examiner_rubric_id   CHAR(36)     NOT NULL                COMMENT '考官评分表ID，→task_content.rubric',
  full_video_required  TINYINT(1)   NOT NULL DEFAULT 1      COMMENT '须全程录像：1 是',
  final_score          DECIMAL(5,2) NULL     DEFAULT NULL   COMMENT '考核得分，0-100；未评分为 NULL',
  result               ENUM('pass','fail') NULL DEFAULT NULL COMMENT '考核结果：pass 通过/fail 不通过；未评分为 NULL',
  cert_eligible        TINYINT(1)   NOT NULL DEFAULT 0      COMMENT '是否具备发证资格：1 是',
  exam_at              DATETIME(3)  NOT NULL                COMMENT '考核时间（UTC）',
  created_at           DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at           DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (exam_id),
  KEY idx_me_user_time (user_id, exam_at DESC),
  KEY idx_me_task (task_id),
  CONSTRAINT fk_me_user   FOREIGN KEY (user_id)            REFERENCES identity_org.`user` (user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_me_task   FOREIGN KEY (task_id)            REFERENCES task_content.trial_task (task_id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_me_rubric FOREIGN KEY (examiner_rubric_id) REFERENCES task_content.rubric (rubric_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_me_countdown CHECK (countdown_s > 0),
  CONSTRAINT ck_me_score CHECK (final_score IS NULL OR final_score BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='G3 模拟考核：全真计时考核与发证资格判定';

-- 关联表：G3 mock_exam.question_ids
CREATE TABLE IF NOT EXISTS mock_exam_question (
  exam_id       CHAR(36) NOT NULL                           COMMENT '考核ID，→growth_cert.mock_exam',
  question_type ENUM('structured','topic') NOT NULL         COMMENT '题目类型：structured 结构化题/topic 试讲题',
  question_id   CHAR(36) NOT NULL                           COMMENT '题目ID：→task_content.structured_question 或 trial_topic',
  seq           TINYINT  NOT NULL DEFAULT 1                 COMMENT '抽题顺序，1 起',
  PRIMARY KEY (exam_id, question_type, question_id),
  KEY idx_meq_question (question_type, question_id),
  CONSTRAINT fk_meq_exam FOREIGN KEY (exam_id) REFERENCES growth_cert.mock_exam (exam_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_meq_seq CHECK (seq >= 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='R7 考核-题目关系：承载 G3.question_ids，支持混合抽题';

-- H1 班级统计：T+1 物化，班级看板的唯一数据源
CREATE TABLE IF NOT EXISTS class_stats (
  stat_id          CHAR(36)     NOT NULL                    COMMENT '统计ID，UUID v4',
  class_id         CHAR(36)     NOT NULL                    COMMENT '班级ID，→identity_org.class',
  period_type      ENUM('day','week','month','term') NOT NULL COMMENT '统计周期：日/周/月/学期',
  period_key       VARCHAR(20)  NOT NULL                    COMMENT '周期键：2026-10-25 / 2026-W43 / 2026-10 / 2026-S1',
  avg_score        DECIMAL(5,2) NULL     DEFAULT NULL       COMMENT '平均分，0-100',
  dimension_avgs   JSON         NULL     DEFAULT NULL       COMMENT '六维均值对象 {dimension: score}',
  weakest_dimension ENUM('content','expression','posture','interaction','board_ppt','time_management') NULL DEFAULT NULL COMMENT '最薄弱维度：六维之一',
  submission_rate  DECIMAL(4,3) NULL     DEFAULT NULL       COMMENT '提交率，0-1',
  active_count     SMALLINT     NOT NULL DEFAULT 0          COMMENT '活跃人数，≥0',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (stat_id),
  UNIQUE KEY uk_cs_class_period (class_id, period_type, period_key),
  KEY idx_cs_period (period_type, period_key),
  CONSTRAINT fk_cs_class FOREIGN KEY (class_id) REFERENCES identity_org.class (class_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_cs_rate CHECK (submission_rate IS NULL OR (submission_rate >= 0 AND submission_rate <= 1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='H1 班级统计：T+1 物化，支撑班级看板';

-- H2 排行榜：周期重建，Redis ZSet 为实时镜像
CREATE TABLE IF NOT EXISTS leaderboard (
  lb_id            CHAR(36)     NOT NULL                    COMMENT '榜单记录ID，UUID v4',
  scope            ENUM('class','grade','major','school') NOT NULL COMMENT '榜单范围：class 班级/grade 年级/major 专业/school 全校',
  scope_id         CHAR(36)     NOT NULL                    COMMENT '范围ID：class→class_id，major→major_id，school→school_id，grade→identity_org.dim_grade.grade_id（按入学届次）',
  period_key       VARCHAR(20)  NOT NULL                    COMMENT '周期键：2026-W43 / 2026-10 / 2026-S1',
  user_id          CHAR(36)     NOT NULL                    COMMENT '上榜人用户ID，→identity_org.user',
  rank_no          SMALLINT     NOT NULL                    COMMENT '名次，≥1；列名避开 RANK 窗口函数关键字',
  score            DECIMAL(5,2) NOT NULL                    COMMENT '榜单分数，0-100',
  improvement_delta DECIMAL(5,2) NULL    DEFAULT NULL       COMMENT '进步幅度，可正可负，与上一周期对比',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (lb_id),
  UNIQUE KEY uk_lb_member (scope, scope_id, period_key, user_id),
  KEY idx_lb_rank (scope, scope_id, period_key, rank_no),
  CONSTRAINT fk_lb_user FOREIGN KEY (user_id) REFERENCES identity_org.`user` (user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_lb_rank  CHECK (rank_no >= 1),
  CONSTRAINT ck_lb_score CHECK (score BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='H2 排行榜：周期重建，Redis ZSet 为实时镜像';

-- H3 达标证书：永久留存，仅可撤销
CREATE TABLE IF NOT EXISTS certificate (
  cert_id          CHAR(36)     NOT NULL                    COMMENT '证书ID，UUID v4',
  user_id          CHAR(36)     NOT NULL                    COMMENT '持证人用户ID，→identity_org.user',
  skill            ENUM('expression','interaction','control','timing','board','comprehensive') NOT NULL COMMENT '认证技能：教学表达/课堂互动/课堂控场/时间管理/板书呈现/综合教学能力',
  level            ENUM('pass','good','excellent') NOT NULL COMMENT '等级：pass 达标/good 良好/excellent 优秀',
  threshold_score  DECIMAL(5,2) NOT NULL                    COMMENT '达标分数线，0-100，管理员可配',
  serial_no        VARCHAR(30)  NOT NULL                    COMMENT '证书编号，CERT-YYYYMM-8位随机，全局唯一，永不复用',
  issue_date       DATE         NOT NULL                    COMMENT '发证日期',
  expire_date      DATE         NULL     DEFAULT NULL       COMMENT '有效期至，默认发证日 +2 年；NULL=长期有效',
  verify_url       VARCHAR(512) NOT NULL                    COMMENT '公开验真地址，扫码可查',
  status           ENUM('valid','expired','revoked') NOT NULL DEFAULT 'valid' COMMENT '状态：valid 有效/expired 已过期/revoked 已撤销',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (cert_id),
  UNIQUE KEY uk_cert_serial (serial_no),
  KEY idx_cert_user_status (user_id, status),
  KEY idx_cert_verify (serial_no, status),
  CONSTRAINT fk_cert_user FOREIGN KEY (user_id) REFERENCES identity_org.`user` (user_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_cert_threshold CHECK (threshold_score BETWEEN 0 AND 100),
  CONSTRAINT ck_cert_expire CHECK (expire_date IS NULL OR expire_date > issue_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='H3 达标证书：永久留存，仅可撤销不可删除';

-- 关联表：H3 certificate.evidence_report_ids
CREATE TABLE IF NOT EXISTS certificate_report (
  cert_id   CHAR(36) NOT NULL                               COMMENT '证书ID，→growth_cert.certificate',
  report_id CHAR(36) NOT NULL                               COMMENT '佐证报告ID，→evaluation.evaluation_report，至少 1 条',
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  PRIMARY KEY (cert_id, report_id),
  KEY idx_cr_report (report_id),
  CONSTRAINT fk_cr_cert   FOREIGN KEY (cert_id)   REFERENCES growth_cert.certificate (cert_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_cr_report FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='R8 证书-佐证报告关系：承载 H3.evidence_report_ids';

-- H4 进步曲线：按维度按日的得分快照
CREATE TABLE IF NOT EXISTS progress_record (
  progress_id     CHAR(36)     NOT NULL                     COMMENT '记录ID，UUID v4',
  user_id         CHAR(36)     NOT NULL                     COMMENT '用户ID，→identity_org.user',
  dimension       ENUM('content','expression','posture','interaction','board_ppt','time_management','overall') NOT NULL COMMENT '维度：六维之一，overall 为综合',
  stat_date       DATE         NOT NULL                     COMMENT '统计日期',
  score           DECIMAL(5,2) NOT NULL                     COMMENT '得分，0-100，当日均分或综合分',
  session_count   INT          NOT NULL DEFAULT 0           COMMENT '累计试讲次数，≥0',
  delta_vs_last   DECIMAL(5,2) NULL     DEFAULT NULL        COMMENT '环比变化，可正可负，与上一统计日对比',
  created_at      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  PRIMARY KEY (progress_id),
  UNIQUE KEY uk_pr_user_dim_date (user_id, dimension, stat_date),
  KEY idx_pr_user_date (user_id, stat_date DESC),
  CONSTRAINT fk_pr_user FOREIGN KEY (user_id) REFERENCES identity_org.`user` (user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_pr_score CHECK (score BETWEEN 0 AND 100),
  CONSTRAINT ck_pr_count CHECK (session_count >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='H4 进步曲线：按维度按日的得分快照';

-- H5 薄弱项与专项推送：训练闭环的起点与终点
CREATE TABLE IF NOT EXISTS weakness_push (
  push_id              CHAR(36)     NOT NULL                COMMENT '推送ID，UUID v4',
  user_id              CHAR(36)     NOT NULL                COMMENT '用户ID，→identity_org.user',
  dimension            ENUM('content','expression','posture','interaction','board_ppt','time_management') NOT NULL COMMENT '薄弱维度：六维之一',
  issue_type           ENUM('fast_speech','slow_speech','filler_word','wrong_knowledge','incomplete_explanation','unclear_logic','insufficient_interaction','poor_questioning','missing_feedback','undisciplined','unclear_board','poor_handwriting','ppt_overreliance','segment_overtime','segment_missing','eye_avoidance','unstable_posture','low_volume') NULL DEFAULT NULL COMMENT '薄弱问题类型，取值同 issue_item.issue_type',
  severity             ENUM('high','mid','low') NOT NULL DEFAULT 'mid' COMMENT '严重程度：high/mid/low',
  recommend_train_mode ENUM('shadowing','full_trial','scenario') NOT NULL COMMENT '推荐训练模式：跟读训练/无提示完整试讲/突发情景模拟',
  recommend_material_type ENUM('follow_along','trial_topic','scenario') NULL DEFAULT NULL COMMENT '推荐素材类型，配合 recommend_material_id',
  recommend_material_id   CHAR(36) NULL   DEFAULT NULL      COMMENT '推荐素材ID',
  pushed_at            DATETIME(3)  NOT NULL                COMMENT '推送时间（UTC），频次控制与防骚扰依据',
  is_clicked           TINYINT(1)   NOT NULL DEFAULT 0      COMMENT '是否点击：1 是',
  is_resolved          TINYINT(1)   NOT NULL DEFAULT 0      COMMENT '是否改善：1 是',
  created_at           DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at           DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (push_id),
  KEY idx_wp_user_time (user_id, pushed_at DESC),
  KEY idx_wp_user_dim (user_id, dimension, is_resolved),
  CONSTRAINT fk_wp_user FOREIGN KEY (user_id) REFERENCES identity_org.`user` (user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_wp_material CHECK (recommend_material_type IS NULL OR recommend_material_id IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='H5 薄弱项与专项推送：训练闭环的推与评';

USE platform;

-- I1 导出任务：异步入队生成，产物 7 天过期
CREATE TABLE IF NOT EXISTS export_task (
  export_id        CHAR(36)     NOT NULL                    COMMENT '导出ID，UUID v4',
  operator_id      CHAR(36)     NOT NULL                    COMMENT '操作人用户ID，→identity_org.user（教师/管理员）',
  export_scope     ENUM('class_score','training_report','leaderboard','student_profile','eval_detail') NOT NULL COMMENT '导出范围：班级成绩/训练报告/排行榜/学生个人档案/评测明细',
  filter_cond      JSON         NULL     DEFAULT NULL       COMMENT '过滤条件：{class_id, date_from, date_to, task_id, dimension}；列名避开 FILTER 关键字',
  export_format    ENUM('xlsx','csv','pdf') NOT NULL        COMMENT '导出格式：xlsx/csv/pdf；列名避开 FORMAT 函数名',
  file_url         VARCHAR(512) NULL     DEFAULT NULL       COMMENT '结果文件 URL；status=success 时必填',
  status           ENUM('queued','generating','success','failed') NOT NULL DEFAULT 'queued' COMMENT '状态：queued 排队中/generating 生成中/success 成功/failed 失败',
  error            VARCHAR(500) NULL     DEFAULT NULL       COMMENT '失败原因；status=failed 时必填。V1.1 新增（对应 11 §2.7 响应字段）',
  expire_at        DATETIME(3)  NOT NULL                    COMMENT '过期时间（UTC），默认生成时间 +7 天',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '创建时间（UTC）',
  updated_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新时间（UTC）',
  PRIMARY KEY (export_id),
  KEY idx_et_operator_time (operator_id, created_at DESC),
  KEY idx_et_status (status),
  KEY idx_et_expire (expire_at),
  CONSTRAINT fk_et_operator FOREIGN KEY (operator_id) REFERENCES identity_org.`user` (user_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_et_file CHECK (status <> 'success' OR file_url IS NOT NULL),
  CONSTRAINT ck_et_error CHECK (status <> 'failed' OR error IS NOT NULL),
  CONSTRAINT ck_et_filter CHECK (filter_cond IS NULL OR JSON_VALID(filter_cond))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='I1 导出任务：异步入队生成，产物 7 天过期';

-- I2 审计日志：只追加，不可篡改，保留 180 天
CREATE TABLE IF NOT EXISTS audit_log (
  log_id           CHAR(36)     NOT NULL                    COMMENT '日志ID，UUID v7',
  user_id          CHAR(36)     NOT NULL                    COMMENT '操作人用户ID，→identity_org.user',
  action           ENUM('login','publish_task','modify_score','review','export','delete_recording','revoke_cert','change_permission') NOT NULL COMMENT '操作类型：登录/发布任务/修改评分/批阅/导出/删除录制/撤销证书/变更权限',
  target_type      VARCHAR(30)  NOT NULL                    COMMENT '对象类型，如 trial_task / certificate / recording',
  target_id        CHAR(36)     NOT NULL                    COMMENT '对象ID',
  ip               VARCHAR(45)  NULL     DEFAULT NULL       COMMENT '客户端 IP，支持 IPv6',
  user_agent       VARCHAR(255) NULL     DEFAULT NULL       COMMENT '客户端 UA，环境追溯',
  created_at       DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '操作时间（UTC）',
  PRIMARY KEY (log_id),
  KEY idx_al_user_time (user_id, created_at DESC),
  KEY idx_al_target (target_type, target_id),
  KEY idx_al_action_time (action, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='I2 审计日志：只追加，不可篡改，保留 180 天';

SET FOREIGN_KEY_CHECKS = 1;


