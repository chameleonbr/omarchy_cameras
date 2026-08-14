// One motion-alert preview: the still Frigate kept for an event, with its
// bounding box already drawn on, plus a caption naming the camera and label.
//
// Also serves as the placement rehearsal card, which is why `placeholder`
// lives here — the rehearsal has to be the same component to be honest about
// where real alerts will land.

import QtQuick
import qs.Commons

Rectangle {
  id: root

  property int previewHeight: 180
  property string source: ""
  property string caption: ""
  property bool placeholder: false

  signal clicked()

  height: previewHeight + captionText.implicitHeight + Style.space(10)
  radius: Style.cornerRadius
  color: Color.popups.background
  clip: true

  Rectangle {
    id: frame
    width: parent.width
    height: root.previewHeight
    color: root.placeholder ? "black" : Qt.darker(Color.popups.background, 1.3)
    clip: true

    // One fixed URL per event, so the Image cache is an asset here rather than
    // the liability it is for polled thumbnails. PreserveAspectFit, not Crop:
    // the bounding box is the point, and cropping can cut off the very thing
    // that tripped the alert.
    Image {
      id: shot
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      visible: !root.placeholder
      source: root.placeholder ? "" : root.source
    }

    Text {
      anchors.centerIn: parent
      visible: root.placeholder || shot.status !== Image.Ready
      text: root.placeholder ? "👀" : "󰞮"
      color: Qt.darker(Color.foreground, 1.55)
      // The nerd-font glyph comes from the theme font; the emoji does not live
      // there, so let fontconfig fall through to the emoji font.
      font.family: root.placeholder ? "Noto Color Emoji" : Style.font.family
      font.pixelSize: root.placeholder
        ? Math.round(root.previewHeight * 0.42) : Style.font.display
    }
  }

  Text {
    id: captionText
    anchors.top: frame.bottom
    anchors.topMargin: Style.space(4)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    elide: Text.ElideRight
    text: root.caption
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // A rehearsal is not clickable: there is no camera behind it to open.
  MouseArea {
    anchors.fill: parent
    visible: !root.placeholder
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
