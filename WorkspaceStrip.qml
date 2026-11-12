pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.components.images
import qs.services
import "."

// The row of workspace thumbnails across the top. Each one is a small copy of
// that desktop: the wallpaper with live, scaled-down previews of its windows
// where they sit. Windows dragged from the grid drop onto them.
Item {
    id: root

    property real s: 1
    property ShellScreen screen
    property int activeWsId: 1
    /// Draw the windows in each thumbnail.
    property bool showIcons: true
    /// Previews stream only while the overview is open.
    property bool live: true
    /// Most windows previewed per thumbnail: each is its own stream.
    property int maxPreviews: 8
    /// Told about each window preview, so the big cards can mirror it.
    property var registerPreview: (address, item) => {}
    property var unregisterPreview: (address, item) => {}
    property bool dragging: false
    property var windowsOn: wsId => []
    /// Told before the strip changes a window or desktop itself.
    property var noteAction: () => {}

    signal workspaceClicked(int wsId)
    signal createWorkspace()

    function removeWorkspace(ws: var): void {
        if (count > 1 && ws && ws.id) {
            noteAction();
            Kwin.removeWorkspace(ws.id);
        }
    }

    readonly property real screenAspect: screen && screen.height > 0 ? screen.width / screen.height : 16 / 9
    readonly property real gap: Math.round(14 * s)
    readonly property int count: Kwin.workspaces.length
    readonly property real addWidth: Math.round(height * 0.42)
    // Full height when they fit; otherwise shrink every thumbnail evenly.
    readonly property real thumbWidth: {
        const natural = height * screenAspect;
        const avail = width - addWidth - gap * count;
        return Math.max(40, Math.min(natural, avail / Math.max(1, count)));
    }
    readonly property real thumbHeight: thumbWidth / screenAspect

    Row {
        id: row

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.gap

        Repeater {
            // Keyed by workspace id, so a thumbnail and its window previews
            // live on while the workspace list is refreshed (as it is on every
            // switch) instead of being rebuilt with every stream restarting.
            model: ScriptModel {
                values: (Kwin.workspaces ?? []).map(w => w.id)
            }

            Item {
                id: thumb

                required property var modelData
                readonly property var ws: (Kwin.workspaces ?? []).find(w => w.id === thumb.modelData) ?? ({})
                readonly property int wsId: ws.index ?? 0
                readonly property bool active: wsId === root.activeWsId
                readonly property var wins: {
                    const _t = Kwin.windowList;
                    return root.windowsOn(wsId);
                }
                /// The windows drawn in this thumbnail, by address: bottom of
                /// the stack first, minimised ones left out.
                readonly property var shownWins: {
                    if (!root.showIcons)
                        return [];
                    const shown = wins.filter(w => !w.minimized && w.address);
                    return shown.slice(Math.max(0, shown.length - root.maxPreviews));
                }
                readonly property var winByAddress: {
                    const map = {};
                    for (const w of shownWins)
                        map[w.address] = w;
                    return map;
                }

                width: root.thumbWidth
                height: root.thumbHeight
                scale: drop.containsDrag ? 1.06 : (thumbHover.hovered ? 1.03 : 1)

                Behavior on scale {
                    Anim {
                        type: Anim.FastSpatial
                    }
                }

                StyledClippingRect {
                    id: frame

                    anchors.fill: parent
                    radius: Tokens.rounding.medium
                    color: Colours.palette.m3surfaceContainer

                    Image {
                        anchors.fill: parent
                        source: Wallpapers.current ? "file://" + Wallpapers.current : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 480
                        opacity: thumb.active ? 1 : 0.75
                    }

                    // Miniature windows, placed where they sit on the screen,
                    // bottom of the stack first. Minimised windows are not on
                    // screen, so they are left out.
                    Repeater {
                        // Keyed by address, so a moved or refreshed window keeps
                        // its preview and stream; only its geometry updates.
                        model: ScriptModel {
                            values: thumb.shownWins.map(w => w.address)
                        }

                        StyledClippingRect {
                            id: mini

                            required property var modelData
                            required property int index
                            readonly property var client: thumb.winByAddress[modelData] ?? ({})
                            z: index
                            readonly property real sx: frame.width / Math.max(1, root.screen.width)
                            readonly property real sy: frame.height / Math.max(1, root.screen.height)

                            x: Math.max(0, ((client.x ?? 0) - root.screen.x) * sx)
                            y: Math.max(0, ((client.y ?? 0) - root.screen.y) * sy)
                            width: Math.min(frame.width - x, Math.max(6, (client.width ?? 0) * sx))
                            height: Math.min(frame.height - y, Math.max(4, (client.height ?? 0) * sy))
                            radius: Math.max(2, Tokens.rounding.small * 0.5)
                            // A plain fill only until the first frame arrives.
                            color: miniPreview.hasStream ? "transparent" : Colours.tPalette.m3surfaceContainerHigh

                            Component.onCompleted: root.registerPreview(modelData, miniPreview)
                            Component.onDestruction: root.unregisterPreview(modelData, miniPreview)

                            LivePreview {
                                id: miniPreview

                                anchors.centerIn: parent
                                width: parent.width + 2
                                height: parent.height + 2
                                active: root.live && mini.modelData !== ""
                                address: mini.modelData ?? ""
                                fallbackIcon: WinIcons.sourceForClient(mini.client)
                                fallbackScale: 0.45
                                sourceAspect: mini.client.width > 0 && mini.client.height > 0 ? mini.client.width / mini.client.height : 16 / 9
                            }
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: Colours.palette.m3primary
                        opacity: drop.containsDrag ? 0.22 : 0

                        Behavior on opacity {
                            Anim {
                                type: Anim.FastEffects
                            }
                        }
                    }
                }

                Rectangle {
                    anchors.fill: frame
                    anchors.margins: -border.width
                    radius: frame.radius + border.width
                    color: "transparent"
                    border.width: thumb.active ? Math.max(2, Math.round(3 * root.s)) : 1
                    border.color: thumb.active ? Colours.palette.m3primary : Qt.alpha(Colours.palette.m3outline, 0.45)
                }

                StyledText {
                    anchors.top: parent.bottom
                    anchors.topMargin: Math.round(4 * root.s)
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: thumbHover.hovered && thumb.ws.name
                    text: thumb.ws.name ?? ""
                    color: Colours.palette.m3onSurface
                    font: Tokens.font.label.small
                }

                HoverHandler {
                    id: thumbHover
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mouse => {
                        if (mouse.button === Qt.MiddleButton)
                            root.removeWorkspace(thumb.ws);
                        else
                            root.workspaceClicked(thumb.wsId);
                    }
                }

                // Remove, top-right on hover, like a window's close button.
                // KWin moves the desktop's windows to its neighbour.
                StyledRect {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: -height / 3
                    anchors.rightMargin: -width / 3
                    width: Math.round(Math.max(20, Math.min(30, root.thumbHeight * 0.26)))
                    height: width
                    radius: width / 2
                    color: Colours.palette.m3surfaceContainerHighest
                    opacity: thumbHover.hovered && root.count > 1 && !root.dragging ? 1 : 0
                    visible: opacity > 0.01
                    z: 4

                    Behavior on opacity {
                        Anim {
                            type: Anim.FastEffects
                        }
                    }

                    StateLayer {
                        anchors.fill: parent
                        radius: parent.radius
                        color: Colours.palette.m3onSurface
                        onClicked: root.removeWorkspace(thumb.ws)
                    }

                    MaterialIcon {
                        anchors.centerIn: parent
                        text: "close"
                        color: Colours.palette.m3onSurface
                        fontStyle.pointSize: Tokens.font.icon.small.pointSize
                    }
                }

                DropArea {
                    id: drop

                    anchors.fill: parent
                    keys: ["gnome-inspired-overview-window"]
                    onDropped: event => {
                        const src = event.source;
                        if (!src || !src.clientAddress)
                            return;
                        const addr = src.clientAddress;
                        const target = thumb.wsId;
                        event.accept(Qt.MoveAction);
                        root.noteAction();
                        Qt.callLater(() => Kwin.setWindowDesktop(addr, target));
                    }
                }
            }
        }

        // New workspace.
        Item {
            width: root.addWidth
            height: root.thumbHeight

            StyledRect {
                anchors.centerIn: parent
                width: parent.width
                height: Math.min(parent.height, parent.width * 1.6)
                radius: Tokens.rounding.medium
                color: Qt.alpha(Colours.palette.m3surfaceContainerHigh, addHover.hovered ? 0.9 : 0.55)

                HoverHandler {
                    id: addHover
                }

                StateLayer {
                    anchors.fill: parent
                    radius: parent.radius
                    color: Colours.palette.m3onSurface
                    onClicked: root.createWorkspace()
                }

                MaterialIcon {
                    anchors.centerIn: parent
                    text: "add"
                    color: Colours.palette.m3onSurface
                    fontStyle.pointSize: Tokens.font.icon.medium.pointSize
                }
            }
        }
    }
}
