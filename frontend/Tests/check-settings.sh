#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:?请提供本轮独立检查目录的绝对路径}"
case "$build_dir" in /*) ;; *) echo '检查目录必须是绝对路径' >&2; exit 2 ;; esac
mkdir -p "$build_dir/module-cache"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 5 -parse-as-library -D PINPIN_UI_TESTING -module-name PointOutUISettingsTests \
  -module-cache-path "$build_dir/module-cache" \
  "$repo_dir/Contracts.swift" "$repo_dir/OverlayUI.swift" "$repo_dir"/UI*.swift \
  "$repo_dir/Tests/SettingsTests.swift" -o "$build_dir/settings-tests"
"$build_dir/settings-tests" --render-dir "$build_dir"
