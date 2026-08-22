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
| 正常路径 correctness batch 3 | Done | [PR #4](https://github.com/GuangDai/Clipy/pull/4)，[correctness CI](https://github.com/GuangDai/Clipy/actions/runs/32565262175) | 三个 correctness jobs 全绿；覆盖下表列出的 capture、preview、storage 与 presentation leaves；未运行 perf/AB | 不证明 AX/WindowServer runtime、完整 destructive purge、全局格式模块或整项 DATA-1/DATA-2/DATA-11 |
| 正常路径 correctness batch 4 | Done | [PR #5](https://github.com/GuangDai/Clipy/pull/5)，[correctness CI](https://github.com/GuangDai/Clipy/actions/runs/32568061992) | 三个 correctness jobs 全绿；覆盖 receipt purge、singleton shape、revision ID、transaction aftermath 与 DEBUG seam leaves；未运行 perf/AB | Card 9B 与 DATA-1 仍仅 Partial；不证明 authoritative all-commit purge、signed/runtime 或完整 test-instrumentation audit |
| 正常路径 correctness batch 5 | Done | [PR #6](https://github.com/GuangDai/Clipy/pull/6)，[correctness CI](https://github.com/GuangDai/Clipy/actions/runs/32570362335) | 三个 correctness jobs 全绿；覆盖 projection recipe v2/rebuild、backfill signature coverage、startup scalar validation、capture change-count fence、relative-time refresh 与三进程 restart leaves；未运行 perf/AB | DATA-2、DATA-11 与 Card 5B 仍仅 Partial；不证明 hosted/signed runtime、通用 migration、性能或完整 crash durability |

## 3. 正常路径 leaf 状态

| Card / finding | 状态 | Production 证据 | Behavior 证据 | 支持上限 / 下一步 |
|---|---|---|---|---|
| Card 3A Keep Current / Use Original / empty Replace | Done | [`ReviseEditorDraft`](../../../Sources/PresentationUI/ReviseEditorDraft.swift)，[`ReviseEditorView`](../../../Sources/PresentationUI/ReviseEditorView.swift) | [`ReviseEditorDraftTests`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift#L13) | 证明 draft→request 与 View wiring；actual hosted control 仍属 3C |
| Card 3B stale draft | Partial | stale 不再 dismiss/覆盖 draft，且 [`ReviseEditorView`](../../../Sources/PresentationUI/ReviseEditorView.swift) 接入 Reload Latest | [`staleDraftCannotSubmitAgainAndKeepsLiteralReplacementBytes`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift#L162)、[`reloadLatestAdvancesBaseAndPreservesAuthoredEditableBytes`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift#L184) | draft/rebase与source wiring已证；真实 stale alert、Reload control、失败恢复 journey 尚未闭合 |
| Card 3C dirty Cancel/Esc | Partial | Cancel 与 `.cancelAction` 共用 dismissal intent | [`ReviseEditorDraftTests`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift) | pure draft与source wiring已证；真实 alert/button/Esc hosted journey 未闭合 |
| Card 7 / CLIP-5 exclusive copy lane | Done | [`AppComposition.requestPaste`](../../../ClipyApp/Sources/AppComposition.swift#L289) 一个 active、零 pending、stop fence | [`AppPasteOrchestrationTests`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppPasteOrchestrationTests.swift) | private pasteboard/app path；不证明 General Pasteboard 跨进程或 signed runtime |
| Card 7 / CLIP-6 complete-item staging | Done | [`PasteboardAdapter.write`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift) 先 stage 一个 item，再 clear + 单次 `writeObjects` | [`wholeItemWriteRefusalSurfacesFailureWithoutClosing`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppPasteOrchestrationTests.swift#L310) 及 adapter tests | staging failure 保留旧板；final refusal 是 post-clear 且不承诺 rollback/atomicity |
| DATA-6 outer observation buffer | Done | [`SwiftDataHistory.observe`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L346) 使用 newest(1) | [`pausedObserverResumesAtNewestAuthoritativeSnapshot`](../../../Tests/HistoryStorageTests/ObservationBufferingTests.swift#L14) | 证明 public snapshot stream coalescing；不等于全进程 RSS bound |
| Card 8A query phase / stale rows | Done | [`HistoryViewState.isLoadingFirstPage`](../../../Sources/PresentationUI/HistoryViewState.swift#L53)；query intent同步清旧rows | [`queryEditImmediatelyHidesOldRowsUntilReplacementPage`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L496) | model/production source成立；actual TextField hosted journey另列 8G |
| Card 8B overall/pinned pagination trigger | Partial | [`HistoryListPaginationTrigger`](../../../Sources/PresentationUI/HistoryListView.swift#L18) 挂在所有row | [`HistoryListPaginationTriggerTests`](../../../Tests/PresentationUITests/HistoryListPaginationTriggerTests.swift#L10) | pure trigger已证；actual scroll/onAppear hosted sentinel 未闭合 |
| Card 8D pagination lifecycle | Done | owned pagination Task + monotonic token；见 [`HistoryViewState`](../../../Sources/PresentationUI/HistoryViewState.swift) | [`deactivateInvalidatesNonCooperativePagination`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L316)、[`stalePaginationCannotAppendOrClearNewerRequestSpinner`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L412) | non-cooperative test double覆盖迟到completion；不证明Storage native cancellation |
| Card 8E raw exact/regexp | Done | exact/regexp draft不trim | [`syntaxBearingQueriesPreserveRawWhitespace`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L620) | Presentation→History request bytes；不证明匹配器结果语义 |
| Card 8F fuzzy atomic admission | Done | raw draft保留，fuzzy只取admitted prefix | [`longExactToFuzzyIsOneAtomicAdmittedIntent`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L661) | 一次mode switch request；不证明Fuse性能 |
| Card 8G visible Clear/autocorrection | Partial | [`SearchHeaderView`](../../../Sources/PresentationUI/SearchHeaderView.swift) 接入 field/Clear stable AX ID、关闭 autocorrection；[`clearSearch`](../../../Sources/PresentationUI/HistoryViewState.swift#L221) | view-state immediate recent test + app correctness compile | source identity与clear intent已证；headless CI不暴露SwiftUI AX controls，真实control/FKA仍Open |
| Card 8H failure episode | Done | [`failureEpisode`](../../../Sources/PresentationUI/HistoryViewState.swift#L62) + source-aware clear；banner按episode dismiss | [`repeatedMutationFailurePublishesANewEpisodeAfterRecovery`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L857) | model与production banner wiring；系统 VoiceOver announcement仍Open |
| Card 9A exact preview reference | Partial | observation-derived exact reference、loader generation/reference fence、mismatch settle | [`sameIDVersionRetargetInvalidatesOldContentBeforePublishingNew`](../../../Tests/PresentationUITests/PreviewContentLoaderTests.swift#L169) | loader/state已证；完整 observed-row→hosted render journey未闭合 |
| Card 9C/9F preview side + main anchor | Partial | shared [`PreviewPlacement`](../../../Sources/PresentationUI/HistoryPanelView.swift#L19) 同时驱动SwiftUI列顺序与AppKit frame | [`previewAtRightEdgeOpensLeadingWithoutMovingTheMainSurface`](../../../ClipyApp/Tests/ClipyIntegrationTests/PanelAndHotKeyTests.swift#L141) | production wiring+pure geometry；headless CI不提供SwiftUI AX frame oracle，真实NSPanel/多屏/Spaces/hot-plug仍Open |
| Card 9E panel session | Done | [`PreviewPaneState.panelClosed`](../../../Sources/PresentationUI/PreviewPaneState.swift#L119)保持auto-open disarmed | [`panelClosedDisarmsAutoOpenUntilThePanelBecomesKeyAgain`](../../../Tests/PresentationUITests/PreviewPaneStateTests.swift#L110) | state lifecycle；不证明WindowServer事件顺序 |
| App lifecycle duplicate activate | Done | `HistoryViewState.activate` 对同一owned observation幂等 | [`repeatedActivateKeepsOneObservationUntilDeactivated`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L84) | 防双注册；不替代真实panel lifecycle hosted test |
| SwiftData managed CloudKit disabled | Done（implementation） | persistent与memory config均显式 [`cloudKitDatabase: .none`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L158) | correctness CI compile | 证明源码配置；Apple未提供稳定public runtime introspection，本表不声称签名产物entitlement matrix已验证 |

## 4. Batch 3 已合并 leaf 状态

以下状态只覆盖 [PR #4](https://github.com/GuangDai/Clipy/pull/4) 经
[correctness CI](https://github.com/GuangDai/Clipy/actions/runs/32565262175) 验证的边界；Card 或
finding 的其余缺口仍以“支持上限”列和第 6 节为准。

| Leaf | 状态 | Production 证据 | Behavior 证据 | 支持上限 / 下一步 |
|---|---|---|---|---|
| Card 9B thumbnail purge generation | Partial | [`ThumbnailStore.reset`](../../../Sources/PresentationUI/ThumbnailStore.swift#L206) 递增 owner-local generation并同步释放旧entry/flight | [`resetInvalidatesEveryLateOutcomeAndAllowsSameReferenceRefetch`](../../../Tests/PresentationUITests/ThumbnailStoreTests.swift#L167) | 证明单一ThumbnailStore reset后旧flight不能复活且同reference可重取；未连接Clear/remove/revise receipt与所有owner，完整destructive purge仍Open |
| Card 9D unsupported vs retryable failed | Partial | [`PreviewContentLoader.Phase`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L174) 分离unsupported/failed，Retry仅重跑当前exact reference | [`transientFailureRetriesTheSameReferenceAndClearsFailure`](../../../Tests/PresentationUITests/PreviewContentLoaderTests.swift#L208)、[`structuredTextWithoutPlainSiblingIsUnsupportedAndNotRetryable`](../../../Tests/PresentationUITests/PreviewContentLoaderTests.swift#L260) | loader phase与SwiftUI source wiring已证；真实Retry/no-Retry控件、键盘与AX journey未闭合 |
| TYPE-2 Preview text codec safety | Done | [`PreviewContent.resolve`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L47) 只按exact UTF-8/native UTF-16 contract解码并优先plain sibling | [`PreviewContentTests`](../../../Tests/PresentationUITests/PreviewContentTests.swift)、[`supportedTextDecodeFailureIsRetryable`](../../../Tests/PresentationUITests/PreviewContentLoaderTests.swift#L327) | 证明Preview resolver不会把RTF/HTML/abstract text误作UTF-8；不提供RTF/HTML renderer，也不等于全局format module |
| TYPE-2 Details text safety | Done | [`DetailsRepresentationPresentation.resolve`](../../../Sources/PresentationUI/HistoryDetailsView.swift#L666) 只为exact UTF-8生成文本，其余metadata-only | [`HistoryDetailsFormatSafetyTests`](../../../Tests/PresentationUITests/HistoryDetailsFormatSafetyTests.swift) | 证明Details owner的presentation decision；不证明hosted row/title，不提供structured renderer或全局format module |
| Card 3B explicit stale Reload Latest | Partial | [`ReviseEditorDraft.reloadLatest`](../../../Sources/PresentationUI/ReviseEditorDraft.swift#L136) 保留authored bytes并推进base；[`ReviseEditorView`](../../../Sources/PresentationUI/ReviseEditorView.swift#L397) 接入reload | [`reloadLatestAdvancesBaseAndPreservesAuthoredEditableBytes`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift#L184)、[`reloadConflictPreservesEntireAuthoredDraftAndOldBase`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift#L312) | draft/rebase与失败不覆盖已证；真实stale提示、Reload control及焦点journey仍Open |
| Card 6 bounded capture lane | Done | [`AppComposition`](../../../ClipyApp/Sources/AppComposition.swift#L399) 只保留one active + replaceable latest pending，并发布content-free health | [`activeCaptureKeepsOnlyTheLatestPendingValue`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppCaptureLaneTests.swift#L22)、[`stopPreventsANonCooperativeCompletionFromDrainingPendingWork`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppCaptureLaneTests.swift#L97) | 证明composition owner的有界调度、replacement与stop fence；不等于低磁盘处理或全进程内存证明 |
| Card 5C concealed-before-bytes | Done | [`PasteboardAdapter.captureOutcome`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L137) 在payload accessor前检查concealment marker | [`declaredConcealmentMarkerShortCircuitsBeforeReadingLargeSiblingPayload`](../../../Tests/PasteboardAdapterTests/PasteboardAdapterTests.swift#L166) | 证明声明marker的单item路径payload read为0；不声称识别未声明或未来私有marker |
| CLIP-7 multi-item short-term rejection | Done | [`PasteboardAdapter.captureOutcome`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L137) 对item count > 1返回显式unsupported shape；composition转成content-free failure | [`multipleItemsAreExplicitlyUnsupportedBeforeAnyPayloadRead`](../../../Tests/PasteboardAdapterTests/PasteboardAdapterTests.swift#L117)、[`multiItemClipboardPublishesContentFreeUnsupportedShape`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppCaptureLaneTests.swift#L271) | 证明不读bytes、不截断first、不flatten；这是显式短期拒绝，不是multi-item持久化/replay支持 |
| Card 8G search accessibility identity | Partial | [`SearchHeaderView`](../../../Sources/PresentationUI/SearchHeaderView.swift) 为field/Clear设置stable AX ID并关闭autocorrection | app correctness compile | 只证明production source与类型检查；headless runner未暴露SwiftUI AX control，真实AX/FKA journey仍Open |
| Position singleton existing-value validation | Done | [`HistoryAuthority.ensurePositionSingleton`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L412) 在后续startup publish前解码已有row | [`PositionSingletonStartupValidationTests`](../../../Tests/HistoryStorageTests/PositionSingletonStartupValidationTests.swift) | persistent public-open下证明越界值typed fail且零repair、合法值不被initial覆盖；不外推到其他singleton classifier |
| Retention config singleton existing-value validation | Done | production existing-row decoder由 [`HistoryAuthority`](../../../Sources/HistoryStorage/HistoryAuthority.swift) startup调用 | [`RetentionConfigSingletonStartupValidationTests`](../../../Tests/HistoryStorageTests/RetentionConfigSingletonStartupValidationTests.swift) | same-process persistent public-open下证明correct-key非法scalar/version在publish前typed fail且零repair；true restart与missing/wrong-key classifier仍Open |
| Signature aggregate bound | Done | [`SignatureBlobV1.decode`](../../../Sources/HistoryStorage/SignatureBlobCodec.swift) checked累计entry byteCount并应用capture总量上限 | [`decodeRejectsAggregateByteCountAboveCaptureBound`](../../../Tests/HistoryStorageTests/SignatureBlobCodecTests.swift#L274)、boundary与overflow fixtures同文件 | 证明codec aggregate bound；不证明每个Canonical↔Signature读取路径都执行双向coverage校验 |
| DATA-2 RetainedBytes relational scalars | Partial | [`RetentionConfigLoading`](../../../Sources/HistoryStorage/RetentionConfigLoading.swift) 在planning前拒绝不可能的count/byte关系 | [`RetainedBytesRelationalValidationTests`](../../../Tests/HistoryStorageTests/RetainedBytesRelationalValidationTests.swift) | capture/revise/policy入口拒绝且不进transaction已证；startup与blob逐项cross-check仍Open |
| WS13/transaction projection exactness | Done | [`HistoryAuthority`](../../../Sources/HistoryStorage/HistoryAuthority.swift) 仍以单一transaction commit并在成功后更新projection/index | [`injectedClosureFailureCommitsNothingAndLeavesStoreAndIndexConsistent`](../../../Tests/HistoryStorageTests/WS13TransactionFailureTests.swift#L25)、[`TransactionBoundaryProofTests`](../../../Tests/HistoryStorageTests/TransactionBoundaryProofTests.swift) | 证明注入failure后成功前持久rows、position、config、Signature Index与invalidation不变，并以forced collision作行为控制；不证明任意系统级崩溃点 |
| Row accessibility actions | Partial | [`HistoryRowView`](../../../Sources/PresentationUI/HistoryRowView.swift#L69) 提供per-ID AX identity、default Copy及Pin/Unpin/Show Details/Remove具名action | app correctness compile | 只证明source wiring与编译；没有可用的SwiftUI AX tree/WindowServer hosted证据，runtime handler、FKA与label质量仍Open |
| TYPE-2 editor codec safety | Done | [`ReviseEditorDraft`](../../../Sources/PresentationUI/ReviseEditorDraft.swift#L286) 只允许exact `public.utf8-plain-text`进入Replace | [`onlyExactUTF8PlainTextOffersLiteralReplacement`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift#L376)、[`unsupportedFormatsRejectProgrammaticReplaceIntent`](../../../Tests/PresentationUITests/ReviseEditorDraftTests.swift#L430) | 证明draft/request不会把structured/abstract/UTF-16 bytes错标为UTF-8 replacement；真实编辑控件仍属Card 3B/3C hosted gate |
| Card 6 capture health presentation | Partial | [`AppComposition`](../../../ClipyApp/Sources/AppComposition.swift) 发布content-free episode state；[`AppDelegate`](../../../ClipyApp/Sources/AppDelegate.swift#L213) 与 [`PanelRootView`](../../../ClipyApp/Sources/Panel/PanelRootView.swift#L155) 接入notice/dismiss | [`olderSuccessCannotClearANewerFailureEpisode`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppCaptureLaneTests.swift#L227)、unsupported/unavailable/concealed fixtures同文件 | 证明health episode语义与presentation source wiring；真实banner/dismiss control、AX announcement及low-disk recovery仍Open |

## 5. Batch 4 已合并 leaf 状态

以下状态只覆盖 [PR #5](https://github.com/GuangDai/Clipy/pull/5) 经
[correctness CI](https://github.com/GuangDai/Clipy/actions/runs/32568061992) 验证的边界；Card 或 finding
的其余缺口仍以“支持上限”列和第 7 节为准。

| Leaf | 当前状态 | Production 证据 | Behavior 证据 | 合并后的最高支持上限 |
|---|---|---|---|---|
| Card 9B receipt-confirmed surface purge | Partial | [`HistoryViewState`](../../../Sources/PresentationUI/HistoryViewState.swift) 只从committed Remove/Clear/Revise receipt发布typed purge；[`HistoryPanelSurfaceState`](../../../Sources/PresentationUI/HistoryPanelView.swift#L73)、[`PreviewPaneState`](../../../Sources/PresentationUI/PreviewPaneState.swift#L139)、[`ThumbnailStore`](../../../Sources/PresentationUI/ThumbnailStore.swift#L220) 与 [`HistoryDetailsLoadFence`](../../../Sources/PresentationUI/HistoryDetailsView.swift#L20) 各自清理owner-local state并fence迟到结果 | [`clearPublishesWholeSurfacePurgeOnlyAfterCommittedReceipt`](../../../Tests/PresentationUITests/HistoryViewStateTests.swift#L856)、[`receiptFirstRevisionRetargetsPreviewAndPurgesOldExactState`](../../../Tests/PresentationUITests/PreviewSelectionReconciliationTests.swift#L105)、[`exactPurgeFencesLateTargetWithoutInvalidatingUnrelatedFlight`](../../../Tests/PresentationUITests/ThumbnailStoreTests.swift#L241)、[`HistoryDetailsPurgeTests`](../../../Tests/PresentationUITests/HistoryDetailsPurgeTests.swift) | 只证明同一panel surface内、由该ViewState发起的Remove/Clear/Revise在receipt后的rows/navigation/selection/preview/thumbnail/details清理与迟到completion fence；capture与retention-policy commit可能产生的淘汰尚无authoritative purge owner，跨window、多panel及未来cache也未证明 |
| Card 5D DEBUG public knobs narrowing | Done（指定 leaf） | [`PasteboardAdapter`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift) 把mutable public failure switches收窄为DEBUG-only immutable package fixture；[`AppComposition`](../../../ClipyApp/Sources/AppComposition.swift) 只保留app-private typed result seam | [`PasteboardAdapterTests`](../../../Tests/PasteboardAdapterTests/PasteboardAdapterTests.swift)、[`AppPasteOrchestrationTests`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppPasteOrchestrationTests.swift)、[`AppCaptureLaneTests`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppCaptureLaneTests.swift) | 证明这组pasteboard/capture failure knobs不再属于public product API，Release不含声明；不声称所有测试instrumentation都已审计或完成signed-symbol检查 |
| DATA-3 duplicate RevisionID planner guard | Done | [`planRevision`](../../../Sources/HistoryDomain/PlannersPinRevision.swift#L258) 在append前拒绝已存在于完整lineage的candidate ID；[`02 §11`](../../02-domain.md#11-revise-planning) 同步planner contract | [`revisionPlannerRejectsCandidateIDAlreadyInTheItemLineage`](../../../Tests/HistoryDomainTests/RevisionPlannerInvariantTests.swift#L126) | 证明pure planner对注入duplicate candidate fail-closed且不产出plan；不证明UUID随机源碰撞概率，也不替代Storage/codec已有lineage validation |
| DATA-1 unambiguous singleton startup shapes | Partial | [`ensurePositionSingleton`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L404) 扫描完整position table并只允许fresh-compatible缺失；[`ensureRetentionExpansionConfig`](../../../Sources/HistoryStorage/HistoryAuthority+RetentionBootstrap.swift#L165) 不再把wrong-key config误作absence | [`nonFreshSingletonCorruptionIsRejectedWithoutDurableMutation`](../../../Tests/HistoryStorageTests/SingletonShapeStartupClassifierTests.swift#L208) 通过persistent public reopen覆盖missing-position、wrong/extra position与wrong/extra config且比较前后durable values | 只关闭可区分shape。仍有两个因果歧义：① 合法V1→V2迁移后待bootstrap的missing config与既有V2删除config同形；② fresh empty store与已clear且两个singleton均被删除的V2 store同形。没有durable provenance时不得猜测原因，DATA-1仍Partial |
| Card 2D / WS13 public browse/details aftermath | Done（指定 leaf） | transaction owner仍是 [`HistoryAuthority`](../../../Sources/HistoryStorage/HistoryAuthority.swift)；failure后的oracle改走production [`SwiftDataHistory`](../../../Sources/HistoryStorage/SwiftDataHistory.swift) public facade | [`injectedClosureFailureCommitsNothingAndLeavesStoreAndIndexConsistent`](../../../Tests/HistoryStorageTests/WS13TransactionFailureTests.swift#L26)、[`injectedFailureBeforeSingletonUpdateCommitsNeitherRowsNorPosition`](../../../Tests/HistoryStorageTests/TransactionBoundaryProofTests.swift#L87) 在任何成功修复前核对public browse/details/notFound | 证明注入transaction failure后public reads仍精确返回pre-attempt state；failure injection本身仍是`@testable` Authority seam，不是无注入的端到端系统崩溃证明 |

## 6. Batch 5 已合并 leaf 状态

以下状态只覆盖 [PR #6](https://github.com/GuangDai/Clipy/pull/6) 经
[correctness CI](https://github.com/GuangDai/Clipy/actions/runs/32570362335) 验证的边界；Card 或 finding
的其余缺口仍以“合并后的最高支持上限”列和第 8 节为准。

| Leaf | 当前状态 | Production 证据 | Behavior 证据 | 合并后的最高支持上限 |
|---|---|---|---|---|
| Projection recipe v2 + startup rebuild | Done | [`ContentProjector`](../../../Sources/HistoryStorage/ContentProjector.swift) 只投影exact plain codecs；[`ContentProjectionRebuild`](../../../Sources/HistoryStorage/ContentProjectionRebuild.swift) 在facade发布前把legacy tag 1原子重建为2；owning [`05 §15`](../../05-authority-kernel.md#15-projection-rules) 已批准 | [`ProjectionRecipeV2RebuildTests`](../../../Tests/HistoryStorageTests/ProjectionRecipeV2RebuildTests.swift) 覆盖active revision、mixed v1/v2、unknown tag、坏revision source与transaction rollback | 证明现有5,000 hard bound内的recipe-v1→v2 derived projection重建；不改SwiftData schema/ContentVersion/ChangePosition，不提供通用migration framework或RSS/perf证明 |
| DATA-11 migration/backfill signature coverage | Partial | [`RetainedBytesBackfill`](../../../Sources/HistoryStorage/RetainedBytesBackfill.swift) 在写projection前用已解码Canonical执行双向signature coverage | [`RetainedBytesBackfillTests`](../../../Tests/HistoryStorageTests/RetainedBytesBackfillTests.swift) 用独立literal oracle覆盖missing/extra type、wrong fingerprint/byteCount与forced collision | 关闭migration/backfill coverage leaf；startup/rebuild的Signature Index负证据contract仍Open，不能外推为整个DATA-11完成 |
| DATA-2 startup relational scalars | Partial | [`ValidatedRetainedBytesScalars`](../../../Sources/HistoryStorage/RetentionConfigLoading.swift) 被startup correspondence与planning共用；startup保持scalar-only | [`reopenFailsClosedOnImpossibleScalar`](../../../Tests/HistoryStorageTests/RetainedBytesScalarValidationTests.swift) 覆盖完整非法scalar矩阵并比较durable snapshot | 关闭public reopen的version/bound/relation验证；正常startup不逐blob equality，R3 exceeding-item piggyback cross-check仍Open |
| Card 5B capture change-count fence | Partial | [`PasteboardAdapter.captureOutcome`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift) 记录start/end `changeCount`并在变化时丢弃已读bytes；[`AppComposition`](../../../ClipyApp/Sources/AppComposition.swift) 在capture lane前拒绝 | [`pasteboardChangeBetweenRepresentationReadsProducesContentFreeRetryOutcome`](../../../Tests/PasteboardAdapterTests/PasteboardAdapterTests.swift) 与complete-convenience control | 精确证明adapter seam不发布跨generation partial；composition为源码接线+correctness compile。`CaptureOutcome`仍是optionals record，observer bounded-retry与hosted exact-outcome仍Open |
| Relative-time shared refresh | Done | [`HistoryListView`](../../../Sources/PresentationUI/HistoryListView.swift) 用一个minute cadence向所有[`HistoryRowView`](../../../Sources/PresentationUI/HistoryRowView.swift)传显式`now` | [`HistoryRowRenderingTests`](../../../Tests/PresentationUITests/HistoryRowRenderingTests.swift) 无sleep验证literal 59秒→1分钟变化 | 证明单list共享刷新与deterministic formatting；无逐row timer/全局clock，不证明WindowServer后台调度 |
| Evidence Card 1C-1 true V2 restart | Done | [`HistoryRestartProbe`](../../../Sources/HistoryRestartProbe/HistoryRestartProbe.swift) 三个短生命周期进程只经public History API共享一个StoreRoot，并用纯文本UUID manifest核对业务ID | [`TrueRestartChildTests`](../../../Tests/HistoryStorageTests/TrueRestartChildTests.swift) 驱动seed→operate→verify；B/C分别核对browse/details ID，B另核对coalesce receipt ID | 只证明普通V2三进程重启、公开业务ID/rows/details/position一致；不证明V1→V2 migration、SIGKILL、断电、externalStorage durability或独立schema inspector |

## 7. Batch 6 current work（unmerged）

以下代码、测试、workflow与规格修订只存在于当前工作树；合并且对应 evidence lane 全绿前一律保持
**In progress**。

| Leaf | 当前状态 | Production / owning 证据 | Behavior 证据 | 合并后的最高支持上限 |
|---|---|---|---|---|
| Card 9B authoritative retention-effect purge | In progress（合并后整体仍Partial） | package-only `HistoryCommit.hasDestructiveRetentionEffects` 由既有retire/prune plan推导；[`AppComposition`](../../../ClipyApp/Sources/AppComposition.swift)把capture receipt转交[`HistoryViewState`](../../../Sources/PresentationUI/HistoryViewState.swift) | [`captureRetentionReceiptPurgesSurfaceBeforeObservationCatchesUp`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppCaptureLaneTests.swift) 与policy/revise receipt fixtures | 关闭单AppComposition/ViewState内capture与retention-policy同commit破坏的authoritative whole-surface purge；跨window/多panel/未来cache仍未证明 |
| Card 6B typed ENOSPC + explicit capture retry | In progress（合并后仍Partial） | [`PersistenceErrorClassification`](../../../Sources/HistoryStorage/PersistenceErrorClassification.swift) 只识别direct Cocoa/POSIX及一层underlying；transaction rollback映射typed failure；App capture失败丢pending且只接受新observation重试 | [`PersistenceErrorClassificationTests`](../../../Tests/HistoryStorageTests/PersistenceErrorClassificationTests.swift)、[`TransactionBoundaryProofTests`](../../../Tests/HistoryStorageTests/TransactionBoundaryProofTests.swift)、[`lowDiskFailureDropsPendingUntilANewCaptureExplicitlyRetries`](../../../ClipyApp/Tests/ClipyIntegrationTests/AppCaptureLaneTests.swift) | 证明合成但穿过production transaction catch的ENOSPC、rollback、content-free health和显式retry；真实APFS满盘、open/migration、Developer ID环境恢复仍Open |
| DATA-2 R3 hydrated-lineage cross-check | In progress（合并后整体仍Partial） | [`RetentionPolicySweep`](../../../Sources/HistoryStorage/RetentionPolicySweep.swift) 只对scalar已判R3 exceeding且已经hydrate的item核对canonical/count/revision bytes | [`RetainedBytesR3CrosscheckTests`](../../../Tests/HistoryStorageTests/RetainedBytesR3CrosscheckTests.swift) | 关闭R3 exceeding piggyback leaf；普通startup与non-exceeding item仍不逐blob equality，不能外推为全库扫描 |
| ClipboardFormats stable-facts module | In progress | package-only Foundation target [`ClipboardFormats`](../../../Sources/ClipboardFormats/StableFormatFacts.swift)；Projection/Preview/Details/Edit各自保留purpose admission | [`StableFormatFactsTests`](../../../Tests/ClipboardFormatsTests/StableFormatFactsTests.swift) 及各owner回归 | 只统一exact identifier与declared codec facts；不是registry/plugin/中央policy/decoder/runtime capability inventory |
| PLAY-PY-GW0 closed allow matrix | In progress | [`ExternalGatewayTypes`](../../../Sources/HistoryCore/ExternalGatewayTypes.swift) + pure [`ExternalAccessPolicy`](../../../Sources/HistoryStorage/ExternalAccessPolicy.swift) | [`ExternalAccessPolicyTests`](../../../Tests/HistoryStorageTests/ExternalAccessPolicyTests.swift) 覆盖2×8×15组合与unknown raw | 只冻结connection-kind/capability/operation classification；没有credential、Gateway actor/schema/audit/App Intents/CLI/socket |
| Python/Gateway + U-scale/P3 spec unblock | In progress（docs decision leaf） | [`V2-05`](../../v2/V2-05-external-gateway.md)、[`07`](07-python-local-automation.md)、[`09`](09-tiered-storage-and-unbounded-history.md) 与owning roadmap已冻结顺序/分轨 | decision/PLAY ID与链接机械检查 | GW0已由本批实现；下一Gateway实现层是X.2 public contract，tier首叶为pre-G8 `PLAY-TIER-2A-THUMB`；authenticated ingress、runtime format injection、production count transition、P3 amendment仍BLOCKED/OPEN |
| SIGNED-RUNTIME-0 manual lane | In progress（需workflow实跑） | workflow-dispatch-only [`signed-runtime.yml`](../../../.github/workflows/signed-runtime.yml) 与单次Release build脚本 [`run_signed_runtime.sh`](../../../scripts/ci/run_signed_runtime.sh) | 合并后手动run才可提供macOS codesign/runtime证据 | 只承诺ad-hoc signature、Hardened Runtime flag、entitlement negative gate与直接process liveness；Developer ID/notary/staple/Gatekeeper/TCC/WindowServer仍Open |

## 8. 明确仍 Open，禁止误报完成

- Card 9B 即使Batch 6合并也只关闭单AppComposition/ViewState内capture、policy、Clear/remove/revise
  receipt路径；跨window/多panel、未来cache以及不经该owner的commit仍Open。
- Card 5D 指定的pasteboard failure knobs已迁到更窄DEBUG/internal边界；完整Release/signed symbol与
  其余test instrumentation审计仍Open。
- Card 5B 仍缺closed exhaustive freeze result、observer bounded-retry与hosted exact-outcome；Batch 5
  只关闭start/end `changeCount` fence与complete-convenience rejection。
- Card 6B 仍缺真实bounded-volume/APFS ENOSPC、open/migration与发行身份环境恢复；Batch 6不能把
  synthetic production-catch proof外推为物理磁盘验收。
- Card 3D、Card 9D hosted Retry/no-Retry control、localization、VoiceOver/FKA、custom shortcut、signed release、StoreRoot/recovery、
  Gateway后续层、format runtime/manifests与tiered/unbounded production transition仍按 `04`/`07`–`09` 的 gates执行。
- DATA-1 的两个不可区分因果shape仍Open；DATA-11 的startup/rebuild Signature Index
  负证据contract仍Open。本批的
  singleton可区分shape、existing-value与aggregate-byte leaf不得外推为整项完成。
- `AppComposition` 的capture lane已形成独立调度责任；只有 deletion test 证明 locality 改善时才提取
  app-internal concrete `CaptureLane`，不得先造protocol/bus。Preview/Details/Edit目前重复的codec facts则
  留给已批准的format-facts模块统一；owner-specific admission仍必须分开，不能造中央policy开关。
- 本文件中的“Done”只关闭所列 leaf；不能据此宣称 state 3、全面超过 Maccy 或字面无限历史。

## 9. Agent 领取前检查

1. 先查本表：Done leaf 不得重做；Partial 只能领取“支持上限/下一步”列中的缺口。
2. 再查 `04` 的唯一 leaf 与 decision/spec gate；没有唯一 observable behavior 就不编码。
3. Red 必须穿过表中列出的 production seam，expected来自literal/spec，不复制implementation。
4. 合并前保持 In progress；PR合并且 correctness CI 绿后，由下一次正常实现PR把相应行改为
   Done/Partial并附证据，不为账本状态单独触发CI。
5. 若实现改变本表已记录的支持上限，必须在同一 PR 更新本表；不要在其他 REVIEW 文件另造第二份状态。
