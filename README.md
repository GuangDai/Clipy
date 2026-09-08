# Clipy

macOS 26、Apple Silicon 上的本地剪贴板历史工具。所有历史保存在本机。

- 按 `⇧⌘C` 打开面板，输入搜索；方向键选择，回车复制并返回原应用。
- 历史支持精确、模糊和正则搜索，以及全历史范围的类型/置顶筛选。
- 可置顶、排序、删除条目；设置中的保留策略分别控制数量、年龄、内容量和修订。
  默认保留最近 200 条未置顶记录；可以自定义条数或关闭按条数删除，其他保留策略仍独立生效。
- 详情按需加载表示，支持完整字节导出和不可变内容修订。
- 预览支持文本、图片、离线 HTML/RTF/RTFD 文本及静态 PDF 页；PDF 可逐页浏览，
  不执行文档动作，也不一次渲染所有页。本地 PDF 经明确加载后可翻页，翻页不重复读取文件。
  RTFD 附件保持惰性占位。
- 设置 → 维护可备份完整历史，显示进度、取消和结果。备份包含原始内容与修订，
  未加密；请选择自己管理的目的地。现有目录不会被覆盖。
- 设置 → 自动化可启用独立授权并找到内置 `clipyctl`。详见
  [Local Automation](docs/local-automation.md)，包括 `recent`、`search`、`read`、
  `pin`、`unpin`、`delete` 命令、原始字节输出和 Python 示例。

点击菜单栏图标也可打开面板；右键菜单提供暂停/恢复捕获等操作。捕获被系统拒绝时，
已保留历史仍可浏览，面板提供明确的访问恢复入口。

构建需要 Xcode 26 / Swift 6.2。SwiftPM 管理库，XcodeGen 管理 App 项目：

```sh
swift build
swift test --skip 'HistoryPerfTests\.'
xcodegen generate --spec ClipyApp/project.yml
```

本仓库通过 macOS CI 验证构建和行为。规模测量由手动 `SQLite storage measurements`
工作流运行，支持 10k、100k、1m 条。产品不再设置固定历史条数上限；实际保留量受
用户策略和可用存储空间影响。百万级一秒搜索目标仍需实际测量证明。
