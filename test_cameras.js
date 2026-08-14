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
  }
})

const fromFrigate = frigateCameras(apiConfig, frigateConfig)
assert.deepEqual(fromFrigate.map(c => c.name), ["garagem", "quintal"], "sorted, disabled dropped")
assert.equal(fromFrigate[0].stream, "rtsp://nvr.lan:8554/garagem")
assert.equal(fromFrigate[0].thumb, "http://nvr.lan:5000/api/garagem/latest.jpg")
assert.equal(fromFrigate[0].source, "frigate")

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
