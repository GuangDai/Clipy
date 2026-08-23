# Python 本机自动化：稳定 CLI、私有 transport、唯一 Gateway

> 本文回答一个具体产品问题：任意 Python 进程能否查询并修改未来 Clipy？结论是：
> **当前不能；未来可以，但产品承诺应定义为“用户显式启用并逐项授权后，同一effective user
> account（same EUID）下的任意Python进程都可通过第一方`clipyctl`调用Clipy”**。它不表示任意进程可以直连
> SwiftData，不表示每个 `.py` 文件有独立身份，也不表示受限 app sandbox 中的 Python 一定
> 能启动外部 executable。
>
> 本文只给 REVIEW、规格改动方向与 TDD 流程，不修改产品代码，不生成 HTML。Apple 平台
> 资料、已知与未知边界见
> [`apple-python-automation-source-memo.md`](apple-python-automation-source-memo.md)；当前
> External Gateway 设计见
> [`V2-05-external-gateway.md`](../../v2/V2-05-external-gateway.md)。

## 1. 直接回答

### 1.1 当前 Clipy：不能

当前 tracked source 已有CI-green的in-process `ExternalGateway`、public connection-bound facade及
`ClipyApp`中的六个App Intents，但没有 `clipyctl` executable/product、production socket listener、
Local Automation authenticated ingress、Apple Events dictionary或XPC external listener。F0A允许
normal build中被compile-time erase的UDS诊断源码；它只在手工dispatch的ad-hoc-signed proof artifact
中形成listener与diagnostic client，不是Python入口。
X.7 的限定证据来自[PR #16](https://github.com/GuangDai/Clipy/pull/16)、
[correctness run 32609910701](https://github.com/GuangDai/Clipy/actions/runs/32609910701)与
[symbol run 32609018894](https://github.com/GuangDai/Clipy/actions/runs/32609018894)；它们不证明
signed Siri/Shortcuts调用，也不建立Python入口。
因此 Python 目前最多能像任何程序一样操作 macOS General pasteboard；它不能通过受支持的
Clipy interface 查询、定位或修改 Clipy 保存的 history。

Python 也不应把 SwiftData store 当作临时 IPC：它既不知道完整 store family、WAL、
external-storage 与 migration 规则，又会绕开 grant、audit、OCC、dedup 和唯一 writer。
“能猜到数据库路径并修改”不是支持能力，而是数据损坏与权限绕过。

### 1.2 未来产品承诺：可以，但要把“任意”说准确

建议冻结下面这句话作为验收定义：

> 用户在 Clipy 中启用 **Local Automation** connection 并授予所需 capability 后，同一 effective
> user account（same EUID）下，任何能执行第一方 `clipyctl` 的 Python 3 进程，都可以只用标准库
> `subprocess`，通过 versioned JSON request/reply 查询或执行获准的单项修改；所有请求最终
> 仍经过唯一 `ExternalGateway` 与唯一 `HistoryAuthority`。

这个定义有五个重要边界：

1. **same EUID 是 account-wide 边界。** 它不证明同一 GUI、login 或 audit session；若产品以后
   要求 session 隔离，需要新的 audit-session/transport 证据，而不是继续外推 `getpeereid`。
2. **显式 opt-in、deny by default。** 安装 Clipy 或第一次运行 Python 不自动开放 history。
3. **共享同用户身份。** Terminal、IDE、venv、launchd job 中的 Python 若都能执行
   `clipyctl`，它们共享一个 `localAutomation` connection、grant、quota 与 audit attribution。
   `getpeereid` 只可证明连接 peer 的 effective UID/GID；chosen signed transport 是否还能证明
   first-party CLI 必须另有平台证据。两者都不可能识别“是哪一个 `.py` 文件”。
4. **不承诺 remote 或其它用户。** 网络、SSH remote gateway、跨用户 daemon 都是另一项产品。
5. **受限 sandbox 是外部约束。** 一个由别的 sandboxed app 启动、禁止执行外部工具的 Python
   可能无法调用 CLI；Clipy 不能绕过调用方自己的 sandbox policy。

因此“任意 Python”应理解为同用户、经第一方 CLI、在用户授权范围内的本机自动化，不是
unauthenticated local RPC。

交付承诺应分版本，避免把“能 pin”冒充“能修改内容”：R0 只读 browse；R1 organize 与经独立
destructive grant 的单项 delete；R2 才是带 OCC 的 content revision。若 `deleteItem` 选择每次交互确认，
它就不属于 unattended automation；若选择持久授权，grant UI 必须明确其不可逆性。

## 2. 先冻结 public interface，不先冻结 IPC

### 2.1 推荐的唯一稳定外部 interface：`clipyctl`

Python 不应依赖 socket path、Mach service name、Apple event four-char code、Shortcuts 显示名、
Swift enum raw value或 SwiftData schema。稳定 contract 是随 Clipy 签名、发布、版本化的第一方
`clipyctl`：

```text
Python / shell / editor / launchd
  -> clipyctl: JSON on stdin, JSON on stdout, stable exit-code classes
  -> private transport adapter
  -> restricted AuthenticatedIngressFacade (no-policy wrapper)
  -> ExternalGateway.authenticateAndPerform(peerEvidence, credential, request)
  -> internal credential/connection resolution -> grant -> authoritative recheck -> audit
  -> HistoryAuthority: the only writable ModelContext and commit path
```

这让 public interface 与 transport 演进解耦。第一项F0A先在ad-hoc-signed、non-sandbox诊断artifact上
判别app-owned Unix-domain socket的机械行为；它不选择production transport。以后若完整
Developer-ID/sandbox证据支持UDS、XPC或Apple Events中的一种，
可以替换 private adapter，而不要求所有 Python scripts 改写。socket wire 不是公开 SDK，禁止
第三方绕过 `clipyctl` 绑定它的 path/framing。

`clipyctl` 是新的 first-party executable，不是第二个 Authority。它不得链接或打开
HistoryStorage store，也不得拥有 `ModelContext`；它只负责：

- 校验 CLI/JSON shape 与本地大小上限；
- 寻找或启动 Clipy，并等待 gateway ready；
- 使用一个已 enrollment 的 `localAutomation` credential；
- 将 request/reply 在 public JSON contract 与 private transport frame 之间转换；
- 把 typed failure 映射为稳定 JSON error code 与稳定 exit-code class。

### 2.2 JSON contract 的最小形状

X.8 将下面的wire contract冻结在no-product、Foundation-only SwiftPM target
`ClipyCLIContract`中。该target只做pure request decode、reply encode与exit mapping；它没有
`main`、`FileHandle`、process I/O、transport、credential、Gateway/History依赖，也不fabricate
positive Gateway result。protocol v1的closed operation set只包含`browsePreview`。

Recent request：

```json
{
  "protocolVersion": 1,
  "requestID": "9bd92054-bd3f-4d20-8f8a-5d77aa63b726",
  "operation": "browsePreview",
  "arguments": { "limit": 20 }
}
```

Search request：

```json
{
  "protocolVersion": 1,
  "requestID": "9bd92054-bd3f-4d20-8f8a-5d77aa63b726",
  "operation": "browsePreview",
  "arguments": { "query": "needle", "mode": "exact", "limit": 20 }
}
```

Deterministic success reply：

```json
{"ok":true,"protocolVersion":1,"requestID":"9bd92054-bd3f-4d20-8f8a-5d77aa63b726","result":{"items":[],"nextCursor":null}}
```

Deterministic error reply：

```json
{"error":{"code":"invalid_request"},"ok":false,"protocolVersion":1,"requestID":null}
```

冻结的输入规则是：

- request最多65,536 bytes；在UTF-8 decode、JSON parse或任何parser-owned allocation前先检查
  supplied byte-buffer length；strict UTF-8，不接受BOM；
- 恰好一个root object，后面只允许RFC 8259 JSON whitespace；空输入、第二个value或其它
  leading/trailing byte均拒绝；
- 最大depth 8（root object为1，每层contained object/array加1）、每个object最多32 lexical
  members、每个array最多512 elements；
- every-object unknown field全部拒绝；decode后UTF-8 scalar/byte sequence相同的key在typed
  request构造前视为duplicate（`"a"`等于`"\u0061"`），不新增NFC/NFD normalization；
- JSON number必须是lexical integer；fraction、exponent、non-finite extension或field checked
  conversion越界均拒绝，不经floating-point round-trip；
- `requestID`必须是lowercase canonical 36-character hyphenated non-nil UUID。它只作
  correlation；跨request重复值合法，X.8不新增idempotency、retry cache、digest或hash；
- recent arguments恰为`{limit,cursor?}`，`query`与`mode`都缺席；search arguments恰为
  `{query,mode,limit,cursor?}`，`query`与`mode`都存在。没有`kind`字段；
- `mode`只允许`exact|fuzzy|regexp`；`limit`为integer `1...500`；query非空且最多4,096
  UTF-8 bytes，fuzzy再限64 Characters、regexp再限512 Characters，exact无第二个Character bound；
  cursor若存在则是opaque non-empty UTF-8，最多4,096 bytes；所有string bound作用于decoded string，
  不作用于JSON escape spelling。

冻结的输出规则是：

- success envelope只有`ok/protocolVersion/requestID/result`；error envelope只有
  `error/ok/protocolVersion/requestID`，其中error只有`code`；无法先取得合法requestID时输出`null`；
- `result`只有`items`与`nextCursor`。每个item恰有`locator/title/typeIdentifiers/lastCopiedAt/pinned/snippet`；
  locator为non-empty且最多1,024 UTF-8 bytes；typeIdentifiers最多32项且每项最多512 UTF-8 bytes；
  lastCopiedAt为UTC RFC 3339、exact milliseconds与literal `Z`；pinned为Boolean；snippet为
  string或null；nextCursor为null或non-empty、最多4,096 UTF-8 bytes的opaque string；title最多
  1,024 UTF-8 bytes、snippet最多322 Characters，均直接复用`06` §2的owning History
  projection bounds，不另造wire literal；
- 完整reply stdout buffer（含terminal LF）最多33,554,432 bytes，超限返回typed codec failure，不截断；items与
  typeIdentifiers保持typed input order；所有object key按lexicographic order输出compact UTF-8 JSON，
  最后恰好一个LF；
- clipboard bytes、query 与 credential 从不放 argv、environment、stderr 或 audit；
- X.8只证明pure emission bytes。未来executable成功时stderr为空，失败时恰为
  `clipyctl: <error.code>\n`，不得添加free text、input fragment或internal error；真实FD/stdin/stdout
  属于X.9；
- CLI version 与 protocol version 分开；升级 CLI 不自动改变 wire semantics。

exit-code classes与exact snake-case codes冻结为：

| Exit | 稳定类别 | Exact `error.code` |
|---:|---|---|
| `0` | success | 只有success envelope；future `unchanged`仍是success。 |
| `2` | invalid invocation/request | `invalid_json`, `invalid_request`, `unsupported_protocol_version`, `unknown_operation`, `request_too_large`, `response_too_large` |
| `3` | denied | `not_enrolled`, `not_granted`, `connection_revoked`, `authentication_failed`, `peer_rejected` |
| `4` | target conflict | `not_found`, `cursor_expired`, `content_stale`, `locator_invalidated` |
| `5` | transient | `not_ready`, `rate_limited`, `busy`, `timeout`, `cancelled`, `outcome_unknown` |
| `6` | Clipy/data failure | `store_open_failed`, `corrupt_data`, `invariant_violation`, `transaction_failed`, `audit_failed` |

exit 2内部也不允许implementation随意选code：input超过65,536-byte envelope只对应`request_too_large`；
invalid UTF-8/BOM/JSON syntax/trailing或second root/duplicate/depth/width/NaN/Infinity对应`invalid_json`；
typed shape、unknown/missing field、type mismatch、fraction/exponent policy、checked overflow、requestID与
arguments bound对应`invalid_request`；valid unsupported major与valid unknown operation分别对应
`unsupported_protocol_version`和`unknown_operation`；encoder总界限只对应`response_too_large`。

不要把每个 Swift error case都做成 shell exit code；那会把实现 vocabulary 永久泄到 public
interface。JSON error code可更细，exit code只服务 shell/Python 的顶层分支。

Python caller 的支持路径因此非常普通：
`subprocess.run([resolved_clipyctl], input=json.dumps(...), encoding="utf-8", errors="strict",
capture_output=True, timeout=..., check=False)`。`resolved_clipyctl` 的安装位置与发现规则必须在
第一条 packaged tracer 前冻结；不能假设用户手工修改 `PATH`，也不能依赖 locale 默认编码。

### 2.3 Binary 不应污染 control plane

JSON 很适合 control/result manifest，不适合无界 binary。建议分两档：

- 小 payload 可用显式 `inlineBase64`，其 decoded size 在 allocation 前检查；
- 大 payload 优先由 caller/CLI 在 **caller 权限下**安全创建文件并把已打开 descriptor交给CLI
  writer；app只返回有界bytes/segments，不使用自己的权限解释或写入任意caller path。stdout只返回
  type identifier、byte count与descriptor/result manifest。若未来采用CLI-owned temp，必须
  `O_EXCL`、owner-only、有界生命周期并有失败清理；不能把路径选择变成app confused deputy。

private transport 可以用 `magic + major/minor + requestID + checked header length + checked segment
lengths` 的 length-prefixed framing传 raw bytes。UDS 是 byte stream，没有 message boundary；半帧、
slowloris、oversize、disconnect 与 response backpressure都必须在 adapter 内收束。这个 binary
framing 保持 private，不能成为 Python 需要重写的第二 public interface。

第一条 read-only tracer 只做 `browsePreview`，不需要提前决定大 binary 输出；`readEffectiveContent`
进入时再冻结一条最小、可测的 binary contract。

## 3. Capability 必须比当前 V2-05 更细

当前 V2-05 的 `.browse` / `.readContent` / `.manage` 对 App Intents 已经比 generic
`HistoryAction` 安全，但对“同用户任意进程”仍太粗。尤其：

- row `title` 与 search `snippet` 可能直接包含 password、token、private message；不能因为它们
  不是 full representation 就称为 non-sensitive metadata；
- `HistoryDetails` 同时包含 current Effective、Canonical、revision summaries 与 occurrence；只想
  “读取现在会粘贴什么”的 script 不应自动得到 Original Capture/lineage；
- `.manage` 把 pin/unpin 与 destructive remove 放进一个 grant；组织历史与删除历史不是同一风险；
- revise 比 organize/delete更复杂：它写入新 immutable revision，需要 exact base token、OCC 与
  binary input；不应随首版 manage 一起开放。

在 V2-05 尚未 scaffold 前，建议 owning spec 将 Local Automation 的 capability vocabulary定为：

| Capability | 允许 | 不允许/说明 |
|---|---|---|
| `browsePreview` | recent/search；返回 opaque locator、bounded title/snippet、types、time、pin state | **仍是content-bearing**，授权文案必须说可暴露复制内容片段；不暗示“仅无敏感metadata”。 |
| `readEffectiveContent` | 读取一个 locator 当前 Effective representations | 不返回 Canonical、旧 revisions、full `HistoryDetails` 或 source lineage；不隐式允许 browse。 |
| `organize` | 首版pin、unpin | 不删除、不revise、不改retention；reorder由`DEC-PY-REORDER`后置。 |
| `deleteItem` | 删除一个明确 locator 指向的 item | 独立 destructive grant；不含 clear-all/clear-unpinned；UI/release需明确 confirmation policy。 |
| `reviseContent` | **后期单独准入**：首版以exact base token只做replace | 独立高风险grant+OCC；basis只给canonical type identifiers、current Effective bytes与token。hide/revert-to-canonical各自经`DEC-PY-REVISE-SUBSET`后置。 |

明确禁止通过 Local Automation 暴露：

- `capture`：避免任意本机进程注入 history、污染 dedup/retention；
- `clear`：bulk destruction；
- `setRetentionPolicy` / `setRetentionPolicies`：产品配置，不是单项内容操作；
- generic `HistoryAction` / arbitrary command name：会让未来新增 app-only action 自动变成外部能力；
- raw audit-admin/grant-admin：external caller不能给自己授权、清审计或执行recovery-only audit rebase；
- direct SwiftData query、predicate、transaction或 raw row access。

如果当前 V2-05 capability 先于本建议落地，迁移不能把既有 `.manage` 自动升级为
`deleteItem`/`reviseContent`，也不能把 `.readContent` 自动解释成 full lineage继续开放；应 revoke
到最小能力并让用户重新确认。当前它仍是未实现设计，最便宜的时机是 scaffold 前先改 owning spec。

owning V2-05 §0.2 现已冻结 closed allow-matrix，而不是只增加 shared enum cases：

| Connection kind | 可grant/调用 | 必须拒绝 |
|---|---|---|
| `.appIntents` | 既有`.browse -> recent/search`、`.readContent -> details/pastePayload`、`.manage -> pin/unpin/remove`，并保留manage-implies-browse | 全部local-only capability/operation与未知pair；除非另有App Intents amendment |
| `.localAutomation` | `browsePreview`、`readEffectiveContent`、`organize -> pin/unpin`、`deleteItem` | App-Intents-only details/pastePayload/manage、capture、clear、retention/admin、generic action、未知pair及尚未准入的revise |

Gateway以durable connection kind与typed operation权威检查；adapter/request不能自报kind绕过。新增enum case
必须让closed switch/source gate失败，不能因“类型可构造”自动对所有connection开放。

而且“复用 V2-05”不等于Python已可调用Gateway。2026-08-22 owning决策已关闭内部形状矛盾：不实现audit
hash/chain或tamper-evidence claim；用typed codec、transaction内sequence mint、contiguous retained suffix与
`compactionFloor`诚实表达边界；GrantRow是一对connection/capability一条current-state row，re-grant更新该行，
event history进audit；global rebase/compact没有connection/capability attribution；audit无off-switch。
X.3–X.6已依次交付schema/bootstrap、audit/admin、denial、positive Gateway与connection-bound facade；
X.7又在PR #16交付App Intents composition。仍不存在的是Local Automation credential、authenticated
ingress、`clipyctl` executable与transport，所以这些landed in-process事实不能升级成Python可用claim。

## 4. Wire identity：外部只看 opaque locator/token

[`HistoryItemID`](../../../Sources/HistoryCore/Identity.swift) 的 raw UUID 可读但 initializer 是
package-only；[`ContentVersion`](../../../Sources/HistoryCore/Identity.swift) 也由 Storage mint；
[`HistoryPageCursor`](../../../Sources/HistoryCore/Requests.swift) 的 payload 完全是 package-only、
process-local implementation detail。Python wire 不应把“public getter”误解成“冻结 raw encoding”。

Gateway 应拥有三种 wire value：

1. **Item locator**：Gateway mint 的 opaque、versioned string；脚本只能比较、保存和回传，不能
   解析或自行构造。它应在 item 生命周期内跨 CLI invocation 稳定；item 删除/store reset后返回
   typed not-found/invalidated。其内部映射到 `HistoryItemID`，但 UUID/encoding不是 contract。
2. **Content token**：绑定 locator + exact Effective Content state；`reviseContent` 必须携带它，
   Gateway内部还原为 `ContentVersion`并走既有 OCC。token stale时保留 caller draft并返回 conflict，
   不做last-write-wins。
3. **Page cursor**：绑定 connection、完整 query shape、snapshot/generation与limit的短期 opaque token；
   app/store generation变化后 typed expired。它不是item locator，不能被 mutation 接受。

locator/cursor parser、bounds、version、credential binding或 server-side mapping都藏在 Gateway
implementation。先用伪造、截断、跨connection、跨query和restart fixture选择最小实现；不能为了
“opaque”直接引入永久 locator table或通用 token framework。删除这一 module 后如果 raw IDs、cursor
payload与validation重新散入 CLI/App Intents/未来 adapters，才说明它通过 deletion test。

## 5. Connection、credential 与同 UID threat model

### 5.1 新增一种明确的 enrollment kind

不要把 Python 混进 V2-05 的共享 `.appIntents` connection。新增：

```text
ConnectionEnrollKind.localAutomation
```

它代表“同一effective user account（same EUID）可经第一方 `clipyctl` 发起的本机程序访问”，不是某一个 script。第一次
enable 时只创建 durable connection 与 credential，grant set 仍为空；用户随后逐项打开
`browsePreview`、`readEffectiveContent`、`organize`、`deleteItem`，`reviseContent` 后期另开。
Disable/revoke 后，下一次 authoritative recheck立即拒绝。

credential 的最低要求：高熵、connection-scoped、可 revoke/rotate、不出现在 argv/env/log/audit，
且只能在 gateway ready 后使用。到底由 same-team Keychain、owner-only file还是 signed CLI 与 app
之间的 enrollment handshake承载，必须由 Developer-ID + Sandbox/TCC 实验证据决定；Review不能凭
API 名称替平台作保证。credential 证明“请求属于被 enroll 的 localAutomation surface”，**不证明
是哪一个 Python program**。

### 5.2 same UID 是刻意接受的风险，不是漏洞修复后的残余

UDS 的 `getpeereid` 可以验证 effective UID/GID；它本身不验证code signature。某个chosen
XPC/签名校验方案能否证明first-party `clipyctl`必须由signed artifact实测与一手契约支持。即使能证明
CLI，也无法把其上层父进程可靠归因到某个 `.py` 文件：多个同用户 caller最终都由同一个CLI发request。
若用户的 threat model包含“同一账户下恶意进程”，
“任意 Python”与“每个 script 隔离”本身冲突。

产品必须在 grant UI 明说：启用后，同一用户下能执行 `clipyctl` 的任何本机进程都可能使用这些
capabilities；`browsePreview` 也可能泄漏内容片段。更强隔离只能选择 signed per-client enrollment、
单独 bearer credential或用户逐次确认，届时就不再是零配置任意 Python。

root、已控制用户会话的 malware、读取进程内存或全磁盘的 attacker不在此 capability model可解决的
范围；不要用audit metadata或socket mode宣称抵御它们。

当前`project.yml`没有App Sandbox，store又在用户Application Support范围；本轮没有证据表明Gateway能阻止
hostile same-UID进程绕过IPC直接读写store family。即使以后改到app container，`0700/0600`也只隔离其他
UID，不自动成为同UID机密性边界。若威胁模型要求抵御这类进程，必须另裁决sandbox、signed helper、
Keychain-held encryption key与derived projection/cache泄漏面；这会与“任意同用户Python零摩擦”形成真实
trade-off，不能靠bearer grant文案抹平。

## 6. Design It Twice：四种 private transport

比较的前提是 public interface 始终为 `clipyctl`；下面只决定 CLI 到 running Clipy 的私有
adapter。App Intents落到已绑定connection的facade；Local Automation落到受限public
`AuthenticatedIngressFacade`，由其把bounded peer evidence、opaque credential和request委托给同一个internal
`ExternalGateway`完成authenticate/connection resolution/live grant。各adapter绝不自行实现 grant、audit 或
History mutation。

| 方案 | Python/CLI reachability | cold start | 身份与授权 | binary | 架构代价 | 判断 |
|---|---|---|---|---|---|---|
| app-owned UDS + LaunchServices ready | Python只需启动CLI；native CLI直接连 byte stream | transport本身不launch；CLI用 LaunchServices启动 app，再有界等ready | `getpeereid`只证same EUID；另需localAutomation credential + gateway grant | 最直接；必须自定义checked framing/backpressure | 一个app内listener/connection task；无需第二writer | **首个判别spike**：先用ad-hoc-signed F0A只证mechanics；Developer ID与最终transport选择仍后置。 |
| Apple Events + `sdef` | CLI可发native event；Python也可借`osascript` | local `tell` request/reply可hidden launch | Automation TCC明确存在，但responsible sender/per-script identity未知；仍需Clipy grant | native descriptor可bytes；`osascript`文本/size contract弱 | script command bridge、TCC UX、dictionary/versioning | 适合窄AppleScript adapter；不优先承载大history protocol。 |
| App Intents/App Shortcuts + `shortcuts` CLI | Python可调用系统CLI，但按shortcut显示名，不是bundle/action-ID RPC | extension/foreground modes有系统lifecycle；Clipy main-process cold path仍未证明 | shared App Intents connection；无documented per-script identity | `IntentFile`可传data，但多representation会变manifest/file protocol | 符合既有V2-05，但CLI contract受Shortcuts collection/name影响 | 保留为用户可见automation surface；不作为稳定 `clipyctl` 底层RPC首选。 |
| XPC / NSXPC + signed CLI | Python间接调用native CLI；不能用stdlib直解opaque XPC | launchd lifecycle强 | EUID/PID/code-signing requirement强；仍需gateway grant | 原生Data/typed serialization | app-bundled private XPC不能给外部CLI；Mach service/LaunchAgent会逼近Authority ownership重构 | 只有signed bridge topology与single-writer proof明确优于UDS时采用；不因“更原生”先加第二进程。 |

### 6.1 推荐结论

1. **先规格化 `clipyctl` JSON/exit-code shape，不先shipping实现。** 文档、golden examples与pure
   wire contract可以先冻结；parser/executable代码必须等Gateway/AUTO-2与已接纳App Intents tracer闭合后
   才落。这样transport spike可替换，Python script不随平台实验重写。
2. **第一项 runtime experiment用ad-hoc-signed、non-sandbox F0A artifact + app-owned UDS +
   LaunchServices cold-start/ready handshake。** 它只判别bounded same-EUID socket mechanics、cold/warm
   lifecycle与`SIGKILL`残留恢复；不回答Python、Gateway、credential或Developer ID是否成立。
3. **不把这次 spike 自动升级为 final architecture。** 若发行最终开启 App Sandbox，矩阵应分别测
   Terminal/IDE/venv/launchd Python能否启动packaged CLI、caller sandbox是否阻断子进程，以及
   first-party `clipyctl`能否连接app。Python不直接访问private socket；Apple的 App Group资料也不能
   单独证明这条完整链路成立。
4. final signed/sandbox matrix复验已选transport；若 UDS 在该矩阵不成立，回到`DEC-PY-TRANSPORT`，优先保持
   `clipyctl` contract不变并替换 private transport；
   选择 Apple Events、App Intents或XPC取决于 TCC、cold launch、payload和 single-writer实测，不向
   Python暴露 fallback 顺序。

这是一处真正的 seam：至少有 UDS spike adapter 与测试loopback adapter；若未来替换为XPC，caller
仍不变。不要为四种候选同时提交四套 production transports。

### 6.2 F0A 的精确证据合同

F0A不是缩小版`clipyctl`。main-app listener仅由`CLIPY_UDS_F0`编入手工dispatch signed-runtime
artifact；`ClipyUDSF0Client`是XcodeGen诊断tool，只复制进该次proof app。normal Debug/Release既没有
listener，也没有nested tool或产品CLI。

其private request固定25 bytes：ASCII `CLIPYF0Q`、version `0x01`、16-byte nonce。reply固定53
bytes：ASCII `CLIPYF0R`、version `0x01`、echoed nonce、16-byte per-process generation、big-endian
UInt32 EUID、EGID与server PID。每connection一问一答后关闭，backlog 4，accepted read/write各自2秒
deadline；不解析X.8 JSON，不产生credential/Gateway/History/audit行为，也不建立unbounded task或stream。

Endpoint path按UTF-8最多103 bytes；directory `0700`、socket `0600`、lifetime advisory lock `0600`。
live connect成功不得unlink；只有持锁时`ECONNREFUSED`且两次`lstat`仍为同owner socket、同device/inode
才可清理；shutdown只移除bind后记录的同device/inode。client永不删除path。cold client以自身executable
位置定位proof app，并把`NSWorkspace.OpenConfiguration`的`activates`、`addsToRecentItems`、
`promptsUserIfNeeded`与`createsNewApplicationInstance`都显式设为`false`；LaunchServices completion不作
readiness且不等待，发出launch request后的reconnect共用10秒deadline。cold成功路径必须先观察
absent/refused并至少执行一次后续connect attempt。

同一artifact必须依次证明：cold先失败后launch成功；warm保持同PID/generation；`SIGKILL`留下stale
socket后relaunch获得新PID/generation。runner不能观察的different-UID和交互式no-activation格保持open。
因此F0A通过也只说明这个ad-hoc-signed non-sandbox artifact的UDS mechanics成立；Developer ID/team、
timestamp/notary/Gatekeeper、Sandbox/App Groups、Keychain sharing、TCC、caller matrix与production adapter
都未成立。

## 7. Cold start、ready 与 shutdown contract

`clipyctl` 不能把“进程存在”当成“history可用”。下面是production方向，不是F0A fixed hello；只有
authenticated ingress与credential custody关闭后才可实现：

```text
connect private endpoint
  -> endpoint absent/refused
  -> LaunchServices请求启动Clipy（不承诺无激活，先实测）
  -> bounded backoff
  -> hello(protocolVersion, clientNonce)
  -> server只有在store startup + gateway config/grant/audit validation完成后返回ready
  -> request
  -> typed response / deadline
```

约束：

- client不得因为connect失败就删除socket path；它可能属于尚在启动或另一个live generation；
- ready handshake带server generation/session nonce，拒绝stale endpoint/reply；
- startup corruption/open failure必须返回 typed unavailable/data failure，不能新建空history冒充成功；
- timeout只终止client等待；若 mutation 已进入 Authority transaction，不能谎称确定未提交；
- app shutdown先停止accept、拒绝新frame、收束已有request，再移除endpoint；kill/relaunch后旧cursor
  typed expired；
- 第一版不做subscription/watch。长连接事件需要overflow、snapshot replacement、reconnect cursor、
  revoke-mid-stream与audit语义；在request/reply主路径稳定前加入只会扩大状态空间。

## 8. Audit、revocation 与 retry

### 8.1 content read 的 audit contract 已冻结

Owning V2-05 已冻结mandatory publication barrier：每个已admit read先构建immutable
result/failure，再成功append一条durable audit，然后才return/throw。append失败则只返回
persistence failure，不释放DTO/content。crash-after-audit-before-return可留一条caller未观察的
record，但不允许successful/typed return时没有record。该record只证明Clipy已批准并准备
发布response，不证明client完整接收；不引入两阶段分布式事务。

### 8.2 revocation 的线性化点

- write：沿用 V2-05，在 Authority transaction内重新读live grant；revoke先落地则request不能commit；
- read：至少在开始构造/发送 response 前 authoritative recheck。若先完整materialize大content再recheck，
  会浪费敏感bytes与资源；若分段stream，grant失效后已发出的prefix无法收回，因此第一版不做streaming；
- CLI preflight/grant cache永远只是fast fail，不是authoritative proof。

### 8.3 request ID 与 idempotency

read-only tracer可把 `requestID` 只作correlation，安全重试仍受cursor/snapshot规则约束；这不阻断
第一版browse。

任何 mutation 自动retry前必须批准 idempotency contract：相同 connection + requestID 与 exact typed
operation 是返回原receipt、返回alreadyProcessed，还是拒绝duplicate？本规格不增加request digest。
若需要exactly-once effect，dedupe事实必须
与history mutation/audit在同一 Authority transaction durable commit；仅在 CLI memory中记ID不能跨crash，
也不能阻止 timeout后的重复 revise。第一张 write slice可以明确“不自动retry mutation”，把durable
idempotency延后；但不能静默重发。

## 9. 支持类型与 Preview 如何向 Python 清晰暴露

Python 不应靠 hard-coded UTI list 猜“Clipy支持什么”。`describeFormatCapabilities` 当前只冻结为
一个只读、无需history-content grant但仍需enrollment的声明合同；它只能返回各行为owner导出的
immutable Foundation summaries，不扫描用户history：

```json
{
  "schemaVersion": 1,
  "build": { "clipy": "...", "macOS": "..." },
  "unknownFormat": {
    "rawCapture": "subjectToCaptureAdmission",
    "rawPaste": "subjectToCompleteSnapshot"
  },
  "formats": [
    {
      "typeIdentifier": "public.utf8-plain-text",
      "rawCapture": "declared",
      "rawPaste": "declared",
      "title": "exactUTF8",
      "search": "exactUTF8",
      "preview": { "route": "text", "runtimeAdmission": "available" },
      "edit": "exactUTF8",
      "specialRoles": [],
      "multiItem": "snapshotShapePending",
      "evidence": ["FORMAT-UTF8-1"],
      "resourceProfile": "text-v1"
    }
  ]
}
```

这里必须区分两类“支持”：

1. **Opaque round-trip policy**：Clipy可以保留并回写一个合法、自描述的representation，并不表示
   它能理解或预览；这可以覆盖未来 custom UTI。
2. **Semantic handler support**：哪些具体 UTI/conformance 有 text/image/PDF/URL/file/archive 等
   preview、title extraction、edit或thumbnail handler。只有显式列入 code catalog并有fixture的能力
   才能报告。

以 [`08-content-types-and-preview.md`](08-content-types-and-preview.md) 的模型为准：Foundation-only
`ClipboardFormats`只保存stable exact facts；Search、Thumbnail、Preview、Edit与Pasteboard分别拥有自己的
manifest/recipe。build/test `CapabilityInventory`把这些owner声明只读join并检查漂移。它当前严格是
test/build artifact；production projection 的合法 owner/target graph 尚未批准。以 `08` 的
`DEC-FORMAT-INVENTORY-OWNER` 为 hard stop：候选是 ClipyApp composition join owner-exported immutable
Foundation summaries并注入restricted external facade，production owners不反过来依赖中央policy catalog。
若无法合法取得 Edit manifest，首版省略 Edit，不复制一份；Python成为第二个 edit caller前再按 deletion
test提取`ContentEditing` owner。在该owner/injection decision关闭前，golden JSON和pure serializer不构成
runtime endpoint，CLI/Gateway也不得复制一份catalog来提前开放它。

新增格式的agent流程应是：先加stable fact与raw fixture；只在本次确实承诺的owner manifest加入route；
最后inventory/projection反映join后的结果。Capture能opaque round-trip而Preview不支持时，必须诚实报告
`preview.route: none`。Unknown raw fallback仍受concealment/transient marker、complete freeze、
representation/count/byte limits和multi-item shape约束，不能用无条件`genericOpaqueRoundTrip: true`
误导caller。`readEffectiveContent`是Gateway API grant，不是per-format renderer能力，不放在格式entry里。

这也给 Python 一个稳定判断方式：先查询format capabilities，再决定是否读取、显示或提交
`reviseContent`；不要根据扩展名或 Apple UTI conformance在脚本端复制 Clipy policy。

## 10. 最小 module/interface 设计

不需要一个 plugin host、RPC framework或第二个 History boundary。建议的最小形状是：

| Module | Interface | Implementation 隐藏 | 不拥有 |
|---|---|---|---|
| `clipyctl` executable | JSON stdin/stdout + exit codes | app discovery、ready retry、credential use、private frames、typed error mapping | SwiftData、grant decision、History planner、UI。 |
| Local Automation adapter（future approved SwiftPM target） | `start/stop` + one framed request handler | listener lifecycle、frame preflight、kernel peer evidence、backpressure | credential/grant/locator授权、History semantics、第二writer。 |
| authenticated ingress facade（opaque public value） | approved SwiftPM adapter经`package` method提交neutral package-only peer/request DTO与opaque credential | 无policy薄包装，只委托Gateway完成authenticate/resolve/check/execute | credential/connection/grant判断、transport lifecycle、UI、公开Gateway/CredentialStore。 |
| `ExternalGateway`（唯一） | prebound connection request或authenticated ingress request | credential→connection resolution、unknown/revoked denial、validation、rate limit、live grant recheck、audit、opaque locator/token resolution | UI transport details。 |
| `ClipboardFormats` + owner manifests + capability audit projection | stable facts；各owner recipe；只读joined projection | exact identifiers、owner route与runtime/evidence展示 | 中央runtime policy、payload decode、grant、plugin loading。 |

Depth 来自小 interface 后隐藏很多行为：Python只学一个 CLI contract；adapter只翻译transport；Gateway
集中所有安全语义；audit projection让“当前build声明什么”可审计。删除 adapter 后 framing/lifecycle会散回 CLI与
app；删除 Gateway 后grant/audit/validation会散到每个transport；两者都通过 deletion test。反之，若新增
`PythonHistoryService` 只是原样转发所有 `HistoryAction`，删除后复杂度反而消失，它就是 shallow module。

Access level建议：

- public compatibility是 executable wire，不是 Swift `public` type数量；
- future neutral peer/request/result DTO放在`HistoryCore`并保持`package`；不为transport扩张public
  History protocol或symbol snapshot；
- ClipyApp 位于 Swift package 外，不能直接访问 package/internal `ExternalGateway`。HistoryStorage可
  提供一个opaque public facade值，只有approved SwiftPM transport target能调用其`package` execution
  method；ClipyApp只负责构造/传递。facade内部解析connection，不公开Gateway/CredentialStore；
- candidate credential是16-byte connection ID + 32-byte secret，不是hash/digest或derived identity。
  该方向不新增SwiftData schema/secret column；server侧Keychain与client侧custody/access-group/handoff仍是
  `BLOCKED-SPEC`，F0A不携带credential；
- `DEC-PY-AUTHENTICATED-INGRESS`当前是明确的`BLOCKED-SPEC`：它不阻塞in-process Gateway或App Intents，
  但阻塞任何production transport、CLI正向tracer与Local Automation history access；
- socket endpoint、credential representation、framing、locator payload、cursor payload、Gateway内部
  IDs全部internal/package；
- 不新增 `LocalAutomationProtocol`，直到 production UDS与另一个真实adapter都需要同一in-process seam；
  loopback test seam可以留在implementation内部。

## 11. TDD vertical slices

每张卡遵守 [`04-tdd-remediation-playbook.md`](04-tdd-remediation-playbook.md)：先批准 seam，
Red必须能编译且因行为失败，一个cycle只证明一个主要结果；Green只做最低行为，之后单独review/
refactor。不要用mock Gateway/Authority复制安全流程；storage语义用真实 in-memory/temp
`SwiftDataHistory`，跨进程用短命 signed/test helper。

`PY-*` 是设计 epic/crosswalk，不是唯一执行编号；真正领取和完成必须映射到 `04` 的 `PLAY-PY-*`
行为卡。一个 hard-coded CLI response、interface shell或pure serializer不能关闭端到端 epic。

### PY-0 — 规格形状与implementation hard stop

先在 owning V2-05/ADR批准：public CLI version/安装发现规则、`localAutomation` enrollment、
deny-by-default与target graph。此时只冻结文档/wire shape，不先落长期`unsupported` CLI shell；实现必须等
production Gateway positive path与App Intents tracer闭合后才从pure codec开始。compile declaration仍是
non-behavior interface gate，不是Red。`browsePreview` audit选择在首次成功browse前批准；binary
`DEC-PY-READ-AUDIT`在PY-7前批准A/B之一；mutation retry/idempotency在PY-9前批准。编译错误不是Red。

### 已完成的 Batch 6 code leaf — `PLAY-PY-GW0`

`DEC-PY-CONNECTION-ALLOW-MATRIX` 已由 V2-05 §0.2 关闭；Batch 6的第一张Gateway代码卡固定为pure
closed-matrix behavior，不碰schema、audit、Gateway actor、App Intents、CLI或transport：

- 新建 `Sources/HistoryCore/ExternalGatewayTypes.swift`：只声明closed
  `ConnectionEnrollKind`、`ExternalCapability` 与 `ExternalOperationKind` vocabulary；
- 新建 `Sources/HistoryStorage/ExternalAccessPolicy.swift`：一个total pure function返回某个
  `(kind, capability, operation)`是否获准；unknown/cross-kind组合一律false；
- 新建 `Tests/HistoryStorageTests/ExternalAccessPolicyTests.swift`：表驱动覆盖§3 matrix的所有正向pair、
  App Intents现有`manage -> browse` implication、local-only pair对App Intents的拒绝、App-Intents-only
  pair对Local Automation的拒绝、revise与unknown pair拒绝；

GW0合并后不得重复领取；X.2 public Gateway contract也排在当前叶之前。
- 由macOS runner更新
  `Tests/HistoryCoreTests/SymbolSurface/HistoryCore.symbols.txt`，并运行source gates与默认functional tests。

验收上限仅是“closed policy可编译且matrix total”；它不证明真实Gateway在History read前拒绝，也不关闭
`PLAY-PY-B1/B2/B0G`。该leaf不得新增credential、hash/request digest、socket、JSON parser或CLI target。

### 当前 code leaf — roadmap `X.8`

X.1–X.6的Gateway substrate/positive facade以及X.7 App Intents composition均已按各自证据上限landed；
X.7由PR #16、correctness run 32609910701与symbol run 32609018894支持。当前X.8只领取§2.2的
`ClipyCLIContract` pure codec：它可证明bounded parser、deterministic renderer、closed operation与exit map，
但不新增executable/product、process I/O、authenticated ingress、credential或transport，也不能把typed
success fixture说成real Gateway response。因此“Python/Gateway已可用”仍不成立；第一条真实Python→History
claim至少要等X.9解除ingress blocker并通过对应signed tracer。

### PY-1 — 当前安全负对照

第一张 Red 直接穿过真实 in-process Gateway absent/unknown-connection seam：未 enrollment 的 browse 在任何
History read前返回 typed `notEnrolled`，store bytes、position、audit与pasteboard均不变。最低 Green只做
Gateway deny path。只有 production adapter已接入后，CLI exit 3 才是端到端 acceptance；硬编码
`notEnrolled` 的 CLI stub 明确不算 Green。

### PY-2 — JSON contract

Pure Red按§2.2的exact literals逐张覆盖：unknown major、65,537-byte request、duplicate decoded keys、
depth 9/object width 33/array width 513、fraction/exponent/nonfinite/checked-overflow、noncanonical或nil
requestID、unknown operation与unknown field、lexicographic compact JSON＋exactly-one LF、content-free
stderr template及完整exit map。最低Green只完成parser/result/exit mapping，不连接app；不生成request
digest。跨请求重复 requestID 必须被codec接受；它只证明correlation，不提前批准mutation retry。

### PY-3 — Format capability discovery

Red：literal stable facts + owner manifests中text可preview、custom UTI只有有条件raw fallback；
capability projection稳定join且不读history。最低Green只project/serialize纯值 inventory；真实 CLI
`describe` 只有 `DEC-FORMAT-INVENTORY-OWNER`、Gateway与production transport闭合后才验收，不允许把manifest
副本编进CLI。不要同时实现preview decoder或中央policy catalog。

### PY-4 — cold-start browse tracer

Given signed test app完全退出、已enroll但只grant `browsePreview`、temp store有三条synthetic rows。
When Python标准库启动真实 `clipyctl`。Then CLI启动app、等ready、返回三个opaque locators；没有
`readEffectiveContent` grant时内容读取仍exit 3。最低Green只连通一种private transport。

该tracer属于roadmap X.9的B4/B5，不是F0A。证据上限：Developer-ID non-sandbox UDS tracer只证明
该artifact/machine；不证明Sandbox/MAS/TCC。X.10从Effective-only content/organize/delete/revise开始，
不重复领取browse。

### PY-5 — browse 也是敏感内容

Red：row title恰是synthetic secret；无 `browsePreview` grant时response/audit/stderr都不得出现secret；
grant后只在stdout result出现，content-free audit记录operation/count。最低Green不引入“metadata默认
可读”例外。

### PY-6 — opaque locator/cursor

每个行为单独Red：伪造locator拒绝；page cursor换query拒绝；server restart令旧cursor typed expired；
同一个item locator跨两次正常CLI invocation、app cold restart与批准的schema migration仍定位同item，
或 owning spec明确把承诺降为较短 lifetime并返回typed expiry。最低Green只实现已批准最小token机制，
不公开UUID/cursor payload。

### PY-7 — Effective-only content

Seed Original=A、current revision=B。只有 `readEffectiveContent` grant时读取locator；all-types结果恰为B的
全部representations，selected-types请求只返回被点名的exact types与明确missing结果，二者都不包含A、
revision list或occurrence；只有browse grant时仍拒绝。aggregate response超cap必须typed `tooLarge`，不能
partial、截断或静默省略representation。最低Green复用或新增purpose-specific Effective projection，不能调用
`details` 后在CLI层丢字段，因为那已在不必要地hydrate/跨seam暴露lineage。

### PY-8 — binary limits

逐张Red：上限-1/上限/上限+1、NUL、invalid UTF-8 type metadata、half frame、slow sender、disconnect、
inherited-FD invalid/closed/short-write。最低Green在allocation前checked length；失败不得留下partial
output或content log，app不得接受任意caller path。具体执行拆到`PLAY-PY-D2…D8`，本epic不把这些行为
合成一个Green。

### PY-9A — organize

只有 `organize` grant可pin/unpin一个locator；`deleteItem`仍拒绝。不得保留旧`.manage implies delete`捷径。

### PY-9B — deleteItem

独立grant `deleteItem`并remove一个locator，断言没有clear能力、audit与History commit按现有single
transaction语义收敛；不与organize同批实现。

### PY-10 — revoke race

Deterministic park request在Gateway fast precheck之后；in-app admin revoke落地；再释放request。
write必须在Authority transaction内拒绝且无mutation；read必须在已批准的release线性化点前拒绝且
不输出bytes。最低Green复用唯一authoritative grant recheck，不在adapter复制cache。

### PY-11 — timeout 与 mutation retry

第一张cycle冻结“不自动retry mutation”：park write越过/未越过commit线性化点后让CLI timeout，JSON
明确返回outcome unknown或typed transient，CLI不得重发。若之后批准durable idempotency，再另写相同
requestID与exact typed operation跨crash只产生一个commit/audit并返回原receipt的Red；不把内存set称exactly-once。

### PY-12A — reviseContent stale（后期）

前置是独立grant、wire draft与purpose-specific`readRevisionBasis`已批准。Basis只返回canonical type
identifiers、current Effective representations与content token，不返回Original bytes/旧revision list。
首版draft只允许replace；hide/revert-to-canonical与旧revision revert分别后置。
Red：读到content token V1，另一路先revise到V2，再提交基于V1的Python draft；返回stale conflict，
draft可由caller保留，history仍V2。不得把revise与first read-only release合并。

### PY-12B — reviseContent fresh append

下一独立cycle才用fresh token追加恰好一个revision，验证OCC、audit与receipt；不与stale路径合成一张卡。

### PY-13 — same-user security matrix

短命process分别运行：same UID Python、different UID helper、错误credential、revoke后的旧credential。
只允许same UID + current credential + grant；audit connection统一为Local Automation，不能伪称per-script。
root/malware不是此test要证明的范围。

### PY-14 — transport replacement

同一 CLI contract suite分别跑loopback adapter与chosen production adapter；Python fixtures、JSON与exit
expected完全不变。这个测试证明private transport seam有leverage。不要为了绿色同时shipping UDS/Apple
Events/XPC三套production implementation。

### PY-15 — signed release matrix

这是聚合 gate，不是一张复合 Red。至少拆成四个 evidence cells：A) packaged/notarized app+CLI签名链；
B) cold/warm/退出/崩溃/login lifecycle；C) Terminal/IDE/venv/launchd caller matrix；D) sandbox/TCC
deny/reset与最终transport reachability。四格全绿后才可在产品文档写“任意同用户Python可用”；hosted
socket test最多证明protocol实现。

