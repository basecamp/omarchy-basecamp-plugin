const test = require("node:test")
const assert = require("node:assert/strict")
const Host = require("../ServiceHost.js")

test("hostedService returns the shell singleton for this plugin", () => {
  const singleton = { unreadCount: 3 }
  const bar = {
    shell: {
      _services: { "37signals.basecamp": singleton },
      serviceFor(id) {
        return id === "37signals.basecamp" ? singleton : null
      }
    }
  }
  assert.equal(Host.hostedService(bar), singleton)
})

test("hostedService returns null when the bar has no shell service host", () => {
  assert.equal(Host.hostedService(null), null)
  assert.equal(Host.hostedService({}), null)
  assert.equal(Host.hostedService({ shell: {} }), null)
  assert.equal(Host.hostedService({ shell: { serviceFor: "not a function" } }), null)
})

test("hostedService returns null when the host has not mounted this plugin", () => {
  const bar = {
    shell: {
      _services: {},
      serviceFor() { return null }
    }
  }
  assert.equal(Host.hostedService(bar), null)
})
