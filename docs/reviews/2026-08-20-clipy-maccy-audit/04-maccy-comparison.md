# Clipy 与修改版 Maccy 的能力、架构和性能对比

> 审查日期：2026-08-20（UTC）
>
> Clipy 初始快照：`61b418bf9b9767ac84f81da3e65cfe447a509cbd`
>
> Clipy 动态 UI 快照：`a028c8c579b365f6c2183c5042ee78a365553d2a`
>（2026-08-20T00:16:36Z），随后有访问级别修复
> `9c6e3b48f1bbf0c642ccbb61b233319003b6fefb`
>（2026-08-20T00:21:44Z），以及 `alertWindow` 编译与 dwell-test timeout
> 修复 `9a637a6c58914c4ef586f45f2996656b69f1c241`
>（2026-08-20T00:31:15Z）。本报告的最终 UI 源码检查以 `9a637a6c` 为准；
> `9c6e3b48` 的 CI 失败仍是时间线上可复核的证据。
>
> Maccy 快照：`/lzcapp/document/Projects/Maccy`,
> `master@818f03d0e0d3912e1ea23657e2630902ebf5cc8b`。其已跟踪源码是比较对象；
> 工作树内未跟踪的设计文档只作为意图，不作为已实现证据。
>
> 结论截止时间：将在总报告收口时填写。所有时间均为 UTC。

## 1. 结论

**当前 Clipy 不能被证明、也不能准确描述为“全面超越 Maccy”。** 更精确的
结论分为四部分：

1. **一致性、持久化语义和模块边界：Clipy 明显更强。** 单一公开
   `ClipboardHistory` 边界、纯 Domain planner、单写者 Authority、稳定业务 ID、
   OCC、版本化 codec、事务 receipt/position、不可变 revision lineage，以及
   编译/源码 gate，构成了 Maccy 当前实现没有的系统性保证。两者都已正确遵守
   “fingerprint 只产生候选、最终仍 byte-exact 确认”，后者是共同基线而非差异化。
2. **当前产品覆盖：Maccy 更完整。** Maccy 已有真正的自动粘贴、无格式粘贴、
   多文件、可配置快捷键、按应用/类型/正则过滤、暂停/忽略下一次、窗口与预览
   配置、App Intents、Sparkle updater、unsigned package workflow 和当前工程纳入
   的 31 个 locale。Clipy 目前只覆盖其中
   一部分；V2 文档中的未来能力不能计为当前能力。
3. **内存更小、速度更快：没有可比证据，而且 Clipy 已有反向风险证据。** 两个
   仓库没有在同一机器、Release 构建、相同语料、相同操作语义下运行 A/B。
   Clipy 自己的 5,000 × 256 KiB 最坏界 exact-search 记录为约 1.59 秒 p50、
   1.59 GiB peak RSS，并仍为每次请求构造约 1.22 GiB 的 corpus snapshot；因此
   不能使用全局“轻量/更快”表述。
4. **时间复杂度全面更低：结论为否。** Clipy 的 recent 页面对应用层物化有结构
   优势，但 capture 的保留清单、search corpus、retention expansion 仍随全部保留
   项增长；retention planner 还执行比较排序，最坏为 `O(N log N)`，与规格和
   fixture 标注的 `O(N)` 不一致。必须逐 workload 比较，不能给整个应用标一个
   复杂度等级。

支持边界：以上是当前快照的源码、文档和既有 CI artifact 所能支持的结论；它不
否定 Clipy 在完成下列缺口后取得实测优势的可能性。

## 2. 当前功能覆盖矩阵

“是”仅表示当前已跟踪源码中存在可达实现，不表示产品质量或性能已验收。