### Design epic → canonical execution leaf

本节编号不能直接领取；实现与关闭状态只记在 `04` 的最小 `PLAY-*` leaf：

| Design epic | Canonical execution leaf / family |
|---|---|
| `PY-0` | `PLAY-PY-A1` + Gateway substrate=`PLAY-PY-GW0…GW4`（GW0=connection matrix，GW1…4=AUTO-2）；Gateway/App Intent baseline=`B0G/B0I`；纯wire实现再拆`PLAY-PY-A2A…A2I` |
| `PY-1` | `PLAY-PY-B1/B2/B3A…B3C`；真实CLI deny另为`B3`且依赖`F0/F1` |
| `PY-2` | `PLAY-PY-A2A…A2I`，每种parser/stdio/closed-operation行为独立 |
| `PY-3` | pure projection=`PLAY-PY-C1`；production export=`PLAY-FORMAT-G` |
| `PY-4/5` | `PLAY-PY-F0A`只做mechanics；后续transport decision + `F1`后才领取`PLAY-PY-B3/B4/B5` |
| `PY-6` | `PLAY-PY-C2…C5` |
| `PY-7/8` | `PLAY-PY-D1A…D8`，all/selected/aggregate-cap与binary lifecycle分开 |
| `PY-9A/9B` | `PLAY-PY-E1A/E1B`与decision-gated`E2` |
| `PY-10` | `PLAY-PY-E5R/E5W` |
| `PY-11` | `PLAY-PY-E6A/E6B`；批准durable idempotency后才领`E7` |
| `PY-12A/12B` | `PLAY-PY-D9` basis后，`PLAY-PY-E3/E4` |
| `PY-13` | Gateway/ingress negatives=`PLAY-PY-B3A…B3C`，granted positive=`B4`；真实caller/same-user signed cell另属`F3C` |
| `PY-14` | `PLAY-PY-F2`，只有第二个真实adapter需求时才领 |
| `PY-15` | `PLAY-PY-F3A…F3D`与最终聚合matrix；聚合本身不是Red |

