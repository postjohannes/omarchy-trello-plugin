import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Trello.js" as Trello

// The Trello popup: connect, pick a board and list, check issues off, and add
// new ones. All state and network work lives in the injected TrelloService so
// the bar widget and this panel share a single client.
Panel {
  id: root
  moduleName: "io.github.postjohannes.trello"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  property int cursorIndex: 0
  property bool showSetup: false
  property bool showDescription: false
  property double nowMs: Date.now()

  readonly property var cards: root.service ? root.service.cards : []
  readonly property bool setupVisible: !root.service || !root.service.authenticated || root.showSetup
  readonly property bool editing: {
    if (newCardField.activeFocus || descField.activeFocus) return true
    if (boardDropdown.popupOpen || listDropdown.popupOpen) return true
    if (root.setupVisible && (apiKeyField.activeFocus || tokenField.activeFocus)) return true
    return false
  }

  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(root.foreground, 1.55)
  readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  function open() {
    root.controller.show()
    root.showSetup = false
    root.cursorIndex = 0
    root.nowMs = Date.now()
    if (root.service) root.service.refresh()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() { root.controller.hide() }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function moveCursor(dy) {
    if (root.cards.length === 0) return
    root.cursorIndex = Math.max(0, Math.min(root.cards.length - 1, root.cursorIndex + dy))
  }

  function toggleSelected() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.cards.length) return
    root.service.toggleCard(root.cards[root.cursorIndex])
  }

  function openSelected() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.cards.length) return
    root.service.openUrl(root.cards[root.cursorIndex].url)
  }

  function focusNewCard() {
    root.showSetup = false
    Qt.callLater(function() { newCardField.forceActiveFocus() })
  }

  function submitNewCard() {
    var title = String(newCardField.text || "").trim()
    if (title === "" || !root.service) return
    root.service.createCard(title, descField.text)
    newCardField.text = ""
    descField.text = ""
    root.showDescription = false
  }

  function submitConnect() {
    if (!root.service) return
    root.service.connect(apiKeyField.text, tokenField.text)
    root.showSetup = false
  }

  function editSettings() {
    root.showSetup = true
    Qt.callLater(function() {
      apiKeyField.text = root.service ? root.service.apiKey : ""
      tokenField.text = root.service ? root.service.token : ""
      apiKeyField.forceActiveFocus()
    })
  }

  onCardsChanged: root.cursorIndex = Math.max(0, Math.min(root.cursorIndex, root.cards.length - 1))
  onOpenedChanged: if (root.opened) root.nowMs = Date.now()

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.toggleSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") { if (root.service) root.service.refresh() }
        else if (t === "n" || t === "N") root.focusNewCard()
        else if (t === "d" || t === "D") { if (root.service) root.service.setShowCompleted(!root.service.showCompleted) }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          // ---- Setup / connect ----
          Column {
            visible: root.setupVisible
            width: parent.width
            spacing: Style.space(12)

            PanelHero {
              width: parent.width
              title: "Trello"
              meta: "Connect your account"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  text: "\uf181"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }

            Text {
              width: parent.width
              text: "Generate a personal API key on the Trello developer page, then authorize it to mint a token. Both are stored locally in ~/.config/omarchy/trello.json."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField {
              id: apiKeyField
              width: parent.width
              placeholderText: "API key"
              foreground: root.foreground
              accent: Color.accent
              font.family: root.fontFamily
            }

            TextField {
              id: tokenField
              width: parent.width
              placeholderText: "Token"
              password: true
              foreground: root.foreground
              accent: Color.accent
              font.family: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              Button {
                text: "1 · Get API key"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: if (root.service) root.service.openDeveloperPage()
              }

              Button {
                text: "2 · Get token"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                tooltipText: "Authorizes the API key above and shows a token"
                onClicked: if (root.service) root.service.openTokenPage()
              }
            }

            Button {
              text: "Connect"
              selected: root.service && root.service.authenticated
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.submitConnect()
            }

            Text {
              width: parent.width
              visible: root.service && root.service.error !== ""
              text: root.service ? root.service.error : ""
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: root.service && root.service.authenticated
              text: "Disconnecting forgets the stored key and token."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              visible: root.service && root.service.authenticated
              text: "Disconnect"
              bordered: true
              foreground: root.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: { if (root.service) root.service.logout(); root.showSetup = false }
            }
          }

          // ---- Main ----
          Column {
            visible: !root.setupVisible
            width: parent.width
            spacing: Style.space(12)

            PanelHero {
              width: parent.width
              title: root.service && root.service.boardName !== "" ? root.service.boardName : "Trello"
              meta: root.service && root.service.listName !== "" ? root.service.listName
                : (root.service ? root.service.memberName : "")
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  text: "\uf181"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                Button {
                  text: "󰒓"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.iconSmall
                  tooltipText: "Settings"
                  onClicked: root.editSettings()
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              SearchableDropdown {
                id: boardDropdown
                width: (parent.width - parent.spacing) / 2
                label: "BOARD"
                value: root.service ? root.service.boardId : ""
                options: root.service ? Trello.optionList(root.service.boards) : []
                placeholderText: "Search boards"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) {
                  if (!root.service) return
                  var idx = Trello.indexOfId(root.service.boards, value)
                  if (idx >= 0) root.service.selectBoard(value, root.service.boards[idx].name)
                }
              }

              SearchableDropdown {
                id: listDropdown
                width: (parent.width - parent.spacing) / 2
                label: "LIST"
                value: root.service ? root.service.listId : ""
                options: root.service ? Trello.optionList(root.service.lists) : []
                placeholderText: "Search lists"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) {
                  if (!root.service) return
                  var idx = Trello.indexOfId(root.service.lists, value)
                  if (idx >= 0) root.service.selectList(value, root.service.lists[idx].name)
                }
              }
            }

            // ---- New issue ----
            Column {
              width: parent.width
              spacing: Style.space(6)

              Row {
                width: parent.width
                spacing: Style.spacing.md

                TextField {
                  id: newCardField
                  width: Math.max(0, parent.width - addButton.width - parent.spacing)
                  placeholderText: "New issue title"
                  foreground: root.foreground
                  accent: Color.accent
                  font.family: root.fontFamily
                  onAccepted: root.submitNewCard()
                  Keys.onEscapePressed: function(event) {
                    newCardField.text = ""
                    root.showDescription = false
                    if (keyCatcher) keyCatcher.forceActiveFocus()
                    event.accepted = true
                  }
                }

                Button {
                  id: addButton
                  text: "Add"
                  selected: newCardField.text.trim() !== ""
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.submitNewCard()
                }
              }

              TextField {
                id: descField
                visible: root.showDescription
                width: parent.width
                placeholderText: "Description (optional)"
                foreground: root.foreground
                accent: Color.accent
                font.family: root.fontFamily
                onAccepted: root.submitNewCard()
                Keys.onEscapePressed: function(event) {
                  descField.text = ""
                  root.showDescription = false
                  if (keyCatcher) keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }

              Button {
                visible: !root.showDescription
                text: "+ note"
                foreground: root.dim
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: {
                  root.showDescription = true
                  Qt.callLater(function() { descField.forceActiveFocus() })
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              width: parent.width
              text: "ISSUES" + (root.service ? " · " + (root.cards.length - root.service.openCardCount) + " done" : "")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
          }

          // ---- Issue list ----
          Column {
            visible: !root.setupVisible
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.cards

              Item {
                id: cardRow
                required property var modelData
                required property int index

                width: parent.width
                implicitHeight: Math.max(checkGlyph.implicitHeight, cardTitle.implicitHeight, dueChip.implicitHeight) + Style.space(12)
                readonly property bool selected: index === root.cursorIndex
                readonly property string due: root.service ? Trello.dueLabel(modelData.due, root.nowMs) : ""
                readonly property bool overdue: root.service
                  ? Trello.isOverdue(modelData.due, modelData.dueComplete, root.nowMs) : false

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: cardRow.selected || rowHover.hovered
                    ? Style.hoverFillFor(root.foreground, Color.accent)
                    : "transparent"
                }

                MouseArea {
                  id: rowHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton
                  onEntered: root.cursorIndex = cardRow.index
                  onClicked: root.cursorIndex = cardRow.index
                }

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.right: dueChip.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)

                  Text {
                    id: checkGlyph
                    text: cardRow.modelData.closed ? "󰄲" : "󰄱"
                    color: cardRow.modelData.closed ? root.dim : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter

                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (root.service) root.service.toggleCard(cardRow.modelData)
                    }
                  }

                  Text {
                    id: cardTitle
                    text: cardRow.modelData.name
                    color: cardRow.modelData.closed ? root.dim : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.strikeout: cardRow.modelData.closed
                    elide: Text.ElideRight
                    width: Math.max(0, parent.width - checkGlyph.width - parent.spacing)
                    anchors.verticalCenter: parent.verticalCenter

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (root.service) root.service.openUrl(cardRow.modelData.url)
                    }
                  }
                }

                Text {
                  id: dueChip
                  visible: text !== ""
                  text: cardRow.due
                  color: cardRow.overdue ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
          }

          // ---- Empty / status ----
          Column {
            visible: !root.setupVisible && root.cards.length === 0
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: {
                if (!root.service) return ""
                if (root.service.cardsLoading) return "Loading issues…"
                if (root.service.listId === "" && root.service.boardsLoading) return "Loading boards…"
                if (root.service.listId === "" && root.service.listsLoading) return "Loading lists…"
                return "No open issues in this list."
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              topPadding: Style.space(20)
            }
          }

          // ---- Footer ----
          Text {
            visible: !root.setupVisible
            width: parent.width
            text: {
              if (!root.service) return ""
              if (root.service.error !== "") return root.service.error
              if (root.service.mutating) return "Saving…"
              if (root.service.cardsLoading) return "Refreshing…"
              var parts = ["r refresh", "n new", "enter check"]
              if (root.service.showCompleted) parts.push("d hide done")
              else parts.push("d show done")
              return parts.join(" · ")
            }
            color: root.service && root.service.error !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
