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

  // Event alerts. A non-empty alertModel is what puts previews on screen.
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
  readonly property string frigateScript: scriptPath("bin/omarchy-cameras-frigate")
  readonly property string mqttScript: scriptPath("bin/omarchy-cameras-mqtt")

  // With a username set, every Frigate request goes through the helper, which
  // logs in and carries the JWT cookie. Without one, plain curl is enough and
  // no extra process is involved.
  readonly property bool frigateAuthed: !!config.frigate.user

  function frigateCommand(path) {
    if (frigateAuthed) {
      return [frigateScript, "get", config.frigate.url, config.frigate.user, path]
    }
    return ["curl", "-fsS", "--max-time", "10", config.frigate.url + path]
  }

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
          Cameras.frigateCameras(frigateStdout.text, config.frigate, runtimeDir), onvif)
      : onvif
    // Frigate reports its own broker settings, so nothing about MQTT has to be
    // configured twice.
    mqttInfo = Cameras.frigateMqtt(frigateStdout.text)
  }

  // ------------------------------------------------------- thumbnail mirror

  // Only authenticated instances need this: QML fetches unauthenticated URLs
  // perfectly well on its own. Runs while something is actually looking at the
  // thumbnails, so an idle desktop costs nothing.
  property bool thumbsWanted: false

  function syncMirror() {
    var specs = Cameras.mirrorSpecs(cameras)
    var want = thumbsWanted && frigateAuthed && specs.length > 0
    if (mirrorProcess.running === want && !want) return
    mirrorProcess.running = false
    if (!want) return
    mirrorProcess.command = [frigateScript, "mirror", config.frigate.url,
                             config.frigate.user, "2"].concat(specs)
    mirrorProcess.running = true
  }

  onThumbsWantedChanged: syncMirror()
  onCamerasChanged: syncMirror()

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

  // No port argument: the restream port is read back out of Frigate's own
  // camera inputs (see Cameras.restreamPort), so it is not a setting.
  function setFrigate(url, user, password) {
    var trimmedUrl = String(url || "").trim()
    var trimmedUser = String(user || "").trim()
    saveConfig({
      frigate: {
        url: trimmedUrl, rtspPort: config.frigate.rtspPort, user: trimmedUser
      }
    })
    // Blank password means "keep whatever is already in the keyring", so
    // re-saving the URL does not wipe a working login.
    if (trimmedUrl && trimmedUser && password) {
      storePasswordProcess.secret = String(password)
      storePasswordProcess.command = [frigateScript, "store-password", trimmedUrl]
      storePasswordProcess.running = true
    }
    // A changed login invalidates any cookie jar and every mirrored frame.
    mirrorProcess.running = false
    Qt.callLater(syncMirror)
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
    if (alertModel.count > 0) return
    placementVisible = true
    placementTimer.restart()
  }

  // Ids already handled. A detection stays in the in-progress list for as long
  // as it runs, so it comes back on every poll until it ends — the id is what
  // keeps it to one alert.
  property var seenEvents: ({})
  // The first reply only records what Frigate already knows. A shell restart,
  // or arming alerts after they have been off, must not replay the backlog.
  property bool eventsSynced: false

  // ---------------------------------------------------------------- mqtt
  //
  // Frigate publishes a detection the instant it makes it, which is several
  // seconds ahead of any poll. Opt-in, and never the only path: polling keeps
  // running whenever the broker is not actually connected, so a wrong password
  // or a broker reboot degrades to slower alerts rather than none.

  property var mqttInfo: Cameras.frigateMqtt("")
  property bool mqttConnected: false
  property string mqttError: ""
  readonly property bool mqttRunning: mqttProcess.running

  readonly property bool mqttWanted: config.alerts.enabled && config.alerts.useMqtt
    && mqttInfo.enabled && mqttInfo.host !== ""

  // One sentence the panel can show verbatim. Connecting takes a moment and
  // failing takes 70ms, so without this the Save button looks like it did
  // nothing either way.
  readonly property string mqttStatus: {
    if (!mqttInfo.enabled) return "Frigate has MQTT switched off"
    if (!config.alerts.useMqtt) return "Off — alerts poll every 3s"
    if (mqttConnected) return "Connected to " + mqttInfo.host
    if (mqttError) return mqttError + " — still polling every 3s"
    if (mqttRunning) return "Connecting to " + mqttInfo.host + "…"
    return "Not connected — polling every 3s"
  }

  function setMqttEnabled(enabled) {
    if (enabled) mqttError = ""
    saveAlerts({ useMqtt: enabled === true })
  }

  function storeMqttPassword(password) {
    if (!mqttInfo.host) {
      mqttError = "Frigate has not reported a broker yet"
      return
    }
    if (!password) {
      mqttError = "Enter the broker password first"
      return
    }
    // Clear the last failure now, so the panel shows "connecting" rather than
    // the stale reason the previous attempt was rejected for.
    mqttError = ""
    mqttPasswordProcess.secret = String(password)
    mqttPasswordProcess.command = ["secret-tool", "store",
      "--label=Omarchy Frigate MQTT " + mqttInfo.host,
      "service", "omarchy-cameras", "key", "mqtt-" + mqttInfo.host]
    mqttPasswordProcess.running = true
  }

  // Reconnect as soon as the credential is on disk, rather than waiting out
  // the retry interval. Doing it here and not in storeMqttPassword is what
  // guarantees the client reads the new password and not the old one.
  function reconnectMqtt() {
    mqttConnected = false
    mqttProcess.running = false
    if (mqttWanted) mqttProcess.running = true
  }

  function handleMqttLine(line) {
    var message = null
    try { message = JSON.parse(String(line || "")) } catch (e) { return }

    if (Array.isArray(message)) {
      applyEvents(line)
      return
    }
    if (message.ready === true) {
      mqttConnected = true
      mqttError = ""
      // MQTT only ever delivers live detections, so there is no backlog to
      // absorb — the first message through it is a real alert.
      eventsSynced = true
      return
    }
    if (message.error) mqttError = String(message.error)
  }

  // Only detections that are still running. Plain /api/events would report the
  // same thing later, once it has ended, which is exactly the delay this is
  // avoiding — so it is not worth a second request.
  //
  // The window reaches further back than the newest event seen, so a detection
  // that started before it but is reported late is still in range. Id dedup,
  // not the window, is what prevents repeats.
  function pollEvents() {
    if (!config.alerts.enabled || !config.frigate.url || eventsProcess.running) return
    eventsProcess.command = frigateCommand(
      "/api/events?limit=20&in_progress=1&after=" + Math.max(0, lastEventTime - 120))
    eventsProcess.running = true
  }

  function applyEvents(raw) {
    var result = Cameras.newEvents(raw, config.alerts.labels, seenEvents)

    if (result.newest > lastEventTime) {
      lastEventTime = result.newest
      stateFile.setText(String(lastEventTime) + "\n")
    }

    // Prune first, then re-mark everything in this payload — never the other
    // way round. A detection can stay in progress for hours (a parked car, a
    // bicycle left in frame), and pruning it after marking would drop an id
    // that is still being reported, so the next poll would see it as new and
    // alert on it again every few seconds.
    var seen = Cameras.pruneSeen(seenEvents, lastEventTime - 600)
    var ids = Cameras.eventIds(raw)
    for (var i = 0; i < ids.length; i++) seen[ids[i].id] = ids[i].startTime
    seenEvents = seen

    if (!eventsSynced) {
      eventsSynced = true
      return
    }
    // Oldest first, so a burst stacks in the order it happened: the first
    // detection sits at the top and later ones appear underneath it.
    for (var j = 0; j < result.events.length; j++) pushAlert(result.events[j])
  }

  function pushAlert(event) {
    var camera = null
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].name === event.camera) { camera = cameras[i]; break }
    }
    if (!camera) return

    // ponytail: four cards. Past that the column is taller than it is useful
    // and the oldest is the least interesting, so it goes.
    while (alertModel.count >= 4) alertModel.remove(0)

    alertModel.append({
      eventId: event.id,
      cameraId: camera.id,
      cameraName: camera.name,
      label: event.label,
      // Unauthenticated instances can point QML straight at Frigate. With a
      // login the still has to be fetched with the cookie first, so the card
      // goes up empty now and fills in when the file lands.
      imageUrl: frigateAuthed ? "" : Cameras.eventImageUrl(config.frigate.url, event),
      imagePath: Cameras.eventImagePath(event)
    })
    if (frigateAuthed) fetchNextShot()
  }

  // One download at a time, in arrival order — a burst of events should not
  // open a burst of curls at the NVR.
  property bool fetchingShot: false

  function fetchNextShot() {
    if (fetchingShot) return
    for (var i = 0; i < alertModel.count; i++) {
      var entry = alertModel.get(i)
      if (entry.imageUrl !== "" || !entry.imagePath) continue
      fetchingShot = true
      eventShotProcess.pendingId = entry.eventId
      eventShotProcess.command = [frigateScript, "save", config.frigate.url,
        config.frigate.user, entry.imagePath, "event-" + Cameras.slug(entry.eventId)]
      eventShotProcess.running = true
      return
    }
  }

  function applyShot(eventId, ok) {
    fetchingShot = false
    if (ok) {
      for (var i = 0; i < alertModel.count; i++) {
        if (alertModel.get(i).eventId !== eventId) continue
        alertModel.setProperty(i, "imageUrl",
          "file://" + runtimeDir + "/event-" + Cameras.slug(eventId) + ".jpg")
        break
      }
    }
    fetchNextShot()
  }

  function dismissAlert(index) {
    if (index >= 0 && index < alertModel.count) alertModel.remove(index)
  }

  function dismissAllAlerts() {
    alertModel.clear()
  }

  // Each card owns its own expiry timer in Alert.qml, so the stack drains one
  // card at a time in the order the detections arrived.
  ListModel { id: alertModel }

  // ------------------------------------------------------------- frigate

  function fetchFrigateConfig() {
    if (!config.frigate.url || frigateProcess.running) return
    loading = true
    frigateProcess.command = frigateCommand("/api/config")
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

  // ponytail: polling, not MQTT. No mosquitto client is installed, and a few
  // seconds of lag on a doorway preview is not worth a dependency. Swap in
  // mosquitto_sub if sub-second alerts, or catching every last sub-3s
  // detection, ever matters.
  //
  // 3s rather than 5s: watching only in-progress events means a detection that
  // starts and ends between two polls is never seen at all, and halving the
  // interval costs nothing now that each poll is one request instead of two.
  //
  // Keeps running whenever MQTT is not actually connected — including while it
  // is retrying — so the fast path failing costs latency, never alerts.
  Timer {
    interval: 3000
    running: root.config.alerts.enabled && root.config.frigate.url !== ""
      && !root.mqttConnected
    repeat: true
    triggeredOnStart: true
    // Arming alerts starts a fresh sync, so whatever happened while they were
    // off stays off the screen.
    onRunningChanged: if (running) root.eventsSynced = false
    onTriggered: root.pollEvents()
  }

  // Long-running: keeps the visible cameras' JPEGs fresh on disk until stopped.
  Process { id: mirrorProcess }

  // secret-tool reads the password on stdin, so it never lands in argv where
  // any process on the machine could read it out of /proc.
  Process {
    id: storePasswordProcess
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
  }

  Process {
    id: eventShotProcess
    property string pendingId: ""
    onExited: function(code) { root.applyShot(pendingId, code === 0) }
  }

  Process {
    id: eventsProcess
    stdout: StdioCollector {
      id: eventsStdout
      waitForEnd: true
      onStreamFinished: root.applyEvents(eventsStdout.text)
    }
  }

  // Long-lived: one JSON line per detection, streamed as they happen.
  //
  // `running` is driven by hand rather than bound to mqttWanted. The process
  // ends on its own — a refused password takes milliseconds — and that write
  // to `running` breaks any binding on it, so the binding would never restart
  // it. mqttRetry owns the restarting instead.
  Process {
    id: mqttProcess
    command: [root.mqttScript, root.mqttInfo.host, String(root.mqttInfo.port),
              root.mqttInfo.prefix, "--user", root.mqttInfo.user]
    stdout: SplitParser { onRead: function(line) { root.handleMqttLine(line) } }
    onExited: root.mqttConnected = false
  }

  // The first attempt happens the moment MQTT is switched on; retries wait.
  onMqttWantedChanged: if (mqttWanted && !mqttProcess.running) mqttProcess.running = true

  // Runs exactly while MQTT is wanted but not up, so one rule covers a
  // rejected password and a broker reboot alike. Polling fills the gap, which
  // is why this can afford to be unhurried.
  //
  // No triggeredOnStart: a refused connection dies in 70ms, and firing on
  // start turned this into a spawn loop — 451 processes in one sitting before
  // it was caught.
  Timer {
    id: mqttRetry
    interval: 15000
    repeat: true
    running: root.mqttWanted && !mqttProcess.running
    onTriggered: if (root.mqttWanted && !mqttProcess.running) mqttProcess.running = true
  }

  Process {
    id: mqttPasswordProcess
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(code) {
      if (code === 0) root.reconnectMqtt()
      else root.mqttError = "Could not save the password to the keyring"
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
    model: alertModel
    placeholder: root.placementVisible && alertModel.count === 0
    previewWidth: root.config.alerts.width
    position: root.config.alerts.position
    durationSec: root.config.alerts.durationSec
    onExpired: function(index) { root.dismissAlert(index) }
    onActivated: function(index) {
      var cameraId = alertModel.get(index).cameraId
      root.dismissAlert(index)
      root.view(cameraId)
    }
  }
}
