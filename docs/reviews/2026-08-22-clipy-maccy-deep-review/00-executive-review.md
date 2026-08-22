# 执行总评

## 1. 最终判断

Clipy 目前是“**内核基础更强、产品闭环尚未完成**”，不是“已经全面超过
Maccy”。更准确的分层判断如下：

| 维度 | 当前领先者 | 证据上限 |
|---|---|---|
| Domain 语义、OCC、内容 lineage、typed receipt/failure | Clipy | 纯 planner、真实 SwiftData、WS 与 deterministic concurrency tests；不自动证明 UI。 |
| 单写者、模块边界、collision-safe dedup | Clipy | 当前源码仍保持；不自动证明 startup corruption、crash durability 或最坏内存。 |
| 日常 capture/search/copy 主路径完整度 | Maccy | Maccy 有 multi-item/files、auto/plain paste、filters/pause、custom shortcut；其失败、权限和 multi-item flatten 实现并非金标准。 |
| UI 成熟度、设置、本地化、真 UI 测试 | Maccy | Maccy 有真实 XCUI 与大量 locale resources；不证明 VoiceOver 或翻译质量。 |
| 发布安全 | 两者都未闭环 | Clipy 无 release pipeline；当前 Maccy fork 也 unsigned、未 notarize，updater feed 还与 fork release 脱节。 |
| 已证明性能/内存 superiority | 无 | 没有同机、同 build、同语料、同语义 A/B；静态上界不能替代 RSS/latency 测量。 |

Clipy 最值得保护的是深而窄的 History boundary，而不是 Maccy 的具体类结构。近期
目标应是把“允许捕获 → summon → find → copy → 返回原任务”做成可解释、可恢复、
资源有界的 signed journey，而不是追逐设置数量。

Python 本机自动化、开放格式能力、独立 Preview 与多级 Storage 都是正确的长期产品方向，
但不是新的 development blocker。当前 `HistoryStorage` 是一个为 5,000 项硬上限认真设计的
**有限持久化内核**，不是 RAM→disk→cold archive 的驻留管理器；它已有短生命周期 context、
scalar projection、durable retention 与局部 thumbnail bound，却没有通用 content eviction、
range/stream read 或进程级 resident-byte budget。上述方向现在应先冻结规格、信任边界、能力清单、
资源账本与判别实验；production shipping 仍必须排在正常路径 correctness 和相应 signed/platform
证明之后。

## 2. 唯一 development blocker：P0-0

### P0-0 — 当前最终 SHA 是红的，且权威 truth sources 已漂移

