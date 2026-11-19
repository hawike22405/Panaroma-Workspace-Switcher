pragma Singleton
import QtQuick
import Quickshell

Singleton {
    // Restart Panorama after editing. Optional live-gesture integration is managed separately by enable/disable-gestures.
    readonly property bool enabled: true
    readonly property int duration: 650
    readonly property real settle: 0.5
    readonly property bool wrapAround: true
    readonly property bool preShow: true
    readonly property bool keepMapped: true // keeps input-transparent surface mapped at rest with shader hidden
    readonly property int maxCards: 8       // clamped to 2..10
    readonly property int refreshMs: 5000  // 0 disables periodic screenshots
    readonly property int captureDelay: 600 // allow native animations to finish

    readonly property real curve: 1.0
    readonly property real gap: 0.04
    readonly property real shrink: 0.10
    readonly property real zoomOut: 0.45
    readonly property real cornerRadius: 24
    readonly property real depthFade: 0.60
    readonly property color backdrop: "#000000"
    readonly property color placeholder: "#16161b"
    readonly property int maxWidth: 1600    // additionally capped at 1920x1080
    readonly property int insetLeft: -1
    readonly property int insetTop: -1
    readonly property int insetRight: -1
    readonly property int insetBottom: -1

    readonly property string dir: Quickshell.env("RYOKU_PANORAMA_DIR")
    readonly property string cacheDir: Quickshell.env("RYOKU_PANORAMA_CACHE")
    readonly property int cardLimit: Math.max(2, Math.min(10, maxCards))
    function clamp(value, low, high) {
        return isFinite(value) ? Math.max(low, Math.min(high, value)) : low
    }
}