一项epic跨多个leaf时，只有所有被批准的leaf闭合才能更新产品claim；反过来，一个leaf也不得用“epic已做”
掩盖尚未验证的transport、signed或grant边界。

## 12. 建议实施顺序

1. **先改规格，不先写transport。** V2-05已加入 `localAutomation`、closed connection allow matrix与
   opaque wire values方向；wire contract可以先冻结。schema/grant/audit integrity形状已由X.3/X.4 owning
   决策关闭；X.3 persistence-only leaf已完成，X.4 spec-first完整audit cases也已冻结，当前只能按该表同批落atomic behavior。
   App Intents既有capability/operation不因Local Automation而改变。
2. **先完成唯一Gateway的in-process trust substrate。** enrollment/grant/revoke/quota/audit/opaque
   locator与Authority recheck先以真实History闭环；按既有V2路线让App Intents成为第一个adapter，不另写
   mutation语义。
3. **实现CLI pure codec。** JSON、exit codes与no-content diagnostics由pure tests锁定，但此时仍不宣称
   Python已连到History。Format discovery只可冻结owner-summary schema；runtime injection owner未批准前
   不实现endpoint。
4. **先跑F0A，再关闭authenticated-ingress blocker，最后做read-only transport tracer。** F0A仅在
   ad-hoc-signed artifact证明cold/warm/stale UDS mechanics，不带JSON、credential或History。随后另行
   关闭opaque facade ownership、server Keychain与client credential custody，才可让一个selected adapter
   连接步骤2同一Gateway并在X.9闭环enroll/deny/grant/revoke/browse；没有write，没有subscription。
