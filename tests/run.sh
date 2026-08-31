#!/bin/bash
# Offline test suite for scripts/slack.sh. A stub curl serves canned Slack
# responses and records every invocation, so the suite verifies command
# routing, input validation, output shapes, caching, and that the token never
# leaks onto any argv — all without touching the network.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SLACK_SH="$HERE/../scripts/slack.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$WORK/config"
export XDG_CACHE_HOME="$WORK/cache"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

# ---- stub curl -------------------------------------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
export CURL_LOG="$WORK/curl.log"
export CURL_BODY_LOG="$WORK/curl-body.log"

cat > "$STUB_BIN/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "ARGV: $*" >> "$CURL_LOG"
url=""
body=""
outfile=""
avurl=""
prev=""
for a in "$@"; do
  case "$a" in https://slack.com/api/*) url="$a" ;; esac
  case "$a" in https://*.slack-edge.com/*|https://secure.gravatar.com/*) avurl="$a" ;; esac
  if [[ "$prev" == "-o" ]]; then outfile="$a"; fi
  if [[ "$prev" == "--data-binary" || "$prev" == "-d" ]]; then body="$a"; fi
  prev="$a"
done
# Avatar download: emit a real, valid image so cache_avatar's magick convert
# works (magick generates it to guarantee valid PNG data).
if [[ -n "$avurl" && -n "$outfile" ]]; then
  magick -size 8x8 xc:'#3366cc' "png:$outfile" 2>/dev/null || printf 'x' > "$outfile"
  exit 0
fi
if [[ "$body" == "@-" ]]; then body="$(cat)"; fi
[[ -n "$body" ]] && printf '%s\n' "BODY: $body" >> "$CURL_BODY_LOG"
method="${url##*/api/}"
method="${method%%\?*}"
case "$method" in
  auth.test)
    echo '{"ok":true,"url":"https://acme.slack.com/","team":"Acme","user":"casper","team_id":"T111","user_id":"U1111111"}' ;;
  users.conversations)
    echo '{"ok":true,"channels":[
      {"id":"D0AAAAAA1","is_im":true,"user":"U2222222"},
      {"id":"C0BBBBBB2","name":"general","is_channel":true},
      {"id":"G0CCCCCC3","name":"mpdm-a--b-1","is_mpim":true,"is_private":true}]}' ;;
  conversations.info)
    ch=""
    for a in "$@"; do case "$a" in channel=*) ch="${a#channel=}" ;; esac; done
    if [[ "$ch" == D0AAAAAA1 ]]; then
      echo '{"ok":true,"channel":{"id":"D0AAAAAA1","unread_count_display":3,"latest":{"ts":"1755900000.000100"}}}'
    else
      echo '{"ok":true,"channel":{"id":"'"$ch"'","unread_count_display":1,"latest":{"ts":"1755900001.000100"}}}'
    fi ;;
  users.info)
    echo '{"ok":true,"user":{"id":"U2222222","name":"jane","real_name":"Jane Doe","profile":{"display_name":"jane.d","image_72":"https://ca.slack-edge.com/T1-U2-72.png","image_48":"http://insecure.example/x.png"}}}' ;;
  users.getPresence)
    echo '{"ok":true,"presence":"active"}' ;;
  dnd.info)
    echo '{"ok":true,"snooze_enabled":false}' ;;
  conversations.history)
    if [[ -n "${FAKE_RATELIMIT:-}" ]]; then echo '{"ok":false,"error":"ratelimited"}'; exit 0; fi
    echo '{"ok":true,"messages":[
      {"type":"message","ts":"1755900002.000200","user":"U2222222","text":"newest <b>bold</b> &amp; stuff","reply_count":2,"thread_ts":"1755900002.000200"},
      {"type":"message","ts":"1755900001.000100","user":"U1111111","text":"older message"}]}' ;;
  conversations.replies)
    echo '{"ok":true,"messages":[
      {"type":"message","ts":"1755900002.000200","user":"U2222222","text":"parent","reply_count":2,"thread_ts":"1755900002.000200"},
      {"type":"message","ts":"1755900002.000300","user":"U1111111","text":"first reply :tada:","thread_ts":"1755900002.000200"},
      {"type":"message","ts":"1755900002.000400","user":"U2222222","text":"second reply","thread_ts":"1755900002.000200"}]}' ;;
  chat.postMessage)
    echo '{"ok":true,"channel":"D0AAAAAA1","ts":"1755900003.000300"}' ;;
  conversations.mark)
    echo '{"ok":true}' ;;
  users.setPresence|dnd.setSnooze|dnd.endSnooze)
    echo '{"ok":true,"snooze_endtime":1755903600}' ;;
  *)
    echo '{"ok":false,"error":"stub_unknown_method:'"$method"'"}' ;;
