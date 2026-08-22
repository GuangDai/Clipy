# 多级存储、内存驻留与“无固定条数上限”历史审查

> 审查日期：2026-08-22
>
> 性质：架构与抽象 TDD 意见，不是实现规格，不修改产品代码。
>
> 平台证据：[Apple / Clipy 多级存储、驻留与淘汰证据备忘录](apple-tiered-storage-source-memo.md)。

## 1. 直接回答

tracked Clipy 代码**没有主动把全部 raw clipboard content 放进一个 process-lifetime collection**：
最近列表主要读取标量投影，`HistoryItemRow` 的 Canonical/revision 大 `Data` 使用 SwiftData
`.externalStorage` placement option，并且每次 Authority 操作使用短生命周期 `ModelContext`。
这只描述应用层所有权；它不能证明 SwiftData、SQLite、filesystem cache 或 framework 永不驻留相关页
([`HistoryAuthority+RecentReads.swift`](../../../Sources/HistoryStorage/HistoryAuthority+RecentReads.swift#L198),
[`Schema.swift`](../../../Sources/HistoryStorage/Schema.swift#L65),
[`HistoryAuthority.swift`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L163))。

但当前也**不是用户设想的可控多级存储**。现在没有统一的：

- 原始内容 RAM 驻留预算；
- 正在读取、复制、解码的 in-flight byte budget；
- 按访问目的取得单个 representation/range/stream 的 content seam；
- app-owned immutable blob depot、lease、分块读取与 orphan GC；
- 全进程 cache 协调或 memory-pressure 降级策略；
- 物理 store-family 配额、写入 reservation 或 ENOSPC 恢复协议。

当前确实有“淘汰算法”，但它们属于两种局部机制。触发矩阵也必须写清：count 在 capture/
set-count 时执行；R1 在 capture/set-expanded-policy 时执行；R2 在 capture/revise/
set-expanded-policy 时执行；R3 在 revise/set-expanded-policy 时执行；时间流逝或 memory pressure
本身不会触发 history sweep。

1. count、age、logical content bytes、revision count/bytes 会**永久删除历史或修剪
   revisions**，属于 durable retention，而不是“把内容从 RAM 降到 disk”
   ([`RetentionPolicies.swift`](../../../Sources/HistoryCore/RetentionPolicies.swift#L16),
   [`RetentionPolicySweep.swift`](../../../Sources/HistoryStorage/RetentionPolicySweep.swift#L42))；
2. 每个 UI surface 的 `ThumbnailStore` 有 500 entries / 64 MiB decoded bytes 的局部
   bound，但超限时清空整个 store，不是 weighted LRU；其 in-flight encoded bytes 与
   ImageIO workspace 不计入这个数字
   ([`ThumbnailStore.swift`](../../../Sources/PresentationUI/ThumbnailStore.swift#L61),
   [`ThumbnailStore.swift`](../../../Sources/PresentationUI/ThumbnailStore.swift#L195))。

因此答案是：**当前在 5,000-item、有单项硬界限的产品范围内有认真做持久化、标量
投影和局部缓存防线；它不能证明按格式动态装载/淘汰，也不能支持“无限历史”。**

长期可以做到用户真正想要的结果，但产品语言必须是：

> 用户可以关闭 item-count 限制；Clipy 不因一个固定产品常量主动删历史。列表、搜索、
> 内容读取和缓存驻留仍保持有界；磁盘保留线或真实写入失败时停止接收新内容并返回
> typed health，不静默删除用户历史。

这叫“**无人工 count cap**”或“virtually unbounded”，不是字面意义上的无限。磁盘、
filesystem metadata、索引、WAL/history、备份时间和恢复时间都仍然有限。

还必须拆开两个正交目标：很多小 items 主要要求 metadata/index/pagination 不全量驻留；
单个大 representation 的 range/stream 才可能要求 app-owned blob depot。**P3/blob 不是
取消 count cap 的必经前置**。正确顺序是先测量和约束 in-flight，再消除四大 O(N)，
最后只在 G8/range/stream trigger 成立时引入 blob medium。

## 2. 现在有哪些层、哪些不是层

| 现有机制 | 当前事实 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| SwiftData `HistoryItemRow` | `canonicalBlob`、`revisionStateBlob` 标为 `.externalStorage` ([`Schema.swift`](../../../Sources/HistoryStorage/Schema.swift#L43)) | durable model 属性仍由唯一 History authority 管理；placement 对业务语义透明 | stable blob path、range read、streaming、明确的 inline threshold、RAM eviction |
| recent browse | scalar `propertiesToFetch`，page limit + lookahead ([`HistoryAuthority+RecentReads.swift`](../../../Sources/HistoryStorage/HistoryAuthority+RecentReads.swift#L198)) | Swift 代码没有主动 decode content blobs；正常页大小有界 | Apple 永久保证 external blob 不发生 I/O；同日期 tie fallback 永不全取 |
| exact tie fallback | 最坏 materialize 5,000 个 scalar `HistoryItemRow`；selector/最终 best rows 才是 page-bounded ([`HistoryAuthorityReadRows.swift`](../../../Sources/HistoryStorage/HistoryAuthorityReadRows.swift#L266)) | 在 5,000 hard cap 下避免把所有行再投影成最终 DTO | 该 fetch/RSS 在取消 5,000 后仍有界 |
| Signature Index | Authority 生命周期内完整保留 postings、reverse map、ID set ([`SignatureIndex.swift`](../../../Sources/HistoryStorage/SignatureIndex.swift#L69)) | capture dedup candidate lookup 加速；fingerprint 后仍 byte-exact confirmation | byte budget、LRU、分片、cold lookup、N 无关的 startup RSS |
| search | 每次读取所有 retained scalar projections，建立完整 `SearchCorpusSnapshot` ([`HistoryAuthority+SearchCorpus.swift`](../../../Sources/HistoryStorage/HistoryAuthority+SearchCorpus.swift#L116), [`RevisionPreparationAndSearchCorpus.swift`](../../../Sources/HistoryStorage/RevisionPreparationAndSearchCorpus.swift#L59)) | content blobs 不必参与 search；5,000 内算法语义完整 | 大历史下有界驻留或低延迟；当前 admission probe 明确记录 5,000 × 256 KiB corpus ([`AdmissionProbes.swift`](../../../Sources/HistoryPerfRunner/AdmissionProbes.swift#L99)) |
| RetainedBytesRow | 保存 Canonical/revision 的 logical byte scalars ([`RetentionSchema.swift`](../../../Sources/HistoryStorage/RetentionSchema.swift#L90)) | R2/R3 不必为每个正常 item decode大 blob | SQLite/WAL/external files/cache/staging 的 physical bytes；RSS |
| details/paste | fetch 一个 item 后完整 hydrate Canonical 与全部 revision lineage，再返回完整 `Data` ([`HistoryAuthority+DetailAndThumbnail.swift`](../../../Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift#L9), [`HistoryAuthority+DetailAndThumbnail.swift`](../../../Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift#L89)) | 工作量不随 retained item count 直接增加；返回 byte-exact Effective Content | 一个 item 内按 representation/range/stream 读取；峰值只等于目标 representation |
| thumbnail service | 同 exact key 的 source+decode single-flight；完成结果不由 Storage 保留 ([`ThumbnailService.swift`](../../../Sources/HistoryStorage/ThumbnailService.swift#L67)) | 同 key 并发 caller 不重复 source/decode | 不同 key 的全局并发 byte/decoder bound；source 只取选中的 representation |
| thumbnail display store | entry/decoded-byte 双界限，超限 whole reset ([`ThumbnailStore.swift`](../../../Sources/PresentationUI/ThumbnailStore.swift#L74), [`ThumbnailStoreTests.swift`](../../../Tests/PresentationUITests/ThumbnailStoreTests.swift#L159)) | 一个 surface 的已完成 decoded bitmap 不无限增长 | LRU 命中质量、in-flight 峰值、整个 app 的 resident limit |
| UI pagination | `loadNextPage` 把下一页 append 到 `rows` ([`HistoryViewState.swift`](../../../Sources/PresentationUI/HistoryViewState.swift#L164)) | 每次网络式请求有 page bound | 长时间滚动后的 UI window bound；无 count cap 时会累计全部已访问 row DTO |
| V2-06 P3 | 现有文档中的 blob handle/streaming graft 仍标为 design-consolidated、proof pending ([`V2-06-platform-grafts.md`](../../../docs/v2/V2-06-platform-grafts.md#L1)) | 已识别 `.externalStorage` opacity 与 streaming 方向 | 当前实现已经有 blob store、stream、lease、GC 或生产证据 |

Apple 对 `.externalStorage` 的公开描述只保证把值作为 binary data 放在 model storage
旁边；它没有公开 stable URL、range/stream 或 eviction API
([Apple `externalStorage`](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage))。
因此把它称为“自动冷存储层”会超过证据。

## 3. 必须拆开的四种 bytes

这是本方向最先要冻结的 ubiquitous language。任何名为 `storageBytes`、`maxBytes` 或
“占用”的字段，都必须明确属于以下哪一个平面。

### 3.1 Logical retained bytes

用户历史语义上的 payload：Canonical representations 加存储的 revision
representations。当前 `StorageRetention.maxTotalBytes` 就是这个定义
([`RetentionPolicies.swift`](../../../Sources/HistoryCore/RetentionPolicies.swift#L61))。

它适合回答：哪些 unpinned items 因用户 retention policy 被永久淘汰。它不应随着
SQLite page size、APFS clone 或 thumbnail cache 改变。

按当前独立上限相乘，5,000 ×（128 MiB Canonical + 256 MiB revisions）=
2,013,265,920,000 bytes ≈ 1.831 TiB logical payload；这只是可接受值域的结构上界，不是物理磁盘
reservation、可执行RSS上界或已测规模。

### 3.2 Physical store bytes

实际设备占用：SwiftData store family、WAL/SHM、app-owned blobs、staging、orphan、
journal/checkpoint、filesystem allocated blocks。`fileSize` 与 `fileAllocatedSize` 本身
也不是同一指标；部分 resource values 还可能不可用
([Apple `URLResourceValues`](https://developer.apple.com/documentation/foundation/urlresourcevalues))。

它适合回答：是否还能安全写入、是否要先清 derived artifacts、是否低于 volume
reserve。它不是用户 retention receipt。

### 3.3 Derived cache bytes

可以从 durable source 重建的 thumbnails、static previews、search/materialization
artifacts。它们可以 aggressive eviction，并可作为 `Library/Caches`/backup-exclusion 的候选；删除后不能
改变 browse/details/paste 的语义。Apple链接只支持iCloud Backup/data-location guidance，不直接定义
Time Machine/local snapshots；最终macOS include/exclude需另行signed验证
([Apple backup/data-location guidance](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup))。

### 3.4 Resident/transient bytes

进程当前拥有或正在使用的 source buffers、`Data` copies、decoded pixels、renderer
workspace、streams、row DTO、search heap、in-flight capture。它需要 hard admission
permits 和并发限制；completed-cache 上限不能替代它。

四者的关系不是简单相等：一个 20 MiB PNG 的 logical bytes 可能对应不同 physical
allocated bytes，decode 后可能占 200 MiB resident pixels，而 thumbnail derived cache
只保留几百 KiB。UI 必须分开命名，telemetry 必须分别报告；不得把 R2 的 logical
数字标成“磁盘限制”或“内存限制”。

## 4. 为什么 5,000 不是“差一个常量”的无限

固定 5,000 是多个完整性证明和复杂度上界的一部分，不只是设置页最大值：

- `HistoryLimits.standard.hardMaximumRetainedItems == 5_000`，生产只使用该固定 profile
  ([`Limits.swift`](../../../Sources/HistoryCore/Limits.swift#L38),
  [`Limits.swift`](../../../Sources/HistoryCore/Limits.swift#L200))；
- startup 获取所有 retained signature metadata 并构建完整内存 index
  ([`HistoryAuthority.swift`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L449))；
- capture 先取完整 retention inventory，并把完整 retained ID set 与 Signature Index
  coverage 对齐 ([`FactLoaders.swift`](../../../Sources/HistoryStorage/FactLoaders.swift#L247))；
- search 每次形成全语料 value snapshot
  ([`HistoryAuthority+SearchCorpus.swift`](../../../Sources/HistoryStorage/HistoryAuthority+SearchCorpus.swift#L116))；
- retention policy sweep 取得全 inventory 与全 `RetainedBytesRow` scalars；所有超过 R3
  的 item 还会逐个完整 hydrate lineage
  ([`RetentionPolicySweep.swift`](../../../Sources/HistoryStorage/RetentionPolicySweep.swift#L158),
  [`RetentionPolicySweep.swift`](../../../Sources/HistoryStorage/RetentionPolicySweep.swift#L187))；
- migration backfill 一次 fetch 所有 items、建立完整 ID/dictionary/computed arrays，并在
  写前 decode 每个 item 的 Canonical/revision blobs
  ([`RetainedBytesBackfill.swift`](../../../Sources/HistoryStorage/RetainedBytesBackfill.swift#L94),
  [`RetainedBytesBackfill.swift`](../../../Sources/HistoryStorage/RetainedBytesBackfill.swift#L176))；
- UI 的 next-page path 不做双向窗口，已访问页持续 append
  ([`HistoryViewState.swift`](../../../Sources/PresentationUI/HistoryViewState.swift#L164))。

仅把 5,000 改为 `Int.max` 会同时放大启动驻留、每次 capture 的 O(N) 扫描、search
snapshot、policy sweep、migration 与 UI 累积。它既不能形成无限历史，也可能把单次
copy 变成随历史增长而越来越慢的操作。

### 4.1 解除 5,000 前必须先转型的四大 O(N)

按优先级，前四个 blocker 必须在允许 `count = nil` 前关闭：

1. **Dedup/startup：**用 durable、可索引的 signature candidate projection 按 incoming
   signature 查询；取消“完整 process-wide Signature Index 是 correctness 前提”。仍然
   对候选做 byte-exact confirmation，fingerprint 永远不是 identity。
2. **Capture/retention admission：**把 retained count、logical bytes、oldest eligible
   cursor 等变成同 History transaction 更新的 durable aggregates/indexed victim
   queries；capture 不再 materialize complete inventory。
3. **Search：**exact search 先变为 store-index/candidate query；fuzzy/regexp 采用
   bounded batches + top-K，或明确限定 scope。不能把完整 `SearchCorpusSnapshot` 换成
   batch iterator后就宣称复杂度已解决：CPU/I/O 仍可能 O(N)。
4. **Policy sweep：**以 durable cursor 和 bounded victim/prune batches 推进；每批的
   History-visible原子语义、position 规则和最终 receipt 必须先裁决。若产品坚持“一次
   action = 一个原子大 sweep”，则必须用外部 plan/spool 保持 resident bounded，并接受
   transaction/lock 时间风险。

V2-06 P1当前设计的`StartupCheckpointRow.indexBlob`会恢复完整in-memory `SignatureIndex`，适合5k capped
regime的启动优化，却与本节U-scale resident-bound目标不兼容。`DEC-U-SCALE-STARTUP-INDEX`必须在实现
`PLAY-COUNT-1`前修订owning P1：选择durable sharded/index-query + bounded cache，或明确hot window并提供
authoritative exact fallback；不能先落complete checkpoint，再由另一套index并存来“优化”无限历史。

随后还要处理 pin ordinal 全量 compaction/validation、UI row window、GC live-set、
migration 与后台一致性验证。它们不是取消 count cap 的首个 tracer bullet，但都决定
百万级历史能否长期运行。

## 5. 按文件类型动态加载：正确边界

用户目标是正确的，但“按文件类型调度”不应该变成 Storage 认识 PNG、PDF、RTF、HTML、
视频的格式分支。

正确职责是：

- `ClipboardFormats`只提供stable exact facts/family；owner-specific manifests声明该owner是否候选以及
  evidence/profile identity，不直接产访问计划；
- `ContentPreview`等具体behavior owner/renderer结合fixture与实测profile决定需要 header、prefix、random ranges、首帧、完整
  payload 还是根本不读取内容；
- `HistoryStorage` 只按 immutable representation identity、exact content version、
  byte cost、range/sequential shape、priority、deadline/cancellation 交付 opaque bytes；
- PresentationUI、Python gateway、renderer 都不能获得裸 blob file URL，因为 URL 会
  绕过 byte permits、version fence、audit、path confinement 和 lease lifetime。

同样大小、同样 access shape 的未知 UTI 和 PNG 应得到相同的 Storage admission 结果。
未知类型可以永久 raw-preserve，但 Preview 默认只显示 type/size；这证明“格式支持”与
“可靠保存 bytes”没有被错误绑定。

并非所有 decoder 都能真正受益于 range/stream。`FileHandle.read(upToCount:)`、
`FileHandle.bytes` 或 `DispatchIO` 可以提供分块运输
([Apple `FileHandle`](https://developer.apple.com/documentation/foundation/filehandle),
[Apple `DispatchIO`](https://developer.apple.com/documentation/dispatch/dispatchio))，但如果
下游 framework 最终要求完整 `Data`，分块只减少运输中的副本，不能消除最终整体
materialization。每个 renderer 必须通过实际 access trace 与 RSS child test 定级，
不能由 UTI 名称推断。

## 6. Design It Twice：A / B / C

### 方案 A：继续使用 SwiftData aggregate blob，只加 caller-shape/telemetry 与 permits

形状：保留当前 monolithic Canonical/revision codecs 与 `.externalStorage`；先只让caller收到目标
representation并诚实计入aggregate hydration，增加重型操作permits、UI window和局部cache改善。没有G8
trigger时不因此新增History read seam。

优点：迁移少；继续享有 SwiftData 管理 row/property 的现有 durable boundary；适合先减少可证明的
无谓副本、限制whole-item hydration并发，并把其真实成本纳入峰值账本。

硬限制：公开 API 没有 external blob URL/range stream；Canonical/revision 仍是单块
codec，读取一个 representation 很可能仍需取得整个 blob；物理空间、orphan 与
streaming不可控。它最多是“更节制的单层持久化”，不能实现用户要求的真实 tier。

裁决：可作为近期 tracer/characterization；它不是需要真实range/stream的large-content终点，但若G8不触发，
可以长期作为many-small/U-scale的physical layout，不应仅为“层更多”迁移。

### 方案 B：SwiftData metadata + Authority-owned immutable representation blob depot

形状：小 representation 可 inline；大 representation 以 opaque `BlobID`/descriptor
引用 app-owned immutable blob。SwiftData 继续保存 item、ordering、lineage、logical
bytes、references、ChangePosition 与恢复 checkpoint；所有业务写仍通过
`HistoryAuthority`。内容通过 purpose-specific `ContentLease`/bounded reader 打开；
每个消费模块只有在reuse证据批准后才拥有自己的小cache；permit/admission也由各resource owner本地持有，
composition只以各owner ceilings之和与soak约束whole-process envelope，不提供跨owner借额度的god scheduler/
dictionary。

优点：能够真正实现 range/sequential read、明确 byte accounting、staging/publish、
orphan GC、独立 derived cache、磁盘 reserve 与跨 Python/Preview 的相同有界 seam；
Storage 保持 type-opaque。

代价：SwiftData transaction 与 filesystem publish 之间没有一个公开的跨介质原子
事务，需要显式 crash-recovery protocol、迁移、备份整体性和真实 ENOSPC 测试。

裁决：**推荐长期方向**，但只在 P3 证据门触发后从一个 large-representation vertical
slice开始；不得一次性建设通用五层框架。

### 方案 C：B 之上的 hot/warm/cold segments / packfiles

形状：保留方案 B 的 SwiftData metadata、唯一 `HistoryAuthority`、opaque descriptor
和同一 `ContentLease` seam；只替换 depot 的物理布局。新写入先进入小型 immutable hot
segments，后台把稳定 loose blobs 合并为带 versioned manifest/index 的 warm/cold
packfiles；读取按 `BlobID → segment + offset + length` 定位。格式 owner、Preview、UI
和 Python 看不到 loose/segment 差异。

优点：当历史达到 250k/1m 后，可以减少 inode/file-open/directory-enumeration 与大量
loose-file metadata 成本，并让顺序迁移、备份和冷数据扫描具有更好的 I/O locality。
它仍保持 Storage type-opaque，也不要求替换 SwiftData metadata truth。

代价：会新增 segment index/manifest 的publish-generation协议、reader generation lease、删除
tombstone、空间放大、后台 compaction、crash recovery、ENOSPC 双空间以及 backup/GC
coordination。删除一个 logical blob 通常不能立刻回收 packfile 区间；旧 segment 必须等
所有 reader lease 释放后再删。若没有真实 loose-file 瓶颈，这些复杂度只会制造新的
durability surface。

裁决：**不是 B 的首发形状，也不是取消 count cap 的前置。**只有方案 B 已通过
250k/1m correctness + soak，而证据把瓶颈明确归因到 inode 数、directory metadata、
file-open rate、backup enumeration 或 loose-file GC，才允许以一个 cold-compaction
vertical slice 比较 C。C 必须复用 B 的 logical descriptor、lease、permit 与恢复语义，
不能让调用方感知新的 storage backend。

### 明确拒绝：自研统一数据库、替换 SwiftData authority、按格式分库

本轮不把“把 metadata、blob、索引和 cache 全迁入自定义 engine”、自定义 SwiftData
store，或为 image/PDF/text 建独立 persistence tier 列为候选。这些方案会一次替换现有
schema/migration/codec/并发和测试资产，容易形成第二 writer、格式与持久化耦合及 god
cache。Apple 的 custom data store 只是扩展点，不自动提供 Clipy 所需的 transaction、
stream、GC、migration 或 recovery 语义
([WWDC24: Create a custom data store with SwiftData](https://developer.apple.com/videos/play/wwdc2024/10138/))。

若 B 与 evidence-gated C 都无法满足明确 SLO，必须重新做独立架构审查，而不是把这类
方案悄悄升级为默认终点。

## 7. 推荐的长期模块形状

```text
HistoryAuthority（唯一业务写 authority）
├── MetadataStore / SwiftData
│   ├── item、ordering、occurrence、ContentVersion
│   ├── representation descriptor / BlobID reference
│   ├── logical-byte aggregate、ref/ownership state
│   └── ChangePosition、migration/GC checkpoints
├── ContentDepot（HistoryStorage package/internal；仅 G8/P3 admission 后）
│   ├── stage → validate → immutable publish
│   ├── open exact representation/range/stream
│   └── bounded reconciliation / orphan GC
└── HistoryStorage source admission（source/blob read permits；不拥有 decoder/UI cache）

clipboard-flow owner ───── current AppComposition；获批后才可提取ClipboardFlow；acquisition/pending permits
ContentPreview ──────────── renderer concurrency/output permits；derived artifact cache仅在独立reuse gate后加入
ThumbnailService/Store ─── source/version fence + decoder permits / Presentation display cache
Search owner ────────────── bounded query/index working set（若证据批准）

ClipboardFormats stable facts + owner manifest/profile
└── concrete behavior owner/renderer：purpose + format → empirical access plan（不直接持有 History 或 ContentLease）
```

这些 owner 可复用同一套 checked reservation arithmetic，或各自持有很小的
`TransientPermitPool`，但首版不建立能调度所有 workload 的全局 scheduler。whole-process envelope 由
批准 cap 的总和与 `PLAY-SOAK-*` 实测验证；一个 owner 的空闲预算不会自动变成另一个 owner 的授权。
row thumbnail 继续由 HistoryStorage 负责 source/version fence、由 PresentationUI 负责 display retention，
不能为了复用 Preview renderer 而把 thumbnail cache 塞进 Authority 或 `ContentPreview`；Preview cache也不是
P3默认产物，只有owner-specific reuse/latency证据后才准入。

### 7.1 应暴露的 seam，不应暴露的实现

内容读取必须分两个阶段，不得把未来 lease 倒灌到当前 target graph：

1. **G8 前：**`PreviewContentLoader` 继续调用现有 `details`，在 operation/task 内短暂拥有并计量完整
   immutable snapshot；`ContentPreview` 只在该 snapshot 内选择并解码，不读 History。禁止的是把完整
   source 留进 SwiftUI observable/process-lifetime state；这条过渡路径不证明 physical on-demand I/O。
2. **G8 后：**先由 ADR 冻结 `descriptor → concrete behavior-owner access plan → HistoryCore purpose-read →
   Authority exact-reference/budget validation → bounded immutable renderer input`。internal depot lease/open
   descriptor 不跨 target；若确需 cross-target stream，必须先批准 Foundation-only `HistoryCore` interface，
   不能让 `ContentPreview` import `HistoryStorage`。

未来获批的行为接口只表达：

- exact `HistoryItemReference` / representation locator；
- purpose：paste、manual preview、row thumbnail、export、Python read；
- requested shape：metadata-only、prefix、ranges、sequential full stream；
- maximum return/chunk bytes、priority、deadline/cancellation；
- typed stale/missing/corrupt/over-budget/unavailable 结果；仅 HistoryStorage 内部实现可见的
  `ContentLease` 生命周期；
- content-free telemetry：active permits、charged bytes、cache bytes、GC backlog、physical
  categories 和 high-water。

接口不应暴露：

- inline/blob 的 enum 给 UI 或 Python；
- file path、`FileHandle`、SwiftData model/context；
- cache dictionary/node 或 GC implementation；
- PNG/PDF/RTF 特有方法；
- 一个可被各模块任意操作的 `GlobalStorageManager`。

internal `ContentLease` 的核心价值不是漂亮地包装 stream，而是让 source buffer、file
descriptor、permit 与 cancellation 共享一个确定的 release lifetime。success、throw、
cancel 和 consumer 提前停止四条路径都必须归还 charge。

但 hard resident budget 只能约束 Clipy 仍拥有的 cache、buffer、permit 和 renderer
workspace。若接口返回普通 `Data`，caller 可以在 lease 结束后无限期持有它；Storage
不能据此承诺整个进程 RSS 上限。需要完整 `Data` 的 lane 要把 caller-owned output另列
为可观测但非 Storage 可强制回收的 charge，或让消费发生在 lease closure/stream 内。

### 7.2 避免 god cache

不要建一个同时保存 raw bytes、decoded images、HTML layout、PDF pages、search results
和 Python export 的中央 LRU。它会让 key、cost、privacy purge、priority 与线程约束互相
污染。

推荐：

- 每个 owner 的 `TransientPermitPool` 只核发其负责资源的 weighted permits，不拥有 cached values；
- 若以后批准 raw encoded content cache，它与 Preview artifact cache、row thumbnail
  store 分属各自 owner；
- 每个 cache 有独立 exact key、byte/count budget、cache law 和 purge policy；
- 只有 owner-specific reuse/hit-rate trace 证明值得时，才采用可证明的 size-aware LRU；没有复用证据时
  正确 Green 可以是“不缓存”。single entry 超 cache budget 时只能在取得 transient
  permit 后 serve-without-retain；超过 resident budget 则必须 stream 或 typed reject；
- sequential scans 默认 bypass/probation，避免污染 interactive hot set；
- workload 证明 LRU thrash 后再升级 segmented LRU/2Q。

更保守的第一版应当**没有共享 raw resident cache**：使用 OS file cache + bounded reader，
大流顺序 bypass，只缓存已经被现有产品路径证明有重用价值的小 whole blobs/derived
artifacts。只有 hit-rate/latency trace 证明值得，才增加 raw weighted LRU。若以后缓存
ranges，也先使用 fixed chunks；任意区间 cache 容易碎片化、重叠计费和形成不可审计
的 key。

不能用 `NSCache.totalCostLimit` 证明硬预算：Apple 明确说它不是严格上限，淘汰时机和
顺序都不保证
([Apple `totalCostLimit`](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit),
[Apple `countLimit`](https://developer.apple.com/documentation/foundation/nscache/countlimit))。
它可以作为可丢弃便利层，不能替代 permits 和自有计费。

## 8. Capture acquisition 是特殊边界

即使 Storage 明天支持 chunked blob write，当前 pasteboard freeze 仍会先在 MainActor
调用每个 type 的 `data(forType:)`，形成完整 `Data`，然后把所有 representations 放进
`ClipboardCapture`
([`PasteboardAdapter.swift`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L78),
[`PasteboardAdapter.swift`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L115))。

这意味着：

- storage-side streaming **不能追溯消除** AppKit provider 已经产生的完整 `Data`；
- capture 128 MiB 是 admission bound，不是进程峰值；读取时的 provider/AppKit copy、
  active capture、pending capture 和 blob staging 可能重叠；
- `data(forType:)` 调用前通常不知道 provider 最终返回多少 bytes；acquisition admission
  只能先按批准的 worst-case/concurrency slot reserve，读取后再按实际 bytes 校准。它能
  限制 Clipy 同时发起的重读取，不能把 AppKit/provider 的未知临时分配变成 hard RSS
  guarantee；
- 多种 representation 同时冻结时，必须计算 aggregate acquired bytes；
- provider timeout/owner change/partial freeze 的语义必须先于 spool，不能为了 streaming
  把不完整 observation 提交为完整历史；当前 adapter 记录 declared-but-unavailable
  types，但仍只处理 first pasteboard item
  ([`PasteboardAdapter.swift`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L82))。

因此 capture 需要单独的阶段化设计：

1. MainActor 同步建立 pasteboard owner/change-count fence 与 metadata snapshot；
2. 在调用 `data(forType:)` 前先取得 worst-case acquisition slot；读取后执行实际 byte
   admission，失败则立即释放/拒绝；
3. 小内容形成 bounded immutable value，大内容尽早 spool 到 private staging；
4. complete freeze 后才交给 preparation/Authority；partial/superseded/oversize 明确失败；
5. active + bounded pending policy 控制同时存在的 captures；
6. commit/abort 后由同一 owner 释放 staging 与 permits。

但 Apple 的 pasteboard object/provider API 是否允许避免 `data(forType:)` 的完整
materialization、changeCount 在长 freeze 中如何 fencing，必须由 signed macOS experiment
决定；在此之前不要承诺 capture path 也能真正 stream。即使最终不能 stream，仍可通过
“一次只准一个重 capture + 一个有界 pending”、尽早 spool 与拒绝过大并发降低峰值。
在 provider-size 与临时复制证据出来前，只能说并发受控，不能说 capture RSS 有硬上限。

## 9. P3 当前裁决：design-only，先纠正再 admission

仓库已经有 V2-06 P3 设计，目标是 blob handle/streaming；文档自身明确状态是
“design-consolidated, scaffold proof pending”，并要求 evidence trigger
([`V2-06-platform-grafts.md`](../../../docs/v2/V2-06-platform-grafts.md#L1),
[`V2-00-overview.md`](../../../docs/v2/V2-00-overview.md#L92))。当前 review 不把它当已实现
能力。

P3 admission 前还应重新裁决：

- 不以“保留旧 `bytes: Data` public surface”为理由让大内容默认仍完整 materialize；
  purpose-specific content source 应是主路径，legacy full-Data 是有明确 hard bound 的
  compatibility lane；
- stream-open version fence、mid-stream revision/delete、consumer early-stop 与 end-of-stream
  integrity各有什么保证；
- whole-file digest 在 stream结束前无法证明，因而是 fail-late。必须按 purpose裁决：用
  authenticated fixed chunks、先完整 prepass再交付，或让有外部副作用的 consumer先写
  private staging并在 end verification 后才 publish/commit；不能边验证边把未认证 bytes
  写入 pasteboard或外部目标后仍称 fail closed；
- `FileHandle.AsyncBytes` 不是自动 chunk-size/RSS proof；必要时由 actor-confined repeated
  `read(upToCount:)` adapter 提供明确 chunk shape；
- in-flight blob 不能只靠 volatile set + elapsed grace 防止 GC；crash/restart需要 durable
  staging/ownership state或一个能证明安全的 publish namespace；
- GC 不得每次扫描全部 retained rows 构造 live-path set；超大历史需要 durable ownership/
  reference metadata 和 bounded cursor；
- migration 不应默认一次 eager decode/rewrite整库；需要 dual-read + resumable bounded
  batches，除非真实最大 store 证据证明 eager 仍满足启动、RSS和临时双倍磁盘预算；
- public seam 不应直接 vended file handle/path；应是 cancellation-aware、Sendable、
  budgeted lease/stream adapter。
- 不无审查继承旧草案中“`nil` 同时表示 inline 与 stale”的 public streaming contract；
  两者的恢复动作不同，必须是 closed typed outcome。旧草案允许 age-out in-flight 后把
  慢 commit 变成 dangling handle 的 residual 也不能批准为正常边界；它必须由 durable
  ownership/reconciliation 消除。

这些是设计纠偏，不是要求立即实现 P3。正确顺序仍是 characterization → trigger →
一个 representation vertical slice → crash/ENOSPC/migration proof → 扩展。

## 10. Durability、GC、磁盘、备份与安全

### 10.1 可恢复 publish protocol

推荐状态机：

`absent → staged temp → published unreferenced → referenced by committed row → garbage`

SwiftData 与 app-owned file 没有公开跨介质 transaction，所以正确目标是可恢复，不是
伪装原子：

1. 在 private staging 以随机、不可猜测 `BlobID` 写入，校验 length 与强完整性摘要；
2. 在同卷执行immutable publish；只把通过指定macOS/filesystem的process-kill/reopen matrix支持的行为称为
   crash-recoverable，不把它称为fsync/power-loss durable。此时文件可能是 orphan，但业务不可见；
3. 唯一 `HistoryAuthority` transaction 写 descriptor/reference、logical bytes、History
   mutation 与 ChangePosition；
4. commit 失败时 published blob 保持 unreferenced，交 bounded GC；
5. delete 先 transactionally 移除 reference，commit 后才允许 unlink；
6. reopen 只读取 O(1)/bounded checkpoint并发布可用 facade；reconciliation 通过 bounded
   background cursor 和 on-access validation 幂等处理 staging/orphan，不能为了 blob
   完整性在 cold open全盘扫描。发现 missing/corrupt referenced blob 默认使受影响的
   representation/item typed-fail；只有 metadata/ownership invariant 无法确定边界时才
   升级为 whole-facade open failure，二者必须由规格分别列举。

当前 xxh3 fingerprint 是 dedup evidence，不是 identity；不能直接把它当唯一 BlobID。
同 bytes 的 physical dedup 若以后需要，必须强 digest + byte confirmation + refcount/crash
协议独立 admission。

这里还有三条 correctness fence：

- “验证 current version → 获得不会被 GC 回收的已打开 source”不能被一个任意 `await` 切开。
  合法实现二选一：在无 suspension 的 serialized Authority interval 内验证并同步打开 descriptor；
  或先在同一 owner 登记 GC 可见的 process-local read reservation，再释放 interval、异步打开，失败时
  exactly-once 归还。GC 只能删除既无 committed reference、又无 live reservation/open descriptor 的 source。
  文件采用 root-relative no-follow open，随后 `fstat` 校验实际 descriptor 的 root/identity/type/length；
  只做字符串 canonicalization 或 open 前 pathname check 仍有 TOCTOU；
- GC 的正确性不能依赖“超过 grace period 就假设写 transaction 已结束”。慢 commit
  没有可证明的时间上限；只有 durable ownership state或 Authority 明确 commit/abort 的
  generation 才能让文件进入可回收集合；
- 若保存 refcount，它只能是与 authoritative representation references 同 transaction
  维护、并可重建验证的 projection。GC 的最终 live truth 是 committed references，不是
  一个可能漂移的独立 cache counter。
- GC 的 batch bound 同时覆盖 filesystem enumeration；blob namespace需要 shard/cursor，
  不能先把整个目录文件名装入数组再宣称“每轮只删除 N 个”。

### 10.2 ENOSPC 与 disk reserve

Apple 建议大写入前查询 important/opportunistic capacity，并说明查询可能失败；Apple没有定义这次
查询形成 reservation。把结果只当瞬时 preflight、并继续处理竞争、quota、volume变化与真实ENOSPC，
是 Clipy 的工程推断，必须由负载实验支持
([Apple volume capacity](https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity))。
这些 volume-capacity keys列在Disk Space required-reason分类中，但Apple当前Privacy Manifest总览列出的
`NSPrivacyAccessedAPITypes`申报平台不含macOS；对本项目macOS-only target，不能断言已有文档化的
`PrivacyInfo.xcprivacy`申报义务。仍应在最终Xcode/签名artifact检查warning与政策变化；若未来增加被列明
平台，再按获批reason申报
([Apple privacy manifest overview](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files))。

推荐顺序：

1. 清理已过期 derived cache；
2. 清理已证明 unreferenced 的 staging/orphans；
3. 在已证明同一 `StoreRoot` 只有一个进程 writer 的前提下，取得 process-local write reservation并做
   advisory capacity preflight；若产品允许第二实例/进程，共享卷配额必须另有跨进程协调，不能把
   process-local counter 当 reservation；
4. 真实处理 create/write/sync/rename/DB commit 各阶段的 ENOSPC；
5. 仍不足时 typed reject 新 capture，原 History state/position 不变；
6. 默认不自动删除 pinned 或 durable history。若需要 emergency oldest-unpinned cleanup，
   必须是用户明确 opt-in retention policy。

### 10.3 物理删除不等于磁盘立即缩小

删除 row/blob 后可以立即承诺“语义不可见、引用已移除”；SQLite/WAL/APFS allocated bytes何时回收是
`UNKNOWN`，只能测量，不能由QA1809推出。QA1809只支持另一条较窄结论：Core Data/SQLite WAL场景中只
复制主文件可能不完整
([Apple QA1809](https://developer.apple.com/library/archive/qa/qa1809/_index.html))。
维护页应分别展示 logical content、derived cache 和测得的 store-family allocation，并
标明 measurement unavailable/lagging。

### 10.4 备份与安全

- durable Canonical/revisions 不可由 Clipy 重建，默认不应因体积大而放进 purgeable
  Caches；derived Preview/thumbnails 可以；
- app-owned blobs、metadata store、references 与 recovery manifests 必须作为一个 backup/
  quarantine unit；漏掉任何一部分会形成 dangling reference。备份/恢复与 GC 还需要
  coordination/checkpoint：复制 metadata/WAL 与 blobs 的不同时刻快照仍可能不一致；
- 是否把敏感 clipboard history纳入系统备份是产品/隐私决策，不能由目录默认值偷偷
  决定；
- blob root 必须 private、路径 confined、拒绝 absolute/`..`/symlink escape；
- `0700` directory / `0600` file 只能隔离其他用户，不能阻止 hostile same-UID Python
  直接读取 app-owned root。若 threat model包含同 UID恶意进程，必须另做 sandbox、
  credential/authorization、encryption/key custody 与签名 helper取舍；Unix permissions
  不能被写成充分防线；
- telemetry、GC log、lease diagnostics 只能含 IDs、counts、bytes、latency与 reason，
  不含 title、query、UTI payload 或内容摘要；
- secure deletion 不能因调用 `unlink` 就承诺物理介质不可恢复，尤其 APFS snapshot/
  backup/WAL 下。产品最多承诺应用语义删除，并准确披露备份与系统层残留边界。
- encryption at rest、Keychain ownership、key rotation、旧备份和 secure delete 属于独立
  threat model；本地 immutable blob 的引入既不自动加密，也不应顺带承诺这些能力。

## 11. Maccy 对比：借鉴机制，不复制总体模型

当前对照 Maccy 有两个值得借鉴的局部点：

- `MemoryGovernor` 监听 `DispatchSourceMemoryPressure`，释放非可见 decorator 的 transient
  images并清 app icon cache
  ([`MemoryGovernance.swift`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Observables/MemoryGovernance.swift#L63))；
- visibility-based release 把 decoded images 与 viewport 生命周期关联，而不是默认做共享
  completed-image cache
  ([`MemoryGovernance.swift`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Observables/MemoryGovernance.swift#L3))。

但 Maccy 不是 Clipy“无限历史”的 storage 蓝图：

- `History.load()` 的 projection 会 `fetchAll`、decorate、按 `Defaults[.size]` 删除 overflow
  ([`HistoryStoreProjector.swift`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Observables/HistoryStoreProjector.swift#L43))；
- `HistoryListState` 长期保存 complete `all` decorator array
  ([`HistoryListState.swift`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Observables/HistoryListState.swift#L4))；
- search actor 长期保存全 corpus dictionary/order
  ([`SearchActor.swift`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Search/SearchActor.swift#L31))；
- `Storage.size` 只读取主 store URL 的 `fileSize`，不能代表完整 store family 或 physical
  allocated bytes
  ([`Storage.swift`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Storage.swift#L16))。

结论：可以借鉴 viewport release、pressure purge 与 app-icon cache 的 owner locality；
不能倒退到“启动 fetch all + 主线程完整 decorator graph + count trim”的模型。

## 12. 抽象 TDD 路线

所有测试先证明行为，再抽 module。真实 persistence 语义继续使用真实
`SwiftDataHistory`；fault injection 只能替代具体 filesystem failure，不能创造第二个
writer implementation。

本节的 `DESIGN-TIER-*` 是设计 epic/crosswalk，不是可直接标记完成的行为卡；真正执行必须映射到
[`04-tdd-remediation-playbook.md`](04-tdd-remediation-playbook.md) 的一个或多个 `PLAY-*` Red。Phase 0
是 characterization，不能因为尚无批准阈值而称 Red；P3 phases 在 owning spec amendment 与 G8
admission record 前统一为 `BLOCKED-SPEC`/`BLOCKED-G8`。

### Test lanes

- `PURE`：budget、admission、LRU、placement、reservation、GC state machine；
- `MEM`：真实 `SwiftDataHistory(.memory)`，证明语义和 exact-version fence；
- `DISK-CHILD`：临时 on-disk store，独立进程 kill/reopen；
- `PERF`：独立进程 RSS/dirty-memory、latency与规模斜率；
- `SIGNED`：真实 app container、backup flags、entitlements、正式版本升级与 Python/helper
  并发；
- `SOAK`：长时间 churn、pressure、ENOSPC、kill、restart、GC。

### Phase 0：characterization，不冻结缺陷

**DESIGN-TIER-CHAR-1：四类 bytes 可观测**

- Characterization：同一 run 分别报告 logical、physical/store-family、derived cache、resident/
  in-flight high-water；只增加 content-free measurement receipt/signposts；
- 记录要求：每条记录带 schema、fixture digest、OS build、机器类别。没有这些元数据的
  数字不进入 gate。

**DESIGN-TIER-CHAR-2：当前 hydration map**

- 以接近 hard limit 的 canonical/revisions 分别执行 browse、details、paste、thumbnail、
  search、R3 sweep；
- 记录 opened representations、hydrated bytes、copies、RSS、decoder output；
- 证明“browse 不主动 decode”与“details/paste/thumbnail 当前完整 hydrate一个 item”分别
  成立，不用 source-level counter 冒充 framework RSS proof。

**DESIGN-TIER-CHAR-3：当前 cache/viewport行为**

- characterise thumbnail whole reset、late completion after reset、negative entries；
- 连续加载 100 页，记录 `HistoryViewState.rows` 曲线；
- 不把现有 whole reset 或 unbounded row append 写成永久期望。

### Phase 1：先建立语言和最窄 seam

**DESIGN-TIER-1：预算配置是四维的**

- Red：零/负数、overflow 或把 logical 与 resident budget 混填必须拒绝；
- Green：独立 safety limits、logical retention、physical reserve、cache budgets、resident/
  in-flight budgets；
- Refactor：同一个字段不跨维度复用。

**DESIGN-TIER-2A：caller-visible purpose shape（方案 A）**

- caller 只收到 exact item/version 的目标 representation，旧 `ContentVersion` 返回 typed stale；
- instrumentation 必须把当前 monolithic codec 为选择目标而整体 hydrate 的 aggregate bytes 全部记账；
- 这不允许宣称 physical single-representation/range read。

**DESIGN-TIER-2B：physical purpose read（方案 B / `BLOCKED-SPEC` / `BLOCKED-G8`）**

- source receipt/File Activity 证明只打开目标 representation/range 加批准 overhead；整块读后切片是假绿；
- Storage 不知道 UTI family；unknown UTI 与 PNG 在同 empirical cost/shape 下 admission 相同；
- 仅在 representation layout/V2-06 P3 amendment 与 G8 admission 后建立最小 storage-facing seam。

**DESIGN-TIER-3：metadata-only page**

- Red：browse 一页的 opened content bytes 必须为 0，fetched scalar rows ≤ limit + approved
  overhead；
- Green：修正意外 hydration/tie path；
- Hosted：用大小 blobs 的同 row-count stores 比较 I/O/RSS。只能把结论限定到测试的
  OS/query shape。

### Phase 2：resident permits 先于 completed cache

**DESIGN-TIER-4：weighted permits**

- 并发已批准 charge 总和不超过预算；
- 单请求大于预算立即 `.requiresStreaming`/typed refusal，不永久排队；
- success/throw/cancel/early-stop 都归还 source/workspace/output charges；
- interactive paste/manual Preview 可优先于尚未开始的 prefetch；
- input、decoder workspace、output 同时存在时分别计费；需要多类 permits 的 operation
  必须一次原子 reserve worst-case，或按全局固定顺序取得并在失败时全部释放/公平重试；
  禁止持有 A 等 B 形成 hold-and-wait deadlock/starvation；
- renderer concurrency 也有独立 bound。native decoder workspace若无法在 API层预知，只能
  以 conservative reservation + child-process RSS envelope约束，不能伪造成精确 charge。

**DESIGN-TIER-5：pressure**

- 注入 normal/warning/critical；warning 清 cold unleased artifacts，critical 清所有可重建
  idle cache并暂停 heavy prefetch；
- pressure burst 不生成无界 Tasks；
- 已在写 pasteboard 的操作不因晚到 pressure 被虚报为未完成；
- hosted lane 再证明真实 `DispatchSourceMemoryPressure` delivery。Apple 只提供 pressure
  signal，不保证替应用释放框架内存
  ([Apple `DispatchSourceMemoryPressure`](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure))。

### Phase 3：局部 weighted LRU

**DESIGN-TIER-6：cache law**

- budget 8，插入 cost 3/3/3，只淘汰最旧 unleased entry；
- touch B 后插入 D，淘汰 C 而不是 B；
- 单 artifact 超 budget 可供当前 caller 使用但不 retain；
- key 至少含 exact representation/content version、range/intent、renderer recipe/extent；
- hit/miss/disabled/evicted 的 payload或 typed failure 等价；
- item remove、clear 或 content-version change 后，相关 app-owned content cache 必须收到 deterministic
  invalidation并在返回前使相关 entry不可再命中；connection revoke 只清该 connection/session 的
  export/read artifacts 与 authorization state，不能为此清空无关全局 UI/thumbnail cache。physical buffer释放可以异步，但不能
  只依赖 best-effort pressure/TTL。进程崩溃后的 derived disk cache由 versioned key和
  reopen reconciliation保证不可复活；durable correctness仍不依赖 cache。

整个 epic 也需要具体 owner 的 reuse/hit-rate/latency trace；没有证据时“不缓存”是合法结果。只有真实
trace显示复用价值才引入该 owner 的 LRU，显示 scan pollution/thrash 才新增 probation/2Q Red；不先实现
generic raw cache或复杂算法。

### Phase 4：U-scale——先解除四大 O(N)，再允许 count disabled

这条主线只需要 metadata/index/pagination 改造；**不得为了完成它提前实现 P3/blob**。

**DESIGN-TIER-7：四大 O(N) tracer**

- capture只查询匹配 signature candidates，forced collision仍 byte-exact确认；
- cold open只读 O(1)/bounded checkpoint，不扫描完整 signature metadata；后台验证有 durable
  cursor，且不阻塞 first page；
- fresh cold open 后第一次 same-content capture（含 forced collision fixture）仍正确 coalesce，不能用
  “尚未加载 index”换取启动常数；
- recent first page fetched rows近似常数；
- exact/fuzzy/regexp 各有独立 scope、ranking-equivalence、cancellation 和 p95 gate；任何 mode 都不以
  构造全语料 snapshot 为前提；
- retention sweep按 bounded cursor推进，aggregate在 capture/revise/remove/crash 后与重算
  oracle一致。

**DESIGN-TIER-8：UI/pin/validation follow-through**

- 滚动 20,000 rows 后 UI retained row/window不增长；
- cursor 在连续 writes/revisions/retirements 下仍满足 snapshot/restart 语义，不漏页、不重复作用于 stale row；
- pin move不要求重写所有 ordinals，compaction独立、分批、可恢复；
- validation不随总 item count一次驻留全部 IDs。

这两个epic必须映射到`04`的新tail controls：1C/1D lazy-validation poison、`PLAY-COUNT-2`的k=N
collision storm、3CV/3RV capture/revise victims、5R3/5X R3组合、5D Clear、7A same-timestamp/all-pinned
pagination，以及7B/7C/8A/8B；只让平均candidate/page有界不能关闭U-scale。

**DESIGN-TIER-9：最后才开放 policy surface**

- 在 DESIGN-TIER-7/8 全绿前，`count=nil` 只能存在于 test-only feature gate，production 配置必须拒绝；
- 之后要分别修订两个独立限制：把 user maximum-unpinned policy/action/config 改为可选，以及移除或替代
  `HistoryLimits.hardMaximumRetainedItems`（它还包含 pinned items）；不能只改一个 `nil` 就宣称完成；
- disabled count 不使用 `Int.max` sentinel；
- 第 5,001 item真实入库/分页；
- disabled count 不改变 per-representation safety、disk reserve和typed failure。
- production enable还要求shared `PLAY-DISK-0A/0B/1/2A/3…6`、current-schema migration/backup headroom与逐级
  scale/soak gate闭合；这些不依赖P3。只通过test-only5,001 fixture不能发布；1m scheduled/release
  evidence由`PLAY-COUNT-9C`单列并先关闭，真正production transition才由9A/9B完成。

### Phase 5：条件分支 P3——仅 G8 触发后做一个 blob vertical slice

若 characterization 未触发 G8，这一整 phase 跳过；U-scale主线继续使用方案 A。
进入前必须有正式 G8 admission record，包含 absolute SLO、fixture/build、失败路径、为何方案 A 的更小
修复不足，以及 V2-06/roadmap/AUDIT amendment；没有记录时所有 DESIGN-TIER-10…17 都是 blocked。

**DESIGN-TIER-10：inline/handle placement**

- threshold 下方 inline，threshold 本身走 blob；
- 同一 fixture 经两路读取 byte-exact；
- `.memory` store 不创建 durable blob files；
- unknown UTI 也能 handle-backed round trip。

**DESIGN-TIER-11：bounded lease 与完整性**

- exact version fence 与 source protection采用 §10.1 的二选一：同一无-suspension Authority interval
  内同步 open+`fstat`，或先登记 GC-visible read reservation 再异步 open、失败 exactly-once 归还；
- 64 MiB blob 以固定最大 chunk 消费，consumer 不形成第二份完整 `Data`；
- cancel/early stop 后 descriptor 与 permit归零；
- missing、length mismatch、digest mismatch 是 typed corruption，不静默 fallback；
- whole-file digest路径明确标为 fail-late，并分别测试 authenticated chunks、prepass、
  staging-until-verified三种候选；有外部副作用的 lane在 integrity完成前不得 publish；
- exact ContentVersion 改变后旧 open失败；mid-stream revision/delete由 race test冻结。

### Phase 6：P3 随后的 ENOSPC、crash 与 GC

**DESIGN-TIER-12：真实 disk pressure**

- 先由 single-instance/StoreRoot ownership proof 保证没有第二进程 writer；在此前提下 process-local
  reservation阻止本进程两个并发 writer共同越界；
- advisory preflight 足够但真实 write 仍 ENOSPC 时，old History/position完整；
- derived-cache-first cleanup 后仍不足，capture typed fail，不自动删 pins/history；
- 至少一条 macOS fixed-size APFS image lane产生真实 ENOSPC，不能只有 mock errno。

**DESIGN-TIER-13：kill matrix**

- staging create、每个 chunk、sync、publish、DB transaction前/中/后、response前；
- delete-reference commit前/后、GC unlink前/后；
- 每点 SIGKILL 后 reopen：committed reference 可读且 exact，orphan不可见，GC不删 live/
  in-flight；
- “response丢失后 retry exactly once”只对携带 durable requestID且与结果同 transaction
  记录的 external/Python或migration operation成立。普通 pasteboard capture当前没有这个
  owner，测试只能断言 store invariants与既定 dedup/coalesce语义，不能宣称通用
  exactly-once retry。

**DESIGN-TIER-14：bounded GC**

- GC 每轮 filesystem enumeration、reference检查和删除都受 fixed count/bytes限制；
- namespace使用 stable shard/cursor，不先构造完整 directory-name或 live-path `Set`；
- crash中断后幂等续跑；
- open stream 与 delete/GC 的 lease语义明确；
- logical references/refcounts/ownership aggregate 与慢速 oracle抽样一致。

### Phase 7：P3 migration

**DESIGN-TIER-15：dual-read + resumable batches**

- 迁移期间旧 inline row 与新 blob row 都能读取相同 bytes；
- 并发新 capture/revise 的 write policy明确为 write-new、dual-write或短时 gate之一；不得
  让 migration cursor越过后写入旧格式的 row，也不得用未经测试的双写制造两个 truth；
- 每批限制 item/bytes，持久 cursor/checkpoint；
- 第 N item 后 kill，reopen从 committed checkpoint继续；
- ENOSPC 暂停时旧 row仍可读；
- 同 batch执行两次不产生重复 live blob；
- migration orphan进入同一 bounded GC；
- 200/1,000/5,000/更大 lineage child suite测 peak RSS、临时双倍 disk与wall time；
- signed lane从上一正式版本真实升级。

当前 `RetainedBytesBackfill` 的小 fixture/interruption proof 有价值，但实现一次构造完整
arrays并全量 decode/rewrite，不能外推到无 count cap
([`RetainedBytesBackfill.swift`](../../../Sources/HistoryStorage/RetainedBytesBackfill.swift#L129),
[`HistoryMigrationInterruptionTests.swift`](../../../Tests/HistoryStorageTests/HistoryMigrationInterruptionTests.swift#L16))。

### Phase 8：格式、Preview、Python共用同一有界 seam

**DESIGN-TIER-16：purpose/access plan**

- access mode 是具体 decoder+fixture+OS 实测分类，不由 UTI 名称静态推断；
- text 在 codec 明确且证据允许时取 bounded prefix/sequential decode；
- raster记录 decoder实际要求的 ranges/full source；ImageIO option本身不证明 parser peak；
- PDFKit 当前只按 bounded full `Data` 设计；Apple 资料未证明第一页可 range-read。media metadata/首帧
  同样在 AV fixture 证明前保持 full/disabled，而不是先写 partial 承诺；
- archive/unknown只显示 type/size，不自动解包；
- 当前 Clipy `PasteboardAdapter.write` 仍逐 representation 调用 `setData`，因此要求 bounded
  full `Data` payload
  ([`PasteboardAdapter.swift`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L159))；
  除非 signed provider/lifetime experiment批准新的 delayed-provider合同，P3 stream首期
  只供 Preview、export和CLI，不能把 export streaming证据外推为 paste streaming；
- Preview cancellation释放 loader/renderer各自permit；Python不打开 store/blob path。Python streaming
  只有在 Gateway audit/idempotency、binary transport、caller-output budget 与 content-read grant 全部批准后
  才可实现，之前为 `BLOCKED-AUDIT`，不能借 Storage stream 绕过外部 trust boundary；
- multi-item必须先有 item-group domain model，不能把多个 pasteboard items扁平合并。

### Phase 9：backup / restore

**DESIGN-TIER-17：一致恢复 gate**

- `DISK-CHILD` 在 backup checkpoint前后并发 capture、delete、GC和WAL activity，复制完整
  metadata store family + blob/manifests；restore后 open不依赖原路径，browse/paste抽样
  byte-exact，orphan/missing reference遵循typed作用域；
- 只复制主 store、只复制 blob、或 backup与GC无coordination的负控制必须被拒绝，不能
  静默打开为“部分成功”；
- `SIGNED` 验证真实 Application Support/Caches分类、backup exclusion、上一正式版本
  restore+upgrade；对 same-UID helper/Python则按已批准 threat model二选一：用 sandbox/
  encryption/key custody证明其不能读取裸 blob root，或明确记录 non-sandbox same-UID 下
  Unix mode无法提供该隔离，绝不能用一条注定过不了的 permission断言伪造安全性。

### Phase 10：规模与 soak

按 5k baseline → 5,001 functional boundary → 50k → 250k → 1m staged gates：

- cold/warm open、first page、page 1000、dedup candidate、exact/fuzzy/regexp search、retention
  batch；仅在 P3已触发时加入blob GC/migration与loose-file指标；
- RSS由 fixed owned budgets决定，不随累计访问 N 线性常驻；native/framework部分以明确
  envelope报告，不伪称由 permits完全控制；
- cache bytes永不越界，cancel/settle后回到稳定 plateau；
- 24–72 小时 capture/coalesce/revise/pin/remove/search/preview/Python read；
- 周期性 SIGKILL、memory pressure、disk pressure、restart与GC；
- 随机抽样 content hash、logical aggregates、references与纯 oracle对比；
- 只有方案 B 在该 soak 中出现可复现的 inode/directory/file-open/backup-enumeration或
  loose-file GC瓶颈，才触发方案 C segments/packfiles实验。

通过 1m fixture 仍然只证明该 OS、机器、fixture 与操作组合，不叫无限。

### Design epic → canonical execution leaf

`DESIGN-TIER-*`只组织目标；实现与完成状态只记录在`04`：

| Design epic | Canonical execution leaf / family |
|---|---|
| `DESIGN-TIER-CHAR-1…3` | §26 characterization + `PLAY-STOR-1…4`；未批准阈值前不是Red |
| `DESIGN-TIER-1` | `PLAY-MEM-1…7`；cache只有具体owner复用证据后才mint `PLAY-LRU-{OWNER}-*` |
| `DESIGN-TIER-2A/2B` | `PLAY-TIER-2A/2B`；2B受spec/G8阻塞 |
| `DESIGN-TIER-3` | `PLAY-STOR-2`与`PLAY-COUNT-7A`，分别证明blob不触碰和规模/tie访问量 |
| `DESIGN-TIER-4/5/6` | `PLAY-MEM-*`、owner-specific `PLAY-LRU-*`、`PLAY-SOAK-*` |
| `DESIGN-TIER-7` | `PLAY-COUNT-1/1B/1C/1D/2/3C/3R/3CV/3RV/4E/4F/4R/5A/5B/5C/5R3/5X/5D`，含lazy-validation poison、candidate-storm、victim/R3组合/revise/remove/Clear tail |
| `DESIGN-TIER-8` | `PLAY-COUNT-7A…7C/8A/8B` |
| `DESIGN-TIER-9` | test-only=`PLAY-COUNT-6A/6B`；aggregate=`8C` + shared `PLAY-DISK-0A/0B/1/2A/3…6`；production=`9A/9B`，1m evidence=`9C` |
| `DESIGN-TIER-10/11` | `PLAY-TIER-SPEC-0`后才领`PLAY-TIER-6/2B/3/4/5S/5P`与`PLAY-BLOB-*`；5S仅为internal test sink，5P另受audit gate阻塞 |
| `DESIGN-TIER-12/13/14` | P3 variants of `PLAY-DISK-*`、`PLAY-CRASH-*`、`PLAY-GC-*` |
| `DESIGN-TIER-15` | `PLAY-MIG-1…6`；future真实schema migration才继承规模gate，concurrent writes由独立decision拥有 |
| `DESIGN-TIER-16` | `PLAY-TIER-1A/1B/2A/2B/5S/5P` + 对应Formats/Preview/Python leaf |
| `DESIGN-TIER-17` | current layout先`PLAY-DISK-6`；P3扩展为`PLAY-BACKUP-*` |

任何family/范围表达都不是一个可关闭ID；若一行需要多个observable结果，后续agent必须先在`04`拆出leaf。

## 13. Agent 实施纪律与完成定义

后续 agent 必须遵守：

1. 一次只从 `04` 领取一张 `PLAY-*` 卡；本节 `DESIGN-TIER-*` 只是 epic/crosswalk，不能直接标成完成；
   对应行为先 Red，再最小 Green，再审查是否删除重复机制；
2. 不先批量创建 tier protocol、actor、配置和 cache；接口由第一个真实 vertical slice
   拉出来；
3. Storage 按 bytes/purpose/shape调度，不按 UTI 建 loader；
4. cache从不成为 durable truth，disabled/hit/miss/evicted/restart结果等价；
5. 唯一 `HistoryAuthority` 仍是业务 writer；depot是物理 medium，不是第二业务 authority；
6. 所有 RSS结论来自独立进程，同时报告 requested source、resident DTO、decoder output和
   framework overhead；
7. 任何 “scalar fetch不读blob”“删除释放磁盘”“stream内存恒定”“crash原子”的文字，
   都绑定明确 OS/SDK/filesystem实验，不升级为 Apple未承诺的普遍事实；
8. 在 DESIGN-TIER-7/8 关闭四大 O(N)与UI/pin follow-through、并由 DESIGN-TIER-9 实际打开 policy前，
   不宣传“无固定条数上限”；未触发 G8不得实现或宣传 P3；在真实 ENOSPC、kill/reopen、
   migration、backup与signed soak前不宣传“生产级多级存储”。

完成定义不是“有一个 Storage target”或“用了 `.externalStorage`”，而是：

- metadata browse/search和写入 admission不需要全量历史驻留；
- 方案 A 下每个 content purpose只把目标 representation交给 caller、同时诚实计入 aggregate hydration；
  只有方案 B/P3 被触发并通过 physical source receipts 后，才宣称只打开必要 representation/range；
- resident、cache、physical和logical四类预算分别可测、可解释；
- cache/pressure/cancellation后内存达到稳定平台；
- crash、ENOSPC、migration、GC不会产生可见半状态或静默删历史；
- 用户可以关闭 count cap，但系统仍在有限资源边界上明确失败而非失控。

这才是“Storage 能按你想的正常工作”的可验证含义。
