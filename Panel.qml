import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Omarchy Slack app: a movable, resizable FloatingWindow (kind: panel,
// the same model as the Spotify plugin) with a conversation sidebar and a
// message pane, in the shell's menu surface style.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  readonly property color dim: Qt.darker(foreground, 1.5)
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int sidebarWidth: Style.space(250)

  readonly property string scriptDir: Qt.resolvedUrl("scripts/").toString().replace("file://", "")

  // ---------------------------------------------------------------- state

  // tokenState: unknown | none | invalid | valid
  property string tokenState: "unknown"
  property string teamName: ""
  property string selfName: ""
  property string selfId: ""

  property var counts: null
  property string countsError: ""
  property var seenMap: ({})

  property bool loginAvailable: false
  property bool loginBusy: false
  property string loginFeedback: ""
  property bool showTokenEntry: false
  property bool tokenBusy: false

  readonly property var conversations: Model.sortConversations(
    Model.applyLocalRead(counts ? counts.conversations : [], seenMap))
  readonly property var visibleConversations: Model.filterConversations(conversations, filterField.text)
  readonly property var dmRows: visibleConversations.filter(function(c) { return c.kind === "im" || c.kind === "mpim" })
  readonly property var channelRows: visibleConversations.filter(function(c) { return c.kind !== "im" && c.kind !== "mpim" })
  readonly property var flatRows: dmRows.concat(channelRows)

  readonly property string presence: counts && counts.presence ? counts.presence : ""
  readonly property bool snoozing: counts ? counts.snoozing === true : false
  readonly property string snoozeUntil: counts ? Model.snoozeLabel(counts.snooze_until) : ""

  property var convo: null
  property var messages: []
  property string historyNote: ""
  property string historyError: ""
  property bool historyLoading: false

  property bool sending: false
  property string sendError: ""
  property bool settingsMode: false
  property string tokenFeedback: ""

  // ------------------------------------------------------ overlay contract

  function open(payloadJson) {
    root.opened = true
    refreshAll()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "bottelet.slack")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ------------------------------------------------------------- plumbing

  function refreshAll() {
    if (!statusProc.running) statusProc.running = true
    if (!loginAvailProc.running) loginAvailProc.running = true
  }

  function applyStatus(raw) {
    var data = Model.parseJson(raw)
    if (!data.ok || !data.has_token) {
      tokenState = "none"
      return
    }
    if (data.valid) {
      tokenState = "valid"
      teamName = String(data.team || "")
      selfName = String(data.user || "")
      if (!countsProc.running) countsProc.running = true
    } else {
      tokenState = String(data.error || "") === "network" ? "unknown" : "invalid"
    }
  }

  function applyCounts(raw) {
    var data = Model.parseJson(raw)
    if (!data.ok) {
      var e = String(data.error || "")
      if (e === "invalid_auth" || e === "token_revoked" || e === "token_expired" || e === "account_inactive")
        tokenState = "invalid"
      if (e === "no token") tokenState = "none"
      countsError = Model.friendlyError(e)
      return
    }
    counts = data
    countsError = ""
    selfId = String(data.self_id || "")
    if (data.team) teamName = String(data.team)
    if (data.seen) seenMap = data.seen
  }

  function applyHistory(raw) {
    historyLoading = false
    var data = Model.parseJson(raw)
    // A fetch started for one conversation may land after the user switched
    // to another — drop it instead of rendering (and marking read) wrongly.
    if (!convo || (data.channel && data.channel !== convo.id)) return
    if (!data.ok) {
      historyError = Model.friendlyError(data.error)
      return
    }
    historyError = ""
    historyNote = data.ratelimited
      ? "rate limited — showing cached messages"
      : (data.cached ? "cached · Slack allows one refresh per minute" : "")
    messages = Model.buildMessages(data, selfId)
    var ts = Model.lastTs(data)
    if (convo && ts !== "") markSeen(convo.id, ts)
    scrollToBottom()
  }

  function scrollToBottom() {
    Qt.callLater(function() {
      messageScroll.contentY = Math.max(0, messageScroll.contentHeight - messageScroll.height)
    })
  }

  // Records the read marker (shared with the bar badge via seen.json) and
  // best-effort syncs other Slack clients via conversations.mark.
  function markSeen(id, ts) {
    var map = {}
    for (var k in seenMap) map[k] = seenMap[k]
    if (!map[id] || parseFloat(map[id]) < parseFloat(ts)) map[id] = String(ts)
    seenMap = map
    seenProc.cmd = Model.seenCommand(scriptDir, id, ts)
    seenProc.running = true
  }

  function openConvo(c) {
    settingsMode = false
    convo = { id: c.id, name: Model.displayName(c), kind: c.kind }
    messages = []
    historyError = ""
    historyNote = ""
    sendError = ""
    historyLoading = true
    composeField.text = ""
    if (historyProc.running) historyProc.running = false
    historyProc.cmd = Model.historyCommand(scriptDir, convo.id)
    historyProc.running = true
    Qt.callLater(function() { composeField.forceActiveFocus() })
  }

  function refreshHistory() {
    if (!convo || historyProc.running) return
    historyLoading = true
    historyProc.cmd = Model.historyCommand(scriptDir, convo.id)
    historyProc.running = true
  }

  function sendMessage() {
    var text = composeField.text
    if (!convo || sending || String(text).replace(/\s+/g, "") === "") return
    sending = true
    sendError = ""
    // Snapshot the destination now — a live binding could re-resolve to a
    // different conversation between here and process start.
    sendProc.cmd = Model.sendCommand(scriptDir, convo.id)
    sendProc.pendingText = String(text)
    sendProc.stdinEnabled = true
    sendProc.running = true
  }

  function sendFinished(raw) {
    sending = false
    var data = Model.parseJson(raw)
    if (!data.ok) {
      sendError = Model.friendlyError(data.error)
      return
    }
    // Append locally instead of refetching — history is 1 request/minute.
    var mine = messages.slice()
    mine.push({
      ts: String(data.ts || ""),
      name: selfName || "me",
      mine: true,
      system: false,
      time: Qt.formatTime(new Date(), "HH:mm"),
      text: Model.formatMessage(sendProc.pendingText, {})
    })
    messages = mine
    composeField.text = ""
    if (convo && data.ts) markSeen(convo.id, String(data.ts))
    scrollToBottom()
  }

  function startLogin() {
    if (loginBusy) return
    loginBusy = true
    loginFeedback = "waiting for your browser — approve Omarchy Slack there"
    loginProc.running = true
  }

  function cancelLogin() {
    loginProc.running = false
    loginBusy = false
    loginFeedback = ""
  }

  function loginFinished(raw) {
    loginBusy = false
    var data = Model.parseJson(raw)
    if (!data.ok) {
      var e = String(data.error || "")
      loginFeedback = e === "not configured"
        ? "browser sign-in isn't configured in this build — paste a token below"
        : Model.friendlyError(e)
      if (e === "not configured") showTokenEntry = true
      return
    }
    loginFeedback = ""
    tokenState = "valid"
    teamName = String(data.team || "")
    selfName = String(data.user || "")
    selfId = String(data.user_id || "")
    if (!countsProc.running) countsProc.running = true
  }

  function submitToken() {
    var t = String(tokenField.text || "").replace(/\s+/g, "")
    if (t === "" || tokenBusy) return
    tokenBusy = true
    tokenFeedback = ""
    tokenProc.pendingText = t
    tokenProc.stdinEnabled = true
    tokenProc.running = true
  }

  function tokenFinished(raw) {
    tokenBusy = false
    var data = Model.parseJson(raw)
    tokenField.text = ""
    if (!data.ok) {
      tokenFeedback = Model.friendlyError(data.error)
      return
    }
    tokenFeedback = ""
    tokenState = "valid"
    teamName = String(data.team || "")
    selfName = String(data.user || "")
    selfId = String(data.user_id || "")
    if (!countsProc.running) countsProc.running = true
  }

  function signOut() {
    actionProc.cmd = Model.clearTokenCommand(scriptDir)
    actionProc.running = true
    tokenState = "none"
    counts = null
    convo = null
    messages = []
    teamName = ""
    selfName = ""
    settingsMode = false
  }

  function togglePresence() {
    if (tokenState !== "valid") return
    actionProc.cmd = Model.presenceCommand(scriptDir, presence === "away" ? "auto" : "away")
    actionProc.running = true
  }

  function toggleSnooze() {
    if (tokenState !== "valid") return
    actionProc.cmd = snoozing ? Model.unsnoozeCommand(scriptDir) : Model.snoozeCommand(scriptDir, 60)
    actionProc.running = true
  }

  function selectStep(step) {
    var rows = flatRows
    if (rows.length === 0) return
    var at = -1
    if (convo) {
      for (var i = 0; i < rows.length; i++) if (rows[i].id === convo.id) { at = i; break }
    }
    var next = at === -1 ? (step > 0 ? 0 : rows.length - 1)
                         : Math.min(rows.length - 1, Math.max(0, at + step))
    openConvo(rows[next])
  }

  // -------------------------------------------------------------- processes

  Process {
    id: statusProc
    command: Model.statusCommand(root.scriptDir)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: loginAvailProc
    command: Model.loginAvailableCommand(root.scriptDir)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = Model.parseJson(text)
        root.loginAvailable = !!(data.ok && data.available)
      }
    }
  }

  Process {
    id: countsProc
    command: Model.countsCommand(root.scriptDir, true)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCounts(text)
    }
  }

  Process {
    id: historyProc
    property var cmd: ["true"]
    command: cmd
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyHistory(text)
    }
  }

  // Message text travels over stdin — never argv — so arbitrary user text
  // stays out of every process list and shell parser.
  Process {
    id: sendProc
    property string pendingText: ""
    property var cmd: ["true"]
    command: cmd
    stdinEnabled: true
    onStarted: {
      write(pendingText)
      stdinEnabled = false
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sendFinished(text)
    }
  }

  Process {
    id: tokenProc
    property string pendingText: ""
    command: Model.setTokenCommand(root.scriptDir)
    stdinEnabled: true
    onStarted: {
      write(pendingText)
      pendingText = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.tokenFinished(text)
    }
  }

  Process {
    id: loginProc
    command: Model.loginCommand(root.scriptDir)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loginFinished(text)
    }
  }

  Process {
    id: seenProc
    property var cmd: ["true"]
    command: cmd
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: actionProc
    property var cmd: ["true"]
    command: cmd
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (root.tokenState === "valid" && !countsProc.running) countsProc.running = true
    }
  }

  // Sidebar counts stay fresh while the app is open.
  Timer {
    interval: 90 * 1000
    running: root.opened && root.tokenState === "valid"
    repeat: true
    onTriggered: if (!countsProc.running) countsProc.running = true
  }

  // The open conversation refreshes on Slack's history cadence (1/min).
  Timer {
    interval: 65 * 1000
    running: root.opened && root.convo !== null && !root.settingsMode
    repeat: true
    onTriggered: root.refreshHistory()
  }

  // ------------------------------------------------------------------- UI

  // A real floating, movable, resizable app window — the same model the
  // Spotify plugin uses (kind: panel + FloatingWindow), not a modal overlay.
  FloatingWindow {
    id: window
    visible: root.opened
    title: "Omarchy Slack"
    color: root.background
    implicitWidth: 980
    implicitHeight: 720
    minimumSize: Qt.size(700, 560)

    // Closing the window from the compositor (title-bar close) unwinds through
    // the host the same way Escape does.
    onVisibleChanged: {
      if (!visible && root.opened) root.dismiss()
    }

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      anchors.margins: root.contentMargin
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Down
                     || (event.key === Qt.Key_J && event.modifiers === Qt.ControlModifier)) {
            root.selectStep(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up
                     || (event.key === Qt.Key_K && event.modifiers === Qt.ControlModifier)) {
            root.selectStep(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Slash) {
            filterField.forceActiveFocus()
            event.accepted = true
          }
        }

        // ========================= SIGNED OUT =========================
        Column {
          visible: root.tokenState !== "valid"
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(40), Style.space(420))
          spacing: Style.space(14)

          Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title * 2
          }

          Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Omarchy Slack"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.tokenState === "invalid"
              ? "Slack rejected the saved sign-in. Sign in again to continue."
              : "Your Slack, themed like your desktop — sign in to get started."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Rectangle {
            visible: root.loginAvailable && !root.loginBusy
            anchors.horizontalCenter: parent.horizontalCenter
            width: signInRow.implicitWidth + Style.space(28)
            height: signInRow.implicitHeight + Style.space(16)
            radius: root.cornerRadius
            color: signInArea.containsMouse ? Qt.darker(Color.accent, 1.15) : Color.accent

            Row {
              id: signInRow
              anchors.centerIn: parent
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: ""
                color: Color.background
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: "Sign in with Slack"
                color: Color.background
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              id: signInArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.startLogin()
            }
          }

          Column {
            visible: root.loginBusy
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Finishing sign-in in your browser…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              width: cancelText.implicitWidth + Style.space(20)
              height: cancelText.implicitHeight + Style.space(10)
              radius: root.cornerRadius
              color: cancelArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
              border.width: 1
              border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.45)

              Text {
                textFormat: Text.PlainText
                id: cancelText
                anchors.centerIn: parent
                text: "Cancel"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: cancelArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cancelLogin()
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.loginFeedback !== ""
            width: parent.width
            text: root.loginFeedback
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          // Advanced: paste a token instead of the browser flow.
          Text {
            textFormat: Text.PlainText
            visible: !root.showTokenEntry && !root.loginBusy
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.loginAvailable ? "advanced: paste a token instead" : "paste a token to sign in"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: tokenLinkArea.containsMouse

            MouseArea {
              id: tokenLinkArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.showTokenEntry = true
                Qt.callLater(function() { tokenField.forceActiveFocus() })
              }
            }
          }

          Column {
            visible: root.showTokenEntry && !root.loginBusy
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: tokenField
              width: parent.width
              password: true
              placeholderText: "xoxp-… (User OAuth Token — see README)"
              foreground: root.foreground
              font.family: root.fontFamily

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.submitToken()
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.tokenBusy || root.tokenFeedback !== ""
              width: parent.width
              text: root.tokenBusy ? "checking token with Slack…" : root.tokenFeedback
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        // ========================== SIGNED IN ==========================
        Row {
          visible: root.tokenState === "valid"
          anchors.fill: parent
          spacing: root.contentMargin

          // ------------------------- SIDEBAR -------------------------
          Column {
            id: sidebar
            width: root.sidebarWidth
            height: parent.height
            spacing: Style.space(10)

            Row {
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                anchors.verticalCenter: parent.verticalCenter
              }
              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  textFormat: Text.PlainText
                  text: root.teamName !== "" ? root.teamName : "Slack"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, root.sidebarWidth - Style.space(60))
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.selfName
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, root.sidebarWidth - Style.space(60))
                }
              }
            }

            // Presence + snooze + refresh + settings row.
            Row {
              spacing: Style.space(6)

              Rectangle {
                width: presenceRow.implicitWidth + Style.space(12)
                height: Style.space(22)
                radius: root.cornerRadius
                color: presenceArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.35)

                Row {
                  id: presenceRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  Rectangle {
                    width: Style.space(8)
                    height: Style.space(8)
                    radius: width / 2
                    color: root.presence === "away" ? "transparent" : Color.accent
                    border.width: 1
                    border.color: root.presence === "away" ? root.dim : Color.accent
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.presence === "away" ? "AWAY" : "ACTIVE"
                    color: root.presence === "away" ? root.dim : Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Math.max(8, Style.font.caption - 1)
                    font.bold: true
                    font.letterSpacing: 1
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  id: presenceArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.togglePresence()
                }
              }

              Rectangle {
                width: Style.space(22)
                height: Style.space(22)
                radius: root.cornerRadius
                color: snoozeArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.35)

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.snoozing ? "" : ""
                  color: root.snoozing ? Color.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: snoozeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleSnooze()
                }
              }

              Rectangle {
                width: Style.space(22)
                height: Style.space(22)
                radius: root.cornerRadius
                color: refreshArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.35)

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: refreshArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.refreshAll()
                    root.refreshHistory()
                  }
                }
              }

              Rectangle {
                width: Style.space(22)
                height: Style.space(22)
                radius: root.cornerRadius
                color: root.settingsMode || gearArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.35)

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: ""
                  color: root.settingsMode ? Color.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: gearArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.settingsMode = !root.settingsMode
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.snoozing
              width: parent.width
              text: "snoozed" + (root.snoozeUntil !== "" ? " until " + root.snoozeUntil : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: filterField
              width: parent.width
              placeholderText: "filter…  ( / )"
              foreground: root.foreground
              font.family: root.fontFamily

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  text = ""
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (root.flatRows.length > 0) root.openConvo(root.flatRows[0])
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.countsError !== ""
              width: parent.width
              text: "⚠ " + root.countsError
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Flickable {
              width: parent.width
              height: parent.height - y
              contentWidth: width
              contentHeight: convColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height

              Column {
                id: convColumn
                width: parent.width
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  visible: root.dmRows.length > 0
                  text: "DIRECT MESSAGES"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Math.max(8, Style.font.caption - 1)
                  font.bold: true
                  font.letterSpacing: 1
                  topPadding: Style.space(4)
                  bottomPadding: Style.space(2)
                }

                Repeater {
                  model: root.dmRows

                  Rectangle {
                    id: dmRow
                    required property var modelData
                    readonly property bool current: root.convo !== null && root.convo.id === modelData.id
                    width: convColumn.width
                    height: Style.space(28)
                    radius: root.cornerRadius
                    color: current ? root.selectedBackground
                         : (dmArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(8)
                      anchors.right: dmBadge.visible ? dmBadge.left : parent.right
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: "@ " + Model.displayName(dmRow.modelData)
                      color: dmRow.current ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: dmRow.modelData.effectiveUnread > 0
                      elide: Text.ElideRight
                    }

                    Rectangle {
                      id: dmBadge
                      visible: dmRow.modelData.effectiveUnread > 0
                      width: Math.max(height, dmBadgeText.implicitWidth + Style.space(8))
                      height: Style.space(15)
                      radius: height / 2
                      color: Color.urgent
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter

                      Text {
                        id: dmBadgeText
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: dmRow.modelData.effectiveUnread > 99 ? "99+" : dmRow.modelData.effectiveUnread
                        color: Color.background
                        font.family: root.fontFamily
                        font.pixelSize: Math.max(8, Style.font.caption - 1)
                        font.bold: true
                      }
                    }

                    MouseArea {
                      id: dmArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openConvo(dmRow.modelData)
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.channelRows.length > 0
                  text: "CHANNELS"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Math.max(8, Style.font.caption - 1)
                  font.bold: true
                  font.letterSpacing: 1
                  topPadding: Style.space(8)
                  bottomPadding: Style.space(2)
                }

                Repeater {
                  model: root.channelRows

                  Rectangle {
                    id: chRow
                    required property var modelData
                    readonly property bool current: root.convo !== null && root.convo.id === modelData.id
                    width: convColumn.width
                    height: Style.space(26)
                    radius: root.cornerRadius
                    color: current ? root.selectedBackground
                         : (chArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(8)
                      anchors.right: chDot.visible ? chDot.left : parent.right
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: (chRow.modelData.kind === "private" ? " " : "# ") + Model.displayName(chRow.modelData)
                      color: chRow.current ? root.selectedText
                           : (chRow.modelData.effectiveUnread > 0 ? root.foreground : root.dim)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: chRow.modelData.effectiveUnread > 0
                      elide: Text.ElideRight
                    }

                    Rectangle {
                      id: chDot
                      visible: chRow.modelData.effectiveUnread > 0
                      width: Style.space(8)
                      height: Style.space(8)
                      radius: width / 2
                      color: Color.accent
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    MouseArea {
                      id: chArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openConvo(chRow.modelData)
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.flatRows.length === 0
                  width: convColumn.width
                  topPadding: Style.space(12)
                  text: root.counts ? "nothing matches" : "loading conversations…"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  textFormat: Text.PlainText
                  visible: !!(root.counts && root.counts.capped)
                  width: convColumn.width
                  topPadding: Style.space(6)
                  text: "unreads checked for the 30 most relevant conversations"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Math.max(8, Style.font.caption - 1)
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          // Divider.
          Rectangle {
            width: 1
            height: parent.height
            color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.25)
          }

          // ------------------------ CHAT PANE ------------------------
          Column {
            width: parent.width - root.sidebarWidth - 1 - root.contentMargin * 2
            height: parent.height
            spacing: Style.space(8)

            // ----- Settings page (replaces chat) -----
            Column {
              visible: root.settingsMode
              width: parent.width
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                text: "SETTINGS"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "Signed in as " + root.selfName + (root.teamName !== "" ? " · " + root.teamName : "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "Reading here always clears the badge locally. To also mark conversations read on your phone and other Slack clients, the Slack app needs the optional write scopes (see README) — without them Slack silently keeps its own read state."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "The bar badge counts unread DMs and group DMs; channels light the icon. Unread counts poll every few minutes (omarchy bar set bottelet.slack refreshMinutes N)."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Rectangle {
                width: signOutText.implicitWidth + Style.space(20)
                height: signOutText.implicitHeight + Style.space(12)
                radius: root.cornerRadius
                color: signOutArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.urgent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.45)

                Text {
                  textFormat: Text.PlainText
                  id: signOutText
                  anchors.centerIn: parent
                  text: "  Sign out & forget token"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: signOutArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.signOut()
                }
              }
            }

            // ----- Empty state -----
            Item {
              visible: !root.settingsMode && root.convo === null
              width: parent.width
              height: visible ? parent.height : 0

              Column {
              anchors.centerIn: parent
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                text: ""
                color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.title * 2
              }
              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Pick a conversation — ↑/↓ and Enter work too"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              }
            }

            // ----- Conversation -----
            Item {
              visible: !root.settingsMode && root.convo !== null
              width: parent.width
              height: Style.space(24)

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.convo
                  ? (root.convo.kind === "im" || root.convo.kind === "mpim" ? "@ " : "# ") + root.convo.name
                  : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
                width: parent.width - Style.space(60)
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.historyNote
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Math.max(8, Style.font.caption - 1)
              }
            }

            Flickable {
              id: messageScroll
              visible: !root.settingsMode && root.convo !== null
              width: parent.width
              height: parent.height - Style.space(24) - composeRow.height - Style.space(24)
              contentWidth: width
              contentHeight: messageColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height

              Column {
                id: messageColumn
                width: messageScroll.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  visible: root.historyLoading && root.messages.length === 0
                  width: parent.width
                  topPadding: Style.space(30)
                  text: "loading messages…"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.historyError !== ""
                  width: parent.width
                  topPadding: Style.space(30)
                  text: "⚠ " + root.historyError
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.messages

                  Column {
                    id: msgItem
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(1)

                    Row {
                      spacing: Style.space(6)

                      Text {
                        textFormat: Text.PlainText
                        text: msgItem.modelData.name
                        color: msgItem.modelData.mine ? Color.accent : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: msgItem.modelData.time
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Math.max(8, Style.font.caption - 1)
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: msgItem.modelData.text
                      color: msgItem.modelData.system ? root.dim : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.italic: msgItem.modelData.system === true
                      wrapMode: Text.Wrap
                    }
                  }
                }
              }
            }

            Item {
              id: composeRow
              visible: !root.settingsMode && root.convo !== null
              width: parent.width
              height: composeField.implicitHeight

              TextField {
                id: composeField
                anchors.left: parent.left
                anchors.right: sendButton.left
                anchors.rightMargin: Style.space(6)
                placeholderText: root.sending ? "sending…" : "Message… (Enter to send)"
                foreground: root.foreground
                font.family: root.fontFamily
                enabled: !root.sending

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.sendMessage()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Escape) {
                    keyCatcher.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }

              Rectangle {
                id: sendButton
                width: Style.space(32)
                height: composeField.height
                radius: root.cornerRadius
                anchors.right: parent.right
                anchors.verticalCenter: composeField.verticalCenter
                color: sendArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.45)

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: ""
                  color: root.sending ? root.dim : Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: sendArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.sendMessage()
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.settingsMode && root.sendError !== ""
              width: parent.width
              text: "⚠ " + root.sendError
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }
