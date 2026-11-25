#!/usr/bin/env bash
# Behavior tests for the localhost web page (bin/fm-web.sh, bin/fm-web.py):
# transcript parsing into chat items (tool calls collapsed with their results,
# hook notices and typed-in doorbells as quiet notes, pasted pictures as
# pictures, compaction boundaries carrying their summary, escaped markdown),
# busy/idle/offline state, following a restarted or /clear'd session,
# the loopback bind, the token/cookie, Host, CSRF and Origin guards on every
# POST, sends that only ever reach bin/fm-desk-voice.sh send with images saved
# in the floater's shots folder, the mirror of the Factory pane's screen and
# the bridge strip's fields in the page's plain words, a button's action handed
# to bin/fm-factory.py act and nowhere else, the settings kept in the browser
# and the colours they put on the page, always readable,
# the page's own rules (the chat folded, links labelled, keys naming buttons),
# the page shown before signing in with its public icons and manifest, the
# one-time link open signs in with, and the launcher's start/status/url/stop.
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
# fm-desk-voice.sh records its arguments, and for suggestion prints the home's
# suggestion file (each waiting the seconds in send.delay or suggestion.delay,
# when there is one, after reading), and for prompt the home's prompt file,
# logging each read in prompt.reads; fm-factory.py prints the home's
# screen.json for --screen (and fails when there is none) and, for act, records
# the action it was handed in act.asks and answers with the home's act.answer;
# fm-bridge-strip.sh prints the home's strip.fields, or fails without one;
# fm-peek.sh records what it was asked in peek.asks and prints the home's
# peek/<job>, or fails without one; fm-speak.sh records each call in
# speak.asks and keeps the volume and mute in the home's speak.* files.
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
  cat > "$root/bin/fm-status-bar.sh" <<'SH'
#!/usr/bin/env bash
[ "$*" = "--replay --own" ] || { echo "stand-in fm-status-bar.sh: unexpected arguments: $*" >&2; exit 2; }
cat "$FM_HOME/status.row" 2>/dev/null
SH
  cat > "$root/bin/fm-peek.sh" <<'SH'
#!/usr/bin/env bash
printf '%s FM_HOME=%s\n' "$*" "$FM_HOME" >> "$FM_HOME/peek.asks"
cat "$FM_HOME/peek/$1" 2>/dev/null
SH
  cat > "$root/bin/fm-speak.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/speak.asks"
case "$1" in
  --enabled) [ -e "$FM_HOME/speak.off" ] && echo disabled || echo enabled ;;
  --volume) if [ "$#" -eq 2 ]; then printf '%s\n' "$2" > "$FM_HOME/speak.volume"; else cat "$FM_HOME/speak.volume" 2>/dev/null || echo 100; fi ;;
  --muted) [ -e "$FM_HOME/speak.muted" ] && echo muted || echo unmuted ;;
  --mute) : > "$FM_HOME/speak.muted" ;;
  --unmute) rm -f "$FM_HOME/speak.muted" ;;
  --history) printf '7\t1795500000\tThe fix landed. More on screen.\n6\t1795490000\tOlder reply.\n' ;;
  --caption) [ "$2" = 7 ] && echo 'The fix landed. Shall I merge it?' || echo 'Older reply.' ;;
  --replay) [ "$2" = 7 ] || exit 1 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$root/bin/fm-factory.py" "$root/bin/fm-bridge-strip.sh" "$root/bin/fm-status-bar.sh" "$root/bin/fm-peek.sh" "$root/bin/fm-speak.sh"
  cat > "$root/bin/fm-desk-voice.sh" <<SH
#!/usr/bin/env bash
if [ "\$*" = suggestion ]; then
  said=\$(cat "$home/suggestion" 2>/dev/null)
  delay=\$(cat "$home/suggestion.delay" 2>/dev/null)
  printf 'suggestion\n' >> "$home/suggestion.reads"
  [ -z "\$delay" ] || sleep "\$delay"
  printf '%s\n' "\$said"
  exit 0
fi
if [ "\$*" = prompt ]; then
  printf 'prompt\n' >> "$home/prompt.reads"
  cat "$home/prompt" 2>/dev/null
  exit 0
fi
cat > "$home/desk-voice.stdin"
printf '%s\n' "\$@" > "$home/desk-voice.args"
printf 'FM_HOME=%s\n' "\$FM_HOME" >> "$home/desk-voice.args"
[ ! -e "$home/send.delay" ] || sleep "\$(cat "$home/send.delay")"
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
  assert_equals "$(jq -r '.items[2] | [.name, .summary, .about, .pending, .result] | join("|")' <<<"$out")" \
    "Bash|List files|List files|false|file-a
file-b" "tool call collapsed with its result and its own description"
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

# While a turn runs the page says when it began, so its live line can show how
# long the first mate has worked; a finished turn carries no start.
test_a_working_turn_says_when_it_began() {
  local home out file version
  home=$(make_home since)
  file=$(transcript "$home")
  {
    printf '%s\n' '{"type":"user","uuid":"u1","timestamp":"2026-10-06T10:00:00Z","origin":{"kind":"human"},"message":{"role":"user","content":"first ask"}}'
    printf '%s\n' '{"type":"assistant","uuid":"a1","timestamp":"2026-10-06T10:00:09Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","description":"List files"}}]}}'
  } > "$file"
  serve_home "$home"
  out=$(conversation "$home")
  assert_equals "$(jq -r '[.state, .since] | join(" ")' <<<"$out")" "busy 2026-10-06T10:00:00Z" "a running turn starts at the message that began it"
  version=$(jq -r .version <<<"$out")
  out=$(curl -sS --cookie "$(cat "$home/web.test-cookie")" \
    "http://127.0.0.1:$(cat "$home/web.test-port")/api/conversation?since=$version")
  assert_equals "$(jq -r '[.unchanged, .since] | join(" ")' <<<"$out")" "true 2026-10-06T10:00:00Z" "an unchanged read still says when the turn began"
  {
    printf '%s\n' '{"type":"user","uuid":"r1","timestamp":"2026-10-06T10:00:12Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a"}]}}'
    printf '%s\n' '{"type":"system","subtype":"turn_duration","uuid":"s1","timestamp":"2026-10-06T10:00:20Z"}'
  } >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '[.state, (.since | tostring)] | join(" ")' <<<"$out")" "idle null" "a finished turn carries no start"
  printf '%s\n' '{"type":"user","uuid":"u2","timestamp":"2026-10-06T11:30:00Z","origin":{"kind":"human"},"message":{"role":"user","content":"next ask"}}' >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '[.state, .since] | join(" ")' <<<"$out")" "busy 2026-10-06T11:30:00Z" "the next turn starts at its own message"
  out=$(FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" "$LAUNCHER" conversation)
  assert_equals "$(jq -r .since <<<"$out")" "2026-10-06T11:30:00Z" "the conversation command carries the start too"
  pass "a working turn says when it began, and a finished one does not"
}

# A turn longer than the part of the transcript the page reads began before
# that part, so it carries no start rather than the time of its first step read.
test_a_turn_begun_before_the_read_part_carries_no_start() {
  local home out
  home=$(make_home longturn)
  python3 - "$(transcript "$home")" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    fh.write(json.dumps({"type": "user", "uuid": "u0", "timestamp": "2026-10-06T08:00:00Z",
                         "origin": {"kind": "human"}, "message": {"role": "user", "content": "long ask"}}) + "\n")
    for i in range(6000):
        fh.write(json.dumps({"type": "assistant", "uuid": f"a{i}", "timestamp": f"2026-10-06T09:{i // 100 % 60:02d}:{i % 60:02d}Z",
                             "message": {"id": f"m{i}", "role": "assistant", "content": [
                                 {"type": "tool_use", "id": f"t{i}", "name": "Bash",
                                  "input": {"command": "ls " + "x" * 600}}]}}) + "\n")
PY
  serve_home "$home"
  out=$(conversation "$home")
  assert_equals "$(jq -r '[.state, (.older | tostring), (.since | tostring)] | join(" ")' <<<"$out")" "busy true null" \
    "a turn whose first message was not read has no start"
  pass "a turn begun before the read part carries no start"
}

# A message typed while the first mate works waits in Claude Code's queue; the
# transcript records it there ("queue-operation") before it is read in. The page
# shows it at once as a waiting message, and as one ordinary message, never two,
# once the transcript shows it read in, mid-turn or as the next turn.
test_a_message_typed_mid_turn_shows_as_waiting_until_it_is_read() {
  local home file out shot
  home=$(make_home queued)
  file=$(transcript "$home")
  mkdir -p "$home/state/desk-voice/shots"
  shot="$home/state/desk-voice/shots/20261123T185500000000Z-ab12cd34.png"
  printf '\x89PNG\r\n\x1a\nshot' > "$shot"
  {
    printf '%s\n' '{"type":"user","uuid":"u1","timestamp":"2026-11-23T18:54:00Z","origin":{"kind":"human"},"message":{"role":"user","content":"send the scout"}}'
    printf '%s\n' '{"type":"assistant","uuid":"a1","timestamp":"2026-11-23T18:54:05Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","description":"List files"}}]}}'
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-23T18:55:10.000Z","content":"<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>"}'
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-23T18:55:13.622Z","content":"send*"}'
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-23T18:55:14.000Z","content":"⁣: Firstmate operational input waiting: read the note"}'
    jq -nc --arg shot "$shot" '{type:"queue-operation",operation:"enqueue",timestamp:"2026-11-23T18:55:20.000Z",content:("and this Screenshots: " + $shot)}'
  } > "$file"
  serve_home "$home"
  out=$(conversation "$home") || fail "conversation read failed"
  assert_equals "$(jq -r '[.items[].kind] | join(",")' <<<"$out")" "user,tool" "a queued message is not yet in the conversation"
  assert_equals "$(jq -r '[.waiting[] | "\(.kind) \(.waiting) \(.ts) \(.html)"] | join("|")' <<<"$out")" \
    "user true 2026-11-23T18:55:13.622Z <p>send*</p>|user true 2026-11-23T18:55:20.000Z <p>and this</p>" \
    "the owner's queued messages wait, oldest first; the machinery's notices do not show"
  assert_equals "$(jq -r '.waiting[1].pictures | length' <<<"$out")" "1" "a queued screenshot shows as a picture"
  assert_equals "$(curl -sS -o /dev/null -w '%{http_code}' --cookie "$(cat "$home/web.test-cookie")" \
    "http://127.0.0.1:$(cat "$home/web.test-port")/api/picture/$(jq -r '.waiting[1].pictures[0]' <<<"$out")")" "200" \
    "and the page may fetch it"
  {
    printf '%s\n' '{"type":"queue-operation","operation":"remove","timestamp":"2026-11-23T18:55:53.980Z","content":"send*","reason":"absorbed_mid_turn"}'
    printf '%s\n' '{"type":"attachment","uuid":"q1","timestamp":"2026-11-23T18:55:13.377Z","attachment":{"type":"queued_command","prompt":"send*","origin":{"kind":"human"}}}'
  } >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '[.items[] | select(.kind == "user") | .html] | join("|")' <<<"$out")" "<p>send the scout</p>|<p>send*</p>" \
    "read in mid-turn, it is an ordinary message"
  assert_equals "$(jq -r '[.waiting[].html] | join("|")' <<<"$out")" "<p>and this</p>" "and no longer waiting: never shown twice"
  # The turn ends and the next queued message starts the next turn: the user
  # message can land before the dequeue that names nothing.
  {
    printf '%s\n' '{"type":"system","subtype":"turn_duration","uuid":"s1","timestamp":"2026-11-23T18:56:00Z"}'
    jq -nc --arg shot "$shot" '{type:"user",uuid:"u2",timestamp:"2026-11-23T18:56:00.100Z",origin:{kind:"human"},message:{role:"user",content:("and this Screenshots: " + $shot)}}'
  } >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.waiting | length' <<<"$out")" "0" "a message read in as the next turn is no longer waiting"
  assert_equals "$(jq -r '[.items[] | select(.kind == "user")] | length' <<<"$out")" "3" "it shows once"
  printf '%s\n' '{"type":"queue-operation","operation":"dequeue","timestamp":"2026-11-23T18:56:00.200Z"}' >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.waiting | length' <<<"$out")" "0" "its dequeue after the read-in takes nothing else"
  # Two messages wait; the first is read in as the next turn before its dequeue
  # lands: that dequeue takes the one read in, and the second still waits.
  {
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-23T18:56:10Z","content":"alpha"}'
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-23T18:56:11Z","content":"bravo"}'
    printf '%s\n' '{"type":"system","subtype":"turn_duration","uuid":"s2","timestamp":"2026-11-23T18:56:20Z"}'
    printf '%s\n' '{"type":"user","uuid":"u3","timestamp":"2026-11-23T18:56:20.100Z","origin":{"kind":"human"},"message":{"role":"user","content":"alpha"}}'
  } >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '[.waiting[].html] | join("|")' <<<"$out")" "<p>bravo</p>" "the one read in no longer waits"
  printf '%s\n' '{"type":"queue-operation","operation":"dequeue","timestamp":"2026-11-23T18:56:20.200Z"}' >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '[.waiting[].html] | join("|")' <<<"$out")" "<p>bravo</p>" "a late dequeue does not hide the one still waiting"
  {
    printf '%s\n' '{"type":"queue-operation","operation":"dequeue","timestamp":"2026-11-23T18:56:30Z"}'
    printf '%s\n' '{"type":"user","uuid":"u4","timestamp":"2026-11-23T18:56:30.100Z","origin":{"kind":"human"},"message":{"role":"user","content":"bravo"}}'
  } >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.waiting | length' <<<"$out")" "0" "a dequeue before its read-in also leaves nothing waiting"
  # The same words queued twice: one read in mid-turn, then removed, leaves the
  # other waiting.
  {
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-23T18:56:40Z","content":"yes"}'
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-23T18:56:41Z","content":"yes"}'
    printf '%s\n' '{"type":"attachment","uuid":"q2","timestamp":"2026-11-23T18:56:42Z","attachment":{"type":"queued_command","prompt":"yes","origin":{"kind":"human"}}}'
    printf '%s\n' '{"type":"queue-operation","operation":"remove","timestamp":"2026-11-23T18:56:42.100Z","content":"yes","reason":"absorbed_mid_turn"}'
  } >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '[.waiting[] | "\(.ts) \(.html)"] | join("|")' <<<"$out")" "2026-11-23T18:56:41Z <p>yes</p>" \
    "the second of two identical messages still waits"
  printf '%s\n' '{"type":"queue-operation","operation":"popAll","timestamp":"2026-11-23T18:56:50Z"}' >> "$file"
  # A dequeue names nothing: it takes the owner's oldest before a notice.
  {
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-23T18:57:00Z","content":"<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>"}'
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-23T18:57:01Z","content":"first"}'
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-23T18:57:02Z","content":"second"}'
    printf '%s\n' '{"type":"queue-operation","operation":"dequeue","timestamp":"2026-11-23T18:57:03Z"}'
  } >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '[.waiting[].html] | join("|")' <<<"$out")" "<p>second</p>" "a dequeue takes the owner's oldest message"
  printf '%s\n' '{"type":"queue-operation","operation":"popAll","timestamp":"2026-11-23T18:57:04Z"}' >> "$file"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.waiting | length' <<<"$out")" "0" "an emptied queue leaves nothing waiting"
  out=$(FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" "$LAUNCHER" conversation)
  assert_equals "$(jq -r '.waiting | type' <<<"$out")" "array" "the conversation command carries what is waiting too"
  pass "a message typed mid-turn shows as waiting at once and as one ordinary message once read in"
}

