# Clipy 推荐目标设计与收敛门槛

> 文档性质：本轮只读审查的设计建议，不是已批准规格，也不是实现状态
>
> 设计审查开始：**2026-08-20T00:30:19Z（UTC）**
>
> 设计审查结束：**待最终复核填写（UTC）**
>
> 固定比较点：`master@dfb08f2d67fb611eec3fa80db2d6a0a63896f139`
>
> 初始实现快照：`61b418bf9b9767ac84f81da3e65cfe447a509cbd`
>
> 动态 UI 快照：`a028c8c579b365f6c2183c5042ee78a365553d2a`
>（2026-08-20T00:16:36Z）→
> `9c6e3b48f1bbf0c642ccbb61b233319003b6fefb`
>（2026-08-20T00:21:44Z）→
> `9a637a6c58914c4ef586f45f2996656b69f1c241`
>（2026-08-20T00:31:15Z）。本文源码判断截止 `9a637a6c`；它相对固定点为
> **61 commits**。
>
> Maccy 比较快照：`/lzcapp/document/Projects/Maccy`,
> `master@818f03d0e0d3912e1ea23657e2630902ebf5cc8b`
>
> 变更约束：本文件是本任务唯一新增文件；没有修改 Swift、测试、workflow、
> 配置、既有 V1/V2 规格或状态文件。

## 1. 结论先行

推荐目标不是再复制一层 Maccy，也不是为未来功能预埋一组空 protocol。应保留
Clipy 已经有价值的 target graph 和单一 `ClipboardHistory` seam，在现有 owner
内部形成少数 **小 interface、深实现、高 leverage、高 locality** 的具体模块：

1. `HistoryStorage` 深化为唯一的持久化事实、fail-closed validation、bounded
   preview projection 和 search execution owner；
2. `PasteboardAdapter` 只负责把 AppKit 的 access/read/write 结果完整翻译成
   `Sendable` outcome，不再把 `nil`/`false` 静默伪装成成功；
3. `ClipyApp` 用一个有界 `CapturePump` 和一个有序 `PasteFlow` 拥有跨 adapter
   orchestration，不把顺序寄托在多个 unstructured `Task` 的启动时机；
4. `PresentationUI` 只持有页面、选择、loading/error 和 exact-reference fence；
   最终 display decode 必须离开 MainActor，并集中在一个内部具体模块；
5. retention settings 增加权威 readback，但不顺带暴露 SwiftData row、当前总字节、
   通用 settings repository 或 durable change feed；
6. search 先建立绝对 residency/latency budget 和单请求取消语义，再用 bounded
   chunk execution 处理已经暴露的 full-snapshot 风险；不把 Maccy 的常驻 corpus
   直接移植为一个未触发的 G2 collection cache。

这套目标可以支持“内核更可靠、模块更深、更容易验证”。它仍不能在同机 A/B 和
产品选择关闭前支持“功能、内存、速度、复杂度全面超过 Maccy”。

## 2. 分类规则与权威边界

本文每个行动使用以下标签，防止把审查证据、产品偏好和性能猜想混在一起：

| 标签 | 含义 | 进入实现的条件 |
|---|---|---|
| **CN — confirmed need** | 当前源码/CI/规格之间已有可复核的正确性、完整性、安全性或 release-state 缺口；若保留对应已交付能力，就必须关闭 | 先修权威规格或实现归属冲突，再用 named acceptance gate 关闭 |
| **PC — product choice** | Maccy 有、用户可能需要，但 V1/V2 没有承诺，或存在明显权限/语义/复杂度取舍 | 产品 owner 先选择 must/optional/non-goal 并写入规格；没有选择前不预埋代码 |
| **ETO — evidence-triggered optimization** | 目标是 latency/RSS/energy/复用率，不是新业务语义 | 预先声明 workload、budget 和触发证据；满足 G1–G8 或本文件对应门槛后再设计/实现 |

### 2.1 本文与 V1/V2 的关系

- 当前 V1 文档仍是 `ClipboardHistory`、单写 Authority、fresh-context、closed
  actions、Foundation-only Core/Domain 和 target graph 的权威来源。
- V2-02 §12 当前**明确选择 write-only retention policy**；公开 seam 没有 persisted
  policy read。本文推荐 readback 是针对已观察到“设置页显示默认值并可能覆盖真实
  policy”的 **CN 改进提案**，不是声称现有 V2 已要求该 API。它需要先修改该
  decision record。它也不重新打开仍排除的“current retained bytes” OPEN-2。
- V2-07 `UX-COMPILE-1` 当前要求 `PresentationUI` 只 import `HistoryCore` + SwiftUI，
  且禁止 ImageIO。本文对最终 display decode 的推荐会改变这条 rule；必须先完成
  明确、窄范围的规格和 gate 修订，不能先落源码再补叙述。
- G1–G8 仍是证据门槛。一个 UI dictionary 被命名为 cache，或 Maccy 已经有某项
  cache，并不构成 Clipy 的准入证据。

## 3. 目标形状：保留 graph，深化 owner

不建议现在新增生产 target。建议的关系仍是：

```text
ClipyApp
├── CapturePump ───────┐
├── PasteFlow ─────────┼──→ PasteboardAdapter ──→ HistoryCore
├── PanelPresentation ─┘
├── PresentationUI ─────────────────────────────→ HistoryCore
└── SwiftDataHistory ───────────────────────────→ HistoryCore
             │
             ├── HistoryAuthority (only writer / context owner)
             ├── RetentionProjection (validation + scalar facts)
             ├── PreviewProjection + ThumbnailWorker
             ├── SearchExecution (owns Fuse confinement)
             └── mutation fact loading ──→ HistoryDomain pure planners
```

图中的名称是 **现有 target 内的具体模块职责**，不是必须各自成为 public protocol、
SwiftPM target 或 service locator。

