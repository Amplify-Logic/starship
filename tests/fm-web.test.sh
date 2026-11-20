#!/usr/bin/env bash
# Behavior tests for the localhost web page (bin/fm-web.sh, bin/fm-web.py):
# transcript parsing into chat items (tool calls collapsed with their results,
# hook notices as quiet notes, compaction boundaries carrying their summary,
# escaped markdown), busy/idle/offline state, following a restarted or
# /clear'd session,
# the loopback bind, the token/cookie, Host, CSRF and Origin guards on every
# POST, sends that only ever reach bin/fm-desk-voice.sh send with images saved
# in the floater's shots folder, the mirror of the Factory pane's screen and
# the bridge strip's fields in the page's plain words, a button's action handed
# to bin/fm-factory.py act and nowhere else, the settings kept in the browser,
# and the launcher's start/status/url/stop.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENGINE="$ROOT/bin/fm-web.py"
LAUNCHER="$ROOT/bin/fm-web.sh"
TMP_ROOT=$(fm_test_tmproot fm-web)
SESSION=11111111-2222-3333-4444-555555555555

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

# start_web runs inside $(...), so its servers are recorded in a file.
WEB_PIDS=()
WEB_PID_FILE=$TMP_ROOT/web.pids
fm_web_cleanup() {
  local pid
  [ -f "$WEB_PID_FILE" ] && while IFS= read -r pid; do WEB_PIDS+=("$pid"); done < "$WEB_PID_FILE"
  for pid in "${WEB_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap fm_web_cleanup EXIT

# A home whose lock names a live pid and SESSION, with that session's
# transcript under a fake Claude config dir.
make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/claude/projects/-fake-project"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$SESSION" > "$home/state/.lock-session"
  : > "$home/claude/projects/-fake-project/$SESSION.jsonl"
  printf '%s\n' "$home"
}

transcript() {  # <home> [<session>]
  printf '%s\n' "$1/claude/projects/-fake-project/${2:-$SESSION}.jsonl"
}

# A root with the real server linked in and stand-ins for what it runs:
# fm-desk-voice.sh records its arguments; fm-factory.py prints the home's
# screen.json for --screen (and fails when there is none) and, for act, records
# the action it was handed in act.asks and answers with the home's act.answer;
# fm-bridge-strip.sh prints the home's strip.fields, or fails without one.
make_root() {  # <home> <desk-voice-output-line>
  local home=$1 root=$1/root
  mkdir -p "$root/bin"
  ln -s "$ROOT/bin/fm-web.py" "$root/bin/fm-web.py"
  cat > "$root/bin/fm-factory.py" <<'PY'
#!/usr/bin/env python3
import os, sys
home = os.environ["FM_HOME"]
if sys.argv[1:] == ["--screen"]:
    try:
        sys.stdout.write(open(os.path.join(home, "screen.json")).read())
    except OSError:
        sys.exit("fm-factory: the fleet could not be read")
elif sys.argv[1:] == ["act"]:
    with open(os.path.join(home, "act.asks"), "a") as asks:
        asks.write(sys.stdin.read() + "\n")
    try:
        answer = open(os.path.join(home, "act.answer")).read()
    except OSError:
        answer = '{"ok": true, "said": "\u2713 SENT to Starship: keep Harvest chart and land it"}'
    if answer.startswith("refuse"):
        sys.exit(2)
    sys.stdout.write(answer)
else:
    sys.exit("stand-in fm-factory.py: unexpected arguments %r" % sys.argv[1:])
PY
  cat > "$root/bin/fm-bridge-strip.sh" <<'SH'
#!/usr/bin/env bash
[ "$*" = fields ] || { echo "stand-in fm-bridge-strip.sh: unexpected arguments: $*" >&2; exit 2; }
cat "$FM_HOME/strip.fields" 2>/dev/null
SH
  chmod +x "$root/bin/fm-factory.py" "$root/bin/fm-bridge-strip.sh"
  cat > "$root/bin/fm-desk-voice.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$home/desk-voice.args"
printf 'FM_HOME=%s\n' "\$FM_HOME" >> "$home/desk-voice.args"
printf '%s\n' "$2"
SH
  chmod +x "$root/bin/fm-desk-voice.sh"
  printf '%s\n' "$root"
}

start_web() {  # <home> <root>
  local home=$1 root=$2 log n=0 line
  log=$home/web-serve.log
  : > "$log"
  HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" python3 "$ENGINE" serve --home "$home" --root "$root" --port 0 >"$log" 2>&1 &
  printf '%s\n' "$!" >> "$WEB_PID_FILE"
  while [ "$n" -lt 50 ]; do
    line=$(grep -E '^listening on 127\.0\.0\.1:[0-9]+$' "$log" 2>/dev/null || true)
    if [ -n "$line" ]; then
      printf '%s\n' "${line##*:}"
      return 0
    fi
    sleep 0.1
    n=$((n + 1))
  done
  fail "web server did not print a loopback listener: $(cat "$log")"
}

