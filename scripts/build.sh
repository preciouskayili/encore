#!/bin/bash
# Builds build/Encore.app: the Swift app, plus the Now Playing helper.
# The app runs on both Apple silicon and Intel Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

APP=build/Encore.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Encore" "$APP/Contents/MacOS/Encore"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Helper/bridge.pl "$APP/Contents/Resources/bridge.pl"
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -framework Foundation Helper/bridge.m -o "$APP/Contents/Resources/bridge.dylib"

# Signed for personal use ("ad hoc"), not notarised by Apple. See the README
# for what that means when someone else opens it.
codesign --force --sign - "$APP/Contents/Resources/bridge.dylib"
codesign --force --sign - "$APP"

echo "Built $APP"
