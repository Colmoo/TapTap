#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# TapTap SPU daemon uninstaller
# Run as: sudo TapTap.app/Contents/Resources/uninstall_daemon.sh
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root (use sudo)." >&2
    exit 1
fi

DAEMON_LABEL="com.colmo.taptap.spud"
DAEMON_PLIST_DST="/Library/LaunchDaemons/com.colmo.taptap.spud.plist"

echo "Uninstalling TapTap SPU daemon..."

# Unload the daemon (ignore errors if it was never loaded)
launchctl bootout system "$DAEMON_LABEL" 2>/dev/null || true

# Remove the LaunchDaemon plist
rm -f "$DAEMON_PLIST_DST"

# Remove the daemon binary and support directory
rm -rf "/Library/Application Support/TapTap"

echo ""
echo "TapTap SPU daemon removed successfully."
