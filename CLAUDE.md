# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

An Omarchy 4 ("Quattro") shell plugin: ONVIF and Frigate camera viewing.
Read `README.md` first for what the plugin does and how a user configures it —
this file covers only what you need to change the code.

## Development loop

The plugin is a Quickshell plugin, so it must be installed to run. `omarchy
plugin add` clones from git, which is useless while developing; symlink instead:

```bash
ln -s ~/orca/omarchy_cameras ~/.config/omarchy/plugins/avila.cameras
omarchy plugin validate .          # manifest + entry points; exit 0 is silent
omarchy-shell shell rescanPlugins
omarchy plugin enable avila.cameras
```

**Hot reload does not update the bar widget.** The registry logs "Local plugin
changed, reloading", but the running widget keeps the old code — verified both
through the dev symlink and with the plugin installed as a real directory, and
`rescanPlugins` does not help either. Every QML change needs:

```bash
omarchy restart shell && sleep 7
```

Budget for that: the shell takes ~6-7s to come back, and IPC calls before then
return "Target not found."

## Checks

```bash
node test_cameras.js   # Cameras.js: parsing, stream selection, event filtering
python3 test_mqtt.py   # MQTT packet framing, event payload handling
python3 test_onvif.py  # WS-Security digest, SOAP parsing, credential handling
python3 test_thumbd.py # runtime dir: symlink, ownership and mode rejection
omarchy plugin validate .
```

All four test files are single scripts of `assert` calls with no framework — run
them whole, there is nothing to run individually. None touches the network.

`test_cameras.js` `eval`s `Cameras.js` into its own scope rather than importing
it, because `Cameras.js` is a QML `.js` resource and cannot have `export`
statements. **Keep `Cameras.js` to plain functions and `var`** — no
`import`/`export`, and nothing that assumes a module scope. The existing file
also avoids arrow functions and `let`/`const` for consistency; match it.

The WSSE digest vector in `test_onvif.py` was cross-checked against `zeep`.
The example printed in the OASIS spec does not reproduce (known erratum) — do
not "correct" the constant to match it.

## Debugging a running shell

```bash
omarchy-shell avila.cameras status        # cameras, view, frigate url, errors
omarchy-shell shell summon avila.cameras '{}'
quickshell log -p $OMARCHY_PATH/shell -t 300 | grep -i avila
```

The log is extremely noisy — every plugin logs a benign "Handler was registered
but will not be used" warning per monitor. Filter those out before reading.

QML errors in this plugin surface as `PluginRegistry`/`loadPluginWidget`
warnings, not as a crash; a broken widget just silently fails to appear.

To verify UI changes, screenshot with `grim -o <monitor>` and crop with
`ffmpeg`. `hyprctl -j monitors` says which one is focused (this machine has
three), and `hyprctl -j layers` lists layer-shell surfaces by namespace —
`omarchy-cameras-alert` is how you check whether an alert is on screen.

## Architecture

Three QML entry points plus two scripts:

- **`Service.qml`** (`kind: service`) — instantiated **once per shell session**.
  Owns the camera list, every write to `cameras.json`, ONVIF subprocesses, the
  Frigate event poller, and the alert window.
- **`Panel.qml`** (`kind: bar-widget`) — instantiated **once per monitor**. The
  bar button, the grid popup, and the config form. Reaches the service through
  `bar.shell.serviceFor(moduleName)` (`shell.qml:275`).
- **`Alert.qml`** — the motion-alert preview. A layer-shell `PanelWindow`
  declared *inside* `Service.qml`, deliberately not a plugin kind (see below).
- **`Cameras.js`** — every pure function: config parsing, source merging,
  stream selection, event filtering, URL building. Anything testable belongs
  here rather than in QML.
- **`bin/omarchy-cameras-frigate`** — authenticated Frigate access: login, one
  fetch, and the thumbnail mirror.
