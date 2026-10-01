# 自动化与命令行接口

## 内置工作流

内置工作流在设置的自动化页面编辑，定义保存在应用 UserDefaults 的 `builtInTextWorkflows`，只保存名称、步骤、条件、触发和输入范围，不保存处理时的剪贴板源文本或结果。定义损坏时保留原数据并显示错误，只有明确重置才丢弃。

| 入口 | 职责 |
| --- | --- |
| [`BuiltInAutomation.swift`](../ClipyApp/Sources/UI/BuiltInAutomation.swift) / [`BuiltInAutomation+Input.swift`](../ClipyApp/Sources/UI/BuiltInAutomation+Input.swift) | 定义、有限文本 / 图像输入、步骤执行 |
| [`BuiltInAutomationPredicate.swift`](../ClipyApp/Sources/UI/BuiltInAutomationPredicate.swift) | 布尔条件组合 |
| [`BuiltInAutomationSyntax.swift`](../ClipyApp/Sources/UI/BuiltInAutomationSyntax.swift) | 文本语法解析及生成 |
| [`BuiltInAutomationModel.swift`](../ClipyApp/Sources/UI/BuiltInAutomationModel.swift) | 定义持久化、验证与预览状态 |
| [`BuiltInAutomationWorkspace.swift`](../ClipyApp/Sources/UI/BuiltInAutomationWorkspace.swift) / [`BuiltInAutomationLibraryEditing.swift`](../ClipyApp/Sources/UI/BuiltInAutomationLibraryEditing.swift) | 工作区草稿、多窗口编辑与保存 |
| [`BuiltInAutomationTransfer.swift`](../ClipyApp/Sources/UI/BuiltInAutomationTransfer.swift) | 定义导入与导出 |
| [`BuiltInAutomationExecution.swift`](../ClipyApp/Sources/Automation/BuiltInAutomationExecution.swift) / [`BuiltInAutomationExecutionQueue.swift`](../ClipyApp/Sources/Automation/BuiltInAutomationExecutionQueue.swift) | 输入选择、手动 / 自动执行、共享执行槽 |

步骤包含前后 / 每行去空白、去空行、行去重、排序、大小写转换、JSON 格式化 / 压缩、字面替换、正则替换 / 提取、文本 / 图像类型检查、文本条件、条件分支、Apple OCR 和受条件限制的通知。禁用步骤不执行；完整定义仍要满足可存储的字节与嵌套约束。预览结果不自动改 History 或剪贴板；需要执行的副作用由对应明确操作提交。

工作流可手动执行，也可针对成功捕获运行自动触发；输入可来自输入框、当前剪贴板或有限历史范围。历史范围为 1 至 1,000 项并支持相应过滤。自动执行依据当次捕获和已保存定义，执行队列有内容字节与数量边界，不把快速复制转为无限后台队列。

文本输入 / 输出最多 1 MiB，行操作最多 50,000 行。图片最多 32 MiB、1,600 万像素。最多保存 50 个工作流，名称最多 200 UTF-8 字节，find / replacement 各最多 16 KiB，完整定义数据最多 4 MiB。手动与自动计算共享一个执行槽，pending 请求最多 32、累计保留源内容最多 64 MiB；自动捕获队列另限制为 8 项和 64 MiB。取消的 native OCR 仍持有槽位直至真实任务结束。

导入分块读取最多 4 MiB 的普通文件，也接受指向普通文件的符号链接。读取器以非阻塞方式打开并检查同一文件描述符，拒绝命名管道、设备等特殊文件，避免导入等待通信端而无法取消。导入只建立独立手动草稿，保存后才可启用自动触发。

正则替换和提取使用带进度回调的 native engine 并检查截止时间、取消及有界输出；通知请求不代表系统一定授予通知权限。失败保留具体类别，用户可区分条件不匹配、格式错误、超限、队列满和权限拒绝。

## App Intents

[`ClipboardHistoryIntents.swift`](../ClipyApp/Sources/AppIntents/ClipboardHistoryIntents.swift) 提供搜索、详情、复制、置顶、取消置顶和删除六种后台 intent。依赖在存储打开前通过应用入口注册，解析后使用已有 `AppIntentHistoryIngress` 和 connection-bound `ExternalHistoryFacade`，不在 intent 内另开 writer。

实体是操作返回值，没有枚举历史的 `EntityQuery`。搜索与详情从权威 DTO 建立结果。复制 intent 通过同一 payload 读取和 MainActor PasteboardAdapter 写入系统剪贴板；在实际写入起点再次检查取消，读取后的取消不能覆盖原剪贴板；其余 intent 分别只执行对应 Gateway 操作。外部删除 / 修订与应用缓存、选择和预览失效联动。

## Local Automation 权限与传输

在设置 → 自动化明确启用访问；新连接没有任何授权。浏览预览、读取当前内容、置顶 / 取消置顶、删除、修订分别授权和撤销。删除与修订授权各需确认；授予修订不隐含读取或删除权限。之后有对应授权的程序可执行删除 / 修订，不再逐次询问。

这个连接供同一 macOS 账户下的程序使用。服务器 verifier 在 `~/Library/Application Support/Clipy/LocalAutomationServer/<connection UUID>/`，客户端凭据在 `~/Library/Application Support/Clipy/LocalAutomation/`；目录模式 `0700`、文件模式 `0600`。客户端副本和服务器 verifier 分开保管；撤销连接仍保留必要 verifier 以报告显式撤销状态。这些本地文件不防御已能以同一账户执行的恶意程序，代码没有 Keychain 回退或旧凭据迁移。

