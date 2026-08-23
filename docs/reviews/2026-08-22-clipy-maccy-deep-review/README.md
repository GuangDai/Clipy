# Clipy × Maccy 深度复审（2026-08-22）

> 目的：审查当前实现是否正确、是否忠于权威规格、是否具备可发布的
> macOS 产品闭环，以及哪些最小改进最有可能让 Clipy 在其支持平台上真正
> 超过 Maccy。

## 审查基线

- Clipy：`codex/v2-implementation@cda2ba0a4a25264ce7855ee5ae71ef60b8252501`。
- Maccy：`master@818f03d0e0d3912e1ea23657e2630902ebf5cc8b`。
- Maccy 的 tracked source 与 2026-08-20 旧审查相同；当前 dirty tree 只有
  `CONTEXT.md` 和未跟踪 Markdown，没有未提交源码、配置或 workflow。未跟踪设计
  只作为意图参考，绝不计为产品能力。
- 审查开始时 Clipy 工作树干净。本目录是本轮唯一预期新增物；没有修改实现、
  测试、workflow、manifest 或既有规格。
- 本机不是 macOS，不能本地运行 Xcode/SwiftData/AppKit。源码结论来自当前树；
  平台语义来自 Apple 一手资料；运行结论只引用精确 CI run 或明确标为待验证。

## 当前结论先读