- **`bin/omarchy-cameras-mqtt`** — stdlib MQTT 3.1.1 subscriber.
- **`bin/omarchy-cameras-onvif`** — stdlib-only Python. `discover` / `probe` /
  `stream-url`.
- **`bin/omarchy-cameras-view`** — the mpv launcher.

### Two layers, and why

Wayland has no window embedding (no XEmbed, no `mpv --wid`). Either pixels are
produced inside the `omarchy-shell` process or the video is a separate Hyprland
window. Thumbnails are polled JPEGs inside the shell; the focused view is mpv.
Do not try to merge these.

## Traps this codebase has already hit

**Do not add `panel`, `overlay`, or `menu` to `manifest.json`'s `kinds`.**
`isBarWidgetPanelPlugin` (`shell.qml:426`) returns false for any plugin
declaring one of those, which reroutes `omarchy-shell shell toggle
avila.cameras` away from the bar widget and breaks the grid popup. That is why
`Alert.qml` is a window owned by the service rather than a `panel` kind — the
first-party notifications service holds its toasts the same way.

**HTTP is `Process { command: ["curl", "-fsS", ...] }`**, not
`XMLHttpRequest`. Every first-party plugin does it this way; see
`$OMARCHY_PATH/shell/plugins/panels/weather/Panel.qml`.

**`fittedContentWidth` does not add the card's padding; `fittedContentHeight`
does** (`Ui/KeyboardPanel.qml:161,168`). Passing a raw content width clips the
last column by exactly the padding plus border.

**`PanelKeyCatcher` takes keys before its children.** Every `TextField` in the
panel must appear in its `blocked:` expression or that field silently refuses
letters. `KeyboardPanel.focusTarget` is force-focused when the surface maps, so
it has to point at the first input when the config view is showing — otherwise
the key catcher takes focus and the whole form is untypeable. Escape is handled
one level above the fields, since a blocked catcher never sees it.

**`StdioCollector.text` is read-only.** Assigning `""` to it to "clear before
the next run" throws, and because the throw aborts the calling function before
`process.running = true`, the process never starts and whatever busy flag was
set stays set forever. That is exactly how the ONVIF Detect button hung. Read
results in `onStreamFinished` (at `onExited` the collector may not have the
whole payload yet), and give any user-visible busy flag a watchdog `Timer` — a
process that fails to start emits neither signal.

**In `Alert.qml`, position with `x`/`y`, not anchors, and measure against
`root.width`.** Two traps stacked here: assigning `undefined` to
`anchors.left`/`anchors.right` still counts as anchored, so QML derived the
width from two unresolved edges and collapsed the card to -10px; and
`root.width` is the default 100 until the layer surface maps, so anything
reading it at `Component.onCompleted` gets nonsense. As a binding it settles
correctly once mapped.

Quickshell's logical width for a screen is not what `grim` captures — eDP-1
here reports 2259 to Quickshell and 1920 to `grim`. When checking placement in
a screenshot, scale the expected coordinates by `1920/2259` before hunting for
the card, or you will conclude it never rendered.

**QML's `Image` fetches URLs itself and cannot carry a cookie.** That is the
whole reason `bin/omarchy-cameras-frigate` exists: on an authenticated Frigate
the JWT lives in an HTTP-only cookie, so images have to be mirrored to files in
`$XDG_RUNTIME_DIR/omarchy-cameras/` and shown as `file://`. `Cameras.js`
switches `thumbKind` to `"file"` the moment `frigate.user` is set. Keep that
path off when there is no login — an unauthenticated instance needs no extra
processes at all.

Guard "is auth on" with `!!frigate.user`, not `frigate.user !== ""`: callers
can hand `frigateCameras` a config object built by hand, and `undefined !== ""`
is true, which silently switched every thumbnail to a file that nothing was
writing.

**Never set `Image.source` on a visible thumbnail.** It clears the element
while the new file loads, so a polled JPEG blinks on every tick. `CameraThumb`
double-buffers and swaps only once the incoming frame is `Ready`.

