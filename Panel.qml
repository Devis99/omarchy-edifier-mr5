import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "devis99.edifier-mr5"
  ipcTarget: "devis99.edifier-mr5"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color barIconColor: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property color card: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.055)

  visible: true
  implicitWidth: vertical ? barSize : chipRow.implicitWidth + Style.space(10)
  implicitHeight: vertical ? chipColumn.implicitHeight + Style.space(8) : barSize

  Service {
    id: edifier
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { edifier.refresh(); return "ok" }
  }

  Component.onCompleted: edifier.refresh()

  onOpenedChanged: if (opened) {
    edifier.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else {
    settingsMode = false
    deleteTargetProfile = ""
    edifier.eqShareCode = ""
    importField.text = ""
  }

  property var registeredBar: null
  property bool settingsMode: false
  property string deleteTargetProfile: ""
  property int draftRefreshIntervalSec: edifier.refreshIntervalSec
  property string settingsStatusText: ""

  function openSettings() {
    draftRefreshIntervalSec = edifier.refreshIntervalSec
    settingsStatusText = ""
    settingsMode = true
  }

  function closeSettings() {
    settingsMode = false
    settingsStatusText = ""
  }

  function canPersistSettings() {
    return !!(bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
  }

  function saveSettings() {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry.refreshIntervalSec = Math.max(2, Math.min(60, Math.round(draftRefreshIntervalSec)))
    root.settings = entry
    if (root.canPersistSettings()) {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
      settingsStatusText = "Saved"
    } else {
      settingsStatusText = "Saved for this session"
    }
  }

  function statusText() {
    if (!edifier.connected) return edifier.everConnected ? "Disconnected" : "Connecting…"
    return "Connected"
  }

  function volumePercent() {
    if (edifier.volumeMax <= 0) return 0
    return Math.round((edifier.volume / edifier.volumeMax) * 100)
  }

  function modeName(mode) {
    if (mode === 0) return "Monitor"
    if (mode === 1) return "Music"
    if (mode === 2) return "Custom"
    return "—"
  }

  function triggerPress(button) {
    if (root.bar) root.bar.hideTooltip(chipItem)
    if (button === Qt.MiddleButton) { edifier.refresh(); return }
    root.toggle()
    if (root.opened) edifier.refresh()
  }

  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(chipItem)
    registeredBar = root.bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(chipItem)
  }

  onBarChanged: syncClickRegistration()
  Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(chipItem)

  Item {
    id: chipItem
    anchors.fill: parent

    function triggerPress(button) { root.triggerPress(button) }

    Item {
      id: chipRow
      visible: !root.vertical
      anchors.centerIn: parent
      implicitWidth: icon.implicitWidth
      implicitHeight: icon.implicitHeight

      SpeakerIcon {
        id: icon
        color: root.barIconColor
        connected: edifier.connected
      }
    }

    Item {
      id: chipColumn
      visible: root.vertical
      anchors.centerIn: parent
      implicitWidth: vIcon.implicitWidth
      implicitHeight: vIcon.implicitHeight

      SpeakerIcon {
        id: vIcon
        color: root.barIconColor
        connected: edifier.connected
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (root.bar) root.bar.showTooltip(chipItem, "Edifier MR5 — " + root.statusText())
      onExited: if (root.bar) root.bar.hideTooltip(chipItem)
      onClicked: function(mouse) { root.triggerPress(mouse.button) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: chipItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(edifier.eqMode === 2 ? Style.space(360) : Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, edifier.eqMode === 2 ? Style.space(660) : Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "s" || t === "S") { root.settingsMode ? root.saveSettings() : root.openSettings(); return }
        if (root.settingsMode) return
        if (t === "r" || t === "R") edifier.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: panelFlick.width
        spacing: Style.space(10)

        RowLayout {
          width: parent.width
          spacing: 10

          SpeakerIcon {
            size: 24
            color: root.foreground
            connected: edifier.connected
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
              text: root.settingsMode ? "Settings" : "Edifier MR5"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: 15
              font.bold: true
            }

            RowLayout {
              visible: !root.settingsMode
              spacing: 5
              Rectangle {
                width: 7
                height: 7
                radius: 3.5
                color: edifier.connected ? "#4CAF50" : (edifier.everConnected ? "#E57373" : root.dim)
              }
              Text {
                text: root.statusText()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelButton {
            visible: root.settingsMode
            text: "Back"
            onClicked: root.closeSettings()
          }

          PanelButton {
            visible: root.settingsMode
            text: "Save"
            active: true
            onClicked: root.saveSettings()
          }

          PanelActionButton {
            visible: !root.settingsMode
            iconText: "⟳"
            tooltipText: "Refresh (r)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: edifier.refresh()
          }

          PanelActionButton {
            visible: !root.settingsMode
            iconText: "⋮"
            tooltipText: "Settings (s)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openSettings()
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- Volume ----------
        SectionCard {
          visible: !root.settingsMode
          title: "Volume"
          headerRight: edifier.connected ? (root.volumePercent() + "%") : "—"

          PanelSlider {
            bar: root.bar
            Layout.fillWidth: true
            minimum: 0
            maximum: edifier.volumeMax > 0 ? edifier.volumeMax : 100
            step: 1
            integer: true
            value: edifier.volume
            enabled: edifier.connected

            onMoved: function(v) { edifier.setVolume(v) }
          }
        }

        // ---------- Sound mode ----------
        SectionCard {
          visible: !root.settingsMode
          title: "Sound Mode"
          headerRight: edifier.eqMode >= 0 ? root.modeName(edifier.eqMode) : "—"

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: ["Monitor", "Music", "Custom"]
              PanelButton {
                required property string modelData
                required property int index
                Layout.fillWidth: true
                text: modelData
                active: edifier.eqMode === index
                enabled: edifier.connected
                onClicked: edifier.setEq(index)
              }
            }
          }
        }

        // ---------- Custom EQ curve ----------
        SectionCard {
          visible: !root.settingsMode && edifier.eqMode === 2
          title: "Custom EQ"
          headerRight: edifier.customEqName

          Row {
            Layout.fillWidth: true
            spacing: (parent.width - (edifier.customEqBands.length * 26)) / Math.max(1, edifier.customEqBands.length - 1)

            Repeater {
              model: edifier.customEqBands
              EqBandSlider {
                required property var modelData
                required property int index
                bandIndex: index
                freq: modelData.freq
                gain: modelData.gain
              }
            }
          }

          RowLayout {
            visible: edifier.eqProfiles.length > 0
            width: parent.width
            spacing: Style.space(8)

            Dropdown {
              id: profileDropdown
              Layout.fillWidth: true
              showLabel: false
              foreground: root.foreground
              accent: Color.accent
              options: edifier.eqProfiles
              value: edifier.customEqName
              onChanged: function(v) { edifier.applyEqProfile(v) }
            }

            PanelActionButton {
              iconText: "×"
              tooltipText: "Delete this preset"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: edifier.eqProfiles.indexOf(edifier.customEqName) >= 0
              onClicked: root.deleteTargetProfile = edifier.customEqName
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            PanelTextField {
              id: eqNameField
              Layout.fillWidth: true
              placeholderText: "Preset name"
              text: edifier.customEqName
              onAccepted: { edifier.setCustomEqName(text); edifier.saveEqProfile(text) }
            }

            PanelButton {
              text: "Save as preset"
              enabled: edifier.connected
              onClicked: { edifier.setCustomEqName(eqNameField.text); edifier.saveEqProfile(eqNameField.text) }
            }
          }

          Text {
            width: parent.width
            text: "Share a preset"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              PanelTextField {
                Layout.fillWidth: true
                readOnly: true
                selectByMouse: true
                text: edifier.eqShareCode
                placeholderText: "Export a preset to get a code"
              }

              PanelButton {
                text: "Export"
                enabled: edifier.customEqName !== ""
                onClicked: edifier.exportEqProfile(edifier.customEqName)
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              PanelTextField {
                id: importField
                Layout.fillWidth: true
                placeholderText: "Paste a share code"
                onAccepted: edifier.importEqProfile(text)
              }

              PanelButton {
                text: "Import"
                onClicked: edifier.importEqProfile(importField.text)
              }
            }
          }
        }

        // ---------- Footer ----------
        Text {
          visible: edifier.lastError !== ""
          width: parent.width
          text: edifier.lastError
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------- Settings ----------
        Column {
          visible: root.settingsMode
          width: parent.width
          spacing: Style.space(10)

          SectionCard {
            title: "Firmware"

            Text {
              width: parent.width
              text: edifier.firmwareVersion !== "" ? ("Installed: " + edifier.firmwareVersion) : "Installed: —"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          SectionCard {
            title: "Acoustic Tuning"
            headerRight: edifier.lowCutoffFreq >= 0 ? (edifier.lowCutoffFreq + "Hz") : "—"

            Text {
              width: parent.width
              text: "Low cutoff: " + (edifier.lowCutoffFreq >= 0 ? edifier.lowCutoffFreq + "Hz" : "—")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // Wrapped so an overlay can swallow wheel events without
            // affecting drag/click — otherwise scrolling the settings list
            // while the cursor happens to pass over this slider nudges its
            // value instead of just scrolling the page.
            Item {
              Layout.fillWidth: true
              height: freqSlider.implicitHeight

              PanelSlider {
                id: freqSlider
                bar: root.bar
                anchors.fill: parent
                minimum: 20
                maximum: 100
                step: 5
                integer: true
                value: edifier.lowCutoffFreq >= 0 ? edifier.lowCutoffFreq : 20
                enabled: edifier.connected

                onMoved: function(v) { edifier.setAcousticTuning({ freq: Math.round(v / 5) * 5 }) }
              }

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                onWheel: function(wheel) { wheel.accepted = false }
              }
            }

            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

            Text {
              width: parent.width
              text: "Slope: " + (edifier.lowCutoffSlope >= 0 && edifier.lowCutoffSlope < 4
                ? (-[6, 12, 18, 24][edifier.lowCutoffSlope]) + "dB/octave" : "—")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: ["-6", "-12", "-18", "-24"]
                PanelButton {
                  required property string modelData
                  required property int index
                  Layout.fillWidth: true
                  text: modelData
                  bordered: true
                  active: edifier.lowCutoffSlope === index
                  enabled: edifier.connected
                  onClicked: edifier.setAcousticTuning({ slope: index })
                }
              }
            }

            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

            Text {
              width: parent.width
              text: "Acoustic space: " + (edifier.acousticSpace >= 0
                ? (edifier.acousticSpace === 0 ? "0dB" : ("-" + edifier.acousticSpace + "dB")) : "—")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: ["0", "-1", "-2", "-3", "-4"]
                PanelButton {
                  required property string modelData
                  required property int index
                  Layout.fillWidth: true
                  text: modelData
                  bordered: true
                  active: edifier.acousticSpace === index
                  enabled: edifier.connected
                  onClicked: edifier.setAcousticTuning({ space: index })
                }
              }
            }

            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

            Text {
              width: parent.width
              text: "Desktop Control: " + (edifier.desktopControl ? "On" : "Off")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            PanelButton {
              Layout.fillWidth: true
              text: edifier.desktopControl ? "Turn Off" : "Turn On"
              bordered: true
              enabled: edifier.connected
              onClicked: edifier.setAcousticTuning({ desktop: !edifier.desktopControl })
            }
          }

          SectionCard {
            title: "Connection"

            PanelButton {
              Layout.fillWidth: true
              text: "Reconnect"
              bordered: true
              onClicked: edifier.reconnect()
            }

            PanelButton {
              Layout.fillWidth: true
              text: "Rescan"
              tooltipText: "Forget the saved address and scan for the speaker again"
              bordered: true
              onClicked: edifier.rescan()
            }

            PanelButton {
              Layout.fillWidth: true
              text: "Hard reconnect"
              tooltipText: "Power-cycles the Bluetooth adapter — briefly disrupts other Bluetooth devices"
              bordered: true
              onClicked: edifier.hardReconnect()
            }
          }

          SectionCard {
            title: "Polling"

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              NumberField {
                label: "Status refresh interval (sec)"
                value: root.draftRefreshIntervalSec
                from: 2
                to: 60
                stepSize: 1
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                onModified: function(v) { root.draftRefreshIntervalSec = v }
              }
            }
          }

          Text {
            visible: root.settingsStatusText !== ""
            width: parent.width
            text: root.settingsStatusText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }

        Text {
          width: parent.width
          text: root.settingsMode ? "s saves · esc closes" : "r refreshes · s settings · esc closes"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
      }
    }

    ConfirmDialog {
      anchors.fill: parent
      opened: root.deleteTargetProfile !== ""
      message: "Delete preset \"" + root.deleteTargetProfile + "\"?"
      cancelText: "Cancel"
      confirmText: "Delete"
      background: root.bar ? root.bar.background : Color.background
      foreground: root.foreground
      onCanceled: root.deleteTargetProfile = ""
      onConfirmed: {
        edifier.deleteEqProfile(root.deleteTargetProfile)
        root.deleteTargetProfile = ""
      }
    }
  }

  component PanelButton: Button {
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
  }

  component PanelTextField: TextField {
    foreground: root.foreground
    accent: Color.accent
  }

  component SectionCard: BorderSurface {
    id: section
    property string title: ""
    property string headerRight: ""
    default property alias content: body.data

    width: parent.width
    color: root.card
    borderSpec: Border.flat(Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05), 1)
    padding: 12
    radius: Style.cornerRadius
    implicitHeight: body.implicitHeight + contentTopInset + contentBottomInset

    ColumnLayout {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: section.contentTopInset
      anchors.rightMargin: section.contentRightInset
      anchors.bottomMargin: section.contentBottomInset
      anchors.leftMargin: section.contentLeftInset
      spacing: 8

      RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Text {
          text: section.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: 12
          font.bold: true
          Layout.fillWidth: true
        }

        Text {
          visible: section.headerRight !== ""
          text: section.headerRight
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: 10
        }
      }
    }
  }

  component EqBandSlider: Column {
    id: bandCol
    property int bandIndex: 0
    property int freq: 0
    property int gain: 0
    property int maxGain: 20
    spacing: 4
    width: 26

    function freqLabel() {
      return freq >= 1000 ? Math.round(freq / 1000) + "k" : String(freq)
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: String(bandCol.gain)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: 9
    }

    Item {
      id: bandTrack
      width: parent.width
      height: 90
      anchors.horizontalCenter: parent.horizontalCenter

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: 3
        height: parent.height
        radius: 1.5
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
      }

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        width: 3
        radius: 1.5
        color: Color.accent
        height: Math.max(2, (bandCol.gain / bandCol.maxGain) * parent.height)
      }

      Rectangle {
        width: 12
        height: 12
        radius: 6
        color: Color.accent
        border.color: root.foreground
        border.width: 1
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - (bandCol.gain / bandCol.maxGain) * parent.height - height / 2
      }

      MouseArea {
        anchors.fill: parent
        anchors.margins: -6
        enabled: edifier.connected
        onPressed: function(mouse) { updateFromY(mouse.y) }
        onPositionChanged: function(mouse) { if (pressed) updateFromY(mouse.y) }

        function updateFromY(y) {
          var ratio = 1 - Math.max(0, Math.min(1, y / bandTrack.height))
          edifier.setCustomEqBand(bandCol.bandIndex, ratio * bandCol.maxGain)
        }
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: bandCol.freqLabel()
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: 9
    }
  }
}
