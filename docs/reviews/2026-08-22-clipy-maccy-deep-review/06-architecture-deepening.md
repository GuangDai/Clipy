# 架构深化：把复杂度藏到正确的 seam 后面

> 本文只给后续实现 Agent 架构与 TDD 方向，不修改产品代码。它使用
> `codebase-design` 的固定词汇：**module** 是有 interface 与 implementation 的任意
> 尺度代码；**seam** 是可替换行为所在的位置；**depth** 是 caller 每学一单位
> interface 能获得多少行为；**leverage** 属于 caller；**locality** 属于维护者。
> 本文不建议生成新的 HTML 报告，也不建议以类型数量或目录层数代表架构质量。

## 1. 结论与排名

现有 History downward graph 不应推倒重来，`HistoryCore` 也不应继续承担与 History 无关的公开抽象。
但格式能力与 Preview 已经出现多个真实 caller、Apple framework confinement 与独立演进版本，因而在
**规格先批准**的前提下，两个 package-only concrete targets——`ClipboardFormats` 与
`ContentPreview`——通过了新增 module 的准入门槛。多级内容存储有真实的潜在 leverage，但当前 G8
测量尚未证明需要替换 SwiftData baseline；它必须先作为 storage-owned、type-agnostic 的条件式深化，
不能先以“无限历史”名义落一套通用 cache framework。Python 自动化则属于未来 V2 External Gateway 的
外部 adapter，不属于 clipboard capture/paste flow。按“错误影响 × caller 数 × 可隐藏复杂度 × 最小
改动可证明性”排序如下：

| 排名 | 深化候选 | 判断 | 推荐 seam | 近期动作 |
|---:|---|---|---|---|
| 1 | 现有 `AppComposition` flow ownership；必要时提取 concrete `ClipboardFlow` | **先原地深化；提取是有条件推荐** | `ClipyApp` 内现有 composition seam | 第一 vertical slice 先删除 mailbox/nested task/复制 wiring；只有 concrete extraction 能完全替换旧 owner 与测试时才保留新类型。 |
| 2 | startup 只读 classification phase | **立即深化现有 startup** | `HistoryAuthority.performStartup`/open flow 内、任何 bootstrap write 前 | 返回 private validated value，再决定合法 bootstrap；不新增 classifier service/protocol，也不做 pre-open 文件探测。 |
| 3 | search execution locality | **立即深化现有 facade/worker** | `SwiftDataHistory` 的 private search function/value + 既有 `SearchWorker` | facade 内统一 admission/empty/cursor/snapshot 顺序；scan-loop cancellation 仍由 `SearchWorker` 实现。 |
| 4 | Presentation mutation/lifecycle ownership | **立即修正所有权，不新增 module** | 既有 `HistoryViewState`、`AppDelegate`、`FloatingPanel` | awaited mutation、owned pagination；删除 SwiftUI 重复 lifecycle owner，保留现有 AppKit owner。 |
| 5 | 单个 retention pure invariant | **发现真实重复才逐项提取** | 三个 commit lane 已有 composition 中的 private pure helper | 一次只抽一条重复 arithmetic/relation；不建 `RuntimeRetention` coordinator、trigger bag 或统一 pipeline。 |
| 6 | source-content tiering / residency | **P3 design-only；G8 触发后优先采用 B** | `HistoryStorage` 内 type-agnostic `ContentDepot` + bounded materialization/lease seam | 先证明 SwiftData baseline 的 fault/RSS；只有超预算才做 metadata + loose immutable blob depot。segment design 只做 soak 对照，不先实施。 |
| 7 | declarative `ClipboardFormats` facts/catalog | **规格批准后新增 package-only Foundation target** | exact identifier、稳定 family/wire/special-role facts | 把源码中“知道哪些格式”变得可搜索、可快照、可导出；unknown 保持 opaque raw，不把 purpose policy 集中成一个开关。 |
| 8 | concrete `ContentPreview` | **规格批准后新增一个 package-only target** | immutable source + constraints → bounded inert `Sendable` artifact/outcome | 集中 Preview source selection、budget、安全 policy 与 Apple renderers；`PreviewContentLoader` 继续拥有 History exact-reference 与 UI lifecycle。 |
| 9 | Python local automation adapter | **先规格化wire；实现先Gateway/App Intents，后CLI/transport** | `clipyctl` JSON contract → private local transport → `ExternalGateway` | 可先审查JSON/exit形状，但实现顺序是Gateway trust substrate→已接纳App Intents→CLI pure codec→chosen production transport。不得并入`ClipboardFlow`。 |
| 10 | build-log diagnostic parser | **聚焦工具层候选** | 现有 workflow 调用的一个窄 parser | 统一 warning/error 窄例外的判定与 fixtures；symbol、scanner、perf gate 各自在 owner 内 harden，不建 validation framework。 |

排名不是实施大 batch 的顺序替代物。每项都应遵守
[`04-tdd-remediation-playbook.md`](04-tdd-remediation-playbook.md) 的一行为一 cycle：先写
能编译、因目标行为失败的 Red，再做最低 Green，最后单独 review/refactor。候选 1–4 也不应
塞进同一个 PR。

这里的排名是“先把正确 seam 变深”的风险顺序，不是“先创建新类型”的排名。尤其候选 1：若在
`AppComposition` 内用私有方法与 owned task 就能获得完整 ownership，它已经足够；不能因为想象中的
future caller 提前创建 `ClipboardFlow`。新 concrete type 只有在迁移完 production caller、生命周期、
错误状态与 tests，并删除旧 wiring 后才算通过 deletion test。候选 6–9 是后续扩展边界，不能抢在
当前 CI/correctness 修复之前以“大架构提交”落地；它们之所以值得独立，是已有跨 owner 漂移、Apple
framework 隔离或外部 trust boundary 的具体证据，而不是“以后可能有很多格式/Python caller”。候选 6
还必须通过 G8 admission，不能与 7–9 捆成一次平台重写。详细多级存储、格式/Preview 与 Python 证据分别见
[`09-tiered-storage-and-unbounded-history.md`](09-tiered-storage-and-unbounded-history.md)、
[`08-content-types-and-preview.md`](08-content-types-and-preview.md) 与
[`07-python-local-automation.md`](07-python-local-automation.md)。

## 2. 评估方法

### 2.1 深 module 的准入问题

每个候选必须同时回答：

1. **Common caller 是谁？** 没有共同 caller 的“统一”通常只是把不相干代码放进一个大类。
2. **Interface 能否明显小于 implementation？** 如果 caller 仍需知道每一步顺序、重试、
   cancellation、错误翻译和状态转移，新类型只是 pass-through。
3. **Dependencies 属于哪一类？** 本仓库主要是 in-process 或 local-substitutable：纯值可直接
   测，SwiftData 用真实 in-memory/temp store，pasteboard 用 private `NSPasteboard`。
4. **Deletion test 是否成立？** 删除 module 后，复杂度应重新散回多个 caller；若复杂度反而
   消失，module 没有赚到 interface 成本。
5. **是否真有 seam？** 只有一个 production implementation、也没有第二个真实变化来源时，
   不新增 protocol。测试可以使用 module 的 internal seam，不能因此扩大 external interface。

### 2.2 Replace，不能 layer

深化完成后，测试应从旧浅 implementation 迁到新 interface。旧测试若只是复述内部步骤，
应删除或降为少数算法单测；不能在新 owner 外再保留一套 production wiring 的手工副本。
本轮最直接的反例是
[`AppPasteOrchestrationTests`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppPasteOrchestrationTests.swift)：
它重建了 stream、payload read 和 adapter write，却没有驱动
[`AppComposition`](../../../ClipyApp/Sources/AppComposition.swift) 的真实 implementation。

## 3. Rank 1 — 先深化 `AppComposition`，再判定是否提取 `ClipboardFlow`

### 3.1 Evidence 与 common caller

[`AppComposition.start`](../../../ClipyApp/Sources/AppComposition.swift) 当前同时装配两套浅流程：

- paste：`HistoryViewState.onPaste` → 默认无界 `AsyncStream` → consumer → `paste(_:)` → 再开
  一个 nested `Task`；consumer 并没有 await write 完成，A、B 两次请求没有明确顺序；
- capture：observer 每交付一个 complete outcome 就新建一个 `Task`，没有 active/pending count、
  aggregate bytes、stop ownership 或失败状态；
- lifecycle：stream continuation、consumer task、capture tasks 都没有一个可见 owner；注释依赖
  对象释放形成的间接终止；
- tests：private pasteboard 是正确的 local stand-in，但测试复制 orchestration 步骤，恰好绕开
  production race。

这两条 flow 的当前 common caller 不是 `PasteboardAdapter`，也不是 `ClipboardHistory`；就是
**现有应用 composition root**。它需要的共同能力是：把 UI intent/observed clipboard value 转成一条
受生命周期、顺序、容量和结果约束的应用操作。`PasteboardAdapter` 继续只做 AppKit value
translation，History 继续只做 durable semantics。这个事实首先证明应当深化 `AppComposition`，并不
自动证明需要一个新类型：若私有函数、一个 owned capture task 与一个 owned paste task 已能隐藏完整
流程，新类型没有额外 leverage。

Dependencies 分类：

- `ClipboardHistory`：local-substitutable；语义测试优先使用真实 in-memory
  `SwiftDataHistory`，不要再写第二个 fake writer；
- `NSPasteboard`：local-substitutable；测试用 private pasteboard；
- `PasteboardObserver`、MainActor panel-close hook：in-process；
- 无 remote/external dependency，因此没有 ports-and-adapters 的理由。

### 3.2 Design It Twice：问题约束

任何设计都必须满足：

- AppKit values 留在 MainActor；跨 actor 只走 immutable `Sendable` values；
- paste 的 resolve → stage → write → completion 是一个被 owner 跟踪的 intent；失败不得 close；
- paste v1 先固定 **exclusive first-accepted**：已有 paste in flight 时后续请求明确拒绝/显示 busy，
  不建无界 FIFO；若用户研究以后要求队列，再以新行为卡批准；
- capture 只能在 successful freeze 后入队；必须有 count/byte budget，但 overload policy 尚需
  判别实验；
- observer startup 的 immediate-import vs baseline，以及 paste current-by-ID vs exact-reference，
  都是产品决策，不应藏在“灵活参数”的默认值里；
- start/stop 必须取消 owner 所持 work；停机后 late completion 不得发布 success/close；
- 测试使用同一 production interface、private pasteboard、真实 in-memory SwiftData；
- 没有两个 real implementations 前，不引入 `ClipboardFlowProtocol`、generic executor 或 endpoint
  registry。

以下 sketch 只表达 interface 形状，不是要求照抄的代码。

### 3.3 方案 A — 分开 `CaptureFlow` 与 `PasteFlow`

```swift
@MainActor final class CaptureFlow {
    func start()
    func stop()
    private(set) var health: CaptureHealth
}

@MainActor final class PasteFlow {
    func request(_ item: HistoryItemReference) -> PasteAdmission
    func stop()
    private(set) var state: PasteState
}
```

**Interface 与 invariants：** capture owner 隐藏 observer、stable freeze admission、budget 和
history write；paste owner 隐藏 exact/current resolve、完整 item staging、write 与 close。两者都
明确 stop；paste admission 同步返回 accepted/busy，便于同步 UI callback 使用。

**Implementation 隐藏：** 两组 task handles、两组 error/result mapping、各自的 cancellation 与
instrumentation。

**优点：** 每个 interface 极窄，capture 与 paste 的资源/错误语义不会被一个巨大状态 enum 混合；
单独测试容易。

