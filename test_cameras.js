// Self-check for Cameras.js. Run: node test_cameras.js
//
// Cameras.js is a QML .js resource, so it has no exports. Eval it into this
// module's scope: its `function` declarations land as locals, and staying in
// one realm keeps deepEqual comparing arrays rather than prototypes.

const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

eval(fs.readFileSync(path.join(__dirname, "Cameras.js"), "utf8"))

// --- parseConfig tolerates everything a hand-edited file can be -------------

const empty = parseConfig("")
assert.equal(empty.frigate.url, "")
assert.equal(empty.frigate.rtspPort, 8554)
assert.deepEqual(empty.onvif, [])

assert.deepEqual(parseConfig("{not json").onvif, [], "broken JSON must not throw")
assert.deepEqual(parseConfig("[1,2,3]").notifyLabels, ["person"], "wrong root type falls back")
assert.equal(parseConfig('{"frigate":{"url":"http://nvr:5000/"}}').frigate.url,
  "http://nvr:5000", "trailing slash stripped")
assert.equal(parseConfig('{"frigate":{"rtspPort":"1935"}}').frigate.rtspPort, 1935,
  "numeric string port accepted")
assert.equal(parseConfig('{"frigate":{"rtspPort":0}}').frigate.rtspPort, 8554,
  "out-of-range port falls back")

// --- alert settings --------------------------------------------------------

assert.equal(empty.alerts.enabled, false, "alerts must be opt-in")
assert.deepEqual(empty.alerts.labels, ["person"], "labels default to notifyLabels")
assert.equal(parseConfig('{"notifyLabels":["cat","dog"]}').alerts.labels.length, 2,
  "an alerts block is not required to pick up notifyLabels")
assert.deepEqual(
  parseConfig('{"notifyLabels":["cat"],"alerts":{"labels":["car"]}}').alerts.labels,
  ["car"], "an explicit alerts.labels wins over notifyLabels")
assert.equal(parseConfig('{"alerts":{"durationSec":9000}}').alerts.durationSec, 300,
  "duration is clamped, not trusted")
assert.equal(parseConfig('{"alerts":{"width":10}}').alerts.width, 120)
assert.equal(parseConfig('{"alerts":{"position":"middle"}}').alerts.position, "top-center",
  "an unknown corner falls back rather than anchoring nowhere")
assert.equal(parseConfig('{"alerts":{"enabled":"yes"}}').alerts.enabled, false,
  "only a real boolean arms the alerts")

// --- newEvents -------------------------------------------------------------

const events = JSON.stringify([
  { id: "c", camera: "garagem", label: "person", start_time: 300, end_time: 305 },
  { id: "b", camera: "quintal", label: "cat", start_time: 200, end_time: 210 },
  { id: "a", camera: "garagem", label: "person", start_time: 100, end_time: 150 }
])

let first = newEvents(events, ["person"], {})
assert.deepEqual(first.events.map(e => e.id), ["a", "c"], "oldest first, cat filtered out")
assert.equal(first.newest, 300, "newest spans every event, not just matching ones")

// Dedup is by id. The same detection is reported twice — once running, once
// ended — with the same id and start_time, so a timestamp alone is not enough.
assert.deepEqual(newEvents(events, ["person"], { a: 100, c: 300 }).events, [])
assert.deepEqual(newEvents(events, ["person"], { a: 100 }).events.map(e => e.id), ["c"])

// An in-progress event has no end_time and must still alert — waiting for one
// means waiting for the subject to leave the frame.
const live = '[{"id":"L","camera":"garagem","label":"person","start_time":400,"end_time":null}]'
assert.equal(newEvents(live, ["person"], {}).events[0].inProgress, true)
assert.equal(newEvents(events, ["person"], {}).events[0].inProgress, false)

// A shorter event that started earlier must not be swallowed by a long-running
// one — the bug a timestamp watermark would have introduced.
const overlapping = JSON.stringify([
  { id: "long", camera: "a", label: "person", start_time: 500, end_time: null },
  { id: "short", camera: "b", label: "person", start_time: 480, end_time: 495 }
])
assert.deepEqual(newEvents(overlapping, ["person"], { long: 500 }).events.map(e => e.id),
  ["short"])

