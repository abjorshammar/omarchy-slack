#!/bin/bash
# Offline test suite for scripts/slack.sh. A stub curl serves canned Slack
# responses and records every invocation, so the suite verifies command
# routing, input validation, output shapes, caching, per-workspace isolation,
# and that the token never leaks onto any argv — all without touching the
# network.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SLACK_SH="$HERE/../scripts/slack.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$WORK/config"
export XDG_CACHE_HOME="$WORK/cache"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

CFG="$XDG_CONFIG_HOME/omarchy-slack"
CACHE="$XDG_CACHE_HOME/omarchy-slack"
ACME="T0ACME001"
BETA="T0BETA002"
TOK_ACME="xoxp-1234567890-abcdefME"
TOK_BETA="xoxp-2222222222-betaWORKSPACE"

# ---- stub curl -------------------------------------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
export CURL_LOG="$WORK/curl.log"
export CURL_BODY_LOG="$WORK/curl-body.log"

cat > "$STUB_BIN/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "ARGV: $*" >> "$CURL_LOG"

# Which test workspace a token belongs to.
team_of() { case "$1" in *beta*|*BETA*) echo beta ;; *) echo acme ;; esac; }

# respond <method> <channel> <user> <types> <team> — the canned JSON for one
# request, on stdout. Shared by the single-call path and the -K batch path.
respond() {
  local method="$1" ch="$2" user="$3" types="$4" team="$5"
  case "$method" in
    auth.test)
      if [[ "$team" == beta ]]; then
        echo '{"ok":true,"url":"https://beta.slack.com/","team":"Beta Inc","user":"casper.b","team_id":"T0BETA002","user_id":"U9999999"}'
      else
        echo '{"ok":true,"url":"https://acme.slack.com/","team":"Acme","user":"casper","team_id":"T0ACME001","user_id":"U1111111"}'
      fi ;;
    users.conversations)
      if [[ "$team" == beta ]]; then
        echo '{"ok":true,"channels":[{"id":"D0BETADM1","is_im":true,"user":"U2222222"}]}'
      elif [[ "$types" == *public_channel* ]]; then
        echo '{"ok":true,"channels":[
          {"id":"D0AAAAAA1","is_im":true,"user":"U2222222"},
          {"id":"C0BBBBBB2","name":"general","is_channel":true},
          {"id":"G0CCCCCC3","name":"mpdm-a--b-1","is_mpim":true,"is_private":true}]}'
      else
        echo '{"ok":true,"channels":[
          {"id":"D0AAAAAA1","is_im":true,"user":"U2222222"},
          {"id":"G0CCCCCC3","name":"mpdm-a--b-1","is_mpim":true,"is_private":true}]}'
      fi ;;
    conversations.info)
      if [[ "$ch" == D0AAAAAA1 ]]; then
        echo '{"ok":true,"channel":{"id":"D0AAAAAA1","unread_count_display":3,"latest":{"ts":"1755900000.000100"}}}'
      elif [[ "$ch" == D0BETADM1 ]]; then
        echo '{"ok":true,"channel":{"id":"D0BETADM1","unread_count_display":5,"latest":{"ts":"1755900000.000900"}}}'
      else
        echo '{"ok":true,"channel":{"id":"'"$ch"'","unread_count_display":1,"latest":{"ts":"1755900001.000100"}}}'
      fi ;;
    users.info)
      # Same user id, a different person in each workspace — exactly what a
      # shared user cache would get wrong.
      if [[ "$team" == beta ]]; then
        echo '{"ok":true,"user":{"id":"U2222222","name":"bob","real_name":"Bob Beta","profile":{"display_name":"bob.b","image_72":"https://ca.slack-edge.com/T2-U2-72.png"}}}'
      else
        echo '{"ok":true,"user":{"id":"U2222222","name":"jane","real_name":"Jane Doe","profile":{"display_name":"jane.d","image_72":"https://ca.slack-edge.com/T1-U2-72.png","image_48":"http://insecure.example/x.png"}}}'
      fi ;;
    users.getPresence) echo '{"ok":true,"presence":"active"}' ;;
    dnd.info)          echo '{"ok":true,"snooze_enabled":false}' ;;
    conversations.history)
      if [[ -n "${FAKE_RATELIMIT:-}" ]]; then echo '{"ok":false,"error":"ratelimited"}'; return 0; fi
      echo '{"ok":true,"messages":[
        {"type":"message","ts":"1755900002.000200","user":"U2222222","text":"newest <b>bold</b> &amp; stuff","reply_count":2,"thread_ts":"1755900002.000200"},
        {"type":"message","ts":"1755900001.000100","user":"U1111111","text":"older message"}]}' ;;
    conversations.replies)
      echo '{"ok":true,"messages":[
        {"type":"message","ts":"1755900002.000200","user":"U2222222","text":"parent","reply_count":2,"thread_ts":"1755900002.000200"},
        {"type":"message","ts":"1755900002.000300","user":"U1111111","text":"first reply :tada:","thread_ts":"1755900002.000200"},
        {"type":"message","ts":"1755900002.000400","user":"U2222222","text":"second reply","thread_ts":"1755900002.000200"}]}' ;;
    chat.postMessage)  echo '{"ok":true,"channel":"D0AAAAAA1","ts":"1755900003.000300"}' ;;
    conversations.mark) echo '{"ok":true}' ;;
    users.setPresence|dnd.setSnooze|dnd.endSnooze) echo '{"ok":true,"snooze_endtime":1755903600}' ;;
    *) echo '{"ok":false,"error":"stub_unknown_method:'"$method"'"}' ;;
  esac
}

# url -> (method, channel, user, types) and dispatch to respond / avatar.
handle_url() {
  local u="$1" out="$2" team="$3"
  case "$u" in
    https://*.slack-edge.com/*|https://secure.gravatar.com/*)
      # Avatar: emit a real, valid image so cache_avatar's magick convert works.
      if [[ -n "$out" ]]; then magick -size 8x8 xc:'#3366cc' "png:$out" 2>/dev/null || printf 'x' > "$out"; fi
      return 0 ;;
  esac
  local method ch="" user="" types=""
  method="${u##*/api/}"; method="${method%%\?*}"
  case "$u" in *channel=*) ch="${u##*channel=}"; ch="${ch%%&*}" ;; esac
  case "$u" in *user=*)    user="${u##*user=}";  user="${user%%&*}" ;; esac
  case "$u" in *types=*)   types="${u##*types=}"; types="${types%%&*}" ;; esac
  if [[ -n "$out" ]]; then respond "$method" "$ch" "$user" "$types" "$team" > "$out"
  else respond "$method" "$ch" "$user" "$types" "$team"; fi
}

