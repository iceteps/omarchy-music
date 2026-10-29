import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "MusicModel.js" as Model

// Music: one bar widget and panel for Spotify, YouTube Music and Apple Music.
// https://github.com/iceteps/omarchy-music (MIT) by iceteps, https://github.com/iceteps
//
// Playback state comes straight from Quickshell's MPRIS players; this widget
// adds which PLATFORM each player is. (The shell's omarchy.media service is out
// of reach: it is handed only to bar-kind plugins, and this is a bar widget.)
// bin/iceteps-music runs every platform in its own Chromium profile, so each
// has its own browser process and MPRIS player, and `iceteps-music status`
// reports the PIDs that tie a player to its platform. Each app lives hidden on
// its own overlay, special:music-<id>; "Show app" (or SUPER+M) reveals only it.
//
// Bar: click the play/pause glyph = play/pause, elsewhere = panel,
// middle = play/pause. The wheel does nothing (touchpad drift skipped tracks).
// Panel keys: Left/Right = platform, Enter = play/pause, Esc = close.
// Only the playing service stays alive: music starting on one closes the
// others, and one that stops playing closes a minute after it is out of sight.
Panel {
  id: root
  moduleName: "iceteps.music"
  ipcTarget: "iceteps.music"

  implicitWidth: vertical ? barSize : row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property var players: Mpris.players ? Mpris.players.values : []
  // The helper ships inside the plugin, so it works without being on PATH.
  readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("bin/iceteps-music").toString().replace(/^file:\/\//, ""))

  // Parsed `iceteps-music status`; null until the first read lands.
  property var status: null
  // A status read asked for while one runs; run again when it finishes.
  property bool refreshPending: false
  // Platform the panel shows. Empty: follow the music (see viewId).
  property string chosenId: ""
  // Script calls waiting for the running one (a stop of each other service).
  property var actionQueue: []
  // Between one queued call ending and the next starting: new calls queue too,
  // so the order holds (a service's remember before its stop).
  property bool draining: false
  // When each running service was last playing or on screen (ms).
  property var lastActive: ({})
  // When each player last stopped playing (ms), by key: a "start" soon after
  // is a track change or a quick resume, not music starting.
  property var stoppedAt: ({})
  // Services being closed: their players' last state changes are not starts.
  property var stopping: ({})
  // Only the playing service stays alive (owner's rule 2026-10-29). A service
  // that is not playing, not on screen and not open in the panel closes after
  // this grace, which only absorbs a quick pause or the moment between showing
  // a service and pressing play. 60 s is arbitrary. Start reopens it, signed in.
  readonly property int idleCloseMs: 60 * 1000
  readonly property bool anyRunning: !!(status && status.platforms.some(function (p) { return p.running }))
  // Last known track per player key. On a skip Chromium reports Stopped and an
  // empty title for a moment before the new track (measured with busctl
  // monitor, 2026-10-29); showing that gap made the bar and panel flash.
  property var held: ({})
  // Players that appeared while the shell was already running, by key. Only
  // these can count as "music just started": the players found at load
  // (a shell restart) are not a start and must not close anything.
  property var freshKeys: ({})
  property real loadedAt: 0

  readonly property var platformPlayers: {
    var map = ({})
    for (var i = 0; i < players.length; i++) {
      var id = Model.platformOf(players[i], status)
      if (id && !map[id]) map[id] = players[i]
    }
    return map
  }

  // The player the bar shows: the platform playing, else one paused with a track.
  readonly property var barPlayer: {
    var paused = null
    for (var i = 0; i < Model.PLATFORMS.length; i++) {
      var p = platformPlayers[Model.PLATFORMS[i].id]
      var t = trackOf(p)
      if (!t) continue
      if (t.playing) return p
      if (!paused) paused = p
    }
    return paused
  }
  readonly property var barTrack: trackOf(barPlayer)
  readonly property string barPlatformId: barPlayer ? Model.platformOf(barPlayer, status) : ""

  readonly property string viewId: chosenId
    || barPlatformId
    || (status && status.last ? status.last : Model.PLATFORMS[0].id)
  readonly property var viewEntry: Model.platformEntry(status, viewId)
  readonly property var viewPlayer: platformPlayers[viewId] || null
  readonly property bool viewRunning: !!(viewEntry && viewEntry.running)
  readonly property var viewTrack: trackOf(viewPlayer)
  // The service's last track, kept while it is closed (iceteps-music remember).
  readonly property var viewLast: viewEntry && viewEntry.lastTrack && viewEntry.lastTrack.title ? viewEntry.lastTrack : null
  readonly property bool viewHasTrack: viewTrack !== null
  readonly property string viewArt: viewTrack ? viewTrack.art : ""

  // The cover shown. Mid-skip Chromium first sends its own logo as the art,
  // then the real cover (~0.3 s apart, measured 2026-10-29), so a new cover is
  // shown only once it has held for artSettle; a platform switch shows at once.
  property string shownArt: ""
  onViewArtChanged: {
    if (!shownArt || !viewArt) {
      shownArt = viewArt
      artSettle.stop()
    } else {
      artSettle.restart()
    }
  }
  onViewIdChanged: {
    shownArt = viewArt
    artSettle.stop()
  }
  // The platform whose app is on screen, or "". Seeded by each status read and
  // kept live by Hyprland's activespecial event, so a SUPER+M or a workspace
  // switch that hides the app is seen at once.
  property string shownId: ""
  // Special workspace open per monitor, from activespecial events: the event
  // names one monitor, so another monitor's scratchpad must not clear ours.
  property var specialByMonitor: ({})
  // Bumped on every event; a status read that started before one is stale.
  property int shownSeq: 0
  property int statusSeq: 0
  // This tab's app is the one on screen (another platform's may be instead).
  readonly property bool overlayShown: shownId !== "" && shownId === viewId

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event) return
      var name = String(event.name)
      // A music app's window opening or closing, however it was started or
      // stopped (the CLI, a launcher, its own window close): re-read which
      // services run. Event-driven, so nothing polls the helper. closewindow
      // carries only an address, so it counts while any service runs.
      if ((name === "openwindow" && String(event.data || "").indexOf("chrome-") !== -1)
          || (name === "closewindow" && root.anyRunning)) {
        root.refresh()
        return
      }
      if (name !== "activespecial") return
      // data: "<workspace>,<monitor>"; the workspace is empty when hidden.
      var parts = String(event.data || "").split(",")
      var next = Object.assign({}, root.specialByMonitor)
      next[parts[1] || ""] = parts[0] || ""
      root.specialByMonitor = next
      root.shownSeq++
      root.shownId = Model.musicIdIn(next)
    }
  }

  readonly property var tabOptions: {
    var list = []
    for (var i = 0; i < Model.PLATFORMS.length; i++) {
      var id = Model.PLATFORMS[i].id
      var entry = Model.platformEntry(status, id)
      var label = entry ? entry.label : id
      list.push({ value: id, label: entry && entry.running ? label + " •" : label })
    }
    return list
  }

  // ---------- Platform state ----------

  function refresh() {
    if (statusProc.running) {
      refreshPending = true
      return
    }
    statusSeq = shownSeq
    statusProc.running = true
  }

  function keyOf(player) {
    return player ? String(player.dbusName || "") : ""
  }

  // What to show for a player: its live track, or the held one while a skip is
  // in flight. null when it has neither.
  function trackOf(player) {
    if (!player) return null
    if (player.trackTitle || player.trackArtist) {
      return snapshot(player)
    }
    return held[keyOf(player)] || null
  }

  // A skip passes through Stopped; while it does, keep the playing state the
  // held track had so the play/pause glyph does not flicker.
  function snapshot(player) {
    var prior = held[keyOf(player)]
    var stopped = player.playbackState === MprisPlaybackState.Stopped
    var title = player.trackTitle || ""
    var length = player.lengthSupported ? player.length : 0
    // The length drops to 0 mid-skip while the old title still shows.
    if (!(length > 0) && prior && prior.title === title) length = prior.length
    return {
      title: title, artist: player.trackArtist || "",
      album: player.trackAlbum || "", art: player.trackArtUrl || "",
      length: length,
      playing: player.isPlaying || (stopped && !!prior && prior.playing)
    }
  }

  function noteTrack(player) {
    var key = keyOf(player)
    if (!key) return
    if (player.trackTitle || player.trackArtist) {
      var next = Object.assign({}, held)
      next[key] = snapshot(player)
      held = next
    } else if (held[key]) {
      releaseHeld.restart()
    }
  }

  // Drop held tracks whose player still has none: the gap was a real stop.
  function dropStaleHeld() {
    var next = ({})
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      var key = keyOf(p)
      if (held[key] && (p.trackTitle || p.trackArtist)) next[key] = held[key]
    }
    held = next
  }

  function control(player, name) {
    if (!player) return
    if (name === "next") {
      if (player.canGoNext) player.next()
    } else if (name === "previous") {
      if (player.canGoPrevious) player.previous()
    } else if (name === "playPause") {
      if (player.canTogglePlaying) player.togglePlaying()
      else if (player.isPlaying && player.canPause) player.pause()
      else if (!player.isPlaying && player.canPlay) player.play()
    }
  }

  function runScript(args) {
    if (actionProc.running || draining) {
      var line = args.join(" ")
      for (var i = 0; i < actionQueue.length; i++) if (actionQueue[i].join(" ") === line) return
      actionQueue = actionQueue.concat([args])
      return
    }
    actionProc.command = [scriptPath].concat(args)
    actionProc.running = true
  }

  function action(name) {
    control(viewPlayer, name)
  }

  function stepPlatform(delta) {
    var n = Model.PLATFORMS.length
    for (var i = 0; i < n; i++) {
      if (Model.PLATFORMS[i].id === viewId) {
        chosenId = Model.PLATFORMS[(i + delta + n) % n].id
        return
      }
    }
  }

  // Music starting on one service closes the others: one service at a time,
  // so an idle one does not hold its memory (owner's choice 2026-10-29; the
  // logins stay, Start reopens in seconds).
  //
  // Never closed this way: a service on screen or open in the panel (you are
  // using it). Not a start: a player of a service being closed, and a play
  // within 5 s of the same player stopping (Chromium passes through Stopped on
  // every track change, measured 2026-10-29).
  function noteStarted(player) {
    var startedId = player && player.isPlaying ? Model.platformOf(player, status) : ""
    if (!startedId || stopping[startedId]) return
    if (Date.now() - (stoppedAt[keyOf(player)] || 0) < 5000) return
    var close = Model.servicesToClose(status.platforms, startedId, inUseIds())
    for (var i = 0; i < close.length; i++) stopService(close[i], startedId + " started playing")
  }

  function noteStopped(player) {
    var next = Object.assign({}, stoppedAt)
    next[keyOf(player)] = Date.now()
    stoppedAt = next
  }

  // On screen on any monitor, or open in the panel.
  function inUseIds() {
    var ids = Model.musicIdsIn(specialByMonitor)
    if (opened && ids.indexOf(viewId) === -1) ids.push(viewId)
    return ids
  }

  // Keep a service's track so its tab shows where you left off once closed.
  function remember(id) {
    var player = platformPlayers[id]
    var t = trackOf(player)
    if (!t) return
    runScript(["remember", id, JSON.stringify({
      title: t.title, artist: t.artist, album: t.album, art: t.art,
      position: player.positionSupported ? player.position : 0, length: t.length
    })])
  }

  function rememberAll() {
    for (var id in platformPlayers) remember(id)
  }

  function stopService(id, reason) {
    remember(id)
    var next = Object.assign({}, stopping)
    next[id] = true
    stopping = next
    runScript(["stop", id, reason])
  }

  // Close a service that has been hidden and silent for idleCloseMs.
  function closeIdle() {
    var active = inUseIds()
    for (var id in platformPlayers) {
      if (platformPlayers[id].isPlaying && active.indexOf(id) === -1) active.push(id)
    }
    var step = Model.idleStep(status.platforms, lastActive, active, Date.now(), idleCloseMs)
    lastActive = step.lastActive
    for (var i = 0; i < step.close.length; i++) stopService(step.close[i], "idle")
  }

  // After a status read. A service's player first appears when it starts
  // playing, before the map knows its PID, so its isPlaying change went
  // unnoticed: a fresh player, now mapped and playing, is the latest start.
  function adoptNewlyMapped() {
    for (var id in platformPlayers) {
      var p = platformPlayers[id]
      var key = keyOf(p)
      if (!freshKeys[key]) continue
      var next = Object.assign({}, freshKeys)
      delete next[key]
      freshKeys = next
      if (p.isPlaying) noteStarted(p)
    }
  }

  function noteAppeared(player) {
    // Mpris lists the existing players within the first moments after load.
    if (loadedAt === 0 || Date.now() - loadedAt < 3000) return
    var next = Object.assign({}, freshKeys)
    next[keyOf(player)] = true
    freshKeys = next
  }

  // Esc hides the app, bound only while one is shown, so Esc everywhere else
  // (and in every other window) is untouched. The cost: while shown, Esc does
  // not reach the app (its search box keeps its text). Unbound on every hide,
  // however it happens (SUPER+M, a workspace switch), and at load.
  function syncEscape() {
    var hideCmd = "'" + scriptPath.replace(/'/g, "'\\''") + "' hide"
    var lua = shownId !== ""
      ? 'hl.unbind("ESCAPE"); hl.bind("ESCAPE", hl.dsp.exec_cmd(' + JSON.stringify(hideCmd) + '))'
      : 'hl.unbind("ESCAPE")'
    Quickshell.execDetached(["hyprctl", "eval", lua])
  }

  onShownIdChanged: syncEscape()
  Component.onCompleted: {
    loadedAt = Date.now()
    refresh()
    syncEscape()
  }
  // A platform's player appears when it first plays and vanishes when its app
  // closes; either way the PID map may have moved.
  onPlayersChanged: refresh()
  onOpenedChanged: if (opened) {
    chosenId = ""
    refresh()
    remember(viewId)
    // The hover card shares this popout key; its closing could release the
    // key after the panel claimed it. Claim it again once both settle.
    Qt.callLater(function () { if (root.opened && root.bar) root.bar.requestPopout(root) })
  }

  Process {
    id: statusProc
    command: [root.scriptPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStatus(text)
        if (parsed) {
          root.status = parsed
          // A service that no longer runs is no longer being closed.
          var still = ({})
          for (var i = 0; i < parsed.platforms.length; i++)
            if (parsed.platforms[i].running && root.stopping[parsed.platforms[i].id]) still[parsed.platforms[i].id] = true
          root.stopping = still
          // An activespecial event during the read is newer than the read.
          if (root.statusSeq === root.shownSeq) {
            root.specialByMonitor = parsed.specials || ({})
            root.shownId = String(parsed.shown || "")
          }
          root.lastActive = Model.pruneLastActive(parsed.platforms, root.lastActive)
        }
        root.adoptNewlyMapped()
      }
    }
    onExited: if (root.refreshPending) {
      root.refreshPending = false
      root.statusSeq = root.shownSeq
      statusProc.running = true
    }
  }

  // What the widget sees: `omarchy-shell iceteps.music.debug dump`. Its own
  // target, since the Panel base owns "iceteps.music". Plugin console output
  // does not reach the journal, so this is the way to look inside.
  IpcHandler {
    target: "iceteps.music.debug"
    function dump(): string {
      var names = []
      for (var i = 0; i < root.players.length; i++) {
        var p = root.players[i]
        names.push(p ? String(p.dbusName) + "|" + String(p.identity) + "|" + Model.playerPid(p) : "null")
      }
      return JSON.stringify({ n: root.players.length, isArray: Array.isArray(root.players), names: names,
        status: root.status, mapped: Object.keys(root.platformPlayers), viewId: root.viewId,
        shownId: root.shownId })
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    // The helper's errors (no chromium, say) would otherwise vanish: a button
    // that silently does nothing.
    onExited: function (exitCode) {
      if (exitCode !== 0)
        Quickshell.execDetached(["notify-send", "Music", String(actionErr.text || "").trim() || "The music helper failed"])
      if (root.actionQueue.length > 0) {
        var next = root.actionQueue[0]
        root.actionQueue = root.actionQueue.slice(1)
        root.draining = true
        // Started after this handler returns, not from inside the exit signal.
        Qt.callLater(function () {
          root.draining = false
          root.runScript(next)
        })
      }
      root.refresh()
    }
  }

  // Every 15 s, only while a service runs.
  Timer {
    interval: 15 * 1000
    repeat: true
    running: root.anyRunning
    onTriggered: root.closeIdle()
  }

  Instantiator {
    model: root.players
    delegate: Connections {
      required property var modelData
      target: modelData
      function onIsPlayingChanged() {
        if (modelData.isPlaying) root.noteStarted(modelData)
        else root.noteStopped(modelData)
        root.noteTrack(modelData)
      }
      function onTrackTitleChanged() {
        root.noteTrack(modelData)
        rememberSoon.restart()
      }
      function onTrackArtistChanged() { root.noteTrack(modelData) }
      function onTrackAlbumChanged() { root.noteTrack(modelData) }
      function onTrackArtUrlChanged() { root.noteTrack(modelData) }
      Component.onCompleted: {
        root.noteTrack(modelData)
        root.noteAppeared(modelData)
      }
    }
  }

  Timer {
    id: artSettle
    interval: 700
    onTriggered: root.shownArt = root.viewArt
  }

  // A track change emits several updates; remember once they settle.
  Timer {
    id: rememberSoon
    interval: 3000
    onTriggered: root.rememberAll()
  }

  Timer {
    id: releaseHeld
    interval: 2500
    onTriggered: root.dropStaleHeld()
  }

  // MPRIS does not push position; re-read it while someone is looking.
  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.viewPlayer !== null && root.viewPlayer.isPlaying
    onTriggered: root.viewPlayer.positionChanged()
  }

  // ---------- Bar widget ----------

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: !root.barTrack ? "󰝚" : root.barTrack.playing ? "󰏤" : "󰐊"
      // One width for every glyph, so play/pause does not nudge the title.
      width: Math.ceil(font.pixelSize * 1.25)
      horizontalAlignment: Text.AlignHCenter
      color: root.barTrack && root.barTrack.playing ? root.barForeground : Qt.darker(root.barForeground, 1.5)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.barPlayer !== null && !root.vertical
      textFormat: Text.PlainText
      text: Model.tagFor(root.barPlatformId)
      color: Commons.Color.accent
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Item {
      id: scrollClip
      anchors.verticalCenter: parent.verticalCenter
      visible: root.barPlayer !== null && !root.vertical
      // Fixed, not sized to the title: a width that followed each song moved the
      // widgets beside it, and the panel anchored under it, on every track change.
      width: Style.space(200)
      height: glyph.height
      clip: true

      Text {
        id: label
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.barTrack ? Model.trackLabel(root.barTrack.title, root.barTrack.artist) : ""
        color: root.barTrack && root.barTrack.playing ? root.barForeground : Qt.darker(root.barForeground, 1.5)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body

        NumberAnimation on x {
          running: label.implicitWidth > scrollClip.width && !root.opened && !root.vertical
            && root.barTrack !== null && root.barTrack.playing
          loops: Animation.Infinite
          duration: Math.max(6000, label.implicitWidth * 25)
          from: scrollClip.width
          to: -label.implicitWidth
          easing.type: Easing.Linear
          onRunningChanged: if (!running) label.x = 0
        }
      }
    }
  }

  MouseArea {
    id: barMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton

    // The play/pause glyph (with a margin, the whole bar height) plays or
    // pauses. Anywhere else: hides a shown app (the quickest way back from
    // searching), else opens or closes the panel.
    function hitsGlyph(x) {
      var left = glyph.mapToItem(barMouse, 0, 0).x
      var margin = Style.space(4)
      return x >= left - margin && x <= left + glyph.width + margin
    }

    onClicked: function (mouse) {
      if (mouse.button === Qt.MiddleButton || (root.barPlayer && hitsGlyph(mouse.x)))
        root.control(root.barPlayer, "playPause")
      else if (root.shownId !== "" && !root.opened) root.runScript(["hide"])
      else root.toggle()
    }
    // Swallowed, not acted on: a touchpad sends wheel events while a finger
    // merely rests or drifts, and skipping tracks on them changed songs on hover.
    onWheel: function (wheel) { wheel.accepted = true }
    // Playing: a cover card after a short rest (passing over does not flash it).
    // Idle: the usual text tooltip.
    onEntered: {
      if (root.shownId !== "") {
        if (root.bar) root.bar.showTooltip(root, "Click: hide the music app")
      } else if (root.barTrack) hoverDelay.restart()
      else if (root.bar) root.bar.showTooltip(root, "Music\nClick: panel  ·  SUPER+SHIFT+M")
    }
    onExited: {
      hoverDelay.stop()
      root.hoverCardOpen = false
      if (root.bar) root.bar.hideTooltip(root)
    }
    onPressed: {
      hoverDelay.stop()
      root.hoverCardOpen = false
    }
  }

  property bool hoverCardOpen: false

  Timer {
    id: hoverDelay
    interval: 350
    // Never over an open panel, or over another widget's popup (opening would
    // close it: the bar shows one popup at a time).
    onTriggered: root.hoverCardOpen = !root.opened && root.barTrack !== null
      && (!root.bar || !root.bar.activePopout || root.bar.activePopout === root)
  }

  PopupCard {
    id: hoverCard
    anchorItem: root
    bar: root.bar
    owner: root
    triggerMode: "hover"
    open: root.hoverCardOpen && !root.opened
    contentWidth: hoverCard.fittedContentWidth(Style.space(220))
    contentHeight: hoverCard.fittedContentHeight(hoverColumn.implicitHeight)

    Column {
      id: hoverColumn
      width: parent.width
      spacing: Style.spacing.lg

      Item {
        width: parent.width
        height: width

        Image {
          id: hoverArt
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          asynchronous: false
          source: root.barTrack ? root.barTrack.art : ""
          visible: status === Image.Ready
        }

        Text {
          anchors.centerIn: parent
          visible: hoverArt.status !== Image.Ready
          textFormat: Text.PlainText
          text: "󰝚"
          color: root.bar ? root.bar.foreground : Commons.Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.display
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: root.barTrack ? root.barTrack.title : ""
        color: root.bar ? root.bar.foreground : Commons.Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        visible: text !== ""
        text: root.barTrack ? root.barTrack.artist : ""
        color: Qt.darker(root.bar ? root.bar.foreground : Commons.Color.foreground, 1.3)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  // ---------- Panel ----------

  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) { if (dx !== 0) root.stepPlatform(dx) }
      onActivateRequested: root.action("playPause")

      Column {
        id: column
        width: parent.width
        spacing: Style.spacing.panelGap

        ButtonGroup {
          width: parent.width
          options: root.tabOptions
          value: root.viewId
          focusable: false
          foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onChanged: function (value) { root.chosenId = value }
        }

        // Not running: where you left off, if it played before, and one way in.
        Column {
          visible: !root.viewRunning
          width: parent.width
          spacing: Style.spacing.rowGap

          Row {
            visible: root.viewLast !== null
            width: parent.width
            spacing: Style.spacing.xxl

            BorderSurface {
              width: Style.space(84)
              height: Style.space(84)
              radius: Style.spacing.labelGap
              color: Style.normalFillFor(root.bar ? root.bar.foreground : Commons.Color.foreground, Commons.Color.accent)
              borderSpec: Border.controlSpec("normal", root.bar ? root.bar.foreground : Commons.Color.foreground, Commons.Color.accent)

              Image {
                id: lastCover
                anchors.fill: parent
                anchors.margins: Style.space(2)
                fillMode: Image.PreserveAspectCrop
                source: root.viewLast && root.viewLast.cover ? "file://" + root.viewLast.cover : ""
                visible: status === Image.Ready
              }

              Text {
                anchors.centerIn: parent
                visible: lastCover.status !== Image.Ready
                textFormat: Text.PlainText
                text: "󰝚"
                color: root.bar ? root.bar.foreground : Commons.Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.displayLarge
              }
            }

            Column {
              width: parent.width - Style.space(84) - parent.spacing
              spacing: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                width: parent.width
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: root.viewLast ? root.viewLast.title : ""
                color: root.bar ? root.bar.foreground : Commons.Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                elide: Text.ElideRight
                visible: text !== ""
                text: root.viewLast ? root.viewLast.artist : ""
                color: Qt.darker(root.bar ? root.bar.foreground : Commons.Color.foreground, 1.3)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                elide: Text.ElideRight
                visible: text !== ""
                text: root.viewLast ? root.viewLast.album : ""
                color: Qt.darker(root.bar ? root.bar.foreground : Commons.Color.foreground, 1.6)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: root.viewLast ? Model.leftOffLabel(root.viewLast, Date.now() / 1000) : ""
                color: Qt.darker(root.bar ? root.bar.foreground : Commons.Color.foreground, 1.6)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            visible: root.viewLast === null
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: (root.viewEntry ? root.viewEntry.label : "This platform") + " is not running."
            color: root.bar ? root.bar.foreground : Commons.Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Button {
            text: (root.viewLast ? "Open " : "Start ") + (root.viewEntry ? root.viewEntry.label : "")
            iconText: "󰐊"
            bordered: true
            foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: {
              root.runScript(["launch", root.viewId, "--show"])
              root.close()
            }
          }
        }

        // Running: now playing, or a nudge to pick something.
        Row {
          visible: root.viewRunning
          width: parent.width
          spacing: Style.spacing.xxl

          BorderSurface {
            width: Style.space(84)
            height: Style.space(84)
            radius: Style.spacing.labelGap
            color: Style.normalFillFor(root.bar ? root.bar.foreground : Commons.Color.foreground, Commons.Color.accent)
            borderSpec: Border.controlSpec("normal", root.bar ? root.bar.foreground : Commons.Color.foreground, Commons.Color.accent)

            Image {
              anchors.fill: parent
              anchors.margins: Style.space(2)
              fillMode: Image.PreserveAspectCrop
              // Chromium hands a small local file; loading it in step keeps the
              // old cover up instead of blanking to the placeholder on a skip.
              asynchronous: false
              source: root.shownArt
              visible: status === Image.Ready
            }

            Text {
              anchors.centerIn: parent
              visible: !root.shownArt
              textFormat: Text.PlainText
              text: "󰝚"
              color: root.bar ? root.bar.foreground : Commons.Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.displayLarge
            }
          }

          Column {
            width: parent.width - Style.space(84) - parent.spacing
            spacing: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: root.viewHasTrack ? root.viewTrack.title : "Nothing playing yet"
              color: root.bar ? root.bar.foreground : Commons.Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              visible: text !== ""
              text: root.viewHasTrack ? root.viewTrack.artist : "Show the app and pick something."
              color: Qt.darker(root.bar ? root.bar.foreground : Commons.Color.foreground, 1.3)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              visible: text !== ""
              text: root.viewHasTrack ? root.viewTrack.album : ""
              color: Qt.darker(root.bar ? root.bar.foreground : Commons.Color.foreground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              visible: root.viewHasTrack
              text: root.viewHasTrack && root.viewTrack.playing
                ? (root.overlayShown ? "Playing" : "Playing in background")
                : "Paused"
              color: root.viewHasTrack && root.viewTrack.playing ? Commons.Color.accent : Qt.darker(root.bar ? root.bar.foreground : Commons.Color.foreground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // Seek bar, when the player reports a length.
        Column {
          visible: root.viewHasTrack && root.viewTrack.length > 0
          width: parent.width
          spacing: Style.space(4)

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: root.viewHasTrack ? Math.max(1, root.viewTrack.length) : 1
            value: root.viewPlayer ? root.viewPlayer.position : 0
            step: 1
            enabled: !!(root.viewPlayer && root.viewPlayer.canSeek)
            onReleased: function (value) {
              if (root.viewPlayer && root.viewPlayer.canSeek) root.viewPlayer.position = value
            }
          }

          Item {
            width: parent.width
            height: elapsed.implicitHeight

            Text {
              id: elapsed
              anchors.left: parent.left
              textFormat: Text.PlainText
              text: Model.formatTime(root.viewPlayer ? root.viewPlayer.position : -1)
              color: Qt.darker(root.bar ? root.bar.foreground : Commons.Color.foreground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: Model.formatTime(root.viewHasTrack ? root.viewTrack.length : -1)
              color: Qt.darker(root.bar ? root.bar.foreground : Commons.Color.foreground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Row {
          visible: root.viewHasTrack
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.spacing.lg

          Button {
            iconText: "󰒮"
            tooltipText: "Previous"
            foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
            enabled: !!(root.viewPlayer && root.viewPlayer.canGoPrevious)
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.action("previous")
          }

          Button {
            iconText: root.viewHasTrack && root.viewTrack.playing ? "󰏤" : "󰐊"
            tooltipText: root.viewHasTrack && root.viewTrack.playing ? "Pause" : "Play"
            foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
            iconSize: Style.font.iconLarge
            horizontalPadding: Style.spacing.panelGap
            bordered: true
            onClicked: root.action("playPause")
          }

          Button {
            iconText: "󰒭"
            tooltipText: "Next"
            foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
            enabled: !!(root.viewPlayer && root.viewPlayer.canGoNext)
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.action("next")
          }
        }

        Row {
          visible: root.viewRunning
          width: parent.width
          spacing: Style.spacing.lg

          Button {
            width: (parent.width - parent.spacing) / 2
            text: root.overlayShown ? "Hide app" : "Show app"
            bordered: true
            foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: {
              root.runScript(root.overlayShown ? ["hide"] : ["show", root.viewId])
              // The app covers the screen; the panel would sit on its controls.
              if (!root.overlayShown) root.close()
            }
          }

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Stop & close"
            bordered: true
            foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: root.stopService(root.viewId, "Stop & close")
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          text: "SUPER+SHIFT+M panel  ·  SUPER+M show app"
          color: Qt.darker(root.bar ? root.bar.foreground : Commons.Color.foreground, 1.6)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
