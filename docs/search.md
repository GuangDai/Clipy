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

## 搜索框中的条件作用域

[`HistorySearchQueryCompiler.swift`](../ClipyApp/Sources/UI/HistorySearchQueryCompiler.swift) 将 `$...$` 内的条件与外部普通搜索文字分开。外部文字继续使用选择的 fuzzy、exact 或 regexp；条件作为独立 `conditionExpression` 与文字结果做 AND，不把整个查询改成 exact。多个条件块各自保留分组，再用 AND 连接；条件之间的普通文字仅去掉各段边缘空白后以一个空格连接，段内原始拼写保留。

```text
meeting $source:"TextEdit"$
^https:// $is:pinned$
$type:images source-id:com.apple.TextEdit$
source:literal
$10$
$10.50$
\$literalDollar
```

前两例的文字部分分别遵循当前所选搜索模式；第三例只有条件，第四例没有条件包装，因此 `source:literal` 是普通文字。成对的整数 / 小数金额仍按普通文字搜索，反斜杠美元符 `\$` 表示字面 `$`；条件引号内的 `$` 不结束条件块。未配对的金额与条件混用时，应写成 `\$10 and \$20 $type:text$`，避免美元符之间的配对歧义。未闭合块保留为当前编辑文字，闭合但语法错误的块给出明确解析失败，不静默退回更宽查询。外层包装和组合在建立大中间值前检查 4,096 UTF-8 字节上限。

regexp 模式只在输入开头或空白后的 `$` 开启条件块，模式内部的 `$` 保留正则含义，因此 `^report$ $type:text$` 同时保留末尾锚点和类型条件。该模式的外部 `\$` 保留反斜杠供正则匹配字面美元符；exact / fuzzy 则将它解为普通 `$`。regexp 中的条件块应与模式用空白分开，exact / fuzzy 仍支持行内条件块。保存的查询原文不改写；旧收藏在当前语法下无效时仍可读取、改名或删除，回放显示对应查询错误，不使整份收藏不可读。

History 的请求和观察分别携带文字 kind 与 `conditionExpression`；两者一起参与分页和观察身份。只有来源、类型、时间或置顶等元数据条件时不读取正文；条件含文字匹配时仍按需读搜索投影。混合查询保持外部文字模式的匹配和排序。直接 History `.expression` 接口仍接受未加 `$` 的原始表达式，包装语法由应用输入层拥有，不能把外部 API 的所有普通 term 重新解释成条件。

## 条件表达式

[`HistorySearchExpression.swift`](../Sources/HistoryCore/HistorySearchExpression.swift) 是纯解析器。`NOT` 优先于 `AND`，`AND` 优先于 `OR`，相邻条件等同 `AND`。括号改变组合顺序；双引号保留短语，其中可转义反斜杠和双引号。括号与 `NOT` 的嵌套受限制，解析错误包含原文 Character 位置。

```text
meeting OR "project notes"
type:images is:pinned
app:"TextEdit" date:2026-09-01..2026-09-30
source-id:com.apple.TextEdit NOT draft
```

支持 `app:` / `source:` 应用名称、精确 `source-id:`、`date:` 单日或范围、`before:`、`after:`、`type:text|images|links|all` 及 `is:pinned`。日期按 UTC 日解释，与机器时区无关。应用名称由应用层读取安装应用元数据并替换成来源 ID，同一次解析中相同名称只匹配一次，解析器本身不查询系统。替换在构造扩张节点前检查 4,096 字节、128 tokens 和 16 层嵌套上限；超出时明确失败，不截断匹配的应用。保存的相对日期搜索定义仍在使用时解析为当时日期，不能永久冻结为首次保存的日期。

来源条件检查项目所有仍保留的复制来源，不限于第一次或最后一次。一个项目先来自 old app、后来又来自 new app，两个来源都可以命中；`NOT source-id:old` 对这个项目为 false，否定的是“任意已记录来源命中”的整体结果。未知来源不命中正条件，但命中该正条件的否定。date / before / after 继续检查项目最近复制时间，不因为来源匹配到旧记录而改用旧记录的时间。

普通 `HistoryFilter.sourceApplication` 保留字面子串和 ASCII 忽略大小写规则，`%` / `_` 是字面字符；精确 `sourceApplicationIDs` 使用 byte-exact 标识。表达式 app / source 的未解析值使用 Unicode 忽略大小写的字面匹配，source-id 使用精确 UTF-8。各条路径的来源范围都统一为 retained `copy_sources`，不改变各自匹配规则。

## 搜索补全

[`HistorySearchCompletionEngine.swift`](../ClipyApp/Sources/UI/HistorySearchCompletionEngine.swift) 按搜索框实际 UTF-16 selection / caret 识别当前条件字段和值；普通外部文本不自动出现字段候选。候选包括字段、AND / OR / NOT、类型值、置顶值、日期和真实来源应用。匹配考虑忽略大小写前缀、有序子序列及短词的一次编辑 / 相邻交换；这是输入辅助，不调用正文搜索，也不是另一个完整表达式 parser。

