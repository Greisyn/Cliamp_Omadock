pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "Cliamp.js" as Cliamp

// Cliamp Dock service. Owns cliamp state (polls `cliamp status --json`,
// dispatches `cliamp <cmd>` actions) and mounts one oShelf-style
// DockWindow per screen. Theme-aware via Color/Style tokens.
Item {
  id: root
  property var shell: null
  property var manifest: null
  readonly property string pluginId: (manifest && manifest.id) ? String(manifest.id) : "local.cliamp-dock"

  DockConfig { id: config }

  // ---------------- cliamp state ----------------
  property var cliamp: null
  property string cliampError: ""
  property bool cliampRunning: false

  function run(action, arg) {
    runner.command = Cliamp.runArgs(action, arg);
    if (runner.running) runner.running = false;
    runner.running = true;
  }

  Process {
    id: runner
    onExited: function(code) { Qt.callLater(pollNow); }
  }

  function pollNow() {
    if (poller.running) return;
    poller.command = Cliamp.statusCommand();
    poller.running = true;
  }

  Process {
    id: poller
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var st = Cliamp.parseStatus(this.text);
        if (st && st.ok !== false) {
          root.cliamp = st;
          root.cliampRunning = true;
          root.cliampError = "";
        } else {
          root.cliampRunning = false;
          root.cliampError = "cliamp not responding";
        }
        root.syncVis();
      }
    }
    onExited: function(code) { if (code !== 0 && !root.cliamp) root.cliampRunning = false; }
  }

  Timer {
    id: pollTimer
    interval: config.loaded ? config.pollMs : 1500
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.pollNow()
  }

  readonly property bool playing: Cliamp.isPlaying(root.cliamp)
  readonly property string trackTitle: root.cliampRunning ? Cliamp.trackTitle(root.cliamp) : "cliamp not running"
  readonly property string trackArtist: {
    if (!root.cliampRunning || !root.cliamp || !root.cliamp.track) return "";
    return String(root.cliamp.track.artist || "");
  }
  readonly property real trackProgress: root.cliamp ? Cliamp.progress(root.cliamp) : 0
  readonly property string posText: root.cliamp ? Cliamp.fmtTime(root.cliamp.position) : "0:00"
  readonly property string durText: root.cliamp ? Cliamp.fmtTime(root.cliamp.duration) : "0:00"

  // ---------------- live volume ----------------
  // Newer cliamp reports `volume` in status; older ones don't, so fall back
  // to the persisted optimistic value (which preview/commit keep updated).
  readonly property double volumeDb: (root.cliamp && isFinite(Number(root.cliamp.volume)))
    ? Number(root.cliamp.volume) : config.volumeDb
  function roundDb(v) { return Math.round(Number(v) * 2) / 2; }
  function previewVolume(v) { config.set("volumeDb", roundDb(v)); }
  function commitVolume(v) {
    var r = roundDb(v);
    config.set("volumeDb", r);
    run("volume", r);
  }

  // ---------------- visualizer stream ----------------
  // `cliamp visstream` emits NDJSON band frames; render a small mirror of
  // whatever visualizer cliamp has selected. Runs only while a card is open.
  readonly property int visN: 24
  property var visBands: []
  property string visMode: ""   // live mode name as reported by visstream frames
  property int visClients: 0
  property double visLastExit: 0

  function visRef(d) {
    visClients = Math.max(0, visClients + d);
    syncVis();
  }

  function visName() {
    if (root.visMode !== "") return root.visMode;
    return root.cliamp && root.cliamp.visualizer ? String(root.cliamp.visualizer) : "";
  }

  // Render family for the dock mirror, so selecting another visualizer
  // visibly changes the strip. Bands are mode-independent data; families
  // approximate each mode's look: bars (default), waveform line
  // (wave-family), center-mirrored bars, and dot-matrix.
  function visStyle() {
    var m = visName().toLowerCase();
    if (m === "wave" || m === "scope" || m === "terrain" || m === "heartbeat" || m === "pulse") return "wave";
    if (m === "mirror" || m === "stereo") return "mirror";
    if (m.indexOf("dot") >= 0 || m === "scatter" || m === "bubbles" || m === "firefly"
        || m === "mosaic" || m === "sand" || m === "sakura" || m === "firework"
        || m === "geyser" || m === "flame" || m === "matrix" || m === "binary"
        || m === "rain" || m === "retro" || m === "ascii" || m === "butterfly") return "dots";
    return "bars";
  }

  function syncVis() {
    var want = visClients > 0 && root.cliampRunning && visName() !== "" && visName() !== "None";
    var now = Date.now() / 1000;
    if (want && !visProc.running && (now - visLastExit) > 2) visProc.running = true;
    else if (!want && visProc.running) visProc.running = false;
    if (!want) {
      if (root.visBands.length) root.visBands = [];
      if (root.visMode !== "") root.visMode = "";
    }
  }

  function parseVisLine(line) {
    line = String(line || "").trim();
    if (!line) return;
    var vals = null;
    try {
      var o = JSON.parse(line);
      if (Array.isArray(o)) vals = o;
      else if (o && typeof o === "object") {
        if (typeof o.visualizer === "string" && o.visualizer !== "" && o.visualizer !== root.visMode)
          root.visMode = o.visualizer;
        var keys = ["bands", "values", "levels", "data", "magnitudes", "spectrum", "frame"];
        for (var ki = 0; ki < keys.length; ki++) {
          if (Array.isArray(o[keys[ki]])) { vals = o[keys[ki]]; break; }
        }
      }
    } catch (e) {
      var tmp = [];
      var parts = line.split(/[\s,;]+/);
      for (var pi = 0; pi < parts.length; pi++) {
        var n = Number(parts[pi]);
        if (isFinite(n)) tmp.push(n);
      }
      if (tmp.length >= 4) vals = tmp;
    }
    if (!vals || !vals.length) return;
    var nums = [];
    var peak = 0;
    for (var i = 0; i < vals.length; i++) {
      var v = Number(vals[i]);
      if (!isFinite(v)) continue;
      v = Math.abs(v);
      nums.push(v);
      if (v > peak) peak = v;
    }
    if (!nums.length) return;
    var scale = peak > 1.01 ? 1 / peak : 1;
    // resample to visN buckets by averaging
    var out = [];
    for (var b = 0; b < root.visN; b++) {
      var from = Math.floor(b * nums.length / root.visN);
      var to = Math.max(from + 1, Math.floor((b + 1) * nums.length / root.visN));
      var sum = 0;
      for (var j = from; j < to && j < nums.length; j++) sum += nums[j];
      out.push(Math.max(0, Math.min(1, (sum / (to - from)) * scale)));
    }
    root.visBands = out;
  }

  Process {
    id: visProc
    command: ["cliamp", "visstream", "--fps", "15"]
    stdout: SplitParser {
      onRead: function(data) { root.parseVisLine(data); }
    }
    onExited: function(code) {
      visLastExit = Date.now() / 1000;
      if (root.visBands.length) root.visBands = [];
      visRetry.restart();
    }
  }

  Timer {
    id: visRetry
    interval: 2500
    repeat: false
    onTriggered: root.syncVis()
  }

  // ---------------- LAN share (Snapcast synced, low-latency) ----------------
  // Role comes from config.lanRole: "server" casts only, "client" listens
  // only, "auto" does both. Ports are configurable (defaults: audio 1704,
  // control 1705, web 1780). Bedroom/office clients run
  // `snapclient -h <host> -p <control>` — or this dock's Listen mode.
  // HTTP fallback: ffmpeg MP3 on :lanHttpPort for any browser/player.
  readonly property string lanScript: Quickshell.env("HOME") + Cliamp.lanScriptSuffix()
  property bool lanSharing: false
  property bool lanFeeder: false
  property bool lanListening: false
  property bool lanHttp: false
  property string lanIp: ""
  property string lanClientHost: ""
  property int lanClientPort: 1705
  property int lanStreamPort: 1704
  property int lanControlPort: 1705
  property int lanWebPort: 1780
  property string lanMonitor: ""
  property string lanError: ""
  property bool lanHaveSnapserver: false
  property bool lanHaveSnapclient: false
  property bool lanHaveFfmpeg: false

  function lanRun(cmd, onDone) {
    lanRunner.command = cmd;
    lanRunner._cb = onDone || null;
    if (lanRunner.running) lanRunner.running = false;
    lanRunner.running = true;
  }
  Process {
    id: lanRunner
    property var _cb: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var cb = lanRunner._cb; lanRunner._cb = null;
        if (cb) cb(String(this.text || ""));
        Qt.callLater(root.lanPoll);
      }
    }
    onExited: function(code, status) {
      // Keep a specific error set by the stdout callback; only fill in
      // a generic one when the helper died silently (its "missing: …"
      // notes go to stderr, which this collector doesn't capture).
      if (code !== 0 && !lanRunner._cb && root.lanError === "")
        root.lanError = "lan helper exited " + code + " (need snapcast? yay -S snapcast)";
    }
  }
  function lanShareStart() {
    root.lanError = "";
    lanRun(Cliamp.lanShareStartCmd(root.lanScript,
      config.lanStreamPort, config.lanControlPort, config.lanWebPort), function(out) {
      if (out.toLowerCase().indexOf("missing") >= 0) root.lanError = out.trim();
    });
  }
  function lanShareStop() { root.lanError = ""; lanRun(Cliamp.lanShareStopCmd(root.lanScript)); }
  function lanListenStart(host) {
    root.lanError = "";
    var h = String(host || config.lanHost || "").trim();
    if (h === "") { root.lanError = "enter host IP first"; return; }
    config.set("lanHost", h);
    lanRun(Cliamp.lanListenStartCmd(root.lanScript, h, config.lanControlPort), function(out) {
      if (out.toLowerCase().indexOf("missing") >= 0) root.lanError = out.trim();
    });
  }
  function lanListenStop() { root.lanError = ""; lanRun(Cliamp.lanListenStopCmd(root.lanScript)); }
  function lanHttpStart() {
    root.lanError = "";
    lanRun(Cliamp.lanHttpStartCmd(root.lanScript, config.lanHttpPort), function(out) {
      if (out.toLowerCase().indexOf("missing") >= 0) root.lanError = out.trim();
    });
  }
  function lanHttpStop() { root.lanError = ""; lanRun(Cliamp.lanHttpStopCmd(root.lanScript)); }

  function lanPoll() {
    if (lanPoller.running) return;
    lanPoller.command = Cliamp.lanStatusCmd(root.lanScript);
    lanPoller.running = true;
  }
  Process {
    id: lanPoller
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var st = Cliamp.parseLanStatus(this.text);
        if (st) {
          root.lanSharing = st.sharing; root.lanFeeder = st.feeder;
          root.lanListening = st.listening; root.lanHttp = st.http;
          root.lanIp = st.ip; root.lanClientHost = st.clientHost;
          root.lanClientPort = st.clientPort; root.lanMonitor = st.monitor;
          root.lanStreamPort = st.streamPort; root.lanControlPort = st.controlPort;
          root.lanWebPort = st.webPort;
        }
      }
    }
  }
  Process {
    id: lanChecker
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var c = Cliamp.parseLanCheck(this.text);
        if (c) {
          root.lanHaveSnapserver = c.snapserver;
          root.lanHaveSnapclient = c.snapclient;
          root.lanHaveFfmpeg = c.ffmpeg;
        }
      }
    }
  }
  Timer {
    id: lanTimer
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      root.lanPoll();
      // refresh dependency flags each round (cheap, local exec)
      if (!lanChecker.running) {
        lanChecker.command = Cliamp.lanCheckCmd(root.lanScript);
        lanChecker.running = true;
      }
    }
  }

  // ---------------- per-screen windows (oShelf model) ----------------
  Variants {
    id: windows
    model: Quickshell.screens
    DockWindow {
      required property var modelData
      screen: modelData
      service: root
      cfg: config
    }
  }

  IpcHandler {
    target: root.pluginId
    function show(): string { for (var w of windows.instances) w.reveal(); return "shown"; }
    function hide(): string { for (var w of windows.instances) w.collapse(); return "hidden"; }
    function toggle(): string {
      var any = false;
      for (var w of windows.instances) if (w.expanded) { any = true; break; }
      if (any) { for (var w2 of windows.instances) w2.collapse(); return "hidden"; }
      for (var w3 of windows.instances) w3.reveal();
      return "shown";
    }
    function status(): string {
      var states = [];
      for (var w of windows.instances) states.push(!!w.expanded);
      return JSON.stringify({ playing: root.playing, title: root.trackTitle, expanded: states });
    }
    function share(): string { root.lanShareStart(); return "sharing"; }
    function unshare(): string { root.lanShareStop(); return "stopped"; }
    function lanstatus(): string {
      return JSON.stringify({ sharing: root.lanSharing, feeder: root.lanFeeder,
        listening: root.lanListening, http: root.lanHttp, ip: root.lanIp,
        clientHost: root.lanClientHost, clientPort: root.lanClientPort,
        monitor: root.lanMonitor, error: root.lanError,
        role: config.lanRole, streamPort: root.lanStreamPort,
        controlPort: root.lanControlPort, webPort: root.lanWebPort,
        httpPort: config.lanHttpPort });
    }
    function listen(host: string): string { root.lanListenStart(host); return "listening:" + host; }
    function unlisten(): string { root.lanListenStop(); return "stopped"; }
  }
}