| Owner | 推荐的小 interface | 隐藏的复杂度 | 不得拥有 |
|---|---|---|---|
| `HistoryCore` | caller intent 的 immutable DTO、closed action、purpose-specific read | item/version/position contract 与 typed failure vocabulary | AppKit、ImageIO、SwiftData row、cache、provider timeout |
| `HistoryDomain` | 纯 facts → plan | dedup/retention/revision/batch（若产品批准）的业务决定 | clock、UUID/Date 生成、I/O、actor、pasteboard |
| `HistoryStorage` | `SwiftDataHistory` 对 `ClipboardHistory` 的一个实现 | codec、projection integrity、fresh read context、single writer、bounded preview/search | UI state、NSPasteboard、权限提示、自动粘贴 |
| `PasteboardAdapter` | freeze/read outcome；write outcome | AppKit access behavior、provider timeout/ownership change、type mapping、lineage marker | dedup、history transaction、过滤 UI、是否关 panel |
| `ClipyApp` | `submit capture`、`request copy/paste`、panel presentation intent | 两个 adapter 的顺序、backpressure、retry、lifecycle、用户反馈路由 | Domain planner、第二写者、content decode |
| `PresentationUI` | view state over Core DTOs；用户 intent closures | selection generation、loading/error、keyboard/VoiceOver、可见 display state | SwiftData、retention facts、pasteboard side effect、持久化 policy defaults |

### 3.1 公开 seam 的目标上限

`ClipboardHistory` 继续是唯一 History seam。只有两项新增读取值得进入候选规格：

```swift
func retentionSettings() async throws -> RetentionSettingsSnapshot
func preview(
    for item: HistoryItemReference,
    pixels: PixelSize
) async throws -> HistoryPreviewPayload?
```

这只是 interface shape，不是可直接复制的实现。两者都通过 deletion test：如果删掉
前者，caller 必须知道两个 config singleton、校验、position coherence；如果删掉
后者，UI 必须重新知道 Effective Content 选择、UTI、text cap、image source、版本
fence 和大 blob 行为。它们因此比“再加一个 repository/query protocol”更深。

- `RetentionSettingsSnapshot` 只含同一 fresh read 中的 `ChangePosition`、count policy
  和 persisted `HistoryRetentionPolicies`。**不含** SwiftData identity、current used
  bytes、retained inventory 或 mutation helper。
- `HistoryPreviewPayload` 是 bounded、immutable、reference-tagged 的 text 或 encoded
  image payload。它不是 `HistoryDetails` 的别名，不能把最大 128 MiB 的完整内容经
  MainActor 送进 preview。
- `[PC]` multi-item 若被批准，必须扩展“一个 clipboard gesture”的明确 domain
  value/action；不得用一个可选 `[Any]` 或通用 command envelope 偷渡。
- 不为未来 OCR、gateway、journal、cache、streaming 预留空 method。

## 4. 各关键问题的推荐 owner 与 contract

### 4.1 Decode 与 preview

#### 观察和目标

- `[CN]` 当前 `ThumbnailStore` 与 `HistoryPreviewView` 在 MainActor 调用 ImageIO，
  而 preview 还先读取完整 Effective image bytes；这与 V1/V2 的响应性和 owner
  约束冲突。
- `[CN]` thumbnail 和 preview 的 thumbnailable UTI 集合已经重复；类型选择不应
  继续散落到 view。
- `[CN]` async preview 必须在 await 返回后验证 **同一个**
  `HistoryItemReference(id, contentVersion)`/request generation，不能只依赖 task
  创建时的 selection。
- `[ETO]` completed image cache 只有在 G1 的 decode p95 + identical-request reuse
  证据触发后才可存在；当前按 500 个 entry 计数的 UI cache 不是 byte budget，也
  不是准入记录。

#### 推荐 flow

```text
HistoryItemReference + PixelSize
  → HistoryStorage.PreviewProjection
      ├── scalar/text projection（固定 text cap）
      └── ThumbnailService/Worker（source hydrate + downsample + encoded PNG）
  → bounded HistoryPreviewPayload(reference-tagged)
  → PresentationUI.DisplayImageDecoder actor（仅最终 bounded PNG → CGImage）
  → MainActor compares exact generation/reference
  → publish visible Image or discard
```

Owner 规则：

1. `HistoryStorage` 拥有 durable codec decode、Effective Content/source 选择、rich
   content parsing、UTI policy、image downsample 和 output bounds。持久化损坏继续
   typed fail-closed；UI 不看 codec rejection 细节。
2. `PresentationUI` 需要一个具体的内部 `DisplayImageDecoder` actor，且仅接受已经
   有界的 encoded image；它不读取 History、不了解 UTI、不持有 completed cache。
   Apple 当前 `CGImage` 文档列出 `Sendable`，所以 actor 可以把 immutable image
   交给 MainActor；这不等于允许 `CGImage` 出现在 `HistoryCore` 或 public target
   seam。
3. `[PC]` 推荐的最小规格改动是：只在一个精确 allowlisted 内部文件允许
   PresentationUI import ImageIO，禁止 public/package signature 出现 `CGImage`，
   并继续禁止 MainActor decode。相比增加一个只有一次转发的新 production target，
   这保持更高 locality。若 owner 不接受改变 `UX-COMPILE-1`，则必须先设计一个
   具体 rendering adapter target；不能维持现状并宣称“UI 不 decode”。
4. SwiftUI view state 只保留当前可见结果。相同 in-flight decode 可以合并并在
   完成后立即移除；跨 page/reopen 的 completed retention 属 G1。

验收：

- `PREVIEW-OWNER-1`：source/import gate 精确证明 view/state 文件没有 ImageIO，唯一
  decoder 文件不是 MainActor，且 Core/Domain/Storage/UI 的 public symbol 不泄漏
  AppKit/CGImage。
- `PREVIEW-FENCE-1`：A→B selection，A 故意晚于 B 完成；最终只能显示 B，A 不进入
  completed state。
- `PREVIEW-BOUND-1`：最大允许 image/text 在进入 MainActor 前已经被固定 pixel/text/
  encoded-byte cap 限制；full `HistoryDetails` 不在 preview 热路径。
- `PREVIEW-PERF-1`：代表性 60 秒 scroll + selection 的 main-thread hang、frame time、
  decode p95 和 peak RSS 有绝对 budget；G1 未触发时 completed cache 为零。

### 4.2 Pasteboard access、failure 与 multi-item

#### Adapter 的深 interface

`PasteboardAdapter` 应返回值语义 outcome，而不是 `ClipboardCapture?`/`Void`：