空查询、刚获得焦点或条件之间的空白不自动抢列表方向键。输入开启条件块的 `$` 后立即显示字段候选；搜索结果发布和重复的原生输入通知保留候选及当前选择。显式入口为搜索框的 AppKit 标准完成命令 `complete:`（通常是 ⌥Esc），或搜索模式菜单的“插入条件 / 显示候选”；在块外插入成对 `$`，在块内列出当前可用字段。regexp 模式末尾的显式插入会按需增加分隔空格，补全与查询编译使用同一模式边界。Ctrl+Space 仅在应用实际收到该组合时兼容，系统可能先将它用于切换输入法。type 候选为 text / images / links / all，is 候选为 pinned，日期提供当日 UTC 模板。纯 quoted phrase 不自动给字段建议。接受候选替换 caret 所在整个 term；只有未闭合块的最后一个 term 补 `$`，在中间补全时保留后续条件，已有闭合符不重复。选区按完整字簇扩展，跨 term 的选区或落在半个字簇的 caret 拒绝补全，不切碎 Unicode 内容。

[`HistorySearchCompletionState.swift`](../ClipyApp/Sources/UI/HistorySearchCompletionState.swift) 每个输入框最多显示八条候选，控制候选选择和 replacement range。输入法正在组合时不生成候选、不替换 marked text；输入法命令优先，补全候选其次，列表导航与复制最后。插入经实际 field editor 应用并由正常文字变化回调更新查询，不由候选 owner 越过输入框直接改 History 选择。关闭候选、焦点离开、输入或查询代次变化都会取消旧请求，旧来源结果不得重新打开已关闭候选。

候选存在时上下方向键选候选、Tab / Return 接受、Esc 先收起候选；左右方向键继续移动文字光标。来源候选仍在加载或显示读取失败时，上下导航 / 确认命令也由候选框处理，不能误触列表复制。候选框关闭后恢复列表及文本输入的原行为。引擎只检查有界输入：最多 8,192 UTF-8 字节、caret 前 4,096 个 UTF-16 unit 和后 512 unit；当前 term 最多 256 unit，匹配 prefix 最多 128 unit，目标最多 1,024 unit。超出输入辅助范围时不给候选，不截断或改变真实查询；History 查询本身仍有独立 4,096 UTF-8 字节限制。

来源候选读取 [`ClipboardHistory.sourceApplications`](../Sources/HistoryCore/ClipboardHistory.swift) 的 `HistorySourceApplicationPage`，默认 / 最大每页 32 个不同 application ID，加一条有限 lookahead。ID 来自所有 retained `copy_sources.application`，排除 nil / 空观察，以字面顺序做 keyset seek 跳过重复；这个读取不打开 title、searchBody 或表示载荷。提交位置变化或另一 History 实例的游标返回 `snapshotExpired`，不会混合不同快照词汇。接口和值定义见 [`HistorySourceApplications.swift`](../Sources/HistoryCore/HistorySourceApplications.swift)，实际读取见 [`HistoryAuthority+SourceApplications.swift`](../Sources/HistoryStorage/HistoryAuthority+SourceApplications.swift)。

补全 worker 在后台分页检查完整来源词汇，只带回八条最佳结果。最多缓存 2,048 个 ID、256 KiB 元数据；更大词汇继续逐页选择候选，不常驻完整集合。应用显示名和标识一起参加候选匹配，选择后写入精确的 source-id 条件。输入不变而历史提交位置推进时，等待刷新期间保留当前候选和选择；新候选到达后按来源 ID 保留仍存在的选择，移除已无记录的来源。输入改变、失焦、关闭和输入法组合仍取消旧请求。并发提交使分页过期时至多重取一次；连续变化或读取失败显示可重试状态，不用当前可见历史页假造完整来源列表。

## 存储搜索路径

[`SearchWorker+SQLite.swift`](../Sources/HistoryStorage/SearchWorker+SQLite.swift) 为每次请求建立自己的只读连接和事务，在事务中捕获 `ChangePosition`。每批最多 32 行、1 MiB 投影 UTF-8 内容；有序页面首批只取页面与相邻命中所需行，连续密集命中时继续按剩余需求收紧，未命中后恢复普通批量。批次之间主动让出执行权并检查取消。标题、正文从严格校验的 SQLite UTF-8 BLOB 同步复制为拥有自身字节的 String，正文 SELECT 在请求内复用。请求不持有全库搜索语料、完整匹配 ID 数组或历史载荷。

[`SQLiteSearchIndex.swift`](../Sources/HistoryStorage/SQLiteSearchIndex.swift) 维护 contentless FTS5 postings。它对标准化 Unicode scalar 的一至三个连续值进行可逆整数编码，提供必要条件候选集；这些值不是内容哈希，也不决定是否真的命中。exact 最多抽取 16 个必要 gram 进行 AND；fuzzy 对有限的查询 scalar 做 OR；简单字面正则可用必要文本，复杂正则回到有界批次扫描。

