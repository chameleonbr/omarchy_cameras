// Pure helpers for the avila.cameras plugin.
//
// Deliberately free of QML types and imports so the same file loads in the
// shell and in `node test_cameras.js`. Everything here is a plain function
// over plain data.

var DEFAULT_CONFIG = {
  frigate: { url: "", rtspPort: 8554 },
  notifyLabels: ["person"],
  alerts: {
    enabled: false,
    labels: [],          // empty means "fall back to notifyLabels"
    monitor: "",         // empty means "wherever the bar widget last was"
    position: "top-center",
    durationSec: 12,
    width: 320
  },
  onvif: []
}

var ALERT_POSITIONS = ["top-left", "top-center", "top-right"]

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
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

  return {
    frigate: {
      url: trimSlash(frigate.url),
      rtspPort: isFinite(port) && port > 0 && port < 65536
        ? port : DEFAULT_CONFIG.frigate.rtspPort
    },
    notifyLabels: notifyLabels,
    alerts: parseAlerts(parsed.alerts, notifyLabels),
    onvif: Array.isArray(parsed.onvif) ? parsed.onvif.filter(isObject) : []
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
    width: clampInt(alerts.width, DEFAULT_CONFIG.alerts.width, 120, 960)
  }
}

// New Frigate events worth alerting on, newest last.
//
// `after` is both the query Frigate was given and the watermark this returns:
// events are keyed on start_time, so advancing past the newest one seen is
// what stops the same detection alerting twice. A restart that loses the
// watermark must not replay history, so callers persist it.
function newEvents(raw, after, labels) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { parsed = null }
  if (!Array.isArray(parsed)) return { events: [], after: after }

  var wanted = {}
  for (var i = 0; i < labels.length; i++) wanted[String(labels[i]).toLowerCase()] = true

  var out = []
  var watermark = after
  for (var j = 0; j < parsed.length; j++) {
    var event = parsed[j]
    if (!isObject(event)) continue
    var start = Number(event.start_time)
    if (!isFinite(start) || start <= after) continue
    if (start > watermark) watermark = start
    if (!wanted[String(event.label || "").toLowerCase()]) continue
    out.push({
      id: String(event.id || ""),
      camera: String(event.camera || ""),
      label: String(event.label || ""),
      startTime: start
    })
  }
  out.sort(function(a, b) { return a.startTime - b.startTime })
  return { events: out, after: watermark }
}

// Cameras out of Frigate's /api/config. Frigate already renders a JPEG per
// camera, so these need no local ffmpeg — the thumbnail is just a URL.
function frigateCameras(raw, frigate) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return [] }
  if (!isObject(parsed) || !isObject(parsed.cameras)) return []

  var base = trimSlash(frigate.url)
  var host = hostOf(base)
  if (!base || !host) return []

  // Only cameras listed under go2rtc have an RTSP restream. Asking
  // :8554/<name> for one that isn't there yields a dead stream, and most
  // Frigate installs restream a handful of cameras at most.
  var restreamed = isObject(parsed.go2rtc) && isObject(parsed.go2rtc.streams)
    ? parsed.go2rtc.streams : {}

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
      thumbKind: "url",
      thumb: base + "/api/" + encodeURIComponent(name) + "/latest.jpg",
      stream: streamFor(name, base, host, frigate.rtspPort, restreamed),
      ptz: false
    })
  }
  return out.sort(function(a, b) { return a.name < b.name ? -1 : 1 })
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
    return entry.name && entry.rtsp
  }).map(function(entry) {
    return {
      id: "onvif:" + entry.name,
      name: String(entry.name),
      source: "onvif",
      thumbKind: "file",
      thumb: dir + "/" + slug(entry.name) + ".jpg",
      stream: String(entry.rtsp),
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

// Cache-busted thumbnail source. QML's Image cache would otherwise pin the
// first frame forever, since the URL never changes.
function thumbSource(camera, tick) {
  if (!camera) return ""
  if (camera.thumbKind === "file") return "file://" + camera.thumb + "?t=" + tick
  return camera.thumb + "?h=180&t=" + tick
}