# ---- -K - : a curl config on stdin (the batched path) ----
kmode=0; prev=""
for a in "$@"; do [[ "$prev" == "-K" && "$a" == "-" ]] && kmode=1; prev="$a"; done
if (( kmode )); then
  token=""; url=""
  while IFS= read -r line; do
    case "$line" in
      *"Authorization: Bearer "*) token="${line##*Bearer }"; token="${token%\"*}" ;;
      "url = "*)    url="${line#url = }";    url="${url#\"}";    url="${url%\"}" ;;
      "output = "*) out="${line#output = }"; out="${out#\"}";    out="${out%\"}"
                    [[ -n "$url" ]] && handle_url "$url" "$out" "$(team_of "$token")"; url="" ;;
    esac
  done
  exit 0
fi

# ---- single request (token via -H @file, never argv) ----
url=""; body=""; outfile=""; avurl=""; hdr=""; prev=""
for a in "$@"; do
  case "$a" in https://slack.com/api/*) url="$a" ;; esac
  case "$a" in https://*.slack-edge.com/*|https://secure.gravatar.com/*) avurl="$a" ;; esac
  [[ "$prev" == "-o" ]] && outfile="$a"
  [[ "$prev" == "--data-binary" || "$prev" == "-d" ]] && body="$a"
  if [[ "$prev" == "-H" && "$a" == @* ]]; then f="${a#@}"; [[ -r "$f" ]] && hdr="$hdr$(cat "$f" 2>/dev/null)"; fi
  prev="$a"
done
if [[ -n "$avurl" && -n "$outfile" ]]; then
  magick -size 8x8 xc:'#3366cc' "png:$outfile" 2>/dev/null || printf 'x' > "$outfile"; exit 0
fi
[[ "$body" == "@-" ]] && body="$(cat)"
[[ -n "$body" ]] && printf '%s\n' "BODY: $body" >> "$CURL_BODY_LOG"
tok="${hdr##*Bearer }"; tok="${tok%%$'\n'*}"
method="${url##*/api/}"; method="${method%%\?*}"
ch=""; user=""; types=""
for a in "$@"; do
  case "$a" in channel=*) ch="${a#channel=}" ;; user=*) user="${a#user=}" ;; types=*) types="${a#types=}" ;; esac
done
respond "$method" "$ch" "$user" "$types" "$(team_of "$tok")"
STUB
chmod +x "$STUB_BIN/curl"

# Most of the suite runs with no keyring, to exercise the file fallback.
cat > "$STUB_BIN/secret-tool.absent" <<'STUB'
#!/bin/bash
exit 1
STUB

# …and a working one, for the keyring section. It reproduces the behaviour
# that matters: libsecret matches on an attribute SUBSET, so a lookup or
# clear naming fewer attributes than an item carries still matches it. A bug
# that depended on exactly this once deleted a token immediately after
# storing it, and the always-failing stub could never have caught it.
cat > "$STUB_BIN/secret-tool.working" <<'STUB'
#!/usr/bin/env python3
import glob, hashlib, json, os, sys

store = os.environ["KEYRING_DIR"]
os.makedirs(store, exist_ok=True)
argv = [a for a in sys.argv[1:] if not a.startswith("--label")]
if not argv:
    sys.exit(1)
cmd, rest = argv[0], argv[1:]
query = dict(zip(rest[0::2], rest[1::2]))

def items():
    for path in sorted(glob.glob(os.path.join(store, "*.json"))):
        with open(path) as fh:
            yield path, json.load(fh)

def matches(item):
    # Subset match: every queried attribute must equal the item's, but the
    # item may carry more.
    return all(item["attrs"].get(k) == v for k, v in query.items())

if cmd == "store":
    secret = sys.stdin.read()
    ident = hashlib.sha256(json.dumps(query, sort_keys=True).encode()).hexdigest()[:16]
    with open(os.path.join(store, ident + ".json"), "w") as fh:
        json.dump({"attrs": query, "secret": secret}, fh)
    sys.exit(0)
if cmd == "lookup":
    for _, item in items():
        if matches(item):
            sys.stdout.write(item["secret"])
            sys.exit(0)
    sys.exit(1)
if cmd == "clear":
    for path, item in items():
        if matches(item):
            os.remove(path)
    sys.exit(0)
sys.exit(1)
STUB
chmod +x "$STUB_BIN/secret-tool.absent" "$STUB_BIN/secret-tool.working"
export KEYRING_DIR="$WORK/keyring"
use_keyring()    { cp "$STUB_BIN/secret-tool.working" "$STUB_BIN/secret-tool"; }
use_no_keyring() { cp "$STUB_BIN/secret-tool.absent"  "$STUB_BIN/secret-tool"; }
use_no_keyring

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

out="$(printf '%s\n' "$TOK_ACME" | run set-token)"
check "accepts valid token" "$(jq -r '.ok' <<<"$out")" "true"
check "reports workspace"   "$(jq -r '.team' <<<"$out")" "Acme"
check "reports team id"     "$(jq -r '.team_id' <<<"$out")" "$ACME"
check "stored in file (no keyring)" "$(jq -r '.stored' <<<"$out")" "file"
check "token stored under its team" "$([ -f "$CFG/tokens/$ACME" ] && echo yes)" "yes"
check "no legacy single-token file" "$([ -e "$CFG/token" ] && echo yes || echo no)" "no"
check "token file is 0600" "$(stat -c %a "$CFG/tokens/$ACME")" "600"
check "tokens dir is 0700" "$(stat -c %a "$CFG/tokens")" "700"

