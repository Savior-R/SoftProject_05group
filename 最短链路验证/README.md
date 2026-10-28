# 最短链路验证：先证明契约能够落地

日期：2026-10-28；针对唯一基准设计文档3.x 3.2.0，实施选择按ADR-010/011/012。

建议采用“文档检查 → 一个数据库的真实约束试验 → 单机纵向切片 → 一次真实AI评测”的顺序。目标是尽早暴露设计矛盾，不是先完成九个模块。切片通过也不代表G1–G6全部通过。

## 1 当前可以立即运行的检查

在工作空间PowerShell执行：

```powershell
Set-Location -LiteralPath 'D:\soft\HomeWork\SoftProject'
python '.\最短链路验证\check_design.py'
```

脚本只用Python标准库，读取当前文档，写本目录检查结果.json；不会重生成或覆盖设计文档。检查文件/版本、链接/表格、API和嵌套DTO、最短路由、61实体字典、FR追踪、评分边界。返回码0表示这些检查通过，1表示发现问题。

依赖旧版的文档生成链已删除；本检查直接读取现行正文与api-contract.json，不需要旧文档。

标准库文档检查与应用环境验收分开。应用统一Python3.12，当前已有最小后端与健康探针；全组环境、目标数据库和业务进度以app/IMPLEMENTATION_STATUS.md为准，不复用旧环境快照。

## 2 第一轮只验证这些对象和规则

采用A1：一个API进程、一个真实SQL实例、本地私有文件、SQL待办与同进程调度。浏览器先做一个录制页，教师操作可由API调试工具执行，不必先做完整后台。首轮不部署Redis/S3/TURN，也不实施训练/考核/证书；这些只是延期验证，仍保留原需求。

最小数据：一院、一专业、一班、一教师、一学生、一题、一份六维标准、一任务、一场次。为了并发主批负例再增加第二教师；为了院系越权增加第二院系/学生。组织数据可seed，标准和任务必须实际调用创建/发布接口，不能全部预置绕开生命周期。

数据库优先选择你机器已经可用的一种；按ADR-010先MySQL，再补SQL Server；双方言均不能免验。切片所用表及其真实FK依赖必须建齐，不能删FK、改SQLite或把事实放JSON文件就声称建库通过。若生成器可完整生成61表，就直接建全表；不用先实现61表的全部业务接口。

第一轮必须实际执行以下负例，失败就回修05/06/11及生成源：

| 输入/动作 | 必须结果 |
|---|---|
| pending批阅、total_score=NULL | 可以落库，不占有效主批唯一名额 |
| 同report两条reviewed且is_primary=1 | 唯一约束拒绝第二条 |
| 旧主批returned再设新主批 | 名额释放，最终分来源正确 |
| unavailable维度score=NULL | 可以落库且有原因；六维固定六行 |
| rubric_item.max_score=0 | 拒绝 |
| 四可用维度但可用权重和0 | AI总分NULL，不除零 |
| 同用户并发start两场 | 最多一场running/paused |
| allow_retry=3，含中途abort | 最多4次已start；not_started不消耗 |

完整G1仍需两方言空库、存量升级、生成链及恢复实测；一个切片数据库通过只能记录该部分通过。

## 3 最短后端开发顺序

按以下顺序实现，每项以真实SQL测试通过后接下一项：

1. 登录、security_session/auth_version在线校验、强制改密、授权。组织seed不替代登录和scope。
2. rubric创建/发布、任务创建/发布；Task字段由服务端绑定并冻结。
3. session创建/start/pause/resume/finish，活动时段和次数事务。候选准备可先用明确的规则实现/测试替身验证生命周期，真实模型候选另验，不标已实现完整虚拟课堂。
4. recordings/init、local_parts上传/查询/complete、服务端SHA256和FFprobe校验。
5. session submit幂等、evaluation_report/attempt、SQL持久待办和发布投影。
6. 批阅pending→完整submit→set-primary，服务端计算人工分，score_version及outbox记录。

不要先把150个接口都写空实现。只实现上述契约真实需要的端点，未实现的明确报告；现有部署壳不能替代应用工程。

## 4 一次实际操作按这个时序

