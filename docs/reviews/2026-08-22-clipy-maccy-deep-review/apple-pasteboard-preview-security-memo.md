# Apple Pasteboard 与 Preview 安全边界备忘录

日期：2026-08-22
资料范围：Apple 官方公开文档与当前 Clipy 源码；不使用第三方文章，不把运行时猜测写成平台契约。
决策对象：未来的多 item 捕获、可审阅的类型支持表，以及 image / rich text / HTML / PDF /
file / Quick Look preview 的模块边界与 TDD 准入。

本备忘录与同目录的
[`apple-pasteboard-type-system-memo.md`](apple-pasteboard-type-system-memo.md)
互补：后者枚举标准 `NSPasteboard.PasteboardType`；本文回答“读取和渲染这些不可信内容时，Apple
到底承诺了什么，以及 Clipy 何时才可以把一种类型标成可安全预览”。

> 架构解释边界：本文较早的“单一capability descriptor”和把exact reference放入renderer request的
> sketch已被最终设计收敛。规范性方向以
> [`08-content-types-and-preview.md`](08-content-types-and-preview.md) 为准：stable facts + owner manifests；
> `PreviewContentLoader`独占History/reference/lifecycle，`ContentPreview`不接收`HistoryItemReference`；
> row thumbnail仍由HistoryStorage拥有source/version fence。

## 1. 证据等级

- **DOC**：Apple 文档直接说明的 API 行为。
- **IMPL**：当前 Clipy 源码中可直接定位的实现事实。
- **INFERENCE**：由 DOC/IMPL 推出的工程判断；不是 Apple 的保证。
- **UNKNOWN**：Apple 当前公开文档没有承诺，必须用目标 macOS 26 运行时试验决定。

“系统能打开”不等于“Clipy 可以在后台自动、安全、可取消地预览”。本文把以下能力严格拆开：

1. 原始 bytes 是否可捕获；
2. item/representation 边界是否可无损回写；
3. 是否能提取搜索文本；
4. 是否能生成静态缩略图；
5. 是否能显示非交互 preview；
6. 是否允许交互、文件访问或网络访问。

## 2. 先给结论

