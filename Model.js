function parseJson(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, error: "The Basecamp CLI returned no data", code: "" }

  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return { ok: false, error: "The Basecamp CLI returned invalid data", code: "" }
    if (parsed.ok === false) {
      return {
        ok: false,
        error: cleanText(parsed.error || parsed.message || "The Basecamp CLI request failed"),
        code: String(parsed.code || ""),
        hint: cleanText(parsed.hint || "")
      }
    }
    return { ok: true, value: parsed }
  } catch (error) {
    return { ok: false, error: "Could not parse the Basecamp CLI response", code: "" }
  }
}

function parseAccounts(raw) {
  var result = parseJson(raw)
  if (!result.ok) return { ok: false, error: result.error, accounts: [] }

  var data = Array.isArray(result.value.data) ? result.value.data : []
  var accounts = []
  for (var i = 0; i < data.length; i++) {
    var account = data[i] || {}
    var id = String(account.id || "").trim()
    if (id === "") continue
    accounts.push({
      id: id,
      name: cleanText(account.name || ("Account " + id)),
      order: accounts.length
    })
  }

  return { ok: true, error: "", accounts: accounts }
}

function parseNotifications(raw, account, limit) {
  var result = parseJson(raw)
  if (!result.ok) return { ok: false, error: result.error, items: [] }

  var data = result.value.data
  var sections = []
  if (Array.isArray(data)) {
    sections.push({ name: "notifications", items: data })
  } else if (data && typeof data === "object") {
    var preferred = ["unreads", "unread", "reads", "read", "memories", "memory"]
    var used = {}
    for (var p = 0; p < preferred.length; p++) {
      var preferredName = preferred[p]
      if (Array.isArray(data[preferredName])) {
        sections.push({ name: preferredName, items: data[preferredName] })
        used[preferredName] = true
      }
    }
    for (var key in data) {
      if (!used[key] && Array.isArray(data[key])) sections.push({ name: key, items: data[key] })
    }
  }

  var items = []
  for (var s = 0; s < sections.length; s++) {
    var section = sections[s]
    var unreadSection = String(section.name).toLowerCase().indexOf("unread") !== -1
    for (var n = 0; n < section.items.length; n++) {
      var item = normalizeNotification(section.items[n], account, unreadSection)
      if (item) items.push(item)
    }
  }

  items.sort(compareWithinAccount)
  var count = positiveInteger(limit, 20)
  if (items.length > count) items = items.slice(0, count)
  return { ok: true, error: "", items: items }
}

function joinNames(names) {
  if (names.length <= 1) return names.join("")
  return names.slice(0, -1).join(", ") + " & " + names[names.length - 1]
}

function pingTitle(item) {
  var names = []
  var list = Array.isArray(item.participants) ? item.participants : []
  for (var i = 0; i < list.length; i++) {
    var name = cleanText(list[i] && list[i].name ? list[i].name : "")
    if (name !== "") names.push(name)
  }
  if (names.length === 0) return ""
  return "Ping with " + joinNames(names)
}

function normalizeNotification(value, account, unread) {
  var item = value || {}
  var id = String(item.id || "").trim()
  if (id === "") return null

  var timestamp = String(item.updated_at || item.created_at || "")
  var parsedTime = Date.parse(timestamp)
  if (!isFinite(parsedTime)) parsedTime = 0

  var title = cleanText(item.title || item.readable_identifier || "Basecamp notification")
  if (String(item.section || "") === "pings" && item.named !== true) {
    title = pingTitle(item) || title
  }

  return {
    id: id,
    accountId: String(account.id || ""),
    accountName: cleanText(account.name || "Basecamp"),
    accountOrder: Number(account.order || 0),
    title: title,
    creator: cleanText(item.creator && item.creator.name ? item.creator.name : ""),
    excerpt: cleanText(item.content_excerpt || ""),
    project: cleanText(item.bucket_name || item.section || ""),
    type: cleanText(item.type || ""),
    timestamp: timestamp,
    timestampMs: parsedTime,
    url: String(item.app_url || ""),
    unread: unread === true,
    unreadCount: positiveInteger(item.unread_count, 0)
  }
}

function compareWithinAccount(a, b) {
  if (a.unread !== b.unread) return a.unread ? -1 : 1
  return Number(b.timestampMs || 0) - Number(a.timestampMs || 0)
}

