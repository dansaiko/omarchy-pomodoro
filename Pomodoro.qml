import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Logic.js" as Logic

// Pomodoro timer: a draining ring in the bar plus a popup with the controls,
// live duration steppers and today's tally.
//
// Authoritative timer state is an absolute deadline persisted to
// ~/.local/state/omarchy/pomodoro/state.json, not a countdown held in
// memory. That buys three things for free: the timer survives a shell
// restart mid-session, it can't drift, and every bar surface on a
// multi-monitor setup renders the same clock without any syncing.
Panel {
  id: root
  moduleName: "dansaiko.pomodoro"
  ipcTarget: "dansaiko.pomodoro"
  // The panel lifecycle handler only speaks open/close/toggle; this plugin
  // also needs start/pause/skip/reset on the same target, and a target only
  // admits one handler, so we own it below.
  manageIpc: false

  // ---------------------------------------------------------------- settings

  readonly property int focusMinutes: Logic.clampMinutes(setting("focusMinutes", 25))
  readonly property int breakMinutes: Logic.clampMinutes(setting("breakMinutes", 5))
  readonly property int longBreakMinutes: Logic.clampMinutes(setting("longBreakMinutes", 15))
  readonly property int cycleLength: Logic.clampCycle(setting("cycleLength", 4))
  readonly property bool autoStartBreaks: setting("autoStartBreaks", true) === true
  readonly property bool autoStartFocus: setting("autoStartFocus", false) === true
  readonly property bool silenceNotifications: setting("silenceNotifications", true) === true
  readonly property bool soundEnabled: setting("sound", true) === true
  readonly property bool showIdleGlyph: setting("showIdleGlyph", true) === true
  readonly property string focusEndSound: String(setting("focusEndSound", "/usr/share/sounds/freedesktop/stereo/complete.oga"))
  readonly property string breakEndSound: String(setting("breakEndSound", "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"))

  // --------------------------------------------------------- runtime state

  property string phase: Logic.PHASE_FOCUS
  property bool running: false
  property real endsAt: 0            // epoch ms; authoritative while running
  property real pausedRemaining: 0   // ms; authoritative while stopped
  property int completed: 0          // focus sessions finished, all time
  property real waitingSince: 0      // epoch ms a finished phase started nagging
  property bool dndOwned: false      // we silenced notifications, so we may unsilence
  property bool stateLoaded: false
  property var sessions: []
  property real now: Date.now()
  property real dayTick: Date.now()
  property int cursorRow: -1         // 0..2 while the keyboard is on a stepper

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/pomodoro"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string logPath: stateDir + "/sessions.jsonl"

  readonly property bool vertical: bar ? bar.vertical : false

  // ------------------------------------------------------------- derived

  function minutesFor(target) {
    if (target === Logic.PHASE_BREAK) return root.breakMinutes
    if (target === Logic.PHASE_LONG) return root.longBreakMinutes
    return root.focusMinutes
  }

  function durationMsFor(target) {
    return root.minutesFor(target) * 60000
  }

  readonly property real phaseDurationMs: durationMsFor(phase)
  readonly property real remainingMs: running ? Math.max(0, endsAt - now) : pausedRemaining
  // A phase whose time is up while the next one waits on an explicit start.
  readonly property bool waiting: !running && waitingSince > 0
  readonly property real overrunMs: waiting ? Math.max(0, now - waitingSince) : 0
  // Untouched: sitting at a full phase length, nothing to resume.
  readonly property bool idle: !running && !waiting && Math.abs(pausedRemaining - phaseDurationMs) < 1000
  readonly property real fraction: phaseDurationMs > 0
    ? Math.max(0, Math.min(1, remainingMs / phaseDurationMs))
    : 0

  readonly property var today: Logic.todayStats(sessions, dayTick)
  readonly property int cyclePos: Logic.cyclePosition(completed, cycleLength)

  readonly property color barTint: bar ? bar.barForeground : Color.foreground
  readonly property color popupTint: bar ? bar.foreground : Color.foreground
  readonly property color urgentTint: bar ? bar.urgent : Color.urgent
  readonly property color phaseTint: waiting
    ? urgentTint
    : (Logic.isBreak(phase) ? Color.accent : barTint)

  readonly property string phaseGlyph: waiting ? Logic.GLYPH_DONE : Logic.phaseGlyph(phase)
  readonly property string barLabel: waiting ? Logic.formatOverrun(overrunMs) : Logic.formatClock(remainingMs)

  readonly property string statusLine: {
    if (waiting) return "Ready — start it"
    if (running) return "Running"
    if (idle) return "Ready"
    return "Paused"
  }

  readonly property string tooltip: {
    var parts = []
    if (waiting) parts.push(Logic.phaseLabel(phase) + " ready, waiting " + Logic.formatOverrun(overrunMs))
    else if (running) parts.push(Logic.phaseLabel(phase) + " · " + Logic.formatClock(remainingMs) + " left")
    else if (idle) parts.push(Logic.phaseLabel(phase) + " · " + minutesFor(phase) + "m, not started")
    else parts.push(Logic.phaseLabel(phase) + " · paused at " + Logic.formatClock(remainingMs))
    if (phase === Logic.PHASE_FOCUS) parts.push("#" + cyclePos + " of " + cycleLength)
    parts.push("today " + today.count + " · " + Logic.formatDuration(today.minutes))
    return parts.join("   ")
  }

  // A bar surface is built per monitor, so this widget can be live several
  // times over. Rendering is safe to duplicate (every instance derives the
  // same clock from the same deadline) but firing a phase transition is not,
  // so exactly one instance owns expiry. Recomputed at each use rather than
  // cached in a binding: `moduleWidgets` is a function call, so a binding
  // would never re-evaluate when a monitor comes or goes.
  function leads() {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var peers = bar.moduleWidgets(moduleName)
    return peers.length === 0 || peers[0] === root
  }

  // ------------------------------------------------------------ persistence

  function hydrate(raw) {
    var parsed = Logic.parseState(raw)
    if (parsed) {
      phase = parsed.phase
      completed = parsed.completed
      dndOwned = parsed.dndOwned
      waitingSince = parsed.waitingSince
      if (parsed.running && parsed.endsAt > 0) {
        running = true
        endsAt = parsed.endsAt
        pausedRemaining = 0
      } else {
        running = false
        endsAt = 0
        pausedRemaining = parsed.remainingMs > 0 ? parsed.remainingMs : durationMsFor(parsed.phase)
      }
    }
    stateLoaded = true
    now = Date.now()
  }

  // First run: no file yet. Arm a fresh focus phase and let the first
  // persist() create it.
  function hydrateMissing() {
    running = false
    endsAt = 0
    waitingSince = 0
    pausedRemaining = durationMsFor(phase)
    stateLoaded = true
  }

  function persist() {
    if (!stateLoaded) return
    stateFile.setText(Logic.serializeState({
      phase: root.phase,
      running: root.running,
      endsAt: root.endsAt,
      remainingMs: root.running ? 0 : root.pausedRemaining,
      completed: root.completed,
      waitingSince: root.waitingSince,
      dndOwned: root.dndOwned
    }))
  }

  function quote(value) {
    if (bar && typeof bar.shellQuote === "function") return bar.shellQuote(value)
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function shellRun(command) {
    if (bar && typeof bar.run === "function") bar.run(command)
  }

  // ------------------------------------------------------ do not disturb

  function notificationService() {
    if (!bar || !bar.shell || typeof bar.shell.serviceFor !== "function") return null
    return bar.shell.serviceFor("omarchy.notifications")
  }

  function refreshIndicators() {
    shellRun("omarchy-shell -q omarchy.indicators refresh")
  }

  function acquireDnd() {
    if (!silenceNotifications || dndOwned) return
    var service = notificationService()
    if (!service || typeof service.setDoNotDisturb !== "function") return
    // Already silenced by hand — leave it be and don't claim it, or finishing
    // a pomodoro would un-silence a DND the user set for their own reasons.
    if (service.doNotDisturb === true) return
    service.setDoNotDisturb(true)
    dndOwned = true
    refreshIndicators()
  }

  function releaseDnd() {
    if (!dndOwned) return
    dndOwned = false
    var service = notificationService()
    if (service && typeof service.setDoNotDisturb === "function") service.setDoNotDisturb(false)
    refreshIndicators()
  }

  // ------------------------------------------------------- announcements

  function notify(headline, description, glyph) {
    shellRun("omarchy notification send --app-name Pomodoro -r 77021 -g "
      + quote(glyph) + " " + quote(headline) + " " + quote(description))
  }

  function playSound(file) {
    if (!soundEnabled || !file) return
    shellRun("pw-play --volume=0.5 " + quote(file) + " >/dev/null 2>&1 || true")
  }

  function logSession(minutes) {
    var line = Logic.sessionLine(Date.now(), Logic.PHASE_FOCUS, minutes)
    shellRun("mkdir -p " + quote(stateDir) + " && printf '%s\n' " + quote(line) + " >> " + quote(logPath))
  }

  // --------------------------------------------------------- phase machine

  function beginPhase() {
    waitingSince = 0
    running = true
    endsAt = Date.now() + Math.max(1000, pausedRemaining)
    now = Date.now()
    if (phase === Logic.PHASE_FOCUS) acquireDnd()
    else releaseDnd()
    persist()
  }

  function armPhase(target) {
    phase = target
    running = false
    endsAt = 0
    pausedRemaining = durationMsFor(target)
  }

  function startTimer() {
    if (running) return
    if (pausedRemaining <= 0) pausedRemaining = phaseDurationMs
    beginPhase()
  }

  function pauseTimer() {
    if (!running) return
    pausedRemaining = Math.max(0, endsAt - Date.now())
    running = false
    endsAt = 0
    // Pausing means stepping away, which is exactly when you want to see
    // what you missed.
    releaseDnd()
    persist()
  }

  function toggleTimer() {
    if (running) pauseTimer()
    else startTimer()
  }

  function resetTimer() {
    releaseDnd()
    waitingSince = 0
    armPhase(phase)
    persist()
  }

  function skipPhase() {
    releaseDnd()
    waitingSince = 0
    armPhase(Logic.skipTarget(phase))
    persist()
  }

  // Time is up. Bank the session, announce it, and either roll straight into
  // the next phase or park in the nag state until the user starts it.
  function completePhase() {
    var finished = phase
    var minutes = Math.round(phaseDurationMs / 60000)

    if (finished === Logic.PHASE_FOCUS) {
      completed = completed + 1
      logSession(minutes)
    }
    // Before the notification, so the toast we're about to send isn't the
    // one thing DND swallows.
    releaseDnd()

    var next = Logic.nextPhase(finished, completed, cycleLength)
    armPhase(next)

    var auto = next === Logic.PHASE_FOCUS ? autoStartFocus : autoStartBreaks
    var nextLabel = Logic.phaseLabel(next).toLowerCase()

    if (finished === Logic.PHASE_FOCUS) {
      playSound(focusEndSound)
      // `today` is read back from the log file a subprocess is still writing,
      // so count the session we just banked by hand.
      notify("Focus complete",
        minutes + "m banked · " + (today.count + 1) + " today · " + (auto ? nextLabel + " started" : nextLabel + " when you're ready"),
        Logic.GLYPH_DONE)
    } else {
      playSound(breakEndSound)
      notify(Logic.phaseLabel(finished) + " over",
        auto ? "Focus started" : "Start your next pomodoro",
        Logic.phaseGlyph(Logic.PHASE_FOCUS))
    }

    if (auto) {
      beginPhase()
    } else {
      waitingSince = Date.now()
      persist()
    }
  }

  // ------------------------------------------------------ duration editing

  function updateSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry[key] = value
    // Applied locally first so the panel responds on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function adjustMinutes(target, delta) {
    var current = minutesFor(target)
    var next = Logic.clampMinutes(current + delta)
    if (next === current) return

    updateSetting(Logic.minutesKey(target), next)
    if (target !== phase) return

    // Retune the phase in flight rather than restarting it: +1 buys a minute
    // now, it doesn't rewind the clock.
    var deltaMs = (next - current) * 60000
    if (running) endsAt = Math.max(now + 1000, endsAt + deltaMs)
    else pausedRemaining = Math.max(0, pausedRemaining + deltaMs)
    persist()
  }

  function adjustCursorRow(delta) {
    if (cursorRow < 0 || cursorRow > 2) return
    adjustMinutes(cursorRow === 0 ? Logic.PHASE_FOCUS
      : (cursorRow === 1 ? Logic.PHASE_BREAK : Logic.PHASE_LONG), delta)
  }

  // ------------------------------------------------------------- lifecycle

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onNowChanged: {
    if (!stateLoaded || !running) return
    if (endsAt <= 0 || now < endsAt) return
    if (!leads()) return
    completePhase()
  }

  Component.onCompleted: {
    ensureDirProc.running = true
    Qt.callLater(function() {
      stateFile.reload()
      sessionsFile.reload()
    })
  }

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.stateDir]
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.hydrate(text())
    onLoadFailed: root.hydrateMissing()
    // `text()` is stale inside the change signal, so route through a reload.
    onFileChanged: reload()
  }

  FileView {
    id: sessionsFile
    path: root.logPath
    watchChanges: true
    printErrors: false
    onLoaded: root.sessions = Logic.parseSessions(text())
    onLoadFailed: root.sessions = []
    onFileChanged: reload()
  }

  // 100ms while the panel is open so the big ring is smooth; a coarser tick
  // is plenty for a bar label that only renders whole seconds.
  Timer {
    id: ticker
    interval: root.opened ? 100 : 250
    repeat: true
    running: root.running || root.waiting || root.opened
    onTriggered: root.now = Date.now()
  }

  // Drives the day boundary for "today" without recomputing the tally on
  // every animation tick.
  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: root.dayTick = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    enabled: true

    function start(): string { root.startTimer(); return root.barLabel }
    function pause(): string { root.pauseTimer(); return root.barLabel }
    function toggleTimer(): string { root.toggleTimer(); return root.barLabel }
    function skip(): string { root.skipPhase(); return Logic.phaseLabel(root.phase) }
    function reset(): string { root.resetTimer(); return root.barLabel }
    function status(): string {
      return JSON.stringify({
        phase: root.phase,
        running: root.running,
        waiting: root.waiting,
        remaining: root.barLabel,
        remainingMs: Math.round(root.waiting ? 0 : root.remainingMs),
        overrunMs: Math.round(root.overrunMs),
        cycle: root.cyclePos + "/" + root.cycleLength,
        todayCount: root.today.count,
        todayMinutes: root.today.minutes
      })
    }

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // ------------------------------------------------------------ components

  // Arc that drains clockwise from 12 o'clock. Canvas rather than Shapes so
  // it works on any Qt build the shell might be running against.
  component ProgressRing: Canvas {
    id: ring

    property real fraction: 0
    property color trackColor: "transparent"
    property color fillColor: "white"
    property real thickness: Math.max(1.5, width * 0.16)

    renderStrategy: Canvas.Cooperative
    onFractionChanged: requestPaint()
    onFillColorChanged: requestPaint()
    onTrackColorChanged: requestPaint()
    onThicknessChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      if (!ctx) return
      ctx.reset()
      var radius = Math.max(0.5, Math.min(width, height) / 2 - ring.thickness / 2)
      var cx = width / 2
      var cy = height / 2
      ctx.lineWidth = ring.thickness
      ctx.lineCap = "butt"

      ctx.strokeStyle = ring.trackColor
      ctx.beginPath()
      ctx.arc(cx, cy, radius, 0, Math.PI * 2)
      ctx.stroke()

      var swept = Math.max(0, Math.min(1, ring.fraction))
      if (swept <= 0) return
      ctx.strokeStyle = ring.fillColor
      ctx.beginPath()
      ctx.arc(cx, cy, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * swept)
      ctx.stroke()
    }
  }

  // "Focus  [-]  25m  [+]" row. Inline components can't see the enclosing
  // file's ids, so the row reports the click and the use site applies it.
  component StepperRow: Item {
    id: stepper

    property string label: ""
    property int minutes: 0
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family
    property bool hasCursor: false

    signal adjust(int delta)

    implicitHeight: Math.max(Style.space(24), minusButton.implicitHeight)

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -Style.space(6)
      anchors.rightMargin: -Style.space(6)
      radius: Style.cornerRadius
      visible: stepper.hasCursor
      color: Style.hoverFillFor(stepper.foreground, Color.accent, Color.urgent)
    }

    Text {
      id: stepperLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: stepper.label
      color: stepper.foreground
      font.family: stepper.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      width: Math.max(0, parent.width - plusButton.width - minusButton.width - valueLabel.width - Style.space(18))
    }

    PanelActionButton {
      id: minusButton
      anchors.right: valueLabel.left
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      iconText: Logic.GLYPH_MINUS
      foreground: stepper.foreground
      fontFamily: stepper.fontFamily
      fontSize: Style.font.iconSmall
      onClicked: stepper.adjust(-1)
    }

    Text {
      id: valueLabel
      textFormat: Text.PlainText
      anchors.right: plusButton.left
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignHCenter
      width: Style.space(38)
      text: stepper.minutes + "m"
      color: stepper.foreground
      font.family: stepper.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    PanelActionButton {
      id: plusButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: Logic.GLYPH_PLUS
      foreground: stepper.foreground
      fontFamily: stepper.fontFamily
      fontSize: Style.font.iconSmall
      onClicked: stepper.adjust(1)
    }
  }

  // ------------------------------------------------------------ bar button

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.tooltip
    fixedWidth: root.vertical ? -1 : Math.round(barContent.implicitWidth + Style.spaceReal(9) * 2)
    fixedHeight: root.vertical ? Math.round(barContent.implicitHeight + Style.spaceReal(5) * 2) : -1

    onPressed: function(pressedButton) {
      if (pressedButton === Qt.RightButton) root.toggleTimer()
      else if (pressedButton === Qt.MiddleButton) root.skipPhase()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (delta === 0) return
      root.adjustMinutes(root.phase, delta > 0 ? 1 : -1)
    }

    // Idle and untouched: a lone glyph, so a timer you aren't running doesn't
    // sit there shouting "25:00" at you all day.
    readonly property bool glyphOnly: root.idle && root.showIdleGlyph

    Item {
      id: barContent
      anchors.centerIn: parent
      implicitWidth: root.vertical
        ? Style.bar.iconSlot
        : (button.glyphOnly ? Style.bar.iconCanvas : barRing.width + Style.space(6) + barTime.implicitWidth)
      implicitHeight: root.vertical
        ? (button.glyphOnly ? Style.bar.iconSlot : barRing.height + Style.space(2) + barTimeVertical.implicitHeight)
        : Style.bar.iconCanvas

      OpticalGlyph {
        anchors.centerIn: parent
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        visible: button.glyphOnly
        text: Logic.GLYPH_IDLE
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: root.barTint
      }

      ProgressRing {
        id: barRing
        visible: !button.glyphOnly
        width: Math.round(Style.bar.iconCanvas * 0.82)
        height: width
        anchors.verticalCenter: root.vertical ? undefined : parent.verticalCenter
        anchors.horizontalCenter: root.vertical ? parent.horizontalCenter : undefined
        anchors.left: root.vertical ? undefined : parent.left
        anchors.top: root.vertical ? parent.top : undefined
        fraction: root.fraction
        thickness: Math.max(1.6, width * 0.2)
        trackColor: Qt.rgba(root.barTint.r, root.barTint.g, root.barTint.b, 0.22)
        fillColor: root.phaseTint
      }

      Text {
        id: barTime
        textFormat: Text.PlainText
        visible: !button.glyphOnly && !root.vertical
        anchors.left: barRing.right
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: root.barLabel
        color: root.phaseTint
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering

        Behavior on color { ColorAnimation { duration: 160 } }
      }

      // Vertical bars are 28px wide — no room for MM:SS, so show whole
      // minutes under the ring and leave the detail to the tooltip.
      Text {
        id: barTimeVertical
        textFormat: Text.PlainText
        visible: !button.glyphOnly && root.vertical
        anchors.top: barRing.bottom
        anchors.topMargin: Style.space(2)
        anchors.horizontalCenter: parent.horizontalCenter
        text: Math.max(0, Math.ceil((root.waiting ? root.overrunMs : root.remainingMs) / 60000))
        color: root.phaseTint
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
        renderType: Text.NativeRendering
      }
    }

    // The nag: once a phase is up and the next one is waiting on you, the
    // widget breathes in the theme's urgent color until you deal with it.
    SequentialAnimation {
      running: root.waiting
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { target: barContent; property: "opacity"; to: 0.35; duration: 750; easing.type: Easing.InOutSine }
      NumberAnimation { target: barContent; property: "opacity"; to: 1.0; duration: 750; easing.type: Easing.InOutSine }
      onRunningChanged: if (!running) barContent.opacity = 1.0
    }
  }

  // ----------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          if (root.cursorRow < 0) root.cursorRow = dy > 0 ? 0 : 2
          else root.cursorRow = Math.max(0, Math.min(2, root.cursorRow + dy))
          return
        }
        if (dx !== 0) root.adjustCursorRow(dx > 0 ? 1 : -1)
      }
      onActivateRequested: root.toggleTimer()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "s") root.skipPhase()
        else if (text === "r") root.resetTimer()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero: phase, status, cycle position ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroGlyph.implicitHeight, heroLabels.implicitHeight, heroCycle.implicitHeight)

          Text {
            id: heroGlyph
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.phaseGlyph
            color: root.waiting ? root.urgentTint : root.popupTint
            font.family: Style.font.family
            font.pixelSize: Style.font.heading

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroGlyph.right
            anchors.leftMargin: Style.space(10)
            anchors.right: heroCycle.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: Logic.phaseLabel(root.phase)
              color: root.popupTint
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusLine.toUpperCase()
              color: root.waiting ? root.urgentTint : Qt.darker(root.popupTint, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroCycle
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.phase === Logic.PHASE_FOCUS ? "#" + root.cyclePos + " of " + root.cycleLength : ""
            color: Qt.darker(root.popupTint, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- The clock ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(128)

          ProgressRing {
            id: heroRing
            anchors.centerIn: parent
            width: Style.space(126)
            height: width
            fraction: root.idle ? 1 : root.fraction
            thickness: Math.max(3, width * 0.055)
            trackColor: Qt.rgba(root.popupTint.r, root.popupTint.g, root.popupTint.b, 0.12)
            fillColor: root.waiting
              ? root.urgentTint
              : (root.idle ? Qt.rgba(root.popupTint.r, root.popupTint.g, root.popupTint.b, 0.3) : root.phaseTint)
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.barLabel
              color: root.waiting ? root.urgentTint : root.popupTint
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              visible: root.dndOwned
              text: Logic.GLYPH_DND + "  silenced"
              color: Qt.darker(root.popupTint, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ---------- Controls ----------
        // Wrapper so the Row can size to its buttons and sit on the same
        // centerline as the ring above; a full-width Row packs them left.
        Item {
          width: parent.width
          implicitHeight: controlRow.implicitHeight

          Row {
            id: controlRow
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.spacing.controlGap

            Button {
              text: root.running ? "Pause" : (root.waiting || root.idle ? "Start" : "Resume")
              iconText: root.running ? Logic.GLYPH_PAUSE : Logic.GLYPH_PLAY
              bordered: true
              foreground: root.popupTint
              accent: root.waiting ? root.urgentTint : Color.accent
              fontFamily: Style.font.family
              onClicked: root.toggleTimer()
            }

            Button {
              text: "Skip"
              iconText: Logic.GLYPH_SKIP
              bordered: true
              foreground: root.popupTint
              fontFamily: Style.font.family
              tooltipText: "Skip to " + Logic.phaseLabel(Logic.skipTarget(root.phase)).toLowerCase() + " (s)"
              onClicked: root.skipPhase()
            }

            Button {
              text: "Reset"
              iconText: Logic.GLYPH_RESET
              bordered: true
              foreground: root.popupTint
              fontFamily: Style.font.family
              tooltipText: "Restart this phase (r)"
              onClicked: root.resetTimer()
            }
          }
        }

        PanelSeparator { foreground: root.popupTint }

        PanelSectionHeader {
          text: "Durations"
          foreground: root.popupTint
          fontFamily: Style.font.family
        }

        StepperRow {
          width: parent.width
          label: "Focus"
          minutes: root.focusMinutes
          foreground: root.popupTint
          fontFamily: Style.font.family
          hasCursor: root.cursorRow === 0
          onAdjust: function(delta) { root.adjustMinutes(Logic.PHASE_FOCUS, delta) }
        }

        StepperRow {
          width: parent.width
          label: "Break"
          minutes: root.breakMinutes
          foreground: root.popupTint
          fontFamily: Style.font.family
          hasCursor: root.cursorRow === 1
          onAdjust: function(delta) { root.adjustMinutes(Logic.PHASE_BREAK, delta) }
        }

        StepperRow {
          width: parent.width
          label: "Long break"
          minutes: root.longBreakMinutes
          foreground: root.popupTint
          fontFamily: Style.font.family
          hasCursor: root.cursorRow === 2
          onAdjust: function(delta) { root.adjustMinutes(Logic.PHASE_LONG, delta) }
        }

        PanelSeparator { foreground: root.popupTint }

        PanelSectionHeader {
          text: "Today"
          foreground: root.popupTint
          fontFamily: Style.font.family
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(dots.implicitHeight, tally.implicitHeight)

          Row {
            id: dots
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: Logic.dotModel(root.today.count, root.cycleLength, 12)

              Rectangle {
                required property bool modelData
                width: Style.space(7)
                height: width
                radius: width / 2
                color: modelData ? root.popupTint : "transparent"
                border.width: modelData ? 0 : 1
                border.color: Qt.rgba(root.popupTint.r, root.popupTint.g, root.popupTint.b, 0.35)
              }
            }
          }

          Text {
            id: tally
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.today.count + " done · " + Logic.formatDuration(root.today.minutes) + " focused"
            color: Qt.darker(root.popupTint, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
