#!/bin/bash
# Installs or updates DockWings from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/dockwings/main/Scripts/install.sh | bash
#
# Only uses what ships with macOS (curl, ditto, xattr, osascript).
# For testing the script itself: DOCKWINGS_ZIP=<local zip> skips the download,
# DOCKWINGS_NO_OPEN=1 skips launching, DOCKWINGS_INSTALL_DIR picks the folder.
set -euo pipefail

REPO="bonkedbythonk/dockwings"
DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/DockWings.zip"
INSTALL_DIR="${DOCKWINGS_INSTALL_DIR:-/Applications}"

say() { printf '%s\n' "$*"; }

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "${MACOS_MAJOR:-0}" -lt 26 ]; then
    say "DockWings needs macOS 26 or later. This Mac runs $(sw_vers -productVersion)."
    exit 1
fi

# Standard (non-admin) accounts can't write /Applications.
if [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    say "Installing to $INSTALL_DIR, since this account can't write to /Applications."
fi
APP="$INSTALL_DIR/DockWings.app"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading DockWings..."
if [ -n "${DOCKWINGS_ZIP:-}" ]; then
    cp "$DOCKWINGS_ZIP" "$TMP/DockWings.zip"
elif ! curl -fL --progress-bar -o "$TMP/DockWings.zip" "$DOWNLOAD_URL"; then
    say "The download didn't work. Check your connection, or get it by hand from"
    say "  https://github.com/$REPO/releases"
    exit 1
fi

ditto -x -k "$TMP/DockWings.zip" "$TMP"
if [ ! -d "$TMP/DockWings.app" ]; then
    say "The download doesn't contain DockWings.app. Please report it at https://github.com/$REPO/issues"
    exit 1
fi

# Quit a running copy so the update can replace it. With "Open at login" on,
# launchd restarts DockWings after a crash but not after a normal quit.
if [ -z "${DOCKWINGS_NO_OPEN:-}" ] && pgrep -xq DockWings; then
    say "Quitting the running DockWings..."
    osascript -e 'tell application "DockWings" to quit' >/dev/null 2>&1 || pkill -x DockWings || true
    sleep 1
fi

rm -rf "$APP"
ditto "$TMP/DockWings.app" "$APP"
# DockWings isn't notarized. Without this, macOS blocks the first launch.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")"
say "Installed DockWings ${VERSION} in $INSTALL_DIR."

[ -n "${DOCKWINGS_NO_OPEN:-}" ] || open "$APP"