业务URL均加/api/v1。表中{}是前一步返回的真实ID，不是可以直接运行的脚本占位值。

| 顺序 | 调用/动作 | 应检查的结果 |
|---|---|---|
| 1 | 教师/学生登录，必要时改密重登，学生授权 | owner、department、scope正确，旧身份撤销有效 |
| 2 | POST /rubrics；POST /rubrics/{rubric_id}/publish | 六维/细则/等级线校验并发布 |
| 3 | POST /tasks；POST /tasks/{task_id}/publish | 学生分配、名单、视频要求、次数、标准冻结 |
| 4 | POST /sessions；POST /recordings/init | 轨道/required_tracks和upload_id真实生成 |
| 5 | POST /sessions/{session_id}/start | 原子分次数，打开活动span；候选ready与设备合格 |
| 6 | 浏览器真实录制，pause/resume一次 | 首轮最短合法5分钟，暂停排除于活动轴 |
| 7 | PUT /media-uploads/{upload_id}/parts/{part_no}，GET parts | 5秒采集blob按8MiB聚合上传，hash/顺序可查 |
| 8 | POST /sessions/{session_id}/finish | 只结束课堂，此时不得产生评测attempt |
| 9 | 等待stop末片与上传；各轨POST /media-uploads/{upload_id}/complete | 服务端算最终hash/时长，轨道封存 |
| 10 | POST /sessions/{session_id}/submit，同key重复一次 | 仅一个初次attempt，202后SQL待办可恢复 |
| 11 | GET /reports/{session_id} | report固定六维，缺分NULL；原始结果及来源可追溯 |
| 12 | 教师POST teacher-reviews、/{review_id}/submit、/{review_id}/set-primary | pending→reviewed；最终分来自主批，AI原分独立保留 |

首轮使用require_video=true、portrait+audio两条必需轨，screen/board明确no_input；不谎称测试了完整四轨。不足正式最短时长的短录音只能试设备和上传，不能修改业务约束让它通过正式提交。

## 5 先测结构，再切真实AI

第一次使用显式rules模式验证存储、NULL、批阅和事务；没有足够可评维度时partial是正确结果，人工主批仍须完整细则且保留AI来源。规则无法产总分不是自动判文档错，也不能补固定80分把流程染绿。

第二次换真实GLM适配器，用新录制完成ASR分段→内容/表达/环节/互动语义，以及可用人像视觉分析。必须获得至少4个真实可用维度且权重和>0，才可以把AI总分链路判通过。缺板书可NULL，无原生精确对齐如实approximate，不能说verified。

先5分钟检验可运行性，再用10分钟录制验证文档定义的时效口径，45分钟及50份样本随后做。不给未知模型强行承诺时间戳能力或费用；能力缺口写入问题单并补适配器/设计，不套其他录像缓存。

真实完整G2还要补实时观摩、统计/导出等原要求；上述切片只是前置探针，不能把它当完整P0验收。

## 6 每轮保留证据、判断问题在哪里

| 证据 | 目的 |
|---|---|
| 请求/响应、request_id，脱敏token和手机号 | 对照06/11字段、权限与错误码 |
| 迁移版本、SQL断言与唯一约束报错 | 证明真正落库及非法状态被拦 |
| 原媒体SHA256、分片清单、最终SHA256和FFprobe | 证明上传无损与真实时长 |
| session/report/attempt/review ID、score_version | 串起同一场次的事实 |
| 模型端点/版本/来源、时间锚点质量和耗时 | 区分规则、测试替身、缓存与真实AI |
| issue表：冲突文档位置、复现步骤、预期/实际、证据、处理 | 避免为了通过而改假数据 |

文档无法确定唯一预期或请求无法映射落库→契约问题；规则明确而代码不符→实现缺陷；依赖不可用→环境问题；真实模型无法提供必需证据/效果→能力风险。修复后回归同一例，不把失败项删掉。

建议开始指令：先实现A1最小验证切片，按3.x的05/06/11完成真实SQL、登录授权、标准/任务发布、session和本地分片、显式submit、rules partial、教师主批；保留负例测试，逐项记录真实通过范围。之后再接真实GLM，不先开发训练/证书/完整后台。
