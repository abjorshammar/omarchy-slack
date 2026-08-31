#!/bin/bash
# Slack API helper for the bottelet.slack Omarchy plugin.
#
# Every subcommand prints exactly one JSON object on stdout — {ok:false,error}
# on any failure — so the QML side never has to guess. The token is read from
# GNOME Keyring (secret-tool) when available, else from a 0600 file, and is
# only ever handed to curl through a process-substitution header file so it
# never appears on any process's argv.
#
# Multi-workspace: tokens, caches and API calls are namespaced by Slack team
# id. Every command takes an optional leading `--team <T…>`; without it the
# command acts on the active workspace recorded in the registry
# (~/.config/omarchy-slack/workspaces.json), which holds no secrets.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-slack"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-slack"
LEGACY_TOKEN_FILE="$CONFIG_DIR/token"     # pre-multi-workspace single token
TOKENS_DIR="$CONFIG_DIR/tokens"           # one 0600 file per team id
REGISTRY="$CONFIG_DIR/workspaces.json"    # metadata only — never a token
SEEN_FILE="$CACHE_DIR/seen.json"          # global; keys are "<team>/<channel>"
COUNTS_CACHE="$CACHE_DIR/counts.json"     # last counts-all payload, for first paint
API="https://slack.com/api"

# Per-team state, filled in by set_team_paths.
TEAM_ID=""
TEAM_CACHE=""
USERS_CACHE=""    # v2: values are {n,i}, i is a local PNG path
AVATAR_DIR=""
FILE_DIR=""
CONV_STATE=""

# Bounds. Slack method responses are small; the caps exist so a hostile or
# misbehaving endpoint cannot stream without end into the shell process.
MAX_BYTES=4194304          # 4 MiB per response
# Both are overridable for a tighter or roomier rate budget, and are forced
# back to their defaults if set to anything but a number — they are handed
# straight to jq.
MAX_CONV_INFO="${MAX_CONV_INFO:-30}"   # conversations.info calls per counts cycle
HOT_SECONDS="${HOT_SECONDS:-5400}"     # activity this recent is polled every cycle
[[ "$MAX_CONV_INFO" =~ ^[0-9]{1,4}$ ]] || MAX_CONV_INFO=30
[[ "$HOT_SECONDS" =~ ^[0-9]{1,9}$ ]] || HOT_SECONDS=5400
CONV_STATE_TTL=2592000     # 30d: forget a conversation not seen in that long
MAX_USER_LOOKUPS=20        # users.info calls per cycle
MAX_FILE_FETCH=12          # image thumbnails downloaded per history call
FILE_CACHE_DAYS=30         # cached thumbnails are pruned after this long
MAX_UPLOAD_BYTES=26214400  # 25 MiB: Slack's own per-file limit for uploads
MAX_MSG_CHARS=4000         # chat.postMessage text cap (Slack's own limit)
MAX_WORKSPACES=8           # workspaces polled by counts-all
PARALLEL_MAX=4             # concurrent transfers in a batched curl (rate-safe)
HISTORY_CACHE_SECS=60      # non-Marketplace apps: conversations.history is 1 req/min

TOKEN_RE='^xox[pb]-[A-Za-z0-9-]{10,200}$'

CURL=(curl -sS --proto '=https' --proto-redir '=https' --max-filesize "$MAX_BYTES")

emit_error() { jq -cn --arg e "$1" '{ok:false,error:$e}'; exit 0; }

# Everything this script writes is private to the user: cached DMs, read
# markers, the OAuth code in flight. 0700/0600 across the board, and repair
# directories created by older builds.
umask 077
mkdir -p "$CACHE_DIR" || emit_error "cannot create cache dir"
chmod 700 "$CACHE_DIR" 2>/dev/null || true

# write_atomic <path> <content> — mktemp (0600 under our umask) then rename, so
# a planted symlink at the destination is replaced rather than written through.
write_atomic() {
  local dest="$1" content="$2" tmp
  tmp="$(mktemp "$dest.XXXXXX")" || return 1
  printf '%s' "$content" > "$tmp" && mv -f "$tmp" "$dest"
}

# ------------------------------------------------------------ id validation

# Team ids become a path component and a keyring attribute, so they are
# validated before any filesystem or secret-store use. [TE]: workspaces are
# T…, Enterprise Grid orgs are E….
valid_team() { [[ "$1" =~ ^[TE][A-Z0-9]{2,30}$ ]]; }
valid_channel() { [[ "$1" =~ ^[CDGW][A-Z0-9]{5,30}$ ]]; }
valid_user() { [[ "$1" =~ ^[UW][A-Z0-9]{5,30}$ ]]; }
valid_file() { [[ "$1" =~ ^F[A-Z0-9]{5,30}$ ]]; }
valid_ts() { [[ "$1" =~ ^[0-9]{1,12}\.[0-9]{1,8}$ ]]; }

# set_team_paths <team_id> — point the per-workspace caches at that team.
set_team_paths() {
  valid_team "$1" || return 1
  TEAM_ID="$1"
  TEAM_CACHE="$CACHE_DIR/$TEAM_ID"
  USERS_CACHE="$TEAM_CACHE/users-v2.json"
  CONV_STATE="$TEAM_CACHE/convstate.json"
  AVATAR_DIR="$TEAM_CACHE/avatars"
  FILE_DIR="$TEAM_CACHE/files"
  mkdir -p "$TEAM_CACHE" 2>/dev/null || return 1
  chmod 700 "$TEAM_CACHE" 2>/dev/null || true
}

# ------------------------------------------------------------------ registry

