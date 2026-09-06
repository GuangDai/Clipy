# 多级存储目标设计：历史数量与常驻内存解耦

状态：2026-09-07 设计建议，尚未实现或完成规模验证。本文按用户最新的多级存储方向
设计终态；正在 CI 中的功能批仍使用当前 SwiftData 存储。下文建议的 SQLite 实现
会替换当前 SwiftData/十模型的内部持久化表达，不能把它默认为当前规范已经变更。
这里不增加迁移、旧存储读取、SHA 内容身份、签名机制或实施审批框架。

## 1. 要达到的结果

10 万到 100 万条历史增长时，关闭面板后的应用主动持有内存不随历史条数线性增长。
打开列表只持有一个小窗口；搜索只持有一批候选和有限结果；读取只持有当前请求需要的
表示。这个目标与“任意大小内容都能在几十 MB 内解码”不同。

绝对 idle RSS 要测量 SwiftUI/AppKit、数据库、allocator 与系统缓存的基础开销后才能
承诺。不能由 `.mappedIfSafe` 或 `NSCache` 的配置推导出“百万条只占 50 MB”。
首屏和常见查询的延迟也要单独验证；有界内存不等于搜索耗时与 N 无关。

## 2. 推荐终态与备选

推荐 **一个 HistoryStorage Module 内，系统 SQLite3 管理元数据和索引，应用管理
不可变大 blob 文件**。保留 HistoryAuthority 唯一写者和现有 HistoryCore 的业务
Interface；不在 SwiftData 后面再旁接一个独立 SQLite writer。

| 方案 | 实际收益 | 主要限制 |
|---|---|---|
| 保留当前 SwiftData aggregate blobs | 改动最少；现有分页和缓存改进继续有效 | 没有受支持的逐表示文件地址；全量 signature index、搜索语料和单项 lineage 物化仍须解决 |
| SQLite，全部 payload 放独立 BLOB 行 | 数据库统一管理原子性；incremental BLOB I/O 可分块读取 | 大原始内容仍参与数据库页/WAL；incremental read 是复制到缓冲区，不是直接映射文件 |
| SQLite 元数据 + 不可变文件（推荐） | 可索引查询、逐表示访问、按需映射；大 payload 不进入元数据 WAL | 必须正确处理文件先写、数据库后提交、孤儿文件及读取寿命 |

选择推荐方案，是为了同时解决“很多条目”和“单个很大的内容”。单独加 blob 文件
不能解决全量索引和全语料数组；单独增加缓存也不能解决它们。

SQLite 是系统依赖，不引入第三方数据库封装。Domain 的去重、不可变修订、保留策略
和 typed planning 仍属于现有纯 Module。持久化实现的替换必须覆盖 Gateway 审计与
History 的同事务提交，不能只替换普通 capture/paste 路径。

## 3. 数据放在哪一层

```text
NSPasteboard → 冻结一次新值 → HistoryAuthority
                               │
                ┌──────────────┴───────────────┐
                ▼                              ▼
       SQLite metadata/indexes          immutable blob files
       item/revision/representation     大图片/PDF/较大原始表示
       小 payload inline BLOB           UUID 标识，文件永不原地修改
                │                              │
                └──────────────┬───────────────┘
                               ▼
                   按用途取得少量 metadata/bytes
                      │                    │
                  UI 行窗口            当前请求/renderer
                                           │
                                    有界可重建显示缓存
```

小内容初始可用 **64 KiB** 作为 inline/file 分界的测量起点，不按 UTI 猜大小，也不把
它做成用户设置。这个数不是已验证的最优值；用真实文本、RTF、HTML、截图、PDF 分布
比较数据库开销和文件数量后再定。100 万条小文本不应变成 100 万个小文件。

持久目录使用当前用户的 Application Support：

```text
Clipy/
  history.sqlite
  blobs/ab/<random-uuid>.blob
  staging/<random-uuid>.partial
```

`ab` 来自随机标识的固定前缀，只用于分散目录项，不来自内容摘要。
同一 blob 可被不可变内容版本引用，引用关系由数据库负责。
原始内容、HTML/RTF 和 PDF 都不属于系统可随意删除的 Caches 目录。
磁盘派生缓存不是首版必需层；当前没有这种落盘缓存，维护页如实显示未使用。

## 4. 元数据与查询

