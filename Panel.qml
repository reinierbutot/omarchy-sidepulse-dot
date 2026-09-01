import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Test-bench panel for the SidePulse Dot. Pick a color swatch, an animation
// preset, or type a raw LEDS.LED program; each choice writes to the mounted
// device through bin/sidepulse-dot.
Panel {
  id: root
  moduleName: "reinier.sidepulse-dot"
  ipcTarget: "reinier.sidepulse-dot"
  manageIpc: false

  readonly property color barForeground: bar ? bar.foreground : Color.foreground
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Current selection, so brightness changes can re-apply the same look.
  property string currentHex: "#00c8ff"
  property string currentMode: "" // "solid" | "pulse" | ""
  property int brightness: 255

  // Which screen of the panel is showing. "reactions" is the primary screen
  // (agent reactions); "manual" holds the demo controls (colors, brightness,
  // animation presets) and the custom-program field.
  property string screen: "reactions"

  readonly property var palette: [
    { name: "Red",     hex: "#ff0000" },
    { name: "Orange",  hex: "#ff7a00" },
    { name: "Yellow",  hex: "#ffd400" },
    { name: "Green",   hex: "#00ff00" },
    { name: "Mint",    hex: "#00ff88" },
    { name: "Cyan",    hex: "#00c8ff" },
    { name: "Blue",    hex: "#0040ff" },
    { name: "Purple",  hex: "#8800ff" },
    { name: "Magenta", hex: "#ff00cc" },
    { name: "Pink",    hex: "#ff3a80" },
    { name: "White",   hex: "#ffffff" }
  ]

  function applySolid(hex) {
    currentHex = hex
    currentMode = "solid"
    dot.apply(dot.solid(hex, brightness), hex)
    dot.saveManual(hex, "solid", brightness)
  }

  function applyPulse(hex) {
    currentHex = hex
    currentMode = "pulse"
    dot.apply(dot.pulse(hex, brightness), "Pulse " + hex)
    dot.saveManual(hex, "pulse", brightness)
  }

  function reapplyForBrightness() {
    if (currentMode === "solid") dot.apply(dot.solid(currentHex, brightness), currentHex)
    else if (currentMode === "pulse") dot.apply(dot.pulse(currentHex, brightness), "Pulse " + currentHex)
    dot.saveManual(currentHex, currentMode, brightness)
  }

  function applyCustom() {
    var text = String(customField.text || "").trim()
    if (text === "") return
    currentMode = ""
    dot.apply(text, "Custom")
    dot.saveManual(currentHex, "", brightness)
  }

  // Restore the manual color/animation/brightness the user last picked, after
  // the persisted config has loaded, so a reload/restart keeps the selection.
  Connections {
    target: dot
    function onUiRestored(hex, mode, brightness) {
      if (hex && hex !== "") root.currentHex = hex
      root.currentMode = mode
      root.brightness = brightness
    }
  }

  // The coding-agent states the Dots can react to, in display order.
  readonly property var reactionStates: [
    { state: "working", title: "Working / thinking" },
    { state: "waiting", title: "Waiting for input" },
    { state: "done",    title: "Done" },
    { state: "error",   title: "Error" },
    { state: "idle",    title: "Idle (nothing running)" }
  ]

  // First #rrggbb in a program, for the little colour preview dots.
  function firstHex(prog) {
    var m = String(prog || "").match(/#([0-9a-fA-F]{6})/)
    return m ? ("#" + m[1]) : "#101014"
  }

  // Does the program animate (multi-line / pulse / roll / repeat)?
  function isAnimated(prog) {
    var p = String(prog || "")
    return p.indexOf("\n") >= 0 || /pulse|roll|repeat|blink/.test(p)
  }

  // A friendly colour + label for a live agent state indicator.
  function stateColor(state) {
    switch (state) {
      case "working": return "#00c8ff"
      case "waiting": return "#ff8a00"
      case "done":    return "#00ff66"
      case "error":   return "#ff0000"
      default:        return root.dim
    }
  }
  function stateLabel(state) {
    switch (state) {
      case "working": return "working"
      case "waiting": return "waiting for input"
      case "done":    return "done"
      case "error":   return "error"
      default:        return "idle"
    }
  }

  function barGlyphColor() {
    if (!dot.mounted) return root.dim
    return root.barForeground
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    dot.refresh()
    Qt.callLater(function() { panelBody.forceActiveFocus() })
  }

  Service {
    id: dot
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function off(): string { dot.turnOff(); return "ok" }
    function status(): string { return dot.mounted ? "mounted" : "not-mounted" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰛨"
    tooltipText: dot.mounted
      ? (dot.deviceCount > 1
          ? (dot.deviceCount + " SidePulse Dots connected")
          : ("SidePulse Dot \u00b7 firmware " + dot.firmware))
      : "SidePulse Dot \u00b7 not connected"
    iconComponent: Component {
      Text {
        anchors.centerIn: parent
        text: button.text
        color: root.barGlyphColor()
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) dot.turnOff()
      else if (buttonCode === Qt.MiddleButton) dot.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panelBody
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    Item {
      id: panelBody
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (customField.activeFocus) return
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        } else if (event.text === "o" || event.text === "O") {
          dot.turnOff()
          event.accepted = true
        } else if (event.text === "r" || event.text === "R") {
          dot.refresh()
          event.accepted = true
        }
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
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: dot.deviceCount > 1 ? "SidePulse Dots" : "SidePulse Dot"
            meta: dot.mounted
              ? (dot.deviceCount > 1
                  ? (dot.deviceCount + " connected \u00b7 controlling "
                     + (dot.target === "all" ? "both" : dot.labelFor(dot.target)))
                  : ("Connected \u00b7 firmware " + dot.firmware))
              : "Not connected"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰛨"
                color: dot.mounted ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // Plug-in-me notice when nothing is mounted.
          Text {
            visible: !dot.mounted
            width: parent.width - Style.space(16)
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Plug in a SidePulse Dot. It mounts as a small USB drive; no drivers are needed. Presets below will light it as soon as it appears."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: dot.lastError !== ""
            width: parent.width - Style.space(16)
            anchors.horizontalCenter: parent.horizontalCenter
            text: dot.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // --- Screen switcher ----------------------------------------
          // Two screens: the primary "Reactions" screen and a "Manual"
          // screen holding the demo controls + custom-program field.
          Flow {
            width: parent.width
            spacing: Style.space(6)
            ScreenChip { label: "Reactions"; screenValue: "reactions" }
            ScreenChip { label: "Manual"; screenValue: "manual" }
          }

          // --- Target Dot ---------------------------------------------
          // Shown once more than one Dot is present: pick which one the
          // colors / presets / custom program below will drive, or Both.
          Column {
            visible: root.screen === "manual" && dot.mounted && dot.deviceCount > 1
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              width: parent.width
              text: "CONTROL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: dot.devices
                delegate: TargetChip {
                  required property int index
                  required property var modelData
                  label: "Dot " + (index + 1)
                  subtitle: modelData.serial ? String(modelData.serial) : ""
                  targetValue: String(modelData.device)
                }
              }

              // "Both" (all devices) chip.
              TargetChip {
                label: "Both"
                subtitle: dot.deviceCount + " Dots"
                targetValue: "all"
              }
            }
          }

          // --- Manual demo controls (Manual screen only) --------------
          Column {
          visible: root.screen === "manual"
          width: parent.width
          spacing: Style.space(12)

          // --- Colors -------------------------------------------------
          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            width: parent.width
            text: "COLORS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.palette
              delegate: Rectangle {
                id: swatch
                required property var modelData
                width: Style.space(34)
                height: Style.space(34)
                radius: width / 2
                color: modelData.hex
                border.width: root.currentMode === "solid" && root.currentHex === modelData.hex ? 2 : 1
                border.color: root.currentMode === "solid" && root.currentHex === modelData.hex
                  ? root.foreground
                  : root.alpha(root.foreground, 0.25)

                MouseArea {
                  id: swatchHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.applySolid(swatch.modelData.hex)
                }

                PanelToolTip {
                  visible: swatchHover.containsMouse
                  text: swatch.modelData.name + " \u00b7 " + swatch.modelData.hex + " (hold: pulse)"
                  fontFamily: root.fontFamily
                }

                // Right-click a swatch to breathe it instead of holding solid.
                MouseArea {
                  anchors.fill: parent
                  acceptedButtons: Qt.RightButton
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.applyPulse(swatch.modelData.hex)
                }
              }
            }
          }

          // --- Brightness ---------------------------------------------
          PanelSeparator { foreground: root.foreground }

          Item {
            width: parent.width
            implicitHeight: brightLabel.implicitHeight

            PanelSectionHeader {
              id: brightLabel
              anchors.left: parent.left
              text: "BRIGHTNESS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: brightLabel.verticalCenter
              text: Math.round(root.brightness / 255 * 100) + "%"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Item {
            width: parent.width - Style.space(8)
            anchors.horizontalCenter: parent.horizontalCenter
            implicitHeight: Style.space(20)

            Rectangle {
              id: brightTrack
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              height: Style.space(6)
              radius: height / 2
              color: root.alpha(root.foreground, 0.18)

              Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                radius: parent.radius
                width: parent.width * (root.brightness - 8) / (255 - 8)
                color: root.foreground
              }

              Rectangle {
                width: Style.space(14)
                height: Style.space(14)
                radius: width / 2
                color: root.foreground
                anchors.verticalCenter: parent.verticalCenter
                x: (brightTrack.width - width) * (root.brightness - 8) / (255 - 8)
              }
            }

            MouseArea {
              anchors.fill: parent
              function setFromX(mx) {
                var ratio = root.clamp(mx / width, 0, 1)
                root.brightness = Math.round(8 + ratio * (255 - 8))
              }
              onPressed: function(mouse) { setFromX(mouse.x) }
              onPositionChanged: function(mouse) { if (pressed) setFromX(mouse.x) }
              onReleased: root.reapplyForBrightness()
            }
          }

          // --- Animation presets --------------------------------------
          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            width: parent.width
            text: "ANIMATIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PresetButton {
              label: "Breathing cyan"
              program: "off\n#00c8ff 1.6s pulse\nrepeat"
            }
            PresetButton {
              label: "Alternating red / blue"
              program: "0:#ff0000 1:#0040ff 250ms none\n0:#0040ff 1:#ff0000 250ms none\nrepeat"
            }
            PresetButton {
              label: "Rainbow roll"
              program: "0:#ff0044 1:#00ccff\nroll 2s linear\nrepeat"
            }
            PresetButton {
              label: "Police blink"
              program: "#ff0000 120ms none\n#0000ff 120ms none\nrepeat"
            }
            PresetButton {
              label: "Soft green heartbeat"
              program: "#00ff44 220ms pulse\noff 120ms none\n#00ff44 220ms pulse\noff 700ms none\nrepeat"
            }
          }
          } // end Manual demo controls wrapper

          // --- Agent reactions (Reactions screen only) ----------------
          // Make the Dots react to your coding agents' state (agy / grok /
          // junie / opencode). Toggle it on, then map a colour to each state.
          Column {
          visible: root.screen === "reactions"
          width: parent.width
          spacing: Style.space(12)

          PanelSeparator { foreground: root.foreground }

          Item {
            width: parent.width
            implicitHeight: reactHeader.implicitHeight

            PanelSectionHeader {
              id: reactHeader
              anchors.left: parent.left
              text: "AGENT REACTIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // Enable / disable pill.
            CursorSurface {
              anchors.right: parent.right
              anchors.verticalCenter: reactHeader.verticalCenter
              foreground: root.foreground
              implicitWidth: enableText.implicitWidth + Style.space(20)
              implicitHeight: enableText.implicitHeight + Style.space(8)

              Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: dot.reactionsEnabled ? root.alpha(root.accent, 0.22) : "transparent"
                border.width: 1
                border.color: dot.reactionsEnabled ? root.accent : root.alpha(root.foreground, 0.3)
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: dot.setReactionsEnabled(!dot.reactionsEnabled)
              }
              Text {
                id: enableText
                anchors.centerIn: parent
                text: dot.reactionsEnabled ? "On" : "Off"
                color: dot.reactionsEnabled ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          // Live status: which agent is doing what right now.
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Rectangle {
              width: Style.space(10)
              height: Style.space(10)
              radius: width / 2
              color: root.stateColor(dot.agentState)
              Layout.alignment: Qt.AlignVCenter
            }
            Text {
              Layout.fillWidth: true
              text: dot.agentState === "idle" || dot.agentState === ""
                ? "No agent active"
                : ((dot.agentActive !== "" ? dot.agentActive : "agent")
                   + " \u00b7 " + root.stateLabel(dot.agentState))
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }

          // How the Dots share the agent statuses (only with 2+ Dots):
          //  - Merged: every reacting Dot shows the one merged status.
          //  - Latest per Dot: the Dots form a rolling window of the most
          //    recent statuses; a new status overrides the oldest-showing Dot.
          Column {
            visible: dot.deviceCount > 1
            width: parent.width
            spacing: Style.space(3)

            PanelSectionHeader {
              width: parent.width
              text: "MODE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)
              ReactionModeChip { label: "Merged"; modeValue: "merged" }
              ReactionModeChip { label: "Latest per Dot"; modeValue: "rolling" }
            }

            Text {
              width: parent.width
              text: dot.reactionMode === "rolling"
                ? "Each Dot shows one of the latest statuses; a new status "
                  + "replaces the oldest-showing Dot."
                : "Every reacting Dot shows the single merged status."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // React-on target (merged mode only; rolling drives every Dot).
          Flow {
            visible: dot.deviceCount > 1 && dot.reactionMode !== "rolling"
            width: parent.width
            spacing: Style.space(6)

            ReactionTargetChip { label: "Selected Dot"; targetValue: "inherit" }
            ReactionTargetChip { label: "All Dots"; targetValue: "all" }
            Repeater {
              model: dot.devices
              delegate: ReactionTargetChip {
                required property int index
                required property var modelData
                label: "Dot " + (index + 1)
                targetValue: String(modelData.device)
              }
            }
          }

          // One colour-mapping row per state.
          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.reactionStates
              delegate: ReactionRow {
                required property var modelData
                stateId: modelData.state
                title: modelData.title
              }
            }
          }

          // Wire the agents to report their state.
          CursorSurface {
            width: parent.width
            foreground: root.foreground
            implicitHeight: hooksText.implicitHeight + Style.spacing.lg
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: dot.installHooks()
            }
            Text {
              id: hooksText
              anchors.centerIn: parent
              text: dot.hooksBusy ? "Installing\u2026" : "Install agent hooks"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          Text {
            visible: dot.hooksResult !== ""
            width: parent.width - Style.space(16)
            anchors.horizontalCenter: parent.horizontalCenter
            text: dot.hooksResult
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          } // end Agent reactions wrapper

          // --- Custom program (Manual screen only) --------------------
          Column {
          visible: root.screen === "manual"
          width: parent.width
          spacing: Style.space(12)

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            width: parent.width
            text: "CUSTOM PROGRAM"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          TextField {
            id: customField
            width: parent.width
            foreground: root.foreground
            font.family: root.fontFamily
            placeholderText: "#ff00ff 1s pulse   (use \\n for new lines)"
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                customField.text = ""
                panelBody.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.applyCustom()
                event.accepted = true
              }
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            CursorSurface {
              Layout.fillWidth: true
              foreground: root.foreground
              implicitHeight: applyText.implicitHeight + Style.spacing.lg
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.applyCustom()
              }
              Text {
                id: applyText
                anchors.centerIn: parent
                text: "Apply"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            CursorSurface {
              Layout.fillWidth: true
              foreground: root.foreground
              implicitHeight: offText.implicitHeight + Style.spacing.lg
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: dot.turnOff()
              }
              Text {
                id: offText
                anchors.centerIn: parent
                text: "Off"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }
          }
          } // end Custom program wrapper

          // --- Device info --------------------------------------------
          Column {
            visible: dot.mounted
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.foreground }

            // Single Dot: show its details directly.
            Column {
              visible: dot.deviceCount <= 1
              width: parent.width
              spacing: Style.space(4)

              InfoRow { label: "Serial"; value: dot.serial }
              InfoRow { label: "Firmware"; value: dot.firmware }
              InfoRow { label: "State"; value: dot.fwState }
              InfoRow { label: "Mount"; value: dot.device }
            }

            // Multiple Dots: one line per device.
            Repeater {
              model: dot.deviceCount > 1 ? dot.devices : []
              delegate: InfoRow {
                required property int index
                required property var modelData
                label: "Dot " + (index + 1)
                value: (modelData.serial ? String(modelData.serial) : "?")
                  + "  \u00b7  fw " + (modelData.firmware ? String(modelData.firmware) : "?")
              }
            }
          }
        }
      }
    }
  }

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  component PresetButton: CursorSurface {
    id: presetBtn
    property string label: ""
    property string program: ""
    width: parent ? parent.width : implicitWidth
    foreground: root.foreground
    implicitHeight: presetLabel.implicitHeight + Style.spacing.lg

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.currentMode = ""
        dot.apply(presetBtn.program, presetBtn.label)
      }
    }

    Text {
      id: presetLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: presetBtn.label
      color: dot.activeLabel === presetBtn.label ? root.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  // A selectable chip that picks which Dot(s) the controls drive.
  component TargetChip: CursorSurface {
    id: chip
    property string label: ""
    property string subtitle: ""
    property string targetValue: ""
    readonly property bool active: dot.target === chip.targetValue
    foreground: root.foreground
    implicitWidth: chipCol.implicitWidth + Style.space(24)
    implicitHeight: chipCol.implicitHeight + Style.space(12)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(8)
      color: chip.active ? root.alpha(root.accent, 0.18) : "transparent"
      border.width: chip.active ? 2 : 1
      border.color: chip.active ? root.accent : root.alpha(root.foreground, 0.25)
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: dot.selectTarget(chip.targetValue)
    }

    Column {
      id: chipCol
      anchors.centerIn: parent
      spacing: Style.space(1)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: chip.label
        color: chip.active ? root.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: chip.active
      }
      Text {
        visible: chip.subtitle !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        text: chip.subtitle
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // A chip choosing how the Dots share agent statuses (merged / rolling).
  component ReactionModeChip: CursorSurface {
    id: mchip
    property string label: ""
    property string modeValue: ""
    readonly property bool active: dot.reactionMode === mchip.modeValue
    foreground: root.foreground
    implicitWidth: mchipText.implicitWidth + Style.space(20)
    implicitHeight: mchipText.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(8)
      color: mchip.active ? root.alpha(root.accent, 0.18) : "transparent"
      border.width: mchip.active ? 2 : 1
      border.color: mchip.active ? root.accent : root.alpha(root.foreground, 0.25)
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: dot.setReactionMode(mchip.modeValue)
    }
    Text {
      id: mchipText
      anchors.centerIn: parent
      text: mchip.label
      color: mchip.active ? root.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: mchip.active
    }
  }

  // A chip choosing which Dot(s) agent reactions drive.
  component ReactionTargetChip: CursorSurface {
    id: rchip
    property string label: ""
    property string targetValue: ""
    readonly property string current: (dot.reactions && dot.reactions.target)
      ? String(dot.reactions.target) : "inherit"
    readonly property bool active: rchip.current === rchip.targetValue
    foreground: root.foreground
    implicitWidth: rchipText.implicitWidth + Style.space(20)
    implicitHeight: rchipText.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(8)
      color: rchip.active ? root.alpha(root.accent, 0.18) : "transparent"
      border.width: rchip.active ? 2 : 1
      border.color: rchip.active ? root.accent : root.alpha(root.foreground, 0.25)
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: dot.setReactionsTarget(rchip.targetValue)
    }
    Text {
      id: rchipText
      anchors.centerIn: parent
      text: rchip.label
      color: rchip.active ? root.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: rchip.active
    }
  }

  // One agent-state -> colour+animation mapping row: a live marker, a title,
  // a Test button, a colour strip (click = set colour) and an animation strip
  // (click = set pattern), chosen independently.
  component ReactionRow: Column {
    id: rrow
    property string stateId: ""
    property string title: ""
    readonly property var style: dot.reactionStyleFor(rrow.stateId)
    readonly property string curHex: rrow.style.hex
    readonly property string curAnim: rrow.style.anim
    readonly property int curBrightness: rrow.style.brightness
    // Live value while dragging the brightness slider; re-syncs to the stored
    // value whenever it changes (e.g. after a write or state edit).
    property int dragBrightness: rrow.curBrightness
    onCurBrightnessChanged: rrow.dragBrightness = rrow.curBrightness
    readonly property bool isOff: rrow.curHex === ""
    readonly property string program: dot.reactionProgramFor(rrow.stateId)
    readonly property string previewHex: rrow.isOff ? "#101014" : rrow.curHex
    readonly property bool live: dot.agentState === rrow.stateId
    function animLabel(id) {
      for (var i = 0; i < dot.animPresets.length; i++)
        if (dot.animPresets[i].id === id) return dot.animPresets[i].label
      return id
    }
    width: parent ? parent.width : implicitWidth
    spacing: Style.space(4)

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      // Preview / live indicator.
      Rectangle {
        width: Style.space(14)
        height: Style.space(14)
        radius: width / 2
        color: rrow.program === "off" || rrow.program === "" ? "transparent" : rrow.previewHex
        border.width: rrow.live ? 2 : 1
        border.color: rrow.live ? root.accent : root.alpha(root.foreground, 0.3)
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        Layout.fillWidth: true
        text: rrow.title + (rrow.isOff ? "  \u00b7 off" : "  \u00b7 " + rrow.animLabel(rrow.curAnim))
        color: rrow.live ? root.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      // Test button.
      CursorSurface {
        foreground: root.foreground
        implicitWidth: testText.implicitWidth + Style.space(16)
        implicitHeight: testText.implicitHeight + Style.space(6)
        Rectangle {
          anchors.fill: parent
          radius: Style.space(6)
          color: "transparent"
          border.width: 1
          border.color: root.alpha(root.foreground, 0.25)
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: dot.testReaction(rrow.stateId)
        }
        Text {
          id: testText
          anchors.centerIn: parent
          text: "Test"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // Colour strip: click a swatch to set only the colour for this state.
    // An "off" chip blanks the Dots for this state.
    Flow {
      width: parent.width
      spacing: Style.space(5)

      Repeater {
        model: root.palette
        delegate: Rectangle {
          id: rsw
          required property var modelData
          readonly property bool sel: !rrow.isOff
            && rrow.previewHex.toLowerCase() === String(modelData.hex).toLowerCase()
          width: Style.space(22)
          height: Style.space(22)
          radius: width / 2
          color: modelData.hex
          border.width: rsw.sel ? 2 : 1
          border.color: rsw.sel ? root.foreground : root.alpha(root.foreground, 0.25)

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: dot.setReactionColor(rrow.stateId, rsw.modelData.hex)
          }
        }
      }

      // "Off" (dark) chip.
      Rectangle {
        width: Style.space(22)
        height: Style.space(22)
        radius: width / 2
        color: "transparent"
        border.width: rrow.isOff ? 2 : 1
        border.color: rrow.isOff ? root.foreground : root.alpha(root.foreground, 0.3)
        Text {
          anchors.centerIn: parent
          text: "\u2205"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: dot.setReactionOff(rrow.stateId)
        }
      }
    }

    // Animation strip: pick the pattern the colour is rendered with,
    // independent of the colour. Dimmed while the state is off.
    Flow {
      width: parent.width
      spacing: Style.space(5)
      opacity: rrow.isOff ? 0.4 : 1.0

      Repeater {
        model: dot.animPresets
        delegate: CursorSurface {
          id: achip
          required property var modelData
          readonly property bool active: !rrow.isOff && rrow.curAnim === String(modelData.id)
          foreground: root.foreground
          implicitWidth: achipText.implicitWidth + Style.space(16)
          implicitHeight: achipText.implicitHeight + Style.space(7)

          Rectangle {
            anchors.fill: parent
            radius: Style.space(6)
            color: achip.active ? root.alpha(root.accent, 0.18) : "transparent"
            border.width: achip.active ? 2 : 1
            border.color: achip.active ? root.accent : root.alpha(root.foreground, 0.25)
          }
          MouseArea {
            anchors.fill: parent
            enabled: !rrow.isOff
            cursorShape: Qt.PointingHandCursor
            onClicked: dot.setReactionAnim(rrow.stateId, achip.modelData.id)
          }
          Text {
            id: achipText
            anchors.centerIn: parent
            text: achip.modelData.label
            color: achip.active ? root.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: achip.active
          }
        }
      }
    }

    // Brightness strip: set only this state's brightness, independent of the
    // colour and animation. Dimmed while the state is off.
    Item {
      width: parent.width
      implicitHeight: Style.space(20)
      opacity: rrow.isOff ? 0.4 : 1.0

      Text {
        id: rbLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "\u2600"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: Math.round(rrow.dragBrightness / 255 * 100) + "%"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        width: Style.space(34)
        horizontalAlignment: Text.AlignRight
      }

      Rectangle {
        id: rbTrack
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: rbLabel.right
        anchors.leftMargin: Style.space(8)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(40)
        height: Style.space(6)
        radius: height / 2
        color: root.alpha(root.foreground, 0.18)

        Rectangle {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          height: parent.height
          radius: parent.radius
          width: parent.width * (rrow.dragBrightness - 8) / (255 - 8)
          color: root.foreground
        }

        Rectangle {
          width: Style.space(14)
          height: Style.space(14)
          radius: width / 2
          color: root.foreground
          anchors.verticalCenter: parent.verticalCenter
          x: (rbTrack.width - width) * (rrow.dragBrightness - 8) / (255 - 8)
        }

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          enabled: !rrow.isOff
          cursorShape: Qt.PointingHandCursor
          function setFromX(mx) {
            var ratio = root.clamp(mx / rbTrack.width, 0, 1)
            rrow.dragBrightness = Math.round(8 + ratio * (255 - 8))
          }
          onPressed: function(mouse) { setFromX(mouse.x) }
          onPositionChanged: function(mouse) { if (pressed) setFromX(mouse.x) }
          onReleased: dot.setReactionBrightness(rrow.stateId, rrow.dragBrightness)
        }
      }
    }
  }

  // A tab chip that switches the panel between its screens.
  component ScreenChip: CursorSurface {
    id: schip
    property string label: ""
    property string screenValue: ""
    readonly property bool active: root.screen === schip.screenValue
    foreground: root.foreground
    implicitWidth: schipText.implicitWidth + Style.space(24)
    implicitHeight: schipText.implicitHeight + Style.space(12)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(8)
      color: schip.active ? root.alpha(root.accent, 0.18) : "transparent"
      border.width: schip.active ? 2 : 1
      border.color: schip.active ? root.accent : root.alpha(root.foreground, 0.25)
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.screen = schip.screenValue
    }
    Text {
      id: schipText
      anchors.centerIn: parent
      text: schip.label
      color: schip.active ? root.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: schip.active
    }
  }

  component InfoRow: RowLayout {
    property string label: ""
    property string value: ""
    width: parent ? parent.width - Style.space(16) : implicitWidth
    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
    spacing: Style.space(8)

    Text {
      text: label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      Layout.preferredWidth: Style.space(64)
    }

    Text {
      text: value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      Layout.fillWidth: true
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideMiddle
    }
  }
}
