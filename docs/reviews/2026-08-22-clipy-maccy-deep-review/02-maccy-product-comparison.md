# 当前 Clipy × Maccy 产品与实现对照

> 对照的是两个当前 source snapshots，不是 README feature list。Maccy 自 2026-08-20
> 旧审查后没有 tracked source/workflow commit；其 dirty Markdown 不计产品能力。

## 1. 能力矩阵

| 维度 | Clipy `cda2ba0` | Maccy `818f03d0` | 判断 |
|---|---|---|---|
| History identity / mutation | stable business ID、OCC、closed actions、typed receipts、immutable revisions、pin reorder | resident CoreData models，mutation通常直接作用 UI-owned state | **Clipy 明显领先**；保持深 boundary。 |
| Dedup correctness | xxh3 candidate + byte-exact confirmation；确定winner与stable item identity | Maccy dedup在hash筛选后也做`Data ==`，不是hash-only；但winner顺序/stable coalescing较弱 | Clipy在determinism/identity领先；不要把Maccy dedup误报为hash-only。其thumbnail cache才是fingerprint identity问题。 |
| Concurrency / persistence | single Authority、fresh contexts、transaction commit、deterministic interleaving tests | main context/resident objects较多，顺序和错误传播更松 | **Clipy 领先**，但 bootstrap singleton、candidate residency、app flow仍需修。 |
| Clipboard shape | first item；多 UTI；lineage hint；conceal marker；无 files group | 读取多item后压平成一组contents；file URL有multi-file回写路径，但不保留通用item boundaries/重复UTI round-trip | Maccy表面更宽但不是忠实multi-item model；Clipy不能用first-item silence，也不能复制flatten。 |
| UTI admission / raw fidelity | 除privacy markers外，first item内任意合法type可成为canonical并raw round-trip；因此pure-custom/unknown UTI也能保留 | 不是“固定8类白名单”：batch必须至少含一个enabled标准类型；随后只移除supported-but-disabled types，同行unknown/custom UTI仍保留；pure-custom batch被忽略 | **Clipy的unknown-only round-trip优于Maccy的admission gate**；但优势只覆盖raw保存/回写，不能误称已理解该格式，且first-item模型仍限制整体保真。 |
| Format semantics | title/search、row icon、details/editor、thumbnail与preview分别维护type集合；同一格式的“可保存/可搜索/可编辑/可预览”没有一份代码可读的能力目录 | 小于512 KiB的RTF/HTML可经`NSAttributedString`提取语义文本供title/search；标准类型与过滤规则集中度较高，但解析会进入MainActor | Clipy应保留unknown raw fallback，建立stable facts + owner manifests + build/test inventory；可借Maccy的bounded semantic extraction思想，不能照抄其MainActor解析与未证明的资源行为。 |
| Rich/PDF/Quick Look preview | production只覆盖冻结文本集合与ImageIO图片；RTF/HTML当前按固定String encoding处理，不是rich document render；PDF只出现在preview fixture | 有text/image preview和小RTF/HTML文本抽取；tracked production code未见Quick Look或PDF renderer | **两边都没有production Quick Look/PDF renderer**。新增renderer必须独立、bounded；`PreviewContentLoader`拥有task/reference/late-result suppression，renderer只负责本次decode与cleanup。同步native parser能否及时停止另证，不能把“pasteboard里有PDF bytes”写成“支持PDF预览”。 |
| Paste failure | 已检查 Bool，但 clear后逐type可partial；app吞错且请求可乱序 | 多处忽略write/result，auto-paste权限恢复很弱 | 两者都不达标；Clipy应先做 typed flow，不复制 Maccy。 |
| Search | exact/fuzzy/regexp；query bounds、byte-exact一致性、强engine proofs | 增量维护、每行有bound的corpus；总bytes无hard cap；mixed是exact→regexp→fuzzy首个非空tier | Clipy安全性强；可借query/corpus分离，不宣称Maccy总内存/性能成熟，两边cancellation都有洞。 |
| Authoritative storage / pagination | SwiftData保存authoritative blobs与scalar projections；recent正常lane用page-sized lookahead，continuation可有`limit + 2` overhead；同日期tie的correctness fallback最坏仍materialize 5,000 scalar rows，外层page上限500 | SwiftData落盘，但启动/重建以`fetchAll`读取所有item models，排序后为所有保留项建立main-actor decorators | **Clipy的正常标量分页更接近cold history前提**；但tie fallback、其他O(N)路径仍要修，不能称整个系统已分层。Maccy的全量resident graph不应复制。 |
| Residency / eviction / “unlimited” | process-lifetime `SignatureIndex`覆盖全部保留项；每次非空search取全量scalar corpus；details/paste/thumbnail会hydrate目标的完整Canonical+revision lineage；UI thumbnail以500 entries/64 MiB约束但越界whole reset。count/age/storage/revision retention存在，另有5,000项hard cap；没有统一resident-byte budget、pressure policy或按type cold-load接口 | 所有models/decorators、完整search corpus和dedup maps随保留项驻留；row按访问cache source bytes，scroll-out只放preview；pressure才清非可见transients。thumbnail有`NSCache` 256 entries/64 MiB与256 MiB disk budget，但disk hit不刷新mtime，淘汰更接近write-age FIFO；history按1–999 unpinned count裁剪并保留pins | **双方都不是真正multi-tier history，也都不支持字面“无限历史”**。Maccy只提供一个derived-thumbnail memory/disk cache；Clipy则有较好seam但仍有O(N)驻留/瞬时路径。下一步应以byte budget、pressure与bounded request做Strategic/evidence-gated设计。 |
| Thumbnail identity | `(itemID, contentVersion, pixels)` exact reference，HEIF primary index | fingerprint+size+pixel cache key，无byte confirm；HEIF固定index 0 | **Clipy correctness领先**。Maccy disk cache不能照搬。 |
| Thumbnail lifecycle | UI completed cache未准入、wipe-all、distinct flight无界 | row-local invalidation不调用shared cache `evict`；memory/disk entry等NSCache/global淘汰，source blobs到pressure/invalidate才释放 | Maccy operational更广但删除不精准；Clipy先做bounded visible-state，不急着加disk。 |
| Preview/details | exact-reference fence的一部分、revision details/editor、dwell preview |成熟preview/slideout/用户设置更多 | Maccy交互更成熟；Clipy已有多个coherence/资源bug，尚不能称领先。 |
| Keyboard path | 固定冲突hotkey，初始selection/focus/IME不明确，无visible preview toggle | configurable recorder、open时first unpinned（否则first pinned）、显式focus、marked-text key handling | **Maccy领先**；Clipy应吸收确定journey，不复制默认冲突。 |
| Panel/window |纯placement math，status-item frame取真实screen；fixed size且search本就不改变外窗 |用户resize/persist、search不改变外窗、slideout左右布局 | Maccy更可调；Clipy先修preview placement，resize只在小屏/用户任务证据触发后加入。 |
| Settings | retention功能已接线，但精度/状态/分组错误，只有英语 |约40 keys、成熟panes、41个唯一locale identifiers（分布在123个`.lproj` directories）、shortcut recorder | Maccy资源更广，但这些目录数不证明翻译/A11y质量；Clipy只补高杠杆状态。 |
| Privacy UX |核心无网络/telemetry、conceal在Storage fail closed；无AccessBehavior/pause/filter |ignore apps/types、pause等；来源仍只是frontmost observation | 两者都不能把source当provenance；Clipy需先权限/暂停。 |
| Automation / Python | 当前没有language-neutral IPC，所以任意Python进程**不能**直接查询或修改运行中的Clipy；也不应绕过Authority写SwiftData store | App Intents可get/select/delete/clear；Python虽可间接运行用户配置的Shortcut，但这不是稳定、按operation/version定义的本地RPC | 用户已明确要求Python自动化，应列为Strategic：先完成同一typed Gateway与App Intents baseline，再提供第一方`clipyctl`；Python用stdlib subprocess，不另造policy-bearing client SDK。 |
| Localization/A11y |raw English，无String Catalog，无真实VoiceOver/FKA proof |广泛localization、真实XCUI，但A11y质量不等于已证明 | 首发质量上 **Maccy领先**。 |
| Test evidence |Domain/Storage/transaction proofs很强；app/UI大多hosted state tests |真实XCUIApplication、status item/general pasteboard、UI perf shards；global hotkey由debug notification绕过Carbon | 证据互补；Clipy先补一条纵向XCUI，双方hotkey仍需signed runtime。 |
| Release |无release pipeline，无sign/notary |该fork workflow unsigned，feed仍指upstream，manual clobber风险 | 两者都未闭环；不能以Maccy fork为发布标准。 |