1. **捕获模型必须保留 `pasteboard item -> ordered representations` 两层结构。**
   `NSPasteboard` 可以有多个 item；pasteboard 级 `data(forType:)` 只面向首个可提供该类型的
   item，而 `string(forType:)` 会把多个 item 的 string/RTF/RTFD 用换行拼接。二者都不能作为
   无损历史格式。[`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard)、
   [`readObjects(forClasses:options:)`](https://developer.apple.com/documentation/appkit/nspasteboard/readobjects(forclasses:options:))、
   [`string(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/string(fortype:))。

2. **未知 UTI 仍应具有“opaque capture + verbatim paste”能力。**
   `UTType` conformance 是类型声明关系，不验证实际 bytes。动态类型由系统生成；未声明的合法
   identifier 在 macOS 26 的新 initializer 中甚至可仅保留 identity、没有 conformances 或 tags。
   不认识不能等价于丢弃。[`UTType.isDynamic`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype/3551517-isdynamic)、
   [`UTType.init(identifier:allowUndeclared:)`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/init(identifier:allowundeclared:))。

3. **支持能力必须分轴且所有权明确，不应只有`isSupported`。** `ClipboardFormats`只保存stable facts；
   capture/paste/search/thumbnail/preview/edit/interaction/external-I/O分别由behavior owner manifest声明；
   build/test inventory只join并报告漂移，不成为中央runtime owner。

4. **当前纯文本 preview 的类型/编码契约需要先修正。** Apple 把 `public.text` 定义为包含
   markup 的抽象 base type，把 `public.plain-text` 定义为“编码未指定”；只有
   `public.utf8-plain-text`、`public.utf16-plain-text` 和
   `public.utf16-external-plain-text` 明确编码。当前代码却把除
   `public.utf16-plain-text` 外的全部“文本”按 UTF-8 解码，并列出了 Apple 文档中找不到的
   `public.utf8-external-plain-text`。这不是“never guess an encoding”。
   [`.text`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/text)、
   [`.plainText`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/plaintext)、
   [`.utf8PlainText`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/utf8plaintext)、
   [`.utf16ExternalPlainText`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttypeutf16externalplaintext)。

5. **HTML 默认raw-preserve；Preview优先plain sibling，否则type/byte metadata。** source-preview只有
   明确charset/codec或另批有限static grammar后才可准入；rich Web preview默认关闭。Apple 明确说
   `NSAttributedString` 的 HTML importer 可能因外部资源而超时，且它不是通用 HTML importer；
   `WKWebView` 会自动加载 HTML 中的图片、视频等嵌入资源。Clipy 的“无网络”产品边界下，任何
   rich HTML preview 都要先通过“零 HTTP(S)、零 file read、零持久 website data”的黑盒门槛。
   [`NSAttributedString.init(data:options:documentAttributes:)`](https://developer.apple.com/documentation/foundation/nsattributedstring/init(data:options:documentattributes:))、
   [`WKWebView`](https://developer.apple.com/documentation/webkit/wkwebview)。

6. **PDF preview 应先是非交互的 page raster，不应直接嵌入 `PDFView`。** PDF 可以包含 URL、
   remote-go-to、named、reset-form 等 actions；`PDFViewDelegate` 明确有 link click 和 remote
   document opening hooks。静态绘制不是任意 PDF 安全性的证明，但它能显著缩小 Clipy 主动执行的
   行为面。[`PDFAction`](https://developer.apple.com/documentation/pdfkit/pdfaction)、
   [`PDFViewDelegate`](https://developer.apple.com/documentation/pdfkit/pdfviewdelegate)、
   [`PDFPage.thumbnail(of:for:)`](https://developer.apple.com/documentation/pdfkit/pdfpage/thumbnail(of:for:))。

7. **ImageIO 的输出尺寸键不是 decompression-bomb 保证。** API文档承诺
   `kCGImageSourceThumbnailMaxPixelSize` 限制 thumbnail 的最大宽高；Apple WWDC还展示并推荐streaming
   downsample，但这不是macOS26所有格式/恶意输入的peak合同。文档没有承诺 peak allocation、
   解码时间、frame count 或恶意 metadata 的上限。需要 header/property preflight、并发上限、RSS /
   deadline 试验，必要时才把复杂 decoder 隔离到辅助进程。
   [`CGImageSource`](https://developer.apple.com/documentation/imageio/cgimagesource)、
   [`kCGImageSourceThumbnailMaxPixelSize`](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize)、
   [`kCGImagePropertyPixelWidth`](https://developer.apple.com/documentation/imageio/kcgimagepropertypixelwidth)。

8. **file URL、iCloud item、网络卷和 file promise 不得在 hover/capture 路径自动兑现。** iCloud
   文件可能尚未下载；调用下载 API会触发同步。file promise 可能耗时很长，失败时甚至可能留下部分或
   损坏文件。它们应是显式用户动作和独立任务，不是普通 byte decoder。
   [`URLUbiquitousItemDownloadingStatus`](https://developer.apple.com/documentation/foundation/urlubiquitousitemdownloadingstatus)、
   [`startDownloadingUbiquitousItem(at:)`](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:))、
   [`receivePromisedFiles(atDestination:options:operationQueue:reader:)`](https://developer.apple.com/documentation/appkit/nsfilepromisereceiver/receivepromisedfiles(atdestination:options:operationqueue:reader:))。

## 3. Pasteboard：无损读取与被动监听的边界

### 3.1 item 与 representation 是两个不可压平的维度

**DOC：**

- 一个 pasteboard 可以包含多个 item；`pasteboardItems` 暴露全部 item。
- `NSPasteboardItem.types` 是该 item 支持的 UTI 字符串列表；pasteboard 级 `types` 是所有 item
  声明类型的并集，按声明顺序返回。
- `readObjects(forClasses:options:)` 对每个 item 按调用方给出的 class 顺序选择第一个可读 class；
  包含 `NSPasteboardItem.self` 才能保证每个 item 至少返回一个原始 item 对象。
- pasteboard 级 `data(forType:)` 返回首个包含该类型的 item 的数据；标准 text/RTF/RTFD 还具有
  合并多 item 的 special consideration。`string(forType:)` 明确会拼接多 item。

证据：[`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard)、
[`NSPasteboard.types`](https://developer.apple.com/documentation/appkit/nspasteboard/types)、
[`NSPasteboardItem`](https://developer.apple.com/documentation/appkit/nspasteboarditem)、
[`readObjects(forClasses:options:)`](https://developer.apple.com/documentation/appkit/nspasteboard/readobjects(forclasses:options:))、
[`data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/data(fortype:))。

**IMPL：** 当前 `PasteboardAdapter.captureOutcome` 只取
`pasteboard.pasteboardItems?.first`，而 `write(_:)` 用 pasteboard 级 `setData` 逐表示写入首个 item。
源码位置：`Sources/PasteboardAdapter/PasteboardAdapter.swift:82-86,115-156,184-215`。

**INFERENCE：** “first item 是 general pasteboard 的 standard shape”不是 Apple 契约。若要扩展
类型，必须先把 History 的 capture/paste DTO 改成 ordered items；否则同一 UTI 出现在多个 item 时
无法表示，文件列表、Finder 多选和多重文本选择会被静默截断。不要用“把 item 拼成一项”解决，
因为那会失去边界并制造重复 type identifier。

### 3.2 读取可能失败、超时或在中途变陈旧

**DOC：** pasteboard 级 `data(forType:)` 可因读取前后内容变化或 owner 未及时提供 promised data
而返回 `nil`；其他通信错误会抛出 `NSPasteboardCommunicationException`。`NSPasteboardItem` 仅在
owner 不变期间有效；owner 改变后，方法返回空数组、`nil` 或 `false`。`changeCount` 每次 ownership
改变时递增。[`data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/data(fortype:))、
[`NSPasteboardItem`](https://developer.apple.com/documentation/appkit/nspasteboarditem)、
[`changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)。

**支持上限：** Apple 的 item-level `data(forType:)` 页面只写“返回该 type 的 data”；timeout 的详细
说明位于 pasteboard-level API。item 失效导致 `nil` 是明确的，但 item-level promised provider 的精确
timeout、thread 和 cancellation 行为应标为 **UNKNOWN**，不能只凭两个 API 名称相似便升级为保证。

**INFERENCE：** 一次完整 freeze 至少需要：读起始 `changeCount`、枚举 item/types、兑现所选
representations、读结束 `changeCount`，只有首尾相同且没有 unavailable representation 才可提交。
这仍不能证明 Apple 提供数据库式 snapshot isolation；它只是用公开 token 排除已观察到的 ownership
切换。slow-provider 的 UI stall 需要真 provider 黑盒测试，不应由模拟 set 代替。

### 3.3 promised data 与 file promise 是两种不同机制

- **DOC：** `NSPasteboardWriting.promised` 表示该 type 的 data 延迟提供；默认第一个 writable type
  立即写入，其余 types 是 promised。`NSPasteboardItemDataProvider` 在请求时提供指定 UTI 的 data，
  owner 改变后收到结束通知。
  [`NSPasteboard.WritingOptions.promised`](https://developer.apple.com/documentation/appkit/nspasteboard/writingoptions/promised)、
  [`writableTypes(for:)`](https://developer.apple.com/documentation/appkit/nspasteboardwriting/writabletypes(for:)),
  [`NSPasteboardItemDataProvider`](https://developer.apple.com/documentation/appkit/nspasteboarditemdataprovider)。
- **DOC：** `NSFilePromiseProvider` 表示未来产生的文件；receiver 在指定 destination 和 operation queue
  上兑现。Apple 警告不要阻塞主线程，而且失败回调可能仍给出 partial/corrupt file。
  [`NSFilePromiseProvider`](https://developer.apple.com/documentation/appkit/nsfilepromiseprovider)、
  [`receivePromisedFiles`](https://developer.apple.com/documentation/appkit/nsfilepromisereceiver/receivepromisedfiles(atdestination:options:operationqueue:reader:))。
- **UNKNOWN：** Apple 文档没有给 `NSFilePromiseReceiver` 一项稳定的取消 API，也没有承诺 deadline、
  最大文件大小或失败时自动删除 partial file。

**建议：** passive history capture 可以请求普通 promised representation，但必须测最坏 stall；file
promise 默认只保存 opaque descriptor/伴随表示，不在监听时兑现。真正接收文件必须经显式 user action、
私有 destination、byte/time budget、partial-file cleanup 和任务状态机。

### 3.4 macOS 26 pasteboard privacy 是产品流程，不是边缘 API

**DOC：** Apple 的 AppKit 更新说明新增 programmatic pasteboard access alert、per-app
`accessBehavior`，以及可在不触发用户通知的情况下检查某些 pattern/metadata 的 detect APIs；实际读取
仍可能需要提示。general pasteboard 还会自动参与 Universal Clipboard，且 macOS 没有控制 Universal
Clipboard 的专用 API。[AppKit updates — macOS pasteboard privacy](https://developer.apple.com/documentation/updates/appkit)、
[`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard)。

**UNKNOWN：** `pasteboardItems`、item `types`、每种 `data(forType:)` 在最终 macOS 26 上分别何时触发
alert，Apple 的摘要没有给出完整矩阵；用户把 access 设为 deny/prompt 时 background polling 的节流与
恢复行为也需运行时验证。

**准入：** capture observer 必须把 `.default / .ask / .alwaysAllow / .alwaysDeny` 作为显式状态；
`alwaysDeny` 时不循环触发读取，不把“没有权限”写成“clipboard empty”。Apple 还明确说 user-originated
且 paste-related 的访问即使在 deny 状态也始终允许，因此“后台监控”和“用户按下 Paste”的流程不能共用
一个粗粒度 `canReadClipboard` Boolean。
[`NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)。

## 4. UTI：routing evidence，不是 payload truth

### 4.1 conformance、dynamic 与 undeclared

**DOC：** `conforms(to:)` 对直接/间接 conformance 或相等返回 `true`；动态 UTI 是系统遇到未知文件
metadata 时生成的类型；普通 `UTType(identifier)` 对系统未知 identifier 返回 `nil`。macOS 26 beta 的
`allowUndeclared` initializer 可为合法但未知 identifier 保留 identity，这类对象既非 dynamic 也非
declared，并且没有 conformances/tags。
[`conforms(to:)`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttypereference/conforms(to:))、
[`isDynamic`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype/3551517-isdynamic)、
[`UTType.init(_:)`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/init(_:))、
[`allowUndeclared`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/init(identifier:allowundeclared:))。

**INFERENCE：** routing 顺序应是：

1. Clipy-owned exact identifiers（lineage/concealment metadata）；
2. exact wire formats with explicit decoder contracts；
3. declared conformance 只用于“候选 decoder”选择；
4. decoder sniff/parse 结果最终决定是否可 preview；
5. dynamic/undeclared/unknown 始终保留为 opaque，而不是构造假的 imported/exported declaration。

`UTType(importedAs:)` 表示“本 app 使用但不拥有此 type”；它不是用来给任意未知 pasteboard identifier
凭空添加可信 conformance 的工具。[Defining file and data types for your app](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app)。

### 4.2 当前 text policy 与 Apple 定义冲突

**IMPL：** `HistoryPreviewView.swift:65-87`：

- 仅对 `public.utf16-plain-text` 用 `.utf16`；其他全部用 `.utf8`；
- 把 `public.plain-text`、`public.text`、`public.rtf`、`public.html` 都列为 textual；
- 列出 `public.utf8-external-plain-text`。

**DOC：**

- `public.text` 是所有 text-encoded data（含 markup）的 base type；
- `public.plain-text` 的 encoding 未指定；
- `public.utf8-plain-text` 是 UTF-8；
- `public.utf16-plain-text` 是 native byte order + optional BOM；
- Apple 声明的 external 变体是 `public.utf16-external-plain-text`，无 BOM 时为 big-endian。

**结论：** 当前 `.rtf`/`.html` preview 实际显示格式源码而非 rich preview；`public.text` 与
`public.plain-text` 的 UTF-8 fallback 是 encoding guess；external identifier/decoder 也写错方向。
支持更多 source-code/JSON/XML/Markdown 类型之前，先定义每个 exact type 的 charset；只凭
`.conforms(to: .text)` 不足以选择 `String.Encoding`。

## 5. Renderer 分析

### 5.1 ImageIO

**Apple 明确提供：**

- `CGImageSourceCreateWithData` 从 bytes 创建 source；`CGImageSourceGetType` 返回识别出的 container
  UTI；`CGImageSourceGetCount` 返回 image count；status 可区分 invalid、unknown、incomplete、complete。
- `CGImageSourceCopyPropertiesAtIndex` 可读 width/height 等 properties。
- `CGImageSourceCreateThumbnailAtIndex` 可生成 thumbnail；`ThumbnailMaxPixelSize` 限制最大宽高，
  `CreateThumbnailWithTransform` 应用方向/缩放。Apple 的 `ShouldCacheImmediately` 页面没有把
  `CreateThumbnailAtIndex` 列为适用函数，因此它能否控制 thumbnail route 属于 `UNKNOWN`，不得从
  `CreateImageAtIndex` 外推。
- Apple 明确说支持 image formats 会随平台变化，应用应使用
  `CGImageSourceCopyTypeIdentifiers()` 获取当前系统支持列表。

证据：[`CGImageSource`](https://developer.apple.com/documentation/imageio/cgimagesource)、
[`CGImageSourceStatus`](https://developer.apple.com/documentation/imageio/cgimagesourcestatus)、
[`Individual Image Properties`](https://developer.apple.com/documentation/imageio/individual-image-properties)、
[`kCGImageSourceShouldCacheImmediately`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately)、
[`Creating Quick Look Thumbnails`](https://developer.apple.com/documentation/quicklookthumbnailing/creating-quick-look-thumbnails-to-preview-files-in-your-app)。

**Apple 没有承诺：** input bytes、declared pixel count、frame count、ICC/EXIF/auxiliary data 对 peak RSS
和 CPU 的上限；`MaxPixelSize` 也没有被文档描述为 decompression-bomb 防护。不能从“输出 640 px”
推出“解码最多分配 640×640×4 bytes”。

**当前 Clipy：** image type exact set 在至少三处复制：

- `HistoryAuthority+DetailAndThumbnail.swift:146-163`；
- `ThumbnailStore.swift:99-112`；
- `HistoryPreviewView.swift:90-101`。

`ThumbnailWorker` 使用 `MaxPixelSize`，但未先检查 source status、recognized UTI、image count 或 header
pixel dimensions，并把“外部 app 声明 PNG 但 bytes 不可解码”分类成
`.persistence(.corruptStoredValue)`（`ThumbnailService.swift:252-300`）。Apple 的 `setData` 接口没有
说明 pasteboard server 会验证 bytes 与 type 相符，因此 malformed media 是不可信输入状态，不足以单独
证明 Clipy 的持久化结构损坏。[`setData(_:forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/setdata(_:fortype:))。

**建议：** 一处 `ImagePreviewDescriptor` 声明 policy；启动时取 ImageIO runtime identifiers，作为
diagnostic/runtime capability 与 policy 的交集。decoder 必须验证 status/type/dimensions/count，输出
中性 encoded artifact；malformed content 返回 `.malformedRepresentation`，不得触发 store recovery。
资源测试不能证明可取消 native decode 时，应只依靠“结果发布取消”；若观测到不可接受的 RSS/延迟，
再批准 renderer helper/XPC 隔离，而不是先建空插件框架。

### 5.2 RTF 与 RTFD

**DOC：** `NSAttributedString` 可从 RTF/RTFD 解码；RTFD 是带附件的 rich text。RTF export 会省略
attachment attributes，RTFD 保留附件。`NSTextAttachment` 可以持有 `Data` 或 `FileWrapper`，macOS
attachment cell 还可处理鼠标事件；`NSTextView` 的 delegate 可处理 link clicks。
[`NSAttributedString`](https://developer.apple.com/documentation/foundation/nsattributedstring)、
[`init(RTFD:documentAttributes:)`](https://developer.apple.com/documentation/foundation/nsattributedstring/init(rtfd:documentattributes:))、
[`NSTextAttachment`](https://developer.apple.com/documentation/appkit/nstextattachment)、
[`NSTextViewDelegate.clickedOnLink`](https://developer.apple.com/documentation/appkit/nstextviewdelegate/textview(_:clickedonlink:at:))。

**INFERENCE：**

- RTF 可先准入“非交互 attributed text + link attributes inert”；
- RTFD 必须另设 tier，因为附件的数量、累计展开 bytes、具体 decoder 和 attachment view 行为都需要
  独立预算；
- 不使用 view-based attachment provider；未知附件显示 placeholder；
- link 只能由明确 user action 交给 app-level policy，renderer 不自行 `NSWorkspace.open`；
- decode 失败不影响 raw capture/paste。

**UNKNOWN：** Apple 没有为 RTF/RTFD importer 公布递归深度、attachment 总量、峰值内存或取消契约。

### 5.3 HTML 与 WebArchive

**DOC：** Apple 写的是 HTML 模式 **should not** 从 background thread 调用；后台调用会尝试与 main
thread同步，并可能失败/超时。含外部资源引用的 HTML 在主线程也可能超时；这不是语言层绝对禁止，
也不是任意外部资源必然超时。Apple还说该机制用于 markdown-like style
import，不是 general HTML import。`WKWebView.loadHTMLString` 使用 `baseURL` 解析相对 URL，WKWebView
总览明确说会自动加载嵌入图片/视频等资源。`WKWebpagePreferences.allowsContentJavaScript` 默认是
`true`，涵盖 inline scripts、`javascript:` URL 和引用的 JavaScript；若未显式配置 data store，
`WKWebViewConfiguration` 使用会把 website data 持久化到磁盘的 default store。
[`allowsContentJavaScript`](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript)、
[`WKWebViewConfiguration.websiteDataStore`](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/websitedatastore)。

`WKNavigationDelegate` 管理 main-frame navigation；它不是 Apple 文档给出的“拦截所有 subresource”
保证。`WKContentRuleListStore` 可应用内容阻止规则；`WKWebsiteDataStore.nonPersistent()` 只保证 website
data 不落盘，不等价于禁止网络。默认 store 会把 website data 持久化到磁盘。
[`WKNavigationDelegate`](https://developer.apple.com/documentation/webkit/wknavigationdelegate)、
[`WKContentRuleListStore`](https://developer.apple.com/documentation/webkit/wkcontentruleliststore)、
[`WKWebsiteDataStore`](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)。

**结论：** v1/下一小步优先exact plain sibling，否则只显示type/byte metadata；HTML source需明确
charset/codec，确定性static extraction需另有grammar。不得把
`loadHTMLString(baseURL:nil)` 当成 offline。若以后批准 WKWebView，必须同时具备：all-resource blocker、
nonpersistent store、JavaScript/下载/window-open/导航关闭、无 file read、外链仅复制或显式确认，以及
本地 HTTP server 证实零请求。任一 gate 不可证明，manifest就继续标plain-sibling/type-metadata route；
只有另行批准source codec后才可标`.sourceOnly`。

### 5.4 PDF

**DOC：** `PDFDocument(data:)` 可失败；文档可 encrypted/locked。PDF annotations 可以包含 link、
form 和交互；`PDFAction` 有 URL、remote-go-to、named、reset-form 等 concrete actions；
`PDFViewDelegate` 暴露点击 URL 和打开 remote document 的回调。`PDFPage` 则可绘制到 `CGContext`
或生成指定尺寸 thumbnail。[`PDFDocument`](https://developer.apple.com/documentation/pdfkit/pdfdocument)、
[`isLocked`](https://developer.apple.com/documentation/pdfkit/pdfdocument/islocked)、
[`PDFAnnotation`](https://developer.apple.com/documentation/pdfkit/pdfannotation)、
[`PDFActionURL`](https://developer.apple.com/documentation/pdfkit/pdfactionurl)、
[`PDFActionRemoteGoTo`](https://developer.apple.com/documentation/pdfkit/pdfactionremotegoto)、
[`PDFPage`](https://developer.apple.com/documentation/pdfkit/pdfpage)。

**准入顺序：**

1. exact `com.adobe.pdf` + parser success；
2. locked/encrypted 返回明确 placeholder，不弹 password UI；
3. page-count/bounds checks；
4. 只 raster first page 到固定 bitmap，默认不显示/不响应 annotation；
5. 返回 encoded bitmap + page count 等中性 DTO；
6. 只有另一次产品批准才嵌 `PDFView`。

**UNKNOWN：** Apple 没有承诺 malformed PDF 的 CPU/RSS 上限、解析可取消或 PDFKit 是安全 sandbox。
所以 first-page 仍需 deadline/RSS/crash corpus；“不用 PDFView”只缩小 action surface，不证明 parser
无资源风险。

### 5.5 Quick Look 与临时文件

**DOC：** `QLThumbnailGenerationRequest` 接收 file URL；Quick Look 可为 image、text、PDF、audio、
video 等常见文件生成缩略图，并提供 `cancelRequest`。低/高质量 representation 可能分阶段回调。
如果已安装的 app 为 custom file type 提供 Thumbnail Extension，其他 app 的
`QLThumbnailGenerator` 也可以使用它；因此“系统能生成”的 handler 集合不是 Clipy 自己完全控制的
固定列表。
[`QLThumbnailGenerator.cancel(_:)`](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator/cancel(_:))、
[`Quick Look Thumbnailing`](https://developer.apple.com/documentation/quicklookthumbnailing)。
保存到文件的 API 明确要求调用方在不用后删除输出。`QLPreviewItem.previewItemURL` 必须是 file URL。
[`QLThumbnailGenerator`](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator)、
[`QLThumbnailGenerationRequest`](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator/request)、
[`Creating Quick Look Thumbnails`](https://developer.apple.com/documentation/quicklookthumbnailing/creating-quick-look-thumbnails-to-preview-files-in-your-app)、
[`QLPreviewItem.previewItemURL`](https://developer.apple.com/documentation/quicklook/qlpreviewitem/previewitemurl)。

**DOC：** 对 iCloud remote file，Quick Look 可下载已上传 thumbnail；小于 1 MB 的 common file 可能
改用 actual file 生成。这个行为意味着对 file URL 发 request 可能涉及 iCloud I/O，不能假定纯本地。

**UNKNOWN：** Apple 没承诺普通 `QLThumbnailGenerator` 总是在隔离进程执行，也没承诺对恶意输入的
资源上限、对 network-mounted file 的行为或 `cancelRequest` 何时释放所有底层工作。

**INFERENCE：** raw bytes 要交给 Quick Look 时，只能在 app-private、每 request 唯一的 temp
directory 物化；扩展名必须来自已验证 `UTType`，不能直接拼接不可信 identifier。成功、失败、cancel、
panel close、app termination 都要删除；任何 callback 必须先过 request token/content-version fence。
对 file URL preview，hover只显示capture时已有的lexical URL/type facts，不stat/open/coordinator；读取target、
查询实时metadata、触发 iCloud download 或访问 network volume
必须是显式 user action。

### 5.6 file URL、sandbox 与网络/iCloud

**DOC：** App Sandbox 只允许 app container 和明确授权范围；即便 sandbox 允许，POSIX ACL、SIP、
Data Protection 等仍可拒绝访问。通过 open/save panel 等标准用户动作得到的 URL 可能自动开始
security-scoped access，完成后应 stop；持久 access 需要 bookmark。字符串路径不是授权。
[Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)、
[`startAccessingSecurityScopedResource()`](https://developer.apple.com/documentation/foundation/nsurl/startaccessingsecurityscopedresource())、
[`NSPasteboard.PasteboardType.string`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/string)。

**DOC：** URL resource keys 能区分 local volume、iCloud item 和 download status；not-downloaded item
需要 `startDownloadingUbiquitousItem(at:)`。[`URLResourceKey`](https://developer.apple.com/documentation/foundation/urlresourcekey)、
[`URLUbiquitousItemDownloadingStatus`](https://developer.apple.com/documentation/foundation/urlubiquitousitemdownloadingstatus)。

**UNKNOWN：** 从 general pasteboard 读取到的 file URL 是否携带哪一种、多久有效的 implicit sandbox
extension，Apple 这些页面没有给出可依赖的统一保证。必须以 signed+sandboxed app 做黑盒测试；历史中
长期保存 URL 字符串本身绝不等价于长期文件授权。

## 6. 推荐的 support tiers

| Tier | 能力 | 建议类型 | 默认行为 |
|---|---|---|---|
| A — Opaque | raw capture、verbatim paste；无 decode | 所有非空/限额内 representation，包括 unknown/dynamic/private UTI | 保存 identifier + bytes + item boundary；UI 显示类型和大小 |
| B — Deterministic text | A + search + plain preview | 只有 encoding 明确的 exact text UTI；source code/JSON/XML 也必须有已知 charset | bounded decode；不可替代 raw bytes |
| C — Bounded static | A + 静态 thumbnail/noninteractive preview | runtime-confirmed ImageIO formats、RTF（inert links/attachments policy）、PDF first-page | native decoder 可失败；固定 output；无外部 I/O/interaction |
| D — Explicit external | 用户明确启动后才可访问外部资源 | file URL、iCloud/network file、file promise、Quick Look temp materialization、RTFD attachment、audio/video playback | 独立任务、可见进度、取消、cleanup；失败不污染 history |
| E — Disabled pending proof | 保留/回写，但不 rich-preview | HTML/WebArchive、interactive PDFView、未知 attachment/custom Quick Look handler | 只有所有 security/resource tests 通过后才能升级 |

Tier 是 Clipy 的支持级别，不是 Apple 的格式分类。同一 item 可以有多种 representation；renderer
selection 应按明确优先级选一个 source，但 paste 必须保留全部原始表示。

## 7. 模块与接口方向

目标不是制造任意插件框架，而是让复杂性有一个可删除、可替换的 owner。

```text
PasteboardAdapter
  └─ freeze/write ordered raw ClipboardItems
           │ immutable Sendable values
           ▼
ClipboardFormats stable facts + ContentPreview-owned manifest/profile
           │ PreviewRequest(immutable source + closed intent/profile/source policy)
           ▼
package-only concrete ContentPreview
  ├─ EncodedTextDecoder
  ├─ ImageIODecoder
  ├─ RichTextDecoder
  ├─ PDFStaticRenderer
  └─ ExplicitFilePreviewCoordinator (Quick Look / promises)
           │ PreviewArtifact (text or checked eager pixels/metadata)
           ▼
PresentationUI
```

建议的最小接口语义：

```swift
struct ContentCapabilityDescriptor: Sendable {
    let matcher: TypeMatcher
    let capture: CaptureSupport
    let paste: PasteSupport
    let search: SearchSupport
    let thumbnail: PreviewSupport
    let preview: PreviewSupport
    let externalIO: ExternalIOSupport
    let evidence: EvidenceReference
}

struct PreviewRequest: Sendable {
    let source: ImmutablePreviewSource
    let intent: PreviewIntent
    let resourceProfile: PreviewResourceProfileID
    let sourcePolicy: PreviewSourcePolicy
}

enum PreviewArtifact: Sendable {
    case text(String, metadata: TextPreviewMetadata)
    case raster(EagerPixelBuffer, metadata: RasterPreviewMetadata)
    case metadata(FilePreviewMetadata)
    case unavailable(PreviewUnavailability)
}
```

这里的`EagerPixelBuffer`是checked width/height/rowBytes/pixelFormat/colorSpace + RGBA/BGRA bytes，默认不
返回encoded PNG/JPEG；后者只有独立UI-decode budget/spec gate后才准入。exact History reference/task
lifecycle属于loader，不进入renderer request。

边界要求：

- `ClipboardFormats`只拥有stable facts；Search/Thumbnail/Preview/Edit/Presentation/Pasteboard各自拥有manifest，
  build/test inventory只检测漂移，不是唯一runtime policy owner；
- decoder 自己拥有 framework imports 和 input/output/resource rules；
- `NSPasteboardItem`、`UTType`、`NSAttributedString`、`CGImage`、`PDFDocument`、`QLThumbnail*` 不跨
  decoder/module/actor 边界；跨边界只走 immutable values；
- registry 是 closed, ordered construction，不做 runtime arbitrary bundle loading；
- runtime capability（如 ImageIO identifiers）作为 catalog 的受测 observation，不改写 raw history；
- complex decoder 是否进 helper/XPC 由 crash/RSS evidence 决定，不能为了“可能以后”预建协议树；
- Presentation 只解释 `PreviewArtifact`，不选择 UTI、不解析 bytes、不发网络或打开 URL。

## 8. TDD 准入流程

每张卡只验证一个行为；先写 observable failing test，再做最小实现，再 refactor。compile error 不是
Red，mock 出内部实现也不是证据。

### MEMO-PBSEC-1：多 item 无损 round-trip

**Red：** private `NSPasteboard` 写入三个 `NSPasteboardItem`；两个 item 都有 `.string`，另一个有相同
private UTI。capture 后 item count/order/每项 type order/bytes 必须精确；paste 后重新读取仍相同。当前
first-item DTO 应失败。
**Green：** 只引入 ordered item DTO 与 `writeObjects`。
**Refactor：** 删除任何 pasteboard-level string/data 的无损路径。

### MEMO-PBSEC-2：ownership 中途改变不能提交 partial snapshot

**Red：** 真 `NSPasteboardItemDataProvider` 在兑现第二个 type 时改变 owner；断言整次 freeze 标记
superseded/unavailable，不进入 History。
**Green：** start/end `changeCount` fence + complete outcome。
**非支持：** 这只证明测试中的 ownership 变化被发现，不证明 Apple snapshot isolation。

### MEMO-PBSEC-3：slow promised provider 的 UI/backpressure

**Red：** provider 延迟超过 UI heartbeat budget；同时连续产生新的 changeCount。断言 panel heartbeat
不中断、队列有硬上限、过期 capture 不提交。
**判别：** 若 AppKit 调用在安全线程/actor 上不可证明或依然冻结 UI，先限制 passive read policy；只有
测得必要性再设计 capture helper。不要用 `simulatedUnavailableTypeIdentifiers` 替代 timing proof。

### MEMO-TYPE-1：stable facts 与 owner manifests 不漂移

**Red：**source gate区分stable identifier/family literal与owner policy literal；stable key唯一，各owner
manifest显式声明其route/evidence，unknown canary保持opaque raw fallback。build/test inventory能显示
HEIF/BMP/UTF-16等未解释漂移，但删除inventory不改变production行为。
**Green：**迁移一个stable fact与一个owner manifest，删除对应重复literal；Storage/Thumbnail/Preview不查询
中央policy catalog。
**Refactor：**逐owner缩小legacy allowlist；不要求一次删除全部image/text sets才允许首张Green。

### MEMO-TYPE-2：unknown/dynamic/undeclared 永不丢失

**Red：** private reverse-DNS、dynamic identifier、合法但 undeclared identifier 各一个；全部 raw
round-trip，preview 明确 `.unsupportedType`，无 fake conformance。
**Green：** opaque fallback。
**Refactor：** exact matcher 与 conformance matcher 共享同一个 deterministic selection owner。

### TEXT-1：编码是 exact type contract

**Red：** UTF-8、UTF-16 native、UTF-16 external big-endian fixtures；另放 UTF-16 bytes under
`public.plain-text` 与 HTML/RTF。断言前三者按 Apple 定义解码；编码未指定和 markup 不走 UTF-8
fallback。
**Green：** 只实现 exact encodings。
**Refactor：** rich formats 交给各自 decoder。

### IMG-1：type claim 不是 store corruption

**Red：** 一个 `.png` representation 内放随机 bytes；capture/paste 必须无损，thumbnail 返回
malformed/unavailable，不能报告 persistence corruption 或触发恢复。
**Green：** 分离 Canonical codec integrity 与 media decode failure。
**Refactor：** source type/status validation 集中进 ImageIODecoder。

### IMG-2：decompression/resource corpus

**Red：** giant declared dimensions、many-frame GIF/TIFF、truncated header、invalid ICC/EXIF、极高压缩率
fixture；child process 记录 wall time、peak RSS、输出尺寸与退出状态。
**Gate：** 输入/输出/并发上限都满足才升 Tier C；若 child 被 kill/crash，先隔离或继续不支持，不以
单元测试超时掩盖。
**Non-support：** `ThumbnailMaxPixelSize` 命中只证明输出，不证明 peak RSS。

### RICH-1：RTF/RTFD 无隐式交互

**Red：** RTF link、RTFD 多附件/大附件/未知 attachment type；断言 link click 不打开 URL、attachment
不创建自定义 view、总预算超限返回 typed unavailable。
**Green：** inert attributed text + placeholders。
**Gate：** RTF 与 RTFD 分开升级。

### HTML-1：零外部 I/O

**Red：** HTML 同时包含 HTTP image/CSS/fetch、file URL、redirect、iframe、link；本地 server 和文件
watcher 断言零访问，website data 断言无落盘，所有 navigation/download/window-open 被拒绝。
**Green：** 优先 source/plain extraction；若选择 WebKit，最小 offline configuration 必须全过。
**Gate：** 任一外部请求即保持 Tier E；只拦 main navigation 不算通过。

### PDF-1：静态 preview 不执行 actions

**Red：** PDF fixture 包含 URL action、remote go-to、named print、form reset、locked document；选中和
点击 preview 不产生 workspace open、print、remote file read 或 password UI，只返回 first-page raster
或 typed placeholder。
**Green：** PDFPage/CGContext static renderer，不嵌 PDFView。
**Refactor：** page metadata 与 raster artifact 保持中性 DTO。

### PDF-2：malformed/resource/cancellation

**Red：** large page count、oversized media box、deep object graph、truncated/encrypted corpus 在 child
process 中测 wall/RSS/crash；快速切换 selection 后旧结果不得发布。
**Gate：** Swift task cancellation 只证明 publish fence；若 native parse 不响应取消，报告实际 latency，
不要宣称 work 已取消。

### FILE-1：hover 不触发 cloud/network/file content read

**Red：** local、not-downloaded iCloud、network-volume、missing、permission-denied file URL；hover 只取
允许的 metadata，不调用 download、不读文件正文。显式 Preview 动作才进入 file coordinator。
**Green：** `ExplicitFilePreviewCoordinator`。
**Gate：** signed+sandboxed app 测试，不能只用 unsandboxed SwiftPM test。

### FILE-2：Quick Look temp 生命周期

**Red：** success/failure/cancel/late callback/panel close/app relaunch 五条路径；每条都验证 private temp
目录最终为空，late artifact 不发布。
**Green：** one request token owns directory + QL request + cleanup。
**Non-support：** temp 被删不证明 Quick Look 没有内部 cache；文档没有该保证。

### FILE-3：file promise partial cleanup

**Red：** provider 写一半后回 error、provider 慢、多个 promises、重复 callback；History 不接收 partial
file，destination 无残留，UI 可取消/重试且有进度。
**Green：** explicit import state machine + background operation queue。
**Gate：** 不在 passive clipboard polling 中运行。

### FLOW-1：全 pipeline backpressure

**Red：** 200 次快速 selection + 混合 image/PDF/Quick Look；断言 active decoder 数、queued bytes、temp
directories、published artifact 都有硬上限，且只有最新 exact `HistoryItemReference` 可发布。
**Green：** 一个 preview coordinator 拥有 task、token、permit 和 cleanup。
**Refactor：** decoder 保持无 UI 状态；不要给每种格式再建一套 selection state machine。

## 9. 尚不能从 Apple 文档得出的结论

- ImageIO、PDFKit、RTF/RTFD importer、Quick Look 对恶意输入的 peak RSS/CPU 或 crash isolation。
- `Task.cancel()` 是否会中断已经进入的同步 native decode。
- `QLThumbnailGenerator` 普通生成调用是否总在另一个受限进程执行。
- general pasteboard 的 file URL 在 sandbox 中携带何种 access extension、有效多久。
- final macOS 26 中每一种 pasteboard metadata/type/data read 的 privacy-alert 行为。
- file promise 的稳定 deadline、最大 size 和可靠 cancellation。
- `WKNavigationDelegate` 是否足以阻止全部 subresource；Apple 只把它描述为 navigation policy。
- 未下载 iCloud/network volume 在 Quick Look preview 时的全部 I/O 行为。

这些未知项都不能写成代码注释中的事实；应保留为 platform proof，并让 support manifest 的 evidence
字段显示 `runtimeVerified`、`documented` 或 `disabledPendingProof`。

### 当前风险与未来 guardrail 的界线

**IMPL：** 当前 product sources 没有 `import WebKit`、`import QuickLook`、
`import QuickLookThumbnailing` 或 `import PDFKit`；现有实际 native rendering surface 是
`HistoryStorage/ThumbnailService.swift` 与 `PresentationUI/DisplayImageDecoder.swift` 中的 ImageIO。
因此本文关于 HTML network load、Quick Look temp file 和 PDF action 的内容是未来扩类型时的准入条件，
不是“当前 Clipy 已在执行这些危险行为”的漏洞结论。当前已成立的问题只有：多 item 被截断、text
encoding/type policy 不准确、UTI sets 重复，以及 ImageIO 对不可信 media 的分类/资源证据仍不足。

## 10. 紧凑 evidence map

| Claim | Reason | Source | Supports | Cannot establish | Next discriminator |
|---|---|---|---|---|---|
| 必须保留多 item | pasteboard 支持多 item，string 可拼接 | `NSPasteboard`, `readObjects` | DTO 需要 item grouping | 并发 snapshot | MEMO-PBSEC-1/MEMO-PBSEC-2 |
| UTI 不是 byte truth | conformance/identifier 是类型关系，decoder 可失败 | `UTType`, `CGImageSource`, `PDFDocument` | candidate routing | payload 合法 | MEMO-TYPE-2/IMG-1 |
| HTML 默认不能 rich-preview | importer 可加载外部资源并超时；WKWebView 加载 embedded resources | `NSAttributedString`, `WKWebView` | plain sibling/type metadata默认 | 完整 exploitability | HTML-1 |
| ImageIO output/streaming示例不等于RSS bound | Apple定义thumbnail最大宽高并展示streaming downsample | ImageIO docs/WWDC | 输出像素gate与实现方向 | 各格式peak allocation | IMG-2 child RSS |
| PDFView 扩大 action surface | PDF actions + delegate hooks 明确存在 | PDFKit actions/delegate | static renderer 优先 | parser 本身安全 | PDF-1/PDF-2 |
| file preview 可能有外部 I/O | iCloud 可未下载；Quick Look 可取 actual file | Foundation ubiquity + QL docs | explicit-only policy | 所有 network-volume behavior | FILE-1 |
| file promise 可能留 partial file | Apple 明确说 error callback 仍可能有 partial/corrupt file | NSFilePromiseReceiver | cleanup/state machine | cancellation SLA | FILE-3 |
| support table 必须多维 | capture/paste 与 decoder/interaction 证据不同 | 上述全部 | capability descriptor | 最终模块数量 | MEMO-TYPE-1 + tracer slice |

## 11. Apple 官方来源索引

### Pasteboard

- [`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard)
- [`NSPasteboardItem`](https://developer.apple.com/documentation/appkit/nspasteboarditem)
- [`NSPasteboard.types`](https://developer.apple.com/documentation/appkit/nspasteboard/types)
- [`NSPasteboard.data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/data(fortype:))
- [`NSPasteboard.string(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/string(fortype:))
- [`readObjects(forClasses:options:)`](https://developer.apple.com/documentation/appkit/nspasteboard/readobjects(forclasses:options:))
- [`changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)
- [`NSPasteboardItemDataProvider`](https://developer.apple.com/documentation/appkit/nspasteboarditemdataprovider)
- [`NSPasteboard.WritingOptions.promised`](https://developer.apple.com/documentation/appkit/nspasteboard/writingoptions/promised)
- [`NSFilePromiseProvider`](https://developer.apple.com/documentation/appkit/nsfilepromiseprovider)
- [`NSFilePromiseReceiver.receivePromisedFiles`](https://developer.apple.com/documentation/appkit/nsfilepromisereceiver/receivepromisedfiles(atdestination:options:operationqueue:reader:))
- [AppKit updates](https://developer.apple.com/documentation/updates/appkit)

### UTI 与文本

- [Uniform Type Identifiers](https://developer.apple.com/documentation/uniformtypeidentifiers/)
- [System-declared UTIs](https://developer.apple.com/documentation/uniformtypeidentifiers/system-declared-uniform-type-identifiers)
- [`UTType.conforms(to:)`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttypereference/conforms(to:))
- [`UTType.isDynamic`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype/3551517-isdynamic)
- [`UTType.text`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/text)
- [`UTType.plainText`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/plaintext)
- [`UTType.utf8PlainText`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/utf8plaintext)
- [`UTTypeUTF16ExternalPlainText`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttypeutf16externalplaintext)
- [`NSAttributedString`](https://developer.apple.com/documentation/foundation/nsattributedstring)
- [`NSTextAttachment`](https://developer.apple.com/documentation/appkit/nstextattachment)

### Rendering 与文件

- [`CGImageSource`](https://developer.apple.com/documentation/imageio/cgimagesource)
- [`CGImageSourceStatus`](https://developer.apple.com/documentation/imageio/cgimagesourcestatus)
- [`kCGImageSourceShouldCacheImmediately`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately)
- [`PDFDocument`](https://developer.apple.com/documentation/pdfkit/pdfdocument)
- [`PDFAction`](https://developer.apple.com/documentation/pdfkit/pdfaction)
- [`PDFActionURL`](https://developer.apple.com/documentation/pdfkit/pdfactionurl)
- [`PDFActionRemoteGoTo`](https://developer.apple.com/documentation/pdfkit/pdfactionremotegoto)
- [`PDFViewDelegate`](https://developer.apple.com/documentation/pdfkit/pdfviewdelegate)
- [`WKWebView`](https://developer.apple.com/documentation/webkit/wkwebview)
- [`WKWebpagePreferences.allowsContentJavaScript`](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript)
- [`WKContentRuleListStore`](https://developer.apple.com/documentation/webkit/wkcontentruleliststore)
- [`WKWebsiteDataStore`](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)
- [`QLThumbnailGenerator`](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator)
- [`QLThumbnailGenerator.cancel(_:)`](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator/cancel(_:))
- [Creating Quick Look Thumbnails](https://developer.apple.com/documentation/quicklookthumbnailing/creating-quick-look-thumbnails-to-preview-files-in-your-app)
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [`URLResourceKey`](https://developer.apple.com/documentation/foundation/urlresourcekey)
- [`URLUbiquitousItemDownloadingStatus`](https://developer.apple.com/documentation/foundation/urlubiquitousitemdownloadingstatus)
