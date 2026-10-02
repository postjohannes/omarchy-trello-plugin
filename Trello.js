// Pure helpers for the Trello plugin. Kept free of Qt/QML types so the
// parsing and URL-building can be reasoned about (and unit-tested) on their
// own. The QML service owns the I/O; this file only shapes strings.

var DEFAULTS = {
  apiKey: "",
  token: "",
  boardId: "",
  boardName: "",
  listId: "",
  listName: "",
  refreshIntervalSec: 300,
  showCompleted: false
}

function clampInt(value, fallback, minimum, maximum) {
  var parsed = parseInt(value, 10)
  if (!isFinite(parsed)) return fallback
  return Math.max(minimum, Math.min(maximum, parsed))
}

function stringOr(value, fallback) {
  if (value === undefined || value === null) return fallback
  var text = String(value)
  return text
}

// Tolerant reader for ~/.config/omarchy/trello.json. A missing, empty, or
// malformed file reads as "not configured" rather than throwing, so a hand
// edit that breaks the JSON can still be repaired from the panel.
function parseConfig(raw) {
  var out = {
    apiKey: DEFAULTS.apiKey,
    token: DEFAULTS.token,
    boardId: DEFAULTS.boardId,
    boardName: DEFAULTS.boardName,
    listId: DEFAULTS.listId,
    listName: DEFAULTS.listName,
    refreshIntervalSec: DEFAULTS.refreshIntervalSec,
    showCompleted: DEFAULTS.showCompleted
  }

  var parsed
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (e) {
    return out
  }
  if (!parsed || typeof parsed !== "object") return out

  out.apiKey = stringOr(parsed.apiKey, "")
  out.token = stringOr(parsed.token, "")
  out.boardId = stringOr(parsed.boardId, "")
  out.boardName = stringOr(parsed.boardName, "")
  out.listId = stringOr(parsed.listId, "")
  out.listName = stringOr(parsed.listName, "")
  out.refreshIntervalSec = clampInt(parsed.refreshIntervalSec, DEFAULTS.refreshIntervalSec, 30, 3600)
  out.showCompleted = parsed.showCompleted === true
  return out
}

function serializeConfig(config) {
  return JSON.stringify({
    apiKey: stringOr(config.apiKey, ""),
    token: stringOr(config.token, ""),
    boardId: stringOr(config.boardId, ""),
    boardName: stringOr(config.boardName, ""),
    listId: stringOr(config.listId, ""),
    listName: stringOr(config.listName, ""),
    refreshIntervalSec: clampInt(config.refreshIntervalSec, DEFAULTS.refreshIntervalSec, 30, 3600),
    showCompleted: config.showCompleted === true
  }, null, 2) + "\n"
}

function parseArray(raw) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    return Array.isArray(parsed) ? parsed : []
  } catch (e) {
    return []
  }
}

// The browser URL that mints a never-expiring read/write token for a given
// API key. Trello shows the token on the page; the user copies it back in.
function authorizeUrl(apiKey) {
  var key = stringOr(apiKey, "")
  return "https://trello.com/1/authorize"
    + "?expiration=never"
    + "&scope=read,write"
    + "&response_type=token"
    + "&name=" + encodeURIComponent("Omarchy Trello")
    + "&key=" + encodeURIComponent(key)
}

function normalizeBoards(records) {
  var out = []
  for (var i = 0; i < records.length; i++) {
    var record = records[i] || {}
    if (!record.id) continue
    out.push({
      id: String(record.id),
      name: stringOr(record.name, "Untitled board"),
      url: stringOr(record.url, "")
    })
  }
  out.sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1 })
  return out
}

function normalizeLists(records) {
  var out = []
  for (var i = 0; i < records.length; i++) {
    var record = records[i] || {}
    if (!record.id) continue
    out.push({
      id: String(record.id),
      name: stringOr(record.name, "Untitled list")
    })
  }
  return out
}

function normalizeCards(records) {
  var out = []
  for (var i = 0; i < records.length; i++) {
    var record = records[i] || {}
    if (!record.id) continue
    out.push({
      id: String(record.id),
      name: stringOr(record.name, "Untitled card"),
      url: stringOr(record.url, ""),
      closed: record.closed === true,
      due: stringOr(record.due, ""),
      dueComplete: record.dueComplete === true
    })
  }
  return out
}

function optionList(items) {
  var out = []
  for (var i = 0; i < items.length; i++) out.push({ value: items[i].id, label: items[i].name })
  return out
}

function indexOfId(items, id) {
  for (var i = 0; i < items.length; i++) if (items[i].id === id) return i
  return -1
}

function withClosed(cards, id, closed) {
  var out = []
  for (var i = 0; i < cards.length; i++) {
    var card = cards[i]
    if (card.id === id) {
      out.push({
        id: card.id,
        name: card.name,
        url: card.url,
        closed: closed,
        due: card.due,
        dueComplete: card.dueComplete
      })
    } else {
      out.push(card)
    }
  }
  return out
}

function removeId(cards, id) {
  var out = []
  for (var i = 0; i < cards.length; i++) if (cards[i].id !== id) out.push(cards[i])
  return out
}

function openCount(cards) {
  var count = 0
  for (var i = 0; i < cards.length; i++) if (!cards[i].closed) count++
  return count
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// Short label for a card's due date: "Mar 4", "Today", "Overdue". Returns an
// empty string when the card has no due date. Formatted by hand rather than
// through toLocaleDateString, which is unreliable in the QML JS engine.
function dueLabel(due, nowMs) {
  if (!due) return ""
  var parsed = new Date(due)
  if (isNaN(parsed.getTime())) return ""
  var now = new Date(nowMs || Date.now())
  var sameDay = parsed.getFullYear() === now.getFullYear()
    && parsed.getMonth() === now.getMonth()
    && parsed.getDate() === now.getDate()
  if (sameDay) return "Today"
  var label = MONTHS[parsed.getMonth()] + " " + parsed.getDate()
  if (parsed.getTime() < now.getTime()) return "Overdue · " + label
  return label
}

function isOverdue(due, dueComplete, nowMs) {
  if (!due || dueComplete) return false
  var parsed = new Date(due)
  if (isNaN(parsed.getTime())) return false
  return parsed.getTime() < (nowMs || Date.now())
}
