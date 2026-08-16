// Pure helpers for the avila.cameras plugin.
//
// Deliberately free of QML types and imports so the same file loads in the
// shell and in `node test_cameras.js`. Everything here is a plain function
// over plain data.

var DEFAULT_CONFIG = {
  // Which camera sources the user has turned on. Everything belonging to a
  // source that is off stays out of the config screen — someone running plain
  // ONVIF cameras has no reason to read about restreams and MQTT.
  sources: { frigate: false, onvif: false },
  frigate: { url: "", rtspPort: 8554, user: "" },
  notifyLabels: ["person"],
  alerts: {
    enabled: false,
    labels: [],          // empty means "fall back to notifyLabels"
    monitor: "",         // empty means "wherever the bar widget last was"
    position: "top-center",
    durationSec: 12,
    width: 320,
    useMqtt: false
  },
  onvif: []
}

var ALERT_POSITIONS = ["top-left", "top-center", "top-right"]

// Every external command the plugin shells out to, and what stops working
// without it. Omarchy ships mpv, jq and libsecret; curl and python3 arrive as
// dependencies of other packages rather than in its own lists, so a lean
// install can genuinely be missing them — and a missing binary makes Process
// fail to start, which is silent apart from a shell warning.
var REQUIRED_TOOLS = [
  { name: "curl", need: "reading anything from Frigate" },
  { name: "mpv", need: "opening a camera, and ONVIF thumbnails" },
  { name: "jq", need: "logging in to an authenticated Frigate" },
  { name: "secret-tool", need: "storing passwords" },
  { name: "python3", need: "MQTT alerts and ONVIF discovery" }
]

// One shell command that prints the name of each tool that is not on PATH.
// Cheaper and more honest than testing paths from QML, which does not know
// what PATH the shell was started with.
function toolCheckCommand() {
  var names = REQUIRED_TOOLS.map(function(t) { return t.name })
  // The names are a constant in this file, but they go in as positional
  // arguments rather than interpolated into the script: a tool name is the
  // kind of thing someone adds without thinking about quoting.
  return ["bash", "-c",
    'for c in "$@"; do command -v "$c" >/dev/null 2>&1 || echo "$c"; done',
    "tool-check"].concat(names)
}

function parseMissingTools(raw) {
  var known = {}
  for (var i = 0; i < REQUIRED_TOOLS.length; i++) known[REQUIRED_TOOLS[i].name] = true
  var out = []
  var lines = String(raw || "").split("\n")
  for (var j = 0; j < lines.length; j++) {
    var name = lines[j].trim()
    // Only report names we asked about: a shell that prints a warning of its
    // own must not turn into a fake missing dependency.
    if (known[name] && out.indexOf(name) === -1) out.push(name)
  }
  return out
}