# Bold or italic words that hold code or a link still render as emphasis.
test_emphasis_around_code_renders() {
  local home html
  home=$(make_home emphasis)
  jq -nc --arg text 'Run **the `ls -la` step** now, *see `x`*, and keep `**raw**` as code.' \
    '{type:"assistant",uuid:"a1",message:{id:"msg_1",role:"assistant",content:[{type:"text",text:$text}]}}' \
    > "$(transcript "$home")"
  serve_home "$home"
  html=$(jq -r '.items[0].html' <<<"$(conversation "$home")")
  assert_contains "$html" '<strong>the <code>ls -la</code> step</strong>'
  assert_contains "$html" '<em>see <code>x</code></em>'
  assert_contains "$html" '<code>**raw**</code>'
  assert_not_contains "$html" '**the'
  pass "emphasis around code renders instead of showing its stars"
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
  assert_equals "$(sed -n 6p <<<"$args")" "--stdin" "the text is read from standard input"
  assert_equals "$(sed -n 7p <<<"$args")" "FM_HOME=$home" "no text rides in the arguments"
  assert_equals "$(cat "$home/desk-voice.stdin")" "--source evil
second line" "the text arrives whole on standard input"
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

# A long paste, such as a video transcript, goes through whole; a message past
# the limit is refused with words that say what the limit is.
test_a_long_paste_is_sent_and_the_limit_is_named() {
  local home root port cookie csrf long out
  home=$(make_home longpaste)
  root=$(make_root "$home" "sent: tmux %1")
  port=$(start_web "$home" "$root")
  cookie=$(sign_in "$home" "$port")
  csrf=$(csrf_of "$port" "$cookie")
  long=$(python3 -c 'print(" ".join(["word"] * 7000), end="")')
  printf '%s' "$long" | python3 -c 'import json, sys; print(json.dumps({"text": sys.stdin.buffer.read().decode()}))' > "$home/long.json"
  out=$(curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data-binary @"$home/long.json" "http://127.0.0.1:$port/api/send")
  assert_equals "$(jq -r '.outcome' <<<"$out")" "typed" "a 35,000 character paste is sent"
  cmp -s "$home/desk-voice.stdin" <(printf '%s' "$long") || fail "the whole paste reached desk voice"
  long=$(python3 -c 'print("\U0001F600" * 40000, end="")')
  [ "$(printf '%s' "$long" | wc -c | tr -d ' ')" -gt 131071 ] || fail "the paste must outgrow one Linux argument"
  printf '%s' "$long" | python3 -c 'import json, sys; print(json.dumps({"text": sys.stdin.buffer.read().decode()}))' > "$home/long.json"
  out=$(curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data-binary @"$home/long.json" "http://127.0.0.1:$port/api/send")
  assert_equals "$(jq -r '.outcome' <<<"$out")" "typed" "a paste larger than one Linux argument is sent"
  cmp -s "$home/desk-voice.stdin" <(printf '%s' "$long") || fail "the paste larger than one Linux argument reached desk voice whole"
  rm -f "$home/desk-voice.args" "$home/desk-voice.stdin"
  python3 -c 'import json; print(json.dumps({"text": "x" * 200001}))' > "$home/over.json"
  out=$(curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data-binary @"$home/over.json" "http://127.0.0.1:$port/api/send")
  assert_equals "$(jq -r '.detail' <<<"$out")" "the message is too long: at most 200,000 characters" "the refusal names the limit"
  assert_absent "$home/desk-voice.args"
  pass "a long paste is sent whole, and a message past the limit is refused naming the limit"
}

# A reply that names a file under the home's data or .lavish folder links it,
# and the link opens the file read-only in its own type; anything outside, a
# ../ escape, a symlink out, a hidden file or a missing file stays plain text
# and is never served.
test_a_reply_links_files_under_the_home_and_serves_them_read_only() {
  local home port cookie out base hdr
  home=$(make_home files)
  mkdir -p "$home/data/task/.hidden" "$home/.lavish" "$home/state/private"
  printf '<h1>Knowledge</h1><script>1</script>' > "$home/data/task/knowledge.html"
  printf '# Report\n\nfound it\n' > "$home/data/task/report.md"
  printf '\x89PNG\r\n\x1a\nchart' > "$home/data/task/chart.png"
  printf 'board' > "$home/.lavish/board.html"
  printf 'secret' > "$home/data/task/.hidden/key.txt"
  printf 'private' > "$home/state/private/notes.md"
  printf 'outside' > "$TMP_ROOT/outside.md"
  ln -s "$TMP_ROOT/outside.md" "$home/data/task/escape.md"
  jq -nc --arg t "Read data/task/knowledge.html, \`data/task/report.md\` and $home/data/task/chart.png. The board is $home/.lavish/board.html: open it. Not data/task/missing.md, $TMP_ROOT/outside.md, data/task/escape.md, data/task/.hidden/key.txt, state/private/notes.md, data/../state/private/notes.md or $home/state/private/notes.md." \
    '{type:"assistant",uuid:"a1",message:{id:"m1",role:"assistant",content:[{type:"text",text:$t}]}}' > "$(transcript "$home")"
  serve_home "$home"
  port=$(cat "$home/web.test-port")
  cookie=$(cat "$home/web.test-cookie")
  out=$(conversation "$home" | jq -r '.items[0].html')
  assert_equals "$(grep -o 'href="/api/file/[^"]*"' <<<"$out" | tr '\n' ' ')" \
    'href="/api/file/data/task/knowledge.html" href="/api/file/data/task/report.md" href="/api/file/data/task/chart.png" href="/api/file/.lavish/board.html" ' \
    "only the files under the home's data and .lavish folders are links"
  assert_contains "$out" '<a href="/api/file/data/task/report.md" target="_blank" rel="noopener noreferrer"><code>data/task/report.md</code></a>'
  assert_contains "$out" "chart.png</a>. The board"
  assert_contains "$out" "board.html</a>: open it"
  assert_contains "$out" "Not data/task/missing.md, $TMP_ROOT/outside.md, data/task/escape.md,"
  base="http://127.0.0.1:$port/api/file"
  hdr=$home/file.hdr
  curl -sS -D "$hdr" -o "$home/file.body" --cookie "$cookie" "$base/data/task/knowledge.html"
  assert_contains "$(cat "$hdr")" "200"
  assert_contains "$(tr -d '\r' < "$hdr" | grep -i '^content-type:')" "text/html"
  assert_contains "$(tr -d '\r' < "$hdr" | grep -i '^content-security-policy:')" "sandbox"
  assert_equals "$(cat "$home/file.body")" '<h1>Knowledge</h1><script>1</script>' "the page is served as it is"
  assert_equals "$(curl -sS -o /dev/null -w '%{http_code} %{content_type}' --cookie "$cookie" "$base/data/task/report.md")" "200 text/plain; charset=utf-8" "Markdown is served as text"
  assert_equals "$(curl -sS -o /dev/null -w '%{http_code} %{content_type}' --cookie "$cookie" "$base/data/task/chart.png")" "200 image/png" "a picture is served as one"
  assert_equals "$(curl -sS -o /dev/null -w '%{http_code}' --cookie "$cookie" "$base/.lavish/board.html")" "200" "a Lavish page is served"
  assert_equals "$(status_of "$base/data/task/report.md")" "403" "a file needs the sign-in"
  assert_equals "$(status_of --path-as-is --cookie "$cookie" "$base/data/../state/private/notes.md")" "404" "a ../ escape is refused"
  assert_equals "$(status_of --cookie "$cookie" "$base/data/%2e%2e/state/private/notes.md")" "404" "an encoded ../ escape is refused"
  assert_equals "$(status_of --cookie "$cookie" "$base/state/private/notes.md")" "404" "the home's other folders are refused"
  assert_equals "$(status_of --cookie "$cookie" "$base/state/web/token")" "404" "the token is refused"
  assert_equals "$(status_of --cookie "$cookie" "$base/data/task/escape.md")" "404" "a symlink out of the home is refused"
  assert_equals "$(status_of --cookie "$cookie" "$base/data/task/.hidden/key.txt")" "404" "a hidden file is refused"
  assert_equals "$(status_of --cookie "$cookie" "$base/$TMP_ROOT/outside.md")" "404" "an absolute path is refused"
  assert_equals "$(status_of --cookie "$cookie" "$base/data/task/missing.md")" "404" "a missing file is refused"
  pass "a reply links files under the home's data and .lavish folders, served read-only, and nothing else"
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
 "sentences": [{"words": "2 things need you. 1 more is put off to a date.", "to": "needs", "colour": "red"},
               {"words": "1 job is running. 1 has stopped and 1 hit a problem, and Starship is on them.", "to": "factories", "colour": "amber"},
               {"words": "1 change went live since you looked at 06:00.", "to": "factories", "colour": "green"}],
 "first_up": "garden-chart",
 "shelves": {"older": {"heading": "1 older question is still open",
                       "note": "It left Needs you after waiting with no date set, waiting since 1 Oct.",
                       "items": [{"id": "garden-units", "asking": "2026-10-01", "factory": "garden-journal",
                                  "factory_name": "Garden Journal", "title": "Metric or cups", "since": "since 1 Oct",
                                  "asked": ""}]},
             "coming": {"heading": "1 thing comes back this week", "rest": "", "after": "",
                        "items": [{"id": "garden-seeds", "factory": "garden-journal", "factory_name": "Garden Journal",
                                   "title": "Charge for seeds", "when": "Mon 16 Nov"}]}},
 "stopped": [{"id": "garden-labels", "factory": "garden-journal", "title": "Print seed labels"}],
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
   "pr": "https://example.invalid/g/pull/12", "read": false,
   "summary": [{"label": "In short", "text": "Queued orders get a page of their own."},
               {"label": "You need to", "text": "Nothing."}, {"label": "Risk", "text": "Low."}]}],
 "factories": [
  {"id": "garden-journal", "name": "Garden Journal", "state": "needs you", "steered_by": "you",
   "about": ["a phone journal for a vegetable garden", "2 workers, 1 busy"],
   "quiet": false, "quiet_words": "", "badge": "2 need you", "now": "",
   "jobs": [
    {"id": "garden-water", "title": "Garden reminders", "state": "busy", "words": "sorting the queued reminders",
     "elapsed": "47 min", "colour": "amber", "quiet": false, "step": 2, "queue": "", "read": false},
    {"id": "garden-share", "title": "The queued orders page", "state": "ready to merge", "words": "ready to merge",
     "elapsed": "", "colour": "green", "quiet": false, "step": 3, "queue": "", "read": false},
    {"id": "garden-labels", "title": "Print seed labels", "state": "waiting", "words": "waiting · tries again 09:30",
     "elapsed": "", "colour": "amber", "quiet": false, "step": 1, "queue": "", "read": false}],
   "routine": [],
   "new": [{"id": "garden-share", "word": "PR ready", "label": "PR ready", "text": "The queued orders page",
            "when": "06:11", "pr": null, "read": false, "title": "The queued orders page", "colour": "green"},
           {"id": "garden-beds", "word": "went live", "label": "Went live", "text": "Raised beds",
            "when": "06:05", "pr": "https://example.invalid/g/pull/9", "read": false, "title": "Raised beds", "colour": "green"},
           {"id": "garden-soil", "word": "report ready", "label": "Report ready", "text": "Why the soil dries out",
            "when": "today", "pr": null, "read": true, "title": "Why the soil dries out", "colour": "green"}],
   "more": 2, "more_words": "and 2 more, on its own page",
   "next": {"title": "Harvest notes", "once_you_answer": true, "then": 1, "words": ", once you answer, then 1 more lined up"},
   "page": {"needs": ["garden-chart", "garden-share"],
    "state": "2 things need you. 1 job is running. 1 change went live in the last 12 hours.",
    "now": [{"id": "garden-water", "title": "Garden reminders", "state": "busy", "words": "sorting the queued reminders",
      "elapsed": "47 min", "colour": "amber", "quiet": false, "step": 2, "queue": "", "read": false}],
    "lately": [{"id": "garden-beds", "word": "went live", "label": "Went live", "text": "Raised beds", "when": "06:05",
                "pr": "https://example.invalid/g/pull/9", "read": false, "title": "Raised beds", "colour": "green"},
               {"id": "garden-fence", "word": "settled", "label": "Settled", "text": "The fence stays wire.",
                "when": "today", "pr": null, "read": false, "title": "Fence: wood or wire?", "colour": "mist",
                "detail": {"question": "Fence: wood or wire?", "answer": "Wire, it matches the shed. Ask again in spring."}}],
    "lately_since": "in the last 12 hours",
    "next": [{"id": "garden-notes", "title": "Harvest notes", "state": "next", "words": "next", "elapsed": "",
              "colour": "mist", "quiet": false, "step": 1, "queue": "in line", "read": false}],
    "lined": 2,
    "coming": [{"id": "garden-seeds", "title": "Charge for seeds", "when": "Mon 16 Nov"}],
    "workers": [
     {"id": "garden-water", "title": "Garden reminders", "state": "busy", "words": "sorting the queued reminders",
      "elapsed": "47 min", "colour": "amber", "quiet": false, "step": 2, "queue": "", "read": false}],
    "folded": [{"words": "1 deferred to a date", "jobs": [{"title": "Charge for seeds", "queue": "deferred"}]}],
    "rules": ["English only."], "rules_size": "rules 1,400 / 1,500 characters · near the cap; past it its jobs get none of these rules",
    "rules_mark": "near", "learned": [],
    "talk": [{"when": "Fri 12:00", "who": "you", "said": "Keep the rows wide."},
             {"when": "Fri 13:00", "who": "Starship", "said": "Done, a hand apart."},
             {"when": "06:00", "who": "you", "said": "Are the labels in?"}]}},
  {"id": "recipe-box", "name": "Recipe Box", "state": "idle", "steered_by": "Starship", "about": ["0 workers, 0 busy"],
   "quiet": true, "quiet_words": "Idle since 06:00, nothing lined up.", "badge": "", "now": "Nothing is running.",
   "jobs": [], "routine": [], "new": [], "more": 0, "next": null,
   "page": {"needs": [], "state": "Nothing needs you. Nothing is running.", "now": [], "lately": [],
    "lately_since": "in the last 12 hours", "next": [], "lined": 0, "coming": [], "workers": [], "folded": [],
    "rules": [], "rules_size": "", "rules_mark": "", "learned": [], "talk": []}}],
 "factories_heading": "new since you looked at 06:00",
 "steps": ["planning", "building", "checking", "ready to merge"], "voice": false}
