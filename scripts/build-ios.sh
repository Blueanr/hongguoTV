#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "iOS builds require macOS and Xcode. Run the iOS TrollStore workflow on GitHub Actions." >&2
  exit 1
fi
npm --prefix ios-native/tooling ci --no-audit --no-fund
npm --prefix ios-native/tooling run build
python3 scripts/ios-icons.py
xcodegen generate --spec ios-native/project.yml
xcodebuild -project ios-native/HongguoPad.xcodeproj -scheme HongguoPad \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO build
APP="$ROOT/build/ios/Build/Products/Release-iphoneos/HongguoPad.app"
# TrollStore replaces this ad-hoc signature at install time; no private entitlements are requested.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p outputs/ios/Payload
ditto "$APP" outputs/ios/Payload/HongguoPad.app
(cd outputs/ios && /usr/bin/zip -qry HongguoTV-iOS15-TrollStore.ipa Payload)
shasum -a 256 outputs/ios/HongguoTV-iOS15-TrollStore.ipa > outputs/ios/SHA256SUMS.txt
echo "IPA: $ROOT/outputs/ios/HongguoTV-iOS15-TrollStore.ipa"
