import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "local.edifier-mr5"
  ipcTarget: "local.edifier-mr5"
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

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

          Button {
            visible: root.settingsMode
            text: "Back"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.closeSettings()
          }

          Button {
            visible: root.settingsMode
            text: "Save"
            active: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
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

            Button {
              Layout.fillWidth: true
              text: "Monitor"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              active: edifier.eqMode === 0
              enabled: edifier.connected
              onClicked: edifier.setEq(0)
            }

            Button {
              Layout.fillWidth: true
              text: "Music"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              active: edifier.eqMode === 1
              enabled: edifier.connected
              onClicked: edifier.setEq(1)
            }

            Button {
              Layout.fillWidth: true
              text: "Custom"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              active: edifier.eqMode === 2
              enabled: edifier.connected
              onClicked: edifier.setEq(2)
            }
          }
        }

        // ---------- Custom EQ curve ----------
        SectionCard {
          visible: !root.settingsMode && edifier.eqMode === 2
          title: "Custom EQ"
          headerRight: edifier.customEqName

          Row {
            width: parent.width
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

            TextField {
              id: eqNameField
              Layout.fillWidth: true
              foreground: root.foreground
              accent: Color.accent
              placeholderText: "Preset name"
              text: edifier.customEqName
              onAccepted: { edifier.setCustomEqName(text); edifier.saveEqProfile(text) }
            }

            Button {
              text: "Save as preset"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
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

          Column {
            width: parent.width
            spacing: Style.space(6)

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                Layout.fillWidth: true
                foreground: root.foreground
                accent: Color.accent
                readOnly: true
                selectByMouse: true
                text: edifier.eqShareCode
                placeholderText: "Export a preset to get a code"
              }

              Button {
                text: "Export"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: edifier.customEqName !== ""
                onClicked: edifier.exportEqProfile(edifier.customEqName)
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: importField
                Layout.fillWidth: true
                foreground: root.foreground
                accent: Color.accent
                placeholderText: "Paste a share code"
                onAccepted: edifier.importEqProfile(text)
              }

              Button {
                text: "Import"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: edifier.importEqProfile(importField.text)
              }
            }
          }
        }

        // ---------- Footer ----------
        Text {
          visible: !root.settingsMode && edifier.firmwareVersion !== ""
          width: parent.width
          text: "Firmware " + edifier.firmwareVersion + (edifier.mac !== "" ? "  ·  " + edifier.mac : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

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

            Text {
              width: parent.width
              text: {
                if (edifier.latestKnownFirmware === "" || edifier.firmwareVersion === "") return ""
                return edifier.latestKnownFirmware === edifier.firmwareVersion
                  ? "Up to date"
                  : "Update available (update via ConneX app)"
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          SectionCard {
            title: "Connection"

            Button {
              Layout.fillWidth: true
              text: "Reconnect"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: edifier.reconnect()
            }

            Button {
              Layout.fillWidth: true
              text: "Rescan"
              tooltipText: "Forget the saved address and scan for the speaker again"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: edifier.rescan()
            }

            Button {
              Layout.fillWidth: true
              text: "Hard reconnect"
              tooltipText: "Power-cycles the Bluetooth adapter — briefly disrupts other Bluetooth devices"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
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