| 能力 | Clipy `9a637a6c` | Maccy `818f03d` | 当前判断与证据 |
|---|---|---|---|
| 历史捕获、去重、置顶、删除、清空 | 是 | 是 | 两者均覆盖核心循环，也都在 fingerprint 相等后 byte-exact 确认；Clipy 的差异是 typed receipt、稳定业务 ID、closed action 和更完整的 collision/fact-proof 测试。 |
| 任意 UTI 原样保存/写回 | 第一 pasteboard item 内除 marker 外的合法 typed bytes 均可 round-trip | 只接纳 fileURL/HEIC/HTML/JPEG/PNG/RTF/string/TIFF 八类 | Clipy 对未知/自定义格式更可扩展；可视化仍只覆盖已识别类型。Maccy `IngestFilterRules.supportedTypes` 是明确产品白名单。 |
| 不可变内容修订、回退和 OCC | 是 | 否 | Clipy 的 Canonical/Effective Content、revision lineage 和 `ContentVersion` 是实质能力优势。 |
| count/age/总字节/revision 保留策略 | 引擎是；UI 回读不完整 | 主要为 count 与单项大小 | Clipy 维度更强，但设置页打不开已持久化策略；直接 Apply 会以默认值替换真实配置，不能算完整产品闭环。 |
| UI 可配置历史上限 | 1...5,000 | 1...999 | Clipy 覆盖更大容量需求；这也使 5,000 项 search/RSS 证据成为发布责任，不能只把上限当宣传数字。 |
| recent 分页和 snapshot observation | 是 | 全量内存投影 | Clipy 的 purpose-specific DTO 边界更适合大历史；实际数据库和 RSS 优势仍需测量。 |
| exact/fuzzy/regexp 搜索 | 是 | 是 | 两者 fuzzy 均解析到同一 Fuse 1.4.0 revision。Clipy 已把 query 限在其单 `Int` Bitap 可表示的 64 Characters；Maccy 无 query cap，≥65 有错误/崩溃窗口，见 §2.2。 |
| mixed 搜索（exact→regexp→fuzzy fallback） | 否 | 是，但继承长 fuzzy query 风险 | Clipy `HistoryCore/Requests.swift:5-13` 只有三种模式；Maccy `SearchMode.swift:6-23` 和 `SearchActor.swift:123-141` 实现 mixed。当前 Clipy 不是搜索功能超集，但 Maccy 的新增模式也未完整守住输入边界。 |
| 缩略图 single-flight | 是 | 有异步图像管线 | Clipy storage 不保留 completed bytes，但当前 UI 又引入 500 个 decoded-image/miss cache；其必要性未满足 G1 证据门槛。 |
| 大图预览 | 是 | 是 | Clipy 当前在 SwiftUI 主 actor 同步 ImageIO downsample；这违反自身 V1/V2 约束，不能据此判为 UI 优势。 |
| 捕获多个 pasteboard item / 多文件 | 否：只取 `.first` | 读取全部 item 后扁平化；多 file URL 可 round-trip | `PasteboardAdapter.swift:44-48,65-83` 明确冻结第一项；Maccy `PasteboardSource.swift:74-90` 读取全部，但 `Clipboard.swift:255-276` 把 item boundaries 扁平为一个 contents 数组。因此只能证明多文件能力，不能说它保留任意 pasteboard item 边界。 |
| 选择后复制到剪贴板 | 是 | 是 | Clipy 当前名为 `paste` 的路径实际只写 pasteboard 并关 panel。 |
| 自动向前台应用发送粘贴 | 否 | 是 | Clipy `AppComposition.swift:220-227` 没有发送 Command-V；Maccy `Clipboard.swift:141-172` 通过 CGEvent 执行。是否默认启用属于产品选择，但“功能超集”不成立。 |
| 无格式粘贴 | 否 | 是 | Maccy `Clipboard.swift:100-129` 和 README usage 已实现；Clipy 无对应 action/UI。 |
| 可配置全局快捷键 | 否：固定 ⇧⌘C | 是 | Clipy `GlobalHotKey.swift:56-64` 固定 chord，注册失败在 `AppDelegate.swift:70-74` 未显示；Maccy 使用 KeyboardShortcuts 设置面。 |
| pin 顺序与 alias | 显式 first/last reorder，持久化 total order | 可配置 pinned lane、每个 pin 有快捷 alias；无 Clipy 同语义的显式 reorder | 两者覆盖不同需求。Clipy 的确定性顺序/校验更强；Maccy 的快速选择和布局设置更成熟。 |
| sort 与内容类别设置 | 当前固定 history order；保留任意合法 UTI | 可配置 sort，files/images/text toggles 和单项大小上限 | Clipy 的通用内容模型更可扩展；Maccy 给普通用户更多即时控制。 |
| quit/系统剪贴板清理 | 否 | 可配置 clear-on-quit / clear system clipboard | 隐私行为需作为显式产品选择，而不是默认复制。 |
| 暂停、忽略下一次捕获 | 否 | 是 | Maccy README 62-63 及 Defaults keys 35-36；Clipy 只有固定 confidential marker 防线。 |
| 按应用、类型、正则过滤 | 否 | 是 | Maccy `Defaults.Keys+Names.swift:30-48`；Clipy 没有用户配置面。 |
| Panel 位置 | 是 | 是 | Clipy 新增 cursor/status item/center/last；两者都有位置选择。 |
| Panel 尺寸与预览布局配置 | 固定 400×560 + 320 preview | 可调整并持久化 | Maccy 默认 450×800、preview width、preview delay/limit 等在 `Defaults.Keys+Names.swift:56-96`。Clipy 的固定尺寸不能覆盖小屏、长内容和多种阅读偏好。 |
| App Intents / 自动化 | V2 设计，未实现 | 是 | 未来设计不可计入当前产品。Clipy 的 grant/audit 方向更严格，但也尚未交付。 |
| 本地化 | 未完成 | 当前工程 knownRegions 31；文件树有 41 个 locale，10 个被 project.yml 显式排除 | Clipy 当前无 `.xcstrings`/`.strings`/`.lproj`，且有大量原始英文 literal；不满足自身 state-3。不能把 Maccy 磁盘上的 41 个目录都算作已打包覆盖。 |
| 应用内更新 | 未完成 | 是 | Maccy 有 `SoftwareUpdater`/Sparkle；Clipy 无 updater。 |
| package/publish workflow | 未完成 | 有 unsigned arm64 zip + SHA-256 workflow | 修改版 Maccy `release.yml:38-47` 明确 `CODE_SIGNING_ALLOWED=NO`，`package-app.sh` 不 codesign/notarize；因此它只有更多 packaging 基础，不是完整发行验收。 |
| 该修改版的签名、公证、Homebrew 发布 | 未完成 | 未证明 | README 的 release/Homebrew 文案来自上游产品，不能证明本地 fork `818f03d` 已签名、公证或进入对应 cask。 |
| 最低系统覆盖 | macOS 26+ arm64 | macOS 14+ | Clipy 可以专注最新 API，但无法声称覆盖更多用户设备。 |

