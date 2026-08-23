// Pure helpers for kb.system-pulse. Everything here is side-effect free so
// it can be unit-reasoned in isolation: parsing the sysprobe JSON, computing
// busy percentages from jiffie deltas, formatting, and picking the primary
// temperature sensor.

function clamp(n, lo, hi) {
  if (!isFinite(n)) return lo
  return Math.max(lo, Math.min(hi, n))
}

// Settings may arrive as real booleans or strings ("true"/"1"/"on").
function truthy(value) {
  if (value === true) return true
  if (typeof value !== "string") return false
  var s = value.replace(/^\s+|\s+$/g, "").toLowerCase()
  return s === "true" || s === "1" || s === "yes" || s === "on"
}

// Parse one line of sysprobe output into a normalized snapshot. Returns null
// when nothing usable came back so callers can keep last-good state visible.
function parseProbe(raw) {
  var text = String(raw || "").trim()
  if (!text) return null
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!data || typeof data !== "object") return null

  function numArr(v) {
    if (!Array.isArray(v)) return []
    var out = []
    for (var i = 0; i < v.length; i++) out.push(isFinite(Number(v[i])) ? Number(v[i]) : 0)
    return out
  }

  var mem = data.mem || {}
  var load = numArr(data.load)
  var rawTemps = Array.isArray(data.temps) ? data.temps : []
  var temps = []
  for (var t = 0; t < rawTemps.length; t++) {
    var s = rawTemps[t] || {}
    var milliC = Number(s.milliC)
    if (!isFinite(milliC)) continue
    // Drop obviously broken readings (-20 °C .. 150 °C is the sane band).
    if (milliC < -20000 || milliC > 150000) continue
    temps.push({
      chip: String(s.chip || ""),
      label: String(s.label || ""),
      milliC: milliC,
      high: isFinite(Number(s.high)) ? Number(s.high) : 0,
      crit: isFinite(Number(s.crit)) ? Number(s.crit) : 0
    })
  }

  var coresRaw = Array.isArray(data.cores) ? data.cores : []
  var cores = []
  for (var c = 0; c < coresRaw.length; c++) cores.push(numArr(coresRaw[c]))

  return {
    cpu: numArr(data.cpu),
    cores: cores,
    memTotalKb: Math.max(0, Number(mem.total) || 0),
    memAvailKb: Math.max(0, Number(mem.avail) || 0),
    swapTotalKb: Math.max(0, Number(mem.swapTotal) || 0),
    swapFreeKb: Math.max(0, Number(mem.swapFree) || 0),
    load1: load.length > 0 ? load[0] : 0,
    load5: load.length > 1 ? load[1] : 0,
    load15: load.length > 2 ? load[2] : 0,
    uptimeSec: Math.max(0, Number(data.uptimeSec) || 0),
    freqMhz: Math.max(0, Number(data.freqMhz) || 0),
    temps: temps
  }
}

// /proc/stat layout: user nice system idle iowait irq softirq steal ...
// "Busy" excludes idle + iowait; "total" is every field.
function jiffiesTotal(arr) {
  var sum = 0
  for (var i = 0; i < arr.length; i++) sum += arr[i]
  return sum
}

function jiffiesIdle(arr) {
  return (arr.length > 3 ? arr[3] : 0) + (arr.length > 4 ? arr[4] : 0)
}

// Busy percentage between two samples. Null until two samples exist or when
// the counter did not advance (e.g. a suspended core).
function cpuBusyPct(cur, prev) {
  if (!prev || !cur || !cur.length) return null
  var dTotal = jiffiesTotal(cur) - jiffiesTotal(prev)
  var dIdle = jiffiesIdle(cur) - jiffiesIdle(prev)
  if (dTotal <= 0) return null
  return clamp(((dTotal - dIdle) / dTotal) * 100, 0, 100)
}

function coreBusyPcts(curCores, prevCores) {
  var out = []
  if (!prevCores) return out
  for (var i = 0; i < curCores.length && i < prevCores.length; i++) {
    var pct = cpuBusyPct(curCores[i], prevCores[i])
    out.push(pct === null ? 0 : pct)
  }
  return out
}

function usedMemKb(snapshot) {
  if (!snapshot) return 0
  return Math.max(0, snapshot.memTotalKb - snapshot.memAvailKb)
}

function memPct(snapshot) {
  if (!snapshot || snapshot.memTotalKb <= 0) return 0
  return clamp((usedMemKb(snapshot) / snapshot.memTotalKb) * 100, 0, 100)
}

