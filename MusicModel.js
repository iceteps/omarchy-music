// Pure helpers for the iceteps.music widget. No QML types, so tests/model.test.mjs
// runs them under node.

// Bar tags, in the panel's tab order. COUPLED with bin/iceteps-music
// (IDS): same ids. Labels come from the script's `status`, not from here.
var PLATFORMS = [
  { id: "spotify", tag: "SPT" },
  { id: "youtube", tag: "YTM" },
  { id: "apple", tag: "APL" }
]

function tagFor(id) {
  for (var i = 0; i < PLATFORMS.length; i++)
    if (PLATFORMS[i].id === id) return PLATFORMS[i].tag
  return ""
}

// Chromium registers its player as org.mpris.MediaPlayer2.chromium.instance<PID>,
// the PID of the browser process. Anything else has no PID to match.
function playerPid(player) {
  var match = /\.instance(\d+)$/.exec(String(player && player.dbusName || ""))
  return match ? parseInt(match[1], 10) : 0
}

// The platform id a player belongs to, or "" for any other player (mpv, a tab
// in the everyday browser). status: the parsed `iceteps-music status` output.
function platformOf(player, status) {
  var pid = playerPid(player)
  if (!pid || !status || !Array.isArray(status.platforms)) return ""
  for (var i = 0; i < status.platforms.length; i++) {
    var p = status.platforms[i]
    if (p && p.running && p.pid === pid) return p.id
  }
  return ""
}

function platformEntry(status, id) {
  if (!status || !Array.isArray(status.platforms)) return null
  for (var i = 0; i < status.platforms.length; i++)
    if (status.platforms[i] && status.platforms[i].id === id) return status.platforms[i]
  return null
}

function parseStatus(text) {
  try {
    var parsed = JSON.parse(String(text || ""))
    return parsed && Array.isArray(parsed.platforms) ? parsed : null
  } catch (e) {
    return null
  }
}

// Seconds -> "m:ss", or "h:mm:ss" past an hour. Unknown or negative -> "-:--".
function formatTime(seconds) {
  var s = Number(seconds)
  if (!isFinite(s) || s < 0) return "-:--"
  s = Math.floor(s)
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var r = s % 60
  var ss = (r < 10 ? "0" : "") + r
  if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m + ":" + ss
  return m + ":" + ss
}

// The music platforms on screen, from { monitor: special workspace name }.
function musicIdsIn(specialByMonitor) {
  var prefix = "special:music-"
  var ids = []
  for (var monitor in specialByMonitor) {
    var name = String(specialByMonitor[monitor] || "")
    if (name.indexOf(prefix) === 0) ids.push(name.slice(prefix.length))
  }
  return ids
}

// The first music platform on screen, or "".
function musicIdIn(specialByMonitor) {
  var ids = musicIdsIn(specialByMonitor)
  return ids.length ? ids[0] : ""
}

// Music started on startedId: the running services to close. A service in use
// (inUseIds: on screen or open in the panel) is never closed.
function servicesToClose(platforms, startedId, inUseIds) {
  var close = []
  for (var i = 0; i < (platforms || []).length; i++) {
    var p = platforms[i]
    if (p.running && p.id !== startedId && inUseIds.indexOf(p.id) === -1) close.push(p.id)
  }
  return close
}

// One idle check. lastActive: { id: ms the service was last active }.
// activeIds: running services playing or in use. Returns the next lastActive
// (only running services, a newly seen one starting now) and the ids whose
// grace ran out.
function idleStep(platforms, lastActive, activeIds, now, graceMs) {
  var next = {}
  var close = []
  for (var i = 0; i < (platforms || []).length; i++) {
    var p = platforms[i]
    if (!p.running) continue
    var since = lastActive[p.id]
    if (activeIds.indexOf(p.id) !== -1 || since === undefined) next[p.id] = now
    else if (now - since >= graceMs) close.push(p.id)
    else next[p.id] = since
  }
  return { lastActive: next, close: close }
}

// lastActive without the services that no longer run: a stale time from an
// earlier run would close a freshly started service at its first check.
function pruneLastActive(platforms, lastActive) {
  var next = {}
  for (var i = 0; i < (platforms || []).length; i++) {
    var p = platforms[i]
    if (p.running && lastActive[p.id] !== undefined) next[p.id] = lastActive[p.id]
  }
  return next
}

// "Stopped at 1:24 of 3:41 · 2 h ago" for a closed service's last track.
// nowSeconds: the current time in seconds since the epoch.
function leftOffLabel(last, nowSeconds) {
  var parts = []
  if (last.position > 0 && last.length > 0)
    parts.push("Stopped at " + formatTime(last.position) + " of " + formatTime(last.length))
  var ago = Math.max(0, Math.floor(nowSeconds - (last.at || nowSeconds)))
  if (ago < 60) parts.push("just now")
  else if (ago < 3600) parts.push(Math.floor(ago / 60) + " min ago")
  else if (ago < 86400) parts.push(Math.floor(ago / 3600) + " h ago")
  else parts.push(Math.floor(ago / 86400) + " d ago")
  return parts.join("  ·  ")
}

function trackLabel(title, artist) {
  return String(title || "") + (artist ? "  ·  " + artist : "")
}