5. **再做Effective-only binary read。** 使用已冻结的durable-before-publication audit contract与binary output，绝不复用full details
   暴露lineage。
6. **按风险逐项开放write。** organize → deleteItem；每项独立grant与transaction/audit proof。
7. **最后才考虑reviseContent。** OCC、wire basis/draft、idempotency与stale UX都明确后再准入。
8. **用final signed/sandbox matrix复验已选private transport。** 若UDS证据失败，保持CLI不变并重开
   `DEC-PY-TRANSPORT`替换adapter；
   不把spike sunk cost变成平台假设。

## 13. 明确拒绝的 overdesign 与危险捷径

- 不让Python、CLI、helper或App Intent直接打开/复制/锁SwiftData store；
- 不增加第二Authority、第二writer、network daemon或“为了cold launch”常驻的generic agent；
- 不公开socket path/framing为第二SDK，不支持caller绕过`clipyctl`；
- 不把所有 `HistoryAction` encode成字符串命令，不提供generic query/predicate/SQL；
- 不先做long-lived subscription、event bus、websocket、plugin runtime或per-format dynamic bundle；
- 不以same UID、TCC、signed CLI或credential任一单项替代Clipy grant与save-boundary recheck；
- 不称title/snippet为non-sensitive metadata，不让readEffectiveContent偷偷返回Canonical/lineage；
- 不让organize隐含delete，不让delete隐含clear，不让revise随manage自动获权；
- 不把requestID存在CLI内存就宣称exactly-once；
- 不在macOS 26 signed/Sandbox matrix前把UDS、Apple Events、App Intents或XPC写成已证明最终路线；
- 不为了“未来很多类型”现在建立public plugin ABI。清晰的compile-time catalog + 独立handlers已经能
  提供更高 locality与可验证性。

