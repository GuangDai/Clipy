# Apple Preview 能力与安全边界备忘录

日期：2026-08-22

范围：macOS 26+；ImageIO、QuickLookThumbnailing、PDFKit、
`NSAttributedString`、WebKit、AVFoundation、文件 URL 与不可信解码。

来源规则：只使用 Apple 一手资料；不把运行时尝试成功等同于稳定产品承诺。

> 架构解释边界：本文较早的 `PreviewCore + ApplePreviewPipeline`、`PreviewEngine` 生命周期与
> encoded PNG/JPEG artifact sketch 仅是研究候选，已被最终设计收敛。规范性方向以
> [`08-content-types-and-preview.md`](08-content-types-and-preview.md) 为准：一个 concrete
> `ContentPreview` target；`PreviewContentLoader` 独占 History/reference/task/lifecycle；默认 artifact 是
> eager bounded pixel/text value，encoded raster 只有独立 UI-decode budget/spec gate 后才可能准入。

## 1. 结论先行

Clipy 若要“支持更多类型、在代码里清楚看出支持什么、并让每个模块独立”，
最稳妥的方向不是继续扩展 `PreviewContent.resolve` 的 `if` 列表，而是建立一个
独立的 Preview 深模块：

1. 代码中的**声明策略**明确列出支持族、优先级、允许的输入来源、资源预算和
   外部 I/O 政策；
2. 启动时的**运行时能力快照**调用 Apple 提供的动态查询，并与声明策略求交集；
3. 一个纯规划器从 Effective Content 生成不可变 `PreviewPlan`，不执行 I/O；
4. 每个格式族只有一个渲染实现；上层只接收 Foundation 值类型的
   `PreviewArtifact`，不接触 `CGImage`、`NSImage`、`PDFDocument`、`WKWebView`、
   `AVAsset`；
5. 默认禁止自动网络、云端下载、网络卷读取、外部文件引用和链接动作；需要读取
   外部资源时，必须转为明确的用户动作；
6. 对 Apple 没有文档化 CPU、峰值 RSS 或墙钟上界的解析器，不得把“最终输出尺寸
   有界”写成“解码资源有界”。先用子进程测量；证据不足时，把高风险渲染放到
   最小权限的 XPC / Enhanced Security helper。

这不是为了制造很多target。最终建议只有一个package-only concrete `ContentPreview` target；stable facts来自
`ClipboardFormats`，Preview manifest与Image/PDF/Rich Text/HTML/Media/File Quick Look等private family
handlers都由该target拥有并共享一个小render接口。build/test inventory不参与runtime选择。

## 2. 证据标签

- **DOC**：Apple 文档直接保证。
- **INFERENCE**：由一个或多个 DOC 事实推导，仍需运行时测试。
- **UNKNOWN**：Apple 文档没有给出足以形成产品承诺的保证。

## 3. 当前实现的具体落差

### P-01：RTF 与 HTML 只按 UTF-8 解码，不是富文本预览

当前 `PreviewContent.resolve` 把 `public.rtf`、`public.html` 放进文本集合，但除
UTF-16 外一律用 UTF-8 生成 `String`。因此它显示的是源码字符，而不是 RTF/HTML
语义。这一点可直接从
[`HistoryPreviewView.swift`](../../../Sources/PresentationUI/HistoryPreviewView.swift)
的类型表与解码分支核对。