// "curl (reading anything from Frigate)" — the tool alone is not actionable
// enough to tell someone why they should care.
function describeMissingTools(missing) {
  if (!missing || missing.length === 0) return ""
  var byName = {}
  for (var i = 0; i < REQUIRED_TOOLS.length; i++) {
    byName[REQUIRED_TOOLS[i].name] = REQUIRED_TOOLS[i].need
  }
  var parts = missing.map(function(name) {
    return byName[name] ? name + " (" + byName[name] + ")" : name
  })
  return (missing.length === 1 ? "Missing command: " : "Missing commands: ")
    + parts.join(", ")
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// An http(s) URL, or nothing.
//
// This value is concatenated into a curl argument, and curl reads a leading
// dash as an option: "-o..." writes a file, "-K..." reads a config file from
// disk. A bare host is what people actually type and curl already assumed http
// for it, so that is filled in rather than rejected; anything that is not
// recognisably a host or an http(s) URL is dropped instead of handed over.
function safeHttpUrl(url) {
  var trimmed = trimSlash(url)
  if (!trimmed || /\s/.test(trimmed)) return ""
  if (/^https?:\/\//i.test(trimmed)) return trimmed
  // Host must start with a letter or digit, which is what rules out "-o/tmp/x".
  if (/^[A-Za-z0-9][A-Za-z0-9.\-_]*(:\d+)?(\/.*)?$/.test(trimmed)) {
    return "http://" + trimmed
  }
  return ""
}

// A stream address the viewer can be handed. Same reasoning one level down:
// the URI comes from whatever answered the ONVIF probe, and it ends up as a
// playlist entry for mpv, which will open any scheme it is given.
function safeStreamUrl(url) {
  var trimmed = String(url || "").trim()
  return /^(rtsps?|https?):\/\/[^\s]+$/i.test(trimmed) ? trimmed : ""
}

// Strip a trailing slash so "http://nvr:5000/" + "/api/config" stays sane.
function trimSlash(url) {
  return String(url || "").replace(/\/+$/, "")
}

// Host portion of an http(s) URL, without port. Used to point the RTSP
// restream at the same box that serves the Frigate API.
function hostOf(url) {
  var match = /^[a-z]+:\/\/(?:[^@/]*@)?([^:/?#]+)/i.exec(String(url || ""))
  return match ? match[1] : ""
}

// Read ~/.config/omarchy/cameras.json. A missing or broken file is not an
// error worth blocking on — the plugin just has nothing to show yet.
function parseConfig(raw) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { parsed = null }
  if (!isObject(parsed)) parsed = {}

  var frigate = isObject(parsed.frigate) ? parsed.frigate : {}
  var port = parseInt(frigate.rtspPort, 10)
  var notifyLabels = Array.isArray(parsed.notifyLabels)
    ? parsed.notifyLabels.map(String) : DEFAULT_CONFIG.notifyLabels.slice()
  var onvif = Array.isArray(parsed.onvif) ? parsed.onvif.filter(isObject) : []

  return {
    sources: parseSources(parsed.sources, frigate, onvif),
    frigate: {
      url: safeHttpUrl(frigate.url),
      rtspPort: isFinite(port) && port > 0 && port < 65536
        ? port : DEFAULT_CONFIG.frigate.rtspPort,
      // Only the username. The password lives in the keyring; a login is
      // attempted whenever this is set and Frigate answers 401.
      user: String(frigate.user || "")
    },
    notifyLabels: notifyLabels,
    alerts: parseAlerts(parsed.alerts, notifyLabels),
    onvif: onvif
  }
}

// A config written before sources existed has no `sources` block, and turning
// both off would silently hide a working setup. Fall back to what is actually
// configured: a Frigate URL means Frigate, saved cameras mean ONVIF.
function parseSources(raw, frigate, onvif) {
  var sources = isObject(raw) ? raw : {}
  return {
    frigate: sources.frigate === undefined
      ? !!trimSlash(frigate.url) : sources.frigate === true,
    onvif: sources.onvif === undefined
      ? onvif.length > 0 : sources.onvif === true
  }
}

function clampInt(value, fallback, min, max) {
  var n = parseInt(value, 10)
  if (!isFinite(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

function parseAlerts(raw, notifyLabels) {
  var alerts = isObject(raw) ? raw : {}
  var labels = Array.isArray(alerts.labels) && alerts.labels.length
    ? alerts.labels.map(String) : notifyLabels.slice()
  var position = String(alerts.position || DEFAULT_CONFIG.alerts.position)
  return {
    enabled: alerts.enabled === true,
    labels: labels,
    monitor: String(alerts.monitor || ""),
    position: ALERT_POSITIONS.indexOf(position) === -1
      ? DEFAULT_CONFIG.alerts.position : position,
    // Long enough to see what tripped it, short enough that a busy driveway
    // does not leave a window parked on the desktop.
    durationSec: clampInt(alerts.durationSec, DEFAULT_CONFIG.alerts.durationSec, 2, 300),
    width: clampInt(alerts.width, DEFAULT_CONFIG.alerts.width, 120, 960),
    useMqtt: alerts.useMqtt === true
  }
}

// Frigate's own MQTT settings, straight out of /api/config. Host, port, topic
// prefix, username and the TLS material are all there, so the only thing the
// user ever has to type is the password — and that goes to the keyring, not
// here.
//
// TLS matters more than it looks: MQTT's CONNECT packet carries the username
// and password as plain length-prefixed strings, so on a bare TCP socket
// anyone on the path reads them off the wire. Frigate already knows whether
// its broker speaks TLS, so that answer is read back rather than asked for a
// second time — any of the tls_* settings means yes, and so does port 8883,
// which IANA registers for exactly this.
function frigateMqtt(raw) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { parsed = null }
  var mqtt = isObject(parsed) && isObject(parsed.mqtt) ? parsed.mqtt : {}
  var port = parseInt(mqtt.port, 10)
  var ca = String(mqtt.tls_ca_certs || "")
  var cert = String(mqtt.tls_client_cert || "")
  var key = String(mqtt.tls_client_key || "")
  var insecure = mqtt.tls_insecure === true
  port = isFinite(port) && port > 0 && port < 65536 ? port : 1883
  return {
    enabled: mqtt.enabled === true,
    host: String(mqtt.host || ""),
    port: port,
    prefix: String(mqtt.topic_prefix || "frigate"),
    user: String(mqtt.user || ""),
    tls: !!(ca || cert || key || insecure || port === 8883),
    tlsCa: ca,
    tlsCert: cert,
    tlsKey: key,
    tlsInsecure: insecure
  }
}

// Arguments for bin/omarchy-cameras-mqtt. The password is not among them: the
// script reads it from the keyring itself.
function mqttCommand(script, mqtt) {
  var command = [script, mqtt.host, String(mqtt.port), mqtt.prefix]
  if (mqtt.user) command.push("--user", mqtt.user)
  if (!mqtt.tls) return command
  command.push("--tls")
  if (mqtt.tlsCa) command.push("--tls-ca", mqtt.tlsCa)
  if (mqtt.tlsCert) command.push("--tls-cert", mqtt.tlsCert)
  if (mqtt.tlsKey) command.push("--tls-key", mqtt.tlsKey)
  if (mqtt.tlsInsecure) command.push("--tls-insecure")
  return command
}

// What to tell the user about credentials crossing the network in the clear.
// Both cases are the server's configuration, not something the plugin can fix
// on its own, so this is a warning rather than a refusal — a Frigate on plain
// HTTP over a home LAN is an ordinary setup, and saying so is more use than
// blocking it.
function insecureWarnings(config, mqtt) {
  var warnings = []
  var frigate = isObject(config) && isObject(config.frigate) ? config.frigate : {}
  var url = String(frigate.url || "")
  var plainHttp = url.indexOf("http://") === 0

  if (plainHttp && !!frigate.user) {
    warnings.push("Frigate is on plain HTTP: the login, the session cookie and "
      + "the camera images all cross the network readable. Use https:// if the "
      + "server offers it.")
  }
  // A broker with no username asks for no password, so there is nothing to
  // capture; the alert payloads themselves are already coming over the same
  // network from Frigate.
  if (isObject(mqtt) && mqtt.host && mqtt.user && !mqtt.tls) {
    warnings.push("The MQTT broker is not using TLS: MQTT sends the password in "
      + "the connect packet, readable to anyone on the path. Alerts keep working "
      + "over HTTP polling if you would rather leave MQTT off.")
  }
  return warnings
}

// New Frigate events worth alerting on, oldest first.
//
// Deduplication is by event id, not by timestamp. Frigate reports a detection
// twice — once while it is still running (`in_progress=1`, no end_time) and
// again once it has ended — and both carry the same id and start_time. A
// timestamp watermark alone would either alert twice or, worse, let a
// still-running event advance the mark past a shorter one that started earlier
// on another camera and swallow it.
//
// `seen` is a map of id -> start_time that the caller owns and updates.
// `newest` comes back so the caller can keep querying a bounded window.
function newEvents(raw, labels, seen) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { parsed = null }
  if (!Array.isArray(parsed)) return { events: [], newest: 0 }

  var wanted = {}
  for (var i = 0; i < labels.length; i++) wanted[String(labels[i]).toLowerCase()] = true

  var out = []
  var newest = 0
  for (var j = 0; j < parsed.length; j++) {
    var event = parsed[j]
    if (!isObject(event)) continue
    var id = String(event.id || "")
    var start = Number(event.start_time)
    // Without a start time there is nothing to age out of `seen` by, and
    // without an id there is no way to tell two detections apart.
    if (!id || !isFinite(start)) continue
    if (start > newest) newest = start
    if (seen[id] !== undefined) continue
    if (!wanted[String(event.label || "").toLowerCase()]) continue
    out.push({
      id: id,
      camera: String(event.camera || ""),
      label: String(event.label || ""),
      hasSnapshot: event.has_snapshot === true,
      // Present only once the detection is over. The alert does not wait for
      // it: an event is worth showing while it is still happening.
      inProgress: event.end_time === null || event.end_time === undefined,
      startTime: start
    })
  }
  out.sort(function(a, b) { return a.startTime - b.startTime })
  return { events: out, newest: newest }
}

// Every id in a payload, so the caller can mark even non-matching events as
// seen and not re-examine them on the next poll.
function eventIds(raw) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return [] }
  if (!Array.isArray(parsed)) return []
  var out = []
  for (var i = 0; i < parsed.length; i++) {
    var event = parsed[i]
    if (!isObject(event)) continue
    var id = String(event.id || "")
    var start = Number(event.start_time)
    if (id && isFinite(start)) out.push({ id: id, startTime: start })
  }
  return out
}

// Drop ids that can no longer come back in the query window, so the seen map
// does not grow for the life of the session.
function pruneSeen(seen, before) {
  var out = {}
  for (var id in seen) {
    if (seen[id] >= before) out[id] = seen[id]
  }
  return out
}

// Cameras out of Frigate's /api/config. Frigate already renders a JPEG per
// camera, so these need no local ffmpeg — the thumbnail is just a URL.
function frigateCameras(raw, frigate, runtimeDir) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return [] }
  if (!isObject(parsed) || !isObject(parsed.cameras)) return []

  // QML's Image fetches URLs itself and cannot be given Frigate's JWT cookie,
  // so on an authenticated instance the thumbnails have to arrive as files
  // that omarchy-cameras-frigate mirrors into the runtime dir.
  var authed = !!frigate.user
  var dir = trimSlash(runtimeDir || "")

  var base = trimSlash(frigate.url)
  var host = hostOf(base)
  if (!base || !host) return []

  // Only cameras listed under go2rtc have an RTSP restream. Asking
  // :8554/<name> for one that isn't there yields a dead stream, and most
  // Frigate installs restream a handful of cameras at most.
  var restreamed = isObject(parsed.go2rtc) && isObject(parsed.go2rtc.streams)
    ? parsed.go2rtc.streams : {}
  var port = restreamPort(parsed, frigate.rtspPort)

  var out = []
  for (var name in parsed.cameras) {
    var camera = parsed.cameras[name]
    // A disabled camera has no live stream behind it; showing a permanently
    // broken tile is worse than showing nothing.
    if (isObject(camera) && camera.enabled === false) continue
    out.push({
      id: "frigate:" + name,
      name: name,
      source: "frigate",
      thumbKind: authed ? "file" : "url",
      thumb: authed
        ? dir + "/" + slug(name) + ".jpg"
        : base + "/api/" + encodeURIComponent(name) + "/latest.jpg",
      stream: streamFor(name, base, host, port, restreamed),
      ptz: false
    })
  }
  return out.sort(function(a, b) { return a.name < b.name ? -1 : 1 })
}

