import QtQuick
import QtTest
import Quickshell.Io
import "../.."

TestCase {
  name: "ServiceActionStatus"

  property var service: null

  Component {
    id: serviceComponent
    Service {}
  }

  Component {
    id: barViewComponent
    QtObject {
      property var service: null
      readonly property int unreadCount: service ? service.unreadCount : -1
      readonly property string accountFilter: service ? service.accountFilter : "missing"
      readonly property string stateFilter: service ? service.stateFilter : "missing"
    }
  }

  function init() {
    service = serviceComponent.createObject(this)
    verify(service !== null)
  }

  function cleanup() {
    service.destroy()
    service = null
  }

  function findReadProcess() {
    for (var i = 0; i < ProcessRegistry.processes.length; i++) {
      var process = ProcessRegistry.processes[i]
      if (process.command.length >= 3
          && process.command[0] === "basecamp"
          && process.command[1] === "notifications"
          && process.command[2] === "read") return process
    }
    return null
  }

  function findProbeProcess() {
    for (var i = 0; i < ProcessRegistry.processes.length; i++) {
      var process = ProcessRegistry.processes[i]
      if (process.command.length > 0 && process.command[0] === "bash" && process.running) return process
    }
    return null
  }

  function findSetupLockProcess() {
    for (var i = 0; i < ProcessRegistry.processes.length; i++) {
      var process = ProcessRegistry.processes[i]
      if (process.command.length > 0 && process.command[0] === "flock") return process
    }
    return null
  }

  function probeOutput(authOutput, version) {
    var cliVersion = version === undefined ? "0.9.1" : version
    return "basecamp-version:basecamp version " + String(cliVersion) + "\n" + String(authOutput || "")
  }

  function findAccountsProcess() {
    for (var i = 0; i < ProcessRegistry.processes.length; i++) {
      var process = ProcessRegistry.processes[i]
      if (process.command.length >= 2
          && process.command[0] === "basecamp"
          && process.command[1] === "accounts") return process
    }
    return null
  }

  function findNotificationListProcess() {
    for (var i = 0; i < ProcessRegistry.processes.length; i++) {
      var process = ProcessRegistry.processes[i]
      if (process.command.length >= 3
          && process.command[0] === "basecamp"
          && process.command[1] === "notifications"
          && process.command[2] === "list") return process
    }
    return null
  }

  function beginRead(id) {
    var item = {
      id: String(id),
      accountId: "42",
      url: "",
      unread: true
    }
    service.notifications = [item]
    service.markRead(item)

    compare(service.actionStatus, "Marking notification as read…")
    var process = findReadProcess()
    verify(process !== null)
    verify(process.running)
    return process
  }

  function test_confirmation_starts_after_the_read_finishes() {
    var process = beginRead("success")

    wait(2300)
    compare(service.actionStatus, "Marking notification as read…")

    process.complete(0, "{}", "")
    compare(service.actionStatus, "Marked as read")
    tryCompare(service, "actionStatus", "", 3000)
  }

  function test_failure_status_clears_after_displaying_the_cli_error() {
    var process = beginRead("failure")

    process.complete(1, "", "Permission denied")
    compare(service.lastError, "Permission denied")
    compare(service.actionStatus, "Permission denied")
    tryCompare(service, "actionStatus", "", 3000)
  }

  function test_queued_read_is_not_cleared_by_the_previous_confirmation_timer() {
    var firstProcess = beginRead("first")
    var secondProcess = beginRead("second")
    compare(firstProcess, secondProcess)

    firstProcess.complete(0, "{}", "")
    compare(service.actionStatus, "Marking notification as read…")

    wait(2300)
    compare(service.actionStatus, "Marking notification as read…")

    secondProcess.complete(0, "{}", "")
    compare(service.actionStatus, "Marked as read")
  }

  function test_missing_cli_stops_refreshing_and_flags_not_installed() {
    service.refresh()
    var probe = findProbeProcess()
    verify(probe !== null)
    probe.complete(0, "missing\n", "")
    compare(service.probed, true)
    compare(service.installed, false)
    compare(service.refreshing, false)
  }

  function test_unauthenticated_probe_stops_refreshing() {
    service.refresh()
    findProbeProcess().complete(0, probeOutput('{"ok":true,"data":{"authenticated":false},"summary":"Not authenticated"}'), "")
    compare(service.probed, true)
    compare(service.installed, true)
    compare(service.authenticated, false)
    compare(service.refreshing, false)
  }

  function test_authenticated_probe_proceeds_to_accounts() {
    service.refresh()
    findProbeProcess().complete(0, probeOutput('{"ok":true,"data":{"authenticated":true,"expired":false}}'), "")
    compare(service.authenticated, true)
    var accounts = findAccountsProcess()
    verify(accounts !== null)
    verify(accounts.running)
  }

  function test_auth_required_error_during_refresh_flips_authenticated() {
    service.refresh()
    findProbeProcess().complete(0, probeOutput('{"ok":true,"data":{"authenticated":true}}'), "")
    var accounts = findAccountsProcess()
    verify(accounts !== null)
    accounts.complete(3, '{"ok":false,"error":"Not authenticated. Run: basecamp auth login","code":"auth_required","hint":"Run: basecamp auth login"}', "")
    compare(service.authenticated, false)
    compare(service.refreshing, false)
    compare(service.lastError, "")
  }

  function test_structured_command_errors_show_message_not_json_data() {
    return [
      { tag: "accounts stdout", command: "accounts", stderr: false },
      { tag: "accounts stderr", command: "accounts", stderr: true },
      { tag: "notifications stdout", command: "notifications", stderr: false },
      { tag: "notifications stderr", command: "notifications", stderr: true },
      { tag: "mark read stdout", command: "read", stderr: false },
      { tag: "mark read stderr", command: "read", stderr: true }
    ]
  }

  function test_structured_command_errors_show_message_not_json(data) {
    var message = "Token refresh failed: network is unreachable"
    var envelope = JSON.stringify({ ok: false, error: message })
    var process
    if (data.command === "read") {
      process = beginRead("offline")
    } else {
      service.refresh()
      findProbeProcess().complete(0, probeOutput('{"ok":true,"data":{"authenticated":true}}'), "")
      if (data.command === "notifications") {
        findAccountsProcess().complete(0, '{"ok":true,"data":[{"id":42,"name":"One"}]}', "")
        process = findNotificationListProcess()
      } else {
        process = findAccountsProcess()
      }
    }
    process.complete(1, data.stderr ? "" : envelope, data.stderr ? envelope : "")
    compare(service.lastError, data.command === "notifications" ? "One: " + message : message)
    compare(service.authenticated, true)
    if (data.command === "read") compare(service.actionStatus, message)
    else compare(service.refreshing, false)
  }

  function test_outdated_cli_stops_refreshing_and_flags_unsupported() {
    service.refresh()
    findProbeProcess().complete(0, probeOutput('{"ok":true,"data":{"authenticated":true}}', "0.8.1"), "")
    compare(service.probed, true)
    compare(service.installed, true)
    compare(service.supported, false)
    compare(service.cliVersion, "0.8.1")
    compare(service.refreshing, false)
    compare(findAccountsProcess(), null)
  }

  function test_blank_cli_version_reports_error() {
    service.authenticated = false
    service.refresh()
    findProbeProcess().complete(0, probeOutput('{"ok":true,"data":{"authenticated":true}}', ""), "")
    compare(service.probed, true)
    compare(service.installed, true)
    compare(service.supported, true)
    compare(service.authenticated, true)
    compare(service.cliVersion, "")
    compare(service.lastError, "Could not determine the Basecamp CLI version")
    compare(service.refreshing, false)
    compare(findAccountsProcess(), null)
  }

  function test_probe_error_flag_sets_and_clears_across_probes() {
    service.refresh()
    findProbeProcess().complete(0, "garbage without version prefix\nmore garbage", "")
    compare(service.probeError, true)
    compare(service.refreshing, false)

    service.refresh()
    findProbeProcess().complete(0, probeOutput('{"ok":true,"data":{"authenticated":true}}'), "")
    compare(service.probeError, false)
    compare(service.authenticated, true)
  }

  function test_setup_stays_running_until_completion() {
    verify(service.tryStartSetup())
    compare(service.setupRunning, true)

    wait(50)
    verify(!service.tryStartSetup())
    compare(service.setupRunning, true)

    service.finishSetup()
    compare(service.setupRunning, false)
    verify(service.tryStartSetup())
    compare(service.setupRunning, true)
  }

  function test_setup_lock_check_recovers_stale_running_state() {
    service.setupRunning = true
    service.checkSetupRunning()

    var process = findSetupLockProcess()
    verify(process !== null)
    compare(process.command, ["flock", "-n", "/tmp/37signals.basecamp.setup.lock", "true"])
    verify(!service.tryStartSetup())

    process.complete(0, "", "")
    compare(service.setupRunning, false)
    verify(service.tryStartSetup())
  }

  function test_setup_lock_check_detects_a_running_process() {
    service.checkSetupRunning()

    var process = findSetupLockProcess()
    verify(process !== null)
    process.complete(1, "", "")
    compare(service.setupRunning, true)
  }

  function test_garbage_probe_output_reports_error_not_signin() {
    service.refresh()
    findProbeProcess().complete(0, probeOutput("not json at all"), "")
    compare(service.probed, true)
    compare(service.installed, true)
    compare(service.authenticated, true)
    verify(service.lastError !== "")
    compare(service.refreshing, false)
    compare(findAccountsProcess(), null)
  }

  function test_error_envelope_probe_output_reports_error_not_signin() {
    service.authenticated = false
    service.refresh()
    findProbeProcess().complete(0, probeOutput('{"ok":false,"error":"Config file is corrupt","code":"config"}'), "")
    compare(service.authenticated, true)
    verify(service.lastError.indexOf("Config file is corrupt") !== -1)
    compare(service.refreshing, false)
    compare(findAccountsProcess(), null)
  }

  function test_auth_required_mid_fetch_stops_the_refresh() {
    service.refresh()
    findProbeProcess().complete(0, probeOutput('{"ok":true,"data":{"authenticated":true}}'), "")
    findAccountsProcess().complete(0, '{"ok":true,"data":[{"id":1,"name":"One"},{"id":2,"name":"Two"}]}', "")

    var notificationList = findNotificationListProcess()
    verify(notificationList !== null)
    verify(notificationList.running)
    notificationList.complete(3, '{"ok":false,"error":"Not authenticated. Run: basecamp auth login","code":"auth_required"}', "")

    compare(service.authenticated, false)
    compare(service.refreshing, false)
    verify(!notificationList.running)
    compare(service.lastUpdated.getTime(), 0)
  }

  function test_retry_after_failed_probe_probes_again() {
    service.refresh()
    findProbeProcess().complete(0, "missing\n", "")
    compare(service.installed, false)

    service.refresh()
    var probe = findProbeProcess()
    verify(probe !== null)
    probe.complete(0, probeOutput('{"ok":true,"data":{"authenticated":true}}'), "")
    compare(service.installed, true)
    compare(service.authenticated, true)
    verify(findAccountsProcess().running)
  }

  function test_filters_default_to_all_accounts_and_unread() {
    compare(service.accountFilter, "")
    compare(service.stateFilter, "unread")
  }

  function test_closed_refresh_with_unread_resets_previous_tab() {
    service.setStateFilter("previous")
    service._fetchedNotifications = [{ id: "new", accountId: "42", unread: true }]
    service.finishRefresh()
    compare(service.stateFilter, "unread")
  }

  function test_closed_refresh_without_unread_keeps_previous_tab() {
    service.setStateFilter("previous")
    service._fetchedNotifications = [{ id: "old", accountId: "42", unread: false }]
    service.finishRefresh()
    compare(service.stateFilter, "previous")
  }

  function test_closed_refresh_checks_unread_across_accounts_without_changing_filter() {
    service.accounts = [{ id: "1", name: "One" }, { id: "2", name: "Two" }]
    service.setAccountFilter("1")
    service.setStateFilter("previous")
    service._fetchedNotifications = [{ id: "new", accountId: "2", unread: true }]
    service.finishRefresh()
    compare(service.stateFilter, "unread")
    compare(service.accountFilter, "1")
  }

  function test_refresh_uses_panel_visibility_at_completion_data() {
    return [
      { tag: "closed throughout", initiallyOpen: false, finallyOpen: false, expected: "unread" },
      { tag: "opened during hover refresh", initiallyOpen: false, finallyOpen: true, expected: "previous" },
      { tag: "open throughout", initiallyOpen: true, finallyOpen: true, expected: "previous" },
      { tag: "closed during refresh", initiallyOpen: true, finallyOpen: false, expected: "unread" }
    ]
  }

  function test_refresh_uses_panel_visibility_at_completion(data) {
    var view = createTemporaryObject(barViewComponent, this, { service: service })
    service.setPanelOpen(view, data.initiallyOpen)
    service.setStateFilter("previous")
    service.refresh()
    findProbeProcess().complete(0, probeOutput('{"ok":true,"data":{"authenticated":true}}'), "")
    findAccountsProcess().complete(0, '{"ok":true,"data":[{"id":42,"name":"One"}]}', "")
    service.setPanelOpen(view, data.finallyOpen)
    findNotificationListProcess().complete(0,
      '{"ok":true,"data":{"unreads":[{"id":"new","unread_at":"2026-10-05T12:00:00Z"}],"reads":[]}}', "")
    compare(service.stateFilter, data.expected)
    compare(service.notifications[0].unread, true)
  }

  function test_one_closed_monitor_does_not_override_an_open_monitor() {
    var viewA = createTemporaryObject(barViewComponent, this, { service: service })
    var viewB = createTemporaryObject(barViewComponent, this, { service: service })
    service.setPanelOpen(viewA, true)
    service.setPanelOpen(viewA, true)
    service.setPanelOpen(viewB, true)
    service.setPanelOpen(viewA, false)
    service.setPanelOpen(viewA, false)
    service.setStateFilter("previous")
    service._fetchedNotifications = [{ id: "new", accountId: "42", unread: true }]
    service.finishRefresh()
    compare(viewB.stateFilter, "previous")

    service.setPanelOpen(viewB, false)
    service.finishRefresh()
    compare(viewA.stateFilter, "unread")
    compare(viewB.stateFilter, "unread")
  }

  function test_failed_refresh_does_not_reset_previous_tab() {
    service.notifications = [{ id: "existing", accountId: "42", unread: true }]
    service.setStateFilter("previous")
    service.refresh()
    findProbeProcess().complete(0, "missing\n", "")
    compare(service.stateFilter, "previous")
  }

  function test_two_bar_views_share_account_and_state_filters() {
    var viewA = barViewComponent.createObject(this, { service: service })
    var viewB = barViewComponent.createObject(this, { service: service })

    service.setAccountFilter("42")
    compare(viewA.accountFilter, "42")
    compare(viewB.accountFilter, "42")

    service.setStateFilter("previous")
    compare(viewA.stateFilter, "previous")
    compare(viewB.stateFilter, "previous")

    viewA.destroy()
    viewB.destroy()
  }

  function test_unread_count_follows_account_filter() {
    service.notifications = [
      { id: "a", accountId: "1", unread: true },
      { id: "b", accountId: "2", unread: true }
    ]

    compare(service.unreadCount, 2)
    service.setAccountFilter("1")
    compare(service.unreadCount, 1)
    service.setAccountFilter("missing")
    compare(service.unreadCount, 0)
  }

  function test_two_bar_views_share_optimistic_mark_read() {
    var item = {
      id: "shared",
      accountId: "42",
      url: "",
      unread: true
    }
    service.notifications = [item]

    var viewA = barViewComponent.createObject(this, { service: service })
    var viewB = barViewComponent.createObject(this, { service: service })
    compare(viewA.unreadCount, 1)
    compare(viewB.unreadCount, 1)

    service.markRead(item)
    compare(viewA.unreadCount, 0)
    compare(viewB.unreadCount, 0)
    compare(service.notifications[0].unread, false)

    viewA.destroy()
    viewB.destroy()
  }

  function test_stale_account_filter_clears_when_accounts_change() {
    service.setAccountFilter("gone")
    service.accounts = [{ id: "1", name: "One" }]
    compare(service.accountFilter, "")
  }

  function test_matching_account_filter_is_kept_when_accounts_change() {
    service.setAccountFilter("1")
    service.accounts = [{ id: "1", name: "One" }]
    compare(service.accountFilter, "1")
  }

  function test_blank_state_filter_falls_back_to_unread() {
    service.setStateFilter("previous")
    service.setStateFilter("")
    compare(service.stateFilter, "unread")
  }
  function bubbleUp(id, accountId) {
    return { id: String(id), accountId: String(accountId), unread: false, bubbledUp: true }
  }

  function test_bubbled_tab_requires_bubble_ups_in_the_selected_account() {
    service.accounts = [{ id: "1", name: "One" }, { id: "2", name: "Two" }]
    service.notifications = [bubbleUp("b", "1")]
    service.setAccountFilter("2")
    service.setStateFilter("previous")

    service.setStateFilter("bubbled")
    compare(service.stateFilter, "previous")

    service.setAccountFilter("1")
    service.setStateFilter("bubbled")
    compare(service.stateFilter, "bubbled")
  }

  function test_bubbled_tab_falls_back_when_the_account_filter_has_none() {
    service.accounts = [{ id: "1", name: "One" }, { id: "2", name: "Two" }]
    service.notifications = [bubbleUp("b", "1")]
    service.setStateFilter("bubbled")
    compare(service.stateFilter, "bubbled")

    service.setAccountFilter("2")
    compare(service.bubbledUpCount, 0)
    compare(service.stateFilter, "unread")
  }

  function test_bubbled_tab_falls_back_when_a_refresh_removes_the_last_bubble_up() {
    service.notifications = [bubbleUp("b", "1")]
    service.setStateFilter("bubbled")

    service._fetchedNotifications = [{ id: "old", accountId: "1", unread: false, bubbledUp: false }]
    service.finishRefresh()
    compare(service.stateFilter, "unread")
  }

}
