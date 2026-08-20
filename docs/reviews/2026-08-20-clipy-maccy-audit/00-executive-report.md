# Clipy 当前实现多 Agent 审查总报告

> 审查开始：**2026-08-20T00:07:11Z（UTC）**
>
> 结论截止：**2026-08-20T01:13:24Z（UTC）**
>
> 初始 Clipy：`codex/v2-implementation@61b418bf9b9767ac84f81da3e65cfe447a509cbd`
>
> 动态 UI 时间线：`a028c8c`（2026-08-20T00:16:36Z）→
> `9c6e3b48`（2026-08-20T00:21:44Z）→
> `9a637a6c`（2026-08-20T00:31:15Z）
>
> Maccy：`/lzcapp/document/Projects/Maccy`,
> `master@818f03d0e0d3912e1ea23657e2630902ebf5cc8b`
>
> 约束：本次审查没有修改任何实现、测试、workflow、配置或既有规格；只新增本目录下的审查文档。

## 1. 决策结论

### 1.1 “当前是否已全面超过 Maccy？”

**否。** 当前最准确的产品判断是：

- Clipy 的历史内核在一致性、可证明语义、持久化安全和编译期模块边界上已经
  **明显强于**修改版 Maccy；
- Maccy 的当前用户功能、macOS 14+ 覆盖、本地化、设置成熟度、自动粘贴/多文件/
  过滤/快捷键/自动化，以及 updater/unsigned packaging 基础仍然**明显更完整**；
  但该修改版的签名、公证和 Homebrew 发布同样没有被当前快照证明；
- Clipy 的 UI/App 新增部分尚有已确认的架构、平台、并发和 release-state 缺口；
- “更省内存、更快、时间复杂度更低”目前**没有同机 A/B 证据**，且 Clipy 自身
  已记录 5,000 × 256 KiB 最坏界 exact search 约 1.59 秒 p50、1.59 GiB peak
  RSS、每请求约 1.22 GiB snapshot 的反向风险证据。

因此可以说“Clipy 已形成更强的正确性与扩展基础”，不能说“当前产品已经全面
超越 Maccy”。完整功能/架构/复杂度矩阵见 `04-maccy-comparison.md`。

### 1.2 当前是否适合标记 product complete / state 3？

**不适合。** V1/V2-02 R.1–R.6 的引擎主体很扎实，但 R.7/产品层仍未闭合；
本地化/VoiceOver/打包发行也没有 state-3 证据。动态 UI 提交曾连续暴露编译和
test failure，且 authoritative status 文档互相矛盾。最终 CI 状态见 §2.1 的
截止快照；不能用较早 `61b418b` 的绿色 run 为之后新增的 AppKit/Carbon/preview
代码背书。

## 2. 最高优先级 findings

### 2.1 CI 与可构建状态随 UI 快照变化

| 快照 / UTC | 观测结果 | 能支持的结论 |
|---|---|---|
| `61b418b`; run 32270414876 | 2026-08-19 完成且绿色 | 只证明该提交及当时 scope；不覆盖后续 panel/preview。 |
| `a028c8c`; run 32316689047 | 2026-08-20T00:19:48Z cancelled；access-level 编译问题 | 新 UI 首次提交不是绿色。 |
| `9c6e3b48`; run 32317009871 | 2026-08-20T00:26:43Z cancelled；lint/source gates 与 perf-helper green；app 因 `NSApplication.alertWindow` 不存在而编译失败；SwiftPM 542 tests/68 suites 中 5 个 dwell tests 共 6 issues | 明确证明 `9c6` 不能称 CI-green；也说明 source gate 不能代替 macOS app compile。 |
| `9a637a6c`; run 32317628976 | 2026-08-20T00:31:22Z **FAILED**：Lint/source gates、SwiftPM build + test、perf-helper、Perf proofs (§9) 均绿；XcodeGen generate + app build/test 失败（`PanelAndHotKeyTests` 的 `origin` helper shadowing，由 `d35f3b9` 修复；`d35f3b9` 的 run 32318520597 亦 FAILED——app test failures） | 该提交不是 CI-green；绿色收口为 `cc59aa8` / run 32319164667（2026-08-20T00:56:06Z，五个 push-scope jobs 全绿；两个 dispatch-only admission lanes 不在 push 范围）。 |

