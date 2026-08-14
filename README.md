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
| 2 — focused view | the real stream, hardware decoded | an `mpv --fs` window |

Nobody watches nine streams at once. Decoding nine of them to fill 170px tiles
would spend a lot of CPU on pictures too small to read.

## Install

```bash
omarchy plugin add https://github.com/<you>/omarchy_cameras.git --enable --yes
```

Then point it at your cameras (see below) and restart the shell once:

```bash
omarchy restart shell
```

## Configuration

`~/.config/omarchy/cameras.json` holds everything camera-related. It is also
where ONVIF discovery writes its results.

```json
{
  "frigate": {
    "url": "http://nvr.lan:5000",
    "rtspPort": 8554
  },
  "notifyLabels": ["person"],
  "onvif": []
}
```

- `frigate.url` — leave empty to run ONVIF-only. Cameras come from
  `/api/config`; disabled ones are skipped.
- `frigate.rtspPort` — the go2rtc restream port. The fullscreen view plays
  `rtsp://<frigate-host>:<rtspPort>/<camera>`, not the camera directly, so
  Frigate's connection to the camera is the only one.
- `onvif[]` — written by `omarchy-cameras-onvif discover`. Hand-editing is
  fine: `{"name": …, "rtsp": …, "ptz": true|false, "xaddr": …}`.

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
node test_cameras.js   # camera-list parsing and merging
```

Plugin load failures surface as `console.warn` from the shell's
`PluginRegistry`:

```bash
quickshell log -p $OMARCHY_PATH/shell -t 200 | grep -i avila
```

## Files

| Path | Role |
|------|------|
| `Service.qml` | camera registry; one instance per shell, shared by every monitor's bar |
| `Panel.qml` | bar widget and its popup grid |
| `Cameras.js` | source merging and URL building — pure functions, no QML |
| `bin/omarchy-cameras-view` | the mpv launcher |
