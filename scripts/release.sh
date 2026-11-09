#!/bin/bash
# Publish a version already committed and merged to main.
set -euo pipefail
cd "$(dirname "$0")/.."

IF_NEEDED=false
if [[ "${1:-}" == "--if-needed" && "$#" == 1 ]]; then
  IF_NEEDED=true
elif [[ "$#" != 0 ]]; then
  echo "Usage: $0 [--if-needed]" >&2
  exit 1
fi

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
RELEASE="$(gh release view "v$VERSION" --json isDraft,targetCommitish \
  --jq '[.isDraft, .targetCommitish] | @tsv' 2>/dev/null || true)"
DRAFT=false
if [[ -n "$RELEASE" ]]; then
  IFS=$'\t' read -r DRAFT TARGET <<< "$RELEASE"
  if [[ "$DRAFT" != true ]]; then
    if [[ "$IF_NEEDED" == true ]]; then
      echo "Release v$VERSION is already published. Nothing to publish."
      exit 0
    fi
    echo "Release v$VERSION already exists. Bump VERSION before publishing." >&2
    exit 1
  fi
  if [[ "$TARGET" != "$HEAD_SHA" ]]; then
    echo "The draft release targets a different commit." >&2
    exit 1
  fi
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
(cd dist && shasum -a 256 Leaf.dmg > Leaf.dmg.sha256)
# Upload every file before changing the stable /releases/latest feed URL.
if [[ "$DRAFT" == true ]]; then
  gh release upload "v$VERSION" dist/Leaf.dmg dist/appcast.xml dist/Leaf.dmg.sha256 --clobber
else
  gh release create "v$VERSION" dist/Leaf.dmg dist/appcast.xml dist/Leaf.dmg.sha256 \
    --target "$HEAD_SHA" --title "Leaf $VERSION" --draft --generate-notes
fi
gh release edit "v$VERSION" --draft=false --latest
gh release view "v$VERSION" --json url --jq .url