`9a637a6c` 消除了源码中“没有该成员”的直接编译原因，但它用 AppKit-private 类名
`_NSAlertPanel` 扫描 windows；这是编译修复，不是公开平台契约修复。即使其 CI
转绿，下面的架构/功能/性能 findings 也不会因此消失。

### 2.2 High — RetainedBytesRow 非法标量没有 fail-closed

`RetentionConfigLoading.fetchProjectedScalars` 只验证 row 数、版本和重复 ID，
没有验证 `canonicalBytes`、`revisionCount`、`revisionBytes` 非负且落在 hard bounds。
随后 R2/R3 把这些 `Int` 当权威事实：负 footprint 可使超预算状态看起来已满足，
异常大值可错误淘汰有效项；负 revision scalar 还会避开应触发的 lineage decode。

- 原因：`Sources/HistoryStorage/RetentionConfigLoading.swift:193-237`；
- 消费：`PlannersRetentionExpansion.swift:142-182,297-319`、
  `RetentionPolicySweep.swift:196-203`；
- 规范：`docs/v2/V2-02-retention.md:462` 要求不一致 projection fail-closed；
- 支持上限：正常生产 stamping 会写合法标量，本 finding 证明的是本地持久化损坏
  下的数据安全边界缺失，不表示日常写入会自行生成负数。

这应在依赖 R2/R3 做破坏性淘汰前关闭。详见 `01-standards.md` S-1。

### 2.3 High — PresentationUI 在 MainActor 做 ImageIO decode，且 gate 漏检

当前两个路径直接违反 V1/V2：

- `ThumbnailStore` 是 `@MainActor`，在 await 后调用
  `CGImageSourceCreateImageAtIndex`；
- `HistoryPreviewView` 在 SwiftUI body 路径同步 downsample full Effective image
  bytes；
- `PresentationUI` 直接 import ImageIO；
- portable gate 与 SwiftLint blocklist 都没有 ImageIO，因此仍报告 green。

这同时是 owner 漂移和响应性风险。Apple 当前 `CGImage` 文档包含 `Sendable`；
没有必要用“CGImage 不能跨 actor”作为主线程 decode 理由。V1 的现成
`ThumbnailWorker`/purpose-specific storage read 应继续拥有 decode，UI 只应用
有界、reference-fenced 的结果。详见 `01-standards.md` S-2、
`02-spec-implementation.md` SPEC-IMPL-002 和 `03-apple-platform.md`。

### 2.4 High — Retention 设置没有权威 readback，可能覆盖真实策略

公开 `ClipboardHistory` 只有 policy mutation，没有 configured-policy read。
设置页每次打开都显示 count=200、age/storage/revision 全关闭；Apply 又会替换完整
policy。重启或重开设置后，用户看到的不是持久化事实，点击 Apply 可禁用原策略并
立即引发淘汰/修订剪枝。

OPEN-2 排除的是“当前已用字节”live usage，不是“已配置 policy”读取；V2-07 还
明确要求显示 configured budget。因此这是 R.7/API gap，而不是已关闭 R.1–R.6
引擎的回归。详见 SPEC-IMPL-003。

### 2.5 High — macOS 26 pasteboard 访问状态没有进入产品模型

Apple 当前文档为 macOS 15.4+ 提供 `NSPasteboard.AccessBehavior`；general
pasteboard 的 programmatic read 默认行为可为 `ask`，也可能处于拒绝状态。Clipy
在 app launch 时立即读当前 pasteboard，之后每 0.5 秒 polling changeCount 后读取，
没有 access-behavior 分支、解释 UI、拒绝/恢复状态或 signed runtime proof。

这不证明所有机器上捕获都会失败；它证明 macOS 26-only clipboard manager 的核心
能力仍依赖一个未建模、未验收的平台状态。需要用官方 API 做 ask/deny/allowed
状态矩阵，证明首次启动、拒绝、稍后授权、重启和 background polling 的行为，且
不得把剪贴板内容写入日志。官方链接与精确 availability 见
`03-apple-platform.md`。

