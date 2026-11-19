import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

ShellRoot {
    id: root
    property var gestureOverlay: null
    Variants {
        id: panels
        model: Quickshell.screens
        delegate: Overlay {}
    }
    function focusedOverlay() {
        const monitor = Hyprland.focusedMonitor
        if (!monitor) return null
        const instances = panels.instances
        for (let i = 0; i < instances.length; ++i)
            if (instances[i].monName === monitor.name) return instances[i]
        return null
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "monitorremoved" || event.name === "configreloaded") {
                root.gestureOverlay = null
                return
            }
            if (event.name !== "custom") return
            const parts = String(event.data).split(",")
            if (parts.length < 5 || parts[0] !== "panorama_v2") return
            const phase = parts[1], token = Number(parts[2]), total = Number(parts[3])
            if (!isFinite(token) || !isFinite(total) || Math.abs(total) > 1000000) return
            if (phase === "start") root.gestureOverlay = root.focusedOverlay()
            const overlay = root.gestureOverlay
            if (overlay) overlay.gestureEvent(phase, token, total, parts[4] === "1")
            if (phase === "finish") root.gestureOverlay = null
        }
    }
    IpcHandler {
        target: "panorama"
        function ping(): string { return "ready" }
        function prepare(): void {
            const overlay = root.focusedOverlay()
            if (overlay) overlay.prepare()
        }
    }
}
