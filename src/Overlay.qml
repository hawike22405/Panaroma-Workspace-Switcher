import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

PanelWindow {
    id: win
    required property var modelData
    screen: modelData
    anchors { top: true; bottom: true; left: true; right: true }
    margins { left: win.insL; top: win.insT; right: win.insR; bottom: win.insB }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {} // empty input region: mouse and keyboard remain usable
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "ryoku-panorama"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Keep transparent surface mapped if keepMapped is enabled to eliminate recreation delay
    visible: Config.enabled && !failed && !specialVisible && (Config.keepMapped || (presenting && shown))

    readonly property string monName: modelData.name
    readonly property var mon: Hyprland.monitorFor(modelData)
    readonly property var ipc: mon && mon.lastIpcObject ? mon.lastIpcObject : ({})
    readonly property var reserved: ipc.reserved || [0, 0, 0, 0]
    readonly property int insL: Math.max(0, Config.insetLeft >= 0 ? Config.insetLeft : (reserved[0] || 0))
    readonly property int insT: Math.max(0, Config.insetTop >= 0 ? Config.insetTop : (reserved[1] || 0))
    readonly property int insR: Math.max(0, Config.insetRight >= 0 ? Config.insetRight : (reserved[2] || 0))
    readonly property int insB: Math.max(0, Config.insetBottom >= 0 ? Config.insetBottom : (reserved[3] || 0))
    readonly property bool specialVisible: !!(ipc.activeSpecialWorkspace && ipc.activeSpecialWorkspace.id !== 0)
    readonly property string geometryKey: [modelData.width, modelData.height, ipc.scale,
        ipc.transform, insL, insT, insR, insB].join(":")

    property bool initialized: false
    property bool failed: false
    property int epoch: 0
    property int lastWs: 0
    property var shots: ({}) // id -> { url: ..., time: ... }
    property int shotsRev: 0
    property var ring: []
    property real moveFrom: 0
    property real moveTo: 0
    property real prog: 1
    property bool presenting: false
    property bool holding: false
    property int pendingFrom: 0
    property int pendingTo: 0
    property bool wantHold: false
    property bool loadPending: false
    property int captureFailures: 0

    // Live gesture tracking
    property bool gestureLive: false
    property bool gestureSettling: false
    property int gestureToken: -1
    property real gestureBase: 0
    property real gestureOffset: 0
    property int gestureOrigin: 0
    property int gestureExpected: 0
    readonly property real gestureDistance: 300
    property real lastUpdateTime: 0
    property real lastUpdateOffset: 0
    property real recentVelocity: 0

    readonly property bool shown: holding || anim.running || gestureLive || gestureSettling || e > 0.003
    readonly property bool busy: shown || loadPending || gestureLive || gestureSettling
    readonly property real pos: (gestureLive || gestureSettling) ? gestureBase + gestureOffset : moveFrom + (moveTo - moveFrom) * ease(prog)
    readonly property real eTarget: (gestureLive || gestureSettling)
        ? Math.sin(Math.PI * Math.min(1, Math.abs(gestureOffset)))
        : (anim.running && prog < Config.clamp(Config.settle, .15, .85) ? 1 : 0)
    property real e: eTarget
    // Disable 170 ms shape smoothing during gesture tracking or settling; preserve for keyboard
    Behavior on e {
        enabled: !win.gestureLive && !win.gestureSettling
        NumberAnimation { duration: 170; easing.type: Easing.InOutSine }
    }

    function ease(t) { return t < .5 ? 4*t*t*t : 1-Math.pow(-2*t+2, 3)/2 }
    function activeId() { return mon && mon.activeWorkspace ? mon.activeWorkspace.id : 0 }
    function usable(id) { return id !== 0 && !specialVisible }

    function sameArray(a, b) {
        if (!a || !b || a.length !== b.length) return false
        for (let i = 0; i < a.length; ++i) if (a[i] !== b[i]) return false
        return true
    }

    function abort() {
        presenting = false
        gestureLive = false
        gestureSettling = false
        gestureAnim.stop()
        anim.stop()
        loadPending = false
        watchdog.stop()
        holding = false
        prog = 1
        moveFrom = moveTo
    }

    function invalidate() {
        if (!initialized) return
        epoch++
        abort()
        shots = ({})
        shotsRev++
        ring = []
        updateSlots()
        refreshSoon()
    }

    onGeometryKeyChanged: invalidate()
    onSpecialVisibleChanged: {
        if (!initialized) return
        epoch++
        abort()
        refreshSoon()
    }
    Connections {
        target: Config
        function onEnabledChanged() {
            if (!Config.enabled) win.invalidate()
            else win.refreshSoon()
        }
    }

    NumberAnimation {
        id: anim
        target: win
        property: "prog"
        from: 0
        to: 1
        duration: Config.clamp(Config.duration, 200, 1000)
        onFinished: { watchdog.stop(); win.refreshSoon(); win.syncIdleRing() }
    }
    Timer {
        id: watchdog
        interval: 1500
        onTriggered: { win.abort(); win.refreshSoon() }
    }
    Timer {
        id: holdTimeout
        interval: 300
        onTriggered: { if (win.holding && !anim.running) { win.abort(); win.refreshSoon() } }
    }
    NumberAnimation {
        id: gestureAnim
        target: win
        property: "gestureOffset"
        duration: 80
        easing.type: Easing.OutCubic
        onFinished: { win.abort(); win.refreshSoon(); win.syncIdleRing() }
    }

    function remember(id, url) {
        const copy = Object.assign({}, shots)
        copy[id] = { url: url, time: Date.now() }
        const ids = Object.keys(copy).sort((a,b) => copy[b].time - copy[a].time)
        for (let i = Config.cardLimit; i < ids.length; ++i) delete copy[ids[i]]
        shots = copy
        shotsRev++
        updateSlots()
        syncIdleRing()
    }
    function refreshSoon() { if (initialized) refreshTimer.restart() }
    function requestCapture() {
        const id = activeId()
        if (!Config.enabled || failed || busy || cap.running || !usable(id) ||
                !Config.cacheDir || !Config.dir || captureFailures >= 3) return
        cap.ws = id
        cap.generation = epoch
        cap.geometry = geometryKey
        cap.result = ""
        cap.exited = false
        cap.streamDone = false
        cap.command = ["python3", Config.dir + "/capture.py", "capture", monName,
            String(id), String(Math.round(Config.clamp(Config.maxWidth, 320, 1920))),
            String(insL), String(insT), String(insR), String(insB), String(Config.cardLimit)]
        cap.running = true
    }
    function finishCapture() {
        if (!cap.exited || !cap.streamDone) return
        const current = cap.generation === epoch && cap.ws === activeId() && cap.geometry === geometryKey && !busy
        if (cap.code === 0 && current) {
            try {
                const result = JSON.parse(cap.result)
                const prefix = "file://" + Config.cacheDir + "/s-"
                if (result.workspace !== cap.ws || !decodeURIComponent(result.url).startsWith(prefix)) throw new Error("Invalid capture response")
                remember(cap.ws, result.url)
                captureFailures = 0
            } catch (err) {
                captureFailures++
                console.warn("Panorama: discarded invalid capture response")
            }
        } else if (current) {
            captureFailures++
            if (captureFailures === 3) console.warn("Panorama: captures paused after three failures; restart after checking doctor/log")
        }
    }
    Process {
        id: cap
        property int ws: 0
        property int generation: 0
        property string geometry: ""
        property string result: ""
        property bool exited: false
        property bool streamDone: false
        property int code: -1
        stdout: StdioCollector {
            onStreamFinished: { cap.result = this.text; cap.streamDone = true; win.finishCapture() }
        }
        stderr: StdioCollector {
            onStreamFinished: { if (this.text.trim()) console.warn(this.text.trim()) }
        }
        onExited: (exitCode, exitStatus) => {
            cap.code = exitCode
            cap.exited = true
            win.finishCapture()
        }
    }
    Timer {
        id: refreshTimer
        interval: Config.clamp(Config.captureDelay, 300, 2000)
        onTriggered: win.requestCapture()
    }
    Timer {
        interval: Math.max(2000, Config.refreshMs)
        running: Config.enabled && Config.refreshMs > 0 && !win.busy && !win.failed && win.captureFailures < 3
        repeat: true
        onTriggered: win.refreshSoon()
    }

    function slotList() {
        return [im0, im1, im2, im3, im4, im5, im6, im7, im8, im9]
    }

    function updateSlots() {
        const slots = slotList()
        for (let i = 0; i < slots.length; ++i) {
            const im = slots[i]
            const wsId = i < ring.length ? ring[i] : -1
            if (wsId < 0 || !shots[wsId]) {
                im.boundWs = -1
                im.activeUrl = ""
                im.source = ""
                continue
            }
            const targetUrl = shots[wsId].url
            if (im.boundWs !== wsId) {
                // Different workspace: clear immediately so another workspace's image is never retained
                im.boundWs = wsId
                im.activeUrl = targetUrl
                im.source = targetUrl
            } else if (im.activeUrl !== targetUrl) {
                // Same workspace, updated capture URL: update source while retaining loaded image during refresh
                im.activeUrl = targetUrl
                im.source = targetUrl
            }
        }
    }

    function onSlotStatusChanged(index, status) {
        if (status !== Image.Ready) return
        if (gestureLive || gestureSettling) {
            if (index === ring.indexOf(gestureOrigin)) {
                win.presenting = true
            }
        }
        if (loadPending && imagesReady()) {
            loadPending = false
            commitPreparedSwitch()
        }
    }

    function getTargetRing(centerWs) {
        const cur = centerWs !== undefined ? centerWs : activeId()
        const existing = Hyprland.workspaces.values
            .filter(w => w.monitor && w.monitor.name === monName && w.id !== 0)
            .map(w => w.id)
        const map = {}
        for (let i = 0; i < existing.length; ++i) map[existing[i]] = true
        if (cur > 0) map[cur] = true
        if (cur > 1) map[cur - 1] = true
        map[cur + 1] = true
        const shotKeys = Object.keys(shots)
        for (let i = 0; i < shotKeys.length; ++i) {
            const sid = Number(shotKeys[i])
            if (sid > 0) map[sid] = true
        }
        const all = Object.keys(map).map(Number).sort((a,b) => a-b)
        if (all.length === 0) return [1, 2]
        const at = all.indexOf(cur)
        if (at < 0) return all.slice(0, Config.cardLimit)
        const limit = Math.max(2, Math.min(Config.cardLimit, all.length))
        if (all.length <= limit) return all
        const ids = []
        const half = Math.floor(limit / 2)
        for (let i = 0; i < limit; ++i)
            ids.push(all[(at - half + i + all.length) % all.length])
        return ids
    }

    function syncIdleRing() {
        if (busy || !usable(activeId())) return
        const ids = getTargetRing(activeId())
        if (!sameArray(ring, ids)) {
            ring = ids
            updateSlots()
        }
    }

    function buildRing(from, to) {
        const live = {}
        const workspaces = Hyprland.workspaces.values
        for (let i = 0; i < workspaces.length; ++i) {
            const w = workspaces[i]
            if (w.monitor && w.monitor.name === monName) live[w.id] = true
        }
        let ids = Object.keys(shots).map(Number).filter(id => live[id] || id === from || id === to)
        ids.sort((a,b) => a-b)
        return ids.slice(0, Config.cardLimit)
    }

    function imagesReady() {
        const slots = slotList()
        const a = ring.indexOf(pendingFrom), b = ring.indexOf(pendingTo)
        return a >= 0 && b >= 0 && slots[a].status !== Image.Loading && slots[b].status !== Image.Loading
    }

    function commitPreparedSwitch() {
        const from = win.ring.indexOf(win.pendingFrom)
        const to = win.ring.indexOf(win.pendingTo)
        win.moveFrom = from
        win.moveTo = to
        win.prog = 1
        win.presenting = true
        if (win.wantHold) {
            win.holding = true
            holdTimeout.restart()
        } else {
            let delta = to - from
            const n = win.ring.length
            if (Config.wrapAround && n >= 3) delta -= n * Math.round(delta / n)
            win.moveTo = from + delta
            win.holding = false
            win.prog = 0
            anim.start()
            watchdog.restart()
        }
    }

    function prepare() {
        if (!Config.enabled || !Config.preShow || failed || busy || cap.running || !usable(lastWs) || !shots[lastWs]) return
        const ids = buildRing(lastWs, lastWs)
        if (!sameArray(ring, ids)) {
            ring = ids
            updateSlots()
        }
        pendingFrom = lastWs
        pendingTo = lastWs
        wantHold = true
        moveFrom = ring.indexOf(lastWs)
        moveTo = moveFrom
        prog = 1
        if (imagesReady()) {
            commitPreparedSwitch()
        } else {
            loadPending = true
        }
    }

    function onSwitched() {
        const to = activeId(), from = lastWs
        if (to === from) return
        epoch++
        lastWs = to
        holdTimeout.stop()
        if (gestureLive || gestureSettling) {
            if ((gestureLive && to !== gestureOrigin) || (gestureSettling && gestureExpected !== 0 && to !== gestureExpected)) abort()
            refreshSoon()
            return
        }
        abort()
        if (!Config.enabled || failed || !usable(from) || !usable(to) || !shots[from] || !shots[to]) {
            refreshSoon()
            syncIdleRing()
            return
        }
        const ids = buildRing(from, to)
        if (!sameArray(ring, ids)) {
            ring = ids
            updateSlots()
        }
        pendingFrom = from
        pendingTo = to
        wantHold = false
        if (imagesReady()) {
            commitPreparedSwitch()
        } else {
            loadPending = true
        }
        refreshSoon()
    }

    Connections {
        target: win.mon
        function onActiveWorkspaceChanged() { win.onSwitched() }
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            switch (event.name) {
            case "openwindow": case "closewindow": case "movewindowv2":
            case "activewindowv2": case "fullscreen": case "changefloatingmode":
                win.refreshSoon(); win.syncIdleRing(); break
            case "activespecial": case "activespecialv2":
                win.invalidate(); Hyprland.refreshMonitors(); break
            case "openlayer": case "closelayer":
                if (String(event.data).indexOf("ryoku-panorama") < 0) insetsTimer.restart()
                break
            case "configreloaded": case "monitoraddedv2": case "monitorremoved":
                win.invalidate(); insetsTimer.restart(); break
            }
        }
    }
    Timer { id: insetsTimer; interval: 400; onTriggered: Hyprland.refreshMonitors() }
    Timer {
        interval: 500
        repeat: true
        running: win.lastWs === 0
        onTriggered: {
            const id = win.activeId()
            if (id !== 0) { win.lastWs = id; win.refreshSoon(); win.syncIdleRing() }
        }
    }
    Component.onCompleted: {
        initialized = true
        syncIdleRing()
        refreshSoon()
    }
    Component.onDestruction: { cap.running = false }

    function gestureEvent(phase, token, total, cancelled) {
        if (phase === "start") {
            abort()
            if (!Config.enabled || failed || !usable(activeId())) return
            epoch++
            gestureToken = token
            gestureOrigin = activeId()
            lastWs = gestureOrigin
            const ids = getTargetRing(gestureOrigin)
            if (ids.length < 2) return
            if (!sameArray(ring, ids)) {
                ring = ids
                updateSlots()
            }
            gestureBase = ring.indexOf(gestureOrigin)
            gestureExpected = 0
            gestureOffset = Config.clamp(-total / gestureDistance, -0.999, 0.999)
            lastUpdateTime = Date.now()
            lastUpdateOffset = gestureOffset
            recentVelocity = 0
            gestureLive = true
            win.presenting = true

            watchdog.restart()
            return
        }
        if (token !== gestureToken || !gestureLive) return
        const now = Date.now()
        const newOffset = Config.clamp(-total / gestureDistance, -0.999, 0.999)
        const dt = now - lastUpdateTime
        if (dt > 4) {
            const v = Math.abs(newOffset - lastUpdateOffset) / dt
            recentVelocity = recentVelocity > 0 ? (recentVelocity * 0.4 + v * 0.6) : v
            lastUpdateTime = now
            lastUpdateOffset = newOffset
        }
        gestureOffset = newOffset
        watchdog.restart()

        if (phase === "finish") {
            gestureLive = false
            gestureSettling = true
            const target = !cancelled && Math.abs(total) >= gestureDistance * 0.20 ? (total < 0 ? 1 : -1) : 0
            const n = ring.length
            gestureExpected = target === 0 ? gestureOrigin : ring[(gestureBase + target + n) % n]
            // Settling duration calculated dynamically based on remaining distance and recent velocity (45-125ms)
            const rem = Math.abs(target - gestureOffset)
            const baseDur = rem * 140
            const speedFactor = 1.0 + Math.min(2.5, recentVelocity * 350)
            const dur = Math.round(baseDur / speedFactor + 35)
            gestureAnim.duration = Math.max(45, Math.min(125, dur))
            gestureAnim.to = target
            gestureAnim.restart()
        }
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        // Shader hidden at rest to save GPU cycles while overlay surface remains mapped
        visible: win.shown && win.presenting && !win.failed
        readonly property real n: Math.max(1, Math.min(10, win.ring.length))
        readonly property real pitchPx: Math.max(1, width) * (1 + Config.clamp(Config.gap, 0, .25))
        readonly property real kFull: Math.min(2*Math.PI/(n*pitchPx), .9/pitchPx) * Config.clamp(Config.curve, 0, 1)
        property size resolution: Qt.size(Math.max(1, width), Math.max(1, height))
        property color backdrop: Config.backdrop
        property color placeholder: Config.placeholder
        property real scroll: win.pos * pitchPx
        property real kappa: kFull * win.e
        property real dist: 1 / Math.max(kFull, 1e-4)
        property real zoom: 1 - Config.clamp(Config.zoomOut, 0, .75) * win.e
        property real cardW: Math.max(1, width * (1 - Config.clamp(Config.shrink, 0, .35) * win.e))
        property real cardH: Math.max(1, height * (1 - Config.clamp(Config.shrink, 0, .35) * win.e))
        property real pitch: pitchPx
        property real count: n
        property real radius: Config.clamp(Config.cornerRadius, 0, 100) * win.e
        property real depthFade: Config.clamp(Config.depthFade, 0, 1)

        property variant src0: Image { id: im0; property int boundWs: -1; property string activeUrl: ""; cache: true; asynchronous: true; visible: false; onStatusChanged: win.onSlotStatusChanged(0, status) }
        property variant src1: Image { id: im1; property int boundWs: -1; property string activeUrl: ""; cache: true; asynchronous: true; visible: false; onStatusChanged: win.onSlotStatusChanged(1, status) }
        property variant src2: Image { id: im2; property int boundWs: -1; property string activeUrl: ""; cache: true; asynchronous: true; visible: false; onStatusChanged: win.onSlotStatusChanged(2, status) }
        property variant src3: Image { id: im3; property int boundWs: -1; property string activeUrl: ""; cache: true; asynchronous: true; visible: false; onStatusChanged: win.onSlotStatusChanged(3, status) }
        property variant src4: Image { id: im4; property int boundWs: -1; property string activeUrl: ""; cache: true; asynchronous: true; visible: false; onStatusChanged: win.onSlotStatusChanged(4, status) }
        property variant src5: Image { id: im5; property int boundWs: -1; property string activeUrl: ""; cache: true; asynchronous: true; visible: false; onStatusChanged: win.onSlotStatusChanged(5, status) }
        property variant src6: Image { id: im6; property int boundWs: -1; property string activeUrl: ""; cache: true; asynchronous: true; visible: false; onStatusChanged: win.onSlotStatusChanged(6, status) }
        property variant src7: Image { id: im7; property int boundWs: -1; property string activeUrl: ""; cache: true; asynchronous: true; visible: false; onStatusChanged: win.onSlotStatusChanged(7, status) }
        property variant src8: Image { id: im8; property int boundWs: -1; property string activeUrl: ""; cache: true; asynchronous: true; visible: false; onStatusChanged: win.onSlotStatusChanged(8, status) }
        property variant src9: Image { id: im9; property int boundWs: -1; property string activeUrl: ""; cache: true; asynchronous: true; visible: false; onStatusChanged: win.onSlotStatusChanged(9, status) }

        fragmentShader: Qt.resolvedUrl("panorama.frag.qsb")
        onStatusChanged: {
            if (status === ShaderEffect.Error) {
                console.warn("Panorama shader failed: " + log)
                win.failed = true
                win.abort()
            }
        }
    }
}