存储必须能分别表达 item、revision metadata、representation、payload 对象和
signature candidate postings；不能把所有表示及所有修订继续塞进一个必须整体解码的
字段。每条 representation 保存 exact identifier、顺序、长度以及 inline bytes 或
随机 BlobID。相同不可变 bytes 的复用通过引用表达，不复制隐藏的完整 lineage。

- recent 使用 pin/date/业务 ID 的复合索引和 keyset，不使用不断增大的 OFFSET。
- dedup 用当前 xxh3 候选事实做持久索引查询，然后逐候选、逐表示确认 bytes。
  指纹不成为 BlobID，不替代相等判断。类型名的索引键必须保留现有 Swift String
  canonical-equivalence 语义；原始标识拼写仍保留用于输出。
- 启动不恢复完整 SignatureIndex，不遍历全部内容，也不把所有业务 ID 放进 Set。
- 计数与 logical byte aggregates 在同一次 History transaction 中更新。
- 搜索按行数和 UTF-8 字节数双重约束读取批次，只保留 top-K 与游标所需数据。
  现有标题 1,024-byte 上限和 search-body 字节上限继续有效。
- exact literal、fuzzy、regexp 的语义保持明确。FTS token 查询不等于当前 literal
  匹配；只有能保证候选无遗漏的索引才能用于其前置筛选。否则按批扫描，并诚实承认
  CPU/I/O 可能是 O(N)。不能用另一个名字掩盖完整搜索被缩小。
- SQLite read transaction 可以提供搜索所需的一致视图；其寿命必须有取消和时间约束，
  因为长读会影响 WAL 回收。不得通过把多次不同 position 的批次拼起来伪造一个快照。

当前工作已推进 count-only capture 的候选/受害者有界读取、recent 同时间戳 keyset
以及 UI 三页窗口，但这些不代表上述持久索引、搜索、启动改造已经完成。

## 5. 小 Interface，明确的内容寿命

界面继续调用 `load(item)`、Copy、Save As 等用户动作。PreviewContentLoader 隐藏
表示选择、History 读取与取消；renderer 只接收所需的不可变值。

内部需要的能力形状是：

```swift
// 示意，不是新增已发布 API。
representationMetadata(for: itemReference) -> [RepresentationDescriptor]
read(contentReference, range: requestedRange, maximumBytes: limit) -> Data
pastePayload(for: itemID) -> PastePayload
```

ContentReference 携带业务身份和内容版本，绝不携带可绕过 History 的裸 blob URL。
Storage 校验版本、目标存活和范围；Preview 仍负责格式选择与解码，Storage 不加入
PNG/RTF/PDF 路由表。Details 默认只取 metadata 和有限预览，展开/导出才读取目标 bytes。
Copy 只读取当前 Effective Content，不为了复制 v20 去读取 Canonical 和前 19 次修订。

当前 NSPasteboard 写入可能仍要求完整 Data。因此复制大内容仍有单次工作集，不能
宣称 range/mmap 已经让整个 paste 成为流式、零复制操作。单次请求大小和并发应按
实际用途限制，历史条数不进入这个内存预算。

上面的每次 `read` 是一次完整的逻辑读取：Authority 确认引用有效并打开文件后，
该次调用内部的所有分块都持有同一个描述符，完成、失败或取消时关闭。提交删除后
可 unlink；已打开文件的读取寿命由系统维持。此后发起的另一轮 `read` 必须重新
校验存活，可能返回 typed failure。调用方不得把多个独立 range 请求当成跨删除仍然
有效的读取会话；需要分块消费的大内容由 Storage 在一次用途明确的操作内读完，
不向外暴露文件句柄，也不引入应用自建的 lease/lock 注册系统。

文件读取完成不等于 UI 仍可发布：删除、版本变化或关闭面板后，现有引用与任务检查
仍须丢弃迟到结果。磁盘读取中途失败时不返回成功的部分内容；应用可重建的预览才可
按其明确的截断规则展示有限内容，原始 Copy/Save As 不得静默截断。

## 6. 原子发布、删除与恢复

新增内容的顺序固定为：

1. 在 staging 完成新文件，检查写入结果，完成所要求的文件同步。
2. 将文件发布到最终不可变路径。
3. 唯一 Authority 用一次 SQLite transaction 提交引用、计数、业务变化、审计和
   ChangePosition。
4. 返回真实 receipt，释放输入及临时内存。

