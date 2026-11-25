#!/usr/bin/env bash
# Builds "build/Wallpaper Manager.app" from the Swift package.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Wallpaper Manager"
EXECUTABLE="WallpaperManager"
APP="build/${APP_NAME}.app"

swift build -c release --product "$EXECUTABLE"
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally on your own Mac (no Apple Developer account needed).
codesign --force --sign - "$APP"

echo "Built $APP"