function swapPct(snapshot) {
  if (!snapshot || snapshot.swapTotalKb <= 0) return 0
  return clamp(((snapshot.swapTotalKb - snapshot.swapFreeKb) / snapshot.swapTotalKb) * 100, 0, 100)
}

function kbToGb(kb) {
  if (!isFinite(kb)) return 0
  return kb / 1048576
}

// 9388608 -> "9.0"
function fmtGb(kb) {
  return kbToGb(kb).toFixed(1)
}

function cToF(celsius) {
  return celsius * 9 / 5 + 32
}

function tempCelsius(milliC) {
  return milliC / 1000
}

// 65875 + "C" -> "66°" ; unit "F" converts first.
function fmtTemp(milliC, unit) {
  var c = tempCelsius(milliC)
  var v = unit === "F" ? cToF(c) : c
  return Math.round(v) + "°"
}

// 0 = ok, 1 = warm, 2 = hot. Thresholds are always given in °C regardless of
// the display unit; hotAt wins over warmAt.
function tempState(milliC, warmAt, hotAt) {
  var c = tempCelsius(milliC)
  if (c >= hotAt) return 2
  if (c >= warmAt) return 1
  return 0
}

// Pick the hero sensor: prefer CPU-package sensors by label/chip name, then
// fall back to whatever reads hottest. Returns { index, ... } or null.
function pickPrimaryTemp(temps) {
  var best = -1
  var bestScore = -Infinity
  for (var i = 0; i < temps.length; i++) {
    var s = temps[i]
    var hay = (s.chip + " " + s.label).toLowerCase()
    var score = tempCelsius(s.milliC) / 100 // mild tie-break toward hottest
    if (/tctl|tdie|package id 0|package id 1|t die|cpu/.test(hay)) score += 50
    if (/k10temp|zenpower|coretemp|cpu_thermal|x86_pkg_temp/.test(hay)) score += 30
    if (/acpitz|iwlwifi/.test(hay)) score -= 20
    if (score > bestScore) {
      bestScore = score
      best = i
    }
  }
  return best >= 0 ? temps[best] : null
}

function sortTempsHottestFirst(temps) {
  return temps.slice().sort(function(a, b) { return b.milliC - a.milliC })
}

function hasCrit(sensor) {
  return sensor && sensor.crit > 0
}

// Sensor row color weight: 0 muted, 1 foreground (at/over its high), 2 urgent.
function sensorSeverity(sensor, warmAt, hotAt) {
  var st = tempState(sensor.milliC, warmAt, hotAt)
  if (st === 2) return 2
  if (hasCrit(sensor) && sensor.milliC >= sensor.crit * 0.95) return 2
  if (st === 1) return 1
  if (hasCrit(sensor) && sensor.high > 0 && sensor.milliC >= sensor.high) return 1
  return 0
}

// 23400 -> "6H 30M" ; 187200 -> "2D 4H"
function fmtUptime(seconds) {
  var d = Math.floor(seconds / 86400)
  var h = Math.floor((seconds % 86400) / 3600)
  var m = Math.floor((seconds % 3600) / 60)
  if (d > 0) return d + "D " + h + "H"
  if (h > 0) return h + "H " + m + "M"
  return m + "M"
}

// 2935 -> "2.94 GHz"; 850 -> "850 MHz"
function fmtFreq(mhz) {
  if (mhz >= 1000) return (mhz / 1000).toFixed(2) + " GHz"
  return Math.round(mhz) + " MHz"
}

function pushSample(hist, value, cap) {
  var next = hist.slice()
  next.push(value)
  return next.length > cap ? next.slice(next.length - cap) : next
}

if (typeof module !== "undefined") {
  module.exports = {
    clamp: clamp,
    truthy: truthy,
    parseProbe: parseProbe,
    cpuBusyPct: cpuBusyPct,
    coreBusyPcts: coreBusyPcts,
    usedMemKb: usedMemKb,
    memPct: memPct,
    swapPct: swapPct,
    fmtGb: fmtGb,
    fmtTemp: fmtTemp,
    tempState: tempState,
    pickPrimaryTemp: pickPrimaryTemp,
    sortTempsHottestFirst: sortTempsHottestFirst,
    sensorSeverity: sensorSeverity,
    fmtUptime: fmtUptime,
    fmtFreq: fmtFreq,
    pushSample: pushSample
  }
}
