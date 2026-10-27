# PinPin Windows

业务、平台采集和应用宿主分别位于 Core、Native 与 App；WPF 界面位于同仓库 `frontend/windows/PinPin.Presentation`。使用根目录 `scripts/build-windows.ps1` 构建。

- Windows 11 x64 / .NET 10 / WPF；Alt + 左键轮盘，Alt + 右键设置。
- 本地 GDI 单点取色，不调用大模型；读数标记为 GDI_SDR_UNMANAGED，未声明完成 ICC 色彩转换。
- HDR、广色域、所有混合 DPI 组合及 Windows ARM64 尚未完成验收。
- 普通包的收藏先保存原图或原文，再尝试 AI 说明；未配置连接时说明不可用，本地原始资产保留。

用户操作见[使用说明.txt](使用说明.txt)，统一构建见[构建说明](../../../docs/build.md)。
