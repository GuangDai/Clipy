# 内容类型与 Preview：开放世界保真、代码可审计能力与独立深模块

日期：2026-08-22
性质：架构与 TDD 修改意见；不包含实现代码。
证据基线：Clipy `cda2ba0`、Maccy `818f03d`、Apple 官方资料。Apple 类型与
Preview 细节分别见
[`apple-pasteboard-type-system-memo.md`](apple-pasteboard-type-system-memo.md)、
[`apple-preview-source-memo.md`](apple-preview-source-memo.md) 和
[`apple-pasteboard-preview-security-memo.md`](apple-pasteboard-preview-security-memo.md)。

## 1. 决策结论

用户的两个目标都合理，但必须按两个正交问题实现：

1. **类型扩展不能变成 closed allowlist。** Clipy 当前对第一个 pasteboard item 已经能保存和
   回写任意非空、限额内的 `typeIdentifier + Data`。这条开放世界的 raw fallback 是正确资产，
   应扩展为多 item 保真，而不是被一个 `supportedTypes` 白名单替换。
2. **“支持”不是 Bool。** 对同一 UTI，raw capture、verbatim paste、title、search、preview、
   edit、privacy 和 multi-item 互操作可以分别成立或失败。源码应把这些维度显式分开。
3. **稳定格式事实可以集中，行为策略不能全塞进中央表。** 建议一个 Foundation-only、
   `package` 级 `ClipboardFormats` 保存 exact identifier、稳定 family fact 与 special role；
   `SearchProjectionManifest`、`PreviewFormatManifest`、`EditableFormats` 和
   pasteboard special rules 仍由各自 module 拥有。build/test-only inventory 将这些清单 join 成
   一张排序稳定、机器可读的 capability table。
4. **Preview 值得成为一个独立的 concrete 深模块。** 推荐一个 package-only
   `ContentPreview` target，集中 Preview manifest、source selection 与 Apple renderer；不再先拆
   `PreviewCore` protocol target、Apple adapter target或每格式 protocol。
5. **UI observable/render state 只保存有界的 immutable `Sendable` Preview artifact。** G8前
   `PreviewContentLoader` operation仍会短暂持有现有限额内的full details/Effective snapshot，必须计量并在
   cancel/close后释放；它不是preview-specific bounded input或resident proof。`CGImage`、`NSImage`、
   `NSAttributedString`、`PDFDocument`、`WKWebView`、`AVAsset`、Quick Look request 和
   security-scoped lease 全部留在 Apple implementation 内，不跨 module/actor seam。
6. **首期只承诺静态、无外部 I/O 的 Preview。** HTML、file URL、Quick Look、音视频和 RTFD
   attachment 都有额外资源面；不能因为系统框架“可能打开”就升级为后台自动 preview。
7. **不要新增第二个 History owner，也不要先扩大 `ClipboardHistory`。** 现有
   `PreviewContentLoader` 继续拥有 `details(for:)`、exact-reference、selection/panel task 与 late-result
   fence；它把一个 immutable Effective Content snapshot 交给 `ContentPreview`。只有 G8/read-path
   absolute SLO 被真实测量触发，或用户明确批准新规格后，才增加 byte-bounded、reference-tagged 的
   purpose-specific History preview read。

这里的核心不变量是：

> Unknown means raw-only, not rejected. Known means a route is declared, not that arbitrary bytes will decode.

## 2. “支持一种类型”必须拆成八个问题

| 维度 | 它回答什么 | 默认规则 | Unknown UTI |
|---|---|---|---|
| Raw capture | 能否冻结 identifier 与原始 bytes？ | 非空、限额内且未命中特殊排除规则即保存 | **保存** |
| Verbatim paste | 能否按原 item/representation shape 回写？ | 原 bytes，不转码；完整 staging 后写 | **回写** |
| Semantic title | 能否稳定生成人类可读标题？ | 只用 exact、确定性 decoder；否则 type fallback | 不解释 |
| Search | 能否提取确定、受限的可见文本？ | 只用 owner 已批准的 extractor | 不索引 bytes |
| Preview | 能否在预算与安全政策内生成 artifact？ | manifest × runtime capability × actual decode | `.unsupported` |
| Edit | 是否有成对 parser/serializer，能保持 type 契约？ | exact encoder 已证明才开放 Replace | 不可编辑 |
| Privacy/special role | 类型是否是 concealment、lineage、transient、promise metadata？ | 在读取普通 payload 前由 pasteboard owner 处理 | 不猜私密性 |
| Multi-item fidelity | item 次序与每 item 表示是否能原样保留？ | 这是 snapshot shape，不是 UTI 能力 | 同样保留 |

任何单一 `isSupported`、`supportedTypes` 或“UTI conforms to text/image 所以支持”的设计都会
丢失至少一条上述事实。特别需要禁止两类失败：

- 新格式不在 allowlist，于是 raw bytes 被丢掉；
- type identifier 命中表格，于是 UI 把 malformed bytes、运行时缺 decoder 或被资源 policy 拒绝的
  输入误报为“已支持”。

## 3. 当前实现：原始底座是开放的，语义与显示策略已经漂移

### 3.1 已成立的好底座及其边界

当前 [`PasteboardAdapter.captureOutcome`](../../../Sources/PasteboardAdapter/PasteboardAdapter.swift)
枚举**第一个** `NSPasteboardItem` 的全部声明类型，并读取其 bytes；它没有内容类型 allowlist。
[`IngestPreparationActor`](../../../Sources/HistoryStorage/IngestPreparation.swift) 校验 identifier、数量、
bytes、重复类型、私密 marker 与总量，同样不以“已知格式”决定是否保存。因此，对单 item 而言，
custom/reverse-DNS/dynamic UTI 已经可以作为 opaque representation 进入 History。

写回也逐项使用原 type identifier 与原 bytes。这个事实只支持“单 item raw passthrough”，不能升级成：

- generic multi-item round-trip；
- 目标应用一定能语义等价地读取每个私有 UTI；
- declared UTI 与 bytes 相符；
- title/search/preview/edit 已支持该格式。

Apple 明确区分 `NSPasteboardItem.types`、`data(forType:)`、对象级
`readObjects(forClasses:options:)` 与 decoder 实际成功。UTI 是 routing evidence，不是 payload truth。

### 3.2 first-item 不是平台契约

当前 adapter 明写“v1 freezes the first item”，实现也只取
`pasteboard.pasteboardItems?.first`。当前 `ClipboardCapture`、Canonical/Effective Content 与
`PastePayload` 都是单层 representations；Domain 又要求整个集合中 type identifier 唯一。把第二个
item 直接 merge 进当前数组，会令两个 item 中相同 UTI 变成非法 duplicate，并丢失 item boundary。

Apple 的 pasteboard 是：

```text
ClipboardSnapshot
└── ordered items
    └── ordered declared representations
        ├── type identifier
        └── materialized bytes / unavailable outcome
```

因此 multi-item 不是 adapter 的小补丁，而是一个需要批准的领域/DTO/schema 变化。规格至少先裁决：

- item order 是否参与 content equality 与 fingerprint；
- representation 声明顺序是 durable replay metadata，还是只保留确定性排序；
- 任意一个 item 有 concealment marker 时拒绝整次 snapshot，还是只拒绝该 item；
- lineage hint 如何随多个 item 写回；
- partial materialization 是整次失败还是允许 per-item partial；
- revision 是修改一个 item、一个 representation，还是完整 snapshot。

安全默认应优先考虑“任一 item 命中 concealment 即拒绝整次 snapshot”，避免通过保留 sibling item
泄漏同一次 copy；但这必须成为规格决定，不能由实现注释暗中决定。

### 3.3 至少十处维护型类型策略，已经出现真实漂移

下面不是“代码中出现过 UTI literal”的机械计数，而是生产路径中各自决定功能的维护点：

