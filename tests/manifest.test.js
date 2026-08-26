const test = require("node:test")
const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const path = require("node:path")

const manifest = JSON.parse(readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8"))

test("manifest mounts a process-wide service so every bar shares one notification store", () => {
  assert.deepEqual(manifest.kinds, ["service", "bar-widget"])
  assert.equal(manifest.entryPoints.service, "Service.qml")
  assert.equal(manifest.entryPoints.barWidget, "Panel.qml")
})