JSON
  cat > "$1/strip.fields" <<'FIELDS'
reading=current
age=
busy=1
for_you=1
to_merge=1
call_kind=merge
call_id=garden-share
call_title=The queued orders page
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
    "the most urgent call is not the first card"
  assert_equals "$(m .first_up)" "garden-chart" "the card marked first up"
  assert_equals "$(m '.band.stopped | "\(.project) \(.job)"')" "garden-journal garden-labels" \
    "the alert's stopped does not open the job that stopped"
  assert_equals "$(m '[.sentences[] | "\(.to) [\(.mark)] \(.words)"] | join(" / ")')" \
    "needs [you] 2 things need you. 1 more is put off to a date. / factories [work] 1 job is running. 1 has stopped and 1 hit a problem, and Starship is on them. / factories [done] 1 change went live since you looked at 06:00." \
    "the three sentences, each with the part it leads to"
  assert_equals "$(m '.shelves.older | "\(.heading)|\(.items[0].id) \(.items[0].asking) \(.items[0].project_name) \(.items[0].since)"')" \
    "1 older question is still open|garden-units 2026-10-01 Garden Journal since 1 Oct" "the older questions shelf"
  assert_equals "$(m '.shelves.coming | "\(.heading)|\(.items[0].when) \(.items[0].title)"')" \
    "1 thing comes back this week|Mon 16 Nov Charge for seeds" "the coming back shelf"
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
  assert_equals "$(m '.needs[1].summary | map("\(.label): \(.text)") | join(" / ")')" \
    "In short: Queued orders get a page of their own. / You need to: Nothing. / Risk: Low." \
    "finished work carries its PR's short section beside the merge choice"
  assert_equals "$(m '.needs[0].summary | length')" "0" "a question carries no short section"
  assert_equals "$(m '.projects[0].jobs | map("\(.title): \(.words) [\(.mark)]") | join("; ")')" \
    "Garden reminders: sorting the queued reminders [work]; The queued orders page: ready for your OK [done]; Print seed labels: waiting, tries again 09:30 [work]" \
    "a project's jobs"
  assert_equals "$(m '.projects[0] | "\(.you_steer) \(.quiet) \(.badge) | \(.next.title)\(.next.words) | \(.about)"')" \
    "true false 2 need you | Harvest notes, once you answer, then 1 more lined up | a phone journal for a vegetable garden. 2 workers, 1 busy" \
    "a project's block"
  # New is told as the pane tells it, each led by its word, with its time and its link; only the pane's jargon word changes.
  assert_equals "$(m '.projects[0].new | map("\(.when) \(.label): \(.text) [\(.mark)] \(.pr) \(.read)") | join(" / ")')" \
    "06:11 Ready for your OK: The queued orders page [done]  false / 06:05 Went live: Raised beds [done] https://example.invalid/g/pull/9 false / today Report ready: Why the soil dries out [done]  true" \
    "a project's New"
  assert_equals "$(m '.projects[0] | "\(.more) \(.more_words)"')" "2 and 2 more, on its own page" \
    "how many more New leaves to the project's page"
  # A project's own page top to bottom, as the pane's page (View.page_parts), with no line of queue counters.
  assert_equals "$(m '.projects[0].page | [.state, (.now | map(.title) | join(",")),
      (.lately | map("\(.when) \(.label): \(.text) \(.pr)") | join(",")), .lately_since,
      (.next | map(.title) | join(",")), .lined, (.coming | map("\(.when) \(.title)") | join(",")),
      "\(.folded[0].words): \(.folded[0].jobs[0].title)", has("queue"), has("feed")] | map(tostring) | join(" | ")')" \
    "2 things need you. 1 job is running. 1 change went live in the last 12 hours. | Garden reminders | 06:05 Went live: Raised beds https://example.invalid/g/pull/9,today Settled: The fence stays wire.  | in the last 12 hours | Harvest notes | 2 | Mon 16 Nov Charge for seeds | 1 put off to a date: Charge for seeds | false | false" \
    "a project's own page"
  # A settled call's sentence or two unfolds to its question and whole answer; other outcomes have nothing to unfold.
  assert_equals "$(m '.projects[0].page.lately | map(.detail | if . then "\(.question) | \(.answer)" else "-" end) | join(" / ")')" \
    "- / Fence: wood or wire? | Wire, it matches the shed. Ask again in spring." \
    "a settled call does not hand the page its question and whole answer to unfold"
  # The page draws no column of workers beside a project's page: its work list
  # already names each one, so the mirror hands the page no second list of them.
  assert_equals "$(m '.projects[0].page | has("workers")')" "false" "the mirror hands the page a second list of workers"
  assert_equals "$(m '.projects[0].page | "\(.rules_size) [\(.rules_mark)]"')" \
    "rules 1,400 / 1,500 characters. near the cap; past it its jobs get none of these rules [near]" \
    "the rules' size, which the pane says only near the cap or over it"
  assert_equals "$(m '.projects[1].page.rules_size')" "" "a project the pane gives no rules size has none"
  # What was said reads newest first on the page; the pane lists it oldest first.
  assert_equals "$(m '.projects[0].page.talk | map("\(.when) \(.who): \(.said)") | join(" / ")')" \
    "06:00 you: Are the labels in? / Fri 13:00 Starship: Done, a hand apart. / Fri 12:00 you: Keep the rows wide." \
    "a project's conversation, newest first"
  assert_equals "$(m '.projects[1] | "\(.quiet) \(.quiet_words)"')" "true Idle since 06:00, nothing lined up." \
    "a quiet project is one line of words"
  assert_equals "$(m '.factories_heading')" "new since you looked at 06:00" "since when New tells what moved"
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

# The primary's own part of the terminal's status bar row, drawn again by
# bin/fm-status-bar.sh --replay --own, reaches the page word for word with each
# colour as a tone, and sits under the message box, not under the header.
test_the_mirror_shows_the_terminal_status_row() {
  local home out page
  home=$(make_home statusrow)
  write_screen "$home"
  printf '\033[1m⚓ Opus\033[0m\033[2m·\033[0mhigh \033[2m│\033[0m \033[92m🧠35%%\033[0m \033[91;1m👁 not watching\033[0m \033[95m1 ready to merge\033[0m\n' > "$home/status.row"
  serve_home "$home"
  page=$(curl -sS --cookie "$(cat "$home/web.test-cookie")" "http://127.0.0.1:$(cat "$home/web.test-port")/")
  python3 - "$page" <<'PY' || fail "the status row should sit under the message box, after it and not in the header"
import sys
page = sys.argv[1]
row, box, header = page.find('id="statusrow"'), page.find('id="input"'), page.find('</header>')
sys.exit(0 if header < box < row else 1)
PY
  out=$(mirror "$home")
  assert_equals "$(jq -r '[.model.status[] | .text] | join("")' <<<"$out")" \
    "⚓ Opus·high │ 🧠35% 👁 not watching 1 ready to merge" "the row's words are the terminal's"
  assert_equals "$(jq -r '[.model.status[] | select(.tone != "") | "\(.tone):\(.text)"] | join("|")' <<<"$out")" \
    "bold:⚓ Opus|dim:·|dim:│|green:🧠35%|alarm:👁 not watching|magenta:1 ready to merge" "each colour is a tone"
  rm -f "$home/status.row"
  sleep 2.2   # the server keeps one reading for two seconds
  assert_equals "$(mirror "$home" | jq -c '.model.status')" "[]" "no row leaves the status bar out"
  pass "the mirror shows the terminal's status bar row word for word"
}

# Watch this worker opens a read-only live copy of that worker's screen. On
# 2026-11-24 the button only opened the project's tab, so the owner could never
# watch the worker at all. The screen is read by bin/fm-peek.sh, only for a job
# the pane keeps a live copy for, as plain text with every terminal escape
# removed; the page has no way to type into it.
test_watch_this_worker_shows_its_live_screen_read_only() {
  local home out port cookie
  home=$(make_home watch)
  write_screen "$home"
  # The busy worker has a live copy; finished work does not.
  jq '(.factories[0].jobs[0].live, .factories[0].page.now[0].live) = true | .factories[0].jobs[1].live = false' \
    "$home/screen.json" > "$home/screen.next" && mv "$home/screen.next" "$home/screen.json"
  mkdir -p "$home/peek"
  printf '\033[1m╭─ Garden\033[0m\r\n│ \033[32m⏺\033[0m Sorting\tthe queue\n│ <b>not a tag</b> \033]0;a title\007\033]8;;https://example.invalid\033\\a link\033]8;;\033\\\033(B\007\n\n\n' \
    > "$home/peek/garden-water"
  printf 'finished\n' > "$home/peek/garden-share"
  serve_home "$home"
  port=$(cat "$home/web.test-port") cookie=$(cat "$home/web.test-cookie")
  worker() { curl -sS --cookie "$cookie" "http://127.0.0.1:$port/api/worker?job=$1"; }
  out=$(worker garden-water)
  assert_equals "$(jq -c '{live, title, project, readable}' <<<"$out")" \
    '{"live":true,"title":"Garden reminders","project":"garden-journal","readable":true}' "a busy worker can be watched"
  assert_equals "$(jq -r '.lines | join("\n")' <<<"$out")" "$(printf '╭─ Garden\n│ ⏺ Sorting     the queue\n│ <b>not a tag</b> a link')" \
    "its screen is plain text: escapes and controls gone, tabs expanded, the blank rows below dropped, markup left as words"
  assert_equals "$(cat "$home/peek.asks")" "garden-water 80 FM_HOME=$home" "the screen is read through fm-peek.sh for that one job"
  assert_equals "$(worker garden-share | jq -c .)" '{"job":"garden-share","live":false}' \
    "a job with no live copy says so"
  assert_equals "$(grep -c garden-share "$home/peek.asks")" "0" "a job with no live copy is never read"
  rm "$home/peek/garden-water"
  sleep 1.2   # one read serves every page for a second
  assert_equals "$(worker garden-water | jq -c '{live, readable, lines}')" '{"live":true,"readable":false,"lines":[]}' \
    "a screen that cannot be read says so"
  assert_equals "$(status_of --cookie "$cookie" "http://127.0.0.1:$port/api/worker?job=../x")" "400" "only a job name is read"
  assert_equals "$(status_of "http://127.0.0.1:$port/api/worker?job=garden-water")" "403" "the screen needs the sign-in"
  assert_equals "$(status_of --cookie "$cookie" -X POST -H "X-FM-CSRF: $(csrf_of "$port" "$cookie")" -d '{}' \
    "http://127.0.0.1:$port/api/worker?job=garden-water")" "404" \
    "nothing can be sent to the worker's screen"
  pass "Watch this worker shows that worker's live screen as plain text, read only"
}

