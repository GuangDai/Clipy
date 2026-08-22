# Apple Pasteboard 类型系统备忘：标准 `PasteboardType`

日期：2026-08-22

资料范围：仅 Apple 官方公开文档；本节聚焦 macOS AppKit 的
`NSPasteboard.PasteboardType` 标准类型，以及“声明了某类型”和“内容能够被解码”之间的边界。

## 1. 证据标记

- **DOC**：下述语义、访问方式或解码入口由 Apple 官方文档明确说明。
- **UNKNOWN**：Apple 当前公开文档没有给出稳定的字节级格式、完整 property-list schema，
  或没有承诺某个固定解码器。`UNKNOWN` 不等于“不支持”；它表示 Clipy 不应把猜测写成契约。

总索引：[Apple — `NSPasteboard.PasteboardType`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype)。
该页面把 `PasteboardType` 定义为“支持的 pasteboard 类型”，列出标准常量，并显示它符合
`RawRepresentable`，可由 `String`/`rawValue` 初始化。Apple 的
[`NSPasteboardItem.types`](https://developer.apple.com/documentation/appkit/nspasteboarditem/types)
又将每项的类型描述为 uniform type identifier 字符串。

> 架构解释边界：本文早期“单一descriptor/catalog拥有所有policy”的示意已被最终设计否决。执行以
> [`08-content-types-and-preview.md`](08-content-types-and-preview.md) 为准：`ClipboardFormats`只保存stable
> facts；各behavior owner拥有manifest；build/test inventory只检测漂移；一个concrete `ContentPreview`
> 内含private family handlers，History/reference/task仍由`PreviewContentLoader`拥有。
> 本轮规范性建议以 [`08-content-types-and-preview.md`](08-content-types-and-preview.md) 为准：
> `ClipboardFormats`只保存stable facts，purpose policy由owner manifests持有，inventory只读join。

## 2. 首要结论：类型标识符不等于可解码能力

这是实现中必须保留的三层区别：

1. **声明层（DOC）**：[`NSPasteboard.types`](https://developer.apple.com/documentation/appkit/nspasteboard/types)
   是所有 pasteboard item 已声明类型的并集；它只回答“对方声明可提供哪些表示”。
2. **取值层（DOC）**：`NSPasteboardItem` 分别提供
   [`data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboarditem/data(forType:))、
   [`string(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboarditem/string(forType:)) 和
   [`propertyList(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboarditem/propertylist(forType:))。
   类型名称并不会把任意表示自动变成 Clipy 想要的领域对象。
3. **解码层（DOC）**：Apple 另有
   [`canReadObject(forClasses:options:)`](https://developer.apple.com/documentation/appkit/nspasteboard/canreadobject(forclasses:options:))，
   它检查内容能否表示成指定的 `NSPasteboardReading` 类型；图像还有
   [`NSImage.canInit(with:)`](https://developer.apple.com/documentation/appkit/nsimage/caninit(with:))。
   二者的存在本身就说明“有某个 type identifier”与“某个对象解码器能够处理它”不是同一判断。

此外，[`setData(_:forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/setdata(_:fortype:))
接受调用方提供的 `Data` 和已声明的类型；Apple 并未说明 pasteboard server 会验证这些字节确实符合
类型名称。所有格式解码仍必须允许失败。对于对象读取，Apple 列出的
[`NSPasteboardReading`](https://developer.apple.com/documentation/appkit/nspasteboardreading)
实现包括字符串、 attributed string、URL、颜色、声音和图像；应优先使用对象级能力探测，而不是
仅凭 raw type string 推断。

还有一个不能被“支持类型表”掩盖的维度：`NSPasteboard` 可以包含多个 item。Apple 的
[`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard) 总览明确说明这一点；
`types` 是跨 item 的并集，而 pasteboard 级 `string(forType:)` 会拼接所有包含该类型的 item。
因此，忠实捕获必须以 `pasteboardItems` 为边界保存 item 与 representation 的分组，不能把并集当成
一个扁平对象。

## 3. 当前标准类型证据矩阵

表内“解码契约”只记录 Apple 明确承诺的入口。即使标为 **DOC**，初始化器返回 `nil` 或抛错仍是
正常输入结果，不可提升为强制成功。

| Swift 常量 | Apple 定义的含义 | 解码/访问契约 | Clipy 应采用的支持边界 | Apple 直链 |
|---|---|---|---|---|
| `.string` | **DOC**：字符串数据。 | **DOC**：可通过 item 的 `string(forType:)` 请求字符串；**UNKNOWN**：Apple 的类型页没有规定应由 Clipy 手工采用哪种字节编码。 | 原始表示可捕获、可回写；文本预览和搜索应走字符串 accessor，失败时保留 opaque data。不要把字符串形式的路径当作沙盒文件授权；Apple 在类型页明确警告这一点。 | [`.string`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/string) |
| `.tabularText` | **DOC**：由 tab 分隔的文本字段。 | **DOC**：它是文本语义；**UNKNOWN**：Apple 未规定 CSV 式 quoting、转义、行终止符或完整表格 grammar。 | 可做文本预览；表格预览只能是可失败的增强，不得改变原始表示，也不能假定 RFC 4180。 | [`.tabularText`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/tabulartext) |
| `.rtf` | **DOC**：RTF 数据。 | **DOC**：[`NSAttributedString.init(RTF:documentAttributes:)`](https://developer.apple.com/documentation/foundation/nsattributedstring/init(rtf:documentattributes:)) 解码 RTF，并在无法解码时返回 `nil`。 | 捕获/回写原始 RTF；富文本预览使用可失败的 attributed-string decoder，另行抽取纯文本用于搜索。 | [`.rtf`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/rtf) |
| `.rtfd` | **DOC**：RTFD 格式化文件内容。 | **DOC**：[`NSAttributedString.init(RTFD:documentAttributes:)`](https://developer.apple.com/documentation/foundation/nsattributedstring/init(rtfd:documentattributes:)) 会解码 RTFD command/data stream，并在失败时返回 `nil`；Apple 也提供基于 `FileWrapper` 的 RTFD decoder。 | 与 RTF 分开注册；附件使预览、大小预算和安全策略更复杂。预览失败不影响 opaque capture/paste。 | [`.rtfd`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/rtfd) |
| `.html` | **DOC**：HTML 内容。Apple 还说明 `NSTextView` 能读、不能写该表示。 | **DOC**：`NSAttributedString` 的 document type 包含 HTML；但 [`init(data:options:documentAttributes:)`](https://developer.apple.com/documentation/foundation/nsattributedstring/init(data:options:documentattributes:)) 说 HTML **should not** 在后台线程调用：它会尝试与主线程同步，并可能失败/超时；含外部资源引用的HTML在主线程也可能超时。该导入机制不是通用 HTML importer。 | 捕获/回写原始 bytes；HTML preview须独立、task-owned、有限时；`Task.cancel()`本身不保证停止或抑制发布，后者由loader token fence实现，native importer真实返回前继续计费。不能把它当浏览器或把type名当“安全HTML”。 | [`.html`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/html) |
| `.font` | **DOC**：字体和字符信息。 | **UNKNOWN**：该常量页没有公开稳定的字节 schema，也没有给出从单个 raw `Data` 解码成 `NSFont` 的标准入口。 | 可 opaque 捕获/回写；默认不承诺结构化 preview。若以后采用 AppKit text-system 行为，应由专用 decoder 模块和互操作 fixture 证明。 | [`.font`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/font) |
| `.ruler` | **DOC**：段落格式信息。 | **UNKNOWN**：该常量页没有公开稳定 payload schema 或独立 decoder。Apple 的标准 ruler pasteboard 用于 Copy/Paste Ruler 命令，但这不是字节格式说明。 | 可 opaque 捕获/回写；不进入普通内容预览。结构化支持必须独立验证，不能与 RTF/RTFD 合并猜测。 | [`.ruler`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/ruler), [standard ruler pasteboard](https://developer.apple.com/documentation/appkit/nspasteboard/name-swift.struct/ruler) |
| `.color` | **DOC**：颜色数据。 | **DOC**：[`NSColor.init(from:)`](https://developer.apple.com/documentation/appkit/nscolor/init(from:)) 从 pasteboard 读取颜色；`NSColor` 也实现 `NSPasteboardReading/Writing`。**UNKNOWN**：类型页不把 raw archive/schema 定为 Clipy 可自行复刻的公开协议。 | 颜色 preview 走 AppKit 对象级 decoder；持久层只保存不可变 bytes/中性 DTO，不让 `NSColor` 跨模块或 actor。 | [`.color`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/color), [`NSColor`](https://developer.apple.com/documentation/appkit/nscolor) |
| `.sound` | **DOC**：声音数据。 | **DOC**：[`NSSound.init(pasteboard:)`](https://developer.apple.com/documentation/appkit/nssound/init(pasteboard:)) 要求正确的 magic number、sound header 及受支持格式的数据；`NSSound` 支持的底层音频格式不等于一种固定 `.sound` 字节 codec。 | 音频信息/波形/播放 preview 独立于 capture；先做 capability probe，再解码，失败时只保留 opaque representation。 | [`.sound`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/sound), [`NSSound`](https://developer.apple.com/documentation/appkit/nssound) |
| `.multipleTextSelection` | **DOC**：多重文本选择。 | **UNKNOWN**：Apple 的常量页没有公开元素结构、range 语义、字符编码或标准 decoder。 | 可 opaque 捕获/回写；不能当作 `[String]`、property list 或 archived ranges 猜解。若同一 item 另有 `.string`/RTF，预览采用那些明确表示。 | [`.multipleTextSelection`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/multipletextselection) |
| `.findPanelSearchOptions` | **DOC**：Find panel metadata property list；Apple 明确要求配合 `propertyList(forType:)`。标准键包括 case-insensitive Boolean 与 substring-match number；第三方可增加键。 | **DOC**：property-list 容器和两个标准键；**UNKNOWN**：这是开放字典，不存在穷尽 schema。 | 作为 Find pasteboard 元数据而非普通用户内容；若保存则保留未知键，不要用 closed enum 解码整个字典。默认无需内容 preview。 | [`.findPanelSearchOptions`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/findpanelsearchoptions), [Find Panel Search Metadata](https://developer.apple.com/documentation/appkit/find-panel-search-metadata) |
| `.textFinderOptions` | **DOC**：Find panel metadata property list。标准键是 case-insensitive Boolean 和 matching-type number。 | **DOC**：Apple 的 [Text Finder Options For The Pasteboard](https://developer.apple.com/documentation/appkit/text-finder-options-for-the-pasteboard) 给出两项键；**UNKNOWN**：未声明一个可穷尽的完整 schema。 | 与 `.findPanelSearchOptions` 分成两个 descriptor，避免因相似名称误当成同一 wire format；通常分类为 metadata/no-preview。 | [`.textFinderOptions`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/textfinderoptions), [`TextFinderOptionKey`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/textfinderoptionkey) |
| `.URL` | **DOC**：一个文件或资源的 URL 数据。Apple 对现代 macOS 推荐用 `writeObjects(_:)` 写 URL。 | **DOC**：`NSURL` 是 `NSPasteboardReading/Writing` 实现，`readObjects(forClasses:options:)` 可按对象能力读取；**UNKNOWN**：常量页未要求 Clipy 按某个固定 raw-byte serialization 自行解析。 | URL preview 使用对象级 decoder；一个 pasteboard 可有多个 item，所以不要因该常量的描述是单数就丢掉其余 item。 | [`.URL`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/url), [`NSPasteboardReading`](https://developer.apple.com/documentation/appkit/nspasteboardreading) |
| `.fileURL` | **DOC**：文件 URL。 | **DOC**：URL 对象读取可用 `NSPasteboard.ReadingOptionKey` 的 file-URLs-only 选项；**UNKNOWN**：类型出现不等于文件仍存在、可访问或授权已获得。 | 将“URL 字符串成功解码”“文件存在”“沙盒可读”作为三个不同结果；preview 不应在 capture 路径同步访问目标文件。 | [`.fileURL`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/fileurl), [pasteboard reading options](https://developer.apple.com/documentation/appkit/nspasteboard/readingoptionkey) |
| `.fileContents` | **DOC**：文件内容的一种表示；Apple 说明 macOS 10.6+ 应以文件 UTI 表示其内容。 | **UNKNOWN**：常量本身没有指定是哪种文件格式、文件名、扩展名或统一 decoder；单独的 `.fileContents` 不足以构造可靠 preview。 | 先做 opaque capture/paste；优先识别同 item 的具体 UTI，只有可验证的内容类型足够时才交给对应 decoder。 | [`.fileContents`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/filecontents) |
| `.pdf` | **DOC**：PDF 数据。 | **DOC**：[`PDFDocument.init(data:)`](https://developer.apple.com/documentation/pdfkit/pdfdocument/init(data:)) 要求 PDF 数据，否则返回 `nil`；[`NSImage.init(data:)`](https://developer.apple.com/documentation/appkit/nsimage/init(data:)) 也明确支持 PDF 等 macOS 图像格式。 | PDF 文档 preview 与通用图像 thumbnail 分开：PDFKit 负责页/文档语义，图像 decoder 可只做封面缩略图；两者都允许失败。 | [`.pdf`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/pdf) |
| `.tiff` | **DOC**：TIFF 数据。 | **DOC**：`NSImage.init(data:)` 接受 macOS 支持的 bitmap 格式；[`NSBitmapImageRep.init(data:)`](https://developer.apple.com/documentation/appkit/nsbitmapimagerep/init(data:)) 对 TIFF 从首个 header/image data 初始化并可能返回 `nil`。 | 使用图像 decoder；preview 产物与原始 TIFF 分离。不要用类型名称跳过像素尺寸、内存和解码失败检查。 | [`.tiff`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/tiff) |
| `.png` | **DOC**：PNG 图像数据。 | **DOC**：Apple 的通用 `NSImage`/`NSImageRep` 数据解码入口可失败；`NSImage.canInit(with:)` 检查当前注册的 image representation 是否能处理 pasteboard。 | 使用图像 decoder，并以 capability probe/实际初始化结果为准；raw identifier 命中不应直接产生“已支持 preview”。 | [`.png`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/png), [`NSImageRep.init(pasteboard:)`](https://developer.apple.com/documentation/appkit/nsimagerep/init(pasteboard:)) |
| `.collaborationMetadata` | **DOC**：协作期间传递数据的对象。 | **DOC**：`NSPasteboardItem.collaborationMetadata`提供typed `SWCollaborationMetadata?` accessor；该存在不等于Apple公开了可由Clipy自行复刻的raw byte schema。 | Adapter可在明确ShareWithYou产品slice中用typed accessor投影中性metadata；当前仍opaque capture/paste、no-preview，framework object不跨module/actor。 | [`.collaborationMetadata`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype/collaborationmetadata), [`NSPasteboardItem.collaborationMetadata`](https://developer.apple.com/documentation/appkit/nspasteboarditem/collaborationmetadata) |

## 4. 废弃标准类型仍可能在历史数据或旧应用中出现

Apple 当前总索引把 `.filePromise`、`.inkText`、`.postScript`、`.vCard`，以及若干由扩展名创建/
反推 pasteboard type 的 API 列在 **Deprecated** 区。Objective-C 索引还列出历史类型，如
`NSFilenamesPboardType`、`NSPICTPboardType` 等。证据见
[`NSPasteboardType` Objective-C 索引](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype?language=objc)。

对 Clipy 的含义不是“遇到就丢弃”，而是：

- **DOC**：这些符号已废弃，不应成为新写入路径的首选类型。
- **UNKNOWN**：旧 producer 的具体 payload 与现代 decoder 兼容性不能由符号名保证。
- 默认策略应为保留 raw type/raw data 并可原样回写；仅在一个独立 legacy decoder 明确验证后提供 preview。

## 5. 对“支持类型”代码表的直接要求

不要定义单一的 `isSupported: Bool`。同一表示可能“可无损捕获和回写”，但“不可 preview”；也可能
Apple 有对象 decoder，但 Clipy 尚未实现资源预算或安全隔离。代码可审阅性来自stable facts +
owner-specific manifests + build/test inventory，而不是一个production descriptor同时决定所有行为。例如：

```swift
struct StableFormatFact: Sendable {
    let typeIdentifier: String
    let semanticFamily: StableFormatFamily
    let specialRole: SpecialFormatRole?
}

struct PreviewFormatRule: Sendable {
    let key: StableFormatKey
    let declaredRoute: PreviewRoute
    let evidenceProfile: PreviewEvidenceProfileID
}
```

AppKit-facing adapter manifest 应直接引用 `.string`、`.rtf` 等标准常量，不应复制 Apple 常量的 raw string；
只有未登记的外部 UTI 才以 `rawValue` 进入 opaque fallback。跨越 AppKit 模块后再把常量投影成
纯 Foundation 的 identifier。

实现边界应当是：

- `PasteboardAdapter` 只负责按 item 枚举 representation、兑现 delayed data、保存 raw identifier/bytes 与
  原样写回；对象级 capability probe 属于 preview/interpretation 模块，不让 transport 逐渐变成 decoder。
- 一个concrete package-only `ContentPreview`按自己的manifest处理text、rich text、HTML、image、PDF、color、
  audio、URL、metadata；private family handlers各有输入上限、task-owned cleanup、失败结果和中性
  `Sendable`输出，native parser是否及时停止另由平台证据限定。
- 存储与领域层保留 raw representations 和 item grouping，不依赖 AppKit 类型。
- 未登记的 UTI 走 `opaque` fallback，而不是被静默丢弃。登记表中的 `UNKNOWN` 也仍可具有
  `capture = .opaque` 和 `paste = .verbatim`。
- decoder 的成功结果不能回写成“这个 type 永远可解码”的静态事实；图像 handler、filter service、
  OS 能力和输入字节都会影响结果。Apple 的
  [`NSImage.canInit(with:)`](https://developer.apple.com/documentation/appkit/nsimage/caninit(with:))
  明确说明它依赖注册的 `NSImageRep` 类，正是这种运行时能力差异的例子。

这套拆分能让代码文件清楚回答三个不同问题：Apple 声明了什么、Clipy 能无损保存什么、Clipy 当前能
安全预览什么。三者不应被一个 type switch 混为一谈。

## 6. 多 item、对象读取与原始表示：三个不同的边界

### 6.1 多 item 是平台契约，不是罕见异常

- **DOC**：[`pasteboardItems`](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboarditems)
  返回 pasteboard 持有的全部 item；出错时才是 `nil`。
- **DOC**：pasteboard 级 [`types`](https://developer.apple.com/documentation/appkit/nspasteboard/types)
  只是所有 item 已声明类型的并集，不能恢复 type 属于哪个 item。
- **DOC**：pasteboard 级 [`string(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/string(fortype:))
  会把多个 item 的 string、RTF 或 RTFD 内容以换行组合。它是方便读取 API，不是忠实归档 API。
- **DOC**：[`readObjects(forClasses:options:)`](https://developer.apple.com/documentation/appkit/nspasteboard/readobjects(forclasses:options:))
  为每个 item 返回第一个可由调用方优先级列表解码的对象；把 `NSPasteboardItem` 放入 class 列表才可确保
  每个 item 至少对应一个返回对象。
- **INFERENCE**：对象读取适合 preview/capability probe；它会选择“最佳对象表示”，因此不能替代
  `item.types × item.data(forType:)` 的全表示捕获。

忠实模型至少需要如下层级：

```text
ClipboardSnapshot
└── items: [ClipboardItem]              // 保留 item 顺序
    └── representations: [Representation]
        ├── typeIdentifier: String
        └── bytes: Data                 // 已兑现后的不可变 bytes
```

同一个 UTI 出现在两个 item 中是合法平台形状。当前 History 的“全局 type identifier 唯一”只适用于
单 item Canonical Content，不能直接扩展到完整 clipboard snapshot。`multipleTextSelection` 又是
**某个 item 内的一种表示类型**，与 pasteboard 的多个 item 是两套正交机制，不能彼此替代。

### 6.2 写回多 item 必须构造新 item

- **DOC**：[`writeObjects(_:)`](https://developer.apple.com/documentation/appkit/nspasteboard/writeobjects(_:))
  接受多个 `NSPasteboardWriting` 对象，包括 `NSPasteboardItem`。
- **DOC**：`setData`、`setString`、`setPropertyList` 的 pasteboard 级便利方法只写第一个 item；
  [`setData(_:forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/setdata(_:fortype:))
  还会在 pasteboard ownership 已改变时返回 `false`。
- **DOC**：[`NSPasteboardItem`](https://developer.apple.com/documentation/appkit/nspasteboarditem)
  与一个 pasteboard 绑定；把已绑定的 item 再传给 `writeObjects` 会抛异常。owner 改变后 item 变 stale，
  方法返回空数组、`nil` 或 `false`。
- **INFERENCE**：历史回放应为每个持久化 item 建一个全新的 `NSPasteboardItem`，逐表示设置原始 bytes，
  最后一次 `writeObjects` 提交整个数组。保存或复用捕获时取得的 AppKit item 对象既违反生命周期，
  也违反 Clipy 的 Sendable 边界。
- **UNKNOWN**：Apple 没有把“逐字节读取全部 representation 后用 `setData` 回放”声明成所有第三方
  私有 UTI 的跨版本语义兼容保证。它是最强的通用 passthrough 候选，但仍须用真实 producer/consumer
  互操作矩阵证明“对目标应用等价”。

### 6.3 类型声明顺序不是 decoder 成功保证

Apple 说明 pasteboard 级 `types` 按声明顺序列出；`availableType(from:)` 和对象读取又包含调用方自己的
优先级。由此只能得到：

- **DOC**：类型列表具有可观察顺序，对象读取按 class 优先级挑选匹配。
- **UNKNOWN**：任意 consumer 是否依赖 producer 的 representation 声明顺序，Apple 没有给出统一保证。
- **建议**：保留 item 顺序；表示顺序可作为原始元数据保留，但 Canonical Content 的确定性排序与回放
  顺序应当在规格中明确分开，不能把“排序后字节相同”自动提升为“所有 consumer 行为相同”。

## 7. Delayed / promised data 不是另一种可持久化 payload

Apple 有两组容易混淆的“promise”：

1. **普通 representation 延迟供数**：
   [`NSPasteboardItem.setDataProvider(_:forTypes:)`](https://developer.apple.com/documentation/appkit/nspasteboarditem/setdataprovider(_:fortypes:))
   注册 `NSPasteboardItemDataProvider`，只有请求某个 type 时才让 provider 供数；
   [`WritingOptions.promised`](https://developer.apple.com/documentation/appkit/nspasteboard/writingoptions/promised)
   同样表示数据尚未立即写入。
2. **未来文件 promise**：[`NSFilePromiseProvider`](https://developer.apple.com/documentation/appkit/nsfilepromiseprovider)
   与 [`NSFilePromiseReceiver`](https://developer.apple.com/documentation/appkit/nsfilepromisereceiver) 面向未来在
   目标目录生成文件，Apple 的主要说明与示例是 drag and drop。它不是普通 `Data` provider 的别名。

普通 delayed data 的结论：

- **DOC**：provider 被请求后才提供指定 type；
  [`pasteboardFinishedWithDataProvider`](https://developer.apple.com/documentation/appkit/nspasteboarditemdataprovider/pasteboardfinishedwithdataprovider(_:))
  在所有 promise 已满足或 pasteboard ownership 改变后通知 provider。
- **DOC**：pasteboard 级 [`data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/data(fortype:))
  在 contents 已改变或 owner 响应太慢、IPC 超时时可返回 `nil`，其他通信错误会抛
  `NSPasteboardCommunicationException`。
- **DOC**：item 级 `data(forType:)` 页本身只写“返回该 type 的 Data”；`NSPasteboardItem` 总览明确给出
  stale 后返回 `nil`。因此，把 pasteboard 级页面的全部 `nil` 原因逐字归因到 item 级方法，是需要
  平台测试支持的 **INFERENCE**，不是该 symbol 页的完整明文契约。
- **INFERENCE**：Clipy 要跨越 source app 生命周期保存历史，就必须在捕获窗口内把普通 delayed
  representation 兑现成 bytes；保存 provider 或 `NSPasteboardItem` 引用无法形成持久历史。
- **UNKNOWN**：Apple 未提供 payload 大小预告、通用取消 API或调用方指定超时。同步请求可能阻塞，
  所以“读取全部声明类型”与 UI 响应性、内存上限之间需要明确产品策略。

捕获结果不应只有 `capture?`。至少要区分：无 item、完整兑现、部分兑现、所有表示均未兑现、读取异常、
访问被拒绝。当前 `PasteboardAdapter.captureOutcome` 在“所有表示都不可用”时返回 `nil`，而 observer 已消费
`changeCount`；这使 caller 无法区分空 pasteboard 与一次完全失败的 materialization，也没有可观察的重试
依据。这是 Clipy 自身的状态模型问题，不是 Apple 承诺自动重试。

文件 promise 的结论更严格：兑现 promise 会要求输出目录、异步文件 I/O、进度、取消和文件协调。
在没有单独产品语义前，应把它列为 `recognized-but-not-captured`，不能因为看到 promise UTI 就把元数据
bytes 当成未来文件内容。若以后支持，必须是独立模块与显式用户动作，不能藏在普通后台 clipboard poll。

## 8. Uniform Type Identifiers 只能分类，不能替 decoder 背书

- **DOC**：[`UTType.identifier`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/identifier)
  是类型的唯一字符串标识；不使用 `UTType` 的 API 会直接用该 String/CFString。
- **DOC**：[`UTType.init(_:)`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/init(_:))
  对系统不知道的 identifier 返回 `nil`。所以第三方 pasteboard UTI 未被当前系统登记，不等于 raw
  representation 无效或应被丢弃。
- **DOC**：[`conforms(to:)`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/conforms(to:))
  对直接/间接 conformance 或相等返回 `true`。例如 Apple 明确说明 PNG 是 `public.image` 子类型，而
  image 又是 `public.content` 与 `public.data` 子类型。
- **DOC**：系统可声明或动态生成 type；[`isDeclared`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/isdeclared)
  说明两者互斥。按未知文件扩展名创建 type 时，Apple 也说明可能得到 dynamic type。
- **INFERENCE**：conformance 可用于候选路由，如“可能是 image/text/audio”，但它只描述类型关系；
  不证明 bytes 匹配 label、不证明当前 decoder 支持、不证明输入在资源预算内，也不证明安全。
- **INFERENCE**：`dyn.*` 与未登记第三方 identifier 应首先保留 identity + opaque bytes；在没有 exact
  handler 与实际 probe 时，不进入结构化 decoder。

因此支持表需要两阶段决策：

```text
exact identifier rule ──→ 明确 codec / accessor / metadata policy
        │ no exact rule
        ▼
UTType conformance hint ─→ 只选候选 family ─→ 实际 decoder probe ─→ success/failure
        │ unknown type
        ▼
opaque capture + verbatim paste + no preview
```

图像是最清楚的例子。Apple 的
[`CGImageSourceCopyTypeIdentifiers`](https://developer.apple.com/documentation/imageio/cgimagesourcecopytypeidentifiers())
返回当前 Image I/O 支持的 source UTI 列表，`CGImageSourceCreateWithData`/thumbnail 创建仍可失败。静态
`public.image` conformance 不能替代这两个运行时事实。若 Clipy 要让“支持哪些图像”在代码中清晰可见，
可在 registry 中列出已验收 exact formats，同时在 macOS 26 测试中校验它们存在于 Image I/O capability
列表，并对每个格式用有效、畸形、伪装和超大维度 fixture 实际解码。

## 9. 当前 Clipy 对类型支持的真实状态

### 9.1 Capture/paste 已是 generic raw，但只覆盖第一个 item

当前 `PasteboardAdapter.captureOutcome`：

- 只取 `pasteboardItems?.first`；
- 枚举这个 item 的全部 declared type，并调用 item 级 `data(forType:)`；
- 丢弃空 bytes；
- 当前写回用 pasteboard 级 `setData`，因此构造的也是单一 item。

所以“增加支持类型”不应先把 adapter 改成白名单。对第一个 item 而言，它已经是 unknown-UTI opaque
passthrough。真正缺口是：完整 item grouping、完全失败结果、delayed provider 策略、空 payload 是否具有
语义的决策，以及对象/preview/search/edit 能力。Apple 的 `setData` 接受 `Data?`，公开文档没有声明
“零字节表示永远无效”；当前忽略空 bytes 是 Clipy 产品不变量，不是可归因给 Apple 的平台事实。

### 9.2 当前富文本、HTML 和抽象 text UTI 被错误当作 UTF-8

`ContentProjector`, `HistoryPreviewView`, `HistoryDetailsView` 与 `ReviseEditorView` 各自复制一组 textual
UTI，其中包含：

- `public.rtf`；
- `public.html`；
- `public.plain-text`（Apple 明确说 encoding unspecified）；
- `public.text`（Apple 明确说是包含 markup 的 base type）。

这些路径除 `public.utf16-plain-text` 外都直接用 UTF-8 解码。证据坐标：

- `Sources/HistoryStorage/ContentProjector.swift:248-279`；
- `Sources/PresentationUI/HistoryPreviewView.swift:39-87`；
- `Sources/PresentationUI/HistoryDetailsView.swift:658-703`；
- `Sources/PresentationUI/ReviseEditorView.swift:349-384`。

后果需要分级：

- **Confirmed behavior defect**：对能通过 UTF-8 初始化的 RTF/HTML payload，preview 与 durable title/search
  得到原始 markup，而不是解码后的可见文本；对其他 payload 则可能直接跳过。`public.text` 与
  `public.plain-text` 的统一 UTF-8 假设也超出 Apple 的 encoding 契约。
- **Confirmed constructible type/byte mismatch path**：Revise editor只要发现RTF/HTML bytes恰好能按UTF-8
  解码，就允许Replace，保存时把任意用户文字的`Data(text.utf8)`放回原type identifier而无serializer验证。
  输入普通非markup文字可确定构造下一次paste声明RTF/HTML但bytes不满足格式的互操作失败；若用户输入
  偶然本身是合法RTF/HTML则未必损坏，所以不能把所有Replace一概称为必然corruption。
- **Safe immediate direction**：Replace 只开放给 Clipy 拥有明确 encoder 的 exact representation，首先是
  UTF-8 plain text；`public.utf16-plain-text` 只有在保存时按 UTF-16 契约重新编码才可编辑。RTF/RTFD/HTML
  在有成对 parser + serializer 与互操作测试前只能 Keep/Hide。
- **Safe projection direction**：先移除 structured/abstract types 的 UTF-8 fallback，依赖同 item 常见的
  plain-text sibling；没有明确 decoder 时使用 type-based fallback title。富文本提取以后作为有预算的派生
  materialization 加入，不能为了标题让 history commit 隐式调用 HTML importer。

HTML 不是简单把解析放到后台 actor 就解决。Apple 对
[`NSAttributedString.init(data:options:documentAttributes:)`](https://developer.apple.com/documentation/foundation/nsattributedstring/init(data:options:documentattributes:))
明确要求 HTML document type 不要从后台线程调用；在主线程仍可能因外部资源引用而超时，且该机制并非
通用 HTML importer。这与 Clipy 的“主 actor 不做 rich-text parsing”约束形成真实设计冲突。解决方案必须
在规格中选择，例如默认只显示安全 source/plain sibling，或引入受控 HTML renderer；不能用一个 actor
包装后宣称风险消失。

### 9.3 支持集合目前散落并已出现概念漂移

文本/图像集合至少散落在 `ContentProjector`、`HistoryPreviewView`、`HistoryDetailsView`、
`ReviseEditorView`、`ThumbnailStore`、`HistoryAuthority+DetailAndThumbnail` 与 row 图标启发式中。
这正是用户所说“代码文件里清晰显示哪些支持”的反例：同一字符串同时被当作 capture、preview、search、
edit 与 thumbnail 能力，实际这些能力并不等价。

建议新增一个**深而窄的stable-facts模块**，但不要新增运行时插件框架或中央policy：

- `ClipboardFormats`只列exact identifiers、稳定语义family与special roles；capture/paste、projection、edit、
  Preview、Thumbnail与Presentation分别在owner manifest中声明route/evidence/resource identity；
- AppKit 标准类型在 AppKit-facing 层用 `.string/.rtf/...` 取 raw value，不手抄常量；非 AppKit 的具体格式
  使用 `UTType.png.identifier` 等系统常量；
- switch 对 preview route 保持 closed/exhaustive，新增格式会让未处理 route 在编译期暴露；
- unknown UTI 不注册 handler也仍然能 opaque 保存和回写；
- decoder implementation 与目录分开：目录不导入 SwiftUI、SwiftData、`CGImage`、`NSColor` 或 `NSSound`。

## 10. Preview 应是独立流水线，不是巨型 type switch

推荐的最小独立边界：

```text
raw History representations
        │
        ▼
PreviewContentLoader   // History read、exact reference、task与late-result fence
        │ one bounded candidate
        ▼
ContentPreview         // stable facts + Preview manifest/profile选择候选并产生artifact
        │
        ▼
family decoder         // plain/rich/html/image/pdf/color/audio/url/file-reference
        │ immutable Sendable artifact
        ▼
PresentationUI renderer
```

接口要深，不要为每种 UTI 新建 public protocol。共享输出只需要有限的中性 artifact，例如 capped plain
text、checked eager RGBA/BGRA pixel bytes + dimensions/rowBytes/pixel-format/color-space metadata、PDF page summary、color components、URL/file-reference facts、
audio metadata、unsupported/failure。`CGImage`、`NSColor`、`NSSound`、`PDFDocument` 与 `NSAttributedString`
留在各 decoder 内部；UI 不直接持有完整 source blob。

按当前仓库依赖纪律，一个可评审而不过度拆分的目标图是：

```text
PresentationUI ──→ HistoryCore
       └─────────→ ContentPreview ──→ ClipboardFormats
PasteboardAdapter ─────────────────→ ClipboardFormats
HistoryStorage ────────────────────→ ClipboardFormats
ClipyApp = composition only
```

- `ClipboardFormats` 是stable facts目录：输入exact key可得到identifier/family/special role；它不输出
  `FormatRoute/Capabilities`、不持有bytes，
  不导入 SwiftUI、AppKit 或 SwiftData。是否允许它导入 `UniformTypeIdentifiers` 需要同步更新架构文档和 import
  gate；若希望维持 Foundation-only，则把 UTType conformance resolver 做成 `PasteboardAdapter`/
  `ContentPreview` 的 platform overlay，目录只接收已经解析好的中性 facts。
- `ContentPreview` 是一个深模块，不是每种格式一个 target。它内部可分 family decoder，package 接口只暴露
  `PreviewRequest → PreviewArtifact`，并把 Apple framework objects 全部封装在内部。
- `HistoryStorage` 只消费目录中明确为 pure/deterministic 的 projection codec。需要 AppKit、PDFKit、HTML
  importer 或文件访问的 extraction 不进入 Authority commit interval。
- `PresentationUI` 只渲染 artifact 与 typed status；它不复制 UTI 集合，不决定编码，也不选择 source blob。

删除测试：如果移除 `ClipboardFormats` 后，三个调用者会再次出现各自的 identifier set/switch，则这个模块
有真实 leverage；如果它只是转发一个 `Set<String>`，没有把 capture/paste/preview/search/edit 能力分轴，
就不值得新增 target。

family 级注意事项：

- **plain text**：只有 exact encoding rule 才直接 `String(data:encoding:)`；`public.text` conformance 只做
  候选，不做 UTF-8 证明。
- **RTF/RTFD**：使用 attributed-string decoder；RTFD 附件单独设数量和 byte 上限。
- **HTML**：默认无网络、无脚本、有限时、有限输出；在这些条件无法被当前 Apple importer证明前，支持
  状态必须写成“opaque transport / no rich preview”，而不是半安全实现。
- **image**：Image I/O 实际 probe；检查 container、primary image、orientation、像素维度、帧数及 decoded
  byte 预算。type label 与 sniffed container 不一致时返回 typed mismatch。
- **PDF**：PDFKit 文档语义与 Image I/O 首屏 thumbnail 分开；加密、损坏、多页和文本提取分别失败。
- **color/sound/URL**：优先借助临时 private pasteboard 的对象级 decoder，或 Apple 明确的 object initializer；
  输出转成中性 DTO。
- **file URL**：URL 可解码、目标存在、目标可读是三种状态。后台 capture 不自动遍历目标文件。Quick Look
  需要真实 file URL，不能把它当作任意 raw clipboard bytes decoder。
- **font/ruler/multiple selection/fileContents/collaboration metadata**：默认 opaque/no-preview，直到 byte schema
  或对象级互操作得到证据。

## 11. TDD / characterization 流程

这些测试应先固定平台可观察事实，再改 History 模型；不要用 mock 证明 AppKit 行为。

### Card MEMO-PBTYPE-1：两 item 同 UTI 不被扁平化

- **Red**：在 private pasteboard 用两个全新的 `NSPasteboardItem` 写入 `.string`，bytes 分别为 A/B；断言捕获
  结果有两个 item、顺序 A/B、每个各自保留 `.string`。
- **Green**：只引入 nested snapshot DTO；暂不改 decoder。
- **Round-trip**：从捕获创建两个新 item 后 `writeObjects` 到第二块 private pasteboard；逐 item 验证 bytes。
- **Anti-test**：pasteboard 级 `string(forType:)` 得到的换行组合不能作为持久化期望值。

### Card MEMO-PBTYPE-2：同一个 item 的多表示与多个 item 不等价

- **Red**：Fixture A 是一个 item，含 `.string + .html`；Fixture B 是两个 item，各含一个 type。断言快照、
  fingerprint 与 replay shape 均不同。
- **Green**：Canonical normalization 只在 item 内做 type uniqueness；snapshot 层保留 item grouping。

### Card MEMO-PBTYPE-3：delayed provider 完整兑现与完全失败均可观察

- **Red**：真实 `NSPasteboardItemDataProvider` 宣布两个 private UTI，记录回调；一条供 bytes，一条故意不供。
  断言请求触发 provider，结果是 partial 且命名缺失 type。另一个 fixture 全不供，结果仍是 typed failure，
  不能退化成“pasteboard empty”。
- **Green**：捕获状态机表达 materializing/complete/partial/unavailable；observer 不因 `nil` 静默吞掉证据。
- **Characterization**：ownership 改变后原 item stale；测试不让 AppKit item/provider 进入持久 DTO。
- **真实 timeout**：另建 macOS helper process 做慢 provider。单进程 injected nil 只能证明 Clipy 分支，不能
  宣称已证明 pasteboard server IPC timeout。

### Card MEMO-PBTYPE-4：对象互操作不是 type-string 命中

- 用 `NSString`、`NSAttributedString`、`NSURL`、`NSColor`、`NSSound`、`NSImage` 的真实
  `NSPasteboardWriting` 写 private pasteboard；捕获原始 item/representation 后原样回放到第二块 pasteboard；
  再用 `readObjects` 读取对应 class。
- 比较语义：字符串、attributed runs/attachments、URL、标准色空间 components、sound duration/header、图像
  dimensions/orientation。不要比较对象 identity。
- 加入“declared `public.png` + 非图像 bytes”，断言 capture/paste 可 opaque 成功，而 image preview 明确
  `decodeFailed/typeMismatch`。

### Card MEMO-PBTYPE-5：文本 codec 矩阵先挡住当前 corruption

- UTF-8 plain text：可 preview/search/edit，Replace 后 bytes 仍是合法 UTF-8。
- UTF-16 native order：含 BOM、不含 BOM 的 arm64 fixture；只在 exact encoder 对称时允许 Replace。
- `public.plain-text` 非 UTF-8、`public.text`、RTF、RTFD、HTML：不得走 UTF-8 fallback。
- RTF/HTML：preview/search 断言是可见文本而非 markup；在 decoder 未实现前，期望明确的 unsupported 比错误
  文本更好。
- RTF/HTML Replace：先写失败测试，断言 UI 不提供 Replace；有 serializer 后再为该格式单独开放。

### Card MEMO-PBTYPE-6：HTML 外部资源与线程约束

- 带 `http://127.0.0.1:<port>/probe` 外部资源的 HTML fixture，断言默认 preview 不发网络请求；若选择 Apple
  HTML importer，测试其执行 actor/thread 契约与超时结果。
- 超长 DOM、深嵌套、data URL、malformed encoding、无 plain-text sibling 各有独立预算测试。
- 这组测试需要 hosted macOS target；纯 SwiftPM/Linux 测试只能验证 selector/policy，不能证明 importer。

### Card MEMO-PBTYPE-7：图像/PDF 以实际 decoder 证明

- CI 在 macOS 26 记录 `CGImageSourceCopyTypeIdentifiers`，确认 registry 声称支持的 exact image type 均存在；
  不要求把所有运行时类型自动升级为产品支持。
- 每个格式包含 valid、truncated、type-label mismatch、巨幅 dimensions、animated/multipage、orientation fixture；
  断言输出像素和 decoded memory 均在预算内。
- PDF 另测 invalid/encrypted/multipage/first-page/text-layer；PDF preview 与 image thumbnail 的 acceptance 不
  相互替代。

### Card MEMO-PBTYPE-8：URL / file URL 的引用语义

- `NSURL` 对象 round-trip 保留 URL；随后移动/删除目标文件，断言 URL bytes 仍可回放但 preview 报
  `missing`，而不是“历史损坏”。
- 沙盒文件授权必须在签名后的 hosted app 中验证；private pasteboard 单元测试不能证明真实 TCC/sandbox
  extension 生命周期。
- 普通 `.string` 中形似路径的内容永不自动升级为 file access。Apple 已明确提醒 sandbox app 不能由
  string pasteboard type 获得文件访问。

### Card MEMO-PBTYPE-9：macOS 26 pasteboard privacy

- **DOC**：[`NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)
  有 default/ask/alwaysAllow/alwaysDeny；General pasteboard 的 default 是 programmatic access 时询问，而
  user-originated 且 paste-related 的访问即使 deny 也允许。
- 对四个状态做 hosted integration/manual matrix；后台 polling 不应把 permission denial 伪装成 empty capture。
- Apple 的 detect pattern/metadata API只覆盖检测目的且针对 first item，不能作为完整 types/bytes capture
  的替代；它可以帮助权限 UX，但不会解决多 item fidelity。

## 12. 尚不能从 Apple 文档推出的结论

- 不能因 UTI conforms to `public.text` 就断言 UTF-8。
- 不能因 UTI conforms to `public.image` 就断言 Image I/O 当前可解码该 bytes。
- 不能因标准 type 常量存在就断言独立 raw byte schema 已公开。
- 不能把 `.multipleTextSelection` 猜成 `[String]`，也不能把它当作多个 pasteboard item。
- 不能把 `.fileURL` 的可解码性提升为文件仍存在或沙盒授权可持久化。
- 不能把 delayed provider 的声明当成 payload 已保存；跨 owner change 后 AppKit item 会 stale。
- 不能把 `readObjects` 的最佳对象结果当成已捕获全部 representations。
- 不能把 successful opaque replay 提升为所有目标 app 的语义互操作；真实 app 矩阵仍是验收证据。
- 不能把 HTML 放入后台 actor 就宣称符合 Apple 的 HTML importer 线程与外部资源限制。

## 13. 推荐的交付顺序

1. **先止损**：取消RTF/HTML/abstract text的naive UTF-8 semantic/edit；关闭Replace可构造的type/byte mismatch。
2. **建立stable facts + owner manifests + build/test inventory**：清除重复stable literals、显式保留owner差异；
   capability分轴，不做`isSupported`总开关或中央runtime policy。
3. **多 item tracer bullet**：先 String × 2 item 端到端，再扩展混合 representation；不要先改所有 codec。
4. **delayed provider 状态机**：完全失败可观察、可重试、受预算；file promise 仍保持独立、默认不支持。
5. **逐 family decoder**：plain → image → PDF → RTF/RTFD → URL/color/sound；HTML 在安全契约明确后再开。
6. **互操作矩阵**：Finder、TextEdit、Safari、Preview、Mail、Xcode/IDE、Office 类应用与 Clipy 自身逐项记录
   item 数、type 数、bytes hash、对象级语义和 preview 结果。失败是 per-capability，不得丢掉 opaque history。