# The registry is display metadata only — team name, your name, poll flag —
# so the UI can draw the workspace rail without a network call or a keyring
# unlock. Tokens never appear here.
registry_read() {
  if [[ -s "$REGISTRY" ]]; then
    jq -c 'if type == "object" then
             {active: (.active // ""),
              workspaces: [(.workspaces // [])[] | select(type == "object" and (.team_id // "") != "")]}
           else {active:"", workspaces:[]} end' "$REGISTRY" 2>/dev/null \
      || echo '{"active":"","workspaces":[]}'
  else
    echo '{"active":"","workspaces":[]}'
  fi
}

registry_write() {
  mkdir -p "$CONFIG_DIR" 2>/dev/null || return 1
  chmod 700 "$CONFIG_DIR" 2>/dev/null || true
  write_atomic "$REGISTRY" "$1"
}

# registry_upsert <team_id> <team> <user> <user_id> <url> — add or refresh a
# workspace in place, preserving list order (the rail's order) and any
# existing poll flag.
registry_upsert() {
  local reg
  reg="$(registry_read)"
  # Names come from Slack and are display data only (every Text rendering them
  # is PlainText, tooltips included) — bounded here the same way user display
  # names are in resolve_users.
  reg="$(jq -c --arg t "$1" --arg team "$2" --arg u "$3" --arg uid "$4" --arg url "$5" '
    ($team | .[0:80]) as $team | ($u | .[0:80]) as $u |
    .workspaces = (if (.workspaces | map(.team_id) | index($t)) != null
      then (.workspaces | map(if .team_id == $t
             then . + {team:$team, user:$u, user_id:$uid, url:$url} else . end))
      else (.workspaces + [{team_id:$t, team:$team, user:$u, user_id:$uid, url:$url, poll:true}])
      end)
    | .active = (if (.active // "") == "" then $t else .active end)' <<<"$reg")" || return 1
  registry_write "$reg"
}

registry_set_active() {
  local reg
  reg="$(registry_read)"
  reg="$(jq -c --arg t "$1" '.active = $t' <<<"$reg")" || return 1
  registry_write "$reg"
}

# registry_remove <team_id> — drop a workspace and hand `active` to whatever
# is left, so the UI is never pointed at a workspace that no longer exists.
registry_remove() {
  local reg
  reg="$(registry_read)"
  reg="$(jq -c --arg t "$1" '
    .workspaces = [.workspaces[] | select(.team_id != $t)]
    | .active = (if .active == $t then (.workspaces[0].team_id // "") else .active end)' <<<"$reg")" || return 1
  registry_write "$reg"
}

# The workspace commands act on when no --team is given: the recorded active
# one, else the first registered.
active_team() {
  local reg a
  reg="$(registry_read)"
  a="$(jq -r '.active // ""' <<<"$reg")"
  if [[ -n "$a" ]] && valid_team "$a"; then printf '%s' "$a"; return 0; fi
  a="$(jq -r '.workspaces[0].team_id // ""' <<<"$reg")"
  if [[ -n "$a" ]] && valid_team "$a"; then printf '%s' "$a"; return 0; fi
  return 1
}

# ---------------------------------------------------------------- token store

have_keyring() { command -v secret-tool >/dev/null 2>&1; }

# libsecret matches on an attribute SUBSET: `secret-tool clear service
# omarchy-slack key token` also deletes an item that additionally carries
# team=…. So per-workspace tokens use a DIFFERENT key value rather than the
# legacy `token` plus an extra attribute — attribute values must match
# exactly, which makes the two namespaces genuinely disjoint. Without this,
# migration's cleanup of the legacy entry wiped the token it had just
# written, and the removal command in older docs would wipe every workspace.
KEYRING_KEY="ws-token"          # per-workspace items
KEYRING_KEY_LEGACY="token"      # the single pre-multi-workspace item

# Descriptor-bound no-follow read: a planted symlink or irregular file at the
# token path is refused outright instead of trusted via a pathname check that
# races. python3 is already a dependency (oauth-callback.py).
read_token_file() {
  python3 - "$1" <<'PY' 2>/dev/null | tr -d '[:space:]'
import os, stat, sys
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
except OSError:
    sys.exit(1)
st = os.fstat(fd)
if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
    sys.exit(1)
sys.stdout.write(os.read(fd, 512).decode("utf-8", "replace"))
PY
}

# read_token <team_id> — keyring first (keyed by team), else the 0600 file.
read_token() {
  local team="$1" t=""
  valid_team "$team" || return 1
  if have_keyring; then
    t="$(timeout 3 secret-tool lookup service omarchy-slack key "$KEYRING_KEY" team "$team" 2>/dev/null || true)"
  fi
  if [[ -z "$t" && -e "$TOKENS_DIR/$team" ]]; then
    t="$(read_token_file "$TOKENS_DIR/$team")"
  fi
  [[ "$t" =~ $TOKEN_RE ]] || return 1
  printf '%s' "$t"
}

# store_raw_token <team_id> <token> — keyring first, 0600 file otherwise.
# Sets STORED. Returns non-zero if the token could not be persisted at all.
store_raw_token() {
  local team="$1" t="$2"
  valid_team "$team" || return 1
  if have_keyring && printf '%s' "$t" \
    | timeout 3 secret-tool store --label="Omarchy Slack token ($team)" service omarchy-slack key "$KEYRING_KEY" team "$team" 2>/dev/null; then
    STORED="keyring"
    rm -f "$TOKENS_DIR/$team" 2>/dev/null
    return 0
  fi
  (
    umask 077
    mkdir -p "$TOKENS_DIR" || exit 1
    chmod 700 "$TOKENS_DIR" 2>/dev/null || true
    tmp="$(mktemp "$TOKENS_DIR/.token.XXXXXX")" || exit 1
    printf '%s\n' "$t" > "$tmp" || { rm -f "$tmp"; exit 1; }
    mv -f "$tmp" "$TOKENS_DIR/$team"
  ) || return 1
  STORED="file"
}

# forget_token <team_id> — remove the secret and every trace of that workspace.
forget_token() {
  local team="$1"
  valid_team "$team" || return 1
  if have_keyring; then
    timeout 3 secret-tool clear service omarchy-slack key "$KEYRING_KEY" team "$team" 2>/dev/null || true
  fi
  rm -f "$TOKENS_DIR/$team" 2>/dev/null
  rm -rf "${CACHE_DIR:?}/$team" 2>/dev/null
  # The first-paint payload still names this workspace; drop it rather than
  # flash a signed-out workspace on the next open.
  rm -f "$COUNTS_CACHE" 2>/dev/null
  # Drop that workspace's read markers from the shared seen map.
  if [[ -s "$SEEN_FILE" ]]; then
    local s
    s="$(jq -c --arg t "$team" 'if type == "object"
           then with_entries(select(.key | startswith($t + "/") | not)) else {} end' "$SEEN_FILE" 2>/dev/null)"
    [[ -n "$s" ]] && write_atomic "$SEEN_FILE" "$s"
  fi
  registry_remove "$team"
}

# ------------------------------------------------------------------ migration

# One-time move from the pre-multi-workspace layout: a single token at a
# team-less keyring key or ~/.config/omarchy-slack/token, with caches sitting
# directly in the cache dir. The team id comes from auth.test, which status
# already had to call — so this costs no extra request.
migrate_legacy() {
  [[ -s "$REGISTRY" ]] && return 0
  local t=""
  if have_keyring; then
    t="$(timeout 3 secret-tool lookup service omarchy-slack key "$KEYRING_KEY_LEGACY" 2>/dev/null || true)"
  fi
  if [[ -z "$t" && -e "$LEGACY_TOKEN_FILE" ]]; then
    t="$(read_token_file "$LEGACY_TOKEN_FILE")"
  fi
  t="${t//[$'\t\r\n ']/}"
  [[ "$t" =~ $TOKEN_RE ]] || return 1

  local res tid
  TOKEN="$t"
  res="$(api_call auth.test -X POST)" || return 1
  jq -e '.ok == true' <<<"$res" >/dev/null 2>&1 || return 1
  tid="$(jq -r '.team_id // ""' <<<"$res")"
  valid_team "$tid" || return 1

  store_raw_token "$tid" "$t" || return 1
  # Only drop the old copy once the new one reads back — never leave the user
  # with no token because a keyring write silently failed.
  read_token "$tid" >/dev/null || return 1

  registry_upsert "$tid" \
    "$(jq -r '.team // ""' <<<"$res")" \
    "$(jq -r '.user // ""' <<<"$res")" \
    "$(jq -r '.user_id // ""' <<<"$res")" \
    "$(jq -r '.url // ""' <<<"$res")"
  registry_set_active "$tid"
  migrate_legacy_cache "$tid"

  # Safe now only because the per-workspace items use a different key value:
  # this clear cannot reach the one just written.
  if have_keyring; then
    timeout 3 secret-tool clear service omarchy-slack key "$KEYRING_KEY_LEGACY" 2>/dev/null || true
  fi
  rm -f "$LEGACY_TOKEN_FILE" 2>/dev/null
  return 0
}

# Caches that used to live directly under the cache dir move under the team,
# and seen.json's bare channel ids become "<team>/<channel>".
migrate_legacy_cache() {
  local tid="$1" f
  mkdir -p "$CACHE_DIR/$tid" 2>/dev/null || return 1
  chmod 700 "$CACHE_DIR/$tid" 2>/dev/null || true
  for f in users-v2.json avatars; do
    [[ -e "$CACHE_DIR/$f" ]] && mv "$CACHE_DIR/$f" "$CACHE_DIR/$tid/$f" 2>/dev/null
  done
  for f in "$CACHE_DIR"/hist-*.json "$CACHE_DIR"/thread-*.json; do
    [[ -e "$f" ]] && mv "$f" "$CACHE_DIR/$tid/" 2>/dev/null
  done
  # The user cache stores each avatar as an ABSOLUTE path, so moving the file
  # is not enough — those paths still point at the pre-migration location.
  # resolve_users only fetches ids it does not already know, so a stale entry
  # never heals itself: without this every already-cached user would lose
  # their avatar permanently.
  if [[ -s "$CACHE_DIR/$tid/users-v2.json" ]]; then
    local u
    u="$(jq -c --arg old "$CACHE_DIR/avatars/" --arg new "$CACHE_DIR/$tid/avatars/" '
      if type == "object" then
        with_entries(.value |= (if type == "object" and ((.i // "") | startswith($old))
          then .i = ($new + (.i | .[($old | length):]))
          else . end))
      else {} end' "$CACHE_DIR/$tid/users-v2.json" 2>/dev/null)"
    [[ -n "$u" ]] && write_atomic "$CACHE_DIR/$tid/users-v2.json" "$u"
  fi
  if [[ -s "$SEEN_FILE" ]]; then
    local s
    s="$(jq -c --arg t "$tid" 'if type == "object"
           then with_entries(if (.key | test("/")) then . else .key = ($t + "/" + .key) end)
           else {} end' "$SEEN_FILE" 2>/dev/null)"
    [[ -n "$s" ]] && write_atomic "$SEEN_FILE" "$s"
  fi
  return 0
}

# ------------------------------------------------------- sign-in confirmation

# verify_and_store <token> — identify the workspace the token belongs to, then
# store it under that team and register it. A token is never persisted before
# Slack tells us whose it is, so it can always be attributed to a workspace.
verify_and_store() {
  local t="$1" res tid
  TOKEN="$t"
  res="$(api_call auth.test -X POST)" || emit_error "network error talking to slack.com"
  jq -e '.ok == true' <<<"$res" >/dev/null 2>&1 || {
    jq -c '{ok:false, error:(.error // "auth failed")}' <<<"$res" 2>/dev/null || emit_error "auth failed"
    exit 0
  }
  tid="$(jq -r '.team_id // ""' <<<"$res")"
  valid_team "$tid" || emit_error "slack did not identify the workspace"

  store_raw_token "$tid" "$t" || emit_error "could not save the token"
  set_team_paths "$tid" || emit_error "could not create the workspace cache"
  registry_upsert "$tid" \
    "$(jq -r '.team // ""' <<<"$res")" \
    "$(jq -r '.user // ""' <<<"$res")" \
    "$(jq -r '.user_id // ""' <<<"$res")" \
    "$(jq -r '.url // ""' <<<"$res")"
  registry_set_active "$tid"

  jq -c --arg s "$STORED" --argjson n "$(registry_read | jq -c '.workspaces | length')" \
    '{ok:true, error:"", stored:$s, team:(.team // ""), team_id:(.team_id // ""),
      user:(.user // ""), user_id:(.user_id // ""), url:(.url // ""), workspaces:$n}' <<<"$res" 2>/dev/null \
    || emit_error "unexpected reply from slack.com"
  exit 0
}

store_token() { # token on stdin
  local t
  IFS= read -r t || true
  t="${t//[$'\t\r\n ']/}"
  [[ "$t" =~ $TOKEN_RE ]] || emit_error "that does not look like a Slack token (expected xoxp-… or xoxb-…)"
  verify_and_store "$t"
}

# clear-token [--all | --team <id>] — forget the selected workspace (default:
# the active one), or every workspace at once. `--team` is accepted here as
# well as before the subcommand, since that is how the command reads.
clear_token() {
  local all=false
  while (( $# )); do
    case "$1" in
      --all)    all=true; shift ;;
      --team)   TEAM_ID="${2:-}"; shift 2 2>/dev/null || shift
                valid_team "$TEAM_ID" || emit_error "bad workspace id" ;;
      --team=*) TEAM_ID="${1#--team=}"; shift
                valid_team "$TEAM_ID" || emit_error "bad workspace id" ;;
      *)        shift ;;
    esac
  done

  if [[ "$all" == true ]]; then
    local reg tid
    reg="$(registry_read)"
    while IFS= read -r tid; do
      [[ -n "$tid" ]] && valid_team "$tid" && forget_token "$tid"
    done <<<"$(jq -r '.workspaces[].team_id' <<<"$reg")"
    # Sweep both namespaces, so a workspace missing from the registry does not
    # leave an orphaned secret behind.
    if have_keyring; then
      timeout 3 secret-tool clear service omarchy-slack key "$KEYRING_KEY" 2>/dev/null || true
      timeout 3 secret-tool clear service omarchy-slack key "$KEYRING_KEY_LEGACY" 2>/dev/null || true
    fi
    rm -f "$LEGACY_TOKEN_FILE" 2>/dev/null
    rm -rf "$CACHE_DIR" 2>/dev/null
    rm -rf "$TOKENS_DIR" 2>/dev/null
    rm -f "$REGISTRY" 2>/dev/null
    jq -cn '{ok:true, workspaces:0}'
    exit 0
  fi

  local tid="${TEAM_ID:-}"
  [[ -z "$tid" ]] && tid="$(active_team || true)"
  if [[ -z "$tid" ]]; then
    # Nothing registered: still clear a stale pre-multi-workspace token.
    if have_keyring; then timeout 3 secret-tool clear service omarchy-slack key "$KEYRING_KEY_LEGACY" 2>/dev/null || true; fi
    rm -f "$LEGACY_TOKEN_FILE" 2>/dev/null
    rm -rf "$CACHE_DIR" 2>/dev/null
    jq -cn '{ok:true, workspaces:0}'
    exit 0
  fi
  forget_token "$tid" || emit_error "could not remove that workspace"
  jq -cn --argjson n "$(registry_read | jq -c '.workspaces | length')" \
         --arg a "$(active_team || true)" '{ok:true, workspaces:$n, active:$a}'
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

OAUTH_SCOPES="channels:read,groups:read,im:read,mpim:read,channels:history,groups:history,im:history,mpim:history,chat:write,users:read,dnd:read,dnd:write,users:write,files:read,files:write"

# Marking a conversation read on your phone and in the official clients needs
# write access to each conversation type. They are heavier permissions than
# anything else here, so the browser flow asks for them only when the user
# opts in with "sync_read_state": true in oauth.json — the same scopes the
# paste-a-token path gets from the docs/OWN-APP.md manifest. The Slack app
# must declare them under User Token Scopes too, or Slack rejects the
# authorize request with invalid_scope.
OAUTH_SCOPES_WRITE="channels:write,groups:write,im:write,mpim:write"

oauth_scopes() {
  if [[ "$(jq -r '.sync_read_state // false' <<<"$1" 2>/dev/null)" == "true" ]]; then
    printf '%s,%s' "$OAUTH_SCOPES" "$OAUTH_SCOPES_WRITE"
  else
    printf '%s' "$OAUTH_SCOPES"
  fi
}

# Browser sign-in doubles as "add a workspace": you pick the workspace on
# Slack's own consent page, and the token comes back tagged with its team.
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
  local redirect auth_url scopes
  scopes="$(oauth_scopes "$cfg")"
  redirect="$proxy/callback"
  auth_url="https://slack.com/oauth/v2/authorize?client_id=$cid&user_scope=$(jq -rn --arg s "$scopes" '$s|@uri')&state=$(jq -rn --arg s "$state" '$s|@uri')&redirect_uri=$(jq -rn --arg u "$redirect" '$u|@uri')"

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
  verify_and_store "$token"
}

# Whether browser sign-in is available (client id + proxy url configured).
cmd_login_available() {
  local cfg
  if cfg="$(oauth_config)"; then
    # Report the exact scope list the browser flow will ask for, so what the
    # consent screen shows is inspectable before anyone clicks it.
    jq -cn --argjson sync "$(jq -c '.sync_read_state // false' <<<"$cfg")" \
           --arg scopes "$(oauth_scopes "$cfg")" \
      '{ok:true, available:true, sync_read_state:$sync, scopes:$scopes}'
  else
    jq -cn --arg scopes "$OAUTH_SCOPES" '{ok:true, available:false, sync_read_state:false, scopes:$scopes}'
  fi
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

# Resolve the workspace this invocation acts on (--team, else active) and load
# its token and caches.
require_token() {
  local tid="${TEAM_ID:-}"
  [[ -z "$tid" ]] && tid="$(active_team || true)"
  [[ -n "$tid" ]] || emit_error "no token"
  valid_team "$tid" || emit_error "bad workspace id"
  TOKEN="$(read_token "$tid")" || emit_error "no token"
  set_team_paths "$tid" || emit_error "cannot create cache dir"
}

# ----------------------------------------------------------------- user names

# Per-workspace cache: user ids are only unique within a workspace, so a
# shared map would show the wrong name (and face) on a DM.
# Cache shape: { "U123": {"n":"Display Name","i":"/…/avatars/U123.png"}, … }.
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
# Qt renders natively; cache per user id, under this workspace's cache dir.
# Echoes the local PNG path, or nothing on failure.
# batch_users_info <json-array-of-user-ids> — parallel users.info, returns
# {uid: {name, img}}: name resolved with the display→real→username fallback and
# 80-capped, img the best avatar URL or "".
batch_users_info() {
  local ids="$1" n
  n="$(jq 'length' <<<"$ids" 2>/dev/null || echo 0)"
  (( n == 0 )) && { echo '{}'; return 0; }

  local outdir
  outdir="$(mktemp -d "$TEAM_CACHE/.usr.XXXXXX")" || { echo '{}'; return 1; }
  # uids are [UW][A-Z0-9]+ so safe unencoded in the query string.
  while IFS= read -r uid; do
    [[ -z "$uid" ]] && continue
    valid_user "$uid" || continue
    printf '%s\t%s\n' "$API/users.info?user=$uid" "$outdir/$uid.json"
  done < <(jq -r '.[]' <<<"$ids" 2>/dev/null) | run_batch 1

  local result
  result="$(cat "$outdir"/*.json 2>/dev/null | jq -sc '
    reduce .[] as $r ({};
      if ($r.ok == true and ($r.user.id // "") != "")
      then .[$r.user.id] = {
             name: (((($r.user.profile.display_name // "") | select(. != ""))
                     // $r.user.real_name // $r.user.name // "") | .[0:80]),
             img: ($r.user.profile.image_72 // $r.user.profile.image_48 // "")}
      else . end)' 2>/dev/null || echo '{}')"
  rm -rf "$outdir"
  printf '%s' "${result:-\{\}}"
}

# batch_cache_avatars <json-object {uid: url}> — download the valid, not-yet-
# cached avatars in ONE parallel curl, then convert each to a local PNG. Same
# raster-only guard as before (never feed SVG/MVG to ImageMagick). Best-effort;
# a failed download or convert just leaves that user without a local avatar.
# Avatars live on public CDN hosts (allowlisted per url), so no auth header.
batch_cache_avatars() {
  local map="$1"
  command -v magick >/dev/null 2>&1 || return 0
  mkdir -p "$AVATAR_DIR" 2>/dev/null || return 0
  local dldir
  dldir="$(mktemp -d "$AVATAR_DIR/.dl.XXXXXX")" || return 0

  # Avatars are public CDN objects (host allowlisted per url) — no auth header.
  while IFS=$'\t' read -r uid url; do
    [[ -z "$uid" || -z "$url" ]] && continue
    [[ "$uid" =~ ^[UW][A-Z0-9]{5,30}$ ]] || continue
    [[ -s "$AVATAR_DIR/$uid.png" ]] && continue
    valid_avatar "$url" || continue
    printf '%s\t%s\n' "$url" "$dldir/$uid.src"
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$map" 2>/dev/null) | run_batch 0

  local src u mime
  for src in "$dldir"/*.src; do
    [[ -e "$src" ]] || continue
    u="$(basename "$src" .src)"
    mime="$(file -b --mime-type "$src" 2>/dev/null || echo "")"
    case "$mime" in
      image/png|image/jpeg|image/gif|image/webp|image/bmp) : ;;
      *) rm -f "$src"; continue ;;
    esac
    # Force jpeg output (this Qt build decodes jpeg via libqjpeg); resource
    # limits guard against decompression bombs; [0] reads only the first frame.
    magick -limit memory 64MiB -limit disk 128MiB \
      "$src[0]" -resize 72x72^ -gravity center -extent 72x72 "jpg:$AVATAR_DIR/$u.png" 2>/dev/null
    rm -f "$src"
  done
  rm -rf "$dldir"
}

# Slack file thumbnails live behind an auth wall on files.slack.com, so the
# QML side cannot load one directly — Image has nowhere to put a bearer token,
# and giving it one would put the token in a URL. They are fetched here
# instead, with the same batched curl everything else uses, and cached under
# the workspace's own 0700 dir.
valid_file_url() { [[ "$1" =~ ^https://files\.slack\.com/ ]]; }

# cache_files <json object {file_id: thumb_url}> — download the not-yet-cached
# thumbnails in ONE parallel authenticated curl. Unlike avatars these need no
# ImageMagick pass: Slack's thumbnails are already small jpeg/png, which Qt
# decodes natively, so the file is kept as it came provided it really is one
# of those. Anything else is dropped rather than handed to an image decoder.
# Best-effort — a file that fails to download just renders as its name.
cache_files() {
  local map="$1"
  mkdir -p "$FILE_DIR" 2>/dev/null || return 0
  chmod 700 "$FILE_DIR" 2>/dev/null || true
  # Images accumulate for as long as the conversations do; drop the ones that
  # have not been looked at in a month rather than growing without bound.
  find "$FILE_DIR" -maxdepth 1 -type f -atime "+$FILE_CACHE_DAYS" -delete 2>/dev/null || true

  local dldir
  dldir="$(mktemp -d "$FILE_DIR/.dl.XXXXXX")" || return 0
  while IFS=$'\t' read -r fid url; do
    [[ -z "$fid" || -z "$url" ]] && continue
    valid_file "$fid" || continue
    valid_file_url "$url" || continue
    compgen -G "$FILE_DIR/$fid.*" >/dev/null 2>&1 && continue
    printf '%s\t%s\n' "$url" "$dldir/$fid.src"
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$map" 2>/dev/null) | run_batch 1

  local src fid mime
  for src in "$dldir"/*.src; do
    [[ -e "$src" ]] || continue
    fid="$(basename "$src" .src)"
    # A token without files:read is bounced to an HTML sign-in page rather
    # than refused, so trust the bytes, never the request having "worked".
    mime="$(file -b --mime-type "$src" 2>/dev/null || echo "")"
    case "$mime" in
      image/jpeg) mv -f "$src" "$FILE_DIR/$fid.jpg" ;;
      image/png)  mv -f "$src" "$FILE_DIR/$fid.png" ;;
      *)          rm -f "$src" ;;
    esac
  done
  rm -rf "$dldir"
}

# cached_file <file_id> — the local thumbnail's path, or "".
cached_file() {
  local f
  for f in "$FILE_DIR/$1.jpg" "$FILE_DIR/$1.png"; do
    [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  printf ''
}

# attach_files <messages-json> — download the image thumbnails these messages
# reference (capped, batched, already-cached ones skipped) and stamp each file
# with the local `path` it landed at. A file that has no local copy — not an
# image, download failed, or the token lacks files:read — keeps path "" and
# the UI shows its name instead.
attach_files() {
  local msgs="$1" want have
  want="$(jq -c --argjson cap "$MAX_FILE_FETCH" '
    [ .[].files[]?
      | select((.mime // "") | startswith("image/"))
      | select((.id // "") != "" and (.url // "") != "") ]
    | unique_by(.id) | .[0:$cap]
    | map({key: .id, value: .url}) | from_entries' <<<"$msgs" 2>/dev/null || echo '{}')"
  [[ "$(jq 'length' <<<"$want" 2>/dev/null || echo 0)" -gt 0 ]] && cache_files "$want"

  # Which ids ended up as a real image on disk, so `path` is never a path to a
  # file that isn't there (the QML side would try to load it and fail). `find`
  # rather than a glob, and the fallback outside the pipeline — see the same
  # note in resolve_users.
  have="$(find "$FILE_DIR" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.png' \) -printf '%f\n' 2>/dev/null \
           | jq -R . | jq -sc 'map(select(length > 0))
             | map({key: (sub("\\.(jpg|png)$"; "")), value: .}) | from_entries')"
  [[ -n "$have" ]] || have='{}'
  jq -c --argjson h "$have" --arg dir "$FILE_DIR" '
    [ .[] | .files = [ .files[]?
        | . + {path: (if $h[.id] then ($dir + "/" + $h[.id]) else "" end)} ] ]' <<<"$msgs" \
    2>/dev/null || printf '%s' "$msgs"
}

# resolve_users <json array of user ids> — fetches at most MAX_USER_LOOKUPS
# unknown ids in one parallel batch (with their avatars in another), merges
# into the cache, prints the full cache object.
resolve_users() {
  local ids="$1" cache missing info_map have
  cache="$(load_users_cache)"
  missing="$(jq -c --argjson cache "$cache" --argjson cap "$MAX_USER_LOOKUPS" '
    [ .[] | select($cache[.] == null) ] | unique
    | map(select(test("^[UW][A-Z0-9]{5,30}$"))) | .[0:$cap]' <<<"$ids" 2>/dev/null || echo '[]')"

  if [[ "$(jq 'length' <<<"$missing" 2>/dev/null || echo 0)" -gt 0 ]]; then
    info_map="$(batch_users_info "$missing")"
    batch_cache_avatars "$(jq -c 'with_entries(select(.value.img != "")) | with_entries(.value = .value.img)' <<<"$info_map")"
    # Which uids ended up with a real PNG on disk — so `i` is never a path to a
    # file that isn't there (the QML side would try to load it and fail).
    # `find` is used rather than a glob because it still exits 0 when the
    # directory is empty: under `pipefail` a failing glob made the pipeline
    # fail *after* jq had already printed, so the `|| echo` fallback appended
    # a second document and every later --argjson choked on it.
    have="$(find "$AVATAR_DIR" -maxdepth 1 -type f -name '*.png' -printf '%f\n' 2>/dev/null \
             | sed 's#\.png$##' | jq -R . | jq -sc 'map(select(length > 0))')"
    [[ -n "$have" ]] || have='[]'
    cache="$(jq -c --argjson info "$info_map" --argjson have "$have" --arg dir "$AVATAR_DIR" '
      ($have | map({key: ., value: true}) | from_entries) as $h
      | reduce ($info | to_entries[] | select(.value.name != "")) as $e (.;
          .[$e.key] = { n: $e.value.name,
                        i: (if $h[$e.key] then ($dir + "/" + $e.key + ".png") else "" end) })' <<<"$cache")"
  fi
  # Bound the cache at 400 entries.
  cache="$(jq -c 'to_entries | .[-400:] | from_entries' <<<"$cache")"
  write_atomic "$USERS_CACHE" "$cache"
  printf '%s' "$cache"
}

# --------------------------------------------------------------------- counts

# The shared read-marker map, keyed "<team>/<channel>".
# Per-conversation polling state: {"<channel>": {latest, unread, checked}}.
# Local bookkeeping only — it decides which conversations the next cycle
# spends its conversations.info budget on, and supplies the last known unread
# for the ones it skips. Lives in the workspace's own 0700 cache dir.
load_conv_state() {
  [[ -n "$CONV_STATE" && -s "$CONV_STATE" ]] || { echo '{}'; return 0; }
  jq -c 'if type == "object" then . else {} end' "$CONV_STATE" 2>/dev/null || echo '{}'
}

save_conv_state() {
  local content="$1"
  [[ -n "$CONV_STATE" && -n "$content" ]] || return 0
  jq -e 'type == "object"' <<<"$content" >/dev/null 2>&1 || return 0
  write_atomic "$CONV_STATE" "$content" 2>/dev/null || true
}

load_seen() {
  if [[ -s "$SEEN_FILE" ]]; then
    jq -c 'if type == "object" then . else {} end' "$SEEN_FILE" 2>/dev/null || echo '{}'
  else
    printf '{}' > "$SEEN_FILE" 2>/dev/null || true
    echo '{}'
  fi
}

# run_batch <with_auth 0|1> — read TAB-separated "url<TAB>outfile" lines on
# stdin and fetch them all in ONE parallel curl. Everything (including the bearer
# token, when with_auth=1) travels in a curl config piped on stdin via `-K -`,
# so — exactly like the single-call process-substitution path — the token never
# touches argv and never lands in a file on disk. The same https-pin, size and
# time caps as elsewhere are set as global config options.
run_batch() {
  local with_auth="$1"
  {
    printf 'parallel\nparallel-max = %s\nproto = "=https"\nproto-redir = "=https"\nmax-filesize = %s\nmax-time = 20\nsilent\nshow-error\n' \
      "$PARALLEL_MAX" "$MAX_BYTES"
    (( with_auth )) && printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
    local url out
    while IFS=$'\t' read -r url out; do
      [[ -z "$url" || -z "$out" ]] && continue
      # A double-quote or newline would break the config line; no legitimate
      # URL here contains one (ids are validated, avatar hosts allowlisted).
      case "$url" in *'"'*|*$'\n'*) continue ;; esac
      printf 'url = "%s"\noutput = "%s"\n' "$url" "$out"
    done
  } | curl -K - 2>/dev/null
}

# batch_conversations_info <json-array-of-channel-ids> — fetch conversations.info
# for every id in ONE parallel curl instead of one process per id, and return a
# single JSON object mapping channel id -> {unread, latest}. Each id is
# regex-validated before it can become a request or a filename. Empty -> "{}".
batch_conversations_info() {
  local ids="$1" n
  n="$(jq 'length' <<<"$ids" 2>/dev/null || echo 0)"
  (( n == 0 )) && { echo '{}'; return 0; }

  local outdir
  outdir="$(mktemp -d "$TEAM_CACHE/.info.XXXXXX")" || { echo '{}'; return 1; }
  # ids are [CDGW][A-Z0-9]+ so safe unencoded in the query string.
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    valid_channel "$id" || continue
    printf '%s\t%s\n' "$API/conversations.info?channel=$id" "$outdir/$id.json"
  done < <(jq -r '.[]' <<<"$ids" 2>/dev/null) | run_batch 1

  # Assemble every response in ONE jq pass (no per-id accumulator).
  local result
  result="$(cat "$outdir"/*.json 2>/dev/null | jq -sc '
    reduce .[] as $r ({};
      if ($r.ok == true and ($r.channel.id // "") != "")
      then .[$r.channel.id] = {
             unread: ($r.channel.unread_count_display // $r.channel.unread_count // 0),
             latest: ($r.channel.latest.ts // "")}
      else . end)' 2>/dev/null || echo '{}')"
  rm -rf "$outdir"
  printf '%s' "${result:-\{\}}"
}

# counts_payload <types> — one workspace's conversations and unread counts.
# Assumes TOKEN and the per-team paths are already set. Prints the workspace
# object without the (global) seen map.
counts_payload() {
  local types="$1"
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

  # Unread counts. Slack has no bulk unread endpoint for a user token, so each
  # conversation costs one conversations.info and only MAX_CONV_INFO of them
  # fit in a cycle's rate budget. Which ones is the interesting part: picking
  # the same first 30 every time left the rest permanently reading zero (with
  # 70 DMs, no channel was ever checked at all).
  #
  # So the budget is spent in two tiers, from remembered per-conversation
  # state: everything active within HOT_SECONDS first, so a live conversation
  # refreshes every cycle, then the remainder fills with the least recently
  # checked, which rotates the whole list through over a few cycles. Anything
  # not checked this cycle keeps the unread and ts it was last seen with
  # rather than reporting zero, or a conversation would blink unread off and
  # on as the rotation passed it.
  #
  # ponytail: a message in a conversation dormant for longer than HOT_SECONDS
  # waits for the sweep to reach it (a few cycles). Only a push channel would
  # fix that, and Slack offers none to a user token.
  local ordered enriched details to_fetch state now
  now="$(date +%s)"
  state="$(load_conv_state)"
  ordered="$(jq -c --argjson st "$state" --argjson now "$now" --argjson hot "$HOT_SECONDS" '
    [ .[]
      | select(.id | test("^[CDGW][A-Z0-9]{5,30}$"))
      | . + {_s: ($st[.id] // {})} ]
    | sort_by([ (if (((._s.latest // "") | tonumber? // 0) > ($now - $hot)) then 0 else 1 end),
                (._s.checked // 0) ])' <<<"$base")"
  to_fetch="$(jq -c --argjson cap "$MAX_CONV_INFO" '[.[range(0; ([length, $cap] | min))].id]' <<<"$ordered")"
  details="$(batch_conversations_info "$to_fetch")"
  # A row missing from the batch was either not selected or its request
  # failed; both fall back to what we remember, never to a bare zero.
  enriched="$(jq -c --argjson d "$details" '
    [ .[]
      | if $d[.id] then . + $d[.id]
        else . + {unread: (._s.unread // 0), latest: (._s.latest // ""), uncounted: true} end
      | del(._s) ]' <<<"$ordered")"
  save_conv_state "$(jq -c --argjson st "$state" --argjson now "$now" --argjson ttl "$CONV_STATE_TTL" '
    reduce (to_entries[]) as $e ($st;
      .[$e.key] = {latest: ($e.value.latest // ""), unread: ($e.value.unread // 0), checked: $now})
    | with_entries(select((.value.checked // 0) > ($now - $ttl)))' <<<"$details")"

  # Resolve DM counterpart names through this workspace's user cache.
  local dm_ids users
  dm_ids="$(jq -c '[.[] | select(.kind == "im") | .user | select(. != "")]' <<<"$enriched")"
  users="$(resolve_users "$dm_ids")"

  # Presence + DND are cheap and round out the header.
  local presence dnd
  presence="$(api_call users.getPresence -G 2>/dev/null || echo '{}')"
  dnd="$(api_call dnd.info -G 2>/dev/null || echo '{}')"

  # Every conversation carries `key` — "<team>/<channel>" — the identity the
  # shared seen map and the QML side use, so the convention lives in one place.
  jq -cn \
    --arg team_id "$TEAM_ID" \
    --argjson me "$(jq -c '{team:(.team // ""), team_id:(.team_id // ""), user:(.user // ""), user_id:(.user_id // ""), url:(.url // "")}' <<<"$me")" \
    --argjson rows "$enriched" \
    --argjson users "$users" \
    --argjson presence "$(jq -c '{presence:(.presence // "")}' <<<"$presence" 2>/dev/null || echo '{"presence":""}')" \
    --argjson dnd "$(jq -c '{snoozing:(.snooze_enabled // false), snooze_until:(.snooze_endtime // 0)}' <<<"$dnd" 2>/dev/null || echo '{"snoozing":false,"snooze_until":0}')" \
    '{ok:true, team:$me.team, team_id:(if $me.team_id != "" then $me.team_id else $team_id end),
      self:$me.user, self_id:$me.user_id, url:$me.url,
      presence:$presence.presence, snoozing:$dnd.snoozing, snooze_until:$dnd.snooze_until,
      capped: ([$rows[] | select(.uncounted == true)] | length > 0),  # some rows carry remembered counts, not fresh ones
      conversations: [$rows[] | {
        id, kind, latest,
        key: ($team_id + "/" + .id),
        unread: (.unread // 0),
        name: (if .kind == "im" then (($users[.user].n) // .user) else .name end),
        avatar: (if .kind == "im" then (($users[.user].i) // "") else "" end),
        user: (.user // "")
      }]}'
}

cmd_counts() {
  require_token
  local out
  out="$(counts_payload "${1:-im,mpim,public_channel,private_channel}")"
  jq -c --argjson seen "$(load_seen)" '. + {seen:$seen}' <<<"$out" 2>/dev/null \
    || printf '%s\n' "$out"
}

# counts_one <team_id> <types> — one workspace, in isolation, always tagged
# with its team id (and name, where the registry knows it) even on failure, so
# a workspace that is rate limited or signed out still gets a rail tile.
counts_one() {
  local tid="$1" types="$2" name out
  name="$(registry_read | jq -r --arg t "$tid" '.workspaces[] | select(.team_id == $t) | .team // ""' 2>/dev/null)"
  out="$(
    set_team_paths "$tid" || { jq -cn '{ok:false,error:"cannot create cache dir"}'; exit 0; }
    TOKEN="$(read_token "$tid")" || { jq -cn '{ok:false,error:"no token"}'; exit 0; }
    counts_payload "$types"
  )"
  jq -c --arg t "$tid" --arg n "$name" \
    '. + {team_id: (if (.team_id // "") != "" then .team_id else $t end),
          team: (if (.team // "") != "" then .team else $n end)}' <<<"$out" 2>/dev/null \
    || jq -cn --arg t "$tid" --arg n "$name" '{ok:false, team_id:$t, team:$n, error:"unexpected reply"}'
}

# counts-all — every polled workspace in one payload, fetched in parallel.
# The bar badge and the workspace rail both read this, so neither has to fan
# out into one process per workspace.
cmd_counts_all() {
  migrate_legacy || true
  local types="${1:-im,mpim,public_channel,private_channel}"
  [[ "$types" =~ ^[a-z_,]+$ ]] || emit_error "bad types"

  local reg order tmpd tid n=0
  reg="$(registry_read)"
  order="$(jq -c '[.workspaces[].team_id]' <<<"$reg")"
  tmpd="$(mktemp -d "$CACHE_DIR/.counts.XXXXXX")" || emit_error "cannot create cache dir"
  # Killed mid-poll, the per-workspace scratch files would otherwise pile up
  # in the cache dir with conversation metadata in them.
  trap 'rm -rf "$tmpd" 2>/dev/null' EXIT TERM INT

  local pids=()
  while IFS= read -r tid; do
    [[ -z "$tid" ]] && continue
    valid_team "$tid" || continue
    (( n >= MAX_WORKSPACES )) && break
    n=$((n + 1))
    counts_one "$tid" "$types" > "$tmpd/$tid.json" 2>/dev/null &
    pids+=("$!")
  done <<<"$(jq -r '.workspaces[] | select(.poll != false) | .team_id' <<<"$reg")"
  local p
  for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2>/dev/null; done

  local ws="[]"
  if compgen -G "$tmpd/*.json" >/dev/null 2>&1; then
    ws="$(cat "$tmpd"/*.json 2>/dev/null \
      | jq -sc --argjson order "$order" 'sort_by(. as $w | ($order | index($w.team_id)) // 999)' 2>/dev/null)" \
      || ws="[]"
    [[ -n "$ws" ]] || ws="[]"
  fi
  rm -rf "$tmpd" 2>/dev/null
  trap - EXIT TERM INT

  # `registered` counts every workspace in the registry, polled or not, so the
  # UI can tell "one workspace" from "one being polled" without guessing.
  local payload
  payload="$(jq -cn --argjson ws "$ws" --argjson seen "$(load_seen)" \
         --argjson registered "$(jq -c '.workspaces | length' <<<"$reg")" \
         --arg active "$(active_team || true)" \
    '{ok:true, active:$active, registered:$registered, seen:$seen, workspaces:$ws}')" || return 1
  # Kept on disk so the next window or bar start has something to draw before
  # its own fetch returns — see counts-cached.
  write_atomic "$COUNTS_CACHE" "$payload" 2>/dev/null || true
  printf '%s\n' "$payload"
}

# counts-cached — the last counts-all payload, straight off disk, no network.
# The UI paints this the moment it opens and then polls; without it the
# sidebar and the bar badge sit empty for the length of a full fetch.
cmd_counts_cached() {
  local miss='{"ok":false,"error":"no cache"}'
  [[ -s "$COUNTS_CACHE" ]] || { printf '%s\n' "$miss"; return 0; }
  # Read markers move locally as conversations are read, so the payload's copy
  # of them is as old as the file. Splice the live one in, or a conversation
  # read since the last poll would light up again on every open.
  jq -c --argjson seen "$(load_seen)" \
    'if .ok == true then . + {seen:$seen, cached:true} else {ok:false,error:"no cache"} end' \
    "$COUNTS_CACHE" 2>/dev/null || printf '%s\n' "$miss"
}

# workspaces — the registry, plus whether each still has a usable token. No
# network: this is what the UI draws the workspace rail from.
cmd_workspaces() {
  migrate_legacy || true
  local reg out="[]" tid row
  reg="$(registry_read)"
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    tid="$(jq -r '.team_id // ""' <<<"$row")"
    valid_team "$tid" || continue
    local has=false
    read_token "$tid" >/dev/null 2>&1 && has=true
    out="$(jq -c --argjson r "$row" --argjson h "$has" '. + [$r + {has_token:$h}]' <<<"$out")"
  done <<<"$(jq -c '.workspaces[]' <<<"$reg")"
  jq -cn --argjson ws "$out" --arg a "$(active_team || true)" \
    '{ok:true, active:$a, workspaces:$ws}'
}

# use <team_id> — make a workspace the one commands act on by default, and
# remember it across restarts.
cmd_use() {
  local tid="${1:-}"
  valid_team "$tid" || emit_error "bad workspace id"
  registry_read | jq -e --arg t "$tid" '[.workspaces[].team_id] | index($t) != null' >/dev/null 2>&1 \
    || emit_error "not signed in to that workspace"
  registry_set_active "$tid" || emit_error "could not save the active workspace"
  jq -cn --arg a "$tid" '{ok:true, active:$a}'
}

# -------------------------------------------------------------------- history

cmd_history() {
  require_token
  local id="${1:-}"
  valid_channel "$id" || emit_error "bad channel id"

  # Non-Marketplace Slack apps created after May 2025 get 1 history request
  # per minute (15 messages). Serve a fresh-enough cache instead of burning it.
  # The budget is per app-per-workspace, so each workspace caches separately.
  local cache_file="$TEAM_CACHE/hist-$id.json" now age
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
  # reply_count>0 marks a thread parent; thread_ts is the parent's ts. Only
  # top-level messages are kept here (replies are shown via `thread`).
  msgs="$(jq -c '[.messages[]? | select(.type == "message")
    | {ts: (.ts // ""), user: (.user // ""), bot: (.bot_id // ""),
       username: (.username // ""), subtype: (.subtype // ""),
       reply_count: (.reply_count // 0), thread_ts: (.thread_ts // ""),
       reactions: [((.reactions // [])[]) | {name, count}],
       files: [((.files // [])[]) | {
         id: (.id // ""), name: ((.name // "") | .[0:120]),
         mime: (.mimetype // ""), size: (.size // 0),
         w: (.thumb_360_w // 0), h: (.thumb_360_h // 0),
         url: (.thumb_360 // "")}],
       text: ((.text // "") | .[0:8000])}] | reverse' <<<"$res")"
  msgs="$(attach_files "$msgs")"
  uids="$(jq -c '[.[] | .user | select(. != "")]' <<<"$msgs")"
  users="$(resolve_users "$uids")"
  # team and channel ride along so the UI can drop a payload that arrives
  # after the user has already switched workspace or conversation.
  out="$(jq -cn --arg t "$TEAM_ID" --arg ch "$id" --argjson m "$msgs" --argjson u "$users" \
    '{ok:true, team_id:$t, channel:$ch, messages:$m, users:$u}')"
  write_atomic "$cache_file" "$out"
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

  local cache_file="$TEAM_CACHE/thread-$id-$ts.json" now age
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

  local msgs uids users out
  # conversations.replies returns the parent first then replies, oldest→newest.
  msgs="$(jq -c '[.messages[]? | select(.type == "message")
    | {ts: (.ts // ""), user: (.user // ""), bot: (.bot_id // ""),
       username: (.username // ""), subtype: (.subtype // ""),
       reply_count: (.reply_count // 0), thread_ts: (.thread_ts // ""),
       reactions: [((.reactions // [])[]) | {name, count}],
       files: [((.files // [])[]) | {
         id: (.id // ""), name: ((.name // "") | .[0:120]),
         mime: (.mimetype // ""), size: (.size // 0),
         w: (.thumb_360_w // 0), h: (.thumb_360_h // 0),
         url: (.thumb_360 // "")}],
       text: ((.text // "") | .[0:8000])}]' <<<"$res")"
  msgs="$(attach_files "$msgs")"
  uids="$(jq -c '[.[] | .user | select(. != "")]' <<<"$msgs")"
  users="$(resolve_users "$uids")"
  out="$(jq -cn --arg t "$TEAM_ID" --arg ch "$id" --arg ts "$ts" --argjson m "$msgs" --argjson u "$users" \
    '{ok:true, team_id:$t, channel:$ch, thread_ts:$ts, messages:$m, users:$u}')"
  write_atomic "$cache_file" "$out"
  printf '%s\n' "$out"
}

# --------------------------------------------------------------------- upload

# clip-image — if the Wayland clipboard holds an image, write it to a private
# file and print its path. This is what makes "screenshot, then paste" work:
# there is no file dialog on this desktop (no zenity, no kdialog), and asking
# QML to hold image bytes would mean passing them through argv.
cmd_clip_image() {
  command -v wl-paste >/dev/null 2>&1 || emit_error "no clipboard tool"
  local types mime ext
  types="$(wl-paste --list-types 2>/dev/null || true)"
  case "$types" in
    *image/png*)  mime=image/png;  ext=png ;;
    *image/jpeg*) mime=image/jpeg; ext=jpg ;;
    *) emit_error "no image on the clipboard" ;;
  esac

  local dir="$CACHE_DIR/outgoing"
  mkdir -p "$dir" 2>/dev/null || emit_error "cannot create cache dir"
  chmod 700 "$dir" 2>/dev/null || true
  # These are only ever a staging area for one send; an abandoned paste should
  # not sit in the cache for the rest of the session.
  find "$dir" -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null || true

  local out
  out="$dir/paste-$(date +%s).$ext"
  wl-paste --type "$mime" > "$out" 2>/dev/null || { rm -f "$out"; emit_error "could not read the clipboard"; }
  # Trust the bytes, not the advertised type — the same rule as for downloads.
  case "$(file -b --mime-type "$out" 2>/dev/null || echo "")" in
    image/png|image/jpeg) : ;;
    *) rm -f "$out"; emit_error "no image on the clipboard" ;;
  esac
  jq -cn --arg p "$out" --arg n "$(basename -- "$out")" '{ok:true, path:$p, name:$n}'
}


# upload <channel> <path> [thread_ts] — share a local file, optional comment
# on stdin. Slack's external-upload flow is three calls: ask for a signed URL,
# POST the bytes to it, then tell Slack to attach the finished file to a
# conversation.
#
# The path arrives from the UI — a clipboard image wl-paste wrote out, or a
# dropped file — so it is never a shell word here (argv only, like every other
# command) and is checked to be a readable regular file within Slack's own
# size limit before anything is sent.
cmd_upload() {
  require_token
  local id="${1:-}" path="${2:-}" thread_ts="${3:-}"
  valid_channel "$id" || emit_error "bad channel id"
  [[ -n "$thread_ts" ]] && { valid_ts "$thread_ts" || emit_error "bad thread ts"; }
  [[ -f "$path" && -r "$path" ]] || emit_error "no such file"
  local size name
  size="$(stat -c %s "$path" 2>/dev/null || echo 0)"
  (( size > 0 )) || emit_error "empty file"
  (( size <= MAX_UPLOAD_BYTES )) || emit_error "file too large"
  # Slack shows this name; keep it a plain basename so a crafted path cannot
  # dress the upload up as something else in the conversation.
  name="$(basename -- "$path")"
  name="${name//[^A-Za-z0-9._-]/_}"
  [[ -n "$name" ]] || name="upload"

  local comment
  comment="$(head -c "$MAX_MSG_CHARS")"

  # 1. A signed, single-use URL to put the bytes at.
  local res upload_url file_id
  res="$(api_call files.getUploadURLExternal -G \
    --data-urlencode "filename=$name" \
    --data-urlencode "length=$size")" || emit_error "network error starting upload"
  jq -e '.ok == true' <<<"$res" >/dev/null 2>&1 \
    || emit_error "$(jq -r '.error // "upload failed"' <<<"$res" 2>/dev/null || echo "upload failed")"
  upload_url="$(jq -r '.upload_url // ""' <<<"$res")"
  file_id="$(jq -r '.file_id // ""' <<<"$res")"
  valid_file "$file_id" || emit_error "upload failed"
  # Slack hands us this URL; it still has to be one of Slack's own hosts over
  # https before we POST a file of the user's to it.
  [[ "$upload_url" =~ ^https://[a-z0-9.-]+\.slack\.com/ ]] || emit_error "upload failed"

  # 2. The bytes. No Authorization header: the URL is itself the credential,
  # and sending the token to a host Slack named would be handing it over.
  # The file rides in on stdin, not inside the -F value: curl gives `;` and
  # `,` meaning there, and a dropped path can contain either.
  "${CURL[@]}" --max-time 120 -o /dev/null -w '%{http_code}' \
    -X POST -F "file=@-;filename=$name" "$upload_url" < "$path" \
    | grep -qE '^2[0-9][0-9]$' || emit_error "upload failed"

  # 3. Attach it to the conversation.
  local body
  body="$(jq -cn --arg fid "$file_id" --arg n "$name" --arg ch "$id" \
                 --arg tt "$thread_ts" --arg c "$comment" '
    {files: [{id: $fid, title: $n}], channel_id: $ch}
    + (if $tt != "" then {thread_ts: $tt} else {} end)
    + (if ($c | gsub("\\s"; "")) != "" then {initial_comment: $c} else {} end)')"
  res="$(printf '%s' "$body" \
    | api_call files.completeUploadExternal -X POST \
        -H 'Content-Type: application/json; charset=utf-8' --data-binary @-)" \
    || emit_error "network error finishing upload"

  jq -c --arg t "$TEAM_ID" \
    '{ok:.ok, error:(.error // ""), ts:((.files[0].timestamp // "") | tostring), team_id:$t}' \
    <<<"$res" 2>/dev/null || emit_error "unexpected reply"
  if jq -e '.ok == true' <<<"$res" >/dev/null 2>&1; then
    rm -f "$TEAM_CACHE/hist-$id.json"
    [[ -n "$thread_ts" ]] && rm -f "$TEAM_CACHE/thread-$id-$thread_ts.json"
  fi
  exit 0
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
  jq -c --arg t "$TEAM_ID" '{ok:.ok, error:(.error // ""), ts:(.ts // ""), team_id:$t}' <<<"$res" 2>/dev/null \
    || emit_error "unexpected reply"
  # A successful send makes the cached history/thread stale immediately.
  if jq -e '.ok == true' <<<"$res" >/dev/null 2>&1; then
    rm -f "$TEAM_CACHE/hist-$id.json"
    [[ -n "$thread_ts" ]] && rm -f "$TEAM_CACHE/thread-$id-$thread_ts.json"
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

  # One map across all workspaces, keyed "<team>/<channel>" so the bar widget
  # keeps watching a single file.
  local seen key="$TEAM_ID/$id"
  seen="$(load_seen)"
  # Keep the newest marker per conversation; bound the map at 500 entries.
  seen="$(jq -c --arg id "$key" --arg ts "$ts" \
    '.[$id] = (if (.[$id] // "0" | tonumber) > ($ts | tonumber) then .[$id] else $ts end)
     | to_entries | sort_by(.value | tonumber) | .[-500:] | from_entries' <<<"$seen")"
  write_atomic "$SEEN_FILE" "$seen"

  local res marked=false
  res="$(jq -cn --arg ch "$id" --arg ts "$ts" '{channel:$ch, ts:$ts}' \
    | api_call conversations.mark -X POST \
        -H 'Content-Type: application/json; charset=utf-8' \
        --data-binary @- 2>/dev/null || echo '{}')"
  jq -e '.ok == true' <<<"$res" >/dev/null 2>&1 && marked=true
  jq -cn --argjson m "$marked" --arg k "$key" '{ok:true, marked:$m, key:$k}'
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
  # watchers have something to watch from the start, and fold a
  # pre-multi-workspace token into the registry.
  [[ -s "$SEEN_FILE" ]] || printf '{}' > "$SEEN_FILE" 2>/dev/null || true
  migrate_legacy || true

  local count tid t
  count="$(registry_read | jq -c '.workspaces | length')"
  tid="${TEAM_ID:-}"
  [[ -z "$tid" ]] && tid="$(active_team || true)"
  if [[ -z "$tid" ]] || ! t="$(read_token "$tid")"; then
    jq -cn --argjson n "$count" '{ok:true, has_token:false, workspaces:$n}'
    exit 0
  fi
  TOKEN="$t"
  local res
  res="$(api_call auth.test -X POST)" \
    || { jq -cn --argjson n "$count" --arg t "$tid" '{ok:true, has_token:true, valid:false, error:"network", team_id:$t, workspaces:$n}'; exit 0; }
  jq -c --argjson n "$count" --arg t "$tid" \
    '{ok:true, has_token:true, valid:(.ok == true), error:(.error // ""),
      team:(.team // ""), team_id:(if (.team_id // "") != "" then .team_id else $t end),
      user:(.user // ""), workspaces:$n}' <<<"$res" 2>/dev/null \
    || jq -cn --argjson n "$count" '{ok:true, has_token:true, valid:false, error:"unexpected reply", workspaces:$n}'
}

# --------------------------------------------------------------------- router

# An optional leading `--team <T…>` selects the workspace for any command.
# Without it, commands act on the active workspace from the registry — which
# is what keeps every pre-multi-workspace call site working unchanged.
while [[ "${1:-}" == --team || "${1:-}" == --team=* ]]; do
  if [[ "${1:-}" == --team=* ]]; then
    TEAM_ID="${1#--team=}"; shift
  else
    TEAM_ID="${2:-}"; shift 2 2>/dev/null || shift
  fi
  [[ -n "$TEAM_ID" ]] || emit_error "bad workspace id"
  valid_team "$TEAM_ID" || emit_error "bad workspace id"
done

case "${1:-}" in
  counts)          shift; cmd_counts "$@" ;;
  counts-all)      shift; cmd_counts_all "$@" ;;
  counts-cached)   shift; cmd_counts_cached ;;
  workspaces)      cmd_workspaces ;;
  use)             shift; cmd_use "$@" ;;
  history)         shift; cmd_history "$@" ;;
  thread)          shift; cmd_thread "$@" ;;
  send)            shift; cmd_send "$@" ;;
  upload)          shift; cmd_upload "$@" ;;
  clip-image)      cmd_clip_image ;;
  seen)            shift; cmd_seen "$@" ;;
  presence)        shift; cmd_presence "$@" ;;
  snooze)          shift; cmd_snooze "$@" ;;
  unsnooze)        shift; cmd_unsnooze "$@" ;;
  status)          cmd_status ;;
  login)           cmd_login ;;
  login-available) cmd_login_available ;;
  set-token)       store_token ;;
  clear-token)     shift; clear_token "$@" ;;
  *)               emit_error "unknown command" ;;
esac
