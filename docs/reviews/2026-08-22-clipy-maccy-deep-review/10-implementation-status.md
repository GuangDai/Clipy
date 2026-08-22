# REVIEW 实现状态账本

> 读者：后续实现、审查与验证 agent。目的不是重述 findings，而是回答“这个 observable behavior
> 是否已经落入 production、由什么证据支持、还缺哪一层”。本文件是 REVIEW 中唯一活状态账本；
> `04-tdd-remediation-playbook.md` 仍是唯一执行卡来源，owning spec 仍高于 REVIEW。

## 1. 状态规则

- **Done**：production path 已合并，相关 correctness CI 绿色，且下表明确写出证据支持上限。
- **Partial**：已合并但只完成一个 leaf、pure/model 层或 source wiring；不得外推为整张 Card 完成。
- **In progress**：仅存在于当前未合并分支/工作树，不是产品能力；合并且 CI 绿后才可改 Done。
- **Open / Blocked**：尚未实现，或仍需 owning-spec/decision/evidence gate。

更新规则：每个 PR 只改自己实际改变的行；必须链接 production source、behavior test 和 CI/PR。
不得以 agent 回报、源码存在、compile success 或 pure helper 单独证明完整产品行为；不得记录源码 hash、
工作树 hash或生成物 checksum。

为避免仅更新账本而重复触发 CI，当前实现 PR 先记 **In progress**；合并且 correctness CI 绿色后，
由下一次正常实现 PR 将上一批晋升为 Done/Partial 并补 PR/CI 证据。晋升前的 In progress 已足以阻止
重复领取，不为状态文字单独发起 CI。

## 2. 已验证合并基线

