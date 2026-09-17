#!/usr/bin/env bash
#
# Version consistency check.
#
# project.yml's MARKETING_VERSION is the only value the build actually reads.
# Everything else — the README badge, the ship-readiness doc — is hand-written
# and has drifted before: the badge sat at 1.0.4 while 1.0.7 shipped, and
# INSTALL.md told people to open a 1.0.0 DMG that never existed.
#
# Pure grep/awk on purpose: this runs first in CI, on a clean runner, before
# any toolchain is installed, so it fails in seconds rather than minutes.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
note() { printf '  %s\n' "$1"; fail=1; }

VERSION="$(awk -F'"' '/MARKETING_VERSION/ { print $2; exit }' project.yml)"
if [[ -z "$VERSION" ]]; then
  echo "FAIL: could not read MARKETING_VERSION from project.yml" >&2
  exit 1
fi
echo "project.yml MARKETING_VERSION = $VERSION"

# README version badge
if ! grep -q "version-${VERSION}-blue" README.md; then
  actual="$(grep -o 'version-[0-9][^-]*-blue' README.md | head -1 || echo '<none>')"
  note "README.md: badge is '${actual}', expected 'version-${VERSION}-blue'"
fi

# Ship-readiness title
if [[ -f docs/SHIP_READINESS.md ]] && ! head -1 docs/SHIP_READINESS.md | grep -q "v${VERSION}"; then
  note "docs/SHIP_READINESS.md: title is '$(head -1 docs/SHIP_READINESS.md)', expected to name v${VERSION}"
fi

# Changelog head, if one exists
if [[ -f CHANGELOG.md ]] && ! grep -qm1 "^## \[${VERSION}\]" CHANGELOG.md; then
  note "CHANGELOG.md: newest entry is not '## [${VERSION}]'"
fi

# No doc may hardcode a DMG filename for a different version.
while IFS= read -r hit; do
  note "stale DMG filename: $hit"
done < <(grep -rn 'MacCleanerPro-[0-9][0-9.]*\.dmg' docs README.md 2>/dev/null \
         | grep -v "MacCleanerPro-${VERSION}.dmg" || true)

if [[ $fail -ne 0 ]]; then
  echo
  echo "FAIL: version strings disagree with project.yml (${VERSION})." >&2
  exit 1
fi

echo "OK: all version strings agree."
