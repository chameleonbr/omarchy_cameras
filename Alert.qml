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
  // Placement rehearsal: same window, same geometry, no camera. Showing where
  // alerts land by drawing the actual window beats any diagram of it.
  property bool placeholder: false
  property int previewWidth: 320
  property string position: "top-center"
  // Clearance below the bar, so the preview sits under it rather than behind.
  property int barClearance: Style.bar.sizeHorizontal
  property int tick: 0

  signal activated()

  readonly property int previewHeight: Math.round(previewWidth * 9 / 16)

  visible: camera !== null || placeholder
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

    // Positioned with x/y off the window, not anchors, and measured against
    // root.width rather than parent.width. Two traps live here: assigning
    // `undefined` to anchors.left/right still counts as anchored, so QML
    // derived the width from two unresolved edges and collapsed the card to
    // -10px; and the content item's width does not track the surface, which
    // put the card at x=1934 on a 1920px screen.
    y: root.barClearance + Style.gapsOut
    x: {
      if (root.position === "top-left") return Style.gapsOut
      if (root.position === "top-right") return root.width - width - Style.gapsOut
      return Math.round((root.width - width) / 2)
    }

    width: root.previewWidth
    height: root.previewHeight + caption.implicitHeight + Style.space(10)
    radius: Style.cornerRadius
    color: Color.popups.background
    clip: true

    Rectangle {
      id: frame
      width: parent.width
      height: root.previewHeight
      color: root.placeholder ? "black" : Qt.darker(Color.popups.background, 1.3)
      clip: true

      CameraThumb {
        id: thumb
        anchors.fill: parent
        visible: !root.placeholder
        camera: root.placeholder ? null : root.camera
        tick: root.tick
      }

      // A preview only lives for a few seconds, so it is worth polling faster
      // than the grid does — this is the one place the picture is meant to
      // read as movement rather than as a still.
      Timer {
        interval: 500
        running: root.visible && !root.placeholder
        repeat: true
        onTriggered: root.tick++
      }

      Text {
        anchors.centerIn: parent
        visible: root.placeholder || !thumb.hasFrame
        text: root.placeholder ? "👀" : "󰞮"
        color: Qt.darker(Color.foreground, 1.55)
        // The nerd-font glyph comes from the theme font; the emoji does not
        // live there, so let fontconfig fall through to the emoji font.
        font.family: root.placeholder ? "Noto Color Emoji" : Style.font.family
        font.pixelSize: root.placeholder
          ? Math.round(root.previewHeight * 0.42) : Style.font.display
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
      text: root.placeholder
        ? "Alerts appear here"
        : (root.camera
            ? root.camera.name + (root.label ? "  ·  " + root.label : "")
            : "")
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // A rehearsal is not clickable: there is no camera behind it to open.
    MouseArea {
      anchors.fill: parent
      visible: !root.placeholder
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activated()
    }
  }
}
