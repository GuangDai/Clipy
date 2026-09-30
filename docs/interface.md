# 应用界面与捕获

## 应用组合与窗口

[`ClipyAppMain.swift`](../ClipyApp/Sources/ClipyAppMain.swift) 是 SwiftUI 入口，应用作为菜单栏 agent 运行。真实状态项、浮动 `NSPanel`、预览窗口和全局召唤快捷键由 [`AppDelegate.swift`](../ClipyApp/Sources/AppDelegate.swift) 管理。默认全局快捷键为 ⇧⌘C；设置中可录制新组合、重试注册或恢复默认。

面板支持鼠标位置、状态项、屏幕中心与上次位置。尺寸由 [`PanelGeometry.swift`](../ClipyApp/Sources/UI/PanelGeometry.swift) 和 [`PopupPositionGeometry.swift`](../ClipyApp/Sources/Panel/PopupPositionGeometry.swift) 在可用屏幕范围内计算；用户调整的稳定尺寸持久化，内容高度随当前内容缩小，持久高度用作上限。面板外单独的浮动预览也必须按屏幕可用区域布置。

应用组合打开成功后预创建隐藏的面板与预览窗口，供后续召唤复用。准备只创建窗口和 hosting 树，不启动历史观察、不读取预览载荷，也不提前显示或强制布局。打开面板仍负责观察与会话；退出应用时释放隐藏和已显示窗口的 hosting 树。

面板有搜索、类型与置顶过滤、列表、上下文操作和底部状态。置顶项目保留用户排列；列表滚动触发相邻页读取，同时仅保留有限分页窗口。设置内的历史工作区有自己的查询、选择、分页和详情，不改浮动面板状态。两个界面访问同一个 History 实例；删除、清空、修订后的失效清理同时传达给相关界面。

## 捕获生命周期

[`PasteboardObserver.swift`](../Sources/PasteboardAdapter/PasteboardObserver.swift) 默认每 0.5 秒在 MainActor 轮询系统剪贴板 `changeCount`。首次启动可以导入当前完整代次；用户从暂停恢复时先将当前代次当作基线，因此暂停期间复制的内容不会因恢复而被补抓。

[`PasteboardAdapter.swift`](../Sources/PasteboardAdapter/PasteboardAdapter.swift) 冻结同一次复制的系统项目和所有保留表示形式，再检查代次是否变化。空组成项目、无法完整取得的声明载荷、资源超限等产生明确结果，不能把不完整读取伪装为成功捕获。来源应用及自身写入的 lineage 提示随原始字节交给 History，不直接决定存储身份。

[`AppComposition.swift`](../ClipyApp/Sources/AppComposition.swift) 只保留一个正在提交的捕获和一个可替换的最新待提交捕获。更晚观察替换 pending 值，避免无界字节队列。捕获忽略名单、暂停状态和访问授权在进入此队列前判断。界面只保留失败类别与计数，不把拒绝的敏感内容存入长期错误状态。

用户可暂停 5 分钟或手动恢复。系统睡眠与登录会话不活跃独立地停止新观察；恢复活动后由同一个捕获 owner 重新基线 / 启动。访问拒绝有明确恢复状态和 Retry，不能靠界面显示默认“运行正常”掩盖读取失败。

## 选择、复制与快捷键

键盘导航与鼠标 hover 有明确输入模式。箭头或快捷键选择后，静止光标下的旧 hover 不立即抢回选择；真实鼠标移动才重新接受 hover。查询 / 分页 / 删除变化按项目 ID 和版本重整选择，详情、Quick Look 与预览不能继续复制已失效目标。

复制路径先按项目 ID 读取当前 Effective 内容，再同步写入 NSPasteboard。一个应用复制槽只允许一个 active 请求，不排队重复 Return / 双击。写入明确成功后才执行成功 UI 行为；历史读取或系统写入失败保持面板可见并显示失败。应用写入剪贴板与另一个进程之间没有跨进程原子事务承诺。