echo "== workspace registry"
check "registry created" "$([ -f "$CFG/workspaces.json" ] && echo yes)" "yes"
check "registry holds no token" "$(grep -c 'xoxp-' "$CFG/workspaces.json" || true)" "0"
out="$(run workspaces)"
check "workspaces lists one" "$(jq -r '.workspaces | length' <<<"$out")" "1"
check "workspaces reports active" "$(jq -r '.active' <<<"$out")" "$ACME"
check "workspaces reports team name" "$(jq -r '.workspaces[0].team' <<<"$out")" "Acme"
check "workspaces reports has_token" "$(jq -r '.workspaces[0].has_token' <<<"$out")" "true"

echo "== counts"
out="$(run counts)"
check "counts ok" "$(jq -r '.ok' <<<"$out")" "true"
check "team name" "$(jq -r '.team' <<<"$out")" "Acme"
check "three conversations" "$(jq -r '.conversations | length' <<<"$out")" "3"
check "dm unread" "$(jq -r '.conversations[] | select(.id=="D0AAAAAA1") | .unread' <<<"$out")" "3"
check "dm name resolved" "$(jq -r '.conversations[] | select(.id=="D0AAAAAA1") | .name' <<<"$out")" "jane.d"
check "conversation carries composite key" "$(jq -r '.conversations[] | select(.id=="D0AAAAAA1") | .key' <<<"$out")" "$ACME/D0AAAAAA1"
check "dm avatar cached under its workspace" "$(jq -r '.conversations[] | select(.id=="D0AAAAAA1") | .avatar | test("/omarchy-slack/'"$ACME"'/avatars/U2222222[.]png$")' <<<"$out")" "true"
check "channel kind" "$(jq -r '.conversations[] | select(.id=="C0BBBBBB2") | .kind' <<<"$out")" "channel"
check "presence" "$(jq -r '.presence' <<<"$out")" "active"

echo "== cache privacy"
check "cache dir is 0700" "$(stat -c %a "$CACHE")" "700"
check "workspace cache dir is 0700" "$(stat -c %a "$CACHE/$ACME")" "700"
bad=0
while IFS= read -r f; do
  perms="$(stat -c %a "$f")"
  [[ "$perms" == "600" ]] || { fail "cache file $f is $perms, not 600"; bad=1; }
done < <(find "$CACHE" -type f)
(( bad == 0 )) && ok "every cache file is 0600"

echo "== history"
out="$(run history D0AAAAAA1)"
check "history ok" "$(jq -r '.ok' <<<"$out")" "true"
check "history names its channel" "$(jq -r '.channel' <<<"$out")" "D0AAAAAA1"
check "history names its workspace" "$(jq -r '.team_id' <<<"$out")" "$ACME"
check "chronological order" "$(jq -r '.messages[0].ts' <<<"$out")" "1755900001.000100"
check "user map present (name)" "$(jq -r '.users.U2222222.n' <<<"$out")" "jane.d"
check "history exposes reply_count" "$(jq -r '.messages[] | select(.ts=="1755900002.000200") | .reply_count' <<<"$out")" "2"
check "history exposes thread_ts" "$(jq -r '.messages[] | select(.ts=="1755900002.000200") | .thread_ts' <<<"$out")" "1755900002.000200"
check "avatar cached under its workspace" "$(jq -r '.users.U2222222.i | test("/omarchy-slack/'"$ACME"'/avatars/U2222222[.]png$")' <<<"$out")" "true"
check "history cache lives under its workspace" "$([ -f "$CACHE/$ACME/hist-D0AAAAAA1.json" ] && echo yes)" "yes"
n_before="$(grep -c conversations.history "$CURL_LOG")"
out="$(run history D0AAAAAA1)"
n_after="$(grep -c conversations.history "$CURL_LOG")"
check "second call served from cache" "$n_after" "$n_before"
check "cache flagged" "$(jq -r '.cached' <<<"$out")" "true"
out="$(run history 'bad;id')"
check "rejects bad channel id" "$(jq -r '.ok' <<<"$out")" "false"

echo "== history rate-limit fallback"
rm -f "$CACHE/$ACME"/hist-*.json
out="$(FAKE_RATELIMIT=1 run history D0AAAAAA1)"
check "ratelimited with no cache is an error" "$(jq -r '.ok' <<<"$out")" "false"
run history D0AAAAAA1 >/dev/null                                  # prime cache
touch -d '5 minutes ago' "$CACHE/$ACME/hist-D0AAAAAA1.json"
out="$(FAKE_RATELIMIT=1 run history D0AAAAAA1)"
check "ratelimited falls back to stale cache" "$(jq -r '.ok' <<<"$out")" "true"
check "fallback flagged ratelimited" "$(jq -r '.ratelimited' <<<"$out")" "true"

echo "== threads"
out="$(run thread D0AAAAAA1 1755900002.000200)"
check "thread ok" "$(jq -r '.ok' <<<"$out")" "true"
check "thread names its channel" "$(jq -r '.channel' <<<"$out")" "D0AAAAAA1"
check "thread names its workspace" "$(jq -r '.team_id' <<<"$out")" "$ACME"
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
check "send names its workspace" "$(jq -r '.team_id' <<<"$out")" "$ACME"
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
check "seen key is team-scoped" "$(jq -r '.key' <<<"$out")" "$ACME/D0AAAAAA1"
check "seen persisted" "$(jq -r '.["'"$ACME"'/D0AAAAAA1"]' "$CACHE/seen.json")" "1755900002.000200"
check "seen map stays a single shared file" "$([ -f "$CACHE/seen.json" ] && echo yes)" "yes"
out="$(run seen D0AAAAAA1 1755900001.000100)"
check "older seen does not regress marker" "$(jq -r '.["'"$ACME"'/D0AAAAAA1"]' "$CACHE/seen.json")" "1755900002.000200"
out="$(run counts)"
check "counts carries seen map" "$(jq -r '.seen["'"$ACME"'/D0AAAAAA1"]' <<<"$out")" "1755900002.000200"
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

# ============================ MULTI-WORKSPACE ==============================