# Claude's suggested next prompt reaches the page while the first mate is
# ready, read through bin/fm-desk-voice.sh suggestion; while it works there is
# none and the screen is not read.
test_the_suggested_prompt_reaches_the_page_only_while_ready() {
  local home out n=0 reads
  home=$(make_home suggestion)
  write_basic_transcript "$(transcript "$home")"
  printf '%s\n' '{"type":"system","subtype":"turn_duration","uuid":"s9"}' >> "$(transcript "$home")"
  printf 'yes, ship both changes\n' > "$home/suggestion"
  serve_home "$home"
  while [ "$n" -lt 30 ]; do
    out=$(conversation "$home")
    [ "$(jq -r '.suggestion' <<<"$out")" = "yes, ship both changes" ] && break
    sleep 0.2
    n=$((n + 1))
  done
  assert_equals "$(jq -r '.state' <<<"$out")" "idle" "the turn has ended"
  assert_equals "$(jq -r '.suggestion' <<<"$out")" "yes, ship both changes" "the suggestion reaches the page"
  out=$(curl -sS --cookie "$(cat "$home/web.test-cookie")" \
    "http://127.0.0.1:$(cat "$home/web.test-port")/api/conversation?since=$(jq -r '.version' <<<"$out")")
  assert_equals "$(jq -r '.unchanged' <<<"$out")" "true" "an unchanged reading"
  assert_equals "$(jq -r '.suggestion' <<<"$out")" "yes, ship both changes" "an unchanged reading still carries the suggestion"
  printf '%s\n' '{"type":"user","uuid":"u9","origin":{"kind":"human"},"message":{"role":"user","content":"go on"}}' >> "$(transcript "$home")"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.state' <<<"$out")" "busy" "a new turn is under way"
  assert_equals "$(jq -r '.suggestion' <<<"$out")" "" "no suggestion while it works"
  reads=$(wc -l < "$home/suggestion.reads")
  sleep 2.5
  conversation "$home" >/dev/null
  assert_equals "$(wc -l < "$home/suggestion.reads")" "$reads" "the screen is not read while it works"
  [ ! -e "$home/desk-voice.args" ] || fail "reading the suggestion must never send anything"
  pass "the suggested prompt reaches the page only while firstmate is ready"
}

# The prompt the terminal waits on a person for reaches the page in place of
# Thinking, read through bin/fm-desk-voice.sh prompt, and leaves it within a
# read or two of being answered; reading it sends nothing.
test_a_prompt_waiting_on_a_person_reaches_the_page() {
  local home out n=0 tab=$'\t'
  home=$(make_home prompt)
  write_basic_transcript "$(transcript "$home")"
  serve_home "$home"
  out=$(conversation "$home")
  assert_equals "$(jq -r '.state' <<<"$out")" "busy" "a turn is under way"
  assert_equals "$(jq -r '.prompt' <<<"$out")" "null" "no prompt yet"
  printf 'yesno%sDo you want to proceed?%sBash command\n' "$tab" "$tab" > "$home/prompt"
  while [ "$n" -lt 30 ]; do
    out=$(conversation "$home")
    [ "$(jq -r '.prompt.kind' <<<"$out")" = yesno ] && break
    sleep 0.2
    n=$((n + 1))
  done
  assert_equals "$(jq -r '.prompt | [.kind, .question, .heading] | join("|")' <<<"$out")" \
    "yesno|Do you want to proceed?|Bash command" "the yes or no reaches the page"
  out=$(curl -sS --cookie "$(cat "$home/web.test-cookie")" \
    "http://127.0.0.1:$(cat "$home/web.test-port")/api/conversation?since=$(jq -r '.version' <<<"$out")")
  assert_equals "$(jq -r '.unchanged' <<<"$out")" "true" "an unchanged reading"
  assert_equals "$(jq -r '.prompt.question' <<<"$out")" "Do you want to proceed?" "an unchanged reading still carries the prompt"
  rm "$home/prompt"
  n=0
  while [ "$n" -lt 30 ]; do
    out=$(conversation "$home")
    [ "$(jq -r '.prompt' <<<"$out")" = null ] && break
    sleep 0.2
    n=$((n + 1))
  done
  assert_equals "$(jq -r '.prompt' <<<"$out")" "null" "an answered prompt leaves the page"
  printf 'choice%sPick a colour?%s\n' "$tab" "$tab" > "$home/prompt"
  n=0
  while [ "$n" -lt 30 ]; do
    out=$(conversation "$home")
    [ "$(jq -r '.prompt.kind' <<<"$out")" = choice ] && break
    sleep 0.2
    n=$((n + 1))
  done
  assert_equals "$(jq -r '.prompt.question' <<<"$out")" "Pick a colour?" "a question with choices reaches the page"
  printf '%s\n' '{"type":"user","uuid":"r9","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"read"}]}}' >> "$(transcript "$home")"
  rm "$home/prompt"
  assert_equals "$(jq -r '.prompt' <<<"$(conversation "$home")")" "null" "a new reading drops the prompt read before it at once"
  printf 'choice\tPick \342\200\224 a\342\200\tcolour\n' > "$home/prompt"
  n=0
  while [ "$n" -lt 30 ]; do
    out=$(conversation "$home")
    [ "$(jq -r '.prompt.kind' <<<"$out")" = choice ] && break
    sleep 0.2
    n=$((n + 1))
  done
  assert_equals "$(jq -r '.prompt | [.question, .heading] | join("|")' <<<"$out")" \
    $'Pick \xe2\x80\x94 a\xef\xbf\xbd|colour' "a question cut inside a character still reaches the page"
  printf 'yesno%sDo you want to proceed?%sBash command\n' "$tab" "$tab" > "$home/prompt"
  n=0
  while [ "$n" -lt 30 ]; do
    out=$(conversation "$home")
    [ "$(jq -r '.prompt.kind' <<<"$out")" = yesno ] && break
    sleep 0.2
    n=$((n + 1))
  done
  assert_equals "$(jq -r '.prompt.kind' <<<"$out")" "yesno" "a later prompt is still read"
  printf 'nonsense%sWhat?%s\n' "$tab" "$tab" > "$home/prompt"
  sleep 2
  conversation "$home" >/dev/null
  sleep 0.5
  assert_equals "$(jq -r '.prompt' <<<"$(conversation "$home")")" "null" "only a yes or no or a choice counts"
  [ -s "$home/prompt.reads" ] || fail "the prompt was never read"
  [ ! -e "$home/desk-voice.args" ] || fail "reading the prompt must never send anything"
  pass "a prompt waiting on a person reaches the page in place of Thinking and leaves once answered"
}

# A prompt shown after Starship's startup has taken the session lock but
# before the first entry of the conversation is written still reaches the
# page while the lock holder lives; once it is gone nothing is read.
test_a_prompt_after_startup_before_any_conversation_reaches_the_page() {
  local home out n=0 tab=$'\t'
  home=$(make_home prompt-start)
  rm "$(transcript "$home")"
  printf 'yesno%sDo you want to proceed?%sBash command\n' "$tab" "$tab" > "$home/prompt"
  serve_home "$home"
  while [ "$n" -lt 30 ]; do
    out=$(conversation "$home")
    [ "$(jq -r '.prompt.kind' <<<"$out")" = yesno ] && break
    sleep 0.2
    n=$((n + 1))
  done
  assert_equals "$(jq -r '.state' <<<"$out")" "offline" "no conversation is written yet"
  assert_equals "$(jq -r '.prompt | [.kind, .question] | join("|")' <<<"$out")" \
    "yesno|Do you want to proceed?" "the prompt before the first conversation entry reaches the page"
  python3 -c 'import subprocess; p=subprocess.Popen(["true"]); p.wait(); print(p.pid)' > "$home/state/.lock"
  assert_equals "$(jq -r '.prompt' <<<"$(conversation "$home")")" "null" "no prompt once the lock holder is gone"
  pass "a prompt after startup but before any conversation reaches the page while the lock holder lives"
}

# A suggestion read that was still under way when a turn began belongs to the
# turn before, so it never comes back once that new turn ends.
test_a_suggestion_read_from_before_a_turn_is_dropped() {
  local home out n=0 seen=""
  home=$(make_home suggestion-stale)
  write_basic_transcript "$(transcript "$home")"
  printf '%s\n' '{"type":"system","subtype":"turn_duration","uuid":"s9"}' >> "$(transcript "$home")"
  printf 'the old suggestion\n' > "$home/suggestion"
  printf '1.5\n' > "$home/suggestion.delay"
  serve_home "$home"
  assert_equals "$(jq -r '.state' <<<"$(conversation "$home")")" "idle" "the turn has ended"
  while [ ! -s "$home/suggestion.reads" ] && [ "$n" -lt 50 ]; do conversation "$home" >/dev/null; sleep 0.1; n=$((n + 1)); done
  [ -s "$home/suggestion.reads" ] || fail "the suggestion was never read"
  printf 'the new suggestion\n' > "$home/suggestion"
  rm "$home/suggestion.delay"
  printf '%s\n' '{"type":"user","uuid":"u9","origin":{"kind":"human"},"message":{"role":"user","content":"go on"}}' >> "$(transcript "$home")"
  assert_equals "$(jq -r '.state' <<<"$(conversation "$home")")" "busy" "a new turn is under way"
  printf '%s\n' '{"type":"system","subtype":"turn_duration","uuid":"s10"}' >> "$(transcript "$home")"
  n=0
  while [ "$n" -lt 30 ]; do
    out=$(jq -r '.suggestion' <<<"$(conversation "$home")")
    [ "$out" = "the old suggestion" ] && fail "a suggestion read before the turn came back after it"
    seen=$out
    [ "$seen" = "the new suggestion" ] && break
    sleep 0.2
    n=$((n + 1))
  done
  assert_equals "$seen" "the new suggestion" "the suggestion after the turn is read afresh"
  pass "a suggestion read from before a turn is dropped"
}

