// Bar widget + popup for the avila.cameras plugin.
//
// Layer 1 of the two-layer design: the popup shows a grid of periodically
// refreshed JPEGs, not live video. Picking a tile hands the stream to mpv
// (layer 2) via the service.

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Cameras.js" as Cameras

Panel {
  id: root
  moduleName: "avila.cameras"
  ipcTarget: "avila.cameras"
  manageIpc: false

  // The shell loads one bar widget per monitor but only one service, so all
  // copies read the same camera list.
  readonly property var service: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property var cameras: service ? service.cameras : []
  readonly property bool hasCameras: cameras.length > 0

  readonly property int columns: clampSetting("columns", 2, 1, 4)
  readonly property int thumbIntervalMs: clampSetting("thumbIntervalMs", 2000, 500, 30000)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color barForegroundColor: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int tileWidth: Style.space(170)
  readonly property int tileHeight: Math.round(tileWidth * 9 / 16)
  readonly property int tileSpacing: Style.space(8)

  property int cursor: 0
  property bool cursorActive: false
  // Bumped on a timer to defeat Image's URL cache; see Cameras.thumbSource.
  property int tick: 0

  function clampSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (!hasCameras) return
    var next = cursor + dx + dy * columns
    cursor = Math.max(0, Math.min(cameras.length - 1, next))
  }

  function activateCursor() {
    if (!hasCameras || !service) return
    var camera = cameras[Math.max(0, Math.min(cursor, cameras.length - 1))]
    service.view(camera.id)
    root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = 0
    tick++
    if (service) service.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Only burn network and decode while someone is looking at the grid.
  Timer {
    interval: root.thumbIntervalMs
    running: root.opened && root.hasCameras
    repeat: true
    onTriggered: root.tick++
  }

  // manageIpc is false above so this handler owns the target: the base only
  // offers the open/close lifecycle, and the plugin also wants refresh/status.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string {
      if (!root.service) return "service unavailable"
      root.service.refresh()
      return "ok"
    }
    // Straight to layer 2, skipping the grid — for a keybind that jumps to
    // one camera ("show me the front door").
    function view(name: string): string {
      if (!root.service) return "service unavailable"
      var cams = root.service.cameras
      for (var i = 0; i < cams.length; i++) {
        if (cams[i].name !== name && cams[i].id !== name) continue
        root.service.view(cams[i].id)
        return "ok"
      }
      return "unknown camera"
    }
    function status(): string {
      if (!root.service) return "service unavailable"
      var names = root.service.cameras.map(function(c) { return c.name })
      return "opened=" + root.opened
        + " cameras=" + names.length
        + " frigate=\"" + root.service.config.frigate.url + "\""
        + " names=[" + names.join(",") + "]"
        + (root.service.lastError ? " error=\"" + root.service.lastError + "\"" : "")
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰞮"
    dimmed: !root.hasCameras
    tooltipText: root.hasCameras
      ? root.cameras.length + (root.cameras.length === 1 ? " camera" : " cameras")
      : "No cameras configured"
    onPressed: function(code) {
      if (code === Qt.RightButton && root.service) root.service.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(
      root.columns * root.tileWidth + (root.columns - 1) * root.tileSpacing)
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.service && root.service.refresh() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Cameras"
            meta: root.service && root.service.lastError
              ? root.service.lastError
              : (root.hasCameras ? root.cameras.length + " live" : "Nothing configured")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰞮"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: !root.hasCameras
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: "Set a Frigate URL in ~/.config/omarchy/cameras.json, "
              + "or run omarchy-cameras-onvif discover to find ONVIF cameras "
              + "on the network."
          }

          Grid {
            columns: root.columns
            spacing: root.tileSpacing

            Repeater {
              model: root.cameras

              Rectangle {
                id: tile
                required property int index
                required property var modelData

                width: root.tileWidth
                height: root.tileHeight + nameLabel.implicitHeight + Style.space(4)
                color: "transparent"
                radius: Style.cornerRadius
                border.width: root.cursorActive && root.cursor === index ? Math.max(1, Style.space(2)) : 0
                border.color: root.foreground

                Rectangle {
                  id: frame
                  width: parent.width
                  height: root.tileHeight
                  radius: Style.cornerRadius
                  clip: true
                  color: Qt.darker(Color.popups.background, 1.3)

                  Image {
                    id: thumb
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    // Every refresh is a distinct URL, so caching a frame
                    // would only pin the first one forever.
                    cache: false
                    source: Cameras.thumbSource(tile.modelData, root.tick)
                  }

                  // Covers both "still loading" and "camera is down" — either
                  // way there is no picture and the name is what identifies
                  // the tile.
                  Text {
                    anchors.centerIn: parent
                    visible: thumb.status !== Image.Ready
                    text: "󰞮"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display
                  }
                }

                Text {
                  id: nameLabel
                  anchors.top: frame.bottom
                  anchors.topMargin: Style.space(2)
                  width: parent.width
                  elide: Text.ElideRight
                  text: tile.modelData.name
                  color: root.cursorActive && root.cursor === tile.index ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: { root.cursorActive = true; root.cursor = tile.index }
                  onClicked: { root.cursor = tile.index; root.activateCursor() }
                }
              }
            }
          }
        }
      }
    }
  }
}
