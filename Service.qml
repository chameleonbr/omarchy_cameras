// Camera registry for the avila.cameras plugin.
//
// Loaded once per shell session (kind: "service"), so the bar widget — which
// the shell instantiates once per monitor — can read one shared camera list
// instead of each copy polling Frigate on its own.

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

  // Parsed cameras.json. Also the ONVIF discovery cache — see
  // bin/omarchy-cameras-onvif.
  property var config: Cameras.parseConfig("")
  property var cameras: []
  property bool loading: false
  property string lastError: ""

  readonly property string viewScript: scriptPath("bin/omarchy-cameras-view")

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
    Quickshell.execDetached([viewScript, camera.name, camera.stream])
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

  // Frigate restarts and cameras get added. Five minutes is well below how
  // often that happens and well above how often it is worth asking.
  Timer {
    interval: 300000
    running: root.config.frigate.url !== ""
    repeat: true
    onTriggered: root.fetchFrigateConfig()
  }
}
