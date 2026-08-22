# Apple 平台一手资料备忘录：Clipy / Maccy 深度审计

> 目的：只解决本轮代码审查中会改变实现建议的 Apple 平台不确定项。本文不是
> 完整产品 review，也不把一次 CI 成功、Maccy 的既有行为或社区惯例升级成 Apple
> 契约。
>
> Apple 资料访问日期：**2026-08-22 (UTC)**。
>
> Clipy 快照：`codex/v2-implementation@cda2ba0a4a25264ce7855ee5ae71ef60b8252501`
>（取证前工作树 clean）。
>
> Maccy 对照快照：`master@818f03d0e0d3912e1ea23657e2630902ebf5cc8b`；
> Maccy 工作树只有文档类 overlay，本文引用的 production Swift、project、workflow
> 与脚本没有未提交修改。
>
> 环境边界：本轮在 Linux 上做静态源码核对并查阅 Apple Developer Documentation、
> HIG、WWDC transcript、Apple Support Platform Security 与 Apple Developer Forums
> 中标明身份的 Frameworks/DTS Engineer 回复；**没有**在 macOS 26 真机上重新运行
> TCC、Spaces、VoiceOver、焦点、签名、公证或 ImageIO Instruments 实验。因此下面
> 每项都明确区分 `DOC`、`CODE/INFERENCE` 与 `UNKNOWN`。

## 0. 先纠正旧审计的时效性

2026-08-20 的报告不能原样搬入新 review。当前代码已经完成四个有意义的修正：