**缺点：** `AppComposition` 仍必须学习两个 lifecycle；access health、自写 round-trip、lineage hint
与 observer start/stop 的协调容易重新出现在 caller。若最终两者共享 pasteboard access state、
pause 与 shutdown，locality 不够。

**Deletion test：** 删除任一个会让对应 task/budget/error 复杂度回到 `AppComposition`；通过。
但删除二者之间的共同 coordination 并不会产生新复杂度，因为它从未被拥有——这是本方案的薄处。

### 3.4 方案 B — 极简统一、由caller持有lifecycle task

```swift
@MainActor final class ClipboardFlow {
    func runCapture() async -> CaptureTermination
    func paste(_ item: HistoryItemReference) async -> PasteResult
}
```

**Interface 与 invariants：** `runCapture()`是一条长期operation，内部拥有observer与唯一drain；
caller只持有这一条lifecycle task并通过cancel+await停止。`paste()`本身完成resolve→write并返回typed
result，但caller仍需在调用前管理single-flight，并在返回后决定close/health。

**优点：** interface最小；capture不会退化成“一次tick一个Task”；每次paste result可直接断言；
没有隐藏的第二层task。

**缺点：** 对本项目的common caller仍不够深。`AppComposition`继续拥有paste admission、paste task、
result→panel-close/health映射以及capture task的exactly-once start/stop；多个UI入口仍可能各自spawn
`Task { await flow.paste(...) }`，绕开single-flight。它能修掉capture task storm，但不能独自保证所有
copy caller共享同一个排他owner。

**Deletion test：** 若 B 被提取成新类型，删除后 capture drain/stable freeze 会散回 caller，但 paste
admission/close 原本就在 caller，因此新类型只部分通过。若 B 直接作为 `AppComposition` 的 private
shape，则没有额外类型需要证明，反而是公平的极简终点：前提是所有 UI paste entry 都只路由到这一个
caller，而且它确实持有 single-flight、close 与 lifecycle。测试能证明这点时，不应为了“更深”再提取。

### 3.5 方案 C — 策略化统一 flow

```swift
@MainActor final class ClipboardFlow<
    CaptureQueuePolicy,
    StartupPolicy,
    PasteVersionPolicy,
    PasteSchedulingPolicy
> {
    func start(configuration: FlowConfiguration)
    func submit(_ intent: ClipboardIntent) -> ClipboardAdmission
    func stop()
}
```

**Interface 与 invariants：** 用 policy types/closures 表达 FIFO/latest/reject、immediate/baseline、
current/exact、exclusive/queued，统一 submit capture/paste intents。

**优点：** 能在一个 harness 中比较多种语义；理论扩展性最高。

**缺点：** 当前每个轴只有一个 production choice。caller 与测试必须理解交叉乘积，interface 近似
implementation；许多非法组合需要额外 validation。它把尚未做出的产品决策永久化成扩展机制，
depth 低、认知成本高。

**Deletion test：** 删除后大部分 generic/policy vocabulary 直接消失，只有少量真正流程复杂度回到
caller；不通过。判别实验应该是 disposable test table，不是 shipped strategy framework。

### 3.6 推荐 — 两阶段、条件式 concrete extraction

**第一 vertical slice 采用方案 B 的纪律，但可以完全留在 `AppComposition` 内。** 先把 paste 变成一条
可 await 的私有 operation，把 admission、single-flight、completion/close 与唯一 capture drain 的 task
handles 收归同一个现有 owner；production test 必须调用真实 `AppComposition` entry point，而不是重建
pump。若完成后 `AppComposition` 的 public/visible surface 仍迫使多个真实 caller 理解这些步骤，才提取
一个 app-internal concrete `@MainActor ClipboardFlow`。它不采用 C 的 generic policy 面：

```swift
@MainActor final class ClipboardFlow {
    init(
        history: any ClipboardHistory,
        adapter: PasteboardAdapter,
        observer: PasteboardObserver,
        onPasteCompleted: @escaping () -> Void
    )

    func start()
    func requestPaste(_ item: HistoryItemReference) -> PasteAdmission
    func stop()

    private(set) var health: ClipboardFlowHealth
}
```

条件满足时，建议的 interface contract：

- `start()` exactly once/idempotent，并由 owner 持有唯一 capture drain；`stop()` 停 observer、拒绝
  新intent并收束owned tasks。已开始的History commit不能被谎称为“确定未提交”；paste若已越过同步
  write线性化点，则最终write receipt仍支配结果；
- `requestPaste` 同步接收 UI callback，v1 固定 exclusive first-accepted；一个 accepted intent 在
  implementation 内串行执行 payload resolve、full `NSPasteboardItem` staging、一次 write、success
  hook；busy/failure 进入 content-free health，不记录 UTI bytes 或 clipboard data；
- capture 使用固定 budget，但 **先**用 queue=2/三次 frozen captures 的判别测试选择 bounded FIFO、
  active+latest 或 explicit reject/pause；选定后删除其它实验分支；
- immediate-import/baseline 与 current-by-ID/exact-reference 各写正反 Behavior Card；规格批准后只保留
  一个分支，不把二选一做成 runtime setting；
- `AppComposition` 退回 construction + lifecycle forwarding；`HistoryViewState.onPaste` 只调用
  `requestPaste`，不再看 stream/task details。

它组合 A 的语义清晰与 B 的小 interface：一个 common caller 只学习一个 lifecycle，而
implementation 内仍可用私有 `runCapture`/`paste` 小函数。它提供 leverage：同一 interface 同时
保证 ordering、backpressure、error visibility 和 shutdown；提供 locality：pasteboard policy 与应用
生命周期只在一个地方变。但这些收益必须由**删除后的 production graph**证明，不能由类型名推断。

**最小 TDD：**

1. Red：通过真实 `AppComposition` surface，用 in-memory `SwiftDataHistory` + private pasteboard 连续提交
   A/B；A accepted、B busy，只有 A bytes 写入、只 close 一次；不得手写 pump。
2. Green：先在 `AppComposition` 内实现一个 owned paste task + synchronous admission；不要先加 queue
   或新类型。
3. Red：park A 在 payload resolve，`stop()`，放行 A；不得写 board、不得 close、health 不报 success。
4. Green：owner generation/cancellation fence。
5. Decision Red：capture budget 2 + 三个 frozen values，分别记录三种候选的可观察结果与 RSS budget；
   批准一种后只实现该种。
6. Refactor decision：若现有 owner 已够深，停止；若提取 `ClipboardFlow`，必须同时删除旧
   `AppComposition.paste`、mailbox、重复 owner 与复制 orchestration tests，并把 byte-exact、lineage
   round-trip、failure-no-close assertions 搬到新 concrete interface。任何旧 wiring 仍在 production 或
   tests 中都表示 deletion test 未通过，应撤回提取。

**明确拒绝：** 以 future caller 为理由预建 `ClipboardFlow`、`ClipboardEndpoint`、command bus、event
bus、protocol-per-operation、generic queue policy、第二个 fake history writer、只为注入 private
pasteboard 而新增 public port。若以后真有第二个 real adapter（例如系统 extension 与 app 同时使用），
再基于证据引入 seam。

## 4. Rank 2 — 深化现有 startup 的只读 classification phase

### Evidence 与 common caller

[`ensurePositionSingleton`](../../../Sources/HistoryStorage/HistoryAuthority.swift) 对正确 key 查询为零时
直接插入；[`ensureRetentionExpansionConfig`](../../../Sources/HistoryStorage/HistoryAuthority+RetentionBootstrap.swift)
也把零行解释为 all-disabled 新配置。两者各自无法知道 store 是 fresh、已 migration、正常 V2，还是
已有 items 但 singleton 缺失/错 key。startup 的 common caller 是 `HistoryAuthority.performStartup`：
它需要在**第一次 write 之前**获得全 store shape 的分类结果。

Dependency 是 local-substitutable SwiftData。测试应使用 temp on-disk store；真正 restart 证据要让
seed child 退出后再由 open child 分类，不能让旧 container/context 同时活着。这是在正常
`ModelContainer`/context open 后读取持久行形状，不是绕过 SwiftData 预先枚举 SQLite、WAL 或 external
storage 文件。

### Interface sketch

```swift
private enum ValidatedStartupState {
    case fresh
    case migratedV1(ValidatedV1State)
    case existingV2(ValidatedV2State)
}

private func classifyStartupState(
    in context: ModelContext,
    limits: HistoryLimits
) throws -> ValidatedStartupState
```

这应当是 `HistoryAuthority.performStartup`（或其 file-private extension）的一段函数与 validated value，
不是 `StoreStartupClassifier` service、protocol 或可注入 dependency。Corrupt 不应成为“可继续”的
case；只读 phase 直接抛 typed persistence failure。validated values 只包含后续 bootstrap/build index
需要的 immutable scalars，不让 `@Model` 逃逸。`performStartup` 对
`.fresh` 才创建全部 required singletons；对 `.migratedV1` 只执行规格批准的 V2 bootstrap/backfill；
对 `.existingV2` 零修复地验证并打开。

### 隐藏 complexity、depth 与 locality

Implementation 隐藏已打开 store 中的 items cardinality、singleton 全 key/cardinality/value、
SignatureBlob structure/coverage、RetainedBytes one-to-one 与“哪些 projection 可重建”的规则。caller
只知道 validated state 后允许的下一步。删除这段 phase/value 后，这些条件会重新散回 position、
retention、signature index、backfill 与 migration branches；deletion test 强通过，但这仍不足以证明
应建立独立 service。

Locality 的关键不是建立“万能修复器”，而是把 **write eligibility** 集中。`RetainedBytes` 是 derived
projection，缺失-only shape 在规格批准时可 idempotent backfill；position/config 是不可重建的用户/
coherence truth，缺失必须 fail closed。只读 phase/validated value 应表达这一区别，不能用统一
`.repair`。

### 最小 TDD

1. Seed child 分别创建 empty fresh、合法 V1、完整 V2、V2 items+missing position、wrong-key、missing
   config、invalid position value；child 必须退出。
2. Red：open child 对 corrupt shapes 在任何 transaction 前失败；目录内store-family文件逐项直接比较，
items、position 与 policies byte-exact不变。
3. Control：fresh 只创建一次；合法 V1 只做批准 bootstrap；完整 V2 不写。
4. Red：SignatureBlob 结构合法但漏掉 canonical representation；startup/capture 不得把缺失 posting 当
   “没有 candidate”的可靠负证据。
5. Green：在现有 startup 中加入最小只读 function/value + 合法状态 switch；复用现有
   codecs/loaders，不新写一套 decode。
6. Refactor：`ensure*` 降为 classification phase 已证明状态下的 mechanical write，或合并进一个 startup
   transaction；旧“零行即新库”测试删除。

### Trade-off 与拒绝的 overdesign

多一次 bounded metadata scan 是 startup 成本；应测 200/1,000/5,000 rows 的 Release child RSS/time，
但不能以省一次 scan 为由保留数据损坏风险。不要加入 `StartupClassifier`/`StoreInspector` service、
protocol、自动 quarantine、pre-open SQLite/WAL/external 文件枚举、恢复 UI 或通用 migration engine。
store family/quarantine 属于 state-3 recovery，必须使用 app-owned dedicated StoreRoot、无 live
coordinator、用户确认后另做 slice。

## 5. Rank 3 — 深化 `SwiftDataHistory` 的 private search execution

### Evidence 与 common caller

[`SwiftDataHistory.browse`](../../../Sources/HistoryStorage/SwiftDataHistory.swift) 直接编排 Authority
snapshot 与 `SearchWorker.page`；observation 又通过 `firstPage` 重走类似路径。
[`searchCorpusSnapshot`](../../../Sources/HistoryStorage/HistoryAuthority+SearchCorpus.swift) 只先验证 page
limit/cursor，随后创建 context、fetch 全 corpus；4,096-byte、regexp、fuzzy admission 则到
[`SearchWorker.page`](../../../Sources/HistoryStorage/SearchWorker.swift) 才执行。empty search 也先
付 corpus 成本。worker 的 cancellation check 主要在入口，scan/sort loops 没有 bounded cooperative
checkpoints。

