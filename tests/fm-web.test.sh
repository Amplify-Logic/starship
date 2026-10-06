#!/usr/bin/env bash
# Behavior tests for the localhost web page (bin/fm-web.sh, bin/fm-web.py):
# transcript parsing into chat items (tool calls collapsed with their results,
# hook notices as quiet notes, compaction boundaries carrying their summary,
# escaped markdown), busy/idle/offline state, following a restarted or
# /clear'd session,
# the loopback bind, the token/cookie, Host, CSRF and Origin guards on every
# POST, sends that only ever reach bin/fm-desk-voice.sh send with images saved
# in the floater's shots folder, the fleet panel through the bridge view's
# snapshot, and the launcher's start/status/url/stop.
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

# A root whose fm-desk-voice.sh and bearings snapshot are stubs; the real
# server and bridge view are linked in.
make_root() {  # <home> <desk-voice-output-line>
  local home=$1 root=$1/root
  mkdir -p "$root/bin"
  ln -s "$ROOT/bin/fm-web.py" "$root/bin/fm-web.py"
  ln -s "$ROOT/bin/fm-bridge-view.py" "$root/bin/fm-bridge-view.py"
  cat > "$root/bin/fm-desk-voice.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$home/desk-voice.args"
printf 'FM_HOME=%s\n' "\$FM_HOME" >> "$home/desk-voice.args"
printf '%s\n' "$2"
SH
  cat > "$root/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"schema":"fm-bearings.v1","generated":"2026-10-06T20:00:00Z","decisions_open":[{"summary":"Pick the page colour"}],"in_flight":[{"state":"working","name":"Web page build"}],"landed":[{"what":"Bridge memory section","artifact":"https://github.com/example/repo/pull/7"}],"gates":[],"omitted":[]}
JSON
SH
  chmod +x "$root/bin/fm-desk-voice.sh" "$root/bin/fm-bearings-snapshot.sh"
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

test_fleet_panel_reuses_bridge_snapshot() {
  local home root port cookie out
  home=$(make_home fleet)
  root=$(make_root "$home" "sent: tmux %1")
  port=$(start_web "$home" "$root")
  cookie=$(sign_in "$home" "$port")
  out=$(curl -sS --cookie "$cookie" "http://127.0.0.1:$port/api/fleet")
  assert_equals "$(jq -r '.needs_you.items[0].title' <<<"$out")" "Pick the page colour"
  assert_equals "$(jq -r '.under_way.items[0].title' <<<"$out")" "Web page build"
  assert_equals "$(jq -r '.just_finished.items[0].url' <<<"$out")" "https://github.com/example/repo/pull/7"
  pass "the fleet panel is the bridge view's glance"
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
test_get_guards_token_cookie_and_host
test_post_guards_never_reach_desk_voice
test_send_uses_desk_voice_with_saved_images
test_send_reports_typed
test_fleet_panel_reuses_bridge_snapshot
test_launcher_start_status_url_stop
