# ClipyApp

应用、随包 CLI、宿主测试和实际 UI 测试由 [project.yml](project.yml) 定义。生成的 `.xcodeproj` 是构建产物，不手工编辑。SwiftPM 库图位于仓库根 `Package.swift`。

源码入口和当前界面行为见 [架构](../docs/architecture.md) 与 [界面](../docs/interface.md)，构建和测试只通过 [macOS CI](../docs/testing.md) 验证。