```text
read/freeze → snapshot | empty | intentionallyExcluded | accessBlocked
            | changedDuringRead | providerUnavailable | invalidProviderValue

write       → written | ownershipChanged | providerRejected | platformFailure
```

枚举名需要在规格阶段按 Apple API 精确定义；这里要求的是语义分离：

- `[CN]` declared type 的 `data(forType:) == nil` 不能被当作“这个 type 不重要”并
  产生 partial capture；ownership change/provider timeout 与真正 empty 必须不同。
- `[CN]` `setData`/批量 write 的失败必须进入 result。`ClipyApp` 只有在 write 已确认
  成功后才能关闭 panel 或继续可选 Command-V。
- `[CN]` macOS 26 的 pasteboard access behavior 必须成为 adapter 的输入/结果；
  launch、ask/deny、稍后允许、重启和 background polling 需要 signed platform
  matrix。任何诊断只记 outcome/count/duration，不记 type payload、query 或文本。
- `[CN]` freeze 在开始和结束检查同一 pasteboard change identity；中途变化时整次
  snapshot 作废或重试，不能混合两个系统 clipboard 状态。
- `[CN]` write 先在内存中形成完整 `NSPasteboardItem` 集合，再进行一次可观察的
  framework write；不要 `clearContents` 后逐个忽略 Bool。AppKit 本身不能加入
  History transaction，因此失败语义必须诚实，而不是宣称跨系统原子性。

为 deterministic failure test，可以在 `PasteboardAdapter` 内有一个 **internal**
framework seam：一个真实 AppKit adapter 与一个 scripted test adapter，恰好满足
“有两个真实使用方才抽 seam”。它不能 public，也不能变成跨 app 的 generic
clipboard provider framework。

#### Multi-item 是产品/domain 选择，不是 parser 小修

当前 Clipy 只取第一项；Maccy 会读取全部 pasteboard items，并支持多文件
round-trip，但会把内容 flatten，不能证明任意 item 边界被保留。候选语义：

| 选择 | 语义结果 | 判断 |
|---|---|---|
| 明确只支持第一项 | 实现小，但多文件 copy 不可忠实 round-trip | 可作为显式 non-goal；不能再称功能超集 |
| 把每个 pasteboard item 展平成独立 history row | 能保留各 item bytes，但一次 copy 的 group/order 与一次 repaste 语义丢失 | **不推荐**，看似兼容实则改变用户 gesture |
| 一个 history item 持有 ordered clipboard-item group | 可忠实 capture/dedup/revise/paste 多文件；需定义 group identity、limits、schema、revision 和 retention accounting | `[PC]` 若目标是超过 Maccy，推荐先完整设计后实施 |

第三项不是往现有 representations dictionary 塞重复 UTI。它必须先回答：group 总
bytes/数量 hard bound、dedup equality、单 item 修订是否允许、title/search 投影、
retention byte accounting、lineage hint、migration 以及 batch receipt。批准前保持
single-item seam，并在 UI/文档准确标注限制。

验收：

- `PB-FAIL-1`：scripted provider 分别模拟 nil data、读取中 ownership change、write
  false/错误；无 partial capture，无“失败后关 panel”，无敏感日志。
- `PB-ACCESS-1`：macOS 26 signed app 覆盖 access 状态转换；拒绝不会 busy-poll 或
  反复触发 prompt，恢复授权后可以继续捕获。
- `PB-ROUNDTRIP-1`：所有已批准 representation/type、lineage 和 item order 做
  byte-exact round-trip；被 conceal marker 标记的整个 snapshot 仍 fail closed。
- `PB-MULTI-1`：只有产品批准 grouped semantics 后才添加；2+ files、duplicate UTI、
  mixed text/file、near-limit group、失败中断与 restart 都有 fixture。

### 4.3 Capture backpressure

`PasteboardObserver` 不应为每个 change 创建独立 history task。推荐在 `ClipyApp`
内使用一个具体 `CapturePump` actor：

```text
observer freezes immutable snapshot
  → CapturePump.submit(snapshot)
      active slot: at most 1 history.perform
      pending slot: at most 1 immutable snapshot
  → sequential perform result
  → content-free health/result event
```

- `[CN]` 同时在飞的 History capture 固定为 1；pending count 和 aggregate bytes 有
  hard bound。actor serialization 只保证进入 actor 后的顺序，不能替代 caller 的
  mailbox contract。
- `[PC]` 推荐 overload 语义是 `newest pending wins`：NSPasteboard 本身没有历史，
  polling 已经可能看不到两次 poll 之间的中间值；在系统不能提供 lossless source
  的前提下承诺 lossless FIFO 是虚假的。若产品选择不同语义，必须同时说明系统
  层无法恢复已消失的 clipboard state。
- `[CN]` 每个 snapshot 在 observer callback 中完整 freeze 后才可跨 actor；不能把
  `NSPasteboard`/item/provider 引用送进后台。被替换的 pending snapshot 立即释放。
- `[CN]` expected concealed/input rejection 与 storage/corruption failure 分流；前者
  可静默计数，后者进入可恢复状态，但都不记录内容。
- `[PC]` grouped multi-item 若批准，必须增加 snapshot 级 total-byte/count bound；
  不能把“每 item 128 MiB”误当 aggregate bound。

验收：

- `CAP-BP-1`：让 history 人为暂停，burst 提交 100 次；观测到 active≤1、pending≤1、
  RSS 不随 burst 数线性增长。
- `CAP-BP-2`：在推荐 newest-wins 下，第一项完成后只提交最后一个 pending；明确记录
  被替换数量且内容不进日志。
- `CAP-ORDER-1`：同一 lineage 的 own-paste round-trip 与紧邻外部 copy 按 admitted
  order 处理；不依赖 Task start order。
- `CAP-LIFE-1`：stop/restart/observer deinit 取消 consumer，释放 pending bytes，
  不留下 detached work。

### 4.4 Retention readback、validation 与 mutation intent

#### Readback

- `[CN]` 只要设置页继续显示并写入 retention，它就必须先读权威 persisted policy。
  未完成 load 时 Apply disabled；load 失败显示 typed、可重试状态，不能用 200/off
  defaults 伪装 store state。
