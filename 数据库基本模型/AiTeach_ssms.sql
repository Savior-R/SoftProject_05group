-- AiTeach 物理模型：SQL Server 2025，库 test，schema 按限界上下文划分，owner=dbo
USE test;
GO
IF SCHEMA_ID('identity_org') IS NULL EXEC('CREATE SCHEMA identity_org AUTHORIZATION dbo;');
IF SCHEMA_ID('task_content') IS NULL EXEC('CREATE SCHEMA task_content AUTHORIZATION dbo;');
IF SCHEMA_ID('classroom') IS NULL EXEC('CREATE SCHEMA classroom AUTHORIZATION dbo;');
IF SCHEMA_ID('media') IS NULL EXEC('CREATE SCHEMA media AUTHORIZATION dbo;');
IF SCHEMA_ID('evaluation') IS NULL EXEC('CREATE SCHEMA evaluation AUTHORIZATION dbo;');
IF SCHEMA_ID('growth_cert') IS NULL EXEC('CREATE SCHEMA growth_cert AUTHORIZATION dbo;');
IF SCHEMA_ID('system') IS NULL EXEC('CREATE SCHEMA system AUTHORIZATION dbo;');
GO
-- 月分区边界：RANGE RIGHT，DATETIME2(3)，边界覆盖 2026-11-01 至 2027-06-01，落 9 个分区，文件组均为 PRIMARY
CREATE PARTITION FUNCTION pf_monthly_event (DATETIME2(3))
AS RANGE RIGHT FOR VALUES (
    '2026-11-01', '2026-12-01', '2027-01-01', '2027-02-01', 
    '2027-03-01', '2027-04-01', '2027-05-01', '2027-06-01'
);

CREATE PARTITION SCHEME ps_monthly_event
AS PARTITION pf_monthly_event ALL TO ([PRIMARY]);
GO