# Prints the cookie pair after signing in with the token link.
sign_in() {  # <home> <port>
  local token hdr cookie
  token=$(head -n 1 "$1/state/web/token")
  hdr=$1/signin.hdr
  curl -sS -o /dev/null -D "$hdr" "http://127.0.0.1:$2/?token=$token"
  cookie=$(awk 'tolower($1)=="set-cookie:" {print $2; exit}' "$hdr" | tr -d '\r')
  [ -n "$cookie" ] || fail "token link did not set a cookie: $(cat "$hdr")"
  printf '%s\n' "${cookie%;}"
}

csrf_of() {  # <port> <cookie>
  curl -sS --cookie "$2" "http://127.0.0.1:$1/" | sed -n 's/.*data-csrf="\([0-9a-f]*\)".*/\1/p'
}

# Serves <home> and signs in, so conversation reads its /api/conversation.
serve_home() {  # <home>
  local root port
  root=$(make_root "$1" "sent: tmux %1")
  port=$(start_web "$1" "$root")
  printf '%s\n' "$port" > "$1/web.test-port"
  sign_in "$1" "$port" > "$1/web.test-cookie"
}

conversation() {  # <home>
  curl -sS --cookie "$(cat "$1/web.test-cookie")" "http://127.0.0.1:$(cat "$1/web.test-port")/api/conversation"
}

status_of() {  # curl args... -> HTTP status
  curl -sS -o /dev/null -w '%{http_code}' "$@"
}

write_basic_transcript() {  # <file>
  cat > "$1" <<'JSONL'
{"type":"user","uuid":"u1","timestamp":"2026-10-06T10:00:00Z","origin":{"kind":"human"},"message":{"role":"user","content":"Hello <script>alert(1)</script> **there**"}}
{"type":"user","uuid":"meta1","isMeta":true,"message":{"role":"user","content":"<system-reminder>hidden</system-reminder>"}}
{"type":"assistant","uuid":"a1","message":{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":"secret thoughts"}]}}
{"type":"assistant","uuid":"a2","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"First part."}]}}
{"type":"assistant","uuid":"a3","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Second part with [a link](https://example.com/x) and [bad](javascript:alert(1))."}]}}
{"type":"assistant","uuid":"a4","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls -la","description":"List files"}}]}}
{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file-a\nfile-b"}]}}
{"type":"assistant","uuid":"a5","message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"Done listing."}]}}
{"type":"system","subtype":"turn_duration","uuid":"s1","durationMs":10}
{"type":"user","uuid":"n1","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>"}}
{"type":"user","uuid":"lc","message":{"role":"user","content":"<local-command-stdout>noise</local-command-stdout>"}}
{"type":"system","subtype":"compact_boundary","uuid":"c1","content":"Conversation compacted"}
{"type":"user","uuid":"cs","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"Summary of the earlier talk."}}
{"type":"attachment","uuid":"q1","attachment":{"type":"queued_command","prompt":"typed mid-turn","origin":{"kind":"human"}}}
{"type":"attachment","uuid":"q2","attachment":{"type":"queued_command","prompt":"hook text","origin":{"kind":"task-notification"}}}
{"type":"assistant","uuid":"a6","isSidechain":true,"message":{"id":"msg_s","role":"assistant","content":[{"type":"text","text":"sidechain"}]}}
{"type":"assistant","uuid":"a7","message":{"id":"msg_3","role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/tmp/notes.md"}}]}}
not json at all
JSONL
}

test_transcript_parsing_collapses_tools_and_marks_compaction() {
  local home out
  home=$(make_home parse)
  write_basic_transcript "$(transcript "$home")"
  serve_home "$home"
  out=$(conversation "$home") || fail "conversation read failed"
  assert_equals "$(jq -r '[.items[].kind] | join(",")' <<<"$out")" \
    "user,assistant,tool,assistant,event,compact,user,tool" "item kinds in order"
  assert_contains "$(jq -r '.items[0].html' <<<"$out")" "&lt;script&gt;alert(1)&lt;/script&gt;"
  assert_not_contains "$(jq -r '.items[0].html' <<<"$out")" "<script>"
  assert_contains "$(jq -r '.items[0].html' <<<"$out")" "<strong>there</strong>"
  assert_contains "$(jq -r '.items[1].html' <<<"$out")" "First part."
  assert_contains "$(jq -r '.items[1].html' <<<"$out")" "Second part"
  assert_contains "$(jq -r '.items[1].html' <<<"$out")" 'href="https://example.com/x"'
  assert_not_contains "$(jq -r '.items[1].html' <<<"$out")" 'href="javascript'
  assert_not_contains "$out" "secret thoughts"
  assert_not_contains "$out" "sidechain"
  assert_not_contains "$out" "noise"
  assert_not_contains "$out" "hook text"
  assert_equals "$(jq -r '.items[2] | [.name, .summary, .pending, .result] | join("|")' <<<"$out")" \
    "Bash|List files|false|file-a
file-b" "tool call collapsed with its result"
  assert_equals "$(jq -r '.items[4].summary' <<<"$out")" "Stop hook feedback" "hook notice is a quiet note"
  assert_equals "$(jq -r '.items[5].detail' <<<"$out")" "Summary of the earlier talk." "compaction carries its summary"
  assert_contains "$(jq -r '.items[6].html' <<<"$out")" "typed mid-turn"
  assert_equals "$(jq -r '.items[7] | [.name, .summary, .pending] | join("|")' <<<"$out")" \
    "Read|/tmp/notes.md|true" "unanswered tool call is pending"
  assert_equals "$(jq -r '.state' <<<"$out")" "busy" "work after the last turn end reads busy"
  assert_no_grep "/api/conversation" "$home/state/web/web.log"
  pass "transcript parsing collapses tools, marks compaction and escapes markdown"
}

