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

当前 tracked source 没有 `clipyctl` executable、socket listener、Apple Events dictionary、
XPC external listener或已经实现的 `ExternalGateway`。根
[`Package.swift`](../../../Package.swift) 只发布五个 library products，另声明
`HistoryPerfRunner` executable target；没有 `clipyctl` target/product。V2-05 自己也仍标为
**design-consolidated, scaffold proof pending**。
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

这个定义有四个重要边界：

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

这让 public interface 与 transport 演进解耦。第一版可以在 Developer-ID、non-sandbox build 上
试 app-owned Unix-domain socket；以后若 signed/sandbox 证据支持 XPC 或 Apple Events 更好，
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

以下只是 interface shape，不是 production code：

```json
{
  "protocolVersion": 1,
  "requestID": "9bd92054-bd3f-4d20-8f8a-5d77aa63b726",
  "operation": "browsePreview",
  "arguments": { "limit": 20 }
}
```

```json
{
  "protocolVersion": 1,
  "requestID": "9bd92054-bd3f-4d20-8f8a-5d77aa63b726",
  "ok": true,
  "result": { "items": [], "nextCursor": null }
}
```

Interface contract 应冻结：

- stdin 恰好读取一个 UTF-8 JSON request；stdout 恰好输出一个 UTF-8 JSON result；
- clipboard bytes、query 与 credential 从不放 argv、environment、stderr 或 audit；
- stderr 只允许 content-free 人类诊断，机器结果始终在 stdout；
- unknown field 可按明确 forward-compatibility policy 忽略或拒绝，但两者必须冻结一种；unknown
  protocol major 必须 fail closed；
- duplicate object key、超深/超宽 container、非有限数字、非整数或越界整数必须在 typed request
  构造前拒绝；本规格不增加request digest或基于原始JSON文本的身份；
- `requestID` 是固定形状、caller-minted 的随机 ID，只作 correlation；是否同时承担 mutation
  idempotency 必须在写能力 slice 前单独裁决；
- 每个 request 有 deadline、最大 JSON bytes、最大 response bytes 与最大 representation bytes；
- CLI version 与 protocol version 分开；升级 CLI 不自动改变 wire semantics。

建议只冻结少量 exit-code classes；详细原因仍在 JSON `error.code` 中：

| Exit | 稳定类别 | 示例 |
|---:|---|---|
| `0` | success | 请求完成；`unchanged` 仍是成功 result。 |
| `2` | invalid invocation/request | CLI 参数、JSON、版本或大小非法。 |
| `3` | denied | 未 enrollment、未 grant、已 revoke、peer/credential 不通过。 |
| `4` | target conflict | locator 不存在、cursor expired、OCC stale。 |
| `5` | transient | Clipy 未 ready、rate limited、busy、timeout。 |
| `6` | Clipy/data failure | typed persistence/invariant failure；不得降成空结果。 |

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

