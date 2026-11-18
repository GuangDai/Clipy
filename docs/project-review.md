# Clipy 全链路审查与修复清单

审查基线为 `fix/clipboard-capture-reliability` 的 `3713000ed026b3bddc828d451fd95796f7cc5bc4`。范围涵盖系统剪贴板、写入与保留、搜索与分页、列表与预览、编辑与回写、设置与备份、App Intents、本地自动化及测试。本文记录待修问题、需要定产品行为的冲突和验收条件。

## 结论和修复次序

剪贴板历史的日常任务是找到一条记得大概时间和内容的记录，看清将要复制什么，再把正确内容交回当前应用。Clipy 在这条路上同时缺少时间线索、稳定的搜索结果、可持续查看的位置，以及统一的键盘动作目标。继续打开多个筛选入口、格式入口和快捷键，增加了用户确认结果所需的操作。启用默认 200 条未置顶上限后，普通新复制还可能打断与淘汰对象无关的详情和编辑。

| 顺序 | 修复目标 | 可以合入的最低验收 |
| --- | --- | --- |
| 1 | 让打开的记录和将要复制的记录一致 | 普通更新、保留淘汰、输入法、候选、预览、文件确认和详情均有明确动作目标。无法继续的编辑仍有草稿去处 |
| 2 | 让搜索可预测并保住阅读位置 | 持续复制时首屏仍出来，正在读的旧页保住锚点，部分命中、零命中、语法错误和暂不可用各有反馈 |
| 3 | 提供可扫描、可筛选的时间 | 主列表直接区分近似条目，完整时间可读。今天和昨天在换日后自动更新，日期筛选和来源组合说明一致 |
| 4 | 保住捕获与原样回写，再处理删除和备份 | 跨应用、慢存储、部分发布、大对象和保留变更都有可预测的行为及反馈 |
| 5 | 收短所有权、删空壳与重复状态 | 以以上真实行为作为回归依据，逐项去除脱离产品入口的模型、测试和文档承诺 |

P1 影响核心任务、草稿、隐私承诺或持久内容。P2 影响特定路径的正确性、可恢复性或日常可用性。P3 属于代码或维护成本。**源码可证**指能从当前实现推导给定输入与顺序下的结果。**平台待验证**指具体事件投递、应用切换或系统回调还需用 macOS 用例确认。**产品决策**指出当前行为已经明确实现或测试，建议先定新的交互契约。

## 一、搜索、查看和时间体验

### S00 · P1 · 默认强制模糊匹配，「自动」把两套排序藏在同一选项里

