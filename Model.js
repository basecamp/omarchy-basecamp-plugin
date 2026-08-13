function parseJson(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, error: "The Basecamp CLI returned no data" }

  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return { ok: false, error: "The Basecamp CLI returned invalid data" }
    if (parsed.ok === false) return { ok: false, error: cleanText(parsed.error || parsed.message || "The Basecamp CLI request failed") }
    return { ok: true, value: parsed }
  } catch (error) {
    return { ok: false, error: "Could not parse the Basecamp CLI response" }
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

function normalizeNotification(value, account, unread) {
  var item = value || {}
  var id = String(item.id || "").trim()
  if (id === "") return null

  var timestamp = String(item.updated_at || item.created_at || "")
  var parsedTime = Date.parse(timestamp)
  if (!isFinite(parsedTime)) parsedTime = 0

  return {
    id: id,
    accountId: String(account.id || ""),
    accountName: cleanText(account.name || "Basecamp"),
    accountOrder: Number(account.order || 0),
    title: cleanText(item.title || item.readable_identifier || "Basecamp notification"),
    excerpt: cleanText(item.content_excerpt || ""),
    project: cleanText(item.bucket_name || item.section || ""),
    type: cleanText(item.type || ""),
    timestamp: timestamp,
    timestampMs: parsedTime,
    url: String(item.app_url || ""),
    unread: unread === true
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
  if (value === "mention") return "󰌻"
  if (value === "comment") return "󰆉"
  if (value === "chat") return "󰭹"
  if (value === "completion") return "󰄬"
  if (value === "event") return "󰃭"
  if (value === "bulletin") return "󰀦"
  if (value === "document") return "󰈙"
  if (value === "hill") return "󰔐"
  if (value === "boostreport") return "󰓎"
  return "󰍡"
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

function relativeTime(timestampMs, nowMs) {
  var value = Number(timestampMs || 0)
  if (!isFinite(value) || value <= 0) return ""
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var seconds = Math.max(0, Math.floor((now - value) / 1000))
  if (seconds < 60) return "Just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.floor(days / 365) + "y ago"
}

function notificationMeta(item, nowMs) {
  if (!item) return ""
  var parts = []
  var account = cleanText(item.accountName || "")
  var project = cleanText(item.project || "")
  var age = relativeTime(item.timestampMs, nowMs)
  if (account !== "") parts.push(account)
  if (project !== "") parts.push(project)
  if (age !== "") parts.push(age)
  return parts.join(" · ")
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
    relativeTime: relativeTime,
    notificationMeta: notificationMeta
  }
}
