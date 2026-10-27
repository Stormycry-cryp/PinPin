# PinPin 原生界面

macOS 使用 AppKit + SwiftUI，Windows 使用 WPF。包含轮盘、结果卡片、标注点、设置、资产看板、连接及订阅界面。

macOS 的 `OverlayUI.swift` 与 `UI*.swift` 由根目录 `scripts/build-macos.sh` 和业务源码一起编译；`Contracts.swift` 仅作协议一致性检查，不重复编译。Windows 项目使用根 `Directory.Build.props` 指向同仓库 Core。

[设计规范](../docs/design-system.md) · [构建与检查](../docs/build.md)
