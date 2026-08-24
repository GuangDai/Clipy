# 收敛后的目标方向

## 1. 目标不是 feature count

Clipy 的目标应写成：

> 在 macOS 26 上，以一个可恢复、可解释、资源有界的本地 clipboard history，可靠完成
> “允许捕获 → 观察状态 → summon → find → copy → 恢复原任务”主路径；在数据语义、
> 故障真实性和发行信任链上优于当前 Maccy。

“全面超过 Maccy”只有绑定 journey 与测量才有意义。近期只承诺六条：

1. signed app 首次运行能解释并建立 capture access；deny/pause/failure均可见且可恢复；
2. 捕获已观察到的普通text/image/custom UTI，不静默接受partial或无限积压；
3. summon后可纯键盘选择、搜索、Copy，成功/失败与panel关闭严格一致；
4. Clear/Remove/Revise后UI、cache和durable state一致，不继续显示旧敏感内容；
5. 代表性和capacity stress下，search/preview/thumbnail/capture有明确资源上限；
6. Developer ID包可安装、验证、重启、login launch、升级/恢复，VoiceOver/FKA可完成主路径。

这六条闭环后，Clipy即使暂时没有Maccy所有排序、sounds、aliases和automation，也已经是
更可信的产品。

本轮用户又明确提出两个**战略扩展目标**：同一effective user account（same EUID）下的任意Python进程可在显式授权后
查询/修改Clipy，以及类型与Preview能力能在代码中清楚审阅并独立扩展。二者从现在开始进入
目标架构，但不抢占上面六条baseline：格式/Preview的边界在Phase 5收敛；Local Automation
现在先冻结contract，只有correctness、State 3发行基础和signed gateway证据闭合后才shipping。
这不是把未实现能力写成当前产品事实。完整设计与Apple证据见
[`07-python-local-automation.md`](07-python-local-automation.md)、
[`08-content-types-and-preview.md`](08-content-types-and-preview.md)、
[`apple-python-automation-source-memo.md`](apple-python-automation-source-memo.md)、
[`apple-pasteboard-type-system-memo.md`](apple-pasteboard-type-system-memo.md)与
[`apple-preview-source-memo.md`](apple-preview-source-memo.md)。

## 2. 不可回退的内核约束

后续修改不得用产品补全为理由破坏以下优势：

- `ClipboardHistory`仍是唯一general-purpose public History boundary；V2-05/Local Automation只能增加窄的、
  capability-scoped external ingress/facade，二者都不让UI/Intent/transport看到SwiftData models。
- writable `ModelContext`仍只属于Authority；不增加第二fake writer。
- Domain保持纯、closed actions保持compiler exhaustive。
- fingerprint只筛候选，永远不作内容/thumbnail correctness identity。
- stable item ID、ContentVersion与ChangePosition语义不变。
- bytes只通过immutable Sendable values跨boundary；不传播`NSImage`/`CGImage`/`@Model`。
- typed failure不能被`try?`、log-only sink或“返回空”降格。
- v1无network/telemetry；任何diagnostic只含category、count、duration、aggregate bytes，
  不含clipboard内容、query、path、bundle ID或历史ID。
- SwiftData production configuration显式设置`cloudKitDatabase: .none`；local-only不能依赖
  “当前没有entitlement”的偶然工程状态。发行配置加入iCloud entitlement后也必须
  保持该明示值，并有构建产物级验证。

因此不建议引入generic repository、event bus、command bus或全局cache coordinator。当前问题
需要几个窄而深的owner，而不是新的基础设施层。