### 2.6 High — 异步 UI/App operation 缺少顺序、取消或 backpressure 契约

三项条件性但高影响的竞态没有 deterministic proof：

1. preview `.task(id:)` await details 后，不检查 cancellation 或当前 exact
   `HistoryItemReference`；旧请求晚到时可能把另一项的敏感内容显示在新 selection
   下（SPEC-IMPL-007）；
2. Details Remove 发起 fire-and-forget mutation 后立即另起 reload；paste mailbox
   的单 consumer 又为每项另起 Task，dependent operations 可乱序
   （SPEC-IMPL-008）；
3. 每次 clipboard capture 都创建独立 unstructured Task；单个 capture 虽有
   128 MiB bound，但 aggregate pending captures 没有 byte/count bound 或 overload
   semantics（SPEC-IMPL-009）。

“actor 最终会串行”不等于 caller 创建顺序、最终 clipboard 写入顺序或内存 backlog
已经定义。应先决定 lossless FIFO、bounded backpressure 或 newest-wins 的产品语义，
再用可暂停/逆序完成的 deterministic test 证明。

### 2.7 High — pasteboard 失败被当作成功；当前也不是 Maccy 功能超集

`PasteboardAdapter.write` 忽略每个 `setData` 的 Bool 并返回 Void；App 随后无条件
关闭 panel。读取时，声明存在但 data 为 nil 的 type 被静默跳过。Apple 文档说明
这些结果可代表 ownership change、内容改变或 provider timeout，所以 partial
write/capture 不能冒充完整成功。

另有明确产品差异：Clipy 只冻结第一个 pasteboard item，当前所谓 `paste` 只写
clipboard 并关 panel，不发送 Command-V，也无 plain-text paste；Maccy 已冻结全部
items、用 `writeObjects` 回写多文件，并支持 auto/plain paste。这些不是 Clipy V1
规格违约，但足以否定“当前功能全面超越”。详见 SPEC-IMPL-005 和对比报告 §2。

### 2.8 High — 性能/复杂度声明超过现有证据

两个静态反例：

- retention expansion 对 R1 victims 和 R2 candidates 全量 sort，最坏
  `O(N log N)`，规格/fixture 却标 `O(N)`；100→300、允许 6× 的 gate 只能大致拒绝
  quadratic，不能区分 linear 与 `N log N`；
- pin reorder 端到端先获取全部 N 项并按 ID sort，再处理 P 个 pinned，最坏
  `O(N log N + P)`，不是 fixture 名称暗示的纯 `O(P)`。

性能数字方面，当前只有各自 CI、不同语料/模式/OS/build 的记录，没有同机 Release
A/B。Clipy 的首屏/浅滚是渐进 DTO 物化，但下一页会 append，深滚到底仍可持有
O(N) DTO；Maccy 的 search actor 则增量常驻 capped corpus，避免 Clipy 每次 query
从 SwiftData 重建 full snapshot。谁更省内存取决于 workload，必须测量。详见
SPEC-IMPL-006/011 和对比报告 §4–§7。

## 3. 其他已确认或需决策的问题