而且“复用 V2-05”不等于Gateway已可调用。2026-08-22 owning决策已关闭内部形状矛盾：不实现audit
hash/chain或tamper-evidence claim；用typed codec、transaction内sequence mint、contiguous retained suffix与
`compactionFloor`诚实表达边界；GrantRow是一对connection/capability一条current-state row，re-grant更新该行，
event history进audit；global rebase/compact没有connection/capability attribution；audit无off-switch。当前代码叶
仍只是X.3 V3 schema/limits/bootstrap，actor/facade/admin均未实现，所以Local Automation仍不能依赖“未来Gateway”。

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
| app-owned UDS + LaunchServices ready | Python只需启动CLI；native CLI直接连 byte stream | transport本身不launch；CLI用 LaunchServices/`open`启动 app，再有界等ready | `getpeereid`只证same EUID；另需localAutomation credential + gateway grant | 最直接；必须自定义checked framing/backpressure | 一个app内listener/connection task；无需第二writer | **首个判别spike**，仅限signed Developer-ID non-sandbox artifact先证明；不是最终承诺。 |
| Apple Events + `sdef` | CLI可发native event；Python也可借`osascript` | local `tell` request/reply可hidden launch | Automation TCC明确存在，但responsible sender/per-script identity未知；仍需Clipy grant | native descriptor可bytes；`osascript`文本/size contract弱 | script command bridge、TCC UX、dictionary/versioning | 适合窄AppleScript adapter；不优先承载大history protocol。 |
| App Intents/App Shortcuts + `shortcuts` CLI | Python可调用系统CLI，但按shortcut显示名，不是bundle/action-ID RPC | extension/foreground modes有系统lifecycle；Clipy main-process cold path仍未证明 | shared App Intents connection；无documented per-script identity | `IntentFile`可传data，但多representation会变manifest/file protocol | 符合既有V2-05，但CLI contract受Shortcuts collection/name影响 | 保留为用户可见automation surface；不作为稳定 `clipyctl` 底层RPC首选。 |
| XPC / NSXPC + signed CLI | Python间接调用native CLI；不能用stdlib直解opaque XPC | launchd lifecycle强 | EUID/PID/code-signing requirement强；仍需gateway grant | 原生Data/typed serialization | app-bundled private XPC不能给外部CLI；Mach service/LaunchAgent会逼近Authority ownership重构 | 只有signed bridge topology与single-writer proof明确优于UDS时采用；不因“更原生”先加第二进程。 |

### 6.1 推荐结论

1. **先规格化 `clipyctl` JSON/exit-code shape，不先shipping实现。** 文档、golden examples与pure
   wire contract可以先冻结；parser/executable代码必须等Gateway/AUTO-2与已接纳App Intents tracer闭合后
   才落。这样transport spike可替换，Python script不随平台实验重写。
2. **第一项 runtime experiment用 signed Developer-ID、non-sandbox Clipy + app-owned UDS +
   LaunchServices cold-start/ready handshake。** 它最直接回答 arbitrary Python、binary、same-UID
   与 single-process Authority 是否能同时成立。
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

## 7. Cold start、ready 与 shutdown contract

`clipyctl` 不能把“进程存在”当成“history可用”。推荐最小状态序列：

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

## 8. Audit、revocation 与 retry 的未决项

### 8.1 content read 的 audit contract 必须单独裁决

当前 V2-05 对read采用“结果与audit分离、best-effort at-most-one”；crash可能让一次已返回content的
read没有durable audit。对 Siri/Shortcuts 这已经被规格诚实接受；对任意同用户process读取clipboard
bytes，是否仍足够必须重新批准。

两个可选 contract：

- **A — 保留 at-most-one。** latency/实现最小，但audit viewer不能保证每次content release都有record；
- **B — durable authorization record before first content byte。** audit transaction失败则不发送bytes；
  record只能声称“Clipy authorized/released a response”，不能证明client完整接收。不要为了宣称
  “read succeeded”引入两阶段分布式事务。

Review推荐在 `readEffectiveContent` release gate 前选择 B 或明确接受 A；不能用现在的“all external
operations audited”一句话掩盖 at-most-one crash gap。`browsePreview` 同样 content-bearing，但可先用
read-only tracer测成本，再决定它与full bytes是否采用相同强度。

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
| Local Automation adapter（app-internal） | `start/stop` + one framed request handler | listener lifecycle、frame preflight、kernel peer evidence、backpressure | credential/grant/locator授权、History semantics、第二writer。 |
| authenticated ingress facade（受限public app-facing seam） | bounded peer evidence + opaque credential + typed request | 无policy薄包装，只委托Gateway `authenticateAndPerform` | credential/connection/grant判断、transport lifecycle、UI、公开Gateway/CredentialStore。 |
| `ExternalGateway`（唯一） | prebound connection request或authenticated ingress request | credential→connection resolution、unknown/revoked denial、validation、rate limit、live grant recheck、audit、opaque locator/token resolution | UI transport details。 |
| `ClipboardFormats` + owner manifests + capability audit projection | stable facts；各owner recipe；只读joined projection | exact identifiers、owner route与runtime/evidence展示 | 中央runtime policy、payload decode、grant、plugin loading。 |