数据库永远不先引用一个尚未发布的文件。文件已发布而 transaction 失败时，留下的是
无引用文件，旧 History 不变；不得先删除旧历史为新写入腾位置。断电耐久性、目录同步
和 APFS 行为仍需要真实平台验证，不能从 rename 的原子性外推全部耐久性。

删除/prune 先提交数据库引用变化，再删除已无引用的文件。清理只查询当前真实引用，
按固定批次枚举文件，不在启动时构建全仓 live-ID Set，不依赖额外持久账本。
清理与同一 blob 引用的发布仍由 Authority 排序；staging 和最终文件分开处理。
不复用一个已经删除的 BlobID 来写另一份内容。

首版备份先采用明确的离线完整目录备份：关闭写入与数据库后复制 metadata 和 blobs
作为一个整体。导出单个表示与完整历史备份是不同功能。没有专门一致性实现时，不
把“应用运行时复制 sqlite 文件”称为可靠备份。

## 7. Foundation 缓存与映射的使用方式

| 机制 | 采用方式 | 不能据此宣称 |
|---|---|---|
| `NSCache` | 适合 owner 内可重建对象；成本按 decoded bytes，cache miss 可重建 | count/cost 配置是严格内存上限或保证 LRU |
| `NSPurgeableData` | 仅冷的派生 bytes；owner 内成对 begin/end，丢失就重建 | 可以保存唯一原始历史，或可以在 end 后继续使用裸指针 |
| `.mappedIfSafe` | 私有本地不可变大文件的整值读取提示；用完释放引用 | 必定 mmap、必定零复制、映射长度等于 RSS、释放马上降低 RSS |
| `.uncached` | 明确的一次性大扫描经过测量后再用 | 默认比 OS page cache 更好 |
| memory pressure | 释放可重建内容、取消预取、恢复时按当前需求重新加载 | 应删除持久历史，或固定降至某个 RSS 数字 |

现有 ThumbnailStore 已有明确的 decoded-byte 约束及冷条目淘汰；不为了使用 API 名称
而把它替换成只有软限额的 NSCache。可把 NSCache 作为具体 owner 的实现选择，但不能
因此失去原本的资源约束。也不增加全应用混合“万能缓存”。

NSPurgeableData 创建时已有一次 content access。放入冷缓存前结束该次访问；取回后
先 `beginContentAccess()`，失败视为 miss，成功在对应 `endContentAccess()` 前完成
读取。不得让 no-copy Data、CGDataProvider 或图像对象偷偷持有超出这段寿命的指针。
需要交给 UI 的独立 bytes 应复制或由现有显示 owner 持有有效访问直到显示对象释放，
两者都计入在用成本。先测复用和复制成本，再决定是否值得启用 purgeable 存储。

不对外部可变文件默认 mmap。文件被截断、卷消失等情况下，映射访问可能无法表现为
普通 Swift throws。显式文件预览采用有界读取；只有 app 自己管理的不可变文件才能
满足更清楚的寿命假设。底层 madvise/Mach purgeable allocator 不进入首版。

## 8. 压力响应与四类数字

| 状态 | 显示/预取行为 | 持久 History |
|---|---|---|
| normal | 仅当前窗口及小预取范围工作 | 不因状态变化删除 |
| warning | 清冷缓存，取消已无可见需求的读取/解码 | 不变 |
| critical | 清所有可重建缓存、取消非必要任务、暂停自动预取；用户明确 Copy 单独处理 | 不变 |
| 回到 normal | 恢复当前需求，不重建整个曾访问集合 | 不变 |

每次压力事件都要到达消费者，不能只依赖枚举值变化。应用能取消自己的排队工作，
不能承诺立即抢占正在执行的系统 decoder。

维护页分开显示 logical retained bytes、近似 allocated store bytes、derived disk cache、
全进程 RSS/footprint。RSS、启动以来 peak RSS 和 footprint 也不是相同数值。
completed-cache bytes 不包括 source buffers、临时拷贝和系统 decoder workspace。

内存规划按以下各项分别考虑：固定数据库缓存、有限 metadata 窗口、搜索批次/top-K、
活动捕获输入、活动读取、解码工作区、完成后的派生缓存。最初沿用一个重型 decode
和已有的 capture active+latest 形状；仅有可测的吞吐需求才扩并发。不要通过很多
独立 actor 各允许一份大 Data，实际同时保留几十份却宣称“每个都有限”。

## 9. 保留策略与磁盘空间