test_numbered_lists_keep_their_numbers() {
  local home out html
  home=$(make_home numbers)
  jq -nc --arg text $'Options:\n\n1. Merge now\n\n2. Wait for CI\n\n3. Abort\n\nLater:\n\n4. Tidy up' \
    '{type:"assistant",uuid:"a1",message:{id:"msg_1",role:"assistant",content:[{type:"text",text:$text}]}}' \
    > "$(transcript "$home")"
  serve_home "$home"
  out=$(conversation "$home") || fail "conversation read failed"
  html=$(jq -r '.items[0].html' <<<"$out")
  assert_contains "$html" '<ol><li>Merge now</li></ol>'
  assert_contains "$html" '<ol start="2"><li>Wait for CI</li></ol>'
  assert_contains "$html" '<ol start="3"><li>Abort</li></ol>'
  assert_contains "$html" '<ol start="4"><li>Tidy up</li></ol>'
  pass "numbered items split by blank lines keep their written numbers"
}

test_idle_offline_and_session_restart() {
  local home out next
  home=$(make_home state)
  write_basic_transcript "$(transcript "$home")"
  printf '%s\n' '{"type":"system","subtype":"turn_duration","uuid":"s9"}' >> "$(transcript "$home")"
  serve_home "$home"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.state' <<<"$out")" "idle" "turn end reads idle"
  # What Claude Code writes for a terminal `! git status`: no turn starts.
  {
    printf '%s\n' '{"type":"user","uuid":"b1","message":{"role":"user","content":"<bash-input>git status</bash-input>"}}'
    printf '%s\n' '{"type":"user","uuid":"b2","message":{"role":"user","content":"<bash-stdout>clean</bash-stdout><bash-stderr></bash-stderr>"}}'
  } >> "$(transcript "$home")"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.state' <<<"$out")" "idle" "a terminal shell command leaves it idle"
  python3 -c 'import os,signal,subprocess; p=subprocess.Popen(["true"]); p.wait(); print(p.pid)' > "$home/state/.lock"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.state' <<<"$out")" "offline" "dead lock pid reads offline"
  printf '%s\n' "$$" > "$home/state/.lock"
  next=99999999-8888-7777-6666-555555555555
  printf '%s\n' '{"type":"user","uuid":"new1","origin":{"kind":"human"},"message":{"role":"user","content":"after restart"}}' \
    > "$(transcript "$home" "$next")"
  printf '%s\n' "$next" > "$home/state/.lock-session"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.session' <<<"$out")" "$next" "follows the new session id"
  assert_equals "$(jq -r '[.items[].kind] | join(",")' <<<"$out")" "user" "shows only the new session"
  printf '%s\n' '../../etc/passwd' > "$home/state/.lock-session"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.items | length' <<<"$out")" "0" "unsafe session id is ignored"
  pass "state reads busy, idle and offline, and a restarted session is followed"
}

# /clear gives the live primary a new session id that Claude Code records in
# sessions/<pid>.json, while state/.lock-session keeps the old one.
test_cleared_session_is_followed_through_the_live_registry() {
  local home out cleared
  home=$(make_home cleared)
  write_basic_transcript "$(transcript "$home")"
  serve_home "$home"
  cleared=77777777-6666-5555-4444-333333333333
  mkdir -p "$home/claude/sessions"
  printf '{"pid":%s,"sessionId":"%s","kind":"interactive"}\n' "$$" "$cleared" > "$home/claude/sessions/$$.json"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.session' <<<"$out")" "$SESSION" "a cleared session with no transcript yet keeps the old conversation"
  # What Claude Code writes for an idle /clear: caveat, command, local_command.
  {
    printf '%s\n' '{"type":"user","uuid":"m1","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"}}'
    printf '%s\n' '{"type":"user","uuid":"c0","message":{"role":"user","content":"<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"}}'
    printf '%s\n' '{"type":"system","subtype":"local_command","uuid":"l1","content":"<local-command-stdout></local-command-stdout>"}'
  } > "$(transcript "$home" "$cleared")"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.session' <<<"$out")" "$cleared" "follows the cleared session while the sidecar is stale"
  assert_equals "$(jq -r '.state' <<<"$out")" "idle" "an idle /clear reads idle"
  printf '%s\n' '{"type":"user","uuid":"c1","origin":{"kind":"human"},"message":{"role":"user","content":"after clear"}}' \
    >> "$(transcript "$home" "$cleared")"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.state' <<<"$out")" "busy" "the cleared session's turn reads busy"
  assert_equals "$(jq -r '[.items[].html] | join(",")' <<<"$out")" "<p>/clear</p>,<p>after clear</p>" "shows the message sent after /clear"
  python3 -c 'import subprocess; p=subprocess.Popen(["true"]); p.wait(); print(p.pid)' > "$home/state/.lock"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.session' <<<"$out")" "$SESSION" "a dead holder's registry entry is ignored"
  pass "a /clear'd primary is followed through its live session registry"
}