| # | 当前 owner | 决定的能力 | 位置 |
|---|---|---|---|
| 1 | `ContentProjector` | title/search textual eligibility 与 encoding | [`ContentProjector.swift`](../../../Sources/HistoryStorage/ContentProjector.swift) |
| 2 | `ContentProjector` | 无文本时 image/URL/file fallback title | 同上 |
| 3 | `HistoryAuthority` | 哪个 representation 可作为 thumbnail source | [`HistoryAuthority+DetailAndThumbnail.swift`](../../../Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift) |
| 4 | `ThumbnailStore` | row 是否值得发 thumbnail request | [`ThumbnailStore.swift`](../../../Sources/PresentationUI/ThumbnailStore.swift) |
| 5 | `PreviewContent` | Preview 的 textual candidates | [`HistoryPreviewView.swift`](../../../Sources/PresentationUI/HistoryPreviewView.swift) |
| 6 | `PreviewContent` | Preview 的 image candidates 与 image-first priority | 同上 |
| 7 | Details | per-representation text decode/preview | [`HistoryDetailsView.swift`](../../../Sources/PresentationUI/HistoryDetailsView.swift) |
| 8 | Details | image heuristic 与 fallback icon | 同上 |
| 9 | Revise editor | 哪些 representation 显示 Replace、如何 decode/encode | [`ReviseEditorView.swift`](../../../Sources/PresentationUI/ReviseEditorView.swift) |
| 10 | History row | 主类型 SF Symbol heuristic | [`HistoryRowView.swift`](../../../Sources/PresentationUI/HistoryRowView.swift) |
| 11 | Pasteboard + Storage | concealment/private marker 集合的两份镜像 | [`PasteboardMarkers.swift`](../../../Sources/PasteboardAdapter/PasteboardMarkers.swift)、[`IngestPreparation.swift`](../../../Sources/HistoryStorage/IngestPreparation.swift) |

已确认的漂移包括：

- HEIF 与 BMP 可以进入 storage thumbnail、row thumbnail 和 large Preview，但
  `HistoryRowView.typeSymbol` 没列 `public.heif` 与 `com.microsoft.bmp`，所以能出图的内容仍可能显示
  generic clipboard icon。
- `ContentProjector` 的 image fallback 还列抽象 `public.image`，decoder 则只认具体 exact UTI；
  “显示为 Image”与“实际能 decode”不是同一集合。
- UTF-16 在 `ContentProjector` 和 large Preview 有专门解码分支；Details 的短文本 eligibility 与
  Revise Replace 却先要求 UTF-8 成功，因此同一 representation 在不同 surface 上能力不同。
- 当前硬编码 `public.utf8-external-plain-text`；Apple 标准类型资料明确的是
  `public.utf16-external-plain-text`。前者若来自真实 producer，仍应作为 unknown raw UTI 保存，但不能
  被当成 Apple 已定义的 UTF-8 encoding contract。
- concealment set 在 adapter 与 storage 手工同步。这里有意做 defense in depth 是合理的，但事实源
  仍应共享稳定 identifier；两层应各自执行 rule，而不是各抄一份字符串。

这些差异不应通过“把所有集合换成同一个全局 Set”修复，因为 thumbnail、icon、search 与 edit 本来就
不是同一能力。正确修复是共享稳定 facts，各 owner 维护 purpose-specific manifest，并由 inventory
检测不一致是否是有意的、是否有证据。

### 3.4 RTF、HTML、抽象 text 与 UTF-16：要校准到具体契约

当前 `ContentProjector`、large Preview、Details 与 Revise editor 都把以下类型放入 textual 集合：

- `public.plain-text`；
- `public.utf8-plain-text`；
- `public.utf16-plain-text`；
- `public.text`；
- `public.rtf`；
- `public.html`。

除一个 UTF-16 exact identifier 外，多数路径直接使用 UTF-8。Apple 的含义却不同：

- `public.text` 是可包含 markup 的抽象 base type，不承诺 UTF-8；
- `public.plain-text` 明确是 encoding unspecified；
- RTF/RTFD/HTML 是文档格式，不是 plain UTF-8 text；
- HTML importer 可能触发外部资源行为与主线程同步，不能塞进 History commit 或用 actor 包装后宣称
  安全；
- `public.utf16-plain-text` 与 external UTF-16 的 byte-order/BOM 契约不同。

当前证据支持的准确表述是：

- raw RTF/HTML bytes **没有被 capture/paste 损坏**；opaque round-trip 仍成立；
- title/search/Preview 当前展示或索引的是可按 UTF-8 解出的 raw markup，不是 rich semantic text；
- 只有对应charset/codec已批准且产品明确标成“HTML Source”或“RTF Source”时，source view才可以是合法
  fallback；当前 generic text
  标签与 search contract 没有作这个区分，所以这是 contract gap；
- Revise editor 是更严重的 confirmed path：只要 RTF/HTML bytes 恰能按 UTF-8 读取，就开放 Replace，
  保存时却把任意用户文字写成`Data(text.utf8)`并保持原RTF/HTML UTI；当前没有serializer验证。用户输入
  普通非markup文字即可确定构造声明type与bytes不匹配的互操作失败，但某次输入偶然本身是合法RTF/HTML
  仍可能成立，因此不把每次Replace都概括成必然损坏。raw source display本身则是标签/语义contract gap。

最小止损顺序：

1. Edit manifest 首先只开放拥有 exact encoder 的 UTF-8 plain text；UTF-16 只有 parser/serializer
   round-trip fixture 通过后加入。
2. 从 durable semantic projection 中移除 RTF、HTML、`public.text` 与 encoding-unspecified
   `public.plain-text` 的 naïve UTF-8 路径；优先使用同 item 的 exact plain-text sibling，否则用稳定
   type fallback。
3. 若在charset/codec批准后仍提供 source Preview，UI 必须明确显示 `HTML Source` / `RTF Source`，并与 semantic preview、
   rich edit 区分。
4. RTF/RTFD visible-text extraction 作为独立、有预算的 derived interpretation；不要把 AppKit parsing
   引入 Authority commit interval。
5. HTML semantic search/rich preview 在零外部 I/O policy 与平台 proof 完成前保持 disabled。

改变 durable title/search extractor 会改变投影语义。后续 agent 必须同步裁决 projection schema version、
旧行重投影与 migration/rebuild 证据，不能只替换一个 set 后把新旧搜索结果混用。

### 3.5 Maccy 提供的教训，不是要复制的实现

Maccy 的 useful pattern 是把 raw RTF/HTML 与派生 visible text 分开；小于其内部限额的 rich text 经
`NSAttributedString` 转为 title/search text，原 bytes 仍用于 paste。证据见
[`HistoryItemEngine.swift`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Engine/HistoryItemEngine.swift) 与
[`HistoryItem.swift`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Models/HistoryItem.swift)。

但 Maccy 不能作为 multi-item 或类型目录的正确答案：

