#!/usr/bin/env bash
# Panaroma Workspace Switcher Installer
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SRC_DIR="$SCRIPT_DIR/src"
TARGET_SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/ryoku-panorama"
CURRENT_DIR="$TARGET_SHARE/current"
BIN_DIR="${HOME}/.local/bin"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

echo "=== Installing Panaroma Workspace Switcher ==="

mkdir -p "$CURRENT_DIR" "$BIN_DIR" "$SERVICE_DIR"

# Copy source files
echo "Installing application files to $CURRENT_DIR..."
cp -r "$SRC_DIR"/* "$CURRENT_DIR/"
chmod +x "$CURRENT_DIR/ryoku-panorama" "$CURRENT_DIR/capture.py"

# Symlink executable
echo "Creating binary symlink in $BIN_DIR..."
ln -sf "$CURRENT_DIR/ryoku-panorama" "$BIN_DIR/ryoku-panorama"

# Install systemd service
if [[ -f "$SCRIPT_DIR/systemd/ryoku-panorama.service" ]]; then
    echo "Installing systemd user service..."
    cp "$SCRIPT_DIR/systemd/ryoku-panorama.service" "$SERVICE_DIR/ryoku-panorama.service"
    systemctl --user daemon-reload || true
fi

echo ""
echo "Installation complete!"
echo "Usage:"
echo "  ryoku-panorama start            Start the overlay daemon"
echo "  ryoku-panorama stop             Stop the overlay daemon"
echo "  ryoku-panorama enable-gestures  Enable Hyprland 3-finger swipe integration"
echo "  ryoku-panorama status           Check daemon status"
echo ""
echo "To enable as systemd service:"
echo "  systemctl --user enable --now ryoku-panorama.service"
