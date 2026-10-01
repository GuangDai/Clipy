# 构建、测试与验证

## 环境与验证依据

完整产品构建和测试要求 macOS 26 arm64、Xcode 26、Swift 6.2；库采用 Swift 6 语言模式，应用启用 complete strict concurrency。源码编译警告视为 CI 失败。依赖只有固定 Fuse revision 与仓库内 xxHash；系统 SQLite3 由 HistoryStorage 链接。

本轮修改按用户要求只通过 macOS CI 验证，不运行本地 Swift 构建 / 测试。下面的命令说明 CI 的实际执行方式，不表示当前机器已经执行或通过这些命令。静态阅读、Linux 脚本检查和编译器解析不能作为 macOS 产品验证通过的证据。

## SwiftPM

功能测试对应所属模块，位于 [`Tests/`](../Tests/)：HistoryCore、HistoryDomain、HistoryStorage、ClipboardFormats、ContentPreview、PasteboardAdapter、ClipyCLIContract、LocalAutomation。持久语义使用真实 `SQLiteHistory` 和 `.temporary` / 临时磁盘目录；只有 SwiftUI 预览可使用 scripted History，不能以假写入者代替存储语义。

[`scripts/ci/run_spm_correctness.sh`](../scripts/ci/run_spm_correctness.sh) 准备 fixture、设置 `CLIPY_FIXTURES_DIR`，执行：

```sh
swift test --no-parallel --skip 'HistoryPerfTests\.'
```

`--no-parallel` 避免互不相关的存储与真实截止时间测试抢占资源；每个并发语义测试仍可在自身内部运行 actors / tasks。脚本检查编译诊断。裸 `swift test` 没有自动排除 `HistoryPerfTests`；应使用功能 lane 的显式 skip。

必要的多进程重开、交易中断和 decoder probe 直接启动已被 target dependency 构建出的辅助程序，不在测试内嵌套第二个 SwiftPM 进程。临时磁盘测试先创建父目录，关闭实际 owner 后再重开，清理仅触及自身创建的数据。

## 应用与 UI

[`scripts/generate-xcodeproj.sh`](../scripts/generate-xcodeproj.sh) 用 XcodeGen 2.45.4 生成项目；图和 target 配置取自 `ClipyApp/project.yml`。基础命令形状为：