- 候选 `retentionSettings()` 在 `HistoryAuthority` 的一个 fresh read context 中同时
  读取 count singleton、V2 config singleton 与 `ChangePosition`，完成所有 validation
  后映射为 immutable `RetentionSettingsSnapshot`。
- 这项 readback **不返回当前总字节**，所以不打开 V2-02 OPEN-2。UI 可以显示“预算
  配置值”，不能显示伪造的“已使用值”。
- `[PC]` 若 UI 呈现一个统一 Apply，目标 action 也应是一个统一 user intent、一次
  History Commit；否则必须保留两个独立 Apply 和各自 failure/receipt，不得把两个
  action 的 partial success 显示成原子成功。是否合并 closed action 先修改
  V1/V2；不要同时永久保留三套等价 setter。

#### Projection validation

`HistoryStorage` 内部应形成一个具体、不可由非法 scalar 构造的
`ValidatedRetainedProjection`（名称可调整）。它统一拥有：

- `canonicalBytes >= 0`、`revisionCount >= 0`、`revisionBytes >= 0`；
- 每项及 aggregate hard bound、checked addition/overflow；
- schema/config version、item ID 唯一性、singleton cardinality；
- 已经 decode lineage 的 lane 中，scalar 与真实 bytes/count 的一致性检查；
- corruption → typed persistence failure，且在 destructive R2/R3 planning 前终止。

`capture`、`revise`、`setRetentionPolicies` 各自仍拥有不同的时序和 facts；不要为消除
几段相似代码而建立一个通用 `RetentionCoordinator<T>`。它们应共享“加载/校验出的
值”，而不是共享一个塞满条件参数的 orchestration 函数。

支持边界：零 decode lane 无法证明一个**落在合法范围内但内容错误**的 scalar 与
blob 完全一致。`[PC]` 可选择显式完整 integrity audit/recovery；`[ETO]` 可在真实
损坏或性能证据后考虑额外 checksum/projection rebuild。本文不把无法由现有标量
证明的事实写成已解决。

验收：

- `RET-READ-1`：persist non-default count/age/storage/revision policy，restart，read
  与 UI 完整回显，再 Apply unchanged；结果为 no-op，不改变 position/数据。
- `RET-CORRUPT-1`：negative、over-bound、overflowing aggregate、duplicate、wrong
  version 均在任何 retire/prune 前 fail closed。
- `RET-CORRUPT-2`：在已有 decode lane 注入 in-range mismatch；不执行 destructive
  plan，返回 typed corruption。
- `RET-APPLY-1`：统一 Apply 时证明一次 commit/一次 position；独立 Apply 时证明
  partial failure 的 UI 表述和重新 readback，不宣称原子性。
- `RET-COMPLEX-1`：当前实现/规格统一诚实标为 `O(N log N)`；只有可区分的 operation
  count/scale proof 才能改回 `O(N)`。

### 4.5 Search residency、取消和复杂度

#### 立即目标

- `[CN]` UI 只允许一个 active search generation；新 query 取消并丢弃旧 generation
  的结果。取消是 correctness/resource contract，不是 cache。
- `[CN]` 为允许的 hard-bound corpus 与代表性 corpus 分别声明 transient RSS、
  aggregate DTO bytes、p95/p99、Authority queue wait budget。当前 5,000 × 256 KiB
  约 1.22 GiB snapshot / 1.59 GiB peak RSS 是风险证据，不是“日常必慢”的证据。
- `[PC]` exact/fuzzy/regexp/mixed、case/locale、完整 256 KiB body 是否都必须搜索，
  是产品语义；不能为性能偷偷截断后仍称同一 workload。

#### 推荐的 first optimization：bounded SearchExecution

若预先声明的 residency gate 失败，优先在 `HistoryStorage` 内把当前 `SearchWorker`
深化为具体 `SearchExecution`，公共 `browse(.search)` 不变：

1. Authority 在一个 fresh context 中读取 `ChangePosition` 与一小段稳定排序的 scalar
   corpus，返回 immutable `SearchCorpusChunk`；context 在 await 前释放。
2. `SearchExecution` actor 持有 matcher 和本次请求的 bounded accumulator，逐 chunk
   评估。exact/regexp 保留 default order；fuzzy 保留完整 score + deterministic
   tie-breaker，只保留形成目标 page/cursor 所需的 top candidates。
3. 每个后续 chunk 的 fresh read 同时验证相同 position。若 mutation 穿插，返回
   `.snapshotExpired(current:)`/restart，不把不同位置的 row 拼成一页。
4. cursor 仍绑定 query shape、position 和完整 ordering anchor；不能把内部 chunk
   cursor 暴露为 public pagination contract。
5. 一次请求只常驻 `O(chunk bytes + bounded candidates)`；chunk size 由 byte budget
   控制，不只按 row count。

这是一个具体 module，不是 `SearchRepository`/`SearchEngineProtocol`。Fuse 继续只在
其 actor 内；Authority 继续是唯一 context owner，且没有 context 跨 suspension。

#### 明确不做的 shortcut

- `[ETO]` 不直接复制 Maccy 的常驻 corpus。V2 的 collection cache + durable HCR 是
  G2；只有 hard bound 下 recent/search p95 >50 ms、Authority queue p95 >20 ms 或
  approved reconnect requirement 才进入设计。
- `[ETO]` 不因为 worst-bound snapshot 就直接落 P3/G8 blob store。G8 需要代表性
  capture/read workload 超出明确 memory budget，且其 integrity/durability 成本必须
  按 V2-06 重新审批。
- `[ETO]` 不先加 SQLite FTS、第三方 search dependency 或自建 index；它们会改变
  exact/fuzzy/regex、migration、locale 与 failure semantics。
- `[CN]` retention/pin 的现有比较排序先诚实描述。若绝对 SLO 已满足，不为追求一
  个较漂亮的 Big-O 额外引入 heap/index/schema。

验收：

- `SEARCH-SEM-1`：old full-snapshot 与 new chunk path 在 exact/fuzzy/regexp、present/
  absent、Unicode、long query、pins、cursor/expiration 上逐 fixture byte-for-byte/
  value-for-value 等价。
- `SEARCH-RES-1`：50/200/1,000/5,000 × short/256 KiB，在连续输入与取消下记录
  transient/peak/settled RSS；不存在多个 1.22 GiB generation 重叠。
