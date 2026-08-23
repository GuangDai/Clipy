# TDD 修复执行手册

> 面向后续修改 Agent。本文描述测试流程和可观察行为，不给出具体 production code。
> 原则来自仓库 `tdd` skill：**一个 seam、一个失败行为、一个最低实现**。Green 后的
> review/refactor 是独立阶段，不与 Red→Green 混成一次大改。

## 1. 先确认测试 seam

TDD skill 要求测试只落在预先同意的 seam。下表是本轮建议；新增的三项必须先写入 owning
spec/ADR并由维护者批准，不能由实现 Agent 悄悄变成 public API。

| Seam | 状态 | 通过什么观察行为 | 允许的安排手段 |
|---|---|---|---|
| `ClipboardHistory` v1 seam | **既有v1 methods已批准；`retentionConfiguration()`隔离等待GOV-2裁决** | action receipt/failure、browse/details/paste/thumbnail/observation DTO | 真实 `SwiftDataHistory`，in-memory或temp on-disk；现有clock/ID/transaction/suspension seam；readback未准入前不扩用 |
| HistoryDomain pure planners | **既有已批准 package seam** | literal facts → plan/outcome/rejection | 固定IDs/times/facts；不mock planner内部helper |
| `PasteboardAdapter` | **既有已批准 product seam** | named pasteboard snapshot/write result | private named pasteboard；AppKit返回值/时序只用internal boundary seam |
| `AppComposition`（现有）或经批准抽出的 concrete `ClipboardFlow` | **现有app owner可先测；抽取新seam需批准** | capture capability/change → History receipt/health；selected reference → write receipt/close decision | 真实History、named private pasteboard、窄system boundary；capture/copy分别测试，不公开queue或failure knobs |
| Purpose-specific preview read | **G8/SLO触发后才建议新增，且需规格批准** | reference + presentation bound → bounded tagged payload/failure | 先测现有路径；触发后才用真实History验证新seam |
| Presentation phase/model | **既有UI owner内部seam** | intent + authoritative snapshot → render/action state | scripted `ClipboardHistory`只用于UI；manual generation/clock |
| Actual SwiftUI/AppKit view | **roadmap已要求，当前缺证据** | accessibility tree、focus、frame、control action | `NSHostingView`/`NSPanel` hosted test；不测private helper |
| Running test app | **state-3 UI seam** | `XCUIApplication`、general pasteboard、status item、真实controls | DEBUG launch environment、temp store、internal summon bridge；只证明test build |
| Running signed release app | **state-3 platform seam** | TCC、real hotkey/status action、Space/login/notary/Gatekeeper | clean profile与synthetic content；**不依赖DEBUG bridge** |
| Perf runner / signed journey | **既有/待批准SLO seam** | latency/RSS/queue/CPU/energy artifact | fixed corpus/build/hardware、validated parsers；不mock production work |

在每张实施卡开始前，PR/issue必须写：`Seam: ...`。如果需要为测试新增public member，默认
说明seam选错；先回到app/package internal边界。

### 1.1 尚不存在的 seam：先做 interface-shell gate

抽出的concrete `ClipboardFlow`、capture health/panel reducer与purpose-specific preview read当前
尚不存在。若现有`AppComposition`不足以表达目标行为，直接引用这些名字会让test编译失败；这不是
合格Red。流程是：

1. owning spec先批准职责、access level、输入/输出与failure vocabulary；
2. 在同一个最小cycle中先加**可编译、无成功行为**的internal/package declaration与neutral
   stub（例如明确返回unsupported/unavailable），不含调度、storage或UI实现；
3. 写通过该seam的behavior test。它应编译，并因stub的中性失败结果而Red；
4. 审查没有扩大public surface、没有偷偷决定额外行为，再进入最低Green。

Interface shell不是behavior Green；internal shell不强制独立PR/commit，关键是Red必须先能编译
且因behavior失败。public/protocol change仍需独立surface/spec批准。若现有public seam已足够，
直接测试现有seam，不为测试另造wrapper。

## 2. 每一个 TDD cycle 的固定流程

### 2.1 写 Behavior Card

先写五行，不写实现计划：

```text
Given: 独立、可读、最小的起始状态
When: 调用哪个已批准 seam 执行一个行为
Then: caller/user能观察到的一个主要结果
Invariant: 失败时绝不能改变什么
Evidence ceiling: 这个层级最多证明什么
```

Then的expected value来自规格或手算literal，不能用production helper重新计算；否则是
tautological test。一个test只表达一个逻辑结果，相关rollback可作为同一behavior的不变式。

### 2.2 Red

1. 只增加最小测试/fixture。
2. 先运行最窄filter，确认**测试能编译且因预期行为失败**；编译错误不是合格Red。
3. 记录失败信息；若它因错误前置条件、timeout或mock setup失败，修测试直到真正Red。
4. 临时破坏/恢复生产实现的mutation test只在需要证明test sensitivity时做，不提交破坏。

### 2.3 Green

1. 只改让当前Red通过的最低production surface。
2. 不预实现下一张卡、不顺便抽generic abstraction、不扩大public API。
3. 先跑单test，再跑同文件/same seam suite，再跑owner target。
4. 若Green只能靠sleep、放宽阈值、重写expected或加warning exclusion，视为仍未Green。

### 2.4 Review / Refactor gate（独立于 Red→Green）

Green且owner suite通过后才审查：重复是否真的跨两处、module depth是否改善、注释/spec是否
需要同步、seam是否可删除/变窄。Refactor不得改变behavior；先跑相同tests再跑全量。

### 2.5 Evidence closure

按风险升级测试层：pure → real storage → adapter/hosted app → actual view/XCUI → signed
platform → Release perf。只有跨层行为才升级，不为每个planner edge写XCUI。

最终PR记录：受保护PR/ref、targeted commands、full workflow run、测试层的支持上限。`PROGRESS`
只能引用该PR/ref的最终run，不引用中间green或另一个head。

## 3. Test doubles 的边界

可以替换的只有系统边界：时间、ID/random、文件路径、AppKit pasteboard result、Carbon
registrar、SMAppService、WindowServer notification、decoder scheduling。优先使用真实
SwiftData与private pasteboard。

不要mock：

- planner、Authority、SearchWorker、ThumbnailService等自有内部collaborators；
- `AppComposition`的步骤并在test中重写一份“等价pump”；
- UI action发给哪个private method/call count；
- 数据库row作为普通业务behavior的唯一验证结果。

只有codec/schema/invariant/rollback proof可直接检查row；普通create/revise/remove应通过
`ClipboardHistory`再次读取。系统boundary double只返回一个明确shape，不在mock中重写
production条件树。

## 4. 证据阶梯与回归顺序

| 层 | 适合证明 | 不能证明 | 典型回归顺序 |
|---|---|---|---|
| Pure Domain | winner、plan、invariant、边界算术、phase reducer | transaction、actor、OS/UI | 单test → planner suite → HistoryDomainTests |
| Real in-memory SwiftData | transaction、OCC、projection、observation、typed failure | restart/file durability、TCC/UI | 单test → storage owner suite → functional lane |
| Temp on-disk + reopen/child | bootstrap、migration、crash/restart、external blobs |真实用户profile/TCC/WindowServer | 单test → restart/migration suites → functional lane |
| Private pasteboard | representations、partial/write result、lineage round trip | General pasteboard privacy/prompt、跨进程竞争全貌 | adapter suite → actual app flow hosted suite |
| Hosted app/view | 真实composition owner、NSHostingView/NSPanel、control wiring | status item/Carbon/Spaces/TCC/signed login | app owner suite → xcodebuild app tests |
| XCUI running app | launch、status item、focus、keyboard、general pasteboard journey | 所有TCC/多屏组合、性能统计稳定性 | UI tracer shard → blocking app lane |
| Signed clean-profile matrix | AccessBehavior、SMAppService、Space/Stage Manager、AX trust |其它OS/hardware的普遍性 | versioned manual/automated artifact |
| Release perf | absolute latency、RSS、CPU/energy、A/B | 正确性本身、未测workload | correctness suites → fixed runner → artifact validator |

一般回归命令顺序（在macOS 26 arm64）：

1. `swift test --filter '<OwnerTests>.<test>'`
2. `swift test --filter '<OwnerTests>.'`
3. `swift test --skip 'HistoryPerfTests\.'`（当前CI functional lane；普通裸`swift test`
   不会自动排除perf target）
4. `swift test --filter 'HistoryPerfTests\.'`（若影响helper/perf）
5. App lane使用完整命令：

   ```sh
   xcodegen generate --spec ClipyApp/project.yml
   xcodebuild -project ClipyApp/ClipyApp.xcodeproj -scheme ClipyApp \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     CODE_SIGNING_ALLOWED=NO clean build test
   ```
6. `bash scripts/run_gates.sh` 与 `swiftlint lint --strict --no-cache`。Zero-warning self-scan
   当前内嵌workflow YAML，没有等价单独命令；最终以CI job为准，或先把scan抽成有测试的
   共享脚本，不能用一句“本地scan通过”替代。
7. 受保护PR/ref最终checkout的完整GitHub workflow

命令的具体filter以实际Swift Testing发现名为准；不要为了文档中的示例名称改生产命名。
需要real-scale fixtures的owner/app suite在运行前还必须执行
`bash scripts/fetch_fixtures.sh <temporary-root>` 并把
`CLIPY_FIXTURES_DIR=<temporary-root>/clipy-fixtures-v1`传入测试；否则fixture-dependent test
可能按设计skip，不能计作已验证。

执行卡编号是目录，不是优先级。领取顺序与00的正常路径优先级一致：卡0 baseline → 卡3/7/8/9
正常可达correctness → FORMAT/PREVIEW逐格式校正 → 卡5/6 signed privacy/capture →
卡11/4/12/13与§26 characterization/current-layout `PLAY-STOR/PLAY-MEM` bounds → 卡1/2
corruption/durability hardening → dedicated StoreRoot、`PLAY-DISK-0A/0B/1/2A/3/4/6`与
`PLAY-COUNT-1…8` test-only U-scale → Card15/16所需signed substrate → `PLAY-DISK-5`及
COUNT 8C/9C/9A/9B production transition → 仅G8触发后的P3 cards → 其余State 3 → PY
Gateway/App Intents/CLI与最终superiority evidence。未触发的
decision experiment、50k/250k/1M规模proof和新cache/tier机制不插队；COUNT/P3不得因统称“第26节resource”
抢在其依赖的corruption/durability baseline之前。

## 5. 执行卡 0：先恢复 CI baseline

### Red/起始证据

当前不需要新增行为测试：run 32348271453是**阻断基线**，不是合格的TDD Red。两个
SwiftPM tests不能编译，app有sendable-capture warning；在测试恢复到可编译前，不开始
production Red→Green cycle。

### 最低 Green

- 将awaited poll结果先绑定到local `Bool`，再传给同步`#expect`；或统一修正async predicate
  harness。只改test，不碰ThumbnailStore production语义。
- App warning不能加入exclusion。本slice只让captured state immutable、消除warning；删除
  手工pump并在现有`AppComposition`或经批准抽出的concrete `ClipboardFlow`上收敛明确留给卡7，
  不能混入baseline repair。

### 回归

PresentationUITests单filter → full functional → perf-helper → app build/test/self-scan → 同一
最终checkout的五个常规jobs。之后按第4节先领正常可达correctness；不能因为编号顺序直接跳到卡1。

### 支持上限

它只恢复可工作的测试基线，不证明下面任何product bug已修。

## 6. 执行卡 1：Store singleton integrity

**Seam：** 真实`SwiftDataHistory.open` + public read/action。确定性on-disk restart由短命
child helper完成seed、corrupt、open三个阶段；当前没有close API，不能把“ARC应已释放facade”
当作coordinator teardown证据。

### Red 1A-1：existing store missing/wrong-key

Given：child A创建temp on-disk store、3 items、非默认count与V2 policy后正常退出；child B用
schema-level setup删除position/config或改错key后退出；另测extra wrong-key row。

When：child C重新open。

Then：typed persistence invariant failure；旧items、blobs、RetainedBytes与原文件仍在；不得
补写默认singleton。因为public facade open已失败，失败后的row/blob不变只能由独立inspector
作**schema/invariant side evidence**，不能冒充public read behavior。

### Red 1A-2：existing position row、invalid scalar value

Given：child A创建非空store并正常退出；child B保留唯一、正确的position key与raw position，但把
该row的`maximumUnpinnedItems`改成`HistoryLimits.userMaximumUnpinnedRange`之外的最小literal，
然后退出。低于下界与高于上界分别是一张cycle。

When：child C重新open。

Then：open在发布facade前返回现有spec规定的typed corrupt-value failure，且不得把value改成默认
retention。Expected range来自literal `HistoryLimits` fixture，不调用production repair/helper。
最低Green只在startup existing-row分支复用既有scalar decode/validation，不借机新增repair。

### Control 1B：合法fresh/migration

Fresh store与真实V1 fixture本应绿色：各创建/保留正确singleton，作为防止“全面拒绝缺行”的
anti-overcorrection control，不把它叫Red。

### 最低 Green

只增加无写startup classifier与完整key/cardinality/value validation；只有被证明fresh/
migrating的shape可以create。是否把不同bootstrap写入合成一个transaction是另一个
partial-initialization行为，不由本Red自动授权；V1→V2时position存在而config合法缺失，也不能
套“两个都创建”。

### Review/Refactor

合并position/config重复classifier逻辑，但不造泛型bootstrap framework。若V2缺config与损坏
无法判别，停下来批准schema/marker；不能猜。

### 回归/证据上限

memory+persistent fresh、cleared-existing、V1 migration、V2 restart、missing/wrong/extra/
value-corrupt、bootstrap injection failure。`@Attribute(.unique)`可能阻止保存duplicate key；
若duplicate只能在未保存context构造，单独标明较低证据上限。上述证明当前schema的open行为，
不等于SQLite crash-atomic。

### Evidence Card 1C-1：true three-child restart / migration tracer

不要让旧`ModelContainer`、context或attached `@Model`跨阶段存活。child A只负责seed V1/V2并
写出primitive manifest后正常退出；child B只负责open/migrate与一次批准的public read，
写出receipt后正常退出；child C只负责fresh reopen、全量public projection与独立schema inspector。
父进程只传路径和primitive manifest，不持有任何SwiftData对象。第一张cycle只证明一次正常
V1→V2 process teardown；第二张再证明普通V2 restart，不能用同一进程reopen给二者背书。

### Evidence Card 1C-2：Migration / externalStorage child kill

在1C-1的process boundary成立后，扩展child helper，在migration first delete、first insert、
transaction return，以及大型external capture/revise/clear的已批准barrier执行process kill。
每一点各是一张proof cycle；fresh child重开只能看到完整old或完整new state，不能有orphan、
duplicate或半个external blob。若现实现已通过，只记录proof；若Red，再根据实际残留shape决定
staging/idempotent recovery，不预先加复杂机制。

### Evidence Card 1C-3：external clone full hydration / byte-exact manifest

现有“过滤已知external clone诊断”不能作为数据完整性oracle。child A写入每种canonical、revision、
thumbnail/paste可达的大blob并输出按item/reference/type分组的fixture ID、type与length manifest；复制完整的
app-owned store family后child A退出；child B只从clone fresh open，并经public browse/details/paste/
thumbnail逐一强制hydrate，与独立fixture bytes逐项byte-exact比较。第一张cycle只比较一个representation；其余
按类型逐张扩展。最低Green先修clone/fixture流程；在所有public payload都被读取前，不把被过滤的
Core Data诊断定性为benign，也不据此设计recovery。

### Card 1D：Local-only CloudKit configuration

通过production configuration seam构造真实ModelConfiguration，Red要求
`cloudKitDatabase == .none`；另给project/entitlement gate一个negative fixture，加入任意iCloud/
CloudKit capability但没有owning spec admission时必须失败。最低Green只是显式`.none`与窄gate，
不引入sync abstraction，也不以当前无entitlement替代测试。

## 7. 执行卡 2：Retained projection 与 ID invariants

### Card 2A — RetainedBytes relations

**Seam：** public capture/revise/policy + real storage；corruption只在setup注入。

