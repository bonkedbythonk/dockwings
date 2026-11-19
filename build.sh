#!/bin/zsh
# Builds DockWings.app into build/. Signs with the first Apple Development
# identity so macOS keeps the Accessibility/Reminders grants across rebuilds;
# falls back to ad-hoc signing (grants then reset on every build).
# `./build.sh --install` also replaces /Applications/DockWings.app and opens it.
# `./build.sh --release` builds for Apple silicon and Intel, signs ad-hoc and
# leaves out the local buddy packs (Scripts/release.sh uses it).
set -e
cd "$(dirname "$0")"
APP=build/DockWings.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ $1 == --release ]]; then
  swift build -c release --arch arm64 --arch x86_64
  cp .build/out/Products/Release/DockWings "$APP/Contents/MacOS/"
else
  swift build -c release
  cp .build/release/DockWings "$APP/Contents/MacOS/"
fi
cp Info.plist "$APP/Contents/"
cp docs/zsh-hook.zsh "$APP/Contents/Resources/"
[[ -f art/shimeji_catalog.json ]] && cp art/shimeji_catalog.json "$APP/Contents/Resources/"
[[ -d art/Buddies && $1 != --release ]] && cp -R art/Buddies "$APP/Contents/Resources/"
[[ -f art/AppIcon.icns ]] && cp art/AppIcon.icns "$APP/Contents/Resources/"
IDENTITY=$(security find-identity -p codesigning -v | awk '/Apple Development/ {print $2; exit}')
[[ $1 == --release ]] && IDENTITY=-
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "$APP"
if [[ $1 == --install ]]; then
  # With the background agent on, launchd owns DockWings: swap the app and
  # let launchd restart it (killing it first would just respawn the old one).
  if launchctl print "gui/$UID/local.dockwings.login" >/dev/null 2>&1; then
    rm -rf /Applications/DockWings.app
    ditto "$APP" /Applications/DockWings.app
    launchctl kickstart -k "gui/$UID/local.dockwings.login"
  else
    pkill -x DockWings && sleep 1
    rm -rf /Applications/DockWings.app
    ditto "$APP" /Applications/DockWings.app
    open /Applications/DockWings.app
  fi
fi
