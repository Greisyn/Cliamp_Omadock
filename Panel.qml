import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Cliamp.js" as Cliamp

// Settings panel for Cliamp Dock. Opened from the bar icon or the dock
// card's header gear button.
// All colors come from Color.* / Style.* so omarchy themes repaint it live.
Panel {
  id: root
  moduleName: "local.cliamp-dock"
  ipcTarget: "local.cliamp-dock-panel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  DockConfig { id: config }

  readonly property var dockService: bar && bar.shell ? bar.shell.serviceFor("local.cliamp-dock") : null
  function applyCliamp(action, arg) {
    if (root.dockService) root.dockService.run(action, arg);
    else { directRunner.command = Cliamp.runArgs(action, arg); directRunner.running = true; }
  }
  Process { id: directRunner }

  function open() { root.controller.show(); }
  function toggle() { root.opened ? root.close() : root.open(); }

  // Touchpad-friendly paging (no wheel needed): scrolls the settings
  // Flickable a full page, clamped to its bounds. No-op when all content
  // fits.
  function pagePanel(dir) {
    var maxY = Math.max(0, panelScroller.contentHeight - panelScroller.height);
    panelScroller.contentY = Math.max(0, Math.min(maxY, panelScroller.contentY + dir * panelScroller.height));
  }

  component RowLabel: Text {
    textFormat: Text.PlainText
    color: root.contentForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.body
  }

  component SectionHeader: Text {
    textFormat: Text.PlainText
    color: Color.accent
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.body
    font.bold: true
  }

  component SwitchRow: Row {
    property string label: ""
    property bool checked: false
    signal flipped()
    width: parent ? parent.width : 0
    spacing: Style.spacing.lg
    // Keyboard-operable: Tab lands here, Space/Enter flips, and the label
    // tints accent while focused so keyboard users can see where they are.
    activeFocusOnTab: true
    Keys.onSpacePressed: flipped()
    Keys.onReturnPressed: flipped()
    RowLabel { text: parent.label; width: parent.width - sw.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight; color: parent.activeFocus ? Color.accent : root.contentForeground }
    ToggleSwitch {
      id: sw
      checked: parent.checked
      foreground: root.contentForeground
      accent: Color.accent
      anchors.verticalCenter: parent.verticalCenter
      onToggled: parent.flipped()
    }
  }

  KeyboardPanel {
    anchorItem: root.anchorItem
    // Owner MUST be this Panel (not the bar widget): KeyboardPanel.close()
    // calls owner.close() on outside-click dismiss, and Panel.close() routes
    // through the controller so the `open: root.opened` binding stays intact.
    // Pointing owner at the BarWidget (which has no close()) made dismiss
    // assign open=false directly, breaking the binding — the panel then
    // never reopened until the shell restarted.
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    // Take keyboard focus on open so PageUp/PageDown work immediately
    // (critical for wheel-less pointers) and Tab starts inside the panel.
    focusTarget: panelScroller
    contentWidth: fittedContentWidth(Style.space(440))
    contentHeight: fittedContentHeight(contentColumn.implicitHeight)

    // PageUp/PageDown scroll a page at a time so lower sections stay
    // reachable on short screens. Single-line inputs ignore these keys,
    // so they bubble up here from anywhere in the panel.
    Keys.onPressed: function(event) {
      if (event.key !== Qt.Key_PageDown && event.key !== Qt.Key_PageUp) return;
      root.pagePanel(event.key === Qt.Key_PageDown ? 1 : -1);
      event.accepted = true;
    }

    Flickable {
      id: panelScroller
      anchors.fill: parent
      focus: true
      contentWidth: width
      contentHeight: contentColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.spacing.xl

        // ---- Player visibility (oShelf model: dwell on the edge handle to reveal) ----
        SectionHeader { text: "Player" }
        Row {
          width: parent.width; spacing: Style.spacing.sm
          WidgetButton { text: "Show"; onPressed: function() { Quickshell.execDetached(["omarchy-shell", "local.cliamp-dock", "show"]); } }
          WidgetButton { text: "Hide"; onPressed: function() { Quickshell.execDetached(["omarchy-shell", "local.cliamp-dock", "hide"]); } }
          WidgetButton { text: "Toggle"; onPressed: function() { Quickshell.execDetached(["omarchy-shell", "local.cliamp-dock", "toggle"]); } }
        }
        SwitchRow { label: "Pin open (no auto-collapse)"; checked: config.keepOpen; onFlipped: config.set("keepOpen", !config.keepOpen) }

        // ---- LAN Share — synced low-latency multiroom (Snapcast) ----
        // Kept near the top so it is reachable without scrolling on short
        // screens / wheel-less pointers. Role gates the controls:
        // server = cast only, client = listen only.
        SectionHeader { text: "LAN Share (synced rooms)" }
        Row {
          width: parent.width; spacing: Style.spacing.sm
          Repeater {
            model: ["auto", "server", "client"]
            delegate: WidgetButton {
              text: modelData === "auto" ? "Auto" : (modelData === "server" ? "Server" : "Client")
              active: config.lanRole === modelData
              onPressed: function() { config.set("lanRole", modelData); }
            }
          }
        }
        RowLabel {
          width: parent.width; wrapMode: Text.WordWrap
          text: {
            if (!root.dockService) return "Start cliamp dock service to manage LAN share.";
            var s = root.dockService;
            if (s.lanSharing) return "SHARING from " + (s.lanIp !== "" ? s.lanIp : "this machine")
              + " :" + s.lanStreamPort + "/:" + s.lanControlPort
              + " — clients: snapclient -h " + (s.lanIp !== "" ? s.lanIp : "<this-ip>") + " -p " + s.lanStreamPort;
            if (s.lanListening) return "LISTENING to " + (s.lanClientHost !== "" ? s.lanClientHost : config.lanHost)
              + ":" + s.lanClientPort;
            if (s.lanHttp) return "HTTP fallback live on :" + config.lanHttpPort;
            if (config.lanRole === "server") return "Server mode — share this room's audio over LAN.";
            if (config.lanRole === "client") return "Client mode — listen to a sharer, no casting.";
            return "Off — share this room's audio, or listen to another.";
          }
        }
        // Server-side controls (hidden in client mode)
        Row {
          width: parent.width; spacing: Style.spacing.sm
          visible: config.lanRole !== "client"
          WidgetButton {
            text: (root.dockService && root.dockService.lanSharing) ? "Stop share" : "Share this room"
            onPressed: function() {
              if (!root.dockService) return;
              if (root.dockService.lanSharing) root.dockService.lanShareStop();
              else root.dockService.lanShareStart();
            }
          }
          WidgetButton {
            text: (root.dockService && root.dockService.lanHttp) ? "Stop HTTP" : "HTTP fallback"
            onPressed: function() {
              if (!root.dockService) return;
              if (root.dockService.lanHttp) root.dockService.lanHttpStop();
              else root.dockService.lanHttpStart();
            }
          }
        }
        // Share source (hidden in client mode). Empty = default sink.
        // Silence/room toggle routes cliamp between the null sink and the
        // speakers; the stream keeps full audio either way.
        Row {
          width: parent.width; spacing: Style.spacing.sm
          visible: config.lanRole !== "client"
          Column { width: parent.width - silBtn.width - parent.spacing; spacing: 2
            RowLabel { text: "Share monitor (empty = default sink)"; width: parent.width }
            TextField {
              width: parent.width; text: config.shareMonitor; placeholderText: "default sink monitor";
              foreground: root.contentForeground; font.family: root.contentFontFamily;
              onAccepted: { config.set("shareMonitor", text.trim()); }
            }
          }
          WidgetButton {
            id: silBtn
            anchors.verticalCenter: parent.verticalCenter
            text: (root.dockService && root.dockService.lanRoomSilent) ? "Room sound" : "Silence"
            active: root.dockService ? root.dockService.lanRoomSilent : false
            onPressed: function() { if (root.dockService) root.dockService.toggleSilentRoom(); }
          }
        }
        // Client-side controls (hidden in server mode)
        Row {
          width: parent.width; spacing: Style.spacing.sm
          visible: config.lanRole !== "server"
          WidgetButton {
            text: (root.dockService && root.dockService.lanListening) ? "Stop listen" : "Listen"
            onPressed: function() {
              if (!root.dockService) return;
              if (root.dockService.lanListening) root.dockService.lanListenStop();
              else root.dockService.lanListenStart(config.lanHost);
            }
          }
        }
        Row {
          width: parent.width; spacing: Style.spacing.sm
          visible: config.lanRole !== "server"
          Column { width: (parent.width - parent.spacing) / 2; spacing: 2
            RowLabel { text: "Listen host (sharer IP)"; width: parent.width }
            TextField {
              width: parent.width; text: config.lanHost; placeholderText: "10.0.0.212";
              foreground: root.contentForeground; font.family: root.contentFontFamily;
              onAccepted: { config.set("lanHost", text); }
            }
          }
          Column { width: (parent.width - parent.spacing) / 2; spacing: 2
            RowLabel { text: "Stream port (must match sharer)"; width: parent.width }
            TextField {
              width: parent.width; text: String(config.lanStreamPort); placeholderText: "1704";
              foreground: root.contentForeground; font.family: root.contentFontFamily;
              onAccepted: { var p = parseInt(text, 10); if (isFinite(p)) config.set("lanStreamPort", Math.max(1024, Math.min(65535, p))); }
            }
          }
        }
        // Independent listen volume (this dock's own loudness on the
        // sharer — server player volume and other listeners untouched).
        Row {
          width: parent.width; spacing: Style.spacing.sm
          visible: config.lanRole !== "server" && root.dockService && root.dockService.lanListening
          WidgetButton { width: 40; text: "-"; onPressed: function() { if (root.dockService) root.dockService.lanListenVolumeSet(root.dockService.listenVolumeShown - 5); } }
          Column { width: parent.width - 2 * 40 - parent.spacing * 2; spacing: 2
            RowLabel { text: "Listen volume (" + (root.dockService ? root.dockService.listenVolumeShown : 100) + "%)"; width: parent.width }
            PanelSlider {
              width: parent.width
              minimum: 0; maximum: 100; step: 1
              value: root.dockService ? root.dockService.listenVolumeShown : 100
              onMoved: function(v) { if (root.dockService) root.dockService.lanListenVolumePreview = Math.max(0, Math.min(100, Math.round(v))); }
              onReleased: function(v) { if (root.dockService) root.dockService.lanListenVolumeSet(v); }
            }
          }
          WidgetButton { width: 40; text: "+"; onPressed: function() { if (root.dockService) root.dockService.lanListenVolumeSet(root.dockService.listenVolumeShown + 5); } }
        }
        // Port tuning (server side; hidden in client mode)
        SectionHeader { text: "Ports"; visible: config.lanRole !== "client" }
        Row {
          width: parent.width; spacing: Style.spacing.sm
          visible: config.lanRole !== "client"
          Column { width: (parent.width - parent.spacing * 3) / 4; spacing: 2
            RowLabel { text: "Audio"; width: parent.width }
            TextField {
              width: parent.width; text: String(config.lanStreamPort); placeholderText: "1704";
              foreground: root.contentForeground; font.family: root.contentFontFamily;
              onAccepted: { var p = parseInt(text, 10); if (isFinite(p)) config.set("lanStreamPort", Math.max(1024, Math.min(65535, p))); }
            }
          }
          Column { width: (parent.width - parent.spacing * 3) / 4; spacing: 2
            RowLabel { text: "Control"; width: parent.width }
            TextField {
              width: parent.width; text: String(config.lanControlPort); placeholderText: "1705";
              foreground: root.contentForeground; font.family: root.contentFontFamily;
              onAccepted: { var p = parseInt(text, 10); if (isFinite(p)) config.set("lanControlPort", Math.max(1024, Math.min(65535, p))); }
            }
          }
          Column { width: (parent.width - parent.spacing * 3) / 4; spacing: 2
            RowLabel { text: "Web"; width: parent.width }
            TextField {
              width: parent.width; text: String(config.lanWebPort); placeholderText: "1780";
              foreground: root.contentForeground; font.family: root.contentFontFamily;
              onAccepted: { var p = parseInt(text, 10); if (isFinite(p)) config.set("lanWebPort", Math.max(1024, Math.min(65535, p))); }
            }
          }
          Column { width: (parent.width - parent.spacing * 3) / 4; spacing: 2
            RowLabel { text: "HTTP mp3"; width: parent.width }
            TextField {
              width: parent.width; text: String(config.lanHttpPort); placeholderText: "8099";
              foreground: root.contentForeground; font.family: root.contentFontFamily;
              onAccepted: { var p = parseInt(text, 10); if (isFinite(p)) config.set("lanHttpPort", Math.max(1024, Math.min(65535, p))); }
            }
          }
        }
        RowLabel {
          width: parent.width; wrapMode: Text.WordWrap
          color: Util.alpha(root.contentForeground, 0.7)
          font.pixelSize: Style.font.caption
          text: {
            var miss = [];
            if (root.dockService) {
              if (!root.dockService.lanHaveSnapserver) miss.push("snapserver");
              if (!root.dockService.lanHaveSnapclient) miss.push("snapclient");
              if (!root.dockService.lanHaveFfmpeg) miss.push("ffmpeg");
            }
            var t = "Synced Snapcast: install on sharer + listeners: yay -S snapcast. ";
            t += "Open TCP " + config.lanStreamPort + "/" + config.lanControlPort + "/" + config.lanWebPort + " on the sharer. ";
            t += "Bedroom cmd: snapclient -h " + (root.dockService && root.dockService.lanIp !== "" ? root.dockService.lanIp : "10.0.0.212") + " -p " + config.lanStreamPort + ". ";
            t += "Ports apply on next Share start; listeners must use the sharer's stream port. ";
            t += "HTTP fallback plays in any browser at http://" + (root.dockService && root.dockService.lanIp !== "" ? root.dockService.lanIp : "<sharer-ip>") + ":" + config.lanHttpPort + "/cliamp.mp3 (~2s delay).";
            if (miss.length > 0) t += " Missing here: " + miss.join(", ") + ".";
            if (root.dockService && root.dockService.lanError !== "") t += " Err: " + root.dockService.lanError;
            return t;
          }
        }

        SectionHeader { text: "Placement & size" }
        Row {
          width: parent.width; spacing: Style.spacing.sm
          Repeater {
            model: ["left", "right", "bottom"]
            delegate: WidgetButton { text: modelData; active: config.placement === modelData; onPressed: function() { config.set("placement", modelData); } }
          }
        }
        Row {
          width: parent.width; spacing: Style.spacing.lg
          Column { width: (parent.width - parent.spacing) / 2; spacing: 2
            RowLabel { text: config.placement === "bottom" ? "Tray width (" + config.bottomWidth + ")" : "Side width (" + config.sideWidth + ")"; width: parent.width }
            PanelSlider {
              width: parent.width
              minimum: config.placement === "bottom" ? 560 : 300
              maximum: config.placement === "bottom" ? 1400 : 640
              step: 10
              value: config.placement === "bottom" ? config.bottomWidth : config.sideWidth
              onMoved: function(v) { config.set(config.placement === "bottom" ? "bottomWidth" : "sideWidth", Math.round(v)); }
            }
          }
          Column { width: (parent.width - parent.spacing) / 2; spacing: 2
            RowLabel { text: config.placement === "bottom" ? "Tray height (" + config.bottomHeight + ")" : "Side height (" + config.sideHeight + ")"; width: parent.width }
            PanelSlider {
              width: parent.width
              minimum: config.placement === "bottom" ? 400 : 460
              maximum: config.placement === "bottom" ? 800 : 1000
              step: 10
              value: config.placement === "bottom" ? config.bottomHeight : config.sideHeight
              onMoved: function(v) { config.set(config.placement === "bottom" ? "bottomHeight" : "sideHeight", Math.round(v)); }
            }
          }
        }
        SwitchRow { label: "Compact mode"; checked: config.compact; onFlipped: config.set("compact", !config.compact) }

        // ---- Activation & motion (mirrors oShelf) ----
        SectionHeader { text: "Edge handle & motion" }
        Row {
          width: parent.width; spacing: Style.spacing.lg
          Column { width: (parent.width - parent.spacing) / 2; spacing: 2
            RowLabel { text: "Hover to open (" + config.openDelay + "ms)"; width: parent.width }
            PanelSlider { width: parent.width; minimum: 150; maximum: 1500; step: 10; value: config.openDelay; onMoved: function(v) { config.set("openDelay", Math.round(v)); } }
          }
          Column { width: (parent.width - parent.spacing) / 2; spacing: 2
            RowLabel { text: "Leave to close (" + config.closeDelay + "ms)"; width: parent.width }
            PanelSlider { width: parent.width; minimum: 250; maximum: 2500; step: 10; value: config.closeDelay; onMoved: function(v) { config.set("closeDelay", Math.round(v)); } }
          }
        }
        Row {
          width: parent.width; spacing: Style.spacing.lg
          Column { width: (parent.width - parent.spacing) / 2; spacing: 2
            RowLabel { text: "Handle length (" + config.activationLength + ")"; width: parent.width }
            PanelSlider { width: parent.width; minimum: 80; maximum: 600; step: 5; value: config.activationLength; onMoved: function(v) { config.set("activationLength", Math.round(v)); } }
          }
          Column { width: (parent.width - parent.spacing) / 2; spacing: 2
            RowLabel { text: "Handle depth (" + config.activationDepth + ")"; width: parent.width }
            PanelSlider { width: parent.width; minimum: 4; maximum: 24; step: 1; value: config.activationDepth; onMoved: function(v) { config.set("activationDepth", Math.round(v)); } }
          }
        }
        RowLabel { text: "Handle position along edge (" + config.activationPosition + "%)"; width: parent.width }
        PanelSlider { width: parent.width; minimum: 10; maximum: 90; step: 1; value: config.activationPosition; onMoved: function(v) { config.set("activationPosition", Math.round(v)); } }
        RowLabel { text: "Motion duration (" + config.motionDuration + "ms)"; width: parent.width }
        PanelSlider { width: parent.width; minimum: 120; maximum: 420; step: 5; value: config.motionDuration; onMoved: function(v) { config.set("motionDuration", Math.round(v)); } }
        SwitchRow { label: "Steady hover (moving restarts open delay)"; checked: config.steadyHover; onFlipped: config.set("steadyHover", !config.steadyHover) }
        SwitchRow { label: "Reduced motion"; checked: config.reducedMotion; onFlipped: config.set("reducedMotion", !config.reducedMotion) }

        // ---- Visible sections ----
        SectionHeader { text: "Dock sections (hide options)" }
        SwitchRow { label: "Progress / seek bar"; checked: config.showProgress; onFlipped: config.set("showProgress", !config.showProgress) }
        SwitchRow { label: "Volume slider"; checked: config.showVolume; onFlipped: config.set("showVolume", !config.showVolume) }
        SwitchRow { label: "Shuffle / repeat / mono"; checked: config.showToggles; onFlipped: config.set("showToggles", !config.showToggles) }
        SwitchRow { label: "EQ row"; checked: config.showEq; onFlipped: config.set("showEq", !config.showEq) }
        SwitchRow { label: "Visualizer / speed row"; checked: config.showMeta; onFlipped: config.set("showMeta", !config.showMeta) }
        SwitchRow { label: "Live visualizer bars"; checked: config.showVis; onFlipped: config.set("showVis", !config.showVis) }

        // ---- Cliamp adjustable options ----
        SectionHeader { text: "Cliamp options" }
        RowLabel {
          width: parent.width; wrapMode: Text.WordWrap
          text: "Now: " + (root.dockService && root.dockService.cliamp ? Cliamp.trackTitle(root.dockService.cliamp) : "…")
        }
        RowLabel { text: "Volume dB (" + config.volumeDb + ") — drag, release to apply"; width: parent.width }
        PanelSlider {
          width: parent.width; minimum: -30; maximum: 6; step: 0.5
          value: root.dockService ? root.dockService.volumeDb : config.volumeDb
          onMoved: function(v) { if (root.dockService) root.dockService.previewVolume(v); else config.set("volumeDb", Math.round(v * 2) / 2); }
          onReleased: function(v) { if (root.dockService) root.dockService.commitVolume(v); }
        }
        Row {
          width: parent.width; spacing: Style.spacing.sm
          WidgetButton { text: "Shuffle: " + Cliamp.shuffleText(root.dockService ? root.dockService.cliamp : null); onPressed: function() { root.applyCliamp("shuffle", "toggle"); } }
          WidgetButton { text: "Repeat: " + Cliamp.repeatText(root.dockService ? root.dockService.cliamp : null); onPressed: function() { root.applyCliamp("repeat", "cycle"); } }
          WidgetButton { text: "Mono: " + Cliamp.monoText(root.dockService ? root.dockService.cliamp : null); onPressed: function() { root.applyCliamp("mono", "toggle"); } }
        }
        RowLabel { text: "Speed (" + (root.dockService && root.dockService.cliamp && root.dockService.cliamp.speed ? root.dockService.cliamp.speed : config.speed) + "x)"; width: parent.width }
        PanelSlider {
          width: parent.width; minimum: 0.25; maximum: 2.0; step: 0.05
          value: root.dockService && root.dockService.cliamp && root.dockService.cliamp.speed ? Number(root.dockService.cliamp.speed) : config.speed
          onReleased: function(v) { root.applyCliamp("speed", Math.round(v * 100) / 100); config.set("speed", Math.round(v * 100) / 100); }
        }

        RowLabel { text: "EQ preset"; width: parent.width }
        Dropdown {
          width: parent.width
          value: root.dockService && root.dockService.cliamp && root.dockService.cliamp.eq_preset ? String(root.dockService.cliamp.eq_preset) : config.eqPreset
          options: Cliamp.eqPresets()
          onChanged: function(v) { root.applyCliamp("eqPreset", v); config.set("eqPreset", v); }
        }
        RowLabel { text: "Visualizer"; width: parent.width }
        Dropdown {
          width: parent.width
          value: root.dockService && root.dockService.cliamp && root.dockService.cliamp.visualizer ? String(root.dockService.cliamp.visualizer) : config.visualizer
          options: Cliamp.visNames()
          onChanged: function(v) { root.applyCliamp("vis", v); config.set("visualizer", v); }
        }
        RowLabel { text: "Cliamp TUI theme (applies to cliamp app)"; width: parent.width }
        Dropdown {
          width: parent.width
          value: config.cliTheme
          options: ["(none)"].concat(Cliamp.themeNames())
          onChanged: function(v) { var name = v === "(none)" ? "" : v; config.set("cliTheme", name); if (name !== "") root.applyCliamp("theme", name); }
        }
        Row {
          width: parent.width; spacing: Style.spacing.sm
          Column { width: (parent.width - parent.spacing) / 2; spacing: 2
            RowLabel { text: "Audio device"; width: parent.width }
            TextField { width: parent.width; text: config.audioDevice; placeholderText: "device name / list"; foreground: root.contentForeground; font.family: root.contentFontFamily; onAccepted: { if (text !== "") root.applyCliamp("device", text); config.set("audioDevice", text); } }
          }
          Column { width: (parent.width - parent.spacing) / 2; spacing: 2
            RowLabel { text: "Load playlist"; width: parent.width }
            TextField { width: parent.width; placeholderText: "playlist name"; foreground: root.contentForeground; font.family: root.contentFontFamily; onAccepted: { if (text !== "") root.applyCliamp("playlist", text); } }
          }
        }
        RowLabel {
          width: parent.width; wrapMode: Text.WordWrap
          color: Util.alpha(root.contentForeground, 0.7)
          font.pixelSize: Style.font.caption
          text: "Seek/volume/speed apply live. EQ bands 0–9, device list, and providers stay in `cliamp` CLI (eq --band, device list). Poll: " + (config.pollMs) + "ms."
        }


        Row {
          width: parent.width; spacing: Style.spacing.sm
          WidgetButton { text: "Reset dock settings"; onPressed: function() { config.resetAll(); } }
          WidgetButton { text: "Close"; onPressed: function() { root.close(); } }
          Text {
            textFormat: Text.PlainText
            text: "v0.3.0"
            color: Util.alpha(root.contentForeground, 0.45)
            font.family: root.contentFontFamily; font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }

    // Sticky page buttons: same paging as PageUp/PageDown for touchpads
    // and other wheel-less pointers. Hidden when everything fits.
    Column {
      anchors { right: parent.right; bottom: parent.bottom; margins: 8 }
      spacing: 6
      z: 10
      visible: panelScroller.contentHeight > panelScroller.height
      WidgetButton { text: "PgUp"; tooltipText: "Scroll up a page"; onPressed: function() { root.pagePanel(-1); } }
      WidgetButton { text: "PgDn"; tooltipText: "Scroll down a page"; onPressed: function() { root.pagePanel(1); } }
    }
  }
}
