# 从源码构建

本仓库把原生业务与界面放在同一目录树，直接克隆即可，不依赖其他私有仓库。普通客户端与 App Store 配置分别构建，不自动切换到商业服务。

## macOS

需要 macOS 14+、Swift 6 工具链、完整 Xcode 和 Python 3；配置脚本另需 Node.js 20+。

```sh
git clone https://github.com/Stormycry-cryp/PinPin.git
cd PinPin
./scripts/build-macos.sh
```

产物为 `backend/dist/PinPin.app`，默认临时签名。使用自己的 Developer ID 时，在构建命令前指定 `PINPIN_SIGN_IDENTITY`。脚本不公证、不上传，也不修改正在运行的应用。不要同时运行另一份相同 bundle ID 的 PinPin。

首次运行，在 macOS 系统设置中为自己构建的 App 开启辅助功能和屏幕录制。两项分别用于全局手势/明确选区与屏幕图像；这些权限由使用者自己授予。

AI 功能通过 HTTPS 网关调用模型。先按[服务端说明](../backend/server/README.md)准备自己的服务，再显式配置客户端：

```sh
PINPIN_GATEWAY_URL=https://your-domain.example/ping/v1 \
PINPIN_ACCESS_TOKEN=your-application-token \
node backend/scripts/configure-local.mjs
```

`your-domain.example` 和 `your-application-token` 是占位符，需替换。供应商密钥只放服务端；此脚本仅写应用访问令牌，文件权限为 0600。公开源码内的默认 `gateway.example.com` 也是占位符，不附带作者的私测服务。

运行核心测试及界面检查：

```sh
(cd backend && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test)
bash frontend/Tests/check-settings.sh "$PWD/.build/check-settings"
```

界面检查使用离屏组件和隔离数据，不代表真实全局手势或跨应用验收。

## Windows

在 Windows 11 x64 安装 .NET 10 SDK。根目录入口会寻找 PATH 中的 dotnet，支持任意本地工作目录：

```powershell
git clone https://github.com/Stormycry-cryp/PinPin.git
cd PinPin
.\scripts\build-windows.ps1
```

默认生成依赖 .NET Desktop Runtime 10 的小包；需要收件人免装运行时时使用 `-SelfContained`。可用 `-DotnetPath` 显式指定 SDK。产物放在 `.build/windows/package`，构建进度在终端显示。日常使用前先把整个包复制到独立运行目录，避免和下一次构建混用；脚本会保留有用户数据或仍在运行的旧包。

`-RunChecks` 运行本地 Core / Native / Host 检查；真实窗口、DPI、权限及网络能力仍需要 Windows 实机验收。此公开整理轮没有重新执行 Windows 构建。

运行时保留整个发布文件夹，双击 `PinPin.exe`。首次启动可填写自己的 HTTPS 网关和访问令牌；也可稍后连接，先使用本地功能。令牌使用当前 Windows 用户的 DPAPI 加密，数据默认在程序旁的 Data 目录。不要把自己使用过的 Data 目录或令牌转发出去。

## App Store 与订阅

源码包含沙盒采集适配、StoreKit 2 和独立订阅服务。它们需要自己的 Apple App ID、月付商品、描述文件、签名证书、可信 Apple 根证书及商业模型密钥。公开快照不包含这些配置，未提供已上线购买服务。

本地沙盒预览可使用：

```sh
zsh backend/scripts/build-mas-preview.sh "$PWD/frontend" "$PWD/.build/mas-preview"
```

该命令要求输出目录尚不存在。正式归档脚本是 `backend/scripts/build-mas-archive.sh`，仅在准备好自己的描述文件和 `PINPIN_MAS_SIGN_IDENTITY` 后使用；构建不等于上传、审核或发布。
