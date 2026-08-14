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
  readonly property bool alertsOn: service ? service.config.alerts.enabled : false

  // "grid" or "config".
  property string view: "grid"

  readonly property int columns: clampSetting("columns", 2, 1, 4)
  readonly property int thumbIntervalMs: clampSetting("thumbIntervalMs", 2000, 500, 30000)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  // The bar exposes `urgent` but not `accent`, so the theme singleton is the
  // source for that one.
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Three shapes the config form repeats: the label above a field, the
  // explanatory line under a group, and the right-aligned row of buttons that
  // acts on the fields above it. Defining them once is what keeps every
  // section laid out the same way.
  component FieldLabel: Text {
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  component Hint: Text {
    width: parent ? parent.width : 0
    wrapMode: Text.WordWrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Actions: Item {
    default property alias buttons: actionRow.children
    width: parent ? parent.width : 0
    implicitHeight: actionRow.implicitHeight

    Row {
      id: actionRow
      anchors.right: parent.right
      spacing: Style.space(8)
    }
  }

  readonly property int tileWidth: Style.space(170)
  readonly property int tileHeight: Math.round(tileWidth * 9 / 16)
  readonly property int tileSpacing: Style.space(8)
  readonly property int gridWidth: columns * tileWidth + (columns - 1) * tileSpacing

  // Monitors to choose from for the alert preview, straight off the
  // compositor so an unplugged display disappears from the list.
  readonly property var monitorOptions: {
    var out = [{ value: "", label: "First available" }]
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      out.push({ value: screens[i].name, label: screens[i].name })
    }
    return out
  }

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
      frigateUserField.text = service.config.frigate.user
      frigatePasswordField.text = ""
      durationField.text = String(service.config.alerts.durationSec)
      alertWidthField.text = String(service.config.alerts.width)
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
  readonly property bool showingThumbs: opened && view === "grid" && hasCameras

  Timer {
    interval: root.thumbIntervalMs
    running: root.showingThumbs
    repeat: true
    onTriggered: root.tick++
  }

  // Tells the service to run the authenticated mirror only while thumbnails
  // are on screen. One widget per monitor writes this, so it is an OR: any
  // open grid keeps the mirror alive.
  onShowingThumbsChanged: if (service) {
    if (showingThumbs) service.thumbsWanted = true
    else Qt.callLater(function() { if (!root.showingThumbs) service.thumbsWanted = false })
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
    // Open first, then switch: onOpenedChanged picks the view when the panel
    // opens, so setting it beforehand just gets overwritten.
    function config(): void {
      root.open()
      root.showConfig()
    }
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
    function showPlacement(): string {
      if (!root.service) return "service unavailable"
      root.service.showPlacement()
      return "ok"
    }
    function mqtt(state: string): string {
      if (!root.service) return "service unavailable"
      if (state === "on" || state === "off") root.service.setMqttEnabled(state === "on")
      var info = root.service.mqttInfo
      return "wanted=" + root.service.config.alerts.useMqtt
        + " active=" + root.service.mqttWanted
        + " procRunning=" + root.service.mqttRunning
        + " connected=" + root.service.mqttConnected
        + " broker=\"" + info.host + ":" + info.port + "\""
        + " frigateMqtt=" + info.enabled
        + " user=\"" + info.user + "\""
        + (root.service.mqttError ? " error=\"" + root.service.mqttError + "\"" : "")
    }
    // ONVIF discovery is wired up but not surfaced while the Frigate side is
    // being finished; these keep it reachable for testing.
    function discover(): string {
      if (!root.service) return "service unavailable"
      root.service.discover()
      return "ok"
    }
    function discovery(): string {
      if (!root.service) return "service unavailable"
      var found = root.service.discovered.map(function(d) { return d.name })
      return "discovering=" + root.service.discovering
        + " probing=\"" + root.service.probing + "\""
        + " found=[" + found.join(",") + "]"
        + (root.service.discoverError ? " error=\"" + root.service.discoverError + "\"" : "")
    }
    // Same write the config form does, for setting a machine up from a script.
    // No password here on purpose: it would land in the shell history and in
    // this process's argv. Store it with
    //   bin/omarchy-cameras-frigate store-password <url>
    // which reads it on stdin, or use the config form.
    function setFrigate(url: string, user: string): string {
      if (!root.service) return "service unavailable"
      root.service.setFrigate(url, user, "")
      return "ok"
    }
    function alerts(state: string): string {
      if (!root.service) return "service unavailable"
      if (state === "on" || state === "off") {
        root.service.setAlertsEnabled(state === "on")
      }
      return root.alertsOn ? "on" : "off"
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰞮"
    dimmed: !root.hasCameras
    // Alerts on is the state worth marking: it is the one that makes windows
    // appear on their own, and the user needs to see at a glance that it is
    // armed.
    active: root.alertsOn
    tooltipText: (root.hasCameras
      ? root.cameras.length + (root.cameras.length === 1 ? " camera" : " cameras")
      : "No cameras configured")
      + (root.alertsOn ? "  ·  alerts on" : "")
    onPressed: function(code) {
      if (code === Qt.RightButton && root.service) root.service.refresh()
      else if (code === Qt.MiddleButton && root.service) root.service.setAlertsEnabled(!root.alertsOn)
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
    // fittedContentHeight clamps to the screen anyway, so the cap only has
    // to be generous enough that the config form is not cut off before
    // its last section.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The catcher takes keys before its children, so every text input has to
      // be named here or it silently refuses to accept letters.
      blocked: urlField.activeFocus
        || frigateUserField.activeFocus || frigatePasswordField.activeFocus
        || durationField.activeFocus || alertWidthField.activeFocus
        || mqttPasswordField.activeFocus
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

                  CameraThumb {
                    id: thumb
                    anchors.fill: parent
                    camera: tile.modelData
                    tick: root.tick
                    active: root.opened && root.view === "grid"
                  }

                  // Covers both "still loading" and "camera is down" — either
                  // way there is no picture and the name is what identifies
                  // the tile.
                  Text {
                    anchors.centerIn: parent
                    visible: !thumb.hasFrame
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

            FieldLabel { text: "Server URL" }

            TextField {
              id: urlField
              width: parent.width
              placeholderText: "http://nvr.lan:5000"
              foreground: root.foreground
              onAccepted: saveFrigate.clicked()
            }

            FieldLabel { text: "Login — only if Frigate asks for one" }

            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: frigateUserField
                width: (parent.width - Style.space(8)) / 2
                placeholderText: "user"
                foreground: root.foreground
                onAccepted: saveFrigate.clicked()
              }

              TextField {
                id: frigatePasswordField
                width: (parent.width - Style.space(8)) / 2
                placeholderText: "password"
                password: true
                foreground: root.foreground
                onAccepted: saveFrigate.clicked()
              }
            }

            Actions {
              Button {
                id: saveFrigate
                text: "Save"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) {
                  root.service.setFrigate(urlField.text,
                    frigateUserField.text, frigatePasswordField.text)
                  frigatePasswordField.text = ""
                }
              }
            }

            Hint {
              text: "Passwords go to the keyring, never to the config file. "
                + "Leaving one blank keeps the one already stored."
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "Motion alerts"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Toggle {
              width: parent.width
              label: "Pop up a preview on detection"
              description: root.service && !root.service.config.frigate.url
                ? "Needs a Frigate URL first" : "From Frigate's own detections"
              checked: root.alertsOn
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: if (root.service) root.service.setAlertsEnabled(!checked)
            }

            // Everything below only matters once alerts are on, and hiding it
            // keeps the form short enough to read without scrolling.
            Column {
              width: parent.width
              spacing: Style.space(10)
              visible: root.alertsOn

              Dropdown {
                width: parent.width
                label: "Monitor"
                value: root.service ? root.service.config.alerts.monitor : ""
                options: root.monitorOptions
                fontFamily: root.fontFamily
                onChanged: function(v) { if (root.service) root.service.saveAlerts({ monitor: v }) }
              }

              Dropdown {
                width: parent.width
                label: "Corner"
                value: root.service ? root.service.config.alerts.position : "top-center"
                options: [
                  { value: "top-left", label: "Top left" },
                  { value: "top-center", label: "Top center (by the clock)" },
                  { value: "top-right", label: "Top right" }
                ]
                fontFamily: root.fontFamily
                onChanged: function(v) { if (root.service) root.service.saveAlerts({ position: v }) }
              }

              Row {
                width: parent.width
                spacing: Style.space(12)

                Column {
                  spacing: Style.space(4)
                  FieldLabel { text: "Seconds on screen" }
                  TextField {
                    id: durationField
                    width: Style.space(100)
                    placeholderText: "12"
                    foreground: root.foreground
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: IntValidator { bottom: 2; top: 300 }
                    onAccepted: saveAlertSizing.clicked()
                  }
                }

                Column {
                  spacing: Style.space(4)
                  FieldLabel { text: "Preview width" }
                  TextField {
                    id: alertWidthField
                    width: Style.space(100)
                    placeholderText: "320"
                    foreground: root.foreground
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: IntValidator { bottom: 120; top: 960 }
                    onAccepted: saveAlertSizing.clicked()
                  }
                }
              }

              Actions {
                Button {
                  text: "Show me"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.service) root.service.showPlacement()
                }

                Button {
                  id: saveAlertSizing
                  text: "Save"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.service) {
                    root.service.saveAlerts({
                      durationSec: parseInt(durationField.text, 10) || 12,
                      width: parseInt(alertWidthField.text, 10) || 320
                    })
                  }
                }
              }

              Hint {
                text: "Changing the monitor, corner or width rehearses the "
                  + "placement for 5s. Middle-click the bar icon to switch "
                  + "alerts off without opening this."
              }
            }

            PanelSeparator {
              foreground: root.foreground
              visible: root.alertsOn
            }

            PanelSectionHeader {
              text: "MQTT"
              foreground: root.foreground
              fontFamily: root.fontFamily
              visible: root.alertsOn
            }

            Toggle {
              width: parent.width
              visible: root.alertsOn
              label: "Alert the instant Frigate detects"
              description: root.service ? root.service.mqttStatus : ""
              checked: root.service && root.service.config.alerts.useMqtt
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: if (root.service) root.service.setMqttEnabled(!checked)
            }

            Column {
              width: parent.width
              spacing: Style.space(10)
              visible: root.alertsOn && root.service && root.service.config.alerts.useMqtt

              FieldLabel {
                text: root.service && root.service.mqttInfo.user
                  ? "Broker password for " + root.service.mqttInfo.user
                  : "Broker password"
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                TextField {
                  id: mqttPasswordField
                  width: parent.width - mqttSave.width - Style.space(8)
                  placeholderText: "password"
                  password: true
                  foreground: root.foreground
                  onAccepted: mqttSave.clicked()
                }

                Button {
                  id: mqttSave
                  text: "Connect"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.service) {
                    root.service.storeMqttPassword(mqttPasswordField.text)
                    mqttPasswordField.text = ""
                  }
                }
              }

              // Connecting takes a moment and failing takes 70ms, so without
              // this the Connect button looks like it did nothing either way.
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.service ? root.service.mqttStatus : ""
                color: !root.service ? root.dim
                  : (root.service.mqttConnected ? root.accent
                      : (root.service.mqttError ? root.urgent : root.dim))
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.service
                  && (root.service.mqttConnected || root.service.mqttError !== "")
              }

              Hint {
                text: {
                  if (!root.service) return ""
                  var info = root.service.mqttInfo
                  return "Broker, port, topic and user all come from Frigate ("
                    + info.host + ":" + info.port + ", " + info.prefix
                    + "/events). Polling keeps running until this connects."
                }
              }
            }
          }
        }
      }
    }
  }
}
