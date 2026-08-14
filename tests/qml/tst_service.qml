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

  function beginRead(id) {
    var item = {
      id: String(id),
      accountId: "42",
      url: "",
      unread: true
    }
    service.notifications = [item]
    service.unreadCount = 1
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
}
