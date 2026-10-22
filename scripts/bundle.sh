#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
APP="build/Peeko.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/PeekoApp" "$APP/Contents/MacOS/Peeko"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/catalog.json "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Sparkle ships as a framework; SwiftPM leaves it next to the binary.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Peeko"

# CI passes its run number so every build gets a higher CFBundleVersion.
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

echo "Bundled $APP"
