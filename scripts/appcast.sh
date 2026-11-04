#!/bin/bash
# Build a signed update feed for the DMG produced by bundle.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLS=".build/artifacts/sparkle/Sparkle/bin"
ACCOUNT="io.github.lgoyal6.findr"
APP="dist/findr.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
if [[ "$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)" != "$PUBLIC_KEY" ]]; then
  echo "The Keychain signing key does not match this app's public key." >&2
  exit 1
fi

"$TOOLS/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/lgoyal6/findr/releases/download/v${VERSION}/" \
  --link https://github.com/lgoyal6/findr -o dist/appcast.xml dist
"$TOOLS/sign_update" --account "$ACCOUNT" --verify dist/appcast.xml
SIGNATURE="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
root = ET.parse('dist/appcast.xml')
print(root.find('./channel/item/enclosure').attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'])
PY
)"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify dist/findr.dmg "$SIGNATURE"
echo "Verified dist/appcast.xml and its signed DMG"