- [`PasteboardSource`](https://github.com/GuangDai/Maccy/blob/818f03d0e0d3912e1ea23657e2630902ebf5cc8b/Maccy/Ingest/PasteboardSource.swift) 读取全部 items，后续却把
  `(type, bytes)` flatten 到一个内容数组；普通重复 UTI 无法恢复 item boundary；
- first-class image 选择只有 TIFF/PNG/JPEG/HEIC，ImageIO 实际可 sniff 更多格式不等于产品已支持；
- `supportedTypes` 实际混合了用户过滤、known type 与 unknown sibling retention；名称比语义宽；
- Quick Look/PDF 没有可复制的完整 production renderer；
- fingerprint-only thumbnail cache 与不完整 eviction 不符合 Clipy 的 byte-confirmed identity 纪律。

应借鉴的是“raw authority 与 derived semantic facts 分离”、row-owned cancellation 与真实 fixture；
不应复制 flatten、全局 mutable settings、hash-only correctness key 或在 Model/UI accessor 中散布格式知识。

## 4. 收敛后的格式架构：共享 facts，owner-specific policy

### 4.1 `ClipboardFormats` 只拥有稳定事实

建议新增 Foundation-only、`package` 级 module。它不 import AppKit、UniformTypeIdentifiers、SwiftUI、
SwiftData、ImageIO、PDFKit 或 WebKit，也不持有 bytes、cache、runtime registry。

它可以拥有：

- known literal使用的轻量`FormatIdentifier` value；unknown lookup仍接受原始`String`，不成为第二个
  raw-input validation/admission owner；
- Clipy 已命名的 stable keys 与 exact identifier；
- Apple 文档明确的 encoding/family facts，例如 exact UTF-8、native UTF-16、RTF、PDF、PNG；
- special role identifier，例如 lineage hint、concealment/transient marker、file-promise metadata；
- evidence reference ID，而不是在运行时请求 URL；
- unknown identifier 的显式开放 fallback。

它**不能**拥有：

- `captureAllowed`、`isSearchable`、`isPreviewable`、`isEditable` 的总开关；
- Preview budget、UI icon、search priority 或 file access policy；
- 任意 decoder closure 或 Apple framework object；
- 运行时 plugin discovery；
- “conforms to public.text/image 所以 bytes 合法”的推断。

抽象形状可以类似：

```swift
package struct StableFormatFact: Sendable {
    package let key: StableFormatKey
    package let exactIdentifier: FormatIdentifier
    package let familyFact: FormatFamilyFact
    package let wireFact: WireFact
    package let specialRole: SpecialRole?
    package let evidenceID: EvidenceID
}
```

这里的 `familyFact` 只陈述格式是什么；它不决定产品拿它做什么。未出现在 known facts 中的合法 raw
identifier 不会构造失败，而是 `FormatIdentifier` + `.unknown` lookup result。

由于Foundation-only facts必须保存raw identifier，另加一个hosted parity test，把Apple-known literals与
相应`NSPasteboard.PasteboardType.rawValue` / `UTType.identifier`对齐；这不要求facts target import AppKit或
UniformTypeIdentifiers，也不允许runtime conformance registry决定raw capture。

### 4.2 每个行为 owner 有自己的 manifest

建议的源码布局使 reviewer 一眼能找到“谁决定什么”：

```text
Sources/ClipboardFormats/
  StableFormatFacts.swift            # exact identifiers + stable facts only
  SpecialFormatRoles.swift           # lineage/concealment/promise role identity

Sources/PasteboardAdapter/
  PasteboardSpecialRules.swift       # conceal before bytes, delayed data, write staging

Sources/HistoryStorage/
  SearchProjectionManifest.swift     # exact extractor + title/search priority + schema owner
  ThumbnailFormatManifest.swift      # row thumbnail source/route；仍由Storage拥有version fence

Sources/ContentPreview/
  PreviewFormatManifest.swift        # route + source priority + budget + fallback
  ContentPreview.swift               # immutable source -> typed bounded artifact
  PreviewTypes.swift                 # package-only Sendable request/outcome/artifact
  Renderers/                         # image/rich/PDF/HTML/media/file internal modules

Sources/PresentationUI/
  EditableFormats.swift              # exact parser/encoder pairs admitted to Replace
  FormatPresentation.swift           # icon/label/a11y mapping from capability/result

Tests/CapabilityInventoryTests/
  CapabilityInventoryTests.swift     # test/build-only join；验证漂移，不参与production决策
```

如果 edit codec 开始被 UI 以外调用，再把 `EditableFormats` 深化成独立 `ContentEditing` module；在只有
一个 caller 时先不造 protocol/target。

owner-specific manifest 的要点是：

- capture/paste 默认是 open-world raw，manifest 只声明**例外与特殊 staging**；
- Search 只声明纯、确定、可在当前 HistoryStorage 规则内运行的 extractor；
- v1 row thumbnail仍是HistoryStorage的独立purpose，拥有自己的manifest/source/version fence；它不因
  full Preview新增renderer而自动迁移owner；
- Preview 声明 Apple renderer route，但实际 enabled 状态还要与 runtime capability 求交；
- Edit 只声明成对、byte-level round-trip 已证明的 encoder；
- icon/a11y 基于 owner 返回的 semantic family/result，不再自己重新猜 UTI。

row thumbnail当前有两个真实决策点：PresentationUI先判断是否发request，HistoryStorage再选择source。
`DEC-THUMBNAIL-REQUEST-OWNER`必须在删除两边集合前二选一：A) 经spec/public-surface批准，让row DTO携带
neutral eligibility/family；B) UI只按visibility请求，Storage快速typed unsupported；C) 明确保留UI scheduling
manifest与Storage source manifest，并由inventory验证兼容。未裁决时不能声称“一个
`ThumbnailFormatManifest`已消除重复”，也不能把row thumbnail迁入`ContentPreview`。

### 4.3 build/test inventory 提供“一张表”，但不成为 policy god-object

一个 build/test-only joiner 按 `StableFormatKey` 合并 owner manifests，输出稳定排序的 capability
inventory。它应检查：

- known fact key 与 exact identifier 唯一；
- owner manifest 没有引用不存在的 stable key；
- 同一 owner 内 priority/route 不冲突；
- edit 必须有 decoder + encoder + round-trip proof ID；
- preview 必须有 renderer、budget、external-I/O policy 与 evidence status；
- search extractor 变化必须伴随 projection schema/migration disposition；
- special marker 在 Adapter 与 Storage 的 defense-in-depth consumer 都有覆盖；
- declared image routes 在 macOS CI 与 runtime ImageIO set 求交并记录 disabled reason；
- 对通过privacy/shape/size admission且provider成功返回bytes的unknown representation，fallback只尝试raw
  capture + verbatim paste，不做semantic interpretation；provider unavailable/changeCount变化或writer rejection
  仍可typed失败，不能称无条件保证。

inventory 是**观察和验证**，不是调用者都依赖的中央决策引擎。删除它后生产策略仍由 owner manifests
执行，但 codebase 会失去跨 owner 漂移检查和机器可读清单；这说明它的 leverage 是审计，而不是运行时
业务控制。

当前 joiner 严格保持 test/build-only。生产 capability projection 目前**没有合法 target owner**：Gateway
不能反向 import PresentationUI/ContentPreview，CLI 也不能为枚举 edit/icon 能力 import SwiftUI target。
因此先建立 `DEC-FORMAT-INVENTORY-OWNER` 决策卡；在 owning spec 冻结依赖图、surface 与注入生命周期前，
真实 Gateway/CLI export 为 `BLOCKED-SPEC`。候选是由 ClipyApp composition join 各 owner 输出的 immutable
Foundation summaries，再把 neutral snapshot 注入 restricted external facade；生产 policy 仍由各 owner
执行。Python成为第二个 edit caller前，还要把 `EditableFormats` 按 deletion test 提取为非UI
`ContentEditing` owner；若这不值得，首版 JSON 就省略 Edit，不复制一张清单。

获批后才可通过stdin JSON operation暴露：

```text
{"operation":"describeFormatCapabilities", ...} | clipyctl
```

输出至少包含：

- capability schema version、Clipy build、macOS build；
- exact identifier 与 stable display key；
- raw capture/paste fallback；
- search/preview/edit 的 declared route；
- runtime admission state：available / unavailable(reason) / not-applicable；这只表示declared route与当前
  framework交集，实际bytes decode/permission/locality仍是per-request outcome；
- evidence tier 与 resource profile ID；
- unknown fallback 的明确声明。

Python 可以用这份 JSON 判断“这台机器上 Clipy 当前会怎样处理一种表示”。它不是授权凭证，也不表示
Python 已获 content read/revise grant；更不能让 Python 绕过 gateway 直接打开 store。若未来 external
revision 开放，gateway 仍必须按 live grant、exact `ContentVersion` 与 `EditableFormats` 重新验证，不能
相信 Python 自报 capability。

不要在 JSON 中输出 clipboard 内容、用户路径、历史 UTI inventory、搜索 query 或私有文件位置。

各purpose的change identity必须分轴；只有已有durable consumer或未来cache/wire需要兼容时才持久版本化：

| Version | Owner | 何时变化 | 不自动影响什么 |
|---|---|---|---|
| `SearchProjectionRecipeVersion` | HistoryStorage | title/search bytes 或 priority 改变 | Preview、Edit recipe |
| Preview recipe identity | ContentPreview | renderer、source priority、sanitizer、artifact shape 改变 | `ContentProjector.schemaVersion` |
| Edit manifest identity | EditableFormats | parser/serializer/Replace admission 改变 | durable search projection |
| Pasteboard replay identity | PasteboardAdapter | item staging、special-type replay 语义改变 | Preview/search |
| capability JSON schema | inventory/CLI | JSON wire shape改变 | 任何产品能力 |

