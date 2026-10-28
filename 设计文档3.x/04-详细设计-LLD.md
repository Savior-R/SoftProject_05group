# 师范专业 AI 试讲台系统 — 详细设计（LLD）

| 文档信息 | 内容 |
|---|---|
| 文档版本 | 3.2.0（设计文档 3.x） |
| 修订日期 | 2026-10-28 |
| 文档职责 | 算法、事务和可验证参考函数 |
| 修订依据 | 本目录 01、05、06、11、12；工程实施按 ADR-010/011/012；旧版已清理 |
| 本版变更 | 统一生命周期、评分、媒体、权限与部署契约；具体映射见 12-修订追踪与验收门禁 |
| 状态 | 设计修订完成；应用开发、DDL 生成与数据库实跑、模型效果和性能验收仍须过门禁 |

## 1 工程结构

```text
app/
  backend/
    app/main.py  app/settings.py
    app/identity_org/ task_content/ classroom/ media/ evaluation/ growth_cert/ platform/
    common/             # DTO、错误、Decimal、权限、StorageAdapter
    app/worker.py        # arq入口、A1恢复调度器
    migrations/         # 单一依赖图，方言条件迁移
    data/               # 姓名、素材清单、seed规格
  frontend/             # 唯一正式前端：Vite+Vue3+TS；产物 dist/，见 ADR-010
  deploy/               # Python3.12镜像与环境配置，需按09重建
```

API→service→repository→model，DTO不暴露ORM对象；配置统一Settings，禁止散落读取环境变量。model显式schema，字段拼写为start_at/end_at，不使用started_at/ended_at代替场次字段。所有新增工程表见05，不从旧代码片段生成模型。

## 2 事务与并发

### 2.1 start与次数

事务中锁user行（MySQL SELECT ... FOR UPDATE，同一连接事务内执行），校验security_session、授权、目标任务和所有running/paused场次；分配task+user的下一个attempt_no。已开始次数包括finished/aborted，不包括not_started。原子写session.status/start_at、time_span、首次任务ongoing、session_event和outbox。唯一活动场次索引再兜底。并发两个start最多一个成功，第二个409 session-already-running。

创建时允许多个not_started，但不预占次数。task截止后不允许start，即便草稿提前创建。服务端覆盖task固定模式和时长；不允许通过传自由练习参数绕过指定题集。自由练习rubric_id必填且已published。

### 2.2 报告发布与人工批阅

report先有稳定ID；evaluation_attempt记录排队/执行。将结果写不可变result_json+sha256，成功发布时锁report，原子替换当前指标/问题投影，记录published_attempt_id，重新读取有效主批，计算teacher_score/final_score/grade，递增score_version，写score.changed outbox。新partial/failed不替换旧成功投影。

review创建pending允许total_score=NULL；submit必须覆盖全部rubric item，排除未知ID、负分、超满分，计算人工总分；客户端不提交权威total_score。set-primary先取消旧主批再设新主批，同一事务；唯一索引冲突统一409。returned先reopen才能再submit。report上人工review存在时不能因AI重算而被清空。

### 2.3 事件与派生数据

outbox在业务事务内写，投递失败指数退避，最多10次后dead_letter并告警，可人工重放。消费者用consumer_receipt(consumer,event_id)唯一键；聚合写入和receipt同事务。score.changed包含完整effective_score与六维快照、report_id/score_version、关联task/class/department/学生和generated_at，growth不跨库在线JOIN。缺上下文通过内部接口读取。

每个report版本单调；乱序到达的旧事件只记已处理，不覆盖新版本。班级平均/提交率/榜单/曲线按受影响用户与周期重建，目标60秒；失败标stale并告警。证书快照由证书服务独立保留，来源不再有效则pending_review。

## 3 行为引擎

每场1–60实例，六类人设按场次RNG种子生成，姓名20姓×30名池中sample不重复，seat_no连续。persona比例可配置但总数必须匹配。行为概率每秒推进，脚本事件按活动时间单独高精度调度；预生成候选文本池ready之前不能start。

