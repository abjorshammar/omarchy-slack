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
USERS_CACHE="$CACHE_DIR/users-v2.json"   # v2: values are {n,i}, i is a local PNG path
SEEN_FILE="$CACHE_DIR/seen.json"
AVATAR_DIR="$CACHE_DIR/avatars"
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

# Everything this script writes is private to the user: cached DMs, read
# markers, the OAuth code in flight. 0700/0600 across the board, and repair
# directories created by older builds.
umask 077
mkdir -p "$CACHE_DIR" || emit_error "cannot create cache dir"
chmod 700 "$CACHE_DIR" 2>/dev/null || true

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

# App config for browser sign-in: the user's own override wins, else the
# config shipped with the plugin. Only a client id and the OAuth proxy URL are
# needed here — the client secret lives ONLY in the proxy (see oauth-proxy/),
# never in this repo, so a public checkout carries no secret.
oauth_config() {
  local f
  for f in "$CONFIG_DIR/oauth.json" "$SCRIPT_DIR/../config/oauth.json"; do
    if [[ -s "$f" ]] \
      && jq -e '(.client_id // "" | length > 0) and (.proxy_url // "" | test("^https://"))' "$f" >/dev/null 2>&1; then
      jq -c . "$f" 2>/dev/null && return 0
    fi
  done
  return 1
}

OAUTH_SCOPES="channels:read,groups:read,im:read,mpim:read,channels:history,groups:history,im:history,mpim:history,chat:write,users:read,dnd:read,dnd:write,users:write"