echo "== adding a second workspace"
out="$(printf '%s\n' "$TOK_BETA" | run set-token)"
check "second sign-in ok" "$(jq -r '.ok' <<<"$out")" "true"
check "second workspace identified" "$(jq -r '.team_id' <<<"$out")" "$BETA"
check "second workspace named" "$(jq -r '.team' <<<"$out")" "Beta Inc"
check "now two workspaces" "$(jq -r '.workspaces' <<<"$out")" "2"
check "first workspace token untouched" "$([ -f "$CFG/tokens/$ACME" ] && echo yes)" "yes"
check "second token stored separately" "$([ -f "$CFG/tokens/$BETA" ] && echo yes)" "yes"
out="$(run workspaces)"
check "registry lists both" "$(jq -r '.workspaces | length' <<<"$out")" "2"
check "registry keeps add order" "$(jq -r '[.workspaces[].team_id] | join(",")' <<<"$out")" "$ACME,$BETA"
check "newest sign-in becomes active" "$(jq -r '.active' <<<"$out")" "$BETA"

echo "== display names are bounded"
# Team and user names are Slack-controlled display data. Every Text that
# renders them is PlainText (the shell's tooltip included), but they are
# still bounded, the way user display names are.
LONGNAME="$(printf 'N%.0s' $(seq 1 300))"
cat > "$STUB_BIN/curl.longname" <<STUBEOF
#!/bin/bash
if [[ "\$*" == *auth.test* ]]; then
  echo '{"ok":true,"url":"https://x.slack.com/","team":"$LONGNAME","user":"$LONGNAME","team_id":"T0LONG003","user_id":"U8888888"}'
  exit 0
fi
exec "$STUB_BIN/curl.real" "\$@"
STUBEOF
cp "$STUB_BIN/curl" "$STUB_BIN/curl.real"
cp "$STUB_BIN/curl.longname" "$STUB_BIN/curl"; chmod +x "$STUB_BIN/curl"
printf 'xoxp-3333333333-longname\n' | run set-token >/dev/null
len="$(jq -r '.workspaces[] | select(.team_id=="T0LONG003") | .team | length' "$CFG/workspaces.json")"
check "team name bounded in registry" "$len" "80"
len="$(jq -r '.workspaces[] | select(.team_id=="T0LONG003") | .user | length' "$CFG/workspaces.json")"
check "user name bounded in registry" "$len" "80"
cp "$STUB_BIN/curl.real" "$STUB_BIN/curl"; rm -f "$STUB_BIN/curl.longname" "$STUB_BIN/curl.real"
run clear-token --team T0LONG003 >/dev/null
run use "$BETA" >/dev/null

echo "== per-workspace isolation"
out="$(run --team "$BETA" counts)"
check "beta counts ok" "$(jq -r '.ok' <<<"$out")" "true"
check "beta sees its own team" "$(jq -r '.team' <<<"$out")" "Beta Inc"
check "beta sees its own conversations" "$(jq -r '.conversations | length' <<<"$out")" "1"
check "beta dm unread" "$(jq -r '.conversations[0].unread' <<<"$out")" "5"
# U2222222 is a different person in each workspace — a shared user cache
# would have handed Beta the name and face from Acme.
check "same user id resolves per workspace" "$(jq -r '.conversations[0].name' <<<"$out")" "bob.b"
check "beta caches are separate" "$([ -f "$CACHE/$BETA/users-v2.json" ] && echo yes)" "yes"
check "acme user cache still says jane" "$(jq -r '.U2222222.n' "$CACHE/$ACME/users-v2.json")" "jane.d"
check "beta user cache says bob" "$(jq -r '.U2222222.n' "$CACHE/$BETA/users-v2.json")" "bob.b"
check "beta avatar cached under beta" "$([ -f "$CACHE/$BETA/avatars/U2222222.png" ] && echo yes)" "yes"

echo "== --team routing"
out="$(run --team "$ACME" counts)"
check "--team selects acme" "$(jq -r '.team' <<<"$out")" "Acme"
out="$(run --team="$BETA" counts)"
check "--team=X form works" "$(jq -r '.team' <<<"$out")" "Beta Inc"
out="$(run --team 'T0ACME001/../../etc' status)"
check "rejects traversal in team id" "$(jq -r '.error' <<<"$out")" "bad workspace id"
out="$(run --team '../../../etc' counts)"
check "rejects relative path team id" "$(jq -r '.error' <<<"$out")" "bad workspace id"
out="$(run --team 'T0; rm -rf /' history D0AAAAAA1)"
check "rejects shell metachars in team id" "$(jq -r '.error' <<<"$out")" "bad workspace id"
out="$(run --team T0NOSUCH counts)"
check "unknown workspace has no token" "$(jq -r '.error' <<<"$out")" "no token"

echo "== active workspace"
out="$(run use "$ACME")"
check "use switches active" "$(jq -r '.active' <<<"$out")" "$ACME"
out="$(run counts)"
check "commands follow the active workspace" "$(jq -r '.team' <<<"$out")" "Acme"
out="$(run use T0NOSUCH)"
check "use refuses an unknown workspace" "$(jq -r '.ok' <<<"$out")" "false"
out="$(run use 'bad;id')"
check "use validates the team id" "$(jq -r '.error' <<<"$out")" "bad workspace id"
check "active survives across invocations" "$(jq -r '.active' "$CFG/workspaces.json")" "$ACME"