| 默认面板快捷键 | 行为 |
| --- | --- |
| ⌘F | 搜索焦点 |
| ⌘1 / ⌘2 / ⌘3 | exact / fuzzy / regexp |
| Return | 复制当前选择 |
| Delete | 删除当前选择 |
| ⌘P | 置顶 / 取消置顶 |
| ⌥⌘↑ / ⌥⌘↓ | 置顶区内移到顶部 / 底部 |
| ⌘I | 详情 |
| Space | Quick Look |
| ⇧⌘P | 显示 / 隐藏预览 |
| ⌘R | 当前允许重试的预览 |

快捷键定义及冲突检查在 [`PanelShortcutSettings.swift`](../ClipyApp/Sources/UI/PanelShortcutSettings.swift)。编辑文本时 Delete、Space 等保留正常输入作用。快捷键是否可用取决于当前界面、选择和操作状态。用户可以启用保持打开，使面板在成功复制后继续显示。

预览面板获得焦点后，Esc 先关闭信息浮层或 Quick Look；没有这些浮层时，关闭预览和整个历史列表。输入法组合、文件确认和原生 sheet 保留各自的取消行为。信息浮层也提供 SwiftUI 关闭按钮。

## 查询、详情与修改

[`HistoryViewState.swift`](../ClipyApp/Sources/UI/HistoryViewState.swift) 持有当前 query、filter、sort、观察任务和三页窗口。搜索输入在 20 ms 内合并，输入时立即退役旧行；显式 Clear / refresh 立即重启请求。所有异步读结果在应用前检查 request generation、取消和版本，较晚返回的旧请求不得覆盖新状态。替换查询加载期间保持窗口高度，收到权威结果后在下一轮 MainActor 调整内容高度，不额外等待固定计时器。

详情按需读元数据，表示载荷在用户选择预览、导出或打开时单独读取。复制来源分页独立于主列表。编辑器通过 [`ReviseEditorDraft.swift`](../ClipyApp/Sources/UI/ReviseEditorDraft.swift) 生成完整修订决策，提交带用户编辑基于的 `ContentVersion`。冲突明确反馈，不覆盖并发新内容；无字节变化不创建空修订。详情告诉用户原始内容和旧修订仍然保留，直到保留策略或删除回收。

[`HistoryListDragSource.swift`](../ClipyApp/Sources/UI/HistoryListDragSource.swift) 与 [`HistoryRowDragRegion.swift`](../ClipyApp/Sources/UI/HistoryRowDragRegion.swift) 提供拖出数据，表示形式导出和打开分别由 [`RepresentationExporter.swift`](../ClipyApp/Sources/Export/RepresentationExporter.swift) 与 [`HistoryExternalOpener.swift`](../ClipyApp/Sources/Export/HistoryExternalOpener.swift) 执行。外部动作由用户明确发起，预览自身不自动打开应用或链接。

## 设置与内存

[`ClipySettingsView.swift`](../ClipyApp/Sources/UI/ClipySettingsView.swift) 包含常规、历史、外观、快捷键、保留、自动化、交互和维护。常规处理启动登录与捕获隐私；外观处理密度、位置、预览、字体与十档动画速度；保留读实际持久配置并在可能删除数据前确认；维护显示逻辑用量和估算文件夹占用、备份与存储路径。设置草稿读取有自身 generation，较晚 readback 不能抹掉用户已输入的更改。

动画默认第 10 档最快，第 1 档最慢。面板、预览和 Quick Look 使用 SwiftUI 过渡，共用出现曲线与小幅缩放，十档保持相同动作，搜索及过滤按钮采用更短的按压反馈；系统 Reduce Motion 关闭自定义动画。原生窗口外壳负责现有定位、跟随、焦点与系统事件，窗口位置与尺寸立即应用，关闭及失效内容清理不等待动画。时长设计、官方资料和测量范围见 [motion-performance.md](motion-performance.md)。

缩略图和应用图标只缓存可重建结果。 [`ThumbnailStore.swift`](../ClipyApp/Sources/UI/ThumbnailStore.swift) 同时限制条目数和实际像素字节；可见图片持有独立像素 Data，冷数据放入 `NSCache` / `NSPurgeableData`。系统内存压力会取消不必要加载、丢弃冷缓存或停止预取，不把缓存当作权威内容。预览和缩略图细节见 [formats-preview.md](formats-preview.md)。
