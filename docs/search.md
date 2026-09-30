# 搜索、排序与分页

## 对外语义

[`HistoryCore/Requests.swift`](../Sources/HistoryCore/Requests.swift) 定义 recent / search 请求、过滤条件、排序和游标。搜索 term 最多 4,096 UTF-8 字节。空 term 使用 recent 等价路径；空格不是空查询。

| 模式 | 匹配范围与顺序 |
| --- | --- |
| `exact` | 不区分大小写的字面子串，先标题、标题未命中才查完整有界搜索正文；使用第一处命中 |
| `regexp` | `NSRegularExpression`，标题和正文各只查前 1,000 个 Character；先标题，使用第一处命中 |
| `fuzzy` | Fuse 1.4.0，查询最多 64 个 Character，标题和正文各前 5,000 个 Character |
| `expression` | 精确文本条件与来源、UTC 日期、类型、置顶状态的布尔表达式 |

默认排列先置顶区的用户顺序，再未置顶区。exact、regexp 和 expression 的未置顶区按最近复制时间降序，再按项目 ID 升序；fuzzy 的未置顶区先按匹配分数，再按最近时间和 ID。显式元数据排序覆盖未置顶区的相关度排序；置顶区仍保留自己的排列。

过滤在存储查询中执行，界面不能只过滤已经加载的一页冒充完整查询。类型、置顶状态、来源和时间过滤与查询、排序共同参与游标身份。标题命中直接高亮标题；正文命中返回最多 322 个 Character 的片段，省略号计入限额。高亮范围是相对于返回标题 / 片段的 UTF-16 整数范围，支持匹配只覆盖复合 Character 中的完整 Unicode 标量。界面用一次标量遍历解析所有边界，时间为 O(n + r log r)，临时空间为 O(r)；越界或截断 surrogate pair 的范围丢弃，不扩展到其他字符。

## 表达式

[`HistorySearchExpression.swift`](../Sources/HistoryCore/HistorySearchExpression.swift) 是纯解析器。`NOT` 优先于 `AND`，`AND` 优先于 `OR`，相邻条件等同 `AND`。括号改变组合顺序；双引号保留短语，其中可转义反斜杠和双引号。括号与 `NOT` 的嵌套受限制，解析错误包含原文 Character 位置。

```text
meeting OR "project notes"
type:images is:pinned
app:"TextEdit" date:2026-09-01..2026-09-30
source-id:com.apple.TextEdit NOT draft
```

支持 `app:` / `source:` 应用名称、精确 `source-id:`、`date:` 单日或范围、`before:`、`after:`、`type:text|images|links|all` 及 `is:pinned`。日期按 UTC 日解释，与机器时区无关。应用名称由应用层读取安装应用元数据并替换成来源 ID，同一次解析中相同名称只匹配一次，解析器本身不查询系统。替换在构造扩张节点前检查 4,096 字节、128 tokens 和 16 层嵌套上限；超出时明确失败，不截断匹配的应用。保存的相对日期搜索定义仍在使用时解析为当时日期，不能永久冻结为首次保存的日期。

## 存储搜索路径

[`SearchWorker+SQLite.swift`](../Sources/HistoryStorage/SearchWorker+SQLite.swift) 为每次请求建立自己的只读连接和事务，在事务中捕获 `ChangePosition`。每批最多 32 行、1 MiB 投影 UTF-8 内容；批次之间主动让出执行权并检查取消。请求不持有全库搜索语料、完整匹配 ID 数组或历史载荷。

[`SQLiteSearchIndex.swift`](../Sources/HistoryStorage/SQLiteSearchIndex.swift) 维护 contentless FTS5 postings。它对标准化 Unicode scalar 的一至三个连续值进行可逆整数编码，提供必要条件候选集；这些值不是内容哈希，也不决定是否真的命中。exact 最多抽取 16 个必要 gram 进行 AND；fuzzy 对有限的查询 scalar 做 OR；简单字面正则可用必要文本，复杂正则回到有界批次扫描。

候选稀疏时从 postings 读取候选，密集时按目标顺序遍历并检查成员。选择稀疏路径只读有限 postings 输出，超过 4,096 个候选便视为密集；不通过完整词汇频次扫描决定路径。FTS 仅减少需要解码和匹配的行，最终匹配仍遵循 Foundation / Fuse 语义。metadata-only 表达式不读取无关搜索正文。

## 复杂度与资源限制

[`ExactLiteralMatcher.swift`](../Sources/HistoryStorage/ExactLiteralMatcher.swift) 对适合的 ASCII 前缀预编译查询，按字扫描候选首字节，再确认候选。重复前缀导致失败确认过多时转入 KMP，使这条快速路径保持 `O(n + m)` 最坏时间和 `O(m)` 查询准备空间，`n` 为被检查文本长度、`m` 为查询长度。非 ASCII 或 CR 等不适用情形交给 Foundation 保留既有匹配与坐标语义，不能把 ASCII 路径复杂度承诺套在所有 Unicode 输入上。

fuzzy 的 Fuse 固定参数是 threshold 0.7、location 0、distance 100、忽略大小写、不 tokenize。每次请求只编译一次查询。默认相关度排序用有限大小的页面候选选择，不保留全部匹配；已获得不能再被后续有序行改善的最佳页面时可提前结束。存在查询仍需要检查大部分或全部候选，不声称任何搜索都是常数时间。

正则在访问存储前验证长度、可编译性和已知危险形状。复杂匹配使用带 progress callback 的迭代器，整个请求的正则匹配时间预算为 2 秒；SQL 获取和主动让出执行权的时间不计入这个匹配预算。超时或引擎中途放弃会使整次请求失败，不返回看似完整的部分结果。这不是所有 native matcher 的任意时刻抢占保证。

搜索快照最长持有 30 秒；过期明确失败并释放事务。SQLite progress callback 和每 32 行检查共同让取消及截止时间影响 SQL 与扫描。读取完整正文、构造片段及修订计数只为真正需要的结果进行。

## 分页与观察

页面 limit 为 1 至 500。按排序 anchor 继续翻页，不把全部结果读入内存再截取。游标封装快照位置、请求身份、方向和排序 anchor；提交后旧位置或改变 query / filter / sort 的游标明确失效。`startAround` 在新的权威快照中定位指定项目；项目不存在或不符合当前查询时失败。fuzzy 目标达到已证明的全局最低分时，前页探测直接使用时间 / ID 反向索引范围；分数较差的目标仍检查其他候选，避免漏掉复制时间更早、分数更好的前项。

`observe` 先注册失效通知再读取，避免提交落在订阅与首读之间；每次输出完整替换第一页。界面收到新快照会重置旧分页窗口，禁止混合不同 `ChangePosition` 的页。界面的默认页长 50，最多留三页；相邻页由一次 `browse` 请求获取。详细实现入口见 [`HistoryViewState.swift`](../ClipyApp/Sources/UI/HistoryViewState.swift) 和 [`HistoryWorkspacePaging.swift`](../ClipyApp/Sources/UI/HistoryWorkspacePaging.swift)。

性能辅助程序会报告读取行数、投影字节、匹配行数和进程资源；实际测量方法见 [testing.md](testing.md)。有界批次和页面空间是源码约束，运行时间和 RSS 改善需要同输入实测。