Common callers 是 one-shot search browse 与 observed search first-page/replacement。共同 complexity 是
admission → empty fast path → cursor shape → snapshot → evaluation → cursor/result → cancellation/position
语义，而不是具体 exact/fuzzy/regexp 算法。

### Private shape sketch

```swift
private struct AdmittedSearch {
    let request: HistoryBrowseRequest
    // 已验证的 mode/query/cursor facts；不持有 worker、context 或 task。
}

private func searchPage(_ admitted: AdmittedSearch) async throws -> HistoryPage
```

它首先应是 `SwiftDataHistory` 内的 private function/value，直接使用 facade 已有的 Authority 与
`SearchWorker` references；不新增 class、actor、service 或 protocol。`browse(.search)` 与 observation
的 `firstPage` 共用这段 implementation。recent 仍直接走 Authority；empty-search 按已批准语义转
recent，而非构造空 corpus。若最后只有一个 caller，甚至无需保留 `AdmittedSearch` 命名类型，局部纯
validation function 足够。

### Implementation 隐藏

- 纯 `SearchAdmission`：shared bytes、mode-specific character/grammar validation；在 context 前运行；
- cursor decode/shape 和 empty recent-equivalent routing；
- Authority snapshot capture 与 immutable corpus hand-off；
- worker evaluation 与 stale-position result discipline；exact/regexp/fuzzy scan-loop 的 bounded
  cancellation checkpoints 继续属于 `SearchWorker`，不能迁到 facade 假装取消已深入 worker 的工作；
- debug/perf phase events，不让 caller 知道 worker/Authority 两阶段。

Depth 来自一个 private path 同时保证 I/O admission 与 coherence，并把取消责任留给真正执行 loop 的
worker。Locality 来自 browse/observe 共用相同 execution。删除后顺序判断会重新分叉到 facade 与
observation；deletion test 通过，但并不需要独立类型边界。

### 最小 TDD

1. Red：invalid bytes/fuzzy/regexp 与 empty request 的 corpus-fetch probe 必须为 0；错误类型保持现有
   typed vocabulary。
2. Green：抽 pure admission，在 Authority 调用前执行；empty route recent。
3. Red：park exact/regexp/fuzzy scan 的第一个 chunk，cancel A、启动 B；A 在固定最大 rows/characters
   后退出，B 不等待 A 全 scan。
4. Green：在 `SearchWorker` 每固定 row/chunk `Task.checkCancellation()`；不为此引入 parallel search。
5. Red：one-shot 与 observation 对同一 request 产生同样 admission/cursor failure；old observed task
   cancellation 不 publish。
6. Refactor：facade 和 observation 都复用 `SwiftDataHistory` private search function/value；保留
   `SearchWorker` 的 mode algorithms、cancellation loops 与 Fuse confinement，不把它们搬进 facade。

### Trade-off 与拒绝的 overdesign

这项工作的收益来自删除分叉，不来自增加一跳。不要建立 `SearchExecution` class/actor/service、query
AST、search provider protocol、pluggable ranking pipeline、OperationQueue 或跨 mode generic matcher。
`SearchWorker` 已是深 module；这里仅深化 `SwiftDataHistory` 到它之间的 private execution path，不再包
一层 pass-through owner。

## 6. Rank 4 — deepen existing Presentation owners by deletion

### Evidence 与 common caller

[`HistoryViewState`](../../../Sources/PresentationUI/HistoryViewState.swift) 同时有 fire-and-forget
`pin/unpin/remove/clear` 和 `async throws` detail/revise/retention passthrough。Details remove 后立即另开
reload Task，read 可先于 write；pagination Task 没有被保存，`deactivate` 不取消它，也不重置
`isLoadingPage`。query restart、old completion 与 spinner 都只靠部分 generation checks。

Panel lifecycle 又双重拥有：
[`HistoryPanelView`](../../../Sources/PresentationUI/HistoryPanelView.swift) 的 `.task/.onDisappear` 与
[`AppDelegate.openPanel/panelDidClose`](../../../ClipyApp/Sources/AppDelegate.swift) 都 activate/deactivate；
[`FloatingPanel`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift) 才是实际窗口 lifecycle owner。

这里不推荐一个把 Storage mutation、SwiftUI navigation、AppKit window 全装进去的
`PresentationCoordinator`。正确深化是两个现有 modules 各自获得完整所有权：

- `HistoryViewState` common callers：list rows、details、settings；拥有 browse/observation/pagination 与
  mutation ordering；
- `AppDelegate` 继续拥有 status item/hotkey/paste completion 到窗口命令的应用 lifecycle，
  `FloatingPanel` 继续拥有具体 `NSPanel` 的 open/close/key/placement；两者不是待合并的新 module。要删除
  的只是 SwiftUI `.task/.onDisappear` 对 activate/deactivate 的重复 ownership。

### Interface sketch

```swift
@MainActor final class HistoryViewState {
    func activate()
    func deactivate()
    func loadNextPage()

    func pin(...) async -> HistoryReceipt
    func unpin(...) async -> HistoryReceipt
    func remove(...) async -> HistoryReceipt
    func clear(...) async -> HistoryReceipt
}

@MainActor final class FloatingPanel {
    func open(...)
    func close()
}
```

Mutation methods可统一 private implementation，但不必再发明 `PresentationIntent` enum；
`HistoryAction` 已是 closed action vocabulary。Views 在一个 Task 内 `await mutation → reload/navigation`。
pagination/observation/debounce tasks 全由 view state 保存、cancel，并用独立 monotonic request token；
只允许当前 token 修改 spinner/rows/failure。

Panel 的 interface 不变；删除 SwiftUI `.task/.onDisappear` lifecycle side effects，由现有
`AppDelegate`/`FloatingPanel` 路径唯一驱动。SwiftUI view 只 render observed state。

### Depth/locality 与 deletion test

深化后的 `HistoryViewState` 隐藏 mutation error mapping、pending state、observation convergence、pagination
token 与 cancel/reset；caller 只 await intent。删除后这些顺序与状态重新散回每个 Button/details/
settings，deletion test 强通过。

`FloatingPanel` 已接近深 module；需要的是移除第二 owner，而非再包它。这里的 deletion test 是：删掉
SwiftUI lifecycle side effects 后，所有行为仍由既有 AppKit owner 覆盖，且 activate/deactivate 次数从
重复变为 exactly once。若必须新增第三个 coordinator 才能通过测试，设计方向就是错的。

### 最小 TDD

1. Red：park remove commit；details 发起 remove；在 commit 前不得 reload 为旧 item，commit 后只 reload/
   dismiss 一次。
2. Green：awaitable mutation；不直接手改 rows。
3. Red：park pagination，deactivate/restart query，再放行；old result 不 append、不清新 spinner；永不返回的
   old request 不阻塞新 pagination。
4. Green：owned pagination task + request token + deactivate/reset。
5. Red：panel open/close 各导致一次 activate/deactivate；hosting view 首次插入、复用、preview resize 都不
   增加次数。
6. Green：移除 SwiftUI lifecycle ownership，保留 AppKit owner。

### Trade-off 与拒绝的 overdesign

awaited UI methods 会让少数 call sites 写显式 Task，这是诚实的 intent lifetime，不是重复业务流程。
不要建立 `PanelLifecycleModule`、Redux store、effect runtime、navigation router、global presentation
actor 或 UI event bus。`PreviewPaneState` 已独立拥有 dwell state；不要把它并入
`HistoryViewState`。

## 7. Rank 5 — one repeated retention invariant at a time

### Evidence 与 common caller

当前 retention semantics 分布在
[`RetentionConfigLoading`](../../../Sources/HistoryStorage/RetentionConfigLoading.swift)、
[`RetentionReviseComposition`](../../../Sources/HistoryStorage/RetentionReviseComposition.swift) 与
[`RetentionPolicySweep`](../../../Sources/HistoryStorage/RetentionPolicySweep.swift)。分文件本身不是问题；
候选问题不是“文件太多”，而是某一条 checked arithmetic 或 relation 可能在 capture、revise、
set-policies paths 中真实重复并可能漂移。现阶段证据还不足以把 config、inventory、protected set、R2/R3
触发与 merge 全部判定成一个共同 module。

同时三条 lane 的语义确实不同：capture fires R1+R2、revise fires R2+R3、policy sweep fires R1+R2+R3；
时间来源与 primary/active-revision protection 也不同。因此“一个 generic retention pipeline”很容易把
差异变成巨大 trigger enum 与 optional 参数。

### 允许的 private shape

```swift
private func checkedRetainedBytes(
    applying delta: RetainedBytesDelta,
    to current: Int64
) throws -> Int64
```

这里只是形状示例，不预先批准这个具体 helper。实际提交必须先指出同一 arithmetic/relation 的至少两个
现有实现与一个可失败的漂移例；然后一次只提取该 pure invariant。三条 lane 继续由现有文件拥有，不把
`ModelContext`、row types、trigger facts 或 planners 塞进共同对象。

### Depth/locality 与 deletion test

若改动只是把三个现有函数换进 `RuntimeRetention` namespace，deletion test 失败。每个小 helper 只有在
删除后会迫使**同一条** pure rule 重新复制到至少两个 lane 时才有 depth；trigger sequence、I/O 与 planner
composition 不属于该 deletion test。没有第二处真实重复就不提取。

### 最小 TDD

1. 选一条已定位到至少两个实现的 pure arithmetic/relation；列出两处输入、输出、overflow/underflow 与
   failure vocabulary。
2. Red：同一 boundary/overflow fixture 经过两个现有 lane 时必须产生相同结果或同类 typed failure，且
   transaction 未开始。
3. Green：只抽这一条 helper，并删除两处旧 arithmetic；不要移动 trigger 或 context loading。
4. Red：为 capture/revise/sweep 各留一条差异反例，证明 R1/R2/R3 trigger 没被统一改变。
5. Refactor：若下一个候选没有第二处真实重复，停止；不要以“完整性”继续造 abstraction。

### Trade-off 与拒绝的 overdesign

收益只应是某一条关系 invariant 的 locality，风险是抽象出一个 optional-parameter 巨物。禁止
`RuntimeRetention` coordinator、trigger bag、统一 pipeline、`RetentionTrigger` 插件、rule engine、
visitor、动态 policy registry、第二个 planner hierarchy。纯 Domain planners 与现有 Storage composition
files 已经是正确 owners。

## 8. Rank 6 — 先证明 G8，再深化为 type-agnostic `ContentDepot`

### 8.1 先分清四件不同的事

用户所说的“多级存储、按需加载、内存淘汰与无限历史”是一个正确的问题，但不能用一个 `StorageManager`
概括。当前实现至少有四条彼此正交的生命周期；混在一起会让删除历史、释放内存、删除 cache 与删除
source bytes 变成同一个危险动作：

