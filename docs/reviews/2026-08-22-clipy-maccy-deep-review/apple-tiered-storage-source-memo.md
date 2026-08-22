# Apple / Clipy 多级存储、驻留与淘汰证据备忘录

> 日期：2026-08-22
>
> 范围：macOS 26+、arm64；SwiftData `DefaultStore`、大二进制内容、
> 内存驻留、分页、淘汰、磁盘容量、备份以及“近似无限历史”的支持上限。
>
> 来源规则：Apple Developer Documentation、Apple WWDC transcript、Apple
> 的公开文件系统/Core Data 文档，以及当前仓库源码。没有使用博客、论坛回答，
> 也不把观察到的 SQLite、WAL 或 `.externalStorage` 文件布局升级为 API 保证。

## 1. 证据标签与结论上限

- **DOC（访问 2026-08-22）**：Apple 公开文档直接支持；结论不宽于原文。
- **CODE（检查 2026-08-22）**：当前 Clipy 源码或设计文档直接支持；不是 Apple
  平台保证。
- **INFERENCE（形成 2026-08-22）**：由 DOC 与 CODE 推导的设计结论；必须由
  macOS 26 真机实验继续约束。
- **UNKNOWN（截至 2026-08-22）**：公开资料和当前测试都不足以形成承诺；文中
  给出判别实验。

> 架构解释边界：本文较早的中央 `ResidentContentCache`、默认 LRU 与“blob tier 是解除 count cap
> 前置”的草图仅是研究候选，已被最终设计收敛。规范性方向以
> [`09-tiered-storage-and-unbounded-history.md`](09-tiered-storage-and-unbounded-history.md) 为准：
> U-scale 与 large-content/P3 是两条独立 track；首版使用 owner-local permits、OS file cache 与
> evidence-gated local cache，不建共享 raw resident cache；本 memo 的 `MEMO-STOR-*` 只代表实验。

本文中的“硬内存上限”只指 Clipy 自己拥有并能够计量的缓存对象；它不包含
SwiftData、Core Data、SQLite、文件系统缓存、解码器、AppKit 或内核的全部临时
分配。本文中的“磁盘大小”也必须区分：

- 内容的逻辑字节数；
- 文件的逻辑长度；
- 文件系统实际分配字节；
- SwiftData store family（主文件、WAL、外置属性、历史等）的总占用；
- 备份中的占用。

这些数值不是同一个指标。

## 2. 结论先行

| 用户关心的问题 | 当前结论 | 对后续设计的含义 |
|---|---|---|
| 现在是否已有真正的多级存储？ | **CODE：没有。** 有持久层、若干有界读路径、一个内存 Signature Index 和一个有界 thumbnail display store，但没有统一的内容驻留/加载/淘汰层。 | 不应把 `HistoryStorage` 这个 target 名称误解成已经实现了 RAM→disk→cold archive 的 tier manager。 |
| `.externalStorage` 是否自动把大内容变成可按需流式加载的冷层？ | **DOC 只保证二进制值位于模型存储旁边；其余 UNKNOWN。** | 不能取得稳定 blob URL、不能做 range read，也不能据它宣称“未把整块 `Data` 载入内存”。 |
| 是否已有淘汰算法？ | **CODE：**持久历史有 count/age/logical-content-bytes/revision pruning；thumbnail store 超限时整库清空。没有通用内容-cache LRU，也没有 Signature Index 淘汰。 | “数据保留策略”与“RAM cache 淘汰”必须分成两个概念和两个接口。 |
| 是否已有可配置的内存驻留参数？ | **CODE：**thumbnail 有 entry/decoded-byte 构造参数；其余只有 admission bounds 和 5,000 项硬上限，没有进程级 resident-content budget。 | 需要独立的 cache budget、in-flight budget、单对象 admission 上限及 memory-pressure trim 规则。 |
| 能否按文件类型动态装载与淘汰？ | **CODE：**当前 details/paste/thumbnail 会完整 hydrate 一个 item 的 Canonical 与整个 revision blob；Storage 没有 range/stream/lease API。 | 存储层应保持类型无关，只提供有界 sequential/range reader；文件类型的访问计划属于 `ContentPreview`/格式策略 owner。 |
| 当前能否无限历史？ | **CODE：不能。** `hardMaximumRetainedItems == 5_000`，搜索、retention fact 和 Signature Index 还有 O(N) 全量驻留/扫描路径。 | 首先把“无限”改写为“没有用户可见 item-count cap、受磁盘与资源保留线约束”；然后消除每操作 O(N) 和全语料内存快照。 |
| 以后能否做到非常大的历史？ | **INFERENCE：可以设计到磁盘主导、内存有界、按页访问。** 但字面意义的无限不可承诺，卷容量、WAL/历史/索引开销、ENOSPC 和备份都有限。 | many-small历史先需稳定游标、持久索引与有界metadata算法；只有large-representation G8/range/stream触发时才需要app-owned immutable blob/GC。 |
| `NSCache` 能否直接承担硬预算？ | **DOC：不能。** Apple 明确说 `countLimit` 和 `totalCostLimit` 都不是严格上限，淘汰顺序也不保证。 | 可把它当可丢弃加速层，不能把产品的内存安全证明托付给它。 |
| SwiftData batch fetch 是否等于内存自动保持平坦？ | **DOC + UNKNOWN：不等于。** Apple 说明 batch 的内存/I/O tradeoff 和释放目标；没有保证精确 RSS 上界。 | 必须在真机以 operation-local context、autorelease pool、RSS/dirty-memory 曲线验证。 |
| SwiftData History 是否就是 Clipy 的无限历史层？ | **DOC：不是。** 它记录 store transaction，额外占磁盘，Apple要求处理后删除；旧 token 可过期。 | 它可用于跨进程失效/同步，不是用户剪切板内容 archive，也必须有独立清理策略。 |

最重要的架构判断是：

> 继续使用 `.externalStorage` 可以支撑当前“有明确单项和总量上限”的 v1/V2。
> 如果large-representation目标需要按范围读取且当前layout越过G8，内容字节才需要
> 进入 HistoryAuthority 所拥有的 app-managed immutable blob 层；many-small超大历史可以在不做P3时先
> 修metadata/index/UI路径。SwiftData 保留
> 元数据、排序、引用和 commit 真相。这个 blob 层不能成为第二个业务写 authority。

## 3. 当前 Clipy 到底已经有什么

### 3.1 已有的持久保留策略不是内存淘汰