test_tail_reads_only_the_end_of_a_large_transcript() {
  local home out
  home=$(make_home tail)
  python3 - "$(transcript "$home")" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    for i in range(6000):
        fh.write(json.dumps({"type": "user", "uuid": f"u{i}", "origin": {"kind": "human"},
                             "message": {"role": "user", "content": f"message {i} " + "x" * 600}}) + "\n")
PY
  serve_home "$home"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.older' <<<"$out")" "true" "older history is flagged"
  assert_equals "$(jq -r '.items | length' <<<"$out")" "160" "only the recent tail is shown"
  assert_contains "$(jq -r '.items[-1].html' <<<"$out")" "message 5999"
  pass "a large transcript is read from its end"
}

test_conversation_command_prints_versioned_json() {
  local home out
  home=$(make_home conversation-json)
  write_basic_transcript "$(transcript "$home")"
  out=$(FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" "$LAUNCHER" conversation) \
    || fail "conversation command failed: $out"
  assert_equals fm-web-conversation.v1 "$(jq -r .schema <<<"$out")" "the read names its schema"
  assert_equals "$SESSION" "$(jq -r .session <<<"$out")" "the read names the live session"
  case "$(jq -r .state <<<"$out")" in busy|idle) ;; *) fail "a live session reads busy or idle: $out" ;; esac
  assert_contains "$(jq -r '[.items[] | select(.kind == "user") | .html] | join(" ")' <<<"$out")" \
    "Hello &lt;script&gt;" "item html is escaped exactly as the page receives it"
  [ "$(jq '[.items[] | select(.kind == "tool")] | length' <<<"$out")" -ge 1 ] || fail "tool calls collapse as on the page"
  [ ! -e "$home/state/web/token" ] || fail "the one-shot read must not create the server's token"
  rm -f "$home/state/.lock-session" "$home/state/.lock"
  out=$(FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" "$LAUNCHER" conversation) \
    || fail "conversation command failed without a session: $out"
  assert_equals offline "$(jq -r .state <<<"$out")" "a home with no session reads as offline"
  pass "fm-web conversation: one versioned JSON read of a home's conversation, no server"
}

test_get_guards_token_cookie_and_host() {
  local home root port cookie token
  home=$(make_home guards)
  write_basic_transcript "$(transcript "$home")"
  root=$(make_root "$home" "sent: tmux %1")
  port=$(start_web "$home" "$root")
  assert_equals "$(if [ "$(uname)" = Darwin ]; then stat -f '%Lp' "$home/state/web/token"; else stat -c '%a' "$home/state/web/token"; fi)" "600" "token is owner-only"
  assert_equals "$(status_of "http://127.0.0.1:$port/")" "403" "no cookie is refused"
  assert_equals "$(status_of "http://127.0.0.1:$port/api/conversation")" "403" "api without cookie is refused"
  assert_equals "$(status_of "http://127.0.0.1:$port/?token=wrong")" "403" "wrong token is refused"
  cookie=$(sign_in "$home" "$port")
  assert_equals "$(status_of --cookie "$cookie" "http://127.0.0.1:$port/")" "200" "cookie opens the page"
  assert_equals "$(status_of --cookie "$cookie" -H "Host: evil.example:$port" "http://127.0.0.1:$port/")" "403" "rebound Host is refused"
  assert_equals "$(status_of --cookie "$cookie" -H "Host: 127.0.0.1:1" "http://127.0.0.1:$port/")" "403" "other port Host is refused"
  token=$(head -n 1 "$home/state/web/token")
  assert_equals "$(status_of -H "Host: evil.example:$port" "http://127.0.0.1:$port/?token=$token")" "403" "token on a rebound Host is refused"
  assert_no_grep "$token" "$home/state/web/web.log"
  pass "pages need the token cookie and this loopback Host, and the token is never logged"
}

test_post_guards_never_reach_desk_voice() {
  local home root port cookie csrf url body='{"text":"hello"}'
  home=$(make_home postguards)
  root=$(make_root "$home" "sent: tmux %1")
  port=$(start_web "$home" "$root")
  cookie=$(sign_in "$home" "$port")
  csrf=$(csrf_of "$port" "$cookie")
  [ -n "$csrf" ] || fail "page did not carry a CSRF value"
  url="http://127.0.0.1:$port/api/send"
  assert_equals "$(status_of -X POST -H 'Content-Type: application/json' -H "X-FM-CSRF: $csrf" --data "$body" "$url")" "403" "no cookie"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H 'Content-Type: application/json' --data "$body" "$url")" "403" "no CSRF header"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: 0000" --data "$body" "$url")" "403" "wrong CSRF header"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" -H 'Origin: https://evil.example' --data "$body" "$url")" "403" "foreign Origin"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" -H 'Sec-Fetch-Site: cross-site' --data "$body" "$url")" "403" "cross-site fetch"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" -H "Host: evil.example:$port" --data "$body" "$url")" "403" "rebound Host"
  assert_absent "$home/desk-voice.args"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" -H "Origin: http://127.0.0.1:$port" --data "$body" "$url")" "200" "guarded send passes"
  [ -f "$home/desk-voice.args" ] || fail "the accepted send did not call fm-desk-voice.sh"
  pass "every POST guard refuses before fm-desk-voice.sh is called"
}