**Do not pass `--fs` to mpv.** Omarchy floats, centers and sizes everything of
class `mpv` at 875x600 (`$OMARCHY_PATH/default/hypr/apps/system.lua`). `--fs`
fights that rule, and mpv re-asserts fullscreen on stream changes, so the
window flips to fullscreen whenever something moves in frame. A dedicated
`--wayland-app-id` dodges the rule but then nothing sizes the window at all.

**The service owns `cameras.json`.** The `FileView` is watched, so a write
comes back through `onLoaded` and rebuilds the camera list. Never write it from
`Panel.qml`, and keep the config form's fields uncontrolled while open — a
binding straight to the config rewrites what the user is typing on every
reload.

**A source that is off must cost nothing.** `config.sources` gates both the
config UI and the runtime: no cameras, no polling, no MQTT, no mirror. Check
it with `frigateEnabled()` inside anything `onConfigChanged` calls — the
`frigateOn` binding has not been re-evaluated yet while its own change handler
runs, so it still holds the previous answer and the Frigate fetch silently
never fires. The binding is fine for UI and `Timer.running`.

**ONVIF's `GetSnapshotUri` is not usable.** Both cameras tested advertise one
and answer HTTP 500 to it — no auth, basic and digest alike. Thumbnails come
from `omarchy-cameras-thumbd`, one long-lived player per camera. Long-lived
matters: a fresh decoder waits for a keyframe, 54s on one camera here, while a
held-open one delivers on schedule.

**A camera URL carries its password, so it must never be an argument.** That
rules ffmpeg out for thumbnails: `ffmpeg -h demuxer=rtsp` lists no credential
option, the input is only ever argv, and argv is world-readable through
`/proc`. The concat demuxer (URL in a 0600 file) hangs on live RTSP. mpv is
what works — `--playlist=/dev/fd/N` on an anonymous pipe, then
`screenshot-to-file` over `--input-ipc-server`, which writes the same path
repeatedly. `omarchy-cameras-view` uses `--playlist=<(printf ...)` for the same
reason. Along the way this got faster, not slower: first frame in 5s where a
fresh ffmpeg took 54s.

Same rule one level up: `thumbd` reads its camera list on **stdin**, because
even without a password a stream path and the account watching it have no
business in the process table. Quickshell's `write()` does not close the pipe,
so `stdinEnabled = false` is what gives the reader its EOF — and that
assignment overwrites the declared `stdinEnabled: true` binding, so every
call site must set it back to true before starting the process again.

**`Quickshell.execDetached` sends the child's stdio to `/dev/null`** — checked
in `/proc/<pid>/fd`, not assumed. That is load-bearing: mpv prints
`Playing: rtsp://admin:<password>@host/live` on stdout when it opens a
playlist, and `omarchy-shell`'s own stdout is a journal socket. Swapping
`omarchy-cameras-view` for a `Process` with a `StdioCollector`, or adding any
redirection to a log, writes camera passwords to disk. `thumbd` sets
`DEVNULL` explicitly for the same reason. Verified with a canary password:
nothing in the journal, nothing in the quickshell log.

**Anything on the LAN can reach the ONVIF XML parser**, because discovery
sweeps every address on the subnet and parses whatever answers on 3702.
`xml.etree` brings no defences, so `parse_xml` adds the two that matter: a
1 MiB cap (an uncapped `response.read()` lets a device grow the process without
limit) and a flat refusal of any payload declaring a DTD. Internal entity
expansion is the reason — 363 bytes of nested entities measured here expand to
1 MB in the tree, and each further level multiplies by ten. External entities
need no handling; ElementTree already refuses them, so this is a DoS, not XXE.

**A URL that reaches a command line has to be a URL.** `curl` reads a leading
dash as an option — `-o` writes a file, `-K` reads a config file — and the
Frigate URL is concatenated straight into an argument, so `safeHttpUrl` gates
it in `parseConfig`. A bare host is filled in with `http://` rather than
rejected, because curl already assumed that and existing configs rely on it.
One level down, `GetStreamUri` is answered by the device and the answer becomes
a playlist entry, so `check_stream_scheme` (in the probe) and `safeStreamUrl`
(on read) keep `file://` away from the player.

