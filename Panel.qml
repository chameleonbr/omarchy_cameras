// Bar widget + popup for the avila.cameras plugin.
//
// Layer 1 of the two-layer design: the popup shows a grid of periodically
// refreshed JPEGs, not live video. Picking a tile hands the stream to mpv
// (layer 2) via the service. The Config button in the hero swaps the grid for
// the setup form, so a fresh install never has to be told to hand-edit JSON.

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

  // "grid" or "config".
  property string view: "grid"

  readonly property int columns: clampSetting("columns", 2, 1, 4)
  readonly property int thumbIntervalMs: clampSetting("thumbIntervalMs", 2000, 500, 30000)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int tileWidth: Style.space(170)
  readonly property int tileHeight: Math.round(tileWidth * 9 / 16)
  readonly property int tileSpacing: Style.space(8)
  readonly property int gridWidth: columns * tileWidth + (columns - 1) * tileSpacing

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
    if (view === "config" || !hasCameras || !service) return
    var camera = cameras[Math.max(0, Math.min(cursor, cameras.length - 1))]
    service.view(camera.id)
    root.close()
  }

  // The form is uncontrolled while it is open — binding the fields straight to
  // the config would rewrite what the user is typing on every file reload — so
  // seed them once on the way in.
  function showConfig() {
    view = "config"
    if (service) {
      urlField.text = service.config.frigate.url
      portField.text = String(service.config.frigate.rtspPort)
    }
    // Land the cursor in the first field. The panel is keyboard-summoned as
    // often as it is clicked, and a form you have to reach for with the mouse
    // is a form nobody fills in.
    Qt.callLater(function() { urlField.forceActiveFocus() })
  }

  function toggleConfig() {
    if (view === "config") view = "grid"
    else showConfig()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = 0
    tick++
    if (service) service.refresh()
    // Land on setup when there is nothing to show yet: an empty grid with no
    // way forward is the one state a first-time user must not get stuck in.
    if (hasCameras) {
      view = "grid"
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      showConfig()
    }
  }

  // Only burn network and decode while someone is looking at the grid.
  Timer {
    interval: root.thumbIntervalMs
    running: root.opened && root.view === "grid" && root.hasCameras
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
    function config(): void { root.view = "config"; root.open() }
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
        + " view=" + root.view
        + " cameras=" + names.length
        + " frigate=\"" + root.service.config.frigate.url + "\""
        + " names=[" + names.join(",") + "]"
        + (root.service.lastError ? " error=\"" + root.service.lastError + "\"" : "")
    }
    function discover(): string {
      if (!root.service) return "service unavailable"
      root.service.discover()
      return "ok"
    }
    // Same write the config form does, for setting a machine up from a script.
    function setFrigate(url: string, rtspPort: string): string {
      if (!root.service) return "service unavailable"
      root.service.setFrigate(url, parseInt(rtspPort, 10) || 8554)
      return "ok"
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
    // KeyboardPanel forces focus onto this item once the surface maps, so in
    // config view it has to be the first field — otherwise the key catcher
    // takes focus and the form cannot be typed into at all.
    focusTarget: root.view === "config" ? urlField : keyCatcher
    // fittedContentHeight adds the card's own padding for you; fittedContentWidth
    // does not, so the inset has to be added here or the last grid column is
    // clipped by exactly the padding and border.
    readonly property int contentInsetX:
      padding * 2 + Border.left(borderSpec) + Border.right(borderSpec)
    contentWidth: panel.fittedContentWidth(panel.contentInsetX
      + (root.view === "config"
          ? Style.space(400)
          // Slack for the overlay scrollbar, which the grid outgrows as soon
          // as there are more than a handful of cameras.
          : root.gridWidth + Style.space(12)))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The catcher takes keys before its children, so every text input has to
      // be named here or it silently refuses to accept letters.
      blocked: urlField.activeFocus || portField.activeFocus
        || userField.activeFocus || passwordField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (root.view === "config") return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.view === "config") return
        if (t === "r" || t === "R") { if (root.service) root.service.refresh() }
        else if (t === "c" || t === "C") root.toggleConfig()
      }

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
            title: root.view === "config" ? "Camera setup" : "Cameras"
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
            trailingControl: Component {
              Button {
                text: root.view === "config" ? "Done" : "Config"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.toggleConfig()
              }
            }
          }

          // ---------------------------------------------------------- grid

          Grid {
            visible: root.view === "grid"
            columns: root.columns
            spacing: root.tileSpacing

            Repeater {
              model: root.view === "grid" ? root.cameras : []

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

          // -------------------------------------------------------- config

          Column {
            visible: root.view === "config"
            width: parent.width
            spacing: Style.space(10)

            // With a field focused the key catcher is blocked, so Escape would
            // otherwise die in the text input. Catching it here, one level up
            // from all four fields, keeps the panel dismissable while typing.
            Keys.onEscapePressed: root.close()

            PanelSectionHeader {
              text: "Frigate"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: urlField
              width: parent.width
              placeholderText: "http://nvr.lan:5000"
              foreground: root.foreground
              onAccepted: saveFrigate.clicked()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              // A plain field rather than the kit's NumberField: a SpinBox
              // formats through the locale and renders port 8554 as "8,554".
              TextField {
                id: portField
                width: Style.space(90)
                placeholderText: "8554"
                foreground: root.foreground
                inputMethodHints: Qt.ImhDigitsOnly
                validator: IntValidator { bottom: 1; top: 65535 }
                onAccepted: saveFrigate.clicked()
              }

              Button {
                id: saveFrigate
                text: "Save"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) {
                  root.service.setFrigate(urlField.text, parseInt(portField.text, 10) || 8554)
                }
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: "Leave blank to run ONVIF-only. Cameras come from Frigate's "
                + "/api/config; the fullscreen view plays the go2rtc restream."
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "ONVIF"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: userField
                width: (parent.width - Style.space(8)) / 2
                placeholderText: "user"
                foreground: root.foreground
              }

              TextField {
                id: passwordField
                width: (parent.width - Style.space(8)) / 2
                placeholderText: "password"
                password: true
                foreground: root.foreground
              }
            }

            Row {
              spacing: Style.space(10)

              Button {
                text: root.service && root.service.discovering
                  ? "Detecting…" : "Detect cameras"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.service && !root.service.discovering
                opacity: enabled ? 1 : 0.5
                onClicked: if (root.service) root.service.discover()
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: text !== ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: !root.service ? ""
                : (root.service.probeError || root.service.discoverError)
            }

            // Devices the last probe turned up. Adding one asks it for its
            // stream URL with the credentials above and writes it to
            // cameras.json.
            Repeater {
              model: root.service ? root.service.discovered : []

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Column {
                  width: parent.width - addButton.width - Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: modelData.host
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Button {
                  id: addButton
                  text: root.service && root.service.probing === modelData.xaddr
                    ? "Adding…" : "Add"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: root.service && root.service.probing === ""
                  opacity: enabled ? 1 : 0.5
                  onClicked: if (root.service) {
                    root.service.probeDevice(modelData.xaddr, userField.text, passwordField.text)
                  }
                }
              }
            }

            PanelSeparator {
              foreground: root.foreground
              visible: root.service && root.service.config.onvif.length > 0
            }

            PanelSectionHeader {
              text: "Added by ONVIF"
              foreground: root.foreground
              fontFamily: root.fontFamily
              visible: root.service && root.service.config.onvif.length > 0
            }

            Repeater {
              model: root.service ? root.service.config.onvif : []

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width - removeButton.width - Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: modelData.name + (modelData.ptz ? "  · PTZ" : "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Button {
                  id: removeButton
                  text: "Remove"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.service) root.service.removeOnvif(modelData.name)
                }
              }
            }
          }
        }
      }
    }
  }
}