test_send_uses_desk_voice_with_saved_images() {
  local home root port cookie csrf out png args image
  home=$(make_home send)
  root=$(make_root "$home" "mailbox: $home/state/desk-voice/inbox/x.json")
  port=$(start_web "$home" "$root")
  cookie=$(sign_in "$home" "$port")
  csrf=$(csrf_of "$port" "$cookie")
  png=$(printf '\x89PNG\r\n\x1a\nrest' | base64 | tr -d '\n')
  out=$(curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" -H 'Content-Type: application/json' \
    --data "{\"text\":\"--source evil\\nsecond line\",\"images\":[\"data:image/png;base64,$png\"]}" \
    "http://127.0.0.1:$port/api/send")
  assert_equals "$(jq -r '.outcome' <<<"$out")" "mailbox" "mailbox outcome reported"
  args=$(cat "$home/desk-voice.args")
  assert_equals "$(sed -n 1,4p <<<"$args" | tr '\n' ' ')" "send --source web --image " "argv starts with send --source web"
  image=$(sed -n 5p <<<"$args")
  case "$image" in "$home/state/desk-voice/shots/"*.png) ;; *) fail "image not saved in the shots folder: $image" ;; esac
  [ -f "$image" ] || fail "saved image is missing"
  assert_equals "$(sed -n 6p <<<"$args")" "--" "text follows an end-of-options marker"
  assert_contains "$args" "--source evil"
  assert_contains "$args" "FM_HOME=$home"
  out=$(curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" \
    --data '{"text":"x","images":["data:text/html;base64,PGI+"]}' "http://127.0.0.1:$port/api/send")
  assert_equals "$(jq -r '.outcome' <<<"$out")" "failed" "non-image attachment is refused"
  pass "sends go only through fm-desk-voice.sh send, with images in the floater's shots folder"
}

test_send_reports_typed() {
  local home root port cookie csrf out
  home=$(make_home typed)
  root=$(make_root "$home" "sent: herdr w1:p1")
  port=$(start_web "$home" "$root")
  cookie=$(sign_in "$home" "$port")
  csrf=$(csrf_of "$port" "$cookie")
  out=$(curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"text":"hi"}' "http://127.0.0.1:$port/api/send")
  assert_equals "$(jq -r '.outcome' <<<"$out")" "typed" "typed outcome reported"
  pass "a message typed into the chat is reported as typed"
}

# What bin/fm-factory.py --screen prints for a small invented fleet, in the
# pane's own words, and what bin/fm-bridge-strip.sh fields prints beside it.
write_screen() {  # <home>
  cat > "$1/screen.json" <<'JSON'
{"schema": "fm-factory-screen.v1", "as_of": "2026-11-14T08:00:00Z", "clock": "Sat 08:00",
 "counts": {"reading": "current", "age": 0, "busy": 1, "decisions": 1, "ready_to_merge": 1, "idle": 1},
 "count_words": [{"words": "1 busy", "colour": "amber"}, {"words": "1 decision for you", "colour": "red"},
                 {"words": "1 ready to merge", "colour": "green"}, {"words": "1 idle", "colour": "faint"}],
 "queue": ["4 queued", "2 in line", "2 wait on you, 1 of them deferred to a date"],
 "needs": [
  {"id": "garden-chart", "asking": "1794632400", "factory": "garden-journal", "factory_name": "Garden Journal",
   "kind": "question", "ask": "Harvest chart", "title": "Harvest chart",
   "why": "The chart can open on this week or this season.",
   "options": [{"key": "1", "label": "this week", "suggested": true}, {"key": "2", "label": "this season", "suggested": false}],
   "suggested_by": "Starship", "recommendation": "", "holds_up": ["Garden reminders"], "waited": "waiting 3 h",
   "answered": null, "checking": false, "mate": null, "pr": null, "read": true},
  {"id": "garden-share", "asking": "1794636660", "factory": "garden-journal", "factory_name": "Garden Journal",
   "kind": "finished work", "ask": "The queued orders page is ready to merge", "title": "The queued orders page",
   "why": "", "options": [], "suggested_by": "Starship", "recommendation": "", "holds_up": [],
   "waited": "ready 1 h 49 min", "answered": null, "checking": false, "mate": null,
   "pr": "https://example.invalid/g/pull/12", "read": false}],
 "factories": [
  {"id": "garden-journal", "name": "Garden Journal", "state": "needs you", "steered_by": "you",
   "about": ["a phone journal for a vegetable garden", "2 workers, 1 busy"], "queue": "3 queued · 2 in line",
   "jobs": [
    {"id": "garden-water", "title": "Garden reminders", "state": "busy", "words": "sorting the queued reminders",
     "elapsed": "47 min", "colour": "amber", "quiet": false, "step": 2, "queue": "", "read": false},
    {"id": "garden-share", "title": "The queued orders page", "state": "ready to merge", "words": "ready to merge",
     "elapsed": "", "colour": "green", "quiet": false, "step": 3, "queue": "", "read": false},
    {"id": "garden-labels", "title": "Print seed labels", "state": "waiting", "words": "waiting · tries again 09:30",
     "elapsed": "", "colour": "amber", "quiet": false, "step": 1, "queue": "", "read": false}],
   "routine": [], "next": {"title": "Harvest notes", "once_you_answer": true, "then": 1},
   "page": {"needs": ["garden-chart", "garden-share"], "queue": ["3 queued", "2 in line", "1 deferred to a date"],
    "jobs": [], "workers": [
     {"id": "garden-water", "title": "Garden reminders", "state": "busy", "words": "sorting the queued reminders",
      "elapsed": "47 min", "colour": "amber", "quiet": false, "step": 2, "queue": "", "read": false}],
    "folded": [{"words": "1 deferred to a date", "jobs": [{"title": "Charge for seeds", "queue": "deferred"}]}],
    "rules": ["English only."], "rules_size": "rules 13 / 1,500 characters", "rules_mark": "", "learned": [],
    "feed": {"title": "LAST 12 HOURS", "events": []}, "talk": []}},
  {"id": "recipe-box", "name": "Recipe Box", "state": "idle", "steered_by": "Starship", "about": ["0 workers, 0 busy"],
   "queue": "idle since 06:00 · nothing queued", "jobs": [], "routine": [], "next": null,
   "page": {"needs": [], "queue": ["nothing queued"], "jobs": [], "workers": [], "folded": [], "rules": [],
    "rules_size": "", "rules_mark": "", "learned": [], "feed": {"title": "LAST 12 HOURS", "events": []}, "talk": []}}],
 "feed": {"title": "SINCE YOU LAST LOOKED, 2 h ago", "events": [
  {"when": "06:00", "actor": "Recipe Box", "factory": "recipe-box", "word": "landed", "text": "A landed gentry recipe is in.", "colour": "green"},
  {"when": "06:11", "actor": "Garden Journal", "factory": "garden-journal", "word": "PR ready",
   "text": "The queued orders page has its PR ready.", "colour": "green"},
  {"when": "07:20", "actor": "Garden Journal", "factory": "garden-journal", "word": "asked you",
   "text": "Harvest chart needs your call.", "colour": "red"}]},
 "steps": ["planning", "building", "checking", "ready to merge"], "voice": false}
JSON
  cat > "$1/strip.fields" <<'FIELDS'
reading=current
age=
busy=1
for_you=1
to_merge=1
call_kind=decision
call_id=garden-chart
call_title=Harvest chart
alert=1 failed, 1 stopped
night=night shift from 23:30
night_mark=
battery=battery 9%, plug in now
battery_mark=critical
FIELDS
}