| 维度 | 当前 owner / 证据 | 它回答什么 | 绝不能顺带改变什么 |
|---|---|---|---|
| **逻辑 retention** | `HistoryAuthority` + Domain planners + [`RetainedBytesRow`](../../../Sources/HistoryStorage/RetentionSchema.swift) | 哪些 item/revision 仍属于用户历史；count/age/storage/revision policy 如何退休它们 | 不决定当前进程内哪些 bytes/pixels 驻留；retirement 才是 History Commit |
| **durable placement** | [`HistoryItemRow.canonicalBlob/revisionStateBlob`](../../../Sources/HistoryStorage/Schema.swift) 的 `.externalStorage` hint | 逻辑 source bytes 最终由 SwiftData inline 还是旁置 | hint 没有公开的 residency、eviction、stream、file URL 或 tier-control contract |
| **transient residency** | operation-local `Data` DTO、decode task、future materialization permit | 一次 read/capture/decode 最多允许多少 source/output bytes 同时活着 | 释放 residency 不是删除 History，不推进 `ChangePosition`/`ContentVersion` |
| **derived cache** | [`ThumbnailStore`](../../../Sources/PresentationUI/ThumbnailStore.swift) 等 owner-local state | 可重建 artifact 是否暂存；miss/evict 后是否重算 | cache 不是 source-of-truth depot；不能替代 retention 或成为格式中央调度器 |

因此当前答案很明确：Clipy 有 durable storage 与逻辑 retention，但**没有一套通用的 source-content
多级 residency/eviction abstraction**。`HistoryLimits.standard` 给单 representation 64 MiB、单 capture
128 MiB、单 item revisions 256 MiB 与 5,000 retained-item hard bound；这些是 admission safety，不是“内存
驻留参数”。`ThumbnailStore` 的 500 entries/64 MiB decoded-byte ceiling 只约束某个 UI surface 的派生像素，
且当前超限是 whole-store reset；它既不是 source bytes LRU，也不能说明 details/paste/Preview 并发
materialization 的 aggregate RSS 有界。现有 `StorageRetention.maxTotalBytes` 由 `RetainedBytesRow` 的
Canonical/revision logical-byte scalars 驱动，也不是 SQLite/WAL/SwiftData sidecars/staging/cache 的实际
physical disk quota。

同样，`.externalStorage` 只允许 SwiftData选择把 `Data` 存在 model storage 邻近位置。当前
`ClipboardCaptureValue`、Canonical/revision codec、details/paste/thumbnail source 的接口仍以完整 `Data` 为
边界。不能根据 annotation 推断“blob 没进内存”、可按 chunk 读取、系统替本应用做了某个 LRU，或 blob
会在压力下自动逐项淘汰。仓库自己的 G8 也把**并发 caller 的 transient hydration RSS 与 resident DTO
bytes**列为待测证据；现有 5,000 × 256 KiB 只是 search-body payload structural ceiling，
不是 search RSS，也不是这项归因证据。

### 8.2 Design It Twice：三种物理设计

三案必须接受相同约束，才能公平比较：

- `HistoryAuthority` 仍是唯一能决定 durable ownership 的 writer；没有第二个 SwiftData writer，也没有
  Preview/Python/format handler 自己改 blob files；
- storage 对 UTI **type-agnostic**：只按 validated byte count、immutable representation identity、integrity
  与 purpose budget 调度，不按“图片放 A 层、文本放 B 层”硬编码。格式解释仍归 projection、Preview、
  Edit 与 Paste 各自 owner；
- public `HistoryCore` DTO 不暴露 inline/file/segment tier、relative path、file descriptor 或 SwiftData
  identity。caller 只请求 purpose-specific content，并获得 `Data`、bounded chunks 或 typed refusal；
- retention、residency、derived cache 各自有独立 limits 与 version/fence；不能通过释放内存偷偷退休 item，
  也不能通过 pin item 强制把它常驻内存；
- source bytes 的 durability/backup/restore 是 correctness；Preview/thumbnail cache 则允许 miss 后重算；
- 任何方案都必须覆盖 capture/revise prepare、commit failure、process death、live read、retirement、GC 与
  migration，而不只画 happy-path tier arrows。

#### 方案 A — 保持 SwiftData `.externalStorage` hint，深化现有 baseline

物理 source bytes 继续由 `HistoryItemRow` 的两个 versioned aggregate blobs 持有；只做 projection-only
fetch、operation-local context/autorelease pool、分批 scalar scan、并发 caller admission 与 owner-local
cache 修正。用 instrumented temp on-disk store 测：

1. recent/search 是否只 materialize所需 scalar projection；startup读取scalar +
   `canonicalSignatureBlob` metadata，但不主动decode Canonical/revision content；
2. detail/paste/thumbnail 是否只 fault 目标 item 的 blobs；
3. 1/2/4/8 个近上限 caller 的 peak RSS、live `Data` bytes、Authority queue wait 与 cancellation reclaim；
4. restart、memory pressure 与 repeated open 后是否出现 `.externalStorage` clone/fault diagnostics。

**优点：** 没有跨 SwiftData transaction 与 sidecar filesystem 的新 crash protocol；backup/migration 沿用
现有 store family；public seam 不动。若实际 RSS 达标，这是最深也最便宜的答案：caller无需知道物理
placement，implementation 由 SwiftData隐藏。

**缺点：** 没有公开 API 控制 `.externalStorage` placement 或对其 file 做 streaming；一旦 fault 返回完整
`Data`，应用只能控制并发而不能把单个 64 MiB representation 变成 256 KiB resident chunks；而当前
aggregate `canonicalBlob` 可承载最多128 MiB logical capture，`revisionStateBlob`最多256 MiB revision
content，另有codec framing/temporary decode values。它也不能据此支持真正large-attachment consumer。

**判定：** A 是必须先跑的 baseline，不是“什么都不做”。先用它关闭 projection fault 与 aggregate
admission 的可证问题；G8 没触发就停止，不能因为 B 看起来更专业而迁移数据。

#### 方案 B — metadata + loose immutable representation blob depot

当 **G8 的 representative capture/read workload 确实超预算，且 A 无法在 bounded inline-value 设计内
修复**时，推荐 B。SwiftData 只持有 item/revision/representation metadata 与 opaque storage reference；
大 representation 的 authoritative bytes 是 app-owned depot 中的一份 immutable loose blob。小值可继续
inline，但这只是 depot implementation 的 private placement decision。

建议深化成两个窄的 internal owners，而不是一个万能 storage service：

```swift
// 只在 HistoryStorage 内出现；没有 path/tier/UTI。
internal struct StoredRepresentationReference: Sendable {
    let representationID: UUID
    let byteCount: Int
    let integrity: RepresentationIntegrity
}

internal actor ContentDepot {
    func prepare(_ bytes: Data) async throws -> PreparedRepresentation
    func open(_ reference: StoredRepresentationReference) async throws -> ContentLease
    func abandon(_ prepared: PreparedRepresentation) async
    func reclaim(_ candidates: ReclaimBatch) async -> ReclaimReport
}

internal actor ContentMaterializer {
    func withData<Result: Sendable>(
        for reference: StoredRepresentationReference,
        purpose: MaterializationPurpose,
        operation: @Sendable (Data) async throws -> Result
    ) async throws -> Result

    func chunks(
        for reference: StoredRepresentationReference,
        purpose: MaterializationPurpose
    ) async throws -> ContentLease
}
```

这些只是 responsibility sketch；Swift 6 proof spike 必须先证明 lease、async cancellation 与 permit release
能在不用 `@unchecked Sendable` 的前提下表达，再冻结签名。关键边界是：

这里的`actor`拼写不是已批准实现。Authority不能持`ModelContext`/row跨`await`，而“先验证reference，
await另一个actor再按path open”会给remove/GC留下TOCTOU。实现必须二选一并用kill/race fixture证明：在同一
serialized Authority interval内抽取immutable descriptor并同步`open`/`fstat`出已打开lease；或先注册
一个GC可见的lease token，再释放interval并open，任何失败都exactly-once归还token。消费只在已打开
descriptor上继续，不能中途重新按path解析。

- **`ContentDepot` 拥有可恢复的物理publish协议。** 它负责 app-owned root、随机 immutable representation ID、path
  confinement、length/integrity check、temporary write + same-volume immutable publish、open handles、orphan enumeration 与
  bounded reclaim。首版不做 content-addressed dedup；xxh3 仍是 evidence，不是 identity。
- **`ContentMaterializer` 只拥有 HistoryStorage source residency。** 它在分配完整 `Data` **之前**向
  HistoryStorage owner-local `TransientPermitPool` 取得count + authoritative source reservation；方案A按
  aggregate descriptor/批准worst-case收费，不能拿较小`maximumReturnBytes`代替，P3后才可按exact
  representation/range收费。permit覆盖caller operation的整个 lexical
  lifetime，cancel/failure 必须归还。需要 streaming 的真实 caller 获取不暴露 path 的 `ContentLease`，
  每次最多交付一个有界 chunk；lease 同时拥有 open-descriptor slot、chunk-window byte permit、exact source
  fence 与 terminal close，EOF/error/cancel 都 exactly-once 释放。pool 的 hard ceiling 来自配置和测试，
  memory-pressure signal 只能收缩 optional prefetch/cache，不能代替 admission invariant。decoder workspace/
  output permits 分别归 `ContentPreview` 与 Thumbnail owner；clipboard-flow owner（当前`AppComposition`，
  只有获批后才提取concrete `ClipboardFlow`）拥有 acquisition/pending。
  首版不建跨 owner global scheduler，whole-process envelope由 cap 总和与 soak 验证。不能先整文件读进
  `Data` 再切片伪装 streaming，也不能在 `withData` 返回后让 caller 偷留一份未计费的 `Data`；若 lexical
  callback 无法证明该点，就必须改成显式 owned lease/result，而不是谎报 resident bytes。即使选择
  serve-without-retain，也只绕过completed-cache admission；transient/output permit仍必须覆盖交付。
  返回给caller后的长期保留不再属于depot-owned resident上限，需由caller contract另行约束。
- **Authority 拥有 durable reference state。** prepare file 可在 transaction 前发生，但只有
  `HistoryAuthority` 的 commit 能让 metadata reference 成为 live。B 若要支撑高于 5,000 的规模，不能只把
  handle 藏回 aggregate codec 后靠全行扫描找 owner；应有 indexed representation metadata 与 durable
  reclaim state/outbox，由同一 transaction 随 item/revision ownership 改变。retire/revision-prune commit
  先把 reference 标为 reclaimable，之后异步 delete；depot actor 能写自己的 bytes/files，但不能自行决定
  哪份 source 仍属于 History，也不能创建 writable `ModelContext`。
- **format owners 只消费 materialized bytes。** `ContentPreview`、thumbnail、paste、projection/editor 各自
  用 purpose-specific budget/recipe；depot 不 import `ClipboardFormats`，不建立 per-UTI file、decoder queue
  或动态 format plugin。调度依据是 bytes、并发与 purpose，不是扩展名。
- **cache 保持 local。** Thumbnail LRU、Preview artifact cache、search collection cache 即使以后被 gate
  批准，也留在各自 owner，并以 exact content token + recipe/materializer version 为 key。`ContentDepot`
  不能长成“L1/L2/L3 都经过它”的中央 cache manager。进程 hard-accounted resident envelope 由 composition
  以“所有有限个owner cache caps + 各owner-local in-flight permit ceilings”的批准总和与soak约束；这不是
  一个跨owner共享/借额度的scheduler。memory-pressure coordinator
  可以只广播 purge/pause-prefetch，不持有 cache entries。ImageIO/AppKit/allocator 等不可直接计费的 workspace
  仍要靠独立 child RSS 与并发 ceiling 校准，不能把自报 byte counters 冒充整个进程内存。

B 的 interface leverage 是 caller 不再学习 inline-vs-file、recoverable publish、integrity、GC 或 permit
accounting；deletion test 是删除 depot/materializer 后，这些问题会重新散回 capture、revision、paste、
details、thumbnail 与 Preview。它同时保留一条重要负边界：删除任何 owner-local artifact cache 都只产生
miss，不影响 depot 中的 authoritative bytes。

#### 方案 C — append-only segments + offset/length metadata

