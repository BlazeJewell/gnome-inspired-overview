pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.components.images
import qs.services

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
    /// The big cards' previews by address, for the current workspace.
    property var cardPreviews: ({})
    property bool dragging: false
    property var windowsOn: wsId => []

    signal workspaceClicked(int wsId)
    signal createWorkspace()

    function removeWorkspace(ws: var): void {
        if (count > 1 && ws && ws.id)
            Kwin.removeWorkspace(ws.id);
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
            model: Kwin.workspaces

            Item {
                id: thumb

                required property var modelData
                readonly property int wsId: modelData.index
                readonly property bool active: wsId === root.activeWsId
                readonly property var wins: {
                    const _t = Kwin.windowList;
                    return root.windowsOn(wsId);
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
                        model: {
                            if (!root.showIcons)
                                return [];
                            const shown = thumb.wins.filter(w => !w.minimized);
                            return shown.slice(Math.max(0, shown.length - root.maxPreviews));
                        }

                        StyledClippingRect {
                            id: mini

                            required property var modelData
                            readonly property real sx: frame.width / Math.max(1, root.screen.width)
                            readonly property real sy: frame.height / Math.max(1, root.screen.height)

                            x: Math.max(0, (modelData.x - root.screen.x) * sx)
                            y: Math.max(0, (modelData.y - root.screen.y) * sy)
                            width: Math.min(frame.width - x, Math.max(6, modelData.width * sx))
                            height: Math.min(frame.height - y, Math.max(4, modelData.height * sy))
                            radius: Math.max(2, Tokens.rounding.small * 0.5)
                            // A plain fill only until the first frame arrives.
                            color: mini.cardItem !== null || miniPreview.hasStream ? "transparent" : Colours.tPalette.m3surfaceContainerHigh

                            readonly property Item cardItem: thumb.active ? (root.cardPreviews[modelData.address] ?? null) : null

                            // The current workspace's windows are already
                            // streaming to their big cards: show those.
                            ShaderEffectSource {
                                anchors.fill: parent
                                visible: mini.cardItem !== null
                                sourceItem: mini.cardItem
                                live: true
                                hideSource: false
                            }

                            WindowPreview {
                                id: miniPreview

                                anchors.centerIn: parent
                                width: parent.width + 2
                                height: parent.height + 2
                                visible: mini.cardItem === null
                                active: root.live && mini.cardItem === null && mini.modelData.address !== ""
                                address: mini.modelData.address ?? ""
                                fallbackIcon: WinIcons.sourceForClient(mini.modelData)
                                fallbackScale: 0.45
                                sourceAspect: mini.modelData.width > 0 && mini.modelData.height > 0 ? mini.modelData.width / mini.modelData.height : 16 / 9
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
                    visible: thumbHover.hovered && thumb.modelData.name
                    text: thumb.modelData.name ?? ""
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
                            root.removeWorkspace(thumb.modelData);
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
                        onClicked: root.removeWorkspace(thumb.modelData)
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
