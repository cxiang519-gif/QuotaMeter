#!/bin/bash
# QuotaMeter build script.
#   ./build.sh            Build ./QuotaMeter.app next to this script.
#   ./build.sh --install  Build, then copy to /Applications and launch.
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --show-sdk-path)"
echo "Using SDK: $SDK"

APP="$PWD/QuotaMeter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Sources/Info.plist "$APP/Contents/Info.plist"

/usr/bin/swiftc -swift-version 5 -O -sdk "$SDK" \
  Sources/main.swift Sources/stats.swift Sources/shortcuts.swift Sources/l10n.swift \
  -o "$APP/Contents/MacOS/QuotaMeter"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
/usr/bin/swiftc -swift-version 5 -O -sdk "$SDK" Sources/icon.swift -o /tmp/qm_icon_gen
/tmp/qm_icon_gen "$ICONSET"
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

/usr/bin/codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x QuotaMeter 2>/dev/null || true
  sleep 1
  rm -rf /Applications/QuotaMeter.app
  cp -R "$APP" /Applications/QuotaMeter.app
  open /Applications/QuotaMeter.app
  echo "Installed and launched /Applications/QuotaMeter.app"
fi
