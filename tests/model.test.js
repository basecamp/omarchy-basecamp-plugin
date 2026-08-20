const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

const account = { id: "42", name: "Main & Co", order: 1 }

function notification(overrides = {}) {
  return Object.assign({
    id: 10,
    title: "A notification",
    content_excerpt: "Details",
    bucket_name: "Project",
    type: "comment",
    updated_at: "2026-08-14T13:05:00Z",
    app_url: "https://example.test/10"
  }, overrides)
}

function payload(data) {
  return JSON.stringify({ data })
}

test("parseCliVersion requires Basecamp CLI 0.9 or newer", () => {
  assert.deepEqual(Model.parseCliVersion("basecamp version 0.8.1"), {
    ok: true,
    error: "",
    version: "0.8.1",
    supported: false
  })
  assert.equal(Model.parseCliVersion("basecamp version 0.9.0").supported, true)
  assert.equal(Model.parseCliVersion("basecamp version 0.10.0").supported, true)
  assert.equal(Model.parseCliVersion("basecamp version 1.0.0").supported, true)
  assert.deepEqual(Model.parseCliVersion("basecamp version 0.9.0+linux.x86-64"), {
    ok: true,
    error: "",
    version: "0.9.0+linux.x86-64",
    supported: true
  })
  assert.deepEqual(Model.parseCliVersion("basecamp version 0.9.1+linux.x86-64"), {
    ok: true,
    error: "",
    version: "0.9.1+linux.x86-64",
    supported: true
  })
  assert.equal(Model.parseCliVersion("basecamp version 0.9.0-rc.1").supported, false)
  assert.equal(Model.parseCliVersion("basecamp version 0.9.1-rc.1").supported, true)
  assert.equal(Model.parseCliVersion("basecamp version 1.0.0-rc.1").supported, true)
  assert.equal(Model.parseCliVersion("unexpected output").ok, false)
})

test("parseAccounts normalizes valid accounts and skips missing ids", () => {
  const result = Model.parseAccounts(payload([
    { id: 42, name: "Main &amp; Co" },
    { name: "Missing id" },
    { id: 7, name: "" }
  ]))

  assert.equal(result.ok, true)
  assert.deepEqual(result.accounts, [
    { id: "42", name: "Main & Co", order: 0 },
    { id: "7", name: "Account 7", order: 1 }
  ])
})

test("parseNotifications preserves unread state and notification fields", () => {
  const result = Model.parseNotifications(payload({
    unreads: [notification({ creator: { name: "Alice" }, unread_count: 3 })],
    reads: [notification({ id: 11, title: "Older", updated_at: "2026-08-13T13:05:00Z" })]
  }), account, 20)

  assert.equal(result.ok, true)
  assert.equal(result.items.length, 2)
  assert.equal(result.items[0].unread, true)
  assert.equal(result.items[0].unreadCount, 3)
  assert.equal(result.items[0].creator, "Alice")
  assert.equal(result.items[0].accountId, "42")
  assert.equal(result.items[1].unread, false)
})

test("unnamed Pings use participant names while named Pings keep their title", () => {
  const participants = [{ name: "Alice" }, { name: "Bob" }]
  const unnamed = Model.parseNotifications(payload({ unreads: [
    notification({ section: "pings", participants, title: "Fallback" })
  ]}), account, 20)
  const named = Model.parseNotifications(payload({ unreads: [
    notification({ section: "pings", participants, named: true, title: "Design crew" })
  ]}), account, 20)

  assert.equal(unnamed.items[0].title, "Ping with Alice & Bob")
  assert.equal(named.items[0].title, "Design crew")
})

test("sortNotifications orders newest first with deterministic ties", () => {
  const items = [
    { id: "z", timestampMs: 1, accountOrder: 0 },
    { id: "b", timestampMs: 3, accountOrder: 1 },
    { id: "a", timestampMs: 3, accountOrder: 1 },
    { id: "c", timestampMs: 3, accountOrder: 0 }
  ]

  assert.deepEqual(Model.sortNotifications(items).map(item => item.id), ["c", "a", "b", "z"])
})

test("filterNotifications combines account and read-state filters without reordering", () => {
  const items = [
    { id: "new-a", accountId: "a", unread: true },
    { id: "new-b", accountId: "b", unread: true },
    { id: "old-a", accountId: "a", unread: false }
  ]

  assert.deepEqual(Model.filterNotifications(items, "a", "unread").map(item => item.id), ["new-a"])
  assert.deepEqual(Model.filterNotifications(items, "a", "previous").map(item => item.id), ["old-a"])
  assert.deepEqual(Model.filterNotifications(items, "", "all").map(item => item.id), ["new-a", "new-b", "old-a"])
})

test("notificationMeta includes account context only when requested", () => {
  const item = {
    timestampMs: 0,
    creator: "Alice",
    project: "Project",
    accountName: "Main"
  }

  assert.equal(Model.notificationMeta(item, 0, false), "Alice • Project")
  assert.equal(Model.notificationMeta(item, 0, true), "Alice • Project (Main)")
})

test("notificationBadgeText shows the unread count until hovered, then a dismiss glyph", () => {
  assert.equal(Model.notificationBadgeText({ unreadCount: 3 }, false), "3")
  assert.equal(Model.notificationBadgeText({}, false), "1")
  assert.equal(Model.notificationBadgeText({ unreadCount: 0 }, false), "1")

  const dismiss = Model.notificationBadgeText({ unreadCount: 3 }, true)
  assert.equal(dismiss, "󰅖")
  assert.equal(dismiss, Model.notificationBadgeText({ unreadCount: 1 }, true))
  assert.equal(dismiss, Model.notificationBadgeText({}, true))
})

test("invalid CLI output returns a useful parse failure", () => {
  assert.deepEqual(Model.parseAccounts("not json"), {
    ok: false,
    error: "Could not parse the Basecamp CLI response",
    accounts: []
  })
})

test("setupPlan maps each setup state to its fix, worst problem first", () => {
  const signIn = Model.setupPlan(true, true, false, "37signals.basecamp")
  assert.equal(signIn.needed, true)
  assert.equal(signIn.title, "Please sign in")
  assert.equal(signIn.buttonLabel, "Sign in to Basecamp…")
  assert.equal(signIn.command, "basecamp auth login")
  assert.equal(signIn.launchCommand,
    Model.setupLaunchCommand("basecamp auth login", "37signals.basecamp"))

  const install = Model.setupPlan(false, true, true, "37signals.basecamp")
  assert.equal(install.title, "Basecamp CLI is required")
  assert.equal(install.buttonLabel, "Install Basecamp CLI…")
  assert.equal(install.command, "omarchy pkg add basecamp-cli")
  assert.equal(install.launchCommand,
    Model.setupLaunchCommand("omarchy-pkg-add basecamp-cli && basecamp auth login", "37signals.basecamp"))

  const update = Model.setupPlan(true, false, true, "37signals.basecamp")
  assert.equal(update.title, "Basecamp CLI 0.9 or newer is required")
  assert.equal(update.buttonLabel, "Update Omarchy…")
  assert.equal(update.command, "omarchy update")
  assert.equal(update.launchCommand,
    Model.setupLaunchCommand("omarchy update", "37signals.basecamp"))

  assert.equal(Model.setupPlan(false, false, false, "t").title, "Basecamp CLI is required")
  assert.equal(Model.setupPlan(true, true, true, "t").needed, false)
})