echo "== counts-all"
out="$(run counts-all)"
check "counts-all ok" "$(jq -r '.ok' <<<"$out")" "true"
check "counts-all covers both" "$(jq -r '.workspaces | length' <<<"$out")" "2"
check "counts-all keeps registry order" "$(jq -r '[.workspaces[].team_id] | join(",")' <<<"$out")" "$ACME,$BETA"
check "counts-all reports active" "$(jq -r '.active' <<<"$out")" "$ACME"
check "counts-all reports the registry total" "$(jq -r '.registered' <<<"$out")" "2"
check "counts-all carries one shared seen map" "$(jq -r '.seen["'"$ACME"'/D0AAAAAA1"]' <<<"$out")" "1755900002.000200"
check "acme dm unread in aggregate" "$(jq -r '.workspaces[] | select(.team_id=="'"$ACME"'") | .conversations[] | select(.id=="D0AAAAAA1") | .unread' <<<"$out")" "3"
check "beta dm unread in aggregate" "$(jq -r '.workspaces[] | select(.team_id=="'"$BETA"'") | .conversations[] | select(.id=="D0BETADM1") | .unread' <<<"$out")" "5"
# What the bar badge sums: unread DMs and group DMs across every workspace.
total="$(jq -r '[.workspaces[]? | select(.ok) | .conversations[]? | select(.kind=="im" or .kind=="mpim") | .unread] | add' <<<"$out")"
check "aggregate dm unread across workspaces" "$total" "9"
# A workspace whose token has gone away still gets a tile, tagged and errored.
mv "$CFG/tokens/$BETA" "$WORK/beta.tok"
out="$(run counts-all)"
check "signed-out workspace still listed" "$(jq -r '.workspaces | length' <<<"$out")" "2"
check "signed-out workspace is tagged" "$(jq -r '.workspaces[] | select(.team_id=="'"$BETA"'") | .error' <<<"$out")" "no token"
check "signed-out workspace keeps its name" "$(jq -r '.workspaces[] | select(.team_id=="'"$BETA"'") | .team' <<<"$out")" "Beta Inc"
check "healthy workspace unaffected" "$(jq -r '.workspaces[] | select(.team_id=="'"$ACME"'") | .ok' <<<"$out")" "true"
mv "$WORK/beta.tok" "$CFG/tokens/$BETA"
# poll:false keeps a workspace signed in but out of the background poll.
jq -c '.workspaces |= map(if .team_id == "'"$BETA"'" then . + {poll:false} else . end)' \
  "$CFG/workspaces.json" > "$WORK/reg" && mv "$WORK/reg" "$CFG/workspaces.json"
out="$(run counts-all)"
check "poll:false is skipped by counts-all" "$(jq -r '.workspaces | length' <<<"$out")" "1"
# `registered` counts the registry, not the poll, so the UI can still tell
# that there is more than one workspace to switch between.
check "poll:false still counted as registered" "$(jq -r '.registered' <<<"$out")" "2"
check "poll:false workspace still in registry" "$(run workspaces | jq -r '.workspaces | length')" "2"
jq -c '.workspaces |= map(. + {poll:true})' "$CFG/workspaces.json" > "$WORK/reg" && mv "$WORK/reg" "$CFG/workspaces.json"

echo "== signing out of one workspace"
run --team "$BETA" seen D0BETADM1 1755900000.000900 >/dev/null
check "beta seen marker recorded" "$(jq -r '.["'"$BETA"'/D0BETADM1"]' "$CACHE/seen.json")" "1755900000.000900"
out="$(run clear-token --team "$BETA")"
check "clear one workspace ok" "$(jq -r '.ok' <<<"$out")" "true"
check "one workspace left" "$(jq -r '.workspaces' <<<"$out")" "1"
check "beta token removed" "$([ -e "$CFG/tokens/$BETA" ] && echo yes || echo no)" "no"
check "beta cache removed" "$([ -e "$CACHE/$BETA" ] && echo yes || echo no)" "no"
check "beta seen markers removed" "$(jq -r '.["'"$BETA"'/D0BETADM1"] // "gone"' "$CACHE/seen.json")" "gone"
check "acme token survives" "$([ -f "$CFG/tokens/$ACME" ] && echo yes)" "yes"
check "acme cache survives" "$([ -f "$CACHE/$ACME/users-v2.json" ] && echo yes)" "yes"
check "acme seen markers survive" "$(jq -r '.["'"$ACME"'/D0AAAAAA1"]' "$CACHE/seen.json")" "1755900002.000200"
check "active falls back to the survivor" "$(run workspaces | jq -r '.active')" "$ACME"
out="$(run counts)"
check "still usable after the removal" "$(jq -r '.team' <<<"$out")" "Acme"

echo "== clearing the active workspace promotes another"
printf '%s\n' "$TOK_BETA" | run set-token >/dev/null   # beta back, and active
check "beta is active again" "$(run workspaces | jq -r '.active')" "$BETA"
run clear-token >/dev/null                              # no --team: the active one
check "active workspace was the one cleared" "$([ -e "$CFG/tokens/$BETA" ] && echo yes || echo no)" "no"
check "acme promoted to active" "$(run workspaces | jq -r '.active')" "$ACME"

echo "== migration from a single-workspace install"
rm -rf "$CFG" "$CACHE"
mkdir -p "$CFG" "$CACHE/avatars"
# The pre-multi-workspace layout: one token at the old path, caches sitting
# directly in the cache dir, seen.json keyed by bare channel id.
printf '%s\n' "$TOK_ACME" > "$CFG/token"; chmod 600 "$CFG/token"
printf '{"U2222222":{"n":"jane.d","i":"%s"}}' "$CACHE/avatars/U2222222.png" > "$CACHE/users-v2.json"
printf '{"ok":true,"channel":"D0AAAAAA1","messages":[],"users":{}}' > "$CACHE/hist-D0AAAAAA1.json"
printf '{"D0AAAAAA1":"1755900002.000200"}' > "$CACHE/seen.json"
printf 'x' > "$CACHE/avatars/U2222222.png"
out="$(run status)"
check "migrated install is signed in" "$(jq -r '.has_token' <<<"$out")" "true"
check "migrated install is valid" "$(jq -r '.valid' <<<"$out")" "true"
check "migration learned the team id" "$(jq -r '.team_id' <<<"$out")" "$ACME"
check "migration wrote the registry" "$(jq -r '.workspaces[0].team_id' "$CFG/workspaces.json")" "$ACME"
check "migration set it active" "$(jq -r '.active' "$CFG/workspaces.json")" "$ACME"
check "token moved under its team" "$([ -f "$CFG/tokens/$ACME" ] && echo yes)" "yes"
check "legacy token file removed" "$([ -e "$CFG/token" ] && echo yes || echo no)" "no"
check "user cache moved under its team" "$(jq -r '.U2222222.n' "$CACHE/$ACME/users-v2.json")" "jane.d"
check "history cache moved under its team" "$([ -f "$CACHE/$ACME/hist-D0AAAAAA1.json" ] && echo yes)" "yes"
check "avatars moved under its team" "$([ -f "$CACHE/$ACME/avatars/U2222222.png" ] && echo yes)" "yes"
# The cache stores absolute avatar paths, and resolve_users never refetches an
# id it already knows — so a path left pointing at the old location would
# blank that user's avatar forever.
check "avatar paths inside the cache were rewritten" "$(jq -r '.U2222222.i' "$CACHE/$ACME/users-v2.json")" "$CACHE/$ACME/avatars/U2222222.png"
check "…and the rewritten path exists" "$([ -f "$(jq -r '.U2222222.i' "$CACHE/$ACME/users-v2.json")" ] && echo yes)" "yes"
check "…and Model.js accepts it" "$(command -v node >/dev/null 2>&1 && node -e 'var M=require(process.argv[1]);process.stdout.write(String(M.validAvatar(process.argv[2])))' "$HERE/../Model.js" "$(jq -r '.U2222222.i' "$CACHE/$ACME/users-v2.json")" || echo true)" "true"
check "seen markers re-keyed by team" "$(jq -r '.["'"$ACME"'/D0AAAAAA1"]' "$CACHE/seen.json")" "1755900002.000200"
check "old bare seen key gone" "$(jq -r '.["D0AAAAAA1"] // "gone"' "$CACHE/seen.json")" "gone"
out="$(run counts)"
check "migrated install still works" "$(jq -r '.team' <<<"$out")" "Acme"
# Migration is one-shot: a second run must not disturb a live registry.
before="$(cat "$CFG/workspaces.json")"
run status >/dev/null
check "migration does not re-run" "$(cat "$CFG/workspaces.json")" "$before"

