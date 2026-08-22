# 详细发现：Standards × Spec × Product

> 基线：Clipy `cda2ba0a4a25`，Maccy `818f03d0e0d3`。本文只审查，不修改
> product code。每项都区分“源码已证明”“可构造风险”“运行证据缺失”，避免把
> 静态推断写成已测事故。

## 1. 两条审查轴

| 轴 | 当前判断 | 代表问题 |
|---|---|---|
| **Standards：是否遵守仓库自己的工程规则** | Domain/Authority 边界总体保持良好，但 public surface、owner/import、single-writer bootstrap、CI provenance 与测试 seam 已漂移。 | 测试故障注入成为 shipped public API；PresentationUI 直接 import ImageIO；outer observation 无界；复制 production wiring 的测试给出假证据。 |
| **Spec：是否实现权威需求** | 一批窄修复已经落地，但未先修改规格；数个 UI/retention/paste 语义与 `docs/` 直接矛盾。 | retention readback 与 write-only 规格冲突；“Keep”不保持 Effective Content；unified retention UI 被拆散；ImageIO owner 违反 V2-07。 |
| **Product：是否形成可信 macOS 主路径** | 还没有。当前内核强于 Maccy，但权限、键盘、multi-item、真实 UI、恢复和 signed release 都未闭环。 | AccessBehavior 未建模；固定快捷键冲突；没有真实 XCUI；无签名、公证、A11y/localization 证据。 |

## 2. 基线与治理

### GOV-1 — Final HEAD 不是 CI-green（Confirmed / Blocker）