// The port go2rtc listens on for RTSP.
//
// Frigate does not report it directly — /api/config's go2rtc block only lists
// streams — but a restreamed camera feeds itself from the restream, so its own
// ffmpeg input is a loopback RTSP URL carrying the port. Reading it back out
// of there beats asking the user for a number they would have to go and look
// up in the same file.
function restreamPort(parsed, fallback) {
  var cameras = isObject(parsed) && isObject(parsed.cameras) ? parsed.cameras : {}
  for (var name in cameras) {
    var camera = cameras[name]
    var ffmpeg = isObject(camera) ? camera.ffmpeg : null
    var inputs = isObject(ffmpeg) && Array.isArray(ffmpeg.inputs) ? ffmpeg.inputs : []
    for (var i = 0; i < inputs.length; i++) {
      var path = isObject(inputs[i]) ? String(inputs[i].path || "") : ""
      var match = /^rtsp:\/\/(?:127\.0\.0\.1|localhost|\[::1\]):(\d+)\//.exec(path)
      if (match) {
        var port = parseInt(match[1], 10)
        if (isFinite(port) && port > 0 && port < 65536) return port
      }
    }
  }
  return fallback
}

// Best playable address for a Frigate camera.
//
// The restream is the good one: H.264/H.265 straight through, and Frigate
// holds the only connection to the camera. Without it, /api/<name> is
// Frigate's MJPEG of the detect feed — heavier on the wire and softer, but it
// exists for every camera, needs no configuration, and beats a tile that
// cannot be opened at all.
//
// ponytail: main stream only. Frigate's substream is conventionally
// "<name>_sub", but nothing guarantees it, and a dead substream is a worse
// default than a heavy main one.
function streamFor(name, base, host, rtspPort, restreamed) {
  if (Object.prototype.hasOwnProperty.call(restreamed, name)) {
    return "rtsp://" + host + ":" + rtspPort + "/" + encodeURIComponent(name)
  }
  return base + "/api/" + encodeURIComponent(name)
}

