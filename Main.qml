import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons as Commons

// Windows-style Alt+Tab with live thumbnails, in the dock's look.
// Hyprland owns the switching (alttab.lua, next to this file): it orders the
// windows, follows Tab / Shift+Tab, focuses the pick when Alt comes up and
// does a quick Alt+Tab without ever talking to the shell. This plugin only
// draws the panel, which the Lua side summons after a short hold:
//   omarchy-shell io.github.hugorolimf.alttab show '<json>'   {s, q, i, mon, w: [{a, c, t, m}]}
//   omarchy-shell io.github.hugorolimf.alttab select <s> <q> <i>
//   omarchy-shell io.github.hugorolimf.alttab hide <s>
// Every call runs in its own process, so they can arrive out of order: s is
// the switching session and q a counter within it; stale calls are dropped.
// A click on a thumbnail hands the pick back to Lua (hugorolimf_alttab_pick).
Item {
  id: root

  property var shell: null
  property var manifest: null

  // The switching lives in Hyprland's Lua config. Omarchy loads every file in
  // toggles/hypr on each reload, so a one-line loader there pulls in this
  // plugin's alttab.lua; nothing in the user's own config is edited. The
  // loader checks the file still exists, so removing the plugin never breaks
  // the config. Written only when missing or out of date.
  readonly property string toggleFile: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/toggles/hypr/hugorolimf-alttab.lua"
  readonly property string toggleLua: [
    "-- io.github.hugorolimf.alttab: Alt+Tab with window thumbnails. Written by the plugin;",
    "-- delete this file and run hyprctl reload to get Omarchy's own Alt+Tab back.",
    "local f = (os.getenv(\"XDG_CONFIG_HOME\") or (os.getenv(\"HOME\") .. \"/.config\")) .. \"/omarchy/plugins/io.github.hugorolimf.alttab/alttab.lua\"",
    "local h = io.open(f, \"r\")",
    "if h then h:close(); dofile(f) end"
  ].join("\n")
  Component.onCompleted: Quickshell.execDetached(["sh", "-c",
    'printf "%s\\n" "$2" | cmp -s - "$1" || { mkdir -p "$(dirname "$1")" && printf "%s\\n" "$2" > "$1" && hyprctl reload; }',
    "sh", toggleFile, toggleLua])

  property int session: 0
  property int seq: 0
  property int hiddenSession: 0
  // A select that beat its show: { s, q, i }.
  property var early: null
  property bool active: false
  property string monitorName: ""
  property int current: 0
  property var entries: []

  function show(payload) {
    var p
    try { p = JSON.parse(payload) } catch (e) { return "bad payload" }
    if (p.s <= hiddenSession || p.s < session || (p.s === session && active)) return "stale"
    var index = p.i
    var q = p.q
    if (early && early.s === p.s && early.q > q) { index = early.i; q = early.q }
    early = null
    session = p.s
    seq = q
    monitorName = p.mon || ""
    entries = (p.w || []).map(function(w) {
      return { address: String(w.a || "").replace(/^0x/, ""), appId: w.c || "", title: w.t || "", minimized: !!w.m }
    })
    current = Math.max(0, Math.min(entries.length - 1, index))
    active = entries.length > 0
    return "ok"
  }

  function select(s, q, i) {
    if (s <= hiddenSession) return "stale"
    if (s !== session || !active) {
      if (s > session && (!early || early.s !== s || early.q < q)) early = { s: s, q: q, i: i }
      return "early"
    }
    if (q <= seq) return "stale"
    seq = q
    current = Math.max(0, Math.min(entries.length - 1, i))
    return "ok"
  }

  function hide(s) {
    if (s > hiddenSession) hiddenSession = s
    if (s >= session) { active = false; entries = [] }
    return "ok"
  }

  function pick(i) {
    current = i
    Quickshell.execDetached(["hyprctl", "eval", "hugorolimf_alttab_pick(" + session + ", " + (i + 1) + ")"])
  }

  function toplevelFor(address) {
    var list = Hyprland.toplevels.values || []
    for (var i = 0; i < list.length; i++)
      if (String(list[i].address || "").replace(/^0x/, "") === address) return list[i]
    return null
  }

  function iconFor(appId) {
    var e = appId ? (DesktopEntries.heuristicLookup(appId) || DesktopEntries.byId(appId)) : null
    var tries = [e && e.icon ? e.icon : "", appId, appId.toLowerCase()]
    for (var i = 0; i < tries.length; i++) {
      if (!tries[i]) continue
      var path = Quickshell.iconPath(tries[i], true)
      if (path) return path
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  FileView {
    id: listReader
    blockLoading: true
    printErrors: false
  }

  IpcHandler {
    target: "io.github.hugorolimf.alttab"
    function show(payload: string): string { return root.show(payload) }
    // The list in a private file (alttab.lua writes it under
    // $XDG_RUNTIME_DIR/glass-alttab), so titles never sit in a command line.
    function showFile(path: string): string {
      var p = String(path || "")
      if (p !== Quickshell.env("XDG_RUNTIME_DIR") + "/glass-alttab/list.json") return "bad path"
      listReader.path = p
      var text = listReader.text()
      listReader.path = ""
      return root.show(text)
    }
    function select(s: int, q: int, i: int): string { return root.select(s, q, i) }
    function hide(s: int): string { return root.hide(s) }
    function state(): string { return root.active ? "shown " + root.session + " " + root.current + "/" + root.entries.length : "hidden" }
  }

  // One full-screen overlay per screen; only the focused monitor's shows.
  // The surface never changes size (a resizing layer surface jumps) and
  // stays mapped, transparent and click-through while hidden, so showing the
  // panel is just fading it in: no surface to create, the switch feels
  // instant. Only the panel takes the pointer.
  Variants {
    model: Quickshell.screens
    delegate: PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      readonly property var monitor: Hyprland.monitorFor(modelData)
      visible: !!monitor
      readonly property bool shown: root.active && !!monitor && monitor.name === root.monitorName
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "hugorolimf-alttab"
      WlrLayershell.layer: WlrLayer.Overlay
      // Keys stay with Hyprland (the alt-tab submap); the panel only takes clicks.
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      mask: Region { item: win.shown ? plate : nothing }
      Item { id: nothing; width: 0; height: 0 }

      // Tiles shrink when many windows would not fit on the screen.
      readonly property int count: root.entries.length
      readonly property real maxWidth: width * 0.86
      readonly property real maxHeight: height * 0.8
      readonly property int gap: 12
      readonly property int pad: 18
      readonly property var layout: {
        var n = Math.max(1, count)
        for (var w = 260; w >= 110; w -= 10) {
          var h = Math.round(w * 0.62) + 34
          var cols = Math.max(1, Math.min(n, Math.floor((maxWidth - pad * 2 + gap) / (w + gap))))
          var rows = Math.ceil(n / cols)
          if (rows * (h + gap) - gap + pad * 2 <= maxHeight || w === 110) return { w: w, h: h, cols: cols }
        }
      }

      Rectangle {
        id: plate
        anchors.centerIn: parent
        width: grid.width + win.pad * 2
        height: grid.height + win.pad * 2
        radius: 22
        color: Qt.rgba(Commons.Color.menu.background.r, Commons.Color.menu.background.g, Commons.Color.menu.background.b, 0.62)
        border.width: 1
        border.color: Qt.rgba(Commons.Color.menu.text.r, Commons.Color.menu.text.g, Commons.Color.menu.text.b, 0.18)
        opacity: win.shown ? 1 : 0
        scale: win.shown ? 1 : 0.97
        Behavior on opacity { NumberAnimation { duration: 70; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

        Grid {
          id: grid
          anchors.centerIn: parent
          columns: win.layout.cols
          spacing: win.gap

          Repeater {
            // Thumbnails exist only while the panel is up: no capture otherwise.
            model: win.shown ? root.entries : []
            delegate: Item {
              id: tile
              required property var modelData
              required property int index
              readonly property var toplevel: root.toplevelFor(modelData.address)
              readonly property bool selected: index === root.current
              readonly property string title: toplevel && toplevel.title ? toplevel.title : modelData.title
              width: win.layout.w
              height: win.layout.h

              Rectangle {
                anchors.fill: parent
                radius: 14
                color: tile.selected
                  ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.28)
                  : Qt.rgba(Commons.Color.menu.text.r, Commons.Color.menu.text.g, Commons.Color.menu.text.b, tileMouse.containsMouse ? 0.12 : 0)
                border.width: tile.selected ? 2 : 0
                border.color: Commons.Color.accent
              }

              // Thumbnail area: the live window, or its icon until a frame arrives.
              Item {
                id: shot
                anchors { top: parent.top; left: parent.left; right: parent.right; margins: 8 }
                height: parent.height - 34 - 8
                opacity: tile.modelData.minimized ? 0.55 : 1

                ScreencopyView {
                  id: view
                  readonly property real aspect: sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 16 / 10
                  anchors.centerIn: parent
                  width: Math.min(parent.width, parent.height * aspect)
                  height: Math.min(parent.height, parent.width / aspect)
                  captureSource: tile.toplevel ? tile.toplevel.wayland : null
                  live: true
                  paintCursor: false
                  constraintSize: Qt.size(width * 2, height * 2)
                  visible: hasContent
                  layer.enabled: true
                  layer.smooth: true
                }

                Image {
                  anchors.centerIn: parent
                  visible: !view.hasContent
                  width: Math.min(parent.width, parent.height) * 0.5
                  height: width
                  sourceSize: Qt.size(width * 2, height * 2)
                  source: root.iconFor(tile.modelData.appId)
                  smooth: true
                  asynchronous: true
                }
              }

              // Minimized windows: a small hollow badge, like the dock's dot.
              Rectangle {
                visible: tile.modelData.minimized
                anchors { right: shot.right; bottom: shot.bottom; margins: 4 }
                width: minLabel.implicitWidth + 12
                height: 18
                radius: 9
                color: Qt.rgba(Commons.Color.menu.background.r, Commons.Color.menu.background.g, Commons.Color.menu.background.b, 0.85)
                border.width: 1
                border.color: Qt.rgba(Commons.Color.menu.text.r, Commons.Color.menu.text.g, Commons.Color.menu.text.b, 0.3)
                Text {
                  id: minLabel
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: Qt.locale().name.indexOf("pt") === 0 ? "minimizada" : "minimized"
                  color: Commons.Color.menu.text
                  opacity: 0.8
                  font.pixelSize: 10
                }
              }

              Row {
                anchors { bottom: parent.bottom; bottomMargin: 8; horizontalCenter: parent.horizontalCenter }
                width: Math.min(implicitWidth, parent.width - 16)
                spacing: 6
                Image {
                  id: appIcon
                  width: 18; height: 18
                  anchors.verticalCenter: parent.verticalCenter
                  sourceSize: Qt.size(36, 36)
                  source: root.iconFor(tile.modelData.appId)
                  smooth: true
                  asynchronous: true
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, tile.width - 16 - appIcon.width - 6)
                  text: tile.title || tile.modelData.appId
                  color: Commons.Color.menu.text
                  font.pixelSize: 12
                  font.bold: tile.selected
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: tileMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.pick(tile.index)
              }
            }
          }
        }
      }
    }
  }

  function open(payloadJson) {}
  function close() {}
}