这些identity先可由build/manifest revision表达；只有出现跨启动artifact cache、durable consumer或稳定外部
wire后，才升级为独立持久schema version，避免为尚不存在的cache预建迁移体系。新增一种 Preview 或调整
图片 renderer **不得自动 bump** `ContentProjector.schemaVersion`；只有 durable
title/search投影发生变化才进入 projection migration。反过来，Preview recipe 变化需要失效其自己的
artifact/cache key（若未来 cache 经 gate 准入），不能借用 Content Version 或 search schema 假装覆盖。

## 5. Design It Twice：三种格式能力组织设计的比较

### 设计 A：一个全维度 `ContentCapabilityDescriptor`

每个 UTI 一行，包含 capture/paste/search/preview/edit/privacy/icon/budget/renderer 等所有字段。

优点：表面上最容易“一个文件看全”。缺点更关键：

- 为了 import-free 会把各 owner 的真实行为压成字符串 ID；
- 为了执行又会把 decoder closure、UI policy、storage projection 与 AppKit special case 拉到同一 module；
- unknown fallback、runtime ImageIO availability 与 durable projection schema 生命周期不同，却被假装成
  同一种静态事实；
- 修改 Preview 可能无意改变 capture/edit；中央表成为 god-object。

Depth 低：interface 很宽，每个 caller 仍需解释大量无关字段。Locality 差：几乎所有格式变更都触碰
中央文件。**拒绝。**

### 设计 B：纯 identifier constants + 每个 caller 自己写 Set

`ClipboardFormats` 只提供字符串常量，Storage、Preview、Editor、UI 各自维护 Set。

优点：依赖简单、owner 明确。缺点是它几乎就是当前结构：常量减少 typo，却无法回答“HEIF 可 Preview
为何 row 不显示 image icon”“RTF 可 raw paste 为何不能 edit”。没有 inventory 就无法发现语义漂移。

Depth 仍低：删除 constants module 后复杂度不会显著重新出现，只有 literal duplication 回来。
**不足以满足用户目标。**

### 设计 C：稳定 facts + owner manifests + inventory join

稳定格式事实集中；每个行为 module 只公开它真正拥有的 purpose-specific manifest；测试 join 后生成
代码可审计 capability table 和 JSON snapshot。Unknown fallback 不需要登记。

优点：

- Depth：每个 manifest 的 interface 很小，却隐藏该 purpose 的 priority、budget、fallback 与 evidence；
- Locality：加一种 Preview 格式主要修改 Preview manifest/renderer/tests；只有确实获得 semantic search
  或 edit 能力时才触碰对应 owner；
- Seam：稳定 facts 与 policy 分离，Apple runtime probe 只在 platform implementation；
- Leverage：inventory 能跨 module 发现非故意漂移，又不接管生产行为；
- 开放世界：unknown raw fallback 不依赖每次注册新 UTI。

代价：同一格式会在多张 purpose manifest 中出现引用，但这是不同产品承诺，不是坏重复；inventory 负责
证明引用一致且差异有意。**推荐设计 C。**

不推荐进一步做 runtime plugin/bundle registry。当前没有第三方 renderer adapter，也没有稳定 plugin
ABI、安全 sandbox 或签名策略；预建 protocol tree 只会放大 interface。新增格式应先作为 compiled,
closed renderer route。只有出现第二个真实部署方与独立更新需求后再评估 plugin seam。

## 6. Preview 深模块

### 6.1 seam 与依赖图

推荐目标：

```text
PresentationUI ──→ ContentPreview ──→ ClipboardFormats
       ├────────→ ClipboardFormats        └─→ ImageIO / PDFKit / AppKit /
       └────────→ HistoryCore                 AVFoundation / QuickLookThumbnailing /
                                              optional WebKit

HistoryStorage ──→ ClipboardFormats  # row thumbnail仍是独立owner
```

- `PreviewContentLoader` 仍在 PresentationUI：它是唯一 History caller，拥有 `details(for:)`、exact
  reference、selection/panel task、取消与 late-result fence；
- `ContentPreview` 是一个 concrete package-only module：只接收已经冻结的 immutable Effective Content
  values 与 bounds，负责 source selection、runtime admission、decode、sanitization 和 typed artifact；
- `ContentPreview` 不持有 `ClipboardHistory`，不读 History，不观察 selection，不拥有 panel lifecycle；
- tests 直接构造 concrete `ContentPreview` 跑真实 fixture。当前只有一个 production implementation，
  因此不先建 `Previewing` protocol或 `PreviewCore`/Apple adapter两层；
- ClipyApp 不拿 Apple renderer object，也不把 format switch 搬到 composition root。

新增 target、target dependency、Apple framework import 与 PresentationUI 规则都是规格变化。实现前应更新
`docs/01-architecture.md`、`Package.swift`、`.swiftlint.yml` 与 portable import gate；不能再像当前
`DisplayImageDecoder` 一样靠注释预告尚未批准的 ImageIO exception。

### 6.2 外部 interface 应小

PresentationUI 只需调用 concrete module 的一个行为入口：

```swift
package actor ContentPreview {
    package func render(
        _ request: ContentPreviewRequest
    ) async -> ContentPreviewOutcome
}
```

`ContentPreviewRequest` 只包含：

-一个 immutable Effective Content representation snapshot；
- intent（dwell preview / manual full preview；row thumbnail暂不归该module）；
- display pixels/scale 与 accessibility context；
-一个预定义 resource profile ID；
- 首期source policy只有closed `historyBytesOnly`。app-owned temp或explicit user-approved external file是future
  spec新增case，必须携带不可伪造的user-action/lease语义，不能由caller自行构造或翻布尔开关。

它不让 caller 选择 renderer、不接受 arbitrary file path、不传 framework object，也不暴露内部 cache key。
`PreviewContentLoader` 在每个 await 后继续检查 task cancellation、requested reference 与 details reference；
exact reference只被调用task捕获并在loader发布前复核，不进入renderer input/output；`ContentPreview`
检查取消但不成为第二个 lifecycle owner。若底层同步 decoder
不响应取消，loader 丢弃结果；不能在注释中声称 native work 已停止。

`actor`只解决state isolation，不自动给调度或取消。若一个同步ImageIO/RTF调用占住唯一actor，新的B请求
仍可能等待旧A完成；每个intent必须给出active-job、queued-source-bytes与deadline profile，并明确是串行
SLO还是允许尚未进入native work的请求被新foreground request抢占。测试要观察B何时开始/完成，不能只看
A最终没有late publish。

`PreviewOutcome` 至少区分：

- ready artifact；
- unsupported type；
- runtime decoder unavailable；
- malformed/type-mismatch representation；
- resource budget exceeded；
- external I/O denied / requires explicit action；
- protected/encrypted content；
- cancelled/superseded；
- retryable platform failure。

当前 UI 把 History failure、unsupported 与很多 preview error 折叠成 `No Preview`。深 module 之后，UI
可以给出准确且不泄露底层错误的 copy，例如“Unsupported format”“Preview too large”“Load Preview”或
“Preview failed — Retry”。

### 6.3 artifact 只使用 bounded `Sendable` primitives

可接受的 output family：

```text
PreviewText
  capped String + inert attributed runs + link metadata

PreviewRaster
  bounded eager RGBA8/BGRA8 pixel Data + width/height/rowBytes/color-space tag

PreviewDocumentSummary
  page count state + static page rasters + locked/encrypted facts

PreviewMediaSummary
  duration/dimensions/codec state + optional bounded poster frame

PreviewFileSummary
  display name/type/size/local-availability + explicit-action requirement
```

`NSAttributedString` 要先净化为有限 attribute enum；links 默认 inert。CGImage 禁令下首选 eager、
有界、inert 的 pixel DTO：pixel count、row bytes 与 Data 长度互相验证，UI 只从已验证 primitive 构造
本地显示 object。若实测证明 encoded artifact 更合适，也必须经规格批准并有独立 decode budget；
**bounded PNG/JPEG bytes 只限制编码体积，不等于 eager decoded，更不证明 UI decode 的 peak RSS/CPU。**
`PDFDocument`、`PDFPage`、`NSImage`、`CGImage`、`AVAsset`、`WKWebView` 和 file-access lease 不能进入
artifact。

