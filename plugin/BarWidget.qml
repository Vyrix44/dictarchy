import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// dictarchy bar icon.
//   left-click   start/stop dictation, or enter the API key while setup is needed
//   right-click  settings menu (API key, language, keys, output, test, log)
//   scroll       next/previous language
//
// State comes from `dictarchy status`, which the CLI also writes to
// $XDG_RUNTIME_DIR/dictarchy/status.json on every change. The widget watches
// that file for instant updates and polls the command every few seconds as a
// fallback (stale recordings, an API key added by hand, a missing file).
BarWidget {
  id: root
  moduleName: "io.github.vyrix44.dictarchy"

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  // shell.json may override the command: { "id": "io.github.vyrix44.dictarchy", "command": "/path/to/dictarchy" }
  readonly property string command: String(setting("command", home + "/.local/bin/dictarchy"))
  readonly property string statusPath: runtimeDir !== "" ? runtimeDir + "/dictarchy/status.json" : ""

  property string status: "idle"   // not "state": Item already has one
  property string language: ""
  property string ptt: ""
  property string toggle: ""
  property bool missing: false

  readonly property var knownStates: ["idle", "recording", "transcribing", "error", "setup"]

  readonly property string icon: {
    if (missing || status === "error" || status === "setup") return "󰍭"
    if (status === "transcribing") return "󰔟"
    return "󰍬"
  }

  readonly property string label: {
    if (vertical) return ""
    if (status === "setup") return strings.t("label.setup")
    return language === "" ? "" : language.toUpperCase()
  }

  readonly property string tooltip: {
    if (missing) return strings.t("state.missing").arg(command)
    var lines = [strings.t("state." + status)]
    if (status === "setup") {
      lines.push("", strings.t("hint.setup"), strings.t("hint.menu"))
      return lines.join("\n")
    }
    lines.push(language === "auto" ? strings.t("info.languageAuto") : strings.t("info.language").arg(language.toUpperCase()))
    lines.push(strings.t("info.ptt").arg(ptt !== "" ? ptt : strings.t("info.off")))
    lines.push(strings.t("info.toggle").arg(toggle !== "" ? toggle : strings.t("info.off")))
    lines.push("", strings.t("hint.toggle"), strings.t("hint.menu"), strings.t("hint.scroll"))
    return lines.join("\n")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // The status is produced by our own CLI, but it is still parsed defensively:
  // only known states and short, plain values are taken over.
  function boundedString(value, pattern) {
    if (typeof value !== "string" || value.length > 64) return ""
    return pattern.test(value) ? value : ""
  }

  function apply(raw) {
    var data
    try {
      data = JSON.parse(String(raw || "").trim())
    } catch (e) {
      return
    }
    if (!data || typeof data !== "object") return
    if (knownStates.indexOf(data.state) === -1) return
    missing = false
    status = data.state
    language = boundedString(data.language, /^([a-z]{2,3}|auto)$/)
    ptt = boundedString(data.ptt, /^[A-Za-z0-9_ +]*$/)
    toggle = boundedString(data.toggle, /^[A-Za-z0-9_ +]*$/)
  }

  function run(args) {
    if (bar) bar.run(Util.shellQuote(command) + " " + args)
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.apply(text())
  }

  Process {
    id: poll
    command: [root.command, "status", "--write"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.apply(text)
        // The file may not have existed when the watch was set up.
        if (root.statusPath !== "") statusFile.reload()
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.missing = true
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!poll.running) poll.running = true
  }

  // A touchpad sends many small wheel events per gesture: one language step each.
  Timer {
    id: wheelGate
    interval: 250
  }

  TextMetrics {
    id: labelMetrics
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    text: root.label
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    labelText: root.label
    slotSize: root.label === "" ? Style.bar.iconSlot
      : Style.bar.iconSlot + labelMetrics.advanceWidth + Style.space(4)
    active: root.status === "recording" || root.status === "error"
    dimmed: root.status === "setup" || root.missing
    tooltipText: root.tooltip
    onPressed: function(b) {
      if (b === Qt.RightButton) root.run("menu")
      else if (b === Qt.LeftButton) root.run(root.status === "setup" ? "setup" : "toggle")
    }
    onWheelMoved: function(delta) {
      if (root.status === "setup" || wheelGate.running) return
      wheelGate.start()
      root.run(delta > 0 ? "lang next" : "lang prev")
    }
  }
}
