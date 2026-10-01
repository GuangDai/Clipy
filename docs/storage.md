# 存储、事务与保留

## 文件布局与配置

默认位置由 [`AppComposition.defaultStoreURL`](../ClipyApp/Sources/AppComposition.swift) 选择：

```text
~/Library/Application Support/Clipy/
├── history.sqlite
├── history.sqlite.lease                     # 稳定的跨进程租约文件
├── history.sqlite-wal / history.sqlite-shm   # SQLite 使用期间
└── history.sqlite-content/
    ├── blobs/<UUID前两字符>/<UUID>.blob
    └── staging/<UUID>.partial
```

每个数据库按自身文件名取得独立内容目录，避免同一父目录中两个存储互相清理。`HistoryPersistence.persistent(storeURL:)` 保留调用者的持久目录；`.temporary` 创建私有临时目录，所有连接和 owner 释放后删除。临时模式使用相同真实 SQLite / blob 实现，不是第二个假写入者。

[`HistoryConfiguration`](../Sources/HistoryStorage/Configuration.swift) 的 `initialMaximumUnpinnedItems` 只用于新存储；默认 200，nil 关闭数量保留，正数没有额外的人为历史总量上限。重开存储读取持久配置。已有不兼容、部分或损坏布局会报错，代码没有旧存储读取、双写、迁移、自动修复或自动删除路径。

预先取消的打开请求不会创建存储文件；启动事务内的取消回滚 schema 和初始记录，允许随后重新打开。写操作入口同样检查预先取消，已有提交的成功回执仍保留。

持久存储打开前获取 [`StoreRootLease`](../Sources/HistoryStorage/StoreRootLease.swift)，同一租约由实际 SQLite 写连接持有，防止多个进程同时持有写入者。外部 facade、自动化 ingress 或清理任务继续持有旧写入者时，释放 `SQLiteHistory` 不会提前释放租约；写连接成功关闭后才释放。应用组合也防止一个进程重复打开同一存储。只读连接不另取写租约，由自身 owner 管理；位置对象让文件至少存活到最后连接关闭。

## SQLite 与内容文件

[`SQLiteDatabase.swift`](../Sources/HistoryStorage/SQLiteDatabase.swift) 使用系统 SQLite3，启用 foreign keys。写连接使用 WAL、`synchronous = FULL` 和 256 页自动 checkpoint；每连接页缓存配置为 4 MiB，SQLite mmap 为 0。读事务用 `BEGIN DEFERRED`，写事务用 `BEGIN IMMEDIATE`。

[`SQLiteHistorySchema.swift`](../Sources/HistoryStorage/SQLiteHistorySchema.swift) 的表按功能分为：

| 功能 | 表 |
| --- | --- |
| 项目、全局位置及逻辑用量 | `history_items`、`history_state` |
| 原始内容 / 不可变修订、表示描述与载荷位置 | `contents`、`representations` |
| 复制来源 | `copy_sources` |
| 保留配置 | `retention_policies` |
| 搜索必要条件索引 | `history_search`、`history_search_terms` |
| 外部连接、授权与操作记录 | `connections`、`grants`、`operation_records`、`gateway_config` |
| History 变更记录 | `history_change_records`、`journal_config` |

标题和搜索正文存成精确 UTF-8 `Data`，读取时严格解码。表示形式不超过 64 KiB 时内联到 SQLite；更大载荷写入 UUID 文件。相同项目中可复用已经字节确认的不可变载荷。复制、修订及读取都保留表示类型拼写、系统项目顺序和原始字节。

[`ImmutableBlobStore.swift`](../Sources/HistoryStorage/ImmutableBlobStore.swift) 先写并同步 staging 文件，再用不能覆盖现有目标的硬链接发布最终文件。文件内容之后不修改。读取检查文件类型和声明长度；区间读取持有同一个 descriptor，以 64 KiB 块读取并检查取消。`mappedIfSafe` 只是系统提示，不能据此声称零拷贝。

## 原子提交与清理

[`HistoryAuthority+TransactionExecution.swift`](../Sources/HistoryStorage/HistoryAuthority+TransactionExecution.swift) 在一个写事务内重新检查位置及外部授权，发布新内容文件，写项目 / 修订 / 搜索索引 / 用量，追加 History 和必要的 Gateway 记录，最后写新的 `ChangePosition` 并提交。这个区间没有 actor suspension。

数据库只在文件已发布后插入引用。事务回滚保留旧内容完整；新文件若失去引用由后续有界清理回收。提交成功后才发布观察失效和安排物理清理，避免未提交的数据进入界面。