当前 `DisplayImageDecoder` actor 返回 `CGImage?` 给 MainActor。即使 SDK 给 `CGImage` 并发标注，这仍与
仓库“CGImage 不跨 actor”规则冲突。修改方向是中性 bounded raster artifact，或正式批准一个极窄、
路径限定的例外；不能继续由源文件注释自行改规。

### 6.4 implementation 内部 owner

这些是同一 target 内的逻辑 module，不建议每个都建 target/protocol。首期planner还必须冻结唯一的
candidate/fallback contract：exact plain-text sibling优先于structured source；image candidates按manifest
priority；声明格式与sniffed格式按route-specific compatibility predicate判断；malformed primary是否尝试
sibling必须逐route明确，不能由dictionary order或“尽量成功”暗定。

| 内部 module | 隐藏的复杂性 | 默认外部 I/O |
|---|---|---|
| `PreviewPlanner` | representation priority、manifest/runtime intersection、fallback、budget admission | 无 |
| `ContentPreview` | immutable source admission、renderer dispatch、取消检查、typed failure、artifact validation | 无 |
| `PlainTextRenderer` | exact encoding、Unicode/line/character/output cap | 无 |
| `RichTextRenderer` | RTF/RTFD parse、attribute sanitization、attachment count/bytes/placeholders | 无 |
| `ImageRenderer` | ImageIO sniff/status/type/count/primary/orientation/downsample/eager raster materialization | 无 |
| `PDFStaticRenderer` | Data-only document、locked state、limited page raster、actions inert | 无 |
| `HTMLStaticRenderer` | 首期优先plain-text sibling；否则仅type/byte metadata。只有明确charset/codec后才显示带encoding标签的source；有限static grammar需另立规格 | **禁止** |
| `MediaRenderer` | app-owned temp、AV runtime probe、external-reference forbid、poster/cancel/no autoplay | **禁止** |
| `FileAccessLease` | local/cloud/network metadata、security scope、coordination、app-owned snapshot | 仅显式用户动作 |
| `QuickLookFileRenderer` | app-owned local temp、request cancellation、upgrade callbacks、cleanup | 仅显式用户动作 |

删除 `ContentPreview` 后，source priority、runtime probe、resource admission、decoder dispatch、error mapping
与 artifact validation 会重新散到 view/Storage/每个 renderer，所以它有真实 Depth。History read、selection
与 exact-reference生命周期仍留在 `PreviewContentLoader`，避免两个 module都声称拥有同一任务。删除某个
family renderer 后只失去该格式知识；它们应是内部 module，而不是十个 public protocols。

### 6.5 不先增加新的 History read

当前 `details(for:)` 是唯一 general UI content read，会返回完整 Canonical、Effective 与 revision summaries。
Preview 目前为一个 selected item 调它，再选择 Effective representation。这有明确的 bounded-but-large
read-path RSS 风险，但 G8 已拥有证据门槛。

建议先做：

1. `PreviewContentLoader` 保留唯一 `details(for:)` 调用，验证 exact reference 后把 immutable Effective
   Content交给 `ContentPreview`；
2. 一个 exact request 只在局部 scope保留 details/source；取消/关闭后立即停止发布，但不可抢占native work
   实际返回前仍计入permit/RSS，只有真实终止或helper被批准地kill后才释放；
3. 量测 representative concurrent retained DTO、transient hydrate RSS 与 copy p95；
4. 若 G8/absolute SLO 未触发，不扩大 `ClipboardHistory` public symbol；
5. 只有触发后，才由 ADR 冻结：metadata/descriptor → concrete behavior owner/renderer产生 access plan →
   loader 调用 Foundation-only HistoryCore purpose-read → Authority 验证 exact reference/budget并返回
   bounded immutable input。internal depot lease不跨 target；Authority不替 renderer选择format source，
   renderer也不直接读 History。

“为了架构更漂亮”不是扩大 public History seam 的理由。

## 7. 首期格式 tiers

这里的“首期”是实现顺序，不是一次性承诺全部完成。Raw tier 永远独立于 semantic/preview tier。下表是
实现优先级的简表，不是§2八维canonical inventory；正式inventory还要把raw capture/raw paste、thumbnail、
privacy/special role与multi-item applicability分轴。Delayed/provider/access health属于Pasteboard runtime，
不伪装成UTI能力。

| 格式/shape | Raw capture/paste | Search/title | Preview 首期 | Edit | Availability 性质 |
|---|---|---|---|---|---|
| unknown/custom/dynamic UTI | opaque/verbatim attempt | none/type fallback | unsupported + type/bytes metadata | no | eligible under limits；provider unavailable、snapshot change或write refusal仍可失败 |
| exact UTF-8 plain text | yes | exact UTF-8 | capped native text | UTF-8 round-trip | declared route；actual bytes may fail |
| exact native/external UTF-16 | yes | exact byte-order decoder | capped native text | parser+serializer proof 后 | declared route；actual bytes may fail |
| `public.plain-text` / `public.text` | yes | no encoding guess | source/type fallback，或 object accessor proof | no | abstract/unspecified |
| RTF | yes | plain sibling first；derived extractor later | inert sanitized rich text after resource proof | no，直到 serializer proof | Apple decoder route，input conditional |
| RTFD | yes | sibling/marker | attachments-bounded after separate proof | no | higher-risk conditional |
| HTML | yes | exact plain sibling first；否则type fallback | 首期plain sibling或type/byte metadata；source需明确charset/codec，static grammar另立规格 | no | rich mode disabled pending zero-I/O proof |
| PNG/JPEG/TIFF | yes | Image fallback title | static ImageIO thumbnail/preview | no | product declared ∩ runtime ImageIO ∩ decode success |
| HEIC/HEIF/GIF/BMP | yes | Image fallback title | fixture/format-policy 通过后逐项启用 | no | runtime-conditional；GIF/TIFF frame policy explicit |
| PDF bytes | yes | sibling/type fallback；text extraction另立规格 | static limited first-page raster | no | PDFKit route，input/resource conditional |
| web URL | yes | inert URL text if object decode succeeds | text/card only；不 fetch | exact serializer proof后另议 | object-decode conditional |
| 单 file URL representation | yes | lexical path/name facts only | metadata only；读取 target需用户动作 | no | 当前first-item raw path可保留；existence/access/locality分开 |
| Finder多文件group | 当前不保真 | none | unsupported | no | 需要multi-item shape，不等于新增file UTI |
| color | yes | type fallback | object decoder → neutral color components | no | object-decode conditional |
| audio/video bytes | yes | type/metadata only | no autoplay；poster/metadata later | no | manifest ∩ AV runtime ∩ Clipy保守`isPlayable == true` admission；Apple false仍可尝试但体验可能差 |
| file promise | descriptor/伴随表示；不被动兑现 | none | explicit import task only | no | not ordinary clipboard Data |
| font/ruler/multiple-selection/collaboration metadata | yes | none | opaque/no preview | no | schema unknown |

Inventory还应显式列出“known opaque/no-preview”而不是让它们消失：tabular text、file contents、
WebArchive、find/text-finder options，以及仍会在真实producer出现的legacy PostScript、vCard、ink/ruler等。
Delayed/promised materialization和macOS 26 pasteboard access health是capture-runtime轴，不是format
descriptor字段；它们在Pasteboard owner中单独展示和测试。

即使 raw route 不依赖 semantic decoder，也只能承诺对完整、稳定、admitted snapshot 做 verbatim attempt；
不能把 provider unavailable、owner change、limit rejection 或 paste write failure改写成“任意输入保证成功”。
图片实际 enable 集合是：

```text
product-declared exact image formats
∩ CGImageSourceCopyTypeIdentifiers() on this OS
∩ actual source sniff/decode success for these bytes
```

runtime set 只能决定这台机器能尝试什么，不能自动把 Apple 新增的所有格式提升为 Clipy 产品承诺。
每个 exact 新格式仍需 fixture、resource envelope、error mapping 与 UI/a11y proof。

## 8. No-external-I/O Preview 原则

默认 hover、dwell、list thumbnail 与 selected preview 必须满足：

- 不发 DNS/TCP/HTTP(S)；
- 不读取 clipboard 中 file URL 指向的正文；
- 不触发 iCloud/File Provider/网络卷下载；
- 不兑现 file promise；
- 不自动打开 link、PDF action、popup、download 或外部 application；
- 不自动播放声音/视频；
- 不写 persistent WebKit website data；
- 临时文件仅由 app-owned bytes 生成，随机命名、权限受限、所有 success/failure/cancel/late-callback 路径
  cleanup。

