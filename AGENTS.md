# Clipy 开发说明

本文件说明仓库入口、实现约束和工作方式。当前产品说明集中在 [docs/README.md](docs/README.md)，实现细节以源码、模块清单和实际 CI 结果核对。

## 沟通和验证

使用自然的简体中文，先回答实际问题。说明完成的修改和验证结果；不要把代码阅读、测试存在或旧 CI 的成功当作当前修改已验证。

用户明确要求只通过 CI 验证，禁止下载或运行本地 Swift、编译器解析、构建和测试。启动 CI 后只能使用 `gh run watch <run-id> --exit-status` 等待，不写轮询脚本，也不反复执行 `gh run list` / `gh run view` 查状态。结束后读取对应日志和产物；等待期间继续审查和修复代码。可以并行派出多个 subagent，按文件所有权避免互相覆盖。

## 产品与模块

Clipy 是 macOS 26+、arm64 剪贴板历史应用，使用 Swift 6 语言模式、complete strict concurrency、Xcode 26 / Swift 6.2。SwiftPM 模块图在 `Package.swift`，应用、CLI 和宿主测试目标在 `ClipyApp/project.yml`。生成的 `.xcodeproj` 是构建产物，修改后重新生成，不手工编辑。

| 路径 | 职责 |
| --- | --- |
| `Sources/HistoryCore` | public History 协议、封闭操作集、DTO、身份、版本和类型化失败 |
| `Sources/HistoryDomain` | package 纯领域事实、内容和规划器 |
| `Sources/HistoryStorage` | `SQLiteHistory`、唯一 `HistoryAuthority` writer、SQLite、内容文件、搜索、Gateway、缩略图 |
| `Sources/PasteboardAdapter` | NSPasteboard 读取、轮询、写入与来源提示 |
| `Sources/ClipboardFormats` | 精确开放格式标识与编码事实 |
| `Sources/ContentPreview` | 有界文本 / 图片 / 地址渲染，不拥有 History、窗口或缓存 |
| `Sources/ClipyCLIContract` | 有界 JSON 协议，不执行产品操作 |
| `Sources/LocalAutomation` | 本地 Unix socket 客户端、服务与传输 |
| `ClipyApp/Sources` | 组合、原生窗口、SwiftUI、捕获和复制、设置、App Intents 与内置工作流 |
| `ClipyApp/Tools/clipyctl` | 随应用打包的 CLI |

`HistoryPerfRunner`、`HistoryRestartProbe`、`PreviewAccessProbeRunner` 是测量或测试程序。UI 没有独立 SwiftPM PresentationUI 库，资源位于 `ClipyApp/Resources`。

## 内容与存储

使用系统 SQLite3 元数据 / 索引和不可变 UUID blob 文件，不恢复 SwiftData。一个 `HistoryAuthority` 写入者原子提交 History、Gateway、变更位置和逻辑用量；内容文件先发布，再提交数据库引用。物理清理独立于用户提交，不改变回执或位置。

不添加双写、ORM / ModelContext 仿真、旧存储读取、迁移、自动修复或删除现有用户存储。标题和搜索正文保持精确 UTF-8 Data。保存原始表示拼写与字节；领域层同一系统项目的类型去重使用 Unicode 规范等价规则，不修改原始拼写。

xxh3 仅查找剪贴板去重候选，候选必须再字节确认。UUID 独立于指纹。修订不可变；`ContentVersion` 只在 Effective Content 字节改变时前进，`ChangePosition` 每个非空 History Commit 恰好前进一次。观察输出权威替换快照，游标绑定查询与快照。

读取按用途取得有界事实和必要表示；不添加全库常驻 ID / signature 索引或搜索语料。NSCache / NSPurgeableData 只保存可重建派生值，`mappedIfSafe` 不保证零拷贝。优先降低时间复杂度，只接受小幅空间代价；并发工作和队列必须有实际资源边界。

## 实现要求

调用者可见边界使用 `public`，跨模块实现词汇使用 `package`，模块内使用 `internal` / `private`。HistoryCore、HistoryDomain 只依赖 Foundation；Domain 不做 I/O、actor、时钟、UUID 生成或 async。跨 actor / 模块只传不可变 Sendable 值，AppKit / SwiftUI 操作属于 MainActor。

不使用应用自建 `.shared` / `.current` 服务定位器、`@unchecked Sendable` 或 `nonisolated(unsafe)`。App Intents 的框架依赖注册保留在组合入口。添加 HistoryAction 时更新所有编译器穷尽分支。

损坏值明确拒绝，不静默修复或忽略解码异常。失败不能泄露 SQL、凭据或剪贴板正文。产品不访问网络、外部服务或遥测；明确的本地导出、工作流和用户发起的打开动作保留其当前行为。

修复实际产品问题及直接测试。不添加策略锁、ratchet、hash / checksum 校验、routing / registry 层、人造边界、仓库扫描器、gates、账本 / snapshots，或证书、签名、公证、发布身份机制。现有模块访问控制和 Gateway 授权可按产品行为维护，但不在外面再加治理层。

依赖只有 vendored xxHash v0.8.3 和 `Package.swift` 固定 revision 的 Fuse 1.4.0；不额外添加第三方依赖。历史 release / runtime 工作流不用于普通修复。

## 测试和 CI

使用 Swift Testing，测试放在所属模块。存储语义用真实 `SQLiteHistory` 和私有临时目录；scripted History 只用于 SwiftUI 预览。App 的 presentation / integration 测试由 XcodeGen 管理；真实 UI journeys 使用 `ClipyUITests`。

保留用户结果、原始字节、事务回滚、版本一致性、取消、资源边界、分页与重开证明。删除固定常量 / 文案快照、源码扫描、实现步骤镜像、重复下层测试和无真实行为的断言。不通过删除失败语义测试、增加 sleep 或扩大超时掩盖问题。异步测试前置条件失败立即退出，分页循环不能在超时后无界重试。

常规 CI 是 `.github/workflows/correctness.yml`：SwiftPM 功能 lane 与四个 App / GUI 分片并行，同一桌面 GUI 串行。第四片包含两个宿主 bundle 和其余 / 新增 UI classes，分组以 `scripts/ci/run_app_correctness.sh` 为准。SwiftPM 显式 `--skip 'HistoryPerfTests\.'`；裸 swift test 没有默认排除性能 tests。编译器警告视为 CI 失败。

只按真实构建和测试证据报告结果。打包成功不代替 correctness；skip 不算对应行为通过。完整执行入口和性能测量范围见 [docs/testing.md](docs/testing.md)。