1. pasteboard write 的每个 `Bool` 已被检查，失败会阻止 panel 关闭；见
   [`PasteboardAdapter.swift:173-215`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L173-L215)
   与
   [`AppComposition.swift:227-251`](../../../ClipyApp/Sources/AppComposition.swift#L227-L251)。
2. Settings 入口已从私有 selector 改成公开 `OpenSettingsAction`；见
   [`PanelRootView.swift:19-42`](../../../ClipyApp/Sources/Panel/PanelRootView.swift#L19-L42)。
3. alert 检测不再匹配 `_NSAlertPanel` 私有类名，而使用 `modalWindow` / `attachedSheet`；
   见
   [`FloatingPanel.swift:219-235`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L219-L235)。
4. Clipy 的 storage thumbnail 与 full preview 都已使用 HEIF primary-image index；见
   [`ThumbnailService.swift:281-295`](../../../Sources/HistoryStorage/ThumbnailService.swift#L281-L295)
   与
   [`DisplayImageDecoder.swift:64-75`](../../../Sources/PresentationUI/DisplayImageDecoder.swift#L64-L75)。

但这些修正没有关闭 pasteboard privacy、poll loss、panel focus、SMAppService 四态、
accessibility、shipping 等问题；而 ImageIO 又暴露出一个更细的新边界：创建
`CGImage` 不等于已经在后台完成像素解码。

## 1. 结论速览

| ID | 判定 | 对当前建议的影响 |
|---|---|---|
| `APL-PB-PRIVACY` | **confirmed product gap / P0** | 必须把 `NSPasteboard.AccessBehavior` 建模为产品状态；不能把 deny/prompt/retrieval error 显示成“clipboard empty” |
| `APL-PB-LOSS` | **confirmed overclaim / P0** | `changeCount + Timer` 只能做 best-effort latest-state polling，不能承诺逐 copy、逐 count 无损 |
| `APL-PB-THREAD` | **unknown + measured-risk / P0** | Apple 没有明确保证 `NSPasteboard` / `NSPasteboardItem` 可放普通 actor；当前同步读取在 MainActor，lazy provider 等待或大 payload materialization 一旦变慢就占用 UI |
| `APL-PB-SNAPSHOT` | **confirmed model gap / P1** | `pasteboardItems == nil` 是 retrieval error；first-item-only 是产品裁剪，不是 General pasteboard 标准形状 |
| `APL-PB-WRITE` | **partially repaired / P1** | 错误传播已修；但 destructive clear 后逐 representation 写仍可能留下 partial subset，Apple 没有给原子事务保证 |
| `APL-PANEL` | **partly aligned, focus unknown / P1** | nonactivating 只保证不激活 owner app；不保证原 target/first responder 精确保存或恢复；`.stationary` 会让敏感 panel 留在 Mission Control |
| `APL-EVENT-MONITOR` | **not used by Clipy; comparator caveat** | 不要照搬 Maccy local monitor 当全局/无损输入机制；nested tracking loops 会绕过 local monitor |
| `APL-CARBON` | **pragmatic but undocumented / P1** | 当前 Apple 没有现代 symbol-level availability/thread/TCC 契约；可保留窄 wrapper，但必须有 runtime proof、冲突 UX 与可配置快捷键 |
| `APL-LOGIN` | **confirmed state-loss / P1** | `SMAppService.Status` 四态被压成 Bool，错误被吞；需 `.requiresApproval` 与 System Settings 恢复入口 |
| `APL-SETTINGS` | **public API repair accepted; activation unknown / P2** | 保留 `OpenSettingsAction`；`NSApp.activate()` 是 request 而非成功保证，LSUIElement/Space 行为需实测 |
| `APL-IMAGE` | **substantially improved, lazy-decode proof missing / P1** | primary-index handling 优于该 Maccy 快照，actor confinement 方向合理；但 `CreateImageAtIndex(..., nil)` 可把实际 decode 推迟到 render |
| `APL-A11Y-HIG` | **release evidence absent / P0** | 默认 ⇧⌘C 冲突系统 Colors shortcut；context-only actions 和零 VoiceOver/FKA proof 不能算 product complete |
| `APL-SHIP` | **release blocker / P0** | Clipy 没有 Release signing/notarization/update lane；此 Maccy fork 的 release 也是明确 unsigned，不能作为达标基准 |

---

## 2. NSPasteboard privacy：四态是产品状态，不是内部细节

### Apple 公开事实（DOC）

- [`NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)
  与
  [`accessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-86972)
  自 macOS 15.4 起提供 `.default`、`.ask`、`.alwaysAllow`、`.alwaysDeny`。
- [`.default`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/default)
  对 General pasteboard 的程序化访问默认是 ask；首次触发 access alert 后转成
  `.ask` 并出现在对应 System Settings pane。
- [`.ask`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/ask)
  会询问；[`.alwaysDeny`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/alwaysdeny)
  会自动拒绝。不过 Apple 明确保留“同时由用户发起且与 paste 相关”的访问豁免。
  后台 clipboard-history polling 不能自行宣称属于该豁免。
- Apple 的 [April 2025 AppKit update](https://developer.apple.com/documentation/updates/appkit)
  说明 pasteboard privacy alert 针对没有 paste-related user intent 的 General pasteboard
  程序化读取；新的 detect APIs 可在不实际读取内容、不通知用户的情况下检查有限模式/
  metadata。
- [`detectedMetadata(for:)`](https://developer.apple.com/documentation/appkit/nspasteboard/detectedmetadata(for:))
  只开放有限 metadata（示例是第一 item 中 file reference 的 content type），并明确
  **不提供 contents**。它不是 history capture 的替代品。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE）

- Clipy production 默认绑定 `.general`，读取 `pasteboardItems`，然后同步读取第一 item
  的每个 representation：
  [`PasteboardAdapter.swift:42-65`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L42-L65)、
  [`PasteboardAdapter.swift:115-156`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L115-L156)。
- observer 启动时立刻读取已有 clipboard，此后 0.5 秒 polling：
  [`PasteboardObserver.swift:29-73`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L29-L73)。
  composition 在 store open 后马上启动 observer：
  [`AppComposition.swift:126-165`](../../../ClipyApp/Sources/AppComposition.swift#L126-L165)。
- `rg 'accessBehavior|detectedMetadata|detectedPatterns' Sources ClipyApp` 无结果。
- Maccy 也直接持有 `.general` 并同步 snapshot；同样没有 `accessBehavior`：
  [Maccy `Clipboard.swift:33-74`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Clipboard.swift#L33-L74)、
  [`Clipboard.swift:199-229`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Clipboard.swift#L199-L229)、
  [`PasteboardSource.swift:65-90`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Ingest/PasteboardSource.swift#L65-L90)。

### 支持上限 / UNKNOWN

- Apple 公开了状态语义，但没有在上述页面承诺 macOS 26 每个 build 的**精确 prompt
  时机**、alert 与 LSUIElement panel 的相对层级、被拒后 `pasteboardItems`/item data
  的具体返回形状；本轮查到的 NSPasteboard pages 也没有提供类似
  `SMAppService.openSystemSettingsLoginItems()` 的 pasteboard-pane opener。
- `changeCount`、`types` 或 detect API 是否在每个隐私状态都不触发 alert，必须逐 API
  真机记录；不能从“没有 payload bytes”自行外推。
- Apple 没有发布一个可据此添加的 macOS pasteboard usage-description Info.plist key；
  不应凭空发明。

### 审查建议

1. **P0：在启动 observer 之前完成一次可理解的 onboarding/enable-history 决策。** 展示
   Clipy 为什么需要后台读取、数据只在本机、如何暂停；然后读取并持续反映
   `accessBehavior`。
2. UI 至少区分 `notYetPrompted/default`、`ask`、`allowed`、`denied`、`readFailure`、
   `pausedByUser`。`.requires user action` 不能伪装成 empty history。
3. `.alwaysDeny`/连续读取失败时停止 payload polling 或显著降频，并给出手工恢复说明；
   在没有查到公开 pane opener 的前提下，不要使用未文档化
   `x-apple.systempreferences:` URL。
4. detect APIs 可用于低侵入 onboarding/预检，但它们只给有限 metadata，不能被包装成
   “可无提示完整捕获”。
5. 在 clean macOS 26 VM 做四态矩阵：冷启动已有内容、后台 copy、panel 内明确 copy、
   切换 System Settings、重启、login launch；记录 API 返回值、prompt 与可恢复 UX。

---

## 3. `changeCount` + Timer：只能发现“现在不同”，不能找回中间内容

### Apple 公开事实（DOC）

- [`NSPasteboard.changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)
  在 pasteboard ownership 每次改变时递增；Apple 给出的用途是记录自己取得 ownership
  时的值，稍后比较是否仍有 ownership。它不是 payload log、notification stream 或
  历史读取 API。
- [`Timer`](https://developer.apple.com/documentation/foundation/timer) 明确不是 real-time
  mechanism。run loop 忙、处于不监听该 timer 的 mode、或 callout 太长时会延迟；若
  错过多个 repeating fire，只补一次，不补齐每个 tick。
- [`RunLoop.Mode.common`](https://developer.apple.com/documentation/foundation/runloop/mode/common)
  是包含若干 mode 的 pseudo-mode，不是“永不延迟”。
- [`Timer.tolerance`](https://developer.apple.com/documentation/foundation/timer/tolerance)
  允许系统在 scheduled date 之后的窗口内合并 wakeups；Apple 的
  [Energy Efficiency Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
  给 repeating timer 的一般建议是至少约 10% interval tolerance，并要求用 Energy
  gauge / Activity Monitor 验证。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE/INFERENCE）

- Clipy 只保存一个 `lastChangeCount`。若两个 tick 之间从 10 跳到 12，只会对 count 12
  的**当前** pasteboard freeze 一次；count 11 的 payload 已不可恢复：
  [`PasteboardObserver.swift:23-35`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L23-L35)、
  [`PasteboardObserver.swift:84-93`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L84-L93)。
- “one outcome/capture per distinct change count” 的注释超过实现与 Apple 契约：
  [`PasteboardObserver.swift:18-20`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L18-L20)、
  [`PasteboardObserver.swift:40-47`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L40-L47)、
  [`AppComposition.swift:192-201`](../../../ClipyApp/Sources/AppComposition.swift#L192-L201)。
- Clipy timer 是 `.common`、0.5 s、zero explicit tolerance：
  [`PasteboardObserver.swift:29-35`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L29-L35)、
  [`PasteboardObserver.swift:67-73`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L67-L73)。
- Maccy 同样只能读取 latest state，但它至少把 interval floor 设为 0.1 s、显式使用
  `.common` 并给 10% tolerance：
  [Maccy `Clipboard.swift:60-83`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Clipboard.swift#L60-L83)、
  [`Clipboard.swift:199-207`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Clipboard.swift#L199-L207)。

### 支持上限 / UNKNOWN

- Apple 没有为 AppKit General pasteboard 发布逐 change notification，也没有 API 以旧
  `changeCount` 取回历史 payload。因此调短 interval 只能降低概率，不能建立无损保证。
- `.common` 在当前 AppKit 配置实际包含哪些 modes、sleep/wake、fast-user-switch、menu
  tracking 与 modal presentation 下延迟多大，是 runtime measurement。

### 审查建议

1. 把所有 spec/comment/product copy 改成 **best-effort latest-state polling**；只承诺
   “观察到改变后尽快捕获当前值”。
2. 在本地 proof harness 中记录 count jump（只记差值和时间，不记敏感内容）。
   `delta > 1` 只证明两次 poll 之间发生了多个 ownership transitions，因而存在中间
   retainable payload 被错过的可能；它不证明每个 transition 都来自用户 copy，也不应
   变成 production telemetry。perf/reliability gate 必须能看到这种风险窗口。
3. 设置明确 latency/energy budget 后再决定 interval；至少测 0.1/0.25/0.5 s 与 10%
   tolerance，而不是把 0 tolerance 当作可靠性增强。
4. proof：500 ms 内 2/5/20 次独立 writer、main-thread 100/500/1500 ms stall、modal、
   menu tracking、drag、sleep/wake。验收应报告 loss/latency distribution，不能断言零丢失。

---

## 4. 读取、lazy provider、multi-item 与线程：当前 MainActor 有正确性理由，也有 UI 风险

### Apple 公开事实（DOC）

- [`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard) 明确可以
  包含多个 item。
- [`pasteboardItems`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboarditems)
  在 retrieval error 时返回 `nil`。所以 `nil` 不能由调用者证明为“空 clipboard”。
- [`NSPasteboardItem`](https://developer.apple.com/documentation/appkit/nspasteboarditem)
  只在一次 pasteboard interaction 中有效；ownership 改变后 item stale，其方法返回
  empty array、`nil` 或 `false`。
- [`NSPasteboardItemDataProvider`](https://developer.apple.com/documentation/appkit/nspasteboarditemdataprovider)
  允许 item 用 `setDataProvider(_:forTypes:)` 承诺 lazy data；系统需要某 type 时调用同步
  `pasteboard(_:item:provideDataForType:)` callback。公开 API 没有 cancellation token、
  deadline 或 async completion 参数。
- item-level
  [`NSPasteboardItem.data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboarditem/data(fortype:))
  的当前 symbol page只承诺返回 optional data。它没有把每个 `nil` 精确分类为 timeout、
  ownership race、privacy denial 或 corrupt provider。
- pasteboard-level
  [`NSPasteboard.data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/data(fortype:))
  的 discussion 会把 `nil` 与 contents changed / provider timeout 联系起来；但 Clipy 实际
  调用的是上面的 **item-level** method，不能把另一个 receiver 的详细 failure prose
  无条件移植过来。
- Apple 的已归档
  [Thread Safety Summary](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html)
  只给 AppKit 一般规则：部分 class 可在非主线程串行使用，明确 main-only 的 class 会被
  点名；但它**没有点名 `NSPasteboard` 或 `NSPasteboardItem` 为 thread-safe、main-only
  或 background-safe**。当前 symbol pages 也没有给这两个类型线程/actor 语义。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE/INFERENCE）

- Clipy 只 freeze `.first`，把 first item 称为 General pasteboard “standard shape”：
  [`PasteboardAdapter.swift:82-94`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L82-L94)、
  [`PasteboardAdapter.swift:115-142`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L115-L142)。
  Apple 的 multi-item 模型不支持“standard shape”作为保证。
- `pasteboardItems == nil` 与 truly empty 最终都变成 `captureOutcome == nil`，没有 typed
  retrieval failure：
  [`PasteboardAdapter.swift:109-116`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L109-L116)。
- Clipy 会记录 declared-but-unavailable type 并在 composition seam 丢弃 partial freeze；
  方向比 Maccy 静默删 representation 更保守：
  [`PasteboardAdapter.swift:119-156`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L119-L156)、
  [`AppComposition.swift:195-213`](../../../ClipyApp/Sources/AppComposition.swift#L195-L213)。
- 但多处注释把 **pasteboard-level** `data(forType:)` 的 timeout/changed-content 解释直接
  套到实际调用的 **item-level** API；Apple 当前 item page不支持该精确归因：
  [`PasteboardAdapter.swift:24-32`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L24-L32)、
  [`PasteboardAdapter.swift:47-52`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L47-L52)、
  [`PasteboardAdapter.swift:87-94`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L87-L94)。
- adapter、observer 和同步 `item.data(forType:)` loop 全部 `@MainActor`：
  [`PasteboardAdapter.swift:14-22`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L14-L22)、
  [`PasteboardAdapter.swift:40-45`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L40-L45)、
  [`PasteboardObserver.swift:18-27`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L18-L27)。
  这避免把 non-`Sendable` AppKit references 跨 actor，但也意味着 provider/materialization
  的全部同步 latency 占用 UI executor。
- storage admission 最终会拒绝单 representation >64 MiB 或总 capture >128 MiB，见
  [`Limits.swift:23-30`](../../../Sources/HistoryCore/Limits.swift#L23-L30) 与
  [`IngestPreparation.swift:155-201`](../../../Sources/HistoryStorage/IngestPreparation.swift#L155-L201)；
  但这些检查发生在 adapter 已经同步取得全部 `Data` **之后**。adapter 没有可在
  `item.data(forType:)` 前获知/限制 payload bytes 的机制，所以 MainActor freeze 的
  pre-admission materialization 本身没有由 128 MiB cap 约束。
- Maccy materialize **所有** items，但每个 `nil` representation 被静默省略：
  [Maccy `PasteboardSource.swift:53-90`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Ingest/PasteboardSource.swift#L53-L90)。

### 支持上限 / UNKNOWN

- 没有 Apple 一手资料足以批准“把同一个 `NSPasteboard` reference 放进普通 Swift
  actor”。普通 actor 只保证互斥，不保证固定 OS thread；类型又不是 `Sendable`。
- 同样，没有资料证明必须 MainActor。也就是说，当前选择是**保守的 strict-concurrency
  confinement**，不是 Apple 明文要求。
- lazy provider 是否超时、timeout 多久、callback 在哪个 process/thread、privacy prompt
  等待是否阻塞本次 item read，公开页面没有完整保证。唯一可确定的是调用面是同步、无
  caller-provided cancellation/deadline，所以 bounded latency 未被证明。

### 审查建议

1. **不要把“dedicated actor”写成现成修复。** 它既不证明 background thread，也无法
   合法跨越 non-`Sendable` 引用。先保留 MainActor confinement 的 correctness posture，
   但删除“因此性能安全”的暗示。
2. 把 freeze outcome 扩成可诊断但不泄露内容的类别：`empty`、`retrievalFailed`、
   `staleDuringRead`、`incompleteRepresentations`、`accessDeniedOrUnavailable`（最后一项只有
   在能结合 `accessBehavior` 时才细分）。
3. freeze 前后读取 `changeCount`；变化则整次 stale，绝不持久化 mixed snapshot。若
   count 未变而 representation unavailable，可做**有界**一次 retry；不要无限重试
   provider。
4. 明确 multi-item 产品语义。要全面超过 Maccy，建议保留 item boundaries，而不是把
   所有 items flatten 成 duplicate type map，也不是静默 first-only；若 v1 暂不支持，
   UI/receipt 必须明确“multi-item capture skipped”，不能称 standard shape。
5. 建立 slow-provider helper fixture（10/100/500/2000 ms）、64/128 MiB payload、ownership
   race 与 privacy prompt 测量，记录 main-thread hang budget。
6. 只有当 measurement 证明 MainActor read 不可接受时，才评估一个**窄的、同一执行域
   创建并使用 NSPasteboard 的 serial executor/thread 或 helper-process spike**。它必须
   在 macOS 26 上证明 API 支持、TCC attribution、run-loop/provider behavior 和 teardown；
   不能仅靠 `@unchecked Sendable` 或 ordinary actor 绕过编译器。helper process 的复杂度
   只有在 slow-provider 数据证明必要时才值得引入。

---

## 5. Pasteboard write：错误传播已修，但不是原子事务

### Apple 公开事实（DOC）

- [`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard) 官方示例
  本身允许 `clearContents(); setData(...)`，并说明 `setData` 是写第一 item 的 convenience。
- [`setData(_:forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/setdata(_:fortype:))
  和 item setter 返回 `Bool`；调用方不能把返回值当装饰。
- [`writeObjects(_:)`](https://developer.apple.com/documentation/appkit/nspasteboard/writeobjects(_:))
  可一次写入 `[NSPasteboardWriting]` 并返回 overall `Bool`。
- 一个 [`NSPasteboardItem`](https://developer.apple.com/documentation/appkit/nspasteboarditem)
  在传入 `writeObjects` 后绑定到该 pasteboard；已绑定 item 再写到 pasteboard 会异常，
  因而应为一次 interaction 创建新 item。
- General pasteboard 自动参加 Universal Clipboard；Apple 在
  [`NSPasteboard` overview](https://developer.apple.com/documentation/appkit/nspasteboard)
  明确说 macOS 没有操作 Universal Clipboard 的 API。`prepareForNewContents(with:
  .currentHostOnly)` 可表达仅本机的新内容策略，但是否采用是产品决策。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE）

- Clipy 先 destructive `clearContents`，再逐 representation 与 lineage hint `setData`；
  任一 false 会在全部尝试后抛 typed failure：
  [`PasteboardAdapter.swift:159-215`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L159-L215)。
- caller 捕获 failure 并保持 panel 打开，但没有用户可见错误：
  [`AppComposition.swift:227-251`](../../../ClipyApp/Sources/AppComposition.swift#L227-L251)。
- 因此旧审计的“silent success”已修；剩余问题是 system pasteboard 可能持有 partial
  subset，而用户只看到 panel 没关闭。实现会在某一 type 失败后继续尝试后续 type，
  因此源码中的 “PREFIX” 也不精确：
  [`PasteboardAdapter.swift:173-183`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L173-L183)、
  [`PasteboardAdapter.swift:247-254`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L247-L254)。
- Maccy 在 strings、representations、file URLs 与 markers 的多个写入点都忽略 Bool：
  [Maccy `Clipboard.swift:91-139`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Clipboard.swift#L91-L139)。Clipy 已经优于该实现。

### 支持上限 / UNKNOWN

- Apple 没有把 `writeObjects` 文档成跨进程 ACID/atomic transaction；overall `true`
  也不承诺竞争 writer 不会在调用返回后立刻取得 ownership。
- 自定义 lineage UTI 是否通过 Universal Clipboard、跨设备是否保留，没有公开保证；
  不能将它当 cross-device identity。

### 审查建议

1. 在内存中新建完整 `NSPasteboardItem`，先检查每个 item setter，再 clear 并只调用一次
   `writeObjects([item])`。这缩小 partial window、让 type set 在 ownership handoff 前
   完整，但文案仍只能说“single framework write attempt”，不能宣称事务原子性。
2. pasteboard write failure 应进入现有 panel failure/banner vocabulary；保持 panel 打开
   是必要但不充分的反馈。
3. 用 competing writer 在 clear、payload、lineage 前后抢 ownership；验收为“永不报告
   成功且用户可恢复”，不是强求系统提供它未承诺的原子性。
4. 明确 Universal Clipboard policy。默认跟随系统可能最符合预期；只有明确隐私模式才
   使用 `.currentHostOnly`，不要暗中改变 copy semantics。

---

## 6. NSPanel、activation、focus 与 Spaces

### Apple 公开事实（DOC）

- [`NSWindow.StyleMask.nonactivatingPanel`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
  只承诺该 panel 不激活 owning app。
- [`orderFrontRegardless()`](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless())
  即使 app inactive 也把 window 放到其 level 前方，并且不改变 key/main window。
- [`makeKey()`](https://developer.apple.com/documentation/appkit/nswindow/makekey()) 使它成为
  **本 app** 的 key window；[`NSApplication.keyWindow`](https://developer.apple.com/documentation/appkit/nsapplication/keywindow)
  是当前接收本 app keyboard events 的 window。
- [`NSWindow.CollectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)
  的公开语义是：
  - `.moveToActiveSpace`：window active 时移到 active Space，而不是切换 Space；
  - `.stationary`：Mission Control 不移动它，保持可见/固定；
  - `.transient`：在 Spaces 浮动并在 Mission Control 隐藏；
  - `.fullScreenAuxiliary`：在 full-screen window 同一 Space 显示；
  - `.canJoinAllSpaces` 才是“可以出现在所有 Spaces”。
- macOS 14 release notes 与 [`NSApplication.activate()`](https://developer.apple.com/documentation/appkit/nsapplication/activate())
  明确说 activation 是 request，结果依赖 context/user activity，不能假定成功。
- [`modalWindow`](https://developer.apple.com/documentation/appkit/nsapplication/modalwindow)
  与 [`attachedSheet`](https://developer.apple.com/documentation/appkit/nswindow/attachedsheet)
  分别覆盖 standalone modal window 与 attached sheet；这两个是公开 API。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE/INFERENCE）

- Clipy 使用 nonactivating panel、statusBar level 与
  `[.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]`：
  [`FloatingPanel.swift:55-81`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L55-L81)。
- `open` 顺序是 position → `orderFrontRegardless` → `makeKey`：
  [`FloatingPanel.swift:99-120`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L99-L120)。
- 注释声称 previous app “keeps focus ownership” 与“receives the paste”：
  [`FloatingPanel.swift:99-103`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L99-L103)、
  [`AppComposition.swift:217-239`](../../../ClipyApp/Sources/AppComposition.swift#L217-L239)。
  Apple 上述三个 symbol page 没有共同承诺另一个 app 的 exact first responder、selected
  text、key window 与 target 在此过程完全不变。
- 代码注释称“visible on every space”，但没有 `.canJoinAllSpaces`；实际 option 是
  move-to-current-space：
  [`FloatingPanel.swift:66-75`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L66-L75)。
- `.stationary` 对 clipboard-content panel 有隐私含义：Mission Control 会继续显示它。
  Maccy 使用完全相同的 collection set：
  [Maccy `FloatingPanel.swift:36-58`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/FloatingPanel.swift#L36-L58)。复制 Maccy 不构成
  product justification。
- 公开 modal/sheet helper 是正确修复，但 SwiftUI `confirmationDialog` 的 macOS
  presentation 是否总映射成这两个形状，Apple presentation page没有承诺：
  [`FloatingPanel.swift:130-139`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L130-L139)、
  [`ClipySettingsView.swift:175-204`](../../../Sources/PresentationUI/ClipySettingsView.swift#L175-L204)。

### 支持上限 / UNKNOWN

- “owning app 不激活”是文档事实；“原 app 的 paste target 精确保存/恢复”是 runtime
  hypothesis。
- Spaces、Stage Manager、多显示器、full-screen app、secure field、screen sharing 与
  lock-screen 的组合没有由 option names 自动证明。
- `.stationary` 与 `.fullScreenAuxiliary` 会增加敏感 history 在系统级窗口管理界面暴露
  的机会；这是从公开显示语义与内容敏感性得到的风险推断，不是 Apple 宣告的漏洞。

### 审查建议

1. 修改注释：只声明“不激活 Clipy”；不要提前声明前一 app target 保留。
2. 评估用 `.transient` 替代 `.stationary`，使 chooser 在 Mission Control 隐藏；保留
   `.moveToActiveSpace` / `.fullScreenAuxiliary` 是否必要由真机矩阵决定。不要为了“所有
   Spaces”加入 `.canJoinAllSpaces`，那会扩大敏感内容暴露且不符合 summon-on-current-
   Space 的任务。
3. `APPLE-PANEL-FOCUS-1`：TextEdit、Safari/WebKit、Electron、Terminal、secure text、
   menu/popover、full-screen、Stage Manager、多显示器；记录 active app、两边 key window、
   first responder、selection 与 panel close 后实际 Command-V target。
4. 分别测试 NSAlert、sheet、SwiftUI alert/confirmationDialog、Settings；以 panel 不误关、
   不永久卡住为验收，不从 `modalWindow || attachedSheet` 静态推导全覆盖。

---

## 7. NSEvent monitors：Apple 公开了明显的覆盖缺口

### Apple 公开事实（DOC）

- Apple 的 [Monitoring Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)
  说明：
  - global monitor 只观察发给**其他 apps** 的事件，不能修改/阻止；key events 只有在
    Accessibility enabled 或 app trusted for accessibility 时才能观察；
  - local monitor 只观察发给**本 app** 的事件，可替换或吞掉；
  - 若要覆盖本 app 与其他 apps，要同时安装两种；
  - 两类 handler 都在 main thread；完成后必须 remove monitor。
- [`addLocalMonitorForEvents`](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:))
  明确说 control tracking、menu tracking、window dragging 等 nested event-tracking loop
  消费的事件不会交给 local handler。
- [`removeMonitor`](https://developer.apple.com/documentation/appkit/nsevent/removemonitor(_:))
  明确要求同一个 token 只 remove 一次；当前 page没有写“可在任意 thread remove”。
- Apple 指南甚至建议：若 notification/window delegate 能完成任务，不要因为方便就加
  event monitor；示例用 `NSApplicationDidResignActiveNotification` 处理 app deactivation，
  因为 global monitor 连 Command-Tab/system alert 都不覆盖。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE）

- Clipy production 不调用 `addLocalMonitorForEvents` 或 `addGlobalMonitorForEvents`；panel
  dismissal 走 window key lifecycle，global summon 走 Carbon。这避免了确定的 global
  key-monitor Accessibility path。
- Maccy 使用 local `.flagsChanged` monitor 做 cycle-mode modifier release：
  [Maccy `Popup.swift:75-125`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Observables/Popup.swift#L75-L125)。
  它的注释说 `removeMonitor` thread-safe，但 Apple 当前 page只提供“remove once”保证：
  [Maccy `Popup.swift:128-140`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Observables/Popup.swift#L128-L140)。

### 支持上限 / UNKNOWN

- handler 在 main thread 是 Apple 文档事实；把任意 main-thread callback 直接视为正在
  执行 Swift `MainActor` serial executor，仍应由 `MainActor.assumeIsolated` runtime check
  或显式 hop 验证。该方法失败会 fatal：
  [`MainActor.assumeIsolated`](https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:))。
- `removeMonitor` 的任意线程安全性未被当前 symbol page证明。

### 审查建议

1. 不要为 outside-click、Esc 或普通 key command 引入 global monitor；window delegate、
   responder chain、SwiftUI/AppKit commands 更符合覆盖范围。
2. 若未来复制 Maccy cycle interaction，必须接受 local monitor 在 nested tracking loops
   缺事件的契约，并设计 state timeout/reset；token 由唯一 owner 在确定线程只 remove 一次。
3. 不要用 global monitor 实现 summon shortcut；它对 key events 有明确 Accessibility
   gate，且看不到本 app events。

---

## 8. Carbon hotkey：可以是窄的现实选择，但不能被写成现代 Apple 保证

### Apple 公开资料边界（DOC）

- Apple 当前 Developer Documentation 没有 `RegisterEventHotKey`、
  `GetEventDispatcherTarget`、`InstallEventHandler` 的现代 symbol pages，因此本轮找不到
  可引用的 macOS 26 availability、callback executor/thread 或 TCC contract。
- Apple 的 retired
  [64-Bit Guide for Carbon Developers — HIToolbox](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/Carbon64BitGuide/HIToolboxChanges/HIToolboxChanges.html)
  明确警告文档不是当前 best practice；Carbon Event Manager 部分函数不支持 64 bit，
  具体函数 availability 应查当前 SDK header。该文档不替代 macOS 26 契约。
- Apple Frameworks Engineer 在
  [Developer Forums thread 763878](https://developer.apple.com/forums/thread/763878)
  确认 macOS 15 曾有意改变仅 Option/Shift hotkey registration，之后 15.2 beta 又调整。
  这证明行为可能随系统安全策略改变，而非提供稳定线程/TCC保证。
- Swift 当前 [`MainActor`](https://developer.apple.com/documentation/swift/mainactor)
  executor 等价于 main dispatch queue；`assumeIsolated` 若不在该 executor 会 fatal。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE/INFERENCE）

- Clipy 通过 dispatcher target 安装 handler 与注册 ⇧⌘C，检查两个 OSStatus，并能 teardown：
  [`GlobalHotKey.swift:78-129`](../../../ClipyApp/Sources/HotKey/GlobalHotKey.swift#L78-L129)。
- callback 现在先检查 `Thread.isMainThread`，否则同步 hop 到 main queue，再执行
  `MainActor.assumeIsolated`；这比无条件 assume 有防御性：
  [`GlobalHotKey.swift:139-190`](../../../ClipyApp/Sources/HotKey/GlobalHotKey.swift#L139-L190)。
- 但文件仍断言 Carbon hotkey “needs no accessibility grant”；Apple 没有该 symbol-level
  保证：
  [`GlobalHotKey.swift:1-17`](../../../ClipyApp/Sources/HotKey/GlobalHotKey.swift#L1-L17)。
- headless hosted test只证明该 runner 上 registration 成功、wrapper idempotence 与直接
  `fire()`；它没有真实触发 C callback、clean TCC、secure input 或 fresh user profile：
  [`PanelAndHotKeyTests.swift:137-178`](../../../ClipyApp/Tests/ClipyIntegrationTests/PanelAndHotKeyTests.swift#L137-L178)。
- `AppDelegate` 忽略 `register()` 的 false，用户不会知道 chord 冲突/注册失败：
  [`AppDelegate.swift:67-75`](../../../ClipyApp/Sources/AppDelegate.swift#L67-L75)。

### 支持上限 / UNKNOWN

- 当前代码在 Xcode 26 CI 编译，只证明该 SDK/runner 仍包含 symbols；不证明未来
  availability、modifier policy、TCC 豁免或 callback thread。
- off-main callback 再 `DispatchQueue.main.sync` 的路径是防御性 fallback，但真实 Carbon
  callback 分支没有 test 驱动；如果 callback 与 main thread 形成等待环，还需 runtime
  观测排除死锁。

### 审查建议

1. 可以保留这个很窄的 wrapper，避免无价值地引入另一快捷键 dependency；但注释与
   产品声明必须写成“在受支持系统实测可用”，不是“Apple 保证无需权限”。
2. Release gate 从 Xcode 26 SDK header 提取 availability/deprecation 并存档；clean macOS
   26 VM 覆盖无/有 Accessibility 与 Input Monitoring、secure input、冲突、不同 layouts、
   sleep/wake、fast user switch、重复注册/注销、真实 callback thread。
3. 注册失败必须在 Settings/status surface 可见，并允许重新录制 chord。
4. 不要把 Carbon callback 做成业务 owner；保持 C boundary → ID check → MainActor action
   的窄度，这一点当前方向正确。

---

## 9. SMAppService：四态、typed error 与官方恢复入口

### Apple 公开事实（DOC）

- macOS 13+ [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice)
  是 main app/login item/agent/daemon 的现代注册 API。
- [`Status`](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum)
  至少有 `.notRegistered`、`.enabled`、`.requiresApproval`、`.notFound`。
- [`.requiresApproval`](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval)
  表示 service 已成功注册，但用户需在 System Settings 操作；用户撤销 consent 也返回
  此状态。它不是简单的 off。
- [`register()`](https://developer.apple.com/documentation/servicemanagement/smappservice/register())
  throws；已注册可返回 `kSMErrorAlreadyRegistered`，未获用户批准可返回
  `kSMErrorLaunchDeniedByUser`。
- [`openSystemSettingsLoginItems()`](https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems())
  是官方 Login Items 恢复入口。Apple 的
  [migration guidance](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
  明确建议未授权时提醒用户并打开该 pane。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE）

- Clipy get 只在 `.enabled` 返回 true；`.requiresApproval`、`.notRegistered`、`.notFound`
  全显示为 off。setter catch 后吞掉 error，只靠下一次 get snap back：
  [`AppDelegate.swift:211-232`](../../../ClipyApp/Sources/AppDelegate.swift#L211-L232)。
- PresentationUI 只得到 `Binding<Bool>`，无法显示 pending approval、error 或 recovery：
  [`ClipySettingsView.swift:41-64`](../../../Sources/PresentationUI/ClipySettingsView.swift#L41-L64)、
  [`ClipySettingsView.swift:164-166`](../../../Sources/PresentationUI/ClipySettingsView.swift#L164-L166)。
- Maccy 当前 surface 使用 third-party `LaunchAtLogin.Toggle`，本 repo 只看到依赖与 view
  call site，没有 vendored dependency source 可据此证明它是否保留四态/官方 recovery：
  [Maccy `project.yml:69-71`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/project.yml#L69-L71)、
  [`GeneralSettingsPane.swift:29-35`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Settings/GeneralSettingsPane.swift#L29-L35)。因此不能
  用 Maccy 的一个 toggle 反证 Clipy 的状态模型已经足够。

### 支持上限 / UNKNOWN

- status 是查询瞬时状态；System Settings 可在 app 外改变它。Apple page没有承诺 SwiftUI
  binding 自动通知，因此 Settings activation/window focus 时需重新读。
- register 成功后何时从 requiresApproval 变 enabled、login launch 时机与 headless agent
  lifecycle 需 runtime proof。

### 审查建议

1. composition root 暴露一个 UI-friendly 四态 value，而不是 Bool：enabled、off、approval
   required、unavailable/error。
2. `.requiresApproval` 显示“Registered — approval required”及
   `SMAppService.openSystemSettingsLoginItems()` 按钮；不要再次盲目 register。
3. 显示 register/unregister typed failure 的可操作文案；Settings scene active 时 refresh。
4. proof 覆盖用户在 app 外撤销、already registered、denied、not found、login/reboot、app
   移动路径与更新后 identity 延续。

---

## 10. OpenSettingsAction：公开入口已正确采用，但 activation 仍是请求

### Apple 公开事实（DOC）

- [`OpenSettingsAction`](https://developer.apple.com/documentation/swiftui/opensettingsaction)
  是呈现 app Settings scene 的公开 MainActor action；从 environment 的
  [`openSettings`](https://developer.apple.com/documentation/swiftui/environmentvalues/opensettings)
  取得。
- [`callAsFunction()`](https://developer.apple.com/documentation/swiftui/opensettingsaction/callasfunction())
  打开 Settings scene；若 window 已打开则 order front。
- [`Settings`](https://developer.apple.com/documentation/swiftui/settings) scene 会让 SwiftUI
  管理 Settings menu/window 与等效 shortcut。
- 但 [`NSApplication.activate()`](https://developer.apple.com/documentation/appkit/nsapplication/activate())
  明确只是 activation request，不保证 app active。
- [HIG Settings](https://developer.apple.com/design/human-interface-guidelines/settings) 要求
  macOS App menu 提供 Settings、标准 ⌘,、多 pane 时稳定 toolbar/title，并恢复最近 pane。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE）

- app 声明公开 Settings scene：
  [`ClipyAppMain.swift:25-37`](../../../ClipyApp/Sources/ClipyAppMain.swift#L25-L37)。
- panel 里的按钮先 `NSApp.activate()` 再 `openSettings()`：
  [`PanelRootView.swift:19-42`](../../../ClipyApp/Sources/Panel/PanelRootView.swift#L19-L42)。
- footer 提供 ⌘,：
  [`HistoryPanelView.swift:190-214`](../../../Sources/PresentationUI/HistoryPanelView.swift#L190-L214)。
- Settings `TabView` 没有 selection binding/persistence；HIG 的“restore most recently viewed
  pane”未被静态代码证明：
  [`ClipySettingsView.swift:67-79`](../../../Sources/PresentationUI/ClipySettingsView.swift#L67-L79)。

### 支持上限 / UNKNOWN

- `openSettings()` 能开/bring-front Settings window 是公开保证；inactive LSUIElement 从
  nonactivating panel 调用时，它是否最终成为 visible/key/frontmost across Spaces，还受
  activation request 结果影响。
- SwiftUI `TabView` 在该 SDK 上产生何种 toolbar/title/restoration，需运行观察，不能只凭
  view declaration判合规。

### 审查建议

1. 保留 `OpenSettingsAction`，不要回退到 selector 或 private class。
2. 在 real LSUIElement release build 测 Settings closed/already-open/other Space/full-screen；
   检查 `NSApp.isActive`、Settings key window 与 panel close。
3. 为 pane selection 加显式 `@AppStorage`（Apple 的 OpenSettingsAction 示例也展示该
   pattern），并让 title/toolbar 在运行时满足 HIG。

---

## 11. ImageIO：primary index 已正确；实际 decode timing 仍有缺口

### Apple 公开事实（DOC）

- [`CGImageSourceGetPrimaryImageIndex`](https://developer.apple.com/documentation/imageio/cgimagesourcegetprimaryimageindex(_:))
  返回 HEIF primary image index；非 HEIF 返回 0。
- [`kCGImageSourceThumbnailMaxPixelSize`](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize)
  限制 thumbnail 最大宽高；
  [`kCGImageSourceCreateThumbnailWithTransform`](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailwithtransform)
  按 orientation/aspect ratio 旋转缩放。
- Apple 的 [iOS Memory Deep Dive](https://developer.apple.com/videos/play/wwdc2018/416/)
  说明 ImageIO `CreateThumbnailAtIndex` 可 streaming downsample，避免先展开 full-resolution
  bitmap；该 session 明说很多原则也适用于其他平台，但其中展示的具体性能数字不是
  Clipy/macOS 26 保证。
- [`kCGImageSourceShouldCacheImmediately`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately)
  控制在 image creation time 就 decode/cache。默认 `false`，默认会等到 render image
  才 decode/cache；Apple 明确列出的适用调用包括 `CGImageSourceCreateImageAtIndex`。
- [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage) 当前 Swift surface
  conform `Sendable`，因此已创建 image 跨 actor 到 MainActor 在类型契约上成立。
- [`CGImageSourceGetType`](https://developer.apple.com/documentation/imageio/cgimagesourcegettype(_:))
  返回 source container UTI；`kCGImageSourceTypeIdentifierHint` 只是“best guess”，不是
  allowlist。
- 新的 [`kCGImageSourceAllowableTypes`](https://developer.apple.com/documentation/imageio/kcgimagesourceallowabletypes)
  能限制 decoder formats，但当前文档标 **Beta** 并要求 final OS 重测，不能直接成为
  macOS 26 release 依赖。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE/INFERENCE）

- storage thumbnail 使用 primary index、max pixel、transform，随后 PNG encode/finalize；
  encode 会消费该 image，整个 pipeline 留在 `ThumbnailWorker` actor：
  [`ThumbnailService.swift:245-341`](../../../Sources/HistoryStorage/ThumbnailService.swift#L245-L341)。
  这是强于“只创建 CGImage 后交给 UI”的 off-main evidence。
- full preview 使用 primary index + bounded thumbnail options，并在普通 actor 中调用：
  [`DisplayImageDecoder.swift:49-76`](../../../Sources/PresentationUI/DisplayImageDecoder.swift#L49-L76)。
- **新 finding：** row/detail thumbnail PNG path 调
  `CGImageSourceCreateImageAtIndex(source, 0, nil)`，没有
  `kCGImageSourceShouldCacheImmediately: true`：
  [`DisplayImageDecoder.swift:38-47`](../../../Sources/PresentationUI/DisplayImageDecoder.swift#L38-L47)。
  按 Apple 默认值，actor 上确定完成的是 source/image object creation；实际 decode/cache
  可能推迟到 SwiftUI render。文件头“decode itself runs on THIS actor's executor, never on
  caller's”目前证据过强：
  [`DisplayImageDecoder.swift:1-17`](../../../Sources/PresentationUI/DisplayImageDecoder.swift#L1-L17)。
- full preview 在 MainActor 先调用 `details(for:)`，把整个 canonical/effective/revision detail
  materialize；随后才挑一个 image bytes 交给 decoder。源码自己承认需要 bounded preview
  seam：
  [`HistoryPreviewView.swift:103-122`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L103-L122)、
  [`HistoryPreviewView.swift:185-221`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L185-L221)。
- ImageIO source creation没有传 declared UTI，也没核对 `CGImageSourceGetType`；因此
  History 的 declared-type allowlist 控制“哪些 representation 被选择”，但 ImageIO 仍
  可 sniff 实际 container：
  [`HistoryAuthority+DetailAndThumbnail.swift:146-151`](../../../Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift#L146-L151)、
  [`ThumbnailService.swift:258-279`](../../../Sources/HistoryStorage/ThumbnailService.swift#L258-L279)。
- Maccy `ImageDownsampler` 固定 index 0，因此对 multi-image HEIF 弱于 Clipy；它把
  `kCGImageSourceShouldCacheImmediately` 传给 `CreateThumbnailAtIndex`，但注释也正确承认
  Apple 只明确为 `CreateImageAtIndex` 文档化该 key：
  [Maccy `ImageDownsampler.swift:22-50`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/ImageProcessing/ImageDownsampler.swift#L22-L50)。

### 支持上限 / UNKNOWN

- Apple pages没有承诺 `CGImageSource` 可由多个线程并发共享，也没有提供 Swift
  `Sendable` conformance。Clipy 每次把 source 创建、使用、释放在一个同步 actor method
  内，没有共享 source；这避开了需要该保证的设计。
- 对 `CreateThumbnailAtIndex`，Apple 证明了 downsample primitive 与 options 语义，但
  `ShouldCacheImmediately` page没有把 thumbnail function列为适用调用。不能仅加这个 key
  就宣布所有像素工作已后台完成。
- PNG encode byte-for-byte determinism、decoder peak RSS、malformed input worst-case time、
  cancellation latency没有公开保证。

### 审查建议

1. **立即收窄 claim：** `DisplayImageDecoder.thumbnailImage` 应给
   `CreateImageAtIndex` 传 `kCGImageSourceShouldCacheImmediately: true`，再用 Time Profiler/
   signpost 证明 SwiftUI first render 不承担 decode。这个建议直接落在 Apple 明确支持的
   option/function pair 上。
2. full preview 保留 `CreateThumbnailAtIndex`，但用 main-thread time + ImageIO signpost
   证明 render 没有 residual decode；若严格 gate 仍发现 work，考虑在 decoder actor 内
   draw 到 bounded bitmap context 后返回 materialized `CGImage`，而不是把未证明的 cache
   key 作用域扩写成保证。
3. 实现 purpose-specific `preview(for:pixels:)` storage read，先在 Authority 内选择单个
   effective representation，只返回有 byte bound 的 immutable source；不要让 UI 为预览
   hydrate 全 detail/revision graph。
4. source value 应携带 declared type；source create 后核对 `CGImageSourceGetType` 与允许的
   container policy。Beta `AllowableTypes` 只作为未来 final-SDK spike，不提前依赖。
5. fixtures：primary index 非 0 的 HEIF、animated GIF/multipage TIFF deliberate-first-frame、
   decompression bomb/adversarial dimensions、corrupt/truncated、128 MiB source、快速 selection
   cancellation；报告 actor time、MainActor time、peak RSS，而非只断言 non-nil image。

---

## 12. Accessibility、keyboard 与 menus：静态 label 不等于任务可完成

### Apple 公开事实（DOC/HIG）

- [HIG Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
  要求尽可能支持 Full Keyboard Access、尊重 standard shortcuts、只给高频 app-specific
  command 定义 custom shortcut。其标准表明确 **⇧⌘C = Display the Colors window**。
- [HIG Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)
  明确要求 context-menu items 也要在 main interface 可用；macOS menu bar menus 应列出
  app commands，包括 context menus 中的 commands。
- [HIG Menus](https://developer.apple.com/design/human-interface-guidelines/menus) 同样说明
  macOS menu bar menu 包含 app 可以执行的 commands。
- [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
  要求仅键盘可导航/交互、不要覆盖系统 shortcuts、正确 labels，并实际验证 VoiceOver、
  Voice Control、Switch Control 等。
- Apple 的
  [Performing accessibility testing](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app)
  要求先列每屏 main tasks，再在每个支持 device type 上用 assistive technologies 测试。
- [VoiceOver evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria)
  要求用户只用 VoiceOver、无需 sighted assistance 就能完成 common tasks；controls 要有
  concise/accurate label，标准键盘 navigation 与 VoiceOver cursor 应一致。

访问日期：**2026-08-22 UTC**。

### 当前代码映射（CODE）

- Clipy default global shortcut 固定 ⇧⌘C，正好复用 Apple 标准 Colors shortcut；也没有
  shortcut recorder/setting：
  [`GlobalHotKey.swift:62-70`](../../../ClipyApp/Sources/HotKey/GlobalHotKey.swift#L62-L70)。
- Maccy 快照的默认同样是 ⇧⌘C，所以默认冲突不是其优势；但它确实提供 recorder，而
  Clipy 没有：
  [Maccy `KeyboardShortcuts.Name+Shortcuts.swift:3-11`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Extensions/KeyboardShortcuts.Name%2BShortcuts.swift#L3-L11)、
  [`GeneralSettingsPane.swift:44-58`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Settings/GeneralSettingsPane.swift#L44-L58)。
- row 的 move top/bottom、pin/unpin、details、remove 主要在 context menu：
  [`HistoryRowView.swift:214-268`](../../../Sources/PresentationUI/HistoryRowView.swift#L214-L268)。
- keyboard commands 通过 0×0、opacity 0、`accessibilityHidden(true)` buttons 注入；这可
  让 shortcuts 工作，却没有形成 HIG 要求的 menu/visible action surface：
  [`HistoryListView.swift:139-190`](../../../Sources/PresentationUI/HistoryListView.swift#L139-L190)、
  [`SearchHeaderView.swift:137-153`](../../../Sources/PresentationUI/SearchHeaderView.swift#L137-L153)、
  [`HistoryPanelView.swift:276-302`](../../../Sources/PresentationUI/HistoryPanelView.swift#L276-L302)。
- app scenes 没有 `.commands` / `CommandMenu`；只有 hidden `MenuBarExtra` 与 Settings：
  [`ClipyAppMain.swift:25-37`](../../../ClipyApp/Sources/ClipyAppMain.swift#L25-L37)。
- 代码有若干良好的 labels/decorative hides，但 repo 中没有 VoiceOver、Full Keyboard
  Access、Accessibility Inspector 或 XCUI accessibility task proof；`rg` 只找到 source
  modifiers 与一条 hotkey test comment。
- status item 有 `accessibilityDescription: "Clipy"`：
  [`AppDelegate.swift:169-179`](../../../ClipyApp/Sources/AppDelegate.swift#L169-L179)。这是
  必要但不足以证明整条 journey。

### 支持上限 / UNKNOWN

- SwiftUI 标准 controls 会自动提供部分 accessibility，但 nonactivating AppKit-hosted panel
  的 focus order、context menu exposure、selection announcements 与 modal transitions 必须
  运行验证。
- `.keyboardShortcut` 在隐藏 button 上能否在所有 input methods、VoiceOver 与 Full
  Keyboard Access 状态稳定工作，没有由 HIG 或静态代码保证。

### 审查建议

1. **更换默认 summon chord**，并提供 recorder、冲突反馈与 reset。不要让“与 Maccy
   相同”压过系统 standard shortcut。具体新默认必须在 macOS 26 Keyboard Shortcuts
   clean profile 做 conflict scan 后决定，而不是在文档里猜一个永不冲突组合。
2. 给 selected item 的 Copy、Pin/Unpin、Details、Remove、Move Top/Bottom 提供可发现的
   main action surface；并通过 SwiftUI `commands` / AppKit menu exposure 提供真正的 menu
   commands。context menu 保留为快捷入口，不做唯一入口。
3. 建立 task matrix：summon、search/mode、navigate/select、copy、pin/reorder/remove、
   preview、details/revise、clear、Settings、failure recovery、quit。逐项 VoiceOver + FKA；
   再覆盖 Voice Control、Switch Control、Increase Contrast、Reduce Motion。
4. 验收不是“存在 accessibilityLabel”，而是 common tasks 完成、focus/announcement 顺序
   合理、shortcut 与 VoiceOver cursor 同步，并保存 macOS 26 录屏/Accessibility Inspector
   report。

### 可选 automatic paste 的权限边界

Clipy 当前只是把 item 写回 clipboard 并关闭 panel，源码明确把 auto-paste 排除：
[`AppComposition.swift:217-239`](../../../ClipyApp/Sources/AppComposition.swift#L217-L239)。
Maccy 则合成 Command-V：
[Maccy `Clipboard.swift:141-173`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Clipboard.swift#L141-L173)。

若产品决定加入 opt-in automatic paste，Apple 的
[WWDC19 Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/)
明确说 synthetic input event 未授权时会被丢弃，并要求 Accessibility approval；可用
[`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
检查/异步提示，Core Graphics 还公开 `CGPreflightPostEventAccess` / `CGRequestPostEventAccess`。
因此建议只能是**明确 opt-in + permission state + manual-copy fallback**；不能把
“Maccy 能做”当作无需权限或一定成功的证明。访问日期同为 **2026-08-22 UTC**。

---

## 13. Signing、notarization、packaging 与 updates：两边当前都没有 ship proof

### Apple 公开事实（DOC）

- Apple 的
  [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
  要求 direct distribution 使用 Developer ID、有效 signatures、Hardened Runtime、secure
  timestamp、正确 entitlements；notary service 扫描并签发可 staple 的 ticket。2019 年后
  新构建的 Developer ID software 按 Apple 说明需 notarize。
- [`notarytool` 与 `stapler`](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
  可集成自动 workflow；`altool` 自 2023-11-01 不再接受。
- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
  说明 direct distribution 需要 distribution-sign code、container、notarize，并建议每个
  version 自动化。ZIP 本身不能签名，未被 app code signature 覆盖的内容可被篡改。
- [Gatekeeper and runtime protection](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)
  说明 Gatekeeper 验证 identified developer、notarization 与内容未被修改。
- [macOS distribution](https://developer.apple.com/macos/distribution/) 明确：Mac App Store
  的 updates 由 Apple hosted；App Store 外的 software updates 由 developer managed。
- Apple Secure Coding Guide 的
  [Third-Party Software Security Guidelines](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/SecurityGuidelines.html)
  要求提供升级/安全修复信息，传输加密并认证 server；可行时优先 Mac App Store。
- [Code Signing Guide — Shipping and Updating](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
  要求合格新版本用相同 identifier/designated requirement 签名，最终安装 product 必须与
  signed code bit-for-bit 一致。
- [TN3127 designated requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
  解释 TCC 等系统如何用 designated requirement 判断更新前后是否同一 app。

访问日期：**2026-08-22 UTC**。

### Clipy 当前映射（CODE）

- XcodeGen spec 只有 Debug/test graph、LSUIElement 与 module settings；没有 team、Developer
  ID、Hardened Runtime、entitlements、marketing/build version 或 archive/export config：
  [`project.yml:6-40`](../../../ClipyApp/project.yml#L6-L40)。
- 审查基线CI app job 明确 `CONFIGURATION=Debug`、`CODE_SIGNING_ALLOWED=NO`；
  该单体workflow随后已被模块化CI替代。
- 当前 workflows 是 correctness、三个无 caller 的 reusable performance evidence
  模块与 `symbol-snapshot.yml`；production sources/config 中无 updater、appcast、
  notary/staple/Developer ID/Hardened Runtime。
- 所以当前证据只支持“代码与 tests 可在 CI 构建”，不支持“用户可安全安装/更新”。

### Maccy 对照映射（CODE）

- Maccy project 打开 Hardened Runtime、配置 team 与 entitlements：
  [Maccy `Maccy-Common.xcconfig:1-23`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Config/Maccy-Common.xcconfig#L1-L23)。
- 它集成 Sparkle，提供 feed 与 check UI：
  [Maccy `project.yml:53-71`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/project.yml#L53-L71)、
  [`project.yml:141-151`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/project.yml#L141-L151)、
  [`Info.plist:31-36`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Info.plist#L31-L36)、
  [`SoftwareUpdater.swift:1-69`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/SoftwareUpdater.swift#L1-L69)。
- 但本地 fork 的 release workflow 明确 `CODE_SIGNING_ALLOWED: NO`：
  [Maccy `release.yml:38-48`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/.github/workflows/release.yml#L38-L48)；package script也默认
  NO，只 zip + SHA-256：
  [Maccy `package-app.sh:4-25`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/scripts/package-app.sh#L4-L25)、
  [`package-app.sh:39-66`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/scripts/package-app.sh#L39-L66)。
- workflow 没有 codesign/notarytool/stapler；当前 appcast enclosure 也没有可见
  `sparkle:edSignature`：
  [Maccy `appcast.xml:1-29`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/appcast.xml#L1-L29)。
  这不证明 upstream 官方发布物如何制作，只证明**这个对照工作树**没有 signed/notarized
  release evidence。一个 SHA-256 sidecar 若与 artifact 同渠道发布，也不是 Apple code
  identity/notarization 的替代。

### 支持上限 / UNKNOWN

- Apple 不提供 App Store 外 updater implementation；采用 Sparkle 或自研属于第三方/
  产品选择。Apple 资料只钉住 distribution identity、transport/server authentication、
  same designated requirement 与 notarization边界。
- workflow 文件名叫 release、存在 appcast 或 Hardened Runtime setting 都不能证明最终
  archive 的 nested code、entitlements、ticket、Gatekeeper 与 update replacement正确。

### 审查建议

1. **P0 ship lane：** Release archive（arm64，未来若支持 universal 则两架构）→ Developer
   ID Application 签名所有 nested code → Hardened Runtime + secure timestamp → export
   DMG/ZIP/PKG → `notarytool --wait` → staple 可 staple container → 验证。
2. 保存机器可审计 evidence：`codesign --verify --deep --strict --verbose=4`、designated
   requirement/entitlements dump、`spctl --assess`、`stapler validate`、notary log、artifact
   checksum、version/build、依赖清单。命令通过后还要在无开发证书的 clean macOS 26 VM
   下载、首次启动、login item、pasteboard privacy、升级/回滚。
3. 先决定 channel：
   - Mac App Store：Apple host updates，但 sandbox/capability/product policy 要单独验证；
   - direct：developer 必须管理 authenticated update channel。选择成熟 updater 可少造轮子，
     但必须验证 release artifact signature、feed signature/HTTPS、same designated requirement、
     downgrade/replay policy、interrupted replacement 与 rollback。
4. update 不能先于 signed release identity。先固定 bundle ID/team/designated requirement 与
   migration compatibility，再接 updater；否则 TCC、login item 与 user trust 可能在更新后
   断裂。
5. 不把当前 Maccy fork 当 shipping gold standard；Clipy 的目标应是有可复现、可验证的
   notarized artifact 和真实 upgrade journey，而不是“也能打一个 zip”。

---

## 14. 建议写入新 review 的最小 Apple proof matrix

| Gate | 场景 | 通过条件 |
|---|---|---|
| `APPLE-PB-PRIVACY-1` | clean profile 四种 AccessBehavior、冷启动、后台 copy、重启 | 状态可见；deny/prompt 不伪装 empty；有恢复路径 |
| `APPLE-PB-LOSS-1` | 0.5 s 内 2/5/20 writes、main stall、sleep/wake | 披露 loss/latency；spec 不再承诺逐 count |
| `APPLE-PB-PROVIDER-1` | lazy provider 10–2000 ms、large payload、ownership race | main-thread stall 有预算；mixed/partial snapshot 不入库；无 unsafe actor escape |
| `APPLE-PB-WRITE-1` | competing writer 抢 clear/write/lineage | 不报告 silent success；error visible；partial-subset 风险可恢复 |
| `APPLE-PANEL-FOCUS-1` | native/WebKit/Electron/terminal/secure field、Spaces/full-screen | active app/key window/first responder/target 符合明确产品定义 |
| `APPLE-PANEL-PRIVACY-1` | Mission Control、Stage Manager、screen share、lock | 敏感 panel visibility 是有意 policy，不是复制 Maccy 默认 |
| `APPLE-HOTKEY-1` | clean TCC、secure input、冲突、layouts、sleep/wake | registration failure 可见；callback crash/deadlock-free；shortcut 可改 |
| `APPLE-LOGIN-1` | 四种 status、external revoke、reboot/update | 状态不压扁；requiresApproval 有官方 Settings recovery |
| `APPLE-SETTINGS-1` | inactive LSUIElement、已开 window、other Space | public action 稳定 bring front；最近 pane恢复 |
| `APPLE-IMAGE-1` | primary HEIF、lazy-decode profiling、bomb/corrupt/128 MiB | bounded pixels/source；first render无意外 main decode；peak RSS有证据 |
| `APPLE-A11Y-1` | 全 main-task matrix × VoiceOver/FKA；抽查 Voice Control/Switch | common tasks无需 sighted help；focus/labels/commands 合理 |
| `APPLE-SHIP-1` | clean-machine install + N-1→N update + interrupted update | Developer ID/hardened/notarized/stapled；identity连续；可恢复/回滚 |

## 15. 给总 review 的措辞约束

- 可以说：Clipy 的 HEIF primary-index handling、typed pasteboard write failure 与 public
  Settings action 已经优于这份 Maccy 工作树对应实现；ImageIO object confinement 的
  方向合理，但 lazy-decode gate 尚未关闭。
- 不可以说：Clipy 已无损捕获每次 copy、Carbon 一定无需权限、nonactivating panel 一定
  保存 paste target、ordinary actor 一定可安全读取 NSPasteboard、创建 `CGImage` 就等于
  后台完成 decode、或任一项目已具备可发布 artifact。
- “全面超过 Maccy”的 Apple 平台证据应落在：privacy recovery 更清楚、捕获局限诚实、
  focus/Spaces 有实测、shortcut 不抢系统语义、VoiceOver/FKA journey 完整、release/update
  identity 可审计。这里没有要求引入遥测、云同步、复杂 plugin system 或自研 updater；
  这些都不是关闭当前平台缺口所必需。