Red literals：`canonical=0`；`revisionCount=1,revisionBytes=0`；`revisionCount=2,
revisionBytes=1`。分别触发capture、revise、R3 sweep、restart；期望typed corruption且
position/config/item不变。

为了证明transaction前失败，可预先arm one-shot transaction failure：第一次corruption
调用后修复scalar，下一次合法调用仍应命中injection。

最低Green：一个不可由非法scalar构造的validated value；R3/migration已decode blobs时调用
shared equality check。不要让R2零decode路径为了cross-check而全量hydrate。

### Card 2B-1 — Domain revision/item candidate ID uniqueness

**Seam：** pure planner先行，随后真实History。

Red：已有revision `r1`，candidate仍为`r1`且content changed；pure planner必须返回批准的
`DomainRejection`，不能append，也绝不mint。属性测试：成功append后ID set恰多1。Item create
ID collision用独立cycle，不与revision混成一个expected。

最低Green：Domain append前O(R≤100) uniqueness guard，只修改pure plan。

### Card 2B-2 — Storage ID-source collision recovery

先批准retry bound与耗尽后的typed failure。然后用固定collision ID source经真实History写
Red：有界重试成功，或耗尽后失败且无blob write/position advance、旧details仍可读。Storage
负责mint/retry，Domain仍只reject。

### Card 2C-1 — Signature codec aggregate bound

**Seam：** `SignatureBlobV1` codec；只做codec invariant，不启动History。

Red：用可注入的小limits构造“每个`byteCount`单独≤per-representation bound，但总和恰为
aggregate bound + 1”的literal blob；decode必须在返回entries前给出既有typed
`totalBytesExceedBound`。Checked-addition overflow是单独的defensive cycle，只有现有limits fixture
能合法构造时才写。最低Green只增加checked sum与既有aggregate limit比较；若`HistoryLimits`尚未
把该总量定义给signature codec，先做decision record，测试不能自行发明数字。

### Card 2C-2 — Signature coverage is safe negative evidence

**Decision gate：** 先批准signature blob只是可丢弃hint，还是必须完整覆盖canonical
representations、可作为“没有candidate”的负面证据。只有后者才能写下面的Red；前者应改为
捕获时byte-exact fallback，不能悄悄把hint升级为authority。

Red：child A写入含text+RTF的canonical item；child B将signature blob改成结构合法但漏掉text，
然后退出；child C重新open并capture同一text。期望在任何insert/position advance前typed corruption，
或按批准的fallback仍byte-exact coalesce，绝不能静默创建duplicate。V1→V2 migration另用一张
cycle：migration已decode canonical时，canonical keys与signature coverage不一致必须按同一批准
语义失败/重建。最低Green复用canonical decode已有事实做一次coverage check，不重扫全库、不引入
第二套index abstraction。

### Card 2D — WS13 immediate rollback oracle

**Seam：** 现有transaction-injection seam + 真实History；schema inspector只补充derived invariant。

Red：seed两个不会coalesce的items并记录rows、position、config、RetainedBytes和Signature Index
snapshot；在一次非空capture/revise plan的commit点注入失败。注入返回后、执行任何后续成功操作
**之前**，public browse/details必须与seed相同，inspector的五类literal也逐项相同，publish counter
不得前进。下一次成功操作只能作为另一张control，不能让相同position或coalescing掩盖前次泄漏。
最低Green只修事务失败路径；不因测试方便暴露public index API。

### Characterization 2E-1 — R3 sweep RSS envelope

这不是预设失败的Red。用短命child、Release build和至少三个`N × revisions × blob-size`尺度，包含
接近批准上限的external blobs与真正会进入R3的lineages；记录peak RSS、hydrated bytes、row count、
wall time及退出后的public byte-exact fixture结果。先保存raw artifact并由owner批准scale envelope。只有当前实现
超过envelope，下一张cycle才写“单个bounded maintenance batch完成且result等价”的Red；若未超过，
不加入batch cursor/applying state。

### Characterization 2E-2 — Migration RSS envelope

用独立seed child生成真实V1 store，退出后由migration child处理至少三个row/blob尺度，再由第三
child核对manifest。记录migration child peak RSS与hydrated bytes，且不能复用仍存活的V1
coordinator。只有批准envelope被击穿后，才先决策restart-safe batch marker/atomicity，再为**一个
batch的可恢复行为**写Red；不要从`fetchLimit=5001`的静态观察直接实现批处理框架。

### Decision experiment 2F — 是否需要 Storage hard content ceiling

**前置：** 先修可见capacity/ENOSPC恢复，并测代表store overhead。只有达到批准风险阈值，
才把本段转成TDD卡；测试不能自行发明global ceiling。

Red：使用package-internal小limits fixture，而不是实际填充数十GiB。所有items pinned、用户
retention全关，durable content达到`limit-1/limit/limit+1`；边界内成功，越界返回明确
capacity failure，旧store/position不变，restart仍可读旧内容。

最低Green：一个不可关闭、包含canonical、revisions与pinned的content safety line；用户预算
可更小但不能关掉hard line。物理disk overhead/ENOSPC属于现有`AppComposition`或经批准抽出的
concrete `ClipboardFlow` capture lane的另一张卡。

## 8. 执行卡 3：Revise editor Keep Current

**Seam：** 先测试从`HistoryDetails`构建draft与draft→`ReviseRequest`的Presentation行为；
再host actual editor control。不要通过检查private enum映射来断言。

### Red序列

1. Canonical `{A:old,B:x}`，Effective `{A:new,B:x}`；打开editor，不改直接Save →
   literal decisions保持current bytes，执行receipt为`.unchanged`，A仍`new`。
2. 同fixture，只Hide B → A仍`new`，B隐藏。
3. 用户明确Use Original A → A才变`old`。
4. Replace空Data → Save disabled/inline error，不能把Storage rejection当正常UX。
5. HTML/RTF先批准raw-markup editor（明确label + format/round-trip validation）、rich
   serializer或禁用三者之一；只为chosen behavior写test，不能把UTF-8本身当损坏证据。

expected bytes使用literal `old/new/x`，不能调用production draft builder生成expected。

### Red 3B — stale editor preserves the user's draft

**Decision gate：** 先批准stale后是“保留并提示Reload”、允许显式rebase，还是禁止继续保存；
不得由实现Agent把自动reload/自动merge写进测试。无论选哪种，用户未提交的bytes不能被迟到的
authoritative details静默覆盖。

Red：打开reference v1并把A改成literal `draft-A`；History随后发布同ID v2，保存返回stale。
断言editor仍显示`draft-A`与dirty状态，并呈现批准的下一步；不得dismiss或用v2替换draft。最低
Green只把base reference、draft与dirty分离并保留；reload/rebase/save policy各自另开cycle。

### Red 3C — dirty Cancel / Esc does not discard silently

Red：actual editor中修改一个field后触发Cancel；第一张cycle只断言editor仍在、draft bytes不变且
出现discard confirmation。Esc走同一product intent的hosted control test，不能复制一套dismiss
逻辑。确认Discard后的关闭是下一张control；无dirty Cancel直接关闭也是独立control。最低Green
只是一个dirty-dismiss guard，不引入autosave、undo framework或跨会话draft store。

### Product decision 3D — revision-history disclosure

“Edit Content”不会删除旧revision里的敏感内容。先决定界面是否明确告知“Save appends an
immutable revision”；批准后用一张hosted copy test证明文案在Save前可见。不要把未批准的
destructive prune API塞进editor TDD。

### 最低 Green

Draft精确保存current Effective与canonical差异；Keep Current在需要表达时生成current bytes；
no dirty返回unchanged。HTML/RTF的最低Green取决于上述独立产品决策，不阻塞Keep bug先Green。

### Review/回归

检查文本format policy是否在Preview/Details/Editor重复；只在Presentation内部抽一个policy，
Storage独立副本用parity test。跑Revise Editor hosted view + Domain/Storage revision suites。

### 支持上限

Draft test证明request语义；只有actual control test证明label/button真的发对request。

## 9. 执行卡 4：Observation 保留最新state

**Seam：** public `observe` stream + real in-memory History。

Red：创建observer后暂停消费；依次完成C1/C2/C3三个commits和outer yields；恢复一次`next()`
应直接得到C3。再覆盖未开始消费、慢消费、recent/search、cancel/unregister、query failure。

最低Green：outer stream明确newest(1)，并处理yield termination使producer及时结束。

Review：若需要新增`afterReplacementYield`，只能是package/internal scheduling seam；测试不应
assert buffer对象或内部call count。

支持上限：证明已生成pages的replacement semantics；不证明UI消费速度或RSS，另加perf。

## 10. 执行卡 5：Pasteboard access、stable snapshot 与 concealment

### Card 5A — Access capability reducer

**Seam：** app-internal capture health state；Apple access读取是system boundary。

Pure Red覆盖default/ask/allow/deny/readFailure/userPaused的显示状态、polling decision与恢复
action。Denied绝不能呈现“empty history”。最低Green只是state/reducer和入口状态，不先猜
真实API返回。

随后signed clean-profile runtime matrix：cold existing content、background copy、user action、
Ask→Allow/Deny、System Settings切换、restart、login launch。Fake不能关闭此acceptance。

### Card 5B — Stable exhaustive snapshot

**Seam：** `PasteboardAdapter.captureOutcome`，named private pasteboard + internal item boundary。

**Decision（Batch 7）：** `CaptureOutcome?` 的 `nil` 只表示真正empty/metadata-only；非空结果是闭合
public enum：stable `complete`、`declaredUnavailable` partial、payload-read前的`concealed`、
`unsupportedMultiItem`和content-free `changedDuringRead`。每个case只携带该状态合法的字段，调用者必须
穷举。lineage hint继续是optional metadata：absent/malformed本身不把已完整读取的content降级为partial。
结果只表达observed unavailable，不推断provider timeout。

Red：

- 若批准exhaustive result：all content types unavailable ≠ empty；
- lineage declared-but-nil/malformed按批准语义要么保持optional，要么使metadata/incomplete状态
  可见，不能由实现Agent默认后一项；
- start/end `changeCount`变化返回changed/retry，不返回complete；
- public complete convenience不得返回partial；
- stable complete返回exact representations。

最低Green：closed exhaustive result、start/end fence、有界一次retry。`capture()`只从`complete`返回值；
observer遇到第一次`changedDuringRead`立即再freeze一次，stable complete替换旧代，第二次race作为唯一
terminal content-free结果，其他partial结果不能把旧代bytes重新带回。

### Card 5C — Concealed before bytes

用lazy accessor spy：item types含conceal marker时，payload accessor调用次数必须为0；即使有
5MiB text也不freeze。最低Green是在任何data call前type short-circuit；Storage保留二次拒绝。

支持上限：private spy证明调用顺序；macOS privacy下types访问是否prompt仍需signed card。

### Card 5D — 移除 shipped public test hooks

先把SwiftPM adapter failure tests改为package/internal AppKit boundary injection；app write-failure
journey改在现有`AppComposition`或经批准抽出的concrete `ClipboardFlow`的copy-lane
writer-result seam安排。两套替代tests必须先Red/Green，证明
不再依赖public knobs。随后删除`simulatedUnavailableTypeIdentifiers`与
`simulatedRejectedWriteTypeIdentifiers`，并按批准流程更新产品surface/symbol evidence。

这张卡只缩surface和迁移测试安排，不同时改变partial/write产品语义；删除后外部调用者无法
切换模拟失败。

## 11. 执行卡 6：app owner 的 bounded capture lane

**前置：** 先批准overload policy、observer start的immediate-import/baseline语义，以及
在现有`AppComposition`内先形成app-internal capture lane；只有职责已使owner过浅时，才按批准设计
抽成concrete `ClipboardFlow`。capture与copy lane共享owner/lifecycle，不共享一个generic queue或
相同overload语义。

### 判别实验（不是先写实现）

把queue budget设为2，暂停真实History commit并提交3个已freeze小值，即可区分bounded FIFO、
active+latest、explicit pause/reject的语义；记录保留顺序/丢弃数。真实RSS与aggregate bytes
另用有总byte cap的Release stress，内容本身不进记录。

### Red

按批准语义写一个最小behavior。例如若选bounded FIFO：第N+1个在budget满时返回visible
overload，而不是silent drop；已接受的A/B顺序与History receipts一致。若选latest，则明确
哪些accepted/frozen值可被替换并有可见counter。

另测capacity/storage failure进入degraded health，只有`.excludedFromHistory`可静默。

### 最低 Green

一个structured owner、一个active operation、明确pending count/bytes；不为每值spawn独立
unowned Task。它只调用adapter与History，不成为command bus。

### 回归/支持上限

small/near-bound、cancel/stop/start、store suspend/fail/recover、panel closed。证明已观察并
提交flow的行为，不证明polling能找回tick间内容。

### Card 6B — Low disk / ENOSPC health

**Seam：** `AppComposition`或经批准抽出的concrete `ClipboardFlow`的capture health，不与Storage hard
ceiling混测。Filesystem/system boundary返回
low-space或transaction ENOSPC；真实History旧state仍可读。Red要求flow进入content-free、可
恢复degraded状态并停止无意义重试，不能`try?`静默；恢复空间后用户动作/retry按批准语义
重新active。最低Green只做错误分类与health transition，不引入通用disk monitor。

## 12. 执行卡 7：app owner 的 ordered copy lane 与 write integrity

**Seam：** 现有`AppComposition`或经批准抽出的concrete `ClipboardFlow` copy lane + real History +
named private pasteboard；close recorder只是外部effect boundary。

**前置：** 先批准current-by-ID（现行规格）或selection-stable语义；不能把下面一个选项当成
无争议bug修复。

### Red

1. A resolve暂停，随后B触发：按近期已冻结的exclusive first-accepted语义，B立即得到busy/rejected并由
   UI保持pending affordance；绝不进入FIFO，也绝不出现B成功后A覆盖且close两次。
2. Revision race按批准规格二选一：
   - selection-stable：请求reference v1、resolve返回v2时不写、不close，显示stale并reload；
   - current-by-ID（现行03b/04）：明确写v2，receipt/界面不得声称复制的是v1。
3. write result false：不close，失败可重试；旧/partial board语义按实现策略明确。
4. staging某representation失败：在`clear/writeObjects`前失败，clipboard不变。
5. 成功：所有representations+lineage在一个item，close exactly once。

### 最低 Green

移除nested Task；resolve→按批准版本语义validate/refresh→stage item→write→receipt在同一
structured operation。UI pending时阻止重复触发是最低复杂度选择。

### Review/回归

删除`AppPasteOrchestrationTests`中的手写pump；同一tests直接调用flow。Private pasteboard完成后
再用XCUI/general pasteboard跑一条纵向journey。不要把`setData/writeObjects`叫atomic。

## 13. 执行卡 8：History/query phases 与 pagination

**Seam：** `HistoryViewState`/presentation model，再host actual list/search controls。

### Red 8A — generation coherence

Scripted UI History安排：query A的page迟到；用户已切B；B invalid regexp。断言A永不以B
caption显示，旧rows不可Return；phase为invalid/loading而非“No History”。Manual generation
代替150/400ms negative sleeps。

### Red 8B — pinned-only pagination

第一页50 pinned且next cursor；让最后一个overall row appear或激活Load More，必须请求第二页。
测试不检查`onAppear`挂在哪个private view，只观察History收到正确cursor、rows最终增加。

### Red 8C — count/selection

有next时显示`50+`/`50 shown`；authoritative rows删除selected item后selection清空，action disabled。

### Red 8D — pagination lifecycle / stale completion

给ScriptedHistory增加non-cooperative pausable browse，而不是sleep：A page parked后deactivate，
立即`!isLoadingPage`；释放A后rows/cursor不变。第二例：fuzzy page A parked→切exact并取得新first
page→在A未返回时启动exact page B；释放A不得append，也不得清B spinner；只释放B才追加并
结束loading。最低Green需要owned pagination Task + monotonic request token；仅`cancel()`不够，
因为旧Task的completion/defer不能修改新请求state。

### Red 8E — raw exact/regexp query preserves spaces

Red：draft为literal `"  needle  "`时切到exact（regexp另开同构cycle），传给History的query bytes
必须逐字相同；只有真正空字符串进入recent，纯空格不是由Presentation擅自定义的empty。最低
Green只分离raw draft与display/admitted query，不把trim helper换一种名字继续复用。若owner要把
whitespace-only定义为empty，先修改owning spec，再写相反的test。