```python
import random
from dataclasses import dataclass, field

@dataclass
class VirtualStudent:
    vs_id: str
    persona: str
    rng: random.Random = field(default_factory=random.Random)
    engagement: float | None = None

    # base, ask概率, challenge概率, discipline概率；每秒一次
    BASE = {
        "focused": (88, .010, .000, .004), "active": (78, .020, .002, .008),
        "distracted": (55, .004, .000, .030), "challenger": (70, .014, .008, .006),
        "quiet": (60, .002, .000, .010), "naughty": (45, .006, .001, .045),
    }

    def __post_init__(self):
        base = self.BASE[self.persona][0]
        if self.engagement is None:
            self.engagement = max(20., min(100., base + self.rng.uniform(-5, 5)))

    def tick(self, intensity: float, handled_bonus: float = 0.):
        if intensity not in (.7, 1., 1.4):
            raise ValueError("intensity")
        _, ask, challenge, discipline = self.BASE[self.persona]
        self.engagement = max(20., min(100., self.engagement - .0049 * (1 + intensity) + handled_bonus))
        probabilities = [ask * self.engagement / 100, challenge, discipline]
        # 强度仅放大事件概率；高强度不会反向稀释随机命中
        rates = [min(.25, p * intensity) for p in probabilities]
        r = self.rng.random()
        if r < rates[0]:
            kind = "ask"
        elif r < rates[0] + rates[1]:
            kind = "challenge"
        elif r < sum(rates):
            # 按当前专注度确定子类，保持每tick只消耗一次事件随机数
            kind = ("distracted", "whisper", "noisy")[int(self.engagement) % 3]
        else:
            return None
        return {"event_type": kind, "vs_id": self.vs_id}

```

作答质量概率：focused .75/active .55/distracted .30/challenger .45/quiet .40/naughty .25为正确率；剩余按partial .6/wrong .4分配。题目相关候选池每人至少6条，创建后后台生成，失败返回候选池failed而不是开课后等待LLM。取完候选池可循环取不同模板，禁止点名链路同步调用外部模型。

事件统一raise_hand/ask/answer_right/answer_wrong/answer_partial/distracted/whisper/noisy/challenge/device_fault。处理事件以独立event.handled记录，原始行为事实不原地篡改；handled/response_ms作为当前投影更新有审计记录。

## 4 活动时间与状态

具体迁移见11 §3。活动毫秒数=Σ闭合session_time_span(end_at-start_at)+当前打开span的now-start_at。pause关闭span并给所有recorder pause，resume打开新span；由服务端返回media_offset_ms，客户端用performance.now插值展示，不自定最终时长。暂停本身不计入录制时间。

设备/服务重启后无法证明连续录制的running/paused在runtime_json.device_flags标recovery_required，拒绝自动续作；默认abort并保留已上传片段，用户新建场次。活动span关闭于最后持久化heartbeat_at（每2秒），记录reason=process_restart。A2仍不能声称只凭Redis即可恢复浏览器原始媒体流。

达到planned_duration_s发超时；活动时间达min(2倍计划,45分钟)则强制finish并按完整性决定能否submit；paused墙上时间超过30分钟abort。finish/abort在同事务关闭span，写actual_duration_s=floor(active_ms/1000)。

## 5 评测DAG和全局限流

```python
import asyncio

class EvaluationPipeline:
    def __init__(self, steps, limiter):
        self.steps = steps
        self.limiter = limiter  # 进程共享或Redis分布式；不是每次run新建

    async def run(self, attempt):
        ctx = await self.steps.preprocess(attempt)
        asr, posture, board = await asyncio.gather(
            self.steps.transcribe(ctx, self.limiter),
            self.steps.posture(ctx, self.limiter),
            self.steps.board(ctx, self.limiter),
            return_exceptions=True,
        )
        # 每路异常转换成typed unavailable；文本依赖只在有效ASR后执行
        inputs = await self.steps.normalize(asr, posture, board, ctx)
        if inputs.asr_available:
            inputs.text = await self.steps.analyze_text_and_events(inputs, self.limiter)
        result = await self.steps.score_validate(inputs)
        await self.steps.publish_or_preserve(attempt, result)
```

上例steps是有类型的适配器接口，具体DTO见11；不是可直接启动的完整应用。A1/A2/B均使用同一依赖图，arq只负责领取attempt与重试。FFmpeg最大并发默认1/节点；ASR/视觉/LLM每个请求都必须获得对应全局租约，按实际配额配置，不把50路流水线等同50个API调用配额。

本版不使用Celery canvas；若未来选用Celery，新增ADR并以集成测试证明回调形参，不能混用.si与“自动接上游结果”的假设。

单步网络/5xx/429按Retry-After、1s/3s退避最多2次；模型输出格式修正最多1次。总时间600s到期取消未开始请求，本次attempt失败；正在运行的外部请求记录late_result并禁止覆盖较新尝试。租约token、attempt_id和generation fencing在写入前再检查。

## 6 评分参考函数