mirror() {  # <home> [<query>]
  curl -sS --cookie "$(cat "$1/web.test-cookie")" "http://127.0.0.1:$(cat "$1/web.test-port")/api/mirror${2:-}"
}

test_the_mirror_is_the_pane_and_the_strip_in_plain_words() {
  local home out
  home=$(make_home mirror)
  serve_home "$home"
  assert_equals "$(mirror "$home" | jq -r .error)" "the fleet could not be read" "a fleet that cannot be read says why"
  write_screen "$home"
  sleep 2.2   # the server keeps one reading for two seconds
  out=$(mirror "$home")
  m() { jq -r ".model | $1" <<<"$out"; }
  assert_equals "$(m '[.band.lamps[] | "\(.count) \(.words) (\(.mark))"] | join(", ")')" \
    "1 busy (work), 1 decision for you (you), 1 ready for your OK (done)" "the three lamps"
  assert_equals "$(m '.band.call | "\(.id)|\(.title)|\(.question)|\(.listed)"')" "garden-chart|Harvest chart|true|true" \
    "the most urgent call is the strip's"
  assert_equals "$(m '.band | "\(.alert)|\(.night)|\(.battery)|\(.battery_mark)"')" \
    "1 hit a problem, 1 stopped|night shift from 23:30|battery 9%, plug in now|critical" "the strip's alert, night shift and battery"
  assert_equals "$(m '[.summary[] | .words] | join(", ")')" "1 busy, 1 decision for you, 1 ready for your OK, 1 idle" \
    "the count line"
  assert_equals "$(m '.queue | join(", ")')" "4 waiting to start, 2 in line, 2 wait on you, 1 of them put off to a date" \
    "the queue line"
  assert_equals "$(m '.steps | join(", ")')" "planning, building, checking, ready for your OK" "the four steps"
  # A call keeps what the button must send back: its id, its asking, its answers' keys.
  assert_equals "$(m '.needs[0] | "\(.id) \(.asking) \(.project) \(.question) \(.waited) \(.read)"')" \
    "garden-chart 1794632400 garden-journal true waiting 3 h true" "a question"
  assert_equals "$(m '.needs[0].options | map("\(.key)=\(.label)/\(.suggested)") | join(" ")')" \
    "1=this week/true 2=this season/false" "its answers"
  # Only the pane's own words change; a title, and what a worker says it is
  # doing, are left as written even when they hold one of those words.
  assert_equals "$(m '.needs[1] | "\(.ask)|\(.question)|\(.pr)"')" \
    "The queued orders page is ready for your OK|false|https://example.invalid/g/pull/12" "finished work"
  assert_equals "$(m '.projects[0].jobs | map("\(.title): \(.words) [\(.mark)]") | join("; ")')" \
    "Garden reminders: sorting the queued reminders [work]; The queued orders page: ready for your OK [done]; Print seed labels: waiting, tries again 09:30 [work]" \
    "a project's jobs"
  assert_equals "$(m '.projects[0] | "\(.you_steer) \(.queue | join(", ")) | \(.next.title) \(.next.once_you_answer) | \(.about)"')" \
    "true 3 waiting to start, 2 in line | Harvest notes true | a phone journal for a vegetable garden. 2 workers, 1 busy" \
    "a project's row"
  assert_equals "$(m '.projects[0].page | "\(.queue | join(", ")) | \(.folded[0].words): \(.folded[0].jobs[0].title) | \(.workers[0].title)"')" \
    "3 waiting to start, 2 in line, 1 put off to a date | 1 put off to a date: Charge for seeds | Garden reminders" \
    "a project's own page"
  assert_equals "$(m '.projects[1] | "\(.idle) \(.queue | join(", "))"')" "true idle since 06:00, nothing waiting to start" \
    "an idle project"
  assert_equals "$(m '.feed.title')" "Since you last looked, 2 h ago" "the feed's heading"
  assert_equals "$(m '.feed.events | map("\(.word): \(.text) [\(.mark)]") | join("; ")')" \
    "went live: A landed gentry recipe is in. [done]; ready for your OK: The queued orders page is ready for your OK. [done]; asked you: Harvest chart needs your call. [you]" \
    "the feed"
  assert_equals "$(mirror "$home" "?since=$(jq -r .version <<<"$out")" | jq -c .)" \
    "{\"version\":\"$(jq -r .version <<<"$out")\",\"unchanged\":true,\"clock\":\"Sat 08:00\"}" "an unchanged reading is not sent again"
  # Without the strip the band still has the pane's counts and its first call.
  rm "$home/strip.fields"
  sleep 2.2
  out=$(mirror "$home")
  assert_equals "$(m '.band | "\(.lamps | length) \(.call.id) \(.alert)|\(.battery)"')" "3 garden-chart |" \
    "a strip that cannot be read leaves the band its lamps"
  assert_equals "$(status_of "http://127.0.0.1:$(cat "$home/web.test-port")/api/mirror")" "403" "the mirror needs the cookie"
  pass "the mirror is the pane's screen and the strip's fields, with only the pane's own jargon reworded"
}

