import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property bool refreshing: false
  property bool installed: true
  property var accounts: []
  property var notifications: []
  property int unreadCount: 0
  property date lastUpdated: new Date(0)
  property string lastError: ""
  property string actionStatus: ""

  property var bookmarks: []
  property bool bookmarksRefreshing: false
  property date bookmarksLastUpdated: new Date(0)
  property string bookmarksError: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 600, 60, 3600)
  readonly property int maxPerAccount: intSetting("maxPerAccount", 20, 5, 50)
  readonly property int accountCount: accounts.length

  property string _accountsOutput: ""
  property string _accountsError: ""
  property var _fetchAccounts: []
  property var _fetchedNotifications: []
  property int _fetchIndex: 0
  property var _currentAccount: null
  property string _notificationsOutput: ""
  property string _notificationsError: ""
  property bool _bookmarksPending: false
  property var _bookmarkAccounts: []
  property var _fetchedBookmarks: []
  property int _bookmarkIndex: 0
  property var _currentBookmarkAccount: null
  property string _bookmarksOutput: ""
  property string _bookmarksErrorOutput: ""
  property var _bookmarkErrors: []
  property var _readQueue: []
  property var _readingNotification: null
  property string _readOutput: ""
  property string _readError: ""
  property var _partialErrors: []

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function conciseError(value, fallback) {
    var text = String(value || fallback || "Basecamp request failed").replace(/\s+/g, " ").trim()
    return text.length > 180 ? text.substring(0, 177) + "…" : text
  }

  function refreshIfStale() {
    var updatedAt = lastUpdated instanceof Date ? lastUpdated.getTime() : 0
    if (updatedAt <= 0 || Date.now() - updatedAt >= refreshIntervalSec * 1000) refresh()
  }

  function refresh() {
    if (refreshing || accountsProcess.running || notificationProcess.running) return
    refreshing = true
    installed = true
    lastError = ""
    _partialErrors = []
    _accountsOutput = ""
    _accountsError = ""
    accountsProcess.command = ["basecamp", "accounts", "list", "--json"]
    accountsProcess.running = true
  }

  function beginNotificationFetch(nextAccounts) {
    _fetchAccounts = nextAccounts
    _fetchedNotifications = []
    _fetchIndex = 0
    fetchNextAccount()
  }

  function fetchNextAccount() {
    if (_fetchIndex >= _fetchAccounts.length) {
      finishRefresh()
      return
    }

    _currentAccount = _fetchAccounts[_fetchIndex]
    _notificationsOutput = ""
    _notificationsError = ""
    notificationProcess.command = [
      "basecamp", "notifications", "list",
      "--account", String(_currentAccount.id),
      "--json"
    ]
    notificationProcess.running = true
  }

  function finishRefresh() {
    notifications = Model.sortNotifications(_fetchedNotifications)
    var unread = 0
    for (var i = 0; i < notifications.length; i++) if (notifications[i].unread) unread += 1
    unreadCount = unread
    refreshing = false
    lastUpdated = new Date()
    lastError = _partialErrors.length > 0 ? _partialErrors.join(" · ") : ""
  }

  function refreshBookmarksIfStale() {
    var updatedAt = bookmarksLastUpdated instanceof Date ? bookmarksLastUpdated.getTime() : 0
    if (updatedAt <= 0 || Date.now() - updatedAt >= refreshIntervalSec * 1000) refreshBookmarks()
  }

  function refreshBookmarks() {
    if (bookmarksRefreshing) return
    bookmarksRefreshing = true
    bookmarksError = ""
    _bookmarkErrors = []

    // Bookmarks are loaded lazily, so the account list can still be on its way.
    if (accounts.length === 0) {
      _bookmarksPending = true
      refresh()
      return
    }
    beginBookmarkFetch(accounts)
  }

  function beginBookmarkFetch(nextAccounts) {
    _bookmarksPending = false
    _bookmarkAccounts = nextAccounts
    _fetchedBookmarks = []
    _bookmarkIndex = 0
    fetchNextBookmarkAccount()
  }

  // The CLI has no bookmarks command yet, so this goes through the raw API
  // passthrough. Swapping in `basecamp bookmarks list` later is a change to
  // this command only.
  function bookmarkCommand(accountId) {
    return [
      "basecamp", "api", "get", "my/bookmarks.json",
      "--account", String(accountId),
      "--json"
    ]
  }

  function fetchNextBookmarkAccount() {
    if (_bookmarkIndex >= _bookmarkAccounts.length) {
      finishBookmarkRefresh()
      return
    }

    _currentBookmarkAccount = _bookmarkAccounts[_bookmarkIndex]
    _bookmarksOutput = ""
    _bookmarksErrorOutput = ""
    bookmarksProcess.command = bookmarkCommand(_currentBookmarkAccount.id)
    bookmarksProcess.running = true
  }

  function finishBookmarkRefresh() {
    bookmarks = Model.sortBookmarks(_fetchedBookmarks)
    bookmarksRefreshing = false
    bookmarksLastUpdated = new Date()
    bookmarksError = _bookmarkErrors.length > 0 ? _bookmarkErrors.join(" · ") : ""
  }

  // A bookmarks request that is still waiting for the account list has nothing
  // left to wait for once that list fails.
  function abandonPendingBookmarks(error) {
    if (!_bookmarksPending) return
    _bookmarksPending = false
    bookmarksRefreshing = false
    bookmarksError = error
  }

  function openBookmark(item) {
    if (item && item.url) Qt.openUrlExternally(String(item.url))
  }

  function openNotification(item) {
    if (!item) return
    if (item.url) Qt.openUrlExternally(String(item.url))
    if (item.unread) markRead(item)
  }

  function markRead(item) {
    if (!item || !item.unread) return
    setReadOptimistically(item)
    var queue = _readQueue.slice()
    queue.push(item)
    _readQueue = queue
    runNextRead()
  }

  function setReadOptimistically(item) {
    var changed = []
    for (var i = 0; i < notifications.length; i++) {
      var existing = notifications[i]
      if (existing.id === item.id && existing.accountId === item.accountId) {
        var replacement = {}
        for (var key in existing) replacement[key] = existing[key]
        replacement.unread = false
        changed.push(replacement)
      } else {
        changed.push(existing)
      }
    }
    notifications = changed
    unreadCount = Math.max(0, unreadCount - 1)
  }

  function runNextRead() {
    if (readProcess.running || _readQueue.length === 0) return
    var queue = _readQueue.slice()
    _readingNotification = queue.shift()
    _readQueue = queue
    _readOutput = ""
    _readError = ""
    actionStatusTimer.stop()
    actionStatus = "Marking notification as read…"
    readProcess.command = [
      "basecamp", "notifications", "read",
      String(_readingNotification.id),
      "--account", String(_readingNotification.accountId),
      "--json"
    ]
    readProcess.running = true
  }

  function finishRead(exitCode, stdout, stderr) {
    if (exitCode !== 0) {
      lastError = conciseError(stderr || stdout, "Could not mark the notification as read")
      actionStatus = lastError
    } else {
      actionStatus = "Marked as read"
    }
    actionStatusTimer.restart()
    _readingNotification = null
    if (_readQueue.length > 0) runNextRead()
    else refreshAfterRead.restart()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: refreshAfterRead
    interval: 1200
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: accountsProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: accountsStdout
      waitForEnd: true
      onStreamFinished: root._accountsOutput = text
    }
    stderr: StdioCollector {
      id: accountsStderr
      waitForEnd: true
      onStreamFinished: root._accountsError = text
    }
    onExited: function(exitCode) {
      var stdout = String(accountsStdout.text || root._accountsOutput || "")
      var stderr = String(accountsStderr.text || root._accountsError || "")
      if (exitCode !== 0) {
        root.installed = exitCode !== 127
        root.lastError = root.conciseError(stderr || stdout, root.installed ? "Could not list Basecamp accounts" : "Basecamp CLI is not installed")
        root.refreshing = false
        root.abandonPendingBookmarks(root.lastError)
        return
      }

      var parsed = Model.parseAccounts(stdout)
      if (!parsed.ok) {
        root.lastError = parsed.error
        root.refreshing = false
        root.abandonPendingBookmarks(parsed.error)
        return
      }
      root.accounts = parsed.accounts
      if (root._bookmarksPending) root.beginBookmarkFetch(parsed.accounts)
      root.beginNotificationFetch(parsed.accounts)
    }
  }

  Process {
    id: notificationProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: notificationsStdout
      waitForEnd: true
      onStreamFinished: root._notificationsOutput = text
    }
    stderr: StdioCollector {
      id: notificationsStderr
      waitForEnd: true
      onStreamFinished: root._notificationsError = text
    }
    onExited: function(exitCode) {
      var account = root._currentAccount
      var stdout = String(notificationsStdout.text || root._notificationsOutput || "")
      var stderr = String(notificationsStderr.text || root._notificationsError || "")
      if (exitCode === 0) {
        var parsed = Model.parseNotifications(stdout, account, root.maxPerAccount)
        if (parsed.ok) root._fetchedNotifications = root._fetchedNotifications.concat(parsed.items)
        else root._partialErrors.push(account.name + ": " + parsed.error)
      } else {
        root._partialErrors.push(account.name + ": " + root.conciseError(stderr || stdout, "request failed"))
      }
      root._fetchIndex += 1
      root.fetchNextAccount()
    }
  }

  Process {
    id: bookmarksProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: bookmarksStdout
      waitForEnd: true
      onStreamFinished: root._bookmarksOutput = text
    }
    stderr: StdioCollector {
      id: bookmarksStderr
      waitForEnd: true
      onStreamFinished: root._bookmarksErrorOutput = text
    }
    onExited: function(exitCode) {
      var account = root._currentBookmarkAccount
      var stdout = String(bookmarksStdout.text || root._bookmarksOutput || "")
      var stderr = String(bookmarksStderr.text || root._bookmarksErrorOutput || "")
      if (exitCode === 0) {
        var parsed = Model.parseBookmarks(stdout, account)
        if (parsed.ok) root._fetchedBookmarks = root._fetchedBookmarks.concat(parsed.items)
        else root._bookmarkErrors.push(account.name + ": " + parsed.error)
      } else {
        root._bookmarkErrors.push(account.name + ": " + root.conciseError(stderr || stdout, "request failed"))
      }
      root._bookmarkIndex += 1
      root.fetchNextBookmarkAccount()
    }
  }

  Process {
    id: readProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: readStdout
      waitForEnd: true
      onStreamFinished: root._readOutput = text
    }
    stderr: StdioCollector {
      id: readStderr
      waitForEnd: true
      onStreamFinished: root._readError = text
    }
    onExited: function(exitCode) {
      var stdout = String(readStdout.text || root._readOutput || "")
      var stderr = String(readStderr.text || root._readError || "")
      root.finishRead(exitCode, stdout, stderr)
    }
  }
}
