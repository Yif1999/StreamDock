#!/bin/sh
# Builds build/StreamDock.app: the menu bar app plus the vendor transport library,
# signed with a stable identity so macOS keeps Accessibility permission across rebuilds.
#
#   scripts/build_app.sh            release build
#   CONFIG=debug scripts/build_app.sh
#   CODESIGN_IDENTITY="Apple Development: ..." scripts/build_app.sh
set -e
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
APP=build/StreamDock.app

swift build -c "$CONFIG" --product DockApp
swift build -c "$CONFIG" --product dock-hook
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DockApp"
HOOK="$(swift build -c "$CONFIG" --show-bin-path)/dock-hook"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/StreamDock"
# The hook command; the app copies it to Application Support on launch (AgentMonitor).
cp "$HOOK" "$APP/Contents/MacOS/dock-hook"
cp ThirdParty/libtransport/libtransport.dylib "$APP/Contents/Frameworks/"

# The bundle must not depend on the repo checkout.
install_name_tool -delete_rpath "$PWD/ThirdParty/libtransport" "$APP/Contents/MacOS/StreamDock" 2>/dev/null || true

codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/Frameworks/libtransport.dylib"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/MacOS/dock-hook"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