Depth 来自小 interface 后隐藏很多行为：Python只学一个 CLI contract；adapter只翻译transport；Gateway
集中所有安全语义；audit projection让“当前build声明什么”可审计。删除 adapter 后 framing/lifecycle会散回 CLI与
app；删除 Gateway 后grant/audit/validation会散到每个transport；两者都通过 deletion test。反之，若新增
`PythonHistoryService` 只是原样转发所有 `HistoryAction`，删除后复杂度反而消失，它就是 shallow module。

Access level建议：

- public compatibility是 executable wire，不是 Swift `public` type数量；
- `ConnectionEnrollKind.localAutomation` 与 capability DTO若需跨 `HistoryStorage`/`ClipyApp`，按现有
  distinct-concern seam做最小 `HistoryCore` public addition，并更新symbol snapshot；
- ClipyApp 位于 Swift package 外，不能直接访问 package/internal `ExternalGateway`。App Intents可以使用
  已绑定connection的facade；Local Automation在未enroll/unknown credential阶段必须经
  `DEC-PY-AUTHENTICATED-INGRESS`批准的受限 app-facing ingress，由HistoryStorage内部解析connection。
  不得把Gateway/CredentialStore公开，也不得让transport import internal Storage types；
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

### 当前 code leaf — roadmap `X.3`

X.3只新增immutable `HistorySchemaV3`（不修改已shipping V2）、四个Gateway/Audit models、fixed
`ExternalLimits`与bootstrap/validation。exact startup shape是一个config、一个active且display name固定为
`Siri / Shortcuts / Spotlight`的App Intents connection、zero grants、zero audit；既有config缺connection或
identity/display/status不匹配均fail closed，不silent repair。只有config absent且三类dependent rows全空时可在同一
bootstrap transaction创建config+connection；该shape与未来V3四类Gateway rows被全部删除同形，无法区分，故只
claim可拒绝“config absent + surviving dependent row”，不加marker/hash。

X.3不实现`OperationPayloadBlobV1`或operation literal cases：V2-05 §4.4现有片段是non-executable historical
skeleton；X.4必须先冻结完整closed request/result cases（含每个admitted admin operation），再同一leaf落codec+
atomic audit。X.3也不实现registry/admin、Gateway actor、facade/factory、App Intents、CLI或transport。
GrantRow冻结为每pair一条current state；re-grant未来更新该行，event history归audit；global rebase/compact的
connection/capability为nil；config不保留write-only generation。任何“Python/Gateway已可用”claim仍不成立。

### PY-1 — 当前安全负对照

第一张 Red 直接穿过真实 in-process Gateway absent/unknown-connection seam：未 enrollment 的 browse 在任何
History read前返回 typed `notEnrolled`，store bytes、position、audit与pasteboard均不变。最低 Green只做
Gateway deny path。只有 production adapter已接入后，CLI exit 3 才是端到端 acceptance；硬编码
`notEnrolled` 的 CLI stub 明确不算 Green。

### PY-2 — JSON contract

Pure Red逐张覆盖：unknown major、oversized stdin、duplicate object keys、超深/超宽container、
非有限/非整数/越界number、invalid-shaped requestID、unknown operation、stdout恰一个JSON值、stderr
无request/query/content。最低Green只完成parser/result/exit mapping，不连接app；不生成request digest。
跨请求重复 requestID 的行为留给 PY-11/idempotency裁决，
不能在尚未决定其语义时直接拒绝。

### PY-3 — Format capability discovery

Red：literal stable facts + owner manifests中text可preview、custom UTI只有有条件raw fallback；
capability projection稳定join且不读history。最低Green只project/serialize纯值 inventory；真实 CLI
`describe` 只有 `DEC-FORMAT-INVENTORY-OWNER`、Gateway与production transport闭合后才验收，不允许把manifest
副本编进CLI。不要同时实现preview decoder或中央policy catalog。

