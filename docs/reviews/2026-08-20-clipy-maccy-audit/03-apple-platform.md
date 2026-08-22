# Apple 平台契约、隐私与 HIG 核验

> 审查轴：AppKit / SwiftUI / SwiftData / ImageIO / ServiceManagement 的公开契约、macOS 26 可用性、隐私与 HIG
>
> 审查开始：**2026-08-20T00:09:29Z (UTC)**
>
> 审查结束：**待最终校验后回填**
>
> 最终平台/接线快照：**`codex/v2-implementation@9a637a6c58914c4ef586f45f2996656b69f1c241`**（提交时间 **2026-08-20T00:31:15Z**）
>
> UI 功能快照：**`a028c8c579b365f6c2183c5042ee78a365553d2a`**（提交时间 **2026-08-20T00:16:36Z**）；`9c6e3b48f1bbf0c642ccbb61b233319003b6fefb`（**2026-08-20T00:21:44Z**）只调整 `PreviewContent.textCharacterCap` 的访问级别；`9a637a6c` 又增加 alert-window helper 和测试等待预算。下文行号以 `9a637a6c` 为准。
>
> 初始现场：审查在 `61b418bf9b9767ac84f81da3e65cfe447a509cbd` 开始，当时 UI、测试与工作流仍是 dirty overlay；因此不能把初始未提交 UI 当成稳定基线。
>
> 审查环境：Linux 6.18 x86_64；没有 Xcode 26、Swift 6.2、`xcrun`、AppKit 运行时或 macOS 26 设备。本报告是静态源码 + Apple 一手资料核验，**不是**新的编译、TCC、焦点、RSS 或延迟实测。
>
> 修改边界：只创建本报告；未修改源码、测试、配置、工作流或既有 V1/V2 文档。

## 1. 结论

当前实现还不能据此宣称“在 macOS 26 上全面超越 Maccy、内存更小、速度更快且平台行为更可靠”。核心 History 模块有不少正确而保守的平台设计，但产品接线新增了几处会直接影响剪贴板管理器基本可用性的 Apple 平台缺口：

1. **剪贴板隐私状态未建模。** `NSPasteboard.AccessBehavior` 自 macOS 15.4 起公开；General pasteboard 的默认程序化访问行为是询问。Clipy 启动即读且持续后台读，却没有查看/呈现 `.default`、`.ask`、`.alwaysAllow`、`.alwaysDeny`，也没有拒绝后的恢复状态。
2. **轮询被文档成了无损观察，但 Apple 的契约明确不支持这一结论。** `changeCount` 只累计 ownership change；`Timer` 会延迟并合并错过的 firing。0.5 秒内连续两次复制只能看到最后状态，无法“每个 distinct change count 各捕获一次”。
3. **写剪贴板的成功/失败被全部忽略。** `setData` 的 `Bool` 明确可能为 `false`；当前多个 representation 与 lineage hint 分次写入，随后仍关闭面板并报告完成，存在部分写入与错误成功态。
4. **主线程预览解码与 Apple 响应性指导及 V1/V2 自身契约相反。** `View` 在当前 SDK 是 `@MainActor`；完整预览在 SwiftUI view 中同步创建 `CGImageSource` 并下采样。ImageIO 的下采样方向本身是正确的，但不应把不可预测的图片解析工作放在交互主线程。
5. **设置与 alert 接线依赖私有实现细节。** `showSettingsWindow:` 被源码自己标为非公开；`9a637a6c` 新增 helper 又通过私有类名 `_NSAlertPanel` 判断 alert。后者消除了“没有 `NSApplication.alertWindow` 成员”的源级编译错误，但没有消除平台契约问题。
6. **Launch at Login 把四态授权模型压成一个 Bool 并吞掉错误。** `.requiresApproval` 是已注册但需用户操作；当前 UI 将其显示为关闭，再次注册又可能返回 already-registered/denied，且没有打开 Login Items 设置的恢复路径。
7. **图像类型与多图 HEIF 处理存在确定性错误/假设。** BMP 的公开标识符是 `com.microsoft.bmp`，不是多处硬编码的 `public.bmp`；HEIF 的 primary image 不保证是 index 0。

这些结论不等价于“所有用户都会立刻失败”：剪贴板隐私的具体 prompt 时机、Carbon hotkey 的 TCC/线程行为、非激活 panel 的焦点恢复、SwiftData transaction 的失败原子性等，都必须在 macOS 26 真实运行时验证。关键区别是：**Apple 没有公开承诺的行为，不能被写成已经证明的平台事实。**

### 1.1 结论分类

| 类别 | 数量 | 含义 |
|---|---:|---|
| `confirmed contradiction / gap` | 13 | 源码或 V1/V2 声明与 Apple 公共契约直接不符，或公开 API 状态被实现遗漏 |
| `undocumented / requires measurement` | 8 | 代码可能工作，但 Apple 没有给出所依赖的稳定保证 |
| `aligned` | 7 | 当前设计与 Apple 已公开语义一致；仍不能外推具体性能数字 |

优先级上，剪贴板隐私、写入结果、主线程图片解码、私有 AppKit 依赖和 ServiceManagement 恢复路径应在产品完成声明前关闭；Carbon、焦点与 SwiftData 的未承诺语义需要 macOS 26 proof gate，而不是继续用注释把假设写成事实。

## 2. 核验问题

本次先从源码与 V1/V2 声明抽出不确定问题，再只查 Apple 一手资料：

1. `NSPasteboard.changeCount` 是否能重建每一次复制？程序化读取 General pasteboard 在 macOS 26 的隐私状态是什么？`pasteboardItems`、`data(forType:)` 和自定义 marker 的失败边界是什么？
2. `clearContents()` 后连续 `setData` 是否要求预先 declare type？`setData(nil, ...)` 的含义是什么？每次写入的 `Bool` 能否忽略？
3. Foundation `Timer`、main `RunLoop` 和 Swift `Task.sleep` 是精确时钟吗？main run loop callback 是否等价于 MainActor executor？
4. `.nonactivatingPanel`、`orderFrontRegardless()`、`makeKey()` 能否保证不激活 Clipy，同时精确保留并恢复前一 app 的 paste target？
5. Carbon `RegisterEventHotKey` 在 macOS 26 的正式 availability、callback 线程和 TCC/Accessibility 语义是什么？
6. `Selector("showSettingsWindow:")` 是否属于公开 API？macOS 26 是否已有公开 SwiftUI 设置入口？
7. `SMAppService` 的 `.requiresApproval`、register/unregister error 与 System Settings 恢复路径是什么？
8. SwiftData 对手工 `ModelContext`、plain actor、`ModelActor`、`transaction`、custom migration、`.externalStorage`、`propertiesToFetch` 和 `#Index` 分别承诺什么？哪些性能/失败原子性并未承诺？
9. ImageIO 的 downsample、cache timing、HEIF primary image、PNG byte determinism 有哪些公开保证？当前 UI 是否在 MainActor 上解码？
10. 当前 panel、context menu、Settings、keyboard、accessibility、localization 与 Apple HIG 是否一致？
11. `LSUIElement` + 隐藏 `MenuBarExtra` + AppDelegate `NSStatusItem` 的生命周期是否有公开保证？所谓 “paste” 是否真的向目标应用发送 Paste 命令？

## 3. 已确认的冲突或实现缺口

### APL-C-01 — General pasteboard 隐私状态没有产品模型