### 2.1 Clipy 已经形成的真正差异化

以下不是未来蓝图，而是当前源码中有实现和语义测试的优势：

- Canonical Content 与 Effective Content 分离，revision append/revert 不破坏原始捕获；
- closed `HistoryAction`、typed rejection/receipt、`ChangePosition` 与
  `ContentVersion` 的明确推进规则；
- xxh3 候选/byte-exact confirm 被更明确地纳入 typed fact proof、forced-collision
  fixture 和完整 transaction 语义；但修改版 Maccy 也做最终字节确认，因此不能把
  “collision correctness”本身算成 Clipy 独有功能；
- 多 candidate 时 Clipy 以完整事实执行确定性 winner ranking；Maccy containment
  candidate 顺序明确 unspecified，并在找到第一个 byte-confirmed candidate 后返回。
  这使 Clipy 的 coalesce identity 在碰撞/多候选下更可复现；
- 单 Authority 写入、事务内事实证明和 fresh-context 可见性；
- versioned blob codec、migration 和 fail-closed corruption 处理；
- count、age、总字节、revision count/bytes 的组合保留模型；
- `HistoryCore`/Domain/Storage/Adapter/UI 下向依赖和 public-symbol、import、
  concurrency escape-hatch gates。

这些能力足以支持“Clipy 的历史内核更严谨、扩展边界更清楚”，但它们并不自动
推出产品覆盖、UI 质量或性能胜出。

### 2.2 Maccy 的长 fuzzy query 是 Clipy 已关闭而对方未关闭的安全差异

