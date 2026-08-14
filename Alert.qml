// Motion-alert previews: a column of small cards, one per unhandled Frigate
// detection, oldest at the top so a burst reads in the order it happened.
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

  property var model: null
  // Placement rehearsal: same window, same geometry, no events. Showing where
  // alerts land by drawing the actual card beats any diagram of it.
  property bool placeholder: false
  property int previewWidth: 320
  property int durationSec: 12
  property string position: "top-center"
  // Clearance below the bar, so previews sit under it rather than behind.
  property int barClearance: Style.bar.sizeHorizontal

  signal activated(int index)
  signal expired(int index)

  readonly property int previewHeight: Math.round(previewWidth * 9 / 16)
  readonly property int cardSpacing: Style.space(8)
  readonly property bool hasAlerts: model !== null && model.count > 0

  visible: hasAlerts || placeholder
  color: "transparent"

  WlrLayershell.namespace: "omarchy-cameras-alert"
  WlrLayershell.layer: WlrLayer.Overlay
  // Never steal focus: an alert that grabs the keyboard mid-sentence is worse
  // than a missed alert.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore

  // Full-screen surface with the column placed inside, so the Wayland surface
  // never resizes as cards come and go.
  anchors { top: true; bottom: true; left: true; right: true }

  // Everything except the cards themselves stays click-through.
  mask: Region { item: column }

  Column {
    id: column

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
    spacing: root.cardSpacing

    // The rehearsal card. One only, and never alongside real alerts.
    AlertCard {
      visible: root.placeholder
      width: root.previewWidth
      previewHeight: root.previewHeight
      placeholder: true
      caption: "Alerts appear here"
    }

    Repeater {
      model: root.placeholder ? null : root.model

      AlertCard {
        id: card
        required property int index
        required property string cameraName
        required property string label
        required property string imageUrl

        width: root.previewWidth
        previewHeight: root.previewHeight
        source: imageUrl
        caption: cameraName + (label ? "  ·  " + label : "")
        onClicked: root.activated(card.index)

        // Each card times out from when it appeared, so one that arrives late
        // gets its full time on screen instead of inheriting what is left of
        // an earlier card's.
        Timer {
          running: true
          interval: root.durationSec * 1000
          onTriggered: root.expired(card.index)
        }
      }
    }
  }
}
