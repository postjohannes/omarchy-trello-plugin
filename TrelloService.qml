import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Trello.js" as Trello

// Owns every conversation with the Trello REST API: credentials, the member's
// boards, the lists of the chosen board, the cards of the chosen list, and the
// create / archive mutations. The bar widget instantiates one of these and
// hands it to the panel, so both surfaces read the same data instead of
// polling the network twice.
//
// All network I/O is a `curl` child process, matching how the rest of the
// shell fetches remote data. Credentials live in
// ~/.config/omarchy/trello.json, which the panel writes and the user can edit
// by hand.
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/omarchy"
  readonly property string configPath: configDir + "/trello.json"

  // ---- persisted configuration -----------------------------------------

  property string apiKey: ""
  property string token: ""
  property string boardId: ""
  property string boardName: ""
  property string listId: ""
  property string listName: ""
  property int refreshIntervalSec: 300
  property bool showCompleted: false
  property bool configReady: false

  readonly property bool authenticated: root.apiKey !== "" && root.token !== ""
  readonly property bool hasSelection: root.boardId !== "" && root.listId !== ""

  // ---- fetched state ----------------------------------------------------

  property string memberName: ""
  property string status: ""
  property string error: ""
  property string lastStderr: ""

  property bool boardsLoading: false
  property bool listsLoading: false
  property bool cardsLoading: false
  property bool mutating: false
  readonly property bool busy: boardsLoading || listsLoading || cardsLoading || mutating

  property var boards: []
  property var lists: []
  property var cards: []
  property int dataRevision: 0

  readonly property int openCardCount: Trello.openCount(root.cards)

  // ---- config file ------------------------------------------------------

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.configReady = true
  }

  function applyConfig(raw) {
    var firstLoad = !root.configReady
    var parsed = Trello.parseConfig(raw)
    root.apiKey = parsed.apiKey
    root.token = parsed.token
    root.boardId = parsed.boardId
    root.boardName = parsed.boardName
    root.listId = parsed.listId
    root.listName = parsed.listName
    root.refreshIntervalSec = parsed.refreshIntervalSec
    root.showCompleted = parsed.showCompleted
    root.configReady = true
    // Only the first read kicks off the network. Later writes come from this
    // plugin's own persist() and would otherwise refetch on every selection.
    if (firstLoad && root.authenticated) Qt.callLater(root.refresh)
  }

  function persist() {
    configFile.setText(Trello.serializeConfig({
      apiKey: root.apiKey,
      token: root.token,
      boardId: root.boardId,
      boardName: root.boardName,
      listId: root.listId,
      listName: root.listName,
      refreshIntervalSec: root.refreshIntervalSec,
      showCompleted: root.showCompleted
    }))
    // The file holds an API token; keep it owner-readable only. Deferred so
    // the write has landed before chmod touches the path.
    Qt.callLater(function() { if (!chmodProc.running) chmodProc.running = true })
  }

  Process {
    id: chmodProc
    running: false
    command: ["chmod", "600", root.configPath]
  }

  // ---- request plumbing -------------------------------------------------

  function authArgs() {
    return ["--data-urlencode", "key=" + root.apiKey, "--data-urlencode", "token=" + root.token]
  }

  function getCommand(path, params) {
    var command = ["curl", "-fsS", "--max-time", "20", "-G", "https://api.trello.com/1" + path]
    return command.concat(root.authArgs(), params || [])
  }

  function requestCommand(method, path, params) {
    var command = ["curl", "-fsS", "--max-time", "20", "-X", method, "https://api.trello.com/1" + path]
    return command.concat(root.authArgs(), params || [])
  }

  function friendlyError() {
    var text = String(root.lastStderr || "").trim()
    if (text.indexOf("401") !== -1 || text.toLowerCase().indexOf("unauthorized") !== -1)
      return "Trello rejected these credentials. Check the API key and token."
    if (text.indexOf("404") !== -1)
      return "That Trello resource no longer exists. Pick a board and list again."
    if (text.indexOf("429") !== -1)
      return "Trello rate limit reached. Try again in a minute."
    if (text.indexOf("Could not resolve") !== -1 || text.indexOf("Failed to connect") !== -1)
      return "Network unreachable. Check your connection."
    if (text !== "") return text.replace(/^curl:\s*\(\d+\)\s*/, "")
    return "Trello request failed."
  }

  function captureStderr(text) {
    var trimmed = String(text || "").trim()
    if (trimmed !== "") root.lastStderr = trimmed
  }

  function bump() { root.dataRevision++ }

  function openUrl(url) {
    if (String(url || "") === "") return
    Quickshell.execDetached(["xdg-open", String(url)])
  }

  function openTokenPage() {
    if (root.apiKey === "") {
      root.error = "Enter an API key first, then open the authorization page."
      return
    }
    Quickshell.execDetached(["xdg-open", Trello.authorizeUrl(root.apiKey)])
  }

  function openDeveloperPage() {
    Quickshell.execDetached(["xdg-open", "https://trello.com/app-key"])
  }

  // ---- refresh orchestration -------------------------------------------

  // Full reload: boards first, which cascades into lists and cards so a board
  // renamed or a list added elsewhere shows up. Used on open and on demand.
  function refresh() {
    if (!root.authenticated) return
    root.fetchBoards()
  }

  // Cheap reload: only the selected list's cards. Drives the bar timer.
  function refreshCards() {
    if (!root.authenticated || root.listId === "") return
    root.fetchCards()
  }

  function connect(key, token) {
    root.apiKey = String(key || "").trim()
    root.token = String(token || "").trim()
    root.boardId = ""
    root.boardName = ""
    root.listId = ""
    root.listName = ""
    root.boards = []
    root.lists = []
    root.cards = []
    root.error = ""
    root.status = ""
    root.persist()
    root.fetchMember()
    root.refresh()
  }

  function logout() {
    root.apiKey = ""
    root.token = ""
    root.memberName = ""
    root.boardId = ""
    root.boardName = ""
    root.listId = ""
    root.listName = ""
    root.boards = []
    root.lists = []
    root.cards = []
    root.error = ""
    root.status = ""
    root.persist()
    root.bump()
  }

  function selectBoard(id, name, save) {
    root.boardId = String(id || "")
    root.boardName = String(name || "")
    root.listId = ""
    root.listName = ""
    root.cards = []
    if (save !== false) root.persist()
    root.bump()
    root.fetchLists()
  }

  function selectList(id, name) {
    root.listId = String(id || "")
    root.listName = String(name || "")
    root.persist()
    root.bump()
    root.fetchCards()
  }

  // ---- fetch processes --------------------------------------------------

  Process {
    id: memberProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        try {
          var parsed = JSON.parse(raw)
          root.memberName = String(parsed.fullName || parsed.username || "")
        } catch (e) {}
      }
    }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.captureStderr(text) }
  }

  function fetchMember() {
    if (!root.authenticated || memberProc.running) return
    memberProc.command = root.getCommand("/members/me", ["--data-urlencode", "fields=fullName,username"])
    memberProc.running = true
  }

  Process {
    id: boardsProc
    running: false
    onRunningChanged: root.boardsLoading = running
    onExited: function(code) {
      if (code !== 0) {
        root.error = root.friendlyError()
        root.bump()
      }
    }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleBoards(text) }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.captureStderr(text) }
  }

  function fetchBoards() {
    if (!root.authenticated || boardsProc.running) return
    root.error = ""
    boardsProc.command = root.getCommand("/members/me/boards", [
      "--data-urlencode", "filter=open",
      "--data-urlencode", "fields=name,url"
    ])
    boardsProc.running = true
  }

  function handleBoards(raw) {
    var text = String(raw || "").trim()
    if (text === "") return
    root.boards = Trello.normalizeBoards(Trello.parseArray(text))
    root.error = ""

    // A stored board that has since been closed or deleted drops out cleanly.
    if (root.boardId !== "" && Trello.indexOfId(root.boards, root.boardId) === -1) {
      root.boardId = ""
      root.boardName = ""
      root.listId = ""
      root.listName = ""
      root.cards = []
    }

    if (root.boardId === "" && root.boards.length > 0) {
      root.selectBoard(root.boards[0].id, root.boards[0].name)
    } else if (root.boardId !== "") {
      root.fetchLists()
    }
    root.bump()
  }

  Process {
    id: listsProc
    running: false
    onRunningChanged: root.listsLoading = running
    onExited: function(code) {
      if (code !== 0) {
        root.error = root.friendlyError()
        root.bump()
      }
    }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleLists(text) }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.captureStderr(text) }
  }

  function fetchLists() {
    if (!root.authenticated || root.boardId === "" || listsProc.running) return
    listsProc.command = root.getCommand("/boards/" + encodeURIComponent(root.boardId) + "/lists", [
      "--data-urlencode", "filter=open",
      "--data-urlencode", "fields=name"
    ])
    listsProc.running = true
  }

  function handleLists(raw) {
    var text = String(raw || "").trim()
    if (text === "") return
    root.lists = Trello.normalizeLists(Trello.parseArray(text))
    root.error = ""

    if (root.listId !== "" && Trello.indexOfId(root.lists, root.listId) === -1) {
      root.listId = ""
      root.listName = ""
      root.cards = []
    }

    if (root.listId === "" && root.lists.length > 0) {
      root.selectList(root.lists[0].id, root.lists[0].name)
    } else if (root.listId !== "") {
      root.fetchCards()
    }
    root.bump()
  }

  Process {
    id: cardsProc
    running: false
    onRunningChanged: root.cardsLoading = running
    onExited: function(code) {
      if (code !== 0) {
        root.error = root.friendlyError()
        root.bump()
      }
    }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleCards(text) }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.captureStderr(text) }
  }

  function fetchCards() {
    if (!root.authenticated || root.listId === "" || cardsProc.running) return
    cardsProc.command = root.getCommand("/lists/" + encodeURIComponent(root.listId) + "/cards", [
      "--data-urlencode", "filter=" + (root.showCompleted ? "all" : "open"),
      "--data-urlencode", "fields=name,url,closed,due,dueComplete"
    ])
    cardsProc.running = true
  }

  function handleCards(raw) {
    var text = String(raw || "").trim()
    if (text === "") return
    root.cards = Trello.normalizeCards(Trello.parseArray(text))
    root.error = ""
    root.bump()
  }

  // ---- mutations --------------------------------------------------------

  property string mutateKind: ""
  property string mutateCardId: ""

  Process {
    id: mutateProc
    running: false
    onRunningChanged: root.mutating = running
    onExited: function(code) {
      if (code !== 0) root.error = root.friendlyError()
      root.mutateKind = ""
      root.mutateCardId = ""
      // Reload either way: a created card has to appear, and a failed toggle
      // has to drop the optimistic edit.
      root.fetchCards()
      root.bump()
    }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.captureStderr(text) }
  }

  function createCard(name, description) {
    var trimmed = String(name || "").trim()
    if (trimmed === "" || root.listId === "" || mutateProc.running) return
    var params = [
      "--data-urlencode", "idList=" + root.listId,
      "--data-urlencode", "name=" + trimmed
    ]
    var desc = String(description || "").trim()
    if (desc !== "") params = params.concat(["--data-urlencode", "desc=" + desc])
    root.mutateKind = "create"
    root.error = ""
    mutateProc.command = root.requestCommand("POST", "/cards", params)
    mutateProc.running = true
  }

  // Check an issue off (archive it) or restore it when "show completed" is on.
  function toggleCard(card) {
    if (!card || mutateProc.running) return
    var nextClosed = !card.closed
    root.mutateKind = "toggle"
    root.mutateCardId = card.id

    // Optimistic: a completed card leaves the list unless completed cards are
    // being shown. The server reload that follows the mutation reconciles it.
    if (nextClosed && !root.showCompleted) root.cards = Trello.removeId(root.cards, card.id)
    else root.cards = Trello.withClosed(root.cards, card.id, nextClosed)
    root.bump()

    root.error = ""
    mutateProc.command = root.requestCommand("PUT", "/cards/" + encodeURIComponent(card.id), [
      "--data-urlencode", "closed=" + (nextClosed ? "true" : "false")
    ])
    mutateProc.running = true
  }

  function setShowCompleted(value) {
    root.showCompleted = value === true
    root.persist()
    root.fetchCards()
    root.bump()
  }
}
