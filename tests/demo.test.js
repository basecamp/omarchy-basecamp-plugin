const test = require("node:test")
const assert = require("node:assert/strict")
const { mkdtempSync, rmSync, writeFileSync } = require("node:fs")
const { tmpdir } = require("node:os")
const path = require("node:path")
const { spawnSync } = require("node:child_process")
const Model = require("../Model.js")

const cli = path.join(__dirname, "..", "demo", "bin", "basecamp")

function demo(args, stateDir, fixturePath = "") {
  const env = {
    ...process.env,
    BASECAMP_DEMO_STATE_DIR: stateDir
  }
  if (fixturePath) env.BASECAMP_DEMO_FIXTURE = fixturePath

  return spawnSync(cli, args, { encoding: "utf8", env })
}

function successfulJson(args, stateDir, fixturePath = "") {
  const result = demo(args, stateDir, fixturePath)
  assert.equal(result.status, 0, result.stderr)
  return JSON.parse(result.stdout)
}

function withState(run) {
  const stateDir = mkdtempSync(path.join(tmpdir(), "basecamp-demo-test-"))
  try {
    return run(stateDir)
  } finally {
    rmSync(stateDir, { recursive: true, force: true })
  }
}

test("demo CLI fixtures follow the production account and notification contracts", () => {
  withState(stateDir => {
    const version = demo(["version"], stateDir)
    assert.equal(version.status, 0, version.stderr)
    assert.equal(version.stdout.trim(), "basecamp version 0.9.1")

    const auth = successfulJson(["auth", "status", "--json"], stateDir)
    assert.equal(auth.data.authenticated, true)

    const accountsResult = successfulJson(["accounts", "list", "--json"], stateDir)
    const parsedAccounts = Model.parseAccounts(JSON.stringify(accountsResult))
    assert.equal(parsedAccounts.ok, true)
    assert.equal(parsedAccounts.accounts.length, 3)

    const allNotifications = []
    const rawNotifications = []
    for (const account of parsedAccounts.accounts) {
      const result = successfulJson([
        "notifications", "list", "--account", account.id, "--json"
      ], stateDir)
      rawNotifications.push(...result.data.unreads, ...result.data.reads)

      const parsed = Model.parseNotifications(JSON.stringify(result), account, 50)
      assert.equal(parsed.ok, true)
      assert.ok(parsed.items.length > 0)
      allNotifications.push(...parsed.items)
    }

    const ids = rawNotifications.map(item => String(item.id))
    assert.equal(new Set(ids).size, ids.length)
    assert.ok(rawNotifications.every(item => item.app_url === ""))
    assert.ok(rawNotifications.every(item => Number.isFinite(Date.parse(item.updated_at))))

    const types = new Set(rawNotifications.map(item => String(item.type).toLowerCase()))
    assert.deepEqual(types, new Set([
      "boostreport", "bulletin", "chat", "comment", "completion",
      "document", "event", "hill", "mention"
    ]))
    assert.ok(rawNotifications.some(item => item.section === "pings"))

    const sorted = Model.sortNotifications(allNotifications)
    for (let index = 1; index < sorted.length; index++) {
      assert.ok(sorted[index - 1].timestampMs >= sorted[index].timestampMs)
    }
  })
})

test("demo CLI keeps mark-as-read state for subsequent refreshes", () => {
  withState(stateDir => {
    const before = successfulJson([
      "notifications", "list", "--account", "1001", "--json"
    ], stateDir)
    assert.ok(before.data.unreads.some(item => String(item.id) === "501"))

    successfulJson([
      "notifications", "read", "501", "--account", "1001", "--json"
    ], stateDir)

    const after = successfulJson([
      "notifications", "list", "--account", "1001", "--json"
    ], stateDir)
    assert.ok(!after.data.unreads.some(item => String(item.id) === "501"))
    assert.ok(after.data.reads.some(item => String(item.id) === "501"))
  })
})

test("demo read state is scoped by account and notification id", () => {
  withState(stateDir => {
    const fixturePath = path.join(stateDir, "duplicate-ids.json")
    const item = {
      id: 900,
      state: "unread",
      minutes_ago: 1,
      type: "Comment",
      title: "Same id",
      content_excerpt: "Scoped fixture",
      bucket_name: "Demo",
      creator: { name: "Demo Person" }
    }
    writeFileSync(fixturePath, JSON.stringify({
      accounts: [
        { id: 1, name: "First" },
        { id: 2, name: "Second" }
      ],
      notifications: [
        { ...item, account_id: 1 },
        { ...item, account_id: 2 }
      ]
    }))

    successfulJson([
      "notifications", "read", "900", "--account", "1", "--json"
    ], stateDir, fixturePath)

    const first = successfulJson([
      "notifications", "list", "--account", "1", "--json"
    ], stateDir, fixturePath)
    const second = successfulJson([
      "notifications", "list", "--account", "2", "--json"
    ], stateDir, fixturePath)
    assert.ok(first.data.reads.some(notification => notification.id === 900))
    assert.ok(second.data.unreads.some(notification => notification.id === 900))
  })
})

test("demo CLI rejects commands outside the plugin contract", () => {
  withState(stateDir => {
    for (const args of [
      ["projects", "list", "--json"],
      ["accounts", "list"],
      ["accounts", "list", "--json", "unexpected"]
    ]) {
      const result = demo(args, stateDir)
      assert.notEqual(result.status, 0)
      assert.match(result.stderr, /Unsupported demo Basecamp CLI command/)
    }
  })
})