echo "== oauth login plumbing"
# No proxy ships with the plugin: the exchange host sees the user token, so
# browser sign-in must be off until the user configures their OWN app + proxy.
out="$(run login-available)"
check "login NOT available by default (no shipped proxy)" "$(jq -r '.available' <<<"$out")" "false"
# and the shipped config carries neither a secret nor an operator proxy
check "shipped config ships no secret" "$(jq -r 'has("client_secret")' "$HERE/../config/oauth.json")" "false"
check "shipped config ships no proxy_url" "$(jq -r 'has("proxy_url")' "$HERE/../config/oauth.json")" "false"

mkdir -p "$CFG"
# A valid user-owned config enables the browser flow…
cat > "$CFG/oauth.json" <<'EOF'
{"client_id":"111.222","proxy_url":"https://my-own.example.workers.dev","port":41879}
EOF
out="$(run login-available)"
check "own app + proxy config enables login" "$(jq -r '.available' <<<"$out")" "true"
# …while a malformed one (non-https proxy) is refused, leaving login off.
cat > "$CFG/oauth.json" <<'EOF'
{"client_id":"111.222","proxy_url":"http://insecure.example","port":41879}
EOF
out="$(run login-available)"
check "invalid override leaves login unavailable" "$(jq -r '.available' <<<"$out")" "false"

# Read-state sync needs write scopes on every conversation type. They are
# heavier than the rest, so the browser flow asks for them only on opt-in —
# matching the scope set the paste-a-token path gets from OWN-APP.md.
WRITE_SCOPES="channels:write groups:write im:write mpim:write"
cat > "$CFG/oauth.json" <<'EOF'
{"client_id":"111.222","proxy_url":"https://my-own.example.workers.dev"}
EOF
out="$(run login-available)"
check "sync off by default" "$(jq -r '.sync_read_state' <<<"$out")" "false"
scopes="$(run login-available | jq -r '.scopes')"
for w in $WRITE_SCOPES; do
  case ",$scopes," in *,$w,*) fail "default flow requests $w" ;; *) ok "default flow omits $w" ;; esac
done
case ",$scopes," in *,im:history,*) ok "default flow still requests im:history" ;; *) fail "default flow lost im:history" ;; esac

cat > "$CFG/oauth.json" <<'EOF'
{"client_id":"111.222","proxy_url":"https://my-own.example.workers.dev","sync_read_state":true}
EOF
out="$(run login-available)"
check "sync opt-in is reported" "$(jq -r '.sync_read_state' <<<"$out")" "true"
scopes="$(run login-available | jq -r '.scopes')"
for w in $WRITE_SCOPES; do
  case ",$scopes," in *,$w,*) ok "opt-in flow requests $w" ;; *) fail "opt-in flow missing $w" ;; esac
done
case ",$scopes," in *,users:read,*) ok "opt-in flow keeps the base scopes" ;; *) fail "opt-in flow dropped base scopes" ;; esac
rm -f "$CFG/oauth.json"

# Token file symlink resistance: a planted symlink must be neither read
# through nor written through — on the per-workspace path and on the legacy
# path migration still reads.
victim="$WORK/victim-file"
printf 'xoxp-1234567890-SHOULDNOTREAD\n' > "$victim"
mkdir -p "$CFG/tokens"
rm -f "$CFG/tokens/$ACME"
ln -s "$victim" "$CFG/tokens/$ACME"
out="$(run counts 2>/dev/null || true)"
check "symlinked token file is not read through" "$(jq -r '.error // ""' <<<"$out" | grep -c "not signed in\|no token" || true)" "1"
out="$(printf '%s\n' "$TOK_ACME" | run set-token)"
check "store replaces a planted symlink" "$([ -f "$CFG/tokens/$ACME" ] && [ ! -L "$CFG/tokens/$ACME" ] && echo yes)" "yes"
check "symlink target was not written through" "$(head -c 40 "$victim")" "xoxp-1234567890-SHOULDNOTREAD"
# …and the legacy path, which migrate_legacy still reads on upgrade.
rm -f "$CFG/workspaces.json"
ln -s "$victim" "$CFG/token"
out="$(run status)"
check "symlinked legacy token is not migrated" "$(jq -r '.workspaces' <<<"$out")" "0"
rm -f "$CFG/token"

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
printf '%s\n' "$TOK_ACME" | run set-token >/dev/null
printf '%s\n' "$TOK_BETA" | run set-token >/dev/null
out="$(run status)"
check "status valid" "$(jq -r '.valid' <<<"$out")" "true"
check "status counts workspaces" "$(jq -r '.workspaces' <<<"$out")" "2"
check "status names the active workspace" "$(jq -r '.team' <<<"$out")" "Beta Inc"
out="$(run --team "$ACME" status)"
check "status honours --team" "$(jq -r '.team' <<<"$out")" "Acme"
out="$(run clear-token --all)"
check "clear-token --all ok" "$(jq -r '.ok' <<<"$out")" "true"
check "clear-token --all leaves nothing" "$(jq -r '.workspaces' <<<"$out")" "0"
check "all tokens gone" "$([ -e "$CFG/tokens" ] && echo yes || echo no)" "no"
check "registry gone" "$([ -e "$CFG/workspaces.json" ] && echo yes || echo no)" "no"
out="$(run status)"
check "status after clear" "$(jq -r '.has_token' <<<"$out")" "false"
out="$(run counts)"
check "counts without token errors" "$(jq -r '.error' <<<"$out")" "no token"
out="$(run counts-all)"
check "counts-all without any workspace is empty" "$(jq -r '.workspaces | length' <<<"$out")" "0"
check "counts-all registered is zero too" "$(jq -r '.registered' <<<"$out")" "0"
out="$(run workspaces)"
check "workspaces without any is empty" "$(jq -r '.workspaces | length' <<<"$out")" "0"