分格式边界：

- **ImageIO**：从 stored `Data` 解码；type label 与 sniffed type 应按该route批准的compatibility predicate
  判定，失败属于media outcome，不是store corruption。不能对HEIC/HEIF/alias机械做exact-string compare。
  `ThumbnailMaxPixelSize` 只证明 output extent，不证明 peak RSS/CPU。
- **RTF/RTFD**：links inert；attachment 有 count/bytes/type policy；unknown attachment 用 marker，不能
  构造自定义交互 view。
- **HTML**：`baseURL=nil` 与关闭 JavaScript 都不足以证明零外部资源。首期优先plain-text sibling，
  否则只显示type/byte metadata；只有明确charset/codec或有限static grammar另行准入后才显示source。
  WebKit fidelity adapter只有在network/file canary全绿后才准入。
- **PDF**：从 Data 构造，默认只出静态页 raster；不嵌交互 `PDFView`，不执行 URL/remote-go-to/form/
  print action。
- **AVFoundation**：仅 app-owned temp；`.forbidAll` 外部引用；先 metadata/poster，Play 是明确用户动作。
- **Quick Look**：它的 request 需要 file URL，且没有通用系统支持类型枚举。只作为尝试型 file adapter，
  不能成为 capability manifest 的 truth source。
- **外部 file URL**：URL 成功 decode、文件存在、已在本地、可读、具有持续授权是五个不同状态。

Apple 没有为这些 parser 提供统一的 CPU、RSS、deadline 或 crash bound。`Task.cancel()`本身不保证旧结果
不发布；该保证来自`PreviewContentLoader`的token/exact-reference fence。不可抢占native work真实返回前继续
计费。adversarial child-process 测量若显示 crash/RSS 超 envelope，才把相应高风险 renderer
迁到最小权限 XPC/Enhanced Security helper；不要无证据地把所有 renderer 都进程化，也不要无证据地
全部留在 app 进程。

## 9. Preview 生命周期、错误与 accessibility

格式扩展不能只验证“屏幕出现了一张图”。每个 renderer 共享以下 contract：

- loader task以 exact `HistoryItemReference` 标识；reference不进入renderer，revision后的旧artifact永不覆盖
  新selection；
- panel close、selection change、manual preview change 会取消 owner task并失效 request token；
- native work晚停时也不得 late publish；所有 temp/lease 最终释放；
- active decoder count、queued bytes、decoded/output bytes 与并发有硬上限；
- unsupported、malformed、policy denied、budget exceeded、runtime unavailable、cancelled 和 retryable failure
  不互相冒充；
- failed Preview 不改变 History raw content，也不触发 store recovery；
- raster 有可访问 label（格式、尺寸、必要时页数），不能一律用 decorative image；
- rich-text link默认不可激活，但可访问文本仍完整；attachment placeholder 可被 VoiceOver读出；
- audio/video 不 autoplay，控制有名称、状态、时长与键盘操作；
- “Load Preview” 明示会访问外部文件/可能下载，Cancel 可达；
- 状态变化需要受测的 accessibility announcement，而不是只有视觉 spinner。

这也要求保留 panel/Preview 的 lifecycle owner。format renderer 不应各自监听 selection 或持有 SwiftUI
state；它们只完成一个 admitted request。

## 10. 每增加一种格式的 vertical TDD 流程

不要一次先写全格式测试再批量实现。每个格式沿同一条纵向 tracer，一格 Red → 最小 Green → review/
refactor 后再进入下一格。compile failure 不是 Red；mock 内部 decoder 调用次数也不是产品证据。

### Step 0：先批准 seam 与产品承诺

在代码前记录：

- exact identifier、Apple/producer evidence 与 format family；
- raw capture/paste 是否已有通用 fallback；
-这次只新增 search、preview、edit 中哪一个能力；
- renderer 的 source、external-I/O policy、input/output/resource profile；
- concrete `ContentPreview` package interface 与 target graph 是否已批准；
- 是否触碰 multi-item、projection schema、History public surface 或 target graph。

一次 issue 只提升一个 capability，不用“支持 PDF”同时暗含 capture、text extraction、interactive view、
Quick Look 与 edit。

### Step 1：Manifest schema gate（不是行为 Red）

- 在 owner manifest 加一条明确失败测试：rule ID 唯一，route/budget/fallback/evidence 填齐；
- inventory snapshot 应显示 declared capability；
- unknown fallback 测试必须仍为 raw-only，不因新增 rule 被 closed allowlist 拒绝；
- source gate 禁止 UI/Storage 重建新的维护型 UTI Set。

这里只验证结构与漂移，不能把“加 `.unsupported` 后通过”称为行为Green。第一张产品行为Red从真实
capture/render seam开始；不要先实现decoder。

### Step 2A-char：Adapter-only multi-item characterization（非 Red）

用真实 private `NSPasteboard` 和 `NSPasteboardItem`：

- valid、empty、declared-but-unavailable、custom sibling；
- 同一 item 多 representations；
- 两个 items 中相同 UTI；
- 记录当前first-item截断、item/type declaration order、provider与changeCount；type declaration order只有
  producer/consumer evidence证明依赖后才升格为durable contract。

### Step 2A-behavior：Adapter ordered snapshot/replay Red（先批准adapter seam）

- adapter freeze → nested snapshot DTO →第二块private board；
- 比较item order以及每item的`(type, bytes)`集合，不冻结type declaration order；
- freeze前后`changeCount`变化、mid-freeze owner replacement与declared-but-unavailable必须整批进入已批准
  incomplete/superseded outcome并清理staging，不能以部分snapshot冒充成功。

这一步只裁决Adapter snapshot/replay，不让当前first-item History接口阻止测试编译；不要丢掉第二item或
flatten以求Green。

### Step 2B：Multi-item spec/schema Red

只有item-order/equality/fingerprint、concealment、partial、revision、lineage与migration语义先批准后，才让
nested DTO经过真实in-memory`SwiftDataHistory`做capture→restart→paste。Schema、codec、Domain与Storage
分vertical slice推进；“只增加DTO+writeObjects”不可能让端到端History Red变Green。

### Step 3：Semantic projection Red（仅当本次承诺 search/title）

- expected text 来自固定、人工核验的 visible-text literal，不在测试里复刻 production parser；
- valid、wrong encoding、malformed、同 item plain sibling priority、budget truncation；
- RTF/HTML 断言 visible text 或明确 unsupported/source mode，不能默认把 markup 当语义文本；
- projection schema/migration test 证明旧行行为与新行一致，或明确 versioned difference。

Green 只实现一个 exact codec。不要用 `UTType.conforms(to: .text)` 批量开启。

### Step 4：Preview Red（真实 Apple framework）

- valid fixture 返回 bounded artifact；
- type label mismatch、truncated、malformed 返回 typed outcome；
- runtime capability 缺失时返回 `runtimeUnavailable`，raw content仍可 paste；
- source selection priority 与 fallback 由planner的mixed-representation pure fixtures固定：malformed image+
  valid exact plain sibling、RTF/HTML+plain sibling、多image candidate都必须有唯一预期；
- integration test 通过 `PreviewContentLoader → ContentPreview.render` production seam，不直接测 private
  renderer 方法。

测试使用真实 framework 与小 fixture，不 mock `CGImageSource`/`PDFDocument` 来证明平台行为。

### Step 5：Resource / cancellation admission

- oversized input、巨大 dimensions/page/frame/attachment count、metadata-heavy、high compression；
- child process 记录 wall time、peak RSS、CPU、exit/crash 与 output bytes；在fixture/build/machine和每intent
  数值profile（input/output/pixels/pages/frames/active jobs/queued bytes/deadline）批准前，这是
  characterization；批准后才是pass/fail Red；
-选择 A 后快速切 B、revision、panel close、helper crash/timeout；
-只有 B/current reference 可发布，所有 lease/temp 被清理；
-测试明确区分“结果取消”与“native work 在 deadline 内停止”。
- controllable renderer seam还要证明批准的调度语义：若B应抢在A结束前开始/完成就明确断言；若接受
  全局串行，则必须用已批准latency SLO约束，不能只测late-result fence。