function sortNotifications(items) {
  var sorted = Array.isArray(items) ? items.slice() : []
  sorted.sort(function(a, b) {
    var timeDifference = Number(b.timestampMs || 0) - Number(a.timestampMs || 0)
    if (timeDifference !== 0) return timeDifference
    var accountDifference = Number(a.accountOrder || 0) - Number(b.accountOrder || 0)
    if (accountDifference !== 0) return accountDifference
    return String(a.id || "").localeCompare(String(b.id || ""))
  })
  return sorted
}

function filterNotifications(items, accountId, state) {
  var source = Array.isArray(items) ? items : []
  var selectedAccount = String(accountId || "")
  var selectedState = String(state || "all")
  return source.filter(function(item) {
    if (selectedAccount !== "" && String(item.accountId || "") !== selectedAccount) return false
    if (selectedState === "unread") return item.unread === true
    if (selectedState === "previous") return item.unread !== true
    return true
  })
}

function accountFilterOptions(accounts) {
  var options = [{ value: "", label: "All accounts" }]
  var source = Array.isArray(accounts) ? accounts.slice() : []
  source.sort(function(a, b) {
    return cleanText(a.name || "Basecamp").toLowerCase().localeCompare(
      cleanText(b.name || "Basecamp").toLowerCase())
  })
  for (var i = 0; i < source.length; i++) {
    options.push({ value: String(source[i].id || ""), label: cleanText(source[i].name || "Basecamp") })
  }
  return options
}

function notificationTypeIcon(type) {
  var value = String(type || "").toLowerCase()
  if (value === "mention") return "󰁥"      // md-at
  if (value === "comment") return "󰆉"      // md-comment_text_outline
  if (value === "chat") return "󰭹"         // md-chat
  if (value === "completion") return "󰄬"   // md-check
  if (value === "event") return "󰂚"        // md-bell
  if (value === "bulletin") return "󰃦"     // md-bullhorn
  if (value === "document") return "󰈙"     // md-file_document
  if (value === "hill") return "󰱐"         // md-chart_bell_curve
  if (value === "boostreport") return "󰑣"  // md-rocket
  return "󰍡"                               // md-message
}

function cleanText(value) {
  return String(value || "")
    .replace(/\\[nrt]/g, " ")
    .replace(/<br\s*\/?\s*>/gi, " ")
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, "\"")
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/\s+/g, " ")
    .trim()
}

function positiveInteger(value, fallback) {
  var number = parseInt(String(value), 10)
  return isFinite(number) && number > 0 ? number : fallback
}

var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function notificationTime(timestampMs, nowMs) {
  var value = Number(timestampMs || 0)
  if (!isFinite(value) || value <= 0) return ""
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var date = new Date(value)
  var ref = new Date(now)
  if (date.getFullYear() === ref.getFullYear() && date.getMonth() === ref.getMonth() && date.getDate() === ref.getDate()) {
    var hours = date.getHours()
    var hour12 = hours % 12 === 0 ? 12 : hours % 12
    var minutes = date.getMinutes()
    return hour12 + ":" + (minutes < 10 ? "0" + minutes : minutes) + (hours >= 12 ? "pm" : "am")
  }
  var label = MONTH_NAMES[date.getMonth()] + " " + date.getDate()
  if (date.getFullYear() !== ref.getFullYear()) label += ", " + date.getFullYear()
  return label
}

function notificationMeta(item, nowMs, showAccount) {
  if (!item) return ""
  var parts = []
  var age = notificationTime(item.timestampMs, nowMs)
  var creator = cleanText(item.creator || "")
  var project = cleanText(item.project || "")
  var account = cleanText(item.accountName || "")
  if (age !== "") parts.push(age)
  if (creator !== "") parts.push(creator)
  if (project !== "") {
    parts.push(showAccount === true && account !== "" ? project + " (" + account + ")" : project)
  } else if (showAccount === true && account !== "") {
    parts.push(account)
  }
  return parts.join(" • ")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseAccounts: parseAccounts,
    parseNotifications: parseNotifications,
    sortNotifications: sortNotifications,
    filterNotifications: filterNotifications,
    accountFilterOptions: accountFilterOptions,
    notificationTypeIcon: notificationTypeIcon,
    cleanText: cleanText,
    notificationTime: notificationTime,
    notificationMeta: notificationMeta
  }
}