1. 当前 `cda2ba0` **不是 CI-green**：run
   [32348271453](https://github.com/GuangDai/Clipy/actions/runs/32348271453)
   在 SwiftPM functional/perf-helper 编译阶段失败；最近同范围绿色 head 是
   `2ff4d2a` / run 32321062928。不能再用 `cc59aa8` 的旧 run 为当前代码背书。
2. Clipy 的 Domain/Authority/codec/OCC/dedup 基础仍明显强于 Maccy；本轮没有
   发现需要推翻单写者、纯 planner、稳定业务 ID 或 byte-confirmed dedup 的理由。
3. 当前产品仍未超过 Maccy。最严重的新问题包括：修订编辑器的 “Keep” 会恢复
   Canonical、真实 copy/capture flow 无顺序和背压、query/preview/pagination task 会跨
   generation 或 session 污染状态、macOS 26 pasteboard access 未建模，以及 search、
   thumbnail、migration/R3 路径缺 aggregate resource 证明。已有库 singleton、Signature
   Index 与 recovery 还有高影响但需损坏或边界条件触发的 fail-closed 缺口。
4. 8 月 20 日旧报告中的 BMP/GIF UTI、HEIF primary index、private Settings
   selector、`_NSAlertPanel` 和 CI filter EOF 等窄问题已有源码修复；本报告不会
   把它们原样重复为现存缺陷，而是审查修复后的残余边界。
5. “超过 Maccy”不应等于复制 Maccy 的 40 个设置、service locator、resident
   object graph、fingerprint-only cache、裸 App Intent 或 unsigned updater。正确路线
   是保留 Clipy 的深内核，补上少数高杠杆用户路径，并用真实 signed app 证明。

## 报告索引

- [`00-executive-review.md`](00-executive-review.md) — 决策结论、最高风险和建议顺序。
- [`01-findings.md`](01-findings.md) — 当前实现的详细 correctness/spec/platform findings。
- [`02-maccy-product-comparison.md`](02-maccy-product-comparison.md) — 当前功能、架构、
  产品力矩阵；该借鉴与该拒绝的 Maccy 模式。
- [`03-target-direction.md`](03-target-direction.md) — 收敛后的目标边界、产品优先级、
  性能与发布方向，以及明确不做什么。
- [`04-tdd-remediation-playbook.md`](04-tdd-remediation-playbook.md) — 后续 agent 可直接
  执行的分层 Red → Green → Refactor 流程和回归矩阵。
- [`05-evidence-and-open-questions.md`](05-evidence-and-open-questions.md) — 证据上限、
  CI/测试盲点、同机 A/B 设计与仍需真机回答的问题。
- [`06-architecture-deepening.md`](06-architecture-deepening.md) — deep-module/deletion-test
  审查、三套 Clipboard Flow 设计与避免过度抽象的收敛结论。
- [`07-python-local-automation.md`](07-python-local-automation.md) — 面向任意same-EUID Python
  的本机自动化边界：稳定 `clipyctl`、私有 transport、capability、OCC、审计与分层 TDD。
- [`08-content-types-and-preview.md`](08-content-types-and-preview.md) — 开放世界 raw 保真、
  可审计格式能力目录、独立 `ContentPreview` 深模块、首期格式矩阵与逐格式 TDD。
- [`09-tiered-storage-and-unbounded-history.md`](09-tiered-storage-and-unbounded-history.md) —
  当前驻留真相、四类资源账本、淘汰/按需读取、conditional content depot，以及解除固定条数
  上限前的 O(N)、崩溃、GC、ENOSPC、迁移和 soak 门槛。
- [`10-implementation-status.md`](10-implementation-status.md) — REVIEW 的唯一活实现账本：逐 leaf
  记录 Done/Partial/In progress/Open、production path、测试与 CI 证据及支持上限，后续 agent 先查此表，
  避免重复领取已关闭行为。
- [`11-ai-todo-map-2026-08-23.md`](11-ai-todo-map-2026-08-23.md) — AI 生成的时点审计与待办地图
  （2026-08-23，基线 `cda2ba0` → `a3e6774`）：对照本 REVIEW、实现树与真实 CI 记录汇总当前状态、
  新发现问题与仍 Open 的分区待办。它不是活账本，也不是执行来源（不新增可领取 leaf）；状态与
  执行仍以 `10` 与 owning spec 为准。
- [`apple-platform-source-memo.md`](apple-platform-source-memo.md) — Apple 官方文档
  逐项备忘录。
- [`apple-swiftdata-durability-memo.md`](apple-swiftdata-durability-memo.md) — SwiftData
  transaction、WAL/external storage、migration、recovery、backup 与 CloudKit 默认值的
  一手资料边界。
- [`apple-python-automation-source-memo.md`](apple-python-automation-source-memo.md) —
  Apple Events、App Intents、Shortcuts CLI、XPC、Unix socket 与 sandbox 的自动化证据边界。
- [`apple-pasteboard-type-system-memo.md`](apple-pasteboard-type-system-memo.md) —
  `NSPasteboard` 多 item、provider、object API、UTType 与 raw round-trip 的一手资料边界。
- [`apple-preview-source-memo.md`](apple-preview-source-memo.md) — ImageIO、Quick Look、
  HTML、PDF、AV 与 file-backed Preview 的平台事实和未知项。
- [`apple-pasteboard-preview-security-memo.md`](apple-pasteboard-preview-security-memo.md) —
  多 item 与高风险 renderer 的安全反审、支持分级和准入实验。
- [`apple-tiered-storage-source-memo.md`](apple-tiered-storage-source-memo.md) — SwiftData
  `.externalStorage`、fault/batch、文件 I/O、缓存/内存压力、容量、备份与大规模历史的证据边界。

本轮架构深挖已直接纳入上述 Markdown REVIEW；按要求没有生成 HTML 报告，也没有修改
产品源码。后续 agent 应从本索引进入，以 `00` 确定优先级、以 `01` 定位事实、以 `04`
执行单行为 TDD，再按 `06`–`09` 的 interface 边界实施；研究 memo 只限定证据，不直接授权功能。

## 执行编号与权威性

- [`04-tdd-remediation-playbook.md`](04-tdd-remediation-playbook.md) 是本报告唯一执行来源。前半保留
  legacy `Card 0…17`，新增 Python/Formats/Storage 使用 `PLAY-*` namespace；领取时必须把来源与最小
  leaf 固定成唯一 issue key。一个 Green 只关闭该 leaf 写明的 observable behavior。
- `07`–`09` 的 `PY-*`、`FORMAT-*`、`PREVIEW-*`、`PB-MULTI-*`、`DESIGN-TIER-*` 是设计分解或 epic，必须
  映射到一张或多张 `PLAY-*` 卡，不能仅凭章节勾选宣称实现完成。
- Apple memo 中的 `MEMO-*` 是 characterization / 平台证据实验，不是功能授权，也不是产品
  acceptance。
- REVIEW 不能覆盖 `docs/` 的 owning spec。凡改变 public surface、durable schema、产品语义、target
  graph 或 V2-06 P3 合同的卡，必须先完成对应 spec/AUDIT/roadmap amendment；未批准时状态是
  `BLOCKED-SPEC`，不是“agent 可自行裁决”。
- `TEST-ONLY / BLOCKED-PRODUCTION-SPEC`表示可以在隐藏test feature gate下收集行为/规模证据，但不得进入
  production config/public surface；它与完全不可执行的`BLOCKED-SPEC`不同。
- `PLAY-PY-A`/`PLAY-FORMAT-B` 这类字母标题是 card family，不是可关闭状态；实际领取项必须使用
  文中最小 leaf ID（例如 `PLAY-PY-B1`、`PLAY-COUNT-5A`）或先为唯一 observable behavior补 leaf ID。

## 证据标签

- **Confirmed**：源码、规格或 CI 直接证明；不依赖特定调度运气。
- **Conditional**：存在可构造的错误交错/平台边界，但实际频率待运行测量。
- **Proof gap**：现有证据不足；不能把“未发现失败”写成“行为已证明”。
- **Product gap**：不是当前已声明 slice 的实现违约，但会阻止“全面超过 Maccy”。
- **Do not copy**：Maccy 已有能力或实现，但复制会降低 Clipy 的正确性、安全或
  可维护性。

每项建议都需经过两个问题：不做会损害正确性/主路径/发布吗？最小方案能否通过
可判别测试证明？若两个答案都是否，就不进入近期路线。
