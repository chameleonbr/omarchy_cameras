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

**Hot reload does not work through the symlink.** Neither saving a file nor
`rescanPlugins` picks up an edit — the plugin registry's file watcher does not
follow it. Every QML change needs:

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
omarchy plugin validate .
```

ONVIF is built and tested but deliberately not in the config UI while the
Frigate side is being finished. `Cameras.onvifCameras`, the scripts and the
`discover`/`discovery` IPC verbs all still work — do not delete them, and put
the UI section back rather than rewriting it.

Both test files are single scripts of `assert` calls with no framework — run
them whole, there is nothing to run individually. Neither touches the network.

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

Frigate's `/api/config` answers more than it looks like: the whole `mqtt` block
(host, port, `topic_prefix`, user — never the password) and, indirectly, the
go2rtc RTSP port. That port is not stated anywhere, but a restreamed camera
feeds itself from the restream, so its own ffmpeg input is
`rtsp://127.0.0.1:<port>/<name>` — `Cameras.restreamPort` reads it back out.
Before adding a setting, check whether Frigate already knows the answer.

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
