#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# TapTap SPU daemon installer
# Run as: sudo TapTap.app/Contents/Resources/install_daemon.sh
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root (use sudo)." >&2
    exit 1
fi

# Resolve the app bundle from the script's own location:
#   TapTap.app/Contents/Resources/install_daemon.sh
#                    ^^       ^^
#   ../.. from Resources/ lands at TapTap.app/Contents/
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_CONTENTS="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPERS_DIR="$BUNDLE_CONTENTS/Helpers"
RESOURCES_DIR="$SCRIPT_DIR"

DAEMON_BINARY_SRC="$HELPERS_DIR/TapTapSPU"
DAEMON_PLIST_SRC="$RESOURCES_DIR/com.colmo.taptap.spud.plist"

INSTALL_DIR="/Library/Application Support/TapTap"
DAEMON_BINARY_DST="$INSTALL_DIR/TapTapSPU"
DAEMON_PLIST_DST="/Library/LaunchDaemons/com.colmo.taptap.spud.plist"
DAEMON_LABEL="com.colmo.taptap.spud"

# Validate source files exist
if [ ! -f "$DAEMON_BINARY_SRC" ]; then
    echo "Error: TapTapSPU binary not found at '$DAEMON_BINARY_SRC'." >&2
    echo "Make sure you are running this script from inside the TapTap.app bundle." >&2
    exit 1
fi

if [ ! -f "$DAEMON_PLIST_SRC" ]; then
    echo "Error: daemon plist not found at '$DAEMON_PLIST_SRC'." >&2
    exit 1
fi

echo "Installing TapTap SPU daemon..."

# Create install directory
mkdir -p "$INSTALL_DIR"

# Copy and secure the daemon binary
cp "$DAEMON_BINARY_SRC" "$DAEMON_BINARY_DST"
chmod 755 "$DAEMON_BINARY_DST"
chown root:wheel "$DAEMON_BINARY_DST"

# Copy and secure the LaunchDaemon plist
cp "$DAEMON_PLIST_SRC" "$DAEMON_PLIST_DST"
chmod 644 "$DAEMON_PLIST_DST"
chown root:wheel "$DAEMON_PLIST_DST"

# Unload any existing instance (ignore errors if not loaded)
launchctl bootout system "$DAEMON_LABEL" 2>/dev/null || true

# Load the new daemon
launchctl bootstrap system "$DAEMON_PLIST_DST"

echo ""
echo "TapTap SPU daemon installed and started successfully."
echo "Open TapTap from your Applications folder (or menu bar) to begin using it."
