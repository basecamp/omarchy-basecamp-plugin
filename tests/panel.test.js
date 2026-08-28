const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const panel = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")

test("setup panel keeps the Basecamp branding header visible", () => {
  assert.match(panel, /Column\s*{\s*id:\s*fixedContent\s*Layout\.fillWidth/)
  const header = panel.slice(panel.indexOf("id: fixedContent"), panel.indexOf("PanelSeparator", panel.indexOf("id: fixedContent")))
  assert.match(header, /BasecampIcon\s*{/)
  assert.match(header, /text:\s*"Basecamp"/)
})

test("missing CLI state hides the header action", () => {
  assert.match(panel, /id:\s*refreshButton\s*visible:\s*!root\.missingCli/)
})

test("empty setup details stay out of the content area", () => {
  assert.match(panel, /visible:\s*root\.setupPlan\.title\s*!==\s*""/)
  assert.match(panel, /visible:\s*root\.setupPlan\.command\s*!==\s*""/)
})

test("initial refresh shows Loading… before the first completed fetch", () => {
  assert.match(panel, /if \(service\.refreshing && service\.lastUpdated instanceof Date && service\.lastUpdated\.getTime\(\) <= 0\) return "Loading…"/)
})

test("refresh button animates rotation while refreshing", () => {
  assert.match(panel, /RotationAnimation\s+on\s+rotation\s*\{[\s\S]*?running:\s*service\.refreshing/)
})

test("empty state message remains visible during refresh", () => {
  assert.match(panel, /visible:\s*!root\.needsSetup && root\.filteredNotifications\.length === 0 && service\.lastError === ""/)
})


