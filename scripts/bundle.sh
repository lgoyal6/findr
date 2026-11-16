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
cp .build/release/LeafBrowserHost "$APP/Contents/Resources/LeafBrowserHost"
mkdir -p "$APP/Contents/Resources/BrowserExtension"
cp BrowserExtension/{manifest.json,background.js,content.js,picker.js} "$APP/Contents/Resources/BrowserExtension/"

EXTENSION="$APP/Contents/PlugIns/LeafSafariExtension.appex"
mkdir -p "$EXTENSION/Contents/MacOS" "$EXTENSION/Contents/Resources"
cp BrowserExtension/Safari/Info.plist "$EXTENSION/Contents/Info.plist"
cp BrowserExtension/{background.js,content.js,picker.js} "$EXTENSION/Contents/Resources/"
python3 - "$EXTENSION/Contents/Resources/manifest.json" <<'PY'
import json,sys
from pathlib import Path
manifest = json.loads(Path('BrowserExtension/manifest.json').read_text())
manifest.pop('key', None)
manifest['background'] = {'scripts': ['background.js'], 'persistent': False}
Path(sys.argv[1]).write_text(json.dumps(manifest, indent=2) + '\n')
PY
xcrun swiftc -emit-executable -parse-as-library -module-name LeafSafariExtension \
  -target "$(uname -m)-apple-macosx14.0" -framework SafariServices -framework AppKit \
  Sources/LeafBrowserBridge/BrowserUploadSession.swift BrowserExtension/Safari/SafariWebExtensionHandler.swift \
  -o "$EXTENSION/Contents/MacOS/LeafSafariExtension" -Xlinker -e -Xlinker _NSExtensionMain

# PDFs are parsed in this sandboxed helper, never in Leaf itself.
XPC="$APP/Contents/XPCServices/LeafPDFReader.xpc"
mkdir -p "$XPC/Contents/MacOS"
cp .build/release/LeafPDFReader "$XPC/Contents/MacOS/LeafPDFReader"
cat > "$XPC/Contents/Info.plist" <<XPCPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.lgoyal6.findr.pdfreader</string>
  <key>CFBundleName</key><string>LeafPDFReader</string>
  <key>CFBundleExecutable</key><string>LeafPDFReader</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict>
</plist>
XPCPLIST
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
  <key>NSAppleEventsUsageDescription</key><string>Leaf uses System Events to choose files in apps whose upload dialogs require keyboard automation.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Leaf browser uploads</string>
    <key>CFBundleURLSchemes</key><array><string>leaf-upload</string></array>
  </dict></array>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c 'Merge config/updates.plist' "$APP/Contents/Info.plist"

# --deep signs Sparkle's nested helpers; then the PDF reader gets its sandbox
# entitlement, and the app is sealed again around it.
codesign --force --deep --sign - "$APP"
codesign --force --sign - --entitlements BrowserExtension/Safari/Extension.entitlements "$EXTENSION"
codesign --force --sign - --entitlements config/pdfreader.entitlements "$XPC"
codesign --force --sign - "$APP"

STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Leaf -srcfolder "$STAGE" -ov -format UDZO dist/Leaf.dmg >/dev/null
echo "Built $APP and dist/Leaf.dmg"
