#!/usr/bin/env bash
# Panaroma Workspace Switcher Uninstaller
set -euo pipefail

TARGET_SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/ryoku-panorama"
BIN_FILE="${HOME}/.local/bin/ryoku-panorama"
SERVICE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ryoku-panorama.service"

echo "=== Uninstalling Panaroma Workspace Switcher ==="

# Stop and disable systemd service if active
if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user is-active ryoku-panorama.service >/dev/null 2>&1; then
        echo "Stopping systemd service..."
        systemctl --user stop ryoku-panorama.service || true
    fi
    if systemctl --user is-enabled ryoku-panorama.service >/dev/null 2>&1; then
        echo "Disabling systemd service..."
        systemctl --user disable ryoku-panorama.service || true
    fi
fi

# Disable gestures if binary still exists
if [[ -x "$BIN_FILE" ]]; then
    echo "Disabling Hyprland gestures..."
    "$BIN_FILE" disable-gestures 2>/dev/null || true
fi

# Remove binary symlink
if [[ -L "$BIN_FILE" || -f "$BIN_FILE" ]]; then
    echo "Removing $BIN_FILE..."
    rm -f "$BIN_FILE"
fi

# Remove systemd service file
if [[ -f "$SERVICE_FILE" ]]; then
    echo "Removing $SERVICE_FILE..."
    rm -f "$SERVICE_FILE"
    systemctl --user daemon-reload || true
fi

# Remove installed share files
if [[ -d "$TARGET_SHARE" ]]; then
    echo "Removing $TARGET_SHARE..."
    rm -rf "$TARGET_SHARE"
fi

echo "Uninstallation complete!"