esac
STUB
chmod +x "$STUB_BIN/curl"

# No keyring in tests: force the file fallback path.
cat > "$STUB_BIN/secret-tool" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$STUB_BIN/secret-tool"

export PATH="$STUB_BIN:$PATH"

# ---- harness ---------------------------------------------------------------
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { # check <desc> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — got '$2' expected '$3'"; fi
}

run() { bash "$SLACK_SH" "$@"; }

echo "== token handling"
out="$(printf 'not-a-token\n' | run set-token)"
check "rejects malformed token" "$(jq -r '.ok' <<<"$out")" "false"

out="$(printf 'xoxp-1234567890-abcdefME\n' | run set-token)"
check "accepts valid token" "$(jq -r '.ok' <<<"$out")" "true"
check "reports workspace"   "$(jq -r '.team' <<<"$out")" "Acme"
check "stored in file (no keyring)" "$(jq -r '.stored' <<<"$out")" "file"
perms="$(stat -c %a "$XDG_CONFIG_HOME/omarchy-slack/token")"
check "token file is 0600" "$perms" "600"

echo "== counts"
out="$(run counts)"
check "counts ok" "$(jq -r '.ok' <<<"$out")" "true"
check "team name" "$(jq -r '.team' <<<"$out")" "Acme"
check "three conversations" "$(jq -r '.conversations | length' <<<"$out")" "3"
check "dm unread" "$(jq -r '.conversations[] | select(.id=="D0AAAAAA1") | .unread' <<<"$out")" "3"
check "dm name resolved" "$(jq -r '.conversations[] | select(.id=="D0AAAAAA1") | .name' <<<"$out")" "jane.d"
check "dm avatar cached to local png" "$(jq -r '.conversations[] | select(.id=="D0AAAAAA1") | .avatar | test("/omarchy-slack/avatars/U2222222[.]png$")' <<<"$out")" "true"
check "channel kind" "$(jq -r '.conversations[] | select(.id=="C0BBBBBB2") | .kind' <<<"$out")" "channel"
check "presence" "$(jq -r '.presence' <<<"$out")" "active"

