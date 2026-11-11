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

    property bool _pendingOverview: false
    property bool _pendingMeta: false
    property bool _ownLauncher: false
    property int _windowCountAtClose: -1
    property var _hookedField: null

    function show(): void {
        const active = Kwin.activeWindow;
        Visibilities.preOverviewActiveWindowAddress = active && active.address ? active.address : "";
        activeScreen = Kwin.cursorOutputName() || Kwin.activeOutputName || "";
        open = true;
    }

    function hide(): void {
        open = false;
        pendingText = "";
        _windowCountAtClose = -1;
        if (launcherFromOverview && Visibilities.launcherOpen)
            Visibilities.closeLauncher();
        launcherFromOverview = false;
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
                root.hide();
        });
    }

    Settings {
        id: settings

        property bool replaceOverview: true
        property bool metaOpensOverview: true
        property bool thumbnailPreviews: true

        category: "Plugin_gnome-inspired-overview"
    }

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
            if (root.open && root._windowCountAtClose >= 0 && Kwin.windowList.length > root._windowCountAtClose)
                root.hide();
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