本文的`Phase`只是把目标能力分组，**不是实现Agent可以逐个整章推进的执行时序**。例如
Phase 1同时记录正常bootstrap与人工损坏后的corruption规则，不表示后者应抢在用户每天都能
触发的Keep/Paste/UI错误之前实现。优先级policy以本文件§11和
[`00-executive-review.md`](00-executive-review.md#6-建议执行顺序)为准；唯一可领取card registry/completion
ledger仍是`04`。各Phase只回答“最终由谁拥有这项能力、边界和完成证据是什么”。

## 3. Phase 0：先恢复一个可信真相

在任何功能batch前：

1. 只修当前测试编译和warning，不改生产语义；
2. 同一受保护branch/PR checkout跑完functional、perf-helper、app、source gates、perf proofs；
3. 决定 retention readback、PresentationUI/ImageIO、completed thumbnail cache三项到底是
   改规还是撤回；
4. 更新00/01/06、V2 owning docs、roadmap、AUDIT、PROGRESS与AGENTS的状态段；
5. symbol snapshot只在public change获准后更新；bot生成后仍要为最终checkout跑主CI；
6. 每一后续finding独立PR/slice，禁止再把preview、cache、retention readback、CI evidence
   合成一个难审的大batch。

完成条件不是“本地看起来通过”，而是 ledger 引用受保护PR/ref的最终run，且文档没有
同一事实的相反句子。

## 4. Phase 1：数据完整性与安全边界

### 4.1 Store bootstrap先分类，再决定能否重建

把fresh/migrating/existing/corrupt作为显式状态，并按“是否能从其他durable facts唯一推导”区分
缺失或异常的状态：

- fresh：创建position/config exactly once；
- approved V1 migration：在migration transaction建立V2 rows；
- existing valid：验证key/cardinality/value并读取；
- position/config缺失、重复或无效：它们无法由现存rows唯一重建，typed fail
  closed，不“补默认值后继续”；
- RetainedBytes等纯派生projection：只有在strict decode、ID/coverage与聚合不变量都通过，
  且重建值可由durable facts唯一得出时，才允许一个明确命名、事务化的rebuild
  path；其它情况仍fail closed。

不要让“query预期key得0”承担fresh判定，也不要把所有derived-state异常一概当作
可修复或不可修复。production store应放在app独占的dedicated `StoreRoot`，该目录只容纳
这个SwiftData store family及其sidecars/external blobs。恢复UX放在app层：Retry、Reveal，
以及在无live coordinator的重启/恢复路径中，由用户确认后将这个**dedicated StoreRoot**
整体移到权限受限quarantine。不移动任意store URL的父目录，也不只移动sqlite主文件。
底层错误文本、localized description或不稳定字符串不得触发自动quarantine；分类没有可靠证据时
只提供Retry/Reveal/退出，不自动破坏原历史。

### 4.2 关系型scalars在最早完整facts处交叉验证

RetainedBytes不只验证nonnegative，还验证canonical/revision count/bytes关系；R3既然已
decode blob，就顺带cross-check。失败统一发生在plan/transaction前，绝不“repair then
continue”。Revision/item ID uniqueness也在Domain plan与codec round-trip双层维护。

### 4.3 Authority-owned destructive time

区分 observed time 与 admitted/commit time。只有Authority clock能支配retention deletion
和durable recency；外部observedAt若保留，只作bounded provenance。Age policy需要一个
明确产品选择：

- **近期低复杂度**：继续event-triggered sweep，但UI明确“将在下次clipboard/history
  activity时应用”；
- **未来若用户需要真实expiry**：最早到期单次timer + startup/wake/resume maintenance，
  不用高频reaper。

### 4.4 先证明是否需要额外hard ceiling

当前finite count/per-item bounds仍可能容许很大的总store，但这不足以授权新拒绝/淘汰语义。
先关闭capacity/ENOSPC的静默失败，测代表store overhead、全pinned/revision压力与reopen。
只有达到批准阈值，再设计包含pinned/revisions的hard content ceiling。UI称“content data
budget”，不能暗示等于实际磁盘。

## 5. Phase 2：一个真实 Clipboard Flow

### 5.1 先让`AppComposition`成为唯一owner，必要时再提取concrete type

先让现有`AppComposition`以private structured operations同时拥有capture drain与copy request生命期，
并让production与composed integration tests走同一入口。只有最低Green后删除测试证明复杂度仍会散回
多个真实caller，才提取`@MainActor`、app-internal concrete `ClipboardFlow`并删除旧owner。它不成为public
protocol、generic bus或第二History boundary。

对capture，该owner的窄流程是：

```text
observe capability/change → freeze one stable result → admit active/latest → await History receipt
→ publish content-free health
```

关键约束：

- start语义先裁决：保留现行“立即导入current clipboard”，或baseline current
  `changeCount`并提供显式Import Current；polling会漏不能替此产品决策；
- 先看access state与declared types；concealed在任何payload read前short-circuit；
- closed result区分empty、complete、incomplete、changed-during-read、retrieval failure；
- start/end changeCount fence，不稳定做有界retry；
- admission后owner稳定保留状态有固定count/byte facts；freeze前provider
  materialization与aggregate RSS仍由独立证据界定；
- 只静默处理明确的excluded outcome；capacity/persistence/permission进入health state；
- polling文案只承诺best-effort latest state。

`DEC-CAPTURE-OVERLOAD` 已选择 active+replaceable-latest：一个active与一个
pending的固定稳定保留形状，active不可替换，新的complete/admissible frozen
snapshot只替换pending，严格按active→latest提交，并把content-free累计
替换数对用户可见。选择理由是保留已开始工作同时优先当前clipboard
值；有界FIFO会优先保留过时中间值，explicit reject则同样丢失最新可操作值。
polling可能漏值不是丢弃已freeze snapshot的理由。该决定不证明freeze前内存、
transient incoming overlap或aggregate process RSS，这些保持OPEN。

### 5.2 同一owner内的copy request

对copy，同一clipboard-flow owner（`AppComposition`或经批准提取的`ClipboardFlow`）中的一个request必须
在同一structured operation内完成：

```text
accept request → resolve approved reference semantics → stage full NSPasteboardItem → write → receipt
→ close on success / retain panel and show failure
```

近期固定为exclusive first-accepted：同一时刻只接受第一个request，按钮/Return pending时
禁用重复触发，后续request不排队、不覆盖。这是最小可解释语义，需直接写进测试；
不再为FIFO/latest-wins预留抽象。全程不嵌套unstructured Task。

Revision race仍需先裁决输出语义。当前规格是current-by-ID；若保留，flow应明确复制最新
Effective并让UI及时refresh/说明。若改为selection-stable，resolve返回的reference必须等于
用户所见reference，不一致时提示并reload。`writeObjects`只能减少partial窗口，不能宣传
跨进程atomic。

### 5.3 Privacy controls的最小集合

先做：AccessBehavior/health、明显且有时限的Pause、conceal marker。Ignore Next、app/type
exclusion与source display是否值得做先走小任务实验；source始终只是best-effort observation。
Regex rule engine、可信provenance、sync/cloud都不是首发目标。

### 5.4 Multi-item的裁决路径

短期：遇到多item时显示unsupported shape并不捕获partial first item。并行做Finder
2/20 files与mixed text/files用户任务实验。

若达到需求阈值，设计：ordered group → ordered items → each item representations；把group
纳入dedup、revision、retention bytes、paste payload与migration。不要复制Maccy flatten。

## 6. Phase 3：让 Presentation 只表达权威状态

### 6.1 一个显式 screen/session state

把隐含的多个Bool/Tasks收敛为最小phase，不要求重写所有views：

- history：inactive / loading(generation) / loaded(snapshot) / invalidQuery / failed；
- panel session：closed / opening / interactive / pendingPaste / presentingSheet / closing；
- capture health：active / paused / permissionRequired / degraded(category)；
- login item：disabled / enabled / requiresApproval / unavailable / failed。

Phase的价值是防止旧rows+新query、旧preview+新version、mutation未完成却reload等不可能组合。
它不是Redux框架；只在当前owner内建小value/reducer即可。

每个可跨session的async工作必须有单一owner和单调request token：activate创建intent，
deactivate/close/query变更先cancel并invalidate，迟到completion只能在token仍当前时写状态。
分页不能用无owner的`Task`跨越隐藏/重开；SwiftUI `.task`与AppDelegate也不得同时拥有
同一activate/deactivate生命期。

故障以episode而不是以文本去重：每次失败的operation产生新episode ID，dismiss只关闭该
episode，下一次同category/value仍需显示。普通page observation成功不得清除无关的
mutation/paste/capture failure；只有同一operation的成功或用户dismiss可以结束它。

### 6.2 Revise editor按Effective Content建模

draft choices明确为Keep Current、Use Original、Hide、Replace。默认从current Effective
byte-exact构建；无dirty返回unchanged。HTML/RTF可选择有validation的raw-markup editor、
真正的rich serializer或禁用Replace；TextEditor不能默认被解释成WYSIWYG rich edit。
Editor/Details mutation都返回awaitable receipt，read发生在write之后。

Revise不是redaction：它会改变当前Effective Content，但旧bytes仍可存在immutable revision
lineage。编辑入口和确认copy要如实提示这一点；不得把Hide/Replace写成“删除敏感
原文”。若draft已dirty，Cancel/Esc需确认丢弃；发现stale reference时保留draft并提供
reload/rebase选择，不要用无声dismiss解决冲突。真正的revision prune/安全删除需另立语义、
持久化和可验证擦除证据，不作为本次编辑修复的附带功能。

### 6.3 Keyboard与focus成为产品契约

summon后的唯一默认：focus search、select newest、arrows移动、Return copy、Esc close；
marked text时IME优先。给Preview一个visible toggle，不依赖隐藏Ctrl-Space。快捷键可配置，
冲突/注册失败可见，换绑失败保留旧组合。

### 6.4 Pagination与search phase

分页sentinel绑定最后一个overall row，不依赖pinned/unpinned lane；另有accessible Load More。
显示“50 shown”或“50+”，不伪造total count。query/mode normalization作为一个原子intent；
旧generation不得被新query标注或执行Copy。

继续保留用户输入的raw draft，与送入History的admitted query分开。mode变更、长度约束和
validation在一个intent内完成后才发起查询，不先发无效请求再修正UI。Exact/regexp的
spaces是语义bytes，不做隐式trim；fuzzy仅在批准的admission规则下clamp。搜索框提供
可见clear action并禁用与clipboard query不符的自动纠正。

### 6.5 Preview以reference和purpose为边界

selected state是`HistoryItemReference?`，不是ID。revision/remove/clear立刻invalidate旧内容，
文本转换移出MainActor并在display前截界；panel close、clear、row removal、version advance有
明确purge generation，迟到任务不能重填。
显示状态区分unsupported、loading、ready与failed(retryable)；decode/I/O失败不能降级成
“No Preview”，同一错误值的新失败也按新episode呈现。panel close后的隐藏selection不得自动
重开preview；下一次session按当前显式preview preference决定。

不要立即扩大唯一History boundary。先比较manual/visible preview与当前auto full-details路径，
跑G8/absolute SLO；只有full hydrate确实超预算且局部修复不足，才批准byte-bounded、exact-
reference-tagged purpose-specific preview payload。

### 6.6 Panel geometry由一个placement值驱动

一个pure `PanelPlacement`同时给出screen、full frame、stable main-content frame、preview
side/mode。AppKit frame与SwiftUI column order读取同一值；position只保存main rect。
窄屏先prototype overlay/replace/收窄三种选项，只冻结“不产生不可达window”。是否采用
`.canJoinAllApplications`等行为只在真机Space/Stage Manager矩阵后决定。

## 7. Phase 4：从有限持久层到可证明的多级 Storage

当前`HistoryStorage`结构上保持唯一Authority，正常路径已有测试，并有严格单项/总项上限与逻辑保留；
corruption、crash、migration/recovery和aggregate residency仍未闭合。它**不是**
已经完成的RAM→disk→cold archive管理器。`@Attribute(.externalStorage)`只给SwiftData一个opaque
placement option；Apple没有承诺稳定blob URL、range/stream read、何时materialize、cache淘汰、
实际空间回收或跨文件crash atomicity。当前完整`SignatureIndex`驻留、每次search构造全语料、
若干mutation读取全retention inventory，details/paste/thumbnail又hydrate整项Canonical与完整
revision blob；把5,000常量调大不能得到“无限历史”。完整源码审计、演进方案与测试矩阵见
[`09-tiered-storage-and-unbounded-history.md`](09-tiered-storage-and-unbounded-history.md)，Apple契约与
UNKNOWN边界见
[`apple-tiered-storage-source-memo.md`](apple-tiered-storage-source-memo.md)。

### 7.1 先建立四本byte账，不把不同资源混成一个数字

| 账本 | 语义与authority | 可作什么决策 | 不能宣称什么 |
|---|---|---|---|
| **logical history bytes** | Canonical与revision representation的逻辑payload；随History transaction更新，是retention的authoritative事实 | 用户的content-data retention、单项admission、迁移一致性 | 不等于SQLite/WAL、外置属性或真实磁盘占用；物理去重也不应偷偷改变用户语义 |
| **physical source/store-family bytes** | SwiftData store family、未来authoritative blobs、staging与GC debt的allocated-size观测 | 磁盘reserve、maintenance、ENOSPC预警与capacity UX | WAL/sidecar/filesystem allocation只能best-effort观测，不能伪装成事务内精确总数或立即回收保证 |
| **derived/rebuildable bytes** | search/thumbnail/static Preview等可由authoritative source重建的durable artifacts | 独立disk budget、derived-first cleanup、backup exclusion | 不能把不可重建的clipboard source误标为cache，也不能靠删除它满足用户history retention |
| **resident/in-flight bytes** | Clipy明确拥有的encoded cache、decoded artifact、queued/loading reservation与active lease | 硬cache/in-flight budget、并发许可、memory-pressure trim | 只约束Clipy-owned对象，不等于全进程RSS，也不能驱逐SwiftData、decoder、filesystem或kernel cache |

四者是不同维度，不能用一个“storage used”相加后驱动所有策略。当前`RetainedBytesRow`最多可承担
第一本账的一部分；它不能直接回答后三本账。面板若展示容量，必须标出logical、device allocation
estimate、reclaimable cache与当前resident各自的单位和证据时点。

### 7.2 History retention、RAM residency、cache eviction与GC是四种不同删除

- **History retention**删除用户可见的unpinned history/revision，改变History Commit和
  `ChangePosition`；count/age/logical bytes属于这里。
- **RAM residency eviction**只释放可重新读取的内存值，不删除history，不推进position；item
  pinned不等于memory-pinned，active lease才临时禁止淘汰。
- **derived cache eviction**只删可重建artifact，可由pressure或disk budget触发；不得让UI把它
  描述成历史已清理。
- **blob GC**只回收已经由authoritative metadata证明不可达的物理source；它不是LRU，也不得
  根据文件年龄猜测“应该已经没有writer”。

系统pressure或低磁盘不能在无显式政策时静默删除pinned或普通history。先清derived cache；若仍
低于hard reserve，就暂停新的capture/revise并给typed health。可选“自动删除最旧unpinned”只能是
用户明确启用的emergency retention policy，不能藏在resident evictor或GC里。

### 7.3 Storage暴露purpose-specific、类型无关的读取，不暴露tier与路径

读取链分成两个阶段；后续 agent 不能把未来接口当成当前已批准 surface：

```text
G8 前：PreviewContentLoader → existing details snapshot → ContentPreview

G8 后：loader把HistoryCore descriptor翻译成ContentPreview-neutral planning facts
      → concrete behavior owner/renderer 产生 access plan
      → loader 调用经批准的 Foundation-only HistoryCore purpose-read
      → HistoryAuthority 验证 exact reference/budget 并返回 bounded immutable input
      → renderer decode；internal depot lease 不跨 target
```

G8 后候选读取链是：

```text
caller purpose + exact HistoryItemReference
→ HistoryAuthority验证存在性、ContentVersion、grant与byte上限
→ immutable ContentReadPlan
→ source/in-flight byte permit
→ representation-scoped bounded read/stream
→ purpose owner解码或回写
→ exact-reference fence后才发布
```

`ContentReadPlan`只描述representation identity、允许的range/sequential/full access、maximum
return bytes、deadline/cancellation、priority和integrity expectation；调用者不得得到SwiftData model、
blob locator或裸file URL。browse/retention只取metadata；search读ingest时生成的bounded projection；
Preview/thumbnail只申请所选representation与批准范围；paste在当前`NSPasteboard`证据下仍走有界、
byte-exact full-`Data` lane，只有future provider/ownership合同经signed proof后才考虑stream；
Python read还要经过live capability与connection quota。

G8 前 loader operation 可以短暂持有完整 immutable details snapshot，但必须计量、支持取消后释放，
且不得放进 SwiftUI observable/process-lifetime state；这不证明 physical on-demand read。Storage本身
不认识PNG、PDF、RTF或视频。`ClipboardFormats`只提供stable facts；`ContentPreview`或其他format
behavior owner根据purpose、neutral facts与实测decoder profile提出access plan，loader负责和HistoryCore
DTO之间翻译。Storage只执行byte/range/budget/cancellation/version contract。这样增加文件类型不会
修改LRU、GC或数据库路径；同一种类型也能因Preview、paste、search目的不同采用不同读取形状。
如果底层decoder事实上要求完整随机访问，结果应明确回报该route的实际需求或over-budget，不能
伪装成streaming成功。

### 7.4 一个source byte permit，多个owner-local cache

资源 owner 固定为三类：Clipboard flow 管 pasteboard acquisition/pending；`HistoryStorage` 管 source
hydration/blob-read permits；`ContentPreview` 与 Thumbnail 各自管 decoder concurrency/output，
PresentationUI 只管 display cache。它们可复用 checked reservation primitive，但首版不建 global
scheduler。每个 owner 在自己的昂贵分配前预留并在取消/失败/超时/迟到结果时释放；whole-process
envelope由批准 caps 的总和与 soak 验证。

completed values继续由最了解reuse与invalidation的owner本地管理：source encoded cache、
Preview decoded cache、thumbnail cache和search artifact各有独立byte/count/version law。第一版只需
可证明的size-aware LRU或明确不cache：

- exact key包含immutable source identity/range、ContentVersion与recipe/renderer version；
- admission前按实际owned cost逐出未lease的最旧entry，永不临时越过硬预算；
- 单对象超过预算比例时bypass cache或typed reject，不先清空hot set再塞入巨物；
- sequential scan默认bypass/probation，避免遍历冷历史污染交互working set；
- warning trim cold/unleased，critical清空所有可重建local cache并停止prefetch；
- `NSCache`只能作可丢弃hint，不能承担硬预算或确定淘汰顺序；
- 只有trace证明LRU scan pollution/抖动后才升级2Q/segmented LRU，不先实现复杂算法。

动态调度依据purpose、byte cost、sequential/random access和用户是否显式请求，而不是在Storage写
每个UTI的优先级switch。候选优先级可从foreground paste、显式details/Python、visible Preview、
dwell、row thumbnail、maintenance开始，但必须由真实重叠workload验证，且不能让大paste饿死或
无界绕过permit。验收看整个进程peak/quiescent RSS与I/O；单个cache的`cachedBytes`绿色不足以关闭。

### 7.5 按证据演进：SwiftData characterization → representation row → blob depot

不要把理想终态一次实现为新repository。分三步，每一步都保留唯一Authority、typed failure、OCC、
ContentVersion与ChangePosition：

1. **现在就characterize当前SwiftData形状。** 在固定macOS/Xcode/fixture上比较scalar-only read、
   details/paste/Preview、R3、migration与并发heavy reads的File Activity、RSS、dirty memory和latency；
   使用fresh operation-local context和autorelease pool作对照。结果只能限定到该OS/query shape，
   不能把`.externalStorage`的观察升级为Apple永久契约。
2. **先做不改 layout 的 caller-shape/telemetry tracer。** caller只收到目标 representation，同时如实
   记录当前 aggregate codec为此实际 hydrate 的全部bytes；若方案A已经满足批准SLO就停止。只有该
   tracer证明monolithic layout本身越界，才另行批准representation-shaped metadata/value migration；
   它不是无固定count cap的默认前置。
3. **只有证据证明需要稳定range/stream、精确source GC/physical accounting，或方案A仍违反批准的
   memory/I/O SLO，才引入app-owned immutable `ContentDepot`。** 它是`HistoryStorage`内的concrete
   deep module，不是第二business writer，不先建packfile/segment/remote cold tier，也不向UI/Python
   暴露locator。

representation row不是multi-item的替代：未来manifest仍须保留ordered ClipboardItems和每item内的
representations，同一UTI可在不同items重复。semantic dedup与physical blob reuse也必须分开；任何
digest仍只是候选，复用前byte-exact确认，opaque BlobID不等于xxh3身份。

### 7.6 如果进入app-owned blob，先证明crash/GC/ENOSPC/migration/backup

文件系统与SwiftData没有可依赖的跨介质原子transaction，因此唯一可接受的是可恢复状态机：

```text
bounded staging write + verify
→ immutable publish（允许暂时成为orphan）
→ HistoryAuthority transaction提交metadata reference
→ 删除时先提交reference removal
→ reachability-proven GC回收unreferenced blob
```

live reference指向missing/corrupt blob必须fail closed；commit前crash最多留下不可见orphan；commit后
清理失败只形成可观测GC debt。以age/grace period猜一个sealed blob“应该不是慢writer”不足以删除；
GC必须从一致的committed reachability事实证明不可达。

进入production前至少关闭以下矩阵：

- child process在staging/write/verify/publish、metadata transaction前中后、receipt前、retire与unlink
  前后逐点kill；reopen只能见完整old/new业务状态，绝不能见dangling live reference；
- disposable volume真实触发create/write/fsync/rename及SwiftData/WAL的ENOSPC/EIO；capacity preflight
  只是提示，失败后old history仍可读、position不假推进、orphan可收敛；
- legacy whole blobs与representation/blob locator双读，item-by-item resumable migration；kill/restart
  幂等，full validation前不删legacy bytes，也不在首次launch全量阻塞；
- backup/restore先quiesce Authority，导出同一metadata generation与全部reachable source；只复制
  SQLite主文件的负例必须失败，derived cache明确排除且可重建；
- logical、physical estimate、temporary、GC debt在reopen后重新核对；删除语义完成不等于allocated
  bytes立即归还，更不等于安全擦除。

### 7.7 “无限历史”只能落成无固定count cap，并有解除O(N)的前置门

诚实的产品文案应是：

> 用户可以关闭按条数或时间的软保留限制，内容从本地存储按需加载；历史仍受设备容量、应用
> 安全限额，以及迁移、备份和恢复所需空间约束。空间不足时Clipy暂停接收新内容并给出可恢复状态，
> 不静默删除历史，也不把所有内容留在RAM。

即使有blob depot，也不能解除count cap，直到以下随N增长的路径都被替换：

1. user maximum-unpinned policy变为可选，同时独立移除/替换包含pinned的global hard bound，
   而不是简单放大常量或另造固定count安全上限；
2. 完整resident `SignatureIndex`改成durable/on-demand posting lookup + bounded hot cache；
3. full `SearchCorpusSnapshot`改为持久projection/index、keyset candidate page与bounded top-K；
4. per-capture完整retention inventory改为transactional aggregate、ordered victim cursor和bounded slice；
5. startup整库coverage与migration/GC改为checkpointed、resumable incremental work；
6. UI page-through不永久append全部rows，observer只保留newest authoritative snapshot；
7. metadata/WAL/index/backup/restore时间和disk headroom先过5,001功能边界，再在50k→250k→1m
   tracer逐级满足SLO。

details/paste/Preview 的 monolithic lineage hydration 属于 large-item/G8 track，应独立修复，但不是解除
many-small-item count cap 的必经前置。

通过1m fixture只证明该OS、机器与workload规模，仍不证明数学意义的无限。production 5,000上限应
一直保留到对应阶段证据通过；调查和test-only tracer现在开始，不等于提前向用户开放无上限模式。

### 7.8 Phase 4的最小交付切片

第一张可领取代码叶是`PLAY-TIER-2A-THUMB`：只量现有aggregate details→thumbnail caller shape、
selected source与authoritative whole-hydration费用，不新增History seam。第一批其余工作只交付四账
measurement receipt、SwiftData characterization、caller-shape/telemetry tracer和
owner-local source/in-flight permit；不迁移现有source layout。之后分成两条互不门禁的track：U-scale直接在
方案A上按metadata/index/UI/maintenance的5,001→50k→250k→1m阶梯推进；large-content则按exact
format/behavior分别测plain-text caller shape、large-image hydration、revision-heavy aggregate与unknown UTI
raw equivalence。只有后者证据触发§7.5，才为一个format-agnostic loose blob做crash/GC vertical slice；
P3通过也不替代U-scale，U-scale失败也不单独授权P3。两条track在production transition前都保持5,000 cap。
Red→Green→Refactor和真机矩阵以
[`04-tdd-remediation-playbook.md`](04-tdd-remediation-playbook.md)及`09`为执行入口。

## 8. Phase 5：有界 Search、格式 facts/manifests 与 Preview pipeline

### 8.0 先测量工作集，再选优化机制

优化顺序先覆盖四个已知高风险workload，每个都用独立子进程记录输入shape、峰值/
稳态RSS、执行时间、I/O与完整性结果：

1. R3 sweep：覆盖多lineage、多revision、大external blob和全pinned，不用零revision小fixture
   代表极端存储形状；
2. V1→V2 migration：seed、migrate、reopen由分离子进程完成，旧container/coordinator不与
   migration并存，同时测批量背压和中断后可重开性；
3. search：测量corpus materialization、rapid query churn、cancel latency、top-K内存和Authority
   wait；
4. preview/image：测量source hydration bytes、decode并发度、MainActor时间、滑动峰值与cancel后
   discarded work。

只有某workload超过批准的absolute SLO，才选它的最小局部机制（例如bounded migration
batch、R3 maintenance slice、bounded top-K或thumbnail permits）。不因纸面最坏值同时引入scheduler、
resident index、持久化maintenance state和disk cache。

### 8.1 Search先admit，再读取

无I/O admission在任何context/corpus前执行；empty term走recent。一个generation最多有一个
active execution，queued generation不预持有full corpus。Authority projection与matcher
按bounded chunks检查cancel/epoch。

Exact/regexp若能按稳定默认顺序流式找到`limit+1`，无需构造全hits；fuzzy用bounded top-K
accumulator。只有代表性50/200/999项连续输入超过SLO，才考虑resident corpus/FTS；5k保留
capacity stress，不支配日常架构。

### 8.2 Regexp是明确受限能力

保持显式mode，不放进默认mixed search。Pure admission拒绝已知危险grammar；runtime使用
progress cancellation与monotonic deadline；timeout有typed结果。危险表达式测试先跑
pure/child-process watchdog，避免把CI进程挂死。

### 8.3 Thumbnail permit在source hydration之前

same-key flight外，再限制distinct active keys与aggregate source bytes；queued只持reference。
row task保留structured cancellation。小型有界worker pool足够，preview可有明确优先级；
不要建generic scheduler。

completed cache若G1未触发则删除，回到visible-state。若触发，准入文档必须写identity、
byte law、eviction、memory pressure、version/removal/clear/close invalidation、decoder version；
仍不需要disk cache。

### 8.4 Image/text materialization真的离开MainActor

owner规格先统一。ImageIO如果留在一个内部display decoder，gate要path-scoped准入且不让
CGImage出现在public/package signatures；像素在worker内eager materialize，首次render不
decode。大text只取bounded prefix并在non-main concrete worker解码一次。

### 8.5 `ClipboardFormats`：开放世界transport上的声明式事实层

新增一个Foundation-only、`package`级`ClipboardFormats` target，作为代码中可直接审阅的稳定
格式事实目录。它只拥有validated exact identifier、稳定family/wire fact、special role
（例如lineage/concealment/promise metadata）和evidence ID；不import AppKit、SwiftUI、SwiftData、
ImageIO、PDFKit或WebKit，不持有bytes、decoder closure、cache或runtime plugin registry。

“支持”必须按能力分轴，不能退化成`isSupported`或capture allowlist：

- raw capture与verbatim paste保持**open world**；合法、非空、限额内的unknown/custom/dynamic UTI
  默认仍保存和原样回写，未知只表示raw-only，不表示拒绝；
- `PasteboardAdapter`、`HistoryStorage`、`ContentPreview`和editing/presentation各自拥有
  purpose-specific manifest，分别决定special replay、search projection、preview route、edit
  codec与显示；共享facts，不共享一个policy god-object；
- build/test inventory按稳定key join这些manifest，生成排序稳定、机器可读的capability snapshot，
  并检查unknown fallback、route/budget/evidence与故意差异；inventory用于审计，不成为所有生产
  路径的中央dispatcher；
- runtime能力（例如ImageIO可读类型）只与产品声明求交并给出available/unavailable reason，不能
  自动把Apple新类型升级为Clipy承诺，也不能把一次malformed input写回全局能力状态。

各owner的change identity必须分轴。已有durable consumer的`SearchProjectionRecipeVersion`随title/search
语义变化；Preview、Edit、Pasteboard先用manifest/build identity。只有跨启动cache、durable artifact或
稳定external wire真正出现时，才把相应identity升级为独立语义version；capability JSON schema另行版本化。
新增Preview不得顺手触发search migration；search投影变化也不得借Preview cache identity代替migration
disposition。

这个目录**不能替代multi-item建模**。类型目录回答一个representation能做什么；multi-item回答
clipboard snapshot如何保存ordered items及其representations。后者仍需§5.4的DTO/domain/schema、
equality/fingerprint、revision、retention、lineage与replay裁决。在该裁决前，不能把第二个item合并
进目录、flatten成重复UTI，或声称“catalog已支持Finder多选”。

### 8.6 `ContentPreview`：一个concrete、独立且有界的深模块

新增一个独立的`ContentPreview` concrete target/module；首个版本是`package`接口，不预建
`PreviewCore`/Apple adapter双target、每格式public protocol或runtime plugin ABI。它依赖
`ClipboardFormats`稳定facts，在内部拥有Preview manifest、source planning、runtime admission、
Apple renderer dispatch、sanitization、预算与typed outcome；具体image/rich/PDF/file/media renderer
只是同一target内的逻辑owner。

`PresentationUI`只拥有selection/panel/exact-reference的task与late-result fence；G8前loader operation
短暂持有现有full details/Effective snapshot并交给`ContentPreview.render`，这不是bounded source seam，
必须计量且cancel/close后释放。SwiftUI observable/render state不解析bytes、不维护UTI set、不选择
renderer，也不持有`CGImage`、`NSImage`、`NSAttributedString`、`PDFDocument`、`WKWebView`、
`AVAsset`或file-access lease。module只返回有界、不可变、`Sendable` primitives，例如capped text、
validated eager raster bytes + dimensions、static document/media/file summary和typed unavailable。
先复用现有exact-reference History read；只有G8/absolute SLO证明full details hydrate越界，才批准
purpose-specific、byte-bounded的History preview read，不因新target自动扩大`ClipboardHistory`。

首批准入按下面的tier推进，而不是一次宣称“支持所有Apple类型”：

1. unknown/custom/dynamic：raw capture/paste，type/byte metadata，Preview明确unsupported；
2. exact UTF-8及经byte-order fixture证明的UTF-16：bounded text/search；Replace只有成对
   parser/serializer证明后开放；`public.text`/encoding-unspecified plain text不猜UTF-8；
3. PNG/JPEG/TIFF static ImageIO，再按runtime intersection、真实fixture与resource child proof逐项
   准入HEIC/HEIF/GIF/BMP；type label与bytes不匹配是media outcome，不是store corruption；
4. inert、sanitized、bounded RTF/RTFD和static PDF first-page只能在各自resource/a11y proof后加入；
5. HTML首期优先使用exact plain-text sibling，否则只显示type/byte metadata；只有明确charset/codec或另批
   有限static grammar后才允许source artifact。file URL只显示metadata；Quick Look、cloud/network
   file、file promise、AV playback及交互PDF全部后置到显式用户动作和独立证据门槛。

所有自动thumbnail、dwell和selected Preview默认**无外部I/O**：不发DNS/HTTP，不读外部file URL
正文，不触发iCloud/File Provider/网络卷下载，不兑现file promise，不自动播放或执行link/PDF action，
也不写persistent website data。Apple只给输出尺寸或取消入口时，不能升级为peak RSS/CPU/deadline
保证；用adversarial child-process测量决定某renderer留在进程内、保持disabled，还是迁入最小权限
helper。不要在证据前把所有renderer进程化。

### 8.7 Phase 5内部交付顺序

先修正RTF/HTML/abstract text的naive UTF-8与Replace语义，再落地facts + owner manifests + inventory；
随后用plain text和PNG形成一条`PreviewContentLoader → ContentPreview.render` production tracer，
证明exact-reference、取消、typed fallback、资源回收和UI无解析。之后才逐格式增加ImageIO、RTF/RTFD、
PDF与显式file能力。multi-item另走§5.4的schema tracer。Python capability export只消费decision批准的
owner-exported immutable summaries与独立pure serializer；build/test inventory仍只做漂移检查，不进入
production，也不反向驱动格式policy。

## 9. Phase 6：State 3 与可信发行

### 9.1 第一条发行路径

优先选择Developer ID direct distribution：

```text
protected release ref == marketing/build version
→ one exact protected-ref full CI
→ Release archive
→ sign all code + hardened runtime + secure timestamp
→ notarize + staple
→ codesign/spctl verification
→ download/copy到干净机器后再验并跑smoke
```

App Sandbox需在发行决策中显式处理。Clipy当前不解引用file URL、无network，原则上适合
窄entitlement sandbox；但已有store迁移、General pasteboard与login item必须在signed
配置实测。不要无迁移计划直接翻开关，也不要长期用unsigned Debug代表发行。

Updater、MAS和Homebrew都延后。若以后加入updater，feed/signature/artifact必须由同一
release transaction生成，不能像当前Maccy fork那样release自身却读取upstream feed。

### 9.2 Recovery是产品能力

启动失败页面最低有Retry、诊断category和Reveal。Quarantine+New Store只在数据位于
app独占dedicated `StoreRoot`、没有live coordinator，且用户明确确认后出现；不根据
localized error/底层错误字符串自动分类或移动数据，也不把store URL的通用父目录
当作quarantine边界。不得自动丢历史或悄悄切内存库。Quarantine仍含敏感
clipboard，路径和内容不进日志。
Clear只承诺逻辑删除，除非另有SQLite/WAL/external blob/backup证据，不写“安全擦除”。
Export会扩大敏感数据处理面，只有独立需求、格式与授权设计后才加入。

### 9.3 Localization与accessibility

先建String Catalog、FormatStyle、plural、pseudo/RTL，再选择实际locale并QA。所有controls有
stable identifiers、labels、focus order和keyboard equivalents；VoiceOver与Full Keyboard
Access完成同一summon→find→copy journey。不要用accessibility labels数量代替journey。

## 10. Phase 7：签名发行后的本机 Python 自动化

### 10.1 产品承诺与交付时机

Local Automation不再是笼统non-goal，而是用户明确要求的**strategic post-baseline slice**。建议冻结
的最终承诺是：用户在Clipy中显式启用Local Automation并逐项授权后，同一effective user account（same EUID）下，任何
能执行第一方`clipyctl`的Python 3进程都可仅用标准库`subprocess`发送versioned JSON request/reply，
查询或执行获准的单项修改。它不表示任意`.py`有独立身份，不表示受限caller sandbox一定允许启动
外部executable，也不开放network、remote或跨用户gateway。

顺序必须是“现在设计，signed gateway后shipping”：先按§11关闭baseline、normal-path correctness、
data recovery、accessibility和Developer ID发行路径；再用最终签名的app + CLI证明cold/warm launch、credential、
sandbox/TCC、grant/revoke、audit与failure contract。unsigned hosted test、开发机socket成功或
V2-05设计文档本身都不能支撑“任意Python可用”的产品声明。当前Gateway实现叶是roadmap
**X.3 schema/limits/bootstrap**：新建immutable `HistorySchemaV3`，保持已shipping
`HistorySchemaV2`不变；bootstrap恰好一个config与active
`Siri / Shortcuts / Spotlight` connection，且grant/audit均为零。X.3不实现audit codec、actor、facade、
admin、App Intents、CLI或transport；完整codec与atomic admin audit同属X.4。该叶的证据不能外推为
Gateway或Python可用。

### 10.2 唯一稳定外部interface与私有transport

Python唯一稳定依赖是第一方`clipyctl`：JSON stdin/stdout、少量稳定exit-code classes、versioned
operations、checked size/deadline和content-free stderr。clipboard bytes、query、credential不得进
argv/environment/log/audit。public compatibility属于executable wire，不要求把socket path、Mach
service、Swift enum raw value或SwiftData schema变成public SDK。
该wire contract及golden examples可以先于实现冻结；CLI parser/executable代码仍必须排在完整in-process
Gateway deny/positive substrate与App Intents tracer之后。

`clipyctl`之后的transport保持private且可替换。第一项判别spike可以是signed Developer ID、
non-sandbox artifact上的app-owned UDS + LaunchServices ready handshake；它只证明这一artifact，不能
自动成为最终路线。最终在UDS、Apple Events、App Intents或signed CLI→XPC间选择，必须由arbitrary
Python/signed non-team/same-team caller、TCC、sandbox、cold launch、binary与single-writer真机矩阵决定。
同一版本只shipping一条production transport，不并行维护四套fallback，也不让Python绑定private
framing。

### 10.3 `ExternalGateway`仍是唯一 external trust boundary

合法路径始终是：

```text
Python → clipyctl → private transport adapter（frame + peer evidence）
       → authenticated ingress facade（无policy薄包装）
       → ExternalGateway.authenticateAndPerform(peerEvidence, credential, request)
       → internal connection resolution / live grant / audit → HistoryAuthority
```

CLI/adapter不得打开或复制SwiftData store，不创建`ModelContext`，不拥有History semantics，也不成为
第二writer。private transport adapter拥有framing、length-before-allocation、connection/backpressure与peer
evidence preflight，再交付bounded typed request。`ExternalGateway`仍是唯一外部trust boundary，集中semantic
request bounds、credential→connection resolution、rate limit、live grant recheck、opaque locator/token、audit和typed failure；所有durable write仍由唯一
`HistoryAuthority` transaction完成。ingress只把bounded evidence/credential/request原样委托，不能解析
connection或缓存授权。V2-05已经接纳的App Intents不是non-goal：它应作为共享Gateway的
第一个用户可见adapter，不能另写一份capability/audit逻辑，也不能冒充稳定Python RPC。本轮Python
要求是对V2-05的显式amendment；先通过process-internal Gateway deny/positive tests和App Intents tracer
冻结授权、审计与opaque-token语义，再实现CLI pure codec，最后选择和实现Python的production transport。Transport不得反向定义Gateway
capability或History mutation。

App Intents使用预绑定connection-scoped facade；Local Automation在credential尚未解析时不能伪造同一个
入口。具体authenticated-ingress surface由`DEC-PY-AUTHENTICATED-INGRESS`裁决；它当前明确为
`BLOCKED-SPEC`，不阻塞Gateway/App Intents，却阻塞production transport和任何Local Automation正向
History tracer。Local Automation新增
独立、deny-by-default的enrollment kind，产品明确告知：同一effective user account（same EUID）下能执行
`clipyctl`的进程共享这一connection/grant/audit attribution；same UID或signed CLI都不能识别某个
`.py`文件。network listener、SSH/remote daemon、跨用户service和direct store access继续明确非目标。

### 10.4 capability先拆细，`reviseContent`最后开放

V2-05当前`.browse`/`.readContent`/`.manage`保留为App Intents既有surface，不迁移也不改 implication；
它们对任意本机进程过粗，因此Local Automation使用独立closed capability cases：

- `browsePreview`：bounded title/snippet/types/time/pin；它仍是content-bearing，授权文案不能称
  “无敏感metadata”；
- `readEffectiveContent`：只读当前Effective representations，不返回Canonical、旧revisions或完整
  lineage；
- `organize`首版只含pin/unpin，不隐含删除；reorder需独立`DEC-PY-REORDER`/OCC卡；
- `deleteItem`：单item destructive grant，不隐含clear；
- `reviseContent`：后期单独grant；首版只做replace，以opaque locator + exact content token做OCC；hide/
  revert-to-canonical各自另行准入。在wire draft、stale conflict、read-audit contract和mutation
  idempotency决定前不开放。

继续禁止external `capture`、bulk `clear`、retention config、generic `HistoryAction`字符串命令和
grant/audit admin。若旧`.manage`先实现，迁移也不能自动给现有connection升级delete/revise权限。
`clipyctl` stdin的`describeFormatCapabilities` JSON shape可以先声明，但只有在
`DEC-FORMAT-INVENTORY-OWNER`批准后，production endpoint才可消费各owner-exported immutable Foundation
summaries与独立pure serializer，让Python看见当前build/runtime格式能力；它不得import/reuse build/test
audit inventory，也不是content grant。在runtime injection owner存在前，golden JSON不是已实现endpoint。
Gateway仍须按live grant、exact token与authoritative owner policy重新验证实际操作。

### 10.5 最小vertical release顺序

先修订V2-05并用in-process tests完成`ExternalGateway`的closed matrix、deny与positive substrate；
再让已接纳的App Intents adapter只走该Gateway。之后才实现Python的JSON/exit/no-content pure codec，
关闭authenticated-ingress blocker，完成signed transport discriminator并shipping唯一transport；其上的第一个cold-start
tracer是`browsePreview`，随后是Effective-only bounded binary read，最后按
`organize → deleteItem → reviseContent`逐项开放。
每一步都跑revoke race、wrong credential/different UID、timeout/no-blind-retry、audit与single-commit proof。
只有最终notarized app/CLI在Terminal、IDE、venv和launchd Python矩阵通过后，产品文档才写
“同一effective user account（same EUID）下、持有效enrollment/grant的任意Python可用”；这不证明
同一GUI/audit session，也不提供per-script identity。

## 11. 统一优先级策略（可领取ID仍只在`04`）

后续Agent不得按Phase编号整章开工，也不得把所有P1风险升级成同一个blocker。与
[`00-executive-review.md`](00-executive-review.md#6-建议执行顺序)一致的领取顺序是：

1. **可信baseline**：只修当前compile/warning与truth drift；受保护PR/ref最终checkout全lane绿色。
2. **正常可达correctness**：先修Revise Keep/dirty draft、exclusive paste、UI generation/session/
   exact-reference/pagination与failure episode。这些日常路径明确早于singleton corruption等人工损坏
   hardening。
3. **格式语义**：关闭RTF/HTML/abstract text/UTF-16错误路径，建立manifest；unknown raw不收窄。
4. **signed privacy/capture**：AccessBehavior、stable freeze、concealed-before-bytes、有界drain与health。
5. **资源与Storage调查/tracer**：search/observation/thumbnail bounds；同时交付四账measurement、
   SwiftData characterization、caller-shape/hydration telemetry和owner-local source byte permit。此处不批准
   新History purpose-read或production blob
   migration，也不因“storage很重要”跳过Red与真实RSS/I/O证据。
6. **corruption与durability hardening**：singleton/RetainedBytes/signature/revision、true child reopen、
   migration/ENOSPC基线。它晚于正常Keep/Paste/UI修复，但若后续要改变durable source layout，它必须
   先为新layout定义fail-closed与恢复证据。
7. **独立U-scale/count路线**：不依赖P3，先替换normal-path O(N)、UI/pin/validation/Clear/retention tail，
   完成current StoreRoot capacity/backup与5,001→50k→250k→1m证据；最后才由owning spec开放无固定count cap。
8. **条件式large-content/P3路线**：仅§7.5 G8/range/stream gate触发后，先representation rows/opaque
   SwiftData sidecar，再做一个loose immutable blob vertical slice及crash/GC/migration/backup；进入该分支时
   仍保持5,000 production cap，不能用blob存在替代U-scale证明。gate未触发不阻塞步骤7或有限历史State 3。
9. **State 3**：真实UI journey、recovery、A11y/localization、Developer ID sign/notarize与signed matrix。
10. **V2 automation**：先amend V2-05并完成唯一`ExternalGateway`与已接纳的App Intents adapter；Gateway
   语义闭合后才选择Python production transport，再按browse→read→organize→delete→revise开放。
11. **superiority claim**：最后在同机signed Release matched journeys报告正确性、latency、RSS/I/O和
    failure rate；没有综合总分，也不把1m soak称为无限。

第5、7项意味着多级存储调查**现在开始**，实现则分证据门；不是旧的“等G8以后再看”，也不是现在
就盲造repository、packfile或全局scheduler。

## 12. 性能与“超过 Maccy”的声明门槛

### 12.1 先有absolute SLO，再谈结构优化

建议冻结少量产品指标：

- launch到capture-ready；
- summon到首行可交互；
- keystroke到稳定结果；
- selection到preview可见；
- Return到paste receipt/panel close；
- burst后的peak/settled RSS、Authority wait、discarded work；
- 60秒image scroll后的source bytes、cache bytes、steady RSS。

阈值在目标macOS26 arm64 hardware上采baseline后批准。Core complexity runner继续做ratio
proof，但不得宣称UI latency。

### 12.2 同机A/B只比较语义等价cell

Maccy支持而Clipy尚不支持的multi-item/auto-paste cell标“missing”，不能偷偷换成first item/
copy；Clipy revision/OCC等Maccy没有的cell也单列。报告每个workload的p50/p95/p99、peak/
settled RSS、CPU/energy、failure rate，不生成综合分数。

先跑三个matched journey：cold ready、summon→find→copy、image/text preview切换。只有准备
发布更广performance claim时才跑完整矩阵。

## 13. 需要规格裁决、不能由实现Agent擅自决定的项目

未裁决条目为 `OPEN`；已有明确冲突且无法安全推断的条目标为
`BLOCKED-SPEC`；owning document 已冻结答案的条目标为 `RESOLVED`。
`Owner` 是必须被修改并记录批准的 owning document，不是建议找谁口头确认；
`Blocks` 指最早不能领取的设计/执行族。

| Decision | Owner | Status | Blocks | 必须冻结的问题 |
|---|---|---|---|---|
| `DEC-RET-READ` | V2-02 + V2-07 + HistoryCore surface | RESOLVED — existing `ClipboardHistory.retentionConfiguration()` purpose-specific public read | — | one validated count+policy snapshot; no live usage/OCC/model identity; owned conformer source break; no fabricated default implementation |
| `DEC-PREVIEW-TARGET` | 01 architecture + V2-07 + roadmap | **RESOLVED (2026-08-24)** — one concrete package-only `ContentPreview` target | — | common-caller closed presets；ClipboardFormats/CoreGraphics/ImageIO allowlist；tight premultiplied BGRA8/sRGB eager artifact；PresentationUI blocks ImageIO and publishes no CGImage/framework object；loader retains History/reference/task/lifecycle ownership；no registry/plugin/cache/external I/O。 |
| `DEC-THUMB-CACHE` | 06 G1 + V2-07 | OPEN | thumbnail cache cards | completed cache 是否获准；否则退回 visible-state。 |
| `DEC-THUMBNAIL-REQUEST-OWNER` | 01 target graph + V2-07 | OPEN | format migration/thumbnail request | row DTO neutral eligibility、UI always-request还是双manifest；Storage仍拥有source/version fence。Batch 31仅把已选中、已version-fenced的PNG交给ContentPreview做inert display rasterization，不裁决request/source/cache owner。 |
| `DEC-CAPTURE-OVERLOAD` | 01/06 cross-cutting + pasteboard roadmap | **RESOLVED (2026-08-24)** — one active + one replaceable latest pending | — | active不替换；complete/admissible新值只替换pending；active→latest串行drain；累计content-free replacement count对用户可见；不由polling漏值辩护；pre-freeze acquisition/transient overlap/RSS仍OPEN。 |
| `DEC-RET-AGE` | V2-02 + V2-07 | OPEN | age UI/maintenance | age 是 event-triggered 还是 wall-clock expiry。 |
| `DEC-CAPTURE-CLOCK` | 03a + V2-02 | OPEN | capture/retention | untrusted `observedAt` skew与 Authority clock。 |
| `DEC-REVERT-RACE` | 03a + V2-02 | OPEN | revision planner | target被R3 prune后采用phase-1 snapshot还是phase-2 existence。 |
| `DEC-UNPIN-SWEEP` | V2-02 | OPEN | unpin/retention | unpin是否立即sweep，以及是否保护刚unpin item。 |
| `DEC-MULTI-ITEM` | overview + domain + schema/roadmap | OPEN | PB-MULTI | multi-item是否进入首发；否则可见unsupported state。 |
| `DEC-DISTRIBUTION` | 06 cross-cutting + V2-06 release | OPEN | signed gates | Developer ID还是MAS；sandbox migration/entitlements。 |
| `DEC-AUTO-PASTE` | V2-07 platform/UX | OPEN | AX/paste | 自动粘贴价值是否足以要求Accessibility授权。 |
| `DEC-SOURCE-LABEL` | presentation/privacy owning docs | OPEN | source UI/filter | frontmost-app弱观察的产品文案与过滤语义。 |
| `DEC-PASTE-REFERENCE` | 03b/04 read-paste contract | **RESOLVED (2026-08-24)** — current-by-ID at the Authority read | — | displayed exact reference只做submission admission；read前revision返回新payload/reference，read后revision不替换已解析的自洽payload；selection-stable v1 rejected。 |
| `DEC-PREVIEW-FALLBACK` | V2-07 + Preview manifest | OPEN | PREVIEW fallback | type mismatch/malformed后是否尝试后续representation，以及priority/budget。 |
| `DEC-OBSERVER-START` | pasteboard/app lifecycle spec | **RESOLVED (2026-08-24)** | — | process startup与explicit access Retry立即导入current complete generation；user Pause后的Resume只baseline current `changeCount`，不导入pause期间值，下一generation才capture。一个observer/direct start option，不造second path。 |
| `DEC-RICH-EDIT` | 03a + V2-07 | OPEN | FORMAT edit | HTML/RTF是raw markup editor、rich serializer还是禁用。 |
| `DEC-PY-TRANSPORT` | V2-05 amendment | OPEN | Python production adapter | public surface已固定为first-party`clipyctl`；signed/sandbox/TCC后只选择其背后的单一private transport。 |
| `DEC-PY-AUTHENTICATED-INGRESS` | V2-05 + 01 target graph | **BLOCKED-SPEC** | `PLAY-PY-F1`、`PLAY-PY-B3`、`PLAY-PY-B3A`、`PLAY-PY-B3B`、`PLAY-PY-B3C`、`PLAY-PY-B4`、`PLAY-PY-B5` | ClipyApp不能访问internal Gateway，unknown credential也不能使用App Intent预绑定facade；必须批准一个只携带bounded peer evidence、opaque credential与typed request的受限app-facing ingress及其target/access placement。不得用公开Gateway、公开CredentialStore或transport-side policy绕过。 |
| `DEC-PY-CONNECTION-ALLOW-MATRIX` | V2-05 §0.2 | **RESOLVED (2026-08-22)** | PLAY-PY-GW0由Batch 6实现；下一层为roadmap X.2 public contract | closed total matrix保持`.appIntents`既有browse/readContent/manage与operation/implication不变；`.localAutomation`只准browsePreview/readEffectiveContent/organize/deleteItem，revise后置；所有cross-kind/unknown pair在History/audit前deny。 |
| `DEC-PY-X3-SCHEMA-BOOTSTRAP` | V2-05 §4/Record 5 + V2 roadmap DC-03 | **RESOLVED / LANDED (2026-08-22)** | roadmap X.3 | incremental shipping：新增immutable `HistorySchemaV3`，绝不修改已shipping V2；只落四models、fixed limits、config + active `Siri / Shortcuts / Spotlight` connection、zero grants/audit bootstrap与validation。X.3不落codec/actor/facade/admin。config absent + dependent tables全空允许重建，但诚实记录它与未来V3全删同形；只拒绝仍有dependent row的可区分腐败，不加marker/hash。 |
| `DEC-PY-GRANT-AUDIT-STATE` | V2-05 §4.2/§4.4/§5.6 | **RESOLVED (2026-08-22)** | roadmap X.4 / PLAY-PY-GW1…GW4 | 每个connection/capability只有一条current-state GrantRow；re-grant更新同一行，event history只进audit。`OperationPayloadBlobV1`已在owning spec冻结完整closed request/result tags与outcome compatibility；global rebase/compact的connection/capability为nil，不伪造admin capability。 |
| `DEC-PY-X4-AUDIT-CODEC` | V2-05 §4.3–§4.5 | **RESOLVED-SPEC (2026-08-22；code open)** | roadmap X.4 / PLAY-PY-GW1…GW4 | raw 10只表示revoke connection，新raw 16/17/18/19分别revoke capability/connections read/grants read/audit read，三种admin read都audit。read先构建immutable result/snapshot，audit commit失败则不发布DTO/content；audit read用pre-append snapshotHead避免包含自身。单blob最大16 KiB；`auditBytes`=Σ(`payloadBlob.count + 128`)是logical counter，不声称physical disk bytes。enroll只在success后带new connection ID，pre-create denied/failed为nil。ordinary-open corruption仍fail closed；X.4不新增public recovery opener。 |
| `DEC-PY-AUDIT-INTEGRITY` | V2-05 D36 + repository no-hash rule | **RESOLVED (2026-08-22)** | roadmap X.4 / `X-SECURITY-2` | 不实现audit hash/chain/CryptoKit，也不声称tamper evidence；typed codec、transaction内counter+row、monotone contiguous `auditSequence`与`compactionFloor`只证明可检出的内部一致性边界。audit无off-switch。`GatewayConfigRow.generation`删除。 |
| `DEC-PY-READ-AUDIT` | V2-05 audit | **RESOLVED (2026-08-22)** | 首次真实content release：PLAY-PY-D1A/B/C、D3/D5/D9及future stream | 所有已admit API attempt都durable-before-publication：先得immutable result/failure，再成功append一条audit，然后才return/throw。append失败不释放DTO/content；crash-after-audit-before-return可留record。rate-limit每call一条immutable denial，不coalesce或update旧row。 |
| `DEC-PY-IDEMPOTENCY` | V2-05 mutation/audit | OPEN | PLAY-PY-E7及future revise retry | request ID如何与mutation/audit同transaction及保留窗口；E6A/E6B的default no-blind-retry可先测。 |
| `DEC-PY-REORDER` | V2-05 organize + pin ordering | OPEN | future organize-reorder leaf | reorder locator/OCC/position/audit语义；首版organize仅pin/unpin。 |
| `DEC-PY-DELETE-UX` | V2-05 + automation UX | OPEN | PLAY-PY-E2 release | 每次确认还是持久destructive grant；无clear implication。 |
| `DEC-PY-REVISE-SUBSET` | V2-05 + 03a revisions | OPEN | future hide/revert leaves | 首版replace后，hide与revert-to-canonical各自basis/effective-result/OCC/audit。 |
| `DEC-PY-REVISE-CONTRACT` | V2-05 amendment + 03a revisions | OPEN | PLAY-PY-D9/E3/E4 | 首版replace-only draft、readRevisionBasis shape、独立grant、read/write audit、OCC token与failure语义。 |
| `DEC-FORMAT-TIERS` | V2-07 + format roadmap | OPEN | FORMAT/PREVIEW runtime | 首发format/resource envelope与helper isolation阈值。 |
| `DEC-FORMAT-INVENTORY-OWNER` | 01 target graph + V2-05 §0.3/V2-07 | **BLOCKED-SPEC** | PLAY-FORMAT-G production injection | `describeFormatCapabilities`目前只允许从各owner声明的immutable Foundation summaries做pure projection/schema；production由谁join/inject尚未批准，不能让Gateway反向import UI、复用test inventory或在CLI复制catalog。 |
| `DEC-COUNT-DISABLED` | V2-02 + HistoryLimits/public config | OPEN | PLAY-COUNT-6A/6B test-only shape；9A/9B production transition | user count policy optional与global hard max分别如何移除；production transition还必须先通过shared `PLAY-DISK-0A/0B/1/2A/3/4/5/6`；低盘pause还是opt-in cleanup。 |
| `DEC-RETENTION-BATCH` | V2-02 commit/trigger/receipt semantics | OPEN | PLAY-COUNT-3CV/3RV、5A/B/C/5R3/5X及future unpin-victim leaf | capture/revise/unpin/policy触发大量victims/prunes时，是external spool+one History commit还是durable applying batches；R3→R1/R2组合、position、receipt、交错与恢复语义。 |
| `DEC-CLEAR-SCALE` | 03a clear + 06 maintenance | OPEN | PLAY-COUNT-5D | 大库Clear的立即可见性、batch progress、ChangePosition/receipt、capture交错、cancel与crash恢复。 |
| `DEC-STARTUP-VALIDATION` | 05 startup + signature/retained projections | OPEN | PLAY-COUNT-1C/1D production fallback | lazy/background validation尚未触及的projection能否用于negative evidence；poisoned signature/aggregate时capture/revise是authoritative bounded fallback、typed pause还是fail-closed health。 |
| `DEC-RESOURCE-BUDGETS` | 06 cross-cutting resource/admission + owner specs | OPEN | production defaults + PLAY-SOAK envelope | literal-budget PURE/MEM evidence可先做；决定四本账生产预算、单位、刷新与typed thresholds。 |
| `DEC-PERMIT-SCHEDULING` | 06 cross-cutting resource ownership | OPEN | PLAY-MEM-7 | 多资源原子预留还是固定顺序/no-hold-and-wait；priority aging/fairness。 |
| `DEC-P3-ADMISSION` | V2-00/V2-06/facts/roadmap/AUDIT | OPEN | PLAY-TIER-SPEC-0及P3 | 何种large-content证据批准representation layout、`ContentDepot`/blob subroot，以及既有StoreRoot backup-generation的P3扩展。 |
| `DEC-P3-MIGRATION-WRITES` | V2-06 P3 migration + History commit semantics | OPEN | PLAY-MIG-6 | dual-read迁移期间capture/revise/remove是write-new、受限dual-write还是typed maintenance gate；cursor与concurrent commit的线性化点。 |
| `DEC-PURPOSE-READ` | 01 architecture + 03b + V2-07 | OPEN | PLAY-TIER-2B/3/4/5S/5P/6 + future PY-D seam | 首批future purpose、cross-target Foundation seam、cancellation/lease/max-return/exact-reference；不阻塞1A/1B/`PLAY-TIER-2A-THUMB`或existing-details Preview。 |
| `DEC-SCALE-GATES` | 06 cross-cutting + V2-06 | OPEN | PLAY-COUNT-9A/9B production transition、9C/release claim | COUNT/test-only scale evidence可先做；决定5,001与50k/250k/1m SLO、headroom及时限。 |
| `DEC-U-SCALE-STARTUP-INDEX` | V2-06 P1 + startup/dedup owning specs | OPEN | PLAY-COUNT-1/1B/1C、production count transition | Recipe-v2 validation与P1 complete checkpoint/in-memory SignatureIndex只保留在5k capped regime；U-scale必须排他选择一个durable indexed candidate-query/lazy-shard authority（可含bounded hot window但必须authoritative fallback），不得保留双truth index，也不能把complete resident index继续当correctness前提。 |
| `DEC-SEARCH-SCALE-SCOPE` | 03b search + 06 performance | OPEN | PLAY-COUNT-4F/4R | exact保持现有全历史语义；fuzzy/regexp在大历史仍全历史还是显式bounded scope，并冻结ranking/cursor/cancellation/SLO。 |

这些问题必须记录到owning spec/ADR并配判别测试。Review给出选项与风险，但不应替代产品
所有者作隐性决定。

## 14. 明确非目标

- 不为首发实现cloud/sync/telemetry/OCR/ML/plugins。
- Local Automation是strategic slice，但不是当前correctness/State 3 baseline blocker；不在signed
  gateway与最终发行矩阵前shipping transport。V2-05已接纳的App Intents应先共享唯一Gateway；它不是
  Python SDK，Python是同一owning design的后续amendment。
- 不做network/remote/cross-user gateway、常驻通用daemon或临时内容export。
- 不让Python、CLI、helper、App Intent直接访问SwiftData，不公开private socket/framing为第二SDK。
- 不复制Maccy的global service locator、position-based destructive automation、private API。
- 不flatten multi-item，不用64-bit fingerprint作cache correctness identity。
- 不用`ClipboardFormats`白名单限制unknown raw capture，也不用catalog掩盖multi-item schema缺口。
- 不为每种UTI创建target/public protocol，不在证据前引入runtime renderer plugin ABI。
- 不让PresentationUI解析clipboard bytes、选择decoder或持有Apple renderer object。
- 不再把多级Storage调查推迟到G8以后：四账characterization、caller-shape/hydration tracer、byte permit和规模
  harness现在开始；但没有§7.5/§11证据前不shipping app-owned depot、disk cache、resident corpus、
  FTS、packfile/segment或多层repository。
- 不向调用者暴露`hot/warm/cold`tier，不让每种UTI拥有storage handler；`ClipboardFormats`只给stable
  facts，类型access plan属于`ContentPreview`/具体behavior owner，物理placement、permit与GC属于Storage。
- 不把所有Maccy appearance/sort/sound/alias选项变成settings。
- 不用单个最好benchmark cell、跨机器数字或record-only smoke宣称全面更快。
- 不用大规模重写修复可以由一个小owner/phase解决的race。