- `SEARCH-ORDER-1`：在 chunk 之间插入 commit，结果只能是 coherent old snapshot
  或 explicit expiration，不能 mixed snapshot。
- `SEARCH-GRAFT-1`：G2/G8 未触发时，symbol/schema/target 中不存在 collection
  cache、journal、blob handle 或占位开关。

### 4.6 Paste/selection ordering 与 panel/platform state

- `[CN]` `ClipyApp.PasteFlow` 顺序执行：resolve current payload → adapter write →
  （可选且批准的）synthetic paste → success feedback/close。任何一步失败均不执行
  后续步骤；新 selection 的排队/replace policy 必须明确。
- `[CN]` PresentationUI 的 remove/revise/reload 等 dependent operation 在一个 async
  flow 中 await receipt 后再 read，不能分别 fire-and-forget。
- `[CN]` `9a637a6c` 修掉了不存在的 `NSApplication.alertWindow` 编译错误，但新增
  helper 依赖 `className == "_NSAlertPanel"`。源码自己承认这是 AppKit-private class
  name，因此仍不是公开平台契约。Floating panel 是否 resign 后关闭，应由 Clipy
  自己的 `PanelPresentation` 状态决定；若使用 window/sheet 关系，必须只用经 Apple
  文档确认的公开 API 和 signed test。
- `[CN]` Settings 使用 macOS 26 公开 SwiftUI/AppKit hosting path，不再向 responder
  chain 发送私有 `showSettingsWindow:` selector。
- `[PC]` automatic Command-V 必须是显式 opt-in，并把 Accessibility/TCC 状态、目标
  app、failure/timeout、secure input 情况列为产品 contract；“写 clipboard”继续
  准确命名为 Copy，不能用 Paste 掩盖缺少的副作用。

## 5. 为什么这些是深模块，而不是泛化层

| 内部模块 | 小 interface | 删除后 caller 被迫重做的隐藏知识 | 深度判断 |
|---|---|---|---|
| `PreviewProjection` | `preview(reference,pixels)` | content/source selection、UTI、caps、version fence、thumbnail path | 高 leverage；值得加入 purpose-specific History read |
| `DisplayImageDecoder` | bounded payload → image | ImageIO lifetime、actor hop、decode failure、in-flight coalescing | 具体 framework module；不需要 public protocol |
| `RetentionProjection` | load validated scalar facts | row cardinality/version/bounds/overflow/blob cross-check | 破坏性 planner 前的单一安全 choke point |
| `PasteboardAdapter` | read/write outcome | access state、change race、provider failure、lineage/type encoding | AppKit 复杂度留在 adapter，app 只决定 policy |
| `CapturePump` | `submit(snapshot)`/lifecycle | bounded pending、drop rule、sequential mutation、release | 避免每个 callback 散落 Task policy |
| `PasteFlow` | `request(reference,mode)` | resolve/write/optional event/feedback order | 跨两个 adapter 的唯一 orchestration owner |
| `SearchExecution` | existing `browse(.search)` 的内部实现 | chunk coherence、Fuse confinement、ranking、cursor、memory budget | public interface 不增长而实现更深 |

测试应以这些 interface 的 observable contract 为主；内部 helper unit test 只有在能
定位复杂算法边界时保留。若新 interface test 已完整覆盖旧浅 helper 的同一行为，
替换重复测试，不再叠一层维护成本。

### 5.1 现在明确不加入的 speculative graft

以下均不是这轮 finding 的通用“解决方案”：

- 通用 `Repository`, `CommandBus`, `EventBus`, `Materializer<T>`, `Cache<T>`,
  `ProviderRegistry` 或 plugin system；
- 第二个 History writer、fake persistence implementation、CloudKit、多进程 writer、
  网络同步；
- 未触发的 G1 completed-thumbnail cache、G2 journal/collection cache、G3 disk cache、
  G4 source stamp、G5 checkpoint、G6 lifecycle、G8 blob store；
- V2-01 OCR/enrichment、V2-05 ExternalGateway/App Intents/audit、第三方写入；
- 为“以后可能换 SwiftData/Fuse/NSPasteboard”预留 public port；
- persistent search corpus、FTS 或额外第三方依赖，除非语义与 measurement gate
  分别批准；
- 以 Maccy 的 `.shared/.current`、私有 selector、私有 window class name 或完整
  resident model 作为“成熟实现所以可复制”的理由。

如果这些能力未来被批准，应进入原 V2 trigger/record/migration/security 流程，而
不是在当前模块中留下 dormant type、flag、table 或 empty target。

## 6. Maccy 功能覆盖的产品决策矩阵

“推荐”不是说所有 Maccy 功能都必须复制。它要求 owner 明确：若选择 non-goal，
Clipy 可以是更聚焦的产品，但不能再使用“功能全面超集/覆盖更多需求”的表述。