Apple 为 RTF、RTFD、HTML 提供了明确的 `NSAttributedString` 导入接口；HTML
转换由 WebKit 完成，并且 Apple 特别要求验证其结果和性能。Apple 还明确警告：
Apple写的是HTML导入 **should not** 在后台执行：后台会尝试与主线程同步并可能失败/超时；含外部
资源引用时即使在主线程也可能超时，但不是任意外部资源必然超时。这个机制适合
类似 Markdown 的有限样式转换，不适合通用 HTML 导入。
([`NSAttributedString`](https://developer.apple.com/documentation/foundation/nsattributedstring),
[`init(data:options:documentAttributes:)`](https://developer.apple.com/documentation/foundation/nsattributedstring/init(data:options:documentattributes:)))

结论：

- **DOC**：RTF、RTFD、HTML 是不同文档格式；HTML 导入由 WebKit 实现。
- **DOC**：含外部资源引用的 HTML 可能令导入超时，Apple 的文档建议避免这种输入。
- **INFERENCE**：Clipy 不应复用当前 UTF-8 分支声称支持 RTF/HTML；应给富文本族
  独立渲染模块与独立失败类型。

### P-02：图片能力表被复制，且不是运行时真相

同一七项图片 UTI 集合目前至少存在于：

- `HistoryAuthority.thumbnailImageTypeIdentifiers`；
- `PreviewContent` 的图片集合；
- `ThumbnailStore.thumbnailableTypeIdentifiers`。

Apple 提供 `CGImageSourceCopyTypeIdentifiers()` 返回当前 ImageIO 可读取的类型，
并明确说明各平台的图片格式支持会变化。
([`CGImageSourceCopyTypeIdentifiers`](https://developer.apple.com/documentation/imageio/cgimagesourcecopytypeidentifiers()),
[`Creating Quick Look Thumbnails`](https://developer.apple.com/documentation/quicklookthumbnailing/creating-quick-look-thumbnails-to-preview-files-in-your-app))

结论：

- **DOC**：ImageIO 可在运行时报告其可读 UTI 集合。
- **INFERENCE**：声明策略仍应在代码中可读，但实际启用集合应为“产品允许集合 ∩
  当前系统能力”，而不是复制三份静态集合。
- **UNKNOWN**：未来 macOS 版本增加或移除哪些具体格式；不能把某次机器快照当成
  永久公开契约。

### P-03：当前注释过度承诺 ImageIO 的临时内存行为

`DisplayImageDecoder.previewImage` 的注释称“full bitmap never materializes”。Apple
API文档保证 `kCGImageSourceThumbnailMaxPixelSize` 限制缩略图宽高；Apple的WWDC ImageIO示例还展示并
推荐streaming downsample，在该示例中dirty-memory主要付结果图成本。后者是正面平台设计证据，但不是
macOS 26所有格式/恶意输入的worst-case合同。若未设置，缩略图
甚至可能和原图一样大。文档没有保证解析器在生成缩略图期间不会分配完整图像或
其他大结构。
([`kCGImageSourceThumbnailMaxPixelSize`](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize),
[`CGImageSourceCreateThumbnailAtIndex`](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:)))

结论：

- **DOC**：最终 thumbnail 的两轴受最大像素尺寸限制。
- **DOC/示例上限**：Apple展示了streaming downsample用法；只能支持该pipeline方向，不支持普遍峰值。
- **UNKNOWN**：解码期间峰值 RSS、CPU、墙钟时间和内部完整位图分配。
- **修改意见**：把注释改成“输出尺寸有界”；临时资源只能由测量证据支持。

### P-04：当前 Preview 直接跨 actor 传 `CGImage`，与仓库既定规则冲突

`docs/01-architecture.md §6` 明确禁止 `CGImage` 跨 actor，而
`DisplayImageDecoder` actor 的结果正是 `CGImage?`。无论当前 SDK 是否给
`CGImage` 并发标注，这都是设计文档与实现不一致。扩展更多格式前，应先决定：

- 保持规则：Apple渲染模块默认输出checked eager RGBA/BGRA pixels、rowBytes/尺寸/color-space等中性值，
  UI在MainActor只做最终显示对象构造；encoded artifact只有独立UI-decode gate后才准入；或
- 正式修订规则：允许某一条经过审计的、路径限定的 immutable image seam。

不要靠文件注释单方面创造例外。

## 4. Apple 框架能力边界

### 4.1 ImageIO

#### 文档直接保证

- `CGImageSource` 可从 `CFData`、文件 URL 或 data provider 创建，并可获取图像、
  缩略图和元数据。
  ([`CGImageSource`](https://developer.apple.com/documentation/imageio/cgimagesource))
- `CGImageSourceCopyTypeIdentifiers()` 返回当前 image source 支持的 UTI。
- `CGImageSourceGetCount` 返回容器中的图像数量，不含缩略图。
- `CGImageSourceGetPrimaryImageIndex` 只对 HEIF 返回容器的 primary image；其他
  格式返回 0。因此把它用于所有格式等价于“HEIF 取 primary，其余取 index 0”。
  ([`CGImageSourceGetPrimaryImageIndex`](https://developer.apple.com/documentation/imageio/cgimagesourcegetprimaryimageindex(_:)))
- `CGImageSourceCreateThumbnailAtIndex` 对无效 index 或错误返回 `nil`；PDF 输入需要
  `CreateThumbnailFromImageIfAbsent` 或 `Always` 才能按页生成 72 dpi 图片。
- `CreateThumbnailFromImageAlways` 若没有同时指定最大像素尺寸，会按原图完整尺寸
  创建 thumbnail，Apple 明确认为多数情况下不理想。
  ([`kCGImageSourceCreateThumbnailFromImageAlways`](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailfromimagealways))
- `CreateThumbnailWithTransform` 默认关闭；打开后才应用方向和长宽比变换。
  ([`kCGImageSourceCreateThumbnailWithTransform`](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailwithtransform))
- `kCGImageSourceShouldCacheImmediately` 默认关闭；对文档列出的创建/属性函数，
  关闭意味着在渲染时才解码缓存。`kCGImageSourceShouldCache` 在 64 位平台默认开启。
  ([`kCGImageSourceShouldCacheImmediately`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately),
  [`kCGImageSourceShouldCache`](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcache))
- ImageIO 有 invalid data、unknown type、unexpected EOF、incomplete 等状态。
  ([`CGImageSourceStatus`](https://developer.apple.com/documentation/imageio/cgimagesourcestatus))

#### 必须校准的推断

- **INFERENCE**：缩略图必须显式给 `Always`、`MaxPixelSize`、`WithTransform`；不能
  依赖默认值。
- **INFERENCE**：多图容器的产品策略必须单独声明：HEIF primary、GIF 首帧或动画、
  TIFF 首页或多页。Apple 的 primary helper 不替 Clipy 决定 GIF/TIFF 语义。
- **UNKNOWN**：ImageIO没有与一次同步thumbnail调用绑定的取消接口；Swift Task取消本身既不证明底层
  解码即时停止，也不自动阻止发布。Clipy必须用loader token/exact-reference fence抑制late result，并在
  native work真实返回前持续计费。
- **UNKNOWN**：`MaxPixelSize` 不构成 CPU、峰值 RSS、metadata 数量或恶意压缩比上界。
- **UNKNOWN**：`ShouldCacheImmediately` 文档没有把 thumbnail 创建函数列为适用函数；
  不应未经运行时验证就声称该键能控制 thumbnail 路径的 eager decode。

#### 适合 Clipy 的模块职责

`ImagePreviewRenderer`只接受已经通过预算检查的bytes、声明UTI与目标像素；内部验证ImageIO实际sniff
出的容器类型、count、primary index和状态，默认输出checked eager pixel artifact或明确失败。它不读取
History、不拥有UI，也不决定representation优先级。

### 4.2 QuickLookThumbnailing

#### 文档直接保证

- `QLThumbnailGenerator.Request` 的输入是一个**文件 URL**，没有 Data initializer。
  ([`Request.init(fileAt:size:scale:representationTypes:)`](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator/request/init(fileat:size:scale:representationtypes:)))
- Quick Look Thumbnailing 可对图片、文本、PDF、音视频等常见文件生成 icon、低质量
  thumbnail 和高质量 thumbnail；自定义扩展可以增加支持类型。
- `generateRepresentations` 可能跳过较低质量回调，但结束前至少给一次最佳结果或
  error。
- `cancel(_:)` 可取消指定 request，取消对应
  `QLThumbnailError.Code.requestCancelled`。
  ([`cancel(_:)`](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator/cancel(_:)),
  [`requestCancelled`](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailerror-swift.struct/code/requestcancelled))
- Apple 明确描述 iCloud 情况下 Quick Look 可能下载缩略图，某些小文件甚至下载
  原文件后生成缩略图。
- `QLPreviewItem.previewItemURL` 同样必须是 file URL。
  ([`previewItemURL`](https://developer.apple.com/documentation/quicklook/qlpreviewitem/previewitemurl))

#### 边界

- **DOC**：request接收 file URL，没有直接的 clipboard-`Data` initializer。
- **INFERENCE**：若 source 只有历史 bytes，Clipy需要提供受控 file-backed materialization；它可以是
  app-owned临时文件，也可能是未来已批准的immutable blob file，不能把具体落盘形状写成Apple合同。
- **UNKNOWN**：Apple 没有为普通 `QLThumbnailGenerator` 提供“列出当前所有可预览
  UTI”的通用查询。`QLSupportedContentTypes` 是自定义 thumbnail extension 自己的
  声明，不是系统能力枚举。
- **INFERENCE**：Quick Look 应是 file-preview 的尝试型 adapter，而不是 registry
  的支持真相；结果要区分 `.unsupported`、`.cancelled`、`.temporarilyUnavailable`。
- **INFERENCE**：默认“禁止外部 I/O”时，不能把任意 file URL 直接交给 Quick Look；
  iCloud、File Provider 或网络卷都可能发生隐式读取/下载。

### 4.3 PDFKit

#### 文档直接保证

- `PDFDocument` 可从 Data 或文件 URL 初始化，并暴露 page count、加密与锁定状态。
  ([`PDFDocument`](https://developer.apple.com/documentation/pdfkit/pdfdocument),
  [`Read Operations`](https://developer.apple.com/documentation/pdfkit/read-operations))
- `PDFPage.thumbnail(of:for:)` 可按目标尺寸生成页面缩略图。
  ([`PDFPage.thumbnail`](https://developer.apple.com/documentation/pdfkit/pdfpage/thumbnail(of:for:)))
- PDF 可以包含链接、表单和其他交互 annotation；annotation 可携带 URL action。
  `PDFViewDelegate` 有链接点击回调，也有 remote-go-to 等动作回调。
  ([`PDFAnnotation`](https://developer.apple.com/documentation/pdfkit/pdfannotation),
  [`PDFViewDelegate`](https://developer.apple.com/documentation/pdfkit/pdfviewdelegate))
- PDF 自带的 copy/print 等权限由文档声明；Apple 提醒应用自己负责执行这些权限。
  ([`allowsCopying`](https://developer.apple.com/documentation/pdfkit/pdfdocument/allowscopying))

#### 边界与建议

- **INFERENCE**：默认预览应从历史 Data 创建 `PDFDocument`，只渲染静态第一页或
  限定页数的缩略图，不把原始 file URL 交给 PDFKit。
- **INFERENCE**：若以后提供交互 `PDFView`，外部 URL、remote-go-to、打印和表单
  必须由统一 policy adapter 拒绝或转为明确用户确认；不能依赖视图默认行为。
- **UNKNOWN**：PDFKit 文档没有解析 CPU、峰值内存、递归对象数量或恶意 PDF 的
  墙钟上限。

### 4.4 `NSAttributedString`：RTF、RTFD、HTML

#### 文档直接保证

- RTF、RTFD 有专用 Data initializer；RTFD 可包含附件。
  ([`init(RTFD:documentAttributes:)`](https://developer.apple.com/documentation/foundation/nsattributedstring/init(rtfd:documentattributes:)))
- 通用 Data initializer 可由 `documentType` 明确指定格式；空 options 会自动探测。
- `textTypes` 包含直接支持类型和用户安装 filter service 可转换的类型；
  `textUnfilteredTypes` 才是直接支持集合。
  ([`textTypes`](https://developer.apple.com/documentation/foundation/nsattributedstring/texttypes))
- HTML importer 由 WebKit 处理；不支持的结构会被忽略；Apple 要求测试结果和性能。
- HTML 读取 options 包含 `baseURL`、`readAccessURL`、timeout、WebKit preference 和
  web resource load delegate；这些选项本身说明 HTML 转换具有资源读取面。
  ([`DocumentReadingOptionKey`](https://developer.apple.com/documentation/foundation/nsattributedstring/documentreadingoptionkey),
  [`readAccessURL`](https://developer.apple.com/documentation/foundation/nsattributedstring/documentreadingoptionkey/readaccessurl))

#### 边界与建议

- **INFERENCE**：Clipy 的默认支持集合不应直接采用 `textTypes`，因为用户安装的
  filter service 会使能力随机器变化，也扩大隐式转换面。使用明确的
  `textUnfilteredTypes` 交集或静态 RTF/RTFD 声明更可审计。
- **INFERENCE**：解析后还需净化 attributed attributes：外部 link 变为不可自动
  激活的文本，attachment 单独计数/限额，未知 attachment 用占位符。
- **DOC/产品否决**：不要把任意 clipboard HTML 直接送入 `NSAttributedString` HTML
  importer；Apple 对外部资源超时已有明确警告。
- **UNKNOWN**：RTF/RTFD 解析的峰值内存、字体表/对象数量、附件膨胀上界。

### 4.5 WebKit 本地 HTML

#### 文档直接保证

- `WKWebView` 是完整 web-content renderer，会自动加载页面内嵌图片和视频资源；
  `loadHTMLString` 的 `baseURL` 用于解析相对 URL。
  ([`WKWebView`](https://developer.apple.com/documentation/webkit/wkwebview),
  [`loadHTMLString`](https://developer.apple.com/documentation/webkit/wkwebview/loadhtmlstring(_:baseurl:)))
- content JavaScript 默认开启；`allowsContentJavaScript = false` 禁止页面内联、
  `javascript:` URL 与引用脚本。
  ([`allowsContentJavaScript`](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript))
- `WKNavigationDelegate` 管理的是 main-frame navigation，文档没有把它描述为全部
  subresource 的拦截器。
- `WKContentRuleList` 可以在 web view 内阻止匹配资源加载；`url-filter: .*` 匹配全部
  URL，`block` 动作停止资源加载且不使用缓存。
  ([`WKContentRuleListStore`](https://developer.apple.com/documentation/webkit/wkcontentruleliststore),
  [`Creating a content blocker`](https://developer.apple.com/documentation/safariservices/creating-a-content-blocker))
- `WKURLSchemeHandler` 只接管 WebKit 不原生处理的自定义 scheme；当资源不再需要时
  会收到停止通知。
  ([`WKURLSchemeHandler`](https://developer.apple.com/documentation/webkit/wkurlschemehandler))
- 默认 website data store 持久化到磁盘；`nonPersistent()` 只在内存保存站点数据。
  ([`WKWebsiteDataStore`](https://developer.apple.com/documentation/webkit/wkwebsitedatastore))

#### 安全判断

- **INFERENCE**：`baseURL = nil` 只影响相对 URL 解析；结合 WebKit 自动加载嵌入
  资源的文档行为，它不会从 HTML 中删除绝对
  `https:`、`file:`、`data:` 等资源。
- **INFERENCE**：只关 JavaScript 不能阻止图片、CSS、字体、媒体、iframe 等非脚本
  资源加载；其他通道是否已被完整阻止仍需 content-rule 与网络探针验证。
- **INFERENCE**：若实现高保真 HTML，至少需要：
  1. 先做大小与结构预算；
  2. 把允许的内嵌资源复制到 app-owned map，并重写为自定义 scheme；
  3. JS 关闭；
  4. non-persistent data store；
  5. content rule 默认阻止所有非自定义资源；
  6. main-frame navigation、popup、download、权限和外部链接统一拒绝；
  7. 不安装 script-message bridge；
  8. 离线网络探针证明没有 DNS/TCP/HTTP 事件。
- **UNKNOWN**：Apple 文档没有把以上组合表述为形式化的“零外部 I/O”保证。因此在
  测试证据形成前，默认产品路径应使用静态、受限的 HTML-to-text/attributed-text
  renderer；WebKit fidelity 只能作为实验或明确用户选择。

### 4.6 AVFoundation 音视频

#### 文档直接保证

- `AVURLAsset` 表示本地或远程 URL 的媒体；创建 asset 很轻量，实际媒体属性延迟
  到异步加载时读取，耗时受媒体大小、设备和网络条件影响。
  ([`AVURLAsset`](https://developer.apple.com/documentation/avfoundation/avurlasset),
  [`Loading media data asynchronously`](https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously))
- `audiovisualContentTypes` 返回当前类理解的 `UTType` 集合；旧的
  `audiovisualTypes()` 已 deprecated。
  ([`audiovisualContentTypes`](https://developer.apple.com/documentation/avfoundation/avurlasset/audiovisualcontenttypes))
- 容器类型可支持并不等于具体 codec 可播放；若已知包含 codec 的 extended MIME，
  可用 `isPlayableExtendedMIMEType`，实际 asset 仍应异步读取 `isPlayable`。
- `cancelLoading()` / `cancelAllCGImageGeneration()` 当前文档仍可用；Swift新实现宜优先评估
  `load(_:)`、`image(at:)` / `images(for:)`等async API。Swift Task cancellation或显式cancel多快停止底层I/O/
  frame generation仍为`UNKNOWN`，必须实测，不能仅由方法存在推导及时取消合同。
  ([`cancelAllCGImageGeneration`](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/cancelallcgimagegeneration()))
- `AVAssetImageGenerator.maximumSize` 限制生成图像的 bounding box；零表示原始尺寸。
- 媒体容器可以引用容器外数据。`AVURLAssetReferenceRestrictionsKey` 配置外部引用
  政策；`.forbidAll` 要求媒体只在容器内，遇到被禁止引用时属性加载失败。
  ([`AVURLAssetReferenceRestrictionsKey`](https://developer.apple.com/documentation/avfoundation/avurlassetreferencerestrictionskey),
  [`AVAssetReferenceRestrictions`](https://developer.apple.com/documentation/avfoundation/avassetreferencerestrictions))

#### 边界与建议

- **INFERENCE**：clipboard Data 的音视频预览应先写入 app-owned、随机命名、权限
  受限的临时文件，再以 `.forbidAll` 和 alias references disabled 创建 asset。
- **INFERENCE**：只在用户按 Play 后创建播放器；默认只生成静态封面/首帧或显示
  媒体元数据，且永不自动播放音频。
- **INFERENCE**：运行时支持判断分两级：声明 UTI 与
  `audiovisualContentTypes` 求交；随后对实际容器异步检查 playable/tracks。
- **UNKNOWN**：`maximumSize` 不保证视频解码峰值 RSS 或解析时间；取消也不等于所有
  底层工作在固定期限内终止。

### 4.7 文件 URL、sandbox、云端与网络卷

#### 文档直接保证

- 在 App Sandbox 中，文件 URL 可因 sandbox、POSIX/ACL 或强制访问控制而失败。
  用户选择、drag/drop、bookmark 等授权路径各有不同生命周期。
  ([`Accessing files from the macOS App Sandbox`](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox))
- security-scoped URL 使用时需平衡
  `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`；
  不平衡会泄漏内核资源并最终使进程无法再扩展访问。
- `URLResourceKey.volumeIsLocalKey` 可查询卷是否在本地设备；还有 internal、removable、
  mount-from-location 等卷属性。
  ([`URLResourceKey`](https://developer.apple.com/documentation/foundation/urlresourcekey),
  [`volumeIsLocalKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeislocalkey))
- `NSFileCoordinator.ReadingOptions.immediatelyAvailableMetadataOnly` 可在不触发下载的
  情况下读取立即可用 metadata；此时实际读 contents 可能失败。
  ([`immediatelyAvailableMetadataOnly`](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/immediatelyavailablemetadataonly))
- iCloud item 的实际内容可能需要 `startDownloadingUbiquitousItem` 才在本机可用。
  ([`startDownloadingUbiquitousItem`](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:)))

#### 产品边界

- **INFERENCE**：Apple 另设本地卷与 ubiquitous download 状态查询，因此
  `url.isFileURL == true` 本身不足以证明内容已经本地可用，也不足以证明不会触发
  网络卷或云端读取。
- **INFERENCE**：默认hover不触碰external URL，只显示capture时已有的lexical URL/type facts。显式“Inspect
  File”才使用`immediatelyAvailableMetadataOnly`查询；它减少主动正文下载，不证明zero-I/O或第三方
  File Provider/SMB绝无网络活动。非本地卷、未下载item、权限未知项仍需另一“Load Preview”动作。
- **INFERENCE**：用户确认后，由 `FileAccessLease` 模块在一个词法作用域内持有
  security scope 与 file coordination，并只把 app-owned 快照交给 decoder。Decoder
  永不持有外部 URL，也不负责授权。
- **UNKNOWN**：第三方 File Provider 与网络文件系统的延迟、下载副作用和取消响应；
  需要真实 provider / SMB 测试矩阵。

## 5. 研究候选的收敛结果（执行以 `08` 为准）

下面的framework family与安全约束仍可作证据，但早期双target/`PreviewEngine`分工已被否决；后续agent不得
实现`PreviewCore + ApplePreviewPipeline`，也不得把History/reference/task ownership移出既有loader。

### 5.1 目标依赖图

```text
PresentationUI.PreviewContentLoader ──→ HistoryCore
                 │ immutable Effective snapshot + closed intent/profile/source policy
                 ▼
      package-only concrete ContentPreview
      ├── internal ImageIO / PDFKit / RichText families
      └── future WebKit / AV / QL only after separate admission
```

只新增一个package-only concrete `ContentPreview` target；它拥有source selection、decoder routing、资源规则
与typed artifact，不读取History。`PreviewContentLoader`继续独占exact reference、task/cancellation、panel
lifecycle与late-result publish fence。PresentationUI不再直接import ImageIO，但render edge可按批准gate从
bounded inert artifact临时构造display object。

### 5.2 外部接口应小

loader只调用一个render行为：传入immutable Effective snapshot、closed intent、预定义resource profile与
首期仅`.historyBytesOnly`的source policy；不传History reference、不让caller自选renderer/任意budget/
external-I/O Bool。取消/版本fence由loader拥有，renderer只检查本次task并清理本次work。

输出只使用不可变 Sendable 值：有界 text/runs、默认eager checked RGBA/BGRA pixel buffer、尺寸、时长和
不可自动激活的 link metadata。encoded PNG/JPEG artifact只有独立UI-decode budget/spec gate后才可准入。
不要在 public/package
接口出现 `CGImage`、`NSImage`、`PDFDocument`、`AVAsset`、`WKWebView` 或 URL 的
持续访问令牌。

### 5.3 内部模块

| 模块 | 小接口后隐藏的实现 | 删除测试 |
|---|---|---|
| `PreviewTypeManifest` | 声明类型族、精确 UTI/动态 probe、优先级、外部 I/O 政策、预算 | 删除后类型表、策略和测试会重新散落到 UI/Storage/decoder |
| `PreviewPlanner` | Effective Content 选择、fallback、manifest/runtime 求交、budget admission | 删除后每种 surface 都会重新实现选择分支 |
| `PreviewContentLoader`（PresentationUI既有owner） | exact-reference fence、任务所有权、取消与artifact发布 | 删除后 UI 重复处理 race 与生命周期；它不进入`ContentPreview`target |
| `ImagePreviewRenderer` | ImageIO sniff/count/primary/transform/thumbnail/encode | 删除后图片知识散到 Storage 与 UI |
| `RichTextPreviewRenderer` | UTF/RTF/RTFD 明确解析、属性净化、attachment 限额 | 删除后 RTF/HTML 继续假装 plain text |
| `HTMLPreviewRenderer` | 静态受限模式；可选 WebKit 隔离模式及全拒绝资源策略 | 删除后 HTML 网络与脚本政策由 view 临时决定 |
| `PDFPreviewRenderer` | Data-only 静态页渲染、encrypted/locked/actions 分类 | 删除后 PDFView 默认交互泄漏到 UI |
| `MediaPreviewRenderer` | 临时快照、AV type probe、forbidAll、frame/cancel、no autoplay | 删除后 URL、外部引用与播放策略散落 |
| `FileAccessLease` | 显式动作后的metadata inspect、local/cloud/network分类、security scope、coordination、snapshot | 删除后 decoder 自己访问用户 URL；default hover不调用它 |
| `QuickLookFileRenderer` | app-owned file request、representation upgrade、request cancellation | 删除后 UI 持有 QL request 与临时文件 |

这里的 module 是逻辑所有者，不表示每行都要单独成为 SwiftPM target。共享 Apple
依赖和同一生命周期的 renderer 应留在一个 target 内，以保持 locality。

### 5.4 类型清单必须同时“代码可读”与“运行时真实”

建议每一条 manifest rule 至少记录：

- stable rule ID；
- 支持族与显示名；
- exact UTI 集或动态 probe ID；
- renderer ID；
- representation 优先级；
- source policy：history bytes / app-owned temp / user-approved external file；
- external I/O：deny / require user action；
- input、decoded/output、character/page/frame、deadline 等预算；
- fallback 与失败类别。

启动时生成只读 `PreviewCapabilitySnapshot`：manifest version、macOS build、ImageIO
readable types、AV audiovisual types、实际 enabled/disabled rule 及原因。它供诊断页、
测试 artifact 和 bug report 使用，不写回业务状态。这样代码审查能看见“产品声明”，
运行时也能回答“这台机器真正能做什么”。

## 6. 推荐运行时矩阵

| 输入族 | 声明/运行时判断 | 默认 renderer | 自动外部 I/O | 关键预算 | 默认 fallback |
|---|---|---|---|---|---|
| UTF-8/UTF-16 plain text | 精确 UTI + 明确 encoding | native text | 禁止 | bytes、Unicode scalars、lines | hex/type metadata |
| RTF | 精确 UTI + direct support | sanitized attributed text | 禁止 | bytes、characters、attributes | plain extracted text |
| RTFD | 精确 UTI + direct support | sanitized attributed text + bounded attachments | 禁止 | bytes、attachments/count | text + attachment markers |
| HTML | 精确 UTI；不使用 generic `textTypes` | plain sibling优先；否则type/byte metadata | 禁止 | bytes、DOM/token count、characters | source/static仅在charset/grammar批准后 |
| Image | manifest family ∩ `CGImageSourceCopyTypeIdentifiers` | ImageIO thumbnail | 禁止 | encoded bytes、output pixels/bytes、deadline | type/dimensions |
| PDF bytes | exact PDF UTI + `PDFDocument(data:)` success | static page thumbnail | 禁止 | bytes、pages rendered、output pixels | encrypted/locked/type state |
| Audio/video bytes | manifest family ∩ `audiovisualContentTypes` + Clipy保守要求`isPlayable == true` | local temp + AVFoundation | 禁止 | bytes、duration probe、frame pixels、deadline | metadata/icon |
| Local file URL | metadata proves local/readable/already available | Quick Look or family renderer | 禁止 | file size、deadline、temp snapshot | file icon/metadata |
| Cloud/network file URL | metadata only | none until user action | **禁止** | metadata deadline | “Load Preview” |

Apple说明`isPlayable == false`时应用仍可尝试播放，只是体验可能较差；表中的true要求是Clipy保守admission，
不是平台宣称“绝对无decoder”。
| Web URL | exact URL UTI | URL text/card only | **禁止** | string length | escaped URL |
| Unknown/custom | exact bytes retained by History | none | **禁止** | metadata only | UTI + byte count |

注意：矩阵的“支持”必须是三态，而非 Bool：

- `declaredAndAvailable`；
- `declaredButUnavailable(reason)`；
- `notDeclared`。

Quick Look 还需要第四类尝试结果 `attemptFailed`，因为没有通用的系统支持类型枚举。

## 7. 不可信 decoder 的资源与权限模型

Apple 的 Secure Coding Guide 明确把来自用户/其他进程的音频、视频、图片文件列为
不可信输入，并要求对输入作合理性检查。Apple 对 XPC 的说明把 privilege separation
和 crash isolation 列为主要用途；Enhanced Security helper extension 更直接把
“处理不可信来源的数据”作为独立进程场景。
([`Validating Input`](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/ValidatingInput.html),
[`Creating XPC Services`](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html),
[`Creating enhanced security helper extensions`](https://developer.apple.com/documentation/xcode/creating-enhanced-security-helper-extensions))

建议分级：

1. **L0 纯值**：plain text、URL 字符串，进程内，严格 byte/character cap。
2. **L1 Apple parser + 小输入**：图片、RTF、PDF 首屏，先做输入 cap、输出 cap、
   wall-clock cancellation 与 child-process RSS 实验；没有越界证据前可进程内。
3. **L2 高风险/复杂**：HTML WebKit、音视频、Quick Look 任意文件、异常大或历史上
   容易崩溃的格式。优先放最小权限 XPC / Enhanced Security helper；helper 无网络、
   不访问 History store、只接收 bounded Data/app-owned temp file，只返回 bounded
   value artifact。

XPC 不是自动安全：主进程必须把 helper 返回值也当不可信，校验长度、像素、枚举和
关联 request ID；helper 必须自己执行预算和 source policy，不能成为由主进程任意
驱动的文件读取代理。

Apple 文档没有提供通用“每次 decoder 调用的硬内存上限”。因此超时取消是结果发布
与体验机制，不是内存隔离；真正的 crash/权限隔离依赖独立进程和 sandbox。

## 8. TDD / 证据流程

每个循环只证明一个行为；先写可编译的失败测试，再最小实现，再重构。不要通过 mock
Apple framework 内部对象证明产品行为；用小 fixture、真实 framework 与可观察的
输出/系统副作用。

### TDD-P1：类型 manifest 是唯一声明源

**Red**：一个测试枚举 manifest，断言每条 rule 有稳定 ID、renderer、预算、外部
I/O policy，且同一 exact UTI 不出现冲突优先级；另一个源码 gate 禁止在 UI/Storage
再次出现维护型 UTI set。

**Green**：迁移一类图片规则，由 planner 与 thumbnail admission 共用。

**Refactor**：再迁移 text/RTF/HTML；删除旧复制集合，而不是在其上再加 registry。

### TDD-P2：运行时能力快照

**Red**：在 macOS CI 记录 ImageIO 与 AVFoundation runtime set，断言 manifest
声明项只有在 runtime 支持时 enabled；snapshot 按 UTI 排序且包含 OS build。

**Green**：加入一次启动 probe。

**Refactor**：让诊断输出和测试共用同一 snapshot serializer。

### TDD-P3：图片多容器与 primary 规则

**Red**：fixtures 覆盖 PNG、JPEG、HEIF primary 非零、GIF 多帧、TIFF 多页、错误
header、truncated data；断言实际容器类型、chosen index、orientation、输出像素与错误
分类。

**Green**：实现 explicit option set 与 container policy。

**Refactor**：将 index 选择做纯函数，不在 UI 中出现 ImageIO 细节。

### TDD-P4：ImageIO 资源证据，不用注释代替

**Red/实验**：独立子进程分别解码小图、超大尺寸小压缩文件、metadata-heavy、损坏
和动画 fixture；采集峰值 RSS、CPU、墙钟、输出像素、取消后的进程存活。

**Gate**：先制定 envelope，再决定 L1 是否留进程内；若任何 fixture 超 envelope 或
crash，转 L2 helper。

**Refactor**：把“输出受限”和“临时资源证据”写成两个不同 invariant。

### TDD-P5：RTF/RTFD 语义与净化

**Red**：RTF bold/link、RTFD attachment、错误 stream、超量 attachment；断言显示
语义不是源码，link 不可自动打开，attachment 超限为 marker，错误可区分。

**Green**：专用 initializer + attribute sanitizer。

**Refactor**：plain text、RTF、RTFD 共用 output budget，不共用 decoder。

### TDD-P6：HTML 零外部 I/O

**Red**：fixture 包含绝对/相对 HTTP(S) image、CSS、font、iframe、video、ping、
form、meta refresh、`javascript:`、file URL 和 data URL；测试用本机 canary DNS/HTTP
listener 与文件访问探针，断言 preview 全程零连接、零文件读取、零 popup/download。

**Green**：先实现plain sibling/type-byte metadata；escaped source或static subset只有charset/grammar
另行批准后才实现。安全canary通过本身不定义文本编码。

**Refactor/可选**：只有 WebKit content-rule/custom-scheme 路径也通过同一黑盒测试，
才允许作为 fidelity adapter；否则不进入默认产品路径。

### TDD-P7：PDF 静态默认

**Red**：普通、多页、加密/locked、URL annotation、remote-go-to、表单、超页数
fixtures；断言默认只渲染限定页、从不打开链接/文件、错误分类稳定。

**Green**：Data-only `PDFDocument` + static page thumbnail。

**Refactor**：交互 view 若加入，必须复用同一 action policy，而非另开默认行为。

### TDD-P8：AVFoundation 本地自包含

**Red**：自包含音频/视频、unsupported codec、外部 file reference、remote reference、
truncated、超长 duration；断言 `.forbidAll` 使外部引用加载失败，默认不播放，取消后
不发布，frame 尺寸受限。

**Green**：app-owned temp + reference restrictions + async actual-playable probe。

**Refactor**：把 temp lifecycle 与 AV renderer 分开，由 `TemporaryArtifactLease` 负责。

### TDD-P9：文件 URL 不自动下载

**Red**：本地、security-scoped、symlink、iCloud placeholder、File Provider、SMB
fixtures；初始 preview 只允许 metadata，canary 证明不下载/不读远端；用户明确触发后
才取得 lease。

**Green**：default hover只用captured lexical facts；显式Inspect才进入metadata-only coordinator +
local/available policy，并把其I/O/network行为留给canary证据。

**Refactor**：所有 PDF/AV/QL 文件读取都必须经过 `FileAccessLease`，禁止各自读取 URL。

### TDD-P10：取消、版本 fence 与 helper crash

**Red**：选择 A 后快速切 B、revision 改变、关闭 panel、helper 超时/crash；断言 A
永不覆盖 B、旧 `ContentVersion` 永不发布、所有 lease/temp 清理、UI 得到可重试的
typed outcome。

**Green**：`PreviewContentLoader`持有一个owned task + request token + exact reference；`ContentPreview`只处理
该次immutable source并返回artifact/outcome。

**Refactor**：删除view/renderer重复的selection/task分支，由既有loader统一Preview publish生命周期；
HistoryStorage row thumbnail继续拥有独立source/version fence，不并入该loader。

## 9. 必须保留为 UNKNOWN 的问题

以下问题不能仅凭 Apple API 说明关闭：

1. 各 decoder 面对 adversarial input 的峰值 RSS、CPU、墙钟和 crash 行为；
2. ImageIO thumbnail 路径是否在所有格式上避免完整像素面中间分配；
3. WebKit content rules/custom scheme 组合是否覆盖当前 macOS 的全部网络与文件资源
   通道；必须有 OS 级黑盒探针；
4. 第三方 Quick Look extension 的实际权限、资源和稳定性表现；
5. File Provider/SMB 在 metadata 查询、Quick Look 与 AV/PDF 打开时的下载副作用；
6. 具体 macOS 26 build 的 ImageIO/AVFoundation runtime type 集；
7. Enhanced Security helper 对本项目 XcodeGen/SwiftPM/签名发布流程的具体接入成本。

这些 UNKNOWN 应进入证据 backlog，而不是用更强的接口抽象掩盖。

## 10. 修改顺序

1. 先修正文档与当前注释：RTF/HTML 不再声称是富文本支持；ImageIO 只承诺输出
   像素有界；承认当前 actor 规则冲突。
2. 建立 manifest + pure planner，替换三份图片 UTI 表和 UI 中的类型选择。
3. 把当前 ImageIO decode 从 PresentationUI 移到唯一 Apple preview target；保持
   History 只提供 immutable bytes/reference。
4. 落地图片、plain/RTF/RTFD、PDF 的静态 renderer 和 TDD 矩阵。
5. 落地 `FileAccessLease`，默认禁止 cloud/network/implicit download。
6. 再做 AVFoundation 与 Quick Look；它们依赖文件/temp 生命周期和更强取消证据。
7. HTML 先静态受限版；WebKit 版只有在零外部 I/O 黑盒 proof 后再开放。
8. 根据 adversarial resource suite 决定哪些 renderer 必须迁移到 XPC / Enhanced
   Security helper；不要预先把所有格式都进程化，也不要在无证据时全部留进程内。

## 11. 紧凑证据图

| Claim | Reason | Source | Supports | Cannot establish | Next discriminator |
|---|---|---|---|---|---|
| 图片支持应为 manifest × runtime | ImageIO 提供动态 readable UTI 列表，平台支持可变 | ImageIO type identifiers；QL thumbnail guide | 当前机器格式 admission | 未来版本永久集合 | 每个 macOS build 保存 capability snapshot |
| ImageIO有streaming-downsample正面证据，但无普遍资源上限 | MaxPixelSize定义输出两轴；WWDC展示推荐streaming pipeline | ImageIO option docs + WWDC示例 | output extent与合理实现方向 | macOS26各格式/恶意输入峰值RSS/CPU/其它大临时结构 | adversarial child-process resource suite |
| Quick Look 是 file adapter | Request 只有 file URL initializer，且 iCloud 路径可能下载 | QL request/guide | 输入形态、取消、云端副作用存在 | 通用系统 UTI 支持枚举 | local/cloud/SMB 黑盒矩阵 |
| 含外部资源引用的 HTML 不走默认 importer | Apple 说明 importer 使用 WebKit，外部资源可令其超时 | NSAttributedString initializer | 默认路径应排除外部资源 | 净化器是否覆盖所有语法 | canary DNS/HTTP/file-access suite |
| AV 需自包含引用政策 | URL asset 可本地/远程，容器可有外部引用，forbidAll 可拒绝 | AVURLAsset/reference restrictions | 阻断容器外媒体引用 | decoder 时间和内存上界 | self-contained/external-ref fixtures + RSS |
| file URL 不等于本地可用 | Foundation 单独暴露 volume-local、ubiquity 与 metadata-only 状态 | URLResourceKey/NSFileCoordinator | 需要额外 admission | 第三方 provider 实际副作用 | iCloud/File Provider/SMB canary tests |
| 高风险解码可进 helper | Apple 将 XPC 用于 crash/privilege isolation，并推荐隔离不可信计算 | XPC/Enhanced Security docs | 独立进程是合理的风险控制 | helper 自动安全或资源硬限额 | entitlement audit、crash/timeout/hostile-reply tests |
