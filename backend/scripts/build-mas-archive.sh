#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
if [[ $# != 3 || -z "${PINPIN_MAS_SIGN_IDENTITY:-}" ]]; then
  print -u2 "用法: PINPIN_MAS_SIGN_IDENTITY=签名身份 ./scripts/build-mas-archive.sh 前端目录 描述文件 新输出目录"
  exit 1
fi
frontend_root="${1:A}"
profile_path="${2:A}"
output_root="${3:A}"
if [[ -e "$output_root" || ! -f "$profile_path" ]]; then
  print -u2 "输出目录必须不存在，且描述文件必须存在。"
  exit 1
fi
mkdir -p "$output_root"
security cms -D -i "$profile_path" > "$output_root/profile.plist"
python3 - "$output_root/profile.plist" "$task_root/Configuration/PinPin-AppStore.entitlements" "$output_root/entitlements.plist" <<'PY'
import datetime, plistlib, sys
from pathlib import Path
profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
ent = profile.get('Entitlements', {})
app_id = ent.get('com.apple.application-identifier')
team = profile.get('TeamIdentifier', [])
assert len(team) == 1 and app_id == team[0] + '.com.pointout.app', '描述文件与 PinPin 不匹配'
assert profile.get('Platform') == ['OSX'], '需要 macOS 描述文件'
assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), '描述文件已过期'
assert not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'), '需要 Mac App Store 描述文件'
result = plistlib.loads(Path(sys.argv[2]).read_bytes())
result.update({'com.apple.application-identifier': app_id,
               'com.apple.developer.team-identifier': team[0],
               'keychain-access-groups': [app_id]})
Path(sys.argv[3]).write_bytes(plistlib.dumps(result))
PY
for build_architecture in arm64 x86_64; do
  PINPIN_SIGN_IDENTITY=- PINPIN_BUILD_ARCH="$build_architecture" \
    zsh "$task_root/scripts/build-mas-preview.sh" "$frontend_root" "$output_root/$build_architecture"
done
app_root="$output_root/PinPin.app"
ditto "$output_root/arm64/PinPin-AppStore-Preview.app" "$app_root"
lipo -create "$output_root/arm64/build/PinPin" "$output_root/x86_64/build/PinPin" -output "$app_root/Contents/MacOS/PinPin"
python3 - "$app_root/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1]); value = plistlib.loads(p.read_bytes())
value.update({'CFBundleIdentifier': 'com.pointout.app', 'CFBundleName': 'PinPin',
              'CFBundleDisplayName': 'PinPin', 'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1'})
p.write_bytes(plistlib.dumps(value))
PY
cp "$profile_path" "$app_root/Contents/embedded.provisionprofile"
codesign --force --options runtime --timestamp --sign "$PINPIN_MAS_SIGN_IDENTITY" \
  --entitlements "$output_root/entitlements.plist" "$app_root"
codesign --verify --strict "$app_root"
archive_root="$output_root/PinPin.xcarchive"
mkdir -p "$archive_root/Products/Applications"
ditto "$app_root" "$archive_root/Products/Applications/PinPin.app"
python3 - "$archive_root/Info.plist" "$PINPIN_MAS_SIGN_IDENTITY" <<'PY'
import datetime, plistlib, sys
from pathlib import Path
value = {'ArchiveVersion': 2, 'Name': 'PinPin', 'SchemeName': 'PinPin',
         'CreationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
         'ApplicationProperties': {'ApplicationPath': 'Applications/PinPin.app',
                                   'CFBundleIdentifier': 'com.pointout.app',
                                   'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
                                   'SigningIdentity': sys.argv[2]}}
Path(sys.argv[1]).write_bytes(plistlib.dumps(value))
PY
print "商店归档: $archive_root"
print "已构建并验签；未上传、提交审核或发布。"
