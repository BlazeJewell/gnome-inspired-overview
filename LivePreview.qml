pragma ComponentBehavior: Bound

import org.kde.pipewire as Pipewire
import QtQuick
import Caelestia.Config
import Caelestia.Services
import qs.components.images

// A live picture of one window, with its own screencast stream.
//
// The shell's WindowPreview shares one stream per window with the bar's dock
// previews, and keeps it a few seconds after they close. Joining a stream that
// is already running gets no picture until the window next repaints, so an
// idle app hovered in the dock came up blank here. A stream of our own gets a
// first frame straight away. Until it does, the app icon is shown.
Item {
    id: root

    required property string address
    property bool active: true
    property url fallbackIcon: ""
    property real fallbackScale: 0.5
    property real sourceAspect: 16 / 9

    /// True once a frame has actually arrived, not just once the stream exists.
    readonly property bool hasStream: request.objectSerial !== 0 && pipewireItem.ready

    WindowScreencastRequest {
        id: request

        // An empty uuid closes the stream.
        uuid: root.active && GlobalConfig.bar.livePreviews ? root.address : ""
    }

    CachingIconImage {
        anchors.centerIn: parent
        implicitSize: Math.min(root.width, root.height) * root.fallbackScale
        source: root.fallbackIcon
        visible: !root.hasStream
    }

    Pipewire.PipeWireSourceItem {
        id: pipewireItem

        readonly property real fitted: root.sourceAspect > (root.width / Math.max(1, root.height)) ? root.width / root.sourceAspect : root.height

        anchors.centerIn: parent
        width: fitted * root.sourceAspect
        height: fitted
        objectSerial: request.objectSerial
        opacity: root.hasStream ? 1 : 0
        z: 1
    }
}