- **优先级：P0 / release blocker**
- **Apple 官方结论。** `NSPasteboard.accessBehavior` 和 `NSPasteboard.AccessBehavior` 自 **macOS 15.4+** 可用。公开 enum 说明 General pasteboard 的 `.default` 对程序化访问采取询问；首次 alert 后进入 `.ask`，用户可在 System Settings 改成 always allow/deny。`.alwaysDeny` 仍允许“用户发起且与粘贴相关”的读取，但后台轮询不能假定自己属于这一豁免。[`accessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-86972)、[`AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)（访问 **2026-08-20T00:23:21Z–00:23:22Z**）。Apple 的 April 2025 AppKit update 还说明，新的 detect API 可在不触发读取通知的情况下检查类型；但该页面只称这是 “upcoming feature”，没有写精确 rollout build，因此 prompt 的具体 macOS 26 时机仍需实测。[AppKit updates](https://developer.apple.com/documentation/updates/appkit)（访问 **2026-08-20T00:23:24Z**）。
- **Clipy 现状。** production adapter 默认持有 `.general`，`capture` 立即读取 `pasteboardItems` 与每种 data（[`PasteboardAdapter.swift:29–38`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L29)、[`:65–94`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L65)）；observer 每次启动先捕获当前内容，然后每 0.5 秒继续捕获（[`PasteboardObserver.swift:26–49`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L26)、[`:78–86`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L78)）。`git grep accessBehavior 9a637a6c -- Sources ClipyApp` 无结果。`project.yml` 只生成 Info.plist 并设置 `LSUIElement`（[`project.yml:9–30`](../../../ClipyApp/project.yml#L9)）。
- **冲突/风险。** 核心捕获在 onboarding 前就可能触发隐私 UI；deny 后，当前 `nil`/空捕获路径只会静默不入库，用户无法区分“剪贴板为空”和“系统拒绝读取”。Apple 资料没有给出一个可据此添加的 macOS pasteboard usage-description key；本报告因此**不建议凭空添加 plist key**。
- **必须验证。** 在全新 TCC profile 上覆盖 `.default/.ask/.alwaysAllow/.alwaysDeny`；分别测试冷启动已有内容、前台/后台复制、状态切换、重启、用户从 panel 明确发起 Copy/Paste。记录 prompt、`accessBehavior`、实际读取结果和可恢复 UX。把“无权限/待询问/已允许/已拒绝”建成明确状态，而不是 `capture == nil`。

### APL-C-02 — `changeCount` + 0.5 秒 Timer 不是无损事件流

- **优先级：P0 / correctness**
- **Apple 官方结论。** `changeCount` 只保证 ownership 每次变化时递增；它不是通知，也不保存历史 payload。Apple 的 `Timer` 文档明确说 timer 不是 real-time，run loop 忙或不监听该 mode 时会晚触发；若错过多个 repeating fire，只补一次。`.common` 只是包含若干 mode 的 pseudo-mode。[`changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)（Apple DocC 未给精确引入版本；访问 **2026-08-20T00:24:37Z**）、[`Timer`](https://developer.apple.com/documentation/foundation/timer)（macOS 10.0+；访问 **2026-08-20T00:25:24Z**）、[`RunLoop.Mode`](https://developer.apple.com/documentation/foundation/runloop/mode)（macOS 10.0+；访问 **2026-08-20T00:25:25Z**）。
- **Clipy 现状。** 注释声称“one frozen capture per distinct change count”，实现却只保存一个 `lastChangeCount`，tick 时若数值不同就读取**当前**内容一次（[`PasteboardObserver.swift:15–17`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L15)、[`:29–32`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L29)、[`:61–86`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L61)）；`AppComposition` 又把该假设写成“one capture per distinct changeCount”（[`AppComposition.swift:189–202`](../../../ClipyApp/Sources/AppComposition.swift#L189)），`PROGRESS` 也将其当作已交付行为（[`PROGRESS.md:630–638`](../../PROGRESS.md#L630)）。
- **冲突/风险。** 若 changeCount 在相邻 tick 之间从 10 跳到 12，代码只能冻结 12 对应的当前 pasteboard，10→11 的内容已经不可恢复。主 run loop 忙、modal/event tracking 或任何同步 capture 工作耗时都会扩大窗口；0.5 秒是期望 cadence，不是最大捕获延迟。
- **必须验证。** 用独立 helper 在 500 ms 内写入 2/5/20 次不同内容，另加 main-thread 100/500/1500 ms 阻塞、sleep/wake、fast user switching、modal panel 与拖拽；断言并记录**丢失率**而不是错误地要求无损。产品文案与规格应明确 “best-effort latest-state polling”，若无损历史是硬需求，则现有 NSPasteboard API 不能提供该保证。Apple 还建议 repeating timer 至少给约 10% tolerance 以改善能耗；当前 timer 未设置 tolerance，应在延迟/丢失预算明确后测 50 ms 左右容忍度与 Energy Log，而不是把 zero tolerance 当准实时保证。

### APL-C-03 — 多 item、读取错误和 “source application” 被压成错误的成功模型

- **优先级：P1**
- **Apple 官方结论。** pasteboard 可以包含多个 item；`pasteboardItems` 返回所有 item，发生 retrieval error 时返回 `nil`。[`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard)、[`pasteboardItems`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboarditems)（macOS 10.6+；访问 **2026-08-20T00:24:38Z–00:25:08Z**）。pasteboard-level `NSPasteboard.data(forType:)` 可因内容已改变或 provider timeout 返回 `nil`，Apple 甚至建议 paste 操作向用户报告失败；Clipy 实际调用的 `NSPasteboardItem.data(forType:)` 自 macOS 10.6+，其 symbol page只说明返回 optional data，并**没有**同样详细的 timeout/ownership 语义。因此 item-level `nil` 的精确原因必须保留为 undocumented，而不能直接套用另一个方法的说明。[`NSPasteboard.data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/data(fortype:))、[`NSPasteboardItem.data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboarditem/data(fortype:))（访问 **2026-08-20T00:24:40Z、00:25:02Z**）。`NSWorkspace.frontmostApplication` 只表示接收键盘事件的 app，不表示 pasteboard owner。[`frontmostApplication`](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)（macOS 10.7+；访问 **2026-08-20T00:24:44Z**）。
- **Clipy 现状。** `capture` 固定 `.first`，注释把第一 item 称作 general pasteboard 的 “standard shape”；对每个 type 的 `nil` 或空 data 直接跳过，剩余 representation 仍可提交；`sourceApplication` 取读取时的 frontmost bundle ID（[`PasteboardAdapter.swift:41–64`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L41)、[`:65–93`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L65)）。
- **冲突/风险。** 多文件、多 selection、多对象复制被静默截断，这是公开 multi-item 模型与实现的直接差异。任一 item representation 返回 nil/empty 时当前代码仍可能提交其余部分，但 Apple 没有为 item-level nil 给出足够原因分类，故“是否会形成部分 durable item”应通过 runtime fixture 证明；一个后台工具写 pasteboard 时，frontmost app 被记录为来源则是字段语义上的确定误归因。
- **建议验证。** 规定并公开 multi-item policy（完整保留、按 item 拆分或明确不支持）；在同一冻结动作前后复核 changeCount；item-level data 返回 nil 时整次 fail closed 或以显式 incomplete 状态报告，不能未经证据把其余 bytes 当完整 Canonical Content。把来源改成“观察时 frontmost app”或留空；用后台 helper、Finder 多文件、Promises、ownership race 与慢 provider 做矩阵。

### APL-C-04 — pasteboard 写入返回值被忽略；Apple 文档对 declare 又互相矛盾

- **优先级：P0 / data transfer**
- **Apple 官方结论。** `setData(_:forType:)` 返回 `false` 表示 ownership 已变化，其他通信错误会抛 Objective-C exception；其 symbol page 还说 type 必须由此前 `declareTypes` 声明。可是 `NSPasteboard` 顶层官方示例又明确展示 `clearContents(); setData(...)`，没有 `declareTypes`。因此“clear 后直接 setData 是否正式满足 declaration 前置条件”在 Apple 当前文档中是**内部矛盾，不能任选一边写成保证**。[`setData`](https://developer.apple.com/documentation/appkit/nspasteboard/setdata(_:fortype:))（Apple DocC 未给精确引入版本；访问 **2026-08-20T00:23:25Z**）、[`NSPasteboard` overview](https://developer.apple.com/documentation/appkit/nspasteboard)（访问 **2026-08-20T00:25:08Z**）。`writeObjects` 自 macOS 10.6+ 可一次提交 `[NSPasteboardWriting]` 并返回整体成功 Bool。[`writeObjects`](https://developer.apple.com/documentation/appkit/nspasteboard/writeobjects(_:))（访问 **2026-08-20T00:24:41Z**）。
- **Clipy 现状。** `write` 先 clear，再逐个 `setData`，最后另写 lineage；每个 Bool 都被丢弃，函数返回 `Void`（[`PasteboardAdapter.swift:97–122`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift#L97)）。`AppComposition.paste` 无论写入是否完整都会调用 `onPasteCompleted`（[`AppComposition.swift:205–227`](../../../ClipyApp/Sources/AppComposition.swift#L205)）。
- **冲突/风险。** 任一 representation 或 lineage 失败都可能留下部分 pasteboard，同时 UI 关闭且没有 error。lineage 失败尤其会让自己的下一轮 capture 无法按设计 coalesce。`setData` 的参数是 `Data?`，但 Apple 只说明它是“要写的数据”，没有说明 `nil` 的特殊语义；当前代码从未传 nil，所以这不是当前 bug，但未来也不能把 nil 当清除/承诺值。
- **建议验证。** 先在本地 `NSPasteboardItem` 组装完整 representations，检查 item setter 的 Bool，再用一次 `writeObjects` 并向上返回结果；不要把 `writeObjects` 进一步宣传成 Apple 已承诺的跨进程原子 transaction，因为 Apple 只承诺 Bool。用竞争 writer 在每一步抢 ownership，覆盖任一 type、lineage 与 overall write 失败；UI 只在完整成功后关闭。General pasteboard 会自动参与 Universal Clipboard；若某次重写必须限制在本机，Apple 提供 macOS 10.12+ 的 `prepareForNewContents(with: .currentHostOnly)`，而当前 `clearContents()` 没有表达这个选择。[`NSPasteboard` overview](https://developer.apple.com/documentation/appkit/nspasteboard)、[`currentHostOnly`](https://developer.apple.com/documentation/appkit/nspasteboard/contentsoptions/currenthostonly)（访问 **2026-08-20T00:24:43Z–00:25:08Z**）。产品需明确同步/本机策略；Apple 没有承诺自定义 lineage UTI 如何跨设备传播，不能拿它当 cross-device identity guarantee。

### APL-C-05 — 六个私有 marker 是启发式约定，不是三个 “NSPasteboard framework markers”

- **优先级：P1 / privacy**
- **Apple 官方结论。** Apple 的公开 `NSPasteboard.PasteboardType` 清单包含 string、RTF、HTML、PNG、TIFF、file URL 等，但没有 `org.nspasteboard.ConcealedType`、`TransientType` 或 `AutoGeneratedType`。[`PasteboardType`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype)（Apple DocC 未给精确引入版本；访问 **2026-08-20T00:24:42Z**）。Apple 没有公开承诺这些 raw strings 的含义、完整性或跨 app 采用率。
- **Clipy 现状。** 注释先称其为 “three NSPasteboard framework markers”，下一段又正确称 `nspasteboard.org conventions`；实现是六个 raw strings 的 Set（[`PasteboardMarkers.swift:18–41`](../../../Sources/PasteboardAdapter/PasteboardMarkers.swift#L18)）。同一集合也进入 V1 preparation 规范（[`05-authority-kernel.md:297–305`](../../05-authority-kernel.md#L297)）。
- **冲突/风险。** whole-capture rejection 是合理的 defense in depth，但它不能成为“敏感内容绝不会入库”的 Apple 平台证明：未采用 marker 的密码管理器、应用自定义 marker、未来变更都会漏过。
- **建议验证。** 把文档措辞改成 “third-party conventions / best-effort denylist”；对目标密码管理器逐版本做真实复制矩阵，并提供全局暂停、按 app 排除和立即清空等用户控制。不要记录被拒绝内容或 marker payload。

### APL-C-06 — BMP/GIF UTI 与 HEIF primary-image 选择

- **优先级：P1**
- **Apple 官方结论。** `UTType.bmp.identifier == "com.microsoft.bmp"`，`UTType.gif.identifier == "com.compuserve.gif"`；二者自 macOS 11+ 可用。HEIC/HEIF 的公开标识符分别是 `public.heic` / `public.heif`。[`UTType.bmp`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/bmp)、[`gif`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/gif)、[`heic`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/heic)、[`heif`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/heif)（访问 **2026-08-20T00:28:39Z–00:28:43Z**）。`CGImageSourceGetPrimaryImageIndex` 自 macOS 10.14+ 返回 HEIF primary image 的 index，非 HEIF 才固定返回 0。[`CGImageSourceGetPrimaryImageIndex`](https://developer.apple.com/documentation/imageio/cgimagesourcegetprimaryimageindex(_:))（访问 **2026-08-20T00:28:15Z**）。
- **Clipy 现状。** `public.bmp` 出现在 Storage authority（[`HistoryAuthority+DetailAndThumbnail.swift:146–161`](../../../Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift#L146)）、projector、details、thumbnail store 和 preview（[`ThumbnailStore.swift:61–74`](../../../Sources/PresentationUI/ThumbnailStore.swift#L61)、[`HistoryPreviewView.swift:85–96`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L85)），集成 fixtures 也用同一错误值。row icon heuristic 另用不存在的 `public.gif`（[`HistoryRowView.swift:191–211`](../../../Sources/PresentationUI/HistoryRowView.swift#L191)）。Storage thumbnail 与 full preview 都固定 index 0（[`ThumbnailService.swift:275–285`](../../../Sources/HistoryStorage/ThumbnailService.swift#L275)、[`HistoryPreviewView.swift:188–198`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L188)）。
- **冲突/风险。** 来自真实 AppKit/UTType 的 BMP 不会进入 thumbnail/preview path；纯 GIF 可能显示通用 icon。多图 HEIF 的主图若不是第 0 张，当前实现选择错误图片。
- **建议验证。** 运行时/fixture 均从 `UTType.*.identifier` 取得稳定值；增加真实 `com.microsoft.bmp` 和 primary index 非 0 的 HEIF fixture，Storage thumbnail、list、details、full preview 使用同一 type registry 与同一 primary-index rule。

### APL-C-07 — ImageIO 方向正确，但完整预览与 thumbnail 展示仍在 MainActor 解码

- **优先级：P0 / responsiveness**
- **Apple 官方结论。** 当前 SwiftUI `View` 是 `@MainActor`；在原始声明中 conform 的类型默认继承该 isolation。[`View`](https://developer.apple.com/documentation/swiftui/view)（macOS 10.15+；访问 **2026-08-20T00:28:50Z**）。Apple 要求 main thread 只做 UI，非 UI preparation 放后台；离散交互约 100 ms 已明显，连续交互应以约 5 ms 为目标。[Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)（当前 Xcode 文档；访问 **2026-08-20T00:28:50Z**）。ImageIO thumbnail 的 max-pixel 与 orientation transform 是公开能力；WWDC18 说明 ImageIO downsample 采用 streaming，避免先完整解压原图的 dirty-memory spike。[`CGImageSourceCreateThumbnailAtIndex`](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:))（macOS 10.4+；访问 **2026-08-20T00:28:14Z**）、[WWDC18/416](https://developer.apple.com/videos/play/wwdc2018/416/)（访问 **2026-08-20T00:28Z**）。
- **Clipy 现状。** Storage 的 `ThumbnailWorker` 在 Authority 外做有 pixel bound 的 ImageIO downsample，这是正确方向（[`ThumbnailService.swift:245–330`](../../../Sources/HistoryStorage/ThumbnailService.swift#L245)）。但完整 preview 是 `View` 内的同步 static method，直接 `CreateWithData` + `CreateThumbnailAtIndex`（[`HistoryPreviewView.swift:160–198`](../../../Sources/PresentationUI/HistoryPreviewView.swift#L160)）。`ThumbnailStore` 也在 `@MainActor` 上用 `CGImageSourceCreateImageAtIndex(..., nil)` 解码 PNG（[`ThumbnailStore.swift:21–28`](../../../Sources/PresentationUI/ThumbnailStore.swift#L21)、[`:99–130`](../../../Sources/PresentationUI/ThumbnailStore.swift#L99)、[`:148–168`](../../../Sources/PresentationUI/ThumbnailStore.swift#L148)）。Apple 说明 `kCGImageSourceShouldCacheImmediately` 默认 false，`CreateImageAtIndex` 的实际 decode/cache 因而可能推迟到 render；`ShouldCache` 在 64-bit 默认 true。[`ShouldCacheImmediately`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately)、[`ShouldCache`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcache)（macOS 10.9+/10.4+；访问 **2026-08-20T00:28:19Z–00:28:20Z**）。
- **规范冲突。** V1 明确写 main actor “No … image decode”（[`01-architecture.md:180–197`](../../01-architecture.md#L180)）；V2-07 再次禁止 main-actor decode 与 PresentationUI 的 ImageIO import（[`V2-07-ux.md:130–141`](../../v2/V2-07-ux.md#L130)、[`:903–914`](../../v2/V2-07-ux.md#L903)）。当前 `HistoryPreviewView` 与 `ThumbnailStore` 直接 import ImageIO。
- **风险/验证。** “full bitmap never materializes”有 ImageIO streaming 依据，但不能推出 CPU 延迟有界或主线程安全。将 source selection/decode/downsample 放入非 main actor worker，只把完成的 bounded Sendable output 与版本 fence 回主 actor；在最大合法图片、损坏/渐进/多帧文件、快速 selection churn 下测 main-thread p50/p95/p99、hang、取消与 stale apply。对小 PNG display decode 也要用 Instruments 证明不超过连续交互预算。

### APL-C-08 — 设置入口使用私有 selector，`activate()` 也不是成功保证

- **优先级：P1**
- **Apple 官方结论。** `SettingsLink` 与 `OpenSettingsAction` 自 **macOS 14+** 是公开入口；前者打开或将现有 Settings window order front，后者从 SwiftUI environment 呈现 app 的 `Settings` scene。[`SettingsLink`](https://developer.apple.com/documentation/swiftui/settingslink)、[`OpenSettingsAction`](https://developer.apple.com/documentation/swiftui/opensettingsaction)、[`EnvironmentValues.openSettings`](https://developer.apple.com/documentation/swiftui/environmentvalues/opensettings)（访问 **2026-08-20T00:23:28Z、00:26:26Z–00:26:27Z**）。`NSApplication.activate()` 自 macOS 14+ 只请求 activation，Apple 明说不保证成功。[`activate()`](https://developer.apple.com/documentation/appkit/nsapplication/activate())（访问 **2026-08-20T00:25:48Z**）。
- **Clipy 现状。** `openSettingsWindow` 先 `NSApp.activate()`，再发送 string-built `Selector("showSettingsWindow:")`；注释直接承认 selector 不是 public API，却又声称 activation 能防止窗口被挡（[`AppDelegate.swift:193–203`](../../../ClipyApp/Sources/AppDelegate.swift#L193)）。公开 `Settings` scene 已存在（[`ClipyAppMain.swift:25–37`](../../../ClipyApp/Sources/ClipyAppMain.swift#L25)）。
- **冲突/风险。** macOS 26 已无需依赖这个私有 responder selector；私有 action 可改名、消失或在 LSUIElement activation 状态下无 receiver。activation 失败时当前代码也不检测结果。
- **建议验证。** 从 SwiftUI surface 注入 `openSettings`/使用 `SettingsLink`，AppDelegate 只接收公开 closure；测试 inactive LSUIElement、Settings 已打开、另一 Space/full-screen、多个显示器以及 cooperative activation。不要把 `activate()` 的 request 写成保证。

### APL-C-09 — `SMAppService.Status` 四态被压扁且恢复错误被吞掉

- **优先级：P0 / settings correctness**
- **Apple 官方结论。** `SMAppService` 自 **macOS 13+**。`.requiresApproval` 表示服务已经注册，但用户必须在 System Settings 操作，或此前同意已被撤销。`register()` 受用户批准约束，并可返回 already-registered / launch-denied；Apple 提供 `openSystemSettingsLoginItems()`。其迁移指导要求解释 helper 用途、检查授权状态，必要时提示用户并打开 Login Items pane。[`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice)、[`requiresApproval`](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval)、[`register()`](https://developer.apple.com/documentation/servicemanagement/smappservice/register())、[`openSystemSettingsLoginItems()`](https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems())（访问 **2026-08-20T00:23:26Z–00:27:03Z**）。注：Apple DocC 对嵌套 `Status` 页面显示了不可信的 macOS 10.6+，但拥有该类型的 `SMAppService` 类与 register API 明确是 macOS 13+；本报告采用 owning API 的 availability。
- **Clipy 现状。** Binding 只在 `.enabled` 时为 true；setter 调 register/unregister，catch 空掉所有错误（[`AppDelegate.swift:214–235`](../../../ClipyApp/Sources/AppDelegate.swift#L214)）。
- **冲突/风险。** `.requiresApproval` 会显示“关闭”，用户再打开时对已注册服务的 register 可能报错，UI 又静默弹回 false，形成无解释死路；`.notFound` 也与普通关闭不可区分。unregister 已处于未注册时同样可报 job-not-found，仍被吞掉。
- **建议验证。** UI 明确建模全部 status 与 typed recovery；`.requiresApproval` 显示“等待系统批准/已被撤销”并经用户动作打开 Login Items；保留错误供可访问的 inline feedback。覆盖 fresh install、denied、revoked、already registered、not found、外部 System Settings 切换和重启。

### APL-C-10 — 当前动作是 Copy，不是向前一 app 执行 Paste

- **优先级：P1 / capability semantics**
- **Apple 官方结论。** `NSPasteboard` 负责在 pasteboard server 提供数据；写入不会自动让其他 app 执行 Paste。Apple HIG 的标准 Paste 动作是 Command-V。若产品选择合成键盘事件，`CGEvent.post` 是公开 posting primitive，而 `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` 自 macOS 10.15+ 提供 posting-access 检查/请求；Apple symbol pages未进一步承诺授权 UX。[`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard)（访问 **2026-08-20T00:25:08Z**）、[HIG Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)（访问 **2026-08-20T00:26:47Z**）、[`CGEvent.post`](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:))（macOS 10.4+）、[`CGPreflightPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()) / [`CGRequestPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess())（macOS 10.15+；访问 **2026-08-20T00:28:58Z–00:29:00Z**）。
- **Clipy 现状。** `AppComposition.paste` 只 resolve payload、写 general pasteboard、关闭 panel；没有 CGEvent、AX action 或目标 app command（[`AppComposition.swift:205–227`](../../../ClipyApp/Sources/AppComposition.swift#L205)）。UI 行为已诚实标为 “Copy to Clipboard”（[`HistoryRowView.swift:214–267`](../../../Sources/PresentationUI/HistoryRowView.swift#L214)），但 AppComposition/AppDelegate/PROGRESS 的注释仍称 paste target 会“receives the paste”（[`AppDelegate.swift:141–155`](../../../ClipyApp/Sources/AppDelegate.swift#L141)、[`PROGRESS.md:763–789`](../../PROGRESS.md#L763)）。
- **冲突/风险。** 平台行为与内部“paste completed”命名不一致；与 Maccy 比较时不能把 copy-only 计为 automatic paste。反过来，也不能为了功能对齐就悄悄加入 event posting，因为它带来新的 TCC/Accessibility、secure input 和用户意图边界。
- **建议验证。** 产品明确选择 “copy” 或 “copy and paste”。前者统一命名/文案；后者先设计授权、失败、secure input、目标焦点与 opt-out，再用 posting-access API 做 macOS 26 矩阵，拒绝时保留 copy-only fallback。

### APL-C-11 — `9a637a6c` 修了成员缺失，却引入 `_NSAlertPanel` 私有类名依赖

- **优先级：P0 / private API stability**
- **Apple 官方结论。** 公开 API 有 `NSApplication.modalWindow`（只覆盖 standalone modal window）、`NSWindow.attachedSheet`/`sheets`（覆盖 sheet），以及持有 `NSAlert` 时的 `NSAlert.window`。`NSApplication.windows` 包含可见和不可见、任意 Space 的所有 window，而且顺序无保证。Apple 没有公开 `NSApplication.alertWindow`，也没有公开 `_NSAlertPanel` 类名契约。[`modalWindow`](https://developer.apple.com/documentation/appkit/nsapplication/modalwindow)（Apple DocC 未给精确引入版本；访问 **2026-08-20T00:33:31Z**）、[`attachedSheet`](https://developer.apple.com/documentation/appkit/nswindow/attachedsheet)、[`sheets`](https://developer.apple.com/documentation/appkit/nswindow/sheets)（macOS 10.9+ for `sheets`；访问 **2026-08-20T00:33:15Z**）、[`NSAlert.window`](https://developer.apple.com/documentation/appkit/nsalert/window)、[`NSApplication.windows`](https://developer.apple.com/documentation/appkit/nsapplication/windows)（访问 **2026-08-20T00:33:13Z–00:33:17Z**）。
- **Clipy 现状。** `resignKey` 访问本地 extension 的 `alertWindow`；helper 遍历 `windows.first` 并比较 `className == "_NSAlertPanel"`，注释承认这是 AppKit-private class name（[`FloatingPanel.swift:130–139`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L130)、[`:218–224`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L218)）。
- **判定。** 该 extension 确实为 `NSApplication` 补上了成员，所以此前“引用不存在的公开成员”的**源级 S-5 编译问题已经消除**；本环境无法替代 Xcode 26 重编译确认。行为层面并未关闭：私有类名可变，offscreen 旧 alert 也可能被误命中，SwiftUI `confirmationDialog` 或 sheet 不必使用该类名。
- **建议验证。** 只用公开 `modalWindow`、`attachedSheet`/`sheets` 或由创建者显式持有的 `NSAlert.window`/modal state；覆盖 app-modal NSAlert、sheet、SwiftUI confirmationDialog、无 alert、已 order-out alert 和多个窗口。禁止把私有 class name 作为发布 gate。

### APL-C-12 — window style 中有确定无效项；panel/HIG 是有意偏离而非已证明更优

- **优先级：P1**
- **Apple 官方结论。** `.nonactivatingPanel` 表示 panel 不激活 owning app；`orderFrontRegardless` 只把 window 放到本 level 最前，明确不改变 key/main，Apple 说应很少使用；`makeKey` 才使 window 成为 key。[`nonactivatingPanel`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)、[`orderFrontRegardless`](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless())、[`makeKey`](https://developer.apple.com/documentation/appkit/nswindow/makekey())（Apple DocC 未给精确引入版本；访问 **2026-08-20T00:23:29Z–00:25:39Z**）。`.fullSizeContentView` 自 macOS 10.10+ **只对有 title bar 的 window 生效**。[`fullSizeContentView`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/fullsizecontentview)（访问 **2026-08-20T00:30:14Z**）。`stationary` 使窗口不受 Mission Control 影响、持续可见；`fullScreenAuxiliary` 使其出现在 full-screen window 的同一 Space。[`stationary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary)、[`fullScreenAuxiliary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)（macOS 10.6+/10.7+；访问 **2026-08-20T00:25:41Z–00:25:42Z**）。
- **Clipy 现状。** style mask 是 `[.nonactivatingPanel, .closable, .fullSizeContentView]`，没有 `.titled`；panel 设 `.statusBar`、`.stationary`、`.moveToActiveSpace`、`.fullScreenAuxiliary`、`hidesOnDeactivate = false`（[`FloatingPanel.swift:55–81`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L55)）。因此 `.fullSizeContentView` 是公开文档确认的无效 flag。
- **HIG 边界。** Apple 建议 floating panel 只有在小、主要面向鼠标、需伴随本 app 标准窗口、且 app deactivated 时隐藏的全部条件满足时使用；Panels HIG 也偏好简单 adjustment controls、避免文本输入/复杂选择，并要求 app inactive 时隐藏。[`NSPanel.isFloatingPanel`](https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel)、[HIG Panels](https://developer.apple.com/design/human-interface-guidelines/panels)（访问 **2026-08-20T00:25:40Z–00:25:44Z**）。Clipy 的 search/list/keyboard-heavy 跨 app chooser 不符合典型 inspector/tool palette 模型。这可以是合理的专用产品模式，但不是“HIG 自动证明更合理”。
- **风险/验证。** `.stationary`/full-screen visibility 会增加敏感历史在 Mission Control、屏幕共享与 full-screen app 上暴露的机会。做多 Space/full-screen/Stage Manager/多显示器/屏幕共享/锁屏与 deactivation 矩阵；为隐私用户提供易理解的自动隐藏/暂停选择，并记录为什么专用 chooser 偏离标准 panel guidance。

### APL-C-13 — context-menu、accessibility 与 localization 尚达不到 V2 的 state-3 声明

- **优先级：P1 / release evidence**
- **Apple 官方结论。** HIG 要求 context-menu action 同时在主界面可用；macOS menu bar 应列出 app commands。[HIG Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)（访问 **2026-08-20T00:26:31Z**）。Full Keyboard Access 应能只用键盘导航/激活界面；Command-Comma 是 Settings 标准快捷键；Shift-Command-C 的系统标准含义是显示 Colors window。[HIG Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)（访问 **2026-08-20T00:26:47Z**）。macOS Settings HIG要求从 App menu/Command-Comma 打开，pane toolbar 稳定且指示当前 pane，并恢复最近使用的 pane。[HIG Settings](https://developer.apple.com/design/human-interface-guidelines/settings)（访问 **2026-08-20T00:26:30Z**）。Apple accessibility test guidance要求把每个主要任务放入 VoiceOver/Voice Control/Switch Control/视觉设置矩阵，并检查每个 element 的名称、状态和顺序。[Performing accessibility testing](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app)、[HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)（访问 **2026-08-20T00:26Z–00:26:47Z**）。String Catalog 用于提取、翻译与 plural variants；多数 SwiftUI literal 可自动提取，但必须有 catalog 并测试语言/地区。[String Catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)、[Preparing SwiftUI views](https://developer.apple.com/documentation/swiftui/preparing-views-for-localization)（访问 **2026-08-20T00:26:36Z–00:26:37Z**）。
- **Clipy 现状。** row 的 move top/bottom、pin/unpin/remove/details 主要在 context menu（[`HistoryRowView.swift:214–268`](../../../Sources/PresentationUI/HistoryRowView.swift#L214)）；selection shortcuts 是 0×0、opacity 0 且 accessibility-hidden 的 Button（[`HistoryListView.swift:139–190`](../../../Sources/PresentationUI/HistoryListView.swift#L139)），snapshot 中没有 `.commands`/`CommandMenu`。默认全局 hotkey 是 Shift-Command-C（[`GlobalHotKey.swift:41–64`](../../../ClipyApp/Sources/HotKey/GlobalHotKey.swift#L41)），与 HIG 的 Colors 标准 shortcut 冲突。Settings 是固定 480×320 的两页 `TabView`，没有显式 selection persistence（[`ClipySettingsView.swift:22–77`](../../../Sources/PresentationUI/ClipySettingsView.swift#L22)）；SwiftUI 可能提供部分标准 pane chrome，但“恢复最近 pane/缩放与大字布局”仍需宿主运行时验证，不能仅凭静态视图判失败或通过。`git ls-tree -r --name-only 9a637a6c` 没有 `.xcstrings`/Localizable.strings；代码还有大量 computed `String` 与手写英文 plural，例如 item count（[`HistoryPanelView.swift:227–250`](../../../Sources/PresentationUI/HistoryPanelView.swift#L227)）和 receipt feedback（[`ClipySettingsView.swift:278–300`](../../../Sources/PresentationUI/ClipySettingsView.swift#L278)）。
- **冲突/风险。** 静态存在若干 `accessibilityLabel` 不等于完成 accessibility；当前没有证据证明非激活 panel 的 focus order、combined row + context actions、details/revise/settings 能由 VoiceOver/Full Keyboard Access 完成。V2-07 要求每个 UI element 本地化与 accessibility-labeled（[`V2-07-ux.md:130–155`](../../v2/V2-07-ux.md#L130)、[`:766–817`](../../v2/V2-07-ux.md#L766)），当前没有 catalog/语言矩阵。
- **建议验证。** 为所有 row actions 提供可发现的主界面或 app command surface；默认 global hotkey 避开标准 shortcut，并允许录制/冲突反馈。建立任务矩阵：打开、搜索模式、选中、copy、pin/reorder/remove、details/revise、clear、settings、错误恢复；逐一跑 VoiceOver、Full Keyboard Access、Voice Control、Increase Contrast、Reduce Motion、较大文字与 RTL。添加 String Catalog，验证 plural/date/byte/shortcut localization，而不是只看英文 snapshot。

## 4. Apple 未承诺的依赖：必须保持 `undocumented / requires measurement`

### APL-U-01 — Carbon `RegisterEventHotKey` 的 macOS 26 契约不完整

- **Apple 资料边界。** Apple 当前 Developer Documentation 搜索没有 `RegisterEventHotKey`、`GetEventDispatcherTarget` 的现代 symbol page，因此没有可引用的当前 availability、callback queue/MainActor 或 TCC 保证。Apple 的 retired 64-bit Carbon guide只说部分 Carbon Event Manager API 不适用于 64-bit、具体函数应查 SDK headers；它没有给 `RegisterEventHotKey` 的 macOS 26 承诺。[64-Bit Guide / HIToolbox changes](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/Carbon64BitGuide/HIToolboxChanges/HIToolboxChanges.html)（检索/访问 **2026-08-20T00:29Z–00:30Z**）。Apple Frameworks Engineer 在 Developer Forums 说明 macOS 15 曾主动改变 hotkey modifier 行为，后又在 15.2 beta 调整；这只能证明行为会变，不能替代正式线程/TCC契约。[Apple Developer Forums thread 763878](https://developer.apple.com/forums/thread/763878)（访问 **2026-08-20T00:29Z**）。
- **Clipy 依赖。** 注释断言 Carbon hotkey “needs no accessibility grant” 且 dispatcher-target handler 一定 main thread；callback 直接 `MainActor.assumeIsolated`（[`GlobalHotKey.swift:1–17`](../../../ClipyApp/Sources/HotKey/GlobalHotKey.swift#L1)、[`:72–110`](../../../ClipyApp/Sources/HotKey/GlobalHotKey.swift#L72)、[`:133–165`](../../../ClipyApp/Sources/HotKey/GlobalHotKey.swift#L133)）。Swift 文档明确说 `assumeIsolated` 若当前不在 MainActor serial executor 会 fatal error（macOS 10.15+）。[`MainActor.assumeIsolated`](https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:))（访问 **2026-08-20T00:25:26Z**）。
- **判定/验证。** 目前 registration 会检查 `OSStatus` 并 graceful false，这是好的；但“无需 TCC”和“callback 在 MainActor”只能标为 undocumented。必须在无 Accessibility/Input Monitoring 权限的 clean macOS 26 account、授权/拒绝后、secure input、sleep/wake、fast user switch、shortcut conflict、不同键盘布局与重复注册下验证；callback 入口先断言线程/executor并采集 crash-free 证据。若保留 Carbon，记录 SDK header availability/deprecation 和 notarized release build 证据。

### APL-U-02 — main RunLoop callback 不应被文字等同于 MainActor executor

- **Apple 资料边界。** `RunLoop.main`/Timer 能确定工作在 main run loop/thread；`MainActor.assumeIsolated` 检查的却是 MainActor serial executor。Apple 响应性文档说明 main run loop、main queue、main actor 都在主线程上协作，但并没有承诺“所有 main-run-loop callback 都等于正在执行 MainActor executor”。[`Timer`](https://developer.apple.com/documentation/foundation/timer)、[`MainActor.assumeIsolated`](https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:))、[Understanding hangs](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app)（macOS 10.0+/10.15+；访问 **2026-08-20T00:25Z–00:26Z**）。
- **Clipy 依赖。** Timer closure 用 `MainActor.assumeIsolated { poll() }`，注释把 main thread 直接称为 guarantee（[`PasteboardObserver.swift:51–66`](../../../Sources/PasteboardAdapter/PasteboardObserver.swift#L51)）。
- **判定/验证。** 这在当前 runtime 很可能成立，但公开文档没有提供 reverse-equivalence 保证；必须覆盖普通 app run loop、modal/event-tracking nested loop 和测试手工 spin。任何不能证明的 path 应安全 hop 到 MainActor，而不是 fatal assertion。

`Task.sleep(for:tolerance:clock:)` 自 macOS 13+ 只承诺按给定 duration 挂起 task、取消时抛 `CancellationError`，且不阻塞 underlying thread；它不承诺恰好在 duration 到点恢复。[`Task.sleep(for:)`](https://developer.apple.com/documentation/swift/task/sleep(for:tolerance:clock:))（访问 **2026-08-20T00:25:27Z**）。Clipy 的 200 ms preview dwell 在 sleep 后检查 cancellation（[`PreviewPaneState.swift:116–130`](../../../Sources/PresentationUI/PreviewPaneState.swift#L116)），search debounce 也捕获取消（[`HistoryViewState.swift:322–333`](../../../Sources/PresentationUI/HistoryViewState.swift#L322)），取消语义方向正确；但 200/250 ms 只能写成目标 suspension interval/调度意图，不是精确 UI deadline。负载、sleep/wake 与 main actor 饥饿下要测实际分布。

### APL-U-03 — 非激活 panel 的“前一 app 精确保留并恢复 paste focus”没有公开保证

- **Apple 资料边界。** `.nonactivatingPanel` 只承诺不激活 owning app；`orderFrontRegardless` 明说自己不改变 key/main；`makeKey` 明说把 Clipy panel 设为 key。这三条没有共同承诺“前一 app 的 first responder、selected field 与 target 在 close 后原样恢复”。[`nonactivatingPanel`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)、[`orderFrontRegardless`](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless())、[`makeKey`](https://developer.apple.com/documentation/appkit/nswindow/makekey())（访问 **2026-08-20T00:23:29Z–00:25:39Z**）。
- **Clipy 依赖。** `open` 依次 `orderFrontRegardless(); makeKey()`，注释称 previously focused app “keeps focus ownership”（[`FloatingPanel.swift:92–120`](../../../ClipyApp/Sources/Panel/FloatingPanel.swift#L92)）；AppComposition/AppDelegate 又以此推导 paste target 始终保留（[`AppComposition.swift:58–63`](../../../ClipyApp/Sources/AppComposition.swift#L58)）。
- **判定/验证。** “owning app不激活”可确认；“前一 app 精确恢复”必须测。覆盖 TextEdit/WebKit/Electron/terminal、secure field、popover/menu、full-screen、Space change、点击 panel、键盘选择、打开 alert/settings、Esc/外点关闭，并在 close 后检查 active app、key window、first responder 与真实 Command-V target。

### APL-U-04 — SwiftData transaction 的成功 save boundary 有文档；throw/commit-failure 原子性没有同等明确文字

- **Apple 官方已承诺。** `ModelContext.transaction(block:)` 自 **macOS 14+**，运行 closure，正常完成后把 pending insert/change/delete 写入 persistent storage；不需要额外 `save()`。[`transaction(block:)`](https://developer.apple.com/documentation/swiftdata/modelcontext/transaction(block:))（访问 **2026-08-20T00:27:15Z**）。
- **未承诺部分。** symbol page 没有明确写出：closure 抛错时自动 rollback 全部 in-memory mutations、save/IO failure 时跨多 row 的可观察 durable atomicity、crash/fsync 边界。页面同时链接显式 `rollback()`，不能仅凭方法名把所有失败语义升级成 Apple guarantee。
- **Clipy 依赖。** executor 注释称 closure failure commits nothing，任何 failure 被统一映射为 `.persistence(.transaction)`（[`HistoryAuthority+TransactionExecution.swift:11–31`](../../../Sources/HistoryStorage/HistoryAuthority+TransactionExecution.swift#L11)、[`:38–87`](../../../Sources/HistoryStorage/HistoryAuthority+TransactionExecution.swift#L38)）。V1/V2 文档进一步把这一点称作 “documented/VERIFIED”（[`01-architecture.md:241–248`](../../01-architecture.md#L241)、[`06-cross-cutting.md:159–170`](../../06-cross-cutting.md#L159)、[`V2-facts.md:992–1008`](../../v2/V2-facts.md#L992)、[`:1826–1844`](../../v2/V2-facts.md#L1826)）。这些文档引用的 Apple 句子只直接支持正常完成后的 save；“closure failure commits nothing”是项目 runtime invariant，不是该引用的完整文字。
- **现有实证。** 这不是“完全没测”：WS13 在临时 on-disk store 内于 row mutation 后、singleton update 前抛错，再用独立 fresh container 验证 durable rows/position 未变，并验证下一次 commit 与 invalidation（[`WS13TransactionFailureTests.swift:36–74`](../../../Tests/HistoryStorageTests/WS13TransactionFailureTests.swift#L36)、[`:84–153`](../../../Tests/HistoryStorageTests/WS13TransactionFailureTests.swift#L84)）；`PROGRESS` 记录该 gate 已在支持的 macOS CI 通过（[`PROGRESS.md:205–236`](../../PROGRESS.md#L205)）。这是有价值的**特定 runtime 行为证据**，但不把 Apple 文档扩写成通用失败/崩溃保证。
- **判定/验证。** fresh context per operation 且失败后释放 context 显著降低风险，现有 WS13 已证明一个关键 throw shape；文档应把它称为 runtime-proved contract。继续扩展 constraint conflict、save/IO failure、disk full/permission loss（安全 fixture）、transaction 中 process kill 与 restart，验证 rows/singleton/HCR/retained-bytes 全部或全无，并记录 durable reopen 结果。

### APL-U-05 — plain actor + 手工 ModelContext 是受约束设计，但不是 Apple 文档指定的 actor/executor 组合

- **Apple 官方已承诺。** SwiftUI environment context 和 `ModelContainer.mainContext` 是 MainActor-bound；外部 view hierarchy 可以从 container 手工创建新 context。`ModelActor` 则明确提供 mutually-exclusive access，其 `modelContext` serializes code on the model actor。[`ModelContext`](https://developer.apple.com/documentation/swiftdata/modelcontext)、[`mainContext`](https://developer.apple.com/documentation/swiftdata/modelcontainer/maincontext)、[`ModelActor`](https://developer.apple.com/documentation/swiftdata/modelactor)、[WWDC23 Meet SwiftData](https://developer.apple.com/videos/play/wwdc2023/10187/)（macOS 14+；访问 **2026-08-20T00:27:16Z–00:27:20Z**）。手工 context 的 autosave 默认 false，Clipy 显式设 false，与文档一致。[`autosaveEnabled`](https://developer.apple.com/documentation/swiftdata/modelcontext/autosaveenabled)（访问 **2026-08-20T00:27:20Z**）。
- **未承诺部分。** Apple 没有在这些页面说明“在任意 plain Swift actor 中创建 `ModelContext`，即可自动把 context 绑定到该 actor executor”，也没有给 plain actor 替代 `ModelActor` 的等价保证。
- **Clipy 依赖。** `HistoryAuthority` 是 plain `actor`，每个操作新建 context、无 suspension、离开即释放（[`HistoryAuthority.swift:163–185`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L163)、[`HistoryAuthority+CaptureCommit.swift:53–68`](../../../Sources/HistoryStorage/HistoryAuthority+CaptureCommit.swift#L53)）；V1 称 off-main manual context 是 documented SwiftData pattern（[`01-architecture.md:188–205`](../../01-architecture.md#L188)）。
- **判定/验证。** 当前 confinement 纪律强且可能完全正确，但文档应把 “manual context allowed” 与 “plain actor executor binding guaranteed” 分开。用 Thread/Concurrency Sanitizer、并发读写/取消/重入压力和 Swift 6.2 strict-concurrency build 证明；并做 `@ModelActor` spike 比较可维护性/性能，而不是假设二者平台语义等价。

### APL-U-06 — custom migration callback 存在，但 callback timing 与内部再开 transaction 未被 Apple 承诺

- **Apple 官方已承诺。** `MigrationStage.custom` 自 **macOS 14+**，`willMigrate`/`didMigrate` 接受 SwiftData 提供的 `ModelContext`；`ModelContainer` 接受 schema migration plan。[`MigrationStage.custom`](https://developer.apple.com/documentation/swiftdata/migrationstage/custom(fromversion:toversion:willmigrate:didmigrate:))、[`ModelContainer.init`](https://developer.apple.com/documentation/swiftdata/modelcontainer/init(for:migrationplan:configurations:)-qof9)（访问 **2026-08-20T00:27:22Z–00:27:23Z**）。
- **未承诺部分。** symbol pages没有说明 callback 相对于 initializer return 的详细 timing、重入/取消/中断恢复，也没有说在 `didMigrate` 收到的 context 上再调用 `context.transaction` 属于受支持的嵌套 transaction 模式。
- **Clipy 依赖。** V1→V2 的 `didMigrate` 调 backfill（[`HistoryMigration.swift:44–60`](../../../Sources/HistoryStorage/HistoryMigration.swift#L44)），backfill 内又调用 `context.transaction`（[`RetainedBytesBackfill.swift:228–248`](../../../Sources/HistoryStorage/RetainedBytesBackfill.swift#L228)）。项目文档已经正确把 callback-before-open timing 留作 runtime assertion（[`V2-facts.md:1708–1714`](../../v2/V2-facts.md#L1708)），但没有同样标注 nested transaction。
- **现有实证。** on-disk V1→V2 test 已通过 migration container 验证 item bytes不变和 1:1 backfill（[`HistoryMigrationTests.swift:86–123`](../../../Tests/HistoryStorageTests/HistoryMigrationTests.swift#L86)、[`:125–184`](../../../Tests/HistoryStorageTests/HistoryMigrationTests.swift#L125)）；engine-level interruption test 让 child 在 backfill compute loop 中退出，再经完整 `SwiftDataHistory.open` 重开并复核 invariants（[`HistoryMigrationInterruptionTests.swift:141–167`](../../../Tests/HistoryStorageTests/HistoryMigrationInterruptionTests.swift#L141)、[`:190–234`](../../../Tests/HistoryStorageTests/HistoryMigrationInterruptionTests.swift#L190)）。后者明确在 transaction 开始**以前**终止，因此没有证明 transaction 执行中 kill 的 crash boundary。
- **判定/验证。** 不能据此判定当前迁移错误；正常 migration 与 pre-transaction interruption 已有很强 runtime 证据。仍应把 nested transaction 独立列为 platform reliance，并增加 transaction 中途 kill、duplicate projection、磁盘失败与 restart；若无法从 SDK/API test 证明 nesting，就避免把 nested behavior 写成 Apple guarantee。

### APL-U-07 — `.externalStorage`/projection 与 `#Index` 不能支撑“内存更小、复杂度更低”的结论

- **Apple 官方已承诺。** `.externalStorage` 自 **macOS 14+** 只说明把 binary value 放在 model storage 邻近位置；没有 threshold、faulting、RSS、file URL 或 latency 保证。[`externalStorage`](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage)（访问 **2026-08-20T00:27:24Z**）。`propertiesToFetch` 自 macOS 14+ 确实只取指定属性，之后访问未取属性会产生额外 fetch，且只是“可能”更快/高效。[`propertiesToFetch`](https://developer.apple.com/documentation/swiftdata/fetchdescriptor/propertiestofetch)（访问 **2026-08-20T00:27:25Z**）。`#Index` 自 **macOS 15+** 可为 key paths 建 index；WWDC24 建议为常用于 filter/sort 的属性建 index，并只声称查询更快，不承诺 Big-O 或具体常数。[`#Index`](https://developer.apple.com/documentation/swiftdata/index(_:)-7d4z0)、[WWDC24/10137](https://developer.apple.com/videos/play/wwdc2024/10137/)（访问 **2026-08-20T00:27:26Z–00:27:53Z**）。
- **Clipy 现状。** schema 对 canonical/revision blobs 使用 `.externalStorage`，而注释正确称其为 hint（[`Schema.swift:65–88`](../../../Sources/HistoryStorage/Schema.swift#L65)）；recent/search 等使用 `propertiesToFetch`，recent 以 `pinOrdinal` 与 `lastCopiedAt` filter/sort（[`HistoryAuthority+RecentReads.swift:163–221`](../../../Sources/HistoryStorage/HistoryAuthority+RecentReads.swift#L163)、[`:255–293`](../../../Sources/HistoryStorage/HistoryAuthority+RecentReads.swift#L255)）。`git grep '#Index' 9a637a6c -- Sources` 无结果；唯一性字段不等价于 Apple 对这些 sort keys 的显式 `#Index` 性能承诺。search 仍 fetch 全部 retained scalar corpus（[`HistoryAuthority+SearchCorpus.swift:116–130`](../../../Sources/HistoryStorage/HistoryAuthority+SearchCorpus.swift#L116)）。
- **判定/验证。** V1 的“hint, not guarantee”措辞是对的；任何外部 “RSS 更小 / O(log N) / 比 Maccy 快” 都必须来自同机同 corpus 测量和 query-plan 证据。对 `pinOrdinal`、`lastCopiedAt`、business ID lookup 做有/无 explicit index 的迁移 spike与 cold/warm p50/p95/p99、I/O、fault/RSS 对比；先证明收益再改变 schema。

### APL-U-08 — 隐藏 `MenuBarExtra` 作为 lifecycle filler 没有公开契约

- **Apple 资料边界。** `Settings` 自 macOS 11+ 本身就是 Scene，并让 SwiftUI 管理 Settings menu/window。`MenuBarExtra` 自 macOS 13+，binding 为 true 才显示；只由 menu-bar extra 构成的 app 在用户移除 extra 后会自动终止。Apple 没有说明“常量 false 的隐藏 extra 可作为持久 lifecycle filler”，也没有承诺它与 AppDelegate-owned `NSStatusItem` 的 termination 组合。[`Settings`](https://developer.apple.com/documentation/swiftui/settings)、[`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)（访问 **2026-08-20T00:26:28Z–00:26:29Z**）。`LSUIElement` 自 macOS 10.0+ 正确表示 background agent、无 Dock icon。[`LSUIElement`](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)（访问 **2026-08-20T00:27:02Z**）。
- **Clipy 依赖。** app 声称 hidden `MenuBarExtra` 满足 “at-least-one-scene requirement”，binding 恒为 false，实际 status item 在 AppDelegate（[`ClipyAppMain.swift:1–37`](../../../ClipyApp/Sources/ClipyAppMain.swift#L1)）；project 正确设置 `LSUIElement`（[`project.yml:19–31`](../../../ClipyApp/project.yml#L19)）。
- **判定/验证。** LSUIElement shape 是 aligned；隐藏 filler 的必要性与 lifecycle 是 undocumented workaround。冷启动、无窗口长期运行、关闭 Settings、隐藏 extra 永不插入、login launch、wake、status item 重建与系统 memory pressure 下跑 process-lifetime test；不要把单次 build success 当 lifecycle 保证。

## 5. 已对齐的 Apple 平台事实

1. **部署 floor 一致。** SwiftPM 是 `.macOS(.v26)`（[`Package.swift:12–20`](../../../Package.swift#L12)），XcodeGen 是 macOS 26.0 + Swift strict concurrency（[`project.yml:7–14`](../../../ClipyApp/project.yml#L7)）。除 Carbon 现代 availability 未文档化外，本报告核验的 SwiftUI Settings/MenuBarExtra、SwiftData、ImageIO、SMAppService、UTType 和 CG posting APIs 都早于 macOS 26。
2. **SwiftData main context 没有泄漏到 UI。** Apple 明确 mainContext 是 MainActor-bound；Clipy 使用 container 创建 operation-local contexts，不把 `@Model`/context 跨 actor，方向正确（[`HistoryAuthority.swift:169–185`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L169)）。plain actor 的保证边界仍见 APL-U-05。
3. **manual context 的 autosave 被显式关闭。** Apple 默认本来就是 false；显式设置让 save boundary 更清楚（例如 [`HistoryAuthority.swift:343–345`](../../../Sources/HistoryStorage/HistoryAuthority.swift#L343)）。
4. **`.externalStorage` 没被当正确性保证。** schema 注释与 Apple 的有限承诺一致；V2-facts 也正确承认没有公开 size-only/file-URL API（[`V2-facts.md:1027–1045`](../../v2/V2-facts.md#L1027)、[`:2752–2773`](../../v2/V2-facts.md#L2752)）。
5. **Storage thumbnail worker 使用有界 ImageIO downsample。** max pixel、orientation transform、PNG output bound 都与公开 ImageIO primitive 对齐（[`ThumbnailService.swift:265–330`](../../../Sources/HistoryStorage/ThumbnailService.swift#L265)）。Apple 没有承诺 PNG bytes 跨 restart 完全确定；V2-04 已正确留下 C2-PLATFORM-3 weakening gate（[`V2-facts.md:2411–2431`](../../v2/V2-facts.md#L2411)）。
6. **没有采用 `NSEvent.addGlobalMonitor`。** Apple 明确 global monitor 只收到其他 app 的事件，key-related monitoring 需要 Accessibility trust；local monitor 只处理本 app，且 nested tracking loop 可能绕开。[global monitor](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)) / [local monitor](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:))（macOS 10.6+；访问 **2026-08-20T00:25:45Z–00:25:46Z**）。当前未使用它们避免了这一确定的监听 TCC path，但不能反向证明 Carbon 无 TCC。
7. **`SMAppService` 与 `Settings` 选型本身正确。** macOS 26 上 `SMAppService.mainApp`、SwiftUI `Settings` 都是公开现代 API；问题在状态/入口/错误处理，不在框架选择。

## 6. macOS 26 必须落地的 proof matrix

下列不是“建议多测一点”，而是把未被 Apple 保证的依赖转成可审计证据的最低矩阵：

| Gate | 最小场景 | 通过条件 |
|---|---|---|
| `APPLE-PB-PRIVACY-1` | clean profile 下四种 `AccessBehavior`、冷启动、后台复制、重启 | 状态可见、deny 不伪装成空 clipboard、用户有恢复说明；记录 prompt/build |
| `APPLE-PB-LOSS-1` | 0.5 s 内 2/5/20 次 copy；main run loop stall；slow provider | 测出并披露 best-effort loss/latency；不再声称每个 count 各捕获一次 |
| `APPLE-PB-WRITE-1` | competing owner 抢占每个 representation/lineage step | 不出现 silent partial success；panel 只在完整成功后关闭 |
| `APPLE-PANEL-FOCUS-1` | native/Electron/WebKit/terminal/secure field、Spaces/full-screen | open/search/copy/close 后 active app、first responder、paste target 符合产品定义 |
| `APPLE-HOTKEY-1` | 无/有 Accessibility、secure input、冲突、布局、sleep/wake | 无 fatal `assumeIsolated`；注册失败有 UX；默认不劫持标准 shortcut |
| `APPLE-ALERT-1` | app-modal NSAlert、sheet、SwiftUI dialog、offscreen alert | 只依赖公开 modal/sheet state；alert 期间 panel 不误关/永久不关 |
| `APPLE-SETTINGS-1` | inactive LSUIElement、Settings 已存在、另一 Space | 公开 Settings action 稳定 order front；不依赖 selector/activation 必成 |
| `APPLE-LOGIN-1` | enabled/requiresApproval/notRegistered/notFound + typed errors | 四态与恢复入口完整，外部状态变化后 UI 正确 |
| `APPLE-SWIFTDATA-1` | closure throw、constraint/IO failure、kill/reopen | 多 row + singleton 全部或全无；结果记录为 runtime proof 而非 Apple quote |
| `APPLE-MIGRATION-1` | fresh V2、真实 V1、abort/kill/retry | backfill completion、幂等、nested transaction 支持性有证据 |
| `APPLE-IMAGE-1` | real BMP、multi-image HEIF、最大/坏图、快速切换 | primary image 正确；main-thread 预算与 version/cancellation fence 通过 |
| `APPLE-A11Y-L10N-1` | VoiceOver、Full Keyboard Access、RTL、两种复数规则 | 所有主要任务可完成；无 context-menu-only action；catalog 覆盖与布局通过 |
| `APPLE-LIFECYCLE-1` | login launch、无 scene visible、Settings close、sleep/wake | agent 与 status item 生命周期稳定；hidden MenuBarExtra workaround有明确证据或被移除 |

## 7. 对“全面超越 Maccy”的 Apple 证据边界

本报告只核验 Apple 平台契约，不重复 sibling Maccy comparison 的业务功能矩阵。可以据此得出的边界是：

- SwiftData `.externalStorage`、`propertiesToFetch`、actors 和 ImageIO downsample 是**有潜力**降低复制/解码成本的结构选择，不是 Apple 对 RSS、p95 或复杂度的保证。
- 缺少 explicit `#Index` 不等于一定慢；同样，`@Attribute(.unique)` 也没有 Apple 文档保证会让 `pinOrdinal`/`lastCopiedAt` 查询达到某个复杂度。必须用同机、同 corpus、同 cold/warm 条件对比。
- copy-only 不能计为 automatic paste；私有 selector/class-name 能工作也不能计为比 Maccy 更稳。
- 只有在上述 P0/P1 gaps 与 runtime gates 关闭、accessibility/localization 真实通过后，才能把平台层从“功能演示”提升到 V1 Part VI state 3。当前 `06` 仍把 product implementation complete 定义为 UI、pasteboard、packaging、accessibility、localization 与非 skeleton tests 全通过（[`06-cross-cutting.md:3–15`](../../06-cross-cutting.md#L3)）；Apple 证据不支持提前宣布完成。

## 8. 资料与引用方法

- 所有技术结论只依赖 Apple Developer Documentation、HIG、WWDC transcript、Apple retired archive 或明确标记 Apple Frameworks Engineer 的 Developer Forums 回复；没有使用博客/Stack Overflow 作为结论来源。
- 已知 Apple URL 通过 Sosumi 读取 Markdown，但报告链接全部指回 canonical `developer.apple.com`。主要资料访问窗口是 **2026-08-20T00:23:21Z–00:33:31Z**。
- Apple DocC 显示 `macOS undefined+` 的旧 AppKit API，本报告不会猜测引入版本；只标注“DocC 未给精确版本”，并要求 macOS 26 SDK compile/runtime gate。
- 没有 Apple 明文保证的地方均标为 `undocumented / requires measurement`，没有用 Maccy 当前行为、社区惯例或一次成功 CI 补洞。
- UI 仍在并发变化；未来实现若越过 `9a637a6c`，必须重新固定 commit 与 UTC 时间后再关闭对应 finding。
