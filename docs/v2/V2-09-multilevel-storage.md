# 多级存储目标设计：历史数量与常驻内存解耦

状态：2026-09-07 用户明确批准实施；规模目标尚未验证。本文定义多级存储终态：
SQLite 元数据、不可变 blob 文件及派生缓存替代 SwiftData/十模型内部持久化表达，
消费路径按用途读取少量 metadata 或选中的表示。这一决定取代
旧文档中保留 SwiftData 十模型的要求，其他公开业务语义继续有效。
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

捕获沿用当前 Adapter 的 changeCount 与权限预检：后台只在明确允许访问时读取，
`.ask`/默认/拒绝不由定时器反复触发内容读取。changeCount 不是内容身份，也不是完整
历史日志；快速覆盖可能发生在两次采样之间。读取过程中 ownership 变化不能把不同
代的表示拼成一个成功捕获。成功捕获立即进入唯一 Authority，提交后释放应用持有的
输入，不保留一个不断增长的原始 Data 数组；这不意味着能强制系统 pasteboard 释放
自己的内容。检测 metadata 也不能绕过原始内容访问权限。

当前不新增无消费者的 detection 循环。Apple 的 `detectedMetadata(for:)` 只提供
有限元数据，其中 [`contentType`](https://developer.apple.com/documentation/appkit/nspasteboard/detectedmetadata/contenttype)
是首项文件 URL 所指文件的类型，不是通用 payload 字节数或完整表示清单；
[`detectedValues(for:)`](https://developer.apple.com/documentation/appkit/nspasteboard/detectedvalues(for:))
则会在命中时读取内容并可能提示。
若未来 UI 需要文件/链接提示，可在用户明确操作时做一次检测，返回时重查 ownership
与生命周期；不得把检测成功当作捕获授权。

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
  history.sqlite-content/
    blobs/ab/<random-uuid>.blob
    staging/<random-uuid>.partial
```

`ab` 来自随机标识的固定前缀，只用于分散目录项，不来自内容摘要。
每个数据库文件使用自己的 `文件名-content` 目录，避免同一父目录的多个数据库
共享文件、相互将对方的数据当作孤儿回收。维护页统计二者共同的应用专属父目录。
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
  确认期间仅保留输入及当前候选表示；即使已匹配输入子集，也须验证候选余下表示，
  不能因提前命中而忽略损坏内容。Canonical 字节总数须与条目聚合值一致。
- 启动不恢复完整 SignatureIndex，不遍历全部内容，也不把所有业务 ID 放进 Set。
- 计数与 logical byte aggregates 在同一次 History transaction 中更新。
- 搜索按行数和 UTF-8 字节数双重约束读取批次，只保留 top-K 与游标所需数据。
  现有标题 1,024-byte 上限和 search-body 字节上限继续有效。
- exact literal、fuzzy、regexp 的语义保持明确。FTS token 查询不等于当前 literal
  匹配；只有能保证候选无遗漏的索引才能用于其前置筛选。否则按批扫描，并诚实承认
  CPU/I/O 可能是 O(N)。不能用另一个名字掩盖完整搜索被缩小。
  当前使用系统 FTS5 压缩可逆 Unicode scalar gram postings；它不保存原始搜索正文，
  不把 word token 查询当作匹配结果。正文及标题保持 exact UTF-8 Data，所有候选仍由
  原 matcher 确认。索引和投影在同一次提交更新，删除同步去除 postings。
  原生词频选择稀疏候选查找或密集匹配的有序扫描，避免先排序全部命中；exact/regexp
  取足页面和 lookahead 后结束，fuzzy 仅在后续行不可能改善当前页时提前结束。
  查询验证实际读取的候选，不为了发现无关行的潜在损坏而额外扫描全库。
- SQLite read transaction 可以提供搜索所需的一致视图；其寿命必须有取消和时间约束，
  因为长读会影响 WAL 回收。不得通过把多次不同 position 的批次拼起来伪造一个快照。
  查询执行中的 SQLite progress callback 检查同一次请求的取消和截止时间，退出时先
  移除 callback 再回滚。regexp 的截止时间也不得超过快照剩余寿命；这不意味着能
  抢占阻塞的文件系统调用或每一段同步原生计算。

`history_items.currentContentID` 的外键查找使用索引，避免每次删除 content 都扫描
全部条目。Swift facts 有界仍不足以排除数据库内部重复全表扫描。

当前存储已实现持久候选查询、分批搜索、无全仓索引恢复的启动及 recent keyset；
这些行为仍需规模测试验证。UI 三页窗口必须同时约束行 DTO 与导航元数据：每页只
保存行数及 previous/next，窗口偏移和“曾淘汰窗口”是固定数量标量，不再保存所有
访问过的请求游标。recent 用同一快照上的双向 keyset；exact/regexp 后退保留固定
大小的最近匹配前驱窗口，fuzzy 按原排序选择有限前驱。所有返回行仍按正常显示顺序，
反向读取不改变匹配、pin 优先、分数及时间/ID 的排序语义。
类型与置顶筛选作用于全历史的当前 Effective metadata，参与观察和游标身份；切换
筛选重新查询。它不再仅隐藏当前三页窗口中的不匹配行。

置顶修改也必须保持有界 facts：只读取目标、锚点的位置及置顶计数，Domain 产生一条
relocation（删除置顶项再跟一条 delete），而不是完整 ID 顺序和每行 mutation。
SQL 使用唯一的置顶 ordinal 索引；位移先移入不相交的非负临时区间，再写回目标区间，
全部在一次提交中完成，不依赖 UPDATE 的行修改顺序。删除前的 relocation 只扣一次
置顶计数，后续 delete 读取目标已取消置顶的状态；原始内容与 retained 计数只删除一次。
唯一索引是当前数据库布局的必要约束，缺失或非唯一的现存布局明确拒绝打开，不迁移、
修复、重建索引或删除原有文件。COUNT/MIN/MAX 校验只返回固定数量标量，但数据库
遍历及实际范围更新仍可能是 O(P)，不能把有界 Swift 内存称为常数时间。

置顶 HCR 记录目标和提交前位移区间，不枚举所有受影响 ID。显式 HCR ID 的独立上限
固定为 5,001，自动化 locator 固定为 5,000、cursor 为 64；均不随历史容量增长。
这些改造也不使搜索 CPU/I/O 与历史规模无关，仍须用真实磁盘数据验证规模目标。

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
Details 的显式表示预览也先按 renderer 元数据限额决定是否读取；不支持或超限的表示
只显示 metadata，Save As 仍读取完整原始字节。编辑器 Reload Latest 的任务由编辑器
持有，关闭或丢弃后取消；迟到结果不得改写原 Details owner。

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
整值文件读取前后检查取消；范围读取在同一描述符的 64 KiB 分块之间检查取消。
取消保持 `CancellationError`，不误报为存储损坏；同步 Foundation 整值读取本身
不可立即抢占，完成后取消的结果也不得返回给调用方。

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

打开存储、实际删除/prune 或新文件发布后的事务失败会请求一次有限后台遍历。
每批最多访问 64 个目录项，批次之间让出 Authority；遍历中新增请求合并为一次补跑，
完成即退出，不依赖后续复制来推进，也不保留永久轮询任务。普通复制/置顶不触发
全目录遍历。清理失败不改写已提交的 receipt；下一次实际清理请求或重新打开时重试。

首版提供用户明确发起的完整目录备份：唯一 Authority 在一个不挂起的操作内，用
SQLite backup API 复制 metadata，再按索引分页复制所有被引用的不可变 blob。
该期间其他 History 写入和清理等待同一个 actor，保证数据库与文件属于同一状态；
不另加 lease/lock，也不把运行中直接复制 sqlite 文件当作备份。共享 blob 只复制一次。
目的地必须是新目录且不位于源存储的受管理目录内，失败或取消仅清理本次创建的
部分备份。成功回执携带源 ChangePosition 和条目数；备份本身不推进 History 状态。
备份包含原始内容、修订和存储元数据，未加密。它可用当前存储实现重开；此功能不
附带旧格式迁移或历史合并。导出单个表示与完整历史备份仍是不同操作。

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
critical 期间只保留当前预览 dwell 的目标；恢复 normal 时重新等待该目标，期间的
新选择或修订替换目标。手动关闭、关闭面板、失去焦点、禁用自动预览或删除目标后
不得恢复；重复 normal 事件不重置正在等待的 dwell。

维护页分开显示 logical retained bytes、近似 allocated store bytes、derived disk cache、
全进程 RSS/footprint。RSS、启动以来 peak RSS 和 footprint 也不是相同数值。
completed-cache bytes 不包括 source buffers、临时拷贝和系统 decoder workspace。

内存规划按以下各项分别考虑：固定数据库缓存、有限 metadata 窗口、搜索批次/top-K、
活动捕获输入、活动读取、解码工作区、完成后的派生缓存。最初沿用一个重型 decode
和已有的 capture active+latest 形状；仅有可测的吞吐需求才扩并发。不要通过很多
独立 actor 各允许一份大 Data，实际同时保留几十份却宣称“每个都有限”。

## 9. 保留策略与磁盘空间

用户可关闭条目数限制；保留额度优先按内容 bytes 表达，现有 count 限制可作为可选项。
`maximumUnpinnedItems` 使用可选正整数：`nil` 明确关闭按条数删除，SQLite 保存 NULL；
正整数表示用户选择的未置顶额度，默认仍为 200。公开打开配置、修改 action、配置读回
与 Domain 使用同一语义，没有 999/5,000 的产品条数上限，也没有另一个总 retained
count hard cap。关闭条数限制不关闭 age/storage/revision 策略或单次输入资源限制。
关闭后重开保持 nil；重新启用额度时最旧未置顶项的退休与配置、ChangePosition/HCR
一起提交，失败时全部回滚。整数表示溢出仍是明确容量失败，不能悄悄绕回负数。
旧的 `maximumUnpinnedItems NOT NULL` 布局不能表达关闭状态，打开时明确拒绝；
不迁移、不补写、不删除原文件。
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
4. 搜索、保留策略应用、Clear、启动清理与 UI 导航书签都移除随全仓规模增长的 Swift facts/DTO/ID
   数组。尤其大 Clear/retention 的 receipt/HCR 不能为了列出全部 IDs重新分配全仓内存；
   采用现有 scope/count 语义或明确修订其业务返回值，保持事务及观察一致性。
5. 在 CI 用真实磁盘数据分别测 10k、100k、1m：冷启动、静置、首屏、持续滚动、三种
   搜索、当前/旧内容 Copy、revision/prune、pressure 后恢复。记录 owned bytes、RSS、
   footprint、耗时及磁盘增长，区分 idle 与活动峰值。规模不是新的仓库 gate/证书，
   这些是产品行为和资源表现的证据。
6. 条数限制使用 §9 的公开可选策略；规模 fixture 与产品使用同一个 HistoryLimits，
   不再创建仅供 fixture 使用的更高容量配置。直接测试覆盖普通公开 store 在 5,000
   条真实 SQLite fixture 之上的 capture/coalesce/pin/读取，以及 5,001/百万用户额度。
   这证明产品路径不再拒绝大历史，不替代步骤 5 的百万条资源与性能测量。

手动 `SQLite storage measurements` 工作流提供 10k、100k、1m 或三档并行选择，
使用 Release `HistoryPerfRunner --sqlite-scale`。seed 和 measure 分属独立进程，
fixture open 只调整该专用数据库的条数限额，公开产品 open 仍用标准限额。工作负载
包含首屏、固定单页窗口的全量遍历、三种搜索的未命中/稀疏与密集命中/拼写错误、当前/Canonical Copy 及
revision/prune，分别记录逻辑内容、文件系统用量、RSS、进程历史 peak RSS、footprint
和耗时，不设数值达标门槛。进程冷启动不代表磁盘缓存冷启动；独立 Storage runner
也不能证明整个 App 的 owned bytes、真实压力恢复或完整生产者内容分布。实现了
测量入口不代表这些规模已通过验证，产品条数上限仍须等真实结果再调整。
百万条下一秒内完成搜索是当前优化目标；用每条查询的实际结果和耗时判断，不能用
单一不存在词项或省略结果校验代替。复杂正则与索引不适用的查询仍如实记录耗时、
取消和截止失败；不以放宽截止时间使测量表面通过。

必须验证：候选碰撞仍逐字节判断；数据库提交失败保留旧历史；文件发布后崩溃可清孤儿；
删除期间已打开读取仍有定义；缺失/损坏原始 blob 不变成空内容；缓存被丢弃能重新生成；
pressure 不推进 ContentVersion/ChangePosition；搜索取消/过期不发布混合快照。
真实断电、全部文件系统以及系统实际强制 purge 的行为不能由注入测试代替。

## 11. 文档依据

- Apple [`changeCount`](https://sosumi.ai/documentation/appkit/nspasteboard/changecount)
  与 [`AccessBehavior`](https://sosumi.ai/documentation/appkit/nspasteboard/accessbehavior-swift.enum)：
  ownership 计数与系统读取行为；不提供历史保存或丢失代补读保证。
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
  [`mmap`](https://sqlite.org/mmap.html)、[`FTS5`](https://sqlite.org/fts5.html)、
  [`progress callback`](https://sqlite.org/c3ref/progress_handler.html) 和
  [`外键索引`](https://sqlite.org/foreignkeys.html#required_and_suggested_database_indexes)：具体能力及适用限制。
- 历史 [09 多级存储审查](../reviews/2026-08-22-clipy-maccy-deep-review/09-tiered-storage-and-unbounded-history.md)
  的四 bytes、O(N) 分析可作背景；其迁移、完整 checkpoint 与治理条件不作为本设计实现要求。