cmd_login() {
  local cfg cid proxy port
  cfg="$(oauth_config)" || emit_error "not configured"
  cid="$(jq -r '.client_id // ""' <<<"$cfg")"
  proxy="$(jq -r '.proxy_url // "" | rtrimstr("/")' <<<"$cfg")"
  port="$(jq -r '.port // 41879' <<<"$cfg")"
  [[ "$cid" =~ ^[0-9]+\.[0-9]+$ ]] || emit_error "not configured"
  [[ "$proxy" =~ ^https://[A-Za-z0-9._-]+(/[A-Za-z0-9._/-]*)?$ ]] || emit_error "bad proxy url"
  [[ "$port" =~ ^[0-9]{4,5}$ ]] || emit_error "bad oauth port"

  # state = <nonce>.<port>, round-tripped through Slack and the proxy so the
  # proxy knows which local listener to hand the token back to.
  local nonce state
  nonce="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || emit_error "could not generate state"
  state="$nonce.$port"

  # The redirect_uri is the proxy's /callback; the proxy does the secret-bearing
  # token exchange and 302s the token to our loopback listener.
  local redirect auth_url
  redirect="$proxy/callback"
  auth_url="https://slack.com/oauth/v2/authorize?client_id=$cid&user_scope=$(jq -rn --arg s "$OAUTH_SCOPES" '$s|@uri')&state=$(jq -rn --arg s "$state" '$s|@uri')&redirect_uri=$(jq -rn --arg u "$redirect" '$u|@uri')"

  # Listener binds first (no race), then opens the browser. In proxy mode it
  # waits for ?token=…&state=<nonce> and prints the token, nothing else.
  local tmp pypid rc token
  tmp="$CACHE_DIR/.oauth-token.$$"
  : > "$tmp" || emit_error "cannot write cache dir"   # 0600 under umask 077
  python3 "$SCRIPT_DIR/oauth-callback.py" "$port" "$nonce" "$auth_url" --expect token > "$tmp" 2>/dev/null &
  pypid=$!
  trap 'kill "$pypid" 2>/dev/null; rm -f "$tmp"' EXIT TERM INT
  wait "$pypid"
  rc=$?
  token="$(head -c 600 "$tmp" 2>/dev/null | tr -d '[:space:]')"
  rm -f "$tmp"
  trap - EXIT TERM INT
  if (( rc != 0 )) || [[ -z "$token" ]]; then
    (( rc == 2 )) && emit_error "port busy — is another sign-in already running?"
    emit_error "sign-in timed out or was cancelled"
  fi
  [[ "$token" =~ ^xoxp-[A-Za-z0-9-]{10,200}$ ]] || emit_error "sign-in did not return a valid token"
  store_raw_token "$token"
  TOKEN="$token"
  confirm_token
}

# Whether browser sign-in is available (client id + proxy url configured).
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
# Cache shape: { "U123": {"n":"Display Name","i":"https://…/image_48"}, … }.
# Old caches stored a bare name string per id; normalize those to {n:…} on read.
load_users_cache() {
  if [[ -s "$USERS_CACHE" ]]; then
    jq -c 'if type == "object"
             then with_entries(.value |= (if type == "string" then {n: ., i: ""} else . end))
             else {} end' "$USERS_CACHE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

# Slack avatars come from these hosts only; anything else is dropped so a
# tampered response can't point curl at an arbitrary URL.
valid_avatar() { [[ "$1" =~ ^https://(secure\.gravatar\.com|[a-z0-9.-]*\.slack-edge\.com)/ ]]; }

# Slack serves avatars as .webp, which Qt here can't decode. Download the
# avatar (https-pinned, size-capped) and convert it to a small local PNG that
# Qt renders natively; cache per user id. Echoes the local PNG path, or
# nothing on failure. Only ever fetches from validated Slack hosts.
cache_avatar() {
  local uid="$1" url="$2" out="$AVATAR_DIR/$uid.png" tmp
  [[ "$uid" =~ ^[UW][A-Z0-9]{5,30}$ ]] || return 1
  [[ -s "$out" ]] && { printf '%s' "$out"; return 0; }
  valid_avatar "$url" || return 1
  command -v magick >/dev/null 2>&1 || return 1
  mkdir -p "$AVATAR_DIR" 2>/dev/null || return 1
  tmp="$(mktemp "$out.XXXXXX")" || return 1
  # Force JPEG output (this Qt build decodes jpeg via libqjpeg) regardless of
  # the source format (Slack serves webp, which Qt can't read).
  if "${CURL[@]}" --max-time 10 "$url" -o "$tmp.src" 2>/dev/null \
     && magick "$tmp.src" -resize 72x72^ -gravity center -extent 72x72 "jpg:$tmp" 2>/dev/null; then
    mv "$tmp" "$out"; rm -f "$tmp.src"; printf '%s' "$out"; return 0
  fi
  rm -f "$tmp" "$tmp.src" 2>/dev/null; return 1
}

# resolve_users <json array of user ids> — fetches at most MAX_USER_LOOKUPS
# unknown ids, merges into the cache, prints the full cache object.
resolve_users() {
  local ids="$1" cache missing uid info name img local_av fetched=0
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
    name="${name:0:80}"
    img="$(jq -r '.user.profile.image_72 // .user.profile.image_48 // ""' <<<"$info" 2>/dev/null)"
    local_av="$(cache_avatar "$uid" "$img")" || local_av=""
    cache="$(jq -c --arg id "$uid" --arg n "$name" --arg i "$local_av" '.[$id] = {n:$n, i:$i}' <<<"$cache")"
  done <<<"$missing"
  # Bound the cache: 80-char names above, 400 entries here.
  cache="$(jq -c 'to_entries | .[-400:] | from_entries' <<<"$cache")"
  local tmp
  tmp="$(mktemp "$USERS_CACHE.XXXXXX")" && printf '%s' "$cache" > "$tmp" && mv "$tmp" "$USERS_CACHE"
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
    --argjson me "$(jq -c '{team:(.team // ""), team_id:(.team_id // ""), user:(.user // ""), user_id:(.user_id // ""), url:(.url // "")}' <<<"$me")" \
    --argjson rows "$enriched" \
    --argjson users "$users" \
    --argjson presence "$(jq -c '{presence:(.presence // "")}' <<<"$presence" 2>/dev/null || echo '{"presence":""}')" \
    --argjson dnd "$(jq -c '{snoozing:(.snooze_enabled // false), snooze_until:(.snooze_endtime // 0)}' <<<"$dnd" 2>/dev/null || echo '{"snoozing":false,"snooze_until":0}')" \
    --argjson seen "$seen" \
    '{ok:true, team:$me.team, team_id:$me.team_id, self:$me.user, self_id:$me.user_id, url:$me.url, seen:$seen,
      presence:$presence.presence, snoozing:$dnd.snoozing, snooze_until:$dnd.snooze_until,
      capped: ([$rows[] | select(.uncounted == true)] | length > 0),
      conversations: [$rows[] | {
        id, kind, latest,
        unread: (.unread // 0),
        name: (if .kind == "im" then (($users[.user].n) // .user) else .name end),
        avatar: (if .kind == "im" then (($users[.user].i) // "") else "" end),
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

  local msgs uids users out tmp
  # reply_count>0 marks a thread parent; thread_ts is the parent's ts. Only
  # top-level messages are kept here (replies are shown via `thread`).
  msgs="$(jq -c '[.messages[]? | select(.type == "message")
    | {ts: (.ts // ""), user: (.user // ""), bot: (.bot_id // ""),
       username: (.username // ""), subtype: (.subtype // ""),
       reply_count: (.reply_count // 0), thread_ts: (.thread_ts // ""),
       reactions: [((.reactions // [])[]) | {name, count}],
       text: ((.text // "") | .[0:8000])}] | reverse' <<<"$res")"
  uids="$(jq -c '[.[] | .user | select(. != "")]' <<<"$msgs")"
  users="$(resolve_users "$uids")"
  # channel rides along so the UI can drop a payload that arrives after the
  # user has already switched conversations.
  out="$(jq -cn --arg ch "$id" --argjson m "$msgs" --argjson u "$users" '{ok:true, channel:$ch, messages:$m, users:$u}')"
  tmp="$(mktemp "$cache_file.XXXXXX")" && printf '%s' "$out" > "$tmp" && mv "$tmp" "$cache_file"
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------- thread

# thread <channel> <thread_ts> — replies in a thread (conversations.replies).
# Same output shape as history (messages + users + avatars), cached per
# channel+ts on the same 60s budget.
cmd_thread() {
  require_token
  local id="${1:-}" ts="${2:-}"
  valid_channel "$id" || emit_error "bad channel id"
  valid_ts "$ts" || emit_error "bad ts"

  local cache_file="$CACHE_DIR/thread-$id-$ts.json" now age
  now="$(date +%s)"
  if [[ -s "$cache_file" ]]; then
    age=$(( now - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if (( age < HISTORY_CACHE_SECS )); then
      jq -c '. + {cached:true}' "$cache_file" 2>/dev/null && exit 0
    fi
  fi

  local res
  res="$(api_call conversations.replies -G \
    --data-urlencode "channel=$id" \
    --data-urlencode "ts=$ts" \
    --data-urlencode "limit=50")" || emit_error "network error fetching thread"
  if ! jq -e '.ok == true' <<<"$res" >/dev/null 2>&1; then
    local err
    err="$(jq -r '.error // "thread failed"' <<<"$res" 2>/dev/null || echo "thread failed")"
    if [[ "$err" == "ratelimited" && -s "$cache_file" ]]; then
      jq -c '. + {cached:true, ratelimited:true}' "$cache_file" 2>/dev/null && exit 0
    fi
    emit_error "$err"
  fi

  local msgs uids users out tmp
  # conversations.replies returns the parent first then replies, oldest→newest.
  msgs="$(jq -c '[.messages[]? | select(.type == "message")
    | {ts: (.ts // ""), user: (.user // ""), bot: (.bot_id // ""),
       username: (.username // ""), subtype: (.subtype // ""),
       reply_count: (.reply_count // 0), thread_ts: (.thread_ts // ""),
       reactions: [((.reactions // [])[]) | {name, count}],
       text: ((.text // "") | .[0:8000])}]' <<<"$res")"
  uids="$(jq -c '[.[] | .user | select(. != "")]' <<<"$msgs")"
  users="$(resolve_users "$uids")"
  out="$(jq -cn --arg ch "$id" --arg ts "$ts" --argjson m "$msgs" --argjson u "$users" \
    '{ok:true, channel:$ch, thread_ts:$ts, messages:$m, users:$u}')"
  tmp="$(mktemp "$cache_file.XXXXXX")" && printf '%s' "$out" > "$tmp" && mv "$tmp" "$cache_file"
  printf '%s\n' "$out"
}

# ----------------------------------------------------------------------- send

cmd_send() {
  require_token
  local id="${1:-}" thread_ts="${2:-}"
  valid_channel "$id" || emit_error "bad channel id"
  # Optional thread_ts: reply into a thread instead of the channel root.
  local body_base
  if [[ -n "$thread_ts" ]]; then
    valid_ts "$thread_ts" || emit_error "bad thread ts"
  fi
  local text
  text="$(head -c $((MAX_MSG_CHARS * 4)) | head -c "$MAX_MSG_CHARS")"
  [[ -z "${text//[$' \t\r\n']/}" ]] && emit_error "empty message"

  if [[ -n "$thread_ts" ]]; then
    body_base="$(jq -cn --arg ch "$id" --arg t "$text" --arg tt "$thread_ts" '{channel:$ch, text:$t, thread_ts:$tt}')"
  else
    body_base="$(jq -cn --arg ch "$id" --arg t "$text" '{channel:$ch, text:$t}')"
  fi
  local res
  res="$(printf '%s' "$body_base" \
    | api_call chat.postMessage -X POST -H 'Content-Type: application/json; charset=utf-8' --data-binary @-)" \
    || emit_error "network error sending message"
  jq -c '{ok:.ok, error:(.error // ""), ts:(.ts // "")}' <<<"$res" 2>/dev/null || emit_error "unexpected reply"
  # A successful send makes the cached history/thread stale immediately.
  if jq -e '.ok == true' <<<"$res" >/dev/null 2>&1; then
    rm -f "$CACHE_DIR/hist-$id.json"
    [[ -n "$thread_ts" ]] && rm -f "$CACHE_DIR/thread-$id-$thread_ts.json"
  fi
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
  local tmp
  tmp="$(mktemp "$SEEN_FILE.XXXXXX")" && printf '%s' "$seen" > "$tmp" && mv "$tmp" "$SEEN_FILE"

  local res marked=false
  res="$(jq -cn --arg ch "$id" --arg ts "$ts" '{channel:$ch, ts:$ts}' \
    | api_call conversations.mark -X POST \
        -H 'Content-Type: application/json; charset=utf-8' \
        --data-binary @- 2>/dev/null || echo '{}')"
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
  thread)          shift; cmd_thread "$@" ;;
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
