pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Cliamp.js" as Cliamp

// Per-screen floating player. Mirrors oShelf's ShelfWindow behavior:
// a slim edge handle with dwell-to-reveal, a collapsing card surface,
// and leave-to-close — only the handle and the open card take input.
PanelWindow {
  id: root
  required property var service
  required property var cfg

  readonly property string placement: cfg.placement
  readonly property bool horizontal: placement === "bottom"
  readonly property bool reducedMotion: cfg.reducedMotion
  property bool expanded: false
  property real openness: expanded ? 1 : 0
  property real dwellProgress: 0
  property point hoverOrigin: Qt.point(0, 0)
  readonly property bool engaged: edgeHover.hovered || panelHover.hovered || cfg.keepOpen
  readonly property real zoneLength: Math.min(cfg.activationLength, (horizontal ? width : height) * 0.8)

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusiveZone: 0
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "cliamp-dock"
  WlrLayershell.keyboardFocus: expanded ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
  // Only these regions receive input; the rest of the desktop passes through.
  mask: Region {
    item: edge
    Region {
      x: surface.x; y: surface.y
      width: root.expanded ? surface.width : 0; height: surface.height
      radius: surface.radius
    }
  }

  Behavior on openness {
    NumberAnimation {
      duration: root.reducedMotion ? 0 : root.expanded ? cfg.motionDuration : Math.round(cfg.motionDuration * 0.75)
      easing.type: Easing.OutCubic
    }
  }

  function reveal() {
    closeTimer.stop(); stopDwell();
    if (expanded) return;
    expanded = true;
    content.forceActiveFocus();
  }
  function collapse() {
    if (cfg.keepOpen) return;
    expanded = false;
    content.forceActiveFocus();
    stopDwell();
  }
  function stopDwell() { hoverTimer.stop(); dwell.stop(); dwellProgress = 0; }
  function startDwell() {
    if (expanded || !edgeHover.hovered) return;
    stopDwell(); hoverOrigin = edgeHover.point.position;
    hoverTimer.restart(); dwell.restart();
  }
  function moveHover(point) {
    if (expanded || !cfg.steadyHover || !edgeHover.hovered) return;
    var dx = point.x - hoverOrigin.x, dy = point.y - hoverOrigin.y;
    if (dx * dx + dy * dy > 36) startDwell();
  }

  onEngagedChanged: { if (engaged) closeTimer.stop(); else if (expanded) closeTimer.restart(); }
  onExpandedChanged: service.visRef(expanded ? 1 : -1)

  Timer { id: closeTimer; interval: cfg.closeDelay; onTriggered: { if (!root.engaged) root.collapse(); } }
  Timer { id: hoverTimer; interval: cfg.openDelay; onTriggered: { if (edgeHover.hovered) root.reveal(); } }
  NumberAnimation { id: dwell; target: root; property: "dwellProgress"; from: 0; to: 1; duration: cfg.openDelay }

  // ---- edge handle ----
  Item {
    id: edge
    objectName: "cliamp-dock-edge"
    width: root.horizontal ? root.zoneLength : cfg.activationDepth
    height: root.horizontal ? cfg.activationDepth : root.zoneLength
    x: root.horizontal ? (root.width - width) * cfg.activationPosition / 100 : root.placement === "left" ? 0 : root.width - width
    y: root.horizontal ? root.height - height : (root.height - height) * cfg.activationPosition / 100
    HoverHandler {
      id: edgeHover
      onHoveredChanged: { if (hovered) root.startDwell(); else root.stopDwell(); }
      onPointChanged: root.moveHover(point.position)
    }
    Rectangle {
      anchors.centerIn: parent
      width: root.horizontal ? (edgeHover.hovered ? 76 : 44) : 3
      height: root.horizontal ? 3 : (edgeHover.hovered ? 76 : 44)
      radius: 2
      color: Util.alpha(service.playing ? Color.accent : Color.foreground, edgeHover.hovered ? 0.45 : service.playing ? 0.4 : 0.13)
      opacity: 1 - root.openness
      Behavior on width { NumberAnimation { duration: root.reducedMotion ? 0 : 180; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: root.reducedMotion ? 0 : 180; easing.type: Easing.OutCubic } }
      Rectangle {
        anchors { bottom: parent.bottom; left: parent.left }
        width: root.horizontal ? parent.width * root.dwellProgress : parent.width
        height: root.horizontal ? parent.height : parent.height * root.dwellProgress
        radius: 2; color: Color.accent
      }
    }
    TapHandler { onTapped: root.reveal() }
  }

  // ---- player card ----
  Rectangle {
    id: surface
    objectName: "cliamp-dock-surface"
    readonly property real inset: 16
    readonly property real openX: root.placement === "left" ? inset : root.horizontal ? (root.width - width) / 2 : root.width - width - inset
    readonly property real openY: root.horizontal ? root.height - height - inset : Math.max(inset, Math.min(root.height - height - inset, (root.height - height) * cfg.activationPosition / 100))
    width: Math.min(root.width - 32, root.horizontal ? cfg.bottomWidth : cfg.sideWidth)
    height: Math.min(root.height - 32, root.horizontal ? cfg.bottomHeight : cfg.sideHeight)
    x: openX + (root.reducedMotion ? 0 : (1 - root.openness) * (root.placement === "left" ? -32 : root.horizontal ? 0 : 32))
    y: openY + (root.reducedMotion || !root.horizontal ? 0 : (1 - root.openness) * 32)
    scale: root.reducedMotion ? 1 : 0.97 + root.openness * 0.03
    opacity: root.openness
    visible: root.openness > 0
    radius: 24
    color: Color.background
    border.width: 1
    border.color: Util.alpha(Color.foreground, 0.15)
    layer.enabled: visible
    layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "#000000"; shadowOpacity: 0.35; shadowBlur: 0.65; shadowVerticalOffset: 8 }
    HoverHandler { id: panelHover }
    // accent wash
    Rectangle {
      anchors { top: parent.top; left: parent.left; right: parent.right; margins: 1 }
      height: Math.min(parent.height, 160); radius: 23
      gradient: Gradient {
        GradientStop { position: 0; color: Util.alpha(Color.accent, 0.085) }
        GradientStop { position: 1; color: "transparent" }
      }
    }
    FocusScope {
      id: content
      anchors.fill: parent
      Keys.onEscapePressed: root.collapse()

      // header icon tile
      Rectangle {
        x: 22; y: 22; width: 40; height: 40; radius: 13
        color: Util.alpha(Color.accent, 0.12)
        border.width: 1; border.color: Util.alpha(Color.accent, 0.17)
        DockGlyph { anchors.centerIn: parent; width: 23; height: 23; kind: "note"; ink: Color.accent }
      }
      Text {
        x: 74; y: 20
        text: "Cliamp"
        color: Color.foreground
        font.family: Style.fontFamily; font.pixelSize: 23; font.weight: Font.DemiBold; font.letterSpacing: -0.6
      }
      Text {
        x: 74; y: 49
        width: parent.width - 190
        text: service.cliampRunning ? (service.trackArtist !== "" ? service.trackArtist : (service.playing ? "Now playing" : "Paused")) : "Player not running"
        elide: Text.ElideRight
        color: Util.alpha(Color.foreground, 0.5)
        font.family: Style.fontFamily; font.pixelSize: 10
      }
      Row {
        anchors.right: parent.right; anchors.rightMargin: 16; y: 23; spacing: 2
        DockAction { icon: "pin"; hint: cfg.keepOpen ? "Unpin (auto-collapse)" : "Pin open"; selected: cfg.keepOpen; onTriggered: cfg.set("keepOpen", !cfg.keepOpen) }
        DockAction { icon: "close"; hint: "Close player"; onTriggered: root.collapse() }
      }

      // track block
      // scrollable body: header/footer stay pinned, everything else scrolls
      Flickable {
        id: scroller
        x: 22; y: 84; width: parent.width - 44; height: parent.height - 84 - 70
        contentWidth: width
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: body
          width: scroller.width
          spacing: 10

          Text {
            width: parent.width
            text: "NOW PLAYING"
            color: Color.accent
            font.family: Style.fontFamily; font.pixelSize: 10; font.letterSpacing: 1.4
          }
          Text {
            width: parent.width
            text: service.trackTitle
            textFormat: Text.PlainText
            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
            color: Color.foreground
            font.family: Style.fontFamily; font.pixelSize: 16; font.weight: Font.DemiBold; lineHeight: 1.15
          }

          // live visualizer mirror: bands from `cliamp visstream`,
          // same source as cliamp's own visualizer view
          Item {
            width: parent.width; height: 52
            visible: cfg.showVis && service.visBands.length > 0
            Text {
              width: parent.width
              text: "LIVE  ·  " + (service.visName() !== "" ? service.visName().toUpperCase() : "VISUALIZER")
              color: Color.accent
              font.family: Style.fontFamily; font.pixelSize: 10; font.letterSpacing: 1.4
            }
            Item {
              y: 14; width: parent.width; height: 38
              // bars for most modes...
              Row {
                anchors.fill: parent
                spacing: 3
                visible: service.visStyle() === "bars"
                Repeater {
                  model: service.visN
                  delegate: Rectangle {
                    required property int index
                    width: Math.max(2, (body.width - (service.visN - 1) * 3) / service.visN)
                    height: Math.max(3, parent.height * ((service.visBands[index] || 0)))
                    anchors.bottom: parent.bottom
                    radius: 1.5
                    color: Util.alpha(Color.accent, 0.35 + 0.65 * (service.visBands[index] || 0))
                  }
                }
              }
              // ...center-mirrored bars for mirror-family modes
              Row {
                anchors.fill: parent
                spacing: 3
                visible: service.visStyle() === "mirror"
                Repeater {
                  model: service.visN
                  delegate: Item {
                    required property int index
                    width: Math.max(2, (body.width - (service.visN - 1) * 3) / service.visN)
                    height: 38
                    readonly property real mh: Math.max(2, 34 * (service.visBands[index] || 0))
                    Rectangle {
                      width: parent.width; height: parent.mh / 2
                      anchors.bottom: parent.verticalCenter
                      radius: 1.5
                      color: Util.alpha(Color.accent, 0.9)
                    }
                    Rectangle {
                      width: parent.width; height: parent.mh / 2
                      anchors.top: parent.verticalCenter
                      radius: 1.5
                      color: Util.alpha(Color.accent, 0.45)
                    }
                  }
                }
              }
              // ...dot matrix for scatter/firework/matrix-family modes
              Column {
                anchors.centerIn: parent
                spacing: 2
                visible: service.visStyle() === "dots"
                Repeater {
                  model: 5
                  delegate: Row {
                    required property int index
                    property int row: index
                    spacing: 3
                    Repeater {
                      model: service.visN
                      delegate: Rectangle {
                        required property int index
                        width: Math.max(2, (body.width - (service.visN - 1) * 3) / service.visN)
                        height: 5
                        radius: 2.5
                        readonly property real dv: (service.visBands[index] || 0)
                        color: dv * 5 > (4 - row) ? Util.alpha(Color.accent, 0.9) : Util.alpha(Color.foreground, 0.1)
                      }
                    }
                  }
                }
              }
              // ...waveform line for wave-family modes
              Canvas {
                id: wave
                anchors.fill: parent
                visible: service.visStyle() === "wave"
                onPaint: {
                  var c = getContext("2d");
                  var bands = service.visBands;
                  c.reset();
                  c.strokeStyle = Color.accent; c.lineWidth = 1.5;
                  c.lineJoin = "round"; c.lineCap = "round";
                  c.beginPath();
                  var n = bands.length;
                  if (!n) return;
                  for (var i = 0; i < n; i++) {
                    var x = (i / Math.max(1, n - 1)) * width;
                    var y = height - Math.max(0, Math.min(1, Number(bands[i]) || 0)) * height;
                    if (i === 0) c.moveTo(x, y); else c.lineTo(x, y);
                  }
                  c.stroke();
                }
              }
              Connections {
                target: service
                function onVisBandsChanged() { wave.requestPaint(); }
              }
            }
          }

          // transport
          Row {
            width: parent.width; spacing: 6
            DockAction { width: 44; height: 44; icon: "prev"; hint: "Previous"; onTriggered: service.run("prev") }
            DockAction { width: 44; height: 44; icon: service.playing ? "pause" : "play"; hint: service.playing ? "Pause" : "Play"; selected: service.playing; onTriggered: service.run("toggle") }
            DockAction { width: 44; height: 44; icon: "next"; hint: "Next"; onTriggered: service.run("next") }
            DockAction { width: 44; height: 44; icon: "stop"; hint: "Stop"; onTriggered: service.run("stop") }
            Text {
              textFormat: Text.PlainText
              text: service.posText + " / " + service.durText
              color: Util.alpha(Color.foreground, 0.55)
              font.family: "monospace"; font.pixelSize: 11
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // seekable progress
          Item {
            width: parent.width; height: 18
            visible: cfg.showProgress
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width; height: 5; radius: 3
              color: Util.alpha(Color.foreground, 0.12)
              Rectangle {
                width: parent.width * service.trackProgress; height: parent.height; radius: 3
                color: Color.accent
              }
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: function(mouse) {
                if (!service.cliamp || !service.cliamp.duration) return;
                var ratio = Math.max(0, Math.min(1, mouse.x / width));
                service.run("seek", Math.round(ratio * Number(service.cliamp.duration)));
              }
            }
          }

          // volume: optimistic state (status carries no volume field),
          // preview while dragging, commit to cliamp on release
          Text {
            width: parent.width
            visible: cfg.showVolume
            text: "OUTPUT  ·  " + cfg.volumeDb + " dB"
            color: Color.accent
            font.family: Style.fontFamily; font.pixelSize: 10; font.letterSpacing: 1.4
          }
          PanelSlider {
            width: parent.width
            visible: cfg.showVolume
            minimum: -30; maximum: 6; step: 0.5
            value: service.volumeDb
            onMoved: function(v) { service.previewVolume(v); }
            onReleased: function(v) { service.commitVolume(v); }
          }

          // toggles
          Row {
            width: parent.width; spacing: 6
            visible: cfg.showToggles
            DockAction { icon: "shuffle"; label: Cliamp.shuffleText(service.cliamp); hint: "Toggle shuffle"; selected: Cliamp.shuffleOn(service.cliamp); onTriggered: service.run("shuffle", "toggle") }
            DockAction { icon: Cliamp.repeatText(service.cliamp) === "One" ? "repeatOne" : "repeat"; label: Cliamp.repeatText(service.cliamp); hint: "Cycle repeat"; selected: Cliamp.repeatText(service.cliamp) !== "Off"; onTriggered: service.run("repeat", "cycle") }
            DockAction { icon: "mono"; label: Cliamp.monoText(service.cliamp); hint: "Toggle mono"; selected: Cliamp.monoOn(service.cliamp); onTriggered: service.run("mono", "toggle") }
          }
          Row {
            width: parent.width; spacing: 6
            visible: cfg.showEq || cfg.showMeta
            DockAction { visible: cfg.showMeta; label: "Vis " + (service.cliamp && service.cliamp.visualizer ? String(service.cliamp.visualizer) : "?"); hint: "Next visualizer"; onTriggered: service.run("vis", "next") }
            DockAction { visible: cfg.showEq; label: "EQ " + (service.cliamp && service.cliamp.eq_preset ? String(service.cliamp.eq_preset) : "?"); hint: "EQ preset"; onTriggered: service.run("eqPreset", "Flat") }
            DockAction { visible: cfg.showToggles; label: Cliamp.speedText(service.cliamp) + "x"; hint: "Reset speed"; onTriggered: service.run("speed", 1.0) }
          }

          // LAN share quick controls (full role/port settings live in the bar settings panel)
          Text {
            width: parent.width
            text: "LAN  ·  " + (service.lanSharing
              ? "SHARING " + (service.lanIp !== "" ? service.lanIp + " " : "") + ":" + service.lanStreamPort
              : service.lanListening
                ? "LISTENING " + (service.lanClientHost !== "" ? service.lanClientHost : "?")
                : service.lanHttp ? "HTTP :" + cfg.lanHttpPort : "OFF")
              + (cfg.lanRole !== "auto" ? "  [" + cfg.lanRole.toUpperCase() + "]" : "")
            color: Color.accent
            font.family: Style.fontFamily; font.pixelSize: 10; font.letterSpacing: 1.4
          }
          Row {
            width: parent.width; spacing: 6
            visible: cfg.lanRole !== "client"
            DockAction { label: service.lanSharing ? "Stop" : "Share"; hint: service.lanSharing ? "Stop LAN share" : "Share this room over LAN"; selected: service.lanSharing; onTriggered: service.lanSharing ? service.lanShareStop() : service.lanShareStart() }
            DockAction { label: service.lanHttp ? "HTTP off" : "HTTP"; hint: "Toggle MP3 fallback stream"; selected: service.lanHttp; onTriggered: service.lanHttp ? service.lanHttpStop() : service.lanHttpStart() }
          }
          Row {
            width: parent.width; spacing: 6
            visible: cfg.lanRole !== "server"
            DockAction { label: service.lanListening ? "Stop" : "Listen"; hint: service.lanListening ? "Stop listening" : ("Listen to " + (cfg.lanHost !== "" ? cfg.lanHost : "sharer")); selected: service.lanListening; onTriggered: service.lanListening ? service.lanListenStop() : service.lanListenStart(cfg.lanHost) }
            Text {
              textFormat: Text.PlainText
              text: (cfg.lanHost !== "" ? cfg.lanHost : "set host in settings") + " :" + cfg.lanControlPort
              color: Util.alpha(Color.foreground, 0.55)
              font.family: "monospace"; font.pixelSize: 11
              anchors.verticalCenter: parent.verticalCenter
            }
          }

        }
      }

      // footer
      Rectangle {
        x: 22; y: parent.height - 61; width: parent.width - 44; height: 1
        color: Util.alpha(Color.foreground, 0.075)
      }
      Text {
        x: 24; y: parent.height - 42; width: parent.width - 48
        text: {
          var lan = "";
          if (service.lanSharing) lan = " · SHARING :" + service.lanStreamPort;
          else if (service.lanListening) lan = " · LISTENING";
          else if (service.lanHttp) lan = " · HTTP :" + cfg.lanHttpPort;
          if (service.cliampError !== "") return service.cliampError + lan;
          if (service.lanError !== "") return service.lanError + lan;
          return "Hover the edge handle to reveal · tap to open" + lan;
        }
        textFormat: Text.PlainText; elide: Text.ElideRight
        color: (service.lanSharing || service.lanListening) ? Color.accent : Util.alpha(Color.foreground, 0.45)
        font.family: Style.fontFamily; font.pixelSize: 10
      }
    }
  }
}