| 项目 | 分类 | 当前证据与支持边界 |
|---|---|---|
| BMP UTI 写成 `public.bmp` | confirmed correctness | Apple `UTType.bmp.identifier` 是 `com.microsoft.bmp`；storage/UI 五处 frozen set 和测试 fixture 都使用非标准 ID，真实标准 BMP 可能无法获得 Image fallback/thumbnail/preview。 |
| HEIF 固定 index 0 | conditional fidelity | Apple为 HEIF 提供 primary image index；固定 0 对带 auxiliary/多 image 的容器不保证选择 primary。GIF/TIFF first-frame 可能是刻意产品简化，应分别记录。 |
| Maccy 长 fuzzy/mixed query | confirmed comparative defect | 修改版 Maccy 对同一 Fuse 1.4.0 无 query cap：65–89 Characters 可错误为空，达到 Bitap `i==63` 的 ≥90 absent query 可触发 checked-arithmetic trap；Clipy 已限 64。Maccy mixed 是功能优势，但未完整守住输入安全。 |
| completed-thumbnail dictionary | design-boundary / likely unadmitted | HistoryStorage 仍遵守 single-flight/no completed bytes；但 UI 长期持有默认 500 个 decoded hit/miss，跨 page/reopen，源码自己称 deferred G1。规格需明确 visible display state 与 shared cache 的边界，不能误报为 Storage defect。 |
| cache ceiling off-by-one | confirmed bounded defect | `if entries.count > maximumEntries` 在插入前检查，配置 500 时可达到 501；按 entry 数而非 decoded byte 数也不能建立 RSS bound。 |
| private Settings selector | confirmed platform risk | `showSettingsWindow:` 无公开文档；macOS 26 有 `OpenSettingsAction`/hosting-scene public path。 |
| `_NSAlertPanel` 类名 | confirmed undocumented dependency | `9a637a6c` 复制 Maccy helper 后可编译，但依赖 AppKit-private implementation class name；“Maccy 也使用”不是 Apple 契约。 |
| Carbon callback → MainActor | proof gap | 注释声称 dispatcher callback 必在 main thread，Apple 当前 symbol-level 文档与真实 C callback test 均未找到；测试只在 MainActor 直接调用 `fire()`。不据此宣称 runtime bug，但 proof 未闭合。 |
| hotkey 与错误反馈 | product/UX gap | summon chord 固定 ⇧⌘C；注册冲突、launch-at-login register/unregister failure 都不会明确告诉用户。 |
| fixed panel/preview | product/UX gap | 400×560 + 320 固定布局，缺少 Maccy 的 resize/preview width/delay/limit；是否保持极简应是显式产品选择，并经小屏、长文本、键盘/VoiceOver 场景验收。 |
| localization/state 3 | confirmed incomplete | 没有 String Catalog/.strings/.lproj，大量 raw English，MB label 实际按 MiB 计算；R.7/VoiceOver/localization/formatting 未闭合。 |
| CI awk noise filter | confirmed gate-integrity defect | 若 CoreData block 缺少终止 `}}`，awk 会吞掉余下所有 warning/error/TEST FAILED。主 build/test 的非零 exit 仍会失败，因此它主要破坏“零 warning/日志自检”保证；必须 EOF fail-closed。 |
| status/roadmap/CI provenance | confirmed | 同一 PROGRESS 文件前部说 step 9 未开始、后部说完成；module docs 仍 not-started；`a028c8c` 曾声称 merge 已记录 CI/run ID，但提交和当时 run 不支持。 |

## 4. 已确认的强项与 no-finding 边界

本轮没有发现新的下列问题：content-lineage、dedup byte-confirmation、
`ContentVersion`/`ChangePosition` 推进、V1→V2 migration 拓扑、事务原子性、R1/R2/R3
选择语义、HistoryAction exhaustive handling 或 writable ModelContext owner 漂移。
这不是笼统“无缺陷”，而是对已检查范围的结论。

Clipy 当前最有价值的资产包括：

- Foundation-only public seam 和纯 Domain planners；
- 单写 Authority、operation-local context、明确 transaction commit；
- typed failure/receipt、snapshot observation、稳定业务 ID/OCC；
- Canonical/Effective/revision lineage；
- two-stage collision-safe dedup；
- versioned codec/migration/fail-closed 基础；
- purpose-specific reads、thumbnail single-flight；
- public symbol/import/escape-hatch gates 和大量真实 SwiftData/concurrency fixtures；
- 比 Maccy 更少的远程 dependency 和更强的编译期 target graph。

这些优势说明应继续深化现有模块，而不是把 Maccy 的功能直接复制进 UI/App。目标
owner、深模块 seam、明确非目标和 phased gates 见 `05-recommended-target-design.md`。

## 5. 建议的发布/超越顺序

1. **恢复可构建、可信证据。** 让实际 final head 的 source/SwiftPM/app/perf-helper
   jobs 完整绿色；CI noise filter fail-closed；同步 status ledger。
