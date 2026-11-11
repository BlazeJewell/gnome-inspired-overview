pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Caelestia.Config
import Caelestia.Layouts
import qs.components
import qs.components.containers
import qs.components.images
import qs.services
import "."

StyledWindow {
    id: win

    required property var ov
    readonly property Item grabItem: content
    property bool showThumbIcons: true

    readonly property bool isActive: ov.activeScreen === "" || ov.activeScreen === screen.name
    readonly property bool shown: ov.open

    // 0 → 1 as the overview opens; drives the fade and the zoom of the windows.
    property real progress: shown ? 1 : 0

    // ---- Responsive metrics -------------------------------------------------
    readonly property real s: Math.max(0.7, Math.min(1.7, Math.min(width / 1920, height / 1080) * 1.15))
    readonly property real margin: Math.round(28 * s)
    readonly property real stripTop: Math.round(22 * s)
    readonly property real stripHeight: Math.round(Math.max(64, Math.min(170, height * 0.105)))
    readonly property real windowsTop: stripTop + stripHeight + Math.round(26 * s)
    /// Space the open launcher needs at the bottom of this window, gap included,
    /// taken from its final size rather than its animated position.
    readonly property real launcherTarget: launcherShown ? Math.max(0, _launcherTargetHeight + _reserveOffset) + Math.round(20 * s) : 0
    /// What the windows actually lay out around. It only changes once the
    /// launcher has finished sliding in (or out), so the two never animate at
    /// the same time: the launcher opens, then the windows make one move.
    property real launcherReserve: 0
    /// The windows use the whole area; the open launcher is an obstacle they
    /// flow around (above it, and beside it if there is room) rather than a
    /// strip cut off the bottom.
    readonly property real windowsBottom: height - margin
    readonly property real windowsAreaHeight: Math.max(0, windowsBottom - windowsTop)
    /// The launcher's left and right edges in this window, measured once it
    /// has settled; -1 until then (it is then taken to be centred).
    property real launcherLeft: -1
    property real launcherRight: -1

    // ---- Workspace state ----------------------------------------------------
    readonly property int activeWsId: {
        const perOutput = Kwin.activeByOutput[screen.name];
        if (perOutput > 0)
            return perOutput;
        return Kwin.activeWsId > 0 ? Kwin.activeWsId : 1;
    }
    readonly property var currentWindows: {
        const _t = Kwin.windowList;
        return windowsOn(activeWsId);
    }
    property int selectedIndex: -1
    /// The shell's reserved edges on this output, used to line the backdrop up
    /// with the real wallpaper behind the border.
    readonly property var exclusions: {
        const _m = Visibilities.exclusions;
        return Visibilities.exclusionsFor(screen);
    }
    property bool dragging: false
    /// The workspace strip's window previews by address. Each window streams
    /// once, to its thumbnail, and the big cards mirror that: a second stream
    /// of a window gets no frame until the window next repaints, and swapping
    /// streams on every workspace switch made the thumbnails flicker.
    property var thumbPreviews: ({})

    function _setThumbPreview(address: string, item: Item): void {
        if (!address || !item)
            return;
        const map = Object.assign({}, thumbPreviews);
        map[address] = item;
        thumbPreviews = map;
    }

    /// Only if it is still this preview's: a rebuilt one may have taken over.
    function _clearThumbPreview(address: string, item: Item): void {
        if (!address || thumbPreviews[address] !== item)
            return;
        const map = Object.assign({}, thumbPreviews);
        delete map[address];
        thumbPreviews = map;
    }

    // ---- Pointer while the launcher is open --------------------------------
    // The open launcher covers the screen with the shell's own window to catch
    // clicks outside it, so this window stops seeing the pointer. A probe with
    // passive handlers is put into that window instead: it watches the pointer
    // without taking anything away from the launcher.
    property var _pointerProbe: null
    /// The window card under the pointer while the probe is in charge.
    property int probeIndex: -1
    /// The last pointer position this window saw, in screen coordinates (the
    /// shell window's), so the probe can tell a real move from a repeat.
    property point lastPointer: Qt.point(-1, -1)

    function _startProbe(): void {
        if (_pointerProbe || !isActive)
            return;
        const host = _shellRoot();
        if (host)
            _pointerProbe = probeComp.createObject(host);
    }

    function _stopProbe(): void {
        if (_pointerProbe)
            _pointerProbe.destroy();
        _pointerProbe = null;
        probeIndex = -1;
    }

    /// Which card is at a point in the shell window's coordinates (which are
    /// the screen's), or -1.
    function _cardAt(sx: real, sy: real): int {
        const p = windowsArea.mapFromItem(content, sx - (exclusions?.leftExclusion ?? 0), sy - (exclusions?.topExclusion ?? 0));
        const wins = currentWindows;
        const layout = windowsArea.layout;
        for (let i = 0; i < wins.length; i++) {
            const r = layout ? layout[wins[i].address] : null;
            if (r && p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height)
                return i;
        }
        return -1;
    }

    // ---- The shell's launcher ----------------------------------------------
    // The launcher lives in the shell's own drawer window, which a plugin has no
    // handle on, so it is found by walking up from this output's bar.
    // Both are looked up once and cached: the launcher keeps its content loaded
    // after first use, and walking the shell's item tree is not free.
    property Item _launcherContent: null
    property Item _launcherField: null
    /// The launcher's drawer wrapper, whose offsetScale runs 1 → 0 as it opens.
    property Item _launcherWrapper: null
    /// Measured difference between this window's bottom edge and the launcher's,
    /// refined once the launcher has settled; 0 when both sit on the border.
    property real _reserveOffset: 0
    readonly property real _launcherTargetHeight: launcherShown && _launcherContent ? _launcherContent.implicitHeight : 0
    readonly property bool launcherShown: shown && Visibilities.launcherOpen && _launcherContent !== null

    function _alive(item: var): bool {
        try {
            return item !== null && item !== undefined && item.parent !== null && item.parent !== undefined;
        } catch (e) {
            return false;
        }
    }

    function _shellRoot(): var {
        let it = Visibilities.bars.get(screen.name);
        if (!it)
            return null;
        while (it.parent)
            it = it.parent;
        return it;
    }

    function _findItem(node: var, pred: var, depth: int): var {
        if (!node || depth > 60)
            return null;
        if (pred(node))
            return node;
        const kids = node.children;
        if (!kids)
            return null;
        for (let i = 0; i < kids.length; i++) {
            const found = _findItem(kids[i], pred, depth + 1);
            if (found)
                return found;
        }
        return null;
    }

    function launcherContent(): var {
        if (_alive(_launcherContent))
            return _launcherContent;
        _launcherField = null;
        _launcherWrapper = null;
        _launcherContent = _findItem(_shellRoot(), it => typeof it.searchTextForMode === "function" && typeof it.clearClipboardHistory === "function", 0);
        for (let it = _launcherContent ? _launcherContent.parent : null; it; it = it.parent) {
            if (typeof it.offsetScale === "number" && typeof it.keepAlive === "boolean") {
                _launcherWrapper = it;
                break;
            }
        }
        return _launcherContent;
    }

    function launcherSearchField(): var {
        const content = launcherContent();
        if (!content)
            return null;
        if (_alive(_launcherField))
            return _launcherField;
        const prefix = GlobalConfig.launcher.actionPrefix;
        _launcherField = _findItem(content, it => typeof it.placeholderText === "string" && it.placeholderText.indexOf(prefix) !== -1 && typeof it.forceActiveFocus === "function", 0);
        return _launcherField;
    }

    /// Measures where the open launcher really sits, once it has stopped moving,
    /// so the reserve matches it exactly from then on.
    /// Settles the reserve once the launcher has stopped moving.
    // The launcher's slide springs past its resting point and back, and its
    // height animates as results change, so its size moves every frame for a
    // while. Following that frame by frame restarts the windows' own slide
    // each time, which stutters. Instead the windows wait until the launcher
    // has held still briefly, then make one move.
    function _syncReserve(measure: bool): void {
        const open = shown && Visibilities.launcherOpen;
        if (!open) {
            // Closing: one move straight back, no need to wait.
            settleTimer.stop();
            launcherReserve = 0;
            return;
        }
        settleTimer.restart();
    }

    function _commitReserve(): void {
        const w = _launcherWrapper;
        const open = shown && Visibilities.launcherOpen;
        if (!open) {
            launcherReserve = 0;
            return;
        }
        // Still sliding in: check again shortly.
        if (w && Math.abs(w.offsetScale) > 0.02) {
            settleTimer.restart();
            return;
        }
        _measureLauncher();
        const target = launcherTarget;
        // Ignore the last pixel or two of a settling animation.
        if (Math.abs(target - launcherReserve) > 4)
            launcherReserve = target;
    }

    function _measureLauncher(): void {
        const content = _launcherContent;
        if (!launcherShown || !_alive(content))
            return;
        const pos = content.mapToItem(null, 0, 0);
        const top = pos.y;
        const ourBottom = (exclusions?.topExclusion ?? 0) + height;
        const offset = ourBottom - top - content.implicitHeight;
        if (Math.abs(offset) < 200 && Math.abs(offset - _reserveOffset) > 2)
            _reserveOffset = offset;
        const left = pos.x - (exclusions?.leftExclusion ?? 0);
        const w = content.width > 0 ? content.width : content.implicitWidth;
        if (w > 0 && left > -w && left < width && (Math.abs(left - launcherLeft) > 4 || Math.abs(left + w - launcherRight) > 4)) {
            launcherLeft = left;
            launcherRight = left + w;
        }
    }

    function windowsOn(wsId: int): var {
        return Kwin.filterWindows(Kwin.windowsForWorkspace(wsId, false), null, screen.name);
    }

    function switchWorkspace(wsId: int): void {
        if (wsId !== activeWsId)
            Kwin.switchToWorkspace(wsId, screen.name);
    }

    function stepWorkspace(delta: int): void {
        const list = Kwin.workspaces;
        for (let i = 0; i < list.length; i++) {
            if (list[i].index === activeWsId) {
                const next = list[Math.max(0, Math.min(list.length - 1, i + delta))];
                if (next)
                    switchWorkspace(next.index);
                return;
            }
        }
    }

    function activateWindow(address: string): void {
        if (!address)
            return;
        Kwin.focusWindow(address);
        ov.hide();
    }

    function cycleSelection(backwards: bool): void {
        const n = currentWindows.length;
        if (n === 0)
            return;
        if (backwards)
            selectedIndex = selectedIndex <= 0 ? n - 1 : selectedIndex - 1;
        else
            selectedIndex = selectedIndex >= n - 1 ? 0 : selectedIndex + 1;
    }

    function preselect(): void {
        const target = Visibilities.preOverviewActiveWindowAddress;
        const wins = currentWindows;
        selectedIndex = -1;
        for (let i = 0; i < wins.length; i++) {
            if (wins[i].address === target) {
                selectedIndex = i;
                break;
            }
        }
    }

    name: "gnome-inspired-overview"
    visible: shown || progress > 0.001
    WlrLayershell.namespace: "caelestia-gnome-inspired-overview"
    // Top layer and honouring exclusive zones: the compositor fits the overview
    // inside the shell's border and bar, which stay visible and clickable.
    WlrLayershell.layer: WlrLayer.Top
    // Hands the keyboard over while the launcher is open on top.
    WlrLayershell.keyboardFocus: shown && isActive && !Visibilities.launcherOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Normal

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    onShownChanged: {
        if (shown) {
            preselect();
            if (isActive)
                content.forceActiveFocus();
        } else {
            dragging = false;
            launcherReserve = 0;
            _stopProbe();
        }
    }
    Component.onDestruction: _stopProbe()

    Component {
        id: probeComp

        Item {
            id: probe

            /// Where the pointer was when the launcher opened. Nothing lights
            /// up until it has moved away from there: typing should not leave
            /// the window that happened to be under the mouse highlighted.
            property point origin: win.lastPointer
            property bool moved: false

            anchors.fill: parent
            z: 100000

            HoverHandler {
                onPointChanged: {
                    if (!hovered)
                        return;
                    const p = point.position;
                    if (!probe.moved) {
                        if (probe.origin.x < 0) {
                            probe.origin = p;
                            return;
                        }
                        if (Math.abs(p.x - probe.origin.x) + Math.abs(p.y - probe.origin.y) < 4)
                            return;
                        probe.moved = true;
                    }
                    win.probeIndex = win._cardAt(p.x, p.y);
                }
                onHoveredChanged: {
                    if (!hovered)
                        win.probeIndex = -1;
                }
            }

            // Passive: the press still reaches the launcher, which closes on
            // it. That also removes this probe before the button comes back
            // up, so a window under the pointer is opened on the press itself.
            PointHandler {
                acceptedButtons: Qt.LeftButton
                onActiveChanged: {
                    if (!active)
                        return;
                    const i = win._cardAt(point.position.x, point.position.y);
                    if (i >= 0 && i < win.currentWindows.length)
                        win.activateWindow(win.currentWindows[i].address);
                }
            }
        }
    }
    onActiveWsIdChanged: selectedIndex = -1
    Component.onCompleted: {
        const map = ov.windowsByScreen;
        map[screen.name] = win;
        ov.windowsByScreen = map;
    }

    Connections {
        function onLauncherOpenChanged(): void {
            if (Visibilities.launcherOpen) {
                // The launcher has the keyboard and pointer now: let go of
                // the highlighted window instead of leaving it lit.
                win.selectedIndex = -1;
                if (win.shown)
                    win._startProbe();
                win.launcherContent();
                if (!win._launcherWrapper)
                    fallbackSettle.restart();
            } else {
                win._stopProbe();
                if (win.shown && win.isActive)
                    content.forceActiveFocus();
                if (!win._launcherWrapper)
                    fallbackSettle.restart();
            }
        }

        target: Visibilities
    }

    // The launcher finished opening or closing: now the windows move.
    Connections {
        function onOffsetScaleChanged(): void {
            win._syncReserve(true);
        }

        target: win._launcherWrapper
        ignoreUnknownSignals: true
    }

    // The launcher grew or shrank while open (results changed): move again.
    onLauncherTargetChanged: _syncReserve(false)

    Timer {
        id: settleTimer

        interval: 120
        onTriggered: win._commitReserve()
    }

    // Without the wrapper to watch, wait out a typical slide instead.
    Timer {
        id: fallbackSettle

        interval: 400
        onTriggered: win._syncReserve(true)
    }

    Behavior on progress {
        Anim {
            type: Anim.DefaultSpatial
        }
    }

    Item {
        id: content

        anchors.fill: parent
        opacity: win.progress
        focus: true

        Keys.onPressed: event => {
            switch (event.key) {
            case Qt.Key_Escape:
                win.ov.hide();
                break;
            case Qt.Key_Return:
            case Qt.Key_Enter:
                if (win.selectedIndex >= 0 && win.selectedIndex < win.currentWindows.length)
                    win.activateWindow(win.currentWindows[win.selectedIndex].address);
                break;
            case Qt.Key_Right:
            case Qt.Key_Down:
            case Qt.Key_Tab:
                win.cycleSelection(false);
                break;
            case Qt.Key_Left:
            case Qt.Key_Up:
            case Qt.Key_Backtab:
                win.cycleSelection(true);
                break;
            case Qt.Key_PageUp:
                win.stepWorkspace(-1);
                break;
            case Qt.Key_PageDown:
                win.stepWorkspace(1);
                break;
            default:
                // Anything printable starts a search in the shell's launcher.
                if (event.text.length > 0 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                        && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
                    win.ov.typeToLauncher(event.text);
                    break;
                }
                return;
            }
            event.accepted = true;
        }

        // ---- Backdrop -------------------------------------------------------
        // Rounded like the inside of the shell border, with the wallpaper laid out
        // at full-screen size so it lines up with the desktop around it.
        StyledClippingRect {
            anchors.fill: parent
            radius: Config.border.rounding
            color: Colours.palette.m3surfaceDim

            Image {
                x: -(win.exclusions?.leftExclusion ?? 0)
                y: -(win.exclusions?.topExclusion ?? 0)
                width: win.screen.width
                height: win.screen.height
                source: Wallpapers.current ? "file://" + Wallpapers.current : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                sourceSize.width: win.screen.width
                sourceSize.height: win.screen.height
            }
            Rectangle {
                anchors.fill: parent
                color: Qt.alpha(Colours.palette.m3scrim, 0.42)
            }
        }

        HoverHandler {
            onPointChanged: {
                if (hovered)
                    win.lastPointer = Qt.point(point.position.x + (win.exclusions?.leftExclusion ?? 0), point.position.y + (win.exclusions?.topExclusion ?? 0));
            }
        }

        // Clicking empty space closes the overview.
        MouseArea {
            anchors.fill: parent
            onClicked: win.ov.hide()
        }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: event => {
                const d = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x;
                if (Math.abs(d) < 60)
                    return;
                win.stepWorkspace(d > 0 ? -1 : 1);
            }
        }

        // ---- Workspace thumbnails -------------------------------------------
        WorkspaceStrip {
            id: strip

            x: win.margin
            y: win.stripTop - (1 - win.progress) * 30 * win.s
            width: parent.width - win.margin * 2
            height: win.stripHeight
            s: win.s
            screen: win.screen
            activeWsId: win.activeWsId
            showIcons: win.showThumbIcons
            live: win.shown
            registerPreview: (address, item) => win._setThumbPreview(address, item)
            unregisterPreview: (address, item) => win._clearThumbPreview(address, item)
            dragging: win.dragging
            windowsOn: wsId => win.windowsOn(wsId)
            onWorkspaceClicked: wsId => {
                if (wsId === win.activeWsId)
                    win.ov.hide();
                else
                    win.switchWorkspace(wsId);
            }
            onCreateWorkspace: Kwin.createWorkspace("")
        }

        // ---- Windows --------------------------------------------------------
        Item {
            id: windowsArea

            readonly property real hoverHeadroom: 8 * win.s
            /// Each card hangs its app icon and title below its bottom edge
            /// (see WindowCard), so a row needs this much free below it.
            readonly property real labelRoom: Math.round(28 * Math.min(1.2, win.s) + 36 * win.s)
            /// What the bottom margin does not already cover of that.
            readonly property real bottomPad: Math.max(0, labelRoom - win.margin - hoverHeadroom)
            readonly property real gap: Tokens.spacing.large * 1.5
            property var layout: flowLayout(win.currentWindows, width, height, win.launcherReserve, win.launcherLeft, win.launcherRight)

            function place(list: var, rx: real, ry: real, rw: real, rh: real, out: var): void {
                if (list.length === 0 || rw <= 1 || rh <= 1)
                    return;
                const l = LayoutGnome.calculateLayout(list, rw, rh, gap, gap);
                for (const k in l) {
                    const r = l[k];
                    out[k] = { x: r.x + rx, y: r.y + ry, width: r.width, height: r.height };
                }
            }

            // Windows over where the launcher sits move into the space beside
            // it; the rest keep the band above it. Each part is laid out on
            // its own, GNOME style, so the windows reflow as the launcher
            // opens, grows with results and closes.
            function flowLayout(wins: var, W: real, H: real, reserve: real, lLeft: real, lRight: real): var {
                if (reserve <= 0 || wins.length === 0)
                    return LayoutGnome.calculateLayout(wins, W, H, gap, gap);

                // The launcher, gap included, in this item's coordinates.
                const top = Math.max(0, win.height - reserve - y);
                // The band above the launcher, less the room its last row's
                // titles need so they do not run into the launcher.
                const topUsable = Math.max(0, top - labelRoom);
                const lw = win._launcherContent ? (win._launcherContent.width || win._launcherContent.implicitWidth) : W / 3;
                const left = (lLeft >= 0 ? lLeft : (win.width - lw) / 2) - x - gap;
                const right = (lRight >= 0 ? lRight : (win.width + lw) / 2) - x + gap;

                const minSide = 220 * win.s;
                const sideH = H - top;
                const leftW = Math.max(0, left);
                const rightW = Math.max(0, W - right);
                const useLeft = leftW >= minSide && sideH >= 140 * win.s;
                const useRight = rightW >= minSide && sideH >= 140 * win.s;

                // How many windows each side takes: its share of the room.
                const areaTop = W * topUsable;
                const areaL = useLeft ? leftW * sideH : 0;
                const areaR = useRight ? rightW * sideH : 0;
                const total = areaTop + areaL + areaR;
                const n = wins.length;
                let capL = total > 0 ? Math.round(n * areaL / total) : 0;
                let capR = total > 0 ? Math.round(n * areaR / total) : 0;
                if (topUsable < 120 * win.s) {
                    // No band worth using above: everything goes beside.
                    capL = useLeft ? (useRight ? Math.ceil(n / 2) : n) : 0;
                    capR = useRight ? n - capL : 0;
                }

                // Which windows go beside: those lowest down where they would
                // sit without the launcher, on the side they were on.
                const base = LayoutGnome.calculateLayout(wins, W, H, gap, gap);
                const mid = (left + right) / 2;
                const order = wins.map((w, i) => {
                    const r = base[w.address] || { x: 0, y: 0, width: 0, height: 0 };
                    return { w: w, cx: r.x + r.width / 2, bottom: r.y + r.height };
                }).sort((a, b) => b.bottom - a.bottom);
                const onLeft = [], onRight = [], above = [];
                for (const o of order) {
                    if (o.cx < mid && onLeft.length < capL)
                        onLeft.push(o.w);
                    else if (o.cx >= mid && onRight.length < capR)
                        onRight.push(o.w);
                    else if (onLeft.length < capL)
                        onLeft.push(o.w);
                    else if (onRight.length < capR)
                        onRight.push(o.w);
                    else
                        above.push(o.w);
                }

                const out = {};
                // Beside the launcher, the side columns reach up into the band
                // when nothing is above, so they use the full height.
                const sideTop = above.length === 0 ? 0 : top;
                place(above, 0, 0, W, topUsable, out);
                place(onLeft, 0, sideTop, leftW, H - sideTop, out);
                place(onRight, right, sideTop, rightW, H - sideTop, out);
                return out;
            }

            x: win.margin + hoverHeadroom
            y: win.windowsTop + hoverHeadroom
            width: parent.width - (win.margin + hoverHeadroom) * 2
            height: Math.max(1, win.windowsAreaHeight - hoverHeadroom * 2 - bottomPad)
            // On a screen too short to show both, the windows bow out entirely.
            opacity: win.windowsAreaHeight < 90 * win.s ? 0 : 1
            scale: 0.94 + 0.06 * win.progress
            transformOrigin: Item.Top

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }

            Repeater {
                model: win.currentWindows

                WindowCard {
                    required property var modelData
                    required property int index

                    client: modelData
                    target: windowsArea.layout && windowsArea.layout[modelData.address] ? windowsArea.layout[modelData.address] : null
                    s: win.s
                    live: win.shown
                    selected: index === win.selectedIndex
                    interactive: !Visibilities.launcherOpen
                    pointerOver: index === win.probeIndex
                    dragParent: content
                    onHoveredChanged: {
                        // Not while the launcher is open: there the highlight
                        // just follows the pointer and goes when it leaves.
                        if (hovered && !Visibilities.launcherOpen)
                            win.selectedIndex = index;
                    }
                    onActivated: win.activateWindow(modelData.address)
                    onDragActiveChanged: win.dragging = dragActive
                    mirrorSource: win.thumbPreviews[modelData.address] ?? null
                }
            }

            StyledText {
                anchors.centerIn: parent
                visible: win.currentWindows.length === 0
                text: qsTr("No open windows")
                color: Qt.alpha(Colours.palette.m3onSurface, 0.6)
                font: Tokens.font.title.medium
            }
        }
    }
}