# A restart waits for a send under way, so the page hears how its send went
# and never asks for it again.
test_a_restart_waits_for_a_send_under_way() {
  local home root code port cookie csrf n=0 status
  home=$(make_home restart-send)
  root=$(make_root "$home" "sent: tmux %1")
  code=$home/code/fm-web.py
  mkdir -p "$home/code"
  cp "$ENGINE" "$code"
  : > "$home/web-serve.log"
  HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" FM_WEB_CODE_CHECK_SECONDS=0.2 \
    python3 "$code" serve --home "$home" --root "$root" --port 0 >"$home/web-serve.log" 2>&1 &
  printf '%s\n' "$!" >> "$WEB_PID_FILE"
  while [ "$n" -lt 50 ] && ! grep -qE '^listening on' "$home/web-serve.log"; do sleep 0.1; n=$((n + 1)); done
  port=$(sed -n 's/^listening on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$home/web-serve.log" | head -n 1)
  [ -n "$port" ] || fail "the server did not start: $(cat "$home/web-serve.log")"
  cookie=$(sign_in "$home" "$port")
  csrf=$(csrf_of "$port" "$cookie")
  printf '2\n' > "$home/send.delay"
  curl -sS -o "$home/send.out" -w '%{http_code}' -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" \
    --data '{"text":"hello"}' "http://127.0.0.1:$port/api/send" > "$home/send.status" 2>&1 &
  n=0
  while [ ! -e "$home/desk-voice.args" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  [ -e "$home/desk-voice.args" ] || fail "the send did not reach desk voice"
  printf '\n# a newer version\n' >> "$code"
  wait $!
  status=$(cat "$home/send.status")
  assert_equals "$status" "200" "the send under way is answered before the restart"
  assert_contains "$(cat "$home/send.out")" "typed" "the page hears the send went through"
  n=0
  while ! grep -q 'changed on disk; restarting' "$home/web-serve.log" && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  assert_contains "$(cat "$home/web-serve.log")" "changed on disk; restarting" "the server still restarts after the send"
  pass "a restart waits for a send under way"
}

# A restart that cannot start the new code leaves the running server
# answering sends and button presses as before.
test_a_failed_restart_keeps_sends_and_buttons_working() {
  local home root code port cookie csrf out n=0
  home=$(make_home restart-fails)
  root=$(make_root "$home" "sent: tmux %1")
  code=$home/code/fm-web.py
  mkdir -p "$home/code" "$home/python"
  cp "$ENGINE" "$code"
  ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$home/python/python3"
  : > "$home/web-serve.log"
  HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" FM_WEB_CODE_CHECK_SECONDS=0.2 \
    "$home/python/python3" "$code" serve --home "$home" --root "$root" --port 0 >"$home/web-serve.log" 2>&1 &
  printf '%s\n' "$!" >> "$WEB_PID_FILE"
  while [ "$n" -lt 50 ] && ! grep -qE '^listening on' "$home/web-serve.log"; do sleep 0.1; n=$((n + 1)); done
  port=$(sed -n 's/^listening on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$home/web-serve.log" | head -n 1)
  [ -n "$port" ] || fail "the server did not start: $(cat "$home/web-serve.log")"
  cookie=$(sign_in "$home" "$port")
  csrf=$(csrf_of "$port" "$cookie")
  rm "$home/python/python3"
  printf '\n# a newer version\n' >> "$code"
  n=0
  while ! grep -q 'not restarting:' "$home/web-serve.log" && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  assert_contains "$(cat "$home/web-serve.log")" "not restarting:" "the failed restart is logged"
  assert_equals "$(status_of --max-time 5 -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"text":"hello"}' \
    "http://127.0.0.1:$port/api/send")" "200" "a send is still answered"
  out=$(curl -sS --max-time 5 -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" \
    --data '{"action":"talk","factory":"garden-journal","text":"check the ribbon"}' "http://127.0.0.1:$port/api/act" 2>&1)
  [ -n "$(jq -r '.said // empty' <<<"$out" 2>/dev/null)" ] || fail "a button press is still answered (got '$out')"
  pass "a failed restart keeps sends and buttons working"
}

# The server restarts itself in place when its own code on disk changes, so an
# update shows without restarting it by hand, and the page learns it runs
# newer code; code that does not compile leaves the running server alone.
test_the_server_restarts_itself_when_its_code_changes() {
  local home root code port cookie pid build page_build n=0 next out
  home=$(make_home restart)
  root=$(make_root "$home" "sent: tmux %1")
  code=$home/code/fm-web.py
  mkdir -p "$home/code"
  cp "$ENGINE" "$code"
  : > "$home/web-serve.log"
  HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" FM_WEB_CODE_CHECK_SECONDS=0.2 \
    python3 "$code" serve --home "$home" --root "$root" --port 0 >"$home/web-serve.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$WEB_PID_FILE"
  while [ "$n" -lt 50 ] && ! grep -qE '^listening on' "$home/web-serve.log"; do sleep 0.1; n=$((n + 1)); done
  port=$(sed -n 's/^listening on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$home/web-serve.log" | head -n 1)
  [ -n "$port" ] || fail "the server did not start: $(cat "$home/web-serve.log")"
  cookie=$(sign_in "$home" "$port")
  build=$(curl -sS --cookie "$cookie" "http://127.0.0.1:$port/api/conversation" | jq -r '.build')
  page_build=$(curl -sS --cookie "$cookie" "http://127.0.0.1:$port/" | sed -n 's/.*data-build="\([0-9a-f]*\)".*/\1/p')
  [ -n "$build" ] && [ "$build" != null ] || fail "a reading should name the code the server runs"
  assert_equals "$page_build" "$build" "the page carries the code it was served by"
  printf '\ndef broken(:\n' >> "$code"
  sleep 1.5
  assert_equals "$(curl -sS --cookie "$cookie" "http://127.0.0.1:$port/api/conversation" | jq -r '.build')" "$build" \
    "code that does not compile leaves the running server as it was"
  assert_contains "$(cat "$home/web-serve.log")" "does not compile" "the refusal is logged"
  cp "$ENGINE" "$code"
  printf '\n# a newer version\n' >> "$code"
  n=0
  while [ "$n" -lt 50 ]; do
    next=$(curl -sS --cookie "$cookie" "http://127.0.0.1:$port/api/conversation" 2>/dev/null | jq -r '.build' 2>/dev/null)
    [ -n "$next" ] && [ "$next" != null ] && [ "$next" != "$build" ] && break
    sleep 0.2
    n=$((n + 1))
  done
  [ -n "$next" ] && [ "$next" != "$build" ] || fail "the server did not restart on its new code: $(cat "$home/web-serve.log")"
  kill -0 "$pid" 2>/dev/null || fail "the restarted server must keep its process id"
  out=$(ps -o args= -p "$pid")
  assert_contains "$out" "serve --home $home --root $root --port $port" "it keeps its command line and its port"
  pass "the server restarts itself in place when its code changes, and keeps running on code that does not compile"
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
  # An older question's Bring back and No longer needed buttons send what
  # bin/fm-factory.py act takes for them (revive and drop, docs/factory-pane.md).
  post '{"action":"revive","item":"recipe-units","asking":"2026-10-01"}' >/dev/null
  post '{"action":"drop","item":"recipe-units","asking":"2026-10-01"}' >/dev/null
  assert_equals "$(sed -n '5,6p' "$home/act.asks" | jq -c .)" \
    '{"action":"revive","item":"recipe-units","asking":"2026-10-01"}
{"action":"drop","item":"recipe-units","asking":"2026-10-01"}' "an older question's two buttons do not reach the factory script"
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

# What machinery types into the chat is a quiet notice, never the owner's
# words; a picture the owner pasted or the desk voice sent is shown as a
# picture, never as its path, while any other image path the owner typed stays
# in the words and gets its picture too; and the page can fetch only the
# pictures the shown conversation holds.
test_notices_fold_away_and_pasted_pictures_show_as_pictures() {
  local home out port cookie shot png id status
  home=$(make_home pictures)
  mkdir -p "$home/state/desk-voice/shots"
  shot="$home/state/desk-voice/shots/20261119T210000000000Z-ab12cd34.png"
  printf '\x89PNG\r\n\x1a\nshot' > "$shot"
  printf '\x89PNG\r\n\x1a\nshot2' > "$home/state/desk-voice/shots/20261119T210500000000Z-ef56ab78.png"
  mkdir -p "$home/assets"
  printf '\x89PNG\r\n\x1a\nlogo' > "$home/assets/logo.png"
  mkdir -p "$home/My Shots"
  printf '\x89PNG\r\n\x1a\ndragged' > "$home/My Shots/Screen shot.png"
  png=$(printf '\x89PNG\r\n\x1a\npasted' | base64 | tr -d '\n')
  {
    jq -nc '{type:"user",uuid:"n1",origin:{kind:"human"},message:{role:"user",content:"[firstmate desk-voice] a desk voice message is waiting in the mailbox. Run bin/fm-wake-drain.sh now to pick it up."}}'
    jq -nc '{type:"user",uuid:"n2",origin:{kind:"human"},message:{role:"user",content:"[firstmate inbox] captain inbox note 7 is queued. Run bin/fm-wake-drain.sh now."}}'
    jq -nc '{type:"attachment",uuid:"n3",attachment:{type:"queued_command",prompt:"⁣: Firstmate operational input waiting: read the note",origin:{kind:"human"}}}'
    jq -nc --arg shot "$shot" '{type:"user",uuid:"u1",origin:{kind:"human"},message:{role:"user",content:("This is the chart on my phone Screenshots: " + $shot)}}'
    jq -nc '{type:"user",uuid:"u2",origin:{kind:"human"},message:{role:"user",content:"See /no/such/folder/gone.png please"}}'
    jq -nc --arg png "$png" '{type:"user",uuid:"u3",origin:{kind:"human"},message:{role:"user",content:[{type:"text",text:"[Image #1] the new icon"},{type:"image",source:{type:"base64",media_type:"image/png",data:$png}}]}}'
    jq -nc --arg p "${home// /\\ }/My\\ Shots/Screen\\ shot.png" --arg q "$home/My Shots/Screen shot.png" \
      '{type:"user",uuid:"u4",origin:{kind:"human"},message:{role:"user",content:("Dragged " + $p + " and quoted \u0027" + $q + "\u0027")}}'
    jq -nc --arg p "$home/state/desk-voice/shots/20261119T210500000000Z-ef56ab78.png" \
      '{type:"user",uuid:"u5",origin:{kind:"human"},message:{role:"user",content:("and this one " + $p)}}'
    jq -nc --arg p "$home/assets/logo.png" '{type:"user",uuid:"u6",origin:{kind:"human"},message:{role:"user",content:("please make " + $p + " bigger")}}'
  } > "$(transcript "$home")"
  serve_home "$home"
  out=$(conversation "$home") || fail "conversation read failed"
  assert_equals "$(jq -r '[.items[].kind] | join(",")' <<<"$out")" "event,event,event,user,user,user,user,user,user" \
    "doorbells and operational input are notices, the owner's messages are messages"
  assert_equals "$(jq -r '[.items[0:3][].summary] | join("|")' <<<"$out")" \
    "A message waited in the mailbox|A note waited in the inbox|A notice for firstmate" "what each notice says"
  assert_equals "$(jq -r '.items[3].html' <<<"$out")" "<p>This is the chart on my phone</p>" \
    "the screenshot's path and its label are taken out of the words"
  assert_equals "$(jq -r '.items[3].pictures | length' <<<"$out")" "1" "the screenshot is one picture"
  assert_contains "$(jq -r '.items[4].html' <<<"$out")" "/no/such/folder/gone.png" "a path to nothing stays as written"
  assert_equals "$(jq -r '.items[4].pictures | length' <<<"$out")" "0" "a path to nothing is no picture"
  assert_equals "$(jq -r '.items[5] | "\(.html)|\(.images)|\(.pictures | length)"' <<<"$out")" "<p>the new icon</p>|1|1" \
    "a pasted image drops its placeholder and is one picture"
  assert_contains "$(jq -r '.items[6].html' <<<"$out")" "Shots/Screen\\ shot.png and quoted" \
    "a dragged path outside the shots folder stays in the words as written"
  assert_equals "$(jq -r '.items[6].pictures | length' <<<"$out")" "1" \
    "a dragged path with escaped spaces, and the same path quoted, are one picture"
  assert_equals "$(jq -r '.items[7] | "\(.html)|\(.pictures | length)"' <<<"$out")" "<p>and this one</p>|1" \
    "a screenshot from the shots folder leaves the words without its label"
  assert_contains "$(jq -r '.items[8].html' <<<"$out")" "please make $home/assets/logo.png bigger" \
    "an image path the owner typed in a sentence stays in the words"
  assert_equals "$(jq -r '.items[8].pictures | length' <<<"$out")" "1" "and still shows as a picture"
  port=$(cat "$home/web.test-port")
  cookie=$(cat "$home/web.test-cookie")
  id=$(jq -r '.items[3].pictures[0]' <<<"$out")
  assert_equals "$(curl -sS --cookie "$cookie" "http://127.0.0.1:$port/api/picture/$id" | od -An -c | tr -s ' ' | head -1)" \
    "$(od -An -c < "$shot" | tr -s ' ' | head -1)" "the screenshot's own bytes come back"
  assert_equals "$(curl -sS -o /dev/null -w '%{content_type}' --cookie "$cookie" "http://127.0.0.1:$port/api/picture/$id")" "image/png" "as a PNG"
  id=$(jq -r '.items[5].pictures[0]' <<<"$out")
  assert_equals "$(curl -sS --cookie "$cookie" "http://127.0.0.1:$port/api/picture/$id" | tail -c 6)" "pasted" "the pasted image's bytes come back"
  assert_equals "$(status_of "http://127.0.0.1:$port/api/picture/$id")" "403" "a picture needs the cookie"
  status=$(status_of --cookie "$cookie" "http://127.0.0.1:$port/api/picture/$(printf '0%.0s' $(seq 1 24))")
  assert_equals "$status" "404" "an id the conversation did not hand out is not found"
  assert_equals "$(status_of --cookie "$cookie" "http://127.0.0.1:$port/api/picture/..%2f..%2fetc")" "404" "a path is not an id"
  pass "notices fold away, pasted pictures show as pictures, and only the shown ones can be fetched"
}

# The desk floater's Front line is for firstmate, not the owner: the chat
# hides it, typed on the words' line or saved on its own, under its old label
# and its new one, while words that only mention "Front:" stay as written.
test_the_front_line_is_hidden_from_the_chat() {
  local home out shot
  home=$(make_home frontline)
  mkdir -p "$home/state/desk-voice/shots"
  shot="$home/state/desk-voice/shots/20261123T190000000000Z-ab12cd34.png"
  printf '\x89PNG\r\n\x1a\nshot' > "$shot"
  {
    jq -nc '{type:"user",uuid:"u1",origin:{kind:"human"},message:{role:"user",content:"What does this error mean Front: Xcode (com.apple.dt.Xcode) - window title (set by the app): Build log"}}'
    jq -nc '{type:"user",uuid:"u2",origin:{kind:"human"},message:{role:"user",content:"Read this back\nFront: Notes (com.apple.Notes) - window title (untrusted): todo"}}'
    jq -nc --arg shot "$shot" '{type:"user",uuid:"u3",origin:{kind:"human"},message:{role:"user",content:("Look at this Front: Google Chrome (com.google.Chrome) - window title (set by the app): Starship - Lars Screenshots: " + $shot)}}'
    jq -nc '{type:"user",uuid:"u4",origin:{kind:"human"},message:{role:"user",content:"Hide it Front: Notes (com.apple.Notes)"}}'
    jq -nc '{type:"user",uuid:"u5",origin:{kind:"human"},message:{role:"user",content:"Front: the hero image, then the footer"}}'
    jq -nc '{type:"user",uuid:"u6",origin:{kind:"human"},message:{role:"user",content:"Put the Front: Notes (com.apple.Notes) line first, then the rest"}}'
    jq -nc '{type:"user",uuid:"u7",origin:{kind:"human"},message:{role:"user",content:"Move the Front: page up Front: Safari (com.apple.Safari) - window title (set by the app): Home"}}'
  } > "$(transcript "$home")"
  serve_home "$home"
  out=$(conversation "$home") || fail "conversation read failed"
  assert_equals "$(jq -r '.items[0].html' <<<"$out")" "<p>What does this error mean</p>" \
    "a Front line typed after the words is hidden"
  assert_equals "$(jq -r '.items[1].html' <<<"$out")" "<p>Read this back</p>" \
    "a Front line on its own line, under the old label, is hidden"
  assert_equals "$(jq -r '.items[2] | "\(.html)|\(.pictures | length)"' <<<"$out")" "<p>Look at this</p>|1" \
    "a Front line before the screenshots is hidden and the screenshot still shows"
  assert_equals "$(jq -r '.items[3].html' <<<"$out")" "<p>Hide it</p>" "a Front line with no window title is hidden"
  assert_contains "$(jq -r '.items[4].html' <<<"$out")" "Front: the hero image, then the footer" \
    "words that only start with Front: stay"
  assert_contains "$(jq -r '.items[5].html' <<<"$out")" "Front: Notes (com.apple.Notes) line first, then the rest" \
    "a Front line shape in the middle of the words stays"
  assert_equals "$(jq -r '.items[6].html' <<<"$out")" "<p>Move the Front: page up</p>" \
    "only the Front line goes when the words also say Front:"
  pass "the Front line is hidden from the chat, and the owner's own words stay"
}

# Opening the address without signing in shows what this is and how to get in;
# the look, the icons and the manifest load for anyone on this Mac, nothing else does.
test_the_address_without_a_sign_in_explains_itself() {
  local home root port page manifest size
  home=$(make_home gate)
  root=$(make_root "$home" "sent: tmux %1")
  port=$(start_web "$home" "$root")
  page=$(curl -sS "http://127.0.0.1:$port/")
  assert_equals "$(status_of "http://127.0.0.1:$port/")" "403" "the page itself stays shut"
  assert_contains "$page" "How to get in"
  assert_contains "$page" "bin/fm-web.sh open"
  assert_contains "$page" "/settings.js"
  assert_not_contains "$page" "data-csrf"
  assert_not_contains "$page" "expired"
  assert_contains "$(curl -sS "http://127.0.0.1:$port/?token=wrong")" "expired" "a wrong link says it no longer works"
  manifest=$(curl -sS "http://127.0.0.1:$port/manifest.webmanifest")
  assert_equals "$(jq -r '"\(.name)|\(.display)|\(.start_url)|\([.icons[].sizes] | join(","))"' <<<"$manifest")" \
    "Starship|standalone|/|any,192x192,512x512" "the manifest makes it installable as its own app"
  for size in 32 180 192 512; do
    assert_equals "$(curl -sS "http://127.0.0.1:$port/icon-$size.png" | python3 -c 'import sys; d=sys.stdin.buffer.read(); print(d[:8] == b"\x89PNG\r\n\x1a\n", int.from_bytes(d[16:20], "big"), int.from_bytes(d[20:24], "big"))')" \
      "True $size $size" "the $size pixel icon"
  done
  assert_contains "$(curl -sS "http://127.0.0.1:$port/icon.svg")" "<svg"
  assert_equals "$(status_of "http://127.0.0.1:$port/view.js")" "200" "the page's rules load without a sign-in"
  assert_equals "$(status_of "http://127.0.0.1:$port/api/mirror")" "403" "the projects do not"
  assert_equals "$(status_of -H "Host: evil.example:$port" "http://127.0.0.1:$port/manifest.webmanifest")" "403" "nor anything on a rebound Host"
  pass "the address without a sign-in explains itself, and only the look, icons and manifest load"
}

# open signs a browser in with a link that works once, within two minutes, and
# never carries the token.
test_open_signs_in_once_with_a_link_that_is_not_the_token() {
  local home link token hdr code
  home=$(make_home openlink)
  link=$(FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" "$LAUNCHER" open --print --port 0 2>&1) \
    && fail "open took a flag it does not have: $link"
  link=$(FM_WEB_PORT=0 FM_HOME="$home" HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" "$LAUNCHER" open --print) \
    || fail "open --print failed: $link"
  WEB_PIDS+=("$(cat "$home/state/web/web.pid")")
  case "$link" in http://127.0.0.1:[0-9]*/\?code=*) ;; *) fail "open did not print a one-time loopback link: $link" ;; esac
  token=$(head -n 1 "$home/state/web/token")
  assert_not_contains "$link" "$token" "the link carries no token"
  assert_equals "$(if [ "$(uname)" = Darwin ]; then stat -f '%Lp' "$home/state/web/codes"; else stat -c '%a' "$home/state/web/codes"; fi)" "700" "codes are kept owner-only"
  hdr=$home/open.hdr
  curl -sS -o /dev/null -D "$hdr" "$link"
  assert_contains "$(cat "$hdr")" "303" "the link signs in"
  assert_contains "$(tr -d '\r' < "$hdr")" "Location: /" "and drops the code from the address"
  assert_grep "Set-Cookie: fm_web_" "$hdr"
  assert_equals "$(status_of "$link")" "403" "a second visit with the same link is refused"
  assert_contains "$(curl -sS "$link")" "expired" "and says so"
  link=$(FM_HOME="$home" "$LAUNCHER" open --print) || fail "a second open --print failed"
  code=${link##*code=}
  for f in "$home/state/web/codes"/*; do printf '%s\n' 1000 > "$f"; done
  assert_equals "$(status_of "$link")" "403" "a link past its two minutes is refused"
  assert_equals "$(FM_HOME="$home" "$LAUNCHER" stop)" "stopped"
  [ -n "$code" ] || fail "no code in the link"
  pass "open signs in once, within two minutes, with a link that is not the token"
}

# The settings script is the page's own, fetched as the browser fetches it and
# run against a stand-in for the browser's storage.
# The voice belongs to the home, not the browser: Settings reads and changes it
# only through bin/fm-speak.sh, behind the same POST guards as a send.
test_the_voice_in_settings_is_the_homes_through_fm_speak() {
  local home root port cookie csrf url out
  home=$(make_home voice)
  root=$(make_root "$home" "sent: tmux %1")
  port=$(start_web "$home" "$root")
  cookie=$(sign_in "$home" "$port")
  csrf=$(csrf_of "$port" "$cookie")
  url="http://127.0.0.1:$port/api/voice"
  out=$(curl -sS --cookie "$cookie" "$url")
  assert_equals "true 100 false" "$(jq -r '"\(.enabled) \(.volume) \(.muted)"' <<<"$out")" "the voice is read from fm-speak.sh"
  assert_equals "The fix landed. Shall I merge it?" "$(jq -r '.replies[0].text' <<<"$out")" "a recent reply shows its caption"
  assert_equals "7 6" "$(jq -r '[.replies[].number] | join(" ")' <<<"$out")" "newest first"
  assert_equals "403" "$(status_of -X POST --cookie "$cookie" --data '{"volume":60}' "$url")" "no CSRF header"
  assert_absent "$home/speak.volume" "a refused change reaches nothing"
  out=$(curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"volume":60}' "$url")
  assert_equals "60" "$(cat "$home/speak.volume")" "the level is kept by fm-speak.sh --volume"
  assert_equals "60" "$(jq -r '.voice.volume' <<<"$out")" "the answer carries the new level"
  curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"mute":true}' "$url" >/dev/null
  [ -e "$home/speak.muted" ] || fail "mute did not reach fm-speak.sh --mute"
  out=$(curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"replay":7}' "$url")
  assert_equals "true" "$(jq -r '.ok' <<<"$out")" "a recent reply plays again"
  assert_grep "--replay 7" "$home/speak.asks" "replay goes through fm-speak.sh --replay"
  for bad in '{"volume":201}' '{"volume":"60"}' '{"volume":60,"mute":true}' '{"shell":"x"}' 'nope'; do
    assert_equals "400" "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data "$bad" "$url")" "refused: $bad"
  done
  assert_equals "60" "$(cat "$home/speak.volume")" "a refused change keeps the level"
  : > "$home/speak.off"
  assert_equals "false" "$(curl -sS --cookie "$cookie" "$url" | jq -r .enabled)" "a home that does not speak says so"
  assert_contains "$(curl -sS --cookie "$cookie" "http://127.0.0.1:$port/")" 'id="voiceLevel"' "Settings carry the voice level"
  pass "the voice in Settings is the home's, read and changed only through fm-speak.sh"
}

# A page the owner is looking at tells the desk floater so, through one file
# in the home, so the floater keeps its reply bubble quiet.
test_a_page_in_front_marks_the_home_for_the_floater() {
  local home root port cookie csrf url marker bad
  home=$(make_home front)
  root=$(make_root "$home" "sent: tmux %1")
  port=$(start_web "$home" "$root")
  cookie=$(sign_in "$home" "$port")
  csrf=$(csrf_of "$port" "$cookie")
  url="http://127.0.0.1:$port/api/front"
  marker="$home/state/desk-voice/web-front"
  assert_absent "$marker" "no page has said anything yet"
  assert_equals "403" "$(status_of -X POST --cookie "$cookie" --data '{"page":"pageone1","front":true}' "$url")" "no CSRF header"
  assert_absent "$marker" "a refused word marks nothing"
  assert_equals "true" "$(curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" \
    --data '{"page":"pageone1","front":true}' "$url" | jq -r .front)" "a page in front is recorded"
  [ -f "$marker" ] || fail "a page in front must leave the marker"
  curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data '{"page":"pagetwo2","front":false}' "$url" >/dev/null
  [ -f "$marker" ] || fail "another page losing focus must not clear a page still in front"
  assert_equals "false" "$(curl -sS -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" \
    --data '{"page":"pageone1","front":false}' "$url" | jq -r .front)" "the last page leaving says so"
  assert_absent "$marker" "no page in front leaves no marker"
  ! grep -qF 'POST /api/front HTTP/1.1" 200' "$home/state/web/web.log" || fail "the beats must stay out of the request log"
  for bad in '{"page":"short","front":true}' '{"page":"pageone1","front":"yes"}' '{"page":"pageone1"}' \
    '{"page":"page/one1","front":true}' '{"page":"pageone1","front":true,"x":1}' 'nope'; do
    assert_equals "400" "$(status_of -X POST --cookie "$cookie" -H "X-FM-CSRF: $csrf" --data "$bad" "$url")" "refused: $bad"
  done
  assert_absent "$marker" "a refused word marks nothing"
  pass "a page in front marks the home for the desk floater, and only while one is"
}

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
const page = () => ({ style: { props: {}, setProperty(k, v) { this.props[k] = v; }, getPropertyValue(k) { return this.props[k] || ''; },
  removeProperty(k) { delete this.props[k]; } }, attrs: {}, setAttribute(k, v) { this.attrs[k] = v; } });
const out = [];
out.push('first visit: ' + JSON.stringify(S.load(storage)));
kept['fm-web-settings'] = JSON.stringify({ text: 0, style: 'lively', theme: 'dark', motion: 'less' });
out.push('after the first version: ' + JSON.stringify(S.load(storage)));
S.save(storage, { text: 3, style: 'lively', theme: 'dark', motion: 'less', keys: 'hide', split: 0.4, splitTab: 0.7 });
out.push('next visit: ' + JSON.stringify(S.load(storage)));
const el = page();
S.apply(el, S.load(storage));
out.push('on the page: ' + el.style.fontSize + ' ' + JSON.stringify(el.style.props) + ' ' + JSON.stringify(el.attrs));
S.save(storage, { text: 99, style: 'neon', theme: 'dark', motion: 'less', keys: 'maybe', split: 5 });
out.push('a bad value: ' + JSON.stringify(S.load(storage)));
kept[S.KEY] = '{not json';
out.push('unreadable: ' + JSON.stringify(S.load(storage)));
out.push('no storage: ' + JSON.stringify(S.load(null)) + ' ' + JSON.stringify(S.save(null, { text: 0 }).text));
out.push('sizes: ' + S.TEXT_STEPS.join(' ') + ' | ' + S.TEXT_NAMES.join(' ') + ' | starts on ' + S.TEXT_NAMES[S.DEFAULTS.text]);
out.push('chat width: ' + S.TEXT_NAMES.map((name, text) => { const p = page(); S.apply(p, { text }); return name + ' ' + p.style.props['--wrap']; }).join(', '));
console.log(out.join('\n'));
JS
) || fail "the settings script did not run: $out"
  assert_equals "$out" 'first visit: {"text":2,"style":"calm","theme":"auto","motion":"auto","keys":"show","split":0.55,"colours":"default","custom":null}
after the first version: {"text":2,"style":"lively","theme":"dark","motion":"less","keys":"show","split":0.55,"colours":"default","custom":null}
next visit: {"text":3,"style":"lively","theme":"dark","motion":"less","keys":"hide","split":0.4,"colours":"default","custom":null}
on the page: 120% {"--wrap":"48rem","--split":"0.4"} {"data-style":"lively","data-theme":"dark","data-motion":"less","data-keys":"hide","data-colours":"default"}
a bad value: {"text":2,"style":"calm","theme":"dark","motion":"less","keys":"show","split":0.75,"colours":"default","custom":null}
unreadable: {"text":2,"style":"calm","theme":"auto","motion":"auto","keys":"show","split":0.55,"colours":"default","custom":null}
no storage: {"text":2,"style":"calm","theme":"auto","motion":"auto","keys":"show","split":0.55,"colours":"default","custom":null} 0
sizes: 80 90 100 120 145 | Smaller Small Normal Large Largest | starts on Normal
chat width: Smaller 60rem, Small 53.33rem, Normal 48rem, Large 48rem, Largest 48rem' "the settings a browser keeps and what they put on the page"
  pass "settings start on normal text in the middle, keep the look from the first version, the key hints and the panel size, drop a size kept for a panel that is gone, and smaller text widens the chat"
}

# The colour schemes: the settings script, fetched as the browser fetches it,
# puts a scheme's light or dark on the page, keeps custom colours for each
# apart, takes them all off for Default, and never shows text too faint to read.
test_colours_are_kept_and_kept_readable() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }
  local home out
  home=$(make_home colours)
  serve_home "$home"
  curl -sS --cookie "$(cat "$home/web.test-cookie")" "http://127.0.0.1:$(cat "$home/web.test-port")/settings.js" > "$home/settings.js"
  out=$(node - "$home/settings.js" <<'JS'
const S = require(process.argv[2]);
const kept = {};
const storage = { getItem: k => (k in kept ? kept[k] : null), setItem: (k, v) => { kept[k] = String(v); } };
const page = () => ({ style: { props: {}, setProperty(k, v) { this.props[k] = v; }, getPropertyValue(k) { return this.props[k] || ''; },
  removeProperty(k) { delete this.props[k]; } }, attrs: {}, setAttribute(k, v) { this.attrs[k] = v; } });
const wears = el => ['--bg', '--here', '--ink'].map(k => el.style.props[k] || '-').join(' ');
const out = [];
const el = page();
S.apply(el, S.save(storage, { colours: 'slate' }), false);
out.push('slate, auto, light computer: ' + wears(el) + ' ' + el.attrs['data-colours']);
S.apply(el, S.load(storage), true);
out.push('slate, auto, dark computer: ' + wears(el) + ' ' + el.style.props['color-scheme']);
S.apply(el, S.save(storage, { colours: 'slate', theme: 'light' }), true);
out.push('slate, light chosen, dark computer: ' + wears(el));
S.apply(el, S.save(storage, { colours: 'default' }), true);
out.push('back to default: ' + JSON.stringify(el.style.props));
const custom = { light: { accent: '#AA3300', bg: '#fff8e0', ink: '#202020' }, dark: null };
S.apply(el, S.save(storage, { colours: 'custom', custom }), false);
out.push('custom in light: ' + wears(el) + ' kept ' + JSON.stringify(S.load(storage).custom));
S.apply(el, S.load(storage), true);
out.push('custom in dark, none picked there: ' + wears(el));
out.push('bad colours: ' + JSON.stringify(S.clean({ colours: 'neon', custom: { light: { accent: 'red', bg: '#ffffff', ink: '#000000' } } })));
const faint = S.palette({ accent: '#ffeb3b', bg: '#ffffff', ink: '#eeeeee' }, {});
out.push('faint picks: nudged ' + faint.nudged.join(',') + ', text ' + faint.vars['--ink'] + ', accent ' + faint.vars['--here']);
const backs = v => [v['--bg'], v['--surface'], v['--surface-2']];
const low = v => Math.min(...['--ink', '--ink-2', '--here'].flatMap(k => backs(v).map(b => S.contrast(v[k], b))));
out.push('faint picks now read at least: ' + (low(faint.vars) >= S.READABLE));
out.push('wcag: black on white ' + S.contrast('#000000', '#ffffff') + ', #777777 on white ' + S.contrast('#777777', '#ffffff').toFixed(2) +
  ', #767676 on white ' + S.contrast('#767676', '#ffffff').toFixed(2) + ', AA ' + S.READABLE);
out.push('mid-grey backgrounds: ' + ['#707070', '#727272', '#747474', '#7a7a7a'].map(bg => {
  const made = S.palette({ accent: '#ff0000', bg, ink: '#ffffff' }, { work: '#7e6431' });
  const work = Math.min(...['--surface', '--surface-2'].map(k => S.contrast(made.vars['--work'], made.vars[k])));
  return bg + (made.nudged.indexOf('bg') >= 0 ? ' lifted' : '') + (low(made.vars) >= 4.5 && work >= 4.5 ? ' reads' : ' FAINT');
}).join(', '));
out.push('schemes: ' + Object.keys(S.SCHEMES).map(name => ['light', 'dark'].map(mode => {
  const made = S.palette(S.SCHEMES[name][mode], {});
  return S.SCHEMES[name].name + ' ' + mode + (made.nudged.length ? ' nudged' : '') + (low(made.vars) >= S.READABLE ? ' reads' : ' FAINT') + (made.dark === (mode === 'dark') ? '' : ' WRONG SHADE');
}).join(', ')).join(', '));
global.getComputedStyle = () => ({ getPropertyValue: k => ({ '--work': ' #7E6431', '--you': '#9F5749', '--here': '#47707F', '--bg': '#ECE8E1', '--ink': '#2A2A28' })[k] || '' });
const dark = page();
S.apply(dark, { colours: 'custom', custom: { light: { accent: '#ffcc66', bg: '#101010', ink: '#f0f0f0' } } }, false);
const p = dark.style.props;
out.push("the style's own colours on a dark custom background: work " + p['--work'] + ' reads ' + (S.contrast(p['--work'], p['--surface']) >= S.READABLE) +
  ', you ' + p['--you'] + ' reads ' + (S.contrast(p['--you'], p['--surface']) >= S.READABLE) + ', done untouched ' + (p['--done'] === undefined));
out.push('own colours: ' + JSON.stringify(S.own(dark).picks) + ', scheme put back ' + (dark.style.props['--bg'] === '#101010'));
console.log(out.join('\n'));
JS
) || fail "the settings script did not run: $out"
  assert_equals "$out" 'slate, auto, light computer: #e6e8ee #4a5ba8 #22252e slate
slate, auto, dark computer: #14161c #a3b1f0 #e6e8ef dark
slate, light chosen, dark computer: #e6e8ee #4a5ba8 #22252e
back to default: {"--wrap":"48rem","--split":"0.55"}
custom in light: #fff8e0 #aa3300 #202020 kept {"light":{"accent":"#aa3300","bg":"#fff8e0","ink":"#202020"},"dark":null}
custom in dark, none picked there: - - -
bad colours: {"text":2,"style":"calm","theme":"auto","motion":"auto","keys":"show","split":0.55,"colours":"default","custom":null}
faint picks: nudged ink,accent, text #727272, accent #80761e
faint picks now read at least: true
wcag: black on white 21, #777777 on white 4.48, #767676 on white 4.54, AA 4.5
mid-grey backgrounds: #707070 lifted reads, #727272 lifted reads, #747474 lifted reads, #7a7a7a reads
schemes: Sea light reads, Sea dark reads, Green light reads, Green dark reads, Warm light reads, Warm dark reads, Slate light reads, Slate dark reads, Paper light reads, Paper dark reads
the style'"'"'s own colours on a dark custom background: work #a08c67 reads true, you #b67f75 reads true, done untouched true
own colours: {"accent":"#47707f","bg":"#ece8e1","ink":"#2a2a28"}, scheme put back true' "the colours a browser keeps and what they put on the page"
  out=$(curl -sS --cookie "$(cat "$home/web.test-cookie")" "http://127.0.0.1:$(cat "$home/web.test-port")/")
  assert_contains "$out" 'aria-label="Colour schemes"' "the settings offer the schemes"
  assert_contains "$out" 'type="color" id="pickAccent"' "an accent picker"
  assert_contains "$out" 'type="color" id="pickBg"' "a background picker"
  assert_contains "$out" 'type="color" id="pickInk"' "a text picker"
  assert_contains "$out" '>Back to default<' "and one way back"
  pass "a colour scheme wears its own light and dark, custom colours are kept for each apart, Default takes them all off, and text too faint to read is moved to the nearest readable shade"
}

# The page's rules, fetched as the browser fetches them and run without a page:
# the chat folded into messages and one quiet line per run of steps, links as
# short labels, and every key naming the button it stands for, so a key sends
# the note that button sends, with no look from a project's tab. On 2026-11-22
# every call on a project's own tab repeated that project's name beside its
# title, and on a phone the chosen tab could sit out of sight.
test_the_page_folds_the_chat_labels_links_and_keys_send_the_buttons_notes() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }
  local home root port out
  home=$(make_home view)
  root=$(make_root "$home" "sent: tmux %1")
  port=$(start_web "$home" "$root")
  curl -sS "http://127.0.0.1:$port/view.js" > "$home/view.js"
  out=$(node - "$home/view.js" <<'JS'
const V = require(process.argv[2]);
const out = [];
const rows = V.foldChat([
  { kind: 'user', id: 'u1' },
  { kind: 'tool', id: 't1', name: 'Bash', summary: 'ls -la', about: 'List files' },
  { kind: 'tool', id: 't2', name: 'Read', summary: '/home/demo/notes.md' },
  { kind: 'event', id: 'e1', summary: 'A message waited in the mailbox' },
  { kind: 'tool', id: 't3', name: 'Bash', summary: 'git status', error: true },
  { kind: 'assistant', id: 'a1' },
  { kind: 'tool', id: 't4', name: 'mcp__mail__send', summary: 'x', pending: true },
]);
out.push('rows: ' + rows.map(r => r.kind === 'quiet' ? V.quietLabel(r) + (r.error ? ' (one failed)' : '') : r.kind).join(' / '));
out.push('steps: ' + rows[1].steps.map(s => s.text).join('; '));
out.push('links: ' + V.plainText('https://github.com/example/garden/pull/42 is ready to merge') + ' | '
  + V.plainText('See https://gitlab.example/x/-/merge_requests/9, https://github.com/a/b/issues/3 and https://www.example.org/docs.'));
out.push('link parts: ' + JSON.stringify(V.linkParts('Open https://github.com/a/b/pull/7.')));
const ask = { id: 'garden-chart', asking: '1794632400', question: true, project: 'garden', read: true,
  options: [{ key: '1' }, { key: '2' }] };
const done = { id: 'garden-share', asking: '1794636660', question: false, project: 'garden' };
const garden = { id: 'garden', you_steer: false, jobs: [{ id: 'g1', read: true }] };
const on = (hl, extra) => Object.assign({ hl, tab: 'home', projectOf: id => (id === 'garden' ? garden : null) }, extra || {});
const keys = (ctx, list) => list.map(k => k + '=' + JSON.stringify(V.keyAction(k, ctx))).join(' ');
out.push('on a question: ' + keys(on({ kind: 'call', call: ask }), ['2', '7', 'x', 't', 'r', 's', 'k', 'Enter']));
out.push('on finished work: ' + keys(on({ kind: 'call', call: done }), ['k', 'c', 'x', '1']));
out.push('on a project: ' + keys(on({ kind: 'project', project: garden }), ['Enter', 't', 'r', 's']));
out.push('while confirming: ' + keys(on(null, { confirming: true }), ['Enter', 'Escape', 'x', 'Tab', 'Shift', 'ArrowDown', 'End', ' ']));
out.push('anywhere: ' + keys(on(null), ['ArrowDown', 'ArrowUp', '?', 'Escape', 'q']));
out.push('watching a worker: ' + keys(on({ kind: 'call', call: ask }, { watching: true }), ['Escape', '?', '1', 'k', 't', 's', 'Enter', 'ArrowDown']));
out.push('notes: ' + JSON.stringify([
  V.noteFor({ act: 'answer', option: '2' }, ask), V.noteFor({ act: 'keep' }, done), V.noteFor({ act: 'settled' }, ask),
  V.noteFor({ act: 'steer', factory: 'garden', who: 'you' }), V.noteFor({ act: 'read', id: 'garden-chart' }),
  V.noteFor({ act: 'talk', kind: 'discuss', id: 'garden-chart', text: 'why?' }, ask),
  V.noteFor({ act: 'talk', kind: 'talk', factory: 'garden', text: 'hello' })]));
out.push('look: ' + JSON.stringify(V.withLook({ action: 'settled', item: 'garden-chart' }, 'home')) + ' '
  + JSON.stringify(V.withLook({ action: 'settled', item: 'garden-chart' }, 'garden')));
out.push('strip: ' + V.keyStrip({}).map(k => k.join(' ')).join(', ') + ' | ' + V.keyStrip({ confirming: true }).map(k => k.join(' ')).join(', ')
  + ' | ' + V.keyStrip({ watching: true }).map(k => k.join(' ')).join(', '));
const card = { project_name: 'Garden Journal', waited: 'waiting 3 h' };
const mates = { project_name: 'Garden Journal', waited: 'ready 53 min', mate: 'near' };
out.push('beside a call: ' + [V.callMeta(card, false, false), V.callMeta(card, true, false), V.callMeta(card, true, true),
  V.callMeta(mates, false, false), V.callMeta(mates, true, false), V.callMeta({}, true, false)].map(m => m.join(' · ') || '-').join(' | '));
out.push('tabs: ' + [V.tabScroll(0, 300, 20, 120), V.tabScroll(0, 300, 420, 120), V.tabScroll(400, 300, 100, 120),
  V.tabScroll(400, 300, 0, 120), V.tabScroll(250, 300, 400, 120)].join(' '));
console.log(out.join('\n'));
JS
) || fail "the page's rules did not run: $out"
  assert_equals "$out" 'rows: user / Looked at 4 things (one failed) / assistant / Looking at 1 thing…
steps: List files; Read notes.md; A message waited in the mailbox; Ran a command
links: the pull request is ready to merge | See the merge request, the issue and example.org.
link parts: [{"text":"Open "},{"text":"the pull request","url":"https://github.com/a/b/pull/7"},{"text":"."}]
on a question: 2={"act":"pick","id":"garden-chart","option":"2"} 7=null x={"act":"settled","id":"garden-chart"} t={"act":"talk","kind":"discuss","id":"garden-chart"} r={"act":"read","id":"garden-chart"} s={"act":"steer","factory":"garden","who":"you"} k=null Enter={"act":"open","id":"garden-chart"}
on finished work: k={"act":"keep","id":"garden-share"} c={"act":"talk","kind":"change","id":"garden-share"} x=null 1=null
on a project: Enter={"act":"tab","id":"garden"} t={"act":"talk","kind":"talk","factory":"garden"} r={"act":"read","factory":"garden","job":"g1"} s={"act":"steer","factory":"garden","who":"you"}
while confirming: Enter={"act":"send"} Escape={"act":"cancel"} x={"act":"hint","text":"Press enter to send it to Starship, or esc to cancel."} Tab=null Shift=null ArrowDown=null End=null  =null
anywhere: ArrowDown={"act":"move","step":1} ArrowUp={"act":"move","step":-1} ?={"act":"keys"} Escape={"act":"back"} q=null
watching a worker: Escape={"act":"back"} ?={"act":"keys"} 1=null k=null t=null s=null Enter=null ArrowDown=null
notes: [{"action":"answer","item":"garden-chart","asking":"1794632400","option":"2"},{"action":"keep","item":"garden-share","asking":"1794636660"},{"action":"settled","item":"garden-chart","asking":"1794632400"},{"action":"steer","factory":"garden","who":"you"},{"action":"read","item":"garden-chart"},{"action":"discuss","item":"garden-chart","asking":"1794632400","text":"why?"},{"action":"talk","factory":"garden","text":"hello"}]
look: {"action":"settled","item":"garden-chart"} {"in_tab":true,"action":"settled","item":"garden-chart"}
strip: ↑↓ move, 1/2/3 answer, enter open, x settled?, k keep, t talk, r read, s who steers, ? all keys | enter send to Starship, esc cancel | esc back to the project, ? all keys
beside a call: Garden Journal · waiting 3 h | waiting 3 h | checking | Garden Journal, from near · ready 53 min | from near · ready 53 min | -
tabs: 0 252 88 0 250' \
    "how the page folds the chat, labels links, what each key sends, what sits beside a call and where the tabs scroll to"
  pass "the chat folds into messages and quiet lines, links read as short labels, keys send the buttons' notes, a call on its own project's tab does not repeat the project, and a chosen tab is brought into sight"
}

# The live line while the first mate works: what it is doing now in plain
# words, never a command, path or code, and for how long.
test_the_live_line_says_what_is_happening_in_plain_words() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }
  local home root port out
  home=$(make_home live)
  root=$(make_root "$home" "sent: tmux %1")
  port=$(start_web "$home" "$root")
  curl -sS "http://127.0.0.1:$port/view.js" > "$home/view.js"
  out=$(node - "$home/view.js" <<'JS'
const V = require(process.argv[2]);
const pending = (name, about, summary) => [{ kind: 'user', id: 'u' }, { kind: 'tool', id: 't', name, about, summary, pending: true }];
console.log([
  V.nowWords([]), V.nowWords([{ kind: 'user', id: 'u' }]),
  V.nowWords([{ kind: 'tool', id: 't', name: 'Bash', about: 'List files', pending: false }]),
  V.nowWords(pending('Bash', 'Show the open pull requests', 'gh pr list')),
  V.nowWords(pending('Bash', '', 'rm -rf /tmp/x')),
  V.nowWords(pending('Bash', 'Run bin/fm-lint.sh', 'bin/fm-lint.sh')),
  V.nowWords(pending('Bash', 'Count `rows` with $HOME', 'x')),
  V.nowWords(pending('Read', '', '/home/demo/notes.md')),
  V.nowWords(pending('Edit', '', '/home/demo/notes.md')),
  V.nowWords(pending('Grep', '', 'secret.*key')),
  V.nowWords(pending('Agent', 'Look through the web code', '')),
  V.nowWords(pending('mcp__mail__search', '', '{"q":"x"}')),
  V.nowWords(pending('Skill', '', 'no-mistakes')),
  V.nowWords(pending('Bash', 'word '.repeat(30), 'x')).length <= 81,
].join(' | '));
console.log([0, 9400, 61000, 3599000, 3780000].map(V.took).join(' | '));
const said = (p) => { const w = V.promptWords(p); return w ? w.what + ' / ' + w.ask : 'none'; };
console.log([said(null), said({ kind: 'yesno', question: '' }),
  said({ kind: 'yesno', question: 'Do you want to proceed?', heading: 'Bash command' }),
  said({ kind: 'choice', question: 'Pick a colour?', heading: '' }),
  said({ kind: 'yesno', question: 'Do you want to make this edit to /home/demo/notes.md?', heading: 'Edit file' }),
  said({ kind: 'yesno', question: 'Do you want to create notes.md?', heading: '' }),
  said({ kind: 'yesno', question: 'Do you want to proceed?', heading: 'rm -rf build' }),
  said({ kind: 'yesno', question: 'Run `make deploy` now?', heading: 'Bash command' }),
  said({ kind: 'choice', question: '', heading: '' }),
  said({ kind: 'yesno', question: 'Do you want to create .env?', heading: 'Create file' }),
  said({ kind: 'yesno', question: 'Do you want to create .env?', heading: '' }),
  said({ kind: 'yesno', question: 'Do you want to make this edit to LICENSE?', heading: 'Edit file' }),
  said({ kind: 'yesno', question: 'Do you want to allow this fetch?', heading: 'Fetch' }),
  said({ kind: 'choice', question: 'Ready to publish?', heading: 'Release' }),
  said({ kind: 'choice', question: 'Ready to publish notes.md?', heading: '' }),
  said({ kind: 'choice', question: 'Which config should I change, app.json or web.json?', heading: '' }),
  said({ kind: 'choice', question: 'Keep "-rf" in the script?', heading: '' }),
  said({ kind: 'yesno', question: 'Do you want to make this edit to LICENSE?', heading: '' }),
  said({ kind: 'choice', question: 'Which web framework should we use?', heading: 'Web stack' }),
  said({ kind: 'yesno', question: 'Do you trust the files in this folder?', heading: '' }),
  said({ kind: 'yesno', question: 'Should I deploy now?', heading: 'Web deploy' }),
  said({ kind: 'yesno', question: 'Do you want to create a release?', heading: '' }),
  said({ kind: 'other', question: 'Pick one?', heading: '' })].join(' | '));
const at = Date.parse('2026-11-23T18:55:13Z'), q = { ts: '2026-11-23T18:55:13Z' };
console.log([V.waitingWords(q, 'busy', at + 5000), V.waitingWords(q, 'busy', at + V.WAIT_LONG_MS + 1000),
  V.waitingWords(q, 'idle', at + 5000), V.waitingWords(q, 'offline', at + 5000), V.waitingWords({}, 'busy', at)].join(' | '));
JS
) || fail "the live line rules did not run: $out"
  assert_equals "$out" 'Thinking | Thinking | Thinking | Show the open pull requests | Running a command | Running a command | Running a command | Reading a file | Changing a file | Searching the files | Waiting on a helper: Look through the web code | Using a connected app | Reading its notes | true
0s | 9s | 1m 01s | 59m 59s | 1h 03m
none | Waiting for your yes or no in the terminal / Firstmate needs your yes or no | Waiting for your yes or no in the terminal / Firstmate wants to run a command | Waiting for your answer in the terminal / Pick a colour? | Waiting for your yes or no in the terminal / Firstmate wants to change a file | Waiting for your yes or no in the terminal / Firstmate needs your yes or no | Waiting for your yes or no in the terminal / Firstmate needs your yes or no | Waiting for your yes or no in the terminal / Firstmate wants to run a command | Waiting for your answer in the terminal / Firstmate needs an answer | Waiting for your yes or no in the terminal / Firstmate wants to change a file | Waiting for your yes or no in the terminal / Firstmate needs your yes or no | Waiting for your yes or no in the terminal / Firstmate wants to change a file | Waiting for your yes or no in the terminal / Firstmate wants to use the web | Waiting for your answer in the terminal / Release: Ready to publish? | Waiting for your answer in the terminal / Firstmate needs an answer | Waiting for your answer in the terminal / Firstmate needs an answer | Waiting for your answer in the terminal / Firstmate needs an answer | Waiting for your yes or no in the terminal / Firstmate needs your yes or no | Waiting for your answer in the terminal / Web stack: Which web framework should we use? | Waiting for your yes or no in the terminal / Firstmate needs your yes or no | Waiting for your yes or no in the terminal / Firstmate needs your yes or no | Waiting for your yes or no in the terminal / Firstmate needs your yes or no | none
Waiting, Firstmate will read it next | Still waiting, Firstmate has not read it yet | Still waiting, Firstmate has not read it yet | Still waiting, Firstmate has not read it yet | Waiting, Firstmate will read it next' "the live line in plain words, how long the turn has run, and what a waiting message says"
  pass "the live line says what is happening in plain words and for how long"
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

test_the_weekly_page_opens_from_the_mirror() {
  local home root port cookie hdr nonce body
  home=$(make_home weekly)
  root=$(make_root "$home" "sent: tmux %1")
  port=$(start_web "$home" "$root")
  cookie=$(sign_in "$home" "$port")
  assert_not_contains "$(curl -sS --cookie "$cookie" "http://127.0.0.1:$port/")" 'href="/weekly"' "no link before a weekly page exists"
  assert_equals "$(status_of --cookie "$cookie" "http://127.0.0.1:$port/weekly")" "404" "no page yet is a plain 404"
  mkdir -p "$home/data/weekly-changes"
  printf '<!doctype html><html><head><style>body{color:red}</style></head><body><h1>What changed this week</h1></body></html>\n' \
    > "$home/data/weekly-changes/latest.html"
  assert_contains "$(curl -sS --cookie "$cookie" "http://127.0.0.1:$port/")" 'href="/weekly"' "the page links to the weekly page"
  assert_equals "$(status_of "http://127.0.0.1:$port/weekly")" "403" "the weekly page needs the cookie"
  hdr=$home/weekly.hdr
  body=$(curl -sS -D "$hdr" --cookie "$cookie" "http://127.0.0.1:$port/weekly")
  assert_contains "$body" "What changed this week" "the weekly page is served"
  nonce=$(sed -n "s/.*style-src 'nonce-\([^']*\)'.*/\1/p" "$hdr" | tr -d '\r')
  [ -n "$nonce" ] || fail "the weekly page has no style nonce: $(cat "$hdr")"
  assert_contains "$body" "<style nonce=\"$nonce\">" "the weekly page's style carries the response nonce"
  pass "the mirror links to and serves the newest weekly page behind the sign-in"
}

test_transcript_parsing_collapses_tools_and_marks_compaction
test_numbered_lists_keep_their_numbers
test_idle_offline_and_session_restart
test_a_working_turn_says_when_it_began
test_a_turn_begun_before_the_read_part_carries_no_start
test_a_message_typed_mid_turn_shows_as_waiting_until_it_is_read
test_emphasis_around_code_renders
test_cleared_session_is_followed_through_the_live_registry
test_tail_reads_only_the_end_of_a_large_transcript
test_conversation_command_prints_versioned_json
test_get_guards_token_cookie_and_host
test_post_guards_never_reach_desk_voice
test_send_uses_desk_voice_with_saved_images
test_send_reports_typed
test_a_long_paste_is_sent_and_the_limit_is_named
test_a_reply_links_files_under_the_home_and_serves_them_read_only
test_notices_fold_away_and_pasted_pictures_show_as_pictures
test_the_front_line_is_hidden_from_the_chat
test_the_address_without_a_sign_in_explains_itself
test_open_signs_in_once_with_a_link_that_is_not_the_token
test_the_mirror_is_the_pane_and_the_strip_in_plain_words
test_the_mirror_shows_the_terminal_status_row
test_watch_this_worker_shows_its_live_screen_read_only
test_the_suggested_prompt_reaches_the_page_only_while_ready
test_a_prompt_waiting_on_a_person_reaches_the_page
test_a_prompt_after_startup_before_any_conversation_reaches_the_page
test_the_server_restarts_itself_when_its_code_changes
test_a_suggestion_read_from_before_a_turn_is_dropped
test_a_restart_waits_for_a_send_under_way
test_a_failed_restart_keeps_sends_and_buttons_working
test_a_button_is_handed_to_the_factory_script_and_nowhere_else
test_settings_are_kept_in_the_browser
test_the_voice_in_settings_is_the_homes_through_fm_speak
test_a_page_in_front_marks_the_home_for_the_floater
test_colours_are_kept_and_kept_readable
test_the_page_folds_the_chat_labels_links_and_keys_send_the_buttons_notes
test_the_live_line_says_what_is_happening_in_plain_words
test_the_weekly_page_opens_from_the_mirror
test_launcher_start_status_url_stop
