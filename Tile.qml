import Quickshell.Wayland
import QtQuick
import QtQuick.Effects

// One window in the Alt+Tab panel (Main.qml): its live thumbnail, its name,
// what it is and which workspace it is on.
Item {
  id: tile
  required property var app   // the panel: Main.qml's root
  required property int gi     // its place in app.entries
  property int thumb: 100      // thumbnail height
  readonly property var entry: app.entries[gi] || ({})
  readonly property var toplevel: app.toplevelFor(entry.address)
  readonly property bool selected: gi === app.current
  readonly property string rawTitle: toplevel && toplevel.title ? toplevel.title : (entry.title || "")
  readonly property string agent: app.agentState(rawTitle)
  readonly property string title: app.cleanTitle(rawTitle) || app.appLabel(entry.appId)
  // The chosen card is lifted a little: a faint fill and a hairline.
  Rectangle {
    anchors.fill: parent
    radius: 12
    color: tile.selected ? tile.app.ink_(0.08) : tile.app.ink_(tileMouse.containsMouse ? 0.04 : 0)
    border.width: 1
    border.color: tile.selected ? tile.app.ink_(0.3) : "transparent"
    Behavior on color { ColorAnimation { duration: 140; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.32, 0.72, 0, 1, 1, 1] } }
  }

  // Thumbnail: the live window fills the frame (cropped, never
  // letterboxed), or its icon until a frame arrives.
  Item {
    id: frame
    x: 6; y: 6
    width: parent.width - 12
    height: tile.thumb
    opacity: tile.entry.minimized ? 0.45 : (tile.selected ? 1 : 0.7)
    Behavior on opacity { NumberAnimation { duration: 140 } }

    Rectangle {
      anchors.fill: parent
      radius: 8
      color: tile.app.ink_(0.05)
    }
    Item {
      id: clipped
      anchors.fill: parent
      layer.enabled: true
      layer.smooth: true
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: frameMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 0.05
      }
      ScreencopyView {
        id: view
        readonly property real aspect: sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 16 / 10
        readonly property bool wide: aspect > frame.width / frame.height
        anchors.horizontalCenter: parent.horizontalCenter
        y: 0
        width: wide ? frame.height * aspect : frame.width
        height: wide ? frame.height : frame.width / aspect
        captureSource: tile.toplevel ? tile.toplevel.wayland : null
        live: true
        paintCursor: false
        constraintSize: Qt.size(width * 2, height * 2)
        visible: hasContent
      }
    }
    Item {
      id: frameMask
      anchors.fill: parent
      visible: false
      layer.enabled: true
      Rectangle { anchors.fill: parent; radius: 8; color: "white"; antialiasing: true }
    }
    Image {
      anchors.centerIn: parent
      visible: !view.hasContent
      width: Math.min(parent.width, parent.height) * 0.4
      height: width
      sourceSize: Qt.size(width * 2, height * 2)
      source: tile.app.iconFor(tile.entry.appId)
      smooth: true
      asynchronous: true
    }
    Rectangle {
      anchors.fill: parent
      radius: 8
      color: "transparent"
      border.width: 1
      border.color: tile.app.ink_(0.1)
    }
  }

  // Name, then what the window is and its state, in mono.
  Text {
    id: name
    x: 10
    y: frame.y + frame.height + 7
    width: parent.width - 20
    textFormat: Text.PlainText
    text: tile.title
    color: tile.selected ? tile.app.ink : tile.app.ink_(0.78)
    font.family: tile.app.sans
    font.pixelSize: 13
    font.weight: tile.selected ? Font.DemiBold : Font.Medium
    elide: Text.ElideRight
  }
  Row {
    x: 10
    y: name.y + 19
    width: parent.width - 20 - (area.implicitWidth + 8)
    height: 14
    spacing: 6
    clip: true
    Image {
      width: 12; height: 12
      anchors.verticalCenter: parent.verticalCenter
      sourceSize: Qt.size(24, 24)
      source: tile.app.iconFor(tile.entry.appId)
      smooth: true
      asynchronous: true
      opacity: 0.85
    }
    Text {
      id: kind
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: (tile.agent ? "Claude" : tile.app.appLabel(tile.entry.appId)).toUpperCase()
      color: tile.app.ink_(0.48)
      font.family: tile.app.mono
      font.pixelSize: 10
      font.letterSpacing: 0.8
    }
    Rectangle {
      visible: tile.agent === "working"
      width: 6; height: 6; radius: 3
      anchors.verticalCenter: parent.verticalCenter
      color: tile.app.working
      SequentialAnimation on opacity {
        running: tile.agent === "working" && tile.app.active
        loops: Animation.Infinite
        NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
      }
    }
    Text {
      visible: tile.agent === "working"
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: tile.app.tr("TRABALHANDO", "WORKING")
      color: tile.app.ink_(0.62)
      font.family: tile.app.mono
      font.pixelSize: 10
      font.letterSpacing: 0.8
    }
  }

  // Which workspace it is on (the list runs by recent use, not by workspace).
  Text {
    id: area
    anchors.right: parent.right
    anchors.rightMargin: 10
    y: name.y + 19
    height: 14
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    text: tile.entry.minimized ? tile.app.tr("MINIMIZADA", "MINIMIZED") + (tile.entry.wsName ? " · " + tile.entry.wsName : "")
      : tile.app.tr("ÁREA ", "WS ") + (tile.entry.wsName || tile.entry.ws)
    color: tile.app.ink_(!tile.entry.minimized && tile.entry.ws === tile.app.currentWs ? 0.7 : 0.42)
    font.family: tile.app.mono
    font.pixelSize: 10
    font.letterSpacing: 0.8
  }

  MouseArea {
    id: tileMouse
    anchors.fill: parent
    hoverEnabled: true
    onClicked: tile.app.pick(tile.gi)
  }
}