2026-08-22T00:56:44Z 查询到的
[run 32348271453](https://github.com/GuangDai/Clipy/actions/runs/32348271453)
绑定 `cda2ba0a4a25264ce7855ee5ae71ef60b8252501`：

- [`Lint + source gates`](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96367240991)、
  [`Perf proofs (§9)`](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96367728660)
  成功；
- [SwiftPM functional](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96367728696)
  与 [perf-helper](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96367728793)
  两个 job 因
  [`ThumbnailStoreTests.swift:209`](../../../Tests/PresentationUITests/ThumbnailStoreTests.swift#L209)
  和第 224 行在同步 `#expect` autoclosure 中 `await` actor 方法而编译失败；
- [app job](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96367728741)
  的 `xcodebuild clean build test` 本体成功，但 self-scan 因
  [`AppPasteOrchestrationTests.swift:267`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppPasteOrchestrationTests.swift#L267)
  的 sendable-capture warning 失败；
- dispatch-only
  [Exact matcher A/B](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96368136670)
  与 [5k evidence](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96368137104)
  被跳过。

最近同一常规 workflow scope 全绿的是 `2ff4d2a` / run
[32321062928](https://github.com/GuangDai/Clipy/actions/runs/32321062928)，不是当前
HEAD。修改方向不是放宽warning filter：第一slice只恢复测试编译/warning，并让同一final
SHA的五个常规jobs全绿；复制production pump的问题由后续`ClipboardFlow` copy-lane独立slice替换，不能混入
baseline repair。

### GOV-2 — 规格、接口、实现与 ledger 不是同一事实（Confirmed / Blocker）

- [`ClipboardHistory.retentionConfiguration()`](../../../Sources/HistoryCore/ClipboardHistory.swift#L103)
  已成为 public requirement；但
  [`V2-02-retention.md`](../../v2/V2-02-retention.md) 仍明确 write-only，V2-07 仍说
  不增加 public DTO。
- [`DisplayImageDecoder.swift`](../../../Sources/PresentationUI/DisplayImageDecoder.swift)
  直接 import ImageIO；权威 architecture/roadmap/V2-07 仍把 ImageIO 限在
  HistoryStorage，并禁止 `CGImage` owner 漂到 PresentationUI。
- [`ThumbnailStore.image(for:)`](../../../Sources/PresentationUI/ThumbnailStore.swift#L132)
  是 `public -> CGImage?`，decoder actor也把CGImage传回MainActor；V2-07 §8.4明确写
  “No ... CGImage ... crosses”。裁决不能只给ImageIO path加allowlist，还必须决定actor
  boundary与public CGImage surface。
- [`PROGRESS.md`](../../PROGRESS.md) 仍把 `cc59aa8` 写成 current landed head；没有记录
  `cc59aa8..cda2ba0` 的十四个commits和当前红run（另：最近绿色`2ff4d2a..cda2ba0`
  是八个commits）。
- overview、V2 roadmap、V2 progress 对 step 9、R.7/state 3 的状态互相矛盾；AGENTS
  也同时出现“产品已完成”和“仍是 placeholder”的陈旧段落。

先做规格裁决：readback 是批准新增，还是撤回 public seam；ImageIO 的 owner 是正式
改规，还是回到 Storage/新的 purpose-specific decoder。只有裁决后才更新 symbol
snapshot、实现、状态账本。源码注释中的 “follow-up” 不是设计准入。

### GOV-3 — 测试便利正在扩大 shipped public surface（Confirmed / High）

[`PasteboardAdapter`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L47) 的
`simulatedUnavailableTypeIdentifiers` / `simulatedRejectedWriteTypeIdentifiers` 是 public
mutable vars；[`ThumbnailStore`](../../../Sources/PresentationUI/ThumbnailStore.swift#L74)
公开 cache knobs/counters；`PreviewContent.resolve` 也只因 hosted smoke 而 public。Adapter
还公开raw `NSPasteboard` property，以及注释声称只有adapter生产却可由任意caller构造的
`CaptureOutcome.init`，都扩大了调用者需要理解/可破坏的interface。

这违反“public 只给 caller-visible seam”。测试应通过 `@testable`、package/internal
环境注入或 app-target internal flow 安排失败；不应让生产调用者切换模拟故障。还应给
PasteboardAdapter/PresentationUI 建最小 public-surface gate，HistoryCore snapshot
不能保护其它 products。

### GOV-4 — 现有 gates 的名称强于其证明范围（Proof gap / Medium tooling hardening）

- [`public_symbol_snapshot.sh`](../../../scripts/public_symbol_snapshot.sh) 只保存去重后的
  `names.title`，丢掉 owner、overload、参数、返回类型、`async/throws`、isolation、
  availability；删除同名 overload 可以不漂移。
- [`escape_hatch_scan.py`](../../../scripts/escape_hatch_scan.py) 不扫描 `ClipyApp/Sources`
  与 `ClipyApp/Tests`；`run_gates.sh` 不执行 scanner self-tests。
- import gate 不锁 Package/XcodeGen dependency graph，也不能证明只有
  `HistoryAuthority` 创建 writable `ModelContext`。
- workflow 中 CoreData diagnostic filter 多处复制；白名单 block 内夹入另一条 error
  仍可能被吞。

建议锁 normalized precise identifier + declaration fragments，并加外部 client compile
fixture；补 manifest/ModelContext ownership gate；把 diagnostic classifier 抽成有
adversarial fixtures 的脚本。它们是防回归工具，不是新的通用 framework。

## 3. 数据安全与持久化

### DATA-0 — Local-only store 依赖 CloudKit `.automatic` 默认值（Confirmed configuration / conditional entitlement trigger / High privacy impact）

[`SwiftDataHistory.open`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L138) 用
`ModelConfiguration(schema:url:)`且没有传`cloudKitDatabase`。Apple该initializer的默认值是
`.automatic`；其语义是从app entitlements的primary ubiquity container启用managed CloudKit
sync，而[`.none`](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct/none)
才显式禁用。当前project没有iCloud entitlement，所以没有证据表明现版本已经上传；风险是未来加入
可被`.automatic`发现的CloudKit container及所需iCloud/Background Modes capabilities时，敏感clipboard
store的配置可能在没有这段源码变化的情况下改变，违反no-network/local-only设计。当前schema含
`.unique`时究竟open失败、不同步还是产生其他行为仍为UNKNOWN，不能声称一定上传。

Production configuration应显式`.none`，并加manifest/entitlement negative gate：除非owning
spec批准sync，任何iCloud/CloudKit entitlement都使build红。TDD通过production config seam
检查CloudKit mode，不依赖当前“恰好没有entitlement”的间接安全。Apple initializer与
`.automatic`语义见
[`ModelConfiguration.init`](https://developer.apple.com/documentation/swiftdata/modelconfiguration/init(_:schema:url:allowssave:cloudkitdatabase:))。

### DATA-1 — singleton 的“存在”与“合法”都没有在 publication 前闭合（Confirmed control flow / conditional corruption trigger / High impact）

[`HistoryAuthority.ensurePositionSingleton`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L409)
只查询预期 key；0 rows 就插入 position 0 和调用者初始 count。一个已有 items 的库若
singleton 被删除、wrong-key 或部分损坏，会被“修复”为新 position。下一次 capture
可能以更低 count 批量淘汰历史。

即使恰有一行，`case 1`也直接通过；startup随后构建Signature Index、检查RetainedBytes对应关系，
但没有在facade publication前调用`decodePositionRow`验证`rawValue`和
`maximumUnpinnedItems`。因此一个存在但非法的position singleton可先open成功，再在第一次
读/写时失败；“startup已验证singleton”这个注释/账本claim强于实际control flow。

[`ensureRetentionExpansionConfig`](../../../Sources/HistoryStorage/HistoryAuthority+RetentionBootstrap.swift#L158)
同样在缺行时恢复为全 disabled，静默丢失用户 retention policy。两者违反 `05 §13`
的 new-store-only / no-silent-repair。

最小方向：在任何写入前区分 fresh store、合法 V1 migration、existing V2、corrupt；
查询 singleton table 的完整 key/cardinality；existing store 缺行必须 typed fail closed，
恰有一行也必须复用production decoder做完整value validation，且不得改变文件、items 或
position。不要用“如果 query 正确 key 得 0”代表 fresh。

这里不能把所有startup repair混为一谈：position/config是不可从items唯一推导的authority
state，缺失时不得猜；`RetainedBytesRow`则是可从已验证Canonical/revision blobs重建的derived
projection。后者可保留一个显式、幂等、先完整计算验证再提交的missing-only rebuild；不需要为了
猜测损坏原因再造marker，但必须拒绝orphan、unknown version和decode/coverage失败。

### DATA-2 — RetainedBytes 的 relational invariant 仍不完整（Confirmed / High）

[`RetentionConfigLoading.swift`](../../../Sources/HistoryStorage/RetentionConfigLoading.swift#L250)
仍接受：

- `canonicalBytes == 0`；
- `revisionCount > 0 && revisionBytes == 0`；
- `revisionBytes < revisionCount`。

canonical/revision representation 都非空，因此这些 scalar 不可能对应合法 blob。它们会
让 R2/R3 低估 durable bytes 并过度保留敏感内容。除 startup stamping 外，R3 已经
decode revision facts 时也没有执行 spec 要求的 blob↔scalar cross-check。

补全关系校验，并在 capture、revise、policy sweep、restart 四条路径证明：失败发生在
mutation 前，旧 store/position 可重开且 byte-exact 不变。不要因此撤销所有projection rebuild：
缺行但源blobs完整时，RetainedBytes是可重算值；修复权限只限这个derived projection，不能外推到
position/config singleton。

### DATA-3 — 重复 revision ID 可写入“本次可提交、下次不可解码”的 blob（Conditional / High）

[`planRevision`](../../../Sources/HistoryDomain/PlannersPinRevision.swift#L208) append 前不查
candidate revision ID 是否已存在；codec encode 只序列化，decode 才拒绝 duplicate ID。
正常 UUID 碰撞概率极低，但 invariant 不能靠概率维护，测试 ID source 可确定复现。

Domain 应在 append 前拒绝；Storage 若 ID source 可重试则做有界 remint。还要增加性质：
任意成功 append plan 的 `newID ∉ oldIDs`，apply 后 unique set 数量恰加一；真实 store
路径必须证明失败时无 blob write/position advance。

### DATA-4 — Dedup candidates 过宽，完整 hydrate 每个 lineage（Confirmed structure / High）

`CompleteDedupCandidates` 持有 `[HistoryItemState]`；loader 对每个 signature candidate
decode 完整 revision blob，而一般 candidate ranking/containment 只需要 id、canonical、
occurrence/version。共同小 representation + 每项大型 revisions 可产生 O(C × lineage)
live values；这支持资源风险，但尚未证明日常 RSS 数值。

先拆出 narrow candidate facts，保持 deterministic rank 和 byte-exact collision confirm；
hint/winner 才 hydrate 完整 lineage。必须先裁决“corrupt non-winner 是否仍阻断 capture”，
不能为了性能悄悄改变 fail-closed 语义。

### DATA-5 — 不可信 `observedAt` 可支配 destructive retention（Conditional / High）

public `ClipboardCapture.observedAt` 只验证 finite，却被作为 R1 的 `now`。一个未来时间的
capture 可在同一 commit 退役所有旧 unpinned，并把 primary recency 固定到未来。正常
adapter 使用当前时间，但 public boundary 和 clock jump 都使该条件可构造。

需要规格裁决：以 Authority-owned admitted time 支配 retention/recency，原始 observed
time 只作 best-effort observation；或定义有限 skew admission。还要诚实说明当前 age
policy 只在 capture/set-policy 等 trigger 执行，不随墙钟自动清理；若要“到时即删”，
那是带 sleep/wake/startup 语义的新维护调度，不应暗加。

### DATA-6 — Public observation 的外层 buffer 是无界的（Confirmed / High）

[`SwiftDataHistory.observe`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L324)
外层 `AsyncThrowingStream` 没有 buffering policy；Swift 默认 `Int.max`。内层 invalidation
即使 `.bufferingNewest(1)`，慢或暂停的下游仍可让外层累计完整 `HistoryPage`。

这是 state snapshot，不是必须逐事件回放的 log；应明确 outer newest(1)，并在慢消费者
和 burst commits 下证明只保留最新 position、内存/queued pages 有硬界。

### DATA-7 — 第二 writer guard 只比较 URL 字面量且仅限单进程（Conditional / High if a second process is supported）

AppComposition 的 guard 是 process-local `Set<URL>` 原值；`..`、symlink、standardized
alias 可绕过，同一 app 的第二进程也不受保护。生产默认 URL 固定，所以触发频率未知。

最小先 canonicalize + resolve symlink，并声明/验证正常LaunchServices single-instance路径。
如果release只支持一个app process，就在创建任何`ModelContainer`前对dedicated StoreRoot取得
一个nonblocking、进程寿命内持有的窄lease，第二进程显示“已由另一实例使用”而不是继续open；
child-process test证明alias收敛、第二lease失败、首进程退出后可重取。若未来App Intent/widget
必须独立写，则这不再是“加一把锁”问题，而是新的跨进程writer/observation协议。文件协调可用于
文件操作，但不能被当作Clipy single-writer lease的替代证明。

### DATA-8 — 是否需要额外 global byte ceiling 尚无测量（Evidence-gated / Medium）

当前已有finite retained-count、per-item/capture/revision bounds；但用户V2 byte policy可关闭，
pinned不受普通淘汰，理论内容上限仍很大。R2 scalar又不等于SQLite、WAL、JSON/base64与
external blob物理占用。静态上界不能证明应立即增加另一个拒绝/淘汰语义。

先让capacity/ENOSPC失败可见且可恢复，测代表store overhead、全pinned/revision压力与reopen。
只有达到预先容量风险阈值，再批准包含pinned/revisions的hard content ceiling；它应显式拒绝
并给恢复，不静默淘汰。UI称“内容数据预算”，不承诺等于物理磁盘。

### DATA-9 — 所有非-marker UTI都参与dedup，易变bookkeeping会制造重复（Evidence-gated / Medium）

Clipy对所有合法representation做签名与containment。浏览器的source token、LinkPresentation/
WebKit bookkeeping若每次变化，即使用户可见text相同也会插入新item。Maccy会忽略一组此类
metadata做dedup，但那些private UTI没有Apple稳定contract，不能复制整张名单。

先采Chrome/Safari/Notes的synthetic/consented fixtures；若确认高频，再把whole-capture privacy
marker与“保留用于paste但忽略dedup”的representation role分开。测试必须证明approved
volatile变化会coalesce，而任何content bytes差异和forced hash collision仍不会误合并。

### DATA-10 — 两阶段revision与retention trigger有未裁决语义（Spec question / Medium）

- phase 1把`revert(r1)`解析成bytes后，R3可在不改ContentVersion的情况下prune r1；phase 2
  当前仍可append缓存bytes。可选phase-1 snapshot语义，或要求transaction时target仍存在。
- `maxUnpinned=1`时把另一个pinned item unpin会暂时得到2个unpinned；age保护也立即消失，
  但unpin不触发sweep。当前trigger spec允许延迟到下一次capture/set-policy。

两者都不能由实现Agent“顺手修”。Owning spec先选择语义，再写相反可判别tests；若保留现状，
UI必须准确说明event-triggered invariant，而不是把maximum/expiry描述为持续成立。

### DATA-11 — Signature metadata 尚不能承担“无候选”的负证据（Confirmed invariant gap / High）

[`buildSignatureIndexAtStartup`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L463)和
capture-time rebuild都只decode `canonicalSignatureBlob`；它们不decode Canonical，也不调用
[`SignatureBlobCodec.validateCoverage`](../../../Sources/HistoryStorage/SignatureBlobCodec.swift#L153)。
因此`ready`只证明每行贡献了一组结构合法的signature entries，未证明这些entries与该行Canonical
一一对应。若fingerprint被改或某个Canonical type被漏掉，incoming exact content可能得不到旧行
candidate并插入duplicate；byte-exact confirm只阻止false positive，不能修复此前的false negative。

codec本身还只逐entry检查`1...maximumRepresentationBytes`，没有用checked addition证明所有
`byteCount`之和不超过`maximumCaptureBytes`。V1→V2 backfill其实已经decode Canonical以校验revision
containment，却漏掉零额外blob-I/O的coverage check；测试oracle
[`MigrationSeeding.recomputedScalars`](../../../Tests/HistoryStorageTests/Support/MigrationSeeding.swift#L263)
又复制了同一遗漏，所以“独立重算”不会抓到这个坏fixture。

第一slice补checked aggregate rejection，并在migration/backfill及其独立oracle调用coverage；用
“坏signature→restart→复制同一Canonical”Red证明不得插入duplicate。随后由owning spec选择
Signature Index的负证据contract：要么startup/rebuild也证明Canonical coverage，要么降格`ready`
与no-candidate语义并提供可判定fallback。不能继续同时声称“complete”与“startup从不验证coverage”。

### DATA-12 — R3 sweep 与 migration backfill 缺 aggregate-residency 证据（Confirmed structure / unmeasured resource risk / High）

[`RetentionPolicySweep`](../../../Sources/HistoryStorage/RetentionPolicySweep.swift#L180)逐个decode所有
超过新R3阈值的lineage，并把完整`PruneLineage`保留到最终单transaction；合法最坏情况下所有
5,000 items都可超过阈值，每项revision content上限256 MiB，约1.2207 TiB只是**可处理逻辑bytes的
结构上界**，不是已测RSS。SwiftData faulting、Data共享和allocator行为都不能由源码推断。

[`RetainedBytesBackfill`](../../../Sources/HistoryStorage/RetainedBytesBackfill.swift#L126)同样用5,001作
over-limit fetch guard；第5,001行会先使异常store失败，合法store最多在一个context内逐行触碰5,000个
Canonical/revision blobs，最后才提交全部projection；
它没有像R3那样把每个decoded lineage显式存进字典，但仍缺大blob迁移的峰值RSS/时长证据。现有
三行migration fixtures和5k但无revision lineage的perf seeding不能关闭这个问题。

先用terminated child构造N×8 MiB、N×64 MiB且大量items同时exceed的合法store，分别测sweep与
migration的peak RSS、wall time、完成后reopen invariants。只有越过预设budget才实现bounded、
restart-safe batch/applying state或批准更窄aggregate contract；不要仅凭1.2207 TiB理论数值先引入
新的maintenance framework，也不要把单行bound宣传成aggregate bound。

### DATA-13 — restart、migration 与 WS13 的测试名称强于当前证据（Confirmed proof gaps / High）

- [`HistoryMigrationTests`](../../../Tests/HistoryStorageTests/HistoryMigrationTests.swift#L94)在旧V1
  container/context和attached models仍存活时打开同一URL的新migration container；
  [`HistoryMigrationInterruptionTests`](../../../Tests/HistoryStorageTests/HistoryMigrationInterruptionTests.swift#L166)
  也让parent的V1 coordinator活着，再让child迁移、parent重开。后者确实证明child在backfill
  transaction前死亡且该store在这种拓扑下可恢复，但不等同于“旧owner完全退出后的物理restart”。
- [`WS14RestartReconstructionTests`](../../../Tests/HistoryStorageTests/WS14RestartReconstructionTests.swift#L111)
  在原`history`仍在scope内时再次`openHistory`。它证明第二facade可见durable state，不证明
  process teardown、WAL/external references清理后的cold restart。
- [`WS13TransactionFailureTests`](../../../Tests/HistoryStorageTests/WS13TransactionFailureTests.swift#L92)
  详细检查HistoryItemRow和position，却不检查同transaction的`RetainedBytesRow`；“index unchanged”
  只由下一次distinct capture成功间接推断。subscriber为newest-style snapshot时，一个错误的failed
  publish(position 2)还可能被随后真正的position 2合并，最终`[2]`不能归因到哪次attempt。

保留这些tests作为same-process、overlapping-coordinator或closure-throw证据，但把
“restart/complete rollback”升级为少量真正
tracer：seed child退出→migrate/kill child退出→reopen/verify child，每段只传primitive manifest与
payload digests；WS14也用writer child退出后reader child全量public验证。WS13在失败后、任何后继
commit前直接断言row、两个singletons、RetainedBytes与index snapshot，并用noncoalescing publish
counter区分failed/success attempts。无需把全部快速测试都process化。

### DATA-14 — `.openStore` 抹平根因，当前路径又不是可安全隔离的 StoreRoot（Confirmed / High recovery impact）

[`SwiftDataHistory.open`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L148)把
`ModelContainer` construction中的所有error统一映射成`.persistence(.openStore)`；migration codec
失败、权限、容量不足、future schema与一般open failure因而不能驱动不同恢复。启动UI又只有Quit。
在这个证据下自动“识别损坏并quarantine”会把可重试的权限/ENOSPC或不兼容新schema误当损坏。

此外默认locator是`.../Application Support/Clipy/history.store`；`history.store`只是交给SwiftData
的URL，不是Apple承诺的完整SQLite/WAL/SHM/`.externalStorage`文件族，而整个`Clipy`目录未来又可能
承载非history数据。先把history所有权收窄到dedicated
`.../Clipy/HistoryStore/history.store` StoreRoot，并规定只有无live coordinator的pre-open/relaunch
recovery child可操作该root。恢复UX先提供Retry与Reveal；只有稳定error-chain/fixture能分类且用户
确认后，才原子rename整个StoreRoot到带时间戳的敏感quarantine。不得只移动locator文件、猜sidecar
名字、移动通用parent、静默建空库或在ENOSPC时承诺`clear`一定能成功（删除本身也需要写）。

### DATA-15 — external-storage diagnostic filter 的完整性gate没有hydrate完整payload（Confirmed proof gap / High）

CI把`Failed to clone external data reference`多行block标为known-benign并过滤；后续prepare验证
row/position/transaction scalars、第一页projection，以及row 0的public coalesce。它没有读取每一行
的Canonical、revision与paste/details payload，因此“进程exit 0 + JSON正确”不能证明被过滤错误
没有留下另一个尚未fault的坏external reference。

在继续保留白名单前，加独立validation child：seed process完全退出后重开，遍历全部IDs，经过
public details/paste路径强制hydrate每个持久payload并与seed manifest的长度+cryptographic digest
核对，最后再验证position、RetainedBytes和全量ID集合；child正常退出后才允许filter将该特定block
视为该workload内可容忍。这个gate证明的是该fixture的逻辑可读性，不是Apple对external-storage
finalization、crash atomicity或物理清理的通用承诺。

## 4. Clipboard capture、copy 与 privacy

### CLIP-1 — AccessBehavior 未建模，deny/ask/read failure 可伪装 empty（Product blocker）

macOS 15.4+ 的
[`NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)
对 General pasteboard 有 `.default/.ask/.alwaysAllow/.alwaysDeny`。Clipy 启动即读并持续
polling，却没有 capability/health state、解释、暂停或恢复入口；private pasteboard tests
无法覆盖 TCC。

产品状态至少区分未决定、询问、允许、拒绝、读取失败、用户暂停；deny 时不能继续把
“没有 captured values”显示成空历史。最终准入需要 signed app + clean profile 的四态、
重启、login launch、System Settings 变化矩阵。

### CLIP-2 — Partial/all-unavailable snapshot 的接口会丢失必要区分（Confirmed / High）

[`captureOutcome`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L109) 的问题：

- 所有 declared types unavailable 时返回 `nil`，与 empty/retrieval failure 合并；
- public `capture()` 丢掉 partial status并返回部分 record；
- lineage hint 的 declared-but-nil/malformed data按当前明文契约视为optional/absent。它可能让
  self-copy失去coalesce hint，但若一律判incomplete，任意外部app又可用同名坏metadata阻断
  正常内容；这项必须单独裁决，不能并入content completeness；
- freeze 前就消费 `lastChangeCount`，无 start/end fence、无有界 retry。

当前代码调用 item-level `NSPasteboardItem.data(forType:)`；Apple 没有为它提供
“一定是 provider timeout/contents changed”的精确因果。结果应命名为 observed
unavailable/incomplete，不要伪造 failure reason。

建议先批准public result surface，再用closed exhaustive result表达content empty、complete、
incomplete、retrieval failure、changed-during-read；lineage metadata另行建模。start/end
changeCount稳定后才承认complete，竞争时做有界retry。删除或收紧public convenience，content
partial不能误入History。

### CLIP-3 — Known concealed item 仍先读取全部敏感 bytes（Confirmed / High）

adapter 已经拿到 `item.types`，但仍逐 type materialize `Data`，之后 Storage 才依据
conceal marker 拒绝。对于最该少读的内容，当前路径反而先冻结到内存。

在第一次 `data(forType:)` 前按 declared types whole-item short-circuit；然后再做 type
count/identifier length preflight、每 representation 和 aggregate byte accounting。Storage
保留防御性拒绝，adapter early reject 不是安全判断的唯一位置。

### CLIP-4 — Capture backlog 无界，但 overload 语义不能凭空选 newest-wins（Confirmed gap）

[`AppComposition`](../../../ClipyApp/Sources/AppComposition.swift#L192) 为每个 frozen
outcome 启动独立 Task，且用 `try?` 吞掉 capture failures。单值可很大，active/pending
count 与 aggregate bytes 无界。

语义判别只需把queue budget设为2并提交3个已freeze小值，比较bounded FIFO、active+latest、
显式reject/pause；真实RSS另跑有aggregate byte cap的Release stress。Polling本来会漏中间
clipboard，不代表应用可主动丢掉已经成功freeze的snapshot。选择的overload policy必须写
规格，并把drop/reject作为content-free health state呈现。

### CLIP-5 — Production paste 顺序与测试模型相反（Confirmed / High）

stream consumer 按 A、B 调同步 `paste()`，但 `paste()` 内再次 spawn Task；B 可以先
resolve/write，关闭 panel 后 A 再覆盖 clipboard。当前
[`AppPasteOrchestrationTests`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppPasteOrchestrationTests.swift)
手工重写串行 await pump，没有调用 production implementation。

此外`AsyncStream.makeStream()`未指定buffer policy，默认可积累到`Int.max`；nested paste
Task又没有handle/stop owner。这里确认的是“无显式顺序、生命周期和上限”，不等于正常用户
一定耗尽内存。

先在`AppComposition`收回完整clipboard-flow ownership；只有迁移production/tests并删除旧wiring后的
deletion test仍证明新类型有leverage，才提取app-internal concrete `ClipboardFlow`。copy lane固定为
exclusive first-accepted：第一个
request在任何`await`前占位，后续request返回busy而不排队。不可回滚的pasteboard write不适合
FIFO连续覆写，latest-wins也无法撤销已越过write point的旧请求。同一个owner负责resolve、write、
success receipt、close和failure state；capture在该owner内保留独立private lane与另行裁决的
overload语义。测试必须调用真实flow，不再复制步骤。

### CLIP-6 — `clear()` 后逐 type write 仍可留下 partial board（Conditional / High）

当前已经检查 `setData` Bool，这是旧报告后的真实进步；但 destructive clear 后逐
representation 写，竞争/失败可留下 prefix 或 lineage-only board，生产又吞失败。

先在内存构造一个 `NSPasteboardItem`，所有 representations/lineage 都成功 staging 后，
一次 `writeObjects([item])` 并检查结果。Apple 没有承诺跨进程原子事务，因此不能宣传
atomic；但产品不得静默留下已知 partial subset，也只有成功 receipt 才关闭 panel。

### CLIP-7 — first-item-only 是静默产品裁剪（Confirmed product gap）

General pasteboard 可以包含多个 items；Apple 的
[`pasteboardItems`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboarditems)
保留 item 边界，而 pasteboard 级 `types` 只是跨 item 的并集。Clipy 的
[`PasteboardAdapter`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L115) 只取 first，
[`ClipboardCapture`](../../../Sources/HistoryCore/Capture.swift#L53) 与
[`CanonicalContent`](../../../Sources/HistoryDomain/Content.swift#L126) 又只有一层 representations，
并要求同一 content 内 type identifier 唯一；一旦producer给出多item（Finder多文件是必须用真机
fixture确认的代表case），后续items必然被当前`first`裁掉，两个item含同一UTI也无法塞入现模型。

这不是给 format catalog 多加几条 UTI 就能修的能力缺口；catalog 只说明**一条
representation**如何处理，multi-item 是其外层的结构维度。短期应显式报告
`unsupportedClipboardShape`且不把 first item 伪装成完整历史；长期若产品批准，先引入
`ClipboardSnapshot → ordered items → ordered representations`的中性值图，再逐一裁决
fingerprint/dedup、revision、retention、marker scope、paste payload和migration。写回必须为每个
持久item构造新的`NSPasteboardItem`并使用
[`writeObjects`](https://developer.apple.com/documentation/appkit/nspasteboard/writeobjects(_:))；
不能采用Maccy式flatten，也不能把重复UTI合成一个set。详见
[`08-content-types-and-preview.md`](08-content-types-and-preview.md)。

### CLIP-8 — polling 只能是 best-effort latest state（Confirmed overclaim）

`changeCount` 不是 payload log；Timer 错过多个 fire 只补一次。启动即捕获现有 clipboard
会把非本次会话 copy 计为新occurrence，但当前实现/测试明确选择了立即捕获；poll loss本身
不能推出应改为baseline。产品需在onboarding/privacy与“启动即可找回当前clipboard”的便利
之间裁决：保留immediate import，或baseline并提供显式Import Current。self-write另可用
ticket/direct known capture记录一次，再让observer dedupe，避免写后很快被覆盖而漏occurrence。

### CLIP-9 — Paste 的“current-by-ID”与所见版本可能不同（Spec-compliant product decision / Medium）

用户选择 `(id,v1)` 后，payload读取只按ID；若并发revision产生v2，返回payload的reference
没有与请求比较。产品可能复制用户从未看见的新版内容；快速A/B选择又叠加CLIP-5乱序。
但当前03b/04明确把`pastePayload(for id)`定义为读取**current Effective**，所以这不是现行
规格的实现bug，而是UI选择模型与输出语义是否应更严格的产品决策。

若选择selection-stable语义，先修改owning spec，再要求
`payload.item == requestedReference`；不相等时不写、不close，提示内容已更新并reload。
若保留current-by-ID，则加相反test和明确文案/refresh，不能让实现Agent自行改变语义。

## 5. 内容类型能力与 Preview 边界

### TYPE-1 — “支持”被十个维护点表达，且已出现可见漂移（Confirmed / High）

当前至少有十个独立的type-policy维护点：
[`ContentProjector`](../../../Sources/HistoryStorage/ContentProjector.swift#L246) 的text eligibility与
image fallback两处；
[`HistoryAuthority`](../../../Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift#L146)
的thumbnail source；
[`HistoryPreviewView`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L77) 的text/image两处；
[`HistoryDetailsView`](../../../Sources/PresentationUI/HistoryDetailsView.swift#L658) 的text/image两处；
[`ReviseEditorView`](../../../Sources/PresentationUI/ReviseEditorView.swift#L349) 的edit eligibility；
[`ThumbnailStore`](../../../Sources/PresentationUI/ThumbnailStore.swift#L99) 的row thumbnail；以及
[`HistoryRowView`](../../../Sources/PresentationUI/HistoryRowView.swift#L191) 的icon heuristic。
这些集合并非同一种能力，却靠注释要求人工同步。

漂移已经可直接构造：`public.heif`与`com.microsoft.bmp`能进入thumbnail/details/preview图片路径，
但row icon集合缺少二者，因而显示generic clipboard icon；`public.utf16-plain-text`能被projector与
preview按UTF-16解码，Details的inline preview和editor的Replace eligibility却先强制UTF-8。后者可能
包含有意的“暂不支持UTF-16写回”，但这个限制没有成为一条集中、可审阅的capability事实。

不要再加第十一份`Set<String>`，也不要用一个`isSupported`抹平差异。`ClipboardFormats`只集中stable
exact facts；Search、Thumbnail、Preview、Edit、Pasteboard各自拥有purpose manifest，build/test inventory
只读join并暴露漂移，不成为production policy owner。新增exact format时，owner route test与source gate应
让遗漏在CI暴露；unknown UTI仍走TYPE-3的opaque fallback。Decoder实现留在独立Preview owner。完整结构与TDD见
[`08-content-types-and-preview.md`](08-content-types-and-preview.md)。

### TYPE-2 — Abstract/structured text 被统一当UTF-8，但产品究竟支持“源码”还是“语义”尚未裁决（Confirmed mechanism / unresolved contract / High）

[`ContentProjector`](../../../Sources/HistoryStorage/ContentProjector.swift#L253)、
[`HistoryPreviewView`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L39)、Details和Editor
把`public.text`、`public.plain-text`、RTF与HTML放进同一text集合；除exact UTF-16外一律
`String(data: .utf8)`。这证明当前title/search/preview对可UTF-8解码的RTF/HTML使用markup源码，
不证明已经实现富文本语义；UTI conformance也不证明`public.text`/`public.plain-text`的实际bytes
采用UTF-8。Apple为RTF提供专用decoder，而HTML importer还明确带有WebKit与外部资源/超时边界：
[`NSAttributedString.init(data:options:documentAttributes:)`](https://developer.apple.com/documentation/foundation/nsattributedstring/init(data:options:documentattributes:))。

这里不能把所有Replace都写成“必然corruption”。RTF/HTML可以成为合法的raw-source editor，用户若
保持有效markup，原UTI+源码bytes仍可能是正确表示；问题是当前UI只写“Replace substitutes edited
text”，没有说明source mode、没有format validation/encoding contract，title/search究竟索引源码还是
可见文本也未由owning spec裁决。因此输入普通可见文字后仍标成RTF/HTML是**可构造的互操作失败路径**，
不是每次编辑都会发生的既成损坏。

先为每个exact type明确能力上限：UTF-8/UTF-16 plain text必须有对称decoder+encoder；RTF/HTML若选
source mode，label必须写“Edit RTF/HTML Source”并在保存前用对应parser验证；若选semantic mode，必须有
bounded parser、sanitizer和serializer；否则只允许Keep/Hide。title/search应优先使用明确的plain-text
sibling，或使用单独批准且资源有界的semantic extractor，不能在History commit interval中临时调用
HTML importer。Apple类型与编码边界详见
[`apple-pasteboard-type-system-memo.md`](apple-pasteboard-type-system-memo.md)和
[`08-content-types-and-preview.md`](08-content-types-and-preview.md)。

### TYPE-3 — Generic unknown-UTI raw round-trip 是现有优势，不能被“支持列表”回归（Confirmed strength / regression risk）

对第一个item，Adapter枚举全部declared types并保存每条非空`Data`；
[`IngestPreparation`](../../../Sources/HistoryStorage/IngestPreparation.swift#L186)只检查identifier/数量/bytes
边界与marker，不要求type在白名单；paste又按原identifier写回。因此Clipy当前已经具备“unknown/custom
UTI可opaque capture + byte-preserving paste”的重要底座，优于把unknown-only内容直接丢弃的策略。
这仍不证明任意第三方consumer都语义兼容，也不覆盖CLIP-7的第二个item，但不是待修缺陷。

未来format manifest只能决定已知type的interpretation能力，不能成为transport admission白名单。
[`UTType.init(_:)`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/init(_:))
对当前系统未知identifier返回`nil`，这不等于representation无效；`dyn.*`和第三方UTI默认必须保留为
`opaque capture / verbatim paste / no semantic preview`。只有privacy marker、明确的产品exclude或硬资源
上限可以阻止capture，且原因必须typed、可观察。

### FINDING-PREVIEW-1 — 扩展renderer会同时扩大外部I/O、资源与actor边界（Confirmed platform surface / High）

“识别更多UTI”不等于“安全预览更多内容”。Apple的Preview路径有不同副作用：Quick Look request只接受
file URL，并可能为iCloud内容下载thumbnail乃至原文件
([request](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator/request/init(fileat:size:scale:representationtypes:)))；
HTML importer/WebKit可能读取嵌入资源；`AVURLAsset`可表示本地或远程媒体，容器还可引用外部资源，需
[`AVAssetReferenceRestrictions.forbidAll`](https://developer.apple.com/documentation/avfoundation/avassetreferencerestrictions/forbidall)
显式收紧。file URL成功解析也不证明文件本地、已下载或sandbox可读。任何这些操作若藏进UI的type
switch，都会让一个新格式同时引入隐式网络/文件I/O、取消、临时文件和权限生命周期。

每条preview rule必须声明source policy（history bytes / app-owned temp / user-approved external URL）、
默认external I/O、input/output/page/frame/character预算、deadline/cancellation和typed fallback。默认禁止
网络、云端下载、网络卷与外部引用；需要外部文件时，先经词法作用域的access lease取得app-owned
snapshot，再把bounded值交给decoder。ImageIO的final pixel bound也不能外推成峰值RSS/CPU有界；是否把
某个高风险decoder放入最小权限helper，应由adversarial child-process测量触发，不能预先把所有格式XPC化。

扩类前还必须关闭GOV-2：当前PresentationUI直接import ImageIO，decoder actor把`CGImage`交给MainActor，
与仓库“CGImage不跨边界”规则冲突。推荐一个窄Preview facade隐藏pure planner、owned task/version fence
与内部family renderers，只输出有界immutable Sendable artifact；这不等于每种格式各建一个target或public
protocol。Apple边界、UNKNOWN与逐格式TDD矩阵见
[`apple-preview-source-memo.md`](apple-preview-source-memo.md)及
[`08-content-types-and-preview.md`](08-content-types-and-preview.md)。

## 6. Presentation 与交互语义

### UI-1 — Revise “Keep” 实际是 Use Original（Confirmed / Critical）

[`ReviseEditorView`](../../../Sources/PresentationUI/ReviseEditorView.swift#L69) 对 Effective
中已有 type 默认 `.keep`，保存时却映射 `.inheritCanonical`。已有 replacement revision
时，无编辑保存或只修改另一个 type 会把当前 bytes 恢复为 Canonical。

draft 必须从 exact Effective bytes 构建；Keep Current、Use Original、Hide、Replace
应是不同语义。无编辑保存返回 `.unchanged`；空 replacement 在 UI 侧 inline 阻止。
HTML/RTF需另行明确editor语义：它可以是有清楚label/validation的raw-markup editor，也可
禁用或使用真正的rich serializer；不能仅因写入UTF-8就断言必然损坏。这项不影响Keep
Current bug的确定性。

### UI-2 — Details mutation 与 reload 未建立 happens-before（Confirmed / High）

Pin/Remove fire-and-forget，随后另一个 Task reload；read 可先于 commit 并长期显示旧状态。
把 view-state mutation 改成 awaitable receipt；同一 user intent 中严格 `await write → read`
或由 authoritative observation 收敛，并显示 pending/failed。不要用任意 sleep 修 race。

### UI-3 — pinned-only 第一页永远不分页（Confirmed / High）

[`HistoryListView`](../../../Sources/PresentationUI/HistoryListView.swift#L60) 只在 unpinned
row 上挂 `onAppear`；首 50 条全 pinned 且 cursor 非空时，没有任何 trigger。分页应绑定
最后一个整体可见 row/scroll sentinel，与 lane 无关；另提供 keyboard/VoiceOver 可达的
“Load More”。

### UI-4 — query generation 与 rendered rows 不一致（Confirmed / High）

query/mode 改变时保留旧 rows，却立即用新 query、new result count 标注；invalid regexp
后旧结果仍可 Return copy。初次 observe 也没有 loading phase，先显示空历史。

建立 `idle/loading(displayedQuery,generation)/loaded/invalid/failed` phase；结果只有匹配
generation 才 publish。若保留旧 rows，必须明确标 stale 并禁用 destructive/copy action；
更简单是 query切换立即进入 loading skeleton。selection 随 authoritative rows 对齐。

### UI-5 — Preview 只观察 ID，版本变化可永久旧内容/spinner（Confirmed / High）

panel 的 selection 只有 `HistoryItemID`；同 ID revision 更新 `ContentVersion` 不触发
retarget。loader 收到 mismatched details 时直接 return 又不清 `isLoading`。

观察 derived `HistoryItemReference?`（ID + version），row 删除时立即清 selection/preview；
current generation mismatch 必须结束 loading 并重试 current reference或显示 recoverable
state。现有 mismatch test 必须加 `!isLoading` 断言。

### UI-6 — “Preview 向左打开”只移动窗口，内容仍在右（Confirmed / High）

[`FloatingPanel`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L150) 在右侧不足时把
整个 window 左移；[`HistoryPanelView`](../../../Sources/PresentationUI/HistoryPanelView.swift#L63)
仍固定 main→preview。结果是主列表左跳，preview 占据原列表位置。

一个 shared `PreviewPlacement` 必须同时驱动 AppKit frame 与 SwiftUI column order，并
以稳定 main-content rect 保存 position。窄屏下应先prototype overlay、replace或收窄策略，
再选择一种；当前确定要求只是不制造不可达721pt window。

### UI-7 — 键盘首路径没有明确 selection/focus/IME contract（Proof gap + product gap）

selection 初始 nil；search `FocusState` 从未显式设 true；多个透明/隐藏 Button 竞争
key equivalents；没有 marked-text guard。需定义并测试：summon 选 newest、输入进入搜索、
上下导航、Return copy、Esc close；CJK IME有 marked text 时 Esc/Return 先交输入法；
close/reopen 哪些状态保留必须明确。

### UI-8 — 固定快捷键与系统标准冲突，注册失败被忽略（Confirmed / High）

全局 `⇧⌘C` 是 Apple HIG 的 Show Colors；preview `⌃Space` 常用于输入源切换。Maccy
默认也有同类冲突，不能作为合理性证明。提供可配置 shortcut、冲突状态、失败保留旧绑定
和恢复 UX；signed runtime 需覆盖布局、Secure Input、锁屏/唤醒与另一进程占用。

### UI-9 — Settings 精度、状态和文案会误导（Confirmed / High）

- 1 秒/1 byte 等精确 policy 被 ceiling 成整天/MiB；只编辑别的维度也会重写原值；
- count 在 General，其余维度在 Retention，不是一个 unified group；
- 二进制 MiB 标作 MB，用户可见 `OPEN-2`；
- async readback 可覆盖正在编辑的 draft；failure 无 Retry；
- launch-at-login 将 `.requiresApproval/.notFound/error` 压成 off。

保留 raw configured DTO + per-field dirty bits；只 normalize 用户实际编辑的字段；使用
locale-aware formatter/unit；read generation 不覆盖 dirty draft。SMAppService 用显式
状态机并提供 `openSystemSettingsLoginItems()`。

### UI-10 — panel/Space/lifecycle 的注释超过平台事实（Proof gap / High）

`.moveToActiveSpace` 不等于 all spaces；`.stationary` 会在 Mission Control 保持敏感
panel；macOS 26 的 `.canJoinAllApplications` 更贴近跨应用 overlay，但仍需 full-screen/
Stage Manager 真机矩阵。AppDelegate 还缺 reopen、session resign/become-active、sleep/
wake、screen change；fast user switch 下可能在 inactive session 开始 polling。

不要仅凭 flag 名称改组合。先写 runtime matrix和隐私语义，再选择最小 behavior。详见
[`apple-platform-source-memo.md`](apple-platform-source-memo.md)。

### UI-11 — Clear/Remove 后敏感 view/cache state 可继续存活（Confirmed / High）

panel和HistoryPanelView长期复用；Clear是fire-and-forget，不清details path、selection或
thumbnail store。`reset()`又允许旧in-flight completion重新落回；detail phase直接持有完整
HistoryDetails。因此用户确认Clear后，旧文本/图像仍可能显示和驻留。

Mutation先await receipt；成功Clear后推进purge generation，清details/selection/preview/
editor/cache并隔离迟到结果；Remove/Revise按exact reference精准evict。测试park fetch→Clear
→late completion，cache与actual view仍为空；close是否也purge由明确privacy policy决定。

### UI-12 — Pagination task 不属于 browsing lifecycle（Confirmed / High）

`loadNextPage()`创建未保存Task；`deactivate()`只取消observation/debounce且不推进generation，
`restartObservation()`也不cancel pagination或复位`isLoadingPage`。因此慢browse可在panel关闭后
追加rows；若先重开/换query，generation虽挡住旧page publish，但`isLoadingPage`会一直阻止新
query分页，旧browse永不返回时可永久卡住。旧Task的无条件`defer`还可能误清后来请求的spinner。

把pagination work纳入HistoryViewState lifecycle：保存task并使用单调request token；restart/
deactivate cancel+invalidate并立即清loading，completion只允许当前token改rows/cursor/loading。
Deterministic TDD用non-cooperative pausable browse：关闭后释放旧page不得应用；换query后旧page
不得阻止/清除新page的pagination状态。现有tests只覆盖立即返回的顺序happy path。

### UI-13 — Search UI 会破坏原始查询（Confirmed spec bug / High）

`HistoryViewState.currentKind`对所有mode做`trimmingCharacters(.whitespaces)`；exact/regexp的前后
空格因此丢失，whitespace-only被改成recent。但03b §8只说真正empty等价recent，SearchWorker
又明确non-empty term不再trim。`SearchHeaderView`还会把长query切fuzzy时永久prefix到64；
`searchMode.didSet`先restart，View的`onChange`才clamp，因此先发一代非法>64 fuzzy request，
再发截断query。

保留raw user draft，构造独立admitted query；exact/regexp byte-for-byte传递，whitespace-only
是否recent需先改规。Mode+query validation作为一个原子intent，超限显示validation或拒绝切换，
不改用户文本。Actual-view Red覆盖`" foo "`、`"^ foo $"`和65+ exact→fuzzy，断言最多一代
admitted request且raw text不变。搜索框另应禁用autocorrection，并提供有明确VO label的visible
Clear；这是小affordance，不引入suggestions/token UI。

### UI-14 — Editor、failure 与 preview 的恢复状态会丢信息（Confirmed / High）

- Revise收到`.staleContent`后唯一OK直接dismiss，用户replacement draft全丢；
- failure banner以`HistoryFailure`值记录dismissed，健康page不清该值，同一个failure episode以后
  永久不再显示；任意观察page又会清mutation failure；
- Preview把所有details error折成`.unavailable`并显示“No Preview”，与确实没有可预览内容
  不可区分，也没有Retry；
- `.snapshotExpired`文案说“showing the latest page”，实现只回退到旧observed first page并等待
  未来observation，当前时刻并不保证latest。

Stale editor保留draft并reload/rebase current version；failure用episode/source identity，健康后
同值新episode可重现并被VO announce；preview区分unsupported与failed(retryable)；snapshot
expired进入“Refreshing”且旧page不可执行，authoritative page到达后才标loaded。所有Red应走
actual view或pausable History，而非只断言private enum。

### UI-15 — Panel lifecycle 与 last-position 由两边拥有（Confirmed + runtime proof gap / High）

`HistoryPanelView.task/onDisappear`和`AppDelegate.openPanel/panelDidClose`都activate/deactivate同一
HistoryViewState；activate不是no-op而会restart observation。composition可能在panel已关闭后
才把真实view插入复用hosting tree，隐藏view的`.task`行为又取决于SwiftUI runtime。生产lifecycle
没有唯一owner。

此外`PreviewPaneState.panelClosed()`反而把auto-open设true；未来迟到selection可在hidden panel
打开preview。保存last position又按721pt preview window中心，而reopen是400pt main column，
main frame横移约160.5pt；preview关闭宽度还依赖hidden SwiftUI `onChange`回调。

深化现有FloatingPanel AppKit adapter，让一次open/close恰好对应一个browse session；closed保持
preview disabled直到windowDidBecomeKey。位置以main-content rect为identity，不以full preview
window中心。Hosted NSPanel Red证明每次open一个observer、right/left preview drag后main rect不动、
快速close/reopen不先显示721pt空窗；Space/WindowServer仍需runtime。

### UI-16 — Explicit VoiceOver operability contract 缺失（Proof gap / release blocker）

History row只声明double-click gesture并`.accessibilityElement(.combine)`，所有keyboard carrier又
`accessibilityHidden(true)`；源码没有default/named accessibility actions。SwiftUI runtime是否
自动合成default action尚未实测，所以不能断言VO一定无法复制，但显式operability contract缺失。
Preview的真实clipboard image还使用`Image(decorative:)`，VO完全没有图像预览语义；动态failure/
result/receipt也没有settled-generation announcement策略。

先检查hosted NSAccessibility tree；若default action不存在，设Copy为default，并给Pin/Unpin、
Details、Remove命名actions。图像至少label尺寸/“Image preview”，不做AI描述。只在稳定generation/
intent完成时发content-free announcement，避免每keystroke播报。最终用Apple
[VoiceOver criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria)
与真实VO/FKA journey关闭gate。

### UI-17 — Settings/详情文案把破坏性与内部术语暴露给用户（Product safety / Medium）

收紧retention会立即retire/prune，却位于普通Apply旁、提交前不说明永久删除；成功“Done”在用户
继续编辑后也不清，未保存draft看似已保存。Settings在composition opening/failed时是EmptyView。
Details直接显示Effective/Canonical/Content Version，source在row/details/preview三处格式不一，
且没有说明只是observed frontmost app。更重要的是，“Edit Content… / Save Revision”会append新的
immutable revision；它改变现在paste的Effective Content，却不会擦除Original Capture，旧revision也
可能继续保留到retention prune。当前文案容易被理解成覆盖或redact敏感原文。

不新增usage preflight：用old/new policy纯比较，只对strict tightening确认一次并诚实说明可能永久
删除；dirty后清success、unchanged Apply禁用。Settings opening/failure显示Retry。用户文案用
“Pastes Now/Original Capture”，ContentVersion移到diagnostics；source经一个presentation policy
格式化并标“Observed app”。editor附近明确写“creates a new revision; original/older content may
remain in history”；需要删除敏感内容时引导Remove item/Clear，并仍只承诺logical removal，不能把
revision edit宣传成redaction。动态String走String Catalog plural/FormatStyle；SwiftUI literal
本身可LocalizeStringKey，问题不是每个literal都“raw”。

## 7. Search、thumbnail 与资源边界

### PERF-1 — invalid/empty search 在 admission 前先构造完整 corpus（Confirmed / High）

facade 先让 Authority fetch、copy、project、sort 全 corpus，worker 才检查 exact 4096B、
fuzzy 64 chars、regexp 512/grammar/compile。5,000×256KiB 的理论 body 上限约 1.22 GiB；
这不是日常实测，但调用顺序已证明 admission 太晚。空 search 按规格等价 recent，也不应
触发 corpus。

提取无 I/O `SearchAdmission.validate`，在创建 context 前执行；empty fast-path recent；
worker 内保留 defensive recheck。测试用 probe/poison row 证明 invalid/empty 不触发
corpus fetch。

### PERF-2 — cancellation 只防 stale publish，不停止旧工作（Confirmed / High）

worker 只在 scan 前检查一次取消；exact/fuzzy/regexp 同步 loops 没有 checkpoints。
Swift Task cancellation 是 cooperative，旧 query 可占住唯一 SearchWorker，新 query
又可能提前持有完整 snapshots。

Authority projection 与 scan 每 bounded chunk 检查 generation/cancellation；queued
generation 不预先持有 full corpus。Regexp 可判别 Apple
[`enumerateMatches`的`.reportProgress`](https://developer.apple.com/documentation/foundation/nsregularexpression/enumeratematches(in:options:range:using:))
与stop/deadline；先定typed timeout semantics，禁止detached timeout遗留后台ICU work。

### PERF-3 — regexp guard 不能被宣传成完整 ReDoS 防线（Conditional / High）

当前 parser 只覆盖有限 nested quantifier shapes；顶层连续 ambiguous quantifier chain
可绕过。静态反例证明 guard 漏形状，但不能单凭源码断言 macOS 26 必然 hang。

先扩 pure conservative admission fixtures，再在可取消实现或 child-process watchdog 下
跑危险 pattern；报告 bounded completion，不声称任意 regexp 安全。

### PERF-4 — distinct thumbnail flights 无 count/byte/cancel backpressure（Confirmed / High）

same-key single-flight 不限制 distinct keys。每个flight最终选择/排队的representation最多64 MiB；但
当前Authority为找到它会先串行full-hydrate该item，合法payload最高约128 MiB Canonical + 256 MiB
revisions。50个queued selected sources本身就是3.125 GiB量级，这还不是包含当前串行whole-lineage
hydrate、copies与decoder scratch的peak上界。row `.task` 又转为丢弃 handle的 unstructured prefetch。

permit 必须在 source hydration 前取得；queued request 只持 key/reference；scroll-off
可取消；记录 content-free in-flight count/bytes。先用 1–2 worker 的小有界池，不要直接
上通用 scheduler。

### PERF-5 — “off-main decode”尚未证明像素真的已 materialize（Confirmed contract gap）

`CGImageSourceCreateImageAtIndex(..., nil)` 未设置
[`kCGImageSourceShouldCacheImmediately`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately)；
Apple 说明默认 false，实际 decode/cache 可推迟到 render。当前 actor只证明 image source/
CGImage creation 不在 caller，不证明首次 draw 不会在 MainActor decode。

对支持的 API显式 eager caching，必要时在 decoder actor 画入 bitmap context；测试 actor
返回后的第一次真实 draw/main-thread heartbeat，而不是只计 API call。

### PERF-6 — Preview/Details 热路径过度 hydrate，文本又在 MainActor 全量 decode（Confirmed structure / High）

200ms dwell 调 `history.details(id)`，Authority 完整 decode canonical + 全 revisions、project
titles，取消只能在 await 返回后丢结果。Preview/Details/Editor 对最大 Data 做完整
`String(data:)` 后才截到 50k/500 chars，Details 甚至重复 decode。

立即修reference/purge，并把bounded文本解析移到concrete non-main worker；同时比较visible/
manual preview与当前auto full-details路径。只有G8/absolute SLO证明full hydrate仍超预算，才
新增reference-tagged、byte-bounded purpose-specific preview projection。不要未经trigger扩大
唯一History boundary，也不要用另一个process-lifetime cache掩盖读取过宽。

### PERF-7 — ThumbnailStore 是未正式准入的 process-lifetime completed cache（Confirmed / High）

panel只 hide 并复用；store跨页、跨 close/reopen保留最多500项/64MiB。越界时
`removeAll()`，会连刚完成和所有可见图一起清掉；in-flight结果之后又可能落回，删除/
version advance也不精确 prune。

若 G1 reuse trigger 未满足，回到 visible-row ownership，离屏/close释放。若测量支持
正式 cache，再用 exact reference/version + byte-cost LRU、memory-pressure 和 precise
invalidation；不要复制 Maccy 的 64-bit fingerprint-only disk identity。

### PERF-8 — rectangular `PixelSize` 不成立；source fallback 需改规（Confirmed + decision / Medium）

worker取 `max(width,height)` 传单一 ImageIO bound，不能保证另一个轴≤请求值。要么 public
contract改为标量 maximum pixel size，要么读取 orientation-aware dimensions做 aspect-fit
并验证两个轴。

thumbnail source 取 canonical UTI 字典序第一项，不是 fidelity/cost policy；第一个不可
decode时也不 fallback。当前`05 §14.5`支持fail-closed分类，因此“尝试后续candidate”必须
先作为产品/规格变更批准；若批准，再建立internal selector，明确alpha/HDR/lossless/cost。
Clipy 已正确使用 HEIF primary index，这是应保留的优势。

### PERF-9 — 复杂度与性能 claim 需要降格或重测（Proof gap / Medium）

search corpus/fuzzy与 retention R1/R2 都显式 sort，却在 metadata/文档中宣称 linear；
100→300/400 的宽 ratio 无法区分 N 与 NlogN。11-sample exact admission 又因旧的125秒/
request预算冻结，但优化后已有约1.59秒记录，仍人为放弃 p95/p99。

若 O(NlogN) 已满足 absolute budget，诚实改 claim；不要为漂亮 Big-O 上复杂结构。
性能 runner继续证明 engine complexity，同时增加少量真实窗口 latency/RSS SLO。

### PERF-10 — 外部伪装图片被归类为 durable corruption（Spec-compliant product risk / Medium）

任意本地应用都可把垃圾bytes声明为`public.png`。Thumbnail decode失败目前可抛
`.persistence(.corruptStoredValue)`，把“不受信任外部格式不可预览”误报成store损坏，并因
失败不cache而在滚动时重复decode。这符合当前`05 §14.5`，所以不能直接写相反Red；但它把
外部格式声明与内部durable corruption混为一类，值得规格裁决。

若批准重新分类，再用假PNG fixture证明paste成功、preview不可用且不会重复昂贵decode；
若保留现规，则用相反fixture锁定fail-closed并改善用户说明。压缩bomb/超大metadata的真实
CPU/RSS需helper-process测量后再决定源级限制，不先引入隔离service。

## 8. 多级存储、驻留与“无限历史”

这一节直接回答新增的 storage 问题。必须先把三种名字相近、后果完全不同的操作分开：

- **history retention** 删除用户历史或inactive revisions；
- **cache eviction** 只丢可重建的内存/派生值，不改变History；
- **blob GC** 只回收已经由durable reachability证明不可达的物理内容。

当前实现有第一种和一个局部thumbnail cache，**没有**统一的多级驻留/淘汰系统。完整目标、
分阶段准入与规模TDD见
[`09-tiered-storage-and-unbounded-history.md`](09-tiered-storage-and-unbounded-history.md)；Apple对
SwiftData fault/batch、`.externalStorage`、`NSCache`、磁盘容量和备份能支持到哪里的证据见
[`apple-tiered-storage-source-memo.md`](apple-tiered-storage-source-memo.md)。

### STORAGE-1 — `HistoryStorage` 当前是有限持久化内核，不是 RAM→disk→cold tier manager（Confirmed structure / High strategic gap）

[`HistoryItemRow`](../../../Sources/HistoryStorage/Schema.swift#L43)把一项内容存成两个整体
`Data`：`canonicalBlob`与包含完整revision list的`revisionStateBlob`；二者都只标了
[`@Attribute(.externalStorage)`](../../../Sources/HistoryStorage/Schema.swift#L65)。源码自己正确称其为
implementation hint，正确性不依赖inline或external placement。Apple公开contract也只说该option让
binary data存到model storage旁；没有给Clipy稳定blob URL、range read、stream、fault/eviction时机、
物理回收或驻留预算
([Apple `externalStorage`](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage))。

因此当前“磁盘里有大Data”不等于已有cold tier，更不能把SwiftData未公开的fault行为当淘汰算法。
仓库也没有按UTI注册storage handler、content lease、range/sequential reader、resident-byte governor或
memory-pressure trim。后续seam应保持Storage **类型无关**：Authority先验证exact reference/opaque
locator，package-internal、evidence-triggered `ContentDepot`再通过带purpose、shape、最大bytes和优先级的
internal lease加载；HistoryStorage owner-local `TransientPermitPool`只核发source-read permit，Preview/
Thumbnail各自拥有decoder/output permits，clipboard-flow owner（当前`AppComposition`，只有deletion test
批准后才提取`ClipboardFlow`）拥有acquisition/pending。`ClipboardFormats`只提供stable facts；PNG/PDF/RTF
的访问策略由具体behavior owner/renderer结合manifest与实测profile产生，不在Storage里做“每文件类型一个handler”。

### STORAGE-2 — 5,000硬上限与全量结构使当前实现不能称“无限历史”（Confirmed structure / RSS unmeasured / High）

[`HistoryLimits.standard`](../../../Sources/HistoryCore/Limits.swift#L205)明确把
`hardMaximumRetainedItems`冻结为5,000，并允许每项`searchBody`最多256 KiB。Authority又在整个生命周期
拥有一个完整[`SignatureIndex`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L177)：其
`postings`、reverse map和retained-ID set覆盖所有保留项
([`SignatureIndex.swift`](../../../Sources/HistoryStorage/SignatureIndex.swift#L106))，没有cold posting query或
LRU。每次search还fetch **所有** retained rows并构造完整`SearchCorpusSnapshot`
([`HistoryAuthority+SearchCorpus.swift`](../../../Sources/HistoryStorage/HistoryAuthority+SearchCorpus.swift#L116))。

5,000 × 256 KiB = 1,310,720,000 bytes，约1.22 GiB；这只是合法search-body payload的**结构上界**，
尚未计String、row、sort/matcher scratch，也不是测得的RSS。正常store可能远小于此，SwiftData/Data的
copy/fault行为也只能实测。但“先把5,000改成很大/去掉”会立刻把resident index、每次search全语料、
capture/retention的全量metadata inventory和migration工作从有限O(N)变成无产品上限的O(N)。产品最多
可以在完成disk-backed postings/search、keyset UI、5,001功能边界与50k/250k/1m staged soak后说
“无用户可见条数上限，受设备
容量和安全reserve约束”，不能承诺字面无限。

### STORAGE-3 — Details、paste、thumbnail与Preview都先hydrate整条lineage（Confirmed structure / peak-memory unmeasured / High）

共享[`HistoryItemRowHydration.hydrate`](../../../Sources/HistoryStorage/FactLoaders.swift#L86)总会decode
Canonical、完整revision blob、signature metadata和occurrence；
[`details`](../../../Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift#L9)复制Canonical、
Effective Content并遍历所有revisions，
[`pastePayload`](../../../Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift#L89)也先走同一完整
hydrate。thumbnail creator的契约同样写明“fetch and fully hydrate exactly one item”
([`ThumbnailService.swift`](../../../Sources/HistoryStorage/ThumbnailService.swift#L4))，而200 ms Preview再通过
[`history.details`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L180)拿全details，之后才选一份
text/image。

这确认的是**当前API/materialization粒度**：调用一份representation也要先形成whole-lineage values；
它不证明每次会产生几份物理copy或达到多少peak RSS。先用Release child对64/128/384 MiB边界、长revision
lineage与selection churn测peak/settled RSS；若越过G8/SLO，再做purpose-specific representation read。
Paste的完整Effective Content语义可以继续whole-item，但Preview/thumbnail/Python metadata不得借
`details`取得不需要的Canonical或旧revisions。

### STORAGE-4 — 现有内存上限是孤岛；distinct in-flight与capture backlog仍无总byte admission（Confirmed / High）

UI的[`ThumbnailStore`](../../../Sources/PresentationUI/ThumbnailStore.swift#L61)只对**已完成**结果设置
500 entries / 64 MiB decoded-byte上限，超限是whole-store reset而非LRU；`inFlight`只是一组exact keys，
不计source bytes、encoded output或decoder scratch
([`ThumbnailStore.swift`](../../../Sources/PresentationUI/ThumbnailStore.swift#L139))。Storage侧
[`ThumbnailService.flights`](../../../Sources/HistoryStorage/ThumbnailService.swift#L81)只合并same-key，
不同key的flight count/source bytes也没有上限。与此同时，composition对每个complete pasteboard
observation直接新建一个Task
([`AppComposition.swift`](../../../ClipyApp/Sources/AppComposition.swift#L192))；每个合法capture可达128 MiB，
active/pending count和总冻结bytes没有admission。

所以“thumbnail cache有64 MiB”不等于“进程内容内存≤64 MiB”，单项上限也不等于aggregate上限；
框架/allocator/OS page cache更不在Clipy精确控制内。建议只承诺并验证Clipy-owned
`resident + reserved/in-flight`预算：same-key single-flight、取得source前reserve、active lease不可淘汰、
oversize bypass/stream、foreground paste优先于dwell/prefetch、cancel释放reservation、memory pressure只
trim evictable values。不要用`NSCache.totalCostLimit`声称硬界；Apple明确把其limits和淘汰顺序定义为
非严格/非保证，细节与测试矩阵见tiered-storage memo §7/§13。

### STORAGE-5 — R2的logical bytes既不是物理磁盘配额，也不是RSS；大维护操作仍缺aggregate证据（Confirmed semantics / unmeasured resource risk / High）

[`StorageRetention.maxTotalBytes`](../../../Sources/HistoryCore/RetentionPolicies.swift#L61)只统计Canonical
representation + revision content的**逻辑bytes**。它不含SwiftData metadata、codec/framing、SQLite/WAL、
external blobs的物理allocation、派生cache、临时文件、GC debt或备份；物理dedup将来也不能反向改变用户
可理解的logical-retention语义。R1/R2删除history，R3删除inactive revisions；二者都不是为了释放RAM的
cache eviction。Pinned content也不能因cache/disk pressure静默淘汰；hard reserve不足时应typed拒绝新
capture/revise并给恢复路径。

aggregate风险也不是推测性的“每个blob都一定进RSS”：已确认的是
[`RetentionPolicySweep`](../../../Sources/HistoryStorage/RetentionPolicySweep.swift#L180)会把所有待剪lineage
的`PruneLineage`保留到一个transaction，migration backfill用5,001作guard、合法store会在一个context中
遍历最多5,000 rows
([`RetainedBytesBackfill.swift`](../../../Sources/HistoryStorage/RetainedBytesBackfill.swift#L126))；真正peak
RSS/时长尚未测，详见DATA-12。应先用terminated child测R3/migration的N×8 MiB、N×64 MiB峰值，再按证据
选择bounded restart-safe batches。若未来转成app-owned immutable representation blobs，还必须把
`logicalContentBytes`、`physicalBlobBytes`、metadata/WAL、derived cache、temp/in-flight、reclaimable/GC
debt与volume safety reserve分账；free-space preflight只能提示，不能保证后续write/fsync/rename/save。

### STORAGE-6 — UI rows与outer observation是独立驻留面；取消5,000 cap前也必须改成有界（Confirmed structure / High at large scale）

分页目前把每页DTO持续append到`HistoryViewState.rows`
([`HistoryViewState.swift`](../../../Sources/PresentationUI/HistoryViewState.swift#L164))，直到新的first-page
snapshot替换；在当前5,000硬上限内它仍有限，但去掉cap后不是virtualized window。更直接的现行问题是
[`SwiftDataHistory.observe`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L311)的内层invalidation
虽为newest(1)，外层`AsyncThrowingStream<HistoryPage>`没有buffer policy，慢consumer可积累完整pages
（DATA-6）。

因此“Storage按需加载”不能只改数据库：UI只能保留可见窗口+小lookahead，cursor必须keyset/query-bound；
outer snapshot stream应`.bufferingNewest(1)`并在burst/paused consumer下测queued page数。这里的row DTO
不含完整content blobs，不能把它和STORAGE-3的blob hydration混为同一RSS来源；两者需要分别计量。

## 9. 发布与证据

### REL-1 — 当前不是可分发产品（Product blocker）

无冻结的 bundle ID/version/build/icon/category/entitlements contract；CI只构建 unsigned
Debug；没有 Release archive、Developer ID signing、hardened runtime验证、notarization、
staple、Gatekeeper/download复验。String Catalog、VoiceOver、Full Keyboard Access 与
storage recovery也未闭合。

先选 Developer ID 直发一条渠道；同一 protected tag/SHA/version/build，复用完整 CI，
archive→codesign→notary→staple→`spctl`→下载后复验。v1 无网络，updater是以后独立决策。

### REL-2 — 当前所谓 UI smoke 不驱动 UI（Confirmed proof gap）

AppDelegate在 hosted tests 直接跳过生产启动；project没有 UI-testing target；
`UISmokeJourneyTests` 直接调用 view state。它们能证明组合状态，不能证明 status item、
真实 panel、first responder、Carbon delivery、Space、VoiceOver或clipboard round trip。

先补一条真正`XCUIApplication`的
`summon → search → Return → clipboard → close` tracer；可用DEBUG/internal summon bridge，
但必须走与Carbon callback相同的产品尾路径。其余journey只由已发现的跨控件风险驱动。
真实Carbon/TCC/多屏仍是signed platform matrix，不能由fake registrar代替。

### REL-3 — Release/runtime performance superiority 尚无证据（Proof gap）

双方没有同机、同OS、同签名模式、同语料、同语义的A/B。Clipy core runner强在事务/
复杂度；Maccy有真实UI traversal，但大量 sleep/record-only数字同样不能外推。

任何“更快/更省内存”必须绑定 workload、build、hardware、样本和指标；不要总分。最小
matched journeys与完整A/B方案见
[`05-evidence-and-open-questions.md`](05-evidence-and-open-questions.md)。

### REL-4 — Sandbox、crash recovery 与物理删除边界未闭合（Product blocker / High）

当前app没有明确App Sandbox entitlement；store位于Application Support并使用externalStorage。
API tests证明logical delete/rollback，不证明SQLite free pages、WAL、external sidecars、APFS
snapshot或backup中无残留。启动失败页面又只有Quit，没有Retry/Reveal/Quarantine。

发布决策应验证最小Sandbox配置与既有store迁移；恢复以DATA-14的dedicated StoreRoot为边界，
提供Retry/Reveal和证据支持后才出现用户确认的whole-StoreRoot quarantine（其中仍含敏感内容），
不静默空库或内存fallback。产品文案只说removed，不说secure erase，除非另有对应层证据。
普通transaction还应补child kill/external blob reopen矩阵；现有migration kill只覆盖backfill
transaction前的compute阶段，且parent旧coordinator仍活（DATA-13）。

## 10. Automation 与 Python 外部修改

### AUTO-1 — 当前没有 IPC；“任意 Python 可修改”需要新增 Local Automation 规格（Confirmed absence + new product requirement / High）

当前 tracked source 没有 CLI、socket listener、Apple Events dictionary、external XPC listener或已实现的
`ExternalGateway`；现有
[`V2-05`](../../v2/V2-05-external-gateway.md)也明确仍是
**design-consolidated, scaffold proof pending**，且拥有的是 App Intents / Siri / Shortcuts / Spotlight
surface。这只支持“当前 Python 不能通过受支持接口访问 Clipy history”的结论；它符合现行范围，
不是漏写了一个 adapter 的既有缺陷。用户新增的“任意 Python 进程可查询并修改”应先成为
`localAutomation` 的 owning spec / enrollment kind，再进入实现。

稳定 public contract建议是随 Clipy 发布、版本化的第一方 `clipyctl`（JSON stdin/stdout、稳定
exit-code classes）；Python只依赖它，不依赖socket path、Mach service、Swift raw value或SwiftData
schema。Unix-domain socket、XPC、Apple Events或App Intents只作为可替换的private transport。
无论选哪一种，private adapter先做framing、length-before-allocation、connection/backpressure与kernel peer
evidence preflight，再把bounded typed request + opaque credential交给唯一`ExternalGateway`做semantic bounds、
credential→connection resolution、grant、rate limit、authoritative recheck与audit，最后由唯一
`HistoryAuthority`读写；CLI/helper不得打开store或成为第二writer/trust boundary。

现有V2-05的`.browse` / `.readContent` / `.manage`对任意本机进程仍过粗：至少应独立裁决
`browsePreview`、`readEffectiveContent`、`organize`与`deleteItem`。`HistoryItemID`、
`ContentVersion`和`HistoryPageCursor`的构造/载荷又是package implementation vocabulary，不能直接
冻结成wire encoding；Gateway应mint opaque item locator、exact-content token和query-bound cursor。
`reviseContent`应最后单独准入，使用独立高风险grant与exact-base token执行OCC；stale时返回conflict，
不做last-write-wins，也不因read/manage grant自动开放旧revision或Canonical内容。

“任意”还必须诚实限定为：用户显式启用后，同一effective user account（same EUID）下、能执行`clipyctl`且持有有效credential
与grant的进程。same-EUID验证不能识别具体`.py`文件，也不能抵御同账户恶意进程；若要per-script
隔离，需求本身就要改成per-client enrollment。最终transport不能凭API名称决定：signed
Developer-ID与App Sandbox下的cold launch、arbitrary/different-team Python可达性、peer identity、
revoke race和single-writer都需实机判别。完整interface、威胁模型、模块边界与TDD顺序见
[`07-python-local-automation.md`](07-python-local-automation.md)，Apple文档能支持和不能支持的结论见
[`apple-python-automation-source-memo.md`](apple-python-automation-source-memo.md)。

### AUTO-2 — 复用V2-05前必须先解决四个内部矛盾（Future-design blocker / **not a current-code vulnerability**）

V2-05仍是`design-consolidated, scaffold proof pending`，这些表/codec/gateway在当前tracked source中不存在；
所以下列问题不会让现版本Clipy被绕过授权，也不是当前可利用漏洞。它们会阻塞未来App Intents和
Local Automation的正确实现，不能把长设计稿直接交给Agent照抄：

1. **compaction chain没有闭合。** `recordHash`包含`previousHash`
   ([`V2-05:583–590`](../../v2/V2-05-external-gateway.md#L583-L590))；compaction却只规定把第一survivor的
   `previousHash`置零并重算该一行
   ([`V2-05:653–666`](../../v2/V2-05-external-gateway.md#L653-L666))。若suffix还有第二行，它仍指向第一行的
   **旧** hash，按read validator的连续性规则会立刻断链。Owning spec须二选一：重算整个surviving
   suffix（含marker），或把新的generation-rooted chain root定义成不改既存记录的显式boundary；先写至少
   3-survivor+marker的codec/transaction Red。
2. **admin record没有足够encoding。** `OperationRecordRow.capabilityRaw`是非optional
   `ExternalCapability`，但admin operation并不由external capability授权，规格没有给它admin sentinel或
   明确映射；当前`RequestSummaryV1`又只有
   `.admin(enrollKindRaw:)`，`ResultSummaryV1`只有`.adminConnectionID`
   ([`V2-05:564–580`](../../v2/V2-05-external-gateway.md#L564-L580))，却要求grant/revoke/rebase/compact都生成
   可审计marker，rebase还要携带reason和discarded range
   ([`V2-05:1142–1157`](../../v2/V2-05-external-gateway.md#L1142-L1157))。为每个admin kind定义closed、bounded、
   privacy-safe payload variant并裁决admin capability column，再冻结golden codec；不能靠
   `operationKindRaw`补出丢失的grant capability/rebase range。
3. **re-grant与unique key冲突。** lifecycle说re-grant创建新row
   ([`V2-05:358–364`](../../v2/V2-05-external-gateway.md#L358-L364))；但`grantKey`固定为
   `"<connectionID>:<capabilityRaw>"`且`@Attribute(.unique)`
   ([`V2-05:443–466`](../../v2/V2-05-external-gateway.md#L443-L466))，第二个event无法拥有唯一key。规格要么使用
   event ID/generation并另证“最多一个live row”，要么就更新唯一state row并承认grant history只在
   OperationRecord中append；不要同时声称两种模型。
4. **fail-closed open后没有可达recovery seam。** singleton缺失且已有gateway rows时`open`拒绝publish，
   却说由chain-rebase admin path恢复
   ([`V2-05:725–755`](../../v2/V2-05-external-gateway.md#L725-L755))；chain corruption也先拒绝facade，再要求
   `GatewayAdminHistory.rebaseAuditLog`
   ([`V2-05:1142–1158`](../../v2/V2-05-external-gateway.md#L1142-L1158))。如果普通`SwiftDataHistory.open`没有返回
   对象，UI就拿不到该admin method。需要独立、能力更窄、只在用户确认后开放的recovery-only open/
   tool：不能发布External facade、不能读content/执行history writes，只能诊断、导出证据和执行已批准
   rebase/quarantine；child-kill与corrupt-chain fixtures证明普通open始终fail closed。

这四项关闭后，AUTO-1的`clipyctl → private transport → ExternalGateway → HistoryAuthority`才有可复用
trust substrate。它们也说明“先实现socket再补audit”会把未决状态机固化在wire protocol里。

## 11. 旧审查项的处置与不应误报的已修项

旧报告不是按文件整体“已修”。至少两个残余仍应显式追踪：

| 旧finding | 当前处置 | 剩余证据/动作 |
|---|---|---|
| `APL-C-05` — six private markers被称为framework markers | **仍开放（措辞+privacy evidence）** | [`PasteboardMarkers.swift:20`](../../../Sources/PasteboardAdapter/PasteboardMarkers.swift#L20)仍写“three NSPasteboard framework markers”，下一段才正确称nspasteboard.org conventions。Apple public [`PasteboardType`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype) list不承诺这六个raw strings；应改成third-party/best-effort denylist，并保留按app暂停/排除与真实password-manager矩阵。marker命中是有价值的defense in depth，不是“敏感内容绝不入库”的平台证明。 |
| `S-8` — dwell tests受CI调度/墙钟影响 | **部分缓解，未从结构上关闭** | shared helper把2 s放宽到10 s，并明确runner starvation原因（[`ScriptedHistory.swift:414`](../../../Tests/PresentationUITests/ScriptedHistory.swift#L414)）；但dwell tests仍用真实30 ms task sleep+poll和120 ms negative sleeps（[`PreviewPaneStateTests.swift:21`](../../../Tests/PresentationUITests/PreviewPaneStateTests.swift#L21)）。当前final SHA又在这些tests运行前因另一编译错误失败，所以没有新CI证据证明flakiness关闭。用可控clock/sleeper或显式continuation驱动state transition，保留一条真实clock smoke即可。 |

以下旧 finding 已有源码层修复，当前报告只保留残余边界：

- BMP/GIF UTI 与 HEIF primary index；
- private Settings selector、`_NSAlertPanel`；
- CoreData diagnostic filter EOF fail-open；
- 完全忽略 `setData` Bool；
- 完全没有 configured retention readback；
- Carbon callback 无条件假定 main thread；
- “所有 image decode 必然在 MainActor”。

但源码变更不等于闭环：write仍可能partial、readback与规格冲突且UI量化、ImageIO owner/
lazy decode仍开、Carbon真实 callback与TCC仍未测、PROGRESS仍未登记当前红head。