-- 域 A：身份与组织
CREATE TABLE identity_org.major (
  major_id UNIQUEIDENTIFIER PRIMARY KEY,
  major_name NVARCHAR(50) NOT NULL,
  school_id UNIQUEIDENTIFIER,
  status VARCHAR(10) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE identity_org.subject (
  subject_id UNIQUEIDENTIFIER PRIMARY KEY,
  subject_name NVARCHAR(30) NOT NULL,
  stage_range NVARCHAR(200),
  ai_prompt_key VARCHAR(50),
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE identity_org.class (
  class_id UNIQUEIDENTIFIER PRIMARY KEY,
  class_name NVARCHAR(50) NOT NULL,
  teacher_ids JSON,
  student_count INT NOT NULL DEFAULT 0,
  enroll_year INT NOT NULL,
  status VARCHAR(10) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE identity_org.[user] (
  user_id UNIQUEIDENTIFIER PRIMARY KEY,
  real_name NVARCHAR(50) NOT NULL,
  role VARCHAR(20) NOT NULL CONSTRAINT ck_user_role CHECK (role IN ('student', 'teacher', 'org_admin', 'sys_admin')),
  permission_codes JSON,
  phone VARCHAR(11) NOT NULL,
  password_hash VARCHAR(60) NOT NULL,
  avatar_url VARCHAR(255),
  status VARCHAR(20) NOT NULL DEFAULT 'active' CONSTRAINT ck_user_status CHECK (status IN ('active', 'disabled', 'locked')),
  last_login_at DATETIME2(3),
  school_id UNIQUEIDENTIFIER,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE identity_org.student_profile (
  profile_id UNIQUEIDENTIFIER PRIMARY KEY,
  user_id UNIQUEIDENTIFIER NOT NULL,
  student_no VARCHAR(30) NOT NULL,
  major_id UNIQUEIDENTIFIER NOT NULL,
  grade VARCHAR(10) NOT NULL,
  class_id UNIQUEIDENTIFIER NOT NULL,
  subject_id UNIQUEIDENTIFIER NOT NULL,
  stage_pref VARCHAR(10) NOT NULL,
  target_cert VARCHAR(20),
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE identity_org.teacher_profile (
  teacher_id UNIQUEIDENTIFIER PRIMARY KEY,
  user_id UNIQUEIDENTIFIER NOT NULL,
  title VARCHAR(20),
  subject_ids JSON,
  managed_class_ids JSON,
  is_examiner BIT NOT NULL DEFAULT 0,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE identity_org.class_group (
  group_id UNIQUEIDENTIFIER PRIMARY KEY,
  class_id UNIQUEIDENTIFIER NOT NULL,
  group_name NVARCHAR(30) NOT NULL,
  member_ids JSON,
  leader_id UNIQUEIDENTIFIER,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE identity_org.consent_record (
  consent_id UNIQUEIDENTIFIER PRIMARY KEY,
  user_id UNIQUEIDENTIFIER NOT NULL,
  consent_text_version VARCHAR(20) NOT NULL,
  signed_at DATETIME2(3) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

-- 域 B：任务与资源
CREATE TABLE task_content.rubric (
  rubric_id UNIQUEIDENTIFIER PRIMARY KEY,
  rubric_name NVARCHAR(50) NOT NULL,
  scope VARCHAR(20) NOT NULL,
  subject_id UNIQUEIDENTIFIER,
  stage VARCHAR(10),
  total_score DECIMAL(5,2) NOT NULL DEFAULT 100,
  dimension_weights JSON NOT NULL,
  version INT NOT NULL,
  is_template BIT NOT NULL DEFAULT 0,
  status VARCHAR(10) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE task_content.rubric_item (
  item_id UNIQUEIDENTIFIER PRIMARY KEY,
  rubric_id UNIQUEIDENTIFIER NOT NULL,
  dimension VARCHAR(20) NOT NULL CONSTRAINT ck_rubric_dim CHECK (dimension IN ('content', 'expression', 'posture', 'interaction', 'board_ppt', 'time_management')),
  item_name NVARCHAR(50) NOT NULL,
  max_score DECIMAL(5,2) NOT NULL,
  scoring_desc NVARCHAR(MAX),
  ai_enabled BIT NOT NULL DEFAULT 1,
  weight_in_dimension DECIMAL(4,3) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE task_content.trial_topic (
  topic_id UNIQUEIDENTIFIER PRIMARY KEY,
  subject_id UNIQUEIDENTIFIER NOT NULL,
  stage VARCHAR(10) NOT NULL,
  textbook_version NVARCHAR(50) NOT NULL,
  topic_title NVARCHAR(200) NOT NULL,
  content_text NVARCHAR(MAX) NOT NULL,
  difficulty INT NOT NULL,
  source VARCHAR(20) NOT NULL,
  usage_count INT NOT NULL DEFAULT 0,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE task_content.structured_question (
  q_id UNIQUEIDENTIFIER PRIMARY KEY,
  category VARCHAR(30) NOT NULL,
  q_text NVARCHAR(MAX) NOT NULL,
  answer_outline NVARCHAR(MAX),
  source VARCHAR(20) NOT NULL,
  difficulty INT NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE task_content.lesson_template (
  template_id UNIQUEIDENTIFIER PRIMARY KEY,
  template_type VARCHAR(20) NOT NULL,
  subject_id UNIQUEIDENTIFIER,
  stage VARCHAR(10),
  template_name NVARCHAR(50) NOT NULL,
  content_json JSON,
  file_url VARCHAR(500),
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE task_content.trial_task (
  task_id UNIQUEIDENTIFIER PRIMARY KEY,
  title NVARCHAR(100) NOT NULL,
  publisher_id UNIQUEIDENTIFIER NOT NULL,
  class_ids JSON NOT NULL,
  subject_id UNIQUEIDENTIFIER NOT NULL,
  stage VARCHAR(10) NOT NULL,
  textbook_version NVARCHAR(50) NOT NULL,
  topic_ids JSON,
  mode VARCHAR(20) NOT NULL CONSTRAINT ck_task_mode CHECK (mode IN ('free', 'scenario', 'structured')),
  duration_limit INT NOT NULL DEFAULT 600,
  rubric_id UNIQUEIDENTIFIER NOT NULL,
  deadline DATETIME2(3) NOT NULL,
  status VARCHAR(20) NOT NULL CONSTRAINT ck_task_status CHECK (status IN ('draft', 'published', 'ongoing', 'closed', 'reviewed')),
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE task_content.exemplar (
  exemplar_id UNIQUEIDENTIFIER PRIMARY KEY,
  topic_id UNIQUEIDENTIFIER,
  video_url VARCHAR(500) NOT NULL,
  transcript NVARCHAR(MAX),
  highlight_tags JSON,
  status VARCHAR(10) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

-- 域 C：虚拟课堂
CREATE TABLE classroom.scenario (
  scenario_id UNIQUEIDENTIFIER PRIMARY KEY,
  scenario_name NVARCHAR(50) NOT NULL,
  scenario_type VARCHAR(20) NOT NULL,
  difficulty INT NOT NULL,
  event_script JSON NOT NULL,
  expected_skill VARCHAR(20) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE classroom.trial_session (
  session_id UNIQUEIDENTIFIER PRIMARY KEY,
  task_id UNIQUEIDENTIFIER,
  user_id UNIQUEIDENTIFIER NOT NULL,
  mode VARCHAR(20) NOT NULL CONSTRAINT ck_sess_mode CHECK (mode IN ('free', 'scenario', 'structured')),
  scenario_id UNIQUEIDENTIFIER,
  topic_id UNIQUEIDENTIFIER,
  student_count INT NOT NULL DEFAULT 30,
  planned_duration INT NOT NULL,
  actual_duration INT,
  start_at DATETIME2(3),
  end_at DATETIME2(3),
  status VARCHAR(20) NOT NULL CONSTRAINT ck_sess_status CHECK (status IN ('not_started', 'running', 'paused', 'finished', 'aborted')),
  consent_id UNIQUEIDENTIFIER NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE classroom.virtual_student (
  vs_id UNIQUEIDENTIFIER PRIMARY KEY,
  session_id UNIQUEIDENTIFIER NOT NULL,
  seat_no INT NOT NULL,
  vs_name NVARCHAR(20) NOT NULL,
  persona VARCHAR(20) NOT NULL,
  engagement_base INT NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

-- behavior_event：课堂行为事件原始事实表；按月分区，主键含分区列 created_at
CREATE TABLE classroom.behavior_event (
  event_id UNIQUEIDENTIFIER NOT NULL,
  session_id UNIQUEIDENTIFIER NOT NULL,
  vs_id UNIQUEIDENTIFIER,
  event_type VARCHAR(20) NOT NULL CONSTRAINT ck_beh_event CHECK (event_type IN ('raise_hand', 'ask', 'answer_right', 'answer_wrong', 'answer_partial', 'distracted', 'whisper', 'noisy', 'challenge', 'device_fault')),
  offset_ms INT NOT NULL,
  payload JSON,
  handled BIT NOT NULL DEFAULT 0,
  response_ms INT,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3),
  CONSTRAINT PK_behavior_event PRIMARY KEY (event_id, created_at)
) ON ps_monthly_event(created_at);

-- live_message：场次实时消息表；按月分区，主键含分区列 created_at
CREATE TABLE classroom.live_message (
  msg_id UNIQUEIDENTIFIER NOT NULL,
  session_id UNIQUEIDENTIFIER NOT NULL,
  sender_type VARCHAR(20) NOT NULL,
  sender_id UNIQUEIDENTIFIER,
  msg_type VARCHAR(20) NOT NULL,
  content NVARCHAR(MAX) NOT NULL,
  sent_at DATETIME2(3) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3),
  CONSTRAINT PK_live_message PRIMARY KEY (msg_id, created_at)
) ON ps_monthly_event(created_at);

-- 域 D：媒体
CREATE TABLE media.recording (
  recording_id UNIQUEIDENTIFIER PRIMARY KEY,
  session_id UNIQUEIDENTIFIER NOT NULL,
  track_type VARCHAR(20) NOT NULL,
  file_url VARCHAR(500) NOT NULL,
  duration_ms INT NOT NULL,
  size_mb DECIMAL(10,2),
  upload_status VARCHAR(20) NOT NULL,
  retention_until DATE,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE media.playback_marker (
  marker_id UNIQUEIDENTIFIER PRIMARY KEY,
  recording_id UNIQUEIDENTIFIER NOT NULL,
  offset_ms INT NOT NULL,
  marker_type VARCHAR(20) NOT NULL,
  comment NVARCHAR(500),
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE media.observation (
  observation_id UNIQUEIDENTIFIER PRIMARY KEY,
  session_id UNIQUEIDENTIFIER NOT NULL,
  teacher_id UNIQUEIDENTIFIER NOT NULL,
  join_at DATETIME2(3),
  leave_at DATETIME2(3),
  watch_duration_ms INT,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

-- 域 E：AI 评测
CREATE TABLE evaluation.evaluation_report (
  report_id UNIQUEIDENTIFIER PRIMARY KEY,
  session_id UNIQUEIDENTIFIER UNIQUE NOT NULL,
  user_id UNIQUEIDENTIFIER NOT NULL,
  rubric_id UNIQUEIDENTIFIER NOT NULL,
  rubric_version INT NOT NULL,
  topic_snapshot JSON NOT NULL,
  ai_total_score DECIMAL(5,2),
  grade VARCHAR(20) NOT NULL CONSTRAINT ck_eval_grade CHECK (grade IN ('excellent', 'good', 'pass', 'fail')),
  teacher_score DECIMAL(5,2),
  final_score DECIMAL(5,2) NOT NULL,
  ai_model_version VARCHAR(30) NOT NULL,
  status VARCHAR(20) NOT NULL CONSTRAINT ck_eval_status CHECK (status IN ('calculating', 'finished', 'failed', 'teacher_reviewed')),
  generated_at DATETIME2(3) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE evaluation.dimension_score (
  score_id UNIQUEIDENTIFIER PRIMARY KEY,
  report_id UNIQUEIDENTIFIER NOT NULL,
  dimension VARCHAR(20) NOT NULL CONSTRAINT ck_dim_score CHECK (dimension IN ('content', 'expression', 'posture', 'interaction', 'board_ppt', 'time_management')),
  score DECIMAL(5,2) NOT NULL,
  max_score DECIMAL(5,2) NOT NULL DEFAULT 100,
  weight DECIMAL(4,3) NOT NULL,
  evidence JSON,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE evaluation.issue_item (
  issue_id UNIQUEIDENTIFIER PRIMARY KEY,
  report_id UNIQUEIDENTIFIER NOT NULL,
  dimension VARCHAR(20) NOT NULL CONSTRAINT ck_dim_issue CHECK (dimension IN ('content', 'expression', 'posture', 'interaction', 'board_ppt', 'time_management')),
  issue_type VARCHAR(30) NOT NULL,
  severity VARCHAR(10) NOT NULL,
  description NVARCHAR(300) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE evaluation.suggestion (
  suggestion_id UNIQUEIDENTIFIER PRIMARY KEY,
  report_id UNIQUEIDENTIFIER NOT NULL,
  issue_id UNIQUEIDENTIFIER,
  suggestion_type VARCHAR(20) NOT NULL,
  content_text NVARCHAR(1000) NOT NULL,
  priority INT,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE evaluation.teacher_review (
  review_id UNIQUEIDENTIFIER PRIMARY KEY,
  session_id UNIQUEIDENTIFIER NOT NULL,
  report_id UNIQUEIDENTIFIER NOT NULL,
  teacher_id UNIQUEIDENTIFIER NOT NULL,
  total_score DECIMAL(5,2) NOT NULL,
  comment_text NVARCHAR(2000),
  status VARCHAR(20) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

-- 域 G：成长与认证
CREATE TABLE growth_cert.training_record (
  train_id UNIQUEIDENTIFIER PRIMARY KEY,
  user_id UNIQUEIDENTIFIER NOT NULL,
  train_mode VARCHAR(30) NOT NULL,
  level VARCHAR(10) NOT NULL,
  duration_ms INT,
  score DECIMAL(5,2),
  session_id UNIQUEIDENTIFIER,
  completed_at DATETIME2(3),
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE growth_cert.certificate (
  cert_id UNIQUEIDENTIFIER PRIMARY KEY,
  user_id UNIQUEIDENTIFIER NOT NULL,
  skill VARCHAR(30) NOT NULL,
  level VARCHAR(10) NOT NULL,
  threshold_score DECIMAL(5,2),
  evidence_report_ids JSON NOT NULL,
  serial_no VARCHAR(30) NOT NULL,
  issue_date DATE NOT NULL,
  status VARCHAR(10) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE growth_cert.class_stats (
  stat_id UNIQUEIDENTIFIER PRIMARY KEY,
  class_id UNIQUEIDENTIFIER NOT NULL,
  period_type VARCHAR(10) NOT NULL,
  period_key VARCHAR(20) NOT NULL,
  avg_score DECIMAL(5,2),
  submission_rate DECIMAL(4,3),
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE growth_cert.leaderboard (
  lb_id UNIQUEIDENTIFIER PRIMARY KEY,
  scope VARCHAR(20) NOT NULL,
  scope_id UNIQUEIDENTIFIER NOT NULL,
  period_key VARCHAR(20) NOT NULL,
  user_id UNIQUEIDENTIFIER NOT NULL,
  rank INT NOT NULL,
  score DECIMAL(5,2) NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

-- 域 I：系统支撑
CREATE TABLE system.export_task (
  export_id UNIQUEIDENTIFIER PRIMARY KEY,
  operator_id UNIQUEIDENTIFIER NOT NULL,
  export_scope VARCHAR(30) NOT NULL,
  format VARCHAR(10) NOT NULL,
  status VARCHAR(20) NOT NULL,
  expire_at DATETIME2(3),
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2(3)
);

CREATE TABLE system.audit_log (
  log_id UNIQUEIDENTIFIER PRIMARY KEY,
  user_id UNIQUEIDENTIFIER NOT NULL,
  action VARCHAR(30) NOT NULL,
  target_type VARCHAR(30) NOT NULL,
  target_id UNIQUEIDENTIFIER NOT NULL,
  ip VARCHAR(45),
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- 唯一索引：软删过滤条件 deleted_at IS NULL
CREATE UNIQUE INDEX uk_user_phone ON identity_org.[user](phone) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uk_student_no ON identity_org.student_profile(student_no) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uk_cert_serial ON growth_cert.certificate(serial_no) WHERE deleted_at IS NULL;

ALTER TABLE identity_org.major ADD CONSTRAINT uk_major_name UNIQUE (major_name);
ALTER TABLE identity_org.subject ADD CONSTRAINT uk_subject_name UNIQUE (subject_name);
GO

-- 外键
ALTER TABLE identity_org.student_profile ADD FOREIGN KEY (user_id) REFERENCES identity_org.[user] (user_id);
ALTER TABLE identity_org.student_profile ADD FOREIGN KEY (major_id) REFERENCES identity_org.major (major_id);
ALTER TABLE identity_org.student_profile ADD FOREIGN KEY (class_id) REFERENCES identity_org.class (class_id);
ALTER TABLE identity_org.student_profile ADD FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id);
ALTER TABLE identity_org.teacher_profile ADD FOREIGN KEY (user_id) REFERENCES identity_org.[user] (user_id);
ALTER TABLE identity_org.class_group ADD FOREIGN KEY (class_id) REFERENCES identity_org.class (class_id);
ALTER TABLE identity_org.consent_record ADD FOREIGN KEY (user_id) REFERENCES identity_org.[user] (user_id);
ALTER TABLE task_content.rubric ADD FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id);
ALTER TABLE task_content.rubric_item ADD FOREIGN KEY (rubric_id) REFERENCES task_content.rubric (rubric_id);
ALTER TABLE task_content.trial_topic ADD FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id);
ALTER TABLE task_content.lesson_template ADD FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id);
ALTER TABLE task_content.trial_task ADD FOREIGN KEY (publisher_id) REFERENCES identity_org.teacher_profile (teacher_id);
ALTER TABLE task_content.trial_task ADD FOREIGN KEY (subject_id) REFERENCES identity_org.subject (subject_id);
ALTER TABLE task_content.trial_task ADD FOREIGN KEY (rubric_id) REFERENCES task_content.rubric (rubric_id);
ALTER TABLE task_content.exemplar ADD FOREIGN KEY (topic_id) REFERENCES task_content.trial_topic (topic_id);
ALTER TABLE classroom.trial_session ADD FOREIGN KEY (task_id) REFERENCES task_content.trial_task (task_id);
ALTER TABLE classroom.trial_session ADD FOREIGN KEY (user_id) REFERENCES identity_org.[user] (user_id);
ALTER TABLE classroom.trial_session ADD FOREIGN KEY (scenario_id) REFERENCES classroom.scenario (scenario_id);
ALTER TABLE classroom.trial_session ADD FOREIGN KEY (topic_id) REFERENCES task_content.trial_topic (topic_id);
ALTER TABLE classroom.trial_session ADD FOREIGN KEY (consent_id) REFERENCES identity_org.consent_record (consent_id);
ALTER TABLE classroom.virtual_student ADD FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id);
ALTER TABLE classroom.live_message ADD FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id);
ALTER TABLE media.recording ADD FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id);
ALTER TABLE media.playback_marker ADD FOREIGN KEY (recording_id) REFERENCES media.recording (recording_id);
ALTER TABLE media.observation ADD FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id);
ALTER TABLE media.observation ADD FOREIGN KEY (teacher_id) REFERENCES identity_org.teacher_profile (teacher_id);
ALTER TABLE evaluation.evaluation_report ADD FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id);
ALTER TABLE evaluation.evaluation_report ADD FOREIGN KEY (user_id) REFERENCES identity_org.[user] (user_id);
ALTER TABLE evaluation.evaluation_report ADD FOREIGN KEY (rubric_id) REFERENCES task_content.rubric (rubric_id);
ALTER TABLE evaluation.dimension_score ADD FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id);
ALTER TABLE evaluation.issue_item ADD FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id);
ALTER TABLE evaluation.suggestion ADD FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id);
ALTER TABLE evaluation.suggestion ADD FOREIGN KEY (issue_id) REFERENCES evaluation.issue_item (issue_id);
ALTER TABLE evaluation.teacher_review ADD FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id);
ALTER TABLE evaluation.teacher_review ADD FOREIGN KEY (report_id) REFERENCES evaluation.evaluation_report (report_id);
ALTER TABLE evaluation.teacher_review ADD FOREIGN KEY (teacher_id) REFERENCES identity_org.teacher_profile (teacher_id);
ALTER TABLE growth_cert.training_record ADD FOREIGN KEY (user_id) REFERENCES identity_org.[user] (user_id);
ALTER TABLE growth_cert.training_record ADD FOREIGN KEY (session_id) REFERENCES classroom.trial_session (session_id);
ALTER TABLE growth_cert.certificate ADD FOREIGN KEY (user_id) REFERENCES identity_org.[user] (user_id);
ALTER TABLE growth_cert.class_stats ADD FOREIGN KEY (class_id) REFERENCES identity_org.class (class_id);
ALTER TABLE growth_cert.leaderboard ADD FOREIGN KEY (user_id) REFERENCES identity_org.[user] (user_id);
ALTER TABLE system.export_task ADD FOREIGN KEY (operator_id) REFERENCES identity_org.[user] (user_id);
ALTER TABLE system.audit_log ADD FOREIGN KEY (user_id) REFERENCES identity_org.[user] (user_id);
GO

-- 索引
CREATE INDEX ix_student_user ON identity_org.student_profile(user_id);
CREATE INDEX ix_trial_session_user ON classroom.trial_session(user_id);
CREATE INDEX ix_recording_session ON media.recording(session_id);
CREATE INDEX ix_eval_report_user ON evaluation.evaluation_report(user_id, generated_at DESC);
GO