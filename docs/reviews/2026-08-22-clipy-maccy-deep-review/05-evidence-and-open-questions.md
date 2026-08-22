# 证据地图、A/B 方案与开放问题

## 1. 证据使用规则

本轮每个强结论都应能回答五个问题：观察到了什么？为什么支持该claim？证据来自哪里？
最多支持到哪一层？什么实验能区分替代解释？

| 证据类型 | 可以支持 | 不可以自动支持 |
|---|---|---|
| 源码控制流/类型 | 必然调用顺序、缺少分支/边界、可构造interleaving | 实际发生频率、日常毫秒/RSS、OS undocumented behavior |
| Pure/functional test | 指定输入下的语义 | transaction、UI wiring、用户journey |
| Real in-memory SwiftData | transaction、OCC、projection、observation、typed failure | restart/file durability、TCC、actual UI |
| Temp on-disk/same-process reopen | bootstrap、第二个container在该进程看到的状态、特定migration shape | 旧coordinator已释放、进程重启、crash/fsync、真实用户profile |
| Seed/operate/reopen分离的child processes | 旧owner退出后的reconstruction、特定kill point与完整payload reopening | 未覆盖kill point、突然断电、跨OS/filesystem普遍性 |
| Hosted view/app | composition owner、NSHostingView/NSPanel、control wiring | status item/Carbon/Spaces/TCC/signed login |
| XCUI test build | running app的launch/focus/keyboard/general pasteboard journey | Release签名/TCC全矩阵、所有多屏配置 |
| Signed clean-profile run | 该OS/build下的TCC、SMAppService、hotkey/Space行为 | 其它OS/hardware的普遍性 |
| CI job | 精确SHA在该runner/命令的结果 | 另一个SHA、被skip的job、签名发行行为、长期可靠性 |
| Apple symbol/HIG文档 | 公开contract、availability、推荐边界 | 未明确写出的thread/TCC/timing、所有OS build行为 |
| Apple type declaration / UTI conformance | producer声明、候选类型族与对象级读取入口 | payload合法、decoder必然成功、字符编码、资源上限 |
| Apple runtime capability list | 该OS build报告的候选decoder/type集合 | 任意bytes可解码、未来OS仍支持、产品已批准该类型 |
| Apple renderer output option | 最终artifact的页数、像素或尺寸约束 | parser的峰值RSS/CPU、中间完整位图、crash isolation |
| SwiftData projection / batch source shape | 调用方只请求哪些属性、每批最多返回多少model、引用生命周期是否受控 | external blob一定没有fault/I/O/materialization、RSS立即下降、跨OS稳定缓存行为 |
| Store-family物理测量 | 指定OS/filesystem/run时主文件、WAL、外置属性、history、派生cache的logical/allocated size与file count | 另一次checkpoint后的布局、APFS clone/snapshot/backup占用、用户逻辑retention bytes |
| Child-process RSS / I/O trace | 固定build、fixture和操作下的peak/quiescent RSS、fault/read/write曲线及process-crash结果 | SwiftData或decoder的通用硬上限、断电原子性、父test runner的真实app峰值 |
| 单次runtime测量 | 该build/machine/workload的样本 | 跨机器/语料/版本的普遍superiority |
| Maccy实现 | 功能存在、一个可比较设计选择或反例 | 用户需要、Apple contract、值得复制 |

因此：

- “理论上50×64MiB≈3.125 GiB”是结构上界，不写成已测RSS；
- “invalid search先抓1.22GiB worst corpus”是调用顺序和规格上限，不写成每次必达；
- “Carbon一次register成功”不证明callback thread、TCC或Secure Input；
- “App build/test本体成功”不能盖过self-scan warning，也不能称final head green；
- “Maccy扫描得到41个distinct locale identifiers、跨target共123个`.lproj` directories”只证明
  source-tree资源拓扑，不证明任一locale的翻译coverage、准确性或A11y质量；identifier数与目录数
  不能互换。

## 2. 审查基线与可复核来源

### 2.1 Source snapshots

- Clipy：`cda2ba0a4a25264ce7855ee5ae71ef60b8252501`。
- Maccy：`818f03d0e0d3912e1ea23657e2630902ebf5cc8b`。
- Maccy `git log --since 2026-08-20 --all`为空；dirty只有`CONTEXT.md`与30个旧Markdown，
  没有未提交source/config/workflow。因此旧快照后的“新增实现”计数为0。

### 2.2 CI provenance