把许多 representations pack 进少量 immutable/append-sealed segments；metadata 记录 segment generation、
offset、length 与 integrity。GC 通过 live-density 选择 segment、copy live records 到新 generation、原子
切换 metadata，旧 segment 等所有 reader leases 释放后删除。

**优点：** 极大历史下减少 inode、directory enumeration、open/close 与 small-file metadata cost；顺序 scan
与 backup 可能更好。

**缺点：** compaction 本身成为第二套 storage engine：需要 torn-tail recovery、record framing/length validation、
generation fence、copy-forward transaction、reader epoch/lease、free-space amplification、后台 I/O budget 与
crash-resumable GC。一个 offset bug 会扩大为 segment blast radius。若 loose blobs 没有被测出 inode/open/
directory bottleneck，这些 interface vocabulary 大部分在删除 module 后直接消失，deletion test 不通过。

**判定：C 只保留为 B 的 soak 对照。** 先让 B 在大规模 fixture 上跑长时 churn/retire/restart/backup
soak；只有证据显示 loose-file metadata 或 inode 成为主瓶颈，且 B 的 sharding/batched GC 仍无法达标，才
写 segment ADR 与故障注入 prototype。C 不能与 B 一起成为 production fallback，也不能首日提供可选
backend setting。

### 8.3 推荐 B 的 crash state machine 与 GC law

文件系统写与 SwiftData transaction 不能被假装成一个原子提交。若 G8 最终批准 B，owning spec 至少要
固定以下状态，而不是只写“失败时清理临时文件”：

```text
absent
  └─ prepare(bytes) ─→ prepared-unreferenced
                         ├─ History transaction fails/process dies ─→ sealed-unreferenced
                         └─ History transaction commits reference+metadata ─→ live
live
  ├─ open lease ─→ live+leased
  └─ retire/prune transaction commits reclaim record ─→ reclaimable
reclaimable + no lease ─→ GC delete ─→ reclaimed-metadata-pending
reclaimed-metadata-pending ─→ Authority cleanup transaction ─→ absent
```

- `prepared-unreferenced`/`sealed-unreferenced`不能被与capture并发的sweep删除；需要持久ownership/checkpoint
  或Authority-coordinated in-flight generation，并由指定OS/filesystem的process-kill fixture证明。age/grace只能决定何时开始核对，
  不能单独证明一条慢 capture 已终止，更不能靠 wall-clock 猜测 correctness。
- file 必须在History transaction引用它**之前**完成bounded write、declared length与byte-exact staged readback验证及process-kill-scoped
  publish；transaction
  failure 只能留下 orphan，绝不能留下一个 committed row 指向从未 published 的 file。DB 中的 live
  representation metadata 是 liveness source of truth；突然断电/fsync仍为UNKNOWN。不能依赖 commit 后的 `markCommitted` callback——若
  进程在 commit 与 callback 之间死亡，那条设计会把真正 live 的 file 错判为 orphan。
- committed live file 缺失、length mismatch、path escape 或 staged-readback failure 必须 fail closed 为 typed
  persistence failure；不能退回“相同 UTI 的另一份 bytes”或静默空 Preview。
- retirement/prune 在同一 transaction durable 移除内容 ownership 并写 reclaim metadata/outbox；unlink 是
  commit 后 best-effort GC。delete 成功后再用 Authority 的 idempotent cleanup transaction 移除 reclaim
  metadata；任一步 process death 都可重放。删除延迟是 disk exposure，不是 item 仍在 History；privacy/UX
  必须披露并给出 bounded sweep cadence/clear-now 语义。
- live lease 与 deletion race 要么依赖已打开 descriptor 的平台语义并用 proof 固定，要么 deferred-delete；
  不能在 mid-stream 重新按 path 打开而偶然读到新 generation。
- open-time repair 不做全库、全目录同步 sweep；恢复只处理 bounded metadata/outbox batch，loose-file
  orphan enumeration 使用 durable shard cursor + grace/process epoch 在后台继续。GC state 本身有明确schema
  version与typed cursor，不依赖扫描所有 aggregate content codecs 才知道哪些 file live。
- sequential reader只承诺locator/path/declared-length/read-error合同，不增加全文件hash。若未来consumer要求
  内容损坏在release前被检测，必须先批准具体安全属性与相应pre-pass/分块envelope，不能把新checksum当默认防御。
- backup/export/restore 将 SwiftData store family、depot root 与 manifest 当成一个 consistency unit；只备份
  SQLite 而漏 depot 必须被检测并拒绝，不产生部分可读的“成功恢复”。

这一点也暴露现有
[`V2-06 P3`](../../v2/V2-06-platform-grafts.md) 的正确定位：它目前是 **design-only graft**，不是已实现、
已测的 tier。其 app-owned sidecar、handle 与 streaming方向可作为 B 的输入，但 1 MiB threshold、公开
`BlobStreamingHistory`、eager migration 和全库 live-handle scan 都不能因为写进设计文档就视为已批准；
迁移默认候选应先比较 dual-read + bounded resumable batches，而不是把首次升级变成全库停机 rewrite。
尤其是公开协议只有在存在一个真实非-`Data` consumer 后才有 leverage；否则先让
`ContentDepot`/`ContentMaterializer` 保持 internal，并以 consumer-specific operation 暴露能力。

### 8.4 “无限历史”不是把 5,000 改成 `Int.max`

当前 5,000 hard bound 支撑 startup/index rebuild、retention inventory、corruption
scan、search corpus、tie fallback 与多个 `fetchLimit = hardMaximum + 1` 的复杂度证明。多级 blob 只把**大
bytes 的物理位置**移走，不会让这些 metadata O(N) 路径消失，也不会让磁盘、WAL、索引、projection 或
search 成本无限。反过来，若用户主要拥有大量小 item，先把 metadata/index/pagination 路径改为有界就
可能取消固定 count cap，**不必为了“无限”先上 P3/depot**；B 解决的是另一个经 G8 触发的大
representation residency/streaming 问题。

因此在删除/大幅提高 5,000 前，必须先逐路径消除正常交互中的 O(N) 依赖，而不是先放开 cap 再靠 cache
掩盖：

- startup 用 bounded metadata validation/checkpoint，不在每次 open 全扫所有 content handles；
- capture/coalesce 的 candidate lookup、count/byte retention 与 aggregate relations 用 durable index/counter
  + bounded victim query，不加载 complete retained inventory；完整 process-lifetime Signature Index 不再是
  correctness 前提，只查询 incoming signature 的 indexed candidates；
- recent/search 以 index/cursor/page budget 执行；无结果 search 不能每次 materialize 全量 256 KiB × N
  corpus。full-tie correctness fallback 需要可索引 total-order key 或明确的 bounded repair，不保留 O(N)
  后门；
- clear/large policy change 可以是显式 batched maintenance state，但对外必须有原子产品语义或清楚的
  progress/cancel/recovery contract；不能长时间占住 Authority 伪装一次小 commit；
- UI 已访问 rows 使用 viewport/window ownership；pin ordering 不能靠每次 move/validation 重写或常驻全部
  ordinals。两者都不能因为 source blob 已落盘就继续随 N 线性驻留；
- Signature Index、retained-byte/accounting、depot live-reference/GC metadata 各有增量一致性和 startup
  validation；缺失 projection 仍 fail closed/backfill，不能用“无限”跳过完整性；
- performance gates 改为 5k baseline、5,001 functional boundary、50k→250k→1m staged fixtures，同时记录 metadata RSS、
  source hydration RSS、database/WAL/depot bytes、cold/warm latency与 mutation tail；只测一页 UI latency不够。

可承诺的产品词应是“**practically unbounded by item count, bounded by configured disk/resource policy**”，
而不是数学上的无限。磁盘写满、depot corruption、migration temp amplification、pinned items 超过 storage
budget 都必须有 typed failure/irreducible-state UX；用户关闭 age/count policy 也不等于进程内存可以无界。

### 8.5 Capture 的 `Data` 边界仍是独立限制

即使 B 完成，当前 pasteboard observer 交付的每个 representation 已是完整 `Data`，
`ClipboardCaptureValue` 又把这些 values 组合后交给 ingest。depot 可以降低**commit 后 storage/read**的
residency，并让后续 consumer stream；它不能倒推消除 capture freeze 已经发生的 64/128 MiB transient
allocation。所谓“capture 也支持 streaming”必须先证明 AppKit pasteboard source 能以稳定、完整、可重试
方式提供 chunked bytes，或设计 bounded spool，使 change-count/freeze 语义仍成立；不能把一个完整 `Data`
写进临时 file 后就把前段峰值记成已解决。

所以 G8 应分别记录 capture peak 与 read/materialization peak：若只有 read 超预算，B 可以仅深化 read/
durable placement；若 capture 超预算而上游 API 仍只能 materialize `Data`，要诚实保留单-capture admission
bound/拒绝，而不是让 storage module承诺它控制不了的内存。

### 8.6 最小 TDD / measurement ladder

1. **A-baseline characterization（不改 schema，不是Red）：** temp on-disk store 放入小/阈值附近/64 MiB representations；用
   independent child 分别跑 recent、search、details、paste、thumbnail/Preview，记录 peak RSS、source bytes
   materialized、concurrent live DTO bytes。scalar-only lanes 若 fault content blob，先修 projection，不进入 B。
2. **Aggregate-residency Red：** park 1/2/4/8 个 details/Preview/paste materializations；超过批准的 count/byte
   envelope 必须在 allocation 前等待或 typed reject，cancel waiter/holder 后 permit exactly once 回收。先用
   test-only `TransientPermitPool` harness证明调度，不先迁移 durable bytes。
3. **G8 decision gate：** 只有 A 在 representative workload 仍超 budget 或 copy p95 无法在 inline model
   内解决，才批准 B、threshold、migration 与新的 SLO；证据未过则删除 spike。
4. **Independent U-scale Red before cap change：**不等待B/P3，直接以5k/5,001/50k/250k/1m metadata fixtures
   证明正常 capture/recent/startup/retention 的
   fetched rows与 temporary state不随 N 线性增长；仍为 O(N) 的 search/clear maintenance有单独可见 budget。
   这些 gate 未绿，不得提高 `hardMaximumRetainedItems`。
5. **Conditional B codec/depot Red：**仅G8触发后，inline/loose reference round trip byte-exact；unknown format与
   已知 format走同一depot；path traversal/symlink、missing、length/integrity mismatch、oversize metadata
   全部 fail closed。
6. **Conditional commit-coupling Red：** park file prepare→History commit；并发 sweep 不删 prepared file。注入
   transaction failure/process death，重开后 committed row永不 dangling，uncommitted file最终 bounded reclaim；
   删除/revision prune 只有 commit 后才可回收。
7. **Conditional materialization Red：** one full-`Data` caller获得 byte permit覆盖整个 async operation；第二
   caller等待/拒绝。chunk caller 的 observed RSS 随 chunk budget而非 file size增长，early cancel关闭 lease并释放 permit。
8. **Conditional cache-separation Red：**只有owner cache另获reuse准入时，清空 Thumbnail/Preview cache只造成
   depot miss/read+re-render，不改 History；retire item即使cache仍有artifact，也不能重新取得source；cache
   eviction不推进任何coherence token。P3不自动创建cache。
9. **Conditional migration Red：** dual-read + bounded resumable batch 下，old inline 与 new handle rows 可在
   迁移期共存，但每一 row 在 kill-at-every-boundary 后必须由其 committed form byte-exact 可读；cursor幂等
   续跑，最终全部转为new-readable且从未出现dangling handle。backup/restore遗漏depot显式失败。不要以
   同进程container重开代替process death。
