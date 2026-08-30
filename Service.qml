import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var settings: ({})

  property bool connected: false
  property string address: ""
  property string firmwareVersion: ""
  property int volumeMax: 30
  property int volume: 0
  property int eqMode: -1
  property int lowCutoffFreq: -1
  property int lowCutoffSlope: -1
  property int acousticSpace: -1
  property bool desktopControl: false
  property var customEqBands: []
  property string customEqName: ""
  property var eqProfiles: []
  property string eqShareCode: ""
  property string lastError: ""
  property double lastUpdateMs: 0
  property bool everConnected: false

  // The command currently awaiting a reply, "" when idle. Status polls don't
  // count: they run every few seconds, so treating them as "busy" would make
  // anything bound to this flicker constantly.
  property string pendingCommand: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 60)
  readonly property string ctlPath: String(Qt.resolvedUrl("scripts/edifier_ctl.py")).replace("file://", "")
  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/edifier-mr5.sock"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function applyResult(raw) {
    var text = String(raw || "").trim()
    if (text === "") return
    var data
    try {
      data = JSON.parse(text.split("\n").pop())
    } catch (e) {
      lastError = "Failed to parse response"
      return
    }
    connected = !!data.connected
    if (connected) everConnected = true
    address = data.address || ""
    firmwareVersion = data.firmware_version || ""
    if (data.volume_max !== null && data.volume_max !== undefined) volumeMax = data.volume_max
    // A status poll can be in flight when the user starts dragging; skip
    // applying its (now-stale) volume for a moment so it can't clobber the
    // optimistic value back to where the drag started. Direct set-volume
    // responses always apply immediately (recentLocalSet re-arms below).
    var recentLocalSet = (Date.now() - _lastVolumeSetMs) < 800
    if (data.volume !== null && data.volume !== undefined && !recentLocalSet) volume = data.volume
    if (data.eq_mode !== null && data.eq_mode !== undefined) eqMode = data.eq_mode
    var recentTuningSet = (Date.now() - _lastTuningSetMs) < 800
    if (!recentTuningSet) {
      if (data.low_cutoff_freq !== null && data.low_cutoff_freq !== undefined) lowCutoffFreq = data.low_cutoff_freq
      if (data.low_cutoff_slope !== null && data.low_cutoff_slope !== undefined) lowCutoffSlope = data.low_cutoff_slope
      if (data.acoustic_space !== null && data.acoustic_space !== undefined) acousticSpace = data.acoustic_space
      if (data.desktop_control !== null && data.desktop_control !== undefined) desktopControl = data.desktop_control
    }
    var recentEqSet = (Date.now() - _lastCustomEqSetMs) < 800
    if (data.custom_eq_bands !== null && data.custom_eq_bands !== undefined && !recentEqSet) customEqBands = data.custom_eq_bands
    if (data.custom_eq_name !== null && data.custom_eq_name !== undefined) customEqName = data.custom_eq_name
    if (data.eq_profiles !== null && data.eq_profiles !== undefined) eqProfiles = data.eq_profiles
    if (data.eq_share_code !== null && data.eq_share_code !== undefined && data.eq_share_code !== "") eqShareCode = data.eq_share_code
    lastError = data.error || data.last_error || ""
    lastUpdateMs = Date.now()
  }

  // ---------- transport ----------
  //
  // One long-lived Unix socket to the daemon. Every command used to fork a
  // python3 edifier_ctl.py, which at a 5s poll meant thousands of interpreter
  // startups a day to write a single line to a socket the daemon already had
  // open. edifier_ctl.py is still the CLI entry point, and is still what
  // starts the daemon when it isn't running yet.
  //
  // Status polls and user commands are serialized through one in-flight slot
  // and one queue so a periodic refresh can never land out-of-order with an
  // in-flight "set volume" and overwrite it with a stale value mid-drag (this
  // caused the slider to visibly jump). Same-key commands (e.g. rapid drag
  // samples) coalesce to the latest value instead of queueing every step.

  property var _queue: []
  property bool _inflight: false

  function _coalesceKey(cmd) {
    // set_custom_eq_band needs the band index in the key too, otherwise
    // dragging band A then quickly starting a drag on band B while A's set
    // is still queued would coalesce them and silently drop A's update.
    if (cmd.cmd === "set_custom_eq_band") return cmd.cmd + ":" + cmd.band
    return cmd.cmd
  }

  function _enqueue(cmd) {
    var key = _coalesceKey(cmd)
    var next = []
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].key !== key) next.push(_queue[i])
    }
    next.push({ key: key, cmd: cmd })
    _queue = next
    _pump()
  }

  function _pump() {
    if (_inflight) return
    if (_queue.length === 0) return
    if (!sock || !sock.connected) { _ensureDaemon(); return }
    var next = _queue[0]
    _queue = _queue.slice(1)
    _inflight = true
    pendingCommand = next.cmd.cmd === "status" ? "" : next.cmd.cmd
    replyTimeout.restart()
    sock.write(JSON.stringify(next.cmd) + "\n")
    sock.flush()
  }

  function _onReply(line) {
    replyTimeout.stop()
    _inflight = false
    pendingCommand = ""
    applyResult(line)
    _pump()
  }

  function _ensureDaemon() {
    if (bootstrap.running) return
    bootstrap.running = true
  }

  function refresh() {
    _enqueue({ cmd: "status" })
  }

  function runCommand(cmd) {
    _enqueue(cmd)
  }

  property double _lastVolumeSetMs: 0
  property double _lastCustomEqSetMs: 0
  property double _lastTuningSetMs: 0

  function setVolume(value) {
    var v = Math.max(0, Math.min(volumeMax > 0 ? volumeMax : 100, Math.round(value)))
    volume = v // optimistic local update for a snappy slider
    _lastVolumeSetMs = Date.now()
    runCommand({ cmd: "set_volume", value: v })
  }

  function setEq(mode) {
    eqMode = mode
    runCommand({ cmd: "set_eq", mode: mode })
  }

  function setAcousticTuning(fields) {
    // fields: partial object, any of {freq, slope, space, desktop}. Always
    // sends the full current snapshot (not just the changed field) so that
    // if two field-changes coalesce in the queue, the surviving one is still
    // complete and correct rather than silently dropping the other field's
    // change. The daemon clamps any field we haven't read from the device yet.
    if (fields.freq !== undefined) lowCutoffFreq = fields.freq
    if (fields.slope !== undefined) lowCutoffSlope = fields.slope
    if (fields.space !== undefined) acousticSpace = fields.space
    if (fields.desktop !== undefined) desktopControl = fields.desktop
    _lastTuningSetMs = Date.now()
    runCommand({
      cmd: "set_acoustic_tuning",
      low_cutoff_freq: lowCutoffFreq,
      low_cutoff_slope: lowCutoffSlope,
      acoustic_space: acousticSpace,
      desktop_control: desktopControl
    })
  }

  function setCustomEqBand(bandIndex, gain) {
    var g = Math.max(0, Math.min(20, Math.round(gain)))
    var bands = customEqBands.slice()
    if (bands[bandIndex]) {
      bands[bandIndex] = { freq: bands[bandIndex].freq, gain: g }
      customEqBands = bands // optimistic local update for a snappy slider
    }
    _lastCustomEqSetMs = Date.now()
    runCommand({ cmd: "set_custom_eq_band", band: bandIndex, gain: g })
  }

  function setCustomEqName(name) {
    if (!name || name.length === 0) return
    customEqName = name // optimistic local update
    runCommand({ cmd: "set_custom_eq_name", name: name })
  }

  function saveEqProfile(name) {
    if (!name || name.length === 0) return
    runCommand({ cmd: "save_eq_profile", name: name })
  }

  function deleteEqProfile(name) {
    if (!name || name.length === 0) return
    runCommand({ cmd: "delete_eq_profile", name: name })
  }

  function applyEqProfile(name) {
    if (!name || name.length === 0) return
    runCommand({ cmd: "apply_eq_profile", name: name })
  }

  function exportEqProfile(name) {
    if (!name || name.length === 0) return
    eqShareCode = ""
    runCommand({ cmd: "export_eq_profile", name: name })
  }

  function importEqProfile(code) {
    if (!code || code.length === 0) return
    runCommand({ cmd: "import_eq_profile", code: code })
  }

  function reconnect() {
    runCommand({ cmd: "reconnect" })
  }

  function hardReconnect() {
    runCommand({ cmd: "hard_reconnect" })
  }

  function rescan() {
    runCommand({ cmd: "rescan" })
  }

  // Quickshell 0.3.1's Socket is single-use: once a connect attempt fails (the
  // daemon isn't running yet at shell start) or the connection drops (the
  // daemon exits when Bluetooth goes away), setting `connected` back to true
  // does nothing — the object has to be recreated. Toggling the property left
  // the socket dead for the rest of the session, so every command sat in the
  // queue forever while status polls still came back through the bootstrap
  // process: the panel looked connected but nothing the user changed applied.
  readonly property var sock: sockLoader.item

  function _reconnect() {
    sockLoader.active = false
    sockLoader.active = true
  }

  Loader {
    id: sockLoader
    active: true
    sourceComponent: Socket {
      path: root.socketPath
      connected: true

      parser: SplitParser {
        onRead: function(line) { root._onReply(line) }
      }

      onConnectionStateChanged: {
        if (connected) {
          root._pump()
        } else {
          // Anything mid-flight died with the connection; let the queue retry
          // instead of wedging on an in-flight slot that will never be answered.
          root._inflight = false
          root.pendingCommand = ""
          if (root._queue.length > 0) root._ensureDaemon()
        }
      }
    }
  }

  // Starts the daemon (and re-creates its socket) when it isn't running.
  // edifier_ctl.py already owns the spawn, the readiness wait, and the cache
  // directory permissions, so reuse it rather than duplicating that here. Its
  // reply is a full status payload, so it doubles as the first poll.
  Process {
    id: bootstrap
    running: false
    command: ["python3", root.ctlPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyResult(text)
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: root._reconnect()
  }

  // A dropped reply must not wedge the queue forever. hard-reconnect is the
  // slowest command the daemon runs, so this sits comfortably past it.
  Timer {
    id: replyTimeout
    interval: 30000
    repeat: false
    onTriggered: {
      root._inflight = false
      root.pendingCommand = ""
      root.lastError = "Timed out waiting for the daemon"
      root._pump()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // While disconnected, keep trying: the daemon may have crashed, or the user
  // may have killed it. Cheap — one connect attempt, no process spawn unless
  // the socket is genuinely gone.
  Timer {
    interval: 3000
    running: !(sock && sock.connected)
    repeat: true
    onTriggered: root._reconnect()
  }
}