assert.deepEqual(newEvents(events, ["nothing"], {}).events, [])
assert.equal(newEvents(events, ["nothing"], {}).newest, 300,
  "an unwatched label still moves the query window forward")

assert.deepEqual(newEvents("<html>502</html>", ["person"], {}).events, [])
assert.equal(newEvents("<html>502</html>", ["person"], {}).newest, 0,
  "an error page reports no newest, so the caller keeps its own watermark")
assert.deepEqual(newEvents("", ["person"], {}).events, [])
assert.deepEqual(
  newEvents('[{"id":"x","camera":"x","label":"person"}]', ["person"], {}).events, [],
  "no start_time means nothing to age the id out by, so it is skipped")
assert.deepEqual(
  newEvents('[{"camera":"x","label":"person","start_time":1}]', ["person"], {}).events, [],
  "no id means no way to tell two detections apart, so it is skipped")
assert.deepEqual(newEvents(events, ["PERSON"], {}).events.map(e => e.id), ["a", "c"],
  "label matching is case-insensitive")

// --- eventIds / pruneSeen --------------------------------------------------

assert.deepEqual(eventIds(events).map(e => e.id), ["c", "b", "a"],
  "every id, so a non-matching event is not re-examined next poll")
assert.deepEqual(eventIds("nonsense"), [])

assert.deepEqual(pruneSeen({ a: 100, b: 200, c: 300 }, 200), { b: 200, c: 300 },
  "ids too old to come back in the query window are dropped")
assert.deepEqual(pruneSeen({}, 0), {})

// A detection can stay in progress for hours — a parked car, a bicycle left in
// frame — and keeps being reported the whole time. Pruning must run before the
// payload is re-marked, or its id is dropped while still live and it alerts
// again on the very next poll. This is the caller's order, asserted here
// because getting it backwards is silent and very loud on screen.
{
  const parked = { id: "parked", camera: "drive", label: "person", start_time: 100 }
  const payload = JSON.stringify([parked,
    { id: "fresh", camera: "door", label: "person", start_time: 5000 }])

  let seen = pruneSeen({ parked: 100 }, 5000 - 600)
  for (const e of eventIds(payload)) seen[e.id] = e.startTime
  assert.deepEqual(newEvents(payload, ["person"], seen).events, [],
    "a long-running detection stays seen across a prune")

  // The other order loses it.
  let wrong = { parked: 100 }
  for (const e of eventIds(payload)) wrong[e.id] = e.startTime
  wrong = pruneSeen(wrong, 5000 - 600)
  assert.deepEqual(newEvents(payload, ["person"], wrong).events.map(e => e.id), ["parked"],
    "marking before pruning re-alerts a detection that never stopped")
}

// --- eventImageUrl ---------------------------------------------------------
//
// The alert shows this still, not a live frame: fast movement is over before
// anyone looks, and a live feed would show an empty driveway.

const withSnap = { id: "1786720728.064015-pbf5n9", hasSnapshot: true }
const noSnap = { id: "1786720728.064015-pbf5n9", hasSnapshot: false }

assert.equal(eventImageUrl("http://nvr.lan:5000/", withSnap),
  "http://nvr.lan:5000/api/events/1786720728.064015-pbf5n9/snapshot.jpg?bbox=1",
  "bbox=1 is what draws the box, label and score onto the still")
assert.equal(eventImageUrl("http://nvr.lan:5000", noSnap),
  "http://nvr.lan:5000/api/events/1786720728.064015-pbf5n9/thumbnail.jpg",
  "a camera with snapshots off still has a thumbnail")
assert.equal(eventImageUrl("", withSnap), "")
assert.equal(eventImageUrl("http://nvr.lan:5000", null), "")
assert.equal(eventImageUrl("http://nvr.lan:5000", { hasSnapshot: true }), "",
  "no id means no URL to build")

