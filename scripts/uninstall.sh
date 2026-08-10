#!/bin/sh
# Removes the user-session agent from the gui domain of the current user.
set -eu

LABEL="org.eof.tools.MCPStudio.LaunchAgent"
INSTALL_DIR="$HOME/Library/Application Support/$LABEL"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# 1) Unregister the job from launchd (sends SIGTERM to a running agent).
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

# 2) Remove plist and installed binary.
rm -f "$PLIST_DST"
rm -rf "$INSTALL_DIR"

echo "Removed $LABEL from domain $DOMAIN"
