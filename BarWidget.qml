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
  // it here clears the badge without waiting for the next poll.
  property var seenMap: ({})

  readonly property var conversations: Model.sortConversations(
    Model.applyLocalRead(counts ? counts.conversations : [], seenMap))
  readonly property int mentionCount: Model.mentionCount(conversations)
  readonly property int unreadChannels: Model.unreadChannelCount(conversations)

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(raw) {
    var data = Model.parseJson(raw)
    hasToken = !!(data.ok && data.has_token && data.valid)
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

  Process {
    id: countsProc
    command: Model.countsCommand(root.scriptDir, true)
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
    tooltipText: root.hasToken ? "" : "Slack — click to sign in"

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