assert.equal(newEvents(events, ["person"], {}).events[0].hasSnapshot, false,
  "has_snapshot absent is not a snapshot")
assert.equal(
  newEvents('[{"id":"z","camera":"c","label":"person","start_time":9,"has_snapshot":true}]',
    ["person"], {}).events[0].hasSnapshot,
  true)

// --- sources ---------------------------------------------------------------
//
// The toggles decide which half of the config screen exists. Getting the
// migration wrong would silently hide a working setup, so the fallback for a
// config written before `sources` existed is what is actually configured.

assert.deepEqual(parseConfig("").sources, { frigate: false, onvif: false },
  "a fresh install starts with neither, and picks in the form")
assert.deepEqual(parseConfig('{"frigate":{"url":"http://nvr:5000"}}').sources,
  { frigate: true, onvif: false }, "an existing Frigate URL means Frigate was in use")
assert.deepEqual(
  parseConfig('{"onvif":[{"name":"a","rtsp":"rtsp://x/1"}]}').sources,
  { frigate: false, onvif: true }, "saved ONVIF cameras mean ONVIF was in use")

// An explicit block always wins, including switching a configured source off.
assert.deepEqual(
  parseConfig('{"sources":{"frigate":false,"onvif":true},"frigate":{"url":"http://nvr:5000"}}').sources,
  { frigate: false, onvif: true })
assert.deepEqual(parseConfig('{"sources":{"frigate":"yes"}}').sources.frigate, false,
  "only a real boolean counts")
assert.deepEqual(parseConfig('{"sources":{}, "frigate":{"url":"http://nvr:5000"}}').sources,
  { frigate: true, onvif: false }, "an empty block still migrates each key")

// --- dependency check ------------------------------------------------------
//
// A missing binary makes Process fail to start, which is invisible apart from
// a shell warning, so the config screen has to say it out loud.

assert.deepEqual(parseMissingTools(""), [], "nothing missing is the normal case")
assert.deepEqual(parseMissingTools("curl\npython3\n"), ["curl", "python3"])
assert.deepEqual(parseMissingTools("  mpv  \n\n"), ["mpv"], "whitespace tolerated")
assert.deepEqual(parseMissingTools("curl\ncurl\n"), ["curl"], "no duplicates")
assert.deepEqual(parseMissingTools("bash: line 1: warning\n"), [],
  "a shell's own chatter must not become a fake missing dependency")

assert.equal(describeMissingTools([]), "")
assert.match(describeMissingTools(["mpv"]), /^Missing command: mpv \(.+\)$/)
assert.match(describeMissingTools(["curl", "jq"]), /^Missing commands: curl \(.+\), jq \(.+\)$/)
assert.equal(describeMissingTools(["nonsense"]), "Missing command: nonsense",
  "an unknown name still gets reported rather than swallowed")

// The command must actually ask about every tool the plugin uses, or the
// check silently stops covering one.
{
  const cmd = toolCheckCommand()
  assert.equal(cmd[0], "bash")
  // The names are positional arguments, not interpolated into the script, so
  // the script itself is a constant and the tools are everything after $0.
  assert.ok(!/curl|mpv|python3/.test(cmd[2]), "no tool name is spliced into the script")
  const asked = cmd.slice(4)
  for (const t of REQUIRED_TOOLS) assert.ok(asked.includes(t.name), t.name)
}

// --- hostOf ----------------------------------------------------------------

assert.equal(hostOf("http://nvr.lan:5000"), "nvr.lan")
assert.equal(hostOf("https://user:pw@10.0.0.5/api"), "10.0.0.5", "userinfo is not the host")
assert.equal(hostOf("garbage"), "")

// --- frigateCameras --------------------------------------------------------

const frigateConfig = { url: "http://nvr.lan:5000", rtspPort: 8554 }
const apiConfig = JSON.stringify({
  cameras: {
    quintal: { enabled: true },
    garagem: {},
    desligada: { enabled: false }
  },
  go2rtc: { streams: { garagem: ["rtsp://cam/1"] } }
})

const fromFrigate = frigateCameras(apiConfig, frigateConfig, "/run/user/1000/omarchy-cameras")
assert.deepEqual(fromFrigate.map(c => c.name), ["garagem", "quintal"], "sorted, disabled dropped")
assert.equal(fromFrigate[0].thumb, "http://nvr.lan:5000/api/garagem/latest.jpg")
assert.equal(fromFrigate[0].source, "frigate")

// Restreamed cameras get the RTSP restream; the rest fall back to Frigate's
// MJPEG, because :8554/<name> for a camera go2rtc never heard of is a dead
// stream and there is no way to tell from the tile.
assert.equal(fromFrigate[0].stream, "rtsp://nvr.lan:8554/garagem")

// --- restreamPort ----------------------------------------------------------
//
// /api/config never states the go2rtc RTSP port, but a restreamed camera pulls
// from the restream, so its own ffmpeg input carries it. Reading it back from
// there is what keeps the port off the settings form.

const withLoopback = {
  cameras: {
    a: { ffmpeg: { inputs: [{ path: "rtsp://user:pw@192.168.1.5:554/live" }] } },
    b: { ffmpeg: { inputs: [{ path: "rtsp://127.0.0.1:8555/b?video" }] } }
  }
}
assert.equal(restreamPort(withLoopback, 8554), 8555, "the loopback input names the port")
assert.equal(
  restreamPort({ cameras: { b: { ffmpeg: { inputs: [{ path: "rtsp://localhost:1935/b" }] } } } }, 8554),
  1935, "localhost counts too")
assert.equal(
  restreamPort({ cameras: { a: { ffmpeg: { inputs: [{ path: "rtsp://10.0.0.5:554/x" }] } } } }, 8554),
  8554, "a real camera address is not the restream")
assert.equal(restreamPort({}, 8554), 8554)
assert.equal(restreamPort(null, 8554), 8554)
assert.equal(
  restreamPort({ cameras: { a: { ffmpeg: { inputs: [{ path: "rtsp://127.0.0.1:99999/x" }] } } } }, 8554),
  8554, "an impossible port is ignored rather than trusted")

// End to end: a config whose restream lives on a non-default port produces
// stream URLs on that port.
const oddPort = JSON.stringify({
  cameras: { quintal: { ffmpeg: { inputs: [{ path: "rtsp://127.0.0.1:8555/quintal" }] } } },
  go2rtc: { streams: { quintal: ["rtsp://cam/1"] } }
})
assert.equal(frigateCameras(oddPort, frigateConfig, "/run")[0].stream,
  "rtsp://nvr.lan:8555/quintal")
assert.equal(fromFrigate[1].stream, "http://nvr.lan:5000/api/quintal")

// A config with no go2rtc section at all must not send every camera to a
// restream that does not exist.
const noRestream = JSON.stringify({ cameras: { quintal: {} } })
assert.equal(frigateCameras(noRestream, frigateConfig)[0].stream,
  "http://nvr.lan:5000/api/quintal")

// Camera names are user-chosen and reach the URL verbatim.
const oddName = JSON.stringify({ cameras: { "back yard": {} } })
assert.equal(frigateCameras(oddName, frigateConfig, "/run")[0].stream,
  "http://nvr.lan:5000/api/back%20yard")

// --- authenticated Frigate -------------------------------------------------
//
// QML's Image fetches URLs itself and cannot carry Frigate's JWT cookie, so
// with a login configured the thumbnails must come off disk instead.

const authed = { url: "http://nvr.lan:5000", rtspPort: 8554, user: "admin" }
const authedCams = frigateCameras(apiConfig, authed, "/run/user/1000/omarchy-cameras")
assert.equal(authedCams[0].thumbKind, "file")
assert.equal(authedCams[0].thumb, "/run/user/1000/omarchy-cameras/garagem.jpg")
assert.equal(authedCams[0].stream, "rtsp://nvr.lan:8554/garagem",
  "auth changes where the picture comes from, not the stream")
assert.equal(fromFrigate[0].thumbKind, "url", "no login means no mirror process")

