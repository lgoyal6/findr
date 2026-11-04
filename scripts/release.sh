#!/bin/bash
# Publish a version already committed and merged to main. Signing stays in Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit and merge the release changes before publishing." >&2
  exit 1
fi
HEAD_SHA="$(git rev-parse HEAD)"
if [[ "$HEAD_SHA" != "$(gh api repos/lgoyal6/findr/commits/main --jq .sha)" ]]; then
  echo "Publish from the current main commit." >&2
  exit 1
fi
VERSION="$(cat VERSION)"
if gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists. Bump VERSION before publishing." >&2
  exit 1
fi
LATEST="$(gh api repos/lgoyal6/findr/releases/latest --jq .tag_name)"
python3 - "$VERSION" "$LATEST" <<'PY'
import re, sys
def version(value):
    if not re.fullmatch(r'v?\d+\.\d+\.\d+', value):
        raise SystemExit(f'Expected a three-part release version: {value}')
    return tuple(map(int, value.lstrip('v').split('.')))
if version(sys.argv[1]) <= version(sys.argv[2]):
    raise SystemExit('VERSION must be greater than the latest release.')
PY
./scripts/bundle.sh
./scripts/check-bundle.sh
./scripts/appcast.sh
# Upload both files before changing the stable /releases/latest feed URL.
gh release create "v$VERSION" dist/findr.dmg dist/appcast.xml \
  --target "$HEAD_SHA" --title "findr $VERSION" --draft --generate-notes
gh release edit "v$VERSION" --draft=false --latest
gh release view "v$VERSION" --json url --jq .url
