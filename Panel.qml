import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Popup review for kb.system-pulse. Reads every number off its host BarWidget
// (injected by injectPanel) so the popup never samples anything itself — it
// only renders what the pill already collected. Typography and hairlines do
// the work: no cards, no chrome, theme palette only.
Panel {
  id: root
  moduleName: "kb.system-pulse"
  ipcTarget: "kb.system-pulse"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false
  property var hostWidget: null
  readonly property var host: hostWidget
  readonly property var barIdentity: hostWidget || root

  // Palette shortcuts. Monochrome by design; Color.urgent is the only hue
  // allowed to appear, and only when something actually needs attention.
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color muted: Qt.darker(root.fg, 1.5)
  readonly property color dimmer: Qt.darker(root.fg, 1.8)
  readonly property color hot: Color.urgent

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    if (root.host) root.host.probe()
    Qt.callLater(cpuGraph.requestPaint)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    if (root.host) root.host.probe()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    if (root.host) root.host.probe()
    cpuGraph.requestPaint()
  }

  // ---- Derived read-outs ----------------------------------------------------
  readonly property bool ready: !!root.host && !!root.host.lastProbe
  // Null-safe snapshot handle: bindings may evaluate before the first sample
  // or before injectPanel runs; Model helpers tolerate null.
  readonly property var probe: root.ready ? root.host.lastProbe : null
  readonly property var corePcts: (root.host && root.host.corePcts) ? root.host.corePcts : []
  readonly property int sensorRowsShown: Math.max(1, parseInt(setting("sensorRows", 6), 10) || 6)
  readonly property real warmAt: root.host ? root.host.warmAt : 70
  readonly property real hotAt: root.host ? root.host.hotAt : 88

  readonly property var primaryTemp: root.ready ? root.host.primaryTemp : null
  readonly property var sensorList: {
    if (!root.ready) return []
    return Model.sortTempsHottestFirst(root.host.lastProbe.temps)
  }
  readonly property var shownSensors: sensorList.slice(0, sensorRowsShown)
  readonly property int hiddenSensors: sensorList.length - shownSensors.length

  Component.onCompleted: cpuGraph.requestPaint()

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(pulseColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onReturnRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: pulseColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: pulseColumn
          width: parent.width
          spacing: Style.space(14)

          Text {
            visible: !root.ready
            text: "Waiting for first sample…"
            color: root.muted
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- Header ------------------------------------------------------
          Item {
            visible: root.ready
            width: parent.width
            height: headerText.implicitHeight

            Text {
              id: headerText
              anchors.left: parent.left
              text: "SYSTEM"
              color: root.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 2
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: headerText.verticalCenter
              text: root.ready ? "UP " + Model.fmtUptime(root.host.lastProbe.uptimeSec) : ""
              color: root.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
          }

          // ---- Hero triptych: CPU / MEMORY / TEMPERATURE -------------------
          Item {
            visible: root.ready
            width: parent.width
            height: heroCol.implicitHeight

            Column {
              id: heroCol
              width: parent.width
              spacing: Style.space(4)

              Row {
                width: parent.width

                // CPU
                Column {
                  width: parent.width / 3
                  spacing: Style.space(4)

                  Text {
                    text: "CPU"
                    color: root.muted
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 2
                  }
                  Text {
                    text: root.host && root.host.cpuPctValue >= 0
                          ? Math.round(root.host.cpuPctValue) + "%" : "—"
                    color: root.fg
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.displayLarge
                    font.bold: true
                  }
                }

                // MEMORY
                Column {
                  width: parent.width / 3
                  spacing: Style.space(4)

                  Text {
                    text: "MEMORY"
                    color: root.muted
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 2
                  }
                  Row {
                    spacing: Style.space(2)

                    Text {
                      id: memValueText
                      text: Model.fmtGb(Model.usedMemKb(root.probe))
                      color: root.fg
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.displayLarge
                      font.bold: true
                    }
                    Text {
                      anchors.baseline: memValueText.baseline
                      text: "G"
                      color: root.muted
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }
                }

                // TEMPERATURE
                Column {
                  width: parent.width / 3
                  spacing: Style.space(4)

                  Text {
                    text: root.primaryTemp ? (root.primaryTemp.label || root.primaryTemp.chip).toUpperCase().slice(0, 10) : "TEMP"
                    color: root.muted
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 2
                  }
                  Row {
                    spacing: Style.space(2)

                    Text {
                      id: tempValueText
                      text: root.primaryTemp ? Model.fmtTemp(root.primaryTemp.milliC, root.host.tempUnit) : "—"
                      color: root.primaryTemp && Model.tempState(root.primaryTemp.milliC, root.warmAt, root.hotAt) === 2 ? root.hot : root.fg
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.displayLarge
                      font.bold: true
                    }
                    Text {
                      anchors.baseline: tempValueText.baseline
                      text: root.host && root.host.tempUnit === "F" ? "F" : "C"
                      color: root.muted
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }
                }
              }
            }
          }

          // ---- Divider -------------------------------------------------------
          Rectangle {
            visible: root.ready
            width: parent.width
            height: Style.spacing.hairline
            color: root.fg
            opacity: 0.12
          }

          // ---- CPU block: sparkline over recent history + per-core strip ----
          Item {
            visible: root.ready
            width: parent.width
            height: cpuBlock.implicitHeight

            Column {
              id: cpuBlock
              width: parent.width
              spacing: Style.space(10)

              Item {
                width: parent.width
                height: cpuCaption.implicitHeight

                Text {
                  id: cpuCaption
                  anchors.left: parent.left
                  text: "CPU \u00b7 LAST " + (root.host ? root.host.historyCap : 60) + " SAMPLES"
                  color: root.muted
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 2
                }

                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: cpuCaption.verticalCenter
                  text: root.corePcts.length + " CORES"
                  color: root.muted
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }

              Canvas {
                id: cpuGraph
                width: parent.width
                height: Style.space(54)
                antialiasing: true

                Connections {
                  target: root.host
                  ignoreUnknownSignals: true
                  function onTickChanged() { cpuGraph.requestPaint() }
                }

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()

                  var w = width
                  var h = height
                  var line = Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.9)
                  var under = Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
                  var grid = Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)

                  // Baseline + 50% guide: structure without a frame.
                  ctx.strokeStyle = grid
                  ctx.lineWidth = 1
                  ctx.beginPath()
                  ctx.moveTo(0, h - 0.5)
                  ctx.lineTo(w, h - 0.5)
                  ctx.moveTo(0, h / 2 + 0.5)
                  ctx.lineTo(w, h / 2 + 0.5)
                  ctx.stroke()

                  var hist = root.host ? root.host.cpuHist : []
                  if (!hist || hist.length < 2) return

                  var step = w / (hist.length - 1)
                  ctx.beginPath()
                  ctx.moveTo(0, h - (hist[0] / 100) * (h - 2) - 1)
                  for (var i = 1; i < hist.length; i++)
                    ctx.lineTo(i * step, h - (hist[i] / 100) * (h - 2) - 1)

                  ctx.strokeStyle = line
                  ctx.lineWidth = 1.25
                  ctx.stroke()

                  // Faint wash under the curve keeps the eye on the trend.
                  ctx.lineTo(w, h)
                  ctx.lineTo(0, h)
                  ctx.closePath()
                  ctx.fillStyle = under
                  ctx.fill()
                }
              }

              // Per-core load strip: one thin vertical bar per core.
              Row {
                spacing: Style.space(3)

                Repeater {
                  model: root.corePcts.length

                  Item {
                    required property int index
                    width: Style.space(4)
                    height: Style.space(36)

                    Rectangle {
                      anchors.bottom: parent.bottom
                      width: parent.width
                      height: Math.max(Style.space(1), (root.corePcts[index] / 100) * parent.height)
                      color: root.corePcts[index] >= 95 ? root.hot : root.fg
                      opacity: 0.85

                      Behavior on height {
                        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                      }
                    }
                  }
                }
              }
            }
          }

          // ---- Divider -------------------------------------------------------
          Rectangle {
            visible: root.ready
            width: parent.width
            height: Style.spacing.hairline
            color: root.fg
            opacity: 0.12
          }

          // ---- Memory block: thin usage track + optional swap -----------------
          Column {
            visible: root.ready
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              height: memCaption.implicitHeight

              Text {
                id: memCaption
                anchors.left: parent.left
                text: "MEMORY"
                color: root.muted
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 2
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: memCaption.verticalCenter
                text: Model.fmtGb(Model.usedMemKb(root.probe)) + " / "
                    + Model.fmtGb(root.probe ? root.probe.memTotalKb : 0) + " GiB"
                color: root.muted
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(3)
              radius: Math.min(1.5, Style.cornerRadius)
              color: Style.normalFillFor(root.fg)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Math.max(parent.height, (Model.memPct(root.probe) / 100) * parent.width)
                  radius: parent.radius
                  color: root.fg
                  opacity: 0.9

                  Behavior on width {
                    NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
                  }
                }
              }

              // Swap only earns a row when the machine actually has some.
              Row {
                visible: root.probe && root.probe.swapTotalKb > 0
                width: parent.width
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "SWAP"
                  color: root.dimmer
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 2
                }

                Rectangle {
                  width: parent.width - swapLabelWidth.implicitWidth - parent.spacing * 2
                  height: Style.space(2)
                  anchors.verticalCenter: parent.verticalCenter
                  radius: 1
                  color: Style.normalFillFor(root.fg)

                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Math.max(parent.height, (Model.swapPct(root.probe) / 100) * parent.width)
                    radius: parent.radius
                    color: root.fg
                    opacity: 0.55

                    Behavior on width {
                      NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
                    }
                  }
                }

                Text {
                  id: swapLabelWidth
                  anchors.verticalCenter: parent.verticalCenter
                  text: Math.round(Model.swapPct(root.probe)) + "%"
                  color: root.dimmer
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
          }

          // ---- Divider -------------------------------------------------------
          Rectangle {
            visible: root.ready
            width: parent.width
            height: Style.spacing.hairline
            color: root.fg
            opacity: 0.12
          }

          // ---- Sensors: hottest first, severity dot, one row each -------------
          Column {
            visible: root.ready && root.shownSensors.length > 0
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "SENSORS"
              color: root.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 2
            }

            Repeater {
              model: root.shownSensors

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                readonly property int severity: Model.sensorSeverity(modelData, root.warmAt, root.hotAt)

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(4)
                  height: width
                  radius: width / 2
                  color: severity === 2 ? root.hot : (severity === 1 ? root.fg : root.dimmer)
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - parent.spacing * 3 - sensorValue.implicitWidth
                  text: ((modelData.chip || "") + (modelData.label ? " " + modelData.label : "")).trim()
                  elide: Text.ElideRight
                  color: root.muted
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  id: sensorValue
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.fmtTemp(modelData.milliC, root.host.tempUnit)
                        + (modelData.crit > 0
                           ? "  /  " + Model.fmtTemp(modelData.crit, root.host.tempUnit)
                           : "")
                  color: severity === 2 ? root.hot : (severity === 1 ? root.fg : root.dimmer)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Text {
              visible: root.hiddenSensors > 0
              text: "+" + root.hiddenSensors + " more"
              color: root.dimmer
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.italic: true
            }
          }

          // ---- Footer meta ------------------------------------------------------
          Item {
            visible: root.ready
            width: parent.width
            height: loadText.implicitHeight

            Text {
              id: loadText
              anchors.left: parent.left
              text: root.ready
                    ? "LOAD " + root.host.lastProbe.load1.toFixed(2) + " "
                      + root.host.lastProbe.load5.toFixed(2) + " "
                      + root.host.lastProbe.load15.toFixed(2)
                    : ""
              color: root.dimmer
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: loadText.verticalCenter
              text: root.ready && root.host.lastProbe.freqMhz > 0
                    ? Model.fmtFreq(root.host.lastProbe.freqMhz)
                    : ""
              color: root.dimmer
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
          }
        }
      }
    }
  }
}
