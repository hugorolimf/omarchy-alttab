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
//   omarchy-shell io.github.hugorolimf.alttab show '<json>'   {s, q, i, mon, cur, w: [{a, c, t, m, ws, wn}]}
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
  // The workspace on screen when the switch began.
  property int currentWs: 0

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
    currentWs = p.cur || 0
    entries = (p.w || []).map(function(w) {
      return { address: String(w.a || "").replace(/^0x/, ""), appId: w.c || "", title: w.t || "", minimized: !!w.m,
        ws: typeof w.ws === "number" ? w.ws : 0, wsName: String(w.wn || "") }
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

  readonly property bool pt: Qt.locale().name.indexOf("pt") === 0
  function tr(ptText, enText) { return pt ? ptText : enText }

  // The look follows anatomy: grey hairlines, mono labels, colour only for a
  // state, written out next to it. Greys come from the theme's menu colours.
  readonly property color ink: Commons.Color.menu.text
  readonly property color paper: Commons.Color.menu.background
  function ink_(a) { return Qt.rgba(ink.r, ink.g, ink.b, a) }
  readonly property string sans: "Adwaita Sans"
  readonly property string mono: "JetBrainsMono Nerd Font"
  readonly property color working: "#6b9bff"

  // Claude Code puts a glyph in front of the session name in the window
  // title: a spinning one while the model writes, a star otherwise (also
  // while a tool runs, so the star says nothing for sure). The glyph goes;
  // only "working" is written under the name.
  function agentState(title) {
    var m = /^([✳✻✽✶✢◐-◓⠀-⣿])\s+/.exec(String(title || ""))
    if (!m) return ""
    return "✳✻✽✶✢".indexOf(m[1]) >= 0 ? "idle" : "working"
  }
  function cleanTitle(title) {
    var t = String(title || "")
    return agentState(t) ? t.replace(/^\S+\s+/, "") : t
  }
  readonly property var terminals: ["foot", "kitty", "alacritty", "ghostty", "wezterm", "org.wezfurlong.wezterm", "xterm", "com.mitchellh.ghostty"]
  function appLabel(appId) {
    var id = String(appId || "")
    if (terminals.indexOf(id.toLowerCase()) >= 0) return "Terminal"
    var e = id ? (DesktopEntries.heuristicLookup(id) || DesktopEntries.byId(id)) : null
    return e && e.name ? e.name : id
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
      // Match on the screen's own output name: Hyprland.monitorFor() is read
      // once and is still null for a screen that reappears (e.g. the laptop
      // panel after undocking), which left that screen without an overlay.
      readonly property bool shown: root.active && modelData.name === root.monitorName
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "hugorolimf-alttab"
      WlrLayershell.layer: WlrLayer.Overlay
      // Keys stay with Hyprland (the alt-tab submap); the panel only takes clicks.
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      mask: Region { item: win.shown ? plate : nothing }
      // Liquid Glass (mask_mode "alpha_region") only works inside this box:
      // the panel while it shows or fades out, nothing while hidden, so the
      // full-screen surface costs no glass at rest. 2 px of slack keep the
      // panel's antialiased edge (centered, often on a half pixel) inside it.
      BackgroundEffect.blurRegion: Region {
        readonly property bool on: win.shown || plate.opacity > 0
        x: on ? plate.x - 2 : 0
        y: on ? plate.y - 2 : 0
        width: on ? plate.width + 4 : 0
        height: on ? plate.height + 4 : 0
      }
      Item { id: nothing; width: 0; height: 0 }

      // Tiles shrink when many windows would not fit on the screen. A tile is
      // the thumbnail (16:10) plus two lines of text under it, in rows by
      // recent use (Tile.qml).
      readonly property int count: root.entries.length
      readonly property real maxWidth: width * 0.86
      readonly property real maxHeight: height * 0.8
      readonly property int gap: 8
      readonly property int pad: 14
      readonly property int head: 30
      readonly property int textBlock: 44
      readonly property var layout: {
        var room = maxWidth - pad * 2
        for (var w = 260; w >= 120; w -= 10) {
          var thumb = Math.round((w - 12) * 0.625)
          var h = 6 + thumb + textBlock
          var cols = Math.max(1, Math.min(count, Math.floor((room + gap) / (w + gap))))
          var height = Math.ceil(count / cols) * (h + gap) - gap
          if (height + pad * 2 + head <= maxHeight || w === 120)
            return { w: w, h: h, thumb: thumb, cols: cols, width: cols * (w + gap) - gap, height: Math.max(0, height) }
        }
      }

      Rectangle {
        id: plate
        anchors.centerIn: parent
        width: grid.width + win.pad * 2
        height: win.head + grid.height + win.pad * 2
        radius: 18
        color: Qt.rgba(root.paper.r, root.paper.g, root.paper.b, 0.8)
        border.width: 1
        border.color: root.ink_(0.12)
        opacity: win.shown ? 1 : 0
        scale: win.shown ? 1 : 0.98
        Behavior on opacity { NumberAnimation { duration: 90; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.32, 0.72, 0, 1, 1, 1] } }
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.32, 0.72, 0, 1, 1, 1] } }

        // Header: how many windows, and the keys that work while switching.
        Text {
          id: countLabel
          x: win.pad + 6
          y: win.pad - 2
          height: 18
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: root.tr("JANELAS", "WINDOWS") + " · " + win.count
          color: root.ink_(0.5)
          font.family: root.mono
          font.pixelSize: 10
          font.letterSpacing: 0.9
        }
        Row {
          id: hints
          anchors { right: parent.right; rightMargin: win.pad + 6 }
          y: win.pad - 2
          height: 18
          spacing: 12
          visible: grid.width > countLabel.implicitWidth + implicitWidth + 40
          Repeater {
            model: [["TAB", root.tr("PRÓXIMA", "NEXT")], ["⇧ TAB", root.tr("ANTERIOR", "BACK")], ["ESC", root.tr("CANCELA", "CANCEL")]]
            delegate: Row {
              required property var modelData
              spacing: 5
              anchors.verticalCenter: parent.verticalCenter
              Rectangle {
                width: key.implicitWidth + 8
                height: 15
                radius: 4
                color: "transparent"
                border.width: 1
                border.color: root.ink_(0.16)
                Text {
                  id: key
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: modelData[0]
                  color: root.ink_(0.62)
                  font.family: root.mono
                  font.pixelSize: 9
                }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: modelData[1]
                color: root.ink_(0.42)
                font.family: root.mono
                font.pixelSize: 10
                font.letterSpacing: 0.8
              }
            }
          }
        }
        Rectangle {
          x: win.pad; y: win.pad + win.head - 12
          width: parent.width - win.pad * 2; height: 1
          color: root.ink_(0.07)
        }

        Item {
          id: grid
          x: win.pad
          y: win.pad + win.head - 4
          width: win.layout.width
          height: win.layout.height

          Repeater {
            // Thumbnails exist only while the panel is up: no capture otherwise.
            model: win.shown ? root.entries.length : 0
            delegate: Tile {
              required property int index
              app: root
              gi: index
              thumb: win.layout.thumb
              x: (index % win.layout.cols) * (win.layout.w + win.gap)
              y: Math.floor(index / win.layout.cols) * (win.layout.h + win.gap)
              width: win.layout.w
              height: win.layout.h
            }
          }
        }
      }
    }
  }

  function open(payloadJson) {}
  function close() {}
}
