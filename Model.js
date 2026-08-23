// Command building, response parsing and mrkdwn formatting for the Slack
// panel. Every network access goes through scripts/slack.sh, which owns the
// token, validates all ids, and returns exactly one JSON object per call —
// QML only ever parses small, pre-trimmed JSON and renders it PlainText.

// ---------------------------------------------------------------- commands

// All commands are plain argv arrays — no `sh -c`, so nothing user- or
// server-controlled is ever interpreted by a shell. Message text and the
// token travel over stdin (see Panel.qml's send/token processes).
function script(scriptDir) {
  return scriptDir + "slack.sh"
}

function countsCommand(scriptDir, showChannels) {
  var types = showChannels
    ? "im,mpim,public_channel,private_channel"
    : "im,mpim"
  return ["bash", script(scriptDir), "counts", types]
}

function historyCommand(scriptDir, channelId) {
  return ["bash", script(scriptDir), "history", String(channelId)]
}

function sendCommand(scriptDir, channelId, threadTs) {
  var a = ["bash", script(scriptDir), "send", String(channelId)]
  if (threadTs) a.push(String(threadTs))
  return a
}

function threadCommand(scriptDir, channelId, ts) {
  return ["bash", script(scriptDir), "thread", String(channelId), String(ts)]
}

function seenCommand(scriptDir, channelId, ts) {
  return ["bash", script(scriptDir), "seen", String(channelId), String(ts)]
}

function loginCommand(scriptDir) {
  return ["bash", script(scriptDir), "login"]
}

function loginAvailableCommand(scriptDir) {
  return ["bash", script(scriptDir), "login-available"]
}

function presenceCommand(scriptDir, presence) {
  return ["bash", script(scriptDir), "presence", presence === "away" ? "away" : "auto"]
}

function snoozeCommand(scriptDir, minutes) {
  return ["bash", script(scriptDir), "snooze", String(parseInt(minutes, 10) || 60)]
}

function unsnoozeCommand(scriptDir) {
  return ["bash", script(scriptDir), "unsnooze"]
}

function statusCommand(scriptDir) {
  return ["bash", script(scriptDir), "status"]
}

function setTokenCommand(scriptDir) {
  return ["bash", script(scriptDir), "set-token"]
}

function clearTokenCommand(scriptDir) {
  return ["bash", script(scriptDir), "clear-token"]
}

// ----------------------------------------------------------------- parsing

function parseJson(raw) {
  var text = String(raw || "").replace(/^\s+|\s+$/g, "")
  if (text === "") return { ok: false, error: "no output" }
  try {
    var data = JSON.parse(text)
    if (!data || typeof data !== "object") return { ok: false, error: "bad output" }
    return data
  } catch (e) {
    return { ok: false, error: "bad output" }
  }
}

// Human wording for the Slack API errors a user can plausibly hit.
function friendlyError(err) {
  var e = String(err || "")
  if (e === "no token") return "not signed in"
  if (e === "invalid_auth" || e === "token_revoked" || e === "token_expired" || e === "account_inactive")
    return "token rejected — sign in again in settings"
  if (e === "ratelimited") return "Slack rate limit — try again in a minute"
  if (e === "missing_scope") return "the token is missing a scope for this (see README)"
  if (e === "channel_not_found") return "conversation not found"
  if (e === "network" || e.indexOf("network") === 0) return "can't reach slack.com"
  return e
}

// Conversations, re-sorted for display: unread first (most unread on top),
// then DMs before channels, then alphabetical.
var KIND_ORDER = { im: 0, mpim: 1, private: 2, channel: 3 }

function sortConversations(convs) {
  var out = (convs || []).slice()
  out.sort(function(a, b) {
    var ua = a.effectiveUnread || 0
    var ub = b.effectiveUnread || 0
    if ((ua > 0) !== (ub > 0)) return ua > 0 ? -1 : 1
    if (ua !== ub) return ub - ua
    var ka = KIND_ORDER[a.kind] !== undefined ? KIND_ORDER[a.kind] : 9
    var kb = KIND_ORDER[b.kind] !== undefined ? KIND_ORDER[b.kind] : 9
    if (ka !== kb) return ka - kb
    return String(a.name).toLowerCase() < String(b.name).toLowerCase() ? -1 : 1
  })
  return out
}

// A conversation counts as read locally once the user has viewed messages at
// or past its latest ts here, even when the token lacks the optional write
// scopes for conversations.mark (localRead is persisted in settings).
function applyLocalRead(convs, localRead) {
  var seen = localRead || {}
  var out = []
  for (var i = 0; i < (convs || []).length; i++) {
    var c = convs[i]
    var copy = {}
    for (var k in c) copy[k] = c[k]
    var unread = parseInt(c.unread, 10) || 0
    var latest = String(c.latest || "")
    var mark = String(seen[c.id] || "")
    if (unread > 0 && latest !== "" && mark !== "" && parseFloat(mark) >= parseFloat(latest))
      unread = 0
    copy.effectiveUnread = unread
    out.push(copy)
  }
  return out
}

