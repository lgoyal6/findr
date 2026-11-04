#!/bin/bash
# Builds Leaf.app and Leaf.dmg into dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must be a three-part version, such as 1.0.2" >&2
  exit 1
fi
APP="dist/Leaf.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build -c release
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Findr "$APP/Contents/MacOS/Leaf"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework \
  "$APP/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"

ICONSET="$WORK/AppIcon.iconset"
cat Sources/Findr/App/LeafLogo.swift scripts/make-icon.swift > "$WORK/make-icon.swift"
swift "$WORK/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Leaf</string>
  <key>CFBundleDisplayName</key><string>Leaf</string>
  <key>CFBundleIdentifier</key><string>io.github.lgoyal6.findr</string>
  <key>CFBundleExecutable</key><string>Leaf</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c 'Merge config/updates.plist' "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"

STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Leaf -srcfolder "$STAGE" -ov -format UDZO dist/Leaf.dmg >/dev/null
echo "Built $APP and dist/Leaf.dmg"