10. **C soak only：** 在 B 上跑 create/read/retire/revise/restart churn，记录 inode、directory/open、GC tail
    与 space amplification。只有 loose-file bottleneck越过批准阈值才建 disposable segment prototype；否则
    C 不进入 production graph。

### 8.7 明确拒绝的 overdesign

不做 `StorageBackend` protocol + memory/SwiftData/file/segment 四个可切换实现，不做用户可见 tier picker、
per-UTI storage class、generic L1/L2/L3 cache、background “AI prefetcher”、content-address dedup、透明网络/
iCloud object store或按内存压力删除 durable source。也不把 `ContentDepot` 放进 `HistoryCore`，不向 Python
返回 path/handle，不让 Preview 自己持有 indefinite source lease。B 只在 G8 触发后替换物理 representation
owner；C 只在 B soak 提供证据后重新走 Design It Twice。

更完整的 current-state、算法清单、crash/GC 状态与“practically unbounded”TDD 见
[`09-tiered-storage-and-unbounded-history.md`](09-tiered-storage-and-unbounded-history.md)。

## 9. Rank 7 — package-only `ClipboardFormats` 声明式事实目录

### 为什么旧的 Presentation helper 已经不够

文本/图片 UTI 与 encoding 判断不仅散在
[`HistoryPreviewView`](../../../Sources/PresentationUI/HistoryPreviewView.swift)、
[`HistoryDetailsView`](../../../Sources/PresentationUI/HistoryDetailsView.swift)、
[`ReviseEditorView`](../../../Sources/PresentationUI/ReviseEditorView.swift)、
[`HistoryRowView`](../../../Sources/PresentationUI/HistoryRowView.swift) 与
[`ThumbnailStore`](../../../Sources/PresentationUI/ThumbnailStore.swift)，还散在
[`ContentProjector`](../../../Sources/HistoryStorage/ContentProjector.swift)、thumbnail source 选择和
[`PasteboardMarkers`](../../../Sources/PasteboardAdapter/PasteboardMarkers.swift)。已确认 HEIF/BMP、UTF-16、
abstract text、HTML/RTF 与 concealment identifiers 在 owners 间出现真实漂移。共同 caller 已跨过
Presentation target，因此旧建议的 `PresentationContentFacts` internal helper locality 太低。

经 owning spec 批准后，建议新增一个**不发布 library product、只供本 package targets 依赖**的
Foundation-only `ClipboardFormats` target。它只回答“这个 exact identifier 有哪些稳定事实”，让支持
范围在源码中有一个明确入口、可被 review 与机器 inventory 检查：

```swift
package struct StableFormatFact: Sendable {
    package let key: StableFormatKey
    package let exactIdentifier: FormatIdentifier
    package let familyFact: FormatFamilyFact
    package let wireFact: WireFact
    package let specialRole: SpecialRole?
    package let evidenceID: EvidenceID
}

package enum ClipboardFormats {
    package static func fact(for identifier: FormatIdentifier) -> FormatFactLookup
    package static var declaredFacts: [StableFormatFact] { get }
}
```

`FormatFactLookup` 必须显式包含 `.unknown(validIdentifier)`；未知/custom/dynamic UTI 默认仍由现有
capture/paste 路径作为 opaque `(identifier, bytes)` 保存和原样回写，而不是因为不在 catalog 中被拒绝。
catalog 不持有 bytes、decoder、I/O、cache、runtime plugin、UI icon 或“是否支持”的总 Bool。

### 稳定 facts 与行为 recipe 必须分开版本化

“支持一种格式”至少分 raw capture、verbatim paste、durable projection/search、Preview、Edit 与
privacy/special staging。`ClipboardFormats` 只给这些 owners stable key/exact identifier/family/wire facts；
每个行为owner继续拥有自己的声明与独立change identity。只有已有durable consumer的Search projection
立即需要schema version；Preview/Edit/Pasteboard先用manifest/build identity，等跨启动cache、durable
artifact或稳定external wire真正出现后才升级为持久语义版本：

| Owner | 版本化 recipe/manifest | 变化时必须处理什么 | 不应被自动联动的 owner |
|---|---|---|---|
| `HistoryStorage` | `SearchProjectionRecipeVersion` | durable title/search schema、旧行重投影或 migration disposition | Preview、Edit、paste staging |
| `HistoryStorage` thumbnail purpose | Thumbnail source manifest identity | source/runtime decoder/version fence | UI request scheduling、full Preview |
| `ContentPreview` | Preview manifest identity | renderer/source priority、budget、安全 policy、artifact contract | durable projection 与 revision bytes |
| `PresentationUI` 或未来 `ContentEditing` | Edit manifest identity | exact parser/serializer pair 与 round-trip evidence | search/Preview |
| `PresentationUI` | Presentation mapping/request identity | icon/label/a11y与按`DEC-THUMBNAIL-REQUEST-OWNER`批准的scheduling | Storage decoder/source truth |
| `PasteboardAdapter` | Paste manifest identity | special marker、promise/delayed data 与 multi-item staging contract | search/Preview/Edit |

因此“给 `public.webp` 增加 Preview”不能顺手改变已有 history 的 title/search bytes；“给 HTML 增加
semantic projection”也不能因为 Preview renderer 已存在而跳过 projection schema/migration。一个
build/test-only inventory可以join这些manifests并输出稳定排序的code-visible table；它不能直接给Python。
只有`DEC-FORMAT-INVENTORY-OWNER`批准owner-exported Foundation summaries、ClipyApp composition join与
Gateway注入生命周期后，Local Automation才经`clipyctl` stdin的`describeFormatCapabilities`展示同一pure
projection。它只做审计和展示，不成为所有production paths调用的中央policy manager。

### Target graph 与 import gates

批准后的最小新增依赖边如下；`ClipboardFormats` 自身只 import Foundation：

```text
ClipboardFormats (package-only declarations; Foundation only)
├── HistoryStorage       # projection/thumbnail owner引用stable facts
├── PasteboardAdapter    # special identifiers与pasteboard-specific rules
├── ContentPreview       # preview manifest引用stable facts
└── PresentationUI       # edit/icon/a11y mapping引用stable facts
```

`HistoryCore` 不依赖 `ClipboardFormats`，从而保持唯一 general-purpose public History seam 与 Foundation-only DTO；
V2-05/Local Automation的窄capability-scoped facade是独立trust-boundary concern，不演变成第二个generic History API。raw DTO
仍携带 string identifier。`HistoryDomain` 也不依赖它，除非未来有一条真正的 pure domain invariant 必须
使用 stable key，并经 spec 明确批准。`Package.swift`、`scripts/import_gate.py` 与 `.swiftlint.yml` 必须同一
slice 更新：禁止 `ClipboardFormats` import AppKit、SwiftUI、SwiftData、ImageIO、UniformTypeIdentifiers、
WebKit、PDFKit 或其它 feature target；禁止反向依赖任何 caller。不要只改 manifest 而让 portable gate
不知道新边。

源码布局应让 agent/reviewer 不用全文搜索就能找到每个维度的支持清单：

```text
Sources/ClipboardFormats/StableFormatFacts.swift
Sources/ClipboardFormats/SpecialFormatRoles.swift
Sources/PasteboardAdapter/PasteRecipe.swift
Sources/HistoryStorage/SearchProjectionManifest.swift
Sources/HistoryStorage/ThumbnailFormatManifest.swift
Sources/ContentPreview/PreviewFormatManifest.swift
Sources/PresentationUI/EditableFormats.swift
Sources/PresentationUI/FormatPresentation.swift
Tests/CapabilityInventoryTests/CapabilityInventoryTests.swift
```

文件名可以随仓库惯例调整，但 ownership 不能重新混回同一个 `SupportedFormats.swift`。一张生成的
capability inventory 在build/test中给人看全貌；Python export受上述DEC阻塞。生产代码仍从各自 owner
recipe 做决定。

### Depth、deletion test 与 TDD

删除 `ClipboardFormats` 后，exact identifiers、encoding/family 与 special-role identity 会重新散回
Adapter、Storage、Preview 与 Presentation，且 defense-in-depth owners 会再次手工同步；deletion test
通过。删除 build/test inventory 只会丢失跨 owner 漂移检查，不应改变 production behavior——这正说明
inventory 不是 policy god-object。

最小 TDD：

1. Red：先对当前各 owner 的 UTI literals/sets 生成排序 inventory；HEIF/BMP、UTF-16、HTML/RTF 与
   concealment drift 必须以 owner+recipe 维度显示，unknown canary 必须是 raw-only 而不是 rejected。
2. Green：只迁移 exact identifier 与稳定 facts；每接一个 owner 就删除其对应 literal 副本，不同时改
   selection、priority、cap 或 fallback。
3. Red：同一 fixture 分别走 projection、Preview、Edit、paste recipes；改变 Preview manifest 后，durable
   projection bytes/schema 与 Edit/Paste 结果 byte-exact 不变。
4. Green：给每个behavior owner（至少Search projection、Thumbnail source、Preview、Edit、Presentation
   request/icon与Pasteboard recipe）manifest独立identity/change disposition；只有已有durable consumer的projection使用
   schema version，inventory join只读。
5. Red：真实Python child向`clipyctl` stdin发送`describeFormatCapabilities` JSON（等automation tracer
   落地后），断言稳定schema/排序/runtime-disabled reason，且输出不含clipboard bytes、query、用户路径或
   历史inventory。

### 明确拒绝的 overdesign

不按每个 UTI 建 protocol、renderer class 或 SwiftPM target；不做 runtime plugin discovery、dynamic
registry、中央 `ContentManager`、通用 conversion graph 或“所有 purpose 一张开关表”。也不以
`UTType.conforms(to:)` 代替 exact encoding/decoder probe。新增格式的正常成本应是一条 stable fact、在
确有能力的 owner recipe 中一条声明及其 fixture，不是复制一套 framework。

## 10. Rank 8 — concrete package `ContentPreview`

### Common caller 与独立 seam

Preview 已同时包含 representation selection、文本/图片解码、malformed/unsupported/failure 分类、资源
budget、cancellation、late-result fencing 与 AppKit/ImageIO object confinement。把这些继续留在一个
SwiftUI view/helper 中，会迫使 row、details、large preview 与未来 PDF/rich-text renderer 各自理解
Apple framework 细节；但首日拆成 `PreviewCore` + `PreviewPipeline` + `PreviewAppleAdapter` 三个 targets
同样没有 depth。

经 spec 批准后，建议只新增一个 concrete、package-only `ContentPreview` target。它的 common caller 是
Presentation 的 Preview loader；interface 只接 immutable source snapshot、closed intent、预定义resource
profile ID与source-policy ID，返回有界、
无行为的 `Sendable` primitives 或 typed outcome：

```swift
package struct PreviewSource: Sendable {
    package let representations: [PreviewRepresentation]
}

package enum PreviewSourcePolicy: Sendable {
    case historyBytesOnly
}

package struct PreviewRequest: Sendable {
    package let source: PreviewSource
    package let intent: PreviewIntent
    package let resourceProfile: PreviewResourceProfileID
    package let sourcePolicy: PreviewSourcePolicy
}

package enum PreviewOutcome: Sendable {
    case artifact(PreviewArtifact)
    case unsupported(PreviewUnsupportedReason)
    case rejected(PreviewRejection)
    case failed(PreviewFailure)
}

package actor ContentPreview {
    package func render(
        _ request: PreviewRequest
    ) async -> PreviewOutcome
}
```

caller不能提交任意max bytes/pixels或`allowsExternalIO`布尔值；`ContentPreview`内部把closed intent/profile
解析为批准上限。首期source policy只有history-owned bytes；显式用户file action需要新的closed case、
lease与spec，不能由caller翻一个Bool获得。