// Bar badge = DM + group-DM unreads (every one of those is directed at you).
// Channel unreads only light the icon: Slack's public API does not expose
// per-channel mention counts to user tokens.
function mentionCount(convs) {
  var n = 0
  for (var i = 0; i < (convs || []).length; i++) {
    var c = convs[i]
    if (c.kind === "im" || c.kind === "mpim") n += c.effectiveUnread || 0
  }
  return n
}

function unreadChannelCount(convs) {
  var n = 0
  for (var i = 0; i < (convs || []).length; i++) {
    var c = convs[i]
    if (c.kind !== "im" && c.kind !== "mpim" && (c.effectiveUnread || 0) > 0) n++
  }
  return n
}

// Case-insensitive substring filter over display names, for the sidebar.
function filterConversations(convs, query) {
  var q = String(query || "").toLowerCase().replace(/^\s+|\s+$/g, "")
  if (q === "") return convs || []
  var out = []
  for (var i = 0; i < (convs || []).length; i++) {
    if (displayName(convs[i]).toLowerCase().indexOf(q) !== -1) out.push(convs[i])
  }
  return out
}

function kindGlyph(kind) {
  if (kind === "im") return "@"
  if (kind === "mpim") return "@"
  if (kind === "private") return "§"
  return "#"
}

// Group-DM API names look like "mpdm-alice--bob--carol-1"; show them as the
// member list instead.
function displayName(conv) {
  var name = String(conv.name || "")
  if (conv.kind === "mpim" && name.indexOf("mpdm-") === 0)
    return name.replace(/^mpdm-/, "").replace(/-\d+$/, "").split("--").join(", ")
  return name
}

// ------------------------------------------------------------- messages

// Slack mrkdwn → plain text. Safe because every rendering Text element uses
// Text.PlainText; this only makes the content readable, it is not a
// sanitizer.
function userName(users, id) {
  var u = users && users[id]
  if (!u) return null
  return typeof u === "string" ? u : (u.n || null)
}

function userAvatar(users, id) {
  var u = users && users[id]
  if (!u || typeof u === "string") return ""
  return validAvatar(u.i) ? u.i : ""
}

// Avatars are either a local PNG the script converted (Slack serves webp,
// which Qt can't decode) under the plugin's own cache dir, or — as a
// fallback — a URL on Slack's own image hosts. Nothing else is accepted.
function validAvatar(x) {
  var s = String(x || "")
  return /\/omarchy-slack\/avatars\/[UW][A-Z0-9]+\.png$/.test(s)
      || /^https:\/\/(secure\.gravatar\.com|[a-z0-9.-]*\.slack-edge\.com)\//.test(s)
}

// Image.source value for an avatar: file:// for the local PNG, the https URL
// otherwise, or "" when there's nothing valid to show.
function avatarSource(x) {
  if (!validAvatar(x)) return ""
  return String(x).charAt(0) === "/" ? "file://" + x : String(x)
}

// A small map of the mrkdwn emoji shortcodes that show up most in practice.
// Unknown :shortcodes: are left as-is (still readable), and Slack already
// sends most emoji as literal unicode.
var EMOJI = {
  ":smile:":"😄",":smiley:":"😃",":grin:":"😁",":laughing:":"😆",":joy:":"😂",
  ":rofl:":"🤣",":wink:":"😉",":blush:":"😊",":slightly_smiling_face:":"🙂",
  ":thinking_face:":"🤔",":upside_down_face:":"🙃",":sunglasses:":"😎",
  ":heart:":"❤️",":yellow_heart:":"💛",":green_heart:":"💚",":blue_heart:":"💙",
  ":thumbsup:":"👍",":+1:":"👍",":thumbsdown:":"👎",":-1:":"👎",":ok_hand:":"👌",
  ":clap:":"👏",":raised_hands:":"🙌",":pray:":"🙏",":muscle:":"💪",":wave:":"👋",
  ":point_up:":"☝️",":point_right:":"👉",":eyes:":"👀",":fire:":"🔥",":tada:":"🎉",
  ":sparkles:":"✨",":star:":"⭐",":star2:":"🌟",":zap:":"⚡",":boom:":"💥",
  ":rocket:":"🚀",":100:":"💯",":white_check_mark:":"✅",":heavy_check_mark:":"✔️",
  ":x:":"❌",":warning:":"⚠️",":bell:":"🔔",":no_bell:":"🔕",":lock:":"🔒",
  ":bulb:":"💡",":bug:":"🐛",":wrench:":"🔧",":hammer:":"🔨",":memo:":"📝",
  ":pushpin:":"📌",":calendar:":"📅",":coffee:":"☕",":beer:":"🍺",":pizza:":"🍕",
  ":smiling_face_with_tear:":"🥲",":sob:":"😭",":cry:":"😢",":angry:":"😠",
  ":scream:":"😱",":sweat_smile:":"😅",":partying_face:":"🥳",":raised_hand:":"✋",
  ":point_down:":"👇",":ok:":"🆗",":heavy_plus_sign:":"➕",":recycle:":"♻️",
  ":question:":"❓",":exclamation:":"❗",":checkered_flag:":"🏁",":dart:":"🎯"
}

