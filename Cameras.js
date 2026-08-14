// Pure helpers for the avila.cameras plugin.
//
// Deliberately free of QML types and imports so the same file loads in the
// shell and in `node test_cameras.js`. Everything here is a plain function
// over plain data.

var DEFAULT_CONFIG = {
  frigate: { url: "", rtspPort: 8554, user: "" },
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
        ? port : DEFAULT_CONFIG.frigate.rtspPort,
      // Only the username. The password lives in the keyring; a login is
      // attempted whenever this is set and Frigate answers 401.
      user: String(frigate.user || "")
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
