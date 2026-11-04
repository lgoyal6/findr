#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Leaf.app"
codesign --verify --deep --strict "$APP"
python3 - <<'PY'
import base64
import pathlib
import plistlib
import subprocess

app = pathlib.Path('dist/Leaf.app/Contents')
with (app / 'Info.plist').open('rb') as f:
    info = plistlib.load(f)
with pathlib.Path('config/updates.plist').open('rb') as f:
    expected = plistlib.load(f)
assert all(info.get(key) == value for key, value in expected.items()), 'Update configuration missing or changed'
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32, 'Invalid Ed25519 public key'
assert info['CFBundleDisplayName'] == 'Leaf'
assert info['CFBundleName'] == 'Leaf'
assert info['CFBundleExecutable'] == 'Leaf'
assert info['CFBundleIdentifier'] == 'io.github.lgoyal6.findr', 'Keep identity for existing installs'
assert (app / 'Resources/AppIcon.icns').is_file()
assert info['CFBundleVersion'] == info['CFBundleShortVersionString']
framework = app / 'Frameworks/Sparkle.framework'
assert (framework / 'Sparkle').is_file(), 'Sparkle framework missing'
assert (framework / 'Versions/Current/Updater.app').is_dir(), 'Sparkle updater helper missing'
links = subprocess.check_output(['otool', '-L', str(app / 'MacOS/Leaf')], text=True)
assert '@rpath/Sparkle.framework/' in links, 'Executable is not linked to Sparkle'
paths = subprocess.check_output(['otool', '-l', str(app / 'MacOS/Leaf')], text=True)
assert '@executable_path/../Frameworks' in paths, 'Bundled framework runpath missing'
print(f"Verified Leaf {info['CFBundleVersion']} with embedded Sparkle and signed-update configuration")
PY
hdiutil verify dist/Leaf.dmg >/dev/null