function emojify(text) {
  return String(text || "").replace(/:[a-z0-9_+-]+:/g, function(code) {
    return EMOJI[code] || code
  })
}

function formatMessage(text, users) {
  var t = String(text || "")
  t = t.replace(/<@([UW][A-Z0-9]{2,30})(\|[^>]*)?>/g, function(m, id, label) {
    var name = userName(users, id) || (label ? label.slice(1) : id)
    return "@" + name
  })
  t = t.replace(/<#[A-Z0-9]+\|([^>]*)>/g, "#$1")
  t = t.replace(/<#([A-Z0-9]+)>/g, "#$1")
  t = t.replace(/<!(here|channel|everyone)(\|[^>]*)?>/g, "@$1")
  t = t.replace(/<((?:https?|mailto):[^>|]*)\|([^>]+)>/g, "$2")
  t = t.replace(/<((?:https?|mailto):[^>]*)>/g, "$1")
  t = t.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
  return emojify(t)
}

// First http(s) URL in a message, for click-to-open. Returns "" if none.
function firstUrl(text) {
  var m = String(text || "").match(/https?:\/\/[^\s<>|]+/)
  return m ? m[0] : ""
}

// One history payload → display rows.
function buildMessages(payload, selfId) {
  var msgs = (payload && payload.messages) || []
  var users = (payload && payload.users) || {}
  var out = []
  var prevUser = null
  for (var i = 0; i < msgs.length; i++) {
    var m = msgs[i]
    var uid = String(m.user || "")
    var name = userName(users, uid) || String(m.username || "") || (m.bot ? "bot" : uid || "?")
    var text = formatMessage(m.text, users)
    out.push({
      ts: String(m.ts || ""),
      name: name,
      avatar: userAvatar(users, uid),
      mine: selfId !== "" && uid === selfId,
      system: String(m.subtype || "") !== "" && String(m.subtype || "") !== "bot_message",
      // Group consecutive messages from the same author: hide the repeated
      // name/avatar header on all but the first.
      grouped: uid !== "" && uid === prevUser,
      replyCount: parseInt(m.reply_count, 10) || 0,
      threadTs: String(m.thread_ts || ""),
      time: msgTime(m.ts),
      url: firstUrl(text),
      text: text
    })
    prevUser = uid
  }
  return out
}

function lastTs(payload) {
  var msgs = (payload && payload.messages) || []
  return msgs.length ? String(msgs[msgs.length - 1].ts || "") : ""
}

// ---------------------------------------------------------------- format

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function msgTime(ts) {
  var t = parseFloat(ts)
  if (!t || isNaN(t)) return ""
  var d = new Date(t * 1000)
  var now = new Date()
  var hm = ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
  if (d.toDateString() === now.toDateString()) return hm
  return MONTHS[d.getMonth()] + " " + d.getDate() + " " + hm
}

function snoozeLabel(until) {
  var t = parseInt(until, 10) || 0
  if (t <= 0) return ""
  var d = new Date(t * 1000)
  return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
}

if (typeof module !== "undefined") {
  module.exports = {
    countsCommand: countsCommand,
    historyCommand: historyCommand,
    sendCommand: sendCommand,
    threadCommand: threadCommand,
    seenCommand: seenCommand,
    loginCommand: loginCommand,
    loginAvailableCommand: loginAvailableCommand,
    filterConversations: filterConversations,
    presenceCommand: presenceCommand,
    snoozeCommand: snoozeCommand,
    unsnoozeCommand: unsnoozeCommand,
    statusCommand: statusCommand,
    setTokenCommand: setTokenCommand,
    clearTokenCommand: clearTokenCommand,
    parseJson: parseJson,
    friendlyError: friendlyError,
    sortConversations: sortConversations,
    applyLocalRead: applyLocalRead,
    mentionCount: mentionCount,
    unreadChannelCount: unreadChannelCount,
    kindGlyph: kindGlyph,
    displayName: displayName,
    formatMessage: formatMessage,
    emojify: emojify,
    validAvatar: validAvatar,
    avatarSource: avatarSource,
    userName: userName,
    userAvatar: userAvatar,
    firstUrl: firstUrl,
    buildMessages: buildMessages,
    lastTs: lastTs,
    msgTime: msgTime,
    snoozeLabel: snoozeLabel
  }
}
