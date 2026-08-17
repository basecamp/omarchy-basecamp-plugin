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

test("parseProjects normalizes project fields and skips ids it cannot use", () => {
  const result = Model.parseProjects(payload([
    {
      id: 900,
      name: "ONP &amp; friends",
      description: "<p>Campaign planning</p>",
      app_url: "https://example.test/900",
      status: "active",
      updated_at: "2026-08-16T22:52:52.161Z"
    },
    { name: "Missing id", app_url: "https://example.test/none" }
  ]), account)

  assert.equal(result.ok, true)
  assert.equal(result.items.length, 1)
  assert.deepEqual(result.items[0], {
    id: "900",
    accountId: "42",
    accountName: "Main & Co",
    accountOrder: 1,
    name: "ONP & friends",
    description: "Campaign planning",
    url: "https://example.test/900",
    timestamp: "2026-08-16T22:52:52.161Z",
    timestampMs: Date.parse("2026-08-16T22:52:52.161Z")
  })
})

test("parseProjects keeps active projects and drops archived or trashed ones", () => {
  const result = Model.parseProjects(payload([
    { id: 1, name: "Active", status: "active" },
    { id: 2, name: "Archived", status: "archived" },
    { id: 3, name: "Trashed", status: "trashed" },
    { id: 4, name: "Unstated status" }
  ]), account)

  assert.deepEqual(result.items.map(item => item.name), ["Active", "Unstated status"])
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

test("sortProjects orders most recently active first with deterministic ties", () => {
  const items = [
    { id: "z", timestampMs: 1, accountOrder: 0 },
    { id: "b", timestampMs: 3, accountOrder: 1 },
    { id: "a", timestampMs: 3, accountOrder: 1 },
    { id: "c", timestampMs: 3, accountOrder: 0 }
  ]

  assert.deepEqual(Model.sortProjects(items).map(item => item.id), ["c", "a", "b", "z"])
})

test("filterProjects narrows to a single account and keeps every project otherwise", () => {
  const items = [
    { id: "1", accountId: "a" },
    { id: "2", accountId: "b" },
    { id: "3", accountId: "a" }
  ]

  assert.deepEqual(Model.filterProjects(items, "a").map(item => item.id), ["1", "3"])
  assert.deepEqual(Model.filterProjects(items, "").map(item => item.id), ["1", "2", "3"])
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

test("projectMeta appends account context only when requested", () => {
  const project = { description: "Campaign planning", accountName: "Main" }
  const bare = { description: "", accountName: "Main" }

  assert.equal(Model.projectMeta(project, false), "Campaign planning")
  assert.equal(Model.projectMeta(project, true), "Campaign planning • Main")
  assert.equal(Model.projectMeta(bare, true), "Main")
  assert.equal(Model.projectMeta(bare, false), "")
})

test("invalid CLI output returns a useful parse failure", () => {
  assert.deepEqual(Model.parseAccounts("not json"), {
    ok: false,
    error: "Could not parse the Basecamp CLI response",
    accounts: []
  })
})