assert.deepEqual(mirrorSpecs(authedCams),
  ["garagem=/api/garagem/latest.jpg", "quintal=/api/quintal/latest.jpg"])
assert.deepEqual(mirrorSpecs(fromFrigate), [], "nothing to mirror without auth")

// --- onvifThumbSpecs -------------------------------------------------------
//
// ONVIF has no dependable snapshot endpoint — both cameras tested advertise
// GetSnapshotUri and then answer HTTP 500 — so a frame comes out of the RTSP
// stream instead.

{
  const cams = onvifCameras(parseConfig(JSON.stringify({
    onvif: [
      { name: "Front Door", rtsp: "rtsp://10.0.0.9/s0", user: "admin" },
      { name: "shed", rtsp: "rtsp://10.0.0.8/s0" }
    ]
  })), "/run")
  assert.deepEqual(onvifThumbSpecs(cams), [
    "Front_Door=rtsp://10.0.0.9/s0=admin",
    "shed=rtsp://10.0.0.8/s0="
  ], "the file name is slugged; a camera with no login still gets a thumbnail")

  // No password in there: the helper reads it from the keyring per host, which
  // is what lets two cameras have different logins.
  for (const spec of onvifThumbSpecs(cams)) {
    assert.equal(spec.split("=").length, 3, spec)
  }
  assert.deepEqual(onvifThumbSpecs(fromFrigate), [],
    "Frigate cameras already have latest.jpg")
}
assert.deepEqual(
  mirrorSpecs(frigateCameras(JSON.stringify({ cameras: { "back yard": {} } }), authed, "/run")),
  ["back_yard=/api/back%20yard/latest.jpg"],
  "the file name is slugged but the URL keeps the real name")

assert.equal(parseConfig('{"frigate":{"user":"admin"}}').frigate.user, "admin")
assert.equal(empty.frigate.user, "", "no login configured by default")
assert.equal(JSON.stringify(parseConfig('{"frigate":{"user":"a","password":"p"}}').frigate)
  .indexOf("password"), -1, "a password must never survive into the config object")

assert.deepEqual(frigateCameras("", frigateConfig), [], "empty body yields no cameras")
assert.deepEqual(frigateCameras("<html>502</html>", frigateConfig), [], "HTML error page yields no cameras")
assert.deepEqual(frigateCameras(apiConfig, { url: "", rtspPort: 8554 }), [],
  "no configured URL yields no cameras")

// --- onvifCameras ----------------------------------------------------------

const config = parseConfig(JSON.stringify({
  onvif: [
    { name: "Portão Lateral", rtsp: "rtsp://10.0.0.9/s0", ptz: true, xaddr: "http://10.0.0.9/onvif" },
    { name: "sem-stream" }
  ]
}))
const fromOnvif = onvifCameras(config, "/run/user/1000/omarchy-cameras")
assert.equal(fromOnvif.length, 1, "an entry without an RTSP URL is not a camera")
assert.equal(fromOnvif[0].thumb, "/run/user/1000/omarchy-cameras/Port_o_Lateral.jpg")
assert.equal(fromOnvif[0].ptz, true)
assert.equal(slug("a/b c"), "a_b_c")

// --- mergeCameras ----------------------------------------------------------

const dup = onvifCameras(parseConfig(JSON.stringify({
  onvif: [{ name: "Garagem", rtsp: "rtsp://10.0.0.8/s0" }]
})), "/tmp")
const merged = mergeCameras(fromFrigate, dup.concat(fromOnvif))
assert.deepEqual(merged.map(c => c.name), ["garagem", "quintal", "Portão Lateral"],
  "Frigate wins the name clash, case-insensitively")

// --- thumbSource -----------------------------------------------------------

assert.equal(thumbSource(fromFrigate[0], 7),
  "http://nvr.lan:5000/api/garagem/latest.jpg?h=180&t=7")
assert.equal(thumbSource(fromOnvif[0], 7),
  "file:///run/user/1000/omarchy-cameras/Port_o_Lateral.jpg?t=7")
assert.notEqual(thumbSource(fromFrigate[0], 7), thumbSource(fromFrigate[0], 8),
  "the tick must change the URL or Image caches the first frame forever")