### Red 8F — fuzzy admission is one atomic intent

Red：raw draft有65个characters，用户从exact切到fuzzy。History recorder不得先收到“fuzzy +
未截断draft”的invalid中间请求；它只收到一次按批准规则clamp后的fuzzy intent，或一次visible
validation failure。mode change与query admission作为一个Presentation intent观察，不assert private
`didSet`调用顺序。最低Green只建立原子set/admit路径，不引入通用form framework。

### Red 8G-1 — visible Clear uses the same query intent

Hosted Red：actual search field输入非空query后，visible clear control可由鼠标与Full Keyboard Access
触发；History最终收到一次empty/recent intent，selection和stale pagination按同一generation失效。
最低Green只连接现有intent，不新增第二套clear逻辑。

### Red 8G-2 — search field does not mutate clipboard syntax

Hosted Red：向actual search field输入易被系统更正的literal，失焦/提交后raw draft完全相同；验证
autocorrection、capitalization等会改写exact/regexp语义的行为已关闭。这个test只证明control
configuration，不与search result correctness混测。

### Red 8H — failure is an episode, not a forever-suppressed string

第一张cycle：mutation失败`E`→用户dismiss→一次明确retry/success→再次失败同样`E`，第二次必须
重新可见。第二张cycle：mutation failure仍显示时收到正常browse/observation page，page不得清掉
该failure。最低Green用operation/episode identity和明确terminal transition，不用
`dismissedFailure == message`；不要借此建立全局toast bus。

### 最低 Green

显式phase+generation；overall sentinel；selection reconciliation；pagination task/token属于同一
browsing lifecycle。不要为了total count新增昂贵query。

### Hosted acceptance

真实`NSHostingView`输入query、触发invalid、滚到sentinel、按Return；证明control wiring，不做
脆弱pixel snapshot。

## 14. 执行卡 9：Preview coherence、purge 与 placement

### Card 9A — exact reference retarget

**Seam：** Preview state/loader + composed row observation。

Red：选中v1并显示；同ID row变v2 → 旧content立即失效并最终显示v2。Load中收到mismatch →
`isLoading`必须结束/重试；remove → preview关闭。现有test先补`!isLoading`断言。

最低Green：监听derived `HistoryItemReference?`，所有result带generation/reference。

### Card 9B — Clear/remove purge

Park thumbnail/preview fetch → Clear成功 → 清details path/selection/preview/cache并advance purge
generation → 迟到completion不得重填。Remove/revise按exact reference精准evict。

最低Green：mutation可await receipt；purge generation属于surface owner，不需要全局cache bus。

### Card 9C — Preview side

最小Pure Red只有一个行为：右边缘placement=`left`，preview frame位于main左侧，且开关前后
main-content screen frame不动。最低Green：shared `PreviewPlacement`驱动frame与column order。

Drag anchor与finite/NaN输入保留/补充独立pure controls；窄屏overlay/replace/收窄属于新产品
决策，先prototype，不并入这个Red。多屏/hotplug继续留给runtime gate。

Hosted Red：main/preview有stable accessibility identifier，真实NSPanel中断言accessible frames和
column order。最后XCUI/真机测cursor/status-item两边、多屏负坐标/hotplug。

### Card 9D — unsupported is not failed

**Decision gate：** 先批准可preview类型与用户文案；若image decode failure仍被spec定义为
`corruptStoredValue`，不能在UI test中把它改叫unsupported。

分别写两张cycle：合法但无preview能力的representation进入stable unsupported phase，不显示Retry；
已支持类型的transient load failure进入failed phase并显示Retry，重试成功后清failure。Expected
phase来自literal loader result，不检查private error mapping。最低Green只引入Presentation内部的
closed phase，不改变Storage failure taxonomy。

### Card 9E — panel closed keeps preview closed

Red：用户显式关闭preview，panel close→reopen且selection仍存在；preview仍关闭，隐藏期间selection
变化也不得自动打开。若产品要“每次session恢复默认开启”，先批准相反规则。最低Green只让
`panelClosed`遵守一个持久/会话内visible value，不新增preview coordinator。

### Card 9F — last-position anchors the main surface

Pure Red：在preview打开、总宽721时记录last position；关闭后以main宽400 reopen，main surface的
anchor与记录值相同，不能因曾包含preview而横移。left/right preview各一张literal frame cycle。
Hosted control再验证实际NSPanel frame。最低Green只统一“记录/恢复哪个rect”的定义；不把多屏
clamping、layout order和preview visibility并入同一cycle。

### 支持上限

Pure只证明数学；hosted只证明单进程layout；WindowServer、多屏、Space必须runtime。

## 15. 执行卡 10：Settings exact draft 与平台状态

**前置：** GOV-2先批准retention readback是public requirement还是app/internal UI seam；未裁决前
只可测试现有行为，不进一步扩用当前未准入protocol requirement。

### Red 10A — retention round trip

Configured `90001s`、`1048577B`、revision limits；用户只改revision count。Apply后的request中
age/bytes必须literal原值。无dirty Apply为unchanged。Readback迟到不能覆盖dirty field。

最低Green：raw DTO + per-field dirty bits；display formatter不成为stored value。

### Red 10B — units/copy

MiB用正确label与locale-aware formatter；去除`OPEN-2`；count与三维retention在同一可达group；
event-triggered age有诚实说明。

### Red 10C — SMAppService state

Pure reducer覆盖disabled/enabled/requiresApproval/notFound/operationFailed；requiresApproval可
unregister并给System Settings action；外部状态变化refresh。

Hosted fake只能证明UI；Developer ID安装包下fresh register/deny/revoke/logout-login才关闭
acceptance。

### Red 10D — warn only for strict retention tightening

**Seam：** Settings draft对已加载raw configuration的pure comparison；不为此扩充public
`ClipboardHistory`。

Red：一次只改变一个dimension。count/age/storage/revision从unlimited或较大值变得更严格时，Apply
先显示“可能立即删除且不可恢复”的confirmation，尚未确认不得发action；同值或放宽时直接Apply。
每个dimension可用同一table表达一个逻辑predicate，但不要在这张卡增加精确“将删除N项”的
preflight API。最低Green只是local strictness comparison与confirm gate。

### Red 10E — success state cannot survive a new edit

Red：Apply成功显示Done；用户随后编辑任一field，Done立即清除并恢复dirty/Apply enabled。迟到的
前一次success completion不得覆盖新dirty generation。最低Green复用per-field dirty bits和request
token，不引入通用form-state框架。

## 16. 执行卡 11：Search admission、cancellation 与 regexp budget

### Red 11A — no-I/O admission

给search debug probe/corpus poison：4097-byte exact、65-char fuzzy、invalid/unsafe regexp都返回
typed invalid，且`context-create/search-corpus-fetch-begin`均为0。Empty search则只要求
`search-corpus-fetch-begin=0`：它应走一次正常recent scalar read/context并返回正确recent cursor，
不能误写成zero I/O。

最低Green：`AdmittedSearchRequest`在context前创建；worker保留defensive check。

### Red 11B — cooperative cancellation

在Authority projection第一个chunk和worker scan第一个chunk park；取消A并发B。A在下一个chunk
退出，B不等待A完整corpus/scan；随后capture latency在批准budget内。用generation/gate，不用
sleep猜“已经取消”。

### Red 11C — regexp

