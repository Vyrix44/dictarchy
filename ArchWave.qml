import QtQuick
import qs.Commons

// The dictarchy mark: five voice bars rising to a peak, drawn natively so it
// takes the bar's theme color and stays crisp at any size. Geometry follows
// assets/icon.svg (a 16-unit grid: bars at x = 2, 5, 8, 11, 14, bottom at 14).
//
// busy: the bars pulse one after another (transcribing). Only their opacity
// changes, so the bounds the bar measures for icon fitting stay the same.
Item {
  id: root

  property real iconSize: 16
  property color color: "white"
  property bool busy: false

  readonly property real unit: iconSize / 16
  readonly property var heights: [3, 6.5, 12, 6.5, 3]   // stroke length, without the round caps
  property real phase: 0

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // With animations turned off (omarchy toggle animations) the bars just show
  // a fixed staggered fade.
  NumberAnimation on phase {
    running: root.busy && Style.duration(1100) > 0
    from: 0
    to: 2 * Math.PI
    duration: 1100
    loops: Animation.Infinite
  }

  Repeater {
    model: 5
    Rectangle {
      required property int index
      readonly property real thickness: Math.max(1.5, 1.8 * root.unit)
      width: thickness
      height: root.heights[index] * root.unit + thickness
      radius: thickness / 2
      x: (2 + 3 * index) * root.unit - thickness / 2
      y: 14 * root.unit + thickness / 2 - height
      color: root.color
      opacity: root.busy ? 0.35 + 0.65 * (0.5 + 0.5 * Math.cos(root.phase - index * 0.9)) : 1
    }
  }
}
