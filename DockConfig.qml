import QtQuick
import Quickshell
import Quickshell.Io

// Dock + cliamp preferences, oShelf-style. Both DockService and Panel
// instantiate this; the JSON file is the single source of truth.
// Shelf-chrome keys mirror oShelf's Preferences.js defaults/ranges.
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string settingsPath: home + "/.config/omarchy/local.cliamp-dock.json"

  // --- Shelf placement & size (oShelf model) ---
  property string placement: "right"   // left | right | bottom
  property int sideWidth: 360
  property int sideHeight: 480
  property int bottomWidth: 640
  property int bottomHeight: 400

  // --- Activation zone (edge handle) ---
  property int activationLength: 200
  property int activationDepth: 8
  property int activationPosition: 50  // percent along edge
  property bool steadyHover: true

  // --- Timing & motion ---
  property int openDelay: 350    // dwell on handle before reveal (ms)
  property int closeDelay: 700   // leave before collapse (ms)
  property int motionDuration: 260
  property bool reducedMotion: false

  // --- Player chrome ---
  property bool keepOpen: false  // pin: never auto-collapse (runtime-ish, persisted)
  property bool compact: false

  // --- Which player sections are visible ---
  property bool showProgress: true
  property bool showVolume: true
  property bool showToggles: true
  property bool showEq: false
  property bool showMeta: true
  property bool showVis: true

  // --- Cliamp runtime options (applied via `cliamp ...` on change) ---
  property double volumeDb: 0.0
  property string shuffle: "off"
  property string repeat: "All"
  property string mono: "off"
  property double speed: 1.0
  property string eqPreset: "Custom"
  property string visualizer: "ClassicPeak"
  property string cliTheme: ""
  property string audioDevice: ""
  property int pollMs: 1500

  // --- LAN share (Snapcast, synced low-latency) ---
  // lanRole: "auto" (share + listen), "server" (cast only),
  // "client" (listen only).
  property string lanRole: "auto"
  property string lanHost: ""     // listen target, e.g. 10.0.0.212
  property int lanStreamPort: 1704   // Snapcast audio
  property int lanControlPort: 1705  // Snapcast control (JSON-RPC, not for snapclient)
  property int lanWebPort: 1780      // Snapcast web/RPC
  property int lanHttpPort: 8099  // ffmpeg MP3 fallback port

  property bool loaded: false
  property string lastWritten: ""

  function ranges() {
    return {
      openDelay: [150, 1500], closeDelay: [250, 2500],
      activationLength: [80, 600], activationDepth: [4, 24],
      activationPosition: [10, 90], motionDuration: [120, 420],
      sideWidth: [300, 640], sideHeight: [460, 1000],
      bottomWidth: [560, 1400], bottomHeight: [400, 800]
    };
  }

  function defaults() {
    return {
      placement: "right",
      sideWidth: 360, sideHeight: 480, bottomWidth: 640, bottomHeight: 400,
      activationLength: 200, activationDepth: 8, activationPosition: 50,
      steadyHover: true,
      openDelay: 350, closeDelay: 700, motionDuration: 260, reducedMotion: false,
      keepOpen: false, compact: false,
      showProgress: true, showVolume: true, showToggles: true,
      showEq: false, showMeta: true, showVis: true,
      volumeDb: 0.0, shuffle: "off", repeat: "All", mono: "off",
      speed: 1.0, eqPreset: "Custom", visualizer: "ClassicPeak",
      cliTheme: "", audioDevice: "", pollMs: 1500,
      lanRole: "auto", lanHost: "", lanStreamPort: 1704,
      lanControlPort: 1705, lanWebPort: 1780, lanHttpPort: 8099
    };
  }

  function clampNum(v, range, fallback) {
    var n = Number(v);
    if (!isFinite(n)) n = fallback;
    return Math.round(Math.max(range[0], Math.min(range[1], n)));
  }

  function clampPort(v, fallback) {
    var n = parseInt(v, 10);
    if (!isFinite(n)) return fallback;
    return Math.max(1024, Math.min(65535, n));
  }

  function load(raw) {
    var d = root.defaults();
    var r = root.ranges();
    var p = {};
    try { p = JSON.parse(String(raw || "{}")); } catch (e) { p = {}; }
    var numKeys = ["sideWidth", "sideHeight", "bottomWidth", "bottomHeight",
      "activationLength", "activationDepth", "activationPosition",
      "openDelay", "closeDelay", "motionDuration"];
    for (var i = 0; i < numKeys.length; i++) {
      var k = numKeys[i];
      d[k] = root.clampNum(p[k], r[k], d[k]);
    }
    if (["left", "right", "bottom"].indexOf(p.placement) >= 0) d.placement = p.placement;
    ["steadyHover", "reducedMotion", "keepOpen", "compact",
     "showProgress", "showVolume", "showToggles", "showEq", "showMeta", "showVis"].forEach(function(key) {
      if (typeof p[key] === "boolean") d[key] = p[key];
    });

    root.placement = d.placement;
    root.sideWidth = d.sideWidth; root.sideHeight = d.sideHeight;
    root.bottomWidth = d.bottomWidth; root.bottomHeight = d.bottomHeight;
    root.activationLength = d.activationLength; root.activationDepth = d.activationDepth;
    root.activationPosition = d.activationPosition; root.steadyHover = d.steadyHover;
    root.openDelay = d.openDelay; root.closeDelay = d.closeDelay;
    root.motionDuration = d.motionDuration; root.reducedMotion = d.reducedMotion;
    root.keepOpen = d.keepOpen; root.compact = d.compact;
    root.showProgress = d.showProgress; root.showVolume = d.showVolume;
    root.showToggles = d.showToggles; root.showEq = d.showEq; root.showMeta = d.showMeta; root.showVis = d.showVis;
    root.volumeDb = Number(p.volumeDb) || 0;
    if (p.shuffle !== undefined) root.shuffle = String(p.shuffle);
    if (p.repeat !== undefined) root.repeat = String(p.repeat);
    if (p.mono !== undefined) root.mono = String(p.mono);
    root.speed = Number(p.speed) || 1.0;
    if (p.eqPreset) root.eqPreset = String(p.eqPreset);
    if (p.visualizer) root.visualizer = String(p.visualizer);
    if (p.cliTheme !== undefined) root.cliTheme = String(p.cliTheme);
    if (p.audioDevice !== undefined) root.audioDevice = String(p.audioDevice);
    root.pollMs = Math.max(500, Math.min(10000, parseInt(p.pollMs, 10) || 1500));
    if (p.lanHost !== undefined) root.lanHost = String(p.lanHost);
    if (["auto", "server", "client"].indexOf(p.lanRole) >= 0) root.lanRole = p.lanRole;
    root.lanStreamPort = clampPort(p.lanStreamPort, 1704);
    root.lanControlPort = clampPort(p.lanControlPort, 1705);
    root.lanWebPort = clampPort(p.lanWebPort, 1780);
    root.lanHttpPort = clampPort(p.lanHttpPort, 8099);
    root.loaded = true;
  }

  function snapshot() {
    return {
      placement: root.placement,
      sideWidth: root.sideWidth, sideHeight: root.sideHeight,
      bottomWidth: root.bottomWidth, bottomHeight: root.bottomHeight,
      activationLength: root.activationLength, activationDepth: root.activationDepth,
      activationPosition: root.activationPosition, steadyHover: root.steadyHover,
      openDelay: root.openDelay, closeDelay: root.closeDelay,
      motionDuration: root.motionDuration, reducedMotion: root.reducedMotion,
      keepOpen: root.keepOpen, compact: root.compact,
      showProgress: root.showProgress, showVolume: root.showVolume,
      showToggles: root.showToggles, showEq: root.showEq, showMeta: root.showMeta, showVis: root.showVis,
      volumeDb: root.volumeDb, shuffle: root.shuffle, repeat: root.repeat,
      mono: root.mono, speed: root.speed, eqPreset: root.eqPreset,
      visualizer: root.visualizer, cliTheme: root.cliTheme,
      audioDevice: root.audioDevice, pollMs: root.pollMs,
      lanRole: root.lanRole, lanHost: root.lanHost,
      lanStreamPort: root.lanStreamPort, lanControlPort: root.lanControlPort,
      lanWebPort: root.lanWebPort, lanHttpPort: root.lanHttpPort
    };
  }

  function save() {
    if (!root.loaded) return;
    var text = JSON.stringify(root.snapshot(), null, 2) + "\n";
    root.lastWritten = text;
    settingsFile.setText(text);
  }

  function set(key, value) {
    if (root[key] === value) return;
    root[key] = value;
    saveTimer.restart();
  }

  function resetAll() {
    var d = root.defaults();
    for (var k in d) root[k] = d[k];
    saveTimer.restart();
  }

  Timer {
    id: saveTimer
    interval: 250
    repeat: false
    onTriggered: root.save()
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: settingsFile.reload()
    onLoaded: {
      if (text() === root.lastWritten && root.loaded) return;
      root.load(text());
    }
    onLoadFailed: root.load("")
  }

  Component.onCompleted: settingsFile.reload()
}