接口形状不是要求首版逐字照抄；关键契约是 `PreviewArtifact` 默认只含 bounded text、eager bounded
RGBA/BGRA pixel buffers、pixel size、page/count 等无行为的 value。encoded PNG/JPEG 会把第二次 decode/
RSS 重新推给 UI，只能在独立 UI-decode budget/spec gate 后准入。item reference 不进入 renderer input；exact-reference/late-result
identity 始终归 loader。`CGImage`、`NSImage`、`NSAttributedString`、`PDFDocument`、
`WKWebView`、`AVAsset`、Quick Look request 与 security-scoped lease 都不得跨 target/actor seam。
ContentPreview 内可以按 `Renderers/Image`、`Renderers/Text`、未来 `Renderers/PDF` 等文件/逻辑模块组织，
但这些先是 internal concrete functions/types，不是每 family 一个 public/package protocol 或 target。

### 所有权边界

[`PreviewContentLoader`](../../../Sources/PresentationUI/HistoryPreviewView.swift) 继续拥有
`ClipboardHistory.details(for:)`、exact `HistoryItemReference` fence、selection/panel lifecycle、owned task
与 late-result suppression；它把已读取的 immutable Effective Content snapshot 交给 `ContentPreview`。
`ContentPreview` 不 import `HistoryStorage`、不直接读取 History、不知道 row selection/panel，也不拥有
completed disk cache。它只拥有 `PreviewFormatManifest`、source priority、decode/render budget、安全 policy
与 renderer implementation。

建议 target graph：

```text
PresentationUI ──→ ContentPreview ──→ ClipboardFormats
       │                  └──→ Foundation + approved Apple decode frameworks
       └──→ HistoryCore

HistoryStorage ──→ ClipboardFormats   # durable projection/thumbnail，不依赖ContentPreview
PasteboardAdapter ──→ ClipboardFormats
```

这要求更新 `Package.swift` 与 import gates：`ContentPreview` 禁止 import SwiftData、HistoryStorage、
PasteboardAdapter、PresentationUI 与 HistoryCore；loader 在 Presentation 边界把 History DTO 映射为
Preview 自有的 immutable source。`PresentationUI` 不再直接解析 raw clipboard source，也不在 state 中
保存 decoder/framework objects。若最终 raster artifact 在 render edge 需要平台对象，只能从 bounded
artifact 临时构造并在 view lifecycle 释放；具体允许的 display-only framework import 应由同步更新的
gate 明写，不能让对象反向进入 Preview/History state或跨 actor。

### Preview change identity 不等于 durable interpretation

Preview manifest/build identity独立于`ContentProjector.projectionSchemaVersion`；只有future cache或stable
wire出现时才引入`PreviewRecipeVersion`。新增 PNG/WebP/PDF Preview route、
改变 source priority 或 sanitizer，只影响 transient Preview artifact；不会自动重写 title/search、改变
dedup fingerprint、生成 revision 或扩大 paste payload。反过来，durable semantic projection 的改变必须
自行处理旧行 migration/rebuild，不能借“Preview 已经能解析”偷渡。

默认安全切片应先做 static、zero-external-I/O renderer。HTML remote resources、file URL、Quick Look、
RTFD attachments 与音视频可能引入网络、文件/TCC、helper process 或大资源面；首期closed
`PreviewSourcePolicy.historyBytesOnly`必须是 hard invariant。runtime framework availability 与 declared route 的
交集返回 typed unavailable/unsupported，UTI 命中不等于 bytes 可 decode。

### Depth、deletion test 与最小 TDD

删除 `ContentPreview` 后，source priority、budgets、malformed classification、framework confinement 与
renderer behavior 会重新散回Preview/Details调用路径；row thumbnail继续是HistoryStorage source +
Presentation display的独立owner，不计入该deletion test。`PreviewContentLoader` 的
History/lifecycle complexity 不会散回，因为那本来就不是 renderer 的责任；这个负边界防止 module
膨胀成 Preview coordinator。

最小 TDD：

1. Red：通过 `PreviewContentLoader` 的真实 seam，exact reference A 取 snapshot 后 selection 变 B；A 的
   slow renderer 结果不得 apply，且 ContentPreview 不再读取 History。
2. Green：loader 保持 reference/task fence，只把 immutable source+constraints 交给 concrete module。
3. Red：先为一个 exact plain-text codec写一张行为卡；UTF-16、每个 raster family、unknown、malformed、
   oversize与rectangular image分别领取后续独立卡，不用一张复合 Red 同时冻结所有格式；每张都得到
   bounded artifact/unsupported/rejected/failed 的批准结果；任何 framework object 都无法出现在 package
   interface 或 `Sendable` state 中。
4. Green：第一张只实现exact plain-text internal renderer；完整materialize已批准input并检查总量，再decode，
   输出前检查text cap；不建registry/plugin/cache。image family必须由后续独立PNG/像素artifact Red拉出，
   不能借plain-text Green顺带实现。
5. Red：HTML/file URL/RTFD/Quick Look canaries 在closed `.historyBytesOnly` source policy下不得产生网络、
   文件 open、security-scope 或 helper launch；未批准 route 返回 typed unsupported。显式外部文件必须由
   future spec新增不可伪造的user-action/lease case，不能复用布尔开关。
6. Red：只修改Preview manifest identity（或future cache已准入后的`PreviewRecipeVersion`）后，持久store
   rows/fields逐项比较不变，projection values、revision count 与
   paste payload 不变。
7. Refactor：当第二个 renderer family 到来时只抽 internal common budget/error helper；只有出现第二个
   **真实外部 renderer implementation** 才评估 protocol seam。

### 明确拒绝的 overdesign

不在首日建立 `PreviewCore` 与 `PreviewPipeline` 两个 targets，不按 UTI/family 建 target/protocol，不做
dynamic renderer plugin、central preview manager、generic document AST、conversion DAG 或无证据的
completed/disk cache。`ContentPreview` 也不能成为 direct DB reader、selection owner、file broker 或网络
fetcher；需要外部 I/O 的 future Preview 必须有独立授权/lease 与 SLO slice。

## 11. Rank 9 — Python 只经过 `clipyctl` 与唯一 `ExternalGateway`

### 直接回答与边界

当前 Clipy 没有支持 Python 访问 History 的进程间 interface；未来可以支持，但“任意 Python”应准确
定义为：用户显式启用 Local Automation 并授予 capability 后，同一effective user account（same EUID）下、能够执行第一方
`clipyctl` 的 Python 进程可通过 versioned JSON request/reply 调用获准操作。它不表示任意脚本可直连
SwiftData、绕过授权，也不保证受第三方 sandbox 限制的 Python 能启动外部 executable。same EUID是
effective-user-account范围，不证明同一GUI/login/audit session或per-script identity。

稳定 public interface 是 `clipyctl` 的 stdin/stdout JSON 与少量 exit-code classes；socket path、XPC
service name、Apple Event encoding 或 App Intent 名称都是可替换的 private transport。建议边界：

```text
Python / shell / editor
  → clipyctl                         # public, versioned JSON/exit-code contract
  → LocalAutomationTransportAdapter # private framing/cold-start/ready/peer adapter
  → AuthenticatedIngressFacade      # restricted public no-policy wrapper
  → ExternalGateway.authenticateAndPerform(peerEvidence, credential, request)
                                      # internal connection resolution/enrollment/grant/quota/OCC/audit
  → HistoryAuthority
                                      # 唯一 writable ModelContext / commit path
```

`clipyctl` 不链接 `HistoryStorage`、不打开 store family、不拥有 `ModelContext`，也不实现 grant/audit。
private adapter 只负责 checked frame、bounded binary、cold-start/ready、kernel peer evidence与transport failure；
credential/connection/locator validation留在HistoryStorage内部。所有 read/write
capability 仍在同一个 `ExternalGateway` authoritative recheck 后映射到既有 purpose-specific reads/closed
actions。**只有 JSON/exit-code shape 可以先在规格中冻结**；实现不先落hard-coded contract stub。
`describeFormatCapabilities` 还受`DEC-FORMAT-INVENTORY-OWNER`阻塞。任何production transport的
`browsePreview` 或 mutation 必须等 `ExternalGateway` 的 enrollment/grant/quota/audit/locator recheck 规格与
implementation 先完成；revision/remove 再等各自 OCC 与 audit-before-release/commit proof 后逐项开放。
`DEC-PY-AUTHENTICATED-INGRESS`也明确为`BLOCKED-SPEC`：它不阻塞in-process Gateway或App Intents，
但在target/access owner获批前阻塞transport与Local Automation正向tracer。

### 为什么绝不能并入 `ClipboardFlow`

clipboard-flow owner的common caller是App UI与系统pasteboard lifecycle，拥有observe/capture/paste、panel
close、single-flight 与 backpressure。External Gateway 的 caller 是不受信任的本机进程，拥有
enrollment/grant/audit/quota/versioned wire/OCC。二者没有共同的app-service调用边界；把Python command塞进
clipboard-flow owner会让UI clipboard owner理解credentials和wire，也可能让external caller获得
capture/pasteboard side effects。两条路径只在Authority/Domain的History semantics与唯一transaction处汇合；
Gateway不绕过capability facade去调用一般用途`ClipboardHistory`。相反，让gateway自建SwiftData writer会创建第二 writer并绕过
Authority transaction/index/observation invariants。

`clipyctl` stdin的`describeFormatCapabilities`只能消费各owner导出的immutable Foundation summaries；
Rank 7的build/test inventory不能直接成为production依赖。runtime join/injection owner未批准前只允许冻结
schema与pure serializer，不宣称endpoint已实现。capability
清单只是信息，不是授权凭证；gateway 必须以 server-side manifest 与当前 grant为准，不能相信 Python
回传的能力。输出不得含 clipboard bytes、query、用户路径、store path 或历史中的实际 UTI inventory。

### Depth、deletion test 与最小 TDD

删除 `clipyctl`/local adapter 后，JSON validation、cold start、framing、deadline 与 stable error mapping 会
重新散入每个 Python/shell/editor caller；deletion test 通过。删除 `ExternalGateway` 后 grant/OCC/audit
若散进 transports 则是安全回归，不是“简化”。transport adapter 可以有一次 disposable UDS/XPC/Apple
Events 判别 spike，但一次只保留一个 production implementation；public CLI contract 不绑定实验结果。

最小 TDD：

1. Spec gate：冻结JSON/exit/no-content-diagnostics形状，但不shipping deterministic server stub。
2. Red：直接驱动 internal `ExternalGateway`：未 enrollment、未 grant、revoke-before-authoritative-check、
   跨 connection locator、quota/timeout 与 app not-ready 都返回稳定 typed code；不能以空列表/unchanged
   冒充成功。
3. Green：先实现唯一 ExternalGateway的deny与真实Authority-backed bounded positive path。
4. Red/Green：让已接纳App Intents通过prebound facade使用同一Gateway，不复制policy。
5. Red：随后实现CLI pure parser/serializer；unknown major/oversize/duplicate keys失败，stdout恰一个JSON，
   stderr/content logs无clipboard内容。它不伪造Gateway result。
6. Red：先关闭authenticated-ingress blocker，再用signed/sandbox/cold-launch matrix选一个production
   private transport并把CLI接到同一Gateway；
   第一production operation只读且bounded。
7. Red：获准单项 mutation 从 Python 发出，park 在 pre-commit、随后 revoke；不得 commit。获准且 token
   current 时 exactly one Authority commit/position，observer 收到同一 authoritative state。
8. Red：扫描/运行时 canary 证明 `clipyctl`不import HistoryStorage/SwiftData，ClipyApp transport只见
   restricted public ingress/HistoryCore DTO、不import internal Storage types，且只有
   `HistoryAuthority` 创建 writable contexts。
