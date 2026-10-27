#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:?请提供本轮独立检查目录的绝对路径}"
mode="${2:---compile-only}"
case "$build_dir" in /*) ;; *) echo '检查目录必须是绝对路径' >&2; exit 2 ;; esac
case "$mode" in --compile-only|--run) ;; *) echo '模式必须为 --compile-only 或 --run' >&2; exit 2 ;; esac
mkdir -p "$build_dir/module-cache"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 5 -parse-as-library -D PINPIN_UI_TESTING -module-name PinPinSettingsReopenTests \
  -module-cache-path "$build_dir/module-cache" \
  "$repo_dir/Contracts.swift" "$repo_dir/OverlayUI.swift" "$repo_dir"/UI*.swift \
  "$repo_dir/Tests/SettingsReopenTests.swift" -o "$build_dir/settings-reopen-tests"
if [[ "$mode" == --run ]]; then
  "$build_dir/settings-reopen-tests" "$build_dir"
else
  echo "Compiled only. GUI checks have NOT run. Executable: $build_dir/settings-reopen-tests"
fi