| SHA / run | 已证明 | 已失败/反证 | 未运行或未知 |
|---|---|---|---|
| `cda2ba0` / [32348271453](https://github.com/GuangDai/Clipy/actions/runs/32348271453) | [source gates 96367240991](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96367240991)与[perf proofs 96367728660](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96367728660)通过；package build本体与app xcodebuild本体完成 | [functional 96367728696](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96367728696) / [perf-helper 96367728793](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96367728793) tests编译失败；[app 96367728741](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96367728741) zero-warning self-scan失败；整体为red | [Exact A/B 96368136670](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96368136670)与[5k 96368137104](https://github.com/GuangDai/Clipy/actions/runs/32348271453/job/96368137104) skipped；signed/runtime state-3不在该run |
| `2ff4d2a` / [32321062928](https://github.com/GuangDai/Clipy/actions/runs/32321062928) | 当时五个常规jobs全绿 | 无针对该SHA的已知常规job失败 | 其后8个commits与当前public/UI changes |
| `cc59aa8` / PROGRESS所引run | 当时旧head的相应结果 | 无法支持“current head green”这个claim | current HEAD；不能继续作为current evidence |

Current app failure的精确warning是
`AppPasteOrchestrationTests.swift:267:55 'adapter' mutated after capture by sendable closure`；
SwiftPM errors在ThumbnailStoreTests 209/224。报告最终交付时没有修改这些production/tests，
所以红状态仍是事实，不应在本review中写成已修。

### 2.3 Apple一手资料

完整逐项来源、访问日期、CODE/INFERENCE/UNKNOWN见
[`apple-platform-source-memo.md`](apple-platform-source-memo.md)。改变建议的关键contract：

- [`NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)
  有default/ask/alwaysAllow/alwaysDeny；General pasteboard后台读取不能假定总获准。
- [`changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)
  反映ownership transitions，不是旧payload log。
- [`pasteboardItems`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboarditems)
  可为multi-item；`nil`可能是retrieval error。
- item-level
  [`data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboarditem/data(fortype:))
  只返回optional；不能照搬pasteboard-level receiver的timeout因果说明。
- [`AsyncThrowingStream`](https://developer.apple.com/documentation/swift/asyncthrowingstream)
  默认buffer上限是`Int.max`；state replacement应显式newest。
- [`Task.cancel`](https://developer.apple.com/documentation/swift/task/cancel())
  是cooperative；不检查就会继续工作。
- [`kCGImageSourceShouldCacheImmediately`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately)
  默认false，object creation不等于pixel decode已完成。
- [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice)
  的status不是Bool；requiresApproval需要用户恢复路径。
- [`NSWindow.CollectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)
  明确区分moveToActiveSpace、canJoinAllSpaces与macOS26 canJoinAllApplications。
- Apple direct distribution要求Developer ID签名、hardened runtime、secure timestamp、
  notarization/stapling；详见平台memo中的官方Security/Distribution链接。

SwiftData的transaction、WAL/external storage、migration interruption、store recovery、backup
与CloudKit证据另见
[`apple-swiftdata-durability-memo.md`](apple-swiftdata-durability-memo.md)。其中最容易误读的
边界是：

- `ModelContext.transaction`正常返回会save，是Apple公开contract；Apple没有把返回点定义为
  `fsync`、突然断电或external blob跨文件crash-atomic边界。
- [`SwiftDataHistory.open`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L138)
  的`ModelConfiguration(schema:url:)`省略`cloudKitDatabase`，其默认值是`.automatic`；当前
  `project.yml`没有iCloud/CloudKit entitlement，所以这**不证明当前artifact上传了clipboard
  数据**。它证明的是conditional fail-open：以后加入可被`.automatic`发现的CloudKit container及所需
  iCloud/Background Modes capabilities时，可以在storage source不变时改变行为；当前`.unique` schema下的
  实际open/sync结果仍UNKNOWN。local-only gate必须同时检查source显式`.none`与最终signed app entitlements。
- `history.store`是configuration URL，不是完整store-family清单；WAL与
  `.externalStorage`使“只复制/移动这个文件”没有恢复证据。

用户新增的“多级存储、驻留、淘汰与近似无限历史”目标，结论与路线见
[`09-tiered-storage-and-unbounded-history.md`](09-tiered-storage-and-unbounded-history.md)，逐项Apple
contract、当前源码控制流、支持上限与 `MEMO-STOR-0…14` 真机矩阵见
[`apple-tiered-storage-source-memo.md`](apple-tiered-storage-source-memo.md)。两份文档必须一起读：
前者给产品/模块裁决，后者刻意区分DOC、CODE、INFERENCE与UNKNOWN。尤其不能把
`.externalStorage`的placement hint、SwiftData batch API或一次低RSS样本压缩成“系统已经自动
提供冷存储和淘汰”。

本轮针对用户新增目标的四份专项证据如下。它们是本节判断的来源索引，不应被压缩成
“Apple支持/不支持”一个布尔值：

- Python、本机自动化、cold launch、caller identity与single-writer落点见
  [`apple-python-automation-source-memo.md`](apple-python-automation-source-memo.md)。关键边界是：
  App Shortcuts可由Python间接驱动，但不是稳定的per-script RPC；UDS是first-party `clipyctl`到app的
  private binary transport候选，不是承诺给Python的第二套direct API，且same-EUID不等于脚本身份；
  XPC需要native bridge，Python标准库不能直接消费
  Apple的opaque XPC channel。
- Apple标准pasteboard type、对象级读取入口、未知/动态UTI与当前Clipy类型政策见
  [`apple-pasteboard-type-system-memo.md`](apple-pasteboard-type-system-memo.md)。type declaration或
  `UTType` conformance只用于routing；捕获、原样回写、search extraction、thumbnail、full preview、
  edit/replace与external I/O必须分别声明。
- ImageIO、RTF/RTFD、HTML、PDF、AVFoundation、Quick Look、file access及preview深模块边界见
  [`apple-preview-source-memo.md`](apple-preview-source-memo.md)。ImageIO runtime list只说明当前
  build的候选输入类型；thumbnail最大像素只限制输出，不建立峰值RSS/CPU或中间位图上限。
- 面向不可信clipboard bytes的安全准入、support tiers与adversarial fixtures见
  [`apple-pasteboard-preview-security-memo.md`](apple-pasteboard-preview-security-memo.md)。Quick Look是
  file-URL adapter而不是通用bytes decoder；iCloud/File Provider/网络卷可能带来外部I/O，必须由
  显式用户动作和真机黑盒证据控制。

当前风险与未来guardrail必须分开：当前product sources没有导入WebKit、QuickLook/
QuickLookThumbnailing或PDFKit，因此HTML外部资源、Quick Look临时文件/iCloud读取与PDF action是
**未来扩类型的准入条件，不是当前已发现的漏洞**。当前可证问题仍是散落/错误的text与image
type policy、RTF/HTML被当作UTF-8、ImageIO框架所有权与actor边界，以及decoder资源证据不足。

## 3. 核心 claim → evidence → support ceiling

| Claim | 直接证据 | 支持上限 | 判别实验 |
|---|---|---|---|
| Existing store缺singleton会静默reset | bootstrap按正确key查询0即insert；不检查items/wrong key | 确认控制流；实际用户store损坏频率未知 | temp on-disk missing/wrong/extra key reopen，验证无补写/无删除 |
| Revise Keep会恢复Canonical | draft `.keep`，save映射`.inheritCanonical`；规范定义Canonical | 确定语义bug | Actual editor: revised A=new，hide B/save，读取A仍new |
| Capture/Paste可无界/乱序 | 每capture Task；paste consumer再spawn Task；tests复制另一套串行pump | 确认可构造调度与无bound；未给实际概率/RSS | queue budget 2 + 3个freeze值判语义；另跑bounded-byte Release stress |
| Search invalid请求admission太晚 | corpus snapshot在worker validation前 | 确认不必要I/O/内存路径；1.22GiB是上限 | probe证明invalid/empty corpus fetch=0；旧实现作Red |
| Search cancel不停止scan | loops无check；Apple cooperative | 确认旧work继续到下个现有check（没有） | park chunk、cancel A/start B、测退出和Authority wait |
| Resident search corpus是当前必要修复 | 当前缺陷是late admission与无cooperative checkpoints；尚无matched SLO证明on-demand corpus失败 | 该claim目前不成立；correct cancellation不依赖常驻corpus | 先在现有架构加入deterministic cancel/admission proof，再以50/200/999项Release typing SLO决定是否常驻 |
| Thumbnail distinct source可聚集 | selected representation在单worker排队前；flight只same key；Authority此前仍whole-lineage hydrate | 确认无硬界；3.125 GiB只是50×64MiB queued selected-source量级，不是含aggregate hydrate/copies/decoder的peak上界 | pause decoder，20/50 distinct，分别记录aggregate hydrated、selected queued、decoder bytes |
| Off-main decode证据不足 | CreateImageAtIndex nil options；Apple default lazy | 确认当前claim过强；不证明实际每图卡顿 | return后first draw heartbeat/Time Profiler |
| 当前`HistoryStorage`已经是RAM→disk→cold archive多级存储 | 有SwiftData持久层、logical-byte retention、短context/projection、完整Signature Index和局部thumbnail budget；没有通用content cache/range reader/lease/GC | 可证明“受5,000项和单项上限约束的持久整体对象模型”；不能证明统一驻留、动态加载或通用淘汰 | 先冻结各lane的hydrated/in-flight/cache bytes；以large/small blob双store和format access trace找出真正materialization点 |
| `.externalStorage`就是可流式访问的冷blob tier | Apple只把它描述为把binary value存于model storage旁边；没有公开locator、threshold、range、eviction或crash/GC layout contract | 只能作为opaque placement option并依赖属性读写语义；不能反向解析sidecar或据此设计streaming | 同row-count的小/大blob stores跑scalar与full-content lane，记录File Activity/page faults/RSS；结论严格限定OS/SDK/query shape |
| Retained logical bytes、store占盘与resident memory可用一个数字治理 | R2累计Canonical+revision payload logical bytes；WAL/external/history/APFS allocation、derived cache与RSS另有owner | R2支持用户可理解的内容retention，不支持物理capacity、删除回收或内存上限 | 同一fixture同时记录payload logical bytes、store-family logical/allocated bytes、volume delta、peak/quiescent RSS与backup artifact size |
| Scalar `propertiesToFetch`没有decode blob就等于没有fault/I/O/RSS成本 | source只证明请求属性集合；Apple未承诺`.externalStorage`在所有build的materialization/cache行为 | 支持“调用方没有显式访问blob”；不能支持“磁盘未读、page未fault、RSS不变” | operation-local Release child对tiny/near-limit blobs跑相同scalar query，测reads/faults/RSS plateau，并保存OS/build |
| “无固定item-count cap”已经等于无限历史 | 当前hard maximum为5,000，search corpus、retention inventory、Signature Index、startup coverage与UI page accumulation仍有O(N)/全量路径；whole-lineage hydration是独立的large-item问题 | 字面无限不可成立；未来最多承诺磁盘主导、操作内存有界、低空间typed暂停且不按固定产品常量静默删除 | 5,001功能边界后，以50k→250k→1M独立child测keyset browse、capture、各search mode、dedup、startup、retention与UI window；large-item details/preview另走G8/P3 track |
| Authority-owned blob tier现在就能改善capture freeze和现有full-`Data` API | `ContentDepot`/reader/GC目前只是conditional P3 direction；当前pasteboard freeze先构造完整`Data`，HistoryCore DTO也返回完整representations。owner-local cache是另一条reuse证据门，不随P3自动出现 | 只支持后续vertical-slice方向；架构图本身不降低当前峰值或改变API复制语义 | 先单独修capture queue/in-flight byte bound；再以一条purpose-specific range/stream tracer替换一条full-`Data` lane并比较peak/correctness；cache另测reuse |
| “代码里声明支持某UTI”即可证明格式支持 | `types`/UTI只表示声明与conformance；对象读取、ImageIO/PDF等实际decoder均可失败 | 只能证明候选routing与产品意图；不能证明bytes合法或语义可用 | 每个exact type做valid/truncated/type-mismatch/oversize真实framework fixture；保存runtime capability snapshot |
| ImageIO runtime readable list与thumbnail像素上限证明资源安全 | runtime list只枚举当前build的source UTI；max-pixel option约束输出extent | 能支持runtime admission与输出尺寸；不支持peak RSS/CPU、中间完整位图或恶意输入安全 | 独立child process记录RSS/CPU/墙钟/输出像素/crash，按格式决定进程内或helper |
| Quick Look可作为任意历史bytes的通用preview decoder | request以file URL为输入；iCloud路径可能下载thumbnail或实际文件；没有通用支持类型枚举 | 支持“显式文件预览adapter”这一方向；不支持hover纯本地、全格式或隔离保证 | local/iCloud placeholder/File Provider/SMB矩阵；只在用户动作后取得lease并监测I/O |
| HTML type声明足以安全rich-preview | Apple HTML importer可访问外部资源并超时；WKWebView会加载embedded resources | 支持plain sibling优先、否则type/byte metadata；source/static需独立charset/grammar；不证明任意sanitizer/WebKit配置完全offline | canary DNS/HTTP/file watcher/website-data黑盒；未全过前不启用rich HTML |
| “同一UID”可鉴别任意Python脚本 | UDS `getpeereid`只给peer UID/GID；同用户多个Python故意相同 | 可作为本机same-user基础检查；不能支持per-script grant/audit | Terminal/IDE/launchd/多个venv caller矩阵；若需细粒度身份则使用enrollment credential或signed bridge |
| Shortcuts/XPC天然就是Python SDK | `shortcuts run`按用户shortcut名称执行shared surface；XPC wire opaque且Python stdlib无typed client | Shortcuts支持用户自动化；XPC支持native signed client | cold/warm/locked Shortcuts CLI contract；只有批准`clipyctl`后才测XPC topology |
| UI acceptance未覆盖view | hosted test跳AppDelegate；无UI-testing target；smoke调用state | 确认proof gap | 新XCUI journey作为Red；actual panel/status item必须出现 |
| WS13证明failed transaction后的所有派生状态不变 | [test](../../../Tests/HistoryStorageTests/WS13TransactionFailureTests.swift#L92)检查item row与position，但未检查`RetainedBytesRow`；“第三个distinct capture成功”不是Signature Index snapshot；publisher使用[newest buffer](../../../Sources/HistoryStorage/HistoryInvalidation.swift#L89)，可把同position publish折叠 | 证明caller收到typed failure且检查到的row/position未变；不足以证明projection、index与零publish三项 | failure后、任何成功写前snapshot全部rows/two singletons/index；用同步计数或non-coalescing probe断言publish count=0 |
| WS14/reopen tests证明真正restart reconstruction | [WS14](../../../Tests/HistoryStorageTests/WS14RestartReconstructionTests.swift#L280)在同一进程重新`open`同URL，旧history仍在scope；[migration fixture](../../../Tests/HistoryStorageTests/HistoryMigrationTests.swift#L99)也保留old-schema container/context | 证明该runtime容忍overlapping coordinators且新facade可见数据；不证明old owner teardown或process restart | seed child退出→verify child；migration用seed child退出→migrate child退出→public reopen child |
| CoreData external-clone error是已证实benign | [CI](../../../.github/workflows/macos26-arm-ci.yml#L182)按错误block过滤；现有JSON主要校验row count/position/transaction与部分公开操作，未证明逐个hydrate/hash所有external-backed canonical/revision payload | 只能说观察到filter后既有标量检查仍通过；不能推广为无payload loss | terminated seed child→fresh validator child逐item走public details/paste/preview所需读取并核对manifest digest |
| R3 sweep与migration资源已有scale proof | [sweep perf](../../../Sources/HistoryPerfRunner/PerfWorkloadsRetention.swift#L94) seeds含零revisions，故没有exceeding lineage decode；[migration backfill](../../../Sources/HistoryStorage/RetainedBytesBackfill.swift#L132)一次fetch全量models，而fixture很小 | 已支持scalar satisfied-path的scale；不支持大量exceeding lineages或大blob migration peak RSS | 独立Release child按items×revision bytes扩展，校验RSS/退出状态/完整结果；与普通search RSS分开归档 |
| SwiftData transaction已证明crash/fsync durability | [normal return/readback与closure-throw tests](../../../Tests/HistoryStorageTests/TransactionBoundaryProofTests.swift#L27)；Apple未给fsync/power-loss contract | 只支持tested runtime的logical save/read-after-write与注入throw路径 | randomized child kill覆盖willSave/didSave/return，并明确仍不等价突然断电 |
| Clipy性能已全面超过Maccy | 无matched A/B | 该claim目前不成立 | 同机Release/signed matched protocol |

## 4. 当前测试/CI盲点清单

### 4.1 “绿色”仍不能证明的层

即便修复当前CI并全绿，常规lane仍不自动证明：

- General pasteboard AccessBehavior prompt/deny/recovery；
- real Carbon delivery、callback thread、shortcut conflict、Secure Input；
- actual status item、panel first responder、nonactivating focus restore；
- full-screen/Stage Manager/多屏hotplug/fast-user-switch；
- Developer ID/SMAppService实际安装状态；
- VoiceOver/Full Keyboard Access/RTL；
- signed Release的absolute latency/RSS；
- SQLite/WAL/external blob的物理安全擦除；
- logical retention bytes与完整store family allocated bytes、volume reserve、backup/snapshot占用之间的
  关系，以及删除/GC后物理空间何时回收；
- scalar projection在目标OS上是否避开external blob reads/faults、operation-local contexts长期RSS是否
  plateau、memory pressure后框架内部cache是否下降；
- 5,001功能边界及50k/250k/1M规模下browse/search/capture/dedup/retention/startup是否仍保持操作内存有界；
- 任意Python caller的cold launch、sandbox reachability、same-user/per-script identity与binary frame上限；
- exact pasteboard type的对象级互操作、未知/动态UTI的无损round-trip和delayed provider时序；
- ImageIO/PDFKit/RTF importer等面对adversarial bytes的peak RSS/CPU/crash isolation；
- file URL hover是否触发iCloud/File Provider/网络卷下载或读取。

它们需要signed/runtime/manual或UI automation evidence，不能继续用pure/hosted suite命名掩盖。

### 4.2 现有false-confidence patterns

1. App paste test手工复制production wiring；应删除并测试actual internal flow。
2. UISmokeJourney直接驱动state却以“UI”命名；保留其state价值，但另建真实UI target。
3. Thumbnail memory smoke每轮手动reset，production不reset；不能证明process-lifetime bound。
4. render speed只测page抵达，不测NSHostingView/frame；应重命名或增加真实SLO。
5. negative cancellation/debounce用150/400/500ms窗口；迟到更久仍可能漏。用generation/manual
   clock/suspension seam。
6. symbol snapshot只锁title set；overload/signature变化可能漏。
7. RSS gate只检查`.time`非空；`unavailable`也可绿。
8. 100→300/400宽ratio只能拒绝明显quadratic，却被写成linear proof。
9. CoreData log filter的白名单block可能吞其它diagnostic；需tested classifier。
10. symbol bot push不触发主CI，ledger可能引用pre-bot SHA。
11. WS13 transaction-failure test在失败后没有立即核对`RetainedBytesRow`与Signature Index；
    后续成功write不是前者的替代证明。若invalidation stream是newest-buffered，失败publish与随后
    相同position的真实publish还可能合并成一个观察值。
12. 多个名为restart/reopen的storage tests没有让旧facade/container/context离开进程；migration
    tests甚至在同一URL migration时保留V1 coordinator。它们是same-process reopen证据，不是
    physical restart证据。
13. CI过滤`Failed to clone external data reference`以后只做row/position等标量与有限公开
    validation；除非新进程逐一hydrate并hash完整canonical/revision payload，否则
    “known-benign”只能是工作假设。
14. retention full-sweep perf fixture明确使用零revisions，证明的是不触发lineage decode的
    scalar path。大量items同时超过R3阈值时源码会把多个decoded lineages保留到plan完成；其
    worst-case RSS必须单独测，不能从时间ratio或零revision fixture外推。
15. V1→V2 backfill一次fetch至多5,001个model并遍历大blob；当前小fixture没有建立migration
    working-set ceiling。是否需要bounded/restart-safe batching取决于独立Release child scale，
    不应由静态上界直接决定。
16. `.externalStorage`、`propertiesToFetch`或`batchSize`被当作自动冷层/自动eviction证据；它们都
    没有给出Clipy可依赖的range locator、fault时机、RSS hard ceiling或GC contract。
17. 只报告`RetainedBytesRow`会把payload logical bytes误当实际占盘；只看`history.store`又漏掉
    WAL、external values、SwiftData History与derived cache。APFS allocated bytes也不能替代backup/
    snapshot或跨filesystem结论。
18. 一个cache的`cachedBytes`达标不能证明全app峰值：capture freezes、full item hydration、decoder
    scratch、in-flight work、SwiftData/Core Data与file cache可以重叠。资源gate必须包含worst-case
    overlap和cancel后的quiescent plateau。
19. app-managed blob tier的diagram被当成已完成优化；它仍是P3 design-only，在实际调用点继续
    freeze/返回完整`Data`时，不会降低当前copy、hydration或backpressure成本。

### 4.3 UI与发行证据阶梯

这些层是累加关系，不是可互换标签：

1. pure/state tests证明view model语义；不能声称用户看见或能操作control；
2. hosted `NSHostingView`/`NSPanel`证明真实view tree与composition wiring；不能声称status item、
   Carbon、Spaces或TCC；
3. XCUI运行app证明指定build下launch/focus/keyboard/general-pasteboard journey；不能替代
   VoiceOver manual matrix或Release签名身份；
4. Developer ID signed、notarized、clean-profile run才支持Gatekeeper、最终entitlements、
   login item、TCC与升级身份的发行claim。

当前`UISmokeJourney`主要直接驱动state；repo没有覆盖产品journey的UI-testing target，也没有
signed state-3 evidence。因此正确路线是逐层补一条vertical tracer，不是把全部pure tests改写成
XCUI，也不是把hosted test改名成“end-to-end”。

### 4.4 Runtime decision artifacts与fixture ownership

“支持类型清单”和“Python可通信”都需要可复核的运行时artifact，不能只依赖注释或一个成功
demo。建议证据产物和fixture边界如下；这些是测试/诊断输入，不应写入History业务状态：

| Artifact / fixture set | 必须记录 | 能关闭的决策 | 不能外推 |
|---|---|---|---|
| `LocalAutomationCapabilitySnapshot` | build/Sandbox/entitlements、transport、cold/warm、caller入口、observed peer identity、grant、request/response bounds、typed failure | 该signed build下Shortcuts/Apple Events/UDS/bridge是否可达及如何失败 | 所有Python脚本具有独立身份；`open`或same-UID等于授权 |
| Python wire fixtures | empty/NUL/invalid UTF-8、JSON、binary上限±1、half-frame、slow reader、disconnect、timeout+retry、concurrent clients | framing、backpressure、idempotency、cleanup与单writer route | secure deletion、任意payload大小、跨版本兼容；需另有version negotiation |
| Format facts + owner manifests + build/test inventory | stable fact ID/exact identifier；各owner的capture/paste/search/thumbnail/preview/edit route、external-I/O、fallback、budget、evidence | owners的声明是否完整、是否出现未解释漂移；inventory不是唯一runtime policy owner | 实际bytes合法、当前机器decoder存在；Local Automation需另生成不依赖PresentationUI的纯值audit projection |
| `PreviewCapabilitySnapshot` | manifest version、OS build、ImageIO/AV runtime type sets、每条rule enabled/disabled原因 | 当前build的runtime admission与bug-report上下文 | 未来OS永久支持集合、decoder对任意输入成功 |
| Pasteboard interoperability fixtures | 多item/重复UTI、unknown/dynamic/private、empty bytes、delayed provider、owner change；再用String/attributed string/URL/color/sound/image对象读回 | raw grouping/round-trip、对象级语义与完全失败分类 | 所有第三方app互操作；仍需Finder/TextEdit/Safari/Preview/IDE等矩阵 |
| Decoder semantic fixtures | exact UTF-8/UTF-16；RTF/RTFD附件；PNG/JPEG/HEIF/GIF/TIFF；PDF普通/locked/actions；type-label mismatch | 每个family的decoder、fallback、静态interaction政策 | parser资源安全；必须配合下面的child resource corpus |
| Decoder resource fixtures | giant dimensions、many-frame/page、deep metadata/object graph、truncated、高压缩率；child记录RSS/CPU/墙钟/输出/crash | 该build/workload是否留进程内或触发最小helper | Apple framework通用硬上限、突然取消native work |
| External-I/O canaries | HTML HTTP(S)/file/website data；file URL local/iCloud placeholder/File Provider/SMB；QL success/fail/cancel cleanup | 未来renderer能否从disabled升为restricted/explicit | 不能据此列为当前漏洞：这些framework尚未进入product source；也不证明QL内部无cache |
| `TieredStorageResourceReport` | build/OS/filesystem/fixture digest；operation与access mode；logical payload、store-family logical/allocated、derived-cache/backup bytes；child peak/quiescent RSS、fault/read/write、in-flight/cache/lease/GC counts | 该固定环境下某一lane是否有界、是否materialize、何时回收，以及下一规模gate能否推进 | SwiftData fault/GC跨OS contract、断电安全、字面“无限”；不得包含title/query/payload/path secrets |
| Blob crash/GC manifest | request ID、checkpoint、committed BlobID references/digests、staging/orphan/referenced/missing counts、reopen invariants | 指定`SIGKILL`点的old-or-new recovery、idempotency和GC不删引用 | power-loss/fsync、secure erase、未覆盖checkpoint |
| Capacity/backup fixture | disposable APFS volume的capacity preflight与真实ENOSPC、opaque store-family清单、backup include/exclude/restore、long-soak时间线 | admission/recovery/space reclamation在该volume和policy下的行为 | 未来卷空间reservation、所有filesystem、历史内容已从旧backup/snapshot消失 |

每个artifact必须来自相应production owner使用的stable facts/manifest/profile与独立pure serializer；
build/test inventory只join验证漂移，不成为production catalog。测试复制一套UTI表、transport routing或
preview selection只会再次制造false confidence。

## 5. 同机 A/B 协议

### 5.1 Claim gate，而不是早期路线阻断

Correctness、permission、packaging、A11y不应等待一个巨大benchmark矩阵。先跑三条matched
journeys，只有准备发布更广superiority claim时才扩展。任何cell必须语义等价；缺功能标
`missing`，不以简化行为替代。

### 5.2 固定条件

- 同一Apple Silicon机器、macOS 26.x build、power/thermal state、显示器配置；
- 两边都用Release；若比较真实startup/login/TCC，则都用signed安装包；
- fresh profile与warm profile分开；store/caches预条件记录；
- synthetic、可公开、distinct内容；不读用户clipboard；
- 同一corpus shape、bytes、image dimensions、query与target result；
- 每次run记录git SHA、toolchain、bundle/version、settings、sample count、random seed；
- warmup与measured samples分开；普通CI artifact只支持短期调试。若发布广泛superiority claim，
  raw samples、validator summary与metadata进入不可变release asset/长期归档并记录SHA-256。

### 5.3 第一阶段三个matched journeys

| Journey | Workload | 指标 |
|---|---|---|
| Cold launch → capture-ready | fresh/warm store 200项，General PB已有1KiB text；permission预状态固定 | ready latency、prompt/失败率、CPU wakeups、peak/settled RSS |
| Summon → find → copy | 200 distinct rows，exact title/body/miss；keyboard only | summon-to-first-row、keystroke-to-stable p50/p95、copy receipt、failure rate、main-thread gap |
| Preview churn | 50 text/image rows，连续A↔B选择/scroll，cold/warm | selection-to-visible、stale result count、decode count、in-flight bytes、peak/settled RSS、frame gaps |

只有这三条已matched并通过correctness assertions，才比较数字。一次最好值不算；报告
p50/p95、样本数与失败率。

### 5.4 完整容量矩阵（发布广泛claim时）

#### Capture

- 1KiB text、5MiB text、32MiB interior sample、64MiB per-representation boundary、128MiB
  total-capture boundary；
- 1/10/100 bursts，slow store与main-thread stall；
- complete/partial/concealed/multi-item；
- 指标：capture latency、observed-loss count、active/pending bytes、RSS、Authority wait、
  committed order、content-free failure category。

#### Search

- N=50/200/999/5000；body=short/32KiB/256KiB；distinct COW bodies；
- exact/fuzzy/regexp，title/body/miss，valid/invalid/empty；
- 300ms continuous typing与cancel backlog，page continuation；
- 指标：query-to-stable p50/p95/p99、corpus bytes、Authority wait、discarded work、peak RSS、
  main-thread gap、timeout/cancel completion。

#### Thumbnail/Preview

- 50 distinct/duplicate 4K/8K，PNG/JPEG/HEIF/BMP；corrupt-first按各产品已批准的
  fail-closed/unpreviewable/fallback语义分类。语义不同则标different/missing，不强比latency；
- rapid scroll/cancel、same-ID revision、remove/clear、cold/warm reopen；
- 64MiB text、large lineage、100 revisions；
- 指标：source hydrations/bytes、decode count/time、first draw、cache hit/reuse、peak/settled RSS、
  stale display、Authority/capture latency。

#### Paste

- single/multi-UTI、revision race、A/B rapid selection、competing writer、write failure；
- 如双方支持再比较plain/auto/multi-file；不支持标missing；
- 指标：selection-to-receipt、correct final clipboard、partial result、close behavior、AX failure。

#### Tiered storage / capacity（Clipy纵向证据，不与Maccy强行配对）

- **独立Release child RSS：** seed、operate、verify分别是退出的process；父runner只收集content-free
  receipt。每个lane记录peak RSS/dirty memory、page faults、file reads/writes、first/steady latency和
  quiescent plateau；不能用父test runner或单个cache counter代替。
- **递进规模：** 5,001先关闭硬边界行为，50k→250k→1M只在前一级通过后运行。分别测keyset browse、
  startup、capture/dedup、retention victim selection、exact search、
  fuzzy/regexp bounded scope、details/preview；通过1M仍只证明该fixture/build，不叫“无限”。
- **三种大小：** 同row count建立tiny、typical、near-admission-limit blobs，区分累计row count与payload
  bytes。scalar lane若曲线相近，只能写成“该OS/query shape未观察到blob materialization”，不能写成
  SwiftData永久contract。
- **物理store family：** 在owner退出后枚举dedicated `StoreRoot`的主文件、WAL、external values、
  SwiftData History与app-managed blob；分别记录logical/allocated/file count/volume delta。DerivedCache
  单列，绝不把`history.store`或R2 logical bytes冒充完整占用。
- **APFS ENOSPC：** 仅在disposable bounded volume/disk image运行；覆盖capacity preflight后被竞争耗尽、
  capture/revise/delete/GC/migration写失败。fresh child必须看到typed old-or-new state；不得在用户卷造
  低空间，也不得假设remove/clear在ENOSPC时一定能成功释放空间。
- **Crash checkpoints：** 若批准app-managed blob slice，在staging create/chunk write/digest/publish、DB
  transaction前/中/返回后、response前，以及dereference/GC unlink前后逐点`SIGKILL`。重启验证referenced
  blob byte-exact、orphan不可见、missing reference fail closed。只有 external/migration operation 已把
  request ID/outcome 与 mutation 同事务持久化时，才断言 retry 不产生第二 commit；普通 capture 只验证
  old-or-new store invariant 与既定 dedup/coalesce 语义。这不证明 power-loss/fsync。
- **GC / backup：** 验证commit前不删referenced；grace只能推迟核对，orphan必须由durable
  ownership/checkpoint与committed-reference reconciliation证明不可达后才可删除。删除后logical state立即不可见但
  allocated capacity回升只作测量；source history与derived cache分开做include/exclude、whole-family restore
  和missing-cache rebuild。不能承诺旧snapshot/backup已安全擦除。
- **Format access modes：** text在codec证据后用bounded prefix/sequential、raster记录header/decoder实际request、
  PDF当前只承诺bounded full `Data`静态页（Apple资料未证明PDFKit first-page random range）、media
  metadata/first frame、archive/unknown metadata-only；paste仍是bounded full `Data`，只有获批sink的export/
  CLI才测试stream。
  Storage只证明range/budget/cancel/version fence；renderer仍要求完整`Data`时要如实记录full
  materialization，不能以chunked transport伪装成有界解码。
- **Long soak：** 固定synthetic rotating corpus持续capture/search/preview/delete/GC、memory-pressure injection、
  reopen与low-space recovery；按批准时长保存周期曲线，验收看RSS/allocated bytes/orphan/index/WAL/history
  是否plateau、延迟是否漂移和failure是否可恢复，不只比较起点终点或最终“没crash”。

### 5.5 统计与报告约束

- 样本不足20不报p95；不足100不报p99，或明确采用的estimator与置信区间；
- RSS parser必须得到正数和单位；无值是failure/unknown，不是0；
- cold/warm、success/failure、different hardware分开；
- latency超过timeout必须计failure，不能从percentile删除；
- ratio claim只覆盖测得scales；NlogN通过宽linear envelope时只写“未见quadratic”；
- 无综合分数。每个workload给winner/tie/unsupported和confidence。

## 6. 产品判别实验

这些实验决定要不要增加复杂能力，不是让静态review替用户做决定。

| 决策 | 最小实验 | 进入实现的阈值类型 |
|---|---|---|
| Capture overload policy | queue budget 2 + 3个freeze值判FIFO/latest/reject；另用有总byte cap的Release stress测RSS | 明确资源budget与用户可接受的数据损失语义 |
| Multi-item group | Finder 2/20 files、mixed text/files，少量目标用户任务观察 | 高频失败且first-item提示不足，才批准schema/migration |
| Auto-paste | signed prototype跑TextEdit/browser/IDE/terminal/Finder/secure field，并询问AX授权接受度 | 兼容/授权达到预先阈值；否则Copy-first |
| Completed thumbnail cache | 60秒真实scroll，测identical reuse、decode p95、settled RSS | 既有G1：decode成本与reuse同时达到；否则visible-state |
| Cooperative search chunks | park/cancel旧query并启动新query | 当前correctness/resource修复：bounded checkpoints让旧work退出，不等待absolute SLO |
| Resident corpus / FTS | 50/200/999连续typing先测 | absolute SLO失败才深化；5k capacity不单独授权常驻state |
| Ignore Next / app/type filters | time-bounded Pause上线后，用opt-in study build让用户主动导出content-free summary，或直接访谈/测试prototype | 真实重复需求；production不自动收集/上传usage，source只作weak observation |
| Panel settings | fixed vs single resize prototype，keyboard/VoiceOver/小屏任务 | 直接manipulation解决时不增加多个knobs |
| 任意Python本机API | public surface固定为first-party `clipyctl`；先做Gateway+App Shortcuts baseline，再比较CLI背后的unsandboxed UDS `open`+ready handshake与sandbox caller矩阵 | 结构化查询/变更和binary需求批准CLI能力，不把UDS升级成公开direct protocol；same-EUID仅作基础检查，不能宣称per-script身份 |
| Python private transport选择 | 在固定CLI contract后，UDS/Apple Events/XPC分别测TCC/caller identity、cold start与payload；XPC需signed native bridge | 不因“原生”新增第二writer；全部private transport只能落到同一ExternalGateway/HistoryAuthority，Python fixture不随替换改变 |
| Pasteboard format architecture | 建立stable facts + owner-manifest tracer，分开capture/paste/search/thumbnail/preview/edit/external-I/O/evidence | 重复stable literals被删除、owner差异显式且unknown仍opaque round-trip，才扩下一family；不建立中央policy owner |
| Image format支持 | manifest exact set ∩ ImageIO runtime set；每种valid/malformed/mismatch/large/multiframe fixture | runtime available、语义fixture通过且child resource envelope内，才标静态preview可用 |
| Rich/PDF preview | RTF/RTFD inert-link与attachment budget；PDF仅做data-only静态页fixture | renderer失败不损坏raw history；交互、外部I/O与资源budget均有独立证据后才升级 |
| File/Quick Look preview | local/iCloud placeholder/File Provider/SMB metadata-only与显式Load Preview矩阵 | hover零下载/正文读取；用户动作后lease/cancel/cleanup可观测，才批准file adapter |
| HTML preview | 默认exact plain sibling，否则type/byte metadata；source/static需先批准charset/grammar；WebKit另跑DNS/HTTP/file/website-data canary | canary全零才可考虑rich adapter；否则保持未来disabled tier |
| Size-aware resident cache | deterministic byte-cost LRU：hit、oversize bypass、all-leased、scan pollution、version fence、warning/critical trim；再跑overlap RSS | 只有owned encoded/decoded/in-flight budgets和真实app plateau都成立才替换局部cache；`NSCache` limit不作hard proof |
| App-managed immutable blob tier（P3） | 先以一个purpose-specific representation做prepare→publish→reference-commit→dereference→GC vertical slice，并跑checkpoint kill matrix | 只有需要range/stream/精确驻留且现有`.externalStorage` full hydration已越过批准budget才进入；不得与capture queue修复捆绑 |
| 无固定item-count cap | 5,001功能边界后以50k→250k→1M逐级child，逐一替换search corpus、full inventory、complete Signature Index、startup O(N)与UI append-all；large-item lineage另测 | 前一级correctness/resource/SLO通过才推进；宣传只能写“无固定count cap，受disk reserve约束” |
| Store physical capacity | dedicated StoreRoot whole-family measurement + disposable APFS ENOSPC + fresh-child reopen + GC/backup restore | typed pause/retry、old-or-new完整性和reserve policy有证据后，才允许解除hard count cap或宣传无固定count cap；它不阻止现有logical age/byte policy设为nil，也不承诺磁盘无限/删除即回收 |
| Format-aware loading | ContentPreview对text/raster/PDF/media/archive/unknown分别声明access plan；Storage只执行bounded range/sequential/full mode | 只有decoder trace表明不需full payload才宣称partial load；paste/export的完整读取继续受in-flight/staging budget |

用户研究使用synthetic content；小样本只发现明显task failure，不外推市场份额。

这里要明确拆开两个search gate：cooperative cancellation和pre-admission是当前correctness /
resource hygiene，无需A/B授权；resident corpus / FTS是新state与新一致性负担，只有前者完成后
现有on-demand方案仍未达到absolute SLO才进入设计。不能用“常驻可能更快”跳过取消语义，也
不能以Maccy当前常驻`history.all`作为产品需求证据。

同样，app-managed immutable blob tier在本review中是**P3 design-only**：它只冻结未来需要
range/stream/精确驻留时的ownership与恢复边界。它不会自动修复当前pasteboard capture先freeze完整
`Data`的峰值，也不会改变`HistoryRepresentation`、details或paste等现有full-`Data` API。前者先用
当前clipboard-flow owner（现有`AppComposition`，或经deletion test批准后提取的concrete
`ClipboardFlow`）的queue/concurrency/in-flight byte gates修，后者必须按purpose做真实vertical
slice；不能因为画出了`ContentDepot`就把任何现有resource claim升级为green。

## 7. Apple/platform仍需回答的开放问题

以下没有足够一手contract，必须测或保持保守表述：

1. macOS 26各AccessBehavior下，`pasteboardItems`、types、item data、detect APIs分别何时prompt、
   返回什么；LSUIElement alert层级如何？
2. Apple未说明`NSPasteboard`/`NSPasteboardItem` thread-safe、main-only或background-safe。普通
   Swift actor不固定OS thread且AppKit references non-Sendable；不能直接“移到actor”。应先
   测MainActor stall，再做窄dedicated thread/executor/helper-process spike。
3. lazy data provider能阻塞多久，AppKit是否有公开timeout/cancel；item-level nil的真实分布？
4. `writeObjects`在competing owner/ObjC exception下留下何种board；是否值得极小ObjC
   exception boundary？
5. Carbon hotkey在macOS26的callback thread、TCC、Secure Input、layout与冲突行为；现代
   symbol-level文档不足。
6. Nonactivating panel如何影响原app first responder、IME、focus restoration；`activate()`
   是request并不保证成功。
7. `.canJoinAllApplications`与move/transient组合在full-screen、Stage Manager、每屏Space、
   Mission Control的实际行为和隐私影响。
8. 手工`NSHostingView`中的`OpenSettingsAction`是否可靠连接Settings scene；hidden
   MenuBarExtra是否真的需要。
9. SwiftData custom migration在transaction中child kill、externalStorage写入中kill后的原子性。
   当前interruption seam明确死在transaction开始前；正常transaction readback与closure-throw
   proof都不回答这个问题。Apple也没有公开`fsync`/power-loss contract，因此只能建立指定
   macOS/SDK/filesystem下的process-kill old-or-new matrix，不能升级成突然断电保证。
10. App Sandbox开启后General pasteboard、SMAppService、现有store migration需要哪些最小
    entitlement/路径处理。
11. ImageIO cache-immediately/bitmap materialization后首次SwiftUI render是否仍做昂贵工作；
    corrupt/metadata bomb的CPU/memory上限。
12. Clear/delete后SQLite free pages、WAL、external sidecars、APFS snapshots/backup中的残留；
    在没有证据前只承诺logical removal。
13. `ModelContainer` construction errors目前统一映射`.openStore`；corruption、future schema、
    permission、ENOSPC与瞬时I/O能否从稳定的underlying error chain可靠分类？在分类proof前，
    recovery UI只能提供Retry、Reveal与user-confirmed recovery，不能看到`.openStore`就自动
    quarantine或创建空库。
14. recovery的file ownership边界是什么？应先批准一个只含SwiftData store family的app-owned
    `StoreRoot`，在没有live coordinator的pre-open/relaunch模式整体move/restore验证。不能把
    `history.store`单文件、调用者提供URL的任意parent，或未来可能混有settings的广目录当作
    可安全quarantine单元。
15. ENOSPC发生在capture/revise、remove/clear与migration各会留下什么typed/physical state？
    remove/clear本身也需要写，不能承诺它们能“释放Clipy空间”完成恢复。用bounded disposable
    volume + fresh child reopen characterization；产品默认停止自动重试、提示释放外部空间后Retry。
16. Apple把SwiftData store changes描述为可查询的chronological History transactions；Clipy
    当前不fetch、消费或主动清理该native History。记录保留多久、何时compact以及旧token如何
    呈现，当前公开资料没有给Clipy可依赖的TTL/expiry contract。先做封闭store的
    size/history-token characterization；在此之前既不声称它无界泄漏，也不把观察到的某个
    TTL写成跨OS保证。
17. R3 policy sweep若大量items同时exceed threshold，会同时保留多少decoded lineage bytes；
    V1→V2 backfill对大canonical/revision blobs的peak RSS与退出行为如何？两者都用独立Release
    child按item count×bytes scale，避免parent/test runner与其它cache污染结果。测得超预算后
    再决定bounded batch/continuation marker，不先引入新状态机。
18. Application Support中的clipboard history应include backup还是best-effort exclude？前者保留
    pins/revisions恢复价值但扩大敏感数据传播；后者仍不能清除旧backup/local snapshot。两者都
    需要closed whole-store-family restore/absence测试与诚实文案。
19. Python的稳定approved surface固定为first-party `clipyctl`；开放问题只是CLI背后的private transport。
    UDS在最终Sandbox配置下是否能由packaged CLI可靠连接、以及Terminal/IDE/launchd Python能否执行CLI，
    Apple文档没有给出完整保证。`open`只解决launch，不能替代ready handshake、grant、audit、frame budget
    或single-writer route，也不授权Python绕过CLI直连socket。
20. Apple Events经`Python -> osascript`时，TCC responsible identity与Clipy实际看到的sender是
    Python、Terminal/IDE、`osascript`还是其它launcher？在真机矩阵完成前不能声称per-script授权。
21. Shortcuts CLI依赖用户collection中的可本地化名称，App Intent也没有给`perform()`暴露Python
    peer identity；它可作为shared user automation，不应承诺稳定低层RPC或逐脚本审计。
22. owner-exported capability summaries如何表达runtime变化？必须同时保存manifest/profile version、OS build、
    ImageIO/AV runtime set与每条rule enabled/disabled reason；build/test inventory只join展示，一次机器快照
    不能升级成未来macOS永久格式清单。
23. unknown/dynamic/private UTI、零字节representation、multi-item grouping与delayed provider的产品
    语义尚未全部批准。默认不能因没有decoder而丢弃raw representation，也不能以对象级best match
    代替无损capture。
24. ImageIO/PDFKit/RTF/RTFD等native parser的恶意输入资源上限没有Apple contract。先用独立child
    fixture建立envelope；超预算或crash才授权最小权限helper，不能预建通用plugin/XPC框架。
25. Quick Look普通request是否由隔离进程执行、第三方extension资源行为，以及metadata query对
    iCloud/File Provider/SMB的副作用均未知；`QLThumbnailGenerationRequest`接收file URL和可取消，
    不等于offline、no-download或通用type enumeration。
26. 如果未来批准WebKit rich HTML，content rules/custom scheme是否覆盖所有网络/文件资源通道？如果
    未来批准interactive `PDFView`，如何阻止URL/remote-go-to/print/form action？这些均是未来准入
    实验；当前代码没有相应framework surface，不能列为current exploit。
27. `.externalStorage`在目标macOS 26 patch/SDK中何时inline或external、scalar projection是否触发
    sidecar read/fault、context销毁后framework/file-cache何时回收？Apple没有公开稳定threshold、locator、
    range或eviction contract；只能由tiny/large twin-store Release child给build-local evidence。
28. SwiftData `fetch(_:batchSize:)`/`enumerate`与operation-local contexts在50k/250k/1M metadata rows上能否
    达到quiescent RSS plateau？batch限制model count而非bytes，必须同时测page faults/I/O，且保留一个
    意外持有model的线性增长negative control。
29. 完整store family在save/checkpoint/history cleanup/delete/GC后包含哪些opaque文件、logical与allocated
    bytes如何变化？只能在所有owner退出后的dedicated `StoreRoot`观察并fresh reopen验证；不得让产品依赖
    当前SQLite/WAL/sidecar命名。
30. app-managed blob future slice的publish与SwiftData reference commit无法由公开API形成一个跨介质
    transaction。staging/publish/DB commit/response/dereference/GC各checkpoint被kill或遇到ENOSPC时，
    orphan、missing reference、idempotent retry与logical-byte/refcount如何reconcile？process-kill old-or-new
    仍不能升级成突然断电保证。
31. canonical/revisions是否进入backup、derived artifacts是否排除、whole-family restore是否保留references与
    blobs一致，属于产品/隐私决定；即使exclude或delete成功，也不能声称旧backup、APFS snapshot或clone
    已清除。需要synthetic backup/restore matrix和诚实用户文案。
32. 各格式是否真的能按range/stream消费，还是ImageIO/PDF/AV/RTF renderer最终仍请求完整payload？
    `ContentAccessPlan`只是请求意图；只有Storage byte trace + decoder结果能批准partial-load claim。archive/
    unknown默认metadata-only，paste/export需要full content时必须走受预算的stream/staging。
33. 长时间capture/search/preview/delete/reopen/GC后，RSS、WAL/history、orphan、索引与derived cache是否
    plateau？短benchmark不能发现周期性maintenance、allocator high-water或慢性泄漏；soak必须保存中间
    time series和failure recovery，而不是只写“运行N小时未crash”。

## 8. 规格/产品开放决策

以下不是平台未知，而是owner必须明确选一项：

- retention readback public vs internal UI seam；
- PresentationUI ImageIO准入 vs Storage/new owner；
- completed thumbnail cache保留/删除；
- capture overload policy；
- age event-triggered vs real wall-clock expiry；
- Authority time与observedAt skew；
- revert target被prune后的snapshot/existence语义；
- unpin是否同commit恢复retention invariants；
- multi-item首发范围；
- Developer ID vs MAS、Sandbox迁移；
- auto-paste是否值得AX授权；
- source app文案与filter的weak semantics；
- dedicated `StoreRoot`、backup policy、可稳定证明的open-error分类与low-disk策略；
- local-only是否升级为source + project + final signed-entitlement三重gate（当前
  `.automatic`默认应显式改为`.none`，但不能倒推当前artifact已经上传）；
- Paste保留现行current-by-ID，还是改为selection-stable exact reference；
- 无法decode的外部image声明保持`corruptStoredValue`、改为unpreviewable，还是尝试后续
  representation。
- Observer start保留现行immediate current capture，还是baseline后只在显式用户动作Import？
- HTML/RTF Replace采用raw-markup editor、rich serializer，还是禁用？
- local automation按既定顺序先闭合Gateway/App Shortcuts，再交付first-party signed `clipyctl`；尚待裁决的是
  CLI背后的private UDS/Apple Events/XPC transport，以及connection enrollment、same-user共享身份、request
  idempotency、cold-launch handshake与Sandbox release gate。没有CLI就不把任何native bridge描述成Python API。
- stable facts、各owner manifest/profile与只读capability summary的能力轴、stable rule ID、证据URL、
  input/output/deadline budget与runtime snapshot schema；禁止退化成`isSupported`布尔值或中央runtime catalog。
- unknown/dynamic/private UTI、零字节representation、multi-item与file promise分别保留/回放到何层；
  preview不支持不能变成history丢弃。
- plain text、RTF、RTFD、image、PDF、URL/file、audio/video、HTML的逐family升级顺序；每一family必须
  明确decoder、fallback、外部I/O、interaction、资源证据与fixtures。
- preview Apple framework归属与`PreviewArtifact`边界；ImageIO/PDFKit/WebKit/Quick Look对象不得跨
  actor/module，UI只消费bounded immutable value。
- helper isolation只在adversarial child-process证据触发，还是有某些family先验强制隔离；两种选择都
  必须写清权限、输入/输出上限、timeout/crash与hostile reply验证。
- “无限历史”的产品文案是否明确为“无固定item-count cap、仍受disk reserve与typed admission failure
  约束”；用户关闭logical retention时是否保留可见absolute safety cap，以及disk pressure下是否只暂停
  capture或允许用户显式opt-in清理最旧unpinned。
- resident encoded、decoded preview、in-flight与single-entry四个budget分别是多少；scan bypass、all-leased、
  memory-pressure warning/critical和oversize请求的等待/拒绝/uncached语义由谁拥有。
- P3 app-managed immutable blob tier的进入gate：哪些已测full-hydration/RSS/range需求足以授权；首条
  vertical slice是哪一种purpose；它与现有SwiftData schema、migration、backup、export和Python binary
  transfer如何版本化。设计批准本身不得被记作性能改进。
- dedicated `StoreRoot`与conditional ContentDepot/DerivedCache的目录、backup include/exclude、disk reserve、
  bounded reconciliation checkpoint、
  orphan/missing-reference恢复和外部卷行为；任何自动删除source history的策略必须显式opt-in。
- 5,001功能边界与50k/250k/1M各级的browse/search/capture/startup/maintenance绝对SLO与资源envelope；未达到下一阶不解除
  现有hard cap，达到1M也不宣传字面无限。
- format access mode必须由具体behavior owner/renderer结合stable facts、manifest、fixture与实测profile
  产生；`ClipboardFormats`不拥有plan，Storage只接受type-neutral sequential/range/full plan。若framework最终要求完整`Data`，产品是拒绝超大preview、隔离
  helper还是允许受限full staging。

每个决策应记录：chosen option、rejected alternative、reason、behavior examples、migration/
public surface影响、TDD card与release gate。没有决策时实现Agent应停在判别实验，不应默认选
最复杂或最像Maccy的方案。

## 9. 可复核交付清单

- [ ] 所有本地相对链接指向当前快照；Maccy引用明确是外部对照仓库。
- [ ] 旧报告已修项没有原样重复成current defect。
- [ ] 每个P0/P1至少有一个最小判别test或runtime matrix。
- [ ] 静态上界与实测数字明确区分。
- [ ] Apple不确定项没有用“通常/应该”伪装成contract。
- [ ] support结论逐轴记录capture/paste/search/thumbnail/preview/edit/external-I/O/evidence，未使用
      单一`isSupported`替代decoder与资源证据。
- [ ] runtime capability snapshot只支持当前OS/build；ImageIO输出像素没有被写成RSS上限。
- [ ] `.externalStorage`只写成opaque placement hint；scalar no-decode没有被升级为no-fault/no-I/O/no-RSS。
- [ ] logical payload bytes、store-family logical/allocated bytes、derived/backup bytes与peak/quiescent RSS分别
      记录，没有合并成一个“storage size”。
- [ ] 多级存储资源claim由独立Release child、closed-owner store-family、disposable APFS ENOSPC、checkpoint
      crash、GC/backup restore、long-soak与5,001→50k→250k→1M阶梯限定；1M没有被称为无限。
- [ ] 各格式access mode区分sequential/range/metadata-only/full；Storage chunking没有被写成decoder一定不
      materialize完整payload。
- [ ] `ContentDepot`/lease/GC仍标为conditional P3 design-only；owner-local cache单独保持reuse/evidence-gated，
      二者都没有被声称已改善当前capture freeze、full-`Data` API或current HEAD resource behavior。
- [ ] Python路线区分Shortcuts shared automation、UDS same-user transport、Apple Events TCC identity
      与需要native bridge的XPC；任何一条都没有绕过ExternalGateway/HistoryAuthority。
- [ ] WebKit、Quick Look与PDF交互风险明确标为未来准入guardrail，没有误报为当前product exploit。
- [ ] 当前HEAD red、last green SHA、skipped jobs写清楚。
- [ ] 任何public/interface变化先有owning spec决定。
- [ ] TDD tests走approved seam，不复制production wiring、不扩大public test hooks。
- [ ] 最终报告不声称已修改或验证product code。
