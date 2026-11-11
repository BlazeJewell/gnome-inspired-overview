pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.components.images
import qs.services

// One window in the overview: a live preview with the app icon tucked under its
// bottom edge, and the title and a close button on hover, GNOME style.
Item {
    id: root

    required property var client
    property var target: null
    property real s: 1
    property bool live: true
    property bool selected: false
    property bool showTitle: true
    /// Off while something else (the launcher) has the pointer: the card then
    /// never hears that the pointer left, so its hover would stick.
    property bool interactive: true
    property Item dragParent: null

    readonly property string clientAddress: client ? client.address : ""
    /// Set from outside while the launcher has the pointer (see OverviewWindow).
    property bool pointerOver: false
    readonly property bool hovered: hover.hovered || pointerOver
    readonly property bool dragActive: drag.active
    readonly property real aspect: client && client.width > 0 && client.height > 0 ? client.width / client.height : 16 / 10
    readonly property real iconSize: Math.round(Math.max(28, Math.min(56, Math.min(width, height) * 0.22)) * Math.min(1.2, s))
    property bool closing: false
    /// This window's preview in the workspace strip, when it has one. The
    /// card shows that stream instead of opening a second one, so switching
    /// workspaces starts and stops no streams.
    property Item mirrorSource: null
    readonly property bool mirroring: mirrorSource !== null && mirrorSource.hasStream === true

    signal activated()

    x: target ? target.x : 0
    y: target ? target.y : 0
    width: target ? target.width : 0
    height: target ? target.height : 0
    z: root.hovered || selected ? 2 : 1
    scale: closing ? 0.6 : (drag.active ? 0.5 : ((root.hovered || selected) ? 1.025 : 1))
    opacity: closing ? 0 : 1

    Drag.active: drag.active
    Drag.source: root
    Drag.hotSpot.x: width / 2
    Drag.hotSpot.y: height / 2
    Drag.keys: ["gnome-inspired-overview-window"]

    Behavior on x {
        enabled: !drag.active

        Anim {
            type: Anim.DefaultSpatial
        }
    }
    Behavior on y {
        enabled: !drag.active

        Anim {
            type: Anim.DefaultSpatial
        }
    }
    Behavior on width {
        Anim {
            type: Anim.DefaultSpatial
        }
    }
    Behavior on height {
        Anim {
            type: Anim.DefaultSpatial
        }
    }
    Behavior on scale {
        Anim {
            type: Anim.FastSpatial
        }
    }
    Behavior on opacity {
        Anim {
            id: fade

            type: Anim.DefaultEffects
            onRunningChanged: {
                if (!running && root.closing)
                    Kwin.closeWindow(root.clientAddress);
            }
        }
    }

    states: State {
        when: drag.active

        ParentChange {
            target: root
            parent: root.dragParent
        }
    }

    StyledClippingRect {
        id: frame

        anchors.fill: parent
        radius: Tokens.rounding.large
        // Only behind the icon fallback: under a live preview the light fill
        // shows through the rounded edge as a bright fringe while the card
        // moves and resizes through fractional pixels.
        color: root.mirroring || preview.hasStream ? "transparent" : Colours.tPalette.m3surfaceContainer
        border.width: root.selected || root.hovered ? Math.max(2, Math.round(3 * root.s)) : 0
        border.color: Qt.alpha(Colours.palette.m3primary, 0.9)

        WindowPreview {
            id: preview

            // A pixel past the clip on every side, so the clipped edge is
            // always the window itself and never what is behind it.
            anchors.centerIn: parent
            width: parent.width + 2
            height: parent.height + 2
            visible: !root.mirroring
            active: root.live && root.mirrorSource === null && root.clientAddress !== ""
            address: root.clientAddress
            fallbackIcon: WinIcons.sourceForClient(root.client)
            sourceAspect: root.aspect
        }

        // The thumbnail's stream, drawn at this card's full resolution.
        ShaderEffectSource {
            anchors.centerIn: parent
            width: parent.width + 2
            height: parent.height + 2
            visible: root.mirroring
            sourceItem: root.mirroring ? root.mirrorSource : null
            textureSize: Qt.size(Math.ceil(width * Screen.devicePixelRatio), Math.ceil(height * Screen.devicePixelRatio))
            live: true
            hideSource: false
            smooth: true
        }
    }

    // Shadow-ish ring so light wallpapers do not swallow the card edge.
    Rectangle {
        anchors.fill: frame
        anchors.margins: -1
        radius: frame.radius + 1
        color: "transparent"
        border.width: 1
        border.color: Qt.alpha(Colours.palette.m3shadow, 0.25)
        z: -1
    }

    IconImage {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.bottom
        implicitSize: root.iconSize
        asynchronous: true
        source: WinIcons.sourceForClient(root.client)
        visible: !drag.active
        z: 3
    }

    StyledRect {
        id: titlePill

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.bottom
        anchors.topMargin: root.iconSize / 2 + Math.round(6 * root.s)
        width: Math.min(root.width, titleText.implicitWidth + Math.round(20 * root.s))
        height: titleText.implicitHeight + Math.round(8 * root.s)
        radius: height / 2
        color: Qt.alpha(Colours.palette.m3surfaceContainerHighest, 0.92)
        opacity: root.showTitle && (root.hovered || root.selected) && !drag.active ? 1 : 0
        visible: opacity > 0.01
        z: 3

        Behavior on opacity {
            Anim {
                type: Anim.FastEffects
            }
        }

        StyledText {
            id: titleText

            anchors.centerIn: parent
            width: Math.min(implicitWidth, root.width - Math.round(20 * root.s))
            text: root.client ? (root.client.title || root.client.class || "") : ""
            elide: Text.ElideRight
            color: Colours.palette.m3onSurface
            font: Tokens.font.body.small
        }
    }

    HoverHandler {
        id: hover

        // Disabling clears the hover; it comes back on the next pointer move.
        enabled: root.interactive
    }

    DragHandler {
        id: drag

        onActiveChanged: {
            if (active)
                return;
            const result = root.Drag.drop();
            if (result === Qt.IgnoreAction)
                root.Drag.cancel();
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton)
                root.closing = true;
            else
                root.activated();
        }
    }

    // Close button, top-right, on hover.
    StyledRect {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: -height / 3
        anchors.rightMargin: -width / 3
        width: Math.round(30 * Math.min(1.3, root.s))
        height: width
        radius: width / 2
        color: Colours.palette.m3surfaceContainerHighest
        opacity: hover.hovered && !drag.active ? 1 : 0
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
            onClicked: root.closing = true
        }

        MaterialIcon {
            anchors.centerIn: parent
            text: "close"
            color: Colours.palette.m3onSurface
            fontStyle.pointSize: Tokens.font.icon.small.pointSize
        }
    }
}
