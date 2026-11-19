#!/bin/zsh
# Builds DockWings.zip and publishes it as a GitHub release for the version in
# Info.plist (CFBundleShortVersionString). Usage: Scripts/release.sh [notes-file]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "$TAG already exists. Bump CFBundleShortVersionString in Info.plist first." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first; the release is built from HEAD." >&2
  exit 1
fi

./build.sh --release
rm -f build/DockWings.zip
# install.sh downloads releases/latest/download/DockWings.zip, so the name never changes.
ditto -c -k --sequesterRsrc --keepParent build/DockWings.app build/DockWings.zip

NOTES=(--generate-notes)
[[ $# -ge 1 ]] && NOTES=(--notes-file "$1")

git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" build/DockWings.zip --title "DockWings $VERSION" "${NOTES[@]}"
