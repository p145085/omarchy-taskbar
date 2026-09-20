import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Open-windows taskbar, filtered to the monitor this bar instance lives on.
// Hyprland has no native minimize, so "minimizing" a window here means
// parking it on a dedicated hidden special workspace (special:taskbardock);
// clicking its entry again brings it back to whichever workspace is
// currently focused and refocuses it. Window data comes from
// Hyprland.workspaces[].toplevels rather than the generic Wayland
// ToplevelManager because dispatching hl.dsp.window.move/close needs each
// window's Hyprland address (only the Hyprland-specific toplevel exposes it,
// via lastIpcObject), and because the generic Wayland ToplevelManager
// singleton is not reachable from a third-party plugin's QML context.
BarWidget {
  id: root
  moduleName: "emila.taskbar"

  readonly property string minimizedWorkspaceName: "special:taskbardock"
  readonly property int maxItemWidth: Number(setting("maxItemWidth", 170))
  readonly property int minItemWidth: 64
  readonly property int iconOnlyThreshold: 64
  // The bar does no space-negotiation between sections (see availableWidth
  // below), so this is a guess at how much room the center section's other
  // modules (indicators, clock, weather, ...) need beyond the clock's own
  // half-width. Tune via the "centerMargin" widget setting if your center
  // section is wider/narrower than the Omarchy default.
  readonly property int safetyMargin: Number(setting("centerMargin", 200))

  // The screen this specific bar instance renders on. Third-party plugins
  // don't get a service handle for "which monitor am I", but QsWindow is a
  // plain QtQuick attached property available on any Item in the window's
  // tree, not a scoped facade, so it stays reachable here.
  readonly property var myScreen: root.QsWindow && root.QsWindow.window ? root.QsWindow.window.screen : null
  readonly property var myMonitor: root.myScreen ? Hyprland.monitorFor(root.myScreen) : null
  readonly property int myMonitorId: root.myMonitor ? root.myMonitor.id : -1

  function allToplevels() {
    var out = []
    var wss = Hyprland.workspaces.values
    for (var i = 0; i < wss.length; i++) {
      var tls = wss[i].toplevels.values
      for (var j = 0; j < tls.length; j++) {
        var t = tls[j]
        var mon = t.lastIpcObject ? t.lastIpcObject.monitor : undefined
        // Only filter once we actually know our own monitor id; otherwise
        // fall back to showing everything rather than showing nothing.
        if (root.myMonitorId !== -1 && typeof mon === "number" && mon !== root.myMonitorId) continue
        out.push(t)
      }
    }
    out.sort(function(a, b) {
      var wa = (a.lastIpcObject && a.lastIpcObject.workspace) ? a.lastIpcObject.workspace.id : 0
      var wb = (b.lastIpcObject && b.lastIpcObject.workspace) ? b.lastIpcObject.workspace.id : 0
      if (wa !== wb) return wa - wb
      return String(a.title || "").localeCompare(String(b.title || ""))
    })
    return out
  }

  readonly property var toplevels: allToplevels()

  function labelFor(t) {
    var title = String(t.title || "").trim()
    if (title !== "") return title
    return (t.lastIpcObject && t.lastIpcObject.class) ? t.lastIpcObject.class : ""
  }

  function classFor(t) {
    return t.lastIpcObject ? String(t.lastIpcObject.class || "") : ""
  }

  // Best-effort: the window's wm class usually matches its icon-theme name
  // (firefox, steam, foot, ...). Apps with no theme match (PWAs, some
  // Electron/Java apps) fall back to a generic icon rather than nothing.
  function iconFor(t) {
    var cls = root.classFor(t)
    if (cls === "") return Quickshell.iconPath("application-x-executable")
    return Quickshell.iconPath(cls, "application-x-executable")
  }

  function addressSelector(t) {
    var addr = t.lastIpcObject ? t.lastIpcObject.address : ""
    return "address:" + addr
  }

  function isMinimized(t) {
    return !!(t.lastIpcObject && t.lastIpcObject.workspace && t.lastIpcObject.workspace.name === root.minimizedWorkspaceName)
  }

  function isFocused(t) {
    return !!(t.lastIpcObject && t.lastIpcObject.focusHistoryID === 0) && !root.isMinimized(t)
  }

  function dispatch(luaCall) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote(luaCall))
    refreshTimer.restart()
  }

  function focusWindow(t) {
    root.dispatch("hl.dsp.focus({ window = \"" + root.addressSelector(t) + "\" })")
  }

  function minimizeWindow(t) {
    root.dispatch("hl.dsp.window.move({ window = \"" + root.addressSelector(t) + "\", workspace = \"" + root.minimizedWorkspaceName + "\", silent = true })")
  }

  function restoreWindow(t) {
    var targetWs = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1
    var sel = root.addressSelector(t)
    root.dispatch("hl.dsp.window.move({ window = \"" + sel + "\", workspace = \"" + targetWs + "\", silent = true })")
    root.dispatch("hl.dsp.focus({ window = \"" + sel + "\" })")
  }

  function closeWindow(t) {
    root.dispatch("hl.dsp.window.close({ window = \"" + root.addressSelector(t) + "\" })")
  }

  function pressEntry(t) {
    if (root.isMinimized(t)) root.restoreWindow(t)
    else if (root.isFocused(t)) root.minimizeWindow(t)
    else root.focusWindow(t)
  }

  // Hyprland's event-driven models pick up most changes on their own, but a
  // dispatch this widget just issued can land a beat late; nudge a refresh
  // shortly after so the just-clicked entry doesn't look stale.
  Timer {
    id: refreshTimer
    interval: 200
    onTriggered: Hyprland.refreshWorkspaces()
  }

  // There's no bar API for "how much space is left before the next
  // section" (the bar doesn't do space negotiation between widgets at all),
  // so this polls its own absolute position each tick and clamps itself to
  // never cross the screen's true midpoint - which is where a center-
  // anchored module (the clock) is centered around. Cheap, and layout only
  // actually moves on resize/bar-config changes, not every frame.
  property real absoluteX: 0
  property real absoluteY: 0

  function syncPosition() {
    if (!root.QsWindow || !root.QsWindow.window || !root.QsWindow.window.contentItem) return
    var p = root.mapToItem(root.QsWindow.window.contentItem, 0, 0)
    if (!p) return
    root.absoluteX = p.x
    root.absoluteY = p.y
  }

  Timer {
    interval: 500
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.syncPosition()
  }

  readonly property real windowWidth: root.QsWindow && root.QsWindow.window ? root.QsWindow.window.width : 0
  readonly property real windowHeight: root.QsWindow && root.QsWindow.window ? root.QsWindow.window.height : 0

  readonly property real availableWidth: root.windowWidth > 0
    ? Math.max(root.barSize, root.windowWidth / 2 - root.absoluteX - root.safetyMargin)
    : 100000
  readonly property real availableHeight: root.windowHeight > 0
    ? Math.max(root.barSize, root.windowHeight / 2 - root.absoluteY - root.safetyMargin)
    : 100000

  readonly property int visibleCount: toplevels.length
  // Once there isn't even room for a shrunk label per window, the whole row
  // collapses to a compact icon strip instead of showing a handful of
  // half-legible slivers of text.
  readonly property bool iconOnlyMode: root.visibleCount > 0 && (root.availableWidth / root.visibleCount) < root.iconOnlyThreshold
  readonly property real perItemWidth: root.iconOnlyMode
    ? root.barSize
    : (visibleCount > 0 ? Math.max(root.minItemWidth, Math.min(root.maxItemWidth, root.availableWidth / visibleCount)) : root.minItemWidth)

  visible: toplevels.length > 0
  implicitWidth: root.vertical ? barSize : Math.min(itemsRow.implicitWidth, root.availableWidth)
  implicitHeight: root.vertical ? Math.min(itemsCol.implicitHeight, root.availableHeight) : barSize
  clip: true

  // --- Hover preview -------------------------------------------------
  // Shared by every entry (only one can be hovered at a time): a short
  // delay before the first capture avoids firing grim while the cursor is
  // just passing through, then it re-captures on an interval for a
  // semi-live feel while the popup stays open. Geometry-based (grim -g
  // using the window's own on-screen rect) rather than a toplevel-handle
  // capture: grim's -T wants a wlr-foreign-toplevel-management identifier
  // that doesn't correspond to Hyprland's own client address, and nothing
  // in the Hyprland or Wayland QML modules surfaces that id.
  property var hoveredItem: null
  property var hoveredEntry: null
  property bool previewValid: false
  property int previewToken: 0

  function previewFilePath(t) {
    var addr = t && t.lastIpcObject ? String(t.lastIpcObject.address || "") : ""
    return "/tmp/omarchy-taskbar-preview-" + addr.replace(/[^a-zA-Z0-9]/g, "") + ".png"
  }

  function capturePreview() {
    var t = root.hoveredEntry
    if (!t || root.isMinimized(t)) { root.previewValid = false; return }
    var ipc = t.lastIpcObject
    if (!ipc || !ipc.at || !ipc.size) { root.previewValid = false; return }
    var geom = ipc.at[0] + "," + ipc.at[1] + " " + ipc.size[0] + "x" + ipc.size[1]
    previewProcess.command = ["grim", "-g", geom, root.previewFilePath(t)]
    previewProcess.running = true
  }

  function startHover(item, t) {
    root.hoveredItem = item
    root.hoveredEntry = t
    root.previewValid = false
    hoverDelay.restart()
  }

  function endHover(item) {
    if (root.hoveredItem !== item) return
    hoverDelay.stop()
    previewRefresh.stop()
    root.hoveredItem = null
    root.hoveredEntry = null
    root.previewValid = false
  }

  Timer {
    id: hoverDelay
    interval: 350
    onTriggered: { root.capturePreview(); previewRefresh.start() }
  }

  Timer {
    id: previewRefresh
    interval: 1200
    repeat: true
    onTriggered: root.capturePreview()
  }

  Process {
    id: previewProcess
    onExited: function(exitCode) {
      root.previewValid = exitCode === 0
      root.previewToken += 1
    }
  }

  // A plain PopupCard would work visually, but it also calls
  // bar.requestPopout(), which marks the *whole taskbar module slot* as
  // having an open panel. The bar's open-panel indicator then centers
  // itself under that entire slot (all entries combined) rather than under
  // whichever single entry is actually hovered - on a multi-entry widget
  // like this one that draws an orange mark straddling two entries instead
  // of sitting under the hovered one. This is PopupCard's own anchoring
  // logic copied in without the requestPopout/releasePopout call, so hover
  // never touches the bar's single-active-popout coordinator.
  PopupWindow {
    id: previewPopup

    property Item anchorItem: root.hoveredItem
    property QtObject bar: root.bar
    property int margin: Style.gapsOut
    property int padding: Style.spacing.popupPadding
    property int contentWidth: Style.space(240)
    property int contentHeight: Style.space(220)
    property bool open: root.hoveredItem !== null
    property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))

    visible: open || previewCard.opacity > 0
    color: "transparent"
    implicitWidth: contentWidth
    implicitHeight: contentHeight

    anchor {
      id: previewAnchor
      window: previewPopup.anchorItem ? previewPopup.anchorItem.QsWindow.window : null
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1

      onAnchoring: {
        if (!previewPopup.anchorItem || !previewPopup.bar) return

        var target = previewPopup.anchorItem
        var popupWidth = previewPopup.implicitWidth
        var popupHeight = previewPopup.implicitHeight
        var localX = target.width / 2 - popupWidth / 2
        var localY = target.height + previewPopup.margin

        if (previewPopup.bar.position === "bottom") {
          localY = -popupHeight - previewPopup.margin
        } else if (previewPopup.bar.position === "left") {
          localX = target.width + previewPopup.margin
          localY = target.height / 2 - popupHeight / 2
        } else if (previewPopup.bar.position === "right") {
          localX = -popupWidth - previewPopup.margin
          localY = target.height / 2 - popupHeight / 2
        }

        var window = target.QsWindow.window
        if (!window) return

        var point = window.contentItem.mapFromItem(target, localX, localY)

        if (previewPopup.bar.position === "top" || previewPopup.bar.position === "bottom") {
          point.x = Math.max(previewPopup.margin, Math.min(point.x, window.width - popupWidth - previewPopup.margin))
        } else {
          point.y = Math.max(previewPopup.margin, Math.min(point.y, window.height - popupHeight - previewPopup.margin))
        }

        previewAnchor.rect.x = Math.round(point.x)
        previewAnchor.rect.y = Math.round(point.y)
      }
    }

    BorderSurface {
      id: previewCard
      anchors.fill: parent
      color: Color.popups.background
      borderSpec: previewPopup.borderSpec
      padding: previewPopup.padding
      radius: Style.cornerRadius
      opacity: previewPopup.open ? 1.0 : 0

      Behavior on opacity {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }

      Item {
        id: previewContentHolder
        anchors.fill: parent
        anchors.topMargin: previewCard.contentTopInset
        anchors.rightMargin: previewCard.contentRightInset
        anchors.bottomMargin: previewCard.contentBottomInset
        anchors.leftMargin: previewCard.contentLeftInset

        Column {
          id: previewColumn
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.hoveredEntry ? root.labelFor(root.hoveredEntry) : ""
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Image {
            width: parent.width
            height: Style.space(150)
            fillMode: Image.PreserveAspectFit
            visible: root.previewValid
            cache: false
            asynchronous: true
            source: root.previewValid && root.hoveredEntry ? ("file://" + root.previewFilePath(root.hoveredEntry) + "?t=" + root.previewToken) : ""
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.previewValid
            width: parent.width
            text: root.hoveredEntry && root.isMinimized(root.hoveredEntry) ? "Minimized" : "No preview available"
            color: Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }
        }
      }
    }
  }

  Row {
    id: itemsRow
    visible: !root.vertical
    anchors.fill: parent
    spacing: Style.space(2)

    Repeater {
      model: root.toplevels

      Item {
        id: entry
        required property var modelData

        readonly property string label: root.labelFor(modelData)
        readonly property bool focused: root.isFocused(modelData)
        readonly property bool minimizedState: root.isMinimized(modelData)
        readonly property string iconSrc: root.iconFor(modelData)

        width: root.perItemWidth
        height: root.barSize
        clip: true

        Rectangle {
          anchors.fill: parent
          radius: Math.max(2, Style.cornerRadius)
          color: entry.focused ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
        }

        Image {
          id: entryIcon
          readonly property real size: root.iconOnlyMode ? Style.space(18) : Style.space(15)
          width: size
          height: size
          anchors.verticalCenter: parent.verticalCenter
          x: root.iconOnlyMode ? (parent.width - width) / 2 : Style.space(6)
          visible: entry.iconSrc !== ""
          source: entry.iconSrc
          sourceSize.width: width * Screen.devicePixelRatio
          sourceSize.height: height * Screen.devicePixelRatio
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          opacity: entry.minimizedState ? 0.4 : (entry.focused ? 1 : 0.75)
        }

        Text {
          id: entryText
          textFormat: Text.PlainText
          visible: !root.iconOnlyMode
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: entryIcon.right
          anchors.right: parent.right
          anchors.leftMargin: Style.space(5)
          anchors.rightMargin: Style.space(8)
          text: entry.label
          color: root.bar ? root.bar.barForeground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          opacity: entry.minimizedState ? 0.4 : (entry.focused ? 1 : 0.75)
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: function(mouse) {
            if (mouse.button === Qt.MiddleButton || mouse.button === Qt.RightButton) {
              root.closeWindow(entry.modelData)
            } else {
              root.pressEntry(entry.modelData)
            }
          }
          onEntered: {
            if (root.bar) root.bar.showTooltip(entry, entry.label)
            root.startHover(entry, entry.modelData)
          }
          onExited: {
            if (root.bar) root.bar.hideTooltip(entry)
            root.endHover(entry)
          }
        }
      }
    }
  }

  Column {
    id: itemsCol
    visible: root.vertical
    anchors.fill: parent
    spacing: Style.space(2)

    Repeater {
      model: root.toplevels

      Item {
        id: ventry
        required property var modelData

        readonly property string label: root.labelFor(modelData)
        readonly property bool focused: root.isFocused(modelData)
        readonly property bool minimizedState: root.isMinimized(modelData)
        readonly property string iconSrc: root.iconFor(modelData)

        width: root.barSize
        height: root.barSize
        clip: true

        Rectangle {
          anchors.fill: parent
          radius: Math.max(2, Style.cornerRadius)
          color: ventry.focused ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
        }

        Image {
          anchors.centerIn: parent
          width: Style.space(18)
          height: Style.space(18)
          visible: ventry.iconSrc !== ""
          source: ventry.iconSrc
          sourceSize.width: width * Screen.devicePixelRatio
          sourceSize.height: height * Screen.devicePixelRatio
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          opacity: ventry.minimizedState ? 0.4 : (ventry.focused ? 1 : 0.75)
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: function(mouse) {
            if (mouse.button === Qt.MiddleButton || mouse.button === Qt.RightButton) {
              root.closeWindow(ventry.modelData)
            } else {
              root.pressEntry(ventry.modelData)
            }
          }
          onEntered: {
            if (root.bar) root.bar.showTooltip(ventry, ventry.label)
            root.startHover(ventry, ventry.modelData)
          }
          onExited: {
            if (root.bar) root.bar.hideTooltip(ventry)
            root.endHover(ventry)
          }
        }
      }
    }
  }
}
