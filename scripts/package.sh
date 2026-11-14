#!/bin/bash
# Builds the app and zips it for sharing: build/Encore-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
ZIP="build/Encore-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the app's signature and icon intact, which plain zip can break.
ditto -c -k --sequesterRsrc --keepParent build/Encore.app "$ZIP"

# A disk image with an Applications shortcut, so installing is one drag.
DMG="build/Encore-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R build/Encore.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Encore" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"

echo "Packaged $ZIP and $DMG"
