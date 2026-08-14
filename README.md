# omarchy-cameras

ONVIF and Frigate camera viewer for [Omarchy](https://omarchy.org) 4 ("Quattro").

Live thumbnails in the bar, fullscreen playback in mpv.

## Why two layers

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
omarchy-shell avila.cameras setFrigate http://nvr.lan:5000 8554 admin
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

Off by default. Once armed, the plugin polls Frigate's events every 5s and pops
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
seconds on screen, and preview width. **Middle-click the bar icon** to arm or
disarm without opening anything; the icon paints in the accent color while
alerts are armed.

Changing the monitor, corner or width rehearses the placement: a black
rectangle appears for 5s exactly where alerts will, so you can see the spot
without waiting for something to walk past a camera. **Show me** replays it.

The newest event's timestamp is kept in
`~/.local/state/omarchy/cameras-last-event`, so restarting the shell does not
replay the day's detections as a burst of previews. The very first poll after
that file is gone adopts the current timestamp and shows nothing.

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

## Install

```bash
omarchy plugin add https://github.com/<you>/omarchy_cameras.git --enable --yes
```

Then point it at your cameras (see below) and restart the shell once:

```bash
omarchy restart shell
```

## Setup

Click the CCTV icon in the bar and hit **Config** (a fresh install opens
straight there). The form takes the Frigate URL, and finds ONVIF cameras on the
local network with **Detect cameras** — fill in the camera credentials first,
then **Add** each one you want. Everything it writes lands in
`~/.config/omarchy/cameras.json`; ONVIF passwords go to the keyring instead,
under `service=omarchy-cameras`.

The same writes are available from a script:

```bash
omarchy-shell avila.cameras setFrigate http://nvr.lan:5000 8554
omarchy-shell avila.cameras discover
```

## Configuration

`~/.config/omarchy/cameras.json` holds everything camera-related. It is also
where ONVIF discovery writes its results.

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
- `frigate.rtspPort` — the go2rtc restream port. The fullscreen view plays
  `rtsp://<frigate-host>:<rtspPort>/<camera>`, not the camera directly, so
  Frigate's connection to the camera is the only one.
- `onvif[]` — written by `omarchy-cameras-onvif discover`. Hand-editing is
  fine: `{"name": …, "rtsp": …, "ptz": true|false, "xaddr": …}`.
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
omarchy-shell avila.cameras discovery           # ONVIF scan state
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
| `bin/omarchy-cameras-onvif` | WS-Discovery, stream lookup, keyring — stdlib Python |
| `bin/omarchy-cameras-view` | the mpv launcher |
