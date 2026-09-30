# 架构与 History 接口

## 模块图

SwiftPM 依赖以 [`Package.swift`](../Package.swift) 为准；应用与其宿主测试以 [`ClipyApp/project.yml`](../ClipyApp/project.yml) 为准。

```text
ClipyApp
├── HistoryCore
├── HistoryStorage ── HistoryCore + HistoryDomain + ClipboardFormats + xxh3 + Fuse + SQLite3
├── PasteboardAdapter ── HistoryCore
├── ContentPreview ── ClipboardFormats + CoreGraphics + ImageIO
├── ClipboardFormats ── Foundation
└── LocalAutomation ── HistoryCore + HistoryStorage + ClipyCLIContract

HistoryDomain ── HistoryCore
HistoryCore、ClipyCLIContract ── Foundation
```

| 模块 / 入口 | 职责 |
| --- | --- |
| [`HistoryCore/ClipboardHistory.swift`](../Sources/HistoryCore/ClipboardHistory.swift) | 调用者可见的协议、操作、DTO、身份、版本与失败 |
| [`HistoryDomain/`](../Sources/HistoryDomain/) | 纯内容模型、去重选择、置顶顺序、修订和保留规划 |
| [`HistoryStorage/SQLiteHistory.swift`](../Sources/HistoryStorage/SQLiteHistory.swift) | 生产 History 实现，操作分派、读取、观察与启动 |
| [`HistoryStorage/HistoryAuthority.swift`](../Sources/HistoryStorage/HistoryAuthority.swift) | 唯一持久写入者，权威状态、事务及快照读取 |
| [`PasteboardAdapter/`](../Sources/PasteboardAdapter/) | NSPasteboard 原始值读取、轮询、写入和来源提示 |
| [`ClipboardFormats/StableFormatFacts.swift`](../Sources/ClipboardFormats/StableFormatFacts.swift) | 开放的精确类型标识及已声明编码事实 |
| [`ContentPreview/ContentPreview.swift`](../Sources/ContentPreview/ContentPreview.swift) | 有界文本、地址和 BGRA8 像素预览 |
| [`ClipyCLIContract/`](../Sources/ClipyCLIContract/) | 有界 JSON 请求解析和响应编码，不执行产品操作 |
| [`LocalAutomation/`](../Sources/LocalAutomation/) | Unix socket 服务、客户端、帧与回复映射 |
| [`ClipyApp/Sources/AppComposition.swift`](../ClipyApp/Sources/AppComposition.swift) | 实例构造、捕获、复制、面板与外部操作的连接 |

`HistoryPerfRunner`、`HistoryRestartProbe`、`PreviewAccessProbeRunner` 是测量或测试程序。`clipyctl` 由 XcodeGen 构建，随应用打包。

## 隔离与所有权

`SQLiteHistory` 组合 `HistoryAuthority`、`IngestPreparationActor`、`RevisionPreparationActor`、`SearchWorker`、`ThumbnailService` 和 `ExternalGateway`。Authority 拥有可写 SQLite 连接和内容文件。SearchWorker 自己打开只读连接；连接和 statement 句柄不跨 actor 传递。准备捕获与修订的 CPU 工作在提交区间外完成，提交前重新检查权威事实。

AppKit 窗口、系统剪贴板写入与 SwiftUI 状态属于 MainActor。跨模块和 actor 只传不可变的 `Sendable` 值；剪贴板内容以 `Data` 传递，图片以编码字节或像素值传递。`NSImage`、`CGImage`、SQLite 句柄不作为 History 的返回值。

调用者可见接口使用 `public`；跨 SwiftPM 模块的实现词汇使用 `package`；模块内部使用 `internal` 或 `private`。领域层没有 I/O、actor、时钟、UUID 生成或 async。代码不用应用自建 `.shared` / `.current` 服务定位器、`@unchecked Sendable` 或 `nonisolated(unsafe)`。App Intents 在应用入口注册其框架要求的依赖，之后复用既有组合实例。

## 内容与身份

一个 History 项目表示一次复制操作，可以包含多个有序系统剪贴板项目，每个系统项目包含若干类型与字节。未知类型仍可保留和原样复制，能否搜索、预览或编辑由对应行为决定。

首次保留的内容称为 Canonical Content；当前复制和预览所用的内容称为 Effective Content。修订追加不可变内容状态，不覆盖原始内容和旧修订；恢复原始内容或某个旧修订同样通过修订操作完成。每个原始系统项目都必须保留至少一种有效表示形式，修订不能新增原始内容没有的项目 / 类型组合。

类型标识的原始 UTF-8 拼写原样保留。格式事实和 UI 表示键按原始字节比较；领域内容集合则使用 Swift String 的 Unicode 规范等价规则，同一个系统剪贴板项目中两个规范等价的类型视为重复并拒绝，不重写已有拼写。不同系统项目可以各自拥有这种拼写，项目索引参与表示身份。

`HistoryItemID`、`RevisionID` 和内容文件使用独立 UUID。xxh3 只筛选剪贴板去重候选，不决定身份；候选必须再逐表示形式确认字节。有效 lineage 提示要求当前 Effective 表示集合完全匹配。普通 Canonical 去重允许富内容吸收同一系统项目结构的简化复制；胜者依次按额外表示最少、最近复制时间、项目 ID 排序。

`ContentVersion` 只在 Effective 字节变化时增加。`ChangePosition` 每个非空 History Commit 恰好增加一次。二者使用检查溢出的整数运算，不循环归零。无变化操作返回 `.unchanged`，不产生提交位置或无意义观察刷新。

## 调用者接口

| 接口 | 行为 |
| --- | --- |
| `perform` | 捕获、置顶 / 移动、取消置顶、删除、清空、修订和配置保留策略 |
| `browse` / `observe` | 一次分页读取 / 第一页完整替换快照；不是增量事件流 |
| `details` | 标题、表示描述、修订摘要、次数与置顶位置，不读内容载荷 |
| `representationMetadata` / `representation` | 按精确项目版本读取描述 / 指定表示形式 |
| `copySources` | 按需读取复制来源，每页最多 32 个；次数变化使旧页失效 |
| `pastePayload` | 读取当前 Effective 内容及 lineage 提示 |
| `thumbnail` | 按精确版本与尺寸返回编码 PNG，或无支持图片时返回 nil |
| `usage` / `retentionConfiguration` | 同一快照的逻辑内容总量 / 已持久化的配置 |
| `backup` | 导出一致的数据库与仍被引用的内容文件 |

`.committed` 回执在持久事务和内部失效发布完成后返回；此后开始的读取至少看到该提交位置。分页游标绑定查询与快照，变化后明确报 `snapshotExpired`。按旧 `ContentVersion` 请求内容明确报 `staleContent`，不得把新字节标为旧版本。损坏内容、无效输入、容量不足、临时不可用等失败使用 [`HistoryCore/Failures.swift`](../Sources/HistoryCore/Failures.swift) 的类型。
