// Camera registry for the avila.cameras plugin.
//
// Loaded once per shell session (kind: "service"), so the bar widget — which
// the shell instantiates once per monitor — can read one shared camera list
// instead of each copy polling Frigate on its own. It also owns every write
// to cameras.json, so the config screen never has two writers racing.

import QtQuick
import Quickshell
import Quickshell.Io
import "Cameras.js" as Cameras

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/cameras.json"
  readonly property string runtimeDir:
    (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-cameras"

  // Parsed cameras.json. Also the ONVIF discovery cache.
  property var config: Cameras.parseConfig("")
  property var cameras: []
  property bool loading: false
  property string lastError: ""

  // Event alerts. `alertCamera` non-null is what puts the preview on screen.
  property var alertCamera: null
  property string alertLabel: ""
  property bool placementVisible: false
  // Newest Frigate event start_time already handled, persisted so a shell
  // restart does not replay the day's detections as a burst of previews.
  property real lastEventTime: 0
  readonly property string statePath:
    home + "/.local/state/omarchy/cameras-last-event"

  // ONVIF discovery state, driven from the config screen.
  property bool discovering: false
  property var discovered: []
  property string discoverError: ""
  property string probing: ""
  property string probeError: ""

  readonly property string viewScript: scriptPath("bin/omarchy-cameras-view")
  readonly property string onvifScript: scriptPath("bin/omarchy-cameras-onvif")

  function scriptPath(relative) {
    return decodeURIComponent(
      String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, ""))
  }

  function cameraById(id) {
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].id === id) return cameras[i]
    }
    return null
  }

  // Open a camera fullscreen in mpv. Detached on purpose: the viewer outlives
  // the popup that launched it, and quitting mpv must not disturb the shell.
  function view(id) {
    var camera = cameraById(id)
    if (!camera) return
    Quickshell.execDetached([viewScript, camera.name, camera.stream, camera.user || ""])
  }

  function refresh() {
    configFile.reload()
    fetchFrigateConfig()
  }

  function rebuild() {
    var onvif = Cameras.onvifCameras(config, runtimeDir)
    cameras = config.frigate.url
      ? Cameras.mergeCameras(
          Cameras.frigateCameras(frigateStdout.text, config.frigate), onvif)
      : onvif
  }

  // ------------------------------------------------------------- writing

  // Read-modify-write of cameras.json. The FileView is watched, so the write
  // comes back through onLoaded and rebuilds the camera list — there is no
  // second code path for "config we just saved".
  function saveConfig(patch) {
    var next = {
      frigate: { url: config.frigate.url, rtspPort: config.frigate.rtspPort },
      notifyLabels: config.notifyLabels.slice(),
      alerts: config.alerts,
      onvif: config.onvif.slice()
    }
    for (var key in patch) next[key] = patch[key]
    configFile.setText(JSON.stringify(next, null, 2) + "\n")
    config = Cameras.parseConfig(JSON.stringify(next))
  }

  function setFrigate(url, port) {
    saveConfig({ frigate: { url: String(url || "").trim(), rtspPort: port } })
  }

  function removeOnvif(name) {
    saveConfig({
      onvif: config.onvif.filter(function(entry) { return entry.name !== name })
    })
  }

  // ----------------------------------------------------------- discovery

  // StdioCollector.text is read-only — assigning to it throws, which would
  // abort this function before the process ever starts and leave the button
  // spinning forever. The collector resets itself on each run anyway.
  function discover() {
    if (discovering) return
    discovering = true
    discoverError = ""
    discovered = []
    discoverProcess.command = [onvifScript, "discover", "--timeout", "3"]
    discoverProcess.running = true
    discoverWatchdog.restart()
  }

  function applyDiscovery(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (e) { parsed = null }
    if (!parsed || !Array.isArray(parsed.devices)) {
      discoverError = "Discovery returned nothing readable"
      discovered = []
      return
    }
    discovered = parsed.devices
    // An empty result is a real answer, not a failure — say which one it is.
    discoverError = parsed.devices.length === 0
      ? "No ONVIF cameras answered on this network" : ""
  }

  // Ask one discovered device for its stream URL and add it to the config.
  // The password goes over stdin, never argv.
  function probeDevice(xaddr, user, password) {
    if (probing) return
    probing = xaddr
    probeError = ""
    probeProcess.secret = password
    probeProcess.command = [onvifScript, "probe", xaddr, "--user", user]
    probeProcess.running = true
    probeWatchdog.restart()
  }

  function applyProbe(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (e) { parsed = null }
    if (!parsed || !parsed.camera) {
      probeError = parsed && parsed.error ? parsed.error : "Camera did not answer"
      return
    }
    probeError = ""
    saveConfig({ onvif: Cameras.upsertOnvif(config, parsed.camera) })
  }

  // -------------------------------------------------------------- alerts

  function setAlertsEnabled(enabled) {
    var alerts = {}
    for (var key in config.alerts) alerts[key] = config.alerts[key]
    alerts.enabled = enabled === true
    saveConfig({ alerts: alerts })
  }

  function saveAlerts(patch) {
    var alerts = {}
    for (var key in config.alerts) alerts[key] = config.alerts[key]
    for (var field in patch) alerts[field] = patch[field]
    saveConfig({ alerts: alerts })
    // Placement is the one setting whose effect is invisible until something
    // trips an alert, which could be hours away. Rehearse it immediately.
    if (patch.monitor !== undefined || patch.position !== undefined
        || patch.width !== undefined) {
      showPlacement()
    }
  }

  function showPlacement() {
    // A real alert outranks a rehearsal of where alerts go.
    if (alertCamera) return
    placementVisible = true
    placementTimer.restart()
  }

  function pollEvents() {
    if (!config.alerts.enabled || !config.frigate.url || eventsProcess.running) return
    eventsProcess.command = ["curl", "-fsS", "--max-time", "5",
      config.frigate.url + "/api/events?limit=20&after=" + lastEventTime]
    eventsProcess.running = true
  }

  function applyEvents(raw) {
    var result = Cameras.newEvents(raw, lastEventTime, config.alerts.labels)
    var firstRun = lastEventTime === 0
    if (result.after > lastEventTime) {
      lastEventTime = result.after
      stateFile.setText(String(lastEventTime) + "\n")
    }
    // The first poll after a cold start has no watermark, so everything
    // Frigate still remembers looks new. Adopt the watermark, show nothing.
    if (firstRun || result.events.length === 0) return

    var latest = result.events[result.events.length - 1]
    var camera = null
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].name === latest.camera) { camera = cameras[i]; break }
    }
    if (!camera) return
    alertLabel = latest.label
    alertCamera = camera
    alertTimer.restart()
  }

  function dismissAlert() {
    alertTimer.stop()
    alertCamera = null
    alertLabel = ""
  }

  // ------------------------------------------------------------- frigate

  function fetchFrigateConfig() {
    if (!config.frigate.url || frigateProcess.running) return
    loading = true
    frigateProcess.command = ["curl", "-fsS", "--max-time", "5",
                              config.frigate.url + "/api/config"]
    frigateProcess.running = true
  }

  onConfigChanged: {
    rebuild()
    fetchFrigateConfig()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    // Absent config is the normal first-run state, not something to log about.
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.config = Cameras.parseConfig(text())
    onLoadFailed: root.config = Cameras.parseConfig("")
  }

  Process {
    id: frigateProcess

    stdout: StdioCollector {
      id: frigateStdout
      waitForEnd: true
      // Also fires on failure, with empty text — which rebuilds to the ONVIF
      // list alone. Exactly the right fallback, so there is no separate
      // error path to write.
      onStreamFinished: root.rebuild()
    }

    onExited: function(code) {
      root.loading = false
      root.lastError = code === 0
        ? "" : "Frigate unreachable at " + root.config.frigate.url
    }
  }

  Process {
    id: discoverProcess
    stdout: StdioCollector {
      id: discoverStdout
      waitForEnd: true
      // streamFinished, not exited: at exit the collector may not have the
      // whole payload yet. It fires on failure too, with empty text, which
      // applyDiscovery reports as unreadable.
      onStreamFinished: {
        discoverWatchdog.stop()
        root.discovering = false
        root.applyDiscovery(discoverStdout.text)
      }
    }
  }

  // A process that never starts — a missing or non-executable script — emits
  // neither exited nor streamFinished, and the button would spin forever.
  // Discovery itself is bounded at 3s inside the script.
  Timer {
    id: discoverWatchdog
    interval: 10000
    onTriggered: {
      root.discovering = false
      root.discoverError = "Discovery did not finish — is bin/omarchy-cameras-onvif executable?"
    }
  }

  Process {
    id: probeProcess
    property string secret: ""
    stdinEnabled: true
    stdout: StdioCollector {
      id: probeStdout
      waitForEnd: true
      onStreamFinished: {
        probeWatchdog.stop()
        root.probing = ""
        root.applyProbe(probeStdout.text)
      }
    }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
  }

  // Each SOAP call inside probe has its own 6s timeout and there are up to
  // four of them, so give the whole exchange room before calling it stuck.
  Timer {
    id: probeWatchdog
    interval: 30000
    onTriggered: {
      root.probing = ""
      root.probeError = "Camera did not answer in time"
    }
  }

  // Frigate restarts and cameras get added. Five minutes is well below how
  // often that happens and well above how often it is worth asking.
  Timer {
    interval: 300000
    running: root.config.frigate.url !== ""
    repeat: true
    onTriggered: root.fetchFrigateConfig()
  }

  // ponytail: polling, not MQTT. No mosquitto client is installed, and five
  // seconds of lag on a doorway preview is not worth a dependency. Swap in
  // mosquitto_sub if sub-second alerts ever matter.
  Timer {
    interval: 5000
    running: root.config.alerts.enabled && root.config.frigate.url !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollEvents()
  }

  Process {
    id: eventsProcess
    stdout: StdioCollector {
      id: eventsStdout
      waitForEnd: true
      onStreamFinished: root.applyEvents(eventsStdout.text)
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.lastEventTime = Number(text()) || 0
    onLoadFailed: root.lastEventTime = 0
  }

  Timer {
    id: alertTimer
    interval: root.config.alerts.durationSec * 1000
    onTriggered: root.dismissAlert()
  }

  // Long enough to look at, short enough that changing two settings in a row
  // does not leave a rehearsal parked on the screen.
  Timer {
    id: placementTimer
    interval: 5000
    onTriggered: root.placementVisible = false
  }

  // One preview window, on the monitor the user picked. Quickshell.screens is
  // the authority on what exists; a monitor that has been unplugged since the
  // setting was saved falls back to the first one rather than showing nothing.
  Alert {
    screen: {
      var wanted = root.config.alerts.monitor
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++) {
        if (screens[i].name === wanted) return screens[i]
      }
      return screens.length > 0 ? screens[0] : null
    }
    camera: root.alertCamera
    label: root.alertLabel
    placeholder: root.placementVisible && root.alertCamera === null
    previewWidth: root.config.alerts.width
    position: root.config.alerts.position
    onActivated: {
      var camera = root.alertCamera
      root.dismissAlert()
      if (camera) root.view(camera.id)
    }
  }
}