两仓库当前都解析到 Fuse 1.4.0 commit
`26ba868691b2d8b7bf2b1322951eb591be70ccca`。该版本的
[`createPattern`](https://github.com/krisk/fuse-swift/blob/26ba868691b2d8b7bf2b1322951eb591be70ccca/Fuse/Classes/Fuse.swift#L78-L91)
直接在一个 `Int` 上构造 mask，初始化参数 `maxPatternLength` 没有被读取；搜索循环
随后执行 `(1 << i) - 1`。Clipy 的既有审查和 macOS regression 已把公开 fuzzy
query bound 降到 64。修改版 Maccy 的 `SearchActor.swift:189-191` 直接把任意长度
query 交给 `createPattern`，UI/session 也没有前置 cap。

因此 Maccy 在当前 64-bit arm64 上，65–89 Character 的 absent fuzzy query 会因
mask 无法表示而产生错误/空结果，达到搜索循环 `i == 63` 的 ≥90 Character query
还可触发 checked subtraction trap；mixed 在 exact/regexp 都无结果而 fallback 到
fuzzy 时继承同一路径。这个结论来自相同 dependency source 与 Maccy 的无边界调用，
不是一般性“第三方库可能有 bug”的猜测。需要在修改版 Maccy 增加 63/64/65/89/
90/100 长度 sweep；在此之前，Maccy 的 mixed 是功能广度优势，但不是完整可靠性
优势。

## 3. 架构与模块对比

| 维度 | Clipy | 修改版 Maccy | 可支持的判断 |
|---|---|---|---|
| 模块边界 | 5 个 Swift target + composition root，只有 HistoryCore 公共 seam | 单 app target 内的目录/协议/actor 分层 | Clipy 的边界由编译器和 gate 强制，更容易局部替换和审计。 |
| 写入模型 | `HistoryAuthority` 单写者；operation-local context；transaction 是 commit primitive | ingest actor context 与 main-context persistence 并存 | Clipy 的顺序与一致性模型更集中；这不代表吞吐自然更高。 |
| Domain | Foundation-only 纯 planner，无 I/O/clock/ID generation/async | 业务逻辑分布在 ingest、history、UI projection | Clipy 更适合 property/fixture 测试和未来演进。 |
| UI 数据 | page/detail 等不可变 DTO | `HistoryItemDecorator` 全量主 actor 投影 | Clipy 结构上减少浏览面常驻对象；Maccy 避免每次 query 重建全文 corpus。两者是不同内存取舍。 |
| 服务定位 | gate 禁止 mutable `.shared/.current` | 当前至少有 Clipboard/Storage/PerfRecorder/AppState/History 等 shared/current | Clipy 的依赖方向与测试注入更整洁。不能据此断言 Maccy 当前行为错误。 |
| 第三方依赖 | 1 个远程 Fuse + vendored xxh3 | 约 10 个直接远程 package | Clipy 的供应链与升级面更小；自己维护 Carbon/panel 等代码也增加平台正确性责任。 |
| 代码体量 | production Swift 约 28,004 行/113 文件；test 约 34,234 行/130 文件 | production Swift 约 13,041 行/129 文件；test 约 11,383 行/70 文件 | Clipy 的规格与测试更深，但实现并非天然“更小/更简单”；应继续控制 accidental complexity。 |
| 故障策略 | durable anomaly typed fail-closed | Maccy 会隔离损坏 store 并重建可用 store | Clipy 偏数据正确性，Maccy偏恢复可用性；需要明确产品恢复/导出策略，不能只用一个“更安全”概括。 |

### 3.1 架构整洁度的保留意见

Clipy 的目标图更整洁，但当前实现已经出现“文档写了边界、gate 却没有执行同一
边界”的漂移：`PresentationUI` 导入 ImageIO 并在 MainActor 解码，而
`scripts/import_gate.py:60-64` 和 `.swiftlint.yml:69-75` 都未禁止 ImageIO。
因此应将“模块整洁”定义为 **源码依赖 + 执行上下文 + 自动 gate 三者一致**，而
不是只看 SwiftPM target 箭头。

## 4. 复杂度比较

记 `N` 为保留项数（Clipy hard bound 5,000）、`B` 为每项被扫描的 body 大小、
`P` 为 pinned 数、`K` 为实际淘汰数、`I` 为输入表示总字节。下表是源码上界，
不是墙钟速度预测；SwiftData/SQLite 查询计划未由静态源码完全决定。

| Workload | Clipy 当前路径 | Maccy 当前路径 | 判断 |
|---|---|---|---|
| recent 首屏/下一页 | 首屏只形成有界 page；每次下一页 append，因此 UI 持有 `V` 个已加载 DTO（`V≤N`）；same-timestamp/anchor fallback 还会 fetch 最多 N 行并作 `O(N log L)` 有界选择 | 启动/reconcile `fetchAll` + decorate + sort，`O(N log N)`，之后读 resident list | Clipy 是渐进物化而非“永远一页”；深滚最坏仍 O(N)，但 value DTO 通常比全量 @Model decorator + search corpus 轻。RSS 尚未证明。 |
| novel capture/coalesce | 输入准备 `O(I)`、candidate exact confirm；完整 retained inventory 还会按 ID sort，端到端至少包含 `O(N log N)` | signature candidate 路径 + retention count/tail 查询；应用层不必每次构造完整 canonical corpus | 不能声称 Clipy 全面更低；需分别测 novel、duplicate、collision、at-cap，并把 inventory sort 纳入计时/operation count。 |
| exact search | 每请求读取/投影全部 N 个 full bounded body、按默认序全量 sort，再扫描；至少含 `O(N log N)` + matcher cost 与大 snapshot。eligible ASCII matcher 近线性，Foundation Unicode fallback 不从源码宣称统一 `O(NB)` | actor 常驻 bounded corpus，但每 query 仍 `order.compactMap` 形成 O(N) value array（String 主要 COW），再执行 Foundation matching | Clipy 多每请求 projection/sort/snapshot；Maccy 多持续 resident corpus。没有统一低阶结论。 |
| fuzzy search | Bitap 类逐行工作、actor 串行，命中后再 `O(H log H)` 排序 | 相同 Fuse revision；每 query O(N) value array，命中也 `O(H log H)` 排序 | 无全局胜者；Clipy 有 64 query safety bound，Maccy 长 query 有错误/崩溃窗口。 |
| R1/R2 retention | common inventory 先按 ID sort，planner 又排序 R1/R2 候选；最坏 `O(N log N)` | count/tail fetch；具体 DB selection 依索引/查询计划，应用物化约 `O(K)` | Clipy 的规格/fixture `O(N)` 声明不成立，也不能证明低于 Maccy。 |
| pin reorder | fact loader 先取完整 `N` 项并按 ID sort，再形成/重排 `P` 个 pinned；最坏 `O(N log N + P)` | Maccy 的 pin 后完整 resident list resort 可到 `O(N log N)`，且没有 Clipy 同语义的显式 first/last reorder | Clipy 不能据当前 fixture 声称复杂度更低；两边语义先对齐再测。 |
| clear | common inventory 全量读取并按 ID sort，最坏含 `O(N log N)`，再形成/执行删除 | bulk/main-context 删除路径；实际 store cost 需 trace | Clipy 不能把 bounded N 或宽松 ratio 写成低一阶复杂度。 |
| thumbnail concurrent duplicate | storage single-flight，source hydrate/decode 一次 | 有异步图像管线和已有缩略图/预览策略 | Clipy 的 single-flight 是强语义；UI completed cache 与主线程 decode 使端到端结论尚未成立。 |

Retention 的关键反例在 `Sources/HistoryDomain/PlannersRetentionExpansion.swift:165,172`：R1
victims 和 R2 candidates 都执行 `sort`。`docs/v2/V2-02-retention.md:1781-1803`
写的是 `O(retained)`，而 `Sources/HistoryPerfRunner/PerfFixtures.swift:247-269`
用 100→300、允许 6× 的“linear” envelope；`N log N` 的增长能轻易通过这个阈值。
正确做法只有两类：把承诺和测试改成诚实的 `O(N log N)`，或让上游提供已证明的
eviction order/使用能达到目标上界的选择算法。此处不能靠改注释解决算法事实。

更广的共同原因是 `FactLoaders.swift:205-243` 对完整 retained inventory 一律按 ID
sort；该 loader 被 capture、pin、clear、retention 等路径复用。因此这些端到端
workload 不能只按各自 pure planner 的线性部分命名。Pin reorder 也有相似的
proof mismatch：
`Sources/HistoryStorage/MutationFactLoaders.swift:76-100` 先调用
`FactLoaders.swift:205-243` 获取全部保留项，后者在 `:242` 按 ID comparison sort。
因此即使纯 Domain reorder 只随 `P` 增长，端到端也不是 fixture 名称暗示的纯
`O(P)`；50→200、6× 的 envelope 同样不能辨别 `P` 与 `P log P`，更没有固定 `N`
与 `P` 的独立实验。Search 则在
`HistoryAuthority+SearchCorpus.swift:116-160,280-282` 每请求全量投影并 sort；
recent 的正常 bounded page 不等于最坏界，same-timestamp exactness fallback 在
`HistoryAuthorityReadRows.swift:266-323` 会 materialize 最多 N 行并执行
`O(N log L)` selection。

## 5. 已有性能证据以及它不能证明什么

### 5.1 Clipy 的可复核记录

CI run [32270414876](https://github.com/GuangDai/Clipy/actions/runs/32270414876)
对应 head `61b418b`，不是当前 `9a637a6c` 的 CI 证明。其
的 `perf-fixtures.json` SHA-256 为
`b5d3dc9b83ecc3876f297a7cb6c5003a99fd10249a4023a6d2260c9f14d7169a`；机器为
VirtualMac2,1 / Apple M1 Virtual / 3 processors / 7,516,192,768 bytes RAM /
macOS 26.5.2。部分 median：

| Clipy fixture | 小规模 → 大规模 | median ms | ratio | 证据上限 |
|---|---:|---:|---:|---|
| capture retained-count | 200 → 1,000 | 14.28 → 57.39 | 4.02× | 通过宽松复杂度 envelope；不是 UX latency SLO。 |
| persistent warm open | 200 → 1,000 | 57.27 → 188.56 | 3.29× | 不含进程启动/冷盘；不是 launch-to-ready。 |
| pin reorder | 50 → 200 | 8.85 → 30.15 | 3.41× | 支持 bounded growth，不是 Maccy A/B。 |
| retention mass eviction | 100 → 300 | 70.92 → 288.47 | 4.07× | 6× gate 不能区分 `N` 与 `N log N`。 |
| retention expansion capture | 100 → 300 | 13.58 → 34.30 | 2.53× | 只覆盖该 fixture 的 projection lane。 |
| exact search | 100 → 400 | 7.08 → 26.69 | 3.77× | 小 body/小 N；不代表 5,000 × 256 KiB。 |
| thumbnail single-flight | sequential → concurrent wall | 0.278 → 0.275 | 0.99× | 很好地证明合并 identical in-flight work；不证明 UI scroll/frame time。 |

更重要的上界记录在
`docs/V1-Verified/07-finding-dispositions.md:238-242`：5,000 × 256 KiB、
absent-term exact search 在 matcher 优化后仍约 1.59 秒 p50、1.59 GiB peak RSS，
每次请求仍有约 1.22 GiB full snapshot。该 lane 明确是 worst-bound record-only，
不能外推日常体验；但它足以否定“已经证明内存更小、速度全面更快”。

`RenderStormAndMemoryTests` 的 RSS 条件只约束多轮增长（leak tripwire），新加入的
`SmokeMeasurementTests` 也以 record-only/宽松 ceiling 为主；两者都不是绝对 idle/
open/search RSS budget，更不是跨应用 A/B。

### 5.2 为什么不能把两个仓库现有 CI 数字直接相减

Maccy 当前 CI 有自己的 XCTest/perf 日志，例如 1,000 条 mixed-search 长 body 的
一次记录约 3.32 秒，而 Clipy 上表 exact 400 条约 26.69 ms。它们的 mode、语料、
body 长度、构建方式、macOS 版本、cache 状态和计时边界都不同。比较这两个数字
会同时改变多个变量，不能归因于实现。

静态上，Maccy 的 `HistoryStoreProjector.load/reconcile` 会 `fetchAll`、decorate、
sort 并保留完整投影（`Maccy/Observables/HistoryStoreProjector.swift:43-67,97-129`）；
Clipy 的 recent UI 首屏按页物化，并随 `loadNextPage` 把 page append 到 rows；因此
未深滚时只持有 `V` 个已加载 value DTO，深滚到底仍可到 `O(N)`。相较 Maccy 从
启动就持有全部 `@Model` decorators，可提出“Clipy 日常 browse working set
**可能**更低”的假设，但不能写成永远只持有当前页。反过来，Maccy `SearchActor`
增量持有 capped corpus；它每次 query 仍按 `order` 建一个 O(N) value array，但
String storage 主要以 COW 共享，不会像 Clipy 一样重新从 SwiftData 投影 full body。
Clipy
每次搜索构造 full snapshot；搜索峰值上 Clipy 未必占优。两项都必须测量。

## 6. UI 与需求覆盖判断

### 6.1 当前 UI 做得好的部分

- 非激活 floating panel、status item、全局 summon、cursor/status item/center/
  last-position 位置模型，形成了可用的菜单栏交互骨架；
- search、selection、pin/reorder/remove/clear、details、revision editor、retention
  设置和 preview 已连到真实 HistoryCore seam，而不是展示型 mock；
- preview dwell/debounce、`HistoryItemReference` version key 和 snapshot replacement
  方向正确；
- 部分重要 control 已有 accessibility label/hint，keyboard-first 方向清晰。

### 6.2 当前不能判为“更合理、更全面”的原因

1. `ThumbnailStore` 和 `HistoryPreviewView` 都在主 actor 做 ImageIO decode；大图
   preview 还先通过 details DTO 取完整 Effective Content bytes。这违反
   `docs/01-architecture.md:184-186` 和 `docs/v2/V2-07-ux.md:135-141`，会让 panel
   frame/hang 风险落在 UI 热路径。
2. 设置页无法读取持久化 retention policy：count 固定显示 200，V2 dimensions
   固定显示全关闭。它不仅“不够友好”，还可能在用户点击 Apply 时覆盖真实策略。
3. panel/preview 尺寸固定，不支持 Maccy 已有的窗口、preview width、delay、text/
   image preview limits；长文本用 SwiftUI `Text` 截至 50,000 Characters，尚无
   layout/frame-time 证明。
4. 所有用户字符串仍为原始英文，缺少 String Catalog 和 locale-aware formatter；
   自身 V2 state-3 要求没有完成。
5. 固定 hotkey 冲突、launch-at-login 注册失败、pasteboard 写失败等都没有明确
   用户反馈；可恢复性弱于一个成熟设置面。
6. Clipy 的 `paste` 当前只是 copy-to-pasteboard，命名和用户预期不一致；如果
   产品刻意选择不请求 Accessibility 权限，应在 UI 中明确区分 “Copy” 与可选
   “Paste”，而不是把缺失副作用藏在内部名称里。

Apple API/HIG 的逐项核验、官方链接和支持边界见 `03-apple-platform.md`。其中
尤其需要处理非公开 `showSettingsWindow:` selector；macOS 26 已有公开的
AppKit-to-SwiftUI Settings 打开路径。`9a637a6c` 虽修复了不存在的
`NSApplication.alertWindow` 成员导致的编译错误，却改为用 AppKit-private 类名
`_NSAlertPanel` 扫描 windows（`FloatingPanel.swift:218-224`）；这与 Maccy 的
同名 helper 对齐，但没有与 Apple 的公开契约对齐，系统升级时仍可能静默失效。

## 7. 达到“可证实超越”的最低验收矩阵

### 7.1 同机 A/B 设计

两个 app 必须在同一台目标硬件、同一 macOS、同一电源/温控状态运行；使用
Release + WMO、相同签名/沙箱状态，fresh process 与 warm process 分开。普通
latency cell 至少 100 个有效独立样本才报告 p50/p95；p99 至少需要 1,000 个样本
或专门的 tail methodology，否则省略。5,000 项等昂贵 process-level cell 若只能
做约 30 次，应报告 median/分位不确定性和全部 raw samples，不伪装成可靠 p99。

共同支持范围固定 corpus：50/200/999 项；text/image/file/mixed 分层；短体和共同
可支持的 body bound；相同重复率、候选率、pin 数和 retention 配置。Clipy 的
1,000/5,000 项作为 capacity/out-of-range stress 单列：Maccy 标记 `unsupported`，
不可把少做工作的一方纳入 latency 比值。每项记录：

- launch-to-capture-ready、physical footprint、dirty memory、idle/panel-open/
  settled/peak RSS（RSS 不能单独代表 macOS memory pressure）；
- novel capture、exact duplicate、forced/high-candidate capture、at-cap capture；
- panel first open、recent first/next page、selection-to-preview、cold/warm thumbnail；
- exact/fuzzy/regexp 的 present/absent/Unicode/long-query，含连续输入与取消；
- copy、auto-paste、plain-text paste、多文件 round-trip；
- 60 秒 scroll/search interaction 的 frame time、hang、CPU、energy、wakeups；
- store/binary 大小、后台 10 分钟 steady-state CPU/RSS。

每个 workload 先定义相同语义；如果一方缺功能，该 cell 标 `missing`，不能用更少
工作换取更快数字。预先注册两个不同判断：非劣势 gate 用有意义的 regression
margin；“更快/更小”则必须用有实际意义的 superiority margin，且置信区间完整
越过该 margin。仅仅“CI 内不退化”只能证明 non-inferiority。不要平均所有数字
得到一个总分。

### 7.2 发布前的产品门槛

在使用“全面超过”描述前，至少应关闭：

1. 主线程 decode 与 ImageIO import/gate 漂移；
2. retention policy readback，以及 invalid projection scalar 的 fail-closed 校验；
3. pasteboard 多 item/多文件语义、声明类型读取失败与写入 Bool 失败处理；
4. 明确 Copy / Paste / Paste without formatting 的产品语义和权限路径；
5. 可配置且冲突可见的 hotkey、可调整 panel/preview、完整键盘/VoiceOver 流；
6. String Catalog、本地化格式化、打包/签名/公证/更新/回滚与恢复说明；
7. 修正 retention 的 `O(N)` 声明或实现，并用可区分复杂度的规模/operation count；
8. 完成上述同机 A/B，尤其解决 5,000 项 search 的 1.22 GiB snapshot / 1.59 GiB
   peak RSS；
9. 决定 Maccy 已有的过滤、暂停、App Intents、预览配置哪些是目标需求，哪些明确
   非目标，并在产品文档中说明，而不是把未实现项默认为“不需要”。

## 8. 证据地图与非结论

| 结论 | 直接原因 | 主要证据 | 当前不能推出 |
|---|---|---|---|
| Clipy 内核边界更强 | 编译 target + 单 seam + 单写者 +纯 planner + gates | `Package.swift`; `docs/01-architecture.md`; Sources/Tests | 不能推出 app 更快、RSS 更低或 UI 更好。 |
| Maccy 当前功能更广 | 已跟踪 settings/clipboard/intents/locales/release surfaces | Maccy README、Defaults、Clipboard、Intents、resources/workflows | 不能推出每项实现的语义都比 Clipy 严谨。 |
| Clipy 性能全面胜出未证明 | 无相同实验；自身 worst-bound search 很高 | run 32270414876；V1 finding disposition | 不能推出 Clipy 日常场景一定慢于 Maccy。 |
| Clipy recent working set 可能更低 | 首屏/浅滚渐进 value DTO（V 行）对比 Maccy 启动即 full projector | 两仓库 projection source | 深滚到底仍 O(N) DTO；没有 footprint/RSS/SQL trace 时不能称为已测优势。 |
| retention 不是 `O(N)` | 对未排序 victims/candidates 做 comparison sort | planner `:165,172` | 不能仅凭 100→300 的 6× gate 判断真实复杂度。 |
| 当前不是功能超集 | auto/plain paste、multi-file、filters、locales 等缺失 | 功能矩阵中的源码 | 不代表这些都必须进入产品；可通过明确非目标缩小“全面”承诺。 |

本报告刻意不作三类断言：不把 V2 设计当作实现；不把不同 CI 环境的数字当作
A/B；不把“架构上可能减少常驻对象”写成“已证明 RSS 更低”。
