pragma ComponentBehavior: Bound

import QtQuick
import QtCore
import Quickshell
import Quickshell.Io
import qs.services
import "."

// GNOME-style overview. One window per output, fitted inside the shell's border
// and bar; the state lives here so every output opens and closes together.
//
// Typing in the overview opens the shell's own launcher from the bottom and
// hands it what was typed; the windows re-lay out above it.
Scope {
    id: root

    property bool open: false
    property string activeScreen: ""
    property var windowsByScreen: ({})

    /// The launcher was opened from the overview by typing.
    property bool launcherFromOverview: false
    /// Characters typed before the launcher's search field could take them.
    property string pendingText: ""

    /// Windows that were fullscreen when the overview opened. Games such as
    /// CS2 leave fullscreen when they lose keyboard focus to the overview;
    /// they are put back when the overview hands focus back to them.
    property var _fullscreenAtOpen: []
    property string _refullscreenAddress: ""
    property bool _activating: false
    /// When the overview last moved focus itself (switched desktop, closed or
    /// moved a window): KWin then focuses another window on its own.
    property real _ownActionAt: 0
    property int _windowCount: 0
    readonly property string _activeAddress: Kwin.activeWindow && Kwin.activeWindow.address ? String(Kwin.activeWindow.address) : ""

    property bool _pendingOverview: false
    property bool _pendingMeta: false
    property bool _ownLauncher: false
    property int _windowCountAtClose: -1
    property var _hookedField: null

    function show(): void {
        const active = Kwin.activeWindow;
        Visibilities.preOverviewActiveWindowAddress = active && active.address ? active.address : "";
        activeScreen = Kwin.cursorOutputName() || Kwin.activeOutputName || "";
        _fullscreenAtOpen = (Kwin.windowList ?? []).filter(w => w.fullscreen === true && !w.minimized && w.address).map(w => String(w.address));
        _windowCount = (Kwin.windowList ?? []).length;
        open = true;
        raiseTimer.restart();
    }

    function noteOwnAction(): void {
        _ownActionAt = Date.now();
    }

    /// Something outside the overview (the bar's dock, a shortcut) focused or
    /// opened a window: close, and leave focus where it went.
    function _closeForOutside(): void {
        if (!open || Date.now() - _ownActionAt < 1000)
            return;
        _hideLeavingFocus();
    }

    /// Closes without handing focus back: something else is taking it.
    function _hideLeavingFocus(): void {
        _activating = true;
        hide();
        _activating = false;
    }

    on_ActiveAddressChanged: {
        if (open && _activeAddress !== "")
            _closeForOutside();
    }

    /// Focuses a window and closes the overview.
    function activate(address: string): void {
        if (!address)
            return;
        Kwin.focusWindow(address);
        _restoreFullscreen(address);
        _hideLeavingFocus();
    }

    function hide(): void {
        if (open && !_activating) {
            // Closed without picking a window: focus goes back to the one that
            // had it, if it is still on screen, so a game drops back in too.
            const prev = Visibilities.preOverviewActiveWindowAddress;
            const w = (Kwin.windowList ?? []).find(x => String(x.address) === prev);
            const wsId = w?.workspace?.id ?? -1;
            if (w && !w.minimized && _fullscreenAtOpen.includes(prev) && (wsId === -1 || Kwin.activeWsId === -1 || wsId === Kwin.activeWsId)) {
                Kwin.focusWindow(prev);
                _restoreFullscreen(prev);
            }
        }
        open = false;
        pendingText = "";
        _windowCountAtClose = -1;
        if (launcherFromOverview && Visibilities.launcherOpen)
            Visibilities.closeLauncher();
        launcherFromOverview = false;
    }

    function _restoreFullscreen(address: string): void {
        if (!_fullscreenAtOpen.includes(address))
            return;
        _refullscreenAddress = address;
        refullscreenTimer.tries = 0;
        refullscreenTimer.restart();
    }

    function toggle(): void {
        if (open)
            hide();
        else
            show();
    }

    function activeWindowObj(): var {
        return windowsByScreen[activeScreen] ?? windowsByScreen[Object.keys(windowsByScreen)[0]] ?? null;
    }

    /// Called by the overview with each printable key it receives.
    function typeToLauncher(text: string): void {
        pendingText += text;
        if (!Visibilities.launcherOpen) {
            launcherFromOverview = true;
            _ownLauncher = true;
            Visibilities.openLauncher("");
            _ownLauncher = false;
        }
        injectTimer.tries = 0;
        injectTimer.restart();
    }

    function _flushOverview(): void {
        if (!_pendingOverview)
            return;
        _pendingOverview = false;
        toggle();
    }

    function _flushMeta(): void {
        if (!_pendingMeta)
            return;
        _pendingMeta = false;
        toggle();
    }

    function _onLauncherAccepted(): void {
        // Enter in the launcher: whatever it ran, the overview is done too.
        Qt.callLater(() => {
            if (root.open && root.launcherFromOverview && !Visibilities.launcherOpen)
                root._hideLeavingFocus();
        });
    }

    Settings {
        id: settings

        property bool replaceOverview: true
        property bool metaOpensOverview: true
        property bool thumbnailPreviews: true

        category: "Plugin_gnome-inspired-overview"
    }

    // Puts a window back in fullscreen once it has focus again. Checked a few
    // times, as the game may only notice the focus a moment later.
    Timer {
        id: refullscreenTimer

        property int tries: 0

        interval: 120
        repeat: true
        onTriggered: {
            tries++;
            const addr = root._refullscreenAddress;
            const w = (Kwin.windowList ?? []).find(x => String(x.address) === addr);
            if (w && w.fullscreen !== true)
                Kwin.setFullscreen(addr, true);
            if (!w || tries >= 5) {
                root._refullscreenAddress = "";
                stop();
            }
        }
    }

    // The overview shares the shell's layer and opens after the shell's own
    // window, so it would cover the bar's popouts (the dock's window previews)
    // and panels. Once it is up, a small KWin script raises the shell's window
    // above it: unload any earlier copy, load, run. The script stays loaded
    // (it has finished) until the next open or until the plugin goes away.
    readonly property string _raiseScriptName: "gnome-inspired-overview-raise"
    readonly property string _raiseScriptPath: decodeURIComponent(Qt.resolvedUrl("raise-shell.js").toString().replace(/^file:\/\//, ""))
    readonly property var _kwinScripting: ["dbus-send", "--session", "--print-reply", "--dest=org.kde.KWin", "/Scripting"]

    Timer {
        id: raiseTimer

        interval: 60
        onTriggered: {
            if (root.open && !raiseProc.running) {
                raiseProc.step = 0;
                raiseProc.running = true;
            }
        }
    }

    Process {
        id: raiseProc

        property int step: 0
        readonly property var steps: [
            [...root._kwinScripting, "org.kde.kwin.Scripting.unloadScript", "string:" + root._raiseScriptName],
            [...root._kwinScripting, "org.kde.kwin.Scripting.loadScript", "string:" + root._raiseScriptPath, "string:" + root._raiseScriptName],
            [...root._kwinScripting, "org.kde.kwin.Scripting.start"]
        ]

        command: steps[Math.min(step, steps.length - 1)]
        onExited: {
            if (step < steps.length - 1) {
                step++;
                running = true;
            }
        }
    }

    Component.onDestruction: Quickshell.execDetached([...root._kwinScripting, "org.kde.kwin.Scripting.unloadScript", "string:" + root._raiseScriptName])

    // Hands the typed text to the launcher once its content exists.
    Timer {
        id: injectTimer

        property int tries: 0

        interval: 30
        repeat: true
        onTriggered: {
            tries++;
            const win = root.activeWindowObj();
            const field = win ? win.launcherSearchField() : null;
            if (field) {
                if (root.pendingText.length > 0) {
                    field.text = field.text + root.pendingText;
                    field.cursorPosition = field.text.length;
                    root.pendingText = "";
                }
                field.forceActiveFocus();
                if (root._hookedField !== field) {
                    field.accepted.connect(root._onLauncherAccepted);
                    root._hookedField = field;
                }
                stop();
            } else if (tries > 50) {
                root.pendingText = "";
                stop();
            }
        }
    }

    // An app launched from the launcher (by click) shows up as a new window:
    // close the overview when it does.
    Connections {
        function onWindowListChanged(): void {
            const n = Kwin.windowList.length;
            const grew = n > root._windowCount;
            root._windowCount = n;
            if (root.open && root._windowCountAtClose >= 0 && n > root._windowCountAtClose)
                root._hideLeavingFocus();
            else if (root.open && grew)
                root._closeForOutside();
        }

        target: Kwin
    }
    Timer {
        id: launchWatch

        interval: 6000
        onTriggered: root._windowCountAtClose = -1
    }

    Connections {
        function onLauncherOpenChanged(): void {
            if (Visibilities.launcherOpen || !root.launcherFromOverview)
                return;
            // Back to the overview (Esc); if an app was launched its window will
            // turn up shortly and close the overview too.
            root.launcherFromOverview = false;
            root._windowCountAtClose = Kwin.windowList.length;
            launchWatch.restart();
        }

        // Meta opens the launcher; open the overview instead, or close it.
        function onLauncherOpened(mode: string): void {
            if (root._ownLauncher || !settings.metaOpensOverview || mode !== "")
                return;
            Visibilities.closeLauncher();
            root._pendingMeta = true;
            Qt.callLater(root._flushMeta);
        }

        target: Visibilities
    }

    // Take over the built-in overview: close it in the same tick it opens, before
    // it draws a frame, and open this one instead. The dock's "show all windows"
    // (an app-filtered overview) is left to the built-in one.
    Instantiator {
        model: Array.from(Visibilities.screens.values())

        delegate: Connections {
            required property var modelData

            function onOverviewChanged(): void {
                if (!settings.replaceOverview || !modelData.overview)
                    return;
                if ((Visibilities.overviewAppFilter ?? []).length > 0)
                    return;
                modelData.overview = false;
                root._pendingOverview = true;
                Qt.callLater(root._flushOverview);
            }

            target: modelData
        }
    }

    Variants {
        model: Quickshell.screens

        OverviewWindow {
            required property ShellScreen modelData

            screen: modelData
            ov: root
            showThumbIcons: settings.thumbnailPreviews
        }
    }

    // caelestia shell gnomeOverview toggle | close | type <text> | snapshot <path>
    IpcHandler {
        function toggle(): void {
            root.toggle();
        }

        function close(): void {
            root.hide();
        }

        /// Opens the overview and types `text`, as if typed on the keyboard.
        function type(text: string): void {
            if (!root.open)
                root.show();
            root.typeToLauncher(text);
        }

        /// Saves the active output's overview to a PNG, for checking the layout.
        function snapshot(path: string): string {
            const win = root.activeWindowObj();
            if (!win)
                return "no window";
            win.grabItem.grabToImage(result => result.saveToFile(path));
            return "ok";
        }

        target: "gnomeOverview"
    }
}
