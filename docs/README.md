# Clipy 文档

Clipy 是 macOS 26 及以上、Apple Silicon 上的剪贴板历史应用。当前代码使用 Swift 6、系统 SQLite3 和不可变内容文件；应用界面由 SwiftUI 和 AppKit 构成。

这组文档描述当前产品行为、实现入口和验证方法。源码、`Package.swift`、`ClipyApp/project.yml` 和实际运行结果用于核对实现；某个行为出现在源码里，不代表已经通过运行测试。这里不保留历史版本、旧迁移方案、审计账本或逐次变更记录。

| 文档 | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | 模块、隔离边界、History 接口与内容语义 |
| [storage.md](storage.md) | SQLite、内容文件、事务、保留策略与备份 |
| [search.md](search.md) | 搜索语义、过滤、排序、分页与复杂度 |
| [interface.md](interface.md) | 捕获、浮动面板、设置、历史工作区与交互状态 |
| [formats-preview.md](formats-preview.md) | 格式事实、预览、缩略图与本地文件读取 |
| [automation.md](automation.md) | 内置工作流、App Intents、Local Automation 与 clipyctl |
| [testing.md](testing.md) | 构建、测试、CI、性能测量与验证边界 |

## 仓库入口

| 路径 | 所有权 |
| --- | --- |
| [`Package.swift`](../Package.swift) | SwiftPM 模块图与依赖版本 |
| [`Sources/`](../Sources/) | History、存储、格式、预览、剪贴板适配、自动化与测量程序 |
| [`Tests/`](../Tests/) | 与 SwiftPM 模块对应的功能测试和性能辅助测试 |
| [`ClipyApp/project.yml`](../ClipyApp/project.yml) | XcodeGen 应用、CLI 和应用测试目标 |
| [`ClipyApp/Sources/`](../ClipyApp/Sources/) | 应用组合、原生窗口、SwiftUI 界面与系统功能 |
| [`ClipyApp/Tools/clipyctl/`](../ClipyApp/Tools/clipyctl/) | 随应用打包的命令行客户端 |
| [`ClipyApp/Resources/`](../ClipyApp/Resources/) | 本地化文本、图标与其他应用资源 |
| [`ClipyApp/Tests/`](../ClipyApp/Tests/) | 应用宿主测试、界面状态测试、实际应用 UI 测试 |
| [`scripts/`](../scripts/) 与 [`.github/workflows/`](../.github/workflows/) | 项目生成、构建、测试、打包与独立测量 |

生成的 `ClipyApp.xcodeproj` 是构建产物。修改项目结构时编辑 `project.yml`，然后重新生成。

## 当前能力

应用捕获完整剪贴板复制操作，保留同一次复制中有序的多个系统剪贴板项目及其表示形式。重复复制更新已有项目的次数和最近时间。用户可以搜索、置顶和移动项目，查看表示形式与复制来源，删除或清空历史，追加修订、恢复旧内容、复制当前内容、拖出或导出表示形式，并创建一致性备份。

浮动面板和设置中的历史工作区使用同一个 History 实例，但分别保留查询、选择和有限分页窗口。预览只读取所选表示形式。Local Automation 和 App Intents 复用同一个写入者，不能另开产品存储。

产品数据默认保存在 `~/Library/Application Support/Clipy/history.sqlite` 及相邻的 `history.sqlite-content/`。旧 SwiftData 存储、不同布局或损坏存储不会被自动读取、迁移、修复或删除。

本仓库的完整构建和运行测试需要 macOS 26 arm64、Xcode 26 和 Swift 6.2。Linux 上的语法或脚本检查不能证明 AppKit、SwiftUI、ImageIO、系统剪贴板或 UI 测试通过。
