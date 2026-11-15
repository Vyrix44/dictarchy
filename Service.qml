import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "StatusModel.js" as StatusModel

// dictarchy service: the hotkeys and the recording overlay.
//
// Hotkeys: the push-to-talk and toggle binds live inside Hyprland's Lua state
// (hypr/dictarchy.lua), so the user's Hyprland config is never edited. This
// service has the CLI set them when it starts and again after every Hyprland
// config reload, which drops them, and removes them when the plugin is disabled
// or removed. A token identifies this instance, so a stop from an old instance
// (a shell reload) can't remove the binds a newer one set.
//
// Overlay: a small card at the bottom of the focused monitor while dictation
// is running.
//   recording     red dot and a scrolling waveform of the live microphone level
//   transcribing  the bars run as a wave until the text arrives
// It reads the same status file as the bar widget, so push-to-talk taps shorter
// than MIN_DURATION_MS never show it. The surface takes no input and no keyboard
// focus, like Omarchy's own OSD. Turn it off with OVERLAY="false" in
// ~/.config/dictarchy/config or from the dictarchy menu.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // ── Hotkeys ──
  readonly property string command: {
    var url = String(Qt.resolvedUrl("bin/dictarchy"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.slice(7)) : ""
  }
  readonly property string token: Date.now().toString(36) + Math.floor(Math.random() * 1e9).toString(36)
  property bool hotkeysPending: false

  function applyHotkeys() {
    if (command === "") return
    if (hotkeys.running) hotkeysPending = true
    else hotkeys.running = true
  }

  function clearHotkeys() {
    // Inline rather than through the CLI: the service may be going away with
    // the plugin folder. The token is base36, safe inside a Lua string.
    Quickshell.execDetached(["hyprctl", "dispatch",
      "(function() if dictarchy_hotkeys then dictarchy_hotkeys.clear('" + token + "') end return hl.dsp.exec_cmd('true') end)()"])
  }

  Process {
    id: hotkeys
    command: [root.command, "bindings", "--owner", root.token]
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) console.warn("[dictarchy] " + text.trim())
    }
    onExited: function(exitCode, exitStatus) {
      // A reload that came in while applying gets its own run.
      if (root.hotkeysPending) {
        root.hotkeysPending = false
        root.applyHotkeys()
      }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && String(event.name) === "configreloaded") root.applyHotkeys()
    }
  }

  Component.onDestruction: clearHotkeys()

  // ── Overlay ──

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string statusPath: runtimeDir !== "" ? runtimeDir + "/dictarchy/status.json" : ""

  property string status: "idle"
  property bool enabledByConfig: true

  readonly property bool recording: status === "recording"
  readonly property bool transcribing: status === "transcribing"
  readonly property bool shown: enabledByConfig && (recording || transcribing)

  readonly property int barCount: 15
  readonly property real barWidth: Style.space(3)
  readonly property real barGap: Style.space(3)
  readonly property real waveHeight: Style.space(22)
  readonly property real minBar: Style.space(3)
  readonly property int pad: Style.space(14)

  // Newest level last; every bar shows one sample, so the wave scrolls left.
  property var levels: []

  function resetLevels() {
    var next = []
    for (var i = 0; i < barCount; i++) next.push(0)
    levels = next
  }

  function apply(raw) {
    var data = StatusModel.parse(raw)
    if (!data) return
    if (data.state === "recording" && status !== "recording") resetLevels()
    status = data.state
    enabledByConfig = data.overlay
  }

  Component.onCompleted: {
    resetLevels()
    applyHotkeys()
  }

  FileView {
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.apply(text())
  }

  // Live input level. Quickshell's peak monitor needs a typed node, so a
  // virtual default source shows a flat line (the dot still marks recording).
  readonly property var source: Pipewire.defaultAudioSource
  PwObjectTracker { objects: root.source ? [root.source] : [] }
  PwNodePeakMonitor {
    id: peakMonitor
    node: root.source
    enabled: root.shown && root.recording && !!root.source
  }

  Timer {
    interval: 60
    repeat: true
    running: root.shown && root.recording
    onTriggered: {
      // Speech peaks sit well below full scale: lift them so normal talking
      // fills most of the height.
      var level = Math.min(1, Math.sqrt(Math.max(0, peakMonitor.peak)) * 1.4)
      var next = root.levels.slice(1)
      next.push(level)
      root.levels = next
    }
  }

  // Travelling wave while transcribing.
  property real phase: 0
  NumberAnimation on phase {
    running: root.shown && root.transcribing && Style.duration(900) > 0
    from: 0
    to: 2 * Math.PI
    duration: 900
    loops: Animation.Infinite
  }

  function barLevel(index) {
    if (transcribing) return 0.25 + 0.35 * (0.5 + 0.5 * Math.sin(phase - index * 0.55))
    return levels.length > index ? levels[index] : 0
  }

  OverlayWindow {
    id: panel
    shown: root.shown
    shownKeyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "dictarchy-overlay"
    // Visual only: an empty input region lets every click through.
    mask: Region {}

    BorderSurface {
      id: card
      width: card.borderLeft + root.pad + dot.width + root.pad + wave.width + root.pad + card.borderRight
      height: card.borderTop + root.pad + root.waveHeight + root.pad + card.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(28)
      color: Util.alpha(Commons.Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: panel.contentRevealed ? 1 : 0
      scale: panel.contentRevealed ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
      Behavior on scale {
        NumberAnimation { duration: Style.duration(160); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
      }

      Rectangle {
        id: dot
        x: card.borderLeft + root.pad
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(9)
        height: width
        radius: width / 2
        color: root.recording ? Commons.Color.urgent : Commons.Color.accent
        opacity: root.recording ? 1 : 0.5

        SequentialAnimation on opacity {
          running: root.shown && root.recording && Style.duration(700) > 0
          loops: Animation.Infinite
          NumberAnimation { to: 0.45; duration: 700; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
        }
      }

      Item {
        id: wave
        x: dot.x + dot.width + root.pad
        anchors.verticalCenter: parent.verticalCenter
        width: root.barCount * root.barWidth + (root.barCount - 1) * root.barGap
        height: root.waveHeight

        Repeater {
          model: root.barCount
          Rectangle {
            required property int index
            x: index * (root.barWidth + root.barGap)
            anchors.verticalCenter: parent.verticalCenter
            width: root.barWidth
            height: Math.max(root.minBar, root.barLevel(index) * root.waveHeight)
            radius: width / 2
            color: root.transcribing ? Commons.Color.accent : Commons.Color.popups.text
            Behavior on height {
              enabled: root.recording
              NumberAnimation { duration: 70; easing.type: Easing.OutCubic }
            }
          }
        }
      }
    }
  }
}
