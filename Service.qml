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
  // $XDG_RUNTIME_DIR only, with no fallback: it is per-user and 0700, and a
  // Wayland session cannot exist without it — the compositor socket is in
  // there. A fallback to world-writable /tmp would put camera frames on a
  // predictable path anyone could create first. Empty here means the helpers
  // that write those frames refuse to run, so nothing reads a planted file.
  readonly property string runtimeDir: {
    var base = Quickshell.env("XDG_RUNTIME_DIR")
    return base ? base + "/omarchy-cameras" : ""
  }

  // Parsed cameras.json. Also the ONVIF discovery cache.
  property var config: Cameras.parseConfig("")
  property var cameras: []
  property bool loading: false
  property string lastError: ""

  // Event alerts. A non-empty alertModel is what puts previews on screen.
  property bool placementVisible: false
  property real lastAlertLatency: -1
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
  readonly property string thumbScript: scriptPath("bin/omarchy-cameras-thumbd")

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

  // ------------------------------------------------------- dependencies

  // A missing binary makes Process fail to start, which shows up nowhere but
  // a shell warning — so check once and let the config screen say so.
  property var missingTools: []
  readonly property string missingToolsText: Cameras.describeMissingTools(missingTools)

  function checkTools() {
    if (toolCheckProcess.running) return
    toolCheckProcess.command = Cameras.toolCheckCommand()
    toolCheckProcess.running = true
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

  // A source that is switched off contributes no cameras and starts no
  // processes, so turning Frigate off really does leave an ONVIF-only setup.
  // Read as a function inside anything onConfigChanged calls: a binding on
  // `config` has not been re-evaluated yet at the moment its own change
  // handler runs, so the property would still hold the previous answer.
  function frigateEnabled() {
    return config.sources.frigate === true && config.frigate.url !== ""
  }

  readonly property bool frigateOn: config.sources.frigate && config.frigate.url !== ""
  readonly property bool onvifOn: config.sources.onvif

  function rebuild() {
    var onvif = config.sources.onvif ? Cameras.onvifCameras(config, runtimeDir) : []
    cameras = frigateEnabled()
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

  // ONVIF cameras have no snapshot endpoint worth relying on, so a frame is
  // decoded out of the RTSP stream instead. Same lifetime rule as the Frigate
  // mirror: only while someone is looking.
  function syncOnvifThumbs() {
    var specs = Cameras.onvifThumbSpecs(cameras)
    var want = thumbsWanted && runtimeDir !== "" && specs.length > 0
    thumbProcess.running = false
    if (!want) return
    // The camera list goes in on stdin, never argv: a stream path and the
    // account it is watched with are readable by every user on the machine
    // once they are in /proc. Only the interval is an argument.
    thumbProcess.specs = specs.join("\n") + "\n"
    thumbProcess.command = [thumbScript, "2"]
    thumbProcess.stdinEnabled = true
    thumbProcess.running = true
  }

  onThumbsWantedChanged: { syncMirror(); syncOnvifThumbs() }
  onCamerasChanged: { syncMirror(); syncOnvifThumbs() }

  // ------------------------------------------------------------- writing

  // Read-modify-write of cameras.json. The FileView is watched, so the write
  // comes back through onLoaded and rebuilds the camera list — there is no
  // second code path for "config we just saved".
  function saveConfig(patch) {
    var next = {
      sources: { frigate: config.sources.frigate, onvif: config.sources.onvif },
      frigate: { url: config.frigate.url, rtspPort: config.frigate.rtspPort,
                 user: config.frigate.user },
      notifyLabels: config.notifyLabels.slice(),
      alerts: config.alerts,
      onvif: config.onvif.slice()
    }
    for (var key in patch) next[key] = patch[key]
    configFile.setText(JSON.stringify(next, null, 2) + "\n")
    config = Cameras.parseConfig(JSON.stringify(next))
    restrictConfig()
  }

  // cameras.json holds no password, but it does hold every camera's address,
  // its stream path and the account watching it — the same thing that is kept
  // out of argv for the same reason. The default umask leaves it 0644 or 0664,
  // readable by every other account on the machine.
  //
  // FileView has no permission setting, and atomicWrites renames a fresh file
  // into place on every save, so the mode has to be reapplied after each write
  // rather than set once. Driven from saveConfig and from startup, never from
  // onLoaded: chmod touches the file the FileView is watching, and reacting to
  // that would be a loop.
  function restrictConfig() {
    chmodProcess.running = false
    chmodProcess.command = ["chmod", "600", configPath]
    chmodProcess.running = true
  }

  Process { id: chmodProcess }

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
      storePasswordProcess.stdinEnabled = true
      storePasswordProcess.running = true
    }
    // A changed login invalidates any cookie jar and every mirrored frame.
    mirrorProcess.running = false
    Qt.callLater(syncMirror)
  }

  function setSource(name, enabled) {
    var sources = { frigate: config.sources.frigate, onvif: config.sources.onvif }
    sources[name] = enabled === true
    saveConfig({ sources: sources })
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

  // Ask one device for its stream URL and add it to the config. `target` is
  // either an xaddr from discovery or an address the user typed — the script
  // resolves a bare address by trying the usual ONVIF ports.
  //
  // The password goes over stdin, never argv.
  function probeDevice(target, user, password) {
    if (probing) return
    probing = target
    probeError = ""
    probeProcess.secret = password
    probeProcess.command = [onvifScript, "probe", target, "--user", user]
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

  // Whether detections are being watched at all. Only a transition into this
  // resets the sync: going from not watching to watching means everything
  // Frigate has is history, and replaying it would put a column of stale
  // previews on screen.
  //
  // Deliberately not tied to the polling Timer, which also starts when MQTT
  // drops. That is not a transition into watching — alerts were already armed
  // and whatever is in frame right now is live news, not backlog. Resetting
  // there made the first poll after every reconnect mark those detections seen
  // and return without alerting, losing them outright rather than delaying
  // them. Re-alerting is not a risk: anything MQTT already delivered is in
  // seenEvents, and newEvents filters on id.
  readonly property bool watchingEvents: config.alerts.enabled && frigateOn
  onWatchingEventsChanged: if (watchingEvents) eventsSynced = false

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

  readonly property bool mqttWanted: frigateOn && config.alerts.enabled
    && config.alerts.useMqtt && mqttInfo.enabled && mqttInfo.host !== ""

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

  // Credentials that cross the network readable because the server is
  // configured that way. Not something the plugin can fix on its own, and a
  // Frigate on plain HTTP over a home LAN is an ordinary setup — so the config
  // screen says so rather than refusing to work.
  readonly property var insecureWarnings: Cameras.insecureWarnings(config, mqttInfo)

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
    mqttPasswordProcess.stdinEnabled = true
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

    // How far behind the detection this alert is. The only honest way to
    // compare the MQTT and polling paths, and worth keeping: "are my alerts
    // fresh" is a real question once this is running unattended.
    lastAlertLatency = Math.max(0, Date.now() / 1000 - event.startTime)

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
    if (!frigateEnabled() || frigateProcess.running) return
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
  // Generous, because discovery sweeps the subnet host by host: ~12s on a /24,
  // and firing before that would report a working search as broken.
  Timer {
    id: discoverWatchdog
    interval: 45000
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
    running: root.frigateOn
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
    running: root.config.alerts.enabled && root.frigateOn && !root.mqttConnected
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollEvents()
  }

  Process {
    id: toolCheckProcess
    stdout: StdioCollector {
      id: toolCheckStdout
      waitForEnd: true
      onStreamFinished: root.missingTools = Cameras.parseMissingTools(toolCheckStdout.text)
    }
  }

  Component.onCompleted: {
    checkTools()
    restrictConfig()
  }

  // Long-running: keeps the visible cameras' JPEGs fresh on disk until stopped.
  Process { id: mirrorProcess }

  // One ffmpeg per ONVIF camera, held open for as long as the grid is up.
  Process {
    id: thumbProcess
    property string specs: ""
    stdinEnabled: true
    // thumbd reads the whole list, so it needs EOF. Process.write() does not
    // close the pipe on its own — clearing stdinEnabled is what does.
    onStarted: { write(specs); stdinEnabled = false }
  }

  // The password goes over stdin, never argv, where any process on the machine
  // could read it out of /proc. Same EOF requirement as above.
  Process {
    id: storePasswordProcess
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
      stdinEnabled = false
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
    command: Cameras.mqttCommand(root.mqttScript, root.mqttInfo)
    stdout: SplitParser { onRead: function(line) { root.handleMqttLine(line) } }
    onExited: root.mqttConnected = false
  }

  // The first attempt happens the moment MQTT is switched on; retries wait.
  // Both directions: switching the Frigate source off has to take the broker
  // connection down with it, not leave a subscriber running for a source the
  // user just disabled.
  onMqttWantedChanged: {
    if (mqttWanted && !mqttProcess.running) mqttProcess.running = true
    else if (!mqttWanted && mqttProcess.running) mqttProcess.running = false
  }

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

  // secret-tool reads the password from stdin and waits for EOF, so stdin has
  // to be closed after writing or the process hangs forever and onExited never
  // fires. Setting stdinEnabled false is how Quickshell closes the pipe — and
  // that assignment overwrites the declared binding, so every caller has to
  // set it back to true before starting the process again.
  Process {
    id: mqttPasswordProcess
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
      stdinEnabled = false
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
    onDismissed: function(index) { root.dismissAlert(index) }
    onActivated: function(index) {
      var cameraId = alertModel.get(index).cameraId
      root.dismissAlert(index)
      root.view(cameraId)
    }
  }
}
