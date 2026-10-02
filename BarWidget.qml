import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar entry point. One glyph plus the number of open issues in the selected
// list; the panel holds the board/list pickers, the issue list, and the
// create form. The TrelloService lives here so the count keeps updating on the
// refresh timer even while the panel is closed, and is injected into the panel
// so both surfaces share one client.
BarWidget {
  id: root
  moduleName: "io.github.postjohannes.trello"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  // Shape contract for shell.summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity, matching the built-in clock and weather widgets.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function refresh() { service.refresh() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  TrelloService {
    id: service
  }

  Timer {
    interval: Math.max(30, service.refreshIntervalSec) * 1000
    running: service.authenticated
    repeat: true
    onTriggered: service.refreshCards()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refresh() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: service.authenticated && service.openCardCount > 0
      ? "\uf181 " + service.openCardCount
      : "\uf181"
    labelVisible: true
    horizontalMargin: 8.75
    verticalPadding: 8.75
    active: service.error !== ""
    useActiveColor: true
    tooltipText: !service.authenticated
      ? "Trello — not connected"
      : (service.listName !== "" ? service.listName : "Trello")

    onPressed: function(b) {
      if (b === Qt.RightButton) service.refresh()
      else if (b === Qt.MiddleButton && service.authenticated && service.boardId !== "")
        service.openUrl("https://trello.com/b/" + service.boardId)
      else root.togglePanel()
    }
  }
}