assert.equal(thumbSource(null, 1), "")

console.log("ok")

// --- MQTT transport: the CONNECT packet carries the password in the clear ---
//
// So the only question that matters is whether the socket is wrapped. Frigate
// already knows the answer, and every route to "yes" has to be honoured, or
// the plugin silently downgrades a broker the user configured for TLS.

{
  const plain = frigateMqtt('{"mqtt":{"enabled":true,"host":"h","port":1883,"user":"u"}}')
  assert.equal(plain.tls, false, "a plain 1883 broker is what it looks like")

  assert.equal(frigateMqtt('{"mqtt":{"port":8883}}').tls, true,
    "8883 is the registered secure-mqtt port")
  assert.equal(frigateMqtt('{"mqtt":{"port":1883,"tls_ca_certs":"/ca.pem"}}').tls, true,
    "a CA bundle means the broker speaks TLS on whatever port it likes")
  assert.equal(frigateMqtt('{"mqtt":{"tls_client_cert":"/c.pem"}}').tls, true)
  assert.equal(frigateMqtt('{"mqtt":{"tls_client_key":"/k.pem"}}').tls, true)
  assert.equal(frigateMqtt('{"mqtt":{"tls_insecure":true}}').tls, true,
    "insecure still means TLS — it only relaxes verification")
  assert.equal(frigateMqtt('{"mqtt":{"tls_insecure":false}}').tls, false,
    "an explicit false must not read as 'set'")

  const full = frigateMqtt('{"mqtt":{"host":"b","port":8883,"user":"u",'
    + '"tls_ca_certs":"/ca.pem","tls_client_cert":"/c.pem",'
    + '"tls_client_key":"/k.pem","tls_insecure":true}}')
  assert.deepEqual(mqttCommand("/s", full),
    ["/s", "b", "8883", "frigate", "--user", "u", "--tls",
     "--tls-ca", "/ca.pem", "--tls-cert", "/c.pem", "--tls-key", "/k.pem",
     "--tls-insecure"])

  assert.deepEqual(mqttCommand("/s", plain), ["/s", "h", "1883", "frigate", "--user", "u"],
    "no TLS flag when the broker has none, and never a password in argv")
  assert.ok(!mqttCommand("/s", full).join(" ").includes("password"))

  const anon = frigateMqtt('{"mqtt":{"host":"h"}}')
  assert.deepEqual(mqttCommand("/s", anon), ["/s", "h", "1883", "frigate"],
    "no --user for a broker that wants none")
}

// --- warnings about credentials crossing the network readable ---------------
//
// Both cases are the server's configuration, so the plugin warns rather than
// refuses. The point of the test is that it warns exactly when it should:
// noise here trains people to ignore the line.

{
  const cfg = (url, user) => ({ frigate: { url: url, user: user } })
  const tlsOff = { host: "b", user: "u", tls: false }
  const tlsOn = { host: "b", user: "u", tls: true }
  const anon = { host: "b", user: "", tls: false }

  assert.equal(insecureWarnings(cfg("http://nvr:5000", "admin"), tlsOn).length, 1,
    "an HTTP login is worth saying out loud")
  assert.equal(insecureWarnings(cfg("https://nvr", "admin"), tlsOn).length, 0,
    "HTTPS with a TLS broker is the quiet case")
  assert.equal(insecureWarnings(cfg("http://nvr:5000", ""), tlsOn).length, 0,
    "no login means no credential to capture")

  assert.equal(insecureWarnings(cfg("https://nvr", "admin"), tlsOff).length, 1,
    "a plaintext broker with a username is the MQTT half")
  assert.equal(insecureWarnings(cfg("https://nvr", "admin"), anon).length, 0,
    "a broker that wants no username sends no password")
  assert.equal(insecureWarnings(cfg("http://nvr", "admin"), tlsOff).length, 2,
    "both halves are reported separately")

  assert.deepEqual(insecureWarnings(null, null), [], "junk in must not throw")
  assert.equal(insecureWarnings(cfg("", ""), { host: "", user: "u", tls: false }).length, 0,
    "nothing configured yet is not a warning")
}