2. **关闭数据与平台边界。** invalid retention scalars、pasteboard access state、
   partial read/write、BMP identifier、公开 Settings/alert handling。
3. **恢复 actor/owner 对齐。** ImageIO/off-main preview、exact-reference/cancellation、
   ordered paste/capture mailbox；决定 completed cache 是否真正获得准入。
4. **完成 R.7/state 3。** authoritative policy readback、String Catalog、locale-aware
   formatters、VoiceOver/keyboard/window-size/product tests、packaging/release/recovery。
5. **明确功能目标。** 对 auto/plain paste、多 item/files、filter/pause、custom
   hotkey、App Intents、preview configuration 逐项选择 must/optional/non-goal；实现前
   指定权限、安全和失败语义。
6. **修正或实现复杂度承诺。** retention/pin workloads 用 operation counts 或可区分
   规模验证；解决 search full snapshot 的峰值内存。
7. **最后才发布 superiority claim。** 用对比报告 §7 的同机 Release A/B matrix，
   按 workload 公布 raw samples、p50/p95/p99、RSS/CPU/energy/frame time，同时报告
   regression 和 missing cells；不能合并成一个没有语义的总分。

## 6. 审查方法与证据边界

四条并行轴分别检查 repository standards、V1/V2 spec fidelity、Apple 当前公开
文档以及 Maccy/复杂度/性能对比；随后再由独立 agent 反驳比较报告中的过度断言。
该交叉核验已经纠正了多项过度断言；典型两项是 Clipy **没有** mixed search，
pin reorder 端到端也**不是**单纯 `O(P)`。它还收窄了本地化、签名发行、分页常驻
内存和 Maccy multi-item 边界等表述。

本机为 Linux，不能运行 Swift/Xcode/macOS framework tests。portable import 与
escape-hatch gates 在 `9c6e3b48` 快照通过；macOS 行为依据仓库 CI artifacts 和
Apple primary documentation。所有 Apple 链接记录访问日期；所有性能结论区分：
源码事实、静态上界、已有 measurement、跨产品未证明假设。

### 证据地图

| 总结性结论 | 主要原因 | 主要证据 | 不支持的外推 |
|---|---|---|---|
| 当前不是全面超越 | Maccy 产品能力更广；Clipy 有 release blockers | `04-maccy-comparison.md`; source matrix | 不表示 Maccy 的内核正确性更强。 |
| Clipy 内核基础更强 | 单 seam/单写者/纯 planner/versioned semantics/gates | `01-standards.md` no-finding；`02-spec-implementation.md` | 不自动推出性能/UI/RSS 优势。 |
| MainActor decode 是事实 | @MainActor source + ImageIO calls；V1/V2 禁令 | SPEC-IMPL-002；Apple responsiveness docs | 不量化每台机器实际卡顿毫秒数。 |
| retention corruption boundary 缺失 | 非法 scalar 无校验后进入 destructive planning | Standards S-1 | 不表示正常 stamping 会写负数。 |
| “更快/更省内存”未建立 | 无同机实验；Clipy 5k search 高水位 | SPEC-IMPL-011；run artifact；对比 §5 | 不表示 Clipy 所有日常 workload 都更慢。 |
| current UI 不是 state 3 | readback/localization/VoiceOver/packaging 缺口 | SPEC-IMPL-003/004/012 | 不否定已连通的真实 History journey。 |

## 7. 报告索引

- `01-standards.md`：工程标准、持久化/CI/gate、smell 与 no-finding；
- `02-spec-implementation.md`：V1/V2 规格到实现，12 项 finding；
- `03-apple-platform.md`：截至 2026-08-20 的 Apple API/HIG/availability 核验；
- `04-maccy-comparison.md`：功能、模块、复杂度、测量与同机 A/B 设计；
- `05-recommended-target-design.md`：对齐后的目标 owner、product decisions 与阶段验收。

完整行号、替代解释和建议的 discriminating test 保留在各附录中；本报告不重复
它们的所有细节。