9. Refactor：删除所有test-only fallback wiring；只保留一个已证明的 private
   transport，不向 Python公开 transport framing。

### 明确拒绝的 overdesign

不做 public socket protocol、network daemon、remote API、generic command bus、arbitrary
`HistoryAction` passthrough、每语言 SDK、dynamic automation plugin或第二 writer。Python 不直读/改数据库，
不复用 process-local page cursor/raw Swift IDs，不通过 `ClipboardFlow` 注入 capture，也不因“本机同 UID”
跳过 opt-in、grant、quota 与 audit。详尽 transport/threat-model 研究见
[`07-python-local-automation.md`](07-python-local-automation.md)。

## 12. Rank 10 — 聚焦 build-log diagnostic parser

### Evidence 与 common caller

[`run_gates.sh`](../../../scripts/run_gates.sh) 不运行已有 scanner self-tests；
[`escape_hatch_scan.py`](../../../scripts/escape_hatch_scan.py) 只扫 root `Sources/Tests`，不扫
`ClipyApp`；[`import_gate.py`](../../../scripts/import_gate.py) 允许 PresentationUI 的 ImageIO 漂移且不锁
manifest graph；[`public_symbol_snapshot.sh`](../../../scripts/public_symbol_snapshot.sh) 只比较 symbol title，
同名 overload/参数/isolation 变化可能漏过。CI workflow 还在多个 jobs 复制 warning/error filter，其中
AppIntents metadata 例外需要保持极窄。

这些是多个 owner 的不同问题，不应被“repo validation”这一名字强行统一。唯一已显示明确 common caller
与同一 failure grammar 的候选，是多个 build/test jobs 对编译日志的 diagnostic classification。scanner
coverage、symbol fidelity 与 perf artifact claim 分别在各自 script/runner 内 harden。

### Interface sketch

```text
scripts/classify-build-log.py <log> <allowlist-profile>
    -> structured pass/fail + matched lines
```

这里的 interface 只包含 log input、精确 allowlist profile、exit code 与命中的原始 lines。workflow
负责运输 log 与调用 parser；parser 不知道 target graph、symbol graph、benchmark claim 或 GitHub job。

### Depth/locality 与 deletion test

depth 来自经过 adversarial fixtures 的一个窄 log grammar：它隐藏 allowlist context、EOF、相邻真实
diagnostic 与 matched-line reporting。删除后同一 awk/allowlist/error matching 会重新散入多个 workflow
jobs；deletion test 通过。删除它不应影响 scanner、symbol snapshot 或 perf artifact；这条边界反而证明
没有统一 framework。

### 最小 TDD

1. 给 parser 输入：仅允许的 AppIntents metadata、同 block 内额外真实 error、EOF、大小写/空白变化、
   普通 warning；只允许精确窄例外并回显所有拒绝 lines。
2. Green：迁移一个 job；保留另一个旧 matcher 作 characterization 对照，不同时改 allowlist 语义。
3. Red：构造“允许行旁边夹真实 error”，新 parser 必须失败；再逐 job 替换并删除旧 awk 片段。
4. 独立 hardening：scanner root/self-test、symbol declaration fidelity、perf artifact metadata 各写在自己
   owner 的 Behavior Card 中，不接入这个 parser 的 abstraction。

### Trade-off 与拒绝的 overdesign

工具维护本身有成本，因此排在产品 correctness 后。不要新增 `validate-repository.sh` 总入口来冒充深
module，不要发明 YAML DSL、跨项目 CI framework、统一 validation/evidence policy、通用 policy engine、
自动把任意 benchmark 合成总分，或让一个绿色 job 替代同一最终checkout的多job ledger。

## 13. 已经够深：修 implementation，不再包一层

以下 modules 不是“代码多所以不能动”，而是它们已有小 interface、隐藏了真实复杂度，并通过 deletion
test。现有缺陷应在 implementation 或 owning spec 内修，不应再造 wrapper。

| 现有 module | 为什么已有 depth | 当前应做什么 | 不应做什么 |
|---|---|---|---|
| [`ClipboardHistory`](../../../Sources/HistoryCore/ClipboardHistory.swift) | caller 只用 action、purpose-specific reads、typed values；背后隐藏 Domain、SwiftData、index、codec 与 actor。 | 裁决未批准的 retention readback；保持 purpose-specific values。External Gateway为App Intents提供prebound connection facade，为Local Automation提供只委托认证的窄ingress wrapper。 | 不加 generic repository/query builder、transaction callback、raw SwiftData escape；不为 Python 暴露 generic action 或数据库 seam。 |
| [`HistoryAuthority`](../../../Sources/HistoryStorage/HistoryAuthority.swift) | 单 actor interface 隐藏 fresh context、fact→plan→stamp→transaction→index→invalidation 的严格顺序。 | 在现有 `performStartup` 增加只读 classification phase；按证据逐条抽 pure retention invariant。 | 不造 startup/retention service、第二 writer、第二 facade、`AuthorityManager` 或跨 actor model cache。 |
| [`IngestFactLoader` / `MutationFactLoaders`](../../../Sources/HistoryStorage/FactLoaders.swift) | 把 `@Model` hydration、codec failure mapping、bounded fetch 转成 immutable Domain facts。删除后所有 actions 都要理解 schema。 | 为 dedup candidate 建更窄 facts；共享完整 hydration only where required。 | 不建 generic ORM repository、predicate DSL 或 mock row store。 |
| [`SearchWorker`](../../../Sources/HistoryStorage/SearchWorker.swift) | 一个 page interface 隐藏 exact/regexp/fuzzy algorithms、Fuse isolation、ordering 与 presentation ranges。 | 在 scan/sort loops 加 cooperative checkpoints；由 `SwiftDataHistory` private path 提前 admission。 | 不包 `SearchExecution`/`MatcherService`、不把 Fuse 暴露为 adapter、不给每个 mode 一个 protocol。 |
| [`ThumbnailService`](../../../Sources/HistoryStorage/ThumbnailService.swift) | exact-key interface 隐藏 Authority source fence、single-flight、off-Authority decode、PNG bound；completed bytes不保留。 | 在 source hydration 前加 distinct-flight count/byte permit与cancel policy；修 rectangular extent；按`DEC-THUMBNAIL-REQUEST-OWNER`裁决UI scheduling→Storage request seam。 | 不再包 cache manager/worker pool protocol；不复制 Maccy fingerprint-only disk cache，也不把row thumbnail并入ContentPreview。 |
| [`PreviewContentLoader`](../../../Sources/PresentationUI/HistoryPreviewView.swift) | reference-exact load interface 隐藏 details read、late-result fence 与 bounded applied state。 | 修 stale-version spinner 与 lifecycle；规格批准后把 source selection/rendering 交给 concrete `ContentPreview`，loader 继续拥有 exact reference。 | 不造第二 preview repository、让 renderer 直接读 History、另一个 image cache或 view model chain。 |
| [`PreviewPaneState`](../../../Sources/PresentationUI/PreviewPaneState.swift) | selection/lifecycle inputs隐藏 dwell、suppression、open/retarget task；删除后状态会散进 view/panel。 | 修 `panelClosed` 后 auto-open arming语义并强化 lifecycle tests。 | 不并入全局 screen reducer，不加 state-machine framework。 |
| [`PasteboardAdapter`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift) | 它是刻意窄的 AppKit adapter，不需要以业务逻辑变“深”；价值是保持 translation seam。 | early concealed/type/byte preflight、stable exhaustive outcome、一次 staged write；从 `ClipboardFormats` 引用 stable special identifiers，但 paste recipe 仍归 Adapter。 | 不让它拥有 History、queue、panel close、access UX、capture policy 或中央 format manager。 |
| [`SwiftDataHistory`](../../../Sources/HistoryStorage/SwiftDataHistory.swift) | public concrete adapter把 `ClipboardHistory` 映射到 Authority/workers；浅 orchestration在这里是合理 facade 角色。 | 用 private function/value 消除 browse/observe search execution 分叉，保持 external interface。 | 不新增 search service/actor，也不把它扩成 application coordinator、recovery UI owner或 test fake switchboard。 |

`ThumbnailStore` 处于不同状态：它现在确实拥有 completed cache interface，但 process-lifetime retention、
whole-reset eviction 与 late completion 语义尚未正式批准。先做决策：若 G1/SLO 不支持 completed cache，
删除它的 retention、只保留 view-lifetime in-flight/result state；若批准，就深化**现有** store 的 LRU/byte
law/invalidation/cancellation。两种情况都不应再包 `ImageCacheService`。

## 14. 架构实施守则

后续 Agent 对每个候选提交前应回答以下问题，并把答案留在 PR/commit evidence 中：

1. Common caller 与 seam 在哪里？为何不是把两个相邻文件机械合并？
2. 新 interface 比旧 callers 需要知道的顺序/状态少了什么？
3. Implementation 隐藏了哪些 failure、ordering、capacity、cancellation 或 coherence invariants？
4. 删除 module 后复杂度会具体散回哪些 callers？
5. 测试是否通过同一 interface，还是仍在复制内部步骤？
6. 是否删除了被替代的 wiring/tests/branches，而不是 layer 一个新类型？
7. 新 protocol 是否至少有两个 real implementations？若没有，为何不用 concrete internal type？
8. 是否使用 private pasteboard、真实 in-memory/temp SwiftData，而不是 mock internal collaborators？
9. 是否先跑 decision experiment，再删除未选策略？
10. 是否保持 public `HistoryCore` seam、single writer、Foundation-only Domain 与 actor value crossing 不变？
11. 新格式改变的是 stable fact 还是哪个 purpose recipe？对应 version/migration disposition 是否独立？
12. Preview interface 是否只含 bounded immutable primitives，Python path 是否仍经过 grant 与唯一 writer？
13. source tiering 是否先有 G8 baseline/trigger，且 retention、residency、depot 与 derived cache 的 limits、
    tokens、failure 仍各自独立？capture 已经形成完整 `Data` 的峰值是否被单独记账？
14. 提高 5,000 hard bound 前，正常 capture/startup/recent/retention/UI 是否已删除 O(N) 路径；
    必须线性的 search/clear maintenance 是否有分页、budget、恢复与 slope evidence？depot GC只在
    large-content/P3路线被独立触发后才进入该路线的scale gate，不能成为count-cap默认前置。

最重要的结构性结论是：Clipy 的强项不是“层多”，而是 History deep module 已经把高风险语义压在一个
窄 seam 后。下一阶段先在现有 owners 内处理 app flow、startup、search 与 Presentation task
ownership；并先用 SwiftData baseline 跑完 G8 fault/RSS/aggregate-residency 证据。只有 baseline 超预算才
在 HistoryStorage 内采用 B 的 loose immutable `ContentDepot`；segment C 等 B soak 证明瓶颈后再审，不能与
“无限历史”一起批量落地。随后以独立版本把 `ClipboardFormats` 的稳定事实、`ContentPreview` 的 transient
rendering 与各 purpose recipes 分开。Python自动化可以先规格化CLI wire shape，但实现不能早于Gateway；
production transport只能经受限authenticated ingress进入唯一 External Gateway，不能穿过`ClipboardFlow`
或数据库捷径。实施顺序固定为owning spec shape → Gateway/AUTO-2 → 已接纳App
Intents tracer → CLI pure codec → signed transport discriminator/adapter → browse/read/write；final matrix只
复验已选transport，失败时重开decision，不在最后才首次决定架构。只有 deletion test 证明必要时才提取 concrete type，不把扩展性误做成
可配置框架。一个 concrete owner、一个明确行为、一个真实 test surface，通常比五个 protocol 与十个
test doubles 更强。
