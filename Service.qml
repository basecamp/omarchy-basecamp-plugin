import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property bool refreshing: false
  property bool installed: true
  property bool supported: true
  property bool authenticated: true
  property bool probed: false
  // True when the probe itself failed (unreadable version or auth status) —
  // distinct from setup states, so the panel can keep retrying: a transient
  // failure mid-install/mid-login must not strand a stuck error.
  property bool probeError: false
  property string cliVersion: ""
  property var accounts: []
  property var notifications: []
  property int unreadCount: 0
  property date lastUpdated: new Date(0)
  property string lastError: ""
  property string actionStatus: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 600, 60, 3600)
  readonly property int maxPerAccount: intSetting("maxPerAccount", 20, 5, 50)
  readonly property int accountCount: accounts.length

  property string _probeOutput: ""
  property string _accountsOutput: ""
  property string _accountsError: ""
  property var _fetchAccounts: []
  property var _fetchedNotifications: []
  property int _fetchIndex: 0
  property var _currentAccount: null
  property string _notificationsOutput: ""
  property string _notificationsError: ""
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
    if (refreshing || probeProcess.running || accountsProcess.running || notificationProcess.running) return
    refreshing = true
    lastError = ""
    _partialErrors = []
    // Probe on every refresh: a bare `basecamp` process would never emit
    // `exited` if the binary vanished since the last check, sticking
    // `refreshing` forever. The probe's bash wrapper always exits.
    _probeOutput = ""
    probeProcess.running = true
  }

  function fetchAccounts() {
    _accountsOutput = ""
    _accountsError = ""
    accountsProcess.command = ["basecamp", "accounts", "list", "--json"]
    accountsProcess.running = true
  }

  function finishProbe(stdout) {
    probed = true
    probeError = false
    var text = String(stdout || "")
    if (text.trim() === "missing") {
      installed = false
      supported = true
      cliVersion = ""
      refreshing = false
      return
    }
    installed = true
    supported = true
    cliVersion = ""

    // Probe stdout starts with `basecamp-version:<basecamp version output>`;
    // the remaining lines contain the `auth status --json` response.
    var separator = text.indexOf("\n")
    var versionPrefix = "basecamp-version:"
    if (separator < 0 || text.indexOf(versionPrefix) !== 0) {
      authenticated = true
      probeError = true
      lastError = "Could not determine the Basecamp CLI version"
      refreshing = false
      return
    }

    var parsedVersion = Model.parseCliVersion(text.substring(versionPrefix.length, separator))
    if (!parsedVersion.ok) {
      authenticated = true
      probeError = true
      lastError = parsedVersion.error
      refreshing = false
      return
    }
    cliVersion = parsedVersion.version
    supported = parsedVersion.supported
    if (!supported) {
      refreshing = false
      return
    }

    // Only a well-formed `auth status` success is authoritative for the
    // authenticated flag. Errors and garbage get the error line instead —
    // telling the user to log in can't fix those.
    var result = Model.parseJson(text.substring(separator + 1))
    if (!result.ok || !result.value.data) {
      authenticated = true
      probeError = true
      lastError = conciseError("Could not check the Basecamp CLI: " + (result.error || "unexpected response"))
      refreshing = false
      return
    }
    authenticated = result.value.data.authenticated === true
    if (authenticated) fetchAccounts()
    else refreshing = false
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
    id: probeProcess
    running: false
    // bash always exists, so `exited` always fires — a bare `basecamp`
    // command would silently never exit when the binary is missing.
    command: ["bash", "-c", "command -v basecamp >/dev/null 2>&1 || { echo missing; exit 0; }; version=$(basecamp version) || exit $?; printf 'basecamp-version:%s\\n' \"$version\"; basecamp auth status --json"]
    stdout: StdioCollector {
      id: probeStdout
      waitForEnd: true
      onStreamFinished: root._probeOutput = text
    }
    onExited: function(exitCode) {
      root.finishProbe(String(probeStdout.text || root._probeOutput || ""))
    }
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
        if (Model.parseJson(stdout).code === "auth_required") {
          root.authenticated = false
          root.refreshing = false
          return
        }
        root.lastError = root.conciseError(stderr || stdout, "Could not list Basecamp accounts")
        root.refreshing = false
        return
      }

      var parsed = Model.parseAccounts(stdout)
      if (!parsed.ok) {
        root.lastError = parsed.error
        root.refreshing = false
        return
      }
      root.accounts = parsed.accounts
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
      } else if (Model.parseJson(stdout).code === "auth_required") {
        // Shared credentials: every remaining account would fail the same
        // way, so stop the refresh instead of finishing as if it completed.
        root.authenticated = false
        root.refreshing = false
        return
      } else {
        root._partialErrors.push(account.name + ": " + root.conciseError(stderr || stdout, "request failed"))
      }
      root._fetchIndex += 1
      root.fetchNextAccount()
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