# The seam the shell tests cannot see: Model.js builds the argv that Quickshell
# hands to Process. A wrong argument order there breaks the app while every
# test above still passes, so run the real builders against the real script.
echo "== keyring backend"
# Everything above ran on the file fallback. These run against a working
# keyring, which is what a real install uses.
use_keyring
rm -rf "$CFG" "$CACHE" "$KEYRING_DIR"

out="$(printf '%s\n' "$TOK_ACME" | run set-token)"
check "keyring is used when present" "$(jq -r '.stored' <<<"$out")" "keyring"
check "no token file is written" "$([ -e "$CFG/tokens/$ACME" ] && echo yes || echo no)" "no"
check "signed in via keyring" "$(run status | jq -r '.valid')" "true"
check "counts works off a keyring token" "$(run counts | jq -r '.team')" "Acme"

printf '%s\n' "$TOK_BETA" | run set-token >/dev/null
check "two workspaces in the keyring" "$(run workspaces | jq -r '[.workspaces[] | select(.has_token)] | length')" "2"

# The regression that matters: libsecret's subset matching means a clear
# naming only the legacy attributes ALSO matches the per-workspace items,
# unless their key value differs. Older docs told users to run exactly this.
secret-tool clear service omarchy-slack key token 2>/dev/null || true
check "a legacy-shaped clear spares workspace tokens" "$(run workspaces | jq -r '[.workspaces[] | select(.has_token)] | length')" "2"
check "…and the app is still signed in" "$(run status | jq -r '.valid')" "true"

# Signing out of one workspace must not take the other's secret with it.
run clear-token --team "$BETA" >/dev/null
check "forgetting one workspace leaves the other" "$(run workspaces | jq -r '[.workspaces[] | select(.has_token)] | length')" "1"
check "the survivor is the right one" "$(run workspaces | jq -r '.workspaces[0].team_id')" "$ACME"

echo "== migration with a keyring"
# The real upgrade path: a single token under the legacy, team-less key.
rm -rf "$CFG" "$CACHE" "$KEYRING_DIR"
mkdir -p "$CACHE"
printf '%s' "$TOK_ACME" | secret-tool store --label='Omarchy Slack token' service omarchy-slack key token
printf '{"D0AAAAAA1":"1755900002.000200"}' > "$CACHE/seen.json"
out="$(run status)"
check "migrated keyring install is signed in" "$(jq -r '.has_token' <<<"$out")" "true"
check "migrated keyring install is valid" "$(jq -r '.valid' <<<"$out")" "true"
check "migration learned the team" "$(jq -r '.team_id' <<<"$out")" "$ACME"
check "token readable under its workspace" "$(secret-tool lookup service omarchy-slack key ws-token team "$ACME" >/dev/null 2>&1 && echo yes)" "yes"
check "legacy keyring entry removed" "$(secret-tool lookup service omarchy-slack key token >/dev/null 2>&1 && echo yes || echo no)" "no"
check "no token file left behind" "$([ -e "$CFG/token" ] && echo yes || echo no)" "no"
check "seen markers re-keyed" "$(jq -r '.["'"$ACME"'/D0AAAAAA1"]' "$CACHE/seen.json")" "1755900002.000200"
check "migrated install can talk to slack" "$(run counts | jq -r '.team')" "Acme"

# clear-token --all must not leave an orphaned secret behind.
printf '%s\n' "$TOK_BETA" | run set-token >/dev/null
run clear-token --all >/dev/null
check "clear --all empties the keyring" "$(ls "$KEYRING_DIR" 2>/dev/null | wc -l)" "0"

use_no_keyring
rm -rf "$CFG" "$CACHE"

echo "== QML command contract (Model.js → slack.sh)"
if ! command -v node >/dev/null 2>&1; then
  echo "  (skipped: node not installed)"