2026-08-22T00:56:44Z 查询到 run
[32348271453](https://github.com/GuangDai/Clipy/actions/runs/32348271453)
绑定 `cda2ba0`：`Lint + source gates` 和 `Perf proofs (§9)` 绿色；
`SwiftPM build + test`、`SwiftPM perf/AB helper tests` 失败；app 的
`xcodebuild clean/build/test` 本体完成，但日志 self-scan 因
`AppPasteOrchestrationTests.swift:267:55` 的 sendable-capture warning 失败。关键编译错误在
`Tests/PresentationUITests/ThumbnailStoreTests.swift:209,224`：同步 autoclosure/`&&`
表达式内 `await` actor 方法。

同时：

- [`docs/PROGRESS.md`](../../PROGRESS.md) 仍把 `cc59aa8` 写成 current landed head；
- V2 progress/roadmap 未登记一批已落实现；
- `ClipboardHistory.retentionConfiguration()` 已成为 public requirement，但
  `V2-02` 仍明确 write-only，`V2-07` 仍说不新增 public DTO；
- `PresentationUI` 已 import ImageIO 且 public 返回 `CGImage`，但权威 owner/gate 仍禁止。

先只恢复测试编译与 zero-warning，并让同一 final SHA 的全部常规 jobs 绿色；随后裁决
readback、ImageIO/CGImage 与 completed thumbnail cache 的规格归属，再同步 ledger。
这一个基线问题会阻断下一轮开发。下面的 correctness、privacy、resource、corruption 与
release 项同样重要，但不应全部伪装成 development P0 或塞进同一个 batch。

## 3. 正常可达的 pre-beta correctness

### 3.1 Revise “Keep” 会恢复原始 bytes，dirty draft 也会丢

[`ReviseEditorView`](../../../Sources/PresentationUI/ReviseEditorView.swift) 对当前
Effective 中存在的类型默认 `.keep`，保存时却把 `.keep` 映射为
`.inheritCanonical`。若当前 revision 已把 `A` 改成 `B`，用户无编辑保存或只隐藏
另一个类型，`B` 会恢复成原始 `A`。这是普通用户路径上的确定语义错误，不依赖损坏
store 或罕见调度。

Draft 必须 byte-exact 表示 current Effective；Keep Current、Use Original、Hide、Replace
是不同选择，无编辑保存返回 `.unchanged`。此外 stale save 当前会直接 dismiss 并丢掉
replacement draft，dirty Cancel/Esc 也没有 discard confirmation。最小修复只需分开 base
reference、current draft 与 dirty 状态；不要借机增加 autosave、merge framework 或 destructive
revision pruning。界面还需明确：保存会追加 revision，不会擦除 Original Capture 或旧 revision。

### 3.2 Copy 请求没有真实顺序；先把所有权收回 `AppComposition`

生产 stream 按 A、B 收到请求后，consumer 又为每次 copy spawn 无 owner 的 Task；B 可以
先 resolve/write/close，A 再覆盖 clipboard。现有 app test 手工复制了一套串行 pump，没有
调用 production implementation，因此不能证明真实 wiring。

第一步不是分别新增 `PasteFlow`、`CaptureFlow`、generic queue/bus 或第二个 History
boundary，而是在现有 `AppComposition` 内收回 operation ownership：

- 一个 owner 持有 capture drain、paste single-flight 与 start/stop task；production 与 composed
  integration tests 走同一真实入口；
- copy request 在一个 structured operation 内完成 resolve → stage full item → write → receipt；
- 近期采用 exclusive first-accepted：pending 时拒绝重复触发；只有 write success 才关闭 panel；
- 同一 owner 也持有 capture drain 的生命周期和 content-free health，但 capture overload
  policy 仍需单独判别，不由 copy 顺序自动决定。

只有完成最低 Green 后，删除测试证明这些复杂度仍散落在多个真实 caller，才提取一个
app-internal concrete `@MainActor ClipboardFlow`，并同时删除旧 mailbox、nested task 与复制的
test pump；否则 `AppComposition` 本身就是足够深的 owner。这是一处“先深化现有 seam，再决定是否
提取”的工作。`writeObjects` 也只能减少已知 partial window，不能被描述成跨进程 atomic
transaction。

### 3.3 History/UI 的异步状态还不是权威状态

当前几个正常操作即可触发的缺陷应在 privacy/resource hardening 前修复：

- query/mode 改变时旧 rows 立即被新 query 标注并仍可 Return copy；exact/regexp 的首尾空格
  又被 trim，切到 fuzzy 会先发一代非法长 query、再永久截断 raw draft；
- `loadNextPage()` 的 Task 无 owner；close/reopen/query restart 不 cancel、invalidate 或可靠
  reset loading。迟到 page 可污染隐藏 session，永不返回的旧 browse 还能永久阻止新分页；
- 同 ID 的 `ContentVersion` 变化不 retarget preview，mismatch 分支可永久 spinner；所有
  loader error 又被折成“No Preview”，unsupported 与 retryable failure 无法区分；
- failure 以错误值去重，同一个值的新 failure episode 以后可能永远不再出现；健康 page
  还会错误清除不相关 mutation failure；
- `panelClosed()` 反而允许 preview auto-open，SwiftUI 与 AppDelegate 双重拥有
  activate/deactivate；隐藏 selection 和迟到任务可能跨 session 生效；
- last position 按 721pt preview window 的中心保存，400pt main surface reopen 会横移约
  160.5pt；位置 identity 应是稳定 main-content rect；
- pinned-only 第一页没有 pagination trigger；preview 左开只移动 window、不反转内容；
  初始 selection、search focus、IME 与可访问操作也没有显式 contract。

最小方向是一个 panel/browse session generation：raw draft 与 admitted query 分离，每个
pagination/preview/mutation task 有单一 owner 和 request token，close/restart 先 cancel +
invalidate；failure 用 operation episode；selection 用 exact `HistoryItemReference`。这不是
引入 Redux，也不需要把全部 view 重写。

## 4. P1 风险与证据缺口

### 4.1 Signed privacy 与 capture health

Apple 的 [`NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)
规定 General pasteboard 读取有 default/ask/alwaysAllow/alwaysDeny 状态。Clipy 启动即读并持续
polling，却没有 capability/health、暂停或恢复入口；private pasteboard tests 默认获准，不能
证明 signed 主路径。

Capture 还会在识别 conceal marker 后才 materialize 敏感 payload，并为每个 frozen outcome
启动独立 Task；pending count/bytes 无界且错误被吞。同一 `AppComposition` operation owner 应在
读 bytes 前完成 access/declared-type preflight，使用 stable start/end change-count result，并以
明确 count/byte budget 驱动 capture drain。只有 deletion test 通过才把该 owner 提取为 concrete
`ClipboardFlow`。是否 bounded FIFO、active+latest 或 visible pause/reject 必须先用小队列判别实验
选择；polling 本来会漏，不是主动丢弃已 freeze snapshot 的授权。

### 4.2 Local-only CloudKit 是 conditional fail-open

[`SwiftDataHistory.open`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L138) 构造
`ModelConfiguration(schema:url:)` 时没有指定 `cloudKitDatabase`；Apple 文档给出的默认值是
`.automatic`，会发现entitlements中的CloudKit container，而 `.none` 才显式禁用。实际managed sync还
要求相应iCloud/Background Modes capabilities与兼容schema；当前`.unique`组合的open/sync结果是UNKNOWN。
当前 `project.yml` 没有 iCloud/CloudKit entitlement，所以**没有证据表明当前 artifact 已上传
clipboard 数据**；确认的是条件性 footgun：未来加入可发现的CloudKit container及所需capabilities时，
可在storage源码不变的情况下破坏 local-only/no-network 承诺。

Production 应显式 `.none`，并以 source configuration、project entitlement 与最终 signed
artifact entitlement 三层 gate 锁住。不要为此引入 sync abstraction；cloud/sync 仍是非目标。

### 4.3 Storage corruption hardening 要与正常路径分层

Singleton 风险需要补全，但它不是正常 fresh-store 路径上的已发生数据丢失：

- existing store 若 position/config singleton 缺失、wrong-key 或部分损坏，startup 会按新库
  默认值补写；下一次 capture 才可能按重置后的 count 淘汰历史；
- 即使唯一 position row 存在且 key 正确，startup `case 1` 也不 decode/验证 `rawValue` 与
  `maximumUnpinnedItems`，可先发布 facade，直到第一次 operation 才失败；
- 合法 fresh store 与批准的 V1 migration 是反向 control，不能因 hardening 被全面拒绝；
- position/config 不可从 items 唯一推导，必须 fail closed；缺失但源 blobs 完整的
  RetainedBytes 是可重算 projection，可以保留严格、幂等的 missing-only rebuild。

因此先做无写 startup classification 与完整 key/cardinality/value validation；只有确认 fresh/
migrating 的 shape 可以 create。腐损 fixture 要由 seed/corrupt/reopen 三个短命 child 证明，
不能把同进程 second facade 叫真正 restart。

另外三个 P1 storage 项应简洁但明确：

1. Signature Index 只 decode signature blob、未验证与 Canonical coverage；损坏 fingerprint 或
   漏 entry 可制造 false-negative candidate 并插入 duplicate。Codec 也缺 aggregate byte-count
   checked addition。先裁决 signature 是否可承担负证据，再写 corruption/restart Red。
2. R3 sweep 会保留多个 decoded lineages 到最终 transaction；V1→V2 backfill 一次 fetch 并
   触碰大量 blobs。约 1.2207 TiB 只是由合法上限相乘得到的**逻辑可处理 bytes 上界，不是实测
   RSS**。先用独立 Release child 测 N×blob-size 的 peak RSS、wall time 与 reopen digest；只有
   超过批准预算才引入 bounded/restart-safe batch。
3. 现有 migration/restart tests 保留旧 coordinator，WS13 又未立即核对 RetainedBytes/index/
   zero-publish；external-clone filter 也未逐 item hydrate 全部 payload。它们仍有价值，但 claim
   必须降到 same-process/已检查字段。补少量真正 seed → operate/kill → reopen child tracers，
   不把全部快速 suite process 化。

### 4.4 其余资源边界

1. Search 在 4,096-byte/fuzzy/regexp admission **之前**抓取、复制并排序全部 bodies；同步 scan
   无 cooperative cancellation。先做 no-I/O admission、empty recent fast path 与 bounded
   cancellation；resident corpus/FTS 只有现方案仍超过 absolute SLO 才准入。
2. Dedup loader 为每个 candidate hydrate 完整 revisions，planner 多数只需 narrow facts。
   先缩 facts，保留 byte-exact confirm 和 corrupt non-winner 的已批准 fail-closed 语义。
3. Thumbnail 只合并 same key，distinct keys 无 count/byte cap；permit 必须在 source hydration
   前取得。ImageIO 未设置 eager materialization，不能把 object creation 宣传成 off-main pixel
   decode 已完成。
4. Preview 的 200 ms dwell 把 full-details read 变成热路径；大型文本又在 MainActor 全量 decode
   后才截断。先修 reference/purge、bounded non-main text 与 visible/manual policy；只有 G8/SLO
   失败才扩大 purpose-specific History projection。
5. Public observation 外层 `AsyncThrowingStream` 默认 `Int.max`；state snapshot 应 newest(1)。
6. ThumbnailStore 是未正式准入的 process-lifetime completed cache；若 reuse trigger 未满足，
   回到 visible-state，而不是补 disk cache。

### 4.5 多级 Storage：当前是有限内核，retention 不是 RAM eviction

当前 Storage 的基础比“所有数据常驻 UI 内存”强：recent browse 使用 scalar projection 与有界页，
operation 使用 fresh `ModelContext`，持久 retention 能按 count/age/logical content bytes/revisions
删除历史，UI thumbnail store 也有 500 entries/64 MiB decoded-byte 上限。但这四件事都不能推出
“大内容不会进入 RAM”或“已存在多级淘汰”。[`HistoryLimits`](../../../Sources/HistoryCore/Limits.swift)
仍固定 `hardMaximumRetainedItems == 5_000`；Signature Index 覆盖全部 retained items；thumbnail 超限
是 whole-store reset，不是通用 content LRU；`.externalStorage` 也只是 SwiftData 的 opaque placement
option，不提供 Clipy 可控制的 blob URL、range read、streaming、fault eviction 或物理回收合同。

后续规格必须至少分开四本账，不能再把一个 `bytes` 或 `retention` 名称横跨四种语义：

| 账本 | 它回答什么 | 允许的动作 |
|---|---|---|
| **logical history** | 每个逻辑 representation/revision 对用户 retention 贡献多少 bytes | 只有已批准的 count/age/logical-byte/revision policy 才能改变用户历史 |
| **physical storage** | SwiftData store family、WAL/history、immutable blobs、metadata、临时文件与备份实际占多少盘，以及 reserve/GC debt | 清 orphan、维护 store、在 reserve 不足时 typed reject；不得把物理压力偷换成静默删除 pinned/history |
| **rebuildable cache** | thumbnail、Preview、search derived artifact 等可重建数据占多少 | 可按预算/pressure 淘汰，不推进 `ChangePosition`，不改变 History 语义 |
| **resident + in-flight** | Clipy 拥有的 encoded/decoded resident values、leases 和并发读写峰值 | byte/count/concurrency admission、single-flight、trim/cancel；不能把该上限宣传为全进程 RSS 上限 |

真正阻止超大历史的首要路径不是“磁盘够不够”，而是规模耦合：每次 search 先 materialize 全部
title/body corpus；capture/若干 mutation 取得全 retention inventory；完整 Signature Index 常驻；
details/paste/preview hydrate 整个 Canonical 与 revision lineage；startup、R3 和 migration 仍有 O(N)
或大 blob 批量路径。只调高 5,000 常量，或者给 UI cache 换一个 LRU，都不会解除这些约束。

推荐目标不是让 caller 选择 `hot/warm/cold`，而是在**真机证据证明确有需要后**保持
`HistoryAuthority` 为唯一业务写 authority，并深化为：SwiftData 保存 metadata、排序、OCC、
projection 与 immutable representation locator；Authority-owned app-managed `ContentDepot` 以
prepare → immutable publish → metadata commit → orphan/GC 的可恢复协议保存 bytes；一个有硬
resident/in-flight byte budget、lease、exact-key single-flight、oversize bypass、scan bypass 与
pressure trim 的 `ContentMaterializer` 提供 bounded range/sequential reads。Storage 必须类型无关；
PNG/PDF/text 的stable identifiers/families来自`ClipboardFormats`；具体behavior owner/renderer结合自己的
manifest、fixture与实测profile产生purpose-specific access plan。UI/Python/renderer 都不得获得裸 blob URL。

这不是立即授权重写 schema。先完成 scalar-fetch、whole-blob hydration、operation-local context
plateau、重型请求重叠、allocated disk/ENOSPC 的 Release child characterization；若现有 bounded
方案已满足批准 SLO，就继续使用 opaque `.externalStorage`。只有 large-representation 的
range/stream 或精确驻留证据失败，才按 representation-level loose immutable blob tracer 进入
Red→Green；它不是解除 count cap 的默认前置。先保持 5,000 production cap，以 5,001 边界验证
功能，再按 50k→250k→1m 做独立 scheduled/soak 证据。

产品也不能承诺字面“无限”：诚实目标是“用户可关闭固定 count/age/content-byte 软保留限制；
Clipy 不因隐藏产品常量主动删历史，metadata query 与内容加载保持有界；设备容量/安全 reserve
不足时暂停新 capture 并返回可恢复 typed 状态”。即便 1m fixture 通过，也只证明该 OS、机器和
语料规模。完整设计分解见 `DESIGN-TIER-*`，可领取执行卡以 `04` 的 `PLAY-*` 为准；Apple
characterization 以 `MEMO-STOR-0…14` 标识。详见
[`09-tiered-storage-and-unbounded-history.md`](09-tiered-storage-and-unbounded-history.md)，Apple/源码
证据见 [`apple-tiered-storage-source-memo.md`](apple-tiered-storage-source-memo.md)。

### 4.6 Python、格式与 Preview：现在定边界，按 vertical slice 交付

**任意 Python 目前不能通过受支持接口查询或修改 Clipy history。** Tracked source 中没有
`clipyctl`、IPC listener 或已实现的 `ExternalGateway`；Python 现在只能像其他进程一样操作
General pasteboard。未来推荐的稳定 contract 是：同一effective user account（same EUID）在显式授权后，以 Python
stdlib 调用第一方 `clipyctl`，再经可替换的 private transport → 唯一 `ExternalGateway`（grant、
限流、审计、authoritative recheck）→ 唯一 `HistoryAuthority`。Python、CLI 和 helper 都不得
直开 SwiftData store；“任意 Python”也不等于每个脚本拥有独立身份。现在只冻结 owning spec、
wire schema、capability、enrollment 与 gateway Behavior Cards；V2-05 的唯一 `ExternalGateway`/
Authority 路径先获批准并闭环，才实现只读 tracer，private transport 与 mutation 最后通过最终签名、
sandbox/TCC、cold-start matrix。详见 [`07-python-local-automation.md`](07-python-local-automation.md)。

格式能力也不能再用一个 `supported` Bool 表示。当前 unknown/custom UTI 的 opaque raw bytes
可以保留并回放，这是开放世界兼容性的优势；它不证明同一表示可正确生成 title/search 语义、
Preview 或可编辑 wire format。源码中至少十处 type set/switch 已出现 HEIF/BMP、RTF/HTML 和
UTF-16 的策略漂移；其中把可按 UTF-8 读取的 RTF/HTML 当 generic text 编辑并把任意用户文字按原 UTI
回写，没有对应serializer保证。输入普通非markup文字即可构造“type仍称RTF/HTML、bytes不满足该格式”的
互操作失败；不能把每一次用户输入都武断称为必然损坏。

规格准入后的目标可以是两个 package-only concrete 深模块：`ClipboardFormats` 只保存代码可审计的
stable exact facts；Search、Thumbnail、Preview、Edit与Pasteboard由各自owner manifest声明能力和
disabled reason，build/test inventory只做join与漂移检查；
`ContentPreview` 只把 immutable Effective Content 转成受预算约束的 typed artifact，不拥有
History、selection 或 panel lifecycle。Quick Look、HTML 外部资源与 file-backed Preview 默认禁止
自动 I/O；只有显式用户动作、资源预算和 signed zero-exfiltration proof 都成立后才逐项开放。
现在先把 format admission、owner manifests、recipe identity与module graph写入owning specs，再修
现有type semantic defects；批准后才建立stable facts与只读capability inventory，并以“一种格式、分轴契约、真实
producer/consumer fixture、一个 Red→Green→Refactor”为单位扩展，不先建 renderer/plugin framework。详见
[`08-content-types-and-preview.md`](08-content-types-and-preview.md)。

### 4.7 产品与 release gates

- multi-item/multi-file 固定取 first item会静默丢数据；短期显式 unsupported，长期只有用户任务
  证据达到阈值才设计 ordered item group，不能复制 Maccy 的 flatten；
- 固定 `⇧⌘C`/`⌃Space` 有系统冲突且注册失败被忽略；需要 custom shortcut 与恢复 UX；
- retention UI 量化并回写未触碰精确值，launch-at-login 把多态压成 Bool；
- hosted state tests 不是 actual UI。先补一条真实
  `summon → search → Return → clipboard → close` XCUI tracer，再按已发现风险增加 journey；
- release 尚缺冻结 identity/entitlements、Release archive、Developer ID、Hardened Runtime、
  notarization/staple/Gatekeeper、String Catalog、VoiceOver/FKA 与 storage recovery。

第一阶段只选择一种发行路径，优先验证 Developer ID 直发；不要同时加入 MAS、Homebrew、
Sparkle 和 updater。v1 无网络，updater 是单独产品决策。

## 5. 旧报告修复状态

2026-08-20 报告中的多项 findings 已关闭、部分关闭或仍开放；本轮没有逐 ID disposition，
因此不用一个不可复核的精确计数代表当前 bug 数量。

已不应原样重复为现存 defect 的包括：

- BMP/GIF UTI 字符串和 HEIF primary image index；
- `showSettingsWindow:`、不存在的 `NSApplication.alertWindow`、`_NSAlertPanel`；
- CI CoreData filter 的 EOF fail-open；
- 完全忽略 `setData` Bool；
- 完全没有 configured retention read；
- 图片解码必然发生在 MainActor（现在改为 actor，但 lazy decode、CGImage boundary 与
  full-byte materialization 仍开放）。

“修源码”不等于“产品闭环”：Settings hosting environment、Carbon 真实 callback、HEIF
primary-index≠0 fixture、pasteboard ownership/access、external payload hydration 与 signed
release 都仍缺相应运行证明。

## 6. 建议执行顺序

1. **恢复可信 baseline**：修当前 test compile/warning；同一 final SHA 常规 jobs 全绿；同步
   authoritative docs；裁决 readback、ImageIO/CGImage、cache 的规格变化。
2. **先修正常可达 correctness**：Revise Keep/dirty draft；在 `AppComposition` 收回 exclusive
   copy/capture ownership，只有 deletion test 需要才提取 concrete `ClipboardFlow`；query raw/admitted
   generation；pagination task lifecycle；preview exact reference、failure episode、panel session 与
   last-anchor。
3. **先做格式规格准入，再校正语义**：把owner manifests、分轴change identity与module graph写入
   owning specs；关闭 RTF/HTML/abstract text/UTF-16 的错误 semantic/edit 路径。规格批准后建立
   `ClipboardFormats` stable facts + owner manifests/inventory，再从plain text与静态图片开始逐格式完成raw →
   semantic → Preview → Edit vertical slices；unknown UTI 的 opaque round-trip 不因 catalog 收窄。
4. **关闭 signed privacy/capture**：AccessBehavior 四态与恢复、stable snapshot、early
   concealed reject、bounded capture drain、content-free failure/overload health。
5. **建立资源基线与现有边界**：search preflight/cancellation、bounded observation、dedup narrow
   facts、thumbnail permits/eager materialization 与大文本 non-main；并执行 STOR scalar/blob/RSS/
   allocated-disk/overlap characterization。机制必须由 absolute SLO 触发。
6. **再做 corruption hardening**：singleton missing/wrong/existing-invalid、RetainedBytes relations、
   signature coverage、revision ID、true child restart/migration/external hydration；R3/migration
   batching只在独立测量超预算后加入。
7. **按两条证据路线推进 Storage**：count-scale 先消除 dedup/startup、admission、search、policy/UI 的
   O(N) 假设，同时完成现有 SwiftData StoreRoot、single-process lease、reserve、真实ENOSPC/reopen与
   backup headroom这些shared gates。只有 large-content 的 G8/range/stream 证据触发时，才独立做
   purpose-specific read、bounded materializer与loose immutable representation depot，并对blob staging/
   publish/GC/migration/backup重跑P3 variants。保持 5,000 production cap，直到 5,001 功能边界及
   50k→250k→1m staged resource gates 逐级关闭。
8. **完成 state 3**：一条真实 UI tracer、custom shortcut、localization/A11y、dedicated
   StoreRoot/recovery、identity/sign/notarize与 signed platform matrix。
9. **交付本机自动化**：现在先把 `clipyctl` contract、`localAutomation` grant 与 transport
   discriminator 写入 owning spec；V2-05 的唯一 Gateway/Authority 路径先批准，才做只读 tracer；
   signed matrix 闭环后才发布 transport/mutation，不让 Python 直连 store。
10. **最后才做 superiority claim**：同机 Release/signed matched journeys；按 workload 报告
   correctness、p50/p95、peak/settled RSS 与失败率，不制造综合总分。

这个顺序把“用户今天能走到的错误”放在“需要人为损坏 store 才触发的 hardening”之前，也把
资源机制放在测量之后；但 release 前二者都必须获得与其 claim 相称的证据。

## 7. 明确不建议的“优化”

- 不因修 paste ordering 就预建 `ClipboardFlow`；先深化 `AppComposition`。只有 deletion test
  证明多个真实 caller 仍需同一 owner 时，才提取一个 app-internal concrete type；不建 public
  protocols、generic EventBus/CommandBus/Repository。
- 不复制 Maccy 的 `.shared/.current`、UI-resident history、裸 App Intent 或 private API。
- 不在没有 reuse/latency/RSS trigger 时落 resident corpus、FTS、completed/disk cache、OCR、
  cloud sync。
- 不把 durable retention 与 RAM/cache eviction 合成一个“淘汰算法”；不反向解析 SwiftData
  `.externalStorage`，不先造 packfile/segment/remote cold tier，也不用 `NSCache` 冒充硬预算。
- 不宣传字面“无限历史”，不在 search/inventory/dedup/startup 的 O(N) 路径仍存在时只调大
  5,000 常量。
- 不用一次性大量低质量翻译代替可本地化与 pseudo/RTL 证明。
- 不用 signed/notarized 之前的 Debug CI、单一 green run 或跨机器数字宣称更快。
- 不把 singleton corruption、理论 RSS 上界或平台未知写成已经发生的用户事故。
- 不把“polling 本来会漏”当作主动丢弃已成功 freeze snapshot 的理由；capture overload
  policy 必须由测试、资源预算和产品语义共同决定。

## 8. 给后续 Agent 的 TDD 入口

不要把本报告翻译成一个大实现 batch。先从
[`04-tdd-remediation-playbook.md`](04-tdd-remediation-playbook.md) 领取一张执行卡：确认
owning spec 与 approved seam，写一个能编译且因目标行为失败的 Red，只做最低 Green；owner
suite 绿色后才进入独立 review/refactor，再按风险升级到 real storage、hosted view、XCUI、
child-process 或 signed platform gate。

领取顺序与上文一致：卡 0 baseline → 卡 3/7/8/9 正常路径 → 卡 5/6 signed privacy/capture
→ 卡 11/4/12/13 resource bounds → 卡 1/2 corruption/evidence hardening → 卡 15/16 state 3。
格式工作在正常路径之后先完成 `08` 的 spec-admission decision，再进入 `04` 的
`PLAY-FORMAT/PLAY-PREVIEW` vertical slice；Python 现在只做 `07` 的 contract/gateway design，V2-05
Gateway 批准后才领 `PLAY-PY-*` 只读
tracer，production transport 与 mutation 留到 signed boundary 成立后。多级 Storage 先领 `04`
的 `PLAY-STOR-1…4`，并按需运行 `MEMO-STOR-0…4` characterization；没有 SLO/规模证据不得跳到
blob depot、cache algorithm 或
“无限历史”实现。
每张卡都明确 fixture、最低实现边界、全量回归与证据上限；后续 Agent 不应再用 public test
knobs、复制 production wiring 或未经测量的框架换取绿色。
