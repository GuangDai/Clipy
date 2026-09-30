# 格式、预览与缩略图

## 原始格式与行为

[`ClipboardFormats/StableFormatFacts.swift`](../Sources/ClipboardFormats/StableFormatFacts.swift) 保存开放的类型标识，比较精确 UTF-8 拼写。未知格式保持不透明；某个类型能被保存 / 复制，不代表它能被投影、预览或编辑。模块只声明事实，不建立运行时 registry、插件或统一解码策略。

已明确字节序的纯文本包括 `public.utf8-plain-text`、本机字节序的 `public.utf16-plain-text` 和外部 UTF-16 的 `public.utf16-external-plain-text`。外部 UTF-16 可带 BOM；没有 BOM 时按大端解释。编码不明确的 `public.text` / `public.plain-text` 不猜测为 UTF-8，错误数据不静默替换。未知格式仍能被原样导出或复制。

存储搜索投影由 [`ContentProjector.swift`](../Sources/HistoryStorage/ContentProjector.swift) 拥有。预览 source 选择由 `ContentPreview` 拥有；编辑字节编码由应用编辑器拥有。三者不能因共享标识事实而相互代替目的判断。

## 预览加载

[`PreviewContentLoader.swift`](../ClipyApp/Sources/UI/PreviewContentLoader.swift) 先以精确 `HistoryItemReference` 读取无载荷表示元数据，交给 renderer 选择 source，再只读取选中的表示形式。它拥有选择、任务和版本发布；[`ContentPreview.swift`](../Sources/ContentPreview/ContentPreview.swift) 拥有优先级、解码与资源限制，不读取 History，不管理面板或缓存。

支持的图片表示优先于文本；无图片时尝试具明确 codec 的纯文本，再按 RTF、flat RTFD、HTML、复制地址的顺序选择单个 rich / reference source。只有纯文本解码格式错误时允许继续下一个文本 / 后续 source；图片失败不降级成看似另一种成功预览。

加载在每次 await 后检查取消、当前 reference 和 request generation。换选择、修订、删除、隐藏等立即退役旧发布；旧结果不能以新目标名义返回。临时存储失败或 native renderer 资源暂时不可用可重试；确定损坏、超限和不支持类型没有无限自动 Retry。

## 解码与资源限制

| 输入 / 输出 | 限制与处理 |
| --- | --- |
| History 图片 source | 输入最多 64 MiB；输出最长边 640 px，premultiplied BGRA8、sRGB |
| 精确纯文本预览 | 输入最多 64 MiB；默认显示 50,000 个 Character，可调整正数或关闭长度限制；截断单独披露 |
| RTF / flat RTFD / HTML | 输入最多 1 MiB，受限解析成静态正文；RTF 输出最多 1,048,576 个 UTF-16 code unit，HTML 输出最多 1 MiB UTF-8 字节；不执行脚本或读取外部资源 |
| 复制 URL / file URL | 输入最多 16 KiB；返回静态地址描述，不访问目标 |
| 显示 History 返回的 PNG 缩略图 | 编码输入最多 16 MiB；最长边 2,048 px |

图片使用 ImageIO 缩放并立即物化像素，输出无 `CGImage` / `NSImage`。多帧 / 多页输入显示选定的首张图，同时保留数量用于披露。富文本解析关注正文、字符、段落与声明编码，不在预览里建立网页浏览器或完整富文档执行环境。RTF 的已知字体表可以声明编码；未知跳过段和未使用的 ANSI 备用段不能修改后续正文的字体事实。原始载荷始终能独立读取，预览失败不删除或改变内容。

解析、文本分段和前几段 native 字体准备都在 detached worker 执行；renderer actor 只管理资源计数与 native 图片槽。UTF-16 decoder 通过只读 code unit sequence 处理源 Data，不再创建文档大小的中间数组，仍拒绝奇数字节和未配对 surrogate。

[`PreviewTextConfiguration.swift`](../Sources/ContentPreview/PreviewTextConfiguration.swift) 默认将 native 布局工作分成 512 个 UTF-16 unit、24 次换行以内的段落单元，短单行段落最多八个成组。超长组合字素可按 scalar 分段，substring 共享原始文本；分组按 scalar 查换行，避免每个小段反复遍历剩余的大组合簇。分段不丢失、归一化或修改字节，也不限制整段内容复制。

`ContentPreview` 分别保留一个图片和一个文字工作槽，等待槽位各有 2 秒上限。文字工作可越过慢图像工作，同一时刻最多一份文本进入解码、分段和字体预热；一个已开始的同步 native 解码只能在引擎允许的边界完成，因此取消不会凭空释放仍执行中的真实槽位。

## 缩略图与显示缓存

[`ThumbnailService.swift`](../Sources/HistoryStorage/ThumbnailService.swift) 拥有精确 item version / size 的 source 读取与同请求 single-flight，返回编码 PNG。尺寸允许每轴 1 至 2,048 px，编码结果最多 16 MiB。没有支持图片返回 nil；选中图片不能解码返回 `thumbnailUnavailable`，原始字节仍可复制和读取。

应用的 [`ThumbnailStore.swift`](../ClipyApp/Sources/UI/ThumbnailStore.swift) 每个浏览界面默认最多 500 个完成条目与 64 MiB 解码像素，同时包含 negative 结果。有限 recency 用于淘汰较冷条目；SwiftUI render 读取不更新缓存状态。显示中的 raster 与系统可回收冷缓存分开，缓存失效后重建结果，不回退到错误版本。来源图标由 [`SourceIconStore.swift`](../ClipyApp/Sources/UI/SourceIconStore.swift) 单独维护有限缓存。

## 显式本地文件预览

普通 file URL 预览只显示复制的地址。用户明确确认“读取文件”后，应用层 [`LocalFilePreviewLoader.swift`](../ClipyApp/Sources/Preview/LocalFilePreviewLoader.swift) 才访问其目标，结果不写入 History。读取最多 64 MiB，按 64 KiB 分块检查取消，并比较打开前后 descriptor 的大小与修改 / 状态时间。

只允许本地 regular file 和已有 renderer 支持的扩展名；不跟随 symlink，不打开 FIFO / 目录，不从非本地卷或 dataless 占位文件读取。原始 URL、访问失败、资源超限和读取中发生变化分别反馈，不自动重新打开目标。打开外部应用、导出与文件预览是不同的明确动作。
