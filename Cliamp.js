.pragma library

// Shared cliamp helpers: command builders, status parsing, formatting.
// No Qt imports here so both DockService and Panel can use it.

function statusCommand(pollMs) {
  return ["cliamp", "status", "--json"];
}

function runArgs(action, arg) {
  // Maps UI actions to `cliamp <cmd> [arg]`
  switch (action) {
  case "toggle": return ["cliamp", "toggle"];
  case "play": return ["cliamp", "play"];
  case "pause": return ["cliamp", "pause"];
  case "next": return ["cliamp", "next"];
  case "prev": return ["cliamp", "prev"];
  case "stop": return ["cliamp", "stop"];
  case "seek": return ["cliamp", "seek", String(arg)];
  case "volume": return ["cliamp", "volume", String(arg)];
  case "shuffle": return ["cliamp", "shuffle", String(arg)];
  case "repeat": return ["cliamp", "repeat", String(arg)];
  case "mono": return ["cliamp", "mono", String(arg)];
  case "speed": return ["cliamp", "speed", String(arg)];
  case "eqPreset": return ["cliamp", "eq", String(arg)];
  case "eqBand": return ["cliamp", "eq", "--band", String(arg.band), String(arg.db)];
  case "vis": return ["cliamp", "vis", String(arg)];
  case "theme": return ["cliamp", "theme", String(arg)];
  case "device": return ["cliamp", "device", String(arg)];
  case "playlist": return ["cliamp", "load", String(arg)];
  default: return ["cliamp", "status"];
  }
}

function parseStatus(raw) {
  try {
    var o = JSON.parse(String(raw || "{}"));
    return o;
  } catch (e) {
    return null;
  }
}

function fmtTime(sec) {
  sec = Math.max(0, Math.floor(Number(sec) || 0));
  var m = Math.floor(sec / 60);
  var s = sec % 60;
  return m + ":" + (s < 10 ? "0" + s : "" + s);
}

function trackTitle(st) {
  if (!st) return "cliamp";
  if (st.track && st.track.title) return String(st.track.title);
  if (st.title) return String(st.title);
  return "cliamp";
}

function isPlaying(st) {
  return st && String(st.state || "").toLowerCase() === "playing";
}

// Safe state readers: status shapes vary across versions and the daemon can
// be mid-transition, so these never yield undefined — the UI binds them.
function shuffleText(st) {
  if (!st) return "Off";
  var v = st.shuffle;
  if (v === true || String(v).toLowerCase() === "on") return "On";
  return "Off";
}

function shuffleOn(st) { return shuffleText(st) === "On"; }

function repeatText(st) {
  if (!st || st.repeat === undefined || st.repeat === null) return "All";
  var r = String(st.repeat).toLowerCase();
  if (r === "off" || r === "0" || r === "false") return "Off";
  if (r === "one" || r === "1" || r === "single") return "One";
  return "All";
}

function monoText(st) {
  if (!st) return "Off";
  var v = st.mono;
  if (v === true || String(v).toLowerCase() === "on") return "On";
  return "Off";
}

function monoOn(st) { return monoText(st) === "On"; }

function speedText(st) {
  var n = st ? Number(st.speed) : NaN;
  if (!isFinite(n) || n <= 0) return "1.00";
  return n.toFixed(2);
}

function progress(st) {
  if (!st || !st.duration || Number(st.duration) <= 0) return 0;
  return Math.max(0, Math.min(1, Number(st.position) / Number(st.duration)));
}

// Known cliamp themes / visualizers (from `cliamp theme list` / `cliamp vis list`).
// Users can still type custom values via CLI; these drive the dropdowns.
function themeNames() {
  return ["ayu-mirage-dark", "catppuccin", "catppuccin-latte", "dracula",
    "ember", "ethereal", "everforest", "flexoki-light", "gruvbox", "hackerman",
    "kanagawa", "matte-black", "miasma", "neon-blade-runner", "nord",
    "osaka-jade", "ristretto", "rose-pine", "tokyo-night", "vantablack", "winamp"];
}