// Cameras discovered by bin/omarchy-cameras-onvif and cached in the config.
// These have no snapshot endpoint, so the thumbnail is a file that
// bin/omarchy-cameras-thumbd keeps fresh while the camera is on screen.
function onvifCameras(config, runtimeDir) {
  var dir = trimSlash(runtimeDir)
  return config.onvif.filter(function(entry) {
    // A hand-edited config, or an older one written before the probe checked
    // the scheme, must not put a file:// URL in front of the player.
    return entry.name && safeStreamUrl(entry.rtsp)
  }).map(function(entry) {
    return {
      id: "onvif:" + entry.name,
      name: String(entry.name),
      source: "onvif",
      thumbKind: "file",
      thumb: dir + "/" + slug(entry.name) + ".jpg",
      stream: safeStreamUrl(entry.rtsp),
      xaddr: String(entry.xaddr || ""),
      host: String(entry.host || ""),
      // The password lives in the keyring; the user is what lets
      // omarchy-cameras-view look it up.
      user: String(entry.user || ""),
      ptz: entry.ptz === true
    }
  })
}

// Add or replace an ONVIF camera, keyed on the device address. Re-probing a
// camera should update it, not add a second copy of it.
function upsertOnvif(config, entry) {
  var next = config.onvif.filter(function(existing) {
    return existing.xaddr !== entry.xaddr && existing.name !== entry.name
  })
  next.push(entry)
  return next
}

