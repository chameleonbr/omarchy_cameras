// Pure helpers for the avila.cameras plugin.
//
// Deliberately free of QML types and imports so the same file loads in the
// shell and in `node test_cameras.js`. Everything here is a plain function
// over plain data.

var DEFAULT_CONFIG = {
  frigate: { url: "", rtspPort: 8554 },
  notifyLabels: ["person"],
  onvif: []
}

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

  return {
    frigate: {
      url: trimSlash(frigate.url),
      rtspPort: isFinite(port) && port > 0 && port < 65536
        ? port : DEFAULT_CONFIG.frigate.rtspPort
    },
    notifyLabels: Array.isArray(parsed.notifyLabels)
      ? parsed.notifyLabels.map(String) : DEFAULT_CONFIG.notifyLabels.slice(),
    onvif: Array.isArray(parsed.onvif) ? parsed.onvif.filter(isObject) : []
  }
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
      // ponytail: main stream only. Frigate's substream is conventionally
      // "<name>_sub" but nothing guarantees it exists, and a 404 restream is
      // a worse default than a heavier one.
      stream: "rtsp://" + host + ":" + frigate.rtspPort + "/" + name,
      ptz: false
    })
  }
  return out.sort(function(a, b) { return a.name < b.name ? -1 : 1 })
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
      ptz: entry.ptz === true
    }
  })
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
