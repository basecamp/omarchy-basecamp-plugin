import QtQuick
import QtTest
import Quickshell.Io
import "../.."

TestCase {
  name: "ServiceProjects"

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

  function projectsPayload(id, name, updatedAt) {
    return JSON.stringify({ data: [
      {
        id: id,
        name: name,
        description: "A demo project",
        status: "active",
        app_url: "https://example.test/" + id,
        updated_at: updatedAt
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

  function test_projects_are_not_fetched_until_the_panel_asks_for_them() {
    completeAccounts()
    compare(findProcess(["basecamp", "projects", "list"]), null)

    service.refreshProjectsIfStale()

    var process = findProcess(["basecamp", "projects", "list"])
    verify(process !== null)
    compare(process.command, ["basecamp", "projects", "list", "--account", "1001", "--json"])
    compare(service.projectsRefreshing, true)
  }

  function test_projects_from_every_account_are_merged_newest_first() {
    completeAccounts()
    service.refreshProjectsIfStale()

    var process = findProcess(["basecamp", "projects", "list"])
    process.complete(0, projectsPayload(701, "Older", "2026-08-10T09:00:00Z"), "")
    compare(process.command, ["basecamp", "projects", "list", "--account", "1002", "--json"])
    process.complete(0, projectsPayload(711, "Newer", "2026-08-16T09:00:00Z"), "")

    compare(service.projectsRefreshing, false)
    compare(service.projects.length, 2)
    compare(service.projects[0].name, "Newer")
    compare(service.projects[0].accountName, "Northstar")
    compare(service.projects[1].name, "Older")
    compare(service.projectsError, "")
  }

  function test_projects_requested_before_the_accounts_arrive_load_afterwards() {
    service.refreshProjectsIfStale()
    compare(findProcess(["basecamp", "projects", "list"]), null)

    completeAccounts()

    var process = findProcess(["basecamp", "projects", "list"])
    verify(process !== null)
    compare(process.command[4], "1001")
  }

  function test_freshly_loaded_projects_are_not_fetched_again() {
    completeAccounts()
    service.refreshProjectsIfStale()

    var process = findProcess(["basecamp", "projects", "list"])
    process.complete(0, projectsPayload(701, "First", "2026-08-10T09:00:00Z"), "")
    process.complete(0, projectsPayload(711, "Second", "2026-08-16T09:00:00Z"), "")
    compare(process.running, false)

    service.refreshProjectsIfStale()
    compare(process.running, false)
    compare(service.projects.length, 2)
  }

  function test_a_failing_account_reports_an_error_and_keeps_the_others() {
    completeAccounts()
    service.refreshProjectsIfStale()

    var process = findProcess(["basecamp", "projects", "list"])
    process.complete(1, "", "Permission denied")
    process.complete(0, projectsPayload(711, "Kept", "2026-08-16T09:00:00Z"), "")

    compare(service.projects.length, 1)
    compare(service.projects[0].name, "Kept")
    compare(service.projectsError, "Acme: Permission denied")
    compare(service.projectsRefreshing, false)
  }
}
