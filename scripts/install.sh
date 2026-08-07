#!/bin/bash
# Build and install CCQuota.
#
# Updates the installed bundle in place with ditto rather than rm -rf + cp.
# Deleting the bundle removes the widget extension the system has registered,
# and any widget the user had placed on the desktop disappears with it — it
# points at that extension, and macOS drops a placed widget whose provider
# vanishes. ditto overwrites the contents without the bundle ever going away.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="${CCQUOTA_INSTALL_DIR:-/Applications}/CCQuota.app"

echo "==> CLI 빌드"
swift build -c release
install -m 755 .build/release/ccquota "${CCQUOTA_BIN_DIR:-/opt/homebrew/bin}/ccquota"

echo "==> 앱 빌드"
command -v xcodegen >/dev/null || { echo "xcodegen 이 필요합니다: brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null
xcodebuild -project CCQuota.xcodeproj -scheme CCQuota -configuration Release \
    -destination 'platform=macOS' -derivedDataPath build \
    -allowProvisioningUpdates build >/dev/null

echo "==> 설치"
osascript -e 'tell application "CCQuota" to quit' 2>/dev/null || true
pkill -f "CCQuota.app/Contents/MacOS/CCQuota" 2>/dev/null || true
sleep 1

ditto build/Build/Products/Release/CCQuota.app "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/CCQuotaWidget.appex" 2>/dev/null || true
open -a "$DEST"

echo "==> 완료"
echo "    위젯이 갤러리에 보이지 않으면 위젯 데몬을 다시 띄우십시오:"
echo "      sudo killall chronod"
echo "    그래도 없으면 로그아웃 후 다시 로그인하면 반영됩니다."