test_a_button_is_handed_to_the_factory_script_and_nowhere_else() {
  local home port cookie csrf url out
  home=$(make_home act)
  serve_home "$home"
  port=$(cat "$home/web.test-port")
  cookie=$(cat "$home/web.test-cookie")
  csrf=$(csrf_of "$port" "$cookie")
  url="http://127.0.0.1:$port/api/act"
  post() { curl -sS -X POST --cookie "$cookie" -H 'Content-Type: application/json' -H "X-FM-CSRF: $csrf" --data "$1" "$url"; }
  out=$(post '{"action":"keep","item":"garden-share","asking":"1794636660","merge":true}')
  assert_equals "$(jq -c . "$home/act.asks")" '{"action":"keep","item":"garden-share","asking":"1794636660"}' \
    "the action reaches bin/fm-factory.py act with only the fields the pane's keys take"
  assert_equals "$(jq -c . <<<"$out")" '{"ok":true,"said":"Sent to Starship: keep Harvest chart and make it live"}' \
    "what the pane says comes back in the page's words"
  assert_absent "$home/desk-voice.args"
  post '{"action":"answer","item":"garden-chart","asking":"1794632400","option":"2"}' >/dev/null
  post '{"action":"talk","factory":"garden-journal","text":"check the ribbon"}' >/dev/null
  assert_equals "$(sed -n '2,3p' "$home/act.asks" | jq -c .)" \
    '{"action":"answer","item":"garden-chart","asking":"1794632400","option":"2"}
{"action":"talk","factory":"garden-journal","text":"check the ribbon"}' "an answer and a typed note"
  post '{"action":"steer","factory":"garden-journal","who":"you","in_tab":true}' >/dev/null
  assert_equals "$(sed -n '4p' "$home/act.asks" | jq -c .)" \
    '{"action":"steer","factory":"garden-journal","who":"you","in_tab":true}' "a project tab's button says it was on a tab"
  printf '{"ok": false, "said": "\\u2717 NOT SENT: the inbox is locked. Nothing reached Starship."}' > "$home/act.answer"
  assert_equals "$(post '{"action":"keep","item":"garden-share"}' | jq -c .)" \
    '{"ok":false,"said":"Not sent: the inbox is locked. Nothing reached Starship."}' "a note that did not go says so"
  : > "$home/act.asks"

  # Refused before the factory script runs: every POST guard, an action the
  # pane has no key for, a name that is not one, and words too long to be a note.
  assert_equals "$(status_of -X POST --cookie "$cookie" --data '{"action":"keep","item":"garden-share"}' "$url")" "403" "no CSRF header"
  assert_equals "$(status_of -X POST -H "X-FM-CSRF: $csrf" --data '{"action":"keep","item":"garden-share"}' "$url")" "403" "no cookie"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" -H 'Origin: https://evil.example' --data '{"action":"keep","item":"garden-share"}' "$url")" "403" "foreign Origin"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"action":"merge","item":"garden-share"}' "$url")" "400" "merge is not an action"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"action":"keep","item":"../etc; rm"}' "$url")" "400" "a name that is not one"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"action":"steer","factory":"garden-journal","who":"them"}' "$url")" "400" "someone else steering"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"action":"keep","item":"garden-share","in_tab":"yes"}' "$url")" "400" "in_tab that is not true"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data "{\"action\":\"talk\",\"factory\":\"garden-journal\",\"text\":\"$(printf 'x%.0s' $(seq 1 4001))\"}" "$url")" "400" "words too long"
  assert_equals "$(cat "$home/act.asks")" "" "a refused request reached the factory script"
  printf 'refuse' > "$home/act.answer"
  assert_equals "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"action":"keep","item":"garden-share"}' "$url")" "400" \
    "an action the factory script cannot read"
  pass "a button's action goes to bin/fm-factory.py act, guarded like a send, and its answer comes back"
}