删除项目和裁剪修订先把不再拥有的 `contents.itemID` 设为 NULL，使后续读取立即看不到被删除内容。常规物理清理使用既有 `UNIQUE(itemID, revisionOrdinal)` 索引寻找 NULL owner，每批最多访问 32 个内容描述并删除 32 条表示引用。提交这些引用删除后，直接检查本批 blob UUID 的其他真实引用，再删除没有引用的文件，不重新扫描完整内容目录。

启动或文件发布失败后才使用有界 metadata 遍历和 blob / staging 全目录分批扫描，以清理较早布局留下的已无 owner 内容和未知孤立文件；目录每批最多访问 64 个条目。删除引用后的 unlink 失败也会让后续真实清理请求带上孤立文件扫描。没有全库常驻 ID / 签名集合，也不一次性加载全部内容。物理清理不改变 History 位置、逻辑用量或用户操作回执，无需新增 schema index 或迁移。

## 保留语义

数量、年龄、逻辑内容字节和修订阈值分别可关闭。置顶项目不作为自动整项淘汰对象；最近写入的主要项目受当前提交保护。可淘汰项目按 `lastCopiedAt` 升序、项目 ID 升序处理。字节预算按 Canonical 加仍保留修订的逻辑内容计算，不等于 Finder 中文件夹占用；去重复用同一 blob 也不改变这个逻辑定义。

| 配置 | 接受范围 |
| --- | --- |
| 未置顶项目数量 | nil 或正 `Int`，默认 200 |
| 最大年龄 | 1 秒至 3,650 天，要求有限数值 |
| 总逻辑内容字节 | 1 至 2,013,265,920,000 字节 |
| 每项修订数 | 1 至 100 |
| 每项修订字节 | 1 字节至 256 MiB |

修订保留先剪掉最旧的不活跃修订，当前有效修订必须存活。若置顶 / 受保护内容或当前修订使新预算无法满足，操作失败并保持原配置和数据。策略更新在有界准备后重新确认位置，再一次提交所有适用淘汰和修订剪裁；配置与效果原子一致。数量保留与其他维度分别由公开 action 设置，设置界面把它们呈现为同一个保留页面。

## 资源边界与备份

[`HistoryLimits.standard`](../Sources/HistoryCore/Limits.swift) 允许每次捕获 / 修订最多 32 个表示形式；单表示 64 MiB，捕获总计 128 MiB，单次修订总计 64 MiB。每项最多保留 100 个修订、修订总计 256 MiB。存储标题最多 1,024 UTF-8 字节，搜索正文最多 256 KiB。关闭数量保留不解除这些单项资源边界。

[`ThumbnailService`](../Sources/HistoryStorage/ThumbnailService.swift) 按项目 ID、内容版本和像素尺寸合并缩略图请求，读取及解码同时只运行一项，最多保留 32 个尚未真正退出的任务。同一精确键最多有 32 个尚未退出的调用者，所有键合计最多 1,024 个。取消立即撤销需求，但仍在原生解码或版本检查中等待的任务、调用者继续占用预算，直到实际退出。超限返回可重试的 `.temporarilyUnavailable(.thumbnailResources)`，不会记录成图片无法解码。

每个浏览界面的 [`ThumbnailStore`](../ClipyApp/Sources/UI/ThumbnailStore.swift) 同时最多拥有 4 个尚未退出的读取 / 显示任务。正常排队、等待容量及等待行出现的地址共用一个预算，默认最多 500 个；这些地址不持有载荷。容量观察流每个界面只订阅一次，缓冲最新一条真实资源释放通知，只重发仍在显示的失败需求；冷请求在行出现后才恢复。关闭界面或清除会取消订阅和待处理地址。容量通知不改变 `ChangePosition`，不发 History 变更，也不保留已完成缩略图。

[`HistoryAuthority+Backup.swift`](../Sources/HistoryStorage/HistoryAuthority+Backup.swift) 在唯一 writer 的串行区间复制一致 SQLite 快照，清除备份中已脱离项目的内容，并按每批 64 个 blob 引用复制仍保留内容。备份包含 `history.sqlite` 和 `history.sqlite-content/`，先完成并同步 `.incomplete` 兄弟目录，再排他重命名为用户选择的全新目录。

备份不覆盖已有目标，也不能放入会被存储清理 / 临时生命周期删除的内容树内。发布前失败或取消只清理本次临时目录；最终目录已发布后同步失败会保留完整副本，同时不返回成功回执。界面可导出备份；这不构成自动恢复或旧存储迁移功能。