候选稀疏时从 postings 读取候选；密集时直接按目标顺序读取并执行实际匹配，不再为每行重复查询 FTS 成员关系。选择稀疏路径只读有限 postings 输出，超过 4,096 个候选便视为密集；不通过完整词汇频次扫描决定路径。FTS 仅减少需要解码和匹配的行，最终匹配仍遵循 Foundation / Fuse 语义。metadata-only 表达式不读取无关搜索正文。

AND 两侧都检查必要文本条件，任一稀疏条件可以驱动候选读取；原有条件顺序仍决定匹配与高亮。独立条件密集时，也会检查外层搜索文本。重复 postings 探测只在本请求的同一快照中复用，键保留精确 UTF-8 字节，不跨请求保存结果。

## 复杂度与资源限制

[`ExactLiteralMatcher.swift`](../Sources/HistoryStorage/ExactLiteralMatcher.swift) 对适合的 ASCII 前缀预编译查询，按字扫描候选首字节，再确认候选。重复前缀导致失败确认过多时转入 KMP，使这条快速路径保持 `O(n + m)` 最坏时间和 `O(m)` 查询准备空间，`n` 为被检查文本长度、`m` 为查询长度。非 ASCII 或 CR 等不适用情形交给 Foundation 保留既有匹配与坐标语义，不能把 ASCII 路径复杂度承诺套在所有 Unicode 输入上。

fuzzy 的 Fuse 固定参数是 threshold 0.7、location 0、distance 100、忽略大小写、不 tokenize。每次请求只编译一次查询。默认相关度排序用有限大小的页面候选选择，不保留全部匹配；已获得不能再被后续有序行改善的最佳页面时可提前结束。存在查询仍需要检查大部分或全部候选，不声称任何搜索都是常数时间。

正则在访问存储前验证长度、可编译性和已知危险形状。复杂匹配使用带 progress callback 的迭代器，整个请求的正则匹配时间预算为 2 秒；SQL 获取和主动让出执行权的时间不计入这个匹配预算。超时或引擎中途放弃会使整次请求失败，不返回看似完整的部分结果。这不是所有 native matcher 的任意时刻抢占保证。

搜索快照最长持有 30 秒；过期明确失败并释放事务。SQLite progress callback 和每 32 行检查共同让取消及截止时间影响 SQL 与扫描。读取完整正文、构造片段及修订计数只为真正需要的结果进行。

每个 History 实例最多同时持有四个搜索快照，包含定位目标及前后页读取。额外请求在打开连接前返回 `temporarilyUnavailable(.factProof)`，不进入等待队列。取消、失败和完成均先关闭读取事务再释放名额；界面结束加载并提供刷新重试。

## 分页与观察

页面 limit 为 1 至 500。按排序 anchor 继续翻页，不把全部结果读入内存再截取。游标封装快照位置、请求身份、方向和排序 anchor；提交后旧位置或改变 query / filter / sort 的游标明确失效。`startAround` 在新的权威快照中定位指定项目；项目不存在或不符合当前查询时失败。fuzzy 目标达到已证明的全局最低分时，前页探测直接使用时间 / ID 反向索引范围；分数较差的目标仍检查其他候选，避免漏掉复制时间更早、分数更好的前项。

`observe` 先注册失效通知再读取，避免提交落在订阅与首读之间；每次输出完整替换第一页。界面收到新快照会重置旧分页窗口，禁止混合不同 `ChangePosition` 的页。界面的默认页长 50，最多留三页；相邻页由一次 `browse` 请求获取。详细实现入口见 [`HistoryViewState.swift`](../ClipyApp/Sources/UI/HistoryViewState.swift) 和 [`HistoryWorkspacePaging.swift`](../ClipyApp/Sources/UI/HistoryWorkspacePaging.swift)。

性能辅助程序会报告读取行数、投影字节、匹配行数和进程资源；实际测量方法见 [testing.md](testing.md)。有界批次和页面空间是源码约束，运行时间和 RSS 改善需要同输入实测。

搜索刷新、条件补全和原生输入的回归用例分别位于 [`HistoryInputResponsivenessTests.swift`](../ClipyApp/Tests/PresentationTests/HistoryInputResponsivenessTests.swift)、[`HistorySearchCompletionStateTests.swift`](../ClipyApp/Tests/PresentationTests/HistorySearchCompletionStateTests.swift)、[`HistorySearchFieldHostedTests.swift`](../ClipyApp/Tests/ClipyIntegrationTests/HistorySearchFieldHostedTests.swift) 和 [`SearchCompletionJourneyUITests.swift`](../ClipyApp/Tests/ClipyUITests/SearchCompletionJourneyUITests.swift)。实际应用用例验证结果刷新后的候选点击、Tab 插入 Safari 来源、左右键编辑及旧来源命中；原生宿主用例验证窄输入框的光标可见、窗口调整后的候选高度及 marked text。marked text 宿主验证不代表已覆盖所有系统输入法。