// --- URLs reach a command line, so they have to be URLs ---------------------
//
// The Frigate URL is concatenated into a curl argument and curl reads a
// leading dash as an option; the stream URL becomes a playlist entry and mpv
// opens any scheme it is handed. Neither is a privilege boundary on a
// single-user desktop — the point is that a value that is not a URL never
// reaches a program that would do something else with it.

{
  assert.equal(safeHttpUrl("http://nvr:5000/"), "http://nvr:5000")
  assert.equal(safeHttpUrl("https://nvr.lan"), "https://nvr.lan")

  // A bare host is what people type, and curl already assumed http for it.
  assert.equal(safeHttpUrl("nvr.lan:5000"), "http://nvr.lan:5000",
    "an existing config without a scheme must keep working")
  assert.equal(safeHttpUrl("192.168.31.5:5000/x"), "http://192.168.31.5:5000/x")

  assert.equal(safeHttpUrl("-o/home/me/.bashrc"), "",
    "curl would read this as an option, not an address")
  assert.equal(safeHttpUrl("-K/tmp/curlrc"), "")
  assert.equal(safeHttpUrl("file:///etc/passwd"), "")
  assert.equal(safeHttpUrl("http://nvr /x"), "", "no whitespace to split on")
  assert.equal(safeHttpUrl(""), "")
  assert.equal(safeHttpUrl(null), "")

  assert.equal(parseConfig('{"frigate":{"url":"-o/tmp/x"}}').frigate.url, "",
    "and parseConfig is where that is enforced")
  assert.equal(parseConfig('{"frigate":{"url":"nvr:5000"}}').frigate.url,
    "http://nvr:5000")
}

{
  assert.equal(safeStreamUrl("rtsp://cam/live"), "rtsp://cam/live")
  assert.equal(safeStreamUrl("rtsps://cam/live"), "rtsps://cam/live")
  assert.equal(safeStreamUrl("http://nvr/api/x"), "http://nvr/api/x",
    "Frigate's MJPEG endpoint is a stream too")
  assert.equal(safeStreamUrl("file:///home/me/.ssh/id_rsa"), "",
    "a camera does not get to point the player at a local file")
  assert.equal(safeStreamUrl("javascript:x"), "")
  assert.equal(safeStreamUrl(""), "")

  // A cached entry written before the probe checked, or hand-edited, is
  // filtered on read as well as on write.
  const cfg = parseConfig(JSON.stringify({
    sources: { onvif: true },
    onvif: [
      { name: "good", rtsp: "rtsp://cam/live", user: "admin" },
      { name: "bad", rtsp: "file:///etc/passwd", user: "admin" }
    ]
  }))
  assert.deepEqual(onvifCameras(cfg, "/run/user/1000/omarchy-cameras")
    .map(c => c.name), ["good"])
}

// --- an MQTT reconnect must not replay what MQTT already delivered ----------
//
// Polling takes over whenever the broker is not connected, and the first poll
// after a drop asks for everything still in progress — including detections
// already alerted over MQTT moments earlier. The service no longer discards
// that first reply (doing so lost live detections outright), so id dedup is
// what keeps it from alerting twice. This asserts the property that fix rests
// on.

{
  const live = JSON.stringify([
    { id: "already-seen", camera: "porta", label: "person",
      start_time: 1000, end_time: null },
    { id: "started-during-the-gap", camera: "quintal", label: "person",
      start_time: 1004, end_time: null }
  ])

  // MQTT delivered the first one before the broker dropped.
  const seen = { "already-seen": 1000 }

  const result = newEvents(live, ["person"], seen)
  assert.deepEqual(result.events.map(e => e.id), ["started-during-the-gap"],
    "the poll after a reconnect alerts only what MQTT never got to deliver")

  // And the detection that arrived while nothing was connected is a real
  // alert, not backlog — the whole point of not discarding the first reply.
  assert.equal(result.events[0].inProgress, true)
}
