import QtQuick
import Quickshell
import Quickshell.Io

// Data + control layer for the SidePulse Dot widget. Everything that touches
// the device goes through bin/sidepulse-dot, which prints one JSON object.
// This file only schedules that helper, parses stdout, and builds the LED
// program strings the panel asks for.
Item {
  id: root
  visible: false

  property var settings: ({})

  // Live device state, refreshed by the poll timer and after every write.
  // devices is the full list of mounted Dots; the first-device fields below
  // (device/firmware/serial/fwState) mirror devices[0] for backward-compat.
  property var devices: []
  property bool mounted: false
  property string device: ""
  property string firmware: ""
  property string serial: ""
  property string fwState: ""
  property bool busy: false
  property string lastError: ""

  // Which Dot(s) the panel is currently driving. "all" targets every mounted
  // Dot; otherwise this is a device mount path (a stable per-Dot handle).
  property string target: "all"

  readonly property int deviceCount: devices ? devices.length : 0

  // Resolve target to the actual device paths to write to.
  function targetPaths() {
    var paths = []
    if (!devices) return paths
    if (target === "all") {
      for (var i = 0; i < devices.length; i++) paths.push(String(devices[i].device))
      return paths
    }
    for (var j = 0; j < devices.length; j++) {
      if (String(devices[j].device) === target) { paths.push(target); break }
    }
    return paths
  }

  // Human label for a device path ("Dot 1", "Dot 2", ...) by list order.
  function labelFor(path) {
    if (!devices) return ""
    for (var i = 0; i < devices.length; i++)
      if (String(devices[i].device) === String(path)) return "Dot " + (i + 1)
    return ""
  }

  // Ensure target still points at something real after a replug/remount.
  function normalizeTarget() {
    if (target === "all") return
    var paths = targetPaths()
    if (paths.length === 0) target = "all"
  }

  // What is currently showing, so the panel can highlight the active preset.
  property string activeProgram: ""
  property string activeLabel: ""

  // --- Coding-agent reactions --------------------------------------------
  // Merged "effective" state across the coding agents (agy/grok/junie/
  // opencode/...) plus the full per-agent list, refreshed by agentTimer.
  property string agentState: "idle"
  property string agentActive: ""
  property var agentList: []
  // The persisted reactions config: { enabled, target, programs{state->prog} }.
  property var reactions: ({})
  // Guards so we only (re)write the Dots when something actually changed.
  property string lastReactionState: ""
  property string lastReactionProgram: ""

  readonly property string agentHelper: pluginDir + "/bin/sidepulse-agent"

  readonly property bool reactionsEnabled: reactions && reactions.enabled === true

  // How reactions drive the Dots:
  //   "merged"  - every reacting Dot shows one merged effective state (default).
  //   "rolling" - the Dots form a rolling window of the most recent statuses;
  //               each new status (from any agent) overrides the Dot that has
  //               been showing the oldest status, so the Dots always display
  //               the latest N statuses without pinning an agent to a Dot.
  readonly property string reactionMode: (reactions && reactions.mode)
    ? String(reactions.mode) : "merged"

  // Rolling-mode runtime state (not persisted). agentLastState remembers each
  // agent's last-seen state so we can detect a change; dotSlots[i] is what
  // device index i is currently showing ({ state, seq }); slotSeq is a
  // monotonically increasing recency counter (higher = more recently updated).
  property var agentLastState: ({})
  property var dotSlots: []
  property int slotSeq: 0
  // Pending rolling writes, drained one at a time so several simultaneous
  // status changes each reach their Dot despite the single writer.
  property var pendingRolling: []

  function reactionProgramFor(state) {
    if (!reactions || !reactions.programs) return ""
    var p = reactions.programs[state]
    return p === undefined || p === null ? "" : String(p)
  }

  // The program a Dot with no live agent status should show. This follows the
  // configurable "idle" mapping and falls back to plain "off" when idle is
  // unset, so a Dot never lingers on a stale/leftover program.
  function idleProgram() {
    var p = reactionProgramFor("idle")
    return p === "" ? "off" : p
  }

  // The animation styles a state's colour can be rendered with, in display
  // order. Each is colour-parameterised, so the colour and the animation are
  // chosen independently in the panel.
  readonly property var animPresets: [
    { id: "solid",     label: "Solid" },
    { id: "pulse",     label: "Breathe" },
    { id: "blink",     label: "Blink" },
    { id: "fastblink", label: "Fast" },
    { id: "heartbeat", label: "Heartbeat" }
  ]

  // Build the LED program for a colour rendered with an animation. An empty
  // colour means "off" (dark), regardless of the animation.
  function buildAnimProgram(hex, anim, brightness) {
    var b = clampBrightness(brightness)
    var pre = (b < 255 ? "brightness " + b + "\n" : "")
    if (!hex || hex === "") return "off"
    switch (String(anim)) {
      case "pulse":     return pre + "off\n" + hex + " 1.6s pulse\nrepeat"
      case "blink":     return pre + hex + " 400ms none\noff 400ms none\nrepeat"
      case "fastblink": return pre + hex + " 150ms none\noff 150ms none\nrepeat"
      case "heartbeat": return pre + hex + " 220ms pulse\noff 120ms none\n"
                              + hex + " 220ms pulse\noff 700ms none\nrepeat"
      default:          return pre + hex
    }
  }

  // Infer a { hex, anim, brightness } style from a raw program string (for
  // configs saved before colour/animation/brightness were stored separately).
  function inferStyle(prog) {
    var p = String(prog || "")
    if (p === "" || p === "off") return { hex: "", anim: "solid", brightness: 255 }
    var m = p.match(/#([0-9a-fA-F]{6})/)
    var hex = m ? ("#" + m[1]) : ""
    var bm = p.match(/brightness\s+(\d+)/)
    var brightness = bm ? clampBrightness(parseInt(bm[1], 10)) : 255
    var anim = "solid"
    if (/pulse/.test(p) && /off/.test(p) && /repeat/.test(p) && !/220ms/.test(p)) anim = "pulse"
    else if (/220ms pulse/.test(p)) anim = "heartbeat"
    else if (/1\d\dms none/.test(p) || /150ms/.test(p) || /200ms/.test(p)) anim = "fastblink"
    else if (/none/.test(p) && /repeat/.test(p)) anim = "blink"
    return { hex: hex, anim: anim, brightness: brightness }
  }

  // The stored (or inferred) { hex, anim, brightness } style for one state.
  function reactionStyleFor(state) {
    if (reactions && reactions.styles && reactions.styles[state]) {
      var s = reactions.styles[state]
      var b = (s.brightness === undefined || s.brightness === null)
        ? 255 : clampBrightness(s.brightness)
      return { hex: String(s.hex || ""), anim: String(s.anim || "solid"), brightness: b }
    }
    return inferStyle(reactionProgramFor(state))
  }

  // Which Dot(s) an agent reaction drives: follow the panel selection
  // ("inherit"), every Dot ("all"), or one pinned device path.
  function reactionTargetPaths() {
    var t = reactions && reactions.target ? String(reactions.target) : "inherit"
    if (t === "inherit") return targetPaths()
    if (t === "all") {
      var all = []
      if (devices) for (var i = 0; i < devices.length; i++) all.push(String(devices[i].device))
      return all
    }
    // Specific device path: only if it is still mounted.
    if (devices) for (var j = 0; j < devices.length; j++)
      if (String(devices[j].device) === t) return [t]
    return []
  }

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    return url.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property string helper: pluginDir + "/bin/sidepulse-dot"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  readonly property int pollIntervalSec: intSetting("pollIntervalSec", 5, 2, 60)

  function parseJson(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed && typeof parsed === "object") return parsed
    } catch (e) {
    }
    return null
  }

  function refresh() {
    if (statusProc.running) return
    statusProc.running = true
  }

  // Select which Dot(s) to drive: "all" or a device mount path (persisted so
  // the choice survives a plugin reload/restart).
  function selectTarget(t) { target = String(t); saveUiKeys({ target: String(t) }) }

  // Notify the panel to restore its manual color/animation/brightness after
  // the persisted config has loaded.
  signal uiRestored(string hex, string mode, int brightness)

  // Merge a subset of manual-control UI state into the reactions config so the
  // panel comes back exactly as the user left it after a reload/restart.
  function saveUiKeys(obj) {
    var r = reactions ? JSON.parse(JSON.stringify(reactions)) : {}
    if (!r.ui) r.ui = {}
    for (var k in obj) r.ui[k] = obj[k]
    reactions = r
    saveReactions()
  }

  // Persist the manual color + animation + brightness selection.
  function saveManual(hex, mode, brightness) {
    saveUiKeys({ hex: String(hex || ""), mode: String(mode || ""),
                 brightness: clampBrightness(brightness) })
  }

  // Restore the persisted manual-control UI state once the config has loaded.
  function restoreUi() {
    if (!reactions || !reactions.ui) return
    var u = reactions.ui
    if (u.target !== undefined && u.target !== null) target = String(u.target)
    var hex = (u.hex === undefined || u.hex === null) ? "" : String(u.hex)
    var mode = (u.mode === undefined || u.mode === null) ? "" : String(u.mode)
    var b = (u.brightness === undefined || u.brightness === null)
      ? 255 : clampBrightness(u.brightness)
    uiRestored(hex, mode, b)
  }

  // Apply an arbitrary LED-DSL program. label is only for UI highlighting.
  function apply(program, label) {
    var text = String(program || "")
    if (text.trim() === "") return
    if (writeProc.running) return
    lastError = ""
    busy = true
    activeProgram = text
    activeLabel = String(label || "")
    var cmd = [helper, "write", text]
    var paths = targetPaths()
    for (var i = 0; i < paths.length; i++) { cmd.push("--device"); cmd.push(paths[i]) }
    // If nothing matched (e.g. list not yet loaded) fall back to all devices.
    writeProc.command = cmd
    writeProc.running = true
  }

  function turnOff() { apply("off", "Off") }

  // Write a program to an explicit set of device paths (used by reactions,
  // whose target can differ from the panel's manual selection).
  function applyProgramTo(program, label, paths) {
    var text = String(program || "")
    if (text.trim() === "") return
    if (writeProc.running) return
    lastError = ""
    busy = true
    activeProgram = text
    activeLabel = String(label || "")
    var cmd = [helper, "write", text]
    for (var i = 0; i < paths.length; i++) { cmd.push("--device"); cmd.push(paths[i]) }
    writeProc.command = cmd
    writeProc.running = true
  }

  // Re-drive the Dots for the current agent state if reactions are enabled.
  // force re-applies even when the state has not changed (config edits, toggle).
  // In rolling mode the Dots are driven per status event, not by the merged
  // state, so this merged path is a no-op there.
  function applyReaction(force) {
    if (reactionMode === "rolling") return
    if (!reactionsEnabled || !mounted) return
    var prog = reactionProgramFor(agentState)
    if (prog === "") { lastReactionState = agentState; return }
    var paths = reactionTargetPaths()
    if (paths.length === 0) return
    if (!force && agentState === lastReactionState && prog === lastReactionProgram) return
    lastReactionState = agentState
    lastReactionProgram = prog
    applyProgramTo(prog, "Agent: " + agentState, paths)
  }

  // ---- rolling mode -----------------------------------------------------
  // Clear the rolling window (on mode switch / enable) so it re-seeds from the
  // agents' current states on the next poll.
  function rollingReset() {
    agentLastState = {}
    dotSlots = []
    slotSeq = 0
    pendingRolling = []
  }

  // Queue a write to one Dot and drain the queue one write at a time, so that
  // several status changes in the same poll each reach their Dot in turn
  // (the single writer would otherwise drop all but the first).
  function queueRollingWrite(path, prog, label) {
    var q = pendingRolling ? pendingRolling.slice() : []
    q.push({ path: String(path), prog: String(prog), label: String(label) })
    pendingRolling = q
    flushRolling()
  }

  function flushRolling() {
    if (writeProc.running) return
    if (!pendingRolling || pendingRolling.length === 0) return
    var q = pendingRolling.slice()
    var item = q.shift()
    pendingRolling = q
    applyProgramTo(item.prog, item.label, [item.path])
  }

  // Process the latest per-agent states: for every agent whose state changed
  // to a lightable (non-idle) status, show it on a Dot. To avoid ever
  // displaying an out-of-date status, a new status from an agent that is
  // already on a Dot overrides *that same Dot* (its previous status was
  // stale). Only a status from an agent not currently shown claims a fresh
  // Dot, taking the one showing the oldest status. The Dots therefore always
  // reflect the latest status per agent, never a superseded one.
  function processRolling(agents) {
    if (reactionMode !== "rolling") return
    if (!reactionsEnabled || !mounted) return
    var n = deviceCount
    if (n <= 0) return
    var list = agents || []

    // Resize the slot buffer to the current Dot count (replug-safe).
    var slots = dotSlots ? dotSlots.slice() : []
    while (slots.length < n) slots.push(null)
    if (slots.length > n) slots = slots.slice(0, n)

    // Detect status changes since the last poll, keeping the agent name so we
    // can find (and override) the Dot already showing that agent.
    var last = agentLastState ? JSON.parse(JSON.stringify(agentLastState)) : {}
    var events = []
    for (var i = 0; i < list.length; i++) {
      var nm = String(list[i].name)
      var st = String(list[i].state)
      if (last[nm] !== st) {
        last[nm] = st
        events.push({ agent: nm, state: st })
      }
    }
    agentLastState = last

    for (var e = 0; e < events.length; e++) {
      var evAgent = events[e].agent
      var evState = events[e].state

      // Is this agent already showing on a Dot? If so, that Dot's status is
      // now stale — reuse the same Dot instead of lighting a second one.
      var idx = -1
      for (var a = 0; a < n; a++) {
        if (slots[a] && slots[a].agent === evAgent) { idx = a; break }
      }

      if (evState === "idle" || evState === "") {
        // The agent went idle: return the Dot it was on to the idle program so
        // it stops showing a status that no longer applies (tracked as an idle
        // placeholder slot, agent empty, so it re-drives if idle's mapping
        // changes and can be reclaimed by the next active agent).
        if (idx >= 0) {
          slots[idx] = { agent: "", state: "idle", seq: 0 }
          if (devices[idx])
            queueRollingWrite(String(devices[idx].device), idleProgram(),
                              "Agent idle: " + evAgent)
        }
        continue
      }

      // A new lightable status. If the agent is not already on a Dot, take the
      // least-recently-updated Dot (preferring an unassigned or idle one).
      if (idx < 0) {
        idx = 0
        var best = null
        for (var s = 0; s < n; s++) {
          if (slots[s] === null || !slots[s].agent) { idx = s; best = null; break }
          if (best === null || slots[s].seq < best) { best = slots[s].seq; idx = s }
        }
      }
      slotSeq += 1
      slots[idx] = { agent: evAgent, state: evState, seq: slotSeq }
      var prog = reactionProgramFor(evState)
      if (prog !== "" && devices[idx])
        queueRollingWrite(String(devices[idx].device), prog, "Agent: " + evState)
    }

    // Drive any Dot with no live agent status to the idle program so a Dot
    // that was never claimed by an agent (e.g. holding a leftover manual
    // program) does not linger. Only unknown (null) slots are written here, so
    // idle placeholders are not re-written every poll.
    for (var d = 0; d < n; d++) {
      if (slots[d] === null) {
        slots[d] = { agent: "", state: "idle", seq: 0 }
        if (devices[d])
          queueRollingWrite(String(devices[d].device), idleProgram(), "Idle")
      }
    }
    dotSlots = slots
  }

  // Re-drive any Dot currently showing a state whose colour/animation changed.
  function reapplyRollingState(state) {
    if (reactionMode !== "rolling" || !reactionsEnabled || !mounted) return
    for (var i = 0; i < dotSlots.length; i++) {
      if (dotSlots[i] && dotSlots[i].state === state && devices[i]) {
        var prog = (state === "idle") ? idleProgram() : reactionProgramFor(state)
        if (prog !== "")
          queueRollingWrite(String(devices[i].device), prog,
                            (state === "idle") ? "Idle" : "Agent: " + state)
      }
    }
  }

  // Switch between "merged" and "rolling" reaction modes.
  function setReactionMode(m) {
    var r = reactions ? JSON.parse(JSON.stringify(reactions)) : {}
    r.mode = String(m)
    reactions = r
    saveReactions()
    rollingReset()
    if (reactionsEnabled) {
      if (r.mode === "rolling") processRolling(agentList)
      else applyReaction(true)
    }
  }

  // Preview one state's program now, regardless of the live agent state.
  function testReaction(state) {
    if (!mounted) return
    var prog = reactionProgramFor(state)
    if (prog === "") return
    var paths = reactionTargetPaths()
    if (paths.length === 0) paths = targetPaths()
    applyProgramTo(prog, "Agent: " + state, paths)
  }

  // --- reactions config mutation (persists via the bridge) ---------------
  function saveReactions() {
    cfgSetProc.command = [agentHelper, "config-set", JSON.stringify(reactions)]
    cfgSetProc.running = true
  }

  function setReactionsEnabled(on) {
    var r = reactions ? JSON.parse(JSON.stringify(reactions)) : {}
    r.enabled = on === true
    reactions = r
    saveReactions()
    if (r.enabled) {
      if (reactionMode === "rolling") { rollingReset(); processRolling(agentList) }
      else applyReaction(true)
    } else {
      turnOff()
    }
  }

  function setReactionsTarget(t) {
    var r = reactions ? JSON.parse(JSON.stringify(reactions)) : {}
    r.target = String(t)
    reactions = r
    saveReactions()
    applyReaction(true)
  }

  function setReactionProgram(state, program) {
    var r = reactions ? JSON.parse(JSON.stringify(reactions)) : {}
    if (!r.programs) r.programs = {}
    r.programs[state] = String(program)
    reactions = r
    saveReactions()
    if (reactionMode === "rolling") reapplyRollingState(state)
    else if (state === agentState) applyReaction(true)
  }

  // Persist a state's colour + animation + brightness, recomputing its
  // program. An empty hex renders as "off"; the animation and brightness are
  // remembered even while off, so choosing a colour later restores them.
  function setReactionStyle(state, hex, anim, brightness) {
    var b = clampBrightness(brightness)
    var r = reactions ? JSON.parse(JSON.stringify(reactions)) : {}
    if (!r.programs) r.programs = {}
    if (!r.styles) r.styles = {}
    r.styles[state] = { hex: String(hex || ""), anim: String(anim || "solid"), brightness: b }
    r.programs[state] = buildAnimProgram(hex, anim, b)
    reactions = r
    saveReactions()
    if (reactionMode === "rolling") reapplyRollingState(state)
    else if (state === agentState) applyReaction(true)
  }

  // Set only the colour of a state, keeping its current animation + brightness.
  function setReactionColor(state, hex) {
    var s = reactionStyleFor(state)
    var anim = (s.anim === "off" || s.anim === "") ? "solid" : s.anim
    setReactionStyle(state, hex, anim, s.brightness)
  }

  // Set only the animation of a state, keeping its current colour + brightness.
  function setReactionAnim(state, anim) {
    var s = reactionStyleFor(state)
    setReactionStyle(state, s.hex, anim, s.brightness)
  }

  // Set only the brightness of a state, keeping its current colour + animation.
  function setReactionBrightness(state, brightness) {
    var s = reactionStyleFor(state)
    setReactionStyle(state, s.hex, s.anim, brightness)
  }

  // Blank a state (no light), keeping its animation + brightness.
  function setReactionOff(state) {
    var s = reactionStyleFor(state)
    setReactionStyle(state, "", s.anim, s.brightness)
  }

  function refreshAgents() {
    if (agentProc.running) return
    agentProc.running = true
  }

  function loadReactions() {
    if (cfgGetProc.running) return
    cfgGetProc.running = true
  }

  function installHooks() {
    if (hooksProc.running) return
    hooksBusy = true
    hooksResult = ""
    hooksProc.running = true
  }

  property bool hooksBusy: false
  property string hooksResult: ""

  function applyAgents(parsed) {
    if (!parsed) return
    agentList = (parsed.agents && parsed.agents.length !== undefined) ? parsed.agents : []
    agentActive = String(parsed.agent || "")
    var st = String(parsed.effective || "idle")
    var changed = st !== agentState
    agentState = st
    if (reactionMode === "rolling") processRolling(agentList)
    else if (changed) applyReaction(false)
  }

  // Build a program for a solid color at the given brightness (0-255).
  function solid(hex, brightness) {
    var b = clampBrightness(brightness)
    return (b < 255 ? "brightness " + b + "\n" : "") + hex
  }

  // Breathing pulse in one color.
  function pulse(hex, brightness) {
    var b = clampBrightness(brightness)
    return (b < 255 ? "brightness " + b + "\n" : "")
      + "off\n" + hex + " 1.6s pulse\nrepeat"
  }

  function clampBrightness(v) {
    var n = Math.round(Number(v))
    if (!isFinite(n)) n = 255
    if (n < 8) n = 8
    if (n > 255) n = 255
    return n
  }

  function applyStatus(parsed) {
    if (!parsed) {
      devices = []
      mounted = false
      normalizeTarget()
      return
    }
    if (parsed.ok === false && parsed.error) lastError = String(parsed.error)
    var list = (parsed.devices && parsed.devices.length !== undefined) ? parsed.devices : []
    devices = list
    mounted = list.length > 0
    if (list.length > 0) {
      device = String(list[0].device || "")
      firmware = String(list[0].firmware || "")
      serial = String(list[0].serial || "")
      fwState = String(list[0].fwState || "")
    } else {
      device = ""; firmware = ""; serial = ""; fwState = ""
    }
    normalizeTarget()
  }

  Process {
    id: statusProc
    running: false
    command: [root.helper, "list"]
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
      onStreamFinished: root.applyStatus(root.parseJson(text))
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("sidepulse-dot", text.trim())
    }
  }

  Process {
    id: writeProc
    running: false
    command: []
    stdout: StdioCollector {
      id: writeOut
      waitForEnd: true
      onStreamFinished: {
        var parsed = root.parseJson(text)
        if (parsed) {
          if (parsed.ok === false)
            root.lastError = parsed.error ? String(parsed.error) : "Write failed."
          if (parsed.mounted !== undefined) root.mounted = parsed.mounted === true
          if (parsed.device) root.device = String(parsed.device)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("sidepulse-dot", text.trim())
    }
    onExited: {
      root.busy = false
      root.flushRolling()
      root.refresh()
    }
  }

  Timer {
    interval: root.pollIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Poll the merged coding-agent state and react to changes.
  Process {
    id: agentProc
    running: false
    command: [root.agentHelper, "effective"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAgents(root.parseJson(text))
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("sidepulse-agent", text.trim())
    }
  }

  // Load the persisted reactions config once at startup.
  Process {
    id: cfgGetProc
    running: false
    command: [root.agentHelper, "config-get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = root.parseJson(text)
        if (parsed) { root.reactions = parsed; root.restoreUi() }
      }
    }
  }

  // Persist the reactions config (fire-and-forget).
  Process {
    id: cfgSetProc
    running: false
    command: []
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("sidepulse-agent", text.trim())
    }
  }

  // Wire the agents' hooks on demand.
  Process {
    id: hooksProc
    running: false
    command: [root.agentHelper, "install-hooks"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = root.parseJson(text)
        if (parsed && parsed.results)
          root.hooksResult = parsed.results.join("\n")
        else
          root.hooksResult = "Hooks installed."
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("sidepulse-agent", text.trim())
    }
    onExited: root.hooksBusy = false
  }

  Timer {
    id: agentTimer
    interval: 1500
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshAgents()
  }

  Component.onCompleted: root.loadReactions()
}
