#!/bin/bash
# Slack API helper for the bottelet.slack Omarchy plugin.
#
# Every subcommand prints exactly one JSON object on stdout — {ok:false,error}
# on any failure — so the QML side never has to guess. The token is read from
# GNOME Keyring (secret-tool) when available, else from a 0600 file, and is
# only ever handed to curl through a process-substitution header file so it
# never appears on any process's argv.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-slack"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-slack"
TOKEN_FILE="$CONFIG_DIR/token"
USERS_CACHE="$CACHE_DIR/users.json"
SEEN_FILE="$CACHE_DIR/seen.json"
API="https://slack.com/api"

# Bounds. Slack method responses are small; the caps exist so a hostile or
# misbehaving endpoint cannot stream without end into the shell process.
MAX_BYTES=4194304          # 4 MiB per response
MAX_CONV_INFO=30           # conversations.info calls per counts cycle
MAX_USER_LOOKUPS=20        # users.info calls per cycle
MAX_MSG_CHARS=4000         # chat.postMessage text cap (Slack's own limit)
HISTORY_CACHE_SECS=60      # non-Marketplace apps: conversations.history is 1 req/min

CURL=(curl -sS --proto '=https' --proto-redir '=https' --max-filesize "$MAX_BYTES")

emit_error() { jq -cn --arg e "$1" '{ok:false,error:$e}'; exit 0; }

mkdir -p "$CACHE_DIR" || emit_error "cannot create cache dir"

# ---------------------------------------------------------------- token store

have_keyring() { command -v secret-tool >/dev/null 2>&1; }

read_token() {
  local t=""
  if have_keyring; then
    t="$(timeout 3 secret-tool lookup service omarchy-slack key token 2>/dev/null || true)"
  fi
  if [[ -z "$t" && -f "$TOKEN_FILE" ]]; then
    t="$(head -c 512 "$TOKEN_FILE" | tr -d '[:space:]')"
  fi
  [[ "$t" =~ ^xox[pb]-[A-Za-z0-9-]{10,200}$ ]] || return 1
  printf '%s' "$t"
}

# store_raw_token <token> — keyring first, 0600 file otherwise. Sets STORED.
store_raw_token() {
  local t="$1"
  if have_keyring && printf '%s' "$t" | timeout 3 secret-tool store --label="Omarchy Slack token" service omarchy-slack key token 2>/dev/null; then
    STORED="keyring"
    rm -f "$TOKEN_FILE" 2>/dev/null
  else
    ( umask 077 && mkdir -p "$CONFIG_DIR" && printf '%s\n' "$t" > "$TOKEN_FILE" ) || emit_error "could not write token file"
    STORED="file"
  fi
}

# confirm_token — auth.test with $TOKEN and emit the standard confirmation.
confirm_token() {
  local res
  res="$(api_call auth.test -X POST)" || emit_error "network error talking to slack.com"
  jq -c --arg s "$STORED" '{ok:.ok, error:(.error // ""), stored:$s, team:(.team // ""), user:(.user // ""), user_id:(.user_id // ""), url:(.url // "")}' <<<"$res" 2>/dev/null \
    || emit_error "unexpected reply from slack.com"
  exit 0
}

store_token() { # token on stdin
  local t
  IFS= read -r t || true
  t="${t//[$'\t\r\n ']/}"
  [[ "$t" =~ ^xox[pb]-[A-Za-z0-9-]{10,200}$ ]] || emit_error "that does not look like a Slack token (expected xoxp-… or xoxb-…)"
  store_raw_token "$t"
  TOKEN="$t"
  confirm_token
}

clear_token() {
  if have_keyring; then timeout 3 secret-tool clear service omarchy-slack key token 2>/dev/null || true; fi
  rm -f "$TOKEN_FILE" 2>/dev/null
  rm -rf "$CACHE_DIR" 2>/dev/null
  jq -cn '{ok:true}'
  exit 0
}