[`LocalAutomationPaths.swift`](../Sources/LocalAutomation/LocalAutomationPaths.swift) 选择 `/tmp/clipy-<uid>/automation.sock`。请求不能指定存储、socket 或凭据路径。服务 [`LocalAutomationService.swift`](../Sources/LocalAutomation/LocalAutomationService.swift) 只传输有界请求 / 响应，执行交给已有 [`LocalAutomationIngress.swift`](../Sources/HistoryStorage/LocalAutomationIngress.swift) 和 Gateway。权限在实际操作时检查；History / Gateway 操作记录与写入在同一事务提交。

## clipyctl 使用

客户端由 XcodeGen 打包在 `Clipy.app/Contents/MacOS/clipyctl`。`--help` / `-h` 和 `--version` 不读 stdin、凭据或历史，也不启动应用。

```sh
client='/Applications/Clipy.app/Contents/MacOS/clipyctl'
"$client" recent --limit 20
"$client" search 'meeting notes'
"$client" search '^https://' --mode regexp --limit 10
"$client" read '<locator>'
"$client" read '<locator>' --raw --type public.utf8-plain-text > clipboard.txt
"$client" pin '<locator>'
"$client" unpin '<locator>'
"$client" delete '<locator>'
```

上述子命令不读 stdin，返回一份 JSON。recent / search 默认 20 项，limit 允许 1 至 500，search 默认 exact，支持 exact / fuzzy / regexp。QUERY 是一个 shell 参数，应正确引用空格、引号和正则字符。用响应 `result.nextCursor` 作为 `--cursor` 并重复同一 query / mode / limit 继续，`null` 表示没有后续页。

项目 locator 来自浏览结果，是不透明进程内令牌。locator 和 cursor 可能被有界表淘汰，应用重启后过期，应重新浏览。它们不是任意项目 UUID，也不允许绕过连接授权。`read` 读取当前内容，不修改系统剪贴板。

没有子命令时，stdin 接收一份 UTF-8 JSON。实现入口为 [`CLIArguments.swift`](../ClipyApp/Tools/clipyctl/CLIArguments.swift)、[`ClipyControl.swift`](../ClipyApp/Tools/clipyctl/ClipyControl.swift)、[`ClipyCLIRequestCodec.swift`](../Sources/ClipyCLIContract/ClipyCLIRequestCodec.swift)。

```sh
printf '%s\n' '{"protocolVersion":1,"requestID":"12345678-1234-1234-1234-123456789abc","operation":"browsePreview","arguments":{"limit":20}}' |
  /Applications/Clipy.app/Contents/MacOS/clipyctl
```

| JSON operation | arguments | 权限 |
| --- | --- | --- |
| `browsePreview` | `limit`；可选 `cursor`；搜索另加 `query`、`mode` | 浏览预览 |
| `detailsEffective` / `pasteEffective` | `locator` | 读取当前内容 |
| `pin` / `unpin` | `locator` | 置顶和取消置顶 |
| `delete` | `locator` | 删除 |
| `reviseContent` | `locator`、`expectedContentVersion`、完整 `representations` | 修订 |

两个内容 operation 返回 `contentVersion` 和当前表示形式数组：`pasteboardItemIndex`、`typeIdentifier`、`bytesBase64`。`pasteEffective` 只把 payload 返回程序，不写系统剪贴板、不模拟按键。Canonical 和旧修订不披露给这个内容读取接口。

修订传完整目标表示数组；每项带精确类型、标准 alphabet / padding 的无空白 Base64 以及系统项目索引，省略索引表示 0。不可新增原始内容没有的项目 / 类型对，不可重复同一项目内的类型，不可提交空字节，每个原始系统项目至少保留一个表示。被省略的原始表示在 Effective 中隐藏，仍作为原始内容保留。`expectedContentVersion` 不匹配返回 `content_stale`、退出码 4，内容不改；相同字节返回 `changed: false`。成功修订不含新 payload，读取新内容仍需独立读授权。

`--raw --type TYPE` 仅接受 `detailsEffective` / `pasteEffective`，成功 stdout 只有原始字节，没有换行或 JSON。加 `--item N` 选择系统项目；不加时若多个项目都有该类型则报歧义，不默选首项。失败 stdout 保持空，由 stderr 报短错误码；mutation 不能进入 raw 模式。

请求整体最多 65,536 UTF-8 字节，包含 JSON 和 Base64，因此 CLI 单次修订有效载荷略小于 48 KiB；响应最多 32 MiB。stdin 读取和 stdout / stderr 交付各有 10 秒限制。客户端可启动其自身所在应用并等待服务，但发送 mutation 后不自动重试；连接或输出失败可能返回 `outcome_unknown`，已提交写入不会因客户端未拿到完整响应而撤销。

服务端每个连接的同一 10 秒期限覆盖请求读取、History 执行和完整响应发送。到期后取消操作并等待它实际结束，再释放连接名额。新的外部搜索遇到连续快照竞争最多重取四次，之后返回可重试的忙状态；游标请求不重取。

设置中的启用、撤销和读取可以交错完成。监听服务按当前已完成的授权和凭据状态串行启停，完成后再读一次状态；较晚返回的旧操作结果不能重新启用已撤销的 socket，也不能关闭后来重新启用的连接。

退出码：0 成功，2 无效输入，3 拒绝授权，4 项目 / 内容 / 游标不存在或过期，5 临时不可用或未知结果，6 持久失败。`output_unavailable` 表示输出目标拒绝字节或关闭；客户端不追加第二份 JSON 到已输出的前缀，也不因此重新执行请求。
