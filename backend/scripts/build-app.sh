#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
frontend_root="${1:-${POINTOUT_FRONTEND_DIR:-$task_root/../frontend}}"
if [[ ! -f "$frontend_root/OverlayUI.swift" ]]; then
  print -u2 "找不到同仓库 frontend，请使用根目录 scripts/build-macos.sh。"
  exit 1
fi
if ! cmp -s Sources/PointOut/Contracts.swift "$frontend_root/Contracts.swift"; then
  print -u2 "前端协议快照与后端不同，请先同步 Contracts.swift 再构建。"
  exit 1
fi
if [[ -d /Applications/Xcode.app/Contents/Developer && -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
app_root="$task_root/dist/PinPin.app"
python3 "$task_root/../scripts/ensure-app-stopped.py" "$app_root"
mkdir -p .build/native/module-cache
task_architecture="$(uname -m)"
# Backend and frontend compile into one native module from this repository.
# Only the canonical backend contract is compiled, never the frontend's verification snapshot.
swiftc -O -swift-version 5 -parse-as-library -module-name PointOut \
  -target "$task_architecture-apple-macos14.0" \
  -module-cache-path .build/native/module-cache \
  Sources/PointOut/*.swift "$frontend_root/OverlayUI.swift" "$frontend_root"/UI*.swift \
  -o .build/native/PinPin
python3 "$task_root/../scripts/ensure-app-stopped.py" "$app_root"
mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources"
cp .build/native/PinPin "$app_root/Contents/MacOS/PinPin"
cat > "$app_root/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.pointout.app</string>
<key>CFBundleName</key><string>PinPin</string>
<key>CFBundleDisplayName</key><string>PinPin</string>
<key>CFBundleExecutable</key><string>PinPin</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSScreenCaptureUsageDescription</key><string>在你按住 Option 和鼠标左键时准备当前窗口截图，确认功能后仅处理所指内容。</string>
</dict></plist>
PLIST
if [[ -f "$frontend_root/brand/PinPin.icns" ]]; then
  cp "$frontend_root/brand/PinPin.icns" "$app_root/Contents/Resources/PinPin.icns"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string PinPin' "$app_root/Contents/Info.plist"
fi
if [[ -d "$task_root/ThirdPartyNotices" ]]; then
  cp -R "$task_root/ThirdPartyNotices" "$app_root/Contents/Resources/"
fi
sign_identity="${PINPIN_SIGN_IDENTITY:--}"
if [[ "$sign_identity" == "-" ]]; then
  codesign --force --sign - "$app_root"
else
  codesign --force --options runtime --timestamp --sign "$sign_identity" "$app_root"
fi
codesign --verify --deep --strict "$app_root"
print "Built: $app_root"
