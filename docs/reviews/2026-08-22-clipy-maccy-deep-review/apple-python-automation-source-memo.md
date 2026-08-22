# Apple 一手资料备忘录：Python 与未来 Clipy 的本机自动化边界

> 目的：只回答 macOS 26 上，一个**调用者自带的任意 Python 进程**如何查询或变更
> 未来 Clipy history。本文比较 Apple Events / `sdef` + `osascript`、App Intents /
> App Shortcuts + `shortcuts` CLI、XPC、Unix-domain socket，以及 `NSWorkspace` /
> `SMAppService` 的生命周期作用；不把它们误写成已经获准或已经实现的 Clipy 功能。
>
> Apple 资料访问日期：**2026-08-22 UTC**。资料范围严格限于 Apple Developer
> Documentation、Apple Support、Apple 归档 programming guides / man pages 与 Apple
> WWDC transcript；没有用第三方博客、PyObjC 文档或社区实现作为平台契约。
>
> 环境边界：本轮在 Linux 上阅读资料和仓库，**没有**在 macOS 26 signed build 上运行
> TCC、Shortcuts、App Sandbox、launchd、XPC 或 socket 实验。`DOC` 是 Apple 明示；
> `INFERENCE` 是从 Apple 契约与 Clipy 设计推导；`UNKNOWN` 必须由下面的真机判别实验
> 关闭。

> 产品接口解释边界：本文对 direct UDS/Apple Events/XPC 的比较只证明技术 reachability，不选择
> public API。最终产品方向以 [`07-python-local-automation.md`](07-python-local-automation.md) 为准：
> Python 稳定调用第一方 `clipyctl`；transport 永远 private/evidence-gated；所有请求必须先经过获批的
> `ExternalGateway`，不得把 Python 直连 UDS spike 宣称为兼容接口。

## 1. 结论先行

### 1.1 对当前 Clipy 的约束不是“选一种 IPC”

