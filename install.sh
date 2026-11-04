#!/bin/bash
# Build and install Leaf from this checkout without sudo.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Leaf requires macOS 14 or later." >&2
  exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 14 )); then
  echo "Leaf requires macOS 14 or later." >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
  echo "Install Apple's developer tools with: xcode-select --install" >&2
  echo "After installation finishes, run ./install.sh again." >&2
  exit 1
fi
SWIFT_MAJOR="$(swift --version | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -n 1)"
if [[ -z "$SWIFT_MAJOR" ]] || (( SWIFT_MAJOR < 6 )); then
  echo "Leaf needs Swift 6 or later. Update Xcode or the Command Line Tools, then retry." >&2
  exit 1
fi
if pgrep -x Leaf >/dev/null || pgrep -x findr >/dev/null; then
  echo "Quit Leaf (or findr) from its menu-bar menu, then run ./install.sh again." >&2
  exit 1
fi

DEST="/Applications"
if [[ -d "$HOME/Applications/Leaf.app" ]] || [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
fi
TARGET="$DEST/Leaf.app"
if [[ -e "$TARGET" ]]; then
  ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$ID" != io.github.lgoyal6.findr ]]; then
    echo "Another app already exists at $TARGET. It has not been changed." >&2
    exit 1
  fi
fi

./scripts/bundle.sh
./scripts/check-bundle.sh
mkdir -p "$DEST"
WORK="$(mktemp -d "$DEST/.leaf-install.XXXXXX")"
cleanup() {
  if [[ -d "$WORK/previous.app" ]] && [[ ! -e "$TARGET" ]]; then
    mv "$WORK/previous.app" "$TARGET"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

ditto dist/Leaf.app "$WORK/Leaf.app"
codesign --verify --deep --strict "$WORK/Leaf.app"
if [[ -e "$TARGET" ]]; then
  mv "$TARGET" "$WORK/previous.app"
fi
mv "$WORK/Leaf.app" "$TARGET"
echo "Installed Leaf $(cat VERSION) at $TARGET"
echo "Open Leaf from Applications, then press Command-Shift-Space to search."
echo "If macOS blocks the first launch, use System Settings > Privacy & Security > Open Anyway."