echo "== cache privacy"
check "cache dir is 0700" "$(stat -c %a "$XDG_CACHE_HOME/omarchy-slack")" "700"
for f in "$XDG_CACHE_HOME/omarchy-slack"/*; do
  [[ -f "$f" ]] || continue
  perms="$(stat -c %a "$f")"
  if [[ "$perms" != "600" ]]; then fail "cache file $f is $perms, not 600"; else ok "cache file $(basename "$f") is 0600"; fi
done

echo "== history"
out="$(run history D0AAAAAA1)"
check "history ok" "$(jq -r '.ok' <<<"$out")" "true"
check "history names its channel" "$(jq -r '.channel' <<<"$out")" "D0AAAAAA1"
check "chronological order" "$(jq -r '.messages[0].ts' <<<"$out")" "1755900001.000100"
check "user map present (name)" "$(jq -r '.users.U2222222.n' <<<"$out")" "jane.d"
check "history exposes reply_count" "$(jq -r '.messages[] | select(.ts=="1755900002.000200") | .reply_count' <<<"$out")" "2"
check "history exposes thread_ts" "$(jq -r '.messages[] | select(.ts=="1755900002.000200") | .thread_ts' <<<"$out")" "1755900002.000200"
check "avatar cached to local png" "$(jq -r '.users.U2222222.i | test("/omarchy-slack/avatars/U2222222[.]png$")' <<<"$out")" "true"
n_before="$(grep -c conversations.history "$CURL_LOG")"
out="$(run history D0AAAAAA1)"
n_after="$(grep -c conversations.history "$CURL_LOG")"
check "second call served from cache" "$n_after" "$n_before"
check "cache flagged" "$(jq -r '.cached' <<<"$out")" "true"
out="$(run history 'bad;id')"
check "rejects bad channel id" "$(jq -r '.ok' <<<"$out")" "false"

echo "== history rate-limit fallback"
rm -f "$XDG_CACHE_HOME/omarchy-slack"/hist-*.json
out="$(FAKE_RATELIMIT=1 run history D0AAAAAA1)"
check "ratelimited with no cache is an error" "$(jq -r '.ok' <<<"$out")" "false"
run history D0AAAAAA1 >/dev/null                                  # prime cache
touch -d '5 minutes ago' "$XDG_CACHE_HOME/omarchy-slack/hist-D0AAAAAA1.json"
out="$(FAKE_RATELIMIT=1 run history D0AAAAAA1)"
check "ratelimited falls back to stale cache" "$(jq -r '.ok' <<<"$out")" "true"
check "fallback flagged ratelimited" "$(jq -r '.ratelimited' <<<"$out")" "true"

echo "== threads"
out="$(run thread D0AAAAAA1 1755900002.000200)"
check "thread ok" "$(jq -r '.ok' <<<"$out")" "true"
check "thread names its channel" "$(jq -r '.channel' <<<"$out")" "D0AAAAAA1"
check "thread carries thread_ts" "$(jq -r '.thread_ts' <<<"$out")" "1755900002.000200"
check "thread has parent + 2 replies" "$(jq -r '.messages | length' <<<"$out")" "3"
check "thread reply order (parent first)" "$(jq -r '.messages[0].text' <<<"$out")" "parent"
out="$(run thread D0AAAAAA1 'bad;ts')"
check "thread rejects bad ts" "$(jq -r '.ok' <<<"$out")" "false"
# reply into a thread: send with a thread_ts adds thread_ts to the body
printf 'a threaded reply' | run send D0AAAAAA1 1755900002.000200 >/dev/null
body="$(grep '^BODY: ' "$CURL_BODY_LOG" | tail -1 | sed 's/^BODY: //')"
check "threaded send includes thread_ts" "$(jq -r '.thread_ts' <<<"$body")" "1755900002.000200"
out="$(printf 'hi' | run send D0AAAAAA1 'bad;ts')"
check "threaded send rejects bad thread ts" "$(jq -r '.ok' <<<"$out")" "false"

echo "== send"
out="$(printf "hello 'world' \"quotes\" \$(dangerous) \`bits\`" | run send D0AAAAAA1)"
check "send ok" "$(jq -r '.ok' <<<"$out")" "true"
body="$(grep '^BODY: ' "$CURL_BODY_LOG" | tail -1 | sed 's/^BODY: //')"
check "body is valid json" "$(jq -r '.channel' <<<"$body")" "D0AAAAAA1"
check "text survives verbatim" "$(jq -r '.text' <<<"$body")" "hello 'world' \"quotes\" \$(dangerous) \`bits\`"
out="$(printf '   \n' | run send D0AAAAAA1)"
check "rejects blank message" "$(jq -r '.ok' <<<"$out")" "false"
out="$(printf 'hi' | run send 'D0AAAAAA1;rm -rf /')"
check "rejects hostile channel id" "$(jq -r '.ok' <<<"$out")" "false"

echo "== seen / presence / snooze"
out="$(run seen D0AAAAAA1 1755900002.000200)"
check "seen ok" "$(jq -r '.ok' <<<"$out")" "true"
check "seen marks upstream" "$(jq -r '.marked' <<<"$out")" "true"
check "seen persisted" "$(jq -r '.["D0AAAAAA1"]' "$XDG_CACHE_HOME/omarchy-slack/seen.json")" "1755900002.000200"
out="$(run seen D0AAAAAA1 1755900001.000100)"
check "older seen does not regress marker" "$(jq -r '.["D0AAAAAA1"]' "$XDG_CACHE_HOME/omarchy-slack/seen.json")" "1755900002.000200"
out="$(run counts)"
check "counts carries seen map" "$(jq -r '.seen["D0AAAAAA1"]' <<<"$out")" "1755900002.000200"
out="$(run seen D0AAAAAA1 'x;y')"
check "seen rejects bad ts" "$(jq -r '.ok' <<<"$out")" "false"
out="$(run presence away)"
check "presence away ok" "$(jq -r '.ok' <<<"$out")" "true"
out="$(run presence sneaky)"
check "presence validates value" "$(jq -r '.ok' <<<"$out")" "false"
out="$(run snooze 60)"
check "snooze ok" "$(jq -r '.ok' <<<"$out")" "true"
out="$(run snooze '60; reboot')"
check "snooze validates minutes" "$(jq -r '.ok' <<<"$out")" "false"

echo "== oauth login plumbing"
# No proxy ships with the plugin: the exchange host sees the user token, so
# browser sign-in must be off until the user configures their OWN app + proxy.
out="$(run login-available)"
check "login NOT available by default (no shipped proxy)" "$(jq -r '.available' <<<"$out")" "false"
# and the shipped config carries neither a secret nor an operator proxy
check "shipped config ships no secret" "$(jq -r 'has("client_secret")' "$HERE/../config/oauth.json")" "false"
check "shipped config ships no proxy_url" "$(jq -r 'has("proxy_url")' "$HERE/../config/oauth.json")" "false"

mkdir -p "$XDG_CONFIG_HOME/omarchy-slack"
# A valid user-owned config enables the browser flow…
cat > "$XDG_CONFIG_HOME/omarchy-slack/oauth.json" <<'EOF'
{"client_id":"111.222","proxy_url":"https://my-own.example.workers.dev","port":41879}
EOF
out="$(run login-available)"
check "own app + proxy config enables login" "$(jq -r '.available' <<<"$out")" "true"
# …while a malformed one (non-https proxy) is refused, leaving login off.
cat > "$XDG_CONFIG_HOME/omarchy-slack/oauth.json" <<'EOF'
{"client_id":"111.222","proxy_url":"http://insecure.example","port":41879}
EOF
out="$(run login-available)"
check "invalid override leaves login unavailable" "$(jq -r '.available' <<<"$out")" "false"

# Read-state sync needs write scopes on every conversation type. They are
# heavier than the rest, so the browser flow asks for them only on opt-in —
# matching the scope set the paste-a-token path gets from OWN-APP.md.
WRITE_SCOPES="channels:write groups:write im:write mpim:write"
cat > "$XDG_CONFIG_HOME/omarchy-slack/oauth.json" <<'EOF'
{"client_id":"111.222","proxy_url":"https://my-own.example.workers.dev"}
EOF
check "sync off by default" "$(run login-available | jq -r '.sync_read_state')" "false"
scopes="$(run login-available | jq -r '.scopes')"
for w in $WRITE_SCOPES; do
  case ",$scopes," in *,$w,*) fail "default flow requests $w" ;; *) ok "default flow omits $w" ;; esac
done
case ",$scopes," in *,im:history,*) ok "default flow still requests im:history" ;; *) fail "default flow lost im:history" ;; esac

cat > "$XDG_CONFIG_HOME/omarchy-slack/oauth.json" <<'EOF'
{"client_id":"111.222","proxy_url":"https://my-own.example.workers.dev","sync_read_state":true}
EOF
check "sync opt-in is reported" "$(run login-available | jq -r '.sync_read_state')" "true"
scopes="$(run login-available | jq -r '.scopes')"
for w in $WRITE_SCOPES; do
  case ",$scopes," in *,$w,*) ok "opt-in flow requests $w" ;; *) fail "opt-in flow missing $w" ;; esac
done
case ",$scopes," in *,users:read,*) ok "opt-in flow keeps the base scopes" ;; *) fail "opt-in flow dropped base scopes" ;; esac
rm -f "$XDG_CONFIG_HOME/omarchy-slack/oauth.json"

# Token file symlink resistance: a planted symlink must be neither read
# through nor written through.
victim="$WORK/victim-file"
printf 'xoxp-1234567890-SHOULDNOTREAD\n' > "$victim"
mkdir -p "$XDG_CONFIG_HOME/omarchy-slack"
rm -f "$XDG_CONFIG_HOME/omarchy-slack/token"
ln -s "$victim" "$XDG_CONFIG_HOME/omarchy-slack/token"
out="$(run counts 2>/dev/null || true)"
check "symlinked token file is not read through" "$(jq -r '.error // ""' <<<"$out" | grep -c "not signed in\|no token" || true)" "1"
out="$(printf 'xoxp-1234567890-abcdefME\n' | run set-token)"
check "store replaces a planted symlink" "$([ -f "$XDG_CONFIG_HOME/omarchy-slack/token" ] && [ ! -L "$XDG_CONFIG_HOME/omarchy-slack/token" ] && echo yes)" "yes"
check "symlink target was not written through" "$(head -c 40 "$victim")" "xoxp-1234567890-SHOULDNOTREAD"

# The loopback listener in PROXY mode: it waits for ?token=…&state=…, refuses
# wrong state, and prints the token. Browser opener stubbed via PATH.
cat > "$STUB_BIN/xdg-open" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$STUB_BIN/xdg-open"
STATE="0123456789abcdef0123456789abcdef"
PORT=41911
TOK="xoxp-9999999999-proxytesttoken"
python3 "$HERE/../scripts/oauth-callback.py" "$PORT" "$STATE" "https://slack.com/oauth/v2/authorize?x=1" --expect token > "$WORK/oauth-out" &
PYPID=$!
sleep 0.7
# The proxy delivers the token via a form POST (body, not URL). Wrong state is
# refused; the matching POST is accepted and the token printed.
codewrong="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' -X POST --data "token=$TOK&state=wrongstate" "http://127.0.0.1:$PORT/callback")"
check "listener refuses wrong state (POST)" "$codewrong" "403"
codeok="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' -X POST --data "token=$TOK&state=$STATE" "http://127.0.0.1:$PORT/callback")"
check "listener accepts matching state (POST)" "$codeok" "200"
wait "$PYPID"
check "listener exits 0 after token" "$?" "0"
check "listener prints the token" "$(cat "$WORK/oauth-out")" "$TOK"

echo "== status + sign out"
out="$(run status)"
check "status valid" "$(jq -r '.valid' <<<"$out")" "true"
out="$(run clear-token)"
check "clear-token ok" "$(jq -r '.ok' <<<"$out")" "true"
out="$(run status)"
check "status after clear" "$(jq -r '.has_token' <<<"$out")" "false"
out="$(run counts)"
check "counts without token errors" "$(jq -r '.error' <<<"$out")" "no token"

echo "== secrets hygiene"
if grep -q 'xoxp-1234567890' "$CURL_LOG"; then
  fail "token appeared on a curl argv"
else
  ok "token never appeared on any curl argv"
fi

echo
echo "passed $PASS, failed $FAIL"
[[ "$FAIL" == 0 ]]
