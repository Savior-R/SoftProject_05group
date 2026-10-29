# 步骤2：B–F开工交接包

日期：2026-10-29。**最低必须包含的基线：`9e298d2dd1303e0d87f29e4530fe4fae906041d2`**（PR #2已合并，本交接包与模型样板自此版本进入main）。

该值是“必须包含”的历史提交，不是“main当前版本”。main每次合并都会前进，但`9e298d2`永远是其后代的祖先，校验命令长期有效；不要把它理解为main停止在9e298d2。PR #1合入的`712da35`与A实现`42cbdc5`作为历史来源保留；不要继续从已删除的旧任务分支开工。

本包是可转发内容，**尚未向群聊发送，未取得成员接收确认**。C–F按用户本轮说明暂未邀请，不猜测用户名或替成员确认。当前`wsc20061204`已具Write权限；角色与成员环境由团队本人确认。main继续要求至少1位非作者PR审批。

## 需要先读的四个入口

1. [环境预检表模板](environment-template.md)：本人复制为`environment-<角色>.md`，填本机实际结果和证据，不能由A代填。
2. [A交接说明§3/§5](../步骤2-A公共数据库基础与交接.md)：统一Base、同步事务及逐表分工。
3. [模型与特殊约束样板](步骤2-模型样板与约束示例.md)：通用生产范例、四种生成列唯一键和循环外键；样板已随PR #2合入main，直接从main读取即可。
4. 设计05字段字典、04事务流程、13步骤2：逐表核对最终实现；示例没有列出的字段不能省略。

## 获取正式基线并开分支

首次获取：

```powershell
git clone https://github.com/Savior-R/SoftProject_05group.git
Set-Location SoftProject_05group
git switch main
git pull --ff-only origin main
# 必须包含已验证的9e298d2（含本交接包与模型样板）；非零时停下核对远端和分支。
git merge-base --is-ancestor 9e298d2dd1303e0d87f29e4530fe4fae906041d2 HEAD
# 按自己职责选择一个，例如identity-models、task-models、classroom-models、media-models、evaluation-models。
git switch -c codex/identity-models
Set-Location app/backend
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --require-hashes --only-binary=:all: -r requirements.lock
```

没有`py`时，用本人确认的Python3.12可执行文件绝对路径替代首个建venv命令，不能换用3.13/3.14。默认lock仅验证Windows x64/CPython3.12；其他平台不能据此写“通过”。安装索引按团队确认源或本机`PIP_INDEX_URL`设置，不提交含凭据地址。日常源码修改与wheel复验方式按backend/README执行，不能只修改源码后测试旧安装包。

当前只需纯单元/模型核对可先运行：

```powershell
.\.venv\Scripts\python.exe -m pytest tests/unit -q
.\.venv\Scripts\python.exe -m tools.db_manifest --models
```

`9e298d2`已独立复验：104项单元+20项集成=124通过（`712da35`时为120，PR #2新增4个模型样板用例）。manifest当前61/4/57、退出1，是尚缺B–F模型的真实状态；freeze退出1、Step2退出2。新增样板分支的测试总数另外记录，不冒充712da35已有样板。真实集成需要A安排的私有MySQL配置，未运行必须填“未运行”，不能跳过后称全套通过。

## 各角色交给A的内容

| 主责 | 数量 | 本域及growth_cert范围 | 交付 |
|---|---:|---|---|
| B | 16 | identity_org14；certificate、certificate_report | 模型、身份组织/证书约束、有效关系数据；核对跨域引用目标 |
| C | 11 | task_content9；follow_along_material、weakness_push | 字段/标准版本/默认/FK及内容约束测试 |
| D | 9 | classroom7；mock_exam、mock_exam_question | 活动场次、open span生成列唯一键，状态/时间/考核关联测试 |
| E | 6 | media5；training_record | 媒体/训练状态、数据完整性及关联约束测试 |
| F | 15 | evaluation12；progress_record、class_stats、leaderboard | 有效主批、运行attempt唯一、pending/六维NULL、投影版本；维护growth_cert聚合导入 |

逐表提交字段/类型/nullable/default/PK/FK/unique/index/生成列/CHECK核对、正负例和关系数据，不只报表数。growth_cert子文件和聚合导入按A说明§5。所有正式模型使用公共Base，不另建业务engine。A审查全61表后才冻结DDL和执行G1；成员不修改初始快照来绕过缺表。

## 环境与权限交接

A机已经准备`test_g1_`七个**空库**及独立迁移/业务两账号，凭据只在A机私有配置。此事不等于成员远程可访问，不开放端口、不发群共享管理员口令。成员需要的连接由A与本人另行受控交接；正式迁移后还需补platform表级业务授权。各成员本机实测表仍待本人填写。

成员本机跑集成测试时：先用`docker ps`确认MySQL容器为Up（容器未启动会报`OperationalError 2003`，是必现问题不是代码缺陷）；测试会自建随机`test_a<token>_`七库与临时账号并在结束时清理，因此需要**本机root口令**，通过`STEP2_BOOTSTRAP_ENV`指向仓库外的私有配置文件（仅含`DB_ROOT_PASSWORD`/`DB_DEV_HOST`/`DB_DEV_PORT`）。不要指向A机实例或任何共享库。

Write权限只有在仓库权限列表实际显示Write后才成立；邀请发出还需本人接受，C–F当前未邀请。PR非作者审批及合入须由有权限的真实成员完成，不能由作者自批。A可以准备PR，但不能保证“五人都确认收到”。

## 接收与环境回执（本人填写）

| 角色 | GitHub账号（本人确认） | 已接收交接包/日期 | 环境表路径 | 模型PR/依赖 | 状态 |
|---|---|---|---|---|---|
| B | 待确认（当前已知Write协作者wsc20061204） | 待本人确认 | 待填写 | 待提交 | 待回执 |
| C | 暂未邀请 | 待发送/确认 | 待填写 | 待提交 | 待账号与回执 |
| D | 暂未邀请 | 待发送/确认 | 待填写 | 待提交 | 待账号与回执 |
| E | 暂未邀请 | 待发送/确认 | 待填写 | 待提交 | 待账号与回执 |
| F | 暂未邀请 | 待发送/确认 | 待填写 | 待提交 | 待账号与回执 |

可直接转发：

> 步骤2 A公共基础已通过PR #1、#2合入main，基线需包含9e298d2（含本交接包与模型样板）。请更新main后按自己的codex分支开工，先读本交接包及A说明§3/§5，复制环境模板填写本人实测结果。当前生产模型仅4/61表，G1未通过；请按职责提交模型、逐表约束核对、正负例和关系数据。收到后请回复角色、GitHub账号、环境表及模型PR位置。不要把私有数据库配置或口令发群。