**`cameras.json` is chmod 600 after every write.** It holds no password, but it
holds every camera's address, stream path and username — the same thing that is
kept out of argv, and the default umask leaves it 0644 or 0664. `FileView` has
no permission setting and `atomicWrites` renames a fresh file into place each
save, so the mode has to be reapplied rather than set once. Drive it from
`saveConfig` and startup, never from `onLoaded`: chmod touches the file the
`FileView` is watching, and reacting to that is a loop.

**The path sanitiser is duplicated on purpose.** `Cameras.slug()` is what every
caller uses, but `thumbd` and `omarchy-cameras-frigate` build paths from that
name in other languages, and each checks it again (`safe_name`, `check_name`).
A caller that does not know about `slug` would otherwise turn `../../.bashrc`
into a path.

**`$XDG_RUNTIME_DIR` has no fallback, on purpose.** It is per-user and 0700,
and a Wayland session cannot exist without it — the compositor socket is in
there. The old `${XDG_RUNTIME_DIR:-/tmp}` traded that guarantee for a
predictable path in a world-writable directory. Whoever creates the
subdirectory (`thumbd`, `omarchy-cameras-frigate`) also checks it rather than
trusting it: a real directory, `lstat`-ed so a symlink is not followed, owned
by this uid, no bits for anyone else. `Service.qml` only reads from it, and
leaves `runtimeDir` empty when the variable is unset, which gates the thumbnail
daemon off.

**Every external command belongs in `Cameras.REQUIRED_TOOLS`.** A missing
binary makes `Process` fail to start, which emits no signal the plugin can see
— no `exited`, no `streamFinished` — so the only symptom is a feature that
does nothing. The startup check spawns one shell that reports which of them
are off PATH, and the config screen shows the list. Add to that table whenever
a new command is introduced; the test asserts the check covers every entry.

The Python scripts use `#!/usr/bin/python3`, not `env python3`, on purpose: a
version manager on PATH (mise here) would otherwise decide which interpreter a
desktop plugin runs, and removing that install would break MQTT and ONVIF.
Everything they use is stdlib, so the system interpreter is always enough.

## Frigate specifics