若 envelope 不成立，保持 disabled 或进入 helper；不要只改注释。

### Step 6：No-external-I/O Red

对可能引用外部资源的格式加入 canary：

- HTTP(S)/DNS listener；
- file read watcher；
- iCloud/File Provider/network volume；
- HTML image/CSS/font/iframe/media/meta refresh/form；
- PDF URL/remote actions；
- AV external media reference；
- Quick Look/cloud file。

默认 Preview 必须零外部访问。需要访问的能力只有明确用户 action 后进入单独状态机。

### Step 7：Error / fallback / accessibility Red

- unsupported 与 malformed 呈现不同文案；retryable failure 有 Retry；
- raw bytes仍可 Copy；Preview failure 不污染 History；
- raster/document/media/file artifact 的 accessibility label 含必要语义；
- links inert、audio no autoplay、controls keyboard/VoiceOver 可达；
- loading/success/failure state change 有可观察 announcement；
- fallback icon 从 returned capability/family 得出，不重新按字符串猜类型。

### Step 8：Runtime inventory 与 Python export Red

- macOS CI 捕获 ImageIO/AV runtime capability 与 OS build；
- declared exact format 只有在 runtime intersection 命中时 runtimeAdmission=available；
-一次实际 decode 失败不能改写 global runtime capability；
- 在 `DEC-FORMAT-INVENTORY-OWNER` 尚未批准时，只测 pure projection/serializer golden fixture，不提交一份
  复制 manifest 的 CLI stub，也不把 hard-coded response 记作 Green；
- owner与Gateway/transport闭合后，才通过`clipyctl` stdin的`describeFormatCapabilities` request验证schema、
  排序、enum、unknown fallback与disabled reason，并用真实 Python child 的 stdlib `json` 解析；
- capability response 无 content、path、query、History ID 或 authorization secret。

### Step 9：真实 producer/consumer interop Red

至少记录：producer、macOS build、item count/order、每 item observed declared types、byte count/hash、lazy provider、
预期 title/search/preview 与 consumer 结果。优先矩阵：

- TextEdit UTF-8/UTF-16/RTF/RTFD；
- Safari HTML + plain、URL + title；
- Finder 两文件/目录/Unicode filename；
- Screenshot/Preview/Photos 的 PNG/JPEG/TIFF/HEIC/HEIF/orientation；
- animated GIF、multi-page TIFF；
- Preview PDF normal/multipage/encrypted/corrupt；
- custom-only、custom+plain、dynamic、concealment marker；
- real delayed provider 与 provider exit。

private pasteboard proof 不能替代 signed+sandboxed General Pasteboard privacy、Finder/TextEdit consumer、
iCloud/File Provider 或 WindowServer acceptance。

## 11. 首批具体 TDD cards

本节编号是设计 epic，不是执行 registry；每个子卡必须映射到 `04` 的一张 `PLAY-*` 行为 Red，不能把
整个 `FORMAT-*` 或 `PREVIEW-*` 标成一次完成。

### FORMAT-1A：Edit 先拒绝未经证明的 codec

**Red：**一个有效 RTF/HTML/encoding-unspecified fixture 不出现 Replace；exact UTF-8 round-trip仍可编辑。

**Green：**只收窄 `EditableFormats`，不同时改 Search/Preview/schema。

### FORMAT-1B：Search projection 与 schema disposition

**Red：**一次只选择一个 exact codec（先 UTF-8，UTF-16分别后续卡）；wrong encoding、malformed、plain
sibling priority与budget truncation得到literal outcome。RTF/HTML不默认把markup当semantic text。

**Green：**只实现该 codec，并明确 projection schema bump/rebuild/no-change disposition。

### FORMAT-1C：Preview/source labeling

**Red：**abstract text、RTF/HTML source与semantic preview有不同label/outcome；raw bytes保持可回放。

**Green：**只修 Presentation/Preview manifest，不触碰durable projection。

### FORMAT-1D：facts迁移与legacy-set ratchet

先snapshot当前重复policy位置，source gate只拒绝**新增**维护型set；随后每迁移一个owner就缩小legacy
allowlist。不要用一次全仓gate改造阻塞首个行为修复。

### FORMAT-2A：HEIF/BMP presentation family 不漂移

**Red：** capability inventory 对 HEIF/BMP 显示同一 stable family，row/details icon由 family artifact显示
photo；这不宣称 decoder available。

**Green：** 先迁移 image family facts与 presentation mapping，不新增格式 decoder。

**Refactor：** 删除 `HistoryRowView`/Details 本地 prefix list。

### FORMAT-2B：runtime Preview admission

**Red：**只为一个 exact image fixture验证 declared route ∩ runtime capability ∩ decode outcome；runtime缺失时
显示 image type + unavailable。HEIF、BMP、GIF/TIFF frame policy各自单独领取。

**Green：**只增加该 exact runtime route，不把 family mapping当decoder证明。

### FORMAT-3：Eligible Unknown UTI 只走 raw-only policy

**Red：** reverse-DNS、`dyn.*`、合法 undeclared 各一个，单独存在也能 capture/store/paste；search 不把
bytes 猜成 UTF-8；Preview `.unsupported`；inventory 输出 unknown fallback。

**Green：** 保持现有 generic raw path，只让各 semantic owner显式拒绝解释。

### PB-MULTI-1A：Adapter ordered snapshot/replay

**Adapter Red：**两个 `NSPasteboardItem` 都含 `.string`，另各带不同 custom UTI；经nested adapter DTO
与第二块private board后保留item order及每item的`(type, bytes)`集合。Type declaration order先只记录，
不升格为未裁决契约。另用mid-freeze `changeCount`变化证明整批superseded/cleanup。

**Adapter Green：**只加入adapter-owned ordered snapshot/item DTO与一次`writeObjects` staging；不进入
History，不实现Finder special case。

### PB-MULTI-1B：History schema/domain vertical slice

**Schema Red/Green：**Domain equality/fingerprint/revision/lineage/partial与migration语义经规格
批准后，才让nested DTO通过真实History capture→restart→paste。不能靠DTO+`writeObjects`声称端到端Green。

### PREVIEW-1：一个 production owner

**Red：**选 A 后快速选 B；A 是慢 image，B 是 text。通过 production
`PreviewContentLoader → ContentPreview.render` seam 观察只有 B artifact，active jobs/retained bytes回到
界限内，panel close后无 late publish。另由批准的调度contract决定：若B应抢占尚未进入native decode的A，
必须断言B在A结束前开始/完成；若接受全局串行，则用明确latency SLO而不只测最终publish。

**Green：** `PreviewContentLoader` 继续拥有唯一 task/token/exact-reference fence；`ContentPreview` 只解码
这一调用收到的 immutable source，renderer 不监听 selection。

**Refactor：** 删除 `PreviewContent.resolve`及view内重复decoder/format switch；保留
`PreviewContentLoader`作为唯一History/exact-reference/lifecycle owner，也保留HistoryStorage row thumbnail
的独立source/version fence。若未来复用renderer，另做owner变更slice。

### PREVIEW-2：malformed image 不是 persistence corruption

**Red：** `public.png` + random bytes 能 raw round-trip；Preview 返回
`.malformedRepresentation`；另一个`public.png`+合法JPEG fixture明确返回`.typeMismatch`；两者都不出现
store recovery或`.corruptStoredValue`。

**Green：** Image renderer 在 Apple seam 内验证 source status/type/count/dimensions。

### PREVIEW-RTF：RTF inert

**Red：** RTF bold/link/attachment fixture的artifact保留可见文本但link inert、attachment受限。

**Green：**只实现 RTF renderer；不顺带加 HTML。

### PREVIEW-HTML：HTML offline

**Red：** HTML HTTP/file/iframe/media fixture首期优先exact plain-text sibling，否则只显示type/byte metadata；
只有另行批准charset/codec或有限static grammar后才允许source/semantic artifact，所有network/file canary为零。

**Green：**保持 metadata/plain sibling route；不引入 `WKWebView`。

**Gate：** WebKit adapter只有同一黑盒 suite 通过后才可选；否则永久不进入默认路径。