| 能力 | Clipy `9a637a6` | Maccy `818f03d` | 分类 | 推荐产品裁决 | 对“全面超过”的影响 / gate |
|---|---|---|---|---|---|
| capture/coalesce/pin/reorder/remove/clear | 已实现 | 已实现 | CN | 保留 Clipy typed/transaction semantics | 必须继续全绿；不能退化为 UI 直接写模型 |
| 任意非-marker UTI 的单 item round-trip | 当前 raw-value 模型可保留 | Maccy 的 content mapping 未证明任意 UTI | CN | 保留这项通用性；multi-item 设计不能把它缩回固定 allowlist | 这是 Clipy 当前可保留的覆盖优势 |
| immutable revision/revert/OCC | 已实现，Clipy 差异化 | 无等价能力 | CN | 保留并把恢复/错误 UX 做完整 | 这是可宣称的功能优势 |
| count/age/bytes/revision retention | 引擎有；readback 不完整 | 主要 count/item size | CN | 完成 persisted policy readback、validation、receipt UX | 关闭后才能称产品闭环优势 |
| exact/fuzzy/regexp | 已实现 | 已实现 | CN | 保持 frozen semantics 与 bounded execution | 需 SEARCH-SEM/RES + A/B |
| mixed search | 未实现 | 已实现 | PC | 用户研究或明确 parity 目标批准后再加；否则标 non-goal | 未实现时不能称 search 功能超集 |
| multi-item / multi-file round-trip | 仅第一项 | 读取全部并支持多文件；任意 item 边界 flatten | PC | 若目标为功能超集，优先设计 grouped clipboard snapshot；不重复 Maccy 的边界丢失 | 必须 PB-MULTI + schema/domain/migration gates |
| Copy to clipboard | 已实现但内部称 paste | 已实现 | CN | UI/代码 intent 准确命名 Copy，失败不关 panel | PB-FAIL/PB-ROUNDTRIP |
| 自动 Paste 到前台 app | 未实现 | 已实现 | PC | 独立、默认关闭、明确 Accessibility/TCC 的 Paste mode | 缺失时不能称同等自动粘贴；不能和 Copy 混名 |
| Paste without formatting | 未实现 | 已实现 | PC | 若批准，定义 plain-text type priority 与 rich-only failure；可与 Copy/Paste 两模式正交 | round-trip/目标 app fixture，权限语义单列 |
| 可配置 global hotkey | 固定 ⇧⌘C | 已实现 | PC | 推荐 state-3 前加入 conflict-visible 配置和 restore default | 注册失败必须可见；Carbon callback 需平台 proof |
| Pause / ignore next capture | 未实现 | 已实现 | PC | 推荐至少加入 time-bounded pause + ignore-next，状态在 menu bar 可见 | 必须定义 own-paste、restart、concealed interaction |
| app/type/regexp capture filters | 未实现 | 已实现 | PC | 先做需求/隐私模型；用户过滤属 app orchestration，不削弱 storage concealed defense | 未批准就列 non-goal，不建通用 rule engine |
| file/image/text capture switches 与单项 size setting | 只有固定 hard limits | 已有用户设置 | PC | 决定哪些是安全 hard cap、哪些是用户偏好；UI 值绝不能放宽安全 cap | 若保持固定，列为 deliberate simplicity，不称 settings 超集 |
| sort/pinned lane 配置 | 固定 pinned-first total order；有显式 first/last/before | Maccy 可配置 sort/pin lane | PC | 推荐保留一个确定默认；只有用户证据支持时再增加少量 ordering choices | Clipy 的显式 pin placement 是优势；配置广度仍较少 |
| pin alias | 无 | 有 | PC | 只有复用/模板场景获得需求证据后加入；不预埋第二命名系统 | 未实现时不是 Maccy UI 功能超集 |
| quit 时清空 history/system clipboard | 无对应设置 | 有 | PC | 分开决定 durable history purge 与 system clipboard clear，警告不可恢复性 | 需要 destructive-action confirmation/restart proof |
| panel position | 已实现 | 已实现 | CN | 保留；多屏/space/cursor/status-item signed tests | 不仅测 geometry helper |
| panel/preview size、delay、limits | 多为固定值 | 可配置 | PC | 推荐少量高价值选项：size、preview width/delay；保持 hard safety cap | 小屏、长文本、Dynamic Type/VoiceOver gate |
| 用户可配置 history 数量上限 | hard bound 5,000；UI 可到 5,000 | UI 上限 999 | CN + PC | 保留更高 ceiling，但默认值/可见选项由产品选择；5,000 必须通过 resource stress | 1,000/5,000 只能证明 Clipy 自身能力，不是共同范围 A/B |
| thumbnail/preview | 有 single-flight；UI decode/cache 有缺口 | 有异步预览 | CN + ETO | 先关闭 owner/fence/bounds；cache 等 G1 | 不得用当前主线程 decode 作为 UI 优势 |
| pasteboard access/denial UX | 未建模 | 比较报告未证明完整 | CN | macOS 26 core capability 必须建模，与是否复制 Maccy 无关 | PB-ACCESS 是 release blocker |
| App Intents / automation | V2 设计，未实现 | 已实现 | PC | 保持 V2-05 gated；只有 grant/audit/security 产品审批后加入 | 未实现时不能称 automation 超集；不要为 parity 绕过 gateway |
| localization | 未完成 | 文件树 41 locales；当前生成项目纳入 31 | CN（state 3） | String Catalog、locale-aware formatter、伪本地化、VoiceOver 一起验收 | 未关闭不能称用户覆盖更广 |
| packaging/signing/update/recovery | 无 release pipeline | 有 Sparkle/unsigned package workflow；该 fork 的签名、公证、Homebrew 发布未证明 | CN + PC | 签名/公证/更新为 ship need；fail-closed store 的 export/quarantine/rebuild UX 由产品裁决 | 两边都需以实际可安装 artifact 证明，不能从 workflow 名称推导成熟度 |
| macOS 14+ / Intel 覆盖 | macOS 26 arm64 only | 覆盖更广 | PC（已决定） | 保持明确 non-goal，利用新平台 API；不伪称设备覆盖更广 | 不阻止质量优势，但阻止“覆盖更多用户设备”表述 |
| OCR/enrichment/cloud/sync | 未实现且当前排除 | 非本次共同 baseline | PC/ETO | 继续不加入，直到独立需求、安全和证据准入 | 不应为“尽可能多需求”牺牲边界 |

### 6.1 推荐的产品定位句

在上述 choices 未全部选择前，推荐只使用：

> Clipy 目标是在 macOS 26 arm64 上提供比 Maccy 更强的历史一致性、修订、保留和
> 可验证性；对自动粘贴、多 item、过滤、自动化与发行覆盖，按公开 product matrix
> 逐项交付或明确非目标。性能优势按 workload 实测，不作全局形容。

这比“全面超越”更可验证，也允许产品有意识地拒绝高权限或低 leverage 功能。

## 7. 分阶段 acceptance gates

每个阶段只有在实际 final commit 的 macOS 26 arm64 evidence 完整时才算关闭。后续
阶段不得用“代码已写”替代前一阶段的 failure/ordering/resource proof。

### Phase 0 — 恢复可信基线

分类：全部 `[CN]`。

- `BASE-CI-1`：source gates、SwiftLint、SwiftPM functional、perf-helper、XcodeGen
  repeatability、app build/test 在同一 final SHA 完整绿色；warning-as-error 日志与
  job exit code 都 fail closed。