else
  printf '%s\n' "$TOK_ACME" | run set-token >/dev/null
  printf '%s\n' "$TOK_BETA" | run set-token >/dev/null
  run use "$ACME" >/dev/null
  SD="$HERE/../scripts/"

  # Print the exact argv Model.js would hand to Process, one element per line.
  argv() {
    node -e '
      var M = require(process.argv[1]);
      var f = M[process.argv[2]];
      if (typeof f !== "function") { console.error("no such builder: " + process.argv[2]); process.exit(1); }
      var args = process.argv.slice(3).map(function (x) {
        return x === "--true" ? true : x === "--false" ? false : x;
      });
      process.stdout.write(f.apply(null, args).join("\n"));
    ' "$HERE/../Model.js" "$@"
  }
  qml() { # qml <builder> [args…] — build the argv, then actually run it
    local -a c
    mapfile -t c < <(argv "$@") || return 1
    "${c[@]}"
  }

  out="$(qml statusCommand "$SD" "")"
  check "statusCommand runs" "$(jq -r '.has_token' <<<"$out")" "true"
  out="$(qml statusCommand "$SD" "$BETA")"
  check "statusCommand honours its team" "$(jq -r '.team' <<<"$out")" "Beta Inc"

  out="$(qml countsAllCommand "$SD" --true)"
  check "countsAllCommand runs" "$(jq -r '.workspaces | length' <<<"$out")" "2"
  check "countsAllCommand asks for channels too" "$(jq -r '[.workspaces[0].conversations[].kind] | contains(["channel"])' <<<"$out")" "true"
  out="$(qml countsAllCommand "$SD" --false)"
  check "countsAllCommand can ask for DMs only" "$(jq -r '[.workspaces[0].conversations[].kind] | contains(["channel"])' <<<"$out")" "false"

  out="$(qml countsCommand "$SD" "$BETA" --true)"
  check "countsCommand targets its team" "$(jq -r '.team' <<<"$out")" "Beta Inc"

  out="$(qml workspacesCommand "$SD")"
  check "workspacesCommand runs" "$(jq -r '.workspaces | length' <<<"$out")" "2"

  out="$(qml historyCommand "$SD" "$ACME" D0AAAAAA1)"
  check "historyCommand targets its team" "$(jq -r '.team_id' <<<"$out")" "$ACME"
  check "historyCommand targets its channel" "$(jq -r '.channel' <<<"$out")" "D0AAAAAA1"

  out="$(qml threadCommand "$SD" "$ACME" D0AAAAAA1 1755900002.000200)"
  check "threadCommand targets its thread" "$(jq -r '.thread_ts' <<<"$out")" "1755900002.000200"
  check "threadCommand targets its team" "$(jq -r '.team_id' <<<"$out")" "$ACME"

  out="$(qml seenCommand "$SD" "$BETA" D0BETADM1 1755900000.000900)"
  check "seenCommand keys on its team" "$(jq -r '.key' <<<"$out")" "$BETA/D0BETADM1"

  # send takes its text on stdin, so build the argv and pipe into it.
  mapfile -t sendargv < <(argv sendCommand "$SD" "$BETA" D0BETADM1 "")
  out="$(printf 'from the model' | "${sendargv[@]}")"
  check "sendCommand posts to its team" "$(jq -r '.team_id' <<<"$out")" "$BETA"
  body="$(grep '^BODY: ' "$CURL_BODY_LOG" | tail -1 | sed 's/^BODY: //')"
  check "sendCommand carries the text" "$(jq -r '.text' <<<"$body")" "from the model"
  mapfile -t sendargv < <(argv sendCommand "$SD" "$ACME" D0AAAAAA1 1755900002.000200)
  printf 'threaded from the model' | "${sendargv[@]}" >/dev/null
  body="$(grep '^BODY: ' "$CURL_BODY_LOG" | tail -1 | sed 's/^BODY: //')"
  check "sendCommand threads when asked" "$(jq -r '.thread_ts' <<<"$body")" "1755900002.000200"

  # A conversation whose head is a threaded reply: history cannot return it,
  # so reading must still advance the marker to the head or the unread badge
  # can never be cleared.
  marker() { node -e '
    var M = require(process.argv[1]);
    process.stdout.write(M.readMarkerTs(JSON.parse(process.argv[2]), process.argv[3]));
  ' "$HERE/../Model.js" "$@"; }
  HIST='{"messages":[{"ts":"100.000100"},{"ts":"157.362129"}]}'
  check "head newer than history wins" "$(marker "$HIST" "651.787609")" "651.787609"
  check "history wins when it is newer" "$(marker "$HIST" "120.000000")" "157.362129"
  check "no head falls back to history" "$(marker "$HIST" "")" "157.362129"
  check "empty history still uses the head" "$(marker '{"messages":[]}' "651.787609")" "651.787609"
  check "neither gives no marker" "$(marker '{"messages":[]}' "")" ""

  out="$(qml presenceCommand "$SD" "$ACME" away)"
  check "presenceCommand runs" "$(jq -r '.ok' <<<"$out")" "true"
  out="$(qml snoozeCommand "$SD" "$ACME" 60)"
  check "snoozeCommand runs" "$(jq -r '.ok' <<<"$out")" "true"
  out="$(qml unsnoozeCommand "$SD" "$ACME")"
  check "unsnoozeCommand runs" "$(jq -r '.ok' <<<"$out")" "true"
  out="$(qml loginAvailableCommand "$SD")"
  check "loginAvailableCommand runs" "$(jq -r '.ok' <<<"$out")" "true"

  out="$(qml useCommand "$SD" "$BETA")"
  check "useCommand switches active" "$(jq -r '.active' <<<"$out")" "$BETA"
  out="$(qml clearTokenCommand "$SD" "$BETA")"
  check "clearTokenCommand forgets just its team" "$(jq -r '.workspaces' <<<"$out")" "1"
  check "the other workspace survived it" "$([ -f "$CFG/tokens/$ACME" ] && echo yes)" "yes"
  out="$(qml clearAllTokensCommand "$SD")"
  check "clearAllTokensCommand forgets everything" "$(jq -r '.workspaces' <<<"$out")" "0"

  # The avatar paths the script actually writes must be the ones Model.js is
  # willing to render — they moved under the workspace, and both sides moved.
  printf '%s\n' "$TOK_ACME" | run set-token >/dev/null
  av="$(run counts | jq -r '.conversations[] | select(.id=="D0AAAAAA1") | .avatar')"
  ok_av="$(node -e 'var M=require(process.argv[1]); process.stdout.write(String(M.validAvatar(process.argv[2])))' "$HERE/../Model.js" "$av")"
  check "script's avatar path passes Model.validAvatar" "$ok_av" "true"
  src="$(node -e 'var M=require(process.argv[1]); process.stdout.write(M.avatarSource(process.argv[2]))' "$HERE/../Model.js" "$av")"
  check "avatar renders as a file:// url" "${src%%:*}" "file"
fi

echo "== secrets hygiene"
if grep -q 'xoxp-1234567890\|xoxp-2222222222' "$CURL_LOG"; then
  fail "token appeared on a curl argv"
else
  ok "no token appeared on any curl argv"
fi
if grep -rq 'xoxp-' "$CFG/workspaces.json" 2>/dev/null; then
  fail "a token was written into the workspace registry"
else
  ok "the workspace registry never holds a token"
fi

echo
echo "passed $PASS, failed $FAIL"
[[ "$FAIL" == 0 ]]