用户可关闭条目数限制；保留额度优先按内容 bytes 表达，现有 count 限制可作为可选项。
自动删除的首版顺序保持可解释：最旧未置顶项优先。置顶保护不因内存压力或磁盘紧张
偷偷失效。文本永久保留若加入，必须是用户看得见的分类策略，不能暗藏在猜测的
reuseProbability/权重分数里。

必须区分“用户允许保留多少逻辑内容”与“卷当前能否完成这次写入”。WAL、staging、
APFS 共享块和备份会使物理大小不同；不能把近似目录 allocated size 当严格配额。
如果只剩受保护内容，或无法安全写入，新捕获返回明确失败与恢复入口；缓存清理不
伪装成已经保证腾出足够磁盘空间。重复复制继续按现有规则 coalesce，同一张图复制
100 次通常是一个 History Item 的 occurrence 增长，不是必须保留 100 个独立条目。

## 10. 实施顺序与证明

1. 收尾当前 CI：bounded capture/recent、UI 窗口、压力响应与独立用量显示。
2. 按本文重写持久化实现：薄 metadata/representation schema、持久候选查询、短事务
   和不可变大文件。Domain 与公开业务语义保留，SwiftData writer 被整体替换；不双写、
   不加兼容迁移，不自动删除用户目录来假装初始化成功。
3. 将 Details/Preview/Paste 改为逐表示读取，移除全 lineage hydration；补所有文件/事务
   失败与取消路径，然后接映射和派生缓存的局部实现。
4. 搜索、保留策略应用、Clear、启动清理都移除随全仓规模增长的 Swift facts/DTO/ID
   数组。尤其大 Clear/retention 的 receipt/HCR 不能为了列出全部 IDs重新分配全仓内存；
   采用现有 scope/count 语义或明确修订其业务返回值，保持事务及观察一致性。
5. 在 CI 用真实磁盘数据分别测 10k、100k、1m：冷启动、静置、首屏、持续滚动、三种
   搜索、当前/旧内容 Copy、revision/prune、pressure 后恢复。记录 owned bytes、RSS、
   footprint、耗时及磁盘增长，区分 idle 与活动峰值。规模不是新的仓库 gate/证书，
   这些是产品行为和资源表现的证据。
6. 上述路径可用且数据支持结论后，取消 5,000 hard cap 和 count-only 产品上限。
   不先改成 Int.max 再让旧全量路径承受百万条数据。

必须验证：候选碰撞仍逐字节判断；数据库提交失败保留旧历史；文件发布后崩溃可清孤儿；
删除期间已打开读取仍有定义；缺失/损坏原始 blob 不变成空内容；缓存被丢弃能重新生成；
pressure 不推进 ContentVersion/ChangePosition；搜索取消/过期不发布混合快照。
真实断电、全部文件系统以及系统实际强制 purge 的行为不能由注入测试代替。

## 11. 文档依据

- Apple [`NSCache.totalCostLimit`](https://sosumi.ai/documentation/foundation/nscache/totalcostlimit)
  与 [`countLimit`](https://sosumi.ai/documentation/foundation/nscache/countlimit)：均非严格限额，淘汰顺序不保证。
- Apple [`NSPurgeableData`](https://sosumi.ai/documentation/foundation/nspurgeabledata)
  与 [`beginContentAccess`](https://sosumi.ai/documentation/foundation/nsdiscardablecontent/begincontentaccess())：
  可丢弃字节的访问契约，不是 durable storage。
- Apple [`mappedIfSafe`](https://sosumi.ai/documentation/foundation/nsdata/readingoptions/mappedifsafe)：映射提示。
- Apple [`externalStorage`](https://sosumi.ai/documentation/swiftdata/schema/attribute/option/externalstorage)：
  邻近 model store 的 binary placement，不公开 blob URL/range/eviction Interface。
- Apple [`MemoryPressureEvent`](https://sosumi.ai/documentation/dispatch/dispatchsource/memorypressureevent)：系统状态事件。
- SQLite [`incremental BLOB I/O`](https://sqlite.org/c3ref/blob_open.html)、
  [`mmap`](https://sqlite.org/mmap.html)、[`FTS5`](https://sqlite.org/fts5.html)：具体能力及适用限制。
- 历史 [09 多级存储审查](../reviews/2026-08-22-clipy-maccy-deep-review/09-tiered-storage-and-unbounded-history.md)
  的四 bytes、O(N) 分析可作背景；其迁移、完整 checkpoint 与治理条件不作为本设计实现要求。
