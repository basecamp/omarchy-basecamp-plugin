import QtQuick
import QtTest
import Quickshell.Io
import "../.."

TestCase {
  name: "ServiceBookmarks"

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

  // Newest first: the registry outlives destroyed services for a few event
  // loop turns, and the service under test always registered last.
  function findProcess(prefix) {
    for (var i = ProcessRegistry.processes.length - 1; i >= 0; i--) {
      var process = ProcessRegistry.processes[i]
      var command = process.command
      if (command.length < prefix.length) continue
      var matches = true
      for (var p = 0; p < prefix.length; p++) {
        if (command[p] !== prefix[p]) matches = false
      }
      if (matches) return process
    }
    return null
  }

  function accountsPayload() {
    return JSON.stringify({ data: [
      { id: 1001, name: "Acme" },
      { id: 1002, name: "Northstar" }
    ]})
  }

  function bookmarksPayload(id, title, createdAt) {
    return JSON.stringify({ data: [
      {
        id: id,
        created_at: createdAt,
        recording: {
          title: title,
          type: "Todoset",
          app_url: "https://example.test/" + id,
          bucket: { id: 1, name: "A project", type: "Project" }
        }
      }
    ]})
  }

  // The poll timer starts this fetch on its own, but not before the test body
  // runs. refresh() is a no-op while that request is already in flight.
  function completeAccounts() {
    service.refresh()
    var process = findProcess(["basecamp", "accounts", "list"])
    verify(process !== null)
    process.complete(0, accountsPayload(), "")
  }

  function test_bookmarks_are_not_fetched_until_the_panel_asks_for_them() {
    completeAccounts()
    compare(findProcess(["basecamp", "api", "get"]), null)

    service.refreshBookmarksIfStale()

    var process = findProcess(["basecamp", "api", "get"])
    verify(process !== null)
    compare(process.command, [
      "basecamp", "api", "get", "my/bookmarks.json", "--account", "1001", "--json"
    ])
    compare(service.bookmarksRefreshing, true)
  }

  function test_bookmarks_from_every_account_are_merged_newest_first() {
    completeAccounts()
    service.refreshBookmarksIfStale()

    var process = findProcess(["basecamp", "api", "get"])
    process.complete(0, bookmarksPayload(601, "Older", "2026-06-12T09:00:00Z"), "")
    compare(process.command[5], "1002")
    process.complete(0, bookmarksPayload(611, "Newer", "2026-08-08T09:00:00Z"), "")

    compare(service.bookmarksRefreshing, false)
    compare(service.bookmarks.length, 2)
    compare(service.bookmarks[0].title, "Newer")
    compare(service.bookmarks[0].accountName, "Northstar")
    compare(service.bookmarks[1].title, "Older")
    compare(service.bookmarksError, "")
  }

  function test_bookmarks_requested_before_the_accounts_arrive_load_afterwards() {
    service.refreshBookmarksIfStale()
    compare(findProcess(["basecamp", "api", "get"]), null)

    completeAccounts()

    var process = findProcess(["basecamp", "api", "get"])
    verify(process !== null)
    compare(process.command[5], "1001")
  }

  function test_freshly_loaded_bookmarks_are_not_fetched_again() {
    completeAccounts()
    service.refreshBookmarksIfStale()

    var process = findProcess(["basecamp", "api", "get"])
    process.complete(0, bookmarksPayload(601, "First", "2026-06-12T09:00:00Z"), "")
    process.complete(0, bookmarksPayload(611, "Second", "2026-08-08T09:00:00Z"), "")
    compare(process.running, false)

    service.refreshBookmarksIfStale()
    compare(process.running, false)
    compare(service.bookmarks.length, 2)
  }

  function test_a_failing_account_reports_an_error_and_keeps_the_others() {
    completeAccounts()
    service.refreshBookmarksIfStale()

    var process = findProcess(["basecamp", "api", "get"])
    process.complete(1, "", "Permission denied")
    process.complete(0, bookmarksPayload(611, "Kept", "2026-08-08T09:00:00Z"), "")

    compare(service.bookmarks.length, 1)
    compare(service.bookmarks[0].title, "Kept")
    compare(service.bookmarksError, "Acme: Permission denied")
    compare(service.bookmarksRefreshing, false)
  }
}
