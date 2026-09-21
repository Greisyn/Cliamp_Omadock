import QtQuick
import qs.Commons
import qs.Ui
import "Cliamp.js" as Cliamp

// Bar surface: icon ONLY. The player floats as a dock (DockService);
// this opens the settings panel and reflects play state.
BarWidget {
  id: root
  moduleName: "local.cliamp-dock"

  function injectPanel() {
    var target = panelLoader.item;
    if (!target) return;
    if ("bar" in target) target.bar = root.bar;
    if ("settings" in target) target.settings = root.settings;
    if ("anchorItem" in target) target.anchorItem = button;
    if ("hostWidget" in target) target.hostWidget = root;
  }

  readonly property var dockService: bar && bar.shell ? bar.shell.serviceFor("local.cliamp-dock") : null
  readonly property bool playing: dockService ? !!dockService.playing : false
  readonly property string trackTitle: dockService ? String(dockService.trackTitle || "cliamp") : "cliamp"

  // Shape contract for shell.summon/hide/toggle routing, keyboard panel
  // switching, and the bar's open-panel indicator. Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root (mirrors first-party
  // clock/weather widgets). The widget stands in for the panel as popout
  // identity, forwarding switch-close + closing flag.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open(); }
  function close() { if (panelLoader.item) panelLoader.item.close(); }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle(); }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch(); }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: root.injectPanel()
  onSettingsChanged: root.injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel); }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fixedWidth: vertical ? -1 : Style.bar.iconSlot
    text: ""
    labelVisible: false
    hasVisualContent: true
    active: false
    useActiveColor: false
    tooltipText: root.trackTitle + (root.playing ? " (playing)" : " (paused)") + "\nLeft click: play/pause\nRight click: settings"

    OpticalGlyph {
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas
      text: root.playing ? "▶" : "♫"
      fontFamily: button.fontFamily
      fontSize: Style.bar.iconFont
      color: button.foreground
    }

    onPressed: function(b) {
      if (!root.bar) return;
      if (b === Qt.RightButton) {
        if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle();
        return;
      }
      if (b === Qt.LeftButton) {
        if (root.dockService) root.dockService.run("toggle");
      }
    }
  }
}