# -------------------------------------------------------------- OAuth login

# App credentials: the user's own override wins, else the ones shipped with
# the plugin. (Shipping a client secret with a native app is the standard
# trade-off for browser sign-in — see README, "Privacy & security".)
oauth_config() {
  local f
  for f in "$CONFIG_DIR/oauth.json" "$SCRIPT_DIR/../config/oauth.json"; do
    if [[ -s "$f" ]] && jq -e '.client_id // "" | length > 0' "$f" >/dev/null 2>&1; then
      jq -c . "$f" 2>/dev/null && return 0
    fi
  done
  return 1
}

OAUTH_SCOPES="channels:read,groups:read,im:read,mpim:read,channels:history,groups:history,im:history,mpim:history,chat:write,users:read,dnd:read,dnd:write,users:write"

cmd_login() {
  local cfg cid secret port bounce
  cfg="$(oauth_config)" || emit_error "not configured"
  cid="$(jq -r '.client_id // ""' <<<"$cfg")"
  secret="$(jq -r '.client_secret // ""' <<<"$cfg")"
  port="$(jq -r '.port // 41879' <<<"$cfg")"
  bounce="$(jq -r '.redirect // ""' <<<"$cfg")"
  [[ "$cid" =~ ^[0-9]+\.[0-9]+$ ]] || emit_error "not configured"
  [[ -n "$secret" ]] || emit_error "not configured"
  [[ "$port" =~ ^[0-9]{4,5}$ ]] || emit_error "bad oauth port"
  [[ "$bounce" =~ ^https:// ]] || emit_error "bad redirect url"

  local state
  state="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  [[ "$state" =~ ^[0-9a-f]{32}$ ]] || emit_error "could not generate state"

  local auth_url
  auth_url="https://slack.com/oauth/v2/authorize?client_id=$cid&user_scope=$(jq -rn --arg s "$OAUTH_SCOPES" '$s|@uri')&state=$state&redirect_uri=$(jq -rn --arg u "$bounce" '$u|@uri')"

  # The listener binds first, then opens the browser itself — no race. It
  # prints the authorization code on success and nothing else.
  local tmp pypid rc code
  tmp="$CACHE_DIR/.oauth-code.$$"
  python3 "$SCRIPT_DIR/oauth-callback.py" "$port" "$state" "$auth_url" > "$tmp" 2>/dev/null &
  pypid=$!
  trap 'kill "$pypid" 2>/dev/null; rm -f "$tmp"' EXIT TERM INT
  wait "$pypid"
  rc=$?
  code="$(head -c 600 "$tmp" 2>/dev/null | tr -d '[:space:]')"
  rm -f "$tmp"
  trap - EXIT TERM INT
  if (( rc != 0 )) || [[ -z "$code" ]]; then
    (( rc == 2 )) && emit_error "port busy — is another sign-in already running?"
    emit_error "sign-in timed out or was cancelled"
  fi
  [[ "$code" =~ ^[A-Za-z0-9._-]{8,600}$ ]] || emit_error "bad authorization code"

  # Exchange over stdin so the client secret never touches argv.
  local body res
  body="$(jq -rn --arg cid "$cid" --arg sec "$secret" --arg code "$code" --arg ru "$bounce" \
    '"client_id=\($cid|@uri)&client_secret=\($sec|@uri)&code=\($code|@uri)&redirect_uri=\($ru|@uri)"')"
  res="$("${CURL[@]}" --max-time 20 -X POST \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data @- "$API/oauth.v2.access" <<<"$body" | head -c "$MAX_BYTES")" \
    || emit_error "network error talking to slack.com"
  if ! jq -e '.ok == true' <<<"$res" >/dev/null 2>&1; then
    jq -c '{ok:false, error:(.error // "sign-in failed")}' <<<"$res" 2>/dev/null || emit_error "sign-in failed"
    exit 0
  fi

  local t
  t="$(jq -r '.authed_user.access_token // ""' <<<"$res")"
  [[ "$t" =~ ^xoxp-[A-Za-z0-9-]{10,200}$ ]] || emit_error "Slack did not return a user token"
  store_raw_token "$t"
  TOKEN="$t"
  confirm_token
}

# Whether browser sign-in is available (app credentials present).
cmd_login_available() {
  if oauth_config >/dev/null; then jq -cn '{ok:true, available:true}'
  else jq -cn '{ok:true, available:false}'; fi
}

# ------------------------------------------------------------------ API layer

# api_call <method> [curl args...] — token travels via an ephemeral /dev/fd
# header file, never argv. Output is size-capped; Slack errors (incl. HTTP
# 429 → {"ok":false,"error":"ratelimited"}) pass through as JSON.
api_call() {
  local method="$1"; shift
  [[ "$method" =~ ^[a-z]+(\.[a-zA-Z]+)+$ ]] || return 1
  "${CURL[@]}" --max-time 15 \
    -H @<(printf 'Authorization: Bearer %s\n' "$TOKEN") \
    "$@" "$API/$method" | head -c "$MAX_BYTES"
}

require_token() {
  TOKEN="$(read_token)" || emit_error "no token"
}

valid_channel() { [[ "$1" =~ ^[CDGW][A-Z0-9]{5,30}$ ]]; }
valid_user() { [[ "$1" =~ ^[UW][A-Z0-9]{5,30}$ ]]; }
valid_ts() { [[ "$1" =~ ^[0-9]{1,12}\.[0-9]{1,8}$ ]]; }

# ----------------------------------------------------------------- user names

# users.json cache: { "U123": "Display Name", ... }. Names are display data
# only; the QML side renders them PlainText.
load_users_cache() {
  if [[ -s "$USERS_CACHE" ]]; then
    jq -c 'if type == "object" then . else {} end' "$USERS_CACHE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

# resolve_users <json array of user ids> — fetches at most MAX_USER_LOOKUPS
# unknown ids, merges into the cache, prints the full cache object.
resolve_users() {
  local ids="$1" cache missing uid info name fetched=0
  cache="$(load_users_cache)"
  missing="$(jq -cr --argjson cache "$cache" '[.[] | select($cache[.] == null)] | unique | .[]' <<<"$ids" 2>/dev/null)"
  while IFS= read -r uid; do
    [[ -z "$uid" ]] && continue
    valid_user "$uid" || continue
    (( fetched >= MAX_USER_LOOKUPS )) && break
    fetched=$((fetched + 1))
    info="$(api_call users.info -G --data-urlencode "user=$uid")" || continue
    name="$(jq -r '.user.profile.display_name // "" | select(. != "")' <<<"$info" 2>/dev/null)"
    [[ -z "$name" ]] && name="$(jq -r '.user.real_name // .user.name // ""' <<<"$info" 2>/dev/null)"
    [[ -z "$name" ]] && continue
    cache="$(jq -c --arg id "$uid" --arg n "$name" '.[$id] = $n' <<<"$cache")"
  done <<<"$missing"
  printf '%s' "$cache" > "$USERS_CACHE.tmp.$$" && mv "$USERS_CACHE.tmp.$$" "$USERS_CACHE"
  printf '%s' "$cache"
}

# --------------------------------------------------------------------- counts

cmd_counts() {
  require_token
  local types="${1:-im,mpim,public_channel,private_channel}"
  [[ "$types" =~ ^[a-z_,]+$ ]] || emit_error "bad types"

  local me convs
  me="$(api_call auth.test -X POST)" || emit_error "network error talking to slack.com"
  jq -e '.ok == true' <<<"$me" >/dev/null 2>&1 || {
    jq -c '{ok:false, error:(.error // "auth failed")}' <<<"$me" 2>/dev/null || emit_error "auth failed"
    exit 0
  }

  convs="$(api_call users.conversations -G \
    --data-urlencode "types=$types" \
    --data-urlencode "exclude_archived=true" \
    --data-urlencode "limit=200")" || emit_error "network error listing conversations"
  jq -e '.ok == true' <<<"$convs" >/dev/null 2>&1 || {
    jq -c '{ok:false, error:(.error // "could not list conversations")}' <<<"$convs" 2>/dev/null || emit_error "could not list conversations"
    exit 0
  }

  # Base rows: id, kind, name (channels) or counterpart user id (DMs).
  local base
  base="$(jq -c '[.channels[]? | {
      id: .id,
      kind: (if .is_im then "im" elif .is_mpim then "mpim" elif .is_private then "private" else "channel" end),
      name: (.name // ""),
      user: (.user // "")
    }]' <<<"$convs")"

  # Unread counts: one conversations.info per row, capped. DMs first — their
  # unreads are what the bar badge counts, so they must land inside the cap.
  local ordered enriched="[]" row id info detail count=0
  ordered="$(jq -c '[.[] | select(.kind == "im" or .kind == "mpim")] + [.[] | select(.kind != "im" and .kind != "mpim")]' <<<"$base")"
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    id="$(jq -r '.id' <<<"$row")"
    valid_channel "$id" || continue
    if (( count < MAX_CONV_INFO )); then
      count=$((count + 1))
      info="$(api_call conversations.info -G --data-urlencode "channel=$id")" || info='{}'
      detail="$(jq -c '{unread: (.channel.unread_count_display // .channel.unread_count // 0),
                        latest: (.channel.latest.ts // "")}' <<<"$info" 2>/dev/null || echo '{"unread":0,"latest":""}')"
    else
      detail='{"unread":0,"latest":"","uncounted":true}'
    fi
    enriched="$(jq -c --argjson row "$row" --argjson d "$detail" '. + [$row + $d]' <<<"$enriched")"
  done <<<"$(jq -c '.[]' <<<"$ordered")"

  # Resolve DM counterpart names through the user cache.
  local dm_ids users
  dm_ids="$(jq -c '[.[] | select(.kind == "im") | .user | select(. != "")]' <<<"$enriched")"
  users="$(resolve_users "$dm_ids")"

  # Presence + DND are cheap and round out the header.
  local presence dnd
  presence="$(api_call users.getPresence -G 2>/dev/null || echo '{}')"
  dnd="$(api_call dnd.info -G 2>/dev/null || echo '{}')"

  # Local read markers ride along so the UI can compute effective unreads;
  # creating the file here also makes it watchable from QML from day one.
  local seen
  if [[ -s "$SEEN_FILE" ]]; then
    seen="$(jq -c 'if type == "object" then . else {} end' "$SEEN_FILE" 2>/dev/null || echo '{}')"
  else
    seen='{}'
    printf '%s' "$seen" > "$SEEN_FILE" 2>/dev/null || true
  fi

  jq -cn \
    --argjson me "$(jq -c '{team:(.team // ""), user:(.user // ""), user_id:(.user_id // ""), url:(.url // "")}' <<<"$me")" \
    --argjson rows "$enriched" \
    --argjson users "$users" \
    --argjson presence "$(jq -c '{presence:(.presence // "")}' <<<"$presence" 2>/dev/null || echo '{"presence":""}')" \
    --argjson dnd "$(jq -c '{snoozing:(.snooze_enabled // false), snooze_until:(.snooze_endtime // 0)}' <<<"$dnd" 2>/dev/null || echo '{"snoozing":false,"snooze_until":0}')" \
    --argjson seen "$seen" \
    '{ok:true, team:$me.team, self:$me.user, self_id:$me.user_id, url:$me.url, seen:$seen,
      presence:$presence.presence, snoozing:$dnd.snoozing, snooze_until:$dnd.snooze_until,
      capped: ([$rows[] | select(.uncounted == true)] | length > 0),
      conversations: [$rows[] | {
        id, kind, latest,
        unread: (.unread // 0),
        name: (if .kind == "im" then ($users[.user] // .user) else .name end),
        user: (.user // "")
      }]}'
}

# -------------------------------------------------------------------- history

cmd_history() {
  require_token
  local id="${1:-}"
  valid_channel "$id" || emit_error "bad channel id"

  # Non-Marketplace Slack apps created after May 2025 get 1 history request
  # per minute (15 messages). Serve a fresh-enough cache instead of burning it.
  local cache_file="$CACHE_DIR/hist-$id.json" now age
  now="$(date +%s)"
  if [[ -s "$cache_file" ]]; then
    age=$(( now - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if (( age < HISTORY_CACHE_SECS )); then
      jq -c '. + {cached:true}' "$cache_file" 2>/dev/null && exit 0
    fi
  fi

  local res
  res="$(api_call conversations.history -G \
    --data-urlencode "channel=$id" \
    --data-urlencode "limit=15")" || emit_error "network error fetching history"
  if ! jq -e '.ok == true' <<<"$res" >/dev/null 2>&1; then
    local err
    err="$(jq -r '.error // "history failed"' <<<"$res" 2>/dev/null || echo "history failed")"
    # On a rate limit, fall back to any cache we have rather than a blank view.
    if [[ "$err" == "ratelimited" && -s "$cache_file" ]]; then
      jq -c '. + {cached:true, ratelimited:true}' "$cache_file" 2>/dev/null && exit 0
    fi
    emit_error "$err"
  fi

  local msgs uids users out
  msgs="$(jq -c '[.messages[]? | select(.type == "message")
    | {ts: (.ts // ""), user: (.user // ""), bot: (.bot_id // ""),
       username: (.username // ""), subtype: (.subtype // ""),
       text: ((.text // "") | .[0:8000])}] | reverse' <<<"$res")"
  uids="$(jq -c '[.[] | .user | select(. != "")]' <<<"$msgs")"
  users="$(resolve_users "$uids")"
  out="$(jq -cn --argjson m "$msgs" --argjson u "$users" '{ok:true, messages:$m, users:$u}')"
  printf '%s' "$out" > "$cache_file.tmp.$$" && mv "$cache_file.tmp.$$" "$cache_file"
  printf '%s\n' "$out"
}

# ----------------------------------------------------------------------- send

cmd_send() {
  require_token
  local id="${1:-}"
  valid_channel "$id" || emit_error "bad channel id"
  local text
  text="$(head -c $((MAX_MSG_CHARS * 4)) | head -c "$MAX_MSG_CHARS")"
  [[ -z "${text//[$' \t\r\n']/}" ]] && emit_error "empty message"

  local res
  res="$(jq -cn --arg ch "$id" --arg t "$text" '{channel:$ch, text:$t}' \
    | api_call chat.postMessage -X POST -H 'Content-Type: application/json; charset=utf-8' --data-binary @-)" \
    || emit_error "network error sending message"
  jq -c '{ok:.ok, error:(.error // ""), ts:(.ts // "")}' <<<"$res" 2>/dev/null || emit_error "unexpected reply"
  # A successful send makes the cached history stale immediately.
  jq -e '.ok == true' <<<"$res" >/dev/null 2>&1 && rm -f "$CACHE_DIR/hist-$id.json"
  exit 0
}

# ------------------------------------------------------------------ the rest

# seen <id> <ts> — record the local read marker (shared by bar widget and
# app), then best-effort conversations.mark so other Slack clients sync too
# (silently skipped when the token lacks the optional write scopes).
cmd_seen() {
  require_token
  local id="${1:-}" ts="${2:-}"
  valid_channel "$id" || emit_error "bad channel id"
  valid_ts "$ts" || emit_error "bad ts"

  local seen
  if [[ -s "$SEEN_FILE" ]]; then
    seen="$(jq -c 'if type == "object" then . else {} end' "$SEEN_FILE" 2>/dev/null || echo '{}')"
  else
    seen='{}'
  fi
  # Keep the newest marker per conversation; bound the map at 300 entries.
  seen="$(jq -c --arg id "$id" --arg ts "$ts" \
    '.[$id] = (if (.[$id] // "0" | tonumber) > ($ts | tonumber) then .[$id] else $ts end)
     | to_entries | sort_by(.value | tonumber) | .[-300:] | from_entries' <<<"$seen")"
  printf '%s' "$seen" > "$SEEN_FILE.tmp.$$" && mv "$SEEN_FILE.tmp.$$" "$SEEN_FILE"

  local res marked=false
  res="$(api_call conversations.mark -X POST \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data-binary "$(jq -cn --arg ch "$id" --arg ts "$ts" '{channel:$ch, ts:$ts}')" 2>/dev/null || echo '{}')"
  jq -e '.ok == true' <<<"$res" >/dev/null 2>&1 && marked=true
  jq -cn --argjson m "$marked" '{ok:true, marked:$m}'
}

cmd_presence() {
  require_token
  local p="${1:-}"
  [[ "$p" == "auto" || "$p" == "away" ]] || emit_error "presence must be auto or away"
  local res
  res="$(api_call users.setPresence -X POST --data-urlencode "presence=$p")" || emit_error "network error"
  jq -c '{ok:.ok, error:(.error // "")}' <<<"$res" 2>/dev/null || emit_error "unexpected reply"
}

cmd_snooze() {
  require_token
  local mins="${1:-60}"
  [[ "$mins" =~ ^[0-9]{1,4}$ ]] || emit_error "bad minutes"
  local res
  res="$(api_call dnd.setSnooze -X POST --data-urlencode "num_minutes=$mins")" || emit_error "network error"
  jq -c '{ok:.ok, error:(.error // ""), snooze_until:(.snooze_endtime // 0)}' <<<"$res" 2>/dev/null || emit_error "unexpected reply"
}

cmd_unsnooze() {
  require_token
  local res
  res="$(api_call dnd.endSnooze -X POST)" || emit_error "network error"
  jq -c '{ok:.ok, error:(.error // "")}' <<<"$res" 2>/dev/null || emit_error "unexpected reply"
}

cmd_status() {
  # First command every widget runs — make seen.json exist so QML file
  # watchers have something to watch from the start.
  [[ -s "$SEEN_FILE" ]] || printf '{}' > "$SEEN_FILE" 2>/dev/null || true
  local t
  if ! t="$(read_token)"; then
    jq -cn '{ok:true, has_token:false}'
    exit 0
  fi
  TOKEN="$t"
  local res
  res="$(api_call auth.test -X POST)" || { jq -cn '{ok:true, has_token:true, valid:false, error:"network"}'; exit 0; }
  jq -c '{ok:true, has_token:true, valid:(.ok == true), error:(.error // ""), team:(.team // ""), user:(.user // "")}' <<<"$res" 2>/dev/null \
    || jq -cn '{ok:true, has_token:true, valid:false, error:"unexpected reply"}'
}

# --------------------------------------------------------------------- router

case "${1:-}" in
  counts)          shift; cmd_counts "$@" ;;
  history)         shift; cmd_history "$@" ;;
  send)            shift; cmd_send "$@" ;;
  seen)            shift; cmd_seen "$@" ;;
  presence)        shift; cmd_presence "$@" ;;
  snooze)          shift; cmd_snooze "$@" ;;
  unsnooze)        shift; cmd_unsnooze "$@" ;;
  status)          cmd_status ;;
  login)           cmd_login ;;
  login-available) cmd_login_available ;;
  set-token)       store_token ;;
  clear-token)     clear_token ;;
  *)               emit_error "unknown command" ;;
esac