```sh
xcodegen generate --spec ClipyApp/project.yml
xcodebuild -project ClipyApp/ClipyApp.xcodeproj -scheme ClipyApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

| 目标 | 所在目录与验证范围 |
| --- | --- |
| `ClipyPresentationTests` | [`ClipyApp/Tests/PresentationTests/`](../ClipyApp/Tests/PresentationTests/)：状态、分页、选择、编辑草稿、预览缓存和工作流行为 |
| `ClipyIntegrationTests` | [`ClipyApp/Tests/ClipyIntegrationTests/`](../ClipyApp/Tests/ClipyIntegrationTests/)：真实 History、捕获、系统桥接、生命周期、intent / CLI 组合 |
| `ClipyUITests` | [`ClipyApp/Tests/ClipyUITests/`](../ClipyApp/Tests/ClipyUITests/)：运行应用、真实控件、键盘、窗口与跨进程操作 |

[`scripts/ci/run_app_correctness.sh`](../scripts/ci/run_app_correctness.sh) 接收 log、result、DerivedData、fixture、XcodeGen 路径及可选 `1|2|3|4|all`。前三分片使用 `ClipyAppGUI` scheme，只构建应用、UI test bundle 及它们的既有依赖，选择互斥 UI class 组。第四分片使用 `ClipyApp` scheme，构建并运行两个宿主 bundle 和剩余 / 新增 UI class；`all` 及省略第六参数的五参数调用也使用 `ClipyApp`，运行完整测试集。分片归属以脚本当前数组为准，维护这些数组时按实际 test duration 平衡，并为第四分片的宿主测试留容量。

各分片在独立 runner 并行；同一 runner 内 GUI 测试串行，避免共享桌面、系统剪贴板和焦点互相干扰。UI fixture 使用生产 writer 预置存储，释放后启动应用；动作通过稳定可访问性标识和真实控件进行。结果保留 `app.xcresult`、测试 log 和可导出的附件，失败时同样保留。

手动 correctness 可填 `ui_test_class`，只运行指定的 `ClipyUITests` 类，用于快速定位真实应用失败。留空以及 push / PR / reusable 调用继续执行五个完整作业。聚焦调用的成功只证明选中的 GUI 路径，不代表完整 correctness 通过。

宿主测试通过 `ClipyApp` test scheme 显式接收素材目录；CI 脚本把 `CLIPY_FIXTURES_DIR` 传入对应构建设置，scheme 展开为测试进程的环境变量。仅在启动 `xcodebuild` 的 shell 中 export 不能证明宿主进程已收到；应从测试日志确认素材用例实际执行，不能把缺素材的 skip 当作通过。

## CI 与性能测量

[`.github/workflows/correctness.yml`](../.github/workflows/correctness.yml) 是 push / PR 常规入口，也支持手动调用。一条 SwiftPM lane 与四条应用 lane 并行，每 job 当前上限 30 分钟，runner 为 `macos-26`。超时是未完成结果，不能当作通过；仅加大上限不能证明不稳定或阻塞测试已修复。

`HistoryPerfTests` 单独验证测量辅助逻辑，不属于功能 correctness lane。现有 [`performance-proofs.yml`](../.github/workflows/performance-proofs.yml) 支持手动选择 `helpers` 或 `proofs`；前者执行辅助测试，后者测量原有工作负载，二者不在 push / PR 自动运行。报告只按实际测量或操作结果判定，不冻结旧文档条款、工作负载名称和标签。性能命令 / 工作流手动运行，不把一次合成测量当作所有真实数据的时间上限：

```sh
swift test --filter 'HistoryPerfTests\.'
swift build -c release --product HistoryPerfRunner
```

`proofs` 的 `pass` 表示该夹具的结果校验和观测耗时比通过既有阈值，不能证明渐进复杂度或所有输入下的时间上限。搜索夹具使用 100 / 400 行短文本，每个 mode 的每次请求必须返回独立捕获的目标条目，exact / regexp 还要求唯一结果；每个规模保存 1 次 warmup 后的 5 个原始耗时及同次请求的行工作计数。索引可以减少候选，低耗时比不能当作完整扫描的复杂度证明。缩略图夹具比较 8 次顺序调用的中位数与 8 个调用者的一次并发总耗时，不记录解码次数；共享解码行为由 HistoryStorage 的确定性并发测试另行验证。

[`.github/workflows/sqlite-scale.yml`](../.github/workflows/sqlite-scale.yml) 为真实 SQLite 独立测量入口：可选 10,000 / 100,000 行，mixed 或固定长度 profile，固定正文可选 1,024 / 65,536 / 262,144 字节。先 seed 临时存储，再用新进程 measure，保留报告与 `/usr/bin/time -l` 资源数据。查询算法的候选、batch、正文读取指标和实际进程资源应放在一起解释，不能用简单输入的耗时推断最坏情况。

mixed 每 10,000 行包含 2,000 条 32–512 字节、6,400 条 1–8 KiB、1,440 条 8–64 KiB、152 条 64–512 KiB 和 8 条 1–8 MiB 原始文本。报告分别统计原始字节长度、实际保存的标题和搜索正文长度；搜索正文仍受产品 256 KiB 上限约束。正文重复七种文本片段，固定长度 profile 使用 ASCII 填充。这些夹具可以比较相同输入下的改动，不能代表真实用户文本的多样性或所有索引分布。

scale 查询分别测量常见标题、常见正文、最老条目的稀有正文，以及最大原始文本在搜索投影尾部的唯一标记；还测量常见正文 / 稀有正文和常见标题 / 稀有大型正文的两种 AND 顺序。另有一个表达式把常见标题词重复 128 次，只测第一页，用于观察重复规划和 posting 查询的耗时。正文命中校验摘录和 UTF-16 标记范围，预期条目来自独立 recent 分页读取。其他常见查询测两页，稀有查询校验唯一结果。每次查询附带同一次生产请求的解码行数、求值行数、命中数、batch 数和终止原因；这些计数不包括 SQLite 内部的 posting-list / planner 工作。

每个 search page 在同一进程和存储中先执行一次 warmup，再执行 5 次计时，保留全部 6 条记录和相同的 phase 名称。`sampleIndex=0`、`isWarmup=true` 标明 warmup；`sampleIndex=1…5`、`isWarmup=false` 标明计时样本，`elapsedMilliseconds` 保存各次原始耗时。按 phase 分组、排除 warmup 后计算中位数；5 个样本不用于报告 p95 / p99。重复请求使用同一输入游标，每次独立校验条目、页边界和摘录。此前已打开存储、遍历 recent 页面并执行其他查询，所以 warmup 也不代表冷盘首查；重复样本是同 runner 的热缓存测量。非 search phase 仍各记录一次；旧 JSON 缺少这两个可选字段，不能把旧版的一次计时当作新版的 5 次样本。RSS 和 footprint 是整进程的操作前后读数，峰值 RSS 从进程启动累计，不能解释成单次查询新增的内存。

[`performance-admission.yml`](../.github/workflows/performance-admission.yml) 使用独立的 5,000 × 256 KiB 临时语料。`exact-search` 保留原有不存在的查询，候选索引可以直接排除它，不能再当作全库扫描证据。`exact-scan` 使用候选不能排除的负查询，并在验证、warmup 和每个样本中要求实际解码 / 求值全部 5,000 行、零命中且正常耗尽。若候选策略改变而不再扫描全部行，测量失败，需重新设计该夹具。两个搜索 mode 各记录 11 个样本和 p50，省略样本数不足的 p95 / p99；browse / warm-open 各记录 101 个样本。JSON 与同 mode 的 `.time` 文件配合读取，独立进程 warm-open 保留系统页缓存，不代表冷启动。这些读数不自行设定产品时间或内存上限。

其他已有 manual / reusable 工作流提供 exact matcher、性能 helper、APFS ENOSPC、跨进程剪贴板或 runtime 的独立检查，不参与普通 push / PR。它们的存在不代表本次已经运行，也不证明当前改动所有 runtime 范围通过。普通产品修复不新增或调用证书、签名、公证与 release identity 流程。

[`.github/workflows/package-app.yml`](../.github/workflows/package-app.yml) 仅手动构建 unsigned Release `Clipy.app` 并上传 zip；`CODE_SIGNING_ALLOWED=NO`。打包成功说明 bundle 构建完成，不代替功能测试。

## 测试取舍与失败定位

保留测试应证明用户可观察结果、持久状态、事务回滚、字节 / 编码边界、版本一致性、真实取消或资源上限。删掉仅重写实现、扫描源码字面、锁住无关布局 / 文案、重复下层语义和只能靠短 sleep 争抢调度的断言；删测试后不能把失去的真实能力证据写成仍已验证。

异步状态测试等待真正的读写 / 发布边界；不要通过不断放大固定等待时间掩盖不确定顺序。UI 测试覆盖用户路径与必要原生接线；可由 owner 功能测试稳定证明的组合和算法不反复在 XCUI 中穷举。权限条件无法由 runner 满足的测试明确报告 skip，不把 skip 写为对应系统行为通过。

定位 UI4 超时时先读取该 job 的最后输出、test identifier、耗时与 `xcresult`；区分构建时间、单条阻塞、分片累计耗时和系统界面不可见。脚本分片调整及测试减负必须由下一次完整 macOS CI 的五个 job 结果证实。

当前文档描述源码可见实现及验证入口。完整验证结论须读取实际 CI 终态和测试范围；提交、排队、编译或跳过测试都不等于行为通过。