关键Maccy坐标：multi-item读取见
[`PasteboardSource.swift:74–90`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Ingest/PasteboardSource.swift#L74-L90)，flatten见
[`Clipboard.swift:255–276`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Clipboard.swift#L255-L276)；search corpus见
[`SearchActor.swift:31–95`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Search/SearchActor.swift#L31-L95)；cache identity/eviction见
[`ThumbnailCache.swift:100–169`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/ImageProcessing/ThumbnailCache.swift#L100-L169)；
unknown/custom type gate见
[`IngestFilter.swift:237–259`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Ingest/IngestFilter.swift#L237-L259)与
[`IngestFilter.swift:437–463`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Ingest/IngestFilter.swift#L437-L463)；小型RTF/HTML语义抽取见
[`HistoryItemEngine.swift:94–153`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Engine/HistoryItemEngine.swift#L94-L153)与
[`IngestFilter.swift:127–205`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Ingest/IngestFilter.swift#L127-L205)；
Clipy的paged recent browse、全量dedup/search facts与whole-lineage reads分别见
[`HistoryAuthority+RecentReads.swift`](../../../Sources/HistoryStorage/HistoryAuthority+RecentReads.swift)、
[`SignatureIndex.swift`](../../../Sources/HistoryStorage/SignatureIndex.swift)、
[`HistoryAuthority+SearchCorpus.swift:116–131`](../../../Sources/HistoryStorage/HistoryAuthority+SearchCorpus.swift#L116-L131)和
[`HistoryAuthority+DetailAndThumbnail.swift:9–115`](../../../Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift#L9-L115)；
Maccy的全量projection、resident corpus/index、row source cache与derived-thumbnail tiers见
[`HistoryStoreProjector.swift:43–65`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Observables/HistoryStoreProjector.swift#L43-L65)、
[`SearchActor.swift:28–95`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Search/SearchActor.swift#L28-L95)、
[`SignatureIndex.swift`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Ingest/SignatureIndex.swift)、
[`ImageGenerationCoordinator.swift:37–131`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/ImageProcessing/ImageGenerationCoordinator.swift#L37-L131)与
[`ThumbnailCache.swift:58–225`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/ImageProcessing/ThumbnailCache.swift#L58-L225)；
keyboard selection/focus见
[`AppState.swift:106–124`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Observables/AppState.swift#L106-L124)与
[`HistoryListView.swift:95–103`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Views/HistoryListView.swift#L95-L103)；XCUI的hotkey
debug tail见
[`MaccyUITests.swift:493–515`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/MaccyUITests/MaccyUITests.swift#L493-L515)与
[`DebugHooks.swift:66–84`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Application/DebugHooks.swift#L66-L84)。

## 2. Clipy 已经真正超过 Maccy 的部分

这些优势应作为不可回退约束，而不是为了 feature parity 被稀释：

1. **一个 general-purpose public History boundary。** UI、pasteboard、storage vocabulary没有泄出 SwiftData
   models；V2-05/Local Automation只能另有窄capability-scoped facade，不得变成第二个generic History API。
   Maccy 的 UI resident object/service access 不能进入 Clipy。
2. **fingerprint只是候选证据。** Canonical equality最终由 bytes确认；thumbnail也以
   item/version identity绑定。Maccy 的 cache key只有64-bit hash+size，理论碰撞可返回错误
   image，且无 materializer version。
3. **稳定业务 identity 与 coherence tokens。** Revision只在 Effective bytes变化时推进
   ContentVersion；History commit精确推进ChangePosition。Maccy没有同等级外部契约。
4. **纯 planner + typed plan/receipt/failure。** 大部分核心语义可用无I/O deterministic
   tests证明；Maccy许多行为只有UI/CoreData路径。
5. **transaction 与故障注入证明。** Clipy对rollback、并发interleaving和collision的
   证据显著更强。
6. **checked copy count、bounded codecs、HEIF primary index。** 当前Maccy仍有unchecked
   增量、固定HEIF index等边界。
7. **没有网络、telemetry或全局service locator。** 这对敏感clipboard应用是实质产品
   优势，不是“功能缺失”。

当前新发现不会推翻这些决策。需要修的是接口过宽、facts过宽和产品wiring，不是把
Authority换成generic repository或把UI绑定到SwiftData。

## 3. 值得吸收，但需按 Clipy 约束重做

### 3.1 一条确定的 keyboard-first journey

Maccy每次open选择first unpinned（没有才first pinned）、显式focus并集中处理marked text。
Clipy应先定义自己的同等清晰契约：

```text
summon → focus search + select newest → type/filter → arrows → Return copy → close
```

要吸收的是这个用户路径，不是Maccy的透明monitor、默认 `⇧⌘C`/`⌃Space` 或具体
Observable结构。Clipy还需冲突反馈、换绑失败保留旧键、CJK IME与Secure Input证明。

### 3.2 搜索时外窗稳定；resize只作 evidence-gated 选项

Maccy近期把search header展开留在固定外窗内部，并持久化用户拖动高度。这解决“输入时
窗口弹跳”的真实问题；Clipy当前search已经固定外窗，不存在同一缺陷。应立即借鉴的是
preview打开时main-content rect保持不动。只有小屏/用户任务显示fixed size失败，才prototype
一次直接resize/persist，不复制width、rows、delay、body limit等多个settings。

### 3.3 独立 image request owner 与主动释放

Maccy将per-row image load/cancel/publish收进 coordinator，比让row decorator无限膨胀好。
Clipy可借鉴“每个surface有清晰owner、scroll-out释放、memory warning收缩”，但必须保留
exact reference/version identity，并在source hydration前限count/bytes。

注意Maccy删除只清row-local state；tracked implementation没有调用shared
`ThumbnailCache.evict`，所以memory/disk derived entry没有精准delete eviction。这是拒绝其
cache lifecycle的直接证据，不只是理论hash风险。

### 3.4 少量真实 XCUI tracer journeys

Maccy有真实UI target、status item/general pasteboard/keyboard journeys。Clipy不必复制36条
重叠测试；先用一条高信息summon→search→copy tracer贯通生产tail，再按实际跨控件风险扩展。
底层大量正确性仍由现有pure/storage tests承担。Maccy所谓hotkey UI test通过distributed
debug notification触发tail，并未证明真实Carbon registration/delivery；Clipy也不能用同类
bridge关闭signed hotkey gate。

### 3.5 Settings window关闭后释放view tree

Maccy在window close时释放controller和SwiftUI pane tree。Clipy使用公开Settings scene，
实现方式不同，而且`AppComposition.viewState`本来就是process-lifetime shared state，不应
要求它随Settings关闭释放。先用Instruments/weak probe确认Settings**自有**draft/task/blob是否
取消/释放；只有发现这类retention才立项，不为Maccy parity预加第二settings model/controller。

### 3.6 Effective build settings与XcodeGen contract gate

Maccy的release checks会读取`xcodebuild -showBuildSettings`，且验证XcodeGen repeatability。
Clipy应先加当前缺失的Release effective-settings/identity检查；只有生成产物drift再次出现或
现有检查难以维护，才引入精简contract JSON，不为“更完整”先建第二份project truth。

### 3.7 可见 Pause / Ignore Next

Maccy的filters/pause满足真实privacy需求。Clipy先做时间有界、明显可见的Pause；Ignore
Next与app/type filters先做任务实验，比一开始建立rule engine更稳。应用过滤若加入，只能称
“按观察时前台app”，不能称可信来源。

### 3.8 Stable format facts、owner manifests 与unknown fallback

Clipy当前的raw fidelity和semantic support是两件不同的事。前者已经很强：只要标识符与bytes
合法，未知UTI也可进入Canonical Content并回写。后者却散落在storage projection、row icon、
details、revision editor、thumbnail与preview的多个集合里；例如text集合分别出现在
[`ContentProjector.swift:246–280`](../../../Sources/HistoryStorage/ContentProjector.swift#L246-L280)、
[`HistoryDetailsView.swift:658–680`](../../../Sources/PresentationUI/HistoryDetailsView.swift#L658-L680)和
[`HistoryPreviewView.swift:77–101`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L77-L101)，image
能力又在Authority与UI重复。漂移已经可见：storage/thumbnail/preview把`public.heif`和
`com.microsoft.bmp`视为image，row icon的image列表却没有这两项（
[`HistoryRowView.swift:191–211`](../../../Sources/PresentationUI/HistoryRowView.swift#L191-L211)）。这里的
风险不是少写了一个数组元素，而是agent无法从一个地方回答“这个type能否捕获、搜索、预览、
编辑、export、原样paste”。

应吸收Maccy把标准类型规则显式列出的优点，但不能把所有purpose策略塞进中央表。Foundation-only
`ClipboardFormats`只保存exact identifier、family/wire与special-role稳定事实；Search、Thumbnail、
Preview、Edit、Pasteboard各自拥有manifest。build/test inventory只读join它们，显示漂移与disabled
reason，删除后不改变production行为。Unknown type走有条件的raw-only fallback，而不是伪造generic
preview。是否新增target先经spec/graph准入，不能为整理常量先增加空抽象层。

Maccy对小型RTF/HTML做semantic extraction值得借鉴：先按bytes拒绝大输入，再提取可搜索plain
text。但Clipy不能把RTF/HTML当UTF-8，也不能直接复制`NSAttributedString` MainActor路径。进入
在stable facts + owner manifests迁移前，每个rich renderer/parser都要证明：不访问外部resource或network、输入/输出
有硬上限、能取消/超时、失败不会影响raw round-trip，且异常文档不会阻塞UI。

### 3.9 独立 Preview 模块与language-neutral automation gateway

Preview应成为“选择renderer并产生bounded显示结果”的独立模块，而不是继续扩张
`HistoryPreviewView`。输入只包含immutable representation values、intent与明确budget；exact
item/version reference仍由`PreviewContentLoader`捕获并在发布前核对，不进入renderer。输出区分
`unsupported`、`rendered`和typed failure。Text、ImageIO、未来Rich Text、PDF或Quick Look renderer通过
同一内部接口接入，各自只拥有本次decode执行域、cooperative cancellation check/cleanup与资源上限；
`PreviewContentLoader`独占request task/token、exact-reference与late-result suppression。native同步work是否
停止由各framework证据限定。UI只负责loader lifecycle/selection fence和展示。这样增加一种格式不会同时
修改Storage、row、details、editor和panel。
Quick Look/PDF目前两边都没有production proof，应该先做malformed/oversized/cancelled fixture，
再决定具体renderer，不能因系统“可能能打开”就列为支持。

任意本机Python进程未来可以与Clipy通信，但前提是增加一个**显式启用、language-neutral、
versioned的本地gateway**；当前代码没有这个入口。先amend并实现V2-05唯一Gateway，按既有路线让
App Intents成为第一个adapter；随后冻结public `clipyctl` JSON/exit-code contract，再以signed+sandbox
prototype选择private transport，不能把XPC、UDS或Apple Events写成第二个SDK。首版operation只包含
`browsePreview`，随后才按grant依次加入`readEffectiveContent`、`organize`、`deleteItem`；content
`reviseContent`最后独立准入，不开放generic details/copy/action。请求携带opaque cursor/OCC token、
typed receipt/failure与payload bounds；写操作仍进入同一Authority，Python绝不直开store。普通Python
只用stdlib `subprocess`调用第一方CLI，不需要另一个policy-bearing Python SDK；同一用户、opt-in、
credential、content-free audit、断线/版本边界仍须逐项证明。

### 3.10 多级存储不是“有SwiftData + 有cache”

当前Clipy的Storage模块**结构上保持唯一持久化authority，正常路径已有测试，但corruption/crash/
recovery与aggregate residency未闭合，也还不能按用户设想承担完整的内存驻留调度**。它已具备
cold-history的重要基础：recent正常路径读取分页scalar projection，
Canonical/revision blobs不会因为滚动列表而被主动decode；authoritative content另有count、age、
storage-byte和revision retention。可是下面四件事仍然把它与真正multi-tier设计隔开：

1. `SignatureIndex`把每个保留item的signature/postings常驻进程；这比常驻content bytes轻，但仍是
   随history count线性增长的索引，没有resident-byte ceiling或降级查询路径。
2. 非空search不是逐页查store：每次请求都会抓取所有保留项的title/search body等scalar fields，
   构造、排序并扫描完整`SearchCorpusSnapshot`。它是operation-bounded的全量瞬时驻留，不是分页
   UI已有的分页特性可以掩盖的成本。
3. details、paste与thumbnail都通过`HistoryItemRowHydration`解码目标item的完整Canonical和完整
   revision-state blob；thumbnail最终只选一个image representation，也先materialize了整个lineage。
   现有schema把多representation聚合进blob，所以没有“只按所需UTI从冷层读一段bytes”的能力。
4. `ThumbnailStore`有entry/decoded-byte上限，这是有价值的保护，但越界采用whole-store reset，
   没有recency/frequency、visible protection、memory-pressure缩容或跨surface统一预算。它是有界
   display state，不是成熟cache tier。

因此，`@Attribute(.externalStorage)`最多说明SwiftData可以选择外置某个`Data`属性；它没有保证某一
representation独立成文件、何时fault、何时进RAM或何时被淘汰。不能把框架实现提示写成Clipy的
residency contract。V2的storage-byte retention同样只决定哪些authoritative bytes继续被保留，
不限制Signature Index、search snapshots、decoded pixels、SwiftData registered objects或SQLite
overhead；**retention（保留/删除）与eviction（可重建内存/缓存释放）必须是两份政策。**

Maccy也不是答案。它在启动时`fetchAll`、为所有保留项持有SwiftData model和decorator，又在
`SearchActor`与ingest `SignatureIndex`保存按item增长的副本/索引。row第一次判断或显示image后会
cache source `Data`；scroll-out只清preview，非可见row的source/thumbnail通常等到memory pressure
或invalidate才释放。它值得借鉴的是两个**概念**：用decoded-byte cost约束`NSCache`，以及收到
system pressure时主动收缩非可见transients；不值得复制的是resident object graph、hash-only
thumbnail identity和以未touch的mtime冒充LRU的disk FIFO近似。

面向“几乎无限历史”，正确目标不是取消所有上限。物理存储、索引和查询时间不可能无限；可验证的
产品语义应是：**authoritative cold history受用户count/age/logical-content-byte/revision policies约束，
physical disk reserve/ENOSPC另管设备健康；history count增长时hot
resident set仍受固定byte budget约束，所有content/preview都经bounded、task-owned、exact-reference
request临时升温，pressure或budget越界后可无语义差异地重新加载。** 文件类型只声明选择规则、
decoder与input/output cost；调度器按request purpose、bytes、visibility和reuse evidence做决定，
不能为每种UTI手写一套永久resident policy。

这意味着近期只先冻结measurement与接口方向，不先造一个通用cache framework：分别量出
startup/index、search snapshot、one-item lineage hydration、source bytes、decoded pixels和derived
entries的peak/steady bytes；为每层定义独立budget、pressure response、eviction后的semantic
equivalence与可观测性；只有hit-rate/latency证据支持时才选择byte-weighted LRU/2Q之类算法。
如果未来移除5,000项hard cap，还必须先证明dedup/search/retention不会重新引入O(N)resident graph或
全量blob decode。完整目标接口、分期和TDD gates见
[`09-tiered-storage-and-unbounded-history.md`](09-tiered-storage-and-unbounded-history.md)。

## 4. 明确不应复制的 Maccy 模式

### 4.1 `.shared` / `.current` 与 UI-resident automation

Maccy `HistoryCommandServices.current` 是mutable global service locator；Intent读取UI
resident `history.all`，cold start无loaded fence，persistence failure又常被mutation层吞掉，
Intent仍宣告成功。Clipy未来若做automation，应让typed external operation先经过唯一`ExternalGateway`，
再由`HistoryAuthority`提交并返回receipt/failure；cold start显式ensure-loaded，copy与synthetic paste分开授权。App Intents是
Apple automation surface，不是Python可稳定调用的language-neutral RPC；即使未来同时提供，也应
与Python gateway共用application service，避免两套mutation语义。

### 4.2 Fingerprint-only memory/disk cache

Maccy用xxh3+size+pixels直接作为cache identity，未byte-confirm；disk hit不touch mtime，
所谓LRU接近write-age FIFO；remove只invalidate memory，disk可留到全局eviction。Clipy
不能为了warm reopen牺牲正确性与privacy lifecycle。

### 4.3 Row view model在 memory pressure / invalidate 前按访问历史保留full source bytes

Maccy `hasImage`会加载并cache完整blob；scroll-out只清preview，不清source Data/thumbnail，
滚遍history后会按访问历史累积，直到memory pressure或显式invalidate。Clipy应通过标量
projection判断类型，source bytes只活在bounded request，completed state按visible/byte
budget释放。

### 4.4 不可取消search与简单regexp heuristic

Maccy的outer task cancel同样不能中断SearchActor内compactMap/sort；regexp只识别少数危险
形状。Clipy不能用“竞品也这样”降低自己的cooperative cancellation与bounded deadline。

### 4.5 Frontmost app作为可信provenance

Maccy读取时看`NSWorkspace.frontmostApplication`。后台helper写clipboard时会归因给另一个
前台app。Clipy可保留best-effort source observation，用于display/便利filter；绝不能用它
做安全授权、审计或“来自某应用”的强文案。

### 4.6 无恢复的 synthetic paste

Maccy accessibility未授权分支为空，随后仍发CGEvent；没有target snapshot、success
receipt或secure-input contract。Clipy先修可靠Copy；Copy as Plain Text先验证任务需求，
auto-paste只能是opt-in，需signed prototype、typed TCC state、目标兼容性和失败UX。

### 4.7 私有AppKit与隐藏lifecycle workaround

Maccy仍匹配`_NSAlertPanel`/private class names，并使用hidden MenuBarExtra形式。Clipy已去掉
私有selector/class依赖，应坚持公开API；hidden scene是否必要须有runtime proof，不能因
两边都这么做就把undocumented behavior当contract。

### 4.8 App Intent临时文件与格式错配

Maccy Get把TIFF/JPEG/HEIC原bytes写成`.png`，没有应用级temp cleanup；RTF按UTF-8直解。
Clipy不应在没有typed format、lifecycle cleanup、authentication policy、grant/audit前做
同类export。

### 4.9 Settings数量与一次性大量翻译

约40个defaults不是product score。Apple HIG建议减少设置；task-local option应靠近任务。
Clipy只增加能解除主路径失败的设置：shortcut、history permission/health、retention、
launch at login；panel size只在任务证据触发后加入。Localization目标是可本地化、pseudo/
RTL/QA，而不是为了数字一次性交付大量未经验证locale。

### 4.10 当前Maccy release workflow

该fork显式`CODE_SIGNING_ALLOWED=NO`，无notary/staple；Info.plist feed仍指upstream，手动
workflow可对任意ref/tag `--clobber`而无SHA/tag/version绑定。Clipy只能借effective-settings
gate，不能借release transaction。

## 5. 功能优先级：Parity不是排序依据

| 优先级 | 近期产品能力 | 为什么现在做 |
|---|---|---|
| **Must** | Pasteboard permission/health、custom shortcut、确定keyboard flow、time-bounded Pause、真实paste/capture flow、multi-item明确策略、**format facts/manifests的规格准入 + unknown raw fallback contract**、signed release/A11y/localization | 直接决定主路径能否成功、用户是否信任、agent能否从代码准确判断已有格式能力、产品能否安装。这里的Must先是规格与现有text/image/unknown契约，不是未批准target或把每种格式都实现。 |
| **Should** | visible preview toggle、**独立Preview module baseline** | 已有隐藏快捷键但缺可见/可访问入口；现有text/image preview先迁入一个bounded、task-owned、typed-result接口。取消默认只停止发布；不可抢占native work在真实返回前继续计费并随后cleanup，避免每加一种格式都扩散修改。 |
| **Strategic / after gateway baseline** | **local Python automation**；V2已接纳的App Intents先作为Gateway adapter | 用户明确需要跨语言修改能力；先完成唯一Gateway与App Intents baseline，再冻结`clipyctl`并做browse/read-only tracer；organize/delete逐项开放，content revise最后。Python是V2-05 amendment，不另造service。 |
| **Strategic / evidence-gated** | **tiered residency/storage control plane、disk-bounded cold history、解除5,000项hard cap的可行性** | 用户明确要求长期/近乎无限history；先用resident-byte与pressure measurements证明瓶颈，建立scalar page、representation request、decode/derived-cache各层预算和eviction-equivalence gates。只有全量Signature Index/search/lineage路径被替代后，才讨论提高或移除count cap。 |
| **Evidence-gated** | 每一种新增semantic/preview格式（RTF、HTML、PDF、Quick Look等）、Ignore Next、panel resize、friendly source、Copy Plain、grouped multi-file、opt-in auto-paste、app filters、completed/disk cache、smart mixed search | stable facts/owner manifests与Preview seam应先存在；具体parser/renderer仍须按用户任务、安全边界、资源proof逐个准入，避免“支持更多类型”变成无界Must清单。 |
| **Later / non-goal** | updater、OCR、cloud/sync、plugins、sounds、复杂sort/settings | 首发不决定核心成功率，且会扩大surface/权限/维护。 |

“全面超过 Maccy”的可验证含义应收敛为：在启动捕获、summon→find→copy、敏感内容
控制、错误恢复、长期内存与可信安装六条journey上，Clipy有更高成功率和更清楚的失败
状态；而不是表格里每个Maccy开关都打勾。