```python
from decimal import Decimal, ROUND_HALF_UP

DIMENSIONS = ("content", "expression", "posture", "interaction", "board_ppt", "time_management")

def dec(x):
    value = Decimal(str(x))
    if not value.is_finite():
        raise ValueError("non_finite")
    return value

def dimension_score(items, scores):
    rated = []
    for item in items:
        maximum, weight = dec(item["max_score"]), dec(item["weight_in_dimension"])
        if not (0 < maximum <= 100 and 0 <= weight <= 1):
            raise ValueError("invalid_item")
        value = scores.get(item["item_id"])
        if value is not None:
            value = dec(value)
            if not 0 <= value <= maximum:
                raise ValueError("score_out_of_range")
            rated.append((value / maximum, weight))
    total_weight = sum((w for _, w in rated), Decimal(0))
    if total_weight <= 0:
        return None
    result = 100 * sum((n * w for n, w in rated), Decimal(0)) / total_weight
    return result.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)

def aggregate(scores, weights):
    if set(weights) != set(DIMENSIONS):
        raise ValueError("dimension_keys")
    w = {d: dec(weights[d]) for d in DIMENSIONS}
    if any(v < 0 or v > 1 for v in w.values()) or abs(sum(w.values()) - 1) >= Decimal("1e-9"):
        raise ValueError("invalid_weights")
    available = [d for d in DIMENSIONS if scores.get(d) is not None]
    for d in available:
        if not 0 <= dec(scores[d]) <= 100:
            raise ValueError("score_out_of_range")
    total_weight = sum((w[d] for d in available), Decimal(0))
    if len(available) < 4 or total_weight <= 0:
        return None
    total = sum((dec(scores[d]) * w[d] for d in available), Decimal(0)) / total_weight
    return total.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)

def grade_of(score, bands=None):
    b = bands or {"pass": 60, "good": 80, "excellent": 90}
    if set(b) != {"pass", "good", "excellent"}:
        raise ValueError("invalid_bands")
    p, g, e = (dec(b[k]) for k in ("pass", "good", "excellent"))
    if not 0 <= p < g < e <= 100:
        raise ValueError("invalid_bands")
    if score is None:
        return None
    s = dec(score)
    if not 0 <= s <= 100:
        raise ValueError("score_out_of_range")
    return "excellent" if s >= e else "good" if s >= g else "pass" if s >= p else "fail"

```

细则权重同维度和1；维度权重全六键和1；满分必须>0。人工最终分必须全量细则，AI允许缺失项重归一，缺失原因写入item_scores。human项AI不得填分。所有四舍五入ROUND_HALF_UP，先维度两位再聚合两位。

规则表达/互动函数签名必须显式包含rubric_items；参考实现及空值保护见11 §6。movement_score不可从孤立静态帧推断；无帧/无板书就是unavailable。不得给缺内容维填关键词默认高分。

## 7 分片、提交与回放

init先创建recording（duration_ms=NULL、status=uploading）和media_upload；相同session+track重复init返回现有upload。浏览器5秒blob按顺序写IndexedDB并聚合8MiB作为part，保留最后不足8MiB片段到stop。local和S3均按同一part编号清单完成，checksum由服务端流式计算，校验FFprobe真实时长。

local分片使用临时路径+原子rename，不把乱序分片直接append到目标文件；同part_no/hash重复返回原结果，hash不一致409。S3 list-parts由服务端对账，ETag当不透明字符串，不当SHA256。

stop等待最后dataavailable和全部上传promise，再complete逐轨；完整manifest封存后调用session submit。submit以session+manifest_hash幂等，唯一活动attempt由report锁保证；无需让客户端直接发“开始AI”内部事件。

play-url先校验本人/管辖/院系范围，local用短期签名下载路由并支持Range；不公开挂载data/media。转码产物与原始录制checksum分开保存，封装格式来自FFprobe，不能把WebM只改.mp4扩展名。

## 8 WS重连与WebRTC

连接票据由POST sessions/{id}/ws-ticket签发，60秒内一次性使用，绑定session/uid/peer/role；过期重连重新申请。每个持久业务帧包含seq、offset_ms、event_id，广播前SQL提交；new WebSocket客户端在snapshot(reset)时先处理reset再去重，不能因旧seq将重置快照丢弃。

重连流程：事务读取high_water_seq和保留最小序号→补齐(since_seq,high_water_seq]→ready(replay_complete)→实时；利用连接缓冲收集切换窗口的新帧并按seq去重。有洞或游标过旧发送reset snapshot。replay容量每页500，最多5000条，更多直接snapshot。timer为瞬态不占重放seq。

WebRTC信令需要offer/answer/ice/renegotiate/closed，目标peer必须属于同一会场的已授权observation；每条16KiB上限，ICE最多60条/分钟/peer，和课堂点名30条/分钟分开限流。浏览器收到pause同步停止媒体发送，resume重新协商必要轨道。

## 9 锁、幂等和恢复

锁SET NX PX 30000，10秒token校验续期；release使用比较token原子删除，禁止无条件DEL。SQL行锁、唯一键和attempt fencing才是最后保护。memory为单进程同义实现；进程失效后SQL恢复器将租约过期attempt标failed并按策略重投。

Idempotency-Key以(user,method,path,key)命名，payload_sha256不同409；存进SQL outbox/对应业务唯一键的请求元数据，保留24小时。分片、start、submit、人工submit均必须支持幂等，不能只依赖内存缓存。
