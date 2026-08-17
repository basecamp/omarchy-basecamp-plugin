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

test("parseBookmarks lifts the recording onto the bookmark and skips unusable entries", () => {
  const result = Model.parseBookmarks(payload([
    {
      id: 9552015,
      created_at: "2026-08-08T19:08:13.255Z",
      recording: {
        title: "To-dos",
        type: "Todoset",
        app_url: "https://example.test/todosets/1",
        bucket: { id: 46125045, name: "[Personal] Inbox", type: "Project" }
      }
    },
    { id: 9552016, created_at: "2026-06-12T10:00:00Z" },
    { created_at: "2026-06-12T10:00:00Z", recording: { title: "No bookmark id" } }
  ]), account)

  assert.equal(result.ok, true)
  assert.equal(result.items.length, 1)
  assert.deepEqual(result.items[0], {
    id: "9552015",
    accountId: "42",
    accountName: "Main & Co",
    accountOrder: 1,
    title: "To-dos",
    project: "[Personal] Inbox",
    type: "Todoset",
    url: "https://example.test/todosets/1",
    timestamp: "2026-08-08T19:08:13.255Z",
    timestampMs: Date.parse("2026-08-08T19:08:13.255Z")
  })
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

test("sortBookmarks orders most recently saved first with deterministic ties", () => {
  const items = [
    { id: "z", timestampMs: 1, accountOrder: 0 },
    { id: "b", timestampMs: 3, accountOrder: 1 },
    { id: "a", timestampMs: 3, accountOrder: 1 },
    { id: "c", timestampMs: 3, accountOrder: 0 }
  ]

  assert.deepEqual(Model.sortBookmarks(items).map(item => item.id), ["c", "a", "b", "z"])
})

test("filterBookmarks narrows to a single account and keeps every bookmark otherwise", () => {
  const items = [
    { id: "1", accountId: "a" },
    { id: "2", accountId: "b" },
    { id: "3", accountId: "a" }
  ]

  assert.deepEqual(Model.filterBookmarks(items, "a").map(item => item.id), ["1", "3"])
  assert.deepEqual(Model.filterBookmarks(items, "").map(item => item.id), ["1", "2", "3"])
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

test("bookmarkTypeIcon maps recording types, ignoring case and namespacing", () => {
  assert.equal(Model.bookmarkTypeIcon("Todoset"), "\u{F0139}")
  assert.equal(Model.bookmarkTypeIcon("Inbox"), "\u{F01EE}")
  assert.equal(Model.bookmarkTypeIcon("vault"), "\u{F024B}")
  assert.equal(Model.bookmarkTypeIcon("Schedule::Entry"), "\u{F00ED}")
  assert.equal(Model.bookmarkTypeIcon("Question::Answer"), "\u{F0817}")
})

test("bookmarkTypeIcon falls back to the bookmark glyph for unknown types", () => {
  assert.equal(Model.bookmarkTypeIcon("Something::New"), "\u{F00C3}")
  assert.equal(Model.bookmarkTypeIcon(""), "\u{F00C3}")
  assert.equal(Model.bookmarkTypeIcon(undefined), "\u{F00C3}")
})

test("bookmarkMeta labels the saved date and adds account context on request", () => {
  const now = Date.parse("2026-08-17T10:00:00Z")
  const item = { timestampMs: Date.parse("2026-08-08T19:08:13.255Z"), accountName: "Main" }
  const undated = { timestampMs: 0, accountName: "Main" }

  assert.equal(Model.bookmarkMeta(item, now, false), "Saved Aug 8")
  assert.equal(Model.bookmarkMeta(item, now, true), "Saved Aug 8 • Main")
  assert.equal(Model.bookmarkMeta(undated, now, true), "Main")
  assert.equal(Model.bookmarkMeta(undated, now, false), "")
})

test("invalid CLI output returns a useful parse failure", () => {
  assert.deepEqual(Model.parseAccounts("not json"), {
    ok: false,
    error: "Could not parse the Basecamp CLI response",
    accounts: []
  })
})