- **CODE（检查 2026-08-22）**：固定安全配置允许单 representation 64 MiB、单次
  capture 128 MiB、单 item revision bytes 256 MiB、最多 100 revisions、最多
  5,000 retained items；源码明确说这些是 admission/resource-safety bounds，
  不是 cache 或用户 retention
  ([`Limits.swift`](../../../Sources/HistoryCore/Limits.swift#L1))。
- **CODE（检查 2026-08-22）**：用户可配置的 durable retention 包括 age、
  logical content bytes、revision count/bytes；旧版还有 maximum-unpinned count
  ([`RetentionPolicies.swift`](../../../Sources/HistoryCore/RetentionPolicies.swift#L16))。
- **CODE（检查 2026-08-22）**：`StorageRetention.maxTotalBytes` 的含义是
  Canonical representation bytes 加 revision content bytes，而不是 store family
  的实际文件系统占用
  ([`RetentionPolicies.swift`](../../../Sources/HistoryCore/RetentionPolicies.swift#L61))。
- **CODE（检查 2026-08-22）**：`RetainedBytesRow` 持久化每 item 的
  `canonicalBytes`、`revisionCount`、`revisionBytes` 标量；它被定义为 projection，
  不是 cache
  ([`RetentionSchema.swift`](../../../Sources/HistoryStorage/RetentionSchema.swift#L90))。

因此当前 R2 可以回答“Clipy 保留的内容 payload 逻辑字节是否超过策略”，不能回答：

- SwiftData/WAL/external blob/history/index 实际占了多少盘；
- APFS compression/clone/sparse 后分配了多少物理块；
- 删除以后何时真正回收块；
- 备份会占多少；
- 当前进程的 RSS 是多少。

### 3.2 当前真正驻留在内存的长期结构

- **CODE（检查 2026-08-22）**：`HistoryAuthority` 生命周期内保留完整
  `SignatureIndex`；其内部同时有 signature→ID postings、ID→entries reverse map
  和 retained-ID set。ready 的含义是覆盖所有 retained rows
  ([`SignatureIndex.swift`](../../../Sources/HistoryStorage/SignatureIndex.swift#L69))。
- **CODE（检查 2026-08-22）**：该 index 上限由 5,000 items × 每 item 最多
  32 representations 间接限定；没有 byte budget、LRU、pressure trim 或 cold tier。
- **CODE（检查 2026-08-22）**：每个浏览 surface 的 `ThumbnailStore` 默认最多
  500 entries、64 MiB decoded bytes；超任一限制后执行 whole-store reset，而不是
  LRU/2Q。in-flight fetch 不计入 retained decoded-byte total
  ([`ThumbnailStore.swift`](../../../Sources/PresentationUI/ThumbnailStore.swift#L61),
  [`ThumbnailStore.swift`](../../../Sources/PresentationUI/ThumbnailStore.swift#L195))。
- **CODE（检查 2026-08-22）**：源码没有 `DispatchSourceMemoryPressure`、通用
  content cache、通用 resident-byte controller 或统一 in-flight byte semaphore。

ThumbnailStore 的限制是有价值的局部防线，但它不等于全进程内存上限：请求中的
encoded `Data`、ImageIO 临时内存、并发 flights、SwiftData hydrated blobs 和返回给
UI 的对象可能同时存在。

### 3.3 当前已正确做出的“少取数据”工作

- **CODE（检查 2026-08-22）**：`HistoryAuthority` 每次操作创建新的
  `ModelContext`，关闭 autosave，不让 row/context 跨操作存活
  ([`HistoryAuthority.swift`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L170))。
- **CODE（检查 2026-08-22）**：recent browse 用 `propertiesToFetch` 只取 projection
  scalars，并把两条 lane 的 fetch 约束到 page limit 加少量 lookahead
  ([`HistoryAuthority+RecentReads.swift`](../../../Sources/HistoryStorage/HistoryAuthority+RecentReads.swift#L71),
  [`HistoryAuthority+RecentReads.swift`](../../../Sources/HistoryStorage/HistoryAuthority+RecentReads.swift#L163))。
- **CODE（检查 2026-08-22）**：startup Signature Index build 只取业务 ID、版本、
  pin/projection/signature metadata，不 decode Canonical/revision bytes
  ([`HistoryAuthority.swift`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L449))。
- **CODE（检查 2026-08-22）**：retention inventory 只取 ID、date、pin ordinal，
  不主动访问 content blobs
  ([`FactLoaders.swift`](../../../Sources/HistoryStorage/FactLoaders.swift#L184))。

这些是“元数据/内容分离”的良好开端，但平台是否真的不读取 external blob 文件仍是
支持平台性能实验，而不是 `propertiesToFetch` 能证明的语义事实。

### 3.4 阻止超大历史的现有全量路径

- **CODE（检查 2026-08-22）**：每次 search 先 fetch 每个 retained row 的 title 和
  search body，构造完整 `SearchCorpusSnapshot` 后再在 `SearchWorker` 扫描
  ([`HistoryAuthority+SearchCorpus.swift`](../../../Sources/HistoryStorage/HistoryAuthority+SearchCorpus.swift#L116),
  [`SearchWorker.swift`](../../../Sources/HistoryStorage/SearchWorker.swift#L126))。
- **INFERENCE（形成 2026-08-22）**：以 5,000 × 256 KiB 的 per-item search-body
  admission ceiling计算，仅 body payload 的理论上限已约 1.22 GiB，还没算 String、
  rows、排序和匹配 scratch。当前默认数据通常远小于这个上限，但此路径不能扩成
  “无限”。
- **CODE（检查 2026-08-22）**：capture/若干 mutation 会取得全 retention inventory；
  Signature Index 也要求完整 retained-set coverage。这使写入存在 O(N) metadata 工作。
- **CODE（检查 2026-08-22）**：details、paste、thumbnail creator 都通过
  `HistoryItemRowHydration.hydrate` decode 一个 item 的完整 Canonical 和完整 revision
  list；revision blob 是包含全部 revisions 和每个完整 Effective Content snapshot 的
  单块编码
  ([`FactLoaders.swift`](../../../Sources/HistoryStorage/FactLoaders.swift#L86),
  [`RevisionStateBlobCodec.swift`](../../../Sources/HistoryStorage/RevisionStateBlobCodec.swift#L16),
  [`HistoryAuthority+DetailAndThumbnail.swift`](../../../Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift#L89))。
- **CODE（检查 2026-08-22）**：Storage 没有 range read、chunk stream、content lease
  或 caller-declared maximum-return-bytes seam；`HistoryRepresentation` 最终携带完整
  `Data`。

所以当前结构是“严格有界的整体对象模型”，不是“任意大 history 的分页对象存储”。
它在既定 5,000 项规格内可以成立；不能仅通过调大常量获得无限扩展。

## 4. `.externalStorage`：它保证什么、不保证什么

### DOC

- **DOC（访问 2026-08-22）**：
  [`Schema.Attribute.Option.externalStorage`](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage)
  的公开描述只有：把属性值作为 binary data 存储在 model storage 旁边。
- **DOC（访问 2026-08-22）**：WWDC23 “Build an app with SwiftData” 说明，在
  SwiftData document 场景中，标为 external storage 的内容属于 document package
  的一部分
  ([WWDC23 session 10154](https://developer.apple.com/videos/play/wwdc2023/10154/?time=814))。
- **DOC（访问 2026-08-22）**：`ModelConfiguration.url` 是 schema persistent
  storage 的 on-disk location；Apple 没有把它定义为可单独复制的完整文件集合
  ([`ModelConfiguration`](https://developer.apple.com/documentation/swiftdata/modelconfiguration))。

### INFERENCE

- **INFERENCE（形成 2026-08-22）**：`.externalStorage` 适合让当前大 `Data` 不必
  与普通 scalar column 使用同样的物理放置方式；它不是一个公开 blob-store API。
- **INFERENCE（形成 2026-08-22）**：正确性必须只依赖 SwiftData 属性读写语义，
  不能依赖旁路查找、命名或修改外置文件。当前 `Schema.swift` 把它称为 implementation
  hint 是正确的保守边界。
- **INFERENCE（形成 2026-08-22）**：即使一次 scalar fetch 在测试中未读取 external
  blob，也只能成为 pinned OS/SDK performance fact，不能成为跨版本永久契约。

### UNKNOWN

Apple 的公开页面没有规定：

- 何种类型、大小或时机使用外置文件，是否存在 inline/external threshold；
- 外置文件名、目录结构、稳定 URL 或 content-addressing；
- 读取 `Data`、读取 `Data.count` 或只取 model 时的 materialization/copy 策略；
- 是否支持 range/stream access；
- 外置文件的缓存、fault、eviction 或 memory-map 行为；
- delete/save/crash 时 sidecar 的创建、rename、回收顺序；
- orphan cleanup、secure deletion、disk-space reclamation 时间；
- 主 row、WAL 与外置内容在进程崩溃或断电后的跨文件原子性；
- 单独备份、迁移或复制外置文件的受支持方式。

结论：任何需要稳定 locator、range access、显式 tier、精确计费、可观察 GC 或跨进程
共享的方案，都不能建立在反向解析 `.externalStorage` 布局上。

## 5. ModelContext、fault 与生命周期

### SwiftData 的公开契约

- **DOC（访问 2026-08-22）**：
  [`ModelContext`](https://developer.apple.com/documentation/swiftdata/modelcontext)
  负责 persistent models 的完整生命周期。context 在 fetch/insert 前并不知道具体
  model；知道 model 后会跟踪它们，未保存变更驻留内存直到 implicit/explicit save。
- **DOC（访问 2026-08-22）**：手工创建的 context 默认 `autosaveEnabled == false`；
  container 的 `mainContext` 会由框架启用 autosave
  ([`autosaveEnabled`](https://developer.apple.com/documentation/swiftdata/modelcontext/autosaveenabled))。
- **DOC（访问 2026-08-22）**：`registeredModel(for:)` 只在 model 已被该 context
  知道时返回 typed instance
  ([`registeredModel(for:)`](https://developer.apple.com/documentation/swiftdata/modelcontext/registeredmodel%28for%3A%29))。
- **DOC（访问 2026-08-22）**：WWDC23 “Dive deeper into SwiftData” 进一步说明，
  models 在使用时 fetch 进 context；调用方仍持有 model 引用时它们继续存在，引用
  结束后可以释放并让 context 清空。该 session 同时把 mutation guard 解释为允许
  `enumerate` 释放已遍历对象的重要前提
  ([WWDC23 session 10196](https://developer.apple.com/videos/play/wwdc2023/10196/))。
- **DOC（访问 2026-08-22）**：`propertiesToFetch` 可以指定属性子集；之后访问未取的
  属性会引发从 persistent storage 获取该值的额外开销。空数组表示取全部属性
  ([`propertiesToFetch`](https://developer.apple.com/documentation/swiftdata/fetchdescriptor/propertiestofetch))。

### Core Data faulting 只能作为背景，不是 SwiftData API 保证

- **DOC（访问 2026-08-22，Core Data）**：Core Data fault 是尚未完全 materialize
  的 managed object placeholder；访问 persistent property 会 fire fault。Core Data
  文档还说单个 fault 被触发时会取得该对象全部属性，针对大属性应采用 BLOB 策略
  ([Faulting and Uniquing](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/FaultingandUniquing.html))。
- **DOC（访问 2026-08-22，SwiftData）**：`DefaultStore` 使用 Core Data 作为底层
  storage mechanism
  ([`DefaultStore`](https://developer.apple.com/documentation/swiftdata/defaultstore))。
- **INFERENCE（形成 2026-08-22）**：Core Data 文档解释了为什么短 context、属性
  projection 和批处理通常重要，但 SwiftData 没有公开 `isFault`、`refresh(...,
  mergeChanges:false)` 或精确 refault 控制。因此不能把 Core Data 的每一条 fault
  行为当作 SwiftData source contract。

### UNKNOWN

- 一个 SwiftData context 是否以及何时自动释放/弱持有已注册 model；
- 在对象无外部引用、context 非 dirty 的前提外，batch iteration 的精确释放时点与
  RSS 下降量；
- `propertiesToFetch` 对 `.externalStorage` 在所有 macOS 26 patch/硬件上的 I/O 与 RSS
  影响；
- context 析构后 Core Data/SQLite/file-cache 仍保留多少 clean/dirty pages；
- 同一 model 被不同 operation-local contexts 读取时框架级共享缓存的行为。

### 对 Clipy 的支持上限

- **INFERENCE（形成 2026-08-22）**：当前“一次操作一个 context、不跨 await 保留
  row/context”是正确的基线；它显著缩短 reachable object graph 生命周期。
- **INFERENCE（形成 2026-08-22）**：这仍不足以证明 RSS 立即下降。allocator、
  autorelease、Core Data 与文件缓存都可能延迟回收；必须测 plateau，而不是只断言
  Swift 引用已释放。
- **INFERENCE（形成 2026-08-22）**：若未来开放 50k/1m rows，不能依赖一个长寿命
  context 顺序遍历全部 rows 后“框架会自动淘汰”；应优先稳定 keyset pagination，
  每页短 context，并把每页转换为 bounded immutable values 后销毁 context。

## 6. Fetch limit、batch、prefetch 与索引

### DOC

- **DOC（访问 2026-08-22）**：
  [`FetchDescriptor`](https://developer.apple.com/documentation/swiftdata/fetchdescriptor)
  支持 predicate、sort、`fetchLimit`、`fetchOffset`、`includePendingChanges`、
  `relationshipKeyPathsForPrefetching` 和 `propertiesToFetch`。
- **DOC（访问 2026-08-22）**：`fetchLimit` 是最多返回多少 models；`fetchOffset`
  是第一个 match 的偏移；这些不是 byte/RSS 上限。
- **DOC（访问 2026-08-22）**：
  [`fetch(_:batchSize:)`](https://developer.apple.com/documentation/swiftdata/modelcontext/fetch%28_%3Abatchsize%3A%29)
  返回 `FetchResultsCollection`；按顺序或下标访问时，context 自动取得所需批次，
  `batchSize` 是每批最大 model 数。
- **DOC（访问 2026-08-22）**：`fetchIdentifiers(_:batchSize:)` 按批返回 persistent
  identifiers，不返回属性值
  ([API](https://developer.apple.com/documentation/swiftdata/modelcontext/fetchidentifiers%28_%3Abatchsize%3A%29))。
- **DOC（访问 2026-08-22）**：`enumerate` 为每个 match 执行 closure，默认 batch
  size 是 5,000
  ([`enumerate`](https://developer.apple.com/documentation/swiftdata/modelcontext/enumerate%28_%3Abatchsize%3Aallowescapingmutations%3Ablock%3A%29))。
- **DOC（访问 2026-08-22）**：WWDC23 明确把 `enumerate` 描述为封装 batching 与
  mutation guards 的 scalable traversal：加大 batch 可减少 I/O 但增加内存增长；
  包含 image、movie 或大 blob 的 graph 可选较小 batch；减小 batch 会降低内存增长
  但增加 I/O。默认 mutation guard 会阻止 dirty context 妨碍已遍历对象释放
  ([WWDC23 session 10196](https://developer.apple.com/videos/play/wwdc2023/10196/))。
- **DOC（访问 2026-08-22）**：relationship prefetch 是主动把相关 models 包含进 fetch；
  它用于避免随后逐个 relationship fetch，不是大 blob 延迟加载控制。
- **DOC（访问 2026-08-22）**：SwiftData `#Index` 让指定 key paths 的 filter/sort
  更快；Apple建议为经常排序/过滤的属性建单列或 compound index
  ([WWDC24 “What’s new in SwiftData”](https://developer.apple.com/videos/play/wwdc2024/10137/?time=1231),
  [`Index(_:)`](https://developer.apple.com/documentation/swiftdata/index%28_%3A%29-7d4z0))。

### 不能从这些 API 推出的结论

- **UNKNOWN（截至 2026-08-22）**：Apple 说明了 `enumerate` 的释放目标和 batch
  内存/I/O tradeoff，但没有保证精确 refault 时点，也没有保证峰值 RSS ≤
  `batchSize × row size`。
- **UNKNOWN（截至 2026-08-22）**：Apple 当前网页列出的
  `fetch(_:batchSize:)`/`fetchIdentifiers(_:batchSize:)` 可能比项目固定 Xcode 26 SDK
  的 symbol set 更新；采用前必须加 compile-contract target。WWDC23 已明确展示的
  `enumerate` 可作为 macOS 26 基线候选。
- **UNKNOWN（截至 2026-08-22）**：`fetchLimit` 不限制 predicate/sort 在 store 内部
  的工作量、临时索引、WAL page cache 或 planner 内存。
- **UNKNOWN（截至 2026-08-22）**：`propertiesToFetch` 不能计算 external `Data`
  的 byte length 而不取得属性；SwiftData 没有公开“只取 BLOB 长度”的 projection。
- **INFERENCE（形成 2026-08-22）**：`fetchOffset` 在深分页上不应被假定为 O(page)。
  当前 recent 的 lane-specific keyset/anchor 方向更适合扩大规模；必须用 query plan 和
  端到端 latency 测试确认索引实际生效。
- **INFERENCE（形成 2026-08-22）**：无限规模下必须禁止全量
  `fetch(...) -> [T]`、全量 SearchCorpus 和 per-capture full inventory；单纯把它们改成
  batch iterator 只能降低一次 materialization，不能消除 O(N) CPU/I/O。

## 7. SwiftData History 不是用户内容的 archive tier

- **DOC（访问 2026-08-22）**：SwiftData History 把 persistent-store changes 组织成
  按时间排序的 transactions，可按 token/author 读取；token 是 opaque、Comparable、
  Codable，可保存用于下次增量读取
  ([Fetching and filtering time-based model changes](https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes))。
- **DOC（访问 2026-08-22）**：History 可用于发现 Widget/App Intent 等另一 process
  的变更；只有采用 `HistoryProviding` 的 store（例如 `DefaultStore`）支持。
- **DOC（访问 2026-08-22）**：transactions 与 model data 一起占用额外磁盘；Apple
  要求应用处理后采用合适策略删除 stale transactions 来回收空间。读取已删除历史的
  token 会得到 `historyTokenExpired`。
- **DOC（访问 2026-08-22）**：`DefaultStore` 遵循 `HistoryProviding`；自定义 store
  若要提供历史需自行实现该协议
  ([`HistoryProviding`](https://developer.apple.com/documentation/swiftdata/historyproviding))。

因此：

- **INFERENCE（形成 2026-08-22）**：Persistent History 是同步/失效 journal，不应
  保存用户的完整剪切板历史副本；它自身也需要 retention。
- **INFERENCE（形成 2026-08-22）**：如果 Clipy 未来增加 Python/helper 第二进程，
  Persistent History 可帮助主进程观察 store changes，但它不授权第二 writer，也不
  替代 `ExternalGateway → HistoryAuthority`。
- **INFERENCE（形成 2026-08-22）**：Clipy 自己的 ChangePosition/HCR 与 SwiftData
  History 是不同协议。若同时存在，必须明确各自 owner、consumer token floor 和清理
  时机，避免双 journal 永久增长。

## 8. DefaultStore、SQLite/WAL 与 store family

- **DOC（访问 2026-08-22）**：`ModelContainer` 协调 contexts 与 underlying
  persistent storage；fetch/save 的实际 storage 工作由 container 管理
  ([`ModelContainer`](https://developer.apple.com/documentation/swiftdata/modelcontainer))。
- **DOC（访问 2026-08-22）**：`DefaultStore` 底层使用 Core Data；Apple 仍把具体
  storage 通过 store abstraction 隐藏。
- **DOC（访问 2026-08-22，Core Data SQLite）**：Core Data 支持 SQLite persistent
  store；Apple 的 QA1809 说明 SQLite store 默认 WAL 时，已保存 transaction 可能仍
  在相邻 `-wal` 文件，复制单一主文件会丢失或产生不一致
  ([QA1809](https://developer.apple.com/library/archive/qa/qa1809/_index.html))。
- **DOC（访问 2026-08-22，SQLite 一般建议）**：Apple 的 disk-write 指南说明 WAL
  可合并对同一 page 的写、支持 readers 与 writer 并行；同时警告显式 full `VACUUM`
  可能造成大量写入
  ([Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes))。

支持边界：

- **UNKNOWN（截至 2026-08-22）**：SwiftData DefaultStore 在 macOS 26 的具体
  SQLite `journal_mode`、`synchronous`、checkpoint、auto-vacuum、page cache、busy
  timeout 和 full-fsync 设置没有成为本文可依赖的 SwiftData 契约。
- **INFERENCE（形成 2026-08-22）**：即使实测是 SQLite/WAL，也不得由产品直接
  query/pragma/vacuum 当前 SwiftData store；这会越过唯一 authority 和私有 schema。
- **INFERENCE（形成 2026-08-22）**：容量、备份、quarantine 和恢复应把 dedicated
  parent directory 视为 opaque store family。任何文件级复制都要在所有 store owner
  关闭后，用重新 open + invariant validation 验证，而不是只比较 `history.store`。

## 9. 内存 cache：Apple 提供的是工具，不是 Clipy 的政策

### NSCache

- **DOC（访问 2026-08-22）**：
  [`NSCache`](https://developer.apple.com/documentation/foundation/nscache)
  保存可临时丢弃的 transient values，资源紧张时可能自动 eviction，并支持多线程
  访问。
- **DOC（访问 2026-08-22）**：
  [`totalCostLimit`](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit)
  不是严格限制；超过后对象可能立刻、稍后、甚至永不淘汰，淘汰顺序不保证。
- **DOC（访问 2026-08-22）**：`countLimit` 同样不是严格限制
  ([`countLimit`](https://developer.apple.com/documentation/foundation/nscache/countlimit))。

所以 `NSCache` 可以是“系统可主动丢弃的第二层便利 cache”，但不能成为以下断言的
唯一证据：

- `residentBytes <= 128 MiB`；
- 最旧/最大对象一定先被淘汰；
- cache clear 已经释放 decoder/SwiftData/in-flight 的全部内存；
- memory pressure 到达前一定会回收。

### Memory pressure

- **DOC（访问 2026-08-22）**：
  [`DispatchSourceMemoryPressure`](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure)
  可以监控系统 memory-pressure condition；事件包括 normal/warning/critical。
- **DOC（访问 2026-08-22）**：
  [`makeMemoryPressureSource`](https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource%28eventmask%3Aqueue%3A%29)
  创建后初始 inactive，安装 handler 后需 activate。
- **DOC（访问 2026-08-22）**：Apple 推荐用 XCTest memory performance tests、
  memgraph、Instruments/VM Tracker 和 production metrics 发现内存增长
  ([`XCTMemoryMetric`](https://developer.apple.com/documentation/xctest/xctmemorymetric),
  [WWDC21 memory diagnostics](https://developer.apple.com/videos/play/wwdc2021/10180/))。

- **INFERENCE（形成 2026-08-22）**：pressure 是 emergency trim signal，不是日常
  admission controller。Clipy 必须在每次 admission 时先执行自己的硬预算；warning
  清理未 lease 的冷 entries，critical 清空所有可重建 caches，并停止/拒绝新的重型
  Preview 工作。
- **INFERENCE（形成 2026-08-22）**：事件只能触发“释放 Clipy 明确拥有的可丢弃
  对象”。它无法命令 SwiftData/Core Data/ImageIO 立即放弃全部内部缓存。

## 10. 文件读取、mapping 与有界 streaming

- **DOC（访问 2026-08-22）**：
  [`NSData.ReadingOptions.mappedIfSafe`](https://developer.apple.com/documentation/foundation/nsdata/readingoptions/mappedifsafe)
  只是“如果可能且安全则 memory map”的 hint；不是强制 mapping，也不是 RSS 为零。
- **DOC（访问 2026-08-22）**：`uncached` 也只是建议不要把文件存入 file-system
  caches；不是整个系统不缓存的保证
  ([`NSData.ReadingOptions`](https://developer.apple.com/documentation/foundation/nsdata/readingoptions))。
- **DOC（访问 2026-08-22）**：
  [`FileHandle.read(upToCount:)`](https://developer.apple.com/documentation/foundation/filehandle/read%28uptocount%3A%29)
  从当前 file pointer 最多读取指定字节，返回 `Data`；`FileHandle.bytes` 是异步 byte
  sequence
  ([`FileHandle`](https://developer.apple.com/documentation/foundation/filehandle))。
- **DOC（访问 2026-08-22）**：
  [`DispatchIO`](https://developer.apple.com/documentation/dispatch/dispatchio)
  支持 sequential/random-access file descriptor、异步 read/write、high/low water
  delivery limits。

- **INFERENCE（形成 2026-08-22）**：这些 API 可以支撑 app-managed blob reader，
  但只有 caller 不累积所有 chunks、decoder 真正支持 incremental/range 输入时，才会
  带来有界峰值。
- **INFERENCE（形成 2026-08-22）**：对必须取得完整 `Data` 的 framework/格式，
  storage 层的 chunking 只改变传输方式，不消除最终整块 materialization。
- **UNKNOWN（截至 2026-08-22）**：`.externalStorage` 没有公开 URL，所以不能把上述
  文件 API 套在 SwiftData-managed external blob 上。

## 11. 磁盘容量、实际分配字节与备份

### 容量查询

- **DOC（访问 2026-08-22）**：Apple指南建议在写入大量本地数据前查询卷容量。
  用户请求或 app 正常运行所需资源使用
  `volumeAvailableCapacityForImportantUsage`；预测性、非必要资源使用
  `volumeAvailableCapacityForOpportunisticUsage`
  ([Checking Volume Storage Capacity](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity))。
- **DOC（访问 2026-08-22）**：capacity 属性可返回 `nil`/查询失败，并报告查询时的
  volume capacity。Apple 页面没有定义 reservation 合同。
- **INFERENCE（形成 2026-08-22）**：因此 Clipy 不能把一次查询当未来写入的 reservation；
  竞争/配额/ENOSPC 必须用独立真实写入测试支持。
- **DOC（访问 2026-08-22）**：important/opportunistic capacity keys列在Disk Space required-reason分类；
  但Apple当前Privacy Manifest总览列出的`NSPrivacyAccessedAPITypes`申报平台不含macOS。因此本项目
  macOS-only target没有由这些页面证明的manifest义务；若未来增加被列明平台或政策变化再复核
  ([`volumeAvailableCapacityForImportantUsageKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey),
  [`volumeAvailableCapacityForOpportunisticUsageKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforopportunisticusagekey),
  [Privacy manifest overview](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files))。
- **DOC（访问 2026-08-22）**：`URLResourceValues` 暴露 `fileSize`、
  `fileAllocatedSize`、`totalFileSize`、`totalFileAllocatedSize`；并明确有些值在某些
  filesystem URL 上可能不存在
  ([`URLResourceValues`](https://developer.apple.com/documentation/foundation/urlresourcevalues))。

设计结论：

- **INFERENCE（形成 2026-08-22）**：capacity preflight 只能减少可预见失败；写入
  仍需处理 ENOSPC、quota、permission、volume disappearance 和与其他进程竞争。
- **INFERENCE（形成 2026-08-22）**：history capture 是用户主动 copy 的结果，更接近
  important data；thumbnail/materialized Preview cache 是可重建数据，应按
  opportunistic/purgeable 处理。两类数据不能共用一个 disk reserve。
- **INFERENCE（形成 2026-08-22）**：需要两个指标：业务 retention 继续使用稳定的
  logical content bytes；运维/容量保护另测 store-family allocated bytes 与 volume
  reserve。不要让文件系统实现细节反向改变用户可理解的 retention receipt。

### 备份与 purgeable cache

- **DOC（访问 2026-08-22）**：Apple 将 `/tmp` 与 `Library/Caches` 定义为 purgeable
  data 的位置；系统可定期清理，应用必须能够重建。不可重建的用户数据不应放入这些
  目录
  ([Optimizing Your App’s Data for iCloud Backup](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup))。
- **支持上限**：该页面讨论 iCloud Backup/数据放置，不直接定义 macOS Time Machine、local snapshot
  或SwiftData替换文件如何继承 exclusion。最终backup include/exclude必须分别以macOS文件系统指南、
  `isExcludedFromBackup`、Time Machine文档和signed restore实验约束。
- **DOC（访问 2026-08-22）**：`isExcludedFromBackup` 是可排除 backup 的 guidance，
  不是永不进入 backup/restore 的保证；某些文件操作会重置它，保存后需重新设置
  ([`isExcludedFromBackup`](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup))。
- **DOC（访问 2026-08-22）**：Application Support 用于 app 管理的持久数据；Caches
  用于容易重建的 cache
  ([File System Programming Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/AccessingFilesandDirectories/AccessingFilesandDirectories.html))。

- **INFERENCE（形成 2026-08-22）**：Canonical/revisions 是用户无法从 Clipy 自己
  重建的历史，不应因为体积大就放入 Caches；Preview thumbnail、解析结果和搜索派生
  cache 可以放 Caches，并在缺失时重建。
- **UNKNOWN（截至 2026-08-22）**：用户是否期望剪切板历史进入系统备份是产品/
  隐私决策。敏感且可能巨大的历史既有恢复价值，也有隐私与备份体积代价；不能由
  目录默认值偷偷决定。

## 12. APFS sparse、clone 与“物理空间优化”

- **DOC（访问 2026-08-22）**：Apple 当前的文件技术概览说多数 Apple 设备磁盘使用
  APFS；APFS 支持 clone、snapshot、space sharing、atomic safe-save 和 sparse files。
  同一页面也提醒磁盘可以使用其他 filesystem，应通过 Foundation 使用一致 API
  ([Files and directories](https://developer.apple.com/documentation/technologyoverviews/files-and-directories))。
- **DOC（访问 2026-08-22）**：`URLResourceValues` 可查询 `isSparse`、
  `mayShareFileContent`、`volumeSupportsSparseFiles` 与 allocated sizes。
- **DOC（访问 2026-08-22，retired APFS guide）**：APFS clone 可减少显式文件复制时
  的重复空间；APFS 不提供一般内容 deduplication
  ([APFS FAQ](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html),
  [clone APIs](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/ToolsandAPIs/ToolsandAPIs.html))。

因此：

- **INFERENCE（形成 2026-08-22）**：稀疏文件主要节省大段未写零区，不能压缩普通
  PNG/PDF/文本 payload；clone 只在 Clipy 显式 clone 相同文件时共享 blocks，不能
  自动对任意相同剪切板 bytes 去重。
- **INFERENCE（形成 2026-08-22）**：Clipy 的语义 dedup 仍必须使用 signature
  candidate + byte-exact confirmation；不能把 APFS block sharing 当 identity。
- **INFERENCE（形成 2026-08-22）**：物理分配计费不能只看 logical byte count；
  clone/sparse/compression 会让两者不同。反过来也不能用当前 APFS 实测占用形成跨
  filesystem 产品承诺。
- **UNKNOWN（截至 2026-08-22）**：SwiftData `.externalStorage` 是否以及何时利用
  clone、sparse、compression，Apple 没有公开契约。

## 13. “无限历史”的准确产品定义

字面意义的无限历史不成立：内存有限、磁盘有限、filesystem metadata 有成本、
SwiftData History/WAL/index 有成本，且系统可能拒绝写入。

可以承诺的目标应改写为：

> 用户可以关闭 item-count/age/content-byte retention；Clipy 不因固定产品常量主动
> 删除历史。元数据查询和内容加载保持有界；当可用磁盘跌破保留线或写入失败时，
> Clipy停止接收新内容并给出可恢复的 typed 状态，而不是静默删除或无限占用 RAM。

其中 `count=nil` 不是单一设置变更。它必须同时表示：（1）user maximum-unpinned
policy/action/config 是可选值；（2）包含 pinned items 的独立 global hard retained-item
bound 已被移除或由已批准的资源安全线取代。只把其中一个变成 optional，或用 `Int.max`
伪装，都不是取消 count cap。

这一定义仍需要明确：

1. pinned 与 unpinned 在 disk-pressure 下谁可删除；推荐默认都不静默删，交给用户。
2. 是否提供“自动清理最旧 unpinned”作为显式 opt-in emergency policy。
3. 用户关闭 retention 后是否仍保留 absolute safety cap；如果保留，UI 必须显示而非
   称为 unlimited。
4. backup、export、migration 和 repair 的最大可接受时间。
5. 搜索是否要求 fuzzy/regexp 全历史实时完成；若要求，必须有持久搜索索引与分页
   candidate pipeline，不能全语料入内存。
6. 外部卷断开、只读、容量变化时是暂停 capture、降级只读，还是迁回内部卷。

### 当前要解除的结构性上限

- 5,000-item `HistoryLimits` hard cap；
- per-capture full retention inventory；
- complete in-memory Signature Index；
- full SearchCorpus snapshot；
- retention sweep 一次需要 complete collection facts；
- startup 对所有 retained rows 做同步完整 coverage proof。

上列是 many-small-items 的 count-scale blockers。monolithic canonical/revision blobs 与
detail/paste/preview whole-lineage hydration 是独立 large-content/G8 问题；它们可以触发 P3，但不是解除
固定 count cap 的必经前置。

当前 projection recipe-v2 rebuild 在 5,000 hard bound 下一次预计算 legacy replacements、
然后单 transaction stamp；V2-06 P1 则拟序列化并恢复完整 `SignatureIndex`。两者都只能
作为 capped-regime 合同，不能作为 U-scale 已解决的证据。进入 U-scale 前必须二选一：
P1 明确仅 capped、U-scale 用 durable indexed signature-candidate query 取代；或在 owning
V2-06 中把 P1 修订为这同一套 bounded query/lazy-shard 合同。不并存 complete checkpoint
和第二套 scale index。legacy recipe/signature validation 也必须可恢复、有界，不把当前
open 全库 rebuild 外推到 count disabled。

这些不能一次性删除。应按 vertical slice 逐个替换，并在每次替换后保持当前
dedup、OCC、ChangePosition、fail-closed codec 和唯一 writer 语义。

## 14. 证据驱动的多级存储形状

下面是 **INFERENCE（形成 2026-08-22）**，不是 Apple 指定架构。

```text
HistoryAuthority（唯一业务写 authority）
├── MetadataStore（SwiftData DefaultStore）
│   ├── item / ordering / occurrence / content-version
│   ├── representation descriptors + immutable BlobID
│   ├── logical byte projections / reference counts
│   └── ChangePosition / HCR / recovery checkpoints
├── ContentDepot（app-owned，仍只可由 Authority 提交引用；仅G8/P3 admission后）
│   ├── immutable blob files/chunks
│   ├── prepare → DB-reference-commit → orphan cleanup
│   ├── bounded range/sequential reader
│   └── no UTI-specific decoder
└── HistoryStorage source permits（不保存decoder/UI cache）

clipboard-flow owner（当前AppComposition；获批后才提取ClipboardFlow）：acquisition/pending permits
ContentPreview / Thumbnail：各自decoder/output permits；derived cache只在owner reuse证据后加入
Search：自己的bounded working set；没有复用证据时不建raw resident cache

ClipboardFormats stable facts + owner manifest/profile
└── concrete behavior owner/renderer根据purpose与实测证据生成ContentAccessPlan
    └── 只通过有界 reader 取所需 ranges/chunks
```

### 14.1 为什么 metadata 与 bytes 要分离

- browse、排序、retention、存在性、版本 fence 通常只需几十到几百字节 metadata；
- paste/export 需要全部 selected representations；
- image/PDF/media preview 可能只需 header、metadata、首帧/第一页，或支持 random
  access；
- search projection 应在 ingest/revision 时生成 bounded durable text，而不是搜索时
  打开任意原始 blob；
- 删除与垃圾回收需要知道引用关系，不需要 decode 内容格式。

### 14.2 blob store 不能成为第二个 writer

SwiftData transaction 无法公开地把任意 app-owned 文件写和 DB row commit 变成一个
跨介质事务。因此建议使用可恢复协议，而不是假装原子：

1. 生成与内容无关的随机 immutable `BlobID`；在 private staging 写入有界内容，
   校验 exact byte count，并在本次冻结 source 仍可用时做 byte-exact readback。
2. 在同卷把staging完成品publish到immutable blob namespace；通过process-kill/reopen矩阵后只能称该
   OS/filesystem/build下crash-recoverable，不能从rename/write推导fsync或突然断电durability。此时它可能是
   orphan，但尚未成为业务可见内容。
3. 在唯一 `HistoryAuthority` 的 SwiftData transaction 中写 representation descriptor、
   BlobID reference、logical bytes、History mutation 与 ChangePosition。
4. commit 成功后 blob 成为 referenced；commit 失败则保留为可安全清理的 orphan。
5. 删除先在 DB transaction 中移除 reference；只有 commit 后 GC 才删除 unreferenced
   blob。GC 永远不能删除仍被任一 committed row 引用的 blob。
6. startup只读取bounded checkpoint；missing referenced blob在on-access或bounded background reconciliation
   中fail closed。grace只能推迟核对；只有durable ownership/checkpoint与committed-reference reconciliation
   证明不可达后才清理orphan。进程kill在每个步骤都必须恢复到可解释状态。

不要把当前 xxh3 fingerprint 直接当 BlobID：仓库已经正确规定 fingerprint 是 evidence，
不是 identity。本设计不新增 content hash/checksum；BlobID、path、manifest 和 backup identity
都使用明确随机 ID/version。所以当前 runtime 只对 wrong identity、missing source、read error和
length mismatch fail closed，不承诺自检同长 silent media corruption。

### 14.3 Storage 接口必须保持类型无关

不建议为 PNG、PDF、RTF、视频各造一个 Storage 协议。Storage 只需要理解：

- immutable blob/representation identity；
- logical byte count 与可读 ranges；
- access purpose、maximum return bytes、deadline/cancellation；
- sequential 或 random-access hint；
- lease 生命周期与 cache cost；
- typed missing/corrupt/unavailable/over-budget result。

`ClipboardFormats`只提供stable facts；需要哪些bytes、decoder与external-I/O policy由
`ContentPreview`/具体behavior owner的manifest决定。这样增加一种 Preview
格式不会修改 DB 文件布局、LRU 或 GC。

不要把裸 file URL 交给 PresentationUI、Python 或第三方 renderer：URL 会绕过 byte
budget、lease、audit、version fence 和路径保密。可暴露的是 bounded value/stream
seam，不是存储路径。

### 14.4 evidence-gated 的 RAM cache政策

首版默认只需要owner-local permits与OS file cache。只有具体owner的reuse/hit-rate/latency证据批准cache后，
一个可证明的size-aware LRU才是起点，不需要上复杂CLOCK-Pro：

- `residentEncodedBytes`：原始/编码内容 cache 的硬预算；
- `residentDecodedPreviewBytes`：decoded pixels/text layout 的独立硬预算；
- `maximumEntries`：零字节 negative result 也受 count 限制；
- `maximumSingleEntryFraction`：超过预算固定比例的 blob 允许读但不 cache；
- `maximumInFlightBytes` 与 `maximumConcurrentLoads`：防止 cache 本身有界而并发峰值
  无界；
- exact key 包含 BlobID/content version/range/renderer version，禁止 stale reuse；
- admission 前计算 owned cost；evict 最旧、未 lease entries 直到可容纳；全部被 lease
  时拒绝或等待，不得静默突破 hard budget；
- sequential full-history scan 默认 bypass/probation，避免一次扫描污染交互 hot set；
- warning pressure trim probation/未 lease；critical 清空全部可重建 cache并停止重型
  prefetch；
- 指标只记录 byte/count/latency/hit/miss/eviction reason，不记录剪切板内容。

若真实 trace 显示 scan pollution 或频繁抖动，再把 LRU 升级为 segmented LRU/2Q；
不能先用复杂算法掩盖尚未量化的 workload。

### 14.5 disk tier 仍需要两套 budget

- **用户内容 retention**：稳定、可解释的 logical representation bytes；现有 R2 可沿用
  语义。
- **设备健康 reserve**：store family allocated bytes、derived-cache bytes、volume
  important/opportunistic capacity、WAL/history headroom。

第二套预算只决定 admission/maintenance，不应在未授权时静默改变第一套 retention。
capacity 不足时优先删除 DerivedCache；仍不足则暂停新 capture并呈现 typed health。

## 15. TDD / 真机判别流程

所有 performance 数值 gate 必须在固定 macOS 26 patch、Xcode/Swift 版本、arm64 机器
类别和显式 fixture ID/version 下记录。unit tests 证明语义；hosted child-process、Instruments、
XCTMemoryMetric 与 disposable volumes 证明资源行为。一次机器的结果不是 Apple 契约。

### MEMO-STOR-0：冻结基线

**Characterization（不是Red）**

- 建立 0/200/5,000 items，small text、64 MiB representation、100 revisions、最大
  search projection、image/PDF fixtures。
- 记录 browse/search/details/paste/thumbnail/capture 的 wall time、RSS/dirty peak、
  logical/allocated disk bytes、file count 与 reads/writes。
- 只增加 content-free measurement receipt 与 signpost；不得打印 UTI payload、title、
  search query 或 bytes。

**Refactor gate**

- 报告 schema/version/fixture ID/version/OS build；否则数据不可比较。

### MEMO-STOR-1：证明 scalar fetch 不触碰 blob 的支持上限

**Characterization（不是Red）**

1. 建两个相同 row-count stores：一个 blob 每项几 bytes，一个 blob 每项接近上限。
2. 分别运行 recent scalar fetch、retention inventory、startup signature fetch。
3. 比较 RSS、page faults、disk reads 与 latency；对 store family 运行 File Activity。

**可升级的结论**

- 若大/小 blob 的 scalar lane 资源曲线无显著差异，只能记录“在该 OS build、fixture、query shape与
  measurement sensitivity下未观察到与大blob materialization一致的额外成本”；这不能证明没有发生。

**不能升级的结论**

- 不能说 `.externalStorage` 永远 lazy；不能说没有任何 metadata I/O；不能覆盖未来
  OS。

### MEMO-STOR-2：operation-local context 的 RSS plateau

**Characterization（不是Red）**

- 连续分页遍历 50k metadata-only rows；每页 fresh context + autorelease pool。
- 另一 control 使用单一长寿命 context。
- 多次完整遍历后，fresh-context lane 的 quiescent footprint 必须在批准斜率内 plateau，
  不能随累计访问行数线性增长。

**Green**

- 若不 plateau，缩短 page、移除意外 row retention、切断 DTO 对 model 的引用；不要
  用强制 `malloc_trim` 或私有 Core Data API掩盖。

### MEMO-STOR-3：batch fetch 不是自证

**Characterization（不是Red）**

- 对 `fetch(_:batchSize:)` 与 `enumerate` 测 batch size 32/128/512/5000；closure 只累加
  scalar，禁止保存 model。
- 单独测试 closure 意外 append model 到数组的负控制，必须显示线性增长。

**Acceptance**

- 选择在目标机上兼顾 I/O 和 plateau 的 batch size；在 memo/代码中将结果标为 platform
  measurement，不写成 framework guarantee。

### MEMO-STOR-4：证明当前 blob read 是整体 materialization

**Characterization（不是Red）**

- 以 canonical 128 MiB + revisions 256 MiB 极限 item，分别调用 details、paste、
  thumbnail。
- 捕获 peak footprint 与复制次数；验证仅要一个小 thumbnail 时当前仍读取/解码完整
  lineage。

**Green（当前模型内）**

- 只可减少无谓副本、限制 concurrent heavy reads；如果目标要求真正 range/stream，
  必须进入 app-managed blob vertical slice，不能在 `.externalStorage` 上伪造。

### MEMO-STOR-5：硬 cache budget 与淘汰顺序

先为具体 owner 记录 reuse/hit-rate/latency；没有复用证据时“不缓存”是正确结果。只有证据批准该owner
的cache后，才把下列每一个行为单独映射为 red→green→refactor：

1. 小 entry 命中后不重复读。
2. 超 budget admission 先 evict LRU unleased entries；观测总 owned cost 从不超限。
3. 单个对象大于 budget 时返回 uncached result 或 typed over-budget，不清空 hot set 后
   又把大对象放进去。
4. 所有 entries leased 时不越界；请求等待或失败的行为冻结。
5. sequential scan 不挤掉 protected interactive entries。
6. negative entries 受 count/TTL 约束。
7. content-version/renderer-version 变化使旧 key 不可命中。

测试通过 cache public/package interface，只观测统计和结果；不断言 dictionary 顺序或
内部 node。

### MEMO-STOR-6：memory-pressure 响应

**Red**

- 通过测试 seam 注入 normal/warning/critical，不依赖 CI 真正制造系统 pressure。
- warning 后未 lease cold entries 被 trim；critical 后所有可重建 entries 归零；leased
  operation 要么完成且仍计入 in-flight，要么收到 typed cancellation。
- pressure burst coalesce，不能每事件 spawn 无界 Task。

**Hosted proof**

- macOS 真机再用受控 memory-pressure 工具/负载观察真实 DispatchSource delivery；
  不把 injection test 冒充系统 proof。

### MEMO-STOR-7：disk-capacity 与 ENOSPC

**Red**

- 在 disposable APFS disk image/有限 volume 中逐渐填满。
- capacity preflight 有足够空间时正常 commit；preflight 显示不足时拒绝在大 staging
  分配前发生；preflight 后被竞争耗尽仍必须处理真实 ENOSPC。
- commit 失败后 reopen：History row、Blob reference、ChangePosition、RetainedBytes、
  HCR 只能是完整 old state；staging orphan 可清理。

**Refactor**

- 重要内容和 derived cache 使用不同 reserve；测试不修改用户真实卷。

### MEMO-STOR-8：app-managed blob crash matrix

用 child process 在以下点逐一 `SIGKILL`：

1. staging file create 前/后；
2. 写每个 chunk 中；
3. length validation 与 staged byte-exact readback 后；
4. immutable publish 后；
5. DB transaction 前/中/返回后；
6. response 前；
7. delete-reference commit 前/后；
8. GC unlink 前/后。

每次 restart 必须满足：

- committed reference 一定可读且 byte-exact；
- missing referenced blob fail closed，不伪装 notFound；
- orphan 不可从 browse/details/paste 可见；
- GC 不删 referenced blob；
- logical bytes、refcount 与 store rows 一致；
- 只有 external/migration operation 已将requestID/outcome与mutation同transaction持久化时，同一request
  retry才不产生第二个业务commit；普通clipboard capture只验证store invariant与既定dedup/coalesce语义。

这个矩阵证明 process-crash recovery；不证明断电后的 device-cache flush，后者仍是
UNKNOWN。

### MEMO-STOR-9：删除与空间回收

**Red**

- 删除大 item 后先验证语义不可见与引用消失；再在有界 maintenance 后验证 orphan
  文件被删。
- 分别记录 logical size、allocated size、volume capacity；不得要求立即一一回升，
  除非实测合同明确批准。
- SwiftData History stale transactions 未清理的 control 必须显示仍占空间；清理后
  old token 得到 expired 行为。

### MEMO-STOR-10：备份与 cache 分类

**Red**

- source history 位于 Application Support；derived Preview 位于 Caches 或明确设置
  exclusion；每次 atomic replace 后重新检查 resource value。
- 删除整个 DerivedCache 后所有 preview 都能由 source 重建；删除 source 必须导致
  明确数据丢失测试，防止把不可重建内容误分类成 cache。

### MEMO-STOR-11：APFS 与非 APFS

- 在 APFS 上测 clone/sparse fixture 的 logical 与 allocated size 差异。
- 在不支持 clone/sparse 的临时卷或模拟 capability seam 上，功能语义必须相同，只是
  空间优化消失。
- BlobStore 不得要求 APFS 才能正确；APFS capability 只能是可选 optimization。

### MEMO-STOR-12：从 5,000 到“无固定 count cap”的 tracer bullets

按 5k baseline→5,001 functional boundary→50k→250k→1m 分阶段，任何一级失败就不推进：

1. recent keyset page 的 peak memory 与累计 N 无关；latency 在 SLO 内。
2. exact indexed search 不生成全语料 snapshot。
3. fuzzy/regexp 使用持久候选/index 或显式 bounded scope；不得 O(N) materialize。
4. capture 不 fetch 全 retention inventory；retention 使用持久 aggregate/ordered victim
   cursor。
5. dedup index 分片/按 signature store-query；不保留全部 reverse/posting maps。
6. startup 只验证 schema/checkpoint，并在后台做可恢复 incremental validation；不阻塞
   整库 O(N) decode。
7. UI滚动使用bounded row window，cursor在连续writes下保持批准语义。

details/preview range read属于独立large-content/G8 track；可并行研究，但不阻塞many-small-item count unlock。
方案 A 可以在 G8 不触发时长期承载 U-scale：只要 metadata/index/pagination 路径有界，
已有 purpose lane 只向 caller 交付选定 representation，并把为选择它而 whole-aggregate
hydrate 的 bytes 如实记账。这不是 physical range read，但也不是强制迁移 P3 的理由。
只有 approved G8/range/stream trigger 才允许 scheme B/P3 的 per-representation/range physical
layout。

“通过 1m fixture”仍不叫无限，只证明该规模和机器类别。

### MEMO-STOR-13：不同内容格式的访问模式

通过同一个 Storage reader seam，为每种 purpose 提供 fixture：

- text：只有codec+fixture证明后才选择bounded prefix/sequential；非法编码使Preview typed-unavailable，raw
  history bytes仍保留并可回放；
- raster：header + decoder 所需 source；记录 decoder 是否仍请求完整 payload；
- PDF：当前按bounded full `Data`设计；Apple资料未证明PDFKit首屏可用random ranges，先记录真实access；
- media：metadata/首帧 future gate，不默认读取整个文件；
- archive/unknown：只展示 type/size，不自动解包；
- paste当前明确要求bounded full `Data`；export/CLI只有其sink/audit合同批准后才可走有界stream/staging，
  不从Storage reader实验外推paste provider语义。

每个 renderer 的 test 只声明 access plan；Storage 测 range、byte budget、cancellation
和 version fence，不知道 PNG/PDF/RTF 语义。

### MEMO-STOR-14：跨资源的峰值而非单 cache 指标

构造 worst-case overlap：

1. 按未来批准的capture backlog policy构造active+pending freeze；当前生产没有该硬界，不能把“两份”写成现状；
2. 一个详情 full hydrate；
3. 多个 thumbnail/Preview decode；
4. search；
5. retention sweep或migration。

验收看整个 app 的 peak footprint、main-thread stall、disk writes 和 cancellation 后的
quiescent plateau。只断言 `cachedDecodedBytes <= 64 MiB` 不能关闭这个 gate。

## 16. 需要写入主 REVIEW 的明确裁决

1. 当前 Storage 在 5,000-item 受限规格下有认真做 scalar projection、短 context、
   logical-byte retention 和局部 thumbnail bound，但它不是多级内容存储系统。
2. `.externalStorage` 继续作为当前 schema 的 opaque placement option；不要反向解析，
   不要称为 streaming/cold tier。
3. 当前不存在 general content eviction；Signature Index 全驻留，search corpus 全量，
   thumbnail 超限整库 reset。
4. storage retention 与 memory cache eviction 必须拆成独立术语、状态和测试。
5. many-small超大历史的 blocker 不是“磁盘够不够”一个问题，而是 O(N) search、inventory、
   dedup、startup/UI；monolithic blob hydration是独立large-content/G8 track。
6. “无限历史”只能宣传为无用户固定 count cap；仍需磁盘 reserve、typed admission
   failure、derived-cache-first cleanup，以及可选的用户授权 emergency retention。
7. 若large-representation证据触发 range/stream/精确驻留，才采用 Authority-owned app-managed immutable blob
   tier；SwiftData transaction 保存引用与业务真相，crash recovery 用 orphan/GC 协议，
   不建立第二 writer。
8. Storage 只暴露类型无关的 bounded reader；stable facts留在`ClipboardFormats`，load plan与decoder
   留在`ContentPreview`/具体behavior owner。
9. 第一版先用owner-local permit；只有reuse证据批准后才加size-aware LRU + scan bypass；
   `NSCache` 和 memory-pressure notification 只作辅助。
10. 所有“不会 materialize”“内存保持平坦”“删除释放磁盘”“崩溃原子”等结论，必须
    由本文真机矩阵限定到明确 OS/SDK/filesystem，不能从 Apple 未承诺的实现细节推出。

## 17. Apple 一手来源索引

以下页面均于 2026-08-22 访问：

- [SwiftData `externalStorage`](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage)
- [WWDC23: Build an app with SwiftData](https://developer.apple.com/videos/play/wwdc2023/10154/?time=814)
- [WWDC23: Dive deeper into SwiftData](https://developer.apple.com/videos/play/wwdc2023/10196/)
- [`ModelContext`](https://developer.apple.com/documentation/swiftdata/modelcontext)
- [`FetchDescriptor`](https://developer.apple.com/documentation/swiftdata/fetchdescriptor)
- [`propertiesToFetch`](https://developer.apple.com/documentation/swiftdata/fetchdescriptor/propertiestofetch)
- [`fetch(_:batchSize:)`](https://developer.apple.com/documentation/swiftdata/modelcontext/fetch%28_%3Abatchsize%3A%29)
- [`fetchIdentifiers(_:batchSize:)`](https://developer.apple.com/documentation/swiftdata/modelcontext/fetchidentifiers%28_%3Abatchsize%3A%29)
- [`enumerate`](https://developer.apple.com/documentation/swiftdata/modelcontext/enumerate%28_%3Abatchsize%3Aallowescapingmutations%3Ablock%3A%29)
- [`DefaultStore`](https://developer.apple.com/documentation/swiftdata/defaultstore)
- [SwiftData History](https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes)
- [`HistoryProviding`](https://developer.apple.com/documentation/swiftdata/historyproviding)
- [WWDC24: Create a custom data store with SwiftData](https://developer.apple.com/videos/play/wwdc2024/10138/)
- [WWDC24: What’s new in SwiftData — Index](https://developer.apple.com/videos/play/wwdc2024/10137/?time=1231)
- [Core Data Faulting and Uniquing](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/FaultingandUniquing.html)
- [Core Data QA1809 — SQLite/WAL backup](https://developer.apple.com/library/archive/qa/qa1809/_index.html)
- [`NSCache`](https://developer.apple.com/documentation/foundation/nscache)
- [`DispatchSourceMemoryPressure`](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure)
- [`XCTMemoryMetric`](https://developer.apple.com/documentation/xctest/xctmemorymetric)
- [WWDC21: Detect and diagnose memory issues](https://developer.apple.com/videos/play/wwdc2021/10180/)
- [`FileHandle`](https://developer.apple.com/documentation/foundation/filehandle)
- [`DispatchIO`](https://developer.apple.com/documentation/dispatch/dispatchio)
- [Checking Volume Storage Capacity](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity)
- [`URLResourceValues`](https://developer.apple.com/documentation/foundation/urlresourcevalues)
- [Optimizing Your App’s Data for iCloud Backup](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)
- [Files and directories](https://developer.apple.com/documentation/technologyoverviews/files-and-directories)
- [Apple File System FAQ](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html)

## 18. 仍需 Apple / macOS 26 实验关闭的 UNKNOWN

- `.externalStorage` 在目标 OS/SDK 的 inline/external、读取与清理行为；
- scalar `propertiesToFetch` 是否稳定避免 external blob I/O；
- SwiftData batch/context 的实际 registered-object 与 RSS plateau；
- DefaultStore 的 WAL/checkpoint/vacuum/page-cache 设置及 store-family 文件集合；
- SwiftData transaction 与 app-owned blob publish 在 process kill/ENOSPC 下的组合恢复；
- 删除 external blob、WAL/history 后实际 allocated-space 回收时机；
- memory-pressure event 在 macOS menu-bar agent 生命周期中的 delivery 与 trim 时机；
- 不同 filesystem、外部卷、网络卷和 volume removal 下的行为；
- 各 Preview decoder 是否能真正消费 range/stream，还是最终要求完整 `Data`；
- 无 fixed item cap 后 exact/fuzzy/regexp search、dedup、retention 和 startup 的可接受 SLO。

在这些项关闭前，REVIEW 应把目标写成“可演进且有判别实验”，不应写成已经具备
无限历史、自动 fault eviction 或精确内存上限。