# The settings script is the page's own, fetched as the browser fetches it and
# run against a stand-in for the browser's storage.
test_settings_are_kept_in_the_browser() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }
  local home out
  home=$(make_home settings)
  serve_home "$home"
  curl -sS --cookie "$(cat "$home/web.test-cookie")" "http://127.0.0.1:$(cat "$home/web.test-port")/settings.js" > "$home/settings.js"
  out=$(node - "$home/settings.js" <<'JS'
const S = require(process.argv[2]);
const kept = {};
const storage = { getItem: k => (k in kept ? kept[k] : null), setItem: (k, v) => { kept[k] = String(v); } };
const page = () => ({ style: {}, attrs: {}, setAttribute(k, v) { this.attrs[k] = v; } });
const out = [];
out.push('first visit: ' + JSON.stringify(S.load(storage)));
S.save(storage, { text: 3, style: 'lively', theme: 'dark', motion: 'less' });
out.push('next visit: ' + JSON.stringify(S.load(storage)));
const el = page();
S.apply(el, S.load(storage));
out.push('on the page: ' + el.style.fontSize + ' ' + JSON.stringify(el.attrs));
S.save(storage, { text: 99, style: 'neon', theme: 'dark', motion: 'less' });
out.push('a bad value: ' + JSON.stringify(S.load(storage)));
kept[S.KEY] = '{not json';
out.push('unreadable: ' + JSON.stringify(S.load(storage)));
out.push('no storage: ' + JSON.stringify(S.load(null)) + ' ' + JSON.stringify(S.save(null, { text: 0 })));
out.push('sizes: ' + S.TEXT_STEPS.join(' ') + ' | ' + S.TEXT_NAMES.join(' '));
console.log(out.join('\n'));
JS
) || fail "the settings script did not run: $out"
  assert_equals "$out" 'first visit: {"text":1,"style":"calm","theme":"auto","motion":"auto"}
next visit: {"text":3,"style":"lively","theme":"dark","motion":"less"}
on the page: 125% {"data-style":"lively","data-theme":"dark","data-motion":"less"}
a bad value: {"text":1,"style":"calm","theme":"dark","motion":"less"}
unreadable: {"text":1,"style":"calm","theme":"auto","motion":"auto"}
no storage: {"text":1,"style":"calm","theme":"auto","motion":"auto"} {"text":0,"style":"calm","theme":"auto","motion":"auto"}
sizes: 87.5 100 112.5 125 150 | Small Normal Large Larger Largest' "the settings a browser keeps and what they put on the page"
  pass "settings default to calm and normal, come back on the next visit, and survive a browser with no storage"
}

test_launcher_start_status_url_stop() {
  local home out port
  home=$(make_home launcher)
  out=$(FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" "$LAUNCHER" start --port 0) || fail "start failed"
  case "$out" in http://127.0.0.1:[0-9]*/\?token=*) ;; *) fail "start did not print a loopback URL: $out" ;; esac
  WEB_PIDS+=("$(cat "$home/state/web/web.pid")")
  port=$(cat "$home/state/web/web.port")
  assert_contains "$(FM_HOME="$home" "$LAUNCHER" status)" "running on 127.0.0.1:$port"
  assert_equals "$(FM_HOME="$home" "$LAUNCHER" url)" "$out" "url repeats the sign-in link"
  assert_equals "$(FM_HOME="$home" "$LAUNCHER" start --port 0)" "$out" "a second start reuses the server"
  assert_equals "$(FM_HOME="$home" "$LAUNCHER" stop)" "stopped"
  out=$(FM_HOME="$home" "$LAUNCHER" status) && fail "status succeeded after stop"
  assert_equals "$out" "stopped"
  pass "the launcher starts, reports, prints the URL and stops"
}

test_transcript_parsing_collapses_tools_and_marks_compaction
test_numbered_lists_keep_their_numbers
test_idle_offline_and_session_restart
test_cleared_session_is_followed_through_the_live_registry
test_tail_reads_only_the_end_of_a_large_transcript
test_conversation_command_prints_versioned_json
test_get_guards_token_cookie_and_host
test_post_guards_never_reach_desk_voice
test_send_uses_desk_voice_with_saved_images
test_send_reports_typed
test_the_mirror_is_the_pane_and_the_strip_in_plain_words
test_a_button_is_handed_to_the_factory_script_and_nowhere_else
test_settings_are_kept_in_the_browser
test_launcher_start_status_url_stop
