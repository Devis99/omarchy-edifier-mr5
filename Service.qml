import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var settings: ({})

  property bool connected: false
  property string address: ""
  property string mac: ""
  property string firmwareVersion: ""
  property int volumeMax: 30
  property int volume: 0
  property int inputIndex: -1
  property int inputValue: -1
  property int eqMode: -1
  property int lowCutoffFreq: -1
  property int lowCutoffSlope: -1
  property int acousticSpace: -1
  property bool desktopControl: false
  property var customEqBands: []
  property string customEqName: ""
  property var eqProfiles: []
  property string eqShareCode: ""
  property string latestKnownFirmware: ""
  property string lastError: ""
  property double lastUpdateMs: 0
  property bool busy: false
  property bool everConnected: false

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 60)
  readonly property string ctlPath: String(Qt.resolvedUrl("scripts/edifier_ctl.py")).replace("file://", "")

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
    mac = data.mac || ""
    firmwareVersion = data.firmware_version || ""
    if (data.volume_max !== null && data.volume_max !== undefined) volumeMax = data.volume_max
    // A status poll can be in flight when the user starts dragging; skip
    // applying its (now-stale) volume for a moment so it can't clobber the
    // optimistic value back to where the drag started. Direct set-volume
    // responses always apply immediately (recentLocalSet re-arms below).
    var recentLocalSet = (Date.now() - _lastVolumeSetMs) < 800
    if (data.volume !== null && data.volume !== undefined && !recentLocalSet) volume = data.volume
    if (data.input_index !== null && data.input_index !== undefined) inputIndex = data.input_index
    if (data.input_value !== null && data.input_value !== undefined) inputValue = data.input_value
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
    if (data.latest_known_firmware !== null && data.latest_known_firmware !== undefined) latestKnownFirmware = data.latest_known_firmware
    lastError = data.error || data.last_error || ""
    lastUpdateMs = Date.now()
  }

  // Status polls and user commands are serialized through one process and one
  // queue so a periodic refresh can never land out-of-order with an in-flight
  // "set volume" and overwrite it with a stale value mid-drag (this caused the
  // slider to visibly jump). Same-key commands (e.g. rapid drag samples)
  // coalesce to the latest value instead of queueing every intermediate step.
  property var _queue: []

  function _coalesceKey(args) {
    return args.length > 0 ? args[0] : ""
  }

  function _enqueue(args) {
    var key = _coalesceKey(args)
    var next = []
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].key !== key) next.push(_queue[i])
    }
    next.push({ key: key, args: args })
    _queue = next
    _pump()
  }

  function _pump() {
    if (opProcess.running) return
    if (_queue.length === 0) return
    var next = _queue[0]
    _queue = _queue.slice(1)
    busy = true
    opProcess.command = ["python3", ctlPath].concat(next.args)
    opProcess.running = true
  }

  function refresh() {
    _enqueue(["status"])
  }

  function runCommand(args) {
    _enqueue(args)
  }

  property double _lastVolumeSetMs: 0
  property double _lastCustomEqSetMs: 0
  property double _lastTuningSetMs: 0

  function setVolume(value) {
    var v = Math.max(0, Math.min(volumeMax > 0 ? volumeMax : 100, Math.round(value)))
    volume = v // optimistic local update for a snappy slider
    _lastVolumeSetMs = Date.now()
    runCommand(["set-volume", String(v)])
  }

  function setEq(mode) {
    eqMode = mode
    runCommand(["set-eq", String(mode)])
  }

  function setAcousticTuning(fields) {
    // fields: partial object, any of {freq, slope, space, desktop}. Always
    // sends the full current snapshot (not just the changed field) so that
    // if two field-changes coalesce in the queue, the surviving one is still
    // complete and correct rather than silently dropping the other field's
    // change.
    if (fields.freq !== undefined) lowCutoffFreq = fields.freq
    if (fields.slope !== undefined) lowCutoffSlope = fields.slope
    if (fields.space !== undefined) acousticSpace = fields.space
    if (fields.desktop !== undefined) desktopControl = fields.desktop
    _lastTuningSetMs = Date.now()
    runCommand([
      "set-acoustic-tuning",
      "low_cutoff_freq=" + lowCutoffFreq,
      "low_cutoff_slope=" + lowCutoffSlope,
      "acoustic_space=" + acousticSpace,
      "desktop_control=" + (desktopControl ? "1" : "0"),
    ])
  }

  function setCustomEqBand(bandIndex, gain) {
    var g = Math.max(0, Math.min(20, Math.round(gain)))
    var bands = customEqBands.slice()
    if (bands[bandIndex]) {
      bands[bandIndex] = { freq: bands[bandIndex].freq, gain: g }
      customEqBands = bands // optimistic local update for a snappy slider
    }
    _lastCustomEqSetMs = Date.now()
    runCommand(["set-custom-eq-band", String(bandIndex), String(g)])
  }

  function setCustomEqName(name) {
    if (!name || name.length === 0) return
    customEqName = name // optimistic local update
    runCommand(["set-custom-eq-name", name])
  }

  function saveEqProfile(name) {
    if (!name || name.length === 0) return
    runCommand(["save-eq-profile", name])
  }

  function deleteEqProfile(name) {
    if (!name || name.length === 0) return
    runCommand(["delete-eq-profile", name])
  }

  function applyEqProfile(name) {
    if (!name || name.length === 0) return
    runCommand(["apply-eq-profile", name])
  }

  function exportEqProfile(name) {
    if (!name || name.length === 0) return
    eqShareCode = ""
    runCommand(["export-eq-profile", name])
  }

  function importEqProfile(code) {
    if (!code || code.length === 0) return
    runCommand(["import-eq-profile", code])
  }

  function reconnect() {
    runCommand(["reconnect"])
  }

  function hardReconnect() {
    runCommand(["hard-reconnect"])
  }

  function rescan() {
    runCommand(["rescan"])
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: opProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: opStdout
      waitForEnd: true
      onStreamFinished: root.applyResult(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
    onExited: {
      root.busy = false
      root._pump()
    }
  }
}