**基线源码可证。** 应用起动构造两份 `HistoryViewState`，各自以 `.fuzzy` 初始化。切换搜索模式只改当前实例，重启回到模糊。自动次序为置顶手排优先，未置顶项先按 Fuse 分数升序、再按最近复制降序、最后按 UUID。标题只要模糊命中便采用其分数，正文没有参与比较，所以正文里的直接命中也可能排在位置较顺的标题模糊命中之后。固定 Fuse 还使用位置 0、距离 100 和阈值 0.7，这让命中的位置影响评分。显式最近排序则对所有结果按时间重排，置顶也进入同一顺序。 [默认状态](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L159) · [两份实例](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppComposition.swift#L379) · [排序比较](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SearchWorker+Fuzzy.swift#L207) · [先标题后正文](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SearchWorker+Fuzzy.swift#L337) · [Fuse 参数](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SearchWorker.swift#L115)

让「字面搜索」「最近复制」各自成为可见默认。保留模糊和置顶优先为显式选项，标明何时用相关度。验收使用日期有先后、含错字的近似词、标题模糊正文精确、相同时间及置顶项同场比较。旧收藏继续按记录里的模式和排序执行，并覆盖旧版仅保存排序的收藏。

### S01 · P1 · 持续捕获可让查询反复重扫，迟迟给不出首屏

**源码可证。** 观察先订阅失效，再查询一页。每拿到一页，只有当前写入位置与其完全相等时才发布。查询期间有一笔提交，就从头再查。单次搜索快照有时限，外层 `while true` 没有总预算。首次打开、改词和已显示结果后的后台刷新都走此路。库越大、模糊和复杂条件越费时，越容易错过发布窗口。 [观察重查](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SQLiteHistory.swift#L651) · [观察替换](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SQLiteHistory.swift#L431) · [查询资源边界](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SearchWorker+SQLite.swift#L88)

修复时让单个一致快照在有限等待内发布，再合并变更追赶。保持已知提交位置的下限，防止删除或修订后的旧目标重新可操作。验收用查询入场点控制每次查询期间都发生提交，验证首屏有结果、停止写入后追上最后位置、取消后读事务和名额释放。

### S02 · P1 · 一笔无关复制也会把深页阅读拉回第一页

**源码可证。** 面板和工作区把观察页当作整个窗口重新开始，取消正在进行的分页、重置页偏移和上一页状态。按 ID 恢复深页只在初始 `restoreTarget` 路径使用，首个恢复成功后目标即清空。当前条目仍匹配时，后台复制也会让其离开加载窗口，用户需要重新滚回去。它与 S01 共用观察入口，修复点不同。 [按锚点恢复](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L1101) · [观察替换重置窗口](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L1236) · [列表滚动绑定](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryListView.swift#L155)

保留当前首个可见项或明确选中的阅读锚点，将后台新快照在该锚点周围恢复，再提交窗口更新。锚点确实被删或被筛掉时显示明确反馈。验收在第二页以后打开与复制无关的项，连续捕获、跨页来回，验证可见锚点、选中项及邻页均正确，并且分页始终使用同一快照。

### S03 · P1 · 普通保留淘汰按「全部清空」传播，打开的详情和草稿会丢

**源码可证。** 达到默认 200 条未置顶额度后，每个新项目可能淘汰旧项目。存储回执把淘汰压成一个布尔值，应用把任一淘汰映射为 `.all`，并传给另一浏览界面。详情的 `.all` 清理会把无关项目判为移除、关闭编辑，预览也会清理内容和信息层。即使观察已到达提交位置，应用仍发出这条清理事件。 [默认上限](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryCore/Limits.swift#L196) · [捕获淘汰](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryDomain/PlannersCapture.swift#L178) · [回执压缩](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/StampedPlan.swift#L361) · [全量清理](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L1394) · [详情处理](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryDetailsView.swift#L739) · [预览处理](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryPreviewView.swift#L273)

用存储已有的影响范围或对活跃目标做小批量事实核对。分别处理真正删除、有效版本变化、仅旧修订被裁剪。保留仍有效的草稿，目标确实失效时提供恢复草稿的路径。验收在额度已满时以置顶项打开详情并改出未保存文本，再复制无关内容。断言实际受害项消失，两个界面的其他行、搜索、预览和草稿持续可用。

### S04 · P2 · 合法正则能被 `$…$` 外层条件拆坏

**源码可证。** 正则模式按前一个字符是否空白判定 `$` 是否开启条件。模式 `^[ $]$` 的字符类中有空格后跟美元符号，编译器会把这个符号当作起点，再用末尾锚点闭合，最后交给正则引擎的外部内容被截断。 [条件包装拆分](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistorySearchQueryCompiler.swift#L65) · [正则起始边界](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistorySearchQueryCompiler.swift#L136)

补全和编译使用同一个能够保留正则字符类和转义的词法边界。验收覆盖裸正则、附加实际类型条件、转义美元、字符类、字符类内部的转义和未完成条件，从真实历史核对搜索命中。

### S05 · P2 · 一个找不到的应用名让整个 OR 或 NOT 查询消失

**源码可证。** 来源解析器已把无匹配的名称替换为恒假条件。界面仍把未解析名称当成阻断错误，整个表达式从未执行。`$source:不存在的应用 OR report$` 应可保留正文命中的分支，`$NOT source:不存在的应用$` 也有确定含义。名称只扫描已安装应用，卸载后的来源还需精确 ID 入口。 [来源替换](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/SourceApplicationSearchResolver.swift#L93) · [界面入场](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L1194) · [现有提示](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistorySearchFilters.swift#L91)

保留缺少来源的提示，交给求值器处理布尔结果。给用户能选的历史来源，保留精确 ID 查询。验收用真实历史覆盖仅来源、AND、OR、NOT、已卸载来源及名称模糊匹配；提示与结果同时成立。

### S06 · P2 · 浮动列表不显示时间，相关测试却能一直通过

**源码可证。** 主列表的行只有标题、命中摘录、图标和置顶等线索，其悬浮提示和无障碍读法均未接入时间。列表每次构建传入 `Date()`，行保存这个值却没有使用。`HistoryRowRenderingModel` 的相对和绝对时间只被测试直接调用。工作区行只显示月日、时分，常驻可见区域没有跨年份的区分；浮动界面的完整时间需要打开预览信息或详情。 [行布局](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryRowView.swift#L109) · [无障碍标签](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryRowView.swift#L229) · [未接线的渲染模型](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryRowView.swift#L568) · [独立格式化测试](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/PresentationTests/HistoryRowRenderingTests.swift#L14) · [工作区时间](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryWorkspaceView.swift#L772)

给主列表保留一条紧凑的时间线索和可访问的完整时间。可以用日期分组配合行内时分，也可以使用近时相对、远时绝对的格式。长开刷新由可见区域统一拥有，避免为每行建定时器。验收用同标题跨小时、跨日、跨年条目在默认面板和工作区确认可分辨性，检查缩窄窗口和 VoiceOver 标签，并从真实行验证时钟变化。

### S07 · P2 · 今天、昨天和最近 N 天在打开期间失效，两个日期入口还用不同日界

**源码可证。** 图形筛选用本地日界，查询启动时转成绝对区间并被观察捕获。换日及时区变更没有触发重建，后来的捕获仍按旧区间筛选。表达式 `date:` 使用 UTC，图形控件使用本地日期，同一台机器上两处选同一个日期可能返回不同结果。保存的相对条件再次打开会重新计算。当前仍打开时才出现旧日界问题。 [图形日期区间](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistorySearchFilters.swift#L45) · [冻结区间](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L1075) · [观察请求参数](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L1091) · [日期表达式](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryCore/HistorySearchExpression.swift#L419) · [两个日期说明](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistorySearchOptionsView.swift#L125)

看得见的活动查询在换日、时区改变以及睡醒越过日界时重建。图形和表达式的时区规则要统一或始终明确标注，尤其在已应用条件旁。验收覆盖午夜前后、夏令时切换、跨 UTC 日、重放收藏和旧游标失效。`Last 7 days` 当前含今天及之前六个自然日，文案也应明确自然日口径。

### S08 · P2 · 重复复制后，列表和已打开详情可以给出不同的时间和次数

**源码可证。** 折叠复制只更新出现事实，不增加 `ContentVersion`。详情进入时取 DTO，并监听破坏性更新，普通重复复制不会重新读。页中行随观察更新，预览信息则按次数和最后时间触发读取。因此用户从两处能看到同一项目的不同「最近复制」和次数。 [折叠复制](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryDomain/PlannersCapture.swift#L120) · [详情读取和失效](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryDetailsView.swift#L251) · [详情显示](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryDetailsView.swift#L949) · [预览信息重读](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/PreviewMetadataView.swift#L68)

给打开的详情补轻量出现事实更新，保持内容版本与详情草稿。验收详情保持打开，外部两次复制同样内容，确认次数、来源和最后时间随观察一致更新，编辑中的有效内容与基准版本仍正确。

### S09 · P2 · 「来源 + 日期」筛的是项目汇总，可能从未在指定日期由该应用复制

**产品决策。** `source:` 对项目所有保留来源判断，`date:` 对该项目全局最后复制时间判断。周一从 A 复制、周二从 B 复制同一内容，`source:A AND date:周二` 会命中；同样条件改周一会排除这条历史。当前来源表保存各来源首末时间及次数，只有这些汇总值时无法精确回答任意中间日的复制事件问题。 [来源和时间语义](search.md#条件表达式) · [来源按项目筛选](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryFilterSQL.swift#L89) · [来源聚合](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryAuthority+CopySources.swift#L8)

先决定产品要提供项目汇总检索还是复制事件检索。保留汇总时，在界面明确「曾来自 A」与「项目最后复制日期」各自的含义。若要找某天的某次复制，需要独立表达事件或明确支持的时间精度。验收用 A/B 两天及同一来源同月相隔多日分别核对结果和文案。

### S10 · P2 · 用户缺少何处匹配、为何无结果和排序为何变化的信息

**源码可证与产品决策。** 默认模糊模式限制查询长度与可搜索正文长度。正则和精确模式又有不同范围，对用户而言都是在同一个框里搜索。浮动列表会展示正文摘录，历史工作区紧凑模式省略摘录，普通模式也没有应用匹配高亮。显式排序在代码和测试中会全局重排置顶与普通项，搜索说明却仍承诺保留独立置顶排列。 [模式上限和排序说明](search.md#对外语义) · [面板摘录](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryRowView.swift#L127) · [工作区摘录](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryWorkspaceView.swift#L764) · [显式排序合同](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryCore/Requests.swift#L57) · [显式排序验证](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Tests/HistoryStorageTests/HistorySortOrderTests.swift#L100)

在主要搜索区展示当前模式、已应用条件和可清除入口。零命中提示给出具体结果范围和下一步，例如查找完整字面、清除日期、查看全部类型。面板与工作区共享最小命中展示语义。验收在正则/fuzzy 预览范围之后放唯一命中，同词测试不同模式；用相同数据确认面板、工作区、置顶与普通项排序说明一致。

### S11 · P2 · 正在编辑搜索数值，按顶部 Done 会丢掉筛选草稿

**源码可证。** 选项弹层顶部按钮写「完成」，只关闭弹层。真正保存按钮在滚动内容里的来源区之后。「重置」也先只改草稿。在小面板内改日期或排序后顺手点「完成」，屏上既没有明确的取消意图，也没有已应用的提示。 [完成按钮](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistorySearchOptionsView.swift#L35) · [重置与应用](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistorySearchOptionsView.swift#L54)

采用明显的「取消 / 应用」常驻操作区，或即时应用配合可撤销的筛选标签。验收覆盖小高度窗口、日期错误、Escape、鼠标点击到外部和清空筛选，验证可见条件与实际请求一致。

### S12 · P1 · 找得到记录，打开却找不到命中的内容

**源码可证。** 搜索把多个剪贴板子项和表示形式中的文本拼成一份投影。结果只带摘录及相对高亮，没有对应子项、格式或原始偏移。预览独立从第一个可渲染子项开始。同一子项的图片又优先于文本。正文在默认预览长度以后、另一子项或伴随图片的文本中命中时，搜索结果可出现，预览却不给用户看到该处。普通面板行的摘录还预留一段命中前文，窄窗默认一行时可能只显示前文。 [投影拼接](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/ContentProjector.swift#L151) · [结果结构](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryCore/ReadDTOs.swift#L16) · [摘录边界](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SearchWorker+Excerpt.swift#L101) · [预览目标与加载条件](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryPreviewView.swift#L242) · [预览挑选表示](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/PreviewContentLoader.swift#L436) · [格式优先级](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/ContentPreview/ContentPreview.swift#L158)

先给预览一个可复制的「命中上下文」以及明确的展示范围，保证一行也看得见命中。再按实际需要获得版本绑定的子项和表示定位。验收涵盖长正文后半、第二子项、图文混合、宽窄窗口与 Unicode 高亮，并校验复制仍写回完整手势。

### S13 · P2 · 错误和临时失败可同时伪装成零结果

**源码可证。** 首读失败会结束加载，却没获得权威页面。空列表随后可以显示「无结果」或「没有历史」，查询栏也可能把空数组当成 0。另有失败提示，可被关闭。语法错误另外分支处理，面板选中项和独立预览仍可能保持到下一次权威页到达，已处于等待的旧预览有机会在错误出现后打开。 [失败结束加载](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L1151) · [列表空态](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryListView.swift#L305) · [结果数](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/SearchHeaderView.swift#L323) · [预览与权威页](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryPanelView.swift#L682) · [延时预览守卫](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/PreviewPaneState.swift#L623)

为当前查询维护一套共享状态，区分初读、刷新中、确证零命中、语法错误和读取失败。保留旧行期间标明其查询并限制动作，最终失败要取消旧预览的打开意图。验收覆盖已打开和等待打开两种预览，给新查询造成解析失败和暂时读取失败，再修正并重试。两种界面都不得把故障报成 0。

### S14 · P2 · 搜索框能显示的查询比实际执行的查询更长

**源码可证。** 模糊是默认模式。应用把外部文字缩到前 64 个 Swift `Character` 后再查，输入框仍显示余下字符。两段带相同前 64 个字符、只在后缀不同的长文本会发出相同的模糊查询。精确模式还有整体字节预算，正则也只扫描有界正文。界面需要让当前查询边界可见。 [默认模式](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistorySearchDefinition.swift#L14) · [实际查询取前缀](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L578) · [模式入口](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/SearchHeaderView.swift#L341)

保留输入全文并清楚反馈生效的查询，提供主动切换完整字面搜索的操作。验收用前缀完全相同、后缀不同的两条真实历史，检查默认模式、切换模式、重试和收藏重放。翻页按钮也应由下一页语义命名，当前标为「较早」的按钮在最早优先和频次优先下会给错方向暗示。 [面板下一页按钮](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryListView.swift#L289)

### S15 · P2 · 常见的标题加链接组合搜不到链接

**源码可证。** 单个系统项同时含人类可读纯文本标签和有效 `public.url` 时，已有纯文本标题路径不会把 URL 添入搜索正文。只有 URL 或多系统项的路径另有处理。显示可打开的地址、却无法按地址找回是常见任务断裂。仅有 HTML/RTF/RTFD 的富文本也可展示、被归到文本类型，但未纳入当前朴素文本搜索投影，属于功能范围缺口。 [投影与 URL](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/ContentProjector.swift#L165) · [富文本投影入口](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/ContentProjector.swift#L295) · [URL-only 用例](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Tests/HistoryStorageTests/ReferenceSearchJourneyTests.swift#L109)

约定哪些实际可查看字段应可搜索。单项保留标题，同时有界索引有效链接。富文本先定可见范围和成本，避免在 writer 内无限解码。验收同时搜索标题、地址、复制链及富文本可见文字，区别支持范围与实际零命中。

### S16 · P2 · 启动导入和未知来源会改写时间的叙述

**产品决策与源码可证。** 启动可导入系统剪贴板当前值，读取时生成本次时间，并经一般折叠增加次数。同一内容长时间留在剪贴板，重开后的观察可使其看起来刚复制。另一条路径中，未知来源的新捕获推进最近时间，却继承上一已知应用；来源记录仍将本次归到未知，预览摘要和详情把旧应用与新时间并列。 [启动捕获](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppComposition.swift#L1141) · [读取时钟](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/PasteboardAdapter/PasteboardAdapter.swift#L169) · [折叠日期与来源](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryDomain/PlannersCapture.swift#L127) · [真实来源聚合](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryAuthority+CopySources.swift#L8) · [预览时间](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/PreviewMetadataView.swift#L32)

将首次发现与系统观察到的复制区分，重复启动不凭空增加复制次数。一次复制的时间与来源应属于同一个事实，若需保留「最近已知来源」则单独标明。验收用同一持久库、固定时钟和未变化的剪贴板重启，再追加未知来源的新捕获，检查列表、预览、详情与日期筛选。

### S17 · P3 · 常规浏览就为可打开的图片和链接查大量额外信息

**源码可证，耗时待测。** 合格的行一挂载就为「打开方式」准备选项。每行要查版本绑定的表示元数据，最多再逐项读 32 个小 URL，并在主隔离域询问系统默认应用。图片字节没有提前读入。多行挂载时，这些任务与首屏、搜索、预览争用资源。只有项目版本作任务键，系统默认应用以后变化时，该行仍可能引用旧选项。 [行任务](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryRowView.swift#L174) · [准备打开选项](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/Export/HistoryExternalOpener.swift#L54) · [使用保存的应用](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/Export/HistoryExternalOpener.swift#L149)

把小元数据的读取移到打开菜单或明确点击，按当时系统默认处理程序解析。验收确认仅滚动不会读取 URL 或调用 handler，明确打开时重新查版本和默认应用。用混合图片、链接、文本记录测首屏和输入到下一帧耗时。

## 二、看、选、复制与编辑

### V01 · P1 · 原生 Return 与眼前 Quick Look 可以使用不同目标

**源码可证，真实键事件待验证。** Quick Look 保有触发时的精确目标，打开后禁用底下 SwiftUI 列表。原生窗口仍只检查是否在列表根和是否有列表选择，抢在 SwiftUI 前提交 Return。浮动预览和 Quick Look 还可同时存在，鼠标进入旧浮动预览会写底层选择 ID。此时 Quick Look 仍显示自己的目标。文件确认和信息层的键盘限制也有各自守卫，原生判断不消费相同状态。 [Quick Look 精确目标](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryPanelView.swift#L447) · [底层禁用与上层构建](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryPanelView.swift#L755) · [浮动预览同步选择](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/Panel/FloatingPreviewPanel.swift#L556) · [AppKit 入场条件](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppDelegate.swift#L776) · [Return 处理](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/Panel/FloatingPanel.swift#L225)

由一个活跃交互上下文提供可执行的目标，按输入法、原生模态、候选、Quick Look 或详情、列表的优先顺序消费按键。用真实窗口和系统剪贴板验证主窗留焦、侧预览与 Quick Look 指向不同项时只复制上层目标；信息层、文件确认和输入法组合期间不执行后面的复制动作。

### V02 · P2 · 浮动面板单击即复制关窗，工作区却是单击选中

**产品决策。** 浮动行单击直接复制，默认无障碍激活动作也是复制。工作区单击用于系统式选择，有独立复制操作。浮动列表可以用悬停与快捷键查看，但鼠标用户很容易把「试着选中看看」变成修改全局剪贴板并关闭面板。在同一产品里这两个相同手势成本差别很大。 [面板单击和 AX 激活](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryRowView.swift#L173) · [工作区行为](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryWorkspaceView.swift#L738) · [当前明确验证单击复制](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyUITests/ContentFirstRowJourneyUITests.swift#L62)

给两处一致且可见的查看入口，让复制是可预期的明确动作。若保留单击速取模式，标清效果并配置为用户可选。验收只用鼠标和只用键盘各做一次「浏览两个相似项后复制」，浏览阶段系统剪贴板保持先前值。

### V03 · P2 · 延迟悬停可以把键盘选择改回鼠标已离开的行

**源码可证，原生经路待验证。** 列表只提交进入行事件。键盘模式挂起一个悬停 ID，没有离开事件清除；恢复鼠标模式就应用该 ID，未校验鼠标此刻所在行和现有结果。快速跨到空白、搜索更新或弹层关闭后，旧 ID 仍可能被用。 [悬停入口](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryListView.swift#L270) · [键鼠切换](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryPanelView.swift#L395)

使用同一份当前鼠标命中状态，进入、离开、行退役和查询切换都更新它。验收覆盖方向键选中 B 后鼠标从 A 移到空白、滚动引发行卸载以及鼠标停住的更新，按 Return 验证真实复制对象。

### V04 · P2 · 「保持打开」与成功复制后的行为有冲突

**源码可证，产品决策。** 接线给所有成功回写无条件 `closePanel()`，状态机随后结束会话并重置保持打开。使用说明承诺保持打开时复制后继续显示。测试覆盖失焦时保持及显式关闭的行为，尚缺这一动作组合。 [成功回调](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppDelegate.swift#L1221) · [保持打开测试](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyIntegrationTests/PanelKeepOpenAndStatusMenuHostedTests.swift#L177) · [交互说明](interface.md)

明确保持打开覆盖哪些关闭原因。验收保持打开分别开启和关闭，验证复制成功后的窗口、焦点、查询、预览和系统剪贴板。复制失败应保留现场以便重试。

### V05 · P2 · 大原件可捕获、可隐藏类型，但不能走「恢复原始」

**源码可证。** 捕获总量可达 128 MiB，提交修订提议总量上限 64 MiB。一条合法的超过 64 MiB 多格式记录可以通过隐藏某个格式变小，随后「恢复原始」会把原件全部表示重新送入 64 MiB 提议检查并拒绝。连字节无变化的判断也发生在该检查以后。 [捕获与修订上限](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryCore/Limits.swift#L188) · [恢复原件入口](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryDetailsView.swift#L1026) · [恢复组装及限额](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/RevisionPreparationAndSearchCorpus.swift#L308)

先判实质无变化。恢复考虑直接复用已保留的原始不可变载荷，同时明确修订计量与重开读取约束。若有额度冲突，编辑前展示可恢复性。验收通过注入缩小等比例上限的实库走捕获、隐藏、恢复、回写和重开，原始字节全程一致。

### V06 · P2 · 详情把暂不可用、版本变化及真正移除混为表面结果

**源码可证。** 详情对有渲染容量限制、格式损坏、超限和无支持预览的情况可能返回相同 `metadataOnly`。该状态按已完成处理，第一次再点击只关闭。读取到同一 ID 的新版本也可能走「项目已移除」路径。不同原因需要不同选择，用户应知道能否重试、切格式还是重新确认新内容。 [详情重新选择](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryDetailsView.swift#L604) · [读取版本后的分支](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryDetailsView.swift#L692) · [详情渲染映射](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryDetailsView.swift#L1407)

保留类型化状态，用稳定的失败原因驱动重试、更新到新版本、保存草稿或关闭动作，和独立预览共享用户语义。验收通过可控容量占用、修订和删除三种情况，打开同一详情并检查可见状态和后续操作。

### V07 · P1 · 用户确认的内容版本在异步回写中丢失

基线向复制传递精确引用，组合入口却按 ID 取当前内容，直接写系统剪贴板。若正在查看 v1，写入者在读取前提交 v2，复制会悄悄写 v2。拖出已经从同一读取返回值核对引用。修复时将同等版本检查用于复制，过期则提示重新确认。验收真实提交修订、使用旧命令确认剪贴板完全不变、使用新引用写入新字节。保持已获得的不可变快照身份，提交发生在读取之后时仍按本次已确认的字节完成。 [复制取载荷](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppComposition.swift#L1281) · [拖出版本检查](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L788)

### V08 · P1 · 工作区的 Done 和浮窗外层关闭能静默丢弃草稿

编辑器自身 Cancel 与 Escape 调用有修改检查。工作区外层 Done 直接撤掉详情，浮窗失焦、外点和召唤键也能直接结束会话。保护只覆盖内层按钮。让用户发起的离开共享现有草稿确认，锁屏、退出等系统边界另定驻内存草稿与隐私行为。验收输入未保存文本后按工作区 Done、外点或召唤键，再选择继续编辑或丢弃，核对退出过程中正在保存的回执。 [编辑器的检查](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/ReviseEditorView.swift#L473) · [工作区外层 Done](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryWorkspaceView.swift#L175) · [浮窗失焦](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/Panel/FloatingPanel.swift#L344)

### V09 · P2 · 报错框偶发反转，已确定有方向跳动及遮挡风险

**用户观察，字形倒置或颜色反相的根因待验证。** 主窗和 Quick Look 只有正数缩放和透明度。侧窗动画每帧用当前左右方向计算水平偏移。屏边或窗口移位令方向在动画中翻转时，仍未展开完的内容会从一个方向跳到另一方向，错误占位也会跟着跳，字形不会被代码镜像。搜索候选覆盖层还可能盖住下面的错误行，过多根通知可能挤掉低窗的列表空间。涉及原生弹层时，错误触发点及具体控件仍待定位。 [动画变换](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/AppMotionSettings.swift#L122) · [侧窗跟随](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/Panel/FloatingPreviewPanel.swift#L204) · [候选与搜索提示](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/SearchHeaderView.swift#L64) · [堆叠通知](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/Panel/PanelRootView.swift#L34)

验收记录出错文字、触发动作和切边前后连续帧。分别覆盖语法错误、搜索读取失败、复制失败、预览读取失败和启动恢复。使用小屏、系统暗色与浅色、减弱动态效果和普通动画，检查文字方向、视觉及点击区域和关闭恢复。不要把捕获权限与原生「打开失败」窗口合并成同一个原因。

### V10 · P2 · 预览工作量上限止于载荷，界面仍可卡顿或一直占位

- 解码临时拥塞被缩略图展示层直接消费，只有存储报容量满才登记容量恢复。保持挂载且引用不变的行可能持续占位。应在同一显示需求预算内处理可重试失败。 [显示解码](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/ThumbnailStore.swift#L443) · [重试队列](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/ThumbnailStore.swift#L494)
- 预览放开长度限制时，文本渲染先为大量换行建立分段和分组，惰性 SwiftUI 容器接手时这些分配已发生。编辑超大文本时又在主隔离域按完整原文比较脏状态，粘贴后先编码全部再触发存储上限。用分段读取或紧凑偏移处理实际工作量，编辑器先检查实际额度。以大文本起落、末尾编辑、撤销和峰值内存验收。 [分段](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/ContentPreview/PreviewText.swift#L19) · [惰性容器](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/PreviewTextBody.swift#L16) · [编辑比较](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/ReviseEditorDraft.swift#L95) · [完整编码](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/EditorTextCodec.swift#L87)
- 文件和普通文字或图标在同一系统项时，默认渲染可能挑了文字或图像，显式读取文件入口随之消失。给各表示形式明确选择，不替用户读文件。验收通过带有效 `file-url` 和路径文字或图标的系统项，先查看默认表示，再显式选择地址、确认后读文件，复制照旧返回完整手势。 [格式选择](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/ContentPreview/ContentPreview.swift#L171) · [读文件条件](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/PreviewContentLoader.swift#L91)

## 三、捕获、版本、保留与持久化

| 编号 | 基线问题 | 修复及可观察验收 |
| --- | --- | --- |
| C01 · P1 | 首次授权绕成一圈。处于 `.default` 或 `.ask` 时，后台不读。「重试」只查权限元数据。Apple 说明应用触发首个程序读取提示后才会进入相应系统设置。现有 GUI 权限用例注入姿态，真实首次交互待验证。 [权限闸门](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/PasteboardAdapter/PasteboardObserver.swift#L168) · [重试](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppComposition.swift#L807) · [Apple 权限说明](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/default) | 增加明确由用户发起的权限设置动作，过程中不入库，后续读由权限控制。用干净 macOS 用户验证首次提示、拒绝、允许、撤回和恢复。 |
| C02 · P1 | 来源忽略名单承诺永不记录，代码却在读完载荷后拿当时前台应用作来源。切焦点或等待 provider 可以错分，未知来源也允许入库。 [采样](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/PasteboardAdapter/PasteboardAdapter.swift#L367) · [忽略判断](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppComposition.swift#L899) · [承诺](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/CapturePrivacySettingsView.swift#L71) | 保留每代次最早可用的来源证据，提前排除确定来源，说明不确定与未知来源。做切换前台、延迟发布、真实存储及工作流断言。 |
| C03 · P1 | 部分发布修复只封住一次冻结期间的声明变化。「完成」后同代次不再重读，随后新增的项目、类型或隐私标记漏掉。已有兄弟表示时，空字节占位也可当成完成。 [冻结](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/PasteboardAdapter/PasteboardAdapter.swift#L286) · [同代次状态](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/PasteboardAdapter/PasteboardObserver.swift#L188) · [完成分支](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/PasteboardAdapter/PasteboardObserver.swift#L276) | 设计有界稳定规则，区分永远为空和待发布，结合已知搁置临界点。测跨 poll 新增声明、空变非空、隐私标记以及最终只提交一份完整字节。 |
| C04 · P2 | 永久不可读的某个表示能触发长时间重读全部兄弟载荷，即使这些载荷已完整。待发布、已放弃、隐私排除和不支持的临时提示也容易残留。磁盘不足时会丢掉整个待写队列，当前只记一次失败。 [重试](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/PasteboardAdapter/PasteboardObserver.swift#L308) · [磁盘满](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppComposition.swift#L1025) | 以未完成位和声明变化优先判断，再做一次完整冻结。按真正丢失条目计数并保留可理解的原因。使用大兄弟载荷和真实 provider 比较调用次数、主线程耗时及告警恢复。 |
| C05 · P1 | 外部复制 A、把历史改成 B、外部再复制 A 时，原始字节匹配可让 A 折叠到 B。它只变更 B 的最近时间和次数，列表、搜索与复制仍是 B。行为符合现有 Canonical 合同，最新实际复制无法从该条取回。 [候选选择](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/FactLoaders.swift#L299) · [折叠](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryDomain/PlannersCapture.swift#L120) | 确定普通外部合并至少要求 Effective 覆盖入站字节，或为 A 保留独立记录。用真实捕获、修订、再捕获、查询、回写检查 A 和 B 各自取回。有效 lineage 的精确绑定应保留。 |
| C06 · P2 | 当焦点和系统剪贴板仍可操作时，旧的复制等待载荷读取，可能覆盖其间完成的较新外部复制。清空与捕获队列也分别提交，清空成功后旧排队记录可重新出现。 [复制等待](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppComposition.swift#L1289) · [队列排空](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppComposition.swift#L1040) · [清空](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryViewState.swift#L848) | 明确较新用户动作及清空的截止顺序。以受控等待验证外部复制优先与清空前后分别入场，一致性证明延伸到重开。 |
| C07 · P1 | 部分持久库只剩 blob 文件时，打开缺失的 SQLite 会创建空库。随后的启动扫描把旧可恢复载荷视为孤儿删除。非规范定位符也可能使维护比读取先触发不可逆结果。 [写连接](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SQLiteDatabase.swift#L76) · [建库](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SQLiteHistorySchema.swift#L61) · [启动扫描](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SQLiteHistory.swift#L247) · [引用检查](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryAuthority+BlobCleanup.swift#L83) | 初始化前检查整个存储布局。遇到不完整布局或定位符损坏，保全现有内容并说明原因。实库含 blob、移走或以零字节替换 DB、启动应拒绝，恢复主文件后原字节可取。再覆盖格式错误引用。 |
| C08 · P1 | 放宽年龄或其他保留策略也可能删记录。设置只对新阈值更严格弹窗；只要年龄仍启用，提交会重算当前时间下的过期条目。 [UI 确认](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/RetentionSettingsTab.swift#L573) · [淘汰计算](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/RetentionPolicySweep.swift#L124) | 对可能删除的实际操作确认，同一个提交边界检查条件。用可控时钟验证久未捕获、放宽年龄、取消及确认一次提交，检查已置顶条目和配置。 |
| C09 · P2 | 数量限制为 1，置顶 A、捕获 B、取消置顶 A 后可长期存在两条普通记录。UI 承诺最多保留。 [取消置顶](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryAuthority+PlacementMutations.swift#L78) · [置顶位移](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryAuthority+PinRelocation.swift#L80) | 明确接受、淘汰或拒绝以及用户如何获知。在一次事务更新配置约束与视图，覆盖 App、外部入口和重开。 |
| C10 · P2 | 索引只筛候选。多个富内容有相同纯文本时，纯文本复制会在唯一 writer 逐条加载整份内容确认，连不比较的图像也读。200 个各含 64 MiB 的候选可造成约 12.5 GiB 逻辑读取，实测 I/O 和时长未知。 [候选遍历](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/FactLoaders.swift#L251) · [加载确认](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SQLiteCaptureConfirmation.swift#L52) | 先用元数据排名，验证必要键的真实字节再停止。保留碰撞、错误与胜者规则，以不同大型伴随表示、冷缓存和等待的捕获测工作量。 |
| C11 · P1 | 备份在唯一 writer 串行复制 SQLite、压缩、逐块复制和同步目标盘；慢盘阻塞正常捕获，入口有界队列满后丢新值。发布后若目标父目录同步失败，完整副本仍在，设置却报无法保存并不提供位置。 [备份](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryAuthority+Backup.swift#L46) · [发布](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryAuthority+Backup.swift#L121) · [设置结果](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/HistoryBackupSettingsModel.swift#L27) | 在同一位置确定 SQLite 快照和引用寿命，然后独立处理慢目标盘。区分未发布与已发布但耐久性待确认。控制慢 I/O 验收备份期间新捕获、备份位置及恢复。 |
| C12 · P2 | 备份复制 FTS 内容无存索引的页。SQLite 内容无存删除表可用墓碑延后移除词元，项目把一至三个 Unicode 标量转成索引词元。SQL 搜索已过滤的片段，在未合并的备份索引中仍可能存在。 [备份压缩](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryAuthority+Backup.swift#L151) · [词元编码](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/SQLiteSearchIndex.swift#L186) · [SQLite 删除合并说明](https://www.sqlite.org/fts5.html#the_deletemerge_configuration_option) | 备份内从保留投影重建索引或显式合并并验证词元回收，保持源库与正常搜索。用独立样本核对被删索引片段和保留项目搜索，范围为片段。 |

公开存储 API 的同进程重复打开也需复核。`fcntl` 租约按进程持有，应用组合有默认路径的进程内保护，单独调用库入口未受同等保护。要保住唯一 writer 与观察一致，测试须覆盖真正写连接和仍持有旧对象时的再次打开。来源键做 NFC 规范合并，精确筛选和建议词表按原始字节，边界输入的后一份真实来源可丢失。普通系统标识多为 ASCII，此项优先级低于 C02。 [租约](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/StoreRootLease.swift#L23) · [应用保护](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/AppComposition.swift#L486) · [来源键](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryAuthority+CopySources.swift#L8) · [精确匹配](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/HistoryFilterSQL.swift#L165)

## 四、应用自动化与运维反馈

| 编号 | 基线问题 | 修复及验收 |
| --- | --- | --- |
| A01 · P1 | 新安装时六个 App Intents 有登记连接、无授权。所有操作都要求有效授权，设置只提供 Local Automation 授权。测试成功路径直接对存储授权，跨过用户实际无法完成的步骤。 [初始化](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/GatewayBootstrap.swift#L73) · [操作鉴权](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/GatewayAuthorization.swift#L272) · [预授测试](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyIntegrationTests/AppIntentTestSupport.swift#L59) | 保留默认拒绝，给 App Intents 独立的用户授权与撤销。验收从全新库、产品设置、实际系统捷径执行到撤销和重开。 |
| A02 · P1/P2 | 两个窗口编辑工作流时，旧窗口能保存已删除或停用的旧规则。工作区保存了基线，写入却按 UUID 用整对象覆盖，没有比过基线。 [工作区](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/BuiltInAutomationWorkspace.swift#L95) · [保存](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/UI/BuiltInAutomationModel.swift#L35) | 提交时比较真实基线，冲突保留草稿，让用户重载或存为独立的手动规则。模拟真实偏好从两处编辑、关闭自动执行及删除，旧草稿不可恢复副作用。 |
| A03 · P2 | 自动通知检查规则后还等待系统授权。期间删除规则，旧任务仍可调用通知。普通复制也可能第一次触发请求授权。 [规则检查](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/Automation/BuiltInAutomationExecution.swift#L259) · [通知权限](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/Automation/BuiltInAutomationNotifications.swift#L8) | 权限申请跟自动动作分开，异步返回后在最终副作用前重新核对规则。控制授权等待，在其中编辑、删除或关闭规则，验收零旧通知。 |
| A04 · P2 | 每次撤销再启用都登记新连接，撤销的连接与 verifier 仍占名额，登记上限为 500（也含预置连接）。客户端凭据丢失时，设置刷新报错而此前监听仍可能继续，运行状态缺少解释。 [撤销](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/GatewayAdministration.swift#L507) · [注册](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/LocalAutomationEnrollment.swift#L59) · [上限](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/ExternalLimits.swift#L70) · [刷新](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/LocalAutomationController.swift#L149) | 定义有界退役且旧身份永久失效。分别呈现凭据异常和监听状态。用真实库跨上限重复启停、重开及撤销，验证被撤连接始终拒绝。 |
| A05 · P2 | 工作流历史预览内层以剪贴板子项计数，外层以历史行计数。一行含两个匹配项，只复制第一项时却可能没有提示。`clipyctl read --raw` 也先受整条记录 24,000,000 字节返回预算限制，再在客户端挑单一表示；小文本伴随大图时可能导不出文本。 [历史工作流](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Sources/Automation/BuiltInAutomationExecution.swift#L169) · [全部读取](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/GatewayExternalReads.swift#L274) · [CLI 选择](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tools/clipyctl/CLIArguments.swift#L101) | 明确匹配子项与匹配记录两种口径。原始导出在授权后按精确表示做有界投影。验收同一手势含多个子项和大格式、小文本，实际选择以及反馈一致。 |
| A06 · P2 | 外部请求计数触发审计压缩。压缩在唯一 writer 遍历并解码全部保留记录，即使无需删一项。设置读取也会写审计，走不同触发路径，用户的捕获可排在串行开销后。 [触发](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/ExternalGateway.swift#L297) · [压缩](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/GatewayAuditStore.swift#L200) · [设置读取](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Sources/HistoryStorage/GatewayAdministrationReads.swift#L13) | 维护前用有界事实判断是否需要裁剪，保住事务检查。测量包含实际授权与追加的使用场景，同时观察捕获与搜索的尾延迟。 |

## 五、代码为何难改

| 热点 | 现在的成本 | 收敛方向 |
| --- | --- | --- |
| 查询状态与分页 | 模式、原始输入、解析条件、来源解析、日期、已展示旧行、可执行行、观察和页各有代次。`HistoryViewState` 基线 1,520 行，单个 setter 就能重启观察。换日与背景写入新增边界时容易让窗口、读屏和命令各取一份真相。 | 用同一个已接纳查询值启动观察和分页，由其持有模式、过滤、快照位置及可执行状态。显示旧行只是一种状态，明确其所对应的查询。 |
| 仓库按层分开，产品判断依旧重复 | AppKit Return、原生搜索框、各 SwiftUI 容器与侧窗各有动作目标守卫。列表、工作区、详情和预览另有时间、失败、筛选和资源预算。 | 收敛同一动作及视觉状态的拥有者，复用可见时间、命中和错误展示。异步结果必须晚于用户意图的判断点才允许覆盖。 |
| 存储的独占写入范围过大 | 去重读大 blob、纯元数据高选择性过滤、备份慢 I/O、部分审计维护都挤在唯一 writer。返回行数和队列长度有界，后台耗时仍可能让正常复制丢失。两份关系校验读取器也会随 schema 同步修改。 | 保留事务规划、引用发布和位置提交；重复的纯校验共享，按用途保留不同 SELECT。把一致快照与慢 I/O 分开；测真实页、等待时间、读字节和首帧。 |
| 测试与产品入口脱节 | 时间格式化原本测试的是无生产调用的模型，剪贴板主旅程的旧夹具查询前后均为两条，UI 语法失效也可绿。固定源码/文案、调试计数和手写 SQL 镜像让测试多却难找失败。 | 合并重复，强测试要有区分信号。在同一真实旅程里改变条件、页面、选择和剪贴板字节。把 AppKit 焦点、SQLite 原子性、编码和取消的独立证明保留在负责它的层。 |
| 隐藏的维护设计 | 搜索查询注释及存储中可找到旧任务代号、已下线 SwiftData 所有权、无产品读取边的变更记录。它们为每次修改增加理解和执行成本。 | 注释写当前的事务、版本和资源不变量。为仍在写入的记录查明真实调用者和兼容需要，再评估内建维护成本。 |

基线 `Sources` 与 `ClipyApp/Sources` 共有 346 个 Swift 文件、81,695 行（含测量程序），历史存储和 App 大文件集中度高。健康性修复应优先削减会改变用户结果的重复状态。已经有效的边界要保住，包括一个 SQLite 事务内的版本／位置／用量写入、引用前发布文件、读取精确版本、字节确认去重、回滚保留旧内容、删除时检查最后一个真实引用、取消后不改写成功提交、同快照分页以及接纳范围限制。 [架构与接口](architecture.md) · [事务与清理](storage.md)

## 六、验证与复查

| 层级 | 需要证明的完整操作 | 当前已有证据和盲区 |
| --- | --- | --- |
| 日常用户任务 | 从三个可混淆条目里按内容和时间找到目标、看见命中、选择、复制到系统剪贴板。加入后台新复制、跨页、临时故障再恢复。 | 旧主旅程覆盖键盘和系统剪贴板字节，原夹具无法判定查询有无实际过滤。测试更新用近似但非字面匹配的干扰项，断言可见顺序和系统字节。 [GUI 主旅程](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyUITests/ClipboardJourneyUITests.swift#L26) |
| 权限与桌面原生行为 | 干净 profile 授权、拒绝/撤销、拖出到另一个应用、信息层和原生弹层的快捷键、屏边窗口命中与反转录屏。 | 常规 GUI 用允许等注入状态；AX 无权限用例可明确 skip。Baseline 实际拖出失败见下方。UI 测试不等同打包 Release 或真实首次 TCC 授权。 [权限 GUI](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyUITests/CaptureAccessJourneyUITests.swift#L24) · [真实拖出](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyUITests/MultiItemDragJourneyUITests.swift#L92) |
| 持久化 | 打开、捕获、编辑、保留、失败、重开后仍得到同字节和一致位置。故障覆盖缺 DB、事务回滚、慢盘备份、容量恢复及异常电源范围。 | 真实 SQLite 已覆盖很多轮回滚、重开、修订、备份，常规 green 需看各用例和 skip。缺 DB 验证已加入修复，备份中的 FTS 词元与真实磁盘耐久性仍待专门证据。 [存储备份测试](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/Tests/HistoryStorageTests/HistoryBackupTests.swift#L130) |
| 外部操作 | 真设置授权、真正的内置 CLI 或系统捷径、原始字节、拒绝、撤销、重启。 | CLI 有真实 socket 和 SQLite；部分专用目录预置失败可 skip，App Intent 测试直接调 `perform` 且内部预授。 [CLI](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyIntegrationTests/LocalAutomationClientRuntimeTests.swift#L16) · [App Intents](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyIntegrationTests/AppIntentBehaviorTests.swift#L88) |
| 大库与长期使用 | 读取深页期间写入、在复杂查询持续捕获、工作区打开同一项多小时、用 10k 人类文本测输入到可见结果、页面重定位与拖动首帧。 | 功能 lane 明确跳过性能目标。既有测量使用合成规模和指定正则/精确负例；结果解释要保留曝光条件，预览和搜索吞吐需拿生产链路测。 [测量范围](testing.md#ci-与性能测量) |

基线复跑 [macOS correctness 44215906064](https://github.com/GuangDai/Clipy/actions/runs/44215906064) 检出 `3713000`，SwiftPM、GUI 1/4、2/4、4/4 通过，GUI 3/4 的 `MultiItemDragJourneyUITests.testRealRowDragsBothItemsAndAllBytesToANativeReceiver` 在第 214 行等待超时。测试记录同一行悬停前后坐标 `(344, 194, 336, 20)` 及源窗口 `(332, 450, 360, 160)`，坐标、拖动投递、接收或观测哪环出错仍需结合附件。本轮证据优先于同一 SHA 10 月那次已过期作业的绿色摘要。 [失败作业](https://github.com/GuangDai/Clipy/actions/runs/44215906064/job/134505556687)

拖放日志进一步确认源端通过实时命中、载荷读取并用两项建立原生拖拽。鼠标进入接收窗口并到达坐标 `(858, 384)`，原生会话以 `.none` 结束，接收端没有进入 `draggingEntered`。第一批修改的另一次运行中，该真实拖放测试通过，原生交付仍存在一次实际失败的证据。已补两端的注册类型、`NSDraggingContext` 和投递诊断。

测试去重第一批从 `3713000` 到 `bd6aaa0`，Swift 测试目录 566 → 561 个文件，2,910 → 2,779 个 `@Test` 声明和 XCTest 方法（参数化实例另计）。改动按独立结果验收。已有测试基础也要修，特别是不能打断的 continuation 等待、共享偏好导致 GUI 跨用例污染以及把意外 `mkdir` 错误当成可跳过的环境限制。 [捕获等待](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyIntegrationTests/AppCaptureLaneTests.swift#L924) · [共享偏好](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyUITests/AppearanceJourneyUITests.swift#L20) · [CLI 环境分支](https://github.com/GuangDai/Clipy/blob/3713000ed026b3bddc828d451fd95796f7cc5bc4/ClipyApp/Tests/ClipyIntegrationTests/LocalAutomationClientRuntimeTests.swift#L282)

## 七、修复分支与复查记录

修复放在 `codex/clipy-ux-review`。以上问题段落及源码锚点保留基线 `3713000` 供比对。下表记录后续实现，验收以对应提交运行的 job 和测试产物为准。

| 轮次 | 实现 | 复查 |
| --- | --- | --- |
| 第一轮 `bd6aaa0` | S00、S01、S04–S07、S11、S13–S14，V01、V03–V04、V07，C07 的缺主文件场景。默认精确和最新优先，筛选可见，日期能随本地时钟刷新，版本与复制一致。测试删除固定文案、死模型、调试和重复夹具。 | [44218600663](https://github.com/GuangDai/Clipy/actions/runs/44218600663) 的 GUI 1、2 通过。真实「捕获干扰项→默认搜索→按时间排序→方向键→原始剪贴板字节」通过。SwiftPM 的 UTF-16 参数合并造成 Swift Testing 宏编译超时。GUI 3 发现弹层根无障碍标识覆盖按钮、RTL 测试仍查旧布局；GUI 4 暴露旧默认排序、旧版本复制预期和替换快照位置相同的夹具。第二轮逐项修正。 |
| 第二轮 | S02 保持深页锚点，S03 把保留清理从全量清空改为观察和精确目标查证，S08 更新打开详情的复制元数据，S12 显示可读命中，S15 索引标题伴随的地址，V06 分开过期/删除/渲染失败，V08 修工作区外层 Done 的退出路径，C05 保住重新复制的原始内容，C08 放宽年龄仍确认。 | 额外考虑了在 seek 等待期间用户重新翻页、深页过时分页、淘汰反复发生时的首屏呈现和旧收藏兼容。需用同提交 macOS CI 核对实际界面触发、两个浏览界面与 SQLite 的一致性。旧修订列表在同版本剪裁后刷新、浮窗外点丢草稿、备份与系统授权还需要各自的工作。 |
| 黄色三角倒置 | 图标对应顶部复制失败与捕获警告。移出整个面板的缩放／透明度动画，保留静态裁剪、窗口适配和提示可访问性，加入警告出现及窗口重开的截图。 | 已确定此处原来存在提示布局测量、原生改 frame 和根视图动画并发。变换计算本身只有正缩放，仍缺出现上下倒置的实际画面。单独记录文字倒置、按钮/标志错位及侧窗横跳三种结果，避免把修好的横跳当成倒置根因。 |

基线 SwiftPM 共运行 1,517 个实例。GUI 4 两个宿主目标分别报告 319 与 941 个实例通过；真实运行应用的 AXPress 用例因 runner 缺辅助功能权限被跳过。统计按用例执行记录，参数化实例和声明数量口径不同。