- `BASE-LOG-1`：CoreData awk filter 对 unterminated block 在 EOF 失败，而不是吞掉
  余下 warning/error/`TEST FAILED`。
- `BASE-PLATFORM-1`：移除 `showSettingsWindow:` 和 `_NSAlertPanel` 依赖；公开 API +
  signed integration test。
- `BASE-TRUTH-1`：唯一 release-state matrix 对齐 roadmap、PROGRESS、commit、run ID、
  test/suite count；较早绿色 run 不为较新 UI commit 背书。

### Phase 1 — 数据安全、失败真实性与有序 orchestration

- `RET-CORRUPT-1/2`：projected scalar 在 destructive planning 前 fail closed。
- `PB-ACCESS-1`, `PB-FAIL-1`, `PB-ROUNDTRIP-1`：access/read/write 不再 silent partial。
- `CAP-BP-1/2`, `CAP-ORDER-1`, `CAP-LIFE-1`：有界、可取消、顺序明确。
- `PREVIEW-OWNER-1`, `PREVIEW-FENCE-1`, `PREVIEW-BOUND-1`：无 MainActor/full-detail
  decode，旧结果不可覆盖新 selection。
- `UI-ORDER-1`：remove/revise/read 与 paste request 的 dependent steps 由一个 flow
  await；reverse-completion harness 不能产生 stale state。

### Phase 2 — R.7 / state-3 产品闭环

- `RET-READ-1`, `RET-APPLY-1`：restart 后权威回显；Apply no-op/atomicity 与 UI 一致。
- `UX-LOC-1`：所有 user-facing string、单位、日期/数字都经 String Catalog 与
  locale-aware formatter；MB/MiB 语义一致，伪本地化不截断。
- `UX-A11Y-1`：keyboard-only、VoiceOver、reduce motion/contrast、small display、长
  文本与 failure announcements 的 app-hosted journey。
- `UX-CONFIG-1`：hotkey conflict、launch-at-login failure、panel/preview size choices
  都有 loading/error/recovery，而非静默。
- `SHIP-1`：Release signing/notarization/package/update/rollback 与 store corruption
  recovery runbook；无内容/路径泄露到 telemetry（当前仍应为 no telemetry）。

### Phase 3 — 逐项关闭 Maccy product choices

先提交 §6 每项的 must/optional/non-goal 决议；只实现 approved must：

- grouped multi-item 若批准：`PB-MULTI-1` + Domain/schema/migration/retention/revision
  组合 proofs；
- auto/plain paste 若批准：Accessibility/TCC、secure-input/failure、目标 app 兼容性
  和 Copy/Paste 命名 proofs；
- filters/pause/hotkey/mixed search 若批准：每项独立 security/failure/interaction
  matrix；
- App Intents 只有 V2-05 trigger/security/gateway record 完整后进入，不为 parity
  提前开 external seam。

### Phase 4 — 资源与复杂度收敛

- `SEARCH-SEM/RES/ORDER/GRAFT` 全部通过；先证明 bounded execution，再讨论 resident
  cache/streaming。
- `RET-COMPLEX-1` 与 pin operation-count experiment 能区分 `N`、`N log N`、`N²`；
  规格、fixture 名称和实现上界一致。
- `PREVIEW-PERF-1` 决定 G1 是否触发；未触发就不保留 completed cache。
- 各 workload 的 absolute SLO 在比较 Maccy 前已经冻结，避免看到结果后改门槛。

### Phase 5 — 同机 A/B 与 claim gate

只有 §8 的 parity、measurement、non-regression 和 artifact gates 全部通过，才发布
按 workload 限定的性能优势。只要 chosen must feature 仍为 `missing`，就不能发布
“功能全面超越”。

## 8. Clipy ↔ Maccy 性能 A/B gate

### 8.1 固定实验条件

- 同一台目标硬件、同一 macOS build、同一电源/温控/后台负载；轮换执行顺序；
- Release + WMO，相同 sandbox/signing/entitlement posture；fresh/warm process 分开；
- 普通 latency cell 至少 200 个独立样本后才把 p95 作为 gate；昂贵的 cold-launch/
  energy cell 可先做至少 30 次并明确 quantile 不确定性。p99 只有在至少 1,000 次
  独立样本或等价长时序观测下报告，否则省略；
- 保留 raw samples、machine metadata、commit、binary hash、fixture hash、build
  command 与 cache-reset procedure；报告 p50/p95、满足样本条件时的 p99、95%
  bootstrap interval，以及 failure/outlier 数；
- 共同支持范围使用 50/200/500/999 项做直接 A/B；1,000/5,000 是 Clipy hard-bound
  stress，Maccy UI 上限为 999 时标 `unsupported`，不能算 Clipy 的直接胜场。两组都
  覆盖 text/image/file/mixed、short 与 256 KiB bound，并固定 duplicate/candidate/
  pin/retention/search hit rate；
- 两边先证明相同用户语义。缺少功能的 cell 写 `missing`，不能以“少做一步”计快。

### 8.2 必测 workload

| Workload | Correctness parity | 时间指标 | Residency/系统指标 |
|---|---|---|---|
| launch/open | capture-ready、store 等价 | cold/warm launch p50/p95；p99 仅在样本充分时 | idle/settled/peak RSS、physical footprint、dirty memory、I/O、wakeups |
| capture | novel、duplicate、high-candidate、at-cap、burst | observation→receipt latency | peak RSS、queue wait、dropped/replaced snapshots |
| browse/panel | first open、next page、pin/remove/reload | interaction→visible page | frame time、hang、CPU、settled RSS |
| search | exact/fuzzy/regexp；present/absent/Unicode/long；typing/cancel | query→stable page | peak transient RSS、physical footprint、dirty memory、aggregate DTO bytes、Authority wait |
| preview | cold/warm thumb、大图/长文、快速换 selection | selection→correct preview | decode p95、frame/hang、peak/settled RSS |
| clipboard action | copy、approved auto/plain、approved multi-file | intent→write/target effect | failure rate、permission prompts、CPU/RSS |
| retention/revision | capture/revise/sweep、mass retire/prune | receipt latency | operation count、store/RSS growth |
| steady use | 10 min idle + 60 sec scroll/search | hang/input latency | CPU、energy、wakeups、RSS growth |

