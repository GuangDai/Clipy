# 动画、响应与性能

Clipy 采用十档速度，1 最慢、10 最快；只有最快档以不超过五帧为目标。十档划分、具体时间和幅度是本项目的设计选择，不能说成 Hyprland 或 Apple 的默认设置。动画请求时长及 AppKit 窗口 display-link 测量不等于输入到实际显示完成的五帧物理测量。

## 官方来源可以确认的事实

| 来源 | 事实与对 Clipy 的意义 |
| --- | --- |
| [Hyprland Animations](https://wiki.hypr.land/Configuring/Advanced-and-Cool/Animations/) | 动画按窗口、显示、工作区等用途组成继承树，未设置的子项继承父项参数；曲线与时长分开定义。它名为 `speed` 的数值实际表示以 100 ms 为单位的时长，1 是 100 ms，值越大越慢；不能直接映射为本项目“值越大越快”的十档。 |
| [hyprutils AnimatedVariable.hpp](https://github.com/hyprwm/hyprutils/blob/main/include/hyprutils/animation/AnimatedVariable.hpp#L225-L247) | 新目标与旧目标相同就直接返回；改变目标时设置 `m_Goal = v`、`m_Begun = m_Value`，从当前值开始，而不是排队播放旧动画。当前 spring 分支另处理既有速度；Bezier 从当前值重启不等于速度连续。 |
| [hyprutils AnimatedVariable.cpp](https://github.com/hyprwm/hyprutils/blob/main/src/animation/AnimatedVariable.cpp#L79-L120) | Bezier 进度由单调时钟已过时间除以配置时长计算，限制在 0 至 1，随后取曲线值。固定显示帧数不是这个时长配置的含义。 |
| [Apple Motion HIG](https://developer.apple.com/design/human-interface-guidelines/motion) | 自定义动态效果应有明确用途，反馈简短精确；高频交互不应反复要求用户注意装饰动画，用户不应等动画结束才能继续操作。动态效果应可减少，重要信息不能只靠动画传达。 |
| [Apple Animation.speed](https://developer.apple.com/documentation/swiftui/animation/speed(_:)) | SwiftUI 的 speed 是播放倍数，2 倍将一秒动画缩短为半秒。它与 Hyprland 同名参数方向不同，接口上应先算统一秒数，再交给框架。 |
| [Apple：统一应用动画](https://developer.apple.com/documentation/swiftui/unifying-your-app-s-animations) | SwiftUI、UIKit、AppKit 有不同动画实现；Apple 提供跨框架使用 SwiftUI Animation 的入口，支持对运行中的动画重新设目标，并延续既有速度。使用相同数值曲线能统一外观，但不足以证明不同实现的中断行为完全相同。 |
| [Apple WWDC23：Explore SwiftUI animation](https://developer.apple.com/videos/play/wwdc2023/10156/) | 内置 `scaleEffect` 等 animatable 属性可高效插值；自定义 `Animatable` 的 `body` 会按帧执行，并可能重新布局。应优先使用已有显示属性，避免为了小幅缩放自建逐帧布局。 |
| [SwiftUI keyframeAnimator](https://developer.apple.com/documentation/swiftui/view/keyframeanimator(initialvalue:trigger:content:keyframes:))、[LinearKeyframe](https://developer.apple.com/documentation/swiftui/linearkeyframe/init(_:duration:timingcurve:)) | 新 trigger 用新序列替换进行中的动画，结束值保持为下一次的起点；LinearKeyframe 支持统一 UnitCurve。content 回调每帧执行，因此只组合现有显示属性，不读取历史、解码或布局。 |
| [Apple：界面响应](https://developer.apple.com/documentation/xcode/understanding-user-interface-responsiveness) | 动画时长、首次反馈延迟和掉帧是不同问题。主线程阻塞可能同时导致响应停顿与掉帧，一个刷新间隔的延迟就可能让动画卡顿；只缩短曲线时间不能修复内容读取、布局或提交阻塞。 |
| [NSScreen.maximumFramesPerSecond](https://developer.apple.com/documentation/appkit/nsscreen/maximumframespersecond) | 返回屏幕支持的最大刷新率，不能把它当作当前正在显示的帧率或整个事件处理链的耗时。 |

以上阅读范围是当前官方 wiki、hyprutils 主分支和 Apple 官方文档 / WWDC 内容，不使用第三方外观截图推断实现或性能。

## Clipy 当前设计

[`AppMotionSettings.swift`](../ClipyApp/Sources/UI/AppMotionSettings.swift) 集中定义档位、时长、曲线、系统 Reduce Motion 和出现效果。普通出现时长如下；其余档位不套用五帧限制。

| 档位 | 出现动画时长 |
| --- | --- |
| 1 | 435 ms |
| 2 | 390 ms |
| 3 | 345 ms |
| 4 | 300 ms |
| 5 | 255 ms |
| 6 | 210 ms |
| 7 | 165 ms |
| 8 | 120 ms |
| 9 | 75 ms |
| 10（默认） | `min(50 ms, 3 / maximumFramesPerSecond 秒)`；无有效屏幕参数时按 60 Hz 计算 |

反馈效果采用出现时长的一半，包括第 10 档；搜索按钮与过滤按钮按压时轻微缩小、松开回弹，操作本身立即执行。Reduce Motion 为所有自定义效果选零时长。最快档为 60 Hz 请求 50 ms、120 Hz 请求 25 ms，按最大刷新率计算均只占三次理论刷新间隔，给五帧目标留出余量；这只是动画请求预算，不能证明主线程、框架提交和 WindowServer 已在剩余两帧内完成。

SwiftUI 与 AppKit 统一使用三次 Bezier 控制点 `(0.2, 0.8, 0.2, 1)`。由控制点计算，曲线起点斜率为 4、终点斜率为 0，意图是尽早靠近目标、平稳收尾；“更利落”的感受是设计推断，仍需实际交互判断。统一只需共用这个有限值定义，不需要继承注册表或另一层动画调度系统。

面板、浮动预览和 Quick Look 初次出现统一使用 0.92 至 1 的透明度及 0.975 至 1 的小幅缩放，十档只改变时长，不改变动作幅度。过渡使用 SwiftUI 的 `scaleEffect`、`opacity` 与统一曲线；窗口位置和内容适配尺寸立即应用，不逐帧重排窗口。关闭、失效清理及隐藏立即生效，不能等待装饰动画才清理敏感内容。

SwiftUI 中的缩放和透明度使用普通 `ViewModifier` 包装框架已有属性，不实现自己的逐帧 `Animatable.body`。这不证明 SwiftUI、AppKit 和 WindowServer 没有其他逐帧计算，只减少应用主动添加的插值工作。具体接线见 [`HistoryPanelView.swift`](../ClipyApp/Sources/UI/HistoryPanelView.swift)、[`FloatingPanel.swift`](../ClipyApp/Sources/Panel/FloatingPanel.swift) 与 [`FloatingPreviewPanel.swift`](../ClipyApp/Sources/Panel/FloatingPreviewPanel.swift)。

## 可以采用与不能照搬的部分

可以采用统一曲线、明确用途和少量子用途时长；让新交互立即替换旧意图，已有窗口不因再次召唤重播出现动画。SwiftUI 执行显示效果，原有窗口生命周期只发出出现或取消意图，不把 animation completion 当窗口生命周期所有者。如未来需要位置变化的连续速度，应核对框架对应 API，而不是自己排队或计时等待。这是依据上面来源形成的 Clipy 设计判断。

不能直接照搬 compositor 的大幅 `popin`、整屏 workspace 滑动、装饰旋转或永久循环：Clipy 的目标是短暂浏览与快速复制，额外几何变化会改变内容位置，并增加每次高频操作的视觉等待。Hyprland 本身也指出循环效果会持续按刷新率渲染、增加 CPU / GPU 和电池负担。[Hyprland Animations](https://wiki.hypr.land/Configuring/Advanced-and-Cool/Animations/)

只调整显示属性，不把搜索、读取、解码、列表分页或实际 mutation 延迟到动画结束。继续使用有界页面、后台内容准备和目标 / 版本发布检查；统一动态效果不成为业务状态转换的第二套机制。

视图和动画优先使用 SwiftUI。窗口外壳仍处理每次召唤定位、独立预览跟随、焦点、Space 和系统事件；这些既有职责没有为了过渡动画再增加 AppKit 视图层。SwiftUI 的 [`defaultWindowPlacement`](https://developer.apple.com/documentation/swiftui/scene/defaultwindowplacement(_:)) 定义首次创建窗口的默认放置，不是持续追踪另一窗口的接口；[`UtilityWindow`](https://developer.apple.com/documentation/swiftui/utilitywindow) 自带自动隐藏与 Esc 关闭规则，不能直接视为当前两窗会话的等价替换。这说明本次保留现有外壳的取舍，不意味着 SwiftUI 无法创建浮动窗口。

## 当前验证边界

代码中的十档时长、Reduce Motion、即时关闭与重复打开不重播是可检查的确定行为；曲线体验、快速反复开关是否平顺，以及输入至稳定画面的五帧上限仍需要真实 macOS 运行证据。按用户要求只使用 CI，不执行本地 Swift 构建 / 测试。普通 CI 编译和功能测试通过也不能自动证明物理显示链的帧数。

后续判断时分清四段：输入到第一处可见反馈、请求的曲线时长、框架 / 渲染掉帧、内容何时可交互。最慢档允许长于五帧但立即可操作，最快档缩短动态效果，不省略正确的内容与权限检查。没有这些证据时不宣称“端到端五帧已验证”或“主线程无开销”。