## 14. 证据地图与支持上限

| Claim | Reason / source | 当前最多支持 | 不能建立 | 下一判别证据 |
|---|---|---|---|---|
| 当前Python不能访问Clipy history | tracked source已有in-process Gateway/App Intents，但无`clipyctl` executable、Local Automation authenticated ingress或transport | 当前source snapshot事实 | future feasibility、真实process I/O或Python-to-History | X.8 pure codec后，X.9 ingress/transport与PY-4 vertical tracer |
| 任意Python可经CLI调用 | Python可启动first-party executable；public contract不依赖Swift bridge | 设计上可行 | signed/sandbox/TCC/cold-start可靠性 | PY-15 matrix |
| UDS F0A值得作为private transport判别器 | `sockaddr_un`路径界限、`getpeereid`与LaunchServices primary contract；详见Apple memo §13.1 | ad-hoc-signed non-sandbox artifact可测same-EUID cold/warm/stale mechanics | Developer ID、credential、Python/History、Sandbox/TCC或final transport | F0A三格后，ingress决策与signed caller matrix |
| XPC不是stdlib Python interface | Apple XPC encoding opaque；需native client | signed CLI可隐藏它 | Python直接实现受支持XPC client | 仅在批准signed bridge后跑X-PY-XPC |
| browse仍可能泄密 | current `HistoryRow.title/search.snippet`直接来自内容presentation | capability必须按content-bearing披露 | 每条title实际都敏感 | synthetic-secret grant test + user UX review |
| details对首版过宽 | current `HistoryDetails`含canonical/effective/revisions/occurrence | Effective-only应是目的型read | 新projection性能/实现必然更好 | PY-7 + G8/resource measure |
| same UID不是per-script identity | UDS/CLI看到OS peer，不看到稳定`.py`身份 | shared localAutomation connection是诚实模型 | 对恶意同用户进程隔离 | 若需求变化，signed per-client design |
| content-read audit实现尚未落地 | V2-05已冻结audit-commit-before-publication | spec支持“successful return必有record” | client完整接收或消费了bytes | mandatory-barrier failure/crash proof |

最终推荐不是“让Python直连一个socket”，而是：**让Python只依赖稳定的第一方 `clipyctl`；让
transport保持private、可替换；让所有外部能力经过一个更细粒度的 `ExternalGateway`；让用户明确
知道同一账户下任意进程能看到什么、能改什么。** 这条路线既满足用户希望从Python修改Clipy的目标，
又保留当前架构最值钱的single writer、typed failure、OCC、grant与audit边界。
