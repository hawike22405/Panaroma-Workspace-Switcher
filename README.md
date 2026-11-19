# Panaroma Workspace Switcher

A 3D curved panorama workspace switcher and live gesture overlay designed for Hyprland and Quickshell.

## Features

- **Analytic 3D Cylinder View**: Projects active workspace snapshots along a curved cylinder using a dedicated GLSL fragment shader (`panorama.frag`).
- **Interactive Gestures**: Hooks into Hyprland touchpad gesture events for real-time workspace navigation.
- **Background Daemon**: Snapshot capture controller written in Python (`capture.py`), managing workspace capture caches via `grim`.
- **Desktop Shell**: Quickshell UI panels (`Overlay.qml`, `shell.qml`) that render on top of Wayland outputs without blocking keyboard focus or mouse interactions.
- **Service Management**: Optional user systemd service to run the daemon continuously.

## Prerequisites

- **Hyprland** (with Lua scripting API enabled)
- **Quickshell** (`qs` CLI available in PATH)
- **Grim** (for Wayland screen capture)
- **Python 3.10+**

## Installation

Clone the repository and run the included installer:

```bash
git clone https://github.com/hawike22405/Panaroma-Workspace-Switcher.git
cd Panaroma-Workspace-Switcher
./install.sh
```

To enable Hyprland 3-finger horizontal gestures:

```bash
ryoku-panorama enable-gestures
```

To run as a systemd user service:

```bash
systemctl --user enable --now ryoku-panorama.service
```

## Control Commands

```bash
ryoku-panorama start            # Launch the overlay daemon
ryoku-panorama stop             # Stop the overlay daemon
ryoku-panorama status           # View running daemon status
ryoku-panorama enable-gestures  # Configure Hyprland gesture bindings
ryoku-panorama disable-gestures # Restore native Hyprland gestures
ryoku-panorama doctor           # Validate environment dependencies
ryoku-panorama log              # View daemon execution logs
```

## Uninstallation

To cleanly disable gestures, stop services, and remove installed files:

```bash
./uninstall.sh
```

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) and [LICENSES.md](LICENSES.md) for details and third-party attributions.