### PY-4 — cold-start browse tracer

Given signed test app完全退出、已enroll但只grant `browsePreview`、temp store有三条synthetic rows。
When Python标准库启动真实 `clipyctl`。Then CLI启动app、等ready、返回三个opaque locators；没有
`readEffectiveContent` grant时内容读取仍exit 3。最低Green只连通一种private transport。

证据上限：Developer-ID non-sandbox UDS tracer只证明该artifact/machine；不证明Sandbox/MAS/TCC。

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
| `PY-4/5` | `PLAY-PY-F0/F1`后领取`PLAY-PY-B3/B4/B5` |
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
   决策关闭；当前先完成X.3 persistence-only leaf，再由X.4 spec-first冻结完整audit cases并同批落atomic behavior。
   App Intents既有capability/operation不因Local Automation而改变。
2. **先完成唯一Gateway的in-process trust substrate。** enrollment/grant/revoke/quota/audit/opaque
   locator与Authority recheck先以真实History闭环；按既有V2路线让App Intents成为第一个adapter，不另写
   mutation语义。
3. **实现CLI pure codec。** JSON、exit codes与no-content diagnostics由pure tests锁定，但此时仍不宣称
   Python已连到History。Format discovery只可冻结owner-summary schema；runtime injection owner未批准前
   不实现endpoint。
4. **先关闭authenticated-ingress blocker，再做read-only transport tracer。** Developer-ID non-sandbox
   UDS + LaunchServices ready只是首个候选，
   必须连接步骤2同一Gateway，先闭环
   enroll/deny/grant/revoke/browse；没有write，没有subscription。
5. **再做Effective-only binary read。** 先批准`DEC-PY-READ-AUDIT`所选合同与binary output，绝不复用full details
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
| 当前Python不能访问Clipy history | tracked source/manifest无CLI/transport/gateway implementation；当前X.3仅schema/limits/bootstrap | 当前source snapshot事实 | future feasibility | PY-1/PY-4 vertical tracer |
| 任意Python可经CLI调用 | Python可启动first-party executable；public contract不依赖Swift bridge | 设计上可行 | signed/sandbox/TCC/cold-start可靠性 | PY-15 matrix |
| UDS适合private CLI→app binary | POSIX byte stream + `getpeereid`；详见Apple memo §5 | non-sandbox私有transport首选spike | arbitrary sandbox caller一定能执行CLI或CLI一定可连接 | signed三类caller matrix |
| XPC不是stdlib Python interface | Apple XPC encoding opaque；需native client | signed CLI可隐藏它 | Python直接实现受支持XPC client | 仅在批准signed bridge后跑X-PY-XPC |
| browse仍可能泄密 | current `HistoryRow.title/search.snippet`直接来自内容presentation | capability必须按content-bearing披露 | 每条title实际都敏感 | synthetic-secret grant test + user UX review |
| details对首版过宽 | current `HistoryDetails`含canonical/effective/revisions/occurrence | Effective-only应是目的型read | 新projection性能/实现必然更好 | PY-7 + G8/resource measure |
| same UID不是per-script identity | UDS/CLI看到OS peer，不看到稳定`.py`身份 | shared localAutomation connection是诚实模型 | 对恶意同用户进程隔离 | 若需求变化，signed per-client design |
| content-read audit当前不完整 | 当前V2-05 reads明确at-most-one | 只支持best-effort audit | crash后每次bytes release必有record | `DEC-PY-READ-AUDIT` A/B decision + corresponding proof |

最终推荐不是“让Python直连一个socket”，而是：**让Python只依赖稳定的第一方 `clipyctl`；让
transport保持private、可替换；让所有外部能力经过一个更细粒度的 `ExternalGateway`；让用户明确
知道同一账户下任意进程能看到什么、能改什么。** 这条路线既满足用户希望从Python修改Clipy的目标，
又保留当前架构最值钱的single writer、typed failure、OCC、grant与audit边界。