| 批次 | 状态 | 直接证据 | 支持 | 不支持 |
|---|---|---|---|---|
| CI correctness/performance 拆分 | Done | [PR #2](https://github.com/GuangDai/Clipy/pull/2)，[correctness CI](https://github.com/GuangDai/Clipy/actions/runs/32559563353) | push/PR 只运行 source、SwiftPM functional、app build/test；perf/AB/exact/scale workflows 无 caller | 不证明性能或 release acceptance |
| 正常路径 correctness batch 2 | Done | [PR #3](https://github.com/GuangDai/Clipy/pull/3)，[correctness CI](https://github.com/GuangDai/Clipy/actions/runs/32562731920) | 三个 correctness jobs 全绿；未运行 perf/AB | 下表标为 Partial/Open 的 hosted、purge、signed/runtime 项 |

## 3. 正常路径 leaf 状态

| Card / finding | 状态 | Production 证据 | Behavior 证据 | 支持上限 / 下一步 |
|---|---|---|---|---|
| Card 3A Keep Current / Use Original / empty Replace | Done | [`ReviseEditorDraft`](../../../Sources/PresentationUI/ReviseEditorDraft.swift)，[`ReviseEditorView`](../../../Sources/PresentationUI/ReviseEditorView.swift) | [`ReviseEditorDraftTests`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift#L13) | 证明 draft→request 与 View wiring；actual hosted control 仍属 3C |
| Card 3B stale draft | Partial | stale 不再 dismiss/覆盖 draft；见 [`ReviseEditorView`](../../../Sources/PresentationUI/ReviseEditorView.swift) | [`dirtyDraftKeepsOpeningReferenceAndLiteralReplacementBytes`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift#L141) | 显式 Reload/Rebase recovery 在 batch 3 中 In progress，尚未合并 |
| Card 3C dirty Cancel/Esc | Partial | Cancel 与 `.cancelAction` 共用 dismissal intent | [`ReviseEditorDraftTests`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift) | pure draft与source wiring已证；真实 alert/button/Esc hosted journey 未闭合 |
| Card 7 / CLIP-5 exclusive copy lane | Done | [`AppComposition.requestPaste`](../../../ClipyApp/Sources/AppComposition.swift#L289) 一个 active、零 pending、stop fence | [`AppPasteOrchestrationTests`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppPasteOrchestrationTests.swift) | private pasteboard/app path；不证明 General Pasteboard 跨进程或 signed runtime |
| Card 7 / CLIP-6 complete-item staging | Done | [`PasteboardAdapter.write`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift) 先 stage 一个 item，再 clear + 单次 `writeObjects` | [`wholeItemWriteRefusalSurfacesFailureWithoutClosing`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppPasteOrchestrationTests.swift#L310) 及 adapter tests | staging failure 保留旧板；final refusal 是 post-clear 且不承诺 rollback/atomicity |
| DATA-6 outer observation buffer | Done | [`SwiftDataHistory.observe`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L346) 使用 newest(1) | [`pausedObserverResumesAtNewestAuthoritativeSnapshot`](../../../Tests/HistoryStorageTests/ObservationBufferingTests.swift#L14) | 证明 public snapshot stream coalescing；不等于全进程 RSS bound |
| Card 8A query phase / stale rows | Done | [`HistoryViewState.isLoadingFirstPage`](../../../Sources/PresentationUI/HistoryViewState.swift#L53)；query intent同步清旧rows | [`queryEditImmediatelyHidesOldRowsUntilReplacementPage`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L496) | model/production source成立；actual TextField hosted journey另列 8G |
| Card 8B overall/pinned pagination trigger | Partial | [`HistoryListPaginationTrigger`](../../../Sources/PresentationUI/HistoryListView.swift#L18) 挂在所有row | [`HistoryListPaginationTriggerTests`](../../../Tests/PresentationUITests/HistoryListPaginationTriggerTests.swift#L10) | pure trigger已证；actual scroll/onAppear hosted sentinel 未闭合 |
| Card 8D pagination lifecycle | Done | owned pagination Task + monotonic token；见 [`HistoryViewState`](../../../Sources/PresentationUI/HistoryViewState.swift) | [`deactivateInvalidatesNonCooperativePagination`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L316)、[`stalePaginationCannotAppendOrClearNewerRequestSpinner`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L412) | non-cooperative test double覆盖迟到completion；不证明Storage native cancellation |
| Card 8E raw exact/regexp | Done | exact/regexp draft不trim | [`syntaxBearingQueriesPreserveRawWhitespace`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L620) | Presentation→History request bytes；不证明匹配器结果语义 |
| Card 8F fuzzy atomic admission | Done | raw draft保留，fuzzy只取admitted prefix | [`longExactToFuzzyIsOneAtomicAdmittedIntent`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L661) | 一次mode switch request；不证明Fuse性能 |
| Card 8G visible Clear/autocorrection | Partial | [`SearchHeaderView`](../../../Sources/PresentationUI/SearchHeaderView.swift)、[`clearSearch`](../../../Sources/PresentationUI/HistoryViewState.swift#L221) | view-state immediate recent test | actual NSHostingView control在batch 3 In progress；系统Full Keyboard Access仍Open |
| Card 8H failure episode | Done | [`failureEpisode`](../../../Sources/PresentationUI/HistoryViewState.swift#L62) + source-aware clear；banner按episode dismiss | [`repeatedMutationFailurePublishesANewEpisodeAfterRecovery`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L857) | model与production banner wiring；系统 VoiceOver announcement仍Open |
| Card 9A exact preview reference | Partial | observation-derived exact reference、loader generation/reference fence、mismatch settle | [`sameIDVersionRetargetInvalidatesOldContentBeforePublishingNew`](../../../Tests/PresentationUITests/PreviewContentLoaderTests.swift#L169) | loader/state已证；完整 observed-row→hosted render journey未闭合 |
| Card 9C/9F preview side + main anchor | Partial | shared [`PreviewPlacement`](../../../Sources/PresentationUI/HistoryPanelView.swift#L19) 同时驱动SwiftUI列顺序与AppKit frame | [`previewAtRightEdgeOpensLeadingWithoutMovingTheMainSurface`](../../../ClipyApp/Tests/ClipyIntegrationTests/PanelAndHotKeyTests.swift#L141) | production wiring+pure geometry；单进程hosted NSPanel/AX frames在batch 3 In progress，多屏/Spaces/hot-plug仍Open |
| Card 9E panel session | Done | [`PreviewPaneState.panelClosed`](../../../Sources/PresentationUI/PreviewPaneState.swift#L119)保持auto-open disarmed | [`panelClosedDisarmsAutoOpenUntilThePanelBecomesKeyAgain`](../../../Tests/PresentationUITests/PreviewPaneStateTests.swift#L110) | state lifecycle；不证明WindowServer事件顺序 |
| App lifecycle duplicate activate | Done | `HistoryViewState.activate` 对同一owned observation幂等 | [`repeatedActivateKeepsOneObservationUntilDeactivated`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L84) | 防双注册；不替代真实panel lifecycle hosted test |
| SwiftData managed CloudKit disabled | Done（implementation） | persistent与memory config均显式 [`cloudKitDatabase: .none`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L158) | correctness CI compile | 证明源码配置；Apple未提供稳定public runtime introspection，本表不声称签名产物entitlement matrix已验证 |

## 4. Batch 3 当前工作（未合并，不得当作 Done）

| Leaf | 状态 | 独占 owner scope | 合并前必须证明 |
|---|---|---|---|
| Card 9B thumbnail purge generation | In progress | `ThumbnailStore` + its tests | reset后迟到flight不复活；新generation可重新请求 |
| Card 9D unsupported vs retryable failed | In progress | `HistoryPreviewView` + Preview tests | unsupported无Retry；failed retry成功且exact fence不退化 |
| TYPE-2 Preview text codec safety | In progress | `HistoryPreviewView` + Preview tests | exact UTF-8/native UTF-16；structured/abstract/unspecified types不误解码；不等于RTF/HTML renderer或全局format module |
| TYPE-2 Details text safety | In progress | `HistoryDetailsView` + Details format tests | exact UTF-8显示；其余metadata-only；不等于hosted row/title或全局format module |
| Card 3B explicit stale Reload Latest | In progress | Revise draft/view/tests | draft bytes保留；base更新；失败不覆盖draft |
| Card 6 bounded capture lane | In progress | `AppComposition` + app capture tests | one active + latest pending；replacement可见；typed failure不静默 |
| Card 5C concealed-before-bytes | In progress | `PasteboardAdapter` + tests | marker存在时payload accessor调用0 |
| CLIP-7 multi-item short-term rejection | In progress | `PasteboardAdapter` + tests；composition health source wiring | item count>1在读取bytes前显式unsupported，不截断first、不flatten；只报告不支持，不是multi-item持久化/replay |
| Card 8G hosted search controls | In progress | `SearchHeaderView` + hosted app test | actual control输入不改syntax；Clear触发recent |
| Card 9C/9F hosted panel frames | In progress | `HistoryPanelView`/`FloatingPanel` + hosted app test | actual column order与main frame invariance |
| Position singleton existing-value validation | In progress | `HistoryAuthority` + startup test | invalid stored count在publish前typed fail且零repair |
| Retention config singleton existing-value validation | In progress | existing production decoder + [`RetentionConfigSingletonStartupValidationTests`](../../../Tests/HistoryStorageTests/RetentionConfigSingletonStartupValidationTests.swift) | same-process persistent public-open下，correct-key非法scalar/version在publish前typed fail且零repair；true restart与missing/wrong-key classifier仍Open |
| Signature aggregate bound | In progress | `SignatureBlobCodec` + tests | per-entry合法但aggregate越界必须拒绝 |
| DATA-2 RetainedBytes relational scalars | In progress | `RetentionConfigLoading` + relational tests | capture/revise/policy planning拒绝不可能scalar且不进transaction；startup及blob逐项cross-check仍Open |
| WS13/transaction projection exactness | In progress | transaction proof tests | failure后成功前四类持久行逐字段、完整Signature Index值与零invalidation不变；forced collision再做行为控制 |
| Row accessibility actions | In progress | `HistoryRowView` + hosted accessibility test | actual AX default/named handlers存在并调用production row callbacks；不证明AppComposition/History journey、FKA或label质量 |
| TYPE-2 editor codec safety | In progress | Revise draft/view/tests | 仅exact UTF-8允许Replace；structured/abstract/UTF-16不产生错标bytes |
| Card 6 capture health presentation | In progress | `AppComposition`/`AppDelegate`/panel + app tests | overload/failure content-free notice state与source wiring；dismiss不抑制下一episode；hosted banner/control仍待证 |

## 5. 明确仍 Open，禁止误报完成

- Card 9B 的完整 destructive purge：Clear/remove/revise receipt、details path、selection、Preview、所有
  owner-local cache与迟到结果 fence尚未整体闭环。
- Card 5D：DEBUG-public failure knobs 尚未迁到更窄 internal boundary。
- Card 6B：low-disk/ENOSPC capture health 未实现。
- Card 3D、Card 9D hosted Retry/no-Retry control、localization、VoiceOver/FKA、custom shortcut、signed release、StoreRoot/recovery、
  Python/Gateway、format modules与tiered/unbounded storage仍按 `04`/`07`–`09` 的 gates执行。
- DATA-1 missing/wrong-key singleton classifier与DATA-11 Canonical↔Signature双向coverage仍Open；本批的
  existing-value与aggregate-byte leaf不得外推为整项完成。
- `AppComposition` 的capture lane已形成独立调度责任；只有 deletion test 证明 locality 改善时才提取
  app-internal concrete `CaptureLane`，不得先造protocol/bus。Preview/Details/Edit目前重复的codec facts则
  留给已批准的format-facts模块统一；owner-specific admission仍必须分开，不能造中央policy开关。
- 本文件中的“Done”只关闭所列 leaf；不能据此宣称 state 3、全面超过 Maccy 或字面无限历史。

## 6. Agent 领取前检查

1. 先查本表：Done leaf 不得重做；Partial 只能领取“支持上限/下一步”列中的缺口。
2. 再查 `04` 的唯一 leaf 与 decision/spec gate；没有唯一 observable behavior 就不编码。
3. Red 必须穿过表中列出的 production seam，expected来自literal/spec，不复制implementation。
4. 合并前保持 In progress；PR合并且 correctness CI 绿后，由下一次正常实现PR把相应行改为
   Done/Partial并附证据，不为账本状态单独触发CI。
5. 若实现改变本表已记录的支持上限，必须在同一 PR 更新本表；不要在其他 REVIEW 文件另造第二份状态。