### 8.3 通过规则

在跑数据前，为每个主要 workload 冻结绝对 SLO 和 non-inferiority margin。推荐规则：

1. **语义先行。** byte/value/result/failure parity 未过，性能 cell 无效；`missing`
   不能获胜。
2. **绝对 budget。** 两边都慢并不使 Clipy 合格。Clipy 必须先满足自己的 p95/p99、
   peak RSS、hang、energy 和 queue budget。
3. **统计支持。** 只有预先选择的 metric，其 effect 超过预声明 practical threshold，
   且 95% interval 不跨越“无差异”，才记 win/loss；其余记 inconclusive。
4. **无隐藏回归。** 关键 safety/semantic metric 零退化；任一主要 workload 超出
   non-inferiority margin，就不能发布全局“更快/更省内存”。
5. **分项结论。** `browse working set 更低`、`duplicate capture 更快`、`search peak
   RSS 更高` 可以同时成立；不把不同 workload 平均为一个总分。
6. **复杂度独立。** wall-clock A/B 不证明 Big-O。复杂度结论需要源码上界和随 N/B/P
   分离的 operation counts；只有对应 proof 才可声称“时间复杂度更低”。

### 8.4 “可证实超过”的最小 claim 形式

若全部 chosen must feature 完成，推荐发布逐项陈述，例如：

> 在 hardware H / macOS M / corpus C / Release build 下，Clipy 的 recent first-page
> p95 和 settled RSS 相对 Maccy 改善 X/Y，95% interval 为 […]；exact-search peak
> RSS 未改善/仍有 Z 回归。两者语义 fixture 均通过。

禁止用一个最优 cell 外推“Clipy 全面更快/更小”。

## 9. 测试 owner 与 graph 一致性

| Contract | 首要 test owner | 需要的更高层 proof |
|---|---|---|
| 新 Core DTO/action/read | `HistoryCoreTests` + public symbol snapshot | compile/import + scripted preview conformance |
| grouped clipboard domain（若批准） | `HistoryDomainTests` | real in-memory `HistoryStorageTests` transaction/migration |
| retention read/validation、preview/search execution | `HistoryStorageTests` | app-hosted restart/RSS/interaction workloads |
| access/read/write outcome | `PasteboardAdapterTests` | signed macOS access/provider integration |
| view generation/loading/error/a11y | `PresentationUITests` | `ClipyIntegrationTests` panel journeys |
| CapturePump/PasteFlow/panel state | `ClipyIntegrationTests`（app owner） | deterministic suspended/reverse-completion + signed platform run |
| A/B harness | versioned perf runner/artifact | same-machine external orchestration，raw samples published |

XcodeGen/SwiftPM 规则：推荐方案不增加 target，所以 `Package.swift` 和
`ClipyApp/project.yml` graph 不应变化。若 owner 拒绝 ImageIO 的窄 allowlist而选择
独立 rendering target，则 graph、import gates、SwiftLint、XcodeGen linkage、tests、
symbol exposure 和两次生成 diff 必须在同一 slice 一起更新；不能只改一个 manifest。

## 10. 实施前必须先修改的设计记录

本文件不会自行改变权威规格。任何实现 PR 前至少需要：

1. `docs/01-architecture.md`：若采用内部 display decoder exception，明确 ImageIO/
   CGImage owner、actor crossing 和 path-level import gate；
2. `docs/03a-instruction-set.md` / `03b`：候选 preview/readback seam、typed semantics；
   grouped multi-item 或 unified retention action 只有 PC 批准后才加入 closed set；
3. `docs/04-coherence.md`：preview generation、chunk search position/cursor 与 paste/
   capture ordering；
4. `docs/05-authority-kernel.md`：fresh-context retention read、projection validation、
   chunk extraction；single writer/transaction rule保持不变；
5. `docs/06-cross-cutting.md`：新 gates、absolute budgets；G1–G8 不因本文件自动触发；
6. `docs/v2/V2-02-retention.md`：明确撤销 persisted-policy write-only decision，同时
   保持 current-retained-bytes OPEN-2；
7. `docs/v2/V2-07-ux.md`：readback loading/error、decoder import decision、state-3 gates；
8. roadmap/PROGRESS/AUDIT/public symbol snapshot：记录 owner、trigger、commit 和同一
   SHA 的 macOS CI evidence。

顺序必须是“产品/规格决定 → closed interface/owner → tests/gates → implementation →
同 SHA 证据”。不能让动态 UI 先形成事实，再让 gate 和文档追认。

## 11. 支持边界与最终建议

本设计有意保留三条边界：

- 它不承诺 zero-copy、`O(N)` 或更低 RSS；它给出能证伪这些 claim 的 gate。
- 它不把 Maccy 的成熟功能自动变成 Clipy defect；§6 要求产品逐项选择。
- 它不以更多 target/protocol/cache 代表可扩展性。可扩展性来自一个变化只有一个
  owner、caller interface 不泄漏实现、failure/ordering/resource contract 可测试。

推荐近期优先级是：**projection corruption → pasteboard failure/access → bounded
capture/paste ordering → preview owner/fence → retention readback → state 3 → search
residency → product choices → same-machine A/B**。这条顺序先保护敏感内容与持久化
正确性，再扩大功能和优化性能，最符合 Clipy 现有深模块资产。

### 参考证据

- 本目录 `01-standards.md`：standards violations、gate integrity、smell/no-finding；
- 本目录 `02-spec-implementation.md`：V1/V2 implementation gaps；
- 本目录 `04-maccy-comparison.md`：功能、复杂度、现有 perf evidence 和 A/B matrix；
- `docs/01-architecture.md`、`docs/06-cross-cutting.md`、`docs/v2/V2-02-retention.md`、
  `docs/v2/V2-07-ux.md`：当前权威 owner、write-only decision、G1–G8 与 UX gates；
- Apple [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage)、
  [`NSPasteboard.data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/data%28fortype%3A%29)、
  [`NSPasteboard.setData(_:forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/setdata%28_%3Afortype%3A%29)、
  [`SettingsLink`](https://developer.apple.com/documentation/swiftui/settingslink)；链接
  核验日期均为 2026-08-20 UTC，具体 availability/支持边界由本轮 Apple 平台报告
  记录。
