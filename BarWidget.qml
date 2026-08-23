import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// CPU / memory / temperature pill for the bar. Owns the sampling loop (one
// sysprobe process per refresh tick); percentages are computed here from
// jiffie deltas so every mounted instance (one per monitor) keeps its own
// history, and the popup reads everything off this widget through injectPanel.
BarWidget {
  id: root
  moduleName: "kb.system-pulse"

  // ---- Settings (inline shell.json entry) ---------------------------------
  readonly property int intervalSec: Math.max(1, parseInt(setting("interval", 2), 10) || 2)
  readonly property int historyCap: Math.max(20, Math.min(240, parseInt(setting("history", 60), 10) || 60))
  readonly property bool showCpu: Model.truthy(setting("showCpu", true))
  readonly property bool showRam: Model.truthy(setting("showRam", true))
  readonly property bool showTemp: Model.truthy(setting("showTemp", true))
  readonly property string tempUnit: String(setting("tempUnit", "C")).toUpperCase() === "F" ? "F" : "C"
  readonly property real warmAt: Number(setting("warmAt", 70)) || 70
  readonly property real hotAt: Number(setting("hotAt", 88)) || 88
  readonly property string middleAction: String(setting("middleAction", "omarchy-launch-or-focus-tui btop"))
  readonly property bool iconOnly: Model.truthy(setting("iconOnly", false))

  // ---- Sampled state -------------------------------------------------------
  property var lastProbe: null          // latest parsed sysprobe snapshot

  // Percentages are computed once per tick (deltas need the previous sample,
  // so they cannot be pure bindings over lastProbe).
  property real cpuPctValue: -1
  property var corePcts: []
  readonly property int tick: tickCounter.value

  // Integer bump that re-evaluates canvas bindings in the popup without
  // reassigning whole arrays every two seconds.
  QtObject {
    id: tickCounter
    property int value: 0
  }

  property var cpuHist: []
  property var memHist: []
  property var tempHist: []

  readonly property var primaryTemp: lastProbe ? Model.pickPrimaryTemp(lastProbe.temps) : null

  readonly property real usedKb: lastProbe ? Model.usedMemKb(lastProbe) : 0
  readonly property real totalKb: lastProbe ? lastProbe.memTotalKb : 0
  readonly property real memPctValue: lastProbe ? Model.memPct(lastProbe) : -1
  readonly property real swapPctValue: lastProbe ? Model.swapPct(lastProbe) : -1

  // Anything red-worthy anywhere → the pill lights up in the theme's urgent
  // color instead of staying monochrome.
  readonly property bool alert: {
    if (!lastProbe) return false
    if (primaryTemp && Model.tempState(primaryTemp.milliC, root.warmAt, root.hotAt) === 2) return true
    if (root.cpuPctValue >= 98) return true
    if (root.memPctValue >= 97) return true
    return false
  }

  // ---- Bar label ------------------------------------------------------------
  readonly property string glyph: ""

  function tempText() {
    if (!primaryTemp) return ""
    return Model.fmtTemp(primaryTemp.milliC, root.tempUnit)
  }

  readonly property var labelParts: {
    var parts = []
    if (root.cpuPctValue >= 0 && root.showCpu) parts.push(Math.round(root.cpuPctValue) + "%")
    if (root.totalKb > 0 && root.showRam) parts.push(Model.fmtGb(root.usedKb) + "G")
    if (primaryTemp && root.showTemp) parts.push(tempText())
    return parts
  }

  readonly property string labelText: root.labelParts.join(" ")

  readonly property string tooltipText: {
    if (!lastProbe) return "System pulse \u00b7 waiting for first sample"
    var t = primaryTemp ? " \u00b7 " + (primaryTemp.label || primaryTemp.chip).toUpperCase() + " " + tempText() : ""
    return "CPU " + Math.round(Math.max(0, root.cpuPctValue)) + "%"
      + " \u00b7 MEM " + Model.fmtGb(root.usedKb) + " / " + Model.fmtGb(root.totalKb) + "G"
      + t
      + " \u00b7 LOAD " + lastProbe.load1.toFixed(2)
  }

  // Vertical bars draw stacked OpticalGlyph lines, one per metric, mirroring
  // omarchy.clock's vertical stack shape.
  readonly property var verticalLines: {
    if (!root.vertical) return []
    var lines = [root.glyph]
    for (var i = 0; i < root.labelParts.length; i++) lines.push(root.labelParts[i])
    return lines
  }

  function persistSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleIconOnly() { root.persistSetting("iconOnly", !root.iconOnly) }

  // ---- Sampling --------------------------------------------------------------
  function probe() {
    if (!probeProc.running) probeProc.running = true
  }

  function refresh() {
    root.probe()
    root.broadcast("refresh")
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  onIntervalSecChanged: probeTimer.restart()

  Timer {
    id: probeTimer
    interval: root.intervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.probe()
  }

  Process {
    id: probeProc
    command: ["bash", Qt.resolvedUrl("scripts/sysprobe").toString().replace(/^file:\/\//, "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var snap = Model.parseProbe(text)
        if (!snap) return   // keep last-good data visible on a bad read

        // Deltas need the previous sample; the first tick only primes them.
        var cpuVal = -1
        if (root.lastProbe) {
          var pct = Model.cpuBusyPct(snap.cpu, root.lastProbe.cpu)
          cpuVal = pct === null ? root.cpuPctValue : pct
        }
        var coresVal = root.lastProbe ? Model.coreBusyPcts(snap.cores, root.lastProbe.cores) : []

        root.lastProbe = snap
        root.cpuPctValue = cpuVal
        if (coresVal.length > 0 || root.corePcts.length === 0) root.corePcts = coresVal

        var tempSensor = Model.pickPrimaryTemp(snap.temps)
        root.cpuHist = Model.pushSample(root.cpuHist, Math.round(Math.max(0, cpuVal)), root.historyCap)
        root.memHist = Model.pushSample(root.memHist, Math.round(Model.memPct(snap)), root.historyCap)
        root.tempHist = Model.pushSample(root.tempHist,
          tempSensor ? Math.round(tempSensor.milliC / 1000) : 0, root.historyCap)

        tickCounter.value++
      }
    }
  }

  // ---- Popup plumbing (same shape contract as omarchy.clock/weather) -------
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "kb.system-pulse"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refresh() }
    function status(): void {
      console.log("kb.system-pulse: cpu=" + Math.round(root.cpuPctValue) + "%"
        + " mem=" + Model.fmtGb(root.usedKb) + "/" + Model.fmtGb(root.totalKb) + "G"
        + " temp=" + (root.primaryTemp ? Model.fmtTemp(root.primaryTemp.milliC, root.tempUnit) : "n/a")
        + " opened=" + root.opened)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.alert
    text: root.vertical ? "" : (root.iconOnly ? root.glyph : root.glyph + " " + root.labelText)
    labelVisible: !root.vertical && !root.iconOnly
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.5
    tooltipText: root.tooltipText

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleIconOnly()
      else if (b === Qt.MiddleButton) { if (root.bar && root.middleAction !== "") root.bar.run(root.middleAction) }
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3 ? button.fontSize * 0.9 : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
