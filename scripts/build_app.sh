#!/bin/bash
# Builds "Sleep Mac.app" (universal arm64 + x86_64, ad-hoc signed) plus a zip and a dmg into dist/.
# Usage: scripts/build_app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Sleep Mac"
EXECUTABLE="SleepMac"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Running tests"
swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|failed" | tail -3

echo "==> Building release (universal)"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> UI smoke test"
SNAPSHOTS="$(mktemp -d)"
"$BIN_DIR/$EXECUTABLE" --ui-smoke-test "$SNAPSHOTS" | grep -E "FAIL|smoke test"
rm -rf "$SNAPSHOTS"

echo "==> Generating icon"
if [ ! -f Resources/AppIcon.icns ]; then
    swift scripts/make_icon.swift Resources
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "==> Assembling $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Packaging"
ditto -c -k --keepParent "$APP" "$DIST/Sleep-Mac.zip"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Sleep-Mac.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "Done:"
echo "  $APP"
echo "  $DIST/Sleep-Mac.zip"
echo "  $DIST/Sleep-Mac.dmg"
lipo -archs "$APP/Contents/MacOS/$EXECUTABLE" | sed 's/^/  architectures: /'
