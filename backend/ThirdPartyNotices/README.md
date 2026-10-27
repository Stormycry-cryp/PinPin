# 第三方来源

- macOS BGRA 像素读取适配自 [Pika](https://github.com/superhighfives/pika)，固定提交 `d28d2ecc4f85ca78077a48a2f669797de65dfab8`，MIT；许可见 `Pika-MIT.txt`。
- Windows 单点采样及 manifest 参考 [Microsoft PowerToys](https://github.com/microsoft/PowerToys)，固定提交 `115665ec3240a0c94dea3f0bfaaa6c52dcf4d019`，MIT；许可见 `PowerToys-MIT.txt`。
- 嘴替回复策略的 criteria 改编来源与 MIT 许可见 `goutoujunshi-jev-chat.md` 和 `goutoujunshi-jev-chat-MIT.txt`。

这里只适配了相关逻辑，未引入完整上游应用。macOS 构包和 Windows 发布目录会包含此许可目录。Python / .NET 等运行依赖继续遵循各自许可；本目录的 MIT 许可仅覆盖对应第三方部分。