Pure grammar先覆盖连续ambiguous quantifiers、nested/backreference等literal。Apple对
[`enumerateMatches(..., .reportProgress)`](https://developer.apple.com/documentation/foundation/nsregularexpression/enumeratematches(in:options:range:using:))
明确写明：long-running match会周期回调，client可将
`stop`设为true停止operation；先用child watchdog判别macOS26/目标pattern确实提供可用progress。
若有效，再按已批准deadline返回match/no-match/typed timeout；若无效，则选择更保守静态拒绝、
新engine或killable helper process之一。不能用另一个Task包timeout后遗留不可抢占ICU work。

### 最低 Green / Review

每固定小chunk检查cancel/epoch；regexp最低Green取决于上述判别和owner批准，不能先写死
engine。Green后才考虑streaming limit+1/top-K；resident corpus/FTS需另一个performance
trigger，不是本卡内容。

## 17. 执行卡 12：Dedup candidate residency

**Seam：** Domain先以narrow candidate facts证明语义；Storage通过public capture测资源。

### Control characterization

现有winner rank/permutation/forced collision examples先通过不含revisions的candidate表达，
outcome必须不变。这可能立即绿色，是characterization/anti-semantic-regression，不叫Red。

### Resource Red

用至少两个N/R scales：每项同text+unique extra UTI并有R-size revisions，再捕获text-only。
Probe记录revision blob decode次数/bytes与peak live bytes；批准一个精确decode/byte ceiling或scale
envelope，使当前full-hydrate路径失败。单个N样本不能证明渐近式。Corrupt non-winner按批准
fail-closed语义另测，不能在优化中偷偷忽略。

### 最低 Green

general candidates只带id/version/canonical/occurrence；hint/winner才full hydrate，或逐候选
验证后立即project/release。保持deterministic rank与byte-exact confirm。

### 回归

collision、containment、permutation、candidate storm、receipt reference、corruption、capture
latency/RSS。先修fact depth，不同时重写signature index。

## 18. 执行卡 13：Thumbnail resource bounds 与 materialization

### Red 13A — distinct flight permit

并发20个不同keys，暂停decode。断言source hydration count/bytes不超过配置；取消19个后它们
不进入hydrate/decode。Queued request只持reference的内部事实通过resource counters间接证明，
不assert具体queue class。

最低Green：permit在loadSource前；active-worker count与source-byte cap来自先批准的resource
budget，不由实现Agent默认“1–2”；row structured task保留cancel handle。

### Red 13B — eager decode

先冻结Release build、目标machine class、synthetic image、sample count、heartbeat metric与
失败阈值；没有approved SLO时本卡只能record-only。随后让decoder返回后在MainActor做第一次
真实draw并运行heartbeat，当前lazy路径应超过阈值形成Red。最低Green：支持处设
cache-immediately；若契约仍不足，worker内画入bitmap context。

### Red 13C — rectangular size

512×512 PNG请求256×64，实际output两轴都≤bound。Expected dimensions是literal。若产品
决定public contract其实只支持方形，则先收窄规格，再写“矩形请求被拒”的相反Red。

### Red 13D — completed state

若暂不准入cache：scroll out/panel close释放，remove/version/clear精准清；若正式准入：顺序
四个entries、capacity3时最新仍可读，不能wipe-all。两种产品决策不能混在同一test。

### Decision-gated 13E — Untrusted image classification / source fallback

当前`05 §14.5`把image decode失败定义为`corruptStoredValue`。实现Agent不得直接写相反Red；
先批准以下之一：

- 保留现规：literal假PNG必须fail closed，UI将其与内部store损坏准确呈现；
- 改为unpreviewable：raw paste仍byte-exact，preview不重复昂贵decode；
- 尝试后续representation：第一候选损坏、第二合法PNG时成功，并明确selection policy。

批准后只为chosen behavior写test；另外两个作为rejected alternatives记录，不同时实现。

## 19. 执行卡 14：Keyboard、hotkey、panel lifecycle

**Decision gate：** 先分别批准open时selection/focus、close后state、标准shortcut是warning还是
hard reject、session/sleep时capture继续还是暂停。尤其暂停observer可能丢history，不能作为
默认Green。下面只对chosen behavior写test。

### Red 14A — panel session reducer

`prepareForOpen(rows)`选newest并请求search focus；close按批准规则清/保留query、selection、
details、preview；closing callback exactly once。Marked text时Esc/Return返回“交给IME”。

### Red 14B — hotkey registrar

Fake system boundary：注册冲突产生visible unavailable；换绑失败保留旧键；system-standard
组合提示/拒绝；token cleanup exactly once。Fake不证明Carbon delivery。

### Red 14C — lifecycle

reopen、session resign/active、sleep/wake、screen change的value/reducer与hosted notifications；
inactive/sleep时panel关、observer停，resume按批准语义baseline/restart。

### Red 14D — one lifecycle owner

Hosted Red：构造真实AppDelegate-owned panel并挂载actual SwiftUI root；一次app activation + view
mount只能产生一个active observation/session，close/deactivate只能结束一次，reopen再产生一个新
generation。通过ScriptedHistory的active stream与visible phase观察，不断言`.task`或delegate
private method call count。最低Green先选定唯一owner并让另一入口只转发intent；不新增第三个
panel manager或全局lifecycle bus。

### Runtime acceptance

真实helper app保持前台文本焦点；按键summon/close且原app仍frontmost；ABC/Dvorak/CJK、Secure
Input、锁屏/唤醒、冲突进程、normal/full-screen/Stage Manager、多屏。只有此层允许文档写
“可靠跨应用/Space召回”。

## 20. 执行卡 15：真正的 UI tracer journeys

新增`bundle.ui-testing` target，但保持小而纵向。**第一张、唯一阻断卡只有一条：** 启动真正的
test app process并等待ready → status action或调用真实Carbon callback之后的同一product tail →
actual panel/search focus → type/arrows/Return → 读取General pasteboard exact content → panel closes
once。测试不能手写capture/paste pump，不能用第二套composition或直接调用view model来冒充XCUI。

### Card 15A — actual accessibility tree

用`NSHostingView`/真实`NSPanel`读取AX tree。第一张cycle只断言每个history row是可聚焦元素，label
包含可辨认content/source，且有default Copy action；第二张cycle才检查Pin/Unpin、Details、Remove
这些named actions。若SwiftUI自动生成的tree已满足，保留characterization test而不加wrapper。
最低Green只补缺失的accessibility representation/actions，不复制业务mutation逻辑。

### Card 15B — accessibility actions reach product intents

从AX element调用一个default Copy action，观察同一批准`AppComposition`/concrete `ClipboardFlow`
copy lane的receipt/close结果；Pin等named
action逐张扩展。测试不调用private closure，也不以“action name存在”代替行为。Hosted层不接触
General pasteboard；真正跨进程copy仍由本节首条XCUI journey证明。

### Card 15C — image preview has non-decorative meaning

Hosted Red：有image preview时AX tree提供localized label与literal pixel dimensions；装饰性背景图
仍应隐藏。第一张cycle只测label，dimensions另开cycle。最低Green只补语义文本，不让AX读取
`CGImage`/`NSImage`对象。

### Card 15D — dynamic result announcement

通过可替换的AppKit announcement boundary捕获一次结果变化：例如Remove成功后发布content-free、
localized announcement；failure和search result count分别另开cycle。Red断言notification种类、
目标element与literal message，不用固定sleep等待VoiceOver。最低Green只在authoritative phase
transition发送一次，迟到/stale completion不得宣布；真实VoiceOver可理解性仍留给16E。

第一条Green后，以下只是由对应finding驱动的候选扩展，不是任意“必须凑满”的test count；每条
独立、可重置temp store：

1. Launch → status item visible → capture-ready marker；
2. panel关闭时写General pasteboard → history最终有值；
3. invalid regexp/loading/pinned pagination不允许旧row copy；
4. preview visible toggle、右边缘placement、revision更新不显示旧content；
5. remove/clear confirmation后actual view与cache不留旧content；
6. Settings exact retention/login state可达且VoiceOver labels/focus order存在。

DEBUG summon bridge必须调用Carbon callback之后相同的product tail；不能另写一条test-only open
路径。Accessibility identifiers是产品可访问性seam，不应暴露public Swift API。

这些tests不替代Domain/storage suites；避免对动画像素、私有view tree或固定sleep断言。

## 21. 执行卡 16：State-3 slices（逐张执行）

这些不是一个release mega-slice。每项独立Red→Green，前一项不能用后一项的成功背书。

### Card 16A — Archive identity / build contract

Red：受保护release ref、实际checkout、marketing version、build version任一不一致即失败；Release
archive缺bundle identity/icon/category/entitlements/expected executable也失败。最低Green只建立
protected release ref→单一checkout→Release archive与effective-build-settings contract，不做签名、
hash/checksum machinery或UI改造。

### Card 16B — Codesign / notarize / staple / Gatekeeper

以16A archive为输入。Red：任一nested executable未Developer ID签名、缺hardened runtime/secure
timestamp、notary失败、未staple、下载后`codesign`/`spctl`失败。最低Green只完成一条direct
distribution信任链；不同时加入updater/MAS/Homebrew。

当前先落一个更低、不可冒充16B Green的 `SIGNED-RUNTIME-0` 判别格：手动触发的macOS 26 arm64
workflow只构建一次Release app，对该产物施加本机ad-hoc签名与Hardened Runtime code-directory flag，
用`codesign --verify --deep --strict`复验，读取同一已签名产物的entitlements并拒绝iCloud/ubiquity，
随后直接启动进程、确认在短lifecycle checkpoint仍存活后终止。此格通过只证明该runner上的Release app可被ad-hoc签名、
签名携带runtime flag、最终entitlement negative gate成立且最小进程lifecycle可达；它明确不运行
`spctl`/`notarytool`/`stapler`，不支持Developer ID、secure timestamp、notarization、Gatekeeper、TCC、
login item、Carbon/status item、Space或WindowServer claim。真正`DEPLOY-16B`仍保持Red/Open，且必须
从16A冻结的archive identity开始，不得把本判别格产物发布给用户。

| Cell | 触发与输入 | 当前可观察通过条件 | 明确不支持的外推 |
|---|---|---|---|
| `SIGNED-RUNTIME-0` | `workflow_dispatch`；当前source构建一次Release app | ad-hoc signature与runtime flag可验证；同一signed app无iCloud/ubiquity entitlement；进程存活至lifecycle checkpoint | Developer ID/timestamp/notary/staple/Gatekeeper/TCC/LaunchServices/WindowServer |
| `DEPLOY-16B` | 受保护16A archive + 发布身份/凭据 | Developer ID全nested code、hardened runtime、secure timestamp、notary、staple、下载后`codesign`与`spctl`全部通过 | updater/MAS/Homebrew、跨版本升级与全部UI/权限行为 |

### Card 16C-1 — characterize open-error observability first

在短命child、独立store中分别制造可恢复permission问题、结构损坏、future schema，以及受控quota
volume上的ENOSPC；记录public typed failure与完整underlying error chain，但artifact不得含clipboard
bytes。若这些case在稳定API上都只呈现`.openStore`，UI的最低诚实行为是generic Retry、Reveal和
退出，不得从localized description猜“corrupt”后自动quarantine。只有某一分类在目标OS矩阵中
稳定可区分，才为该分类批准并写下一张recovery Red。

### Card 16C-2 — approve a dedicated StoreRoot before quarantine

**Decision gate：** store URL迁移、目录ownership和旧安装兼容必须先写入owning spec。建议候选是
app-owned `.../Clipy/HistoryStore/`，其内包含`history.store`及SwiftData管理的sidecars/external
artifacts；不能把任意caller URL的parent或整个Application Support当作所有物。

批准后第一张Red只证明新安装的所有durable artifacts都落在StoreRoot，root旁的sentinel文件不受
clear/recovery影响。旧路径→新root迁移、collision/rollback分别另开cycle。最低Green只是明确
locator/ownership，不自行枚举SwiftData内部文件格式。

### Card 16C-3 — user-confirmed quarantine with no live coordinator

以16C-2已批准root为前提。Red：open失败先提供Retry/Reveal；用户确认后，recovery child或下次启动
在没有live `ModelContainer`时，把整个StoreRoot做同文件系统、可回滚的rename。任一步失败，原root
仍在且不得悄悄进入空/in-memory store；成功后保留可Reveal的quarantine manifest。最低Green只做
这条用户确认路径，不宣称secure erase，也不根据单个`history.store`推断store family完整。

### Card 16C-4 — ENOSPC recovery is characterized, not guessed

与6B共用同一个system failure vocabulary，但分开测试：quota child证实capture/revise/remove/clear
各自在无空间时的真实结果，以及旧public reads是否仍可用。先据artifact批准UX；最低候选是停止
自动重试、提示从应用外释放空间并提供Retry/Reveal。不得承诺“Clear会腾空间”，因为clear本身也
需要transaction；不得把ENOSPC误映射成用户retention storageBytes。空间恢复后的fresh child
reopen和一次write是独立control。

### Card 16D — Localization / pseudo / RTL

Red：String Catalog缺key、plural/date/byte formatter不locale-aware、pseudo expansion截断或RTL
顺序不可用。最低Green只建立可本地化surface和pseudo/RTL gate；实际locale逐个QA，不用一次
大量未经验证翻译换数字。

### Card 16E — Accessibility journey

Red：VoiceOver与Full Keyboard Access不能完成summon/status action→find→copy，或focus order/
labels/confirmation不明确。最低Green只改这条journey与stable identifiers，不把所有像素/UI
细节塞进同一test。

### Card 16F — Signed privacy/platform matrix

使用16B的signed app且不依赖DEBUG bridge。分别测试fresh pasteboard access deny/allow/recover、
SMAppService requiresApproval/revoke/logout-login、真实hotkey/status action、Space/Stage Manager。
每个能力可拆独立case；失败只修对应state/UX，不改其它release slice。

### 共同证据上限

目录marker scan不证明SSD/backup安全擦除；一次macOS26机器不证明所有OS；notary成功不证明
业务正确。因此signed acceptance永远在functional/UI tests之后。

## 22. 执行卡 17：CI gates 与性能证据本身

### Gate tracer bullets

以下每项是独立cycle：先用一个negative fixture证明当前gate确会漏检，再做最低Green。不要把
九项合成tooling batch，也不让未触发的gate hardening抢占Keep/Paste/access主路径。

1. symbol fixture有两个同title不同signature，删除一个必须detect；
2. diagnostic合法block内夹另一条`error:`必须失败；unterminated/相似非白名单也失败；
3. RSS `.time`非空但没有positive maximum resident set size必须失败；
4. escape/import scanner的negative fixtures在`run_gates.sh`执行；
5. manifest新增非法dependency、ClipyApp新增banned spelling、第二ModelContext writer必须失败；
6. XcodeGen output缺scheme/host/Release/bundle field或app tests executed=0必须失败；
7. functional与`HistoryPerfTests` filter分别要求非零目标test执行，防止错误filter静默绿；
8. symbol bot提交snapshot后，主workflow必须在该受保护分支的最终checkout重跑并成为ledger引用；
9. XcodeGen使用仓库批准的固定版本与原生版本检查；同一checkout连续生成两次并直接`diff`输出，
   不增加下载checksum或hash-derived repeatability状态。

### Perf流程

先冻结workload、build、machine class、sample count、unit与absolute/ratio claim。Correctness suite
先绿，再运行Release runner；raw samples、parser output与metadata作为artifact。n不足以计算p95/
p99时不能打印相应claim。100→400宽ratio若只能排除quadratic，文档就写“未见quadratic”，
不能写linear。

同机A/B先三条journey；完整矩阵见05。任何优化必须先让一个批准SLO Red，不能因为Maccy有
cache或静态worst-case就自动落resident state。

## 23. 后续 Agent 的交付模板

每个修复PR/工作单应包含：

```markdown
Behavior:
Owning spec + section:
Approved seam:
Red test + why it failed:
Minimal Green boundary:
Tests deliberately not added:
Targeted runs:
Owner/full runs:
Evidence ceiling / remaining runtime gate:
Public surface change: none / approved record:
Protected ref / PR + CI run:
```

若一张卡需要同时改schema、public protocol、AppKit lifecycle、cache与release workflow，说明
切片仍过大。回到最小user/caller behavior，先交付一条能独立Green的vertical tracer。

## 24. 执行区：Local Python Automation

完整边界与平台证据见
[`07-python-local-automation.md`](07-python-local-automation.md)；本区只把它压缩成可逐张领取的
TDD顺序。**它不是一个“实现07中PY-0到PY-15”的PR。** 每个编号下的每一条Red仍是独立cycle：一条
caller-visible behavior、一个已批准seam、一个最低Green。任何cycle开始前，执行卡0的current-head
correctness suite必须先恢复绿色；不得在已知编译/CI失败上用新CLI测试制造第二条baseline。

### PLAY-PY-A family（不可直接标记完成）— owning spec 与 public contract

**PLAY-PY-A1 [SPEC，非Red]：**先批准V2-05/ADR中的最小产品承诺：同一effective user account（same EUID）、显式Local Automation enrollment、deny by default、
CLI version/安装发现规则与target graph。`browsePreview` audit选择在首次成功browse前批准；binary
`DEC-PY-READ-AUDIT`在PLAY-PY-D首次content release前批准A/B之一；mutation retry/idempotency在PLAY-PY-E前批准。若需要新增HistoryCore public
DTO/symbol、SwiftPM executable target或target依赖，先批准spec/target graph并更新相应gate/snapshot；
编译失败不是Red。

ClipyApp不能访问package/internal `ExternalGateway`。App Intents使用已绑定known connection的
connection-scoped facade；Local Automation则需要受限public `AuthenticatedIngressFacade`薄包装，把bounded
peer evidence、opaque credential与request原样委托给Gateway完成authenticate+connection resolution+live
grant check。amendment不能把Gateway/CredentialStore公开，也不能让transport复制授权policy或import Storage
内部类型。

**PLAY-PY-A2 [PURE contract]：**X.7 landed后，只在no-product、Foundation-only
`ClipyCLIContract`冻结versioned JSON request/reply、稳定exit-code类别与golden codec；不新增`main`、
`FileHandle`、process I/O、executable product、transport、credential、Gateway/History dependency或fabricated
positive result。若首个production adapter需要neutral declaration，把它与PLAY-PY-F1同一slice引入；
compile smoke不是行为Green。

A2是family，下面九张Red各自独立Green，不得用一张parser test关闭全部：

- **PLAY-PY-A2A — protocol major：**`protocolVersion != 1`稳定输出
  `unsupported_protocol_version`、exit 2，不dispatch。
- **PLAY-PY-A2B — size-before-parse：**65,536-byte request仍由其它规则决定，65,537 bytes在UTF-8
  decode/JSON parse/parser-owned allocation前得到`request_too_large`、exit 2。完整reply上限
  33,554,432 bytes（含terminal LF），超限得到`response_too_large`而不truncate。
- **PLAY-PY-A2C — duplicate keys：**任一object内decode成同一UTF-8 scalar/byte sequence的key拒绝，
  包括`"a"`与`"\u0061"`；不做NFC/NFD normalization。Red不得只覆盖同spelling duplicate。
- **PLAY-PY-A2D — structural bounds：**root object计depth 1，depth 8/object 32 lexical members/array
  512 elements是admitted edge；
  9/33/513分别拒绝。strict UTF-8、no BOM、one root plus RFC JSON whitespace only也各有boundary fixture。
- **PLAY-PY-A2E — numbers：**只接受JSON lexical integer与target-field checked conversion；fraction、
  exponent、nonfinite extension及overflow分别拒绝，不能经floating point round-trip。
- **PLAY-PY-A2F — requestID：**只接受lowercase canonical 36-character hyphenated non-nil UUID；跨request
  重复ID必须decode成功，因为X.8只定义correlation，不定义idempotency/digest/hash。
- **PLAY-PY-A2G — pure emission：**success/error object keys递归lexicographic sort、compact UTF-8、
  stdout bytes最后恰好一个LF且无其它bytes；future stderr template恰为
  `clipyctl: <error.code>\n`，无query/cursor/content/input fragment/free text。这里只证明pure bytes，真实FD
  stdin/stdout/stderr属于X.9。
- **PLAY-PY-A2H — stable mapping：**exit 0只对应success；exit 2精确映射
  `invalid_json|invalid_request|unsupported_protocol_version|unknown_operation|request_too_large|response_too_large`；
  exit 3映射`not_enrolled|not_granted|connection_revoked|authentication_failed|peer_rejected`；exit 4映射
  `not_found|cursor_expired|content_stale|locator_invalidated`；exit 5映射
  `not_ready|rate_limited|busy|timeout|cancelled|outcome_unknown`；exit 6映射
  `store_open_failed|corrupt_data|invariant_violation|transaction_failed|audit_failed`。每个code至少一个golden，
  不能只测每组代表值。exit 2还要固定原因分类：byte envelope=`request_too_large`；UTF-8/BOM/JSON
  syntax/trailing/second-root/duplicate/depth/width/NaN/Infinity=`invalid_json`；typed shape、unknown/missing
  field、type mismatch、fraction/exponent、checked overflow、requestID/argument bounds=`invalid_request`；
  supported-grammar major/operation miss用各自dedicated code；encoder总界限=`response_too_large`。
- **PLAY-PY-A2I — closed operation/shape：**protocol v1只接受`operation:"browsePreview"`；recent args
  恰为`{limit,cursor?}`且query/mode都缺席，search args恰为`{query,mode,limit,cursor?}`且query/mode都存在，
  没有`kind`字段。unknown operation/field拒绝；limit `1...500`、query `1...4096` UTF-8 bytes、fuzzy
  64 Characters、regexp 512 Characters、cursor `1...4096` UTF-8 bytes逐边界覆盖。成功reply item/result
  exact fields、non-empty locator 1,024/1,025 UTF-8 bytes、title 1,024/1,025
  UTF-8 bytes、snippet 322/323 Characters、type count 32/33、type byte
  512/513、date-millisecond、nextCursor 4,096/4,097与result count 500/501
  bounds另用encoder goldens覆盖。

`PLAY-PY-A2A…A2I`已由
[PR #17](https://github.com/GuangDai/Clipy/pull/17)与
[correctness run 32613689337](https://github.com/GuangDai/Clipy/actions/runs/32613689337)
关闭。该证据只覆盖pure codec，不能作为process I/O、transport、credential或Python→History Green。

在任何positive Gateway tracer前，**PLAY-PY-GW0 [PURE / RESOLVED-SPEC]**先冻结
`(ConnectionEnrollKind, capability/operation) -> grantable` closed matrix：`.appIntents`只保留owning V2-05
已批准surface；`deleteItem/reviseContent`等local-only operation即使共享enum可构造也必须denied，unknown pair
deny且不触发History/audit side effect。只有独立App Intents amendment才能扩它。

AUTO-2不是一张browse可关闭的标签。当前X.3 schema/bootstrap完成后，再逐张领取四张X.4 Gateway substrate Red：
**PLAY-PY-GW1** compaction/recovery marker、prefix trim与floor advance同transaction，survivor恰好覆盖
`[compactionFloor, nextAuditSequence)`，below-floor typed返回；这只证明sequence/floor一致性，不证明tamper evidence。
**PLAY-PY-GW2** 完整codec一次覆盖所有已准入external/admin literal，每个kind的closed、bounded、privacy-safe
request/result encoding可golden round-trip；global rebase/compact的connection/capability为nil，不伪造admin capability。
**PLAY-PY-GW3** revoke后re-grant更新唯一current-state row、不撞unique key且最多一个live grant，grant/revoke/
re-grant event history由audit records承载；**PLAY-PY-GW4** ordinary open面对可区分的corrupt/missing audit
state仍fail closed，而用户确认的recovery-only seam只能诊断/rebase/quarantine，不能读content或执行History
mutation。无audit off-switch；不新增hash/chain或`GatewayConfigRow.generation`。

### 当前 Gateway code leaf — roadmap `X.4`

X.3 schema/bootstrap已落地。X.4的spec-first Red不再是OPEN：owning `V2-05` §4.4已冻结
17个request tags、15个result tags、outcome/attribution compatibility和operation raws。raw 10只是
revoke connection；raw 16/17/18/19分别revoke capability、connections read、grants read和audit
read。三个admin read都是durable-before-release：先得immutable DTO/snapshot，再append audit，成功
后才return；audit append失败必须throw且不发布content/DTO。audit read以append前的
exclusive `snapshotHead`选页，自身record不能递归出现在返回页中。

Red/Green按owner拆，但同一PR落地，避免一个incomplete codec被writer使用：

1. **GW2-codec：** `OperationPayloadBlobV1Tests` table-drive全部request/result tag、raw/cross-field
   mismatch、outcome compatibility、enroll pre-create nil attribution、search/no-content privacy；输入
   `Data.count > 16 KiB`在parse前拒绝，encode亦不得越界。Green只新建
   `OperationPayloadBlobV1.swift`，没有writer。
2. **GW1-audit store：** `GatewayAuditStoreTests`先证mint+insert+counter、retained interval、
   bounded read以及exact logical accounting。每行贡献`payloadBlob.count + 128`，startup重算
   必须等于`auditBytes`；overflow/underflow/mismatch fail closed。这不是physical disk-byte claim。
3. **GW3-admin：** `GatewayAdministrationTests`通过真实Authority transaction证enroll/grant/
   revoke-connection/revoke-capability的distinct audit kind与同transaction behavior；re-grant只更新
   同一current-state row。connections/grants/auditLog各有自己的read kind，绝不经generic admin。
4. **GW1/GW4-maintenance/startup：** compaction marker+prefix trim+floor+logical-byte subtract在同一
   transaction；X.3 zero-row startup rule与首个writer同时替换为full validation。ordinary open遇
   corrupt retained interval仍fail closed。可单测internal rebase transaction和healthy-store
   `.adminForced`，但X.4不增public recovery opener，不得声称ordinary-open拒绝的store已可恢复。

X.4不实现`ExternalGateway` actor、facade/factory、App Intents、credential、CLI或transport；
不新增hash/chain/request digest、generic payload或performance gate。

### PLAY-PY-B family（不可直接标记完成）— deny tracer，再做read-only tracer

- **PLAY-PY-B1：**Red：未enroll时，直接穿过真实 in-process Gateway absent/unknown-connection seam的browse得到denied，且在
   History read前停止；History、audit、pasteboard都不变。Green只实现authoritative deny，不做CLI stub。
- **PLAY-PY-B2：**Red：已enroll但没有`browsePreview` grant仍denied，synthetic secret不进入result/audit。Green只增加
   authoritative grant check。
- **PLAY-PY-B0G：**`PLAY-PY-GW0…GW4`关闭后，才用真实in-process Gateway/Authority与已enroll+granted connection完成一个bounded
   positive browse；receipt/result来自production trust substrate，不经CLI或App Intent。Green只证明granted
   Gateway positive path，不能宣称一张browse关闭AUTO-2。
- **PLAY-PY-B0I：**B1/B2/B0G全绿后，已接纳的App Intent再用prebound connection-scoped facade穿过同一
   production Gateway，得到与B0G相同的bounded result；revoked/no-grant control在History read前拒绝。
   Green只闭合V2-05既有adapter baseline，不实现CLI/transport，也不复制mutation语义。
- **PLAY-PY-B3：**F0A不满足此前置；只有后续transport decision与`PLAY-PY-F1`接入production adapter后才做CLI端到端Red：真实Python向`clipyctl`发送同一request并映射exit 3；
   hard-coded deny response不得算Green。首个正向browse前分别关闭：**PLAY-PY-B3A** wrong credential、
   **PLAY-PY-B3B** revoked credential、**PLAY-PY-B3C** kernel peer evidence为different EUID；三者都必须在History
   read/response content前拒绝。B3C先用platform seam deterministic验证，最终different-user signed cell另证真实delivery。
- **PLAY-PY-B4：**Red：已grant且app已运行时，只读browse返回bounded rows；Green只完成warm read-only tracer。
- **PLAY-PY-B5：**Red：app退出时CLI能有界启动、等待ready并得到同一结果；Green只加cold-start lifecycle，不增加write。

B1/B2直接通过production Gateway/Authority in-process seam；B3–B5再通过第一方CLI与同一路径。不得mock
内部Gateway后称端到端安全已成立，也不得让Python/helper直接查询SwiftData作oracle。

### PLAY-PY-C family（不可直接标记完成）— capability discovery 与 opaque wire values

**PLAY-PY-C1：**`DEC-FORMAT-INVENTORY-OWNER`之前允许纯capability projection：Red用两个literal stable
facts + owner manifests证明declared format与有条件unknown raw fallback能被build/test
`CapabilityInventory`稳定join，且不读取history。最低Green只投影facts/manifests，不实现renderer、真实CLI
或中央production policy catalog。decision批准production owner与transport后，才让`clipyctl`消费owner-exported
immutable summaries与独立pure serializer；不得import test inventory。

opaque identity再分开执行：**PLAY-PY-C2**伪造item locator拒绝；**PLAY-PY-C3** cursor换query拒绝；
**PLAY-PY-C4** restart后旧cursor expired；**PLAY-PY-C5**同一item locator跨正常CLI invocation、app cold restart与批准migration
稳定（或按spec typed expiry），各自一张Red。Green只实现当前行为需要的最小locator/cursor
机制；不冻结UUID、`HistoryPageCursor` payload或generic token framework。capability response不得携带
grant、content、path、History ID或credential。

### PLAY-PY-D family（不可直接标记完成）— Effective-only content read

**PLAY-PY-D1A：**`DEC-PY-READ-AUDIT`已冻结；Red：Original=A、current revision=B时，拥有`readEffectiveContent` grant且请求all types的
caller只得到B的全部Effective representations；不得得到A、Canonical、revision list或occurrence。只有browse
grant仍必须denied。**PLAY-PY-D1B**再冻结explicit selected exact types及missing-type结果；
**PLAY-PY-D1C**冻结aggregate response cap：超限必须在binary release前typed `tooLarge`，不能partial、截断或
悄悄省略representation。

最低Green只做purpose-specific Effective read seam；不得先取完整`details`再在CLI丢字段。
**PLAY-PY-D2** binary length-before-allocation、**PLAY-PY-D3** caller/CLI-owned output FD、
**PLAY-PY-D4** partial cleanup、**PLAY-PY-D5** mandatory audit-publication barrier（append失败不发布
DTO/content；crash-after-audit-before-return允许留record）、**PLAY-PY-D6** half-frame、
**PLAY-PY-D7** slow sender与**PLAY-PY-D8** timeout分别是一张Red，不合成巨型test。

### PLAY-PY-E family（不可直接标记完成）— write能力按风险逐项开放

**PLAY-PY-E1A**先`organize` pin：只证明获准locator可pin且delete仍被拒绝；**PLAY-PY-E1B**另证unpin与
相应receipt/position，不从pin测试外推。**PLAY-PY-E2 [BLOCKED-DECISION]**只有`DEC-PY-DELETE-UX`冻结
destructive grant/确认与not-found disclosure后才开放`deleteItem`；只删一个明确locator，并证明没有
clear/retention/revise能力。每次都经唯一Authority transaction、live grant recheck与audit；不得恢复
`.manage implies delete`或公开generic `HistoryAction`。

`reviseContent`明确后置。只有wire draft、独立grant、audit和retry/idempotency contract已批准后，先领
**PLAY-PY-D9 [BLOCKED-SPEC/BLOCKED-DECISION]**：`DEC-PURPOSE-READ`与`DEC-PY-REVISE-CONTRACT`批准后，
purpose-specific `readRevisionBasis`只返回current Effective representations、
exact content token与可编辑type facts，不泄露Canonical bytes/旧revision list。**PLAY-PY-E3**再写stale OCC
Red；**PLAY-PY-E4**才证明fresh token只append一次revision。不要把revise塞进首个read-only或write PR。

**PLAY-PY-E5R** park read在fast precheck后、authoritative byte release前再revoke，必须零输出；
**PLAY-PY-E5W**独立park write在fast precheck后、authoritative commit前再revoke，必须零commit。
**PLAY-PY-E6A**在commit前制造CLI timeout，默认不blind retry并返回typed transient；**PLAY-PY-E6B**在
commit后、response前断线，CLI本地只报告`outcomeUnknown`且仍不blind retry；在
`DEC-PY-IDEMPOTENCY`批准前没有request-status/recheck operation。只有批准后才领
**PLAY-PY-E7**：同
connection+requestID与持久化的bounded canonical request fields在response-lost/restart后返回原receipt且
mutation/audit各一次；同ID但fields/bytes不一致时必须拒绝。它不依赖P3，也不复用`PLAY-CRASH-7`，
不新增request hash。

### PLAY-PY-F family（不可直接标记完成）— transport与signed acceptance只证明最后一公里

**PLAY-PY-F0A [LANDED，AD-HOC SIGNED DISCRIMINATOR，非产品完成]**先只回答main-app-owned UDS的机械
问题，不等待或暗中解决authenticated ingress。该卡只在手工dispatch signed-runtime proof artifact中
给main app注入compile-time `CLIPY_UDS_F0` listener，并把独立XcodeGen诊断工具
`ClipyUDSF0Client`复制进该次proof app后分别签nested tool与outer app。normal Debug/Release无listener、
无nested diagnostic client，也没有产品`clipyctl`。

F0A的private wire恰为：request 25 bytes = ASCII `CLIPYF0Q` 8 bytes + version `0x01` + nonce 16 bytes；
reply 53 bytes = ASCII `CLIPYF0R` 8 bytes + version `0x01` + echoed nonce 16 bytes + per-process generation
16 bytes + EUID/EGID/server PID三个UInt32 big-endian。一个connection只处理一个request/reply；listen backlog
为4；accepted read与write各自2秒deadline；不得产生unbounded task/queue/stream。它不解析X.8 JSON，
不读写History，不访问Gateway、credential、authenticated ingress或durable audit，也不输出public CLI
stdout/stderr。

Endpoint Red分别固定：strict UTF-8 path最多103 bytes；owner-only directory `0700`、socket `0600`、
lifetime advisory lock `0600`；symlink/non-socket/wrong owner/wrong mode fail closed；live connect成功绝不unlink；
只有持锁时`ECONNREFUSED`且两次`lstat`观察到同owner、同socket type、同device/inode才清stale node；
shutdown也只unlink bind后记录的同device/inode。client不能删endpoint。cold-start先观察absent/refused，
发出LaunchServices request后由reconnect独占10秒总deadline；completion不当作readiness且不等待。成功路径
内部必须至少发生一次后续connect attempt；启动配置四项都必须显式为false：
`activates`、`addsToRecentItems`、`promptsUserIfNeeded`、`createsNewApplicationInstance`。

同一ad-hoc-signed artifact依次跑三格：

1. cold先观察absent/refused connect，再LaunchServices启动并成功hello；
2. warm不启动第二instance，server PID与generation必须与cold相同；
3. `SIGKILL`留下socket后重新cold launch，保守stale recovery成功，PID与generation都必须更新。

runner若不能建立different-UID或交互式focus/Dock/panel/recent-items观察，这两格明确保持open；不得用
same-EUID response或`activates=false`配置值代替。F0A Green最多证明该ad-hoc-signed、non-sandbox artifact的
bounded UDS mechanics；它不证明Developer ID/team、secure timestamp、notary/staple、Gatekeeper、
App Sandbox/App Groups、Keychain sharing/client custody、TCC、caller matrix、Python→History或production
transport选择。

PR #18按此合同landed；normal graph/app scheme由
[correctness run 32615569895](https://github.com/GuangDai/Clipy/actions/runs/32615569895)
支持，最终flagged proof artifact的cold/warm/`SIGKILL`三格由
[signed-runtime run 32615713100](https://github.com/GuangDai/Clipy/actions/runs/32615713100)
支持。两次run合起来仍只关闭上述mechanics，不关闭credential、Python→History或distribution格。

**PLAY-PY-F1 [FROZEN DIRECTION，当前X.9]：**当前产品方向明确限定为non-sandbox、account-wide
same-EUID。credential恰为48 opaque bytes：preassigned UUID 16 bytes + `SecRandomCopyBytes`直接生成的
secret 32 bytes，不是hash/digest/derived identity。server保存exact token于app-private Data Protection
Keychain；client保存exact token于validated owner-only目录中的no-follow regular file（目录`0700`、文件
`0600`、descriptor上重验owner/mode/type/length），由dedicated inherited stdin provision，不经argv/env/
cwd/caller-selected path。该文件不声称抵御malicious same-EUID process；若未来需要这种confidentiality或
Sandbox，必须改为app-like wrapped CLI + 已验证Team/profile/access-group的shared Data Protection Keychain，
不能把现有file mode外推。

F1 enrollment Red必须固定publication order：client exact readback -> server Keychain exact readback ->
Authority以preassigned ID在最后一个transaction写`.localAutomation` row + successful admin-enroll audit；新row
恰为zero grants。Authority前crash留下的client/Keychain orphan没有connection/grant，因此无权；startup与retry
先best-effort清理exact orphan，清理失败阻止publication。Revoke Red反向排序：Authority先durable revoke row、
live grants与admin audit，再保留bounded server verifier使旧exact credential稳定得到audited
`connection_revoked`，最后best-effort删client file。Rotation=new connection；不迁移grant。

Ingress分类也必须独立Red：unknown/malformed/wrong secret与peer reject均在Gateway admission前停止且unaudited；
valid exact revoked credential与valid exact active-but-ungranted credential分别得到audited
`connection_revoked`/`not_granted`。先落storage-only `expectedKind` targeted authorization mismatch rejection是
允许的hardening leaf，但它既不验证secret/peer，也不算F1 authentication或B3 Green。

F1仍有两个wire blocker：X.8 cursor上限4,096 UTF-8 bytes，而现有private `HistoryPageCursor`在admitted
query bounds下约26 KiB；locator也还没有approved stable lifetime/invalidated encoding。先为二者选择bounded
server-side state或明确versioned encoding，不得用hash/digest/truncated fingerprint压缩或当identity。
Developer ID/profile、Data Protection Keychain、nested client/provisioning、notary/Gatekeeper与caller matrix的
实际signed proof仍open。roadmap X.9最终拥有B3–B5，包括warm B4与cold B5；X.10从Effective-only
content、organize、delete与后期revise开始。只有未来出现第二个真实adapter需求时才领
**PLAY-PY-F2** contract substitution；不要为“可替换”同时shipping UDS、Apple Events和XPC。

**PLAY-PY-F3A…F3D**用distribution形态分别运行：签名/公证链；cold/warm/退出/崩溃lifecycle；
Terminal/IDE/venv/launchd caller；sandbox/TCC。不得把四格合成一个Red。最终聚合matrix还包括
Python、same/different UID、credential revoke、Sandbox/TCC候选与notarized app+CLI签名链。每格失败只修
该平台行为。hosted/loopback测试最多支持protocol正确；只有最终signed matrix才支持“同用户任意可执行
`clipyctl`的Python进程可用”，仍不支持per-script identity或恶意同用户进程隔离的声称。

## 25. 执行区：Formats 与 ContentPreview

完整设计与Apple证据见
[`08-content-types-and-preview.md`](08-content-types-and-preview.md)。本区的基本规则是：raw
capture/paste、search/title、Preview、Edit和Python capability projection是不同承诺；一次cycle只提升
一个exact format的一项能力。执行卡0/current correctness suite先绿；涉及projection schema、multi-item
domain shape、History public seam、`ClipboardFormats`/`ContentPreview`新target或import gate的变化必须先
批准owning spec与target graph。

### PLAY-FORMAT-A — 先characterize，再迁移facts/catalog

先用现有public behavior与固定fixtures记录当前类型策略：exact identifier、raw round-trip、title/search、
preview outcome、edit admission、icon family和concealment。characterization只描述当前事实，不把错误行为
升级成新spec，也不靠snapshot代替语义断言。

迁移时每个cycle只移动一个stable fact或一个owner rule，并证明迁移前后caller-visible结果不变。
`ClipboardFormats`只拥有Foundation-only exact facts/special roles；Search projection、HistoryStorage
Thumbnail source、Preview、Edit、Pasteboard与Presentation request/icon各自拥有purpose-specific manifest。
inventory只join/审计这些manifest，不成为生产
god-object。若新增target尚未批准，先在现有owner内完成characterization，不能借TDD暗改架构。

source gate采用legacy-debt ratchet：先snapshot当前重复policy位置，只拒绝新增维护型Set；每迁移一个owner
再缩小allowlist。不得一次要求全仓删除所有旧集合后才允许首个行为修复。

**PLAY-FORMAT-A1 [REGRESSION GATE，非新行为Red] — unknown raw-only：**一个single-item、非privacy-marker的
未知exact UTI与literal bytes必须能经adapter capture → real in-memory History → paste replay保持type/bytes；
provider unavailable、capture changed、oversize或writer rejection仍按各自typed outcome失败，不能把“eligible
opaque round-trip”升级成无条件保证。本卡不证明multi-item fidelity，也不授予search/edit/Preview语义。

### PLAY-FORMAT-B — exact text codec逐个准入

1. exact UTF-8 plain text：valid/malformed/budget各自Red；Green只加入UTF-8 decoder，Edit只有对应
   byte-level encoder round-trip证明后才开放。
2. native UTF-16与external UTF-16按byte order/BOM契约分别执行，不用一个“text conforms”测试批量放行。
3. encoding-unspecified `public.plain-text`与abstract `public.text`保持raw-only或明确fallback，直到有独立
   object-accessor/encoding contract证据。

expected visible text必须是人工核验literal，不能在test里复刻production parser。改变durable title/search
规则前，先批准projection recipe/version与旧行migration disposition。

### PLAY-FORMAT-C — RTF/HTML先裁决raw与semantic，不从可UTF-8解码推导支持

先冻结产品决定：raw bytes继续opaque round-trip；RTF/HTML是source preview、sanitized semantic preview
还是暂时unsupported；search是否依赖plain-text sibling；Edit默认关闭。每个决定独立Red。

最低Green只关闭当前naive generic-text/Replace路径，并优先使用exact plain sibling；没有sibling时显示
type/byte metadata或typed unsupported。`RTF Source`/`HTML Source`只有对应charset/codec或有限static grammar
已批准后才可显示。semantic RTF需真实fixture、inert link与bounded attachment；HTML默认不解码源码，
network/file canary为零。没有zero-external-I/O证据时不引入WebKit，也不保持原UTI却写入plain UTF-8 bytes。

### PLAY-FORMAT-D — image label、sniffed type与runtime capability分离

分别写Red：declared exact type不在runtime ImageIO set时返回`runtimeUnavailable`；`public.png`标签+
合法JPEG bytes明确返回`.typeMismatch`；`public.png`标签+truncated PNG明确返回
`.malformedRepresentation`；每张都以raw bytes仍可paste为control。HEIF/BMP family可驱动一致icon而不等于
decoder已启用。最低Green只修一条classification或mapping；alias/HEIC-HEIF compatibility另由已批准
predicate与fixture裁决，不能机械比较sniffed identifier字符串。

effective image支持必须是“product-declared exact format ∩ 当前OS runtime capability ∩ 本次bytes实际
decode成功”。一次坏图不能改写global capability；runtime probe也不能自动把Apple未来新增格式变成
Clipy承诺。

### PLAY-FORMAT-E family — multi-item是独立schema工作流

**PLAY-FORMAT-E1 [CHAR，非Red]**先记录当前first-item截断、item/type declaration order与provider行为。
**PLAY-FORMAT-E2 [Adapter Red]**再用两个相同UTI且各有custom sibling的item，比较item count/order与每item
`(type, bytes)`集合；type declaration order暂不升格为durable contract。Green只加入adapter nested
snapshot/replay，不进入History。

**PLAY-FORMAT-E3 family [BLOCKED-SPEC，不可直接领取]**只有批准ordered snapshot/domain equality、
fingerprint/dedup、revision、lineage、persistence migration与paste staging语义后才可展开：
**PLAY-FORMAT-E3A**只锁Domain item grouping/equality/dedup；**E3B**只锁schema+codec round-trip与migration；
**E3C**只锁real Storage capture/read/revision；**E3D**只锁adapter→History→staged replay的producer/consumer
interop。每个再按一个observable behavior细分，不把整条链合成一张Red。不要把multi-item藏进“新增一种
格式”的PR，也不要用pasteboard-level`string(forType:)`当逐item round-trip oracle。

### PLAY-PREVIEW-0 — 先建立可编译seam，不把编译失败当Red

批准package-only concrete `ContentPreview` target、request/outcome与import gates后，可在首个exact-format
behavior cycle内建立最小neutral declaration/temporary `.unsupported` path以让Red编译；它不是独立、长期
scaffold，也不能单独落地后宣称进展。若首个vertical slice否决该seam，删除spike。interface gate只证明
target graph、依赖方向和production wiring可编译，不声称任何格式已支持。

### PLAY-PREVIEW-A family — 一个owner，bounded primitive artifacts

**PLAY-PREVIEW-A1**在PLAY-PREVIEW-0后只用一个exact UTF-8 fixture与一个已批准text profile，断言literal
capped text artifact；Green只支持这一variant，不先建renderer protocol树。另设compile/source gates：
artifact必须`Sendable`，package/public signatures不得出现`NSImage`、`CGImage`、`PDFDocument`、`AVAsset`、
`WKWebView`或file lease。这些类型约束不能由同一runtime Red证明。

**PLAY-PREVIEW-A2**只用一个exact PNG fixture，返回eager RGBA/BGRA artifact；checked
`rowBytes × height == Data.count`，像素/输出bytes在profile内，含dimensions/pixel format/color-space tag，
UI不再解码PNG/JPEG。encoded artifact只有独立UI-decode budget/spec gate后才另领卡。

selection、exact-reference token、panel lifecycle和late-result fence仍由`PreviewContentLoader`拥有；
renderer不观察History/UI。**PLAY-PREVIEW-A3** A慢图后切B文本、**PLAY-PREVIEW-A4** panel close、
**PLAY-PREVIEW-A5** revision
retarget各自一张Red，不能用内部调用
次数代替“只有current artifact发布”。

### PLAY-PREVIEW-B — no-external-I/O与resource proof分层

分三层，不互相冒充：owner/framework test用小fixture证明typed outcome；短命child用受控HTTP/DNS/local
file canary和固定build/profile测RSS/wall-time；最终signed acceptance才覆盖iCloud、File Provider、SMB与
Quick Look。默认hover/dwell Preview必须零外部访问；需要外部file的能力只能由明确用户action进入另一
状态机。

oversized input、巨大dimensions/page/frame/attachment、压缩炸弹、cancel/timeout先用短命child记录peak RSS、
wall time、CPU、exit/crash与output bytes；在fixture、build、machine和数值profile批准前它只是
characterization，批准后才转为pass/fail Red。普通unit test只证明typed outcome，不证明native decoder
资源有界；child envelope失败时保持该route disabled，先不要把所有renderer一律进程化。

### PLAY-FORMAT-F — 每次只交付一个format的一项vertical slice

推荐固定顺序：manifest schema/source gate（非行为Red）→ 第一张真实raw/semantic/preview behavior Red →
（若承诺）exact semantic projection → real framework
Preview → resource/cancellation → no-external-I/O → error/fallback/a11y → runtime inventory → real producer/
consumer interop。某格式若本次只增加Preview，就跳过未承诺的search/edit，而不是补齐一张横向能力表。

第一条可选tracer应是exact UTF-8 text或一个已存在raw round-trip的静态图片；PDF、RTF、HTML、AV、
Quick Look分别后续领取。一个PR不得同时加入多种renderer、multi-item schema和public History read。

### PLAY-FORMAT-G — Python formats projection是只读投影

在`DEC-FORMAT-INVENTORY-OWNER`、PLAY-PY-A/C的CLI shell、Gateway injection与projection schema都批准后，Given test app/Gateway ready、Local Automation已
enrollment但没有任何content grant；Red由真实Python child向`clipyctl` stdin发送
`operation: "describeFormatCapabilities"` JSON，验证schema version、稳定排序、有条件unknown raw
fallback、declared route、runtime admission reason与evidence/resource profile。Green只消费
`DEC-FORMAT-INVENTORY-OWNER`批准的各owner-exported immutable Foundation summaries，并用独立pure serializer
投影；production不得import/reuse build/test `CapabilityInventoryTests`产物，也不复制Python UTI列表、不触发
History读取或renderer decode。真实OS runtime值
只断schema与自洽性；固定枚举/排序由PLAY-PY-C的literal pure projection测试证明。

capability JSON不含clipboard content、用户路径、query、History locator、credential或grant。它说明当前
build/OS如何处理格式，不授予content read/revise权限；Gateway在实际操作时仍以live grant、exact
content token与owner policy作authoritative recheck。

## 26. 执行区：多级 Storage、驻留与“无固定 count cap”

完整架构、当前源码盘点与Apple证据见
[`09-tiered-storage-and-unbounded-history.md`](09-tiered-storage-and-unbounded-history.md)和
[`apple-tiered-storage-source-memo.md`](apple-tiered-storage-source-memo.md)。当前实现是有严格上限的
SwiftData持久层，加完整Signature Index与局部thumbnail cache；它**不是**RAM→disk→cold archive的
多级内容系统。目标也不能写成字面“无限”：可批准的产品语义是用户可关闭固定item-count retention，
但metadata查询、content load和进程内驻留仍有界，磁盘reserve不足时以typed health暂停新capture，
不静默删除历史。

`04` 是本报告唯一执行来源；legacy Card 0…17 与新增 `PLAY-*` leaf 在领取时都必须生成唯一 issue key。
`09` 的 `DESIGN-TIER-*` 只描述设计 epic，Apple
memo 的 `MEMO-STOR-*` 只描述证据实验。执行卡 0/current correctness 恢复绿色后，characterization、
四本账与当前 SwiftData 路径测量即可领取，它们负责产生 decision-gate 证据，不要求 gate 预先存在。
purpose-read interface 需要 owning spec/target-graph 批准；blob/migration/GC 还必须由 G8/range/stream
证据触发；`count=nil` 则必须先关闭规模路径并批准产品/`HistoryLimits` surface。每一行 Red 是一个
独立 cycle，不得把 cache、blob migration、移除 5,000 上限与百万项 soak 合成一个 PR。

下列标题是**两条独立 track + 一组共享 device-health gates**，不是从上到下的必然实施顺序：

- U-scale 先做 `PLAY-STOR/PLAY-MEM/PLAY-COUNT` 四类 O(N) 与 UI window；
- current SwiftData StoreRoot 的 `PLAY-DISK-0A/0B/1/2A/3/4/5/6`（writer identity/lease、四账、reserve、真实ENOSPC、
  recovery与backup/restore）不依赖G8，且在
  解除hard count cap前必须有证据；若日后进入P3，再对blob staging/publish路径重跑扩展variant；
- pre-G8可做`PLAY-TIER-1A` characterization与首张`PLAY-TIER-2A-THUMB` caller-shape/
  aggregate-hydration tracer，
  它们负责产生G8证据且不新增History seam；`PLAY-TIER-1B`只是获批profile的pure planner；
- `PLAY-TIER-2B/3/4/5S/5P/6`、`PLAY-DISK-2B`以及blob-specific
  `PLAY-BLOB/PLAY-GC/PLAY-CRASH/PLAY-MIG/PLAY-BACKUP`
  仅在G8 + spec amendment后执行。

P3既不是解除5,000的前置，也不能抢先因为章节排在COUNT之前造BlobStore。`PLAY-SOAK-*`分别验证
两条track和shared device-health claim。

**PLAY-TIER-SPEC-0 [SPEC，非 Red] — P3 hard stop：**在修改 app-managed blob、为P3新增public/`package`
content-read seam、blob schema、migration 或 GC 前，先正式修订 `docs/v2/V2-06-platform-grafts.md`、
`V2-00`/facts、roadmap 与 AUDIT，记录旧 P3 → 新合同的 gate crosswalk；同时提交 G8 admission record，
说明是哪条 absolute SLO/range/stream 证据触发。缺任一项，所有 P3 卡均为 `BLOCKED-SPEC`/
`BLOCKED-G8`，neutral shell 也不能冒充行为 Green。

### 26.1 先分四本账，再批准 seam

| 账本 | 计量对象 | 可支持的结论 | 不能混称 |
|---|---|---|---|
| logical content | committed Canonical + revisions的稳定payload byte counts | retention、quota、用户解释 | SQLite/WAL/external blob实际盘占、RSS |
| physical disk | metadata store family、source blobs、staging/orphans、history/WAL、derived cache各自的allocated bytes | capacity reserve、GC/backup/maintenance | logical payload；删除后也不承诺立刻等量回升 |
| owned cache | Clipy明确拥有的encoded/decoded/negative entries与derived-disk artifacts | 可证明的per-owner count/byte hard budget与eviction | SwiftData、ImageIO、AppKit、filesystem cache的全部内存 |
| resident / in-flight | 已取得permit的source bytes、decoder scratch估计、leased values、whole-process RSS/dirty peak | 并发admission与固定环境下的peak/plateau证据 | 不能把`ownedCacheBytes`当进程RSS精确上限 |

同一payload可同时出现在四本账，不能相加后称“总字节”；每个metric必须带scope、unit、采样点和
owner。用户retention只改第一本账；cache eviction只改第三本账；disk health读取第二本账；第四本账
决定是否准入并发重活。任何resource receipt都必须content-free。

长期 P3 的候选package seam是类型无关的purpose read：exact immutable
representation/blob locator + content version、`purpose`、full/sequential/range shape、maximum-return
bytes、deadline/cancellation → bounded value/stream/typed failure。Storage只强制range、budget、
version fence与lease；具体behavior owner/renderer以`ClipboardFormats` stable facts、自己的
manifest与实测profile决定某个UTI和purpose需要哪些bytes。不得把裸file URL交给UI、
Python或renderer。

这个新 seam 与它的 neutral shell 都受 `PLAY-TIER-SPEC-0` + G8 阻塞；pre-G8 不先造 protocol、
DTO、actor 或 compile gate。方案 A 只在已有 purpose lane 内收窄 caller output，并如实记录
whole-aggregate hydration。若 G8 不触发，它可以与 durable candidate query/pagination 一起长期承载
many-small U-scale；不为了“更像多级”而迁移。只有range/stream或实测peak越过 G8 时，
才批准Authority-owned app-managed immutable blob tier。不能通过解析SwiftData
external-storage目录伪造reader。

### STOR — 基线、计量与当前SwiftData边界

**[PERF / characterization，均不是Red]** 固定macOS/Xcode/build/machine和versioned fixture ID，分别记录
0/200/5,000 items下browse、search、capture、details、paste、preview、R3与migration的wall time、
peak/settled RSS、dirty memory、logical bytes、各physical category、read/write bytes和file count；另用
small/near-limit blob对照scalar fetch。Characterization只保存事实，不因“还没有阈值”而失败。owner批准
某个数值envelope后，才把**一个journey的一个metric**转为独立performance Red。

以下每一行都是独立cycle：

1. **PLAY-STOR-1 [PURE] — ledger arithmetic Red：**一个literal capture只增加其committed logical payload；
   WAL、staging、thumbnail和同一bytes的resident副本都不进入`RetainedBytes`。Green只统一checked
   accounting，不引入capacity manager。
2. **PLAY-STOR-2 [MEM] — scalar-lane Red：**recent-page只返回scalars，安排的blob accessor调用次数为0。
   Green只去掉该lane的意外blob触碰；这不证明未来OS永远lazy。
3. **PLAY-STOR-3 [PERF] — context plateau Red：**在批准页数和规模下，多次keyset遍历后的quiescent RSS
   slope不超过已批准envelope。Green先切断row/context/DTO意外引用或缩页，不用私有Core Data API。
4. **PLAY-STOR-4 [PERF] — heavy-read Red：**一个near-limit item的details journey不得超过已批准peak envelope。
   Green只移除已观测到的一份无谓copy或收紧并发；range/stream需求另领TIER卡。

### MEM / LRU — permit先于hydration，cache只在本地owner内

责任按 owner 分开：clipboard-flow owner（当前`AppComposition`；只有批准后才提取concrete
`ClipboardFlow`）核算pasteboard acquisition/pending；HistoryStorage核算source
hydration/blob reads；ContentPreview与Thumbnail各自核算decoder concurrency/output。它们可复用同一套
checked reservation arithmetic或各自的小`TransientPermitPool`，但不建统一调度所有workload的global
scheduler；whole-process envelope由批准caps之和和SOAK验证。每个有实测reuse价值的owner才拥有自己的
local size-aware LRU；raw encoded cache在hit-rate/latency证据
出现前不建立，现有Preview/thumbnail owner可先领取。encoded source、decoded Preview和in-flight各用
独立budget，跨owner峰值再由后面的SOAK约束。

领取任一 `PLAY-LRU-*` 时必须在卡名/fixture中写明具体 owner、reuse trace与删除cache后的正确性oracle；
没有reuse证据时该owner的Green是“不缓存”，不得实现一个generic LRU后再寻找caller。

以下每一行都是独立cycle：

1. **PLAY-MEM-1 [PURE] — count permit Red：**active permit已达到literal count limit时，下一个request得到
   已批准的wait/reject结果，计数不越界。Green只实现count reservation。
2. **PLAY-MEM-2 [PURE] — byte permit Red：**区分`maximumReturnBytes`与昂贵操作真正会hydrate/allocate的
   reservation。方案A读取目标前可能要hydrate 128 MiB canonical aggregate + 256 MiB revision content
   （另有framing/opaque framework overhead），不能只按caller返回的小representation收费；P3后才能按
   exact representation/range source charge。已reserved + authoritative reservation越界时next不准入。
   Green只实现checked reservation，不顺便建cache。
3. **PLAY-MEM-3 [MEM] — ordering Red：**source hydration boundary在没有permit时必须不可达。Green把
   reservation移到SwiftData `Data`访问、blob read、staging allocation和decoder启动之前。
4. **PLAY-MEM-4A [MEM] — cancel release Red：**一个被取消的load实际终止后，active count/bytes回到调用前literal。
5. **PLAY-MEM-4B [MEM] — throw release Red：**source/decoder抛错后相同charge exactly-once归还。
6. **PLAY-MEM-4C [MEM] — timeout release Red：**deadline后permit持续计费到不可抢占native work真实返回，
   再exactly-once归还；不能在Task停止等待时提前退款。
7. **PLAY-MEM-4D [MEM] — early-stop release Red：**stream consumer提前停止后descriptor/chunk/output charge归零。
8. **PLAY-MEM-5 [MEM] — oversize Red：**单对象只超过cache-entry budget时可在取得transient/output permit后
   serve-without-retain；超过resident单请求budget则stream或typed reject。不得清空hot set后绕过任一
   permit。Green只加admission rule。
9. **PLAY-LRU-{OWNER}-1 [MEM] — hit Red：**同exact blob/version/range/purpose的第二次read不再触发source access。
   Green只增加这一owner的local cache。
10. **PLAY-LRU-{OWNER}-2 [MEM] — eviction Red：**容纳新entry所需空间不足时，只淘汰最老的unleased entry，且
   `ownedCacheBytes`在publish前后均不越界。不要断言private dictionary/node顺序。
11. **PLAY-LRU-{OWNER}-3 [MEM] — lease Red：**所有候选都leased时，request按批准语义wait/reject，不能淘汰仍被
   caller使用的value。Green只加入lease fence。
12. **PLAY-LRU-{OWNER}-4 [MEM] — scan pollution Red：**一次sequential full-history scan结束后，先前受保护的
   interactive hot entry仍命中。Green优先bypass/probation，不直接引入2Q/CLOCK-Pro。
13. **PLAY-LRU-{OWNER}-5 [MEM] — coherence Red：**content version或renderer recipe version变化后，旧entry绝不能
    命中。Green只把缺失的coherence component纳入exact key。
14. **PLAY-LRU-{OWNER}-6 [MEM] — pressure Red：**注入critical pressure后，所有unleased可重建entries归零。
    Green只做coalesced trim；warning、leased cancellation和真实system delivery分别另测。
15. **PLAY-LRU-{OWNER}-7 [MEM] — privacy invalidation Red：**remove/clear/content-version receipt到达相关content
    owner后，对应app-owned entry立即不再命中并释放到已批准settle状态；connection revoke只清该
    session/connection的export/read artifacts与authorization state，不清无关全局UI/thumbnail cache。只有
    OS/framework copies与secure-delete residual是best-effort。Green只接该owner-local invalidation。

`PLAY-LRU-{OWNER}-*`是minting template，不是可领取ID；例如证据批准thumbnail cache后才实例化
`PLAY-LRU-THUMB-1`。同一个generic完成状态不能被两个owners共用。

**PLAY-MEM-7 [PURE / BLOCKED-DECISION] — scheduling Red：**任务不能持有source permit再无限等待output
permit，maintenance也不能永久饥饿。先由`DEC-PERMIT-SCHEDULING`选择原子预留worst-case组合，或固定
acquisition order + no-hold-and-wait + aging；测试只锁被批准的一种。ImageIO/PDFKit内部workspace只能以
并发slot+child RSS约束，不能伪装成可精确charge的hard bytes。

Capture acquisition是例外：当前AppKit accessor可能在Storage看见request前已整体产生`Data`。先在signed
macOS上characterize provider、owner-change与copy peak；这不是Red，也不能由Storage streaming倒推已解决。
批准acquisition policy后再单独领取 **PLAY-MEM-6 [MEM]**：一个已冻结值已占满aggregate acquisition/pending
budget时，下一值必须得到可见over-budget/overload且不能进入History。Green只把conservative acquisition
permit与卡6的pending-byte账连起来；真实provider能否避免整体materialization仍只由signed evidence支持。

### TIER — purpose-specific read与app-owned blob的最小纵切

`PLAY-TIER-1A` 和首张 `PLAY-TIER-2A-THUMB` 可直接用当前layout characterization/
caller shape领取；其余卡按上面的spec/G8门逐项解除。以下每一行都是独立cycle：

1. **PLAY-TIER-1A [PLATFORM CHARACTERIZATION，非 Red]：**用具体 decoder、fixture与OS trace记录某个
   purpose实际使用header/range/full中的哪一种；不能按UTI名称预设“header-only”。
2. **PLAY-TIER-1B [PURE] — access-plan Red：**只有1A evidence profile获批后，pure planner才输出对应range、
   maximum bytes与fallback。Storage/plan test不调用decoder。
3. **`PLAY-TIER-2A-{OWNER}` [MINTING TEMPLATE，非可领取 ID]：**每个已有 purpose lane
   各自 mint concrete ID；调用者只收到该 purpose 选定的 representation，同时分开记录
   returned bytes 与当前 aggregate codecs 为筛选它而整体 hydrate 的 bytes。不能以返回值
   较小宣称按需 I/O，也不能用一个 owner 的 Green 关闭全部 purpose。
4. **PLAY-TIER-2A-THUMB [MEM] — pre-G8 first code leaf：**在已有 thumbnail source lane 中，
   构造一个 exact item/version，其 Effective Content 同时含可选 image representation 与一个较大无关
   representation。Authority 仍按当前 codec 完整 hydrate item，但 source caller 只收到被选中的
   image bytes；content-free receipt 分别报告 `returnedRepresentationBytes` 和
   `aggregateHydratedBytes`，后者覆盖本次访问的 Canonical/revision encoded aggregate 而不只是
   返回值。stale/missing 继续使用现有 typed failure，no-supported-image 仍返回 `nil`；
   不改 History Commit/
   `ChangePosition`。Green 只允许修改
   `Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift`、
   `Sources/HistoryStorage/ThumbnailService.swift`、
   `Sources/HistoryStorage/SwiftDataHistory.swift` 与新测试
   `Tests/HistoryStorageTests/ThumbnailAggregateHydrationAccountingTests.swift`；不改 `HistoryCore`、
   `Package.swift`、paste/details API、codec/layout，不加 cache/permit/BlobStore。测试同时锁定返回内容和两个
   byte counters；它是 current-layout accounting，不是 RSS 或 physical single-representation I/O proof。
5. **PLAY-TIER-2B [MEM / BLOCKED-SPEC/BLOCKED-G8] — physical range Red：**读取 literal `[offset, length]` 时，source
   instrumentation 证明实际打开/读取不超过该 range 加批准 overhead，返回量不超过 request maximum；
   只能在 representation layout/P3 gate 后领取。整块 `Data` 后再 `subdata` 仍是 Red。
6. **PLAY-TIER-3 [MEM / BLOCKED-SPEC/BLOCKED-G8] — version-fence Red：**request locator为V1而committed descriptor已是V2时返回stale，
   不返回V2或cache中的V1。Green只加authoritative fence。
7. **PLAY-TIER-4 [MEM / BLOCKED-SPEC/BLOCKED-G8] — cancellation Red：**caller取消sequential read后不再发布chunk，permit最终归零。
   Green只打通这一structured cancellation path。
8. **PLAY-TIER-5S [MEM / BLOCKED-SPEC/BLOCKED-G8] — internal sequential test-sink Red：**一个不shipping的
   bounded sink按顺序消费byte-exact chunks，reader不拼出第二份完整aggregate`Data`；它只证明base reader/
   lease contract，不授权产品export。当前paste在signed provider/ownership proof前仍是有界full-`Data` lane，
   另测permit与single-flight；不能从test sink外推paste或任意产品surface已流式化。
9. **PLAY-TIER-5P [MEM / BLOCKED-SPEC/BLOCKED-G8/BLOCKED-AUDIT] — Python streaming-sink Red：**在5S
   base reader shape之外，还必须先闭合readContent grant、audit-before-first-byte、binary stdout ownership、
   disconnect cleanup与caller output budget；不得借storage stream绕过ExternalGateway。

若 `PLAY-TIER-1A` 与 `PLAY-TIER-2A-THUMB`（或以后单独 mint 的其他 purpose leaf）的current-layout
trace证明whole hydration越过G8，且`.externalStorage`没有公开方式满足
批准的physical range/stream需求，才通过`PLAY-TIER-SPEC-0`批准app-managed blob；不能先要求2B在旧layout
通过/失败来触发它。compile、schema和source gate仍不是Red。第一张
**PLAY-TIER-6 [DISK-CHILD / BLOCKED-SPEC/BLOCKED-G8] — one-blob vertical Red**只让一次新capture写入一个representation/item；该
capture按既有语义产生恰好一次History commit。随后2B才可在新layout证明physical range：Authority发布
immutable BlobID后，public paste byte-exact。Blob store只提供
bytes，不理解PNG/PDF/RTF；SwiftData仍保存metadata/reference与唯一业务真相，不能形成第二writer。

### DISK / CRASH — device health、ENOSPC与可恢复blob协议

以下测试只在专用temp root/disposable volume运行；绝不填用户真实卷。每一行都是独立cycle：

0. **PLAY-DISK-0A [PURE/DISK-CHILD] — StoreRoot identity Red：**standardized/symlink/`..` aliases指向同一
   root时归为同一writer identity，路径逃逸拒绝；不能只比较URL字符串。
1. **PLAY-DISK-0B [DISK-CHILD] — process lease Red：**第二child在创建`ModelContainer`前被拒绝；首个owner
   退出/崩溃后fresh child可安全reacquire。该证据是process-local reservation成立的前提。
2. **PLAY-DISK-1 [PURE] — reserve classification Red：**相同logical payload下，source store、staging、
   derived cache和WAL/history的physical observations进入不同category。Green只修projection。
3. **PLAY-DISK-2A [DISK-CHILD] — current preflight Red：**capacity低于批准reserve时，current SwiftData variant必须在
   进入writable History transaction/save前返回typed capacity failure；pasteboard accessor可能已经冻结完整
   `Data`，本卡不能宣称消除该峰值。Green只加早期admission；它不能替代真实write error处理。
4. **PLAY-DISK-2B [DISK-CHILD / BLOCKED-SPEC/BLOCKED-G8] — P3 staging preflight Red：**批准P3后，
   capacity低于reserve时必须在blob staging allocation前拒绝；仍需处理preflight后的真实ENOSPC。
5. **PLAY-DISK-3 [DISK-CHILD] — cleanup priority Red：**空间不足时先删可重建DerivedCache，committed source
   item仍可读。Green只增加这一类安全cleanup，不自动删oldest history。
6. **PLAY-DISK-4 [DISK-CHILD] — ENOSPC Red：**preflight后由竞争写耗尽空间，本次capture失败；fresh child
   reopen只看到完整old History state。Green只处理真实ENOSPC rollback/health。
7. **PLAY-DISK-5 [SIGNED] — recovery Red：**释放空间并由明确用户 retry 后，signed app 从 degraded 恢复，
   失败前已确认的旧 History state 保持可读，新请求按普通 capture 语义给出明确 receipt。不要在没有
   durable request ID 的 clipboard capture 上断言跨崩溃 exactly-once；该保证只属于
   `PLAY-CRASH-7` 指定的 external/migration operation。Green 只接通该恢复 transition。
8. **PLAY-DISK-6 [DISK-CHILD / PREREQ Card16C-2] — current StoreRoot backup/restore Red：**先批准并落地
   dedicated StoreRoot ownership；owner必须完全退出或进入owning spec批准的quiesced状态，再按
   characterization得到的required-member manifest复制完整root。从fresh path恢复后，按明确
   item/reference/type/length manifest 做public byte-exact重读，
   `ChangePosition`与配置均匹配manifest；漏掉任一已枚举required member的负控制必须typed incomplete-store/
   quarantine，不能静默造空库或部分库。不得要求“只复制某个当前inline main file必然打不开”这种Apple
   未保证的结果。Green只形成current SwiftData store-family backup合同；P3落地后再以独立
   `PLAY-BACKUP-*`扩展blob generation与GC协调。

app-managed blob的协议固定为prepare/stage → validate → immutable publish → Authority DB-reference commit
→ committed-reference removal → orphan GC。下面每个kill point必须用**独立短命child Red**，不能把整张
matrix放进一个timeout test：

1. **PLAY-CRASH-1 [DISK-CHILD]：**chunk write中kill；reopen时partial staging不可见。
2. **PLAY-CRASH-2 [DISK-CHILD]：**publish后、DB commit前kill；reopen时blob是不可见orphan，只有durable
   reachability/checkpoint的bounded reconciliation证明无引用后才可清理；不得以age/grace猜测。
3. **PLAY-CRASH-3 [DISK-CHILD]：**DB transaction返回边界kill；reopen只能看到完整old或完整new commit。
4. **PLAY-CRASH-4 [DISK-CHILD]：**referenced blob缺失；受影响item/read必须fail closed为
   corrupt/missing-content，不能伪装item not found或空bytes。是否阻止整个facade发布须由owning spec另定，
   cold open不得为发现它全库扫描。
5. **PLAY-CRASH-5 [DISK-CHILD]：**remove-reference commit前kill；GC不得删除仍被committed row引用的blob。
6. **PLAY-CRASH-6 [DISK-CHILD]：**remove-reference commit后、unlink前kill；reopen后item不可见且orphan最终可删。
7. **PLAY-CRASH-7 [DISK-CHILD]：**仅对已有durable requestID/outcome marker的external或migration operation，
   response前kill后以同ID retry，业务commit总数仍恰为1。普通clipboard capture没有该identity时不得套用
   exactly-once断言。

这些只证明process-crash恢复；不把一次`SIGKILL`写成断电/device-cache flush保证。allocated blocks何时
回收先characterize；除非批准了平台/volume-specific contract，不能用“删除后容量立刻等量回升”做Red。

### GC / blob integrity（BLOCKED-SPEC / BLOCKED-G8）— 不能只靠 crash matrix 暗示完成

1. **PLAY-BLOB-1A [DISK-CHILD] — path identity Red：**root-relative no-follow open + `fstat`拒绝symlink swap、
   directory/file type、wrong owner与path escape；字符串standardize不足以Green。
2. **PLAY-BLOB-1B [DISK-CHILD] — descriptor/read integrity Red：**truncate、length mismatch、
   wrong blob ID、missing source 与 read error 均 typed fail。本卡不新增 content hash/checksum；迁移/
   publish 在本次冻结 source 仍可用时做 byte-exact staged readback，有副作用consumer在该
   validation 前不得publish。runtime不承诺自检同长 silent media corruption。
3. **PLAY-GC-1 [DISK-CHILD] — live lease race Red：**retire/remove与active open descriptor交错时，GC不删
   live reservation；consumer结束后才能进入reclaimable。
4. **PLAY-GC-2 [DISK-CHILD/PERF] — bounded enumeration Red：**每轮目录enumeration、reference query与delete
   都受count/bytes界限，namespace以shard/cursor继续，不一次构造全文件名/live-path Set。
5. **PLAY-GC-3 [DISK-CHILD] — eventual orphan Red：**publish后DB commit前留下的orphan只在durable
   ownership/checkpoint证明不可达后最终回收；grace仅延迟核对，不是正确性证据。
6. **PLAY-GC-4 [DISK-CHILD] — resumable/idempotent Red：**kill在enumerate/check/delete各边界，fresh child从
   durable cursor续跑；重复batch不删live source、不重复业务commit。

### MIG — 从opaque `Data`到blob descriptor的可恢复迁移

迁移前先批准schema version、mixed-state read precedence、checkpoint、rollback/forward-only策略与备份。
新schema/interface shell能编译不是Red。以下每一行才是独立cycle：

1. **PLAY-MIG-1 [DISK-CHILD] — one-item Red：**一个旧row做纯物理迁移后，fresh child经public paste读取
   byte-exact内容；不新增History Commit，`ChangePosition`/`ContentVersion`/logical bytes保持不变。Green
   只迁一个item shape。
2. **PLAY-MIG-2 [DISK-CHILD] — mixed-state Red：**一个已迁与一个未迁item同时存在时，两者都只能按批准
   precedence读到一份authoritative content。Green只加兼容read，不做全库切换。
3. **PLAY-MIG-3 [DISK-CHILD] — checkpoint Red：**一个bounded batch完成后kill，fresh child只从下一个
   checkpoint继续，不重复发布业务commit。Green只持久化该batch进度。
4. **PLAY-MIG-4 [DISK-CHILD] — verify-before-delete Red：**新blob的declared length与byte-exact staged readback尚未成功时，旧payload不得
   删除。Green只把旧内容cleanup移到verification之后。
5. **PLAY-MIG-5 [PERF] — migration envelope Red：**在characterization得到并批准batch RSS/IO envelope后，
   一个batch不越界。Green只调batch/read shape；不在同cycle改GC和search index。
6. **PLAY-MIG-6 [DISK-CHILD / BLOCKED-DECISION] — concurrent write/cursor Red：**先由
   `DEC-P3-MIGRATION-WRITES`选择write-new、受限dual-write或typed maintenance gate。park migration cursor后
   并发capture/revise/remove，再恢复并kill/reopen；不得留下cursor已越过却仍为旧layout的live row、两份
   authoritative bytes或漏迁item。Green只实现被批准的一种线性化/互斥合同。

### BACKUP — metadata/blob generation必须一起恢复

1. **PLAY-BACKUP-1 [DISK-CHILD] — coordinated snapshot Red：**并发capture/delete/GC/WAL activity时执行已批准
   checkpoint/export；恢复到新StoreRoot后，每个committed reference可读且没有uncommitted item可见。
   Green只实现同一generation的quiesce/manifest，不复制derived cache。
2. **PLAY-BACKUP-2 [DISK-CHILD] — incomplete family Red：**只复制主store、只复制blob或缺一个reachable source
   时，restore返回typed quarantine/recovery failure，不能补空bytes或新建空库。
3. **PLAY-BACKUP-3 [SIGNED] — policy Red：**最终Application Support/Caches布局与backup include/exclude行为符合
   已批准产品承诺；从上一正式版本restore+upgrade后逐item public bytes/OCC/position一致。

### COUNT — 移除5,000之前先消掉四类全局 O(N) 路径

不能把`hardMaximumRetainedItems`从5,000改大后称为“无限”。必须先逐类关闭：

1. dedup/startup把完整Signature Index与coverage常驻并作为ready前提；
2. capture/retention admission读取全retention inventory；
3. search构造全量`SearchCorpusSnapshot`；
4. policy sweep一次取得全inventory并对R3 victims整体推进。

下面每一行是一个独立Red；第一类刻意拆成cold-open与incoming-candidate两张卡。expected只观察批准的
访问量/resource receipt与public结果，不断言具体SQL或private collection：

- **PLAY-COUNT-1 [PERF / BLOCKED-DECISION] — cold-start Red：**先由
   `DEC-U-SCALE-STARTUP-INDEX` 做排他裁决：V2-06 P1 保持 complete checkpoint 但仅限 capped
   profile，U-scale 用 durable indexed signature-candidate query + bounded batches 取代；或者
   owning P1 本身被修订为这同一套 query/lazy-shard 合同。不得并存 complete checkpoint 和第二套
   scale index。当前 recipe-v2 全库 rebuild 也仅属于 5k capped open；U-scale 的 legacy
   projection/signature validation 必须可恢复且有界。store规模从N到10N时，ready不再同步构建全
   retained signature coverage；首次browse结果正确。fresh cold open 后第一次
   same-content capture（含forced-collision fixture）仍正确coalesce，不能用“index尚未ready”
   换取启动常数。Green只落地被批准的一种 candidate path。
- **PLAY-COUNT-1B [DISK-CHILD / BLOCKED-DECISION] — background validation Red：**bounded validator从durable cursor恢复，发现
   corrupted/missing signature projection时按批准scope fail closed；不阻塞first page，也不漏掉期间的新commit。
- **PLAY-COUNT-1C [DISK-CHILD / BLOCKED-DECISION] — unvalidated signature negative-evidence Red：**park
   background validator在一个structurally valid但与authoritative Canonical不匹配的signature row之前，再
   capture byte-identical content；由`DEC-STARTUP-VALIDATION`批准的bounded authoritative fallback或typed
   health必须阻止silent duplicate，不能把“validator尚未看见异常”当no-candidate证明。
- **PLAY-COUNT-1D [DISK-CHILD / BLOCKED-DECISION] — unvalidated aggregate negative-evidence Red：**在validator
   尚未触及一个missing/corrupt retained-count/byte projection时分别capture与revise；不得用该低估值批准
   retention或capacity结果。Green只实现`DEC-STARTUP-VALIDATION`选定的fallback/pause，不恢复cold-open全扫。
- **PLAY-COUNT-2 [PERF] — dedup Red：**捕获一个signature只有k个candidate的值时，resident/fetched candidate
   facts随k而非总N增长，forced collision仍做byte-exact确认。Green只替换完整process-wide
   postings/reverse-map是correctness前提的那条路径。另跑k=N collision/candidate-storm child：候选分批释放、
   peak有界、byte-exact不丢；wall time/typed overload按批准合同处理。不新增 secondary
   hash/checksum；现有 fingerprint 仍只产生 candidates，候选必须 byte-confirm。不能把O(k)
   宣称N-independent。
- **PLAY-COUNT-3C [PERF] — no-victim capture admission Red：**一次明确不触发淘汰的capture不得读取全部
   retained item facts。Green只用同History commit维护的persistent aggregate/indexed victim cursor满足这一行为。
- **PLAY-COUNT-3R [PERF/DISK-CHILD] — no-victim revise/remove aggregate Red：**under-budget ordinary
   revise/remove更新persistent aggregates时只触碰目标；注入commit failure/reopen后aggregate与slow oracle一致。
- **PLAY-COUNT-3CV [DISK-CHILD / BLOCKED-DECISION] — capture victim Red：**capture会触发大量count/age/R2
   victims时，先由`DEC-RETENTION-BATCH`冻结external spool+one commit或durable applying语义，再证明每批
   memory有界、protected items不删、position/receipt/reopen与最终oracle一致。
- **PLAY-COUNT-3RV [DISK-CHILD / BLOCKED-DECISION] — revise victim Red：**revise新增bytes并触发大量R2 victims
   时，按同一批准语义完成bounded enforcement；不能用3R的under-budget fixture外推。若
   `DEC-UNPIN-SWEEP`选择立即sweep，另mint unpin-victim leaf并复用该合同。
- **PLAY-COUNT-4E [PERF] — exact search Red：**固定query/page limit从N到10N时不构造N条完整body snapshot，
   ranking/cursor与literal oracle一致，cancelled旧query不阻塞新query，query→stable p95在SLO内。
- **PLAY-COUNT-4F [PERF / BLOCKED-DECISION] — fuzzy search Red：**先由`DEC-SEARCH-SCALE-SCOPE`冻结全历史或
   bounded scope，再锁同样的ranking/cancellation/p95，不用exact结果代替。
- **PLAY-COUNT-4R [PERF / BLOCKED-DECISION] — regexp search Red：**独立冻结scope、安全grammar、cooperative
   cancellation与p95；不能和fuzzy共用一个Green。
- **PLAY-COUNT-5A [DISK-CHILD / BLOCKED-DECISION] — count policy batch Red：**只覆盖count victim batch。
- **PLAY-COUNT-5B [DISK-CHILD / BLOCKED-DECISION] — age policy batch Red：**只覆盖age victim batch。
- **PLAY-COUNT-5C [DISK-CHILD / BLOCKED-DECISION] — logical-byte policy batch Red：**只覆盖R2 victim batch。
- **PLAY-COUNT-5R3 [DISK-CHILD / BLOCKED-DECISION] — revision-prune batch Red：**大量items同时超过revision
   count/bytes时，lineage按bounded item/bytes加载并只删oldest inactive revisions；active revision永不删，
   kill/reopen可恢复，peak RSS不随全部exceeding lineage总量增长。
- **PLAY-COUNT-5X [DISK-CHILD / BLOCKED-DECISION] — composed R3→R1/R2 Red：**同一policy change同时触发
   revision prune与age/logical-byte retire时，最终结果与literal slow oracle一致；post-prune bytes参与R2，
   retire-subsumes-prune不产生dangling mutation/重复position。Green只组合已批准batch合同。
- **PLAY-COUNT-5D [DISK-CHILD / BLOCKED-DECISION] — Clear scale Red：**由`DEC-CLEAR-SCALE`冻结立即可见、
    ChangePosition/receipt、batch progress、capture交错与crash/reopen语义后，Clear在大库不构造全量facts/
    delete transaction，最终结果与empty oracle一致。

3CV/3RV与5A/5B/5C/5R3/5X这些retention-victim/prune卡共同要求：fresh reopen与最终literal oracle一致。领取前先由
`DEC-RETENTION-BATCH`冻结external spool+one commit或durable applying batches、policy write、progress可见性、
ChangePosition/receipt、capture/revise/unpin交错；实现agent不得用测试私自改语义。选择batch模式时一次只推进
一个批准batch；选择one-commit模式时也必须以有界external preparation实现，不得把全部victims驻留。

四类正常路径Red与现有dedup/OCC/observation/retention correctness全绿后，才允许用test-only feature gate
进入5,001 boundary；这还不是production surface批准：

- **PLAY-COUNT-6A [PURE / TEST-ONLY / BLOCKED-PRODUCTION-SPEC] — policy surface Red：**test-only feature gate下，user
   maximum-unpinned policy/action/config能表达disabled，不用`Int.max`；production在scale gates前仍拒绝。
- **PLAY-COUNT-6B [MEM / TEST-ONLY / BLOCKED-PRODUCTION-SPEC] — global hard bound Red：**在同一test-only gate下，第5,001个
   小item不因独立`HistoryLimits.hardMaximumRetainedItems`（包含pins）被删除或拒绝。单representation、
   capture bytes、revision与disk-health safety lines仍保留。只改6A不能关闭6B。
- **PLAY-COUNT-7A [DISK-CHILD] — reopen/page Red：**超过5,000的fixture在fresh child中keyset分页可完整
   遍历；fixture矩阵必须分别含mixed、all-pinned与pinned-only请求，每页peak memory不随累计页数增长；
   all-items-same-timestamp负控制也必须只fetch
   `limit + approved overhead`，使用stable total-order cursor并满足p95，不能保留O(N) tie fallback。
- **PLAY-COUNT-7B [HOSTED] — UI window Red：**分别滚动20,000 mixed与all-pinned synthetic rows后，
   `HistoryViewState`/view只保留visible window + approved backbuffer；稳定selection可按ID重取，不能把
   storage分页绿外推为UI有界，也不能只给unpinned rows挂下一页trigger。
- **PLAY-COUNT-7C [DISK-CHILD/HOSTED] — concurrent cursor Red：**分页期间持续capture/revise/retire，
    按批准snapshot/restart语义无stale destructive action、无不可解释漏/重复页。
- **PLAY-COUNT-8A [PURE/DISK-CHILD] — pin ordinal Red：**pin/move只触碰bounded邻域或durable compaction
    batch；fresh reopen顺序与oracle一致，不因N重写全部ordinals。
- **PLAY-COUNT-8B [DISK-CHILD] — current-schema maintenance Red：**不引入P3也能在50k/250k规模完成
    current-schema restart/background validation/maintenance，RSS/temp-disk/time在批准envelope。现有V1→V2
    migration只测合法≤5k与large-lineage envelope；未来每次真实schema migration再继承scale gate，不预造
    50k旧schema fixture或speculative migration framework。
- **PLAY-COUNT-8C [AGGREGATE GATE，非 Red，不可领取] — capacity/restore prerequisite：**引用
    `PLAY-DISK-0A/0B/1/2A/3/4/5/6`与当前StoreRoot backup/reopen证据；没有这些leaf不开放production count=nil。
- **PLAY-COUNT-9A [PURE / BLOCKED-SPEC/BLOCKED-GATES] — production surface Red：**只有8C、本节全部适用
    behavior leaves与`DEC-COUNT-DISABLED/DEC-SCALE-GATES`关闭后，production public/config/persistence round-trip
    才能表达真实`count=nil`：user maximum-unpinned policy/action/config 可选，且包含 pins 的
    独立 global `hardMaximumRetainedItems` 已移除或被批准的资源安全线取代。不以`Int.max`
    伪装，也不改变单representation/capture/revision安全上限。
- **PLAY-COUNT-9B [DISK-CHILD / BLOCKED-SPEC/BLOCKED-GATES] — production behavior Red：**用production build/config
    写入5,001个small items（另跑all-pinned），fresh reopen全部可分页读取且没有因固定count constant静默retire；
    low-disk仍按shared health policy typed pause，不自动删除source history。
- **PLAY-COUNT-9C [PERF / BLOCKED-GATES] — 1m scheduled evidence：**test-only scale path在固定Release child、
    fixture与机器上完成1m cold/warm open、browse、capture/dedup、exact/fuzzy/regexp、retention/Clear、UI window
    和restart后按显式 item/reference/type/length manifest 抽样 public byte-exact 内容；每个mode
    只按`DEC-SCALE-GATES`批准的SLO/范围判定。它不进每PR，也不把1m写成无限。

8C聚合的全部适用non-aggregate `PLAY-COUNT-1…8` leaves、shared
`PLAY-DISK-0A/0B/1/2A/3/4/5/6`、5,001功能边界、`DEC-SCALE-GATES`要求的各级scale/backup headroom及适用
`PLAY-SOAK-*`先闭合；9C再关闭1m scheduled/release evidence，随后才可领取9A/9B完成production transition。
较低scale可供内部开发与诊断，但不能先开放production `count=nil`。P3仍不是默认前置。某search mode、policy或journey
只有owning spec明确从production承诺移除时才能记`N/A`，实现agent不得自行跳过失败卡。

以 5,001 boundary 先验证语义；50k、250k 与 1M 是递进的 scheduled/nightly 或 release-candidate
evidence，**不进入每个 PR**。
功能PR用小limits、5,001 boundary或synthetic access counter证明单一行为；规模lane只验证组合resource
claim。即使1M通过，也只能写“该build/机器/fixture支持1M”，不能写字面无限。

### SOAK — 跨owner峰值与长期plateau

先characterize代表性混合workload；它不是Red。固定并公布capture mix、format/size分布、browse/search/
preview/paste比例、retention/migration是否并发、duration、build、machine和versioned fixture ID。批准envelope后，
以下每一行才成为独立cycle：

1. **PLAY-SOAK-1 [PERF] — quiescent Red：**一轮混合负载停止并等待批准settle window后，active permits归零。
2. **PLAY-SOAK-2 [PERF] — cache Red：**整个run中每个local owned-cache ledger都不越各自hard budget。
3. **PLAY-SOAK-3 [PERF] — plateau Red：**重复固定轮次后quiescent RSS/dirty slope不超过批准envelope。
4. **PLAY-SOAK-4 [PERF] — durability Red：**soak child正常退出后，fresh child的public IDs/positions与
byte-exact payload fixture同成功receipt manifest一致。
5. **PLAY-SOAK-5 [SIGNED] — product journey Red：**distribution形态在memory pressure + low disk + panel activity
   的一个批准组合下给出可见health、保持旧history可读且不崩溃。

SOAK不替代每张PURE/MEM/DISK-CHILD correctness卡，也不以单个thumbnail cache的64 MiB断言whole-app
有界。performance failure只授权修已越界的owner/path；没有证据时不先落global scheduler、复杂2Q、
常驻全文索引或第二业务writer。
