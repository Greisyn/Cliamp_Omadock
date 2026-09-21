# Cliamp_Omadock

Control dock for cliamp, works with headless daemon, casts to other docks
on the same LAN network.

## Install

```bash
git clone https://github.com/Greisyn/Cliamp_Omadock.git ~/.config/omarchy/plugins/local.cliamp-dock
chmod +x ~/.config/omarchy/plugins/local.cliamp-dock/lan-share.sh
omarchy restart shell
```

> First run: the plugin starts closed by default. Look for the slim edge
> handle on the right edge of the screen (middle) — hover it briefly or
> tap it to reveal the player card.

Updates: `omarchy plugin update local.cliamp-dock && omarchy restart shell`.

LAN audio needs `yay -S snapcast` on sharer and listeners (ffmpeg ships
with Omarchy). Open TCP 1704/1705/1780 on the sharer, or your custom ports.

---

# Cliamp Dock (`local.cliamp-dock`)

Floating, theme-aware docked player for cliamp, styled and behaved like
[oShelf](https://github.com/i12bp8/oShelf): a slim edge handle with
dwell-to-reveal, a collapsing card surface, and leave-to-close.
The bar shows only an icon (play state + settings).

## Hiding (oShelf model)

- One floating window per screen (`Overlay` layer, zero exclusive zone).
- Only the edge handle and the open card take input; all other pixels
  pass through to the desktop (layer-shell input mask).
- Hover the handle for `openDelay` ms (accent dwell fill, tap opens
  instantly) to reveal the card with slide + scale + fade (`motionDuration`).
- Leaving both handle and card for `closeDelay` ms collapses it.
  Moving the pointer off the handle restarts the dwell (`steadyHover`).
- Pin (`keepOpen`) disables auto-collapse. `reducedMotion` kills animation.
- Handle length/depth/position, both delays, and motion duration are tunable
  in the settings panel with oShelf's ranges.

## Layout

- `placement`: left / right side card (360×480) or bottom tray (640×400),
  all resizable within oShelf's bounds.
- Card: radius-24 `Color.background` surface, 1px border, soft drop shadow,
  accent gradient wash, icon-tile header with DemiBold title.

## Kinds

- `service` (`DockService.qml`, `keepLoaded: true`): polls `cliamp status --json`,
  renders the floating `PanelWindow` dock, auto-hides, exposes IPC
  `local.cliamp-dock toggle/show/hide/status/settings` (plus LAN:
  `share/unshare/listen/unlisten/lanstatus`, see below).
- `bar-widget` (`BarWidget.qml`): icon only. Right click toggles settings
  (`Panel.qml`), left click toggles play/pause. The dock card header also
  carries a gear button that opens settings. Exposes the same open/close
  contract as first-party widgets so hotkeys/summon route to the panel.

## Player

- Transport: prev / play-pause / next / stop, seekable progress, time readout.
- Header shows the live track artist when the daemon reports one.
- Volume slider binds the real `volume` field from `status --json` (newer
  cliamp), falling back to the persisted value otherwise. Drag previews the
  dB label live; release sends one `cliamp volume` call.
- Visualizer mirror: a strip fed by `cliamp visstream --fps 15`, the same
  band data cliamp's own visualizer renders. The live mode name rides in the
  stream frames, so the caption always shows what cliamp actually selected —
  and the render follows the family: waveform line (Wave, Scope, Terrain,
  Heartbeat, Pulse), mirrored bars (Mirror, Stereo), dot matrix (Scatter,
  Firework, Matrix, Rain, Retro and friends), plain bars for the rest.
  Streams only while the card is open and the player runs a non-None
  visualizer; toggle with "Live visualizer bars".

## Settings panel sections (top to bottom)

- Player: show/hide/toggle the dock card, pin open.
- LAN Share + Ports: role, share/listen, host, ports (see below).
- Placement & size: left / right / bottom, card dimensions, compact mode.
- Edge handle & motion: open/close delays, handle length/depth/position,
  motion duration, steady hover, reduced motion.
- Dock sections: show/hide progress, volume, shuffle/repeat/mono, EQ row,
  visualizer/speed row, live visualizer bars individually.
- Cliamp options: volume, shuffle, repeat, mono, speed, EQ preset,
  visualizer, theme, audio device, playlist load.

Persisted to `~/.config/omarchy/local.cliamp-dock.json`.

## Keyboard & touchpad

No right-click, hover, or scroll wheel required:

- The dock handle opens on tap as well as hover-dwell; the card header
  gear opens settings (right-click on the bar icon works too).
- Tab / Shift+Tab moves through card buttons, switches, and text fields;
  Enter/Space activates; Esc closes card and settings.
- Settings takes keyboard focus on open, so PageUp/PageDown works at once.
- PageUp/PageDown — or the sticky PgUp/PgDn buttons — scroll long panels.
- Volume has −/+ step buttons beside the slider (sliders are pointer-only).

## Theme-aware

All surfaces use `Color.popups.background/text/border`, `Color.accent`,
`Color.muted`, `Style.cornerRadius/font/spacing`. `omarchy theme set`
repaints dock + panel with no plugin changes.

## IPC

```bash
omarchy-shell local.cliamp-dock toggle
omarchy-shell local.cliamp-dock show
omarchy-shell local.cliamp-dock hide
omarchy-shell local.cliamp-dock status
omarchy-shell local.cliamp-dock settings    # open settings panel
omarchy-shell local.cliamp-dock share        # start LAN share (Snapcast)
omarchy-shell local.cliamp-dock lanstatus    # {"sharing":..,"ip":..}
omarchy-shell local.cliamp-dock listen 10.0.0.212
omarchy-shell local.cliamp-dock unlisten
omarchy-shell local.cliamp-dock unshare
cliamp toggle && cliamp next && cliamp prev
cliamp volume -5 && cliamp seek 30 && cliamp shuffle toggle
```

## LAN Share — synced low-latency rooms (Snapcast)

Play a playlist on this machine, listen in the bedroom/office in sync.

- Role: **Auto** (share + listen), **Server** (cast only — listen controls
  hidden), **Client** (listen only — share controls hidden). Persisted as
  `lanRole` in `~/.config/omarchy/local.cliamp-dock.json`.
- The floating dock card carries a compact LAN row (status + Share/Listen
  quick toggles, role-aware); full role/port editing stays in the settings
  panel.
- Ports (all switchable in the panel, applied on next Share start):
  audio `lanStreamPort` (1704), control `lanControlPort` (1705),
  web `lanWebPort` (1780), HTTP fallback `lanHttpPort` (8099).
  Listeners must use the sharer's STREAM port
  (`snapclient tcp://<sharer-ip>:1704`).
- Panel section "LAN Share (synced rooms)" (near the top of the settings
  panel): **Share this room** publishes
  the default-sink monitor via Snapcast. **Listen** joins another sharer.
  Footer shows `SHARING :<audio>` / `LISTENING` state. Helper:
  `lan-share.sh`
  (`check|status --json|share-start [audio [control [web]]]|share-stop|`
  `listen-start <host> [stream-port]|listen-stop|http-start [port]|`
  `http-stop`). Share and Listen are single-mode (starting one stops the other).
- Deps on sharer AND listeners: `yay -S snapcast` (ffmpeg already present).
  Open the three Snapcast TCP ports on the sharer
  (e.g. `sudo ufw allow 1704,1705,1780/tcp`, adjusted if you changed ports).
  No root needed otherwise; binds LAN only.
- Bedroom/office laptop (any distro): `snapclient tcp://10.0.0.212:1704`
  (use the sharer's IP/port from `lanstatus`). All Snapcast clients stay
  sample-synced; per-client latency trim via Snapcast web/app if needed.
- Fallback: **HTTP fallback** serves `http://<sharer>:8099/cliamp.mp3`
  (MP3 192k, plays in any browser/player, ~2s delay, not synced).
- Note: the service is `keepLoaded`, so after updating this plugin run
  `omarchy restart shell` once to pick up service-side changes.
