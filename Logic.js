.pragma library

// Pure helpers for the Pomodoro widget. Kept out of the QML so the phase
// machine, clock formatting and stats aggregation can be reasoned about (and
// changed) without touching bindings.

var PHASE_FOCUS = "focus"
var PHASE_BREAK = "break"
var PHASE_LONG = "longBreak"

var MIN_MINUTES = 1
var MAX_MINUTES = 180

function phaseLabel(phase) {
  if (phase === PHASE_BREAK) return "Break"
  if (phase === PHASE_LONG) return "Long break"
  return "Focus"
}

// Material Design Icons via the Nerd Font patch, addressed by codepoint so
// this file stays plain ASCII and can't be mangled by an editor that
// normalizes surrogate pairs.
function phaseGlyph(phase) {
  if (phase === PHASE_BREAK) return String.fromCodePoint(0xF0176)  // coffee
  if (phase === PHASE_LONG) return String.fromCodePoint(0xF04B2)   // sleep
  return String.fromCodePoint(0xF0238)                             // fire
}

var GLYPH_IDLE = String.fromCodePoint(0xF13AB)   // timer-outline
var GLYPH_PLAY = String.fromCodePoint(0xF040A)   // play
var GLYPH_PAUSE = String.fromCodePoint(0xF03E4)  // pause
var GLYPH_SKIP = String.fromCodePoint(0xF04AD)   // skip-next
var GLYPH_RESET = String.fromCodePoint(0xF0709)  // restart
var GLYPH_MINUS = String.fromCodePoint(0xF0374)  // minus
var GLYPH_PLUS = String.fromCodePoint(0xF0415)   // plus
var GLYPH_DONE = String.fromCodePoint(0xF05E0)   // check-circle
var GLYPH_DND = String.fromCodePoint(0xF00AA)    // bell-off

function isBreak(phase) {
  return phase === PHASE_BREAK || phase === PHASE_LONG
}

function normalizePhase(phase) {
  return phase === PHASE_BREAK || phase === PHASE_LONG ? phase : PHASE_FOCUS
}

function clampMinutes(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return MIN_MINUTES
  return Math.max(MIN_MINUTES, Math.min(MAX_MINUTES, n))
}

function clampCycle(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 4
  return Math.max(1, Math.min(12, n))
}

// The phase that follows a *completed* one. `completedAfter` already counts
// the focus session that just finished, so the long break lands on the
// cycle boundary rather than one session late.
function nextPhase(phase, completedAfter, cycleLength) {
  if (phase !== PHASE_FOCUS) return PHASE_FOCUS
  var length = clampCycle(cycleLength)
  return completedAfter > 0 && completedAfter % length === 0 ? PHASE_LONG : PHASE_BREAK
}

// Skipping is not completing: an abandoned focus doesn't earn a long break,
// so the skip target ignores the cycle position entirely.
function skipTarget(phase) {
  return phase === PHASE_FOCUS ? PHASE_BREAK : PHASE_FOCUS
}

// Which setting key holds a phase's length.
function minutesKey(phase) {
  if (phase === PHASE_BREAK) return "breakMinutes"
  if (phase === PHASE_LONG) return "longBreakMinutes"
  return "focusMinutes"
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

function mmss(totalSeconds) {
  var sec = Math.max(0, totalSeconds)
  var h = Math.floor(sec / 3600)
  var m = Math.floor((sec % 3600) / 60)
  var s = sec % 60
  return h > 0 ? h + ":" + pad2(m) + ":" + pad2(s) : pad2(m) + ":" + pad2(s)
}

// Countdowns ceil so a fresh 25-minute phase reads "25:00" rather than
// flashing "24:59" on the first frame. Overrun counts up, so it floors.
function formatClock(ms) {
  if (ms < 0) return "+" + mmss(Math.floor(-ms / 1000))
  return mmss(Math.ceil(ms / 1000))
}

function formatOverrun(ms) {
  return "+" + mmss(Math.floor(Math.max(0, ms) / 1000))
}

// "3 of 4" — the position of the focus session currently in play.
function cyclePosition(completed, cycleLength) {
  var length = clampCycle(cycleLength)
  return (Math.max(0, completed) % length) + 1
}

function parseState(raw) {
  var parsed
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object" || parsed.version !== 1) return null
  var running = parsed.running === true
  return {
    phase: normalizePhase(parsed.phase),
    running: running,
    endsAt: Math.max(0, Number(parsed.endsAt) || 0),
    remainingMs: Math.max(0, Number(parsed.remainingMs) || 0),
    completed: Math.max(0, Math.round(Number(parsed.completed) || 0)),
    waitingSince: Math.max(0, Number(parsed.waitingSince) || 0),
    dndOwned: parsed.dndOwned === true
  }
}

function serializeState(state) {
  return JSON.stringify({
    version: 1,
    phase: state.phase,
    running: state.running,
    endsAt: Math.round(state.endsAt),
    remainingMs: Math.round(state.remainingMs),
    completed: state.completed,
    waitingSince: Math.round(state.waitingSince),
    dndOwned: state.dndOwned
  }, null, 2) + "\n"
}

// One JSON object per line, appended by a subprocess. A torn final line is
// expected while a write is in flight, so unparseable lines are skipped
// rather than treated as corruption.
function parseSessions(raw) {
  var out = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (!line) continue
    try {
      var entry = JSON.parse(line)
      if (entry && isFinite(Number(entry.ts)) && isFinite(Number(entry.minutes)))
        out.push({ ts: Number(entry.ts), minutes: Number(entry.minutes) })
    } catch (e) {
      // ignore
    }
  }
  return out
}

function startOfDay(nowMs) {
  var d = new Date(nowMs)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

function todayStats(sessions, nowMs) {
  var from = startOfDay(nowMs)
  var count = 0
  var minutes = 0
  for (var i = 0; i < sessions.length; i++) {
    if (sessions[i].ts < from) continue
    count++
    minutes += sessions[i].minutes
  }
  return { count: count, minutes: minutes }
}

function formatDuration(minutes) {
  var total = Math.max(0, Math.round(minutes))
  var h = Math.floor(total / 60)
  var m = total % 60
  if (h > 0) return h + "h " + m + "m"
  return m + "m"
}

// A dot per finished pomodoro today, padded out to at least one full cycle so
// the row reads as progress toward the next long break instead of a stub.
function dotModel(count, cycleLength, cap) {
  var length = clampCycle(cycleLength)
  var limit = Math.max(1, Math.round(Number(cap) || 12))
  var filled = Math.max(0, Math.round(Number(count) || 0))
  var slots = Math.min(limit, Math.max(length, filled))
  var out = []
  for (var i = 0; i < slots; i++) out.push(i < filled)
  return out
}

function sessionLine(nowMs, phase, minutes) {
  return JSON.stringify({
    at: new Date(nowMs).toISOString(),
    ts: Math.round(nowMs),
    phase: phase,
    minutes: Math.round(minutes)
  })
}