V2-05 已经规定唯一外部信任边界：transport adapter 只能把 typed request 交给
`ExternalHistoryFacade` / `ExternalGateway`；gateway 做限流、输入验证、durable grant
复查与 audit，所有 durable write 最终仍由唯一 `HistoryAuthority` 提交。外部进程、
helper、App Intents extension 和 Python 都不得打开 SwiftData store、创建 writable
`ModelContext` 或成为第二 writer；成功 external write 与 Operation Record 必须共享
Authority transaction。见
[`V2-05 §1`](../../v2/V2-05-external-gateway.md#1-role-and-boundary) 和
[`§3.1`](../../v2/V2-05-external-gateway.md#31-the-single-trust-boundary)。

这项设计当前仍是 **design-consolidated, scaffold proof pending**；V2 主线只准入 main-app
process 的 App Intents connection，不准入 extension、network 或第二进程。`urlScheme` 与
`xpc` 只是 post-V2 credential-bearing kind 的注释预留，UDS / Apple Events 根本还没有
enrollment kind。见
[`V2-05 §1.1–§2.3`](../../v2/V2-05-external-gateway.md#11-what-v2-05-is-not)、
[`§3.3–§3.4`](../../v2/V2-05-external-gateway.md#33-connection-and-grant-lifecycle) 与
[`V2 roadmap X.1–X.7`](../../v2/V2-roadmap.md#gateway-slices)。因此本文给的是后续
architecture admission 输入，不是绕过 V2-05 的实现许可。

### 1.2 明确决策矩阵

| 方案 | Python stdlib / 无第三方依赖 | cold launch | TCC / caller 身份 | binary payload | 对 Clipy 的判断 |
|---|---|---|---|---|---|
| App Intents + `shortcuts run` | **可间接到达**：Python `subprocess` 调系统 CLI；但 CLI 跑的是按名称识别的 shortcut，不是按 bundle/action ID 的通用 RPC | **方向成立、Clipy 未证明**：系统可在 app 未运行时跑 extension；V2-05 禁 extension，main-app cold path 仍是 X.1/X.6 proof | 不应假定 Automation TCC；App Intent 自有 authentication policy / confirmation，但没有文档化的 Python peer identity | CLI 支持文件输入/输出和 UTI；`IntentFile` 可读成 `Data` | **V2-05 首选用户自动化面**；适合少量稳定动作，不等于 Python SDK |
| Apple Events + `sdef` + `osascript` | **可到达**：`/usr/bin/osascript` 从 stdin 读脚本、向 stdout 写结果 | **最好**：需要 response 的 local `tell` 会把未运行 app hidden-launch | 明确受 Automation consent 约束；event 有 sender UID/EUID/audit-token attrs，但 `Python → osascript` 的最终 TCC/audit identity 未验证 | Apple Event descriptor 能装任意 bytes；`osascript` 文本边界宜用 JSON + Base64 或文件 | **可行的窄命令面**；TCC、文本 marshaling 与共享 caller identity 使其不宜作首选 bulk API |
| app-owned UDS + `open` + retry | **直接可到达**：Python 标准 `socket` 的 `AF_UNIX`，无需 Apple framework bridge | **不是 transport 自带**：先 `open` 启 app，再以有界 backoff 等 socket ready | 没有 Apple Events Automation 层；legacy `getpeereid` 文档支持peer EUID/EGID，但macOS 26 SDK/sandbox仍需实测。只认证“同一用户”，不识别具体 Python 程序 | 原生 byte stream；由 Clipy 定 framing、版本、长度上限和 backpressure | **private transport spike候选**；public API仍是`clipyctl`，且必须新增V2-05 enrollment/spec并关闭sandbox reachability |
| XPC / NSXPC | **不能直接到达**：Python stdlib没有 Apple XPC typed client；需要 first-party signed `clipyctl` / native bridge | **很好**：launchd 按需启动 XPC service / Mach service | `NSXPCConnection` 暴露 peer EUID/PID，并能强制 code-signing requirement | 原生 XPC data buffer / `Data` | **native signed client 最强**，但不满足“任意 Python 直接调用”；LaunchAgent/authority ownership 会带来最大重构 |
| `NSWorkspace` / `open` / `SMAppService` | 只是 Python 可通过 subprocess 触发的生命周期工具 | `open` 启 GUI app；registered service 可由 launchd 管理 | 不定义业务授权或 request peer | 不承载 history payload | **只能配合 transport，绝不是 transport 或 grant** |

推荐分两层：

1. **先按现有 V2-05 完成 App Intents / App Shortcuts**，把 user-visible、低频、有限参数
   的 browse/read-content/manage 做完 deny-by-default grant、audit 与 main-process cold/warm
   proofs。Python 可用 `shortcuts` CLI 编排，但产品文案只能称“Shortcuts automation”。
2. 若批准真正的程序接口，稳定public surface固定为first-party **`clipyctl`**，再为其选择一个private
   transport与独立Local Automation enrollment kind。UDS adapter若入选，只做frame preflight/peer evidence；
   它经无policy `AuthenticatedIngressFacade`把opaque credential/request委托给internal `ExternalGateway`
   完成connection resolution、grant、rate limit与audit。Python只启动CLI；CLI可用`open`冷启动Clipy并做
   ready handshake，Python不绑定或直连private socket。

Apple Events 是可行的第二 adapter，适合想保留 AppleScript discoverability 的小命令集；
XPC 只有在 Clipy 同时交付一个 signed native CLI/bridge，或未来把唯一 Authority 明确迁到
launch-managed agent 时才值得进入主路径。不要让“XPC 很原生”掩盖它对 arbitrary Python
没有直接 reachability 的事实。

---

## 2. Apple Events、`sdef` 与 `osascript`

### 2.1 DOC：它天然是 request/reply 的 app automation IPC

- Apple 把 Apple Events 定义为跨进程 request/reply message；脚本 target app 时，命令
  以 Apple event 发送。Cocoa scripting 会接收 event、提取参数并调用 scriptable class
  ([Apple Events](https://developer.apple.com/documentation/coreservices/apple_events)、
  [`NSScriptCommand`](https://developer.apple.com/documentation/foundation/nsscriptcommand))。
- scriptable app 的术语由 bundle 内 `.sdef` 定义；dictionary 描述 commands、classes 和
  properties，并由系统 scripting components、app 与 scripts 共用
  ([About Scripting Terminology](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AboutScriptingTerminology.html)、
  [`NSScriptSuiteRegistry`](https://developer.apple.com/documentation/foundation/nsscriptsuiteregistry))。
- `/usr/bin/osascript` 是系统 command-line OSA 前端：从文件或 stdin 执行脚本，并把结果
  写 stdout。Apple 的示例明确用它 launch、query app
  ([Application Scripting With osascript](https://developer.apple.com/library/archive/documentation/OpenSource/Conceptual/ShellScripting/AdvancedTechniques/AdvancedTechniques.html))。
- cold launch 是该路线最强的性质：local `tell application` 内一旦执行需要 app response
  的语句，AppleScript 会在 app 尚未运行时把它**隐藏启动**
  ([AppleScript Control Statements](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_control_statements.html))。

所以 Python 端只需标准库 `subprocess` 驱动固定 AppleScript/JXA template，stdin 传 request、
stdout/stderr 收 result，无需 PyObjC。不过这一点只证明“Python 可借系统 executable 到达”，
不证明 `osascript` 是稳定 binary protocol。

### 2.2 async 与 single-writer 可以正确衔接

Cocoa scripting 并不要求 Clipy 在 Apple-event callback 中同步阻塞等待 actor。自定义
`NSScriptCommand` 可调用 `suspendExecution()`，handler 返回后由任意 thread 调
`resumeExecution(withResult:)`
([`resumeExecution(withResult:)`](https://developer.apple.com/documentation/foundation/nsscriptcommand/resumeexecution%28withresult%3A%29))；raw handler 也有
`NSAppleEventManager.suspendCurrentAppleEvent()` / `resume(withSuspensionID:)`
([`NSAppleEventManager`](https://developer.apple.com/documentation/foundation/nsappleeventmanager))。

因此若该 transport 获准，合理路径是：

```text
NSScriptCommand / AppleEvent adapter
  -> parse + fixed bounds + sender policy
  -> connection-scoped ExternalHistoryFacade
  -> ExternalGateway grant/rate/audit
  -> HistoryAuthority (only writer)
  -> resume command with Sendable result
```

不要让 command subclass 直接调用 `ClipboardHistory.perform` 来跳过 ExternalGateway，也
不要在 main thread semaphore-wait actor；两者分别破坏 V2-05 security boundary 与 AppKit
liveness。

### 2.3 TCC 与 peer identity

- macOS Automation 设置让用户逐 app 允许或拒绝其控制其他 app；首次请求会显示 consent
  dialog，之后可在 Privacy & Security > Automation 修改
  ([Allow apps to automate and control other apps](https://support.apple.com/guide/mac-help/mchl108e1718/mac))。
- 发送方 app 需要 `NSAppleEventsUsageDescription`；Hardened Runtime 下，用于向其他 team
  发送 Apple events 的 resource entitlement 是
  `com.apple.security.automation.apple-events`。Apple 明确说只向自身或同 Team ID process
  发送时不需要该 entitlement
  ([`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)、
  [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events))。
- received Apple event 有 read-only sender attributes，包括 UID、EUID、PID、sandbox flag、
  app identifier entitlement 与 audit token
  ([Keyword Attribute Constants](https://developer.apple.com/documentation/coreservices/1542920-keyword_attribute_constants))。
- sandboxed receiver 仍可 receive/respond Apple events；sandbox restriction 主要限制它向
  其他 app 发送
  ([App Sandbox temporary Apple Event exception](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html))。

`INFERENCE`：Clipy 可拒绝 sender EUID 不等于自己的 event，并把 sender audit token 作为
诊断输入；但经 `Python → /usr/bin/osascript` 调用时，TCC 记录哪一个 responsible code
identity、Clipy 看到的 sender 是 `osascript`、Terminal/IDE 还是上层 launcher，Apple 上述
页面没有给足契约。若所有 Python caller 最终都呈现同一个系统 tool identity，V2-05 只能
把它们视作一个共享 connection，无法做 per-script grant/audit。必须用 signed/notarized
Clipy 和至少 Terminal、IDE、launchd Python、signed wrapper 四种入口实测，不能凭开发机
一次 Allow 推广。

### 2.4 binary 与 wire shape

Apple event descriptor 是“typed code + data”；`NSAppleEventDescriptor` 可以从任意 byte
sequence/length 构造，也可以取回 `Data`
([`NSAppleEventDescriptor`](https://developer.apple.com/documentation/foundation/nsappleeventdescriptor)、
[`init(descriptorType:bytes:length:)`](https://developer.apple.com/documentation/foundation/nsappleeventdescriptor/init%28descriptortype%3Abytes%3Alength%3A%29))。
所以 native Apple Event client 与 Clipy 之间技术上能传 binary。

但 `osascript` 的公开 contract 是 script/result 经 stdin/stdout；Apple 没有保证它会把
arbitrary descriptor bytes 原样写 stdout，也没有公布适合 large clipboard blobs 的 event
size ceiling。因此 Python-facing v1 wire 不应依赖 `osascript` pretty-print 的 list/record：

- control plane 用一个 versioned UTF-8 JSON string；
- small binary representation 用 Base64 并计入严格 decoded-byte bound；
- large payload 返回 owner-only temp file / file URL，并规定 close/crash cleanup；
- request/reply 都带 request ID、timeout 与 typed error；永不把 raw clipboard content 写
  command line argument、log 或 audit payload。

这些是设计选择，不是 Apple 契约；message ceiling、timeout、TCC deny/error shape 与 app
quit-mid-command 都是 `UNKNOWN`。

---

## 3. App Intents、App Shortcuts 与 `shortcuts` CLI

### 3.1 DOC：系统支持 command-line intelligent input/output

- App Shortcuts 安装 app 后即可出现在 Shortcuts/Siri/Spotlight，无需用户先手工 Add to Siri
  ([App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts))。
- Apple Support 明确提供 `shortcuts run <name>`；`-i/--input-path` 传 documents/images/
  files，`-o/--output-path` 或 stdout 取结果，`--output-type` 用 UTI 指定输出类型；成功与
  失败分别 exit 0/1
  ([Run shortcuts from the command line](https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac))。
- App Intent 参数/结果只可用 framework 支持类型，包括 primitives、collections、
  `AppEntity`、`AppEnum` 与 `IntentFile`；结果支持同一组类型
  ([Adding parameters to an app intent](https://developer.apple.com/documentation/appintents/adding-parameters-to-an-app-intent))。
  `IntentFile.data(contentType:)` 能取得 binary `Data`，但 file-backed value 可能把整文件
  载入内存
  ([`IntentFile.data(contentType:)`](https://developer.apple.com/documentation/appintents/intentfile/data%28contenttype%3A%29))。

因此 Python 可以用 `subprocess.run(["shortcuts", "run", ...])`，通过 temp file/stdio
做 intelligent input/output；这满足“无 Python 第三方 package”，但仍依赖用户当前
Shortcuts collection、shortcut display name 与系统 CLI，而不是稳定的低层 RPC endpoint。
Apple 文档没有给 `shortcuts run` 以 bundle ID + AppIntent type ID + arbitrary named
parameters 直接调用的 contract；name collision、localization、App Shortcut 是否在 CLI
`list` 中以何种名称出现都需 macOS 26 实测。

### 3.2 cold launch 与 V2-05 的进程边界

Apple 公开两种执行形态：

- custom intent 可以放 App Intents extension，使 app 未运行时仍能执行
  ([App Intents app extension](https://developer.apple.com/documentation/appintents/app-extension))；
- intent 通过 `supportedModes` 声明 foreground/background，一些需要 foreground 的 intent
  会在 app 未运行时自动 launch app
  ([Getting started with App Intents](https://developer.apple.com/documentation/appintents/getting-started-with-the-app-intents-framework)、
  [`supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes))。

但 V2-05 明确禁止 extension second process，并要求 main app 启动后取得 baked-connection
facade、只注册一次 `@Dependency`。因此不能引用“extension 可冷运行”来证明 Clipy 的
main-process cold path。真正的验收仍是 roadmap 已写的 X.1/X.6：app terminated 时通过
Siri、Shortcuts UI 和 `shortcuts run` 分别启动，证明 store/gateway/dependency fully loaded
后才接受请求；未加载只能 typed clean-denial，不能把 empty history 当正常结果。

### 3.3 TCC、authentication 与 caller granularity

App Intents 不是 Apple Events；不能把 Automation pane 的 Apple-event consent 规则直接
套来，也不能反向断言“绝无 TCC”。Apple 给的明确安全 controls 是：

- `authenticationPolicy` 默认 `.alwaysAllowed`，可在 locked device 运行；敏感 history
  intent 应显式选 `.requiresAuthentication` 或 `.requiresLocalDeviceAuthentication`
  ([`authenticationPolicy`](https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy)、
  [`IntentAuthenticationPolicy`](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy))。
- destructive / unsafe work 前应调用 `requestConfirmation()`
  ([`requestConfirmation()`](https://developer.apple.com/documentation/appintents/appintent/requestconfirmation%28%29))。
- App Intent 本身还能因其访问的 protected resource 返回 permission-required failure；这
  与 V2-05 的 history grant 是不同层
  ([`AppIntentError.PermissionRequired`](https://developer.apple.com/documentation/appintents/appintenterror/permissionrequired))。

V2-05 已决定 Siri/Shortcuts/Spotlight 共用一个 `.appIntents` connection，grant 是用户对
该 surface 的 consent，不是 Python client credential。`shortcuts` CLI 也没有向
`perform()` 暴露可据以鉴别“哪个 Python script”的 documented peer UID/audit token。
所以它适合 shared user automation grant，不适合 per-script identity。`.browse`、
`.readContent`、`.manage` 仍必须分开；特别是 full clipboard bytes 不能因 caller 已解锁
就自动获得 `readContent`。

### 3.4 single writer 与 binary 的实际取舍

只要 intent 留在 main app target，并仅 await `ExternalHistoryFacade`，single writer 可保持；
把 intent 搬进 extension 后让它打开同一 SwiftData store，则直接违反 V2-05。若未来确需
extension，extension 只能经另外获准的 IPC 回 main-process gateway，或先把 Authority 所有权
整体迁到单一 service；不能让 app 与 extension 各写。

Shortcuts 对 files/UTI 的 binary support 很适合“导出一个 item”“对一个 ID pin/remove”；
但 history page + 多 representation + cursor + typed failures 要塞成一个 intelligent output
会变成 manifest/temp-files protocol。它仍可做，但那已经是额外 wire spec，而不是 App
Intents 免费提供的 RPC。不要让 `IntentFile` 绕过 V2-05 response byte limits，也要避免整文件
materialization 无界。

---

## 4. XPC：native 能力强，但 arbitrary Python 不能直接消费

### 4.1 DOC：launch、payload 与 peer validation 都很强

- XPC service 由 launchd on-demand launch、idle terminate、crash restart；app-bundled XPC
  service 默认是 private，只对包含它的 main app 可用
  ([Creating XPC Services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)、
  [XPC overview](https://developer.apple.com/documentation/xpc))。
- 对 app bundle 外的 LaunchAgent/LaunchDaemon，可用
  `NSXPCConnection(machServiceName:)` 连接 launchd.plist 广告的 Mach service
  ([`init(machServiceName:options:)`](https://developer.apple.com/documentation/foundation/nsxpcconnection/init%28machservicename%3Aoptions%3A%29))。
- `NSXPCConnection` 公开 peer EUID、EGID、PID、audit-session ID，并可设置 code-signing
  requirement；listener 也能对 incoming connections 强制签名条件
  ([`NSXPCConnection`](https://developer.apple.com/documentation/foundation/nsxpcconnection)、
  [`setConnectionCodeSigningRequirement(_:)`](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement%28_%3A%29))。
- low-level XPC 有 byte-buffer object，`xpc_data_create` 会复制任意 bytes
  ([`xpc_data_create`](https://developer.apple.com/documentation/xpc/1505855-xpc_data_create))；
  high-level NSXPC 会序列化允许的 primitive / `NSSecureCoding` object，并要求明确 class
  whitelist
  ([Creating XPC Services — Designing an Interface](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html#//apple_ref/doc/uid/10000172i-SW5))。

### 4.2 Python reachability ceiling

Apple 支持的 client APIs 是 C/libXPC、Objective-C/Foundation 与 Swift。Apple 还明确说 XPC
底层 encoding / channel 是 opaque、可变，client 不得自行解析。Python stdlib没有这些
typed API 的 high-level binding；用 `ctypes` 猜 opaque protocol 不构成受支持的方案。

所以只有两条诚实路线：

1. Python 通过 subprocess 调 Clipy 随 app 交付的 signed `clipyctl`，CLI 再调用 XPC；这
   对 Python 是“无需 pip dependency”，但依赖一个 first-party native executable。
2. 交付 LaunchAgent/Mach service，并给每个受支持 native client SDK；这不再满足
   arbitrary Python 直接连接。

app-bundled private XPC service 也不能反向解决问题：Apple 明确限制它只供 containing main
app 使用，外部 Python/CLI 不能仅凭 service bundle ID 连接。

### 4.3 对 single writer 的代价

若 Mach service/LaunchAgent 自己打开 history store，而 GUI Clipy 继续打开同一 store，便是
第二 writer，明确禁止。合规拓扑只能二选一：

- service 是 stateless/authenticated proxy，最终把 request 转到**现有 main-process**
  `ExternalGateway`；但还需要另一个可 cold-launch main app 的 hop，系统复杂度很高；或
- 正式把 `HistoryAuthority` 整体迁到唯一 launch-managed service，GUI 与所有 adapters
  都做 client。这是架构迁移，不是“加一个 XPC target”。

XPC service 默认独立、最小 sandbox，且 Apple 建议尽量 stateless；这正说明把有 migration、
single-flight、observation 与 audit transaction 的长期 Authority 塞进去必须另立规格和完整
recovery proof，不能由 XPC 的 on-demand lifecycle 自动证明正确。

---

## 5. Unix-domain socket：候选private `clipyctl ↔ app` wire，不是Python兼容面

### 5.1 reachability 与 binary

Apple 的 POSIX socket 文档把 socket 定义为 process communication endpoint，并建议需要
cross-platform server/client 时使用 POSIX APIs
([Using Sockets and Socket Streams](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/NetworkingTopics/Articles/UsingSocketsandSocketStreams.html)、
[System call overview](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/intro.2.html))。
Python runtime的标准`socket.AF_UNIX`技术上可直接对接BSD interface；这只证明reachability，不选择产品
contract。最终Python只调用first-party`clipyctl`，由CLI作为native private-transport client；脚本不得
绑定socket path/framing。这项Python-language mapping是implementation premise，不冒充Apple对某个Python
distribution/version的保证。

UDS 是 byte stream，天然适合 Clipy 的多 representation bytes；但 stream 没有 message
boundary，必须自行定义：magic/version、request ID、operation discriminant、length-prefixed
header/body、maximum frame/representation/aggregate bytes、deadline、cancellation、response
status、分页 cursor，以及 truncated/oversized/unknown-version fail-closed。JSON control header
+ raw binary segments 比把所有 bytes Base64 化更高效；任何 frame 都必须在 allocation 前
checked-length。

### 5.2 same-user authentication

Apple 的归档 `getpeereid(3)` man page返回 connected Unix `SOCK_STREAM` peer 的 effective UID/GID，并
明确说该机制可靠、双方不能影响对方看到的 credential（除非在不同 credential 下执行
connect/listen）；常见用途就是 server 验证 client
([`getpeereid(3)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getpeereid.3.html))。
这是legacy DOC，不单独证明macOS 26 availability、Swift import或sandbox reachability；必须用Xcode 26 SDK
header/local man page与signed runtime proof关闭。
再配合 owner-only directory/socket permissions，可把入口限制到同一 EUID；macOS 的权限判断
顺序仍先受 sandbox 限制，再走 ACL/BSD owner/group/other
([Understanding Permissions](https://developer.apple.com/library/archive/documentation/Security/Conceptual/AuthenticationAndAuthorizationGuide/Permissions/Permissions.html))。

这只证明socket peer（候选设计里是`clipyctl`）的EUID，不是“某个受信Python文件/venv”。同EUID进程仍可
执行CLI或尝试攻击private endpoint，root也不在该威胁边界内。Local Automation connection仍由V2-05 UX
显式grant/revoke，且对`.readContent`单独告知“同一effective user account中能取得credential并执行CLI的
进程可能读取完整clipboard history”。signed `clipyctl`只能证明中介binary，不能识别调用它的
`.py`。若需要per-client identity，必须引入独立enrollment credential/certificate及其custody；即便如此也
不能自动等同per-script identity，且不再是arbitrary Python零配置。

### 5.3 cold launch 与 lifecycle helpers

普通 app-owned socket 不会因 `connect()` 自动启动 Clipy。最低复杂度 cold path 是：

1. Python启动`clipyctl`；CLI connect，若private endpoint不存在/拒绝，由CLI调用系统`open`启Clipy；Apple Support明确
   `open -a MyProg.app` 可启动 app
   ([Execute commands in Terminal](https://support.apple.com/guide/terminal/apdb66b5242-0d18-49fc-9c47-a2498b7c91d5/mac))。
2. 以有界 exponential backoff 等待 socket ready；server 只有在 store、gateway、grant/audit
   chain 全部 open 成功后才 bind/publish ready socket。
3. 用 boot/session nonce 或 server generation 区分 stale socket；连接失败不得自行删除一个
   可能属于 live server 的 path。

AppKit 内部若需要控制 launch/activation，`NSWorkspace.openApplication(at:configuration:)`
会异步报告 launch success；configuration 能指定 `activates`/`hides`
([`openApplication`](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication%28at%3Aconfiguration%3Acompletionhandler%3A%29)、
[`NSWorkspace.OpenConfiguration`](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration))。
Python不依赖Foundation bridge；由native CLI封装`open`/NSWorkspace选择。`open` CLI的精确
non-activating flags要以macOS 26本机`man open` + signed UX test为准。即使app已launch，也仍需protocol-ready
handshake，process existence 不等于 Authority ready。

`SMAppService` 可注册 app-bundle 内 LoginItem、LaunchAgent、LaunchDaemon；registration
subject to user approval，LaunchAgent 可立即 bootstrap，之后每次 login bootstrap
([`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice)、
[`register()`](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29))。
launchd 还能持有 socket 并按需启动 job，job 通过 `launch_activate_socket` 取回 plist
`Sockets` dictionary 中的 fd
([`launch_activate_socket`](https://developer.apple.com/documentation/xpc/launch_activate_socket)、
[Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html))。

但 `SMAppService` 只是 lifecycle/installation authority。若 registered helper 接 socket，它
仍不能打开 SwiftData；它只能 proxy 到 main-process gateway，或者在另一次正式重构后成为
唯一 Authority。为避免现在引入常驻第二进程、login-item approval 与双重 crash/reconnect
状态，第一版UDS spike若获选，应优先app-owned + CLI封装的`open`/retry，而不是先上launch agent；Python仍不直连。

### 5.4 App Sandbox 是这一路的主要 UNKNOWN

Apple 说 App Group 可让**同一 developer team 的 apps**共享 container，并支持 Mach/XPC/
UDS；UDS path 必须在 group container
([Configuring App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)、
[App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups))。
macOS 15+ 对不在 app group 的 app 访问 group/app-data container 还可能显示 authorization
prompt
([Accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers))。

这些资料**不能**证明一个 unsigned、无 Clipy team entitlement 的任意 Python interpreter
能以受支持方式访问 group container 内的 socket。也不能从“sandboxed 与 nonsandboxed app
可 IPC”外推到“任意解释器一定可连接、无 prompt、可稳定分发”。若 future Clipy 开启 App
Sandbox，必须把下面三种 signed artifact 分开测：

- sandboxed Clipy + unsigned arbitrary Python；
- sandboxed Clipy + signed but non-team Python/launcher；
- sandboxed Clipy + same-team signed bridge。

若前两者没有明确 contract/green proof，UDS 只能要求同 Team ID 的 signed `clipyctl` bridge，
或退回 Apple Events/App Intents；不能把 App Group entitlement 交给 arbitrary Python，也不能
用 `/tmp` 路径猜测绕过 sandbox。当前 Clipy project 没有 App Sandbox entitlement，这只说明
现状，不保证未来 distribution。

---

## 6. 横向 security / correctness 判断

### 6.1 TCC 不等于 V2-05 grant

Automation consent 只说明某 sender 被 macOS 允许控制 Clipy；Shortcuts authentication 只
说明系统允许这次 intent 执行；UDS EUID 只说明同一用户；XPC signing requirement 只说明
peer 满足签名规则。它们都不能替代 Clipy 的 `.browse` / `.readContent` / `.manage` durable
grant、revocation-at-commit recheck、rate limit 与 Operation Record audit。

反过来，V2-05 grant 也不能绕过 TCC、locked-device authentication、App Sandbox 或 launchd
approval。两个层次必须分别失败并分别呈现。

### 6.2 所有 transport 的唯一合法落点

```text
Python
  -> osascript | shortcuts CLI | UDS | signed native bridge
  -> transport adapter (no SwiftData, no HistoryDomain facts)
  -> baked ExternalConnectionID + ExternalHistoryFacade
  -> ExternalGateway: bounds -> capability -> authoritative recheck -> audit
  -> HistoryAuthority: only writable ModelContext / transaction
```

外部 request set 也应继续小于 app 内 `HistoryAction`：现有 V2-05 只给 browse/search、
details/pastePayload，以及 pin/unpin/remove；external capture/revise/clear/retention configuration
仍不应因 transport 支持 binary 或 CLI 参数就悄悄开放。

### 6.3 binary content 的 privacy 上限

history query 可能返回 password、token、image、file promise 或多 representation 原始 bytes。
任何方案都必须：

- 默认无 grant；`readContent` 与 browse/manage 分离；
- stdout/stderr/log/audit 只写 request ID、operation kind、byte counts 和 typed failure，不写
  query/body/payload；
- 限制单 frame、单 representation、总 response 与并发 in-flight bytes；
- temp-file output 用 owner-only mode、随机不可猜名、same-volume safe creation、ack/TTL/
  crash cleanup；
- client timeout 不能取消已经进入 Authority transaction 的 commit；retry 必须靠 request ID
  / idempotency policy，而不是盲目重发 mutation。

Apple 文档证明各 transport 能承载 bytes，不证明 large clipboard payload 的合适 ceiling、
zero-copy、atomic delivery 或 secure deletion；这些都是 Clipy-owned protocol semantics。

---

## 7. 必须先做的 macOS 26 判别实验

### `X-PY-AE` — Apple Events

- signed/notarized Clipy，fresh TCC DB；从 Terminal Python、IDE Python、launchd Python、
  signed wrapper 各跑一次 `osascript`，记录 prompt owner、Automation pane identity、received
  sender UID/PID/audit token、deny/error/timeout。
- app fully terminated 时执行 browse；证明 hidden cold launch、gateway loaded fence、async
  suspend/resume、no empty-success。
- 0 B、NUL、invalid UTF-8、64 KiB、1 MiB、上限±1 的 descriptor/Base64/file round-trip；
  查明实际 timeout 与 message ceiling，但只把更小的 approved bound 写进 spec。

### `X-PY-INTENT` — App Intents / CLI

- fresh install 后在 Shortcuts UI 与 `shortcuts list/run` 核对 App Shortcut 名称、localization、
  collision、参数与 exit/stderr contract；不要只在已有 user shortcut 的机器上测。
- warm/cold/locked 三态跑 browse、readContent、pin/remove；验证 explicit authentication policy、
  destructive confirmation、user cancel、TCC/resource denial、dependency unresolved。
- 输出 text、JSON manifest、one/many `IntentFile`、large binary；记录 peak RSS 与 cleanup。

### `X-PY-UDS` — socket

- 真实Python child只调用packaged `clipyctl`；unsandboxed signed Clipy覆盖CLI封装的`open` cold launch +
  ready handshake、concurrent invocations、disconnect、kill/relaunch/stale endpoint。裸socket的half frame、
  slowloris、oversize只由native internal harness测试，不冻结成Python SDK。
- 用different-user signed helper验证directory mode + `getpeereid` deny；same-EUID多个Python各自执行CLI，
  证明它们按批准模型共享Local Automation connection/grant/audit attribution，而非per-script identity。
- sandbox matrix 使用上一节三类 caller；记录 connect 是 success、sandbox deny、TCC prompt
  还是 path denial。未得到支持性结果前，不准把 App Group 当 arbitrary-Python contract。
- mutation timeout/retry下验证获批no-blind-retry/idempotency policy；CLI/helper全程不得打开store。

### `X-PY-XPC` — 仅在批准 signed bridge 后

- app-bundled private service 对外部 `clipyctl` 的 negative control 必须失败；再验证 Mach
  service + code-signing requirement 的 approved topology。
- wrong-team、unsigned、missing entitlement、same-team client matrix；验证 EUID 与 signature
  check 都发生在接受第一个 request 之前。
- cold launch/idle kill/crash restart 后仍只有一个 Authority owner；若做不到，XPC design
  不得落地。

## 8. 最终建议的支持上限

在 macOS 26 proof 完成前，可以作出的最强结论是：

- **App Intents/App Shortcuts** 是 Apple 支持最完整、最符合当前 V2-05 的用户自动化路线；
  `shortcuts` CLI 让 Python 无 pip dependency 地触达它，但仍是 shared, name-based Shortcuts
  surface，不是稳定 per-script RPC identity。
- **UDS** 是`clipyctl`到app的private结构化query/mutation与binary transport候选；它必须作为新的
  ExternalGateway ingress/enrollment正式准入，并以`open`/ready handshake解决第一版cold launch。
  Python public contract仍是CLI；same-EUID只是基础peer evidence，不是完整授权或per-script identity。
- **Apple Events** 具有最自然的 hidden cold launch 和 `.sdef` discoverability，且 sandboxed
  receiver 可接收；但 TCC identity、`osascript` text marshaling 与 caller 粒度让它更适合作为
  窄 adapter，而不是完整 binary history API。
- **XPC** 在 native launch/auth/payload 上最强，却不能被 arbitrary Python stdlib 直接消费。
  除非交付 signed bridge 或正式迁移 Authority ownership，否则不要为“原生”二字增加第二进程。
- **NSWorkspace / `open` / SMAppService** 只解决 lifecycle；它们永远不能替代 transport、
  gateway、grant、audit 或 single-writer ownership。

最重要的否定性结论是：**任何 Python/helper 都不能通过直接读写 SwiftData 来获得“简单
IPC”。** 那会绕开 V2-05 的 capability split、revocation-at-commit、audit atomicity 与唯一
`HistoryAuthority`，不是性能优化，而是重新引入仓库已经明确排除的第二 writer。