### PREVIEW-PDF：PDF static bounded-full input

**Red：** bounded full-`Data` PDF fixture只生成静态页，actions不执行。Apple资料未证明first-page range read，
不能先把 partial I/O写成contract。

**Green：**只做 PDF static page。

### PREVIEW-FILE：file metadata first

**Red：**not-downloaded iCloud/File Provider与SMB hover只显示capture时已有的lexical URL/type/byte facts，
filesystem open/stat/coordinator与network canary均为零。明确“Inspect File”动作才可进入metadata lease；
`immediatelyAvailableMetadataOnly`只表示不主动下载正文，不等于zero-I/O/zero-network。再由独立“Load Preview”
动作进入content snapshot/temp状态。

### PREVIEW-AV：future explicit media

AV不autoplay、external refs拒绝、input/decoder budget与helper边界须单独spec/Red；不与PDF/file卡绑定。

### Design epic → canonical execution leaf

本节编号是设计/验收分解，不能直接领取；实际工作只从`04`映射：

| Design epic | Canonical execution leaf / family |
|---|---|
| `FORMAT-1A` | `PLAY-FORMAT-B/C`中的一个exact codec/edit行为 |
| `FORMAT-1B` | 对应`PLAY-FORMAT-B/C`的projection recipe/schema decision与独立migration card；不得借Preview卡顺带改变 |
| `FORMAT-1C` | `PLAY-FORMAT-C`或某一exact `PLAY-FORMAT-F` slice |
| `FORMAT-1D` | `PLAY-FORMAT-A` ratchet；compile/source gate不是行为Green |
| `FORMAT-2A/2B` | `PLAY-FORMAT-D`后，再按一个exact format领取`PLAY-FORMAT-F` |
| `FORMAT-3` | `PLAY-FORMAT-A1` unknown raw-only regression gate |
| `PB-MULTI-1A/1B` | `PLAY-FORMAT-E1/E2/E3A…E3D`；E1是characterization，E3 family受spec gate阻塞 |
| `PREVIEW-1` | `PLAY-PREVIEW-0/A1/A2/A3…A5`；seam gate本身不算renderer完成 |
| `PREVIEW-2` | `PLAY-FORMAT-D`的malformed/type-mismatch分类 + `PLAY-PREVIEW-A2` artifact |
| `PREVIEW-RTF/HTML/PDF/FILE/AV` | 每次在`PLAY-FORMAT-F`下mint一个exact-format leaf，并继承`PLAY-PREVIEW-B`的平台/资源层级 |
| Python capability export | `PLAY-PY-C1` pure projection；production injection=`PLAY-FORMAT-G` |

若表中写“mint leaf”，必须先在`04`增加唯一ID、单一observable behavior与gate，不能直接把family或本节epic
标成done。

## 12. 不要做的复杂化

- 不做单一 `supported: Bool`。
- 不做所有 owner 都查询的中央 `ContentPolicyManager`。
- 不让 raw capture/paste依赖 registered format allowlist。
- 不按每个 UTI 建一个 target、public protocol或runtime plugin。
- 不用 `UTType.conforms(to:)` 替代 exact encoding/decoder probe。
- 不让 PresentationUI、HistoryStorage、PasteboardAdapter各自继续复制维护型 Set。
- 不让 Preview renderer直接读 SwiftData、拥有 selection UI或打开外部 URL。
- 不让 SwiftUI observable/process-lifetime UI state 持有完整 source blob、framework
  document/player/web view；G8前loader operation可短暂持有并计量details snapshot，取消/close后停止发布，
  但native work/retained source直到真实返回前继续计费，
  但这不证明resident bound。
- 不因“Quick Look支持很多格式”就把任意用户 file URL 自动交给 Quick Look。
- 不在 G1/G3 前引入 completed/disk Preview cache；不在 G8/SLO 前扩大 History read。
- 不用 mock Apple framework证明格式支持、资源上限或零外部 I/O。
- 不把 capability JSON 当成 authorization，也不让 Python直连 store。

## 13. 推荐交付顺序

1. **止损与规格裁决**：关闭 RTF/HTML/abstract text naïve semantic/edit；修正 external UTF-16 事实；
   明确 raw source view 的标签；决定 projection schema disposition。
2. **格式 facts + manifests + inventory**：先迁移 image/text/special marker，删除至少十处散落 policy；
   unknown raw fallback 作为硬回归。
3. **ContentPreview tracer**：loader 保留 exact History fence，concrete module 完成 plain text artifact + typed
   unsupported；不增加 History public read。
4. **ContentPreview image tracer**：PNG/JPEG/TIFF，真实 ImageIO runtime intersection、malformed分类、
   resource child proof；替换当前 CGImage cross-actor seam。
5. **multi-item raw tracer**：两个 string items端到端，再做 Finder多文件；不要先铺开全部格式。
6. **RTF/RTFD 与 PDF static**：inert links/attachments/page actions，bounded artifact与 accessibility。
7. **file metadata + explicit lease**：先 local/cloud/network 状态，再 Quick Look/AV；默认 hover不读正文。
8. **HTML**：先plain sibling/type metadata；source/static grammar各自有codec/spec后再做，WebKit fidelity只有
   zero-I/O black-box证据后再准入。
9. **Python capability export**：先批准 `DEC-FORMAT-INVENTORY-OWNER` 与 Gateway注入 seam；之后才复用同一
   pure serializer让真实 Python child验证 JSON。外部修改权限仍由独立 ExternalGateway/grant/revision设计拥有。
10. **按证据优化**：G1/G3/G8 或 renderer RSS/crash proof实际触发后，才加 cache、purpose-specific read、
    streaming blob或 helper isolation。

## 14. 紧凑 evidence map

| 结论 | 直接理由 | 证据 | 支持上限 | 下一判别测试 |
|---|---|---|---|---|
| unknown UTI 应 raw-preserve | 当前 adapter/storage无类型 allowlist；UTI identity不等于 decoder | 当前源码；Apple pasteboard/UTType memo | 单 item raw passthrough | FORMAT-3 + real consumer |
| 必须有 multi-item模型 | Apple pasteboard可含多个 item；当前只取 first | `PasteboardAdapter.swift`; Apple memo | 当前会截断第二项 | PB-MULTI-1A/1B |
| 当前 text policy 不正确 | abstract/unspecified/markup UTI被 UTF-8处理 |四个当前源码位置；Apple text facts | raw未损坏，但 semantic/edit有缺口 | FORMAT-1A…1D |
| 至少十处策略会漂移 | Storage、Preview、Details、Editor、row、privacy各有 set/switch |当前源码表 | 已确认 HEIF/BMP/UTF-16差异 | inventory source gate |
| ImageIO表必须和 runtime求交 | Apple提供动态 readable type set，实际 decode仍可失败 | Apple ImageIO docs/memos | 当前 OS admission | per-build snapshot + fixtures |
| Preview 应独立 | 当前 UTI、History read、decode、lifecycle、UI error散落 |当前 Preview/thumbnail源码 | 架构 deepening direction | PREVIEW-1 deletion test |
| output/streaming downsample证据不等于 decoder资源有界 | Apple定义thumbnail extent并展示推荐streaming pipeline | Apple ImageIO memo | 不能声称各格式peak RSS bound | adversarial child suite |
| HTML/Quick Look/file不可自动外部 I/O | framework有资源下载/文件访问面 | Apple Preview memo | 需要默认 deny policy | zero-I/O canary suite |
| 新 History preview read必须后置 |现有 details可先集中；G8拥有 read-path证据门槛 | `06` G8；当前 review | 不证明现有 RSS满足SLO | representative G8 measurement |
| Python可读取 capability清单 | inventory可序列化无内容状态 |本设计 | 不授予 content/revise权限 | real Python JSON golden test |

最终目标不是声称“Clipy支持所有 Apple 剪贴板类型”，而是让代码和运行时都能诚实回答：

1. 哪些 bytes 会被无损保存与回写；
2. 哪些 exact formats 有确定的 search/edit契约；
3. 哪些 Preview route在这台 macOS上可用、受什么预算与权限限制；
4. 哪些输入仍然只作为 opaque history存在；
5. 加一种格式时，只修改真正拥有该行为的 module，并通过同一条纵向 TDD证据链。
