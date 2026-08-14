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
  { id: "c", camera: "garagem", label: "person", start_time: 300 },
  { id: "b", camera: "quintal", label: "cat", start_time: 200 },
  { id: "a", camera: "garagem", label: "person", start_time: 100 }
])

let seen = newEvents(events, 0, ["person"])
assert.deepEqual(seen.events.map(e => e.id), ["a", "c"], "oldest first, cat filtered out")
assert.equal(seen.after, 300, "the watermark passes every event, not just matching ones")

// The watermark is what stops one detection alerting forever.
assert.deepEqual(newEvents(events, 300, ["person"]).events, [])
assert.deepEqual(newEvents(events, 100, ["person"]).events.map(e => e.id), ["c"])

// A label the user did not ask for still advances the watermark, or an
// unwatched camera would keep re-delivering the events behind it.
assert.equal(newEvents(events, 0, ["nothing"]).after, 300)
assert.deepEqual(newEvents(events, 0, ["nothing"]).events, [])

assert.equal(newEvents("<html>502</html>", 42, ["person"]).after, 42,
  "an error page must not reset the watermark")
assert.deepEqual(newEvents("", 0, ["person"]).events, [])
assert.deepEqual(
  newEvents('[{"camera":"x","label":"person"}]', 0, ["person"]).events, [],
  "an event with no start_time cannot be de-duplicated, so it is skipped")
assert.deepEqual(newEvents(events, 0, ["PERSON"]).events.map(e => e.id), ["a", "c"],
  "label matching is case-insensitive")

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

assert.equal(newEvents(events, 0, ["person"]).events[0].hasSnapshot, false,
  "has_snapshot absent is not a snapshot")
assert.equal(
  newEvents('[{"id":"z","camera":"c","label":"person","start_time":9,"has_snapshot":true}]',
    0, ["person"]).events[0].hasSnapshot,
  true)

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
