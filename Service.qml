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
  property bool setupRunning: false
  readonly property string setupLockPath: Model.setupLockPath(Quickshell.env("XDG_RUNTIME_DIR"))
  readonly property bool setupChecking: setupLockProcess.running
  // True when the probe itself failed (unreadable version or auth status) —
  // distinct from setup states, so the panel can keep retrying: a transient
  // failure mid-install/mid-login must not strand a stuck error.
  property bool probeError: false
  property string cliVersion: ""
  property var accounts: []
  property var notifications: []
  readonly property int unreadCount: Model.unreadCount(notifications, accountFilter)
  readonly property int bubbledUpCount: Model.filterNotifications(notifications, accountFilter, "bubbled").length
  property date lastUpdated: new Date(0)
  property string lastError: ""
  property string actionStatus: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 600, 60, 3600)
  readonly property int maxPerAccount: intSetting("maxPerAccount", 20, 5, 50)
  readonly property int accountCount: accounts.length

  property string accountFilter: ""
  property string stateFilter: "unread"
  property var _openPanels: []

  property string _probeOutput: ""
  property string _accountsOutput: ""
  property string _accountsError: ""
  property var _fetchAccounts: []
  property var _fetchedNotifications: []
  property int _fetchIndex: 0
  property var _currentAccount: null
  property string _notificationsOutput: ""
  property string _notificationsError: ""
  property var _actionQueue: []
  property var _currentAction: null
  property string _actionOutput: ""
  property string _actionError: ""
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
    var text = String(value || fallback || "Basecamp request failed")
    try {
      var result = JSON.parse(text)
      if (result && result.ok === false)
        text = Model.cleanText(result.error || result.message || "The Basecamp CLI request failed")
    } catch (error) {
      // Plain-text CLI failures still carry useful diagnostics.
    }
    text = text.replace(/\s+/g, " ").trim()
    return text.length > 180 ? text.substring(0, 177) + "…" : text
  }

  function setAccountFilter(value) {
    accountFilter = String(value || "")
  }

  // The bubbled tab only exists while the selected account view has
  // bubble-ups, so it can never be selected empty.
  function setStateFilter(value) {
    var next = String(value || "unread")
    if (next === "bubbled" && bubbledUpCount === 0) return
    stateFilter = next
  }

  // Tab state is shared across monitors: never reset it while any panel is open.
  function setPanelOpen(panel, opened) {
    var index = _openPanels.indexOf(panel)
    if (opened && index === -1) _openPanels.push(panel)
    else if (!opened && index !== -1) _openPanels.splice(index, 1)
  }

  function ensureAccountFilter() {
    if (accountFilter === "") return
    for (var i = 0; i < accounts.length; i++) {
      if (String(accounts[i].id) === accountFilter) return
    }
    setAccountFilter("")
  }

  onAccountsChanged: ensureAccountFilter()

  // Leave the bubbled tab once its last item is gone, whether a refresh
  // removed it or the account filter moved to an account without any.
  onBubbledUpCountChanged: if (stateFilter === "bubbled" && bubbledUpCount === 0) setStateFilter("unread")

  function refreshIfStale() {
    var updatedAt = lastUpdated instanceof Date ? lastUpdated.getTime() : 0
    if (updatedAt <= 0 || Date.now() - updatedAt >= refreshIntervalSec * 1000) refresh()
  }

  function tryStartSetup() {
    if (setupRunning || setupChecking) return false
    setupRunning = true
    return true
  }

  function finishSetup() {
    setupRunning = false
  }

  function checkSetupRunning() {
    if (!setupLockProcess.running) setupLockProcess.running = true
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
    if (_openPanels.length === 0 && Model.unreadCount(notifications, "") > 0)
      setStateFilter("unread")
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
    enqueueAction({
      command: ["basecamp", "notifications", "read", String(item.id), "--account", String(item.accountId), "--json"],
      pending: "Marking notification as read…",
      done: "Marked as read",
      failure: "Could not mark the notification as read"
    })
  }

  function popBubbleUp(item) {
    if (!item || item.bubbledUp !== true || !item.recordingId) return
    notifications = notifications.filter(function(existing) {
      return !(existing.bubbledUp === true && existing.id === item.id && existing.accountId === item.accountId)
    })
    enqueueAction({
      command: ["basecamp", "bubble-up", "remove", String(item.recordingId), "--account", String(item.accountId), "--json"],
      pending: "Popping bubble-up…",
      done: "Popped bubble-up",
      failure: "Could not pop the bubble-up"
    })
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
  }

  // Reads and pops share one CLI process so their status messages never
  // interleave: each action starts only after the previous one exits.
  function enqueueAction(action) {
    var queue = _actionQueue.slice()
    queue.push(action)
    _actionQueue = queue
    runNextAction()
  }

  function runNextAction() {
    if (actionProcess.running || _actionQueue.length === 0) return
    var queue = _actionQueue.slice()
    _currentAction = queue.shift()
    _actionQueue = queue
    _actionOutput = ""
    _actionError = ""
    actionStatusTimer.stop()
    actionStatus = _currentAction.pending
    actionProcess.command = _currentAction.command
    actionProcess.running = true
  }

  function finishAction(exitCode, stdout, stderr) {
    if (exitCode !== 0) {
      lastError = conciseError(stderr || stdout, _currentAction.failure)
      actionStatus = lastError
    } else {
      actionStatus = _currentAction.done
    }
    actionStatusTimer.restart()
    _currentAction = null
    if (_actionQueue.length > 0) runNextAction()
    else refreshAfterAction.restart()
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
    id: refreshAfterAction
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
    id: setupLockProcess
    running: false
    command: ["flock", "-n", root.setupLockPath, "true"]
    onExited: function(exitCode) {
      // Exit 0 acquired the lock, so no setup process holds it. Any other
      // result fails closed and keeps duplicate authentication blocked.
      root.setupRunning = exitCode !== 0
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: actionStdout
      waitForEnd: true
      onStreamFinished: root._actionOutput = text
    }
    stderr: StdioCollector {
      id: actionStderr
      waitForEnd: true
      onStreamFinished: root._actionError = text
    }
    onExited: function(exitCode) {
      var stdout = String(actionStdout.text || root._actionOutput || "")
      var stderr = String(actionStderr.text || root._actionError || "")
      root.finishAction(exitCode, stdout, stderr)
    }
  }
}