function visNames() {
  return ["None", "Bars", "BarsDot", "BarsOutline", "Bricks", "Columns",
    "ClassicPeak", "ClassicLED", "Wave", "Scatter", "Flame", "Retro", "Pulse",
    "Matrix", "Binary", "Sakura", "Firework", "Bubbles", "Logo", "Terrain",
    "Scope", "Heartbeat", "Butterfly", "Ascii", "Firefly", "Mosaic", "Sand",
    "Geyser", "Stereo", "Mirror", "Rain"];
}

function eqPresets() {
  // Common presets accepted by `cliamp eq <preset>`; Custom = per-band values.
  return ["Flat", "Bass", "Treble", "Vocal", "Rock", "Pop", "Jazz",
    "Classical", "Electronic", "Hip-Hop", "Custom"];
}

function repeatModes() { return ["off", "all", "one"]; }
function onOff() { return ["on", "off"]; }

// ---- LAN share (Snapcast synced audio + ffmpeg HTTP fallback) ----
// The helper lives next to this file in the installed plugin dir.
// QML passes the absolute script path (HOME + suffix) since .pragma
// libraries have no access to Quickshell.env().
function lanScriptSuffix() {
  return "/.config/omarchy/plugins/local.cliamp-dock/lan-share.sh";
}
function lanCheckCmd(script) { return [script, "check"]; }
function lanStatusCmd(script) { return [script, "status", "--json"]; }
function lanShareStartCmd(script, stream, control, web, monitor) {
  var args = [script, "share-start", String(stream), String(control), String(web)];
  if (monitor !== undefined && monitor !== null && String(monitor) !== "")
    args.push(String(monitor));
  return args;
}
function lanShareStopCmd(script) { return [script, "share-stop"]; }
function lanSilentSinkCmd(script) { return [script, "silent-sink"]; }
function lanListenStartCmd(script, host, streamPort, webPort) {
  var args = [script, "listen-start", String(host), String(streamPort)];
  if (webPort !== undefined && webPort !== null && String(webPort) !== "")
    args.push(String(webPort));
  return args;
}
function lanListenStopCmd(script) { return [script, "listen-stop"]; }
function lanListenVolumeCmd(script, host, webPort, percent) {
  var args = [script, "listen-volume", String(host), String(webPort)];
  if (percent !== undefined && percent !== null && String(percent) !== "")
    args.push(String(percent));
  return args;
}
function lanHttpStartCmd(script, port) { return [script, "http-start", String(port)]; }
function lanHttpStopCmd(script) { return [script, "http-stop"]; }

function parseLanStatus(raw) {
  try {
    var o = JSON.parse(String(raw || "{}"));
    var lv = parseInt(o.listen_volume, 10);
    return {
      sharing: !!o.sharing, feeder: !!o.feeder, listening: !!o.listening,
      http: !!o.http, ip: String(o.ip || ""), clientHost: String(o.client_host || ""),
      clientPort: parseInt(o.client_port, 10) || 1704,
      httpPort: String(o.http_port || "8099"), monitor: String(o.monitor || ""),
      streamPort: parseInt(o.stream_port, 10) || 1704,
      controlPort: parseInt(o.control_port, 10) || 1705,
      webPort: parseInt(o.web_port, 10) || 1780,
      portsBusy: !!o.ports_busy, clientOk: !!o.client_ok,
      listenVolume: (isFinite(lv) && lv >= 0) ? Math.max(0, Math.min(100, lv)) : -1
    };
  } catch (e) { return null; }
}
function parseLanListenVolume(raw) {
  try {
    var o = JSON.parse(String(raw || "{}"));
    var v = parseInt(o.volume, 10);
    if (!isFinite(v)) return null;
    return Math.max(0, Math.min(100, v));
  } catch (e) { return null; }
}
function parseLanCheck(raw) {
  try {
    var o = JSON.parse(String(raw || "{}"));
    return { snapserver: !!o.snapserver, snapclient: !!o.snapclient, ffmpeg: !!o.ffmpeg };
  } catch (e) { return null; }
}
function parseLanSilentSink(raw) {
  try {
    var o = JSON.parse(String(raw || "{}"));
    if (!o.monitor) return null;
    return String(o.monitor);
  } catch (e) { return null; }
}
