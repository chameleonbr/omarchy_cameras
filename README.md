# omarchy-cameras

Frigate camera viewer for [Omarchy](https://omarchy.org) 4 ("Quattro").

Live thumbnails in the bar, motion alerts as they happen, fullscreen playback
in mpv.

ONVIF discovery is written and tested but not yet exposed in the interface —
this release is Frigate only.

## Install

```bash
omarchy plugin add https://github.com/chameleonbr/omarchy_cameras.git --enable --yes
```

It shells out to `curl`, `mpv`, `jq`, `secret-tool` and `python3`. Omarchy
ships mpv, jq and libsecret; curl and python3 usually arrive as dependencies
of something else, so a lean install can be missing them:

```bash
sudo pacman -S --needed curl python jq mpv libsecret
```

Config names anything missing at the top of the screen rather than failing
quietly — a command that is not there makes the plugin's helper processes fail
to start, which otherwise shows up nowhere.

Then point it at Frigate (see Setup) and restart the shell once:

```bash
omarchy restart shell
```

## Setup

Click the CCTV icon in the bar and hit **Config** (a fresh install opens
straight there). The Frigate URL is the only required field — everything else,
including the login, the motion alerts and MQTT, is optional and sits below it.
Settings land in `~/.config/omarchy/cameras.json`; every password goes to the
keyring instead, under `service=omarchy-cameras`.

The same writes are available from a script:

```bash
omarchy-shell avila.cameras setFrigate http://nvr.lan:5000
omarchy-shell avila.cameras mqtt on
```

## How it works

### Two layers

Wayland has no window embedding — no XEmbed, no `mpv --wid`. Either the pixels
are produced inside the `omarchy-shell` process, or the video is a separate
Hyprland window. This plugin uses each where it is good:

| Layer | What | Where |
|-------|------|-------|
| 1 — thumbnails | a JPEG per camera, refreshed every ~2s | inside the shell, in the popup grid |
| 2 — focused view | the real stream, hardware decoded | a floating `mpv` window |

Nobody watches nine streams at once. Decoding nine of them to fill 170px tiles
would spend a lot of CPU on pictures too small to read.

### If Frigate requires a login

Frigate 0.15+ ships with auth on. Fill in **user** and **password** next to the
URL in Config; the password goes to the keyring (`service=omarchy-cameras`,
`key=frigate-<host>`) and never into `cameras.json`. Only the username is
stored there, which is what tells the plugin a login is needed at all.

Leaving the password blank on a later save keeps the one already stored, so
re-saving the URL will not wipe a working login.

Behind the scenes an authenticated instance works differently, because QML
fetches image URLs itself and cannot be handed Frigate's JWT cookie: while the
grid is open, `omarchy-cameras-frigate mirror` keeps each visible camera's JPEG
fresh in `$XDG_RUNTIME_DIR/omarchy-cameras/` and the tiles read those files. It
runs only while thumbnails are on screen, and only when a login is configured —
without one, nothing extra runs at all.

To store the password from a script instead:

```bash
bin/omarchy-cameras-frigate store-password http://nvr.lan:5000   # reads stdin
omarchy-shell avila.cameras setFrigate http://nvr.lan:5000 admin
```

`setFrigate` deliberately takes no password — it would end up in shell history
and in the process's argv.

### Which stream a camera plays

Frigate only restreams the cameras listed under `go2rtc:` in its own config.
For those, the viewer plays `rtsp://<frigate-host>:8554/<camera>` — the good
path: the codec passes through untouched and Frigate keeps the only connection
to the camera. For every other camera it plays `http://<frigate>/api/<camera>`,
Frigate's MJPEG of the detect feed: heavier on the wire and softer, but it
exists for every camera with no configuration. Asking for a restream that
isn't there just yields a dead window.

To upgrade a camera, add it to `go2rtc:` in Frigate's config — nothing changes
here, the plugin picks it up on the next refresh.

### Motion alerts

Off by default. Once armed, the plugin watches Frigate for detections and pops
a small preview of whichever camera tripped — sized, timed, and placed where
you tell it, on the monitor you tell it. Clicking the preview opens that camera
full size; otherwise it disappears on its own.

Several detections at once stack downwards, oldest at the top, so a burst reads
in the order it happened. Four at a time: past that the column is taller than
it is useful, and the oldest card drops off. Each card times out from when it
appeared, so a late arrival still gets its full time on screen.

The preview is the **still Frigate saved for that event**, with its bounding
box, label and score drawn on (`snapshot.jpg?bbox=1`). It is deliberately not a
live frame: quick movement is over long before anyone looks up, and a live feed
would just show an empty driveway.

Everything about it is a setting in **Config → Motion alerts**: on/off, which
labels count, which monitor, which corner (top-center sits by the clock),
seconds on screen, and preview width.

Arming and disarming has two shortcuts that skip the form: the **Detection
on/off** button beside Config, and **middle-clicking the bar icon**. While
armed the bar icon is highlighted; switched off it goes back to the ordinary
bar color, so a glance tells you whether windows can appear on their own.

Changing the monitor, corner or width rehearses the placement: a black
rectangle appears for 5s exactly where alerts will, so you can see the spot
without waiting for something to walk past a camera. **Show me** replays it.

Alerts fire **while the detection is still happening**, not once it is over.
The poll asks Frigate only for `in_progress=1`; its plain `/api/events` returns
events that have already ended, which is exactly the delay worth avoiding.
Measured against a live camera: the preview lands 4-9s after the detection
starts, while the event is still running.

The trade is that a detection which starts and finishes inside one poll
interval is never seen, so the poll runs every 3s.

### MQTT

Optional, and strictly a shortcut: Frigate publishes a detection to MQTT the
instant it makes one, with no poll interval in the way. Switch it on in
**Config → MQTT**.

Measured against the same live camera: **0.6-0.7s** from the start of a
detection to the preview, where polling took 3.9-9.1s.

Nothing has to be typed but the password. Host, port, topic prefix and username
all come from Frigate's own `/api/config`, and the password goes to the keyring
under `key=mqtt-<host>`.

Polling never stops while the broker is not actually connected — a wrong
password or a broker reboot costs latency, not alerts. The client retries every
15s in the background. The toggle's subtitle says which path is live.

A running detection is reported on every poll until it ends, so alerts
deduplicate on the event id. The newest timestamp is still kept in
`~/.local/state/omarchy/cameras-last-event`, but only to bound the query
window. The first reply after the shell starts, or after alerts are armed,
records what Frigate already knows and shows nothing — so neither a restart nor
a car that has been parked in frame since this morning turns into an alert.

### The viewer window

It is a plain floating `mpv`, which Omarchy already centers at 875x600. Press
**f** for fullscreen and **q** to close — mpv's own bindings, spelled out in a
line of OSD text when the window opens.

Not fullscreen from the start, on purpose: Omarchy's rule for class `mpv` and
mpv's own `--fs` fight each other, and every change in the video stream
re-triggers the fight, so the window flips back to fullscreen whenever
something moves in frame.

For a window parked in a corner instead of centered, add a rule of your own —
the viewer titles its windows `omarchy-cameras: <name>`:

```lua
-- ~/.config/hypr/apps/cameras.lua
o.window({ class = "mpv", title = "^omarchy-cameras:" }, {
  float = true,
  size = { 640, 360 },
  move = { "(monitor_w-680)", 60 },
})
```

## Configuration

`~/.config/omarchy/cameras.json` holds everything camera-related.

```json
{
  "frigate": {
    "url": "http://nvr.lan:5000",
    "rtspPort": 8554,
    "user": ""
  },
  "notifyLabels": ["person"],
  "alerts": {
    "enabled": false,
    "labels": ["person"],
    "monitor": "",
    "position": "top-center",
    "durationSec": 12,
    "width": 320
  },
  "onvif": []
}
```

- `frigate.url` — leave empty to run ONVIF-only. Cameras come from
  `/api/config`; disabled ones are skipped.
- `frigate.user` — set only when Frigate requires a login; the password lives
  in the keyring. See "If Frigate requires a login" above.
- `frigate.rtspPort` — fallback only, and not a setting in the UI. The real
  port is read back out of Frigate's own camera inputs: a restreamed camera
  pulls from `rtsp://127.0.0.1:<port>/<name>`, so the number is already in
  `/api/config`.
- `onvif[]` — ONVIF support is built but not surfaced while the Frigate side is
  being finished. The scripts and IPC verbs still work; see Development.
- `alerts` — see Motion alerts above. `monitor` is a connector name as the
  compositor reports it (`DP-1`, `HDMI-A-1`); empty means the first screen.
  `labels` falls back to `notifyLabels` when it is absent or empty.

The file is watched, so edits apply without a restart.

Display preferences live on the bar widget entry in
`~/.config/omarchy/shell.json` (or in Setup > Plugins):

| Setting | Default | Meaning |
|---------|---------|---------|
| `columns` | 2 | grid columns in the popup |
| `thumbIntervalMs` | 2000 | thumbnail refresh, only while the popup is open |

Credentials never go in either file — see below.

## Usage

Click the CCTV icon in the bar for the grid; click a tile (or select it with
the arrow keys and press Enter) to open that camera fullscreen. `r` refreshes.

Over IPC, for keybinds:

```bash
omarchy-shell shell toggle avila.cameras '{}'   # grid, on the focused monitor
omarchy-shell avila.cameras view garagem        # straight to one camera
omarchy-shell avila.cameras alerts on           # or off; "" just reports
omarchy-shell avila.cameras mqtt on             # or off; "" reports broker state
                                                # and the last alert's latency
omarchy-shell avila.cameras showPlacement       # rehearse the alert position
omarchy-shell avila.cameras status
```

The `shell toggle` form is the one to bind: it picks the bar copy on the
focused monitor, whereas `avila.cameras open` acts on whichever copy owns the
IPC target.

## Development

`omarchy plugin add` clones from git, which is awkward while writing the
plugin. Symlink the checkout instead:

```bash
ln -s ~/orca/omarchy_cameras ~/.config/omarchy/plugins/avila.cameras
omarchy plugin validate ~/orca/omarchy_cameras
omarchy-shell shell rescanPlugins
omarchy plugin enable avila.cameras
```

The scanner follows the symlink, but **its file watcher does not** — neither
saving a file nor `rescanPlugins` picks up an edit through it. Run
`omarchy restart shell` after each change. (A plugin installed normally, as a
real directory, hot-reloads on save.)

Checks:

```bash
node test_cameras.js   # camera-list parsing, stream selection, merging
python3 test_onvif.py  # WS-Security digest, SOAP parsing, credential handling
```

Plugin load failures surface as `console.warn` from the shell's
`PluginRegistry`:

```bash
quickshell log -p $OMARCHY_PATH/shell -t 200 | grep -i avila
```

## Files

| Path | Role |
|------|------|
| `Service.qml` | camera registry and every write to cameras.json; one instance per shell, shared by every monitor's bar |
| `Panel.qml` | bar widget, popup grid, and the config form |
| `CameraThumb.qml` | double-buffered thumbnail; swaps frames only once the next one has loaded, so a polled JPEG does not blink |
| `Alert.qml` | the motion-alert window, owned by the service: a column of cards, oldest on top |
| `AlertCard.qml` | one preview card, also used for the placement rehearsal |
| `Cameras.js` | source merging, stream selection, event filtering, URL building — pure functions, no QML |
| `bin/omarchy-cameras-frigate` | authenticated Frigate access: login, one-shot fetch, and the thumbnail mirror |
| `bin/omarchy-cameras-mqtt` | stdlib MQTT 3.1.1 subscriber; one JSON line per detection |
| `bin/omarchy-cameras-onvif` | WS-Discovery, stream lookup, keyring — stdlib Python |
| `bin/omarchy-cameras-view` | the mpv launcher |
