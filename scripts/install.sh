#!/bin/sh
# Installs the user-session agent into the gui domain of the current user.
# No root required: everything lives inside the user's home directory.
set -eu

LABEL="org.eof.tools.MCPStudio.LaunchAgent"
AGENT_BIN="MCPStudioLaunchAgent"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")

BUILD_BIN="$PROJECT_DIR/.build/debug/$AGENT_BIN"
INSTALL_DIR="$HOME/Library/Application Support/$LABEL"
PLIST_TEMPLATE="$PROJECT_DIR/LaunchAgents/$LABEL.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# 1) Build the agent binary.
swift build --package-path "$PROJECT_DIR"

# 2) Install the binary into a user-writable location
#    (no /usr/local/libexec, no sudo - that is the key difference
#    to the LaunchDaemon/system-domain variant).
mkdir -p "$INSTALL_DIR"
cp "$BUILD_BIN" "$INSTALL_DIR/$AGENT_BIN"

# 3) Render the plist with the absolute agent path.
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__AGENT_PATH__|$INSTALL_DIR/$AGENT_BIN|" "$PLIST_TEMPLATE" > "$PLIST_DST"

# 4) (Re)register the job in the gui domain of the current user.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST_DST"

# Restart once so a possibly cached older binary is replaced immediately.
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "Installed and started $LABEL in domain $DOMAIN"
echo "Inspect with: launchctl print $DOMAIN/$LABEL"
