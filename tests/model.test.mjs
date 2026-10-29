// Run: node ~/.config/omarchy/plugins/iceteps.music/tests/model.test.mjs
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import vm from "node:vm"
import assert from "node:assert/strict"

const source = readFileSync(fileURLToPath(new URL("../MusicModel.js", import.meta.url)), "utf8")
const M = {}
vm.runInNewContext(source, M)

const status = M.parseStatus(JSON.stringify({
  shown: false,
  last: "spotify",
  platforms: [
    { id: "spotify", label: "Spotify", running: true, pid: 4242 },
    { id: "youtube", label: "YouTube Music", running: false, pid: 0 },
    { id: "apple", label: "Apple Music", running: true, pid: 77 }
  ]
}))

const player = (dbusName) => ({ dbusName })

assert.equal(M.playerPid(player("org.mpris.MediaPlayer2.chromium.instance4242")), 4242)
assert.equal(M.playerPid(player("org.mpris.MediaPlayer2.mpv")), 0)
assert.equal(M.playerPid(null), 0)

assert.equal(M.platformOf(player("org.mpris.MediaPlayer2.chromium.instance4242"), status), "spotify")
assert.equal(M.platformOf(player("org.mpris.MediaPlayer2.chromium.instance77"), status), "apple")
// The everyday browser's player: a PID no platform owns.
assert.equal(M.platformOf(player("org.mpris.MediaPlayer2.chromium.instance130309"), status), "")
// A stopped platform reports pid 0; a pid-less player must not match it.
assert.equal(M.platformOf(player("org.mpris.MediaPlayer2.mpv"), status), "")
assert.equal(M.platformOf(player("org.mpris.MediaPlayer2.chromium.instance4242"), null), "")

assert.equal(M.parseStatus("not json"), null)
assert.equal(M.parseStatus("{}"), null)
assert.equal(M.platformEntry(status, "youtube").label, "YouTube Music")
assert.equal(M.platformEntry(status, "nope"), null)

assert.equal(M.tagFor("youtube"), "YTM")
assert.equal(M.tagFor("nope"), "")

assert.equal(M.formatTime(0), "0:00")
assert.equal(M.formatTime(84.9), "1:24")
assert.equal(M.formatTime(3661), "1:01:01")
assert.equal(M.formatTime(-1), "-:--")
assert.equal(M.formatTime(NaN), "-:--")

assert.equal(M.trackLabel("Song", "Artist"), "Song  ·  Artist")
assert.equal(M.trackLabel("Song", ""), "Song")

assert.equal(M.musicIdIn({ "eDP-1": "special:music-apple", "HDMI-A-1": "" }), "apple")
assert.deepEqual([...M.musicIdsIn({ a: "special:music-apple", b: "special:music-spotify", c: "" })], ["apple", "spotify"])

// Close rules. JSON round trip: arrays from the vm context compare by value.
const plain = (x) => JSON.parse(JSON.stringify(x))
const run = (ids) => ["spotify", "youtube", "apple"].map((id) => ({ id, running: ids.includes(id) }))
assert.deepEqual(plain(M.servicesToClose(run(["spotify", "youtube"]), "youtube", [])), ["spotify"])
// On screen or open in the panel: never closed.
assert.deepEqual(plain(M.servicesToClose(run(["spotify", "youtube"]), "youtube", ["spotify"])), [])
assert.deepEqual(plain(M.servicesToClose(run(["spotify", "youtube", "apple"]), "apple", ["youtube"])), ["spotify"])

// Idle: a newly seen service starts its grace now; active ones refresh it.
let step = M.idleStep(run(["apple"]), {}, [], 1000, 60000)
assert.deepEqual(plain(step), { lastActive: { apple: 1000 }, close: [] })
step = M.idleStep(run(["apple"]), { apple: 1000 }, [], 61000, 60000)
assert.deepEqual(plain(step), { lastActive: {}, close: ["apple"] })
step = M.idleStep(run(["apple"]), { apple: 1000 }, ["apple"], 61000, 60000)
assert.deepEqual(plain(step), { lastActive: { apple: 61000 }, close: [] })
step = M.idleStep(run(["apple"]), { apple: 1000 }, [], 30000, 60000)
assert.deepEqual(plain(step), { lastActive: { apple: 1000 }, close: [] })
// A stopped service's old time is dropped, so restarting it gets a full grace.
assert.deepEqual(plain(M.pruneLastActive(run([]), { spotify: 5 })), {})
step = M.idleStep(run(["spotify"]), M.pruneLastActive(run([]), { spotify: 5 }), [], 999999, 60000)
assert.deepEqual(plain(step), { lastActive: { spotify: 999999 }, close: [] })
assert.equal(M.musicIdIn({ "eDP-1": "special:scratchpad" }), "")
assert.equal(M.musicIdIn({}), "")

assert.equal(M.leftOffLabel({ position: 84, length: 221, at: 1000 }, 1030), "Stopped at 1:24 of 3:41  ·  just now")
assert.equal(M.leftOffLabel({ position: 0, length: 0, at: 1000 }, 1000 + 7200), "2 h ago")
assert.equal(M.leftOffLabel({ position: 10, length: 0, at: 1000 }, 1000 + 300), "5 min ago")

console.log("iceteps.music model: all assertions passed")