// Filename-safe form of a camera name, for thumbnail paths.
function slug(name) {
  return String(name).replace(/[^A-Za-z0-9._-]+/g, "_")
}

// One list out of both sources. A camera fronted by Frigate wins over the
// same camera reached directly: Frigate gives us free thumbnails and a
// restream that survives the camera's own connection limit.
function mergeCameras(frigate, onvif) {
  var taken = {}
  var out = []
  var i
  for (i = 0; i < frigate.length; i++) {
    taken[frigate[i].name.toLowerCase()] = true
    out.push(frigate[i])
  }
  for (i = 0; i < onvif.length; i++) {
    if (taken[onvif[i].name.toLowerCase()]) continue
    out.push(onvif[i])
  }
  return out
}

// "<name>=<rtsp>=<user>" triples for `omarchy-cameras-thumbd`, one per ONVIF
// camera. No password: the helper reads that from the keyring, keyed on the
// camera's own host, so two cameras with different logins each get their own.
function onvifThumbSpecs(cameras) {
  return cameras.filter(function(camera) {
    return camera.source === "onvif" && camera.stream
  }).map(function(camera) {
    return slug(camera.name) + "=" + camera.stream + "=" + (camera.user || "")
  })
}

// "<name>=<path>" pairs for `omarchy-cameras-frigate mirror`, one per Frigate
// camera whose thumbnail has to come through the authenticated fetcher.
function mirrorSpecs(cameras) {
  return cameras.filter(function(camera) {
    return camera.source === "frigate" && camera.thumbKind === "file"
  }).map(function(camera) {
    return slug(camera.name) + "=/api/" + encodeURIComponent(camera.name) + "/latest.jpg"
  })
}

// The still Frigate kept for one event.
//
// This is deliberately not a live frame: by the time an alert is on screen the
// thing that tripped it has often already left, and a live feed shows an empty
// driveway. `bbox=1` draws Frigate's own box, label and score, so the picture
// says what was detected and where.
//
// The snapshot is the full frame and only exists when the camera has snapshots
// enabled; the thumbnail always exists and is what Frigate itself falls back
// to. Both URLs are stable, so unlike the polled thumbnails these want the
// Image cache left on.
function eventImagePath(event) {
  if (!event || !event.id) return ""
  var path = "/api/events/" + encodeURIComponent(event.id)
  return event.hasSnapshot ? path + "/snapshot.jpg?bbox=1" : path + "/thumbnail.jpg"
}

function eventImageUrl(frigateUrl, event) {
  var base = trimSlash(frigateUrl)
  var path = eventImagePath(event)
  return base && path ? base + path : ""
}

// Cache-busted thumbnail source. QML's Image cache would otherwise pin the
// first frame forever, since the URL never changes.
function thumbSource(camera, tick) {
  if (!camera) return ""
  if (camera.thumbKind === "file") return "file://" + camera.thumb + "?t=" + tick
  return camera.thumb + "?h=180&t=" + tick
}
