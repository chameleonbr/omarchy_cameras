// Small live preview that pops up when Frigate detects something.
//
// Owned by the service rather than declared as a `panel` plugin kind: adding
// "panel" to the manifest would reroute `omarchy-shell shell toggle
// avila.cameras` away from the bar widget and break the grid popup. A service
// can hold its own layer-shell window just as well — the notifications service
// does exactly this for its toasts.

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

PanelWindow {
  id: root

  property var camera: null
  property string label: ""
  property int previewWidth: 320
  property string position: "top-center"
  // Clearance below the bar, so the preview sits under it rather than behind.
  property int barClearance: Style.bar.sizeHorizontal
  property int tick: 0

  signal activated()

  readonly property int previewHeight: Math.round(previewWidth * 9 / 16)

  visible: camera !== null
  color: "transparent"

  WlrLayershell.namespace: "omarchy-cameras-alert"
  WlrLayershell.layer: WlrLayer.Overlay
  // Never steal focus: an alert that grabs the keyboard mid-sentence is worse
  // than a missed alert.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore

  // Full-screen surface with the card placed inside, so the Wayland surface
  // never resizes as the preview swaps cameras.
  anchors { top: true; bottom: true; left: true; right: true }

  // Everything except the card itself stays click-through.
  mask: Region { item: card }

  Rectangle {
    id: card

    anchors.top: parent.top
    anchors.topMargin: root.barClearance + Style.gapsOut
    anchors.left: root.position === "top-left" ? parent.left : undefined
    anchors.right: root.position === "top-right" ? parent.right : undefined
    anchors.horizontalCenter: root.position === "top-center" ? parent.horizontalCenter : undefined
    anchors.leftMargin: Style.gapsOut
    anchors.rightMargin: Style.gapsOut

    width: root.previewWidth
    height: root.previewHeight + caption.implicitHeight + Style.space(10)
    radius: Style.cornerRadius
    color: Color.popups.background
    clip: true

    Rectangle {
      id: frame
      width: parent.width
      height: root.previewHeight
      color: Qt.darker(Color.popups.background, 1.3)
      clip: true

      CameraThumb {
        id: thumb
        anchors.fill: parent
        camera: root.camera
        tick: root.tick
      }

      // A preview only lives for a few seconds, so it is worth polling faster
      // than the grid does — this is the one place the picture is meant to
      // read as movement rather than as a still.
      Timer {
        interval: 500
        running: root.visible
        repeat: true
        onTriggered: root.tick++
      }

      Text {
        anchors.centerIn: parent
        visible: !thumb.hasFrame
        text: "󰞮"
        color: Qt.darker(Color.foreground, 1.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.display
      }
    }

    Text {
      id: caption
      anchors.top: frame.bottom
      anchors.topMargin: Style.space(4)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      elide: Text.ElideRight
      text: root.camera
        ? root.camera.name + (root.label ? "  ·  " + root.label : "")
        : ""
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activated()
    }
  }
}