Only cameras listed under `go2rtc:` in Frigate's config have an RTSP restream.
`Cameras.streamFor` picks `rtsp://<host>:8554/<name>` for those and falls back
to `http://<frigate>/api/<name>` (Frigate's MJPEG of the detect feed) for the
rest. Asking `:8554` for a camera go2rtc never heard of yields a dead window,
and on a typical install most cameras are not restreamed.

**`/api/events` returns only events that have already ended.** Live ones come
from `/api/events?in_progress=1` and carry `end_time: null`. The poller asks
only for those — waiting for the ended copy is the delay worth avoiding — and
runs every 3s, because a detection shorter than one interval is never seen at
all.

Dedup is on **id**, not a timestamp: a running detection comes back on every
poll until it ends. A timestamp watermark would also let a long-running event
advance the mark past a shorter one that started earlier on another camera and
swallow it. `lastEventTime` survives only to bound the query window
(`after = newest - 120`); `seenEvents` (id → start_time) is what prevents
repeats.

**MQTT is a shortcut, never the only path.** `bin/omarchy-cameras-mqtt` is a
stdlib MQTT 3.1.1 subscriber (four packet types) that streams one JSON line per
detection; the Service parses `[{...}]` lines through the same `applyEvents` as
HTTP. HTTP polling keeps running while `mqttConnected` is false, so a bad
password degrades latency rather than losing alerts.

**`secret-tool store` waits for stdin EOF.** Quickshell's `Process.write()`
does not close the pipe, so the process hangs forever, `onExited` never fires,
and the password is never stored — the Connect button looked like it did
nothing. Set `stdinEnabled = false` right after writing. (The ONVIF probe
escapes this because Python's `readline()` returns on the newline.)

**Tab does not walk the config form by itself.** `PanelKeyCatcher` claims Tab
for `switchPanel`, and even while `blocked` the focus chain leaves the panel
entirely. Every `TextField` in the form is wired with explicit
`KeyNavigation.tab` / `backtab`; add new fields to that ring, and to the
`blocked:` expression, or they will be unusable from the keyboard.

**Do not bind `Process.running` for a process that exits on its own.** The exit
writes `running`, which breaks the binding, so it never restarts. And do not
give the retry `Timer` `triggeredOnStart` — a refused MQTT connection dies in
70ms, so start-triggering it spawns a new process every few milliseconds (451
of them before it was noticed). Drive the first attempt from
`onMqttWantedChanged` and let a plain repeating timer own the backoff.

**MQTT's CONNECT packet carries the password as a plain length-prefixed
string.** Captured through a passthrough proxy, a plaintext connect puts
`\x00\x05avila\x00\x0fsecret-pass-123` on the wire in the first 48 bytes; the
same session with `--tls` yields a handshake and nothing recoverable. So the
socket gets wrapped whenever Frigate says the broker speaks TLS — any of
`tls_ca_certs`, `tls_client_cert`, `tls_client_key`, `tls_insecure`, or port
8883. Verification stays on; `tls_insecure` is honoured because Frigate honours
it, but it is never reached for here after a handshake fails, and a CA file
Frigate named but that is missing raises rather than falling back to the system
roots. `test_mqtt.py` asserts all of that on the context alone, no socket.

Plain HTTP on Frigate is not the plugin's to fix, and a home LAN install on
`http://` is ordinary, so `Cameras.insecureWarnings` says so at the top of the
config screen instead of refusing. Keep it quiet when there is nothing to
capture — no Frigate login, or a broker with no username — or the line stops
being read. ONVIF needs no warning: WS-Security sends
`Base64(SHA1(nonce + created + password))`, never the password, and there is no
Basic fallback in `bin/omarchy-cameras-onvif`.

Frigate's `/api/config` answers more than it looks like: the whole `mqtt` block
(host, port, `topic_prefix`, user, the TLS material — never the password) and,
indirectly, the go2rtc RTSP port. That port is not stated anywhere, but a restreamed camera
feeds itself from the restream, so its own ffmpeg input is
`rtsp://127.0.0.1:<port>/<name>` — `Cameras.restreamPort` reads it back out.
Before adding a setting, check whether Frigate already knows the answer.

**Do not reset `eventsSynced` when the polling `Timer` starts.** That timer
also starts when MQTT drops, and the reset makes the next `applyEvents` mark
every in-progress detection as seen and return without alerting — so a
reconnect loses whatever was in frame at that moment rather than delaying it.
The reset belongs on the transition into watching (`watchingEvents`, alerts
armed and Frigate on), which is the case that genuinely has a backlog. Nothing
double-alerts after a reconnect: what MQTT already delivered is in
`seenEvents`, and `newEvents` filters on id. `omarchy-shell avila.cameras mqtt
""` reports `synced=` so this is visible from outside.

**Prune `seenEvents` before re-marking the payload, never after.** A detection
can stay in progress for hours — a parked car, a bicycle left in frame — and
`pruneSeen(seen, newest - 600)` will happily drop an id that is still being
reported. Mark the payload after pruning and anything still live survives;
do it the other way round and that camera alerts every 3 seconds. There is a
test asserting both orders.

## Credentials

ONVIF passwords never enter `cameras.json`. `probe` stores them via
`secret-tool` under `service=omarchy-cameras, key=onvif-<host>`, and
`stream-url` reads them back and percent-encodes them into the RTSP URL when
the viewer launches. Passwords reach the Python script over **stdin**, never
argv — argv is world-readable in `/proc`.
