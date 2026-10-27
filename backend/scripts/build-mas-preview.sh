#!/bin/zsh
# Local sandbox preview only. App Store distribution still needs its own profile and signing identity.
set -euo pipefail
task_root="${0:A:h:h}"
if [[ $# != 2 ]]; then
  print -u2 "用法: ./scripts/build-mas-preview.sh /绝对路径/前端源码 /绝对路径/新输出目录"
  exit 1
fi
frontend_root="${1:A}"
output_root="${2:A}"
if [[ -e "$output_root" ]]; then
  print -u2 "输出目录已经存在，请指定新目录，避免覆盖正在运行的 App。"
  exit 1
fi
if [[ ! -f "$frontend_root/OverlayUI.swift" ]] || ! cmp -s "$task_root/Sources/PointOut/Contracts.swift" "$frontend_root/Contracts.swift"; then
  print -u2 "前端源码缺失或协议快照不一致。"
  exit 1
fi
if [[ -d /Applications/Xcode.app/Contents/Developer && -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p "$output_root/build" "$output_root/module-cache"
build_architecture="${PINPIN_BUILD_ARCH:-$(uname -m)}"
if [[ "$build_architecture" != "arm64" && "$build_architecture" != "x86_64" ]]; then
  print -u2 "不支持的构建架构。"
  exit 1
fi
app_root="$output_root/PinPin-AppStore-Preview.app"
mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -module-name PointOut \
  -D PINPIN_APP_STORE -target "$build_architecture-apple-macos14.0" \
  -module-cache-path "$output_root/module-cache" \
  "$task_root"/Sources/PointOut/*.swift "$frontend_root/OverlayUI.swift" "$frontend_root"/UI*.swift \
  -o "$output_root/build/PinPin"
cp "$output_root/build/PinPin" "$app_root/Contents/MacOS/PinPin"
cat > "$app_root/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.pointout.app.store-preview</string>
<key>CFBundleName</key><string>PinPin Store Preview</string>
<key>CFBundleDisplayName</key><string>PinPin 商店预览</string>
<key>CFBundleExecutable</key><string>PinPin</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSScreenCaptureUsageDescription</key><string>仅在你操作轮盘时准备当前窗口图像，用于所选功能或本地取色。</string>
</dict></plist>
PLIST
if [[ -f "$frontend_root/brand/PinPin.icns" ]]; then
  cp "$frontend_root/brand/PinPin.icns" "$app_root/Contents/Resources/PinPin.icns"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string PinPin' "$app_root/Contents/Info.plist"
fi
if [[ -d "$task_root/ThirdPartyNotices" ]]; then
  cp -R "$task_root/ThirdPartyNotices" "$app_root/Contents/Resources/"
fi
cp "$task_root/Configuration/PrivacyInfo.xcprivacy" "$app_root/Contents/Resources/PrivacyInfo.xcprivacy"
identity="${PINPIN_SIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
  codesign --force --sign - --entitlements "$task_root/Configuration/PinPin-AppStore.entitlements" "$app_root"
else
  codesign --force --options runtime --timestamp --sign "$identity" \
    --entitlements "$task_root/Configuration/PinPin-AppStore.entitlements" "$app_root"
fi
codesign --verify --strict "$app_root"
print "本地沙盒预览包: $app_root"
print "此包使用独立标识，不用于真实商店购买或提交审核。"
