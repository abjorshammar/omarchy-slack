import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "bottelet.slack"

  readonly property string scriptDir: Qt.resolvedUrl("scripts/").toString().replace("file://", "")
  readonly property string seenPath: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy-slack/seen.json"
  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 3), 10) || 3)

  property bool hasToken: false
  property var counts: null

  // Live read markers: the full app writes seen.json as you read; applying
  // it here clears the badge without waiting for the next poll. One file
  // covers every workspace (keys are "<team>/<channel>"), so this stays a
  // single watcher.
  property var seenMap: ({})

  // The badge is the whole point of signing in to more than one workspace:
  // it counts unread DMs everywhere, so a message in a workspace you are not
  // currently looking at still reaches you.
  readonly property var workspaces: Model.workspaceSummaries(
    counts ? { workspaces: counts.workspaces, seen: seenMap } : null)
  readonly property int mentionCount: Model.totalMentions(workspaces)
  readonly property int unreadChannels: Model.totalUnreadChannels(workspaces)

  // Which workspaces the waiting DMs are in, when there is more than one.
  readonly property string mentionBreakdown: {
    if (workspaces.length < 2) return ""
    var parts = []
    for (var i = 0; i < workspaces.length; i++) {
      var w = workspaces[i]
      if (w.mentions > 0) parts.push(w.team + " " + w.mentions)
      else if (!w.ok) parts.push(w.team + " — " + w.error)
    }
    return parts.join("  ·  ")
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(raw) {
    var data = Model.parseJson(raw)
    // A workspace whose token has gone bad is reported per workspace by
    // counts-all, so poll as long as any workspace is signed in at all.
    hasToken = !!(data.ok && data.has_token)
    if (hasToken && !countsProc.running) countsProc.running = true
  }

  function applyCounts(raw) {
    var data = Model.parseJson(raw)
    if (!data.ok) return
    counts = data
    if (data.seen) seenMap = data.seen
    Qt.callLater(function() { seenView.reload() })
  }

  function toggleApp() {
    // The app panel is a separate entry point; the shell owns its lifecycle.
    root.bar.run("omarchy-shell shell toggle bottelet.slack")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: Model.statusCommand(root.scriptDir)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    Component.onCompleted: running = true
  }

  // First paint: the last poll's payload off disk, so a freshly started bar
  // shows the badge it had rather than nothing until its own fetch returns.
  Process {
    id: cachedCountsProc
    command: Model.countsCachedCommand(root.scriptDir)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.counts) root.applyCounts(text)
    }
    Component.onCompleted: running = true
  }

  Process {
    id: countsProc
    command: Model.countsAllCommand(root.scriptDir, true)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCounts(text)
    }
  }

  Timer {
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // seen.json is written by the app panel as conversations are read.
  FileView {
    id: seenView
    path: root.seenPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var data = Model.parseJson(text())
      if (data && data.ok === undefined) root.seenMap = data
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "" // nf-fa-slack
    slotSize: Style.bar.statusSlot
    active: root.mentionCount > 0 || root.unreadChannels > 0
    useActiveColor: true
    activeColor: root.mentionCount > 0 ? Color.urgent : Color.accent
    tooltipText: root.hasToken ? root.mentionBreakdown : "Slack — click to sign in"

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggleApp()
    }
  }

  // Mention badge: unread DMs and group DMs — every one is aimed at you.
  Rectangle {
    visible: root.mentionCount > 0
    width: Math.max(height, badgeText.implicitWidth + Style.space(4))
    height: Style.space(11)
    radius: height / 2
    color: Color.urgent
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(1)

    Text {
      id: badgeText
      anchors.centerIn: parent
      text: root.mentionCount > 99 ? "99+" : root.mentionCount
      textFormat: Text.PlainText
      color: Color.background
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Math.max(8, Style.font.caption - 2)
      font.bold: true
    }
  }
}
