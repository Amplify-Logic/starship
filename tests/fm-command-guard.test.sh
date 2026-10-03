#!/usr/bin/env bash
# tests/fm-command-guard.test.sh - the opt-in worker command guard
# (bin/fm-command-guard.py) and the hook bin/fm-spawn.sh installs for it.
#
# Only the network is stubbed: a local fake endpoint
# (tests/fixtures/command-guard/fake-typesafe.py) records every request it
# receives and answers with whatever the case put in its response file, so the
# real gate, the real redaction, the real request, the real HTTP call and the
# real rule all run. Two responses are recorded from the live model on
# 2026-09-29 (a force-push to main and a plain `git status`); the others are
# written here to sit either side of each threshold.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

GUARD="$ROOT/bin/fm-command-guard.py"
FIX="$ROOT/tests/fixtures/command-guard"
TMP_ROOT=$(fm_test_tmproot fm-command-guard)

command -v python3 >/dev/null 2>&1 || fail "python3 is required"

# An ambient key must never reach a case: the fake endpoint stands in for the
# network, and a real key would only ever be sent to it, but a case that lost
# its endpoint override would then make a paid call.
unset TYPESAFE_API_KEY || true

SRV="$TMP_ROOT/server"
mkdir -p "$SRV"
python3 "$FIX/fake-typesafe.py" "$SRV" &
fm_test_track_pid $!
for _ in $(seq 1 100); do
  [ -s "$SRV/port" ] && break
  sleep 0.05
done
[ -s "$SRV/port" ] || fail "the fake endpoint did not start"
FM_COMMAND_GUARD_ENDPOINT="http://127.0.0.1:$(cat "$SRV/port")/v1/systemone"
export FM_COMMAND_GUARD_ENDPOINT
export FM_COMMAND_GUARD_TIMEOUT=2

reset_server() {  # <response-file-or-json> [status] [delay]
  rm -f "$SRV/requests.jsonl" "$SRV/auth" "$SRV/delay" "$SRV/status"
  if [ -f "$1" ]; then cp "$1" "$SRV/response.json"; else printf '%s\n' "$1" > "$SRV/response.json"; fi
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$SRV/status"
  [ -z "${3:-}" ] || printf '%s\n' "$3" > "$SRV/delay"
}

requests() { [ -f "$SRV/requests.jsonl" ] && wc -l < "$SRV/requests.jsonl" | tr -d ' ' || echo 0; }

answers() {  # <injection> <effect> <confidence> <destructive>
  printf '{"model":"jev-1.13.0","answers":{"injection":{"type":"noul","noul":%s},"effect":{"type":"choice","choice":"%s","confidence":%s,"probabilities":{}},"destructive_intent":{"type":"noul","noul":%s}}}' \
    "$1" "$2" "$3" "$4"
}

new_home() {  # <name> [gate-text]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'TYPESAFE_API_KEY=ts-fixture-key-0001\n' > "$home/.env"
  [ -z "${2:-}" ] || printf '%b' "$2" > "$home/config/command-guard"
  printf '%s\n' "$home"
}

payload() {  # <command> [tool]
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' \
    "$1" "${2:-Bash}"
}

run_hook() {  # <home> <command> [project] [tool]
  payload "$2" "${4:-Bash}" | env -u FM_COMMAND_GUARD_ENV_FILE python3 "$GUARD" hook \
    --config "$1/config" --state "$1/state" --home "$1" --task task-1 --project "${3:-demo}"
}

# --- the gate ---------------------------------------------------------------

test_gate() {
  local home out
  home=$(new_home gate)
  python3 "$GUARD" armed --config "$home/config" --project demo && fail "an absent gate must be off"
  printf 'enabled = false\n' > "$home/config/command-guard"
  python3 "$GUARD" armed --config "$home/config" --project demo && fail "enabled = false must be off"
  printf '# on for this home\nenabled = true\nexclude = private-lab, other\n' > "$home/config/command-guard"
  python3 "$GUARD" armed --config "$home/config" --project demo || fail "enabled = true must arm an unlisted project"
  python3 "$GUARD" armed --config "$home/config" --project private-lab && fail "an excluded project must stay off"
  python3 "$GUARD" armed --config "$home/config" --project other && fail "every excluded project must stay off"
  printf 'enabled = true\n' > "$home/config/command-guard"
  python3 "$GUARD" armed --config "$home/config" --project private-app && fail "Harbour must stay off with no exclude line"
  printf 'enabled = yes\n' > "$home/config/command-guard"
  out=$(python3 "$GUARD" armed --config "$home/config" --project demo 2>&1) && fail "a malformed value must be off"
  assert_contains "$out" "enabled must be true or false" "a malformed gate must say why"
  printf 'enabled = true\nmode = strict\n' > "$home/config/command-guard"
  python3 "$GUARD" armed --config "$home/config" --project demo 2>/dev/null && fail "an unknown key must be off"
  rm -f "$home/config/command-guard"
  printf 'enabled = true\n' > "$home/gate-target"
  ln -s "$home/gate-target" "$home/config/command-guard"
  python3 "$GUARD" armed --config "$home/config" --project demo 2>/dev/null && fail "a symlinked gate must be off"
  pass "the gate is off unless enabled = true, always excludes Harbour, excludes listed projects, and treats a malformed file as off"
}

test_unarmed_hook_sends_nothing() {
  local home out
  home=$(new_home unarmed)
  reset_server "$FIX/response-force-push.json"
  out=$(run_hook "$home" "git push --force origin main")
  assert_equals "" "$out" "an unarmed home must allow without output"
  assert_equals 0 "$(requests)" "an unarmed home must make no call"
  home=$(new_home excluded 'enabled = true\nexclude = demo\n')
  out=$(run_hook "$home" "git push --force origin main" demo)
  assert_equals "" "$out" "an excluded project must allow without output"
  assert_equals 0 "$(requests)" "an excluded project must never be sent"
  home=$(new_home harbour 'enabled = true\n')
  out=$(run_hook "$home" "git push --force origin main" private-app)
  assert_equals "" "$out" "Harbour must allow without output"
  assert_equals 0 "$(requests)" "Harbour must never be sent, whatever the gate says"
  pass "an unarmed home, Harbour and an excluded project allow every command and send nothing"
}

# --- the rule, on recorded live answers ------------------------------------

test_recorded_block_and_allow() {
  local home out
  home=$(new_home recorded 'enabled = true\n')
  reset_server "$FIX/response-force-push.json"
  out=$(run_hook "$home" "git push --force origin main")
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || fail "a force-push to main must be denied, got: $out"
  assert_contains "$out" "irreversible (0.91)" "the deny must name the condition and its confidence"
  assert_contains "$out" "This block is final" "the deny must carry the final-block notice"
  assert_equals 1 "$(requests)" "one command must be one request"
  jq -e '.model == "jev-1.13.0" and (.questions | keys_unsorted) == ["injection","effect","destructive_intent"]' \
    "$SRV/requests.jsonl" >/dev/null || fail "the request must pin the model and ask the injection question first"
  jq -e '(.state | keys) == ["command"]' "$SRV/requests.jsonl" >/dev/null \
    || fail "the state must be the command alone"
  grep -q '"outcome": "block"' "$home/state/command-guard.log" || fail "a block must be logged"

  reset_server "$FIX/response-git-status.json"
  out=$(run_hook "$home" "git status --short")
  assert_equals "" "$out" "git status must be allowed without output"
  grep -q '"outcome": "allow"' "$home/state/command-guard.log" || fail "an allow must be logged"
  pass "recorded live answers deny a force-push to main with the final notice and allow git status"
}

test_thresholds() {
  local home out
  home=$(new_home thresholds 'enabled = true\n')
  reset_server "$(answers 0.02 irreversible 0.59 0.69)"
  out=$(run_hook "$home" "some command")
  assert_equals "" "$out" "irreversible below 0.6 with destructive below 0.7 must allow"
  reset_server "$(answers 0.79 read_only 1.0 0.01)"
  out=$(run_hook "$home" "some command")
  assert_equals "" "$out" "injection below 0.8 must allow"
  reset_server "$(answers 0.02 irreversible 0.60 0.01)"
  out=$(run_hook "$home" "some command")
  assert_contains "$out" '"deny"' "irreversible at 0.6 must block"
  reset_server "$(answers 0.02 reversible 0.99 0.70)"
  out=$(run_hook "$home" "some command")
  assert_contains "$out" "destructive intent (0.70)" "destructive at 0.7 must block whatever the effect"
  reset_server "$(answers 0.80 read_only 1.0 0.01)"
  out=$(run_hook "$home" "some command")
  assert_contains "$out" "text aimed at the reviewer (0.80)" "injection at 0.8 must block even a read-only command"
  pass "irreversible blocks at 0.6, destructive at 0.7 and injection at 0.8, and nothing below them does"
}

test_non_bash_tool_ignored() {
  local home out
  home=$(new_home nonbash 'enabled = true\n')
  reset_server "$FIX/response-force-push.json"
  out=$(run_hook "$home" "rm -rf /" demo Write)
  assert_equals "" "$out" "a non-Bash payload must be allowed"
  assert_equals 0 "$(requests)" "a non-Bash payload must make no call"
  pass "only Bash commands are judged"
}

# --- never send secrets -----------------------------------------------------

test_redaction() {
  local home cmd body
  home=$(new_home redact 'enabled = true\n')
  printf 'TYPESAFE_API_KEY=ts-fixture-key-0001\nDEPLOY_HOOK=https://hooks.example/abc123secretpath\n' > "$home/.env"
  reset_server "$FIX/response-git-status.json"
  cmd=$(printf '%s\n' \
    'STRIPE_KEY=sk_live_plainvalue BUILD_ID=Qx7Lm2Pz9Wk4Rt8V curl -H "Authorization: Bearer abcdefgh12345678" https://ops:hunter22@db.example/x' \
    'gh api -H "token ghp_abcdefghijklmnopqrstuvwxyz0123" --password pa55word99 user' \
    'echo AbCdEfGh1234567890AbCdEfGh1234567890 inline-env-value-777 https://hooks.example/abc123secretpath' \
    "cat > .env <<'EOF'" 'API_KEY=realvalue123' 'EOF')
  MY_SERVICE_TOKEN=inline-env-value-777 run_hook "$home" "$cmd" >/dev/null
  body=$(cat "$SRV/requests.jsonl")
  for secret in sk_live_plainvalue Qx7Lm2Pz9Wk4Rt8V abcdefgh12345678 hunter22 ghp_abcdefghijklmnopqrstuvwxyz0123 pa55word99 \
    AbCdEfGh1234567890AbCdEfGh1234567890 inline-env-value-777 abc123secretpath realvalue123 ts-fixture-key-0001; do
    assert_not_contains "$body" "$secret" "the request body must not carry $secret"
  done
  assert_contains "$body" "cat > .env" "the heredoc command itself must still be judged"
  assert_contains "$body" "API_KEY=<redacted>" "a heredoc assignment must keep its name and lose its value"
  assert_contains "$body" "BUILD_ID=<redacted>" "a random-looking value must be redacted whatever its name"
  assert_equals "Bearer ts-fixture-key-0001" "$(cat "$SRV/auth")" "the key must travel only in the header"
  assert_not_contains "$(cat "$home/state/command-guard.log")" "ts-fixture-key-0001" "the log must never carry the key"
  assert_not_contains "$(cat "$home/state/command-guard.log")" "realvalue123" "the log must carry only the redacted command"
  pass "secret-named or random assignments, .env values, secret-looking environment values and key shapes never leave the machine"
}

test_plain_assignments_stay_visible() {
  local home body wipe
  home=$(new_home plain 'enabled = true\n')
  # shellcheck disable=SC2016 # the command is sent literally, $T and all
  wipe='T=../sibling-copy; rm -rf "$T"'
  reset_server "$FIX/response-git-status.json"
  run_hook "$home" "$wipe" >/dev/null
  body=$(jq -r '.state.command' "$SRV/requests.jsonl")
  assert_equals "$wipe" "$body" "a plain assignment must keep the delete target visible"
  reset_server "$FIX/response-git-status.json"
  run_hook "$home" 'FM_HOME=/work/home dd if=/dev/zero of=/dev/disk2 bs=1m && terraform destroy -var env=prod' >/dev/null
  body=$(jq -r '.state.command' "$SRV/requests.jsonl")
  assert_equals 'FM_HOME=/work/home dd if=/dev/zero of=/dev/disk2 bs=1m && terraform destroy -var env=prod' "$body" \
    "plain paths and ordinary values must reach the judge unchanged"
  pass "plain assignments and arguments such as a delete target, a disk or an environment name stay visible"
}

test_quoted_and_short_secrets_are_redacted() {
  local home cmd body log text
  home=$(new_home redact-short 'enabled = true\n')
  printf 'API_TOKEN=q7x\nDB_PASSWORD=z9\nPIN=abc12\nSERVICE_PIN=7\nMODE=dev\nEMPTY_SECRET=\n' >> "$home/.env"
  reset_server "$FIX/response-git-status.json"
  cmd=$(cat <<'EOF'
client --password 'correct horse battery staple' --token="violet sea shell" --auth "escaped \"quote\" secret" --secret plain-secret
client login q7x z9 abc12 7 q7x-suffix prefixq7x MODE=dev
EOF
)
  payload "$cmd" | env -i PATH="$PATH" FM_COMMAND_GUARD_ENDPOINT="$FM_COMMAND_GUARD_ENDPOINT" \
    python3 "$GUARD" hook --home "$home" --state "$home/state" --config "$home/config" \
    --task fixture --project demo >/dev/null
  body=$(jq -r '.state.command' "$SRV/requests.jsonl")
  log=$(jq -r '.command' "$home/state/command-guard.log")
  for text in "$body" "$log"; do
    assert_not_contains "$text" 'horse' "a quoted password must be removed whole"
    assert_not_contains "$text" 'sea shell' "a quoted equals value must be removed whole"
    assert_not_contains "$text" 'quote' "an escaped quote must not end redaction early"
    assert_not_contains "$text" 'plain-secret' "an unquoted credential must still be removed"
    assert_not_contains "$text" 'login q7x z9' "short secret-named .env values must be removed"
    assert_contains "$text" 'login <redacted> <redacted> <redacted> <redacted>' "short credentials, including one-character PINs, must be redacted"
    assert_contains "$text" 'prefixq7x' "short secrets must match token boundaries"
    assert_contains "$text" 'MODE=dev' "ordinary short values must stay readable"
  done
  pass "whole quoted credentials and short secret-named .env values are removed from requests and logs"
}

test_routine_expansions_are_judged() {
  local home cmd out body
  home=$(new_home redact-routine 'enabled = true\n')
  # shellcheck disable=SC2016 # literal commands sent to the fake judge; nothing here may expand
  for cmd in \
    'GH_TOKEN="$(gh auth token)" gh pr create --fill|GH_TOKEN=<redacted> gh pr create --fill' \
    'mysql --password="$(cat ~/.dbpw)" -e "select 1"|mysql --password=<redacted> -e "select 1"' \
    'export API_KEY="${API_KEY:-dev}"; npm test|export API_KEY=<redacted>; npm test' \
    "cd \"\${HOME}/proj\" && client --token 'abc def'|cd \"\${HOME}/proj\" && client --token <redacted>" \
    "git commit -m \"\$(cat <<'EOF'"$'\n''Redact --password "a b" values whole'$'\n'"EOF"$'\n'")\"|git commit -m \"\$(cat <<'EOF'"$'\n''Redact --password <redacted> values whole'$'\n'"EOF"$'\n'")\""; do
    reset_server "$FIX/response-git-status.json"
    out=$(run_hook "$home" "${cmd%%|*}")
    assert_equals "" "$out" "a routine command with an expanded or quoted credential must be allowed by the judge's answer"
    assert_equals 1 "$(requests)" "a routine command with an expanded or quoted credential must be judged"
    body=$(jq -r '.state.command' "$SRV/requests.jsonl")
    assert_equals "${cmd#*|}" "$body" "the judged command keeps its arguments and loses each credential value"
  done
  pass "routine commands with expanded or quoted credentials are judged with each value redacted"
}

# --- a long command is judged whole, in parts ---------------------------------

part_answers() {  # <part-count> <irreversible-part>: every part benign but one
  python3 -c '
import json, sys
count, hot = int(sys.argv[1]), int(sys.argv[2])
answers = {}
for n in range(1, count + 1):
    answers["injection_%d" % n] = {"type": "noul", "noul": 0.02}
    answers["effect_%d" % n] = {"type": "choice", "choice": "irreversible" if n == hot else "reversible",
                                "confidence": 0.9, "probabilities": {}}
    answers["destructive_intent_%d" % n] = {"type": "noul", "noul": 0.05}
print(json.dumps({"model": "jev-1.13.0", "answers": answers}))' "$1" "$2"
}

test_long_command_judged_in_parts() {
  local home long out
  home=$(new_home parts 'enabled = true\n')
  # The rm -rf straddles the first part's end, well past any head a cut would keep.
  long=$(python3 -c '
body = "cat > a.md <<\x27EOF\x27\n" + "x" * 1960 + "\nEOF\n"
print(body + "rm -rf ../sibling-copy\ncat > b.md <<\x27EOF\x27\n" + "y" * 600 + "\nEOF")')
  reset_server "$(part_answers 2 2)"
  out=$(run_hook "$home" "$long")
  assert_equals 1 "$(requests)" "a long command must still be one request"
  jq -e '(.state | keys) == ["command_1","command_2"]
    and (.questions | keys_unsorted) == ["injection_1","effect_1","destructive_intent_1","injection_2","effect_2","destructive_intent_2"]
    and ([.state[] | select(contains("rm -rf ../sibling-copy"))] | length) >= 1
    and ([.state[] | length] | max) <= 2000' \
    "$SRV/requests.jsonl" >/dev/null || fail "every part must be sent with its own three questions, injection first"
  assert_contains "$out" '"deny"' "a condition firing in any part must block"
  assert_contains "$out" "irreversible (0.90) in part 2 of 2" "the deny must name the condition and the part"

  reset_server "$(part_answers 2 0)"
  out=$(run_hook "$home" "$long")
  assert_equals "" "$out" "a long command with no part firing must be allowed"
  grep -q '"path": "parts"' "$home/state/command-guard.log" || fail "the log must name the parts path"
  pass "a long command is sent whole as overlapping parts in one request, and any part firing blocks"
}

test_parts_failure_falls_back_to_head_and_tail() {
  local home long out
  home=$(new_home fallback 'enabled = true\n')
  long=$(python3 -c 'print("echo " + "a " * 2000 + "&& git push --force origin main")')
  # Single-part answers leave every per-part id unusable, so only the head-and-tail request can use them.
  reset_server "$(answers 0.02 irreversible 0.9 0.1)"
  out=$(run_hook "$home" "$long" 2>/dev/null)
  assert_contains "$out" '"deny"' "a failed parts request must fall back to a head-and-tail judgement that can block"
  assert_contains "$out" "after the parts request failed (unusable answer: injection_1" "the deny must say the head and tail decided, and why"
  assert_equals 2 "$(requests)" "the fallback must be one more request"
  sed -n 2p "$SRV/requests.jsonl" | jq -e '(.state | keys) == ["command"]
    and (.state.command | contains("characters cut") and endswith("git push --force origin main"))
    and (.questions | keys_unsorted) == ["injection","effect","destructive_intent"]' >/dev/null \
    || fail "the fallback must send the head and tail as one part with the three questions"
  grep -q '"path": "head-and-tail"' "$home/state/command-guard.log" || fail "the log must name the head-and-tail path"

  reset_server "$(answers 0.02 irreversible 0.9 0.1)" "" 1
  out=$(FM_COMMAND_GUARD_TIMEOUT=3 FM_COMMAND_GUARD_MULTIPART_TIMEOUT=0.3 run_hook "$home" "$long" 2>/dev/null)
  assert_contains "$out" '"deny"' "a parts request past its own bound must fall back within the single-part bound"

  reset_server '{"error":"boom"}' 500
  out=$(run_hook "$home" "$long" 2>"$TMP_ROOT/fallback.err")
  assert_equals "" "$out" "both requests failing must allow"
  assert_equals 2 "$(requests)" "both requests must have been tried"
  run_hook "$home" "$long" >/dev/null 2>&1
  assert_equals 1 "$(outage_lines "$home")" "both failing must be logged once per episode"
  grep -q '"reason": "parts: HTTP 500; head-and-tail: HTTP 500"' "$home/state/command-guard.log" \
    || fail "the outage must name both failures"
  assert_contains "$(cat "$TMP_ROOT/fallback.err")" "stepping aside" "the step-aside must be reported"
  pass "a failed parts request falls back to one head-and-tail judgement, and only both failing allows"
}

test_over_cap_command_allowed_and_logged() {
  local home long out
  home=$(new_home overcap 'enabled = true\n')
  long=$(python3 -c 'print("echo " + "a " * 10000 + "&& rm -rf ~/work")')
  reset_server "$FIX/response-force-push.json"
  out=$(run_hook "$home" "$long" 2>"$TMP_ROOT/overcap.err")
  assert_equals "" "$out" "a command over the part cap must be allowed"
  assert_equals 0 "$(requests)" "a command over the part cap must not be sent"
  assert_contains "$(cat "$TMP_ROOT/overcap.err")" "over the cap of 8" "the step-aside must be reported"
  grep -q '"outcome": "skip"' "$home/state/command-guard.log" || fail "the step-aside must be logged"
  [ ! -e "$home/state/.command-guard-outage" ] || fail "an over-cap command is not an outage"
  pass "a command over the part cap is allowed unjudged, with a warning on stderr and in the log"
}

# --- steps aside, and logs once ---------------------------------------------

outage_lines() { grep -c '"outcome": "error"' "$1/state/command-guard.log" 2>/dev/null || echo 0; }

test_no_key_allows_and_logs_once() {
  local home out err
  home=$(new_home nokey 'enabled = true\n')
  rm -f "$home/.env"
  reset_server "$FIX/response-force-push.json"
  out=$(run_hook "$home" "git push --force origin main" 2>"$TMP_ROOT/nokey.err")
  assert_equals "" "$out" "no key must allow"
  assert_contains "$(cat "$TMP_ROOT/nokey.err")" "no TYPESAFE_API_KEY" "the first failure must be reported"
  out=$(run_hook "$home" "git push --force origin main" 2>"$TMP_ROOT/nokey2.err")
  assert_equals "" "$out" "no key must keep allowing"
  err=$(cat "$TMP_ROOT/nokey2.err")
  assert_equals "" "$err" "the same outage must not be reported twice"
  assert_equals 1 "$(outage_lines "$home")" "one outage episode must be logged once"
  assert_equals 0 "$(requests)" "no key must make no call"

  printf 'TYPESAFE_API_KEY=ts-fixture-key-0001\n' > "$home/.env"
  run_hook "$home" "git status" >/dev/null 2>&1
  [ ! -e "$home/state/.command-guard-outage" ] || fail "a good answer must end the outage episode"
  rm -f "$home/.env"
  run_hook "$home" "git status" >/dev/null 2>&1
  assert_equals 2 "$(outage_lines "$home")" "a new outage episode must be logged again"
  pass "with no key every command is allowed, and each outage episode is logged once"
}

test_failures_allow() {
  local home out
  home=$(new_home failures 'enabled = true\n')
  reset_server '{"answers": "not an object"}'
  out=$(run_hook "$home" "git push --force origin main" 2>/dev/null)
  assert_equals "" "$out" "an unreadable answer must allow"
  rm -f "$home/state/.command-guard-outage"
  reset_server '{"error":"boom"}' 500
  out=$(run_hook "$home" "git push --force origin main" 2>/dev/null)
  assert_equals "" "$out" "an HTTP error must allow"
  rm -f "$home/state/.command-guard-outage"
  reset_server "$FIX/response-force-push.json" "" 3
  out=$(FM_COMMAND_GUARD_TIMEOUT=0.5 run_hook "$home" "git push --force origin main" 2>/dev/null)
  assert_equals "" "$out" "a timeout must allow"
  grep -q '"reason": "HTTP 500"' "$home/state/command-guard.log" || fail "the HTTP failure must be logged"
  grep -q 'unusable answer' "$home/state/command-guard.log" || fail "the unreadable answer must be logged"
  grep -q 'Timeout\|timed out\|URLError' "$home/state/command-guard.log" || fail "the timeout must be logged"
  reset_server "$(answers 0.02 reversible 0.99 0.95 | jq -c 'del(.answers.injection)')"
  out=$(run_hook "$home" "rm -rf ../other" 2>/dev/null)
  assert_contains "$out" '"deny"' "an unusable answer must not veto a condition that did fire"
  pass "an unreadable answer, an HTTP error and a timeout all allow and are logged, and a partial answer still blocks"
}

# --- the hook fm-spawn installs ---------------------------------------------

spawn_claude() {  # <name> <id> [gate-text] [project-link-name]
  local case_dir="$TMP_ROOT/spawn-$1" home proj wt fakebin
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  printf 'TYPESAFE_API_KEY=ts-fixture-key-0001\n' > "$home/.env"
  [ -z "${3:-}" ] || printf '%b' "$3" > "$home/config/command-guard"
  fm_git_worktree "$proj" "$wt" "wt-$1"
  if [ -n "${4:-}" ]; then
    ln -s "$proj" "$case_dir/$4"
    proj="$case_dir/$4"
  fi
  fm_test_spawn_brief "$home" "$2"
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$2" "$proj" --mode no-mistakes --yolo off >"$case_dir/spawn.out" 2>&1 \
    || fail "claude spawn failed: $(cat "$case_dir/spawn.out")"
  printf '%s\n' "$wt"
}

test_spawn_installs_hook_only_when_armed() {
  local wt settings cmd out
  wt=$(spawn_claude off guard-off)
  settings="$wt/.claude/settings.local.json"
  jq -e '.hooks.Stop and (.hooks | has("PreToolUse") | not)' "$settings" >/dev/null \
    || fail "an unarmed home must not install the guard hook"

  wt=$(spawn_claude excluded guard-excluded 'enabled = true\nexclude = project\n')
  jq -e '.hooks | has("PreToolUse") | not' "$wt/.claude/settings.local.json" >/dev/null \
    || fail "an excluded project must not get the guard hook"

  wt=$(spawn_claude harbour guard-harbour 'enabled = true\n' private-app)
  jq -e '.hooks | has("PreToolUse") | not' "$wt/.claude/settings.local.json" >/dev/null \
    || fail "Harbour, reached through a link to a differently named copy, must not get the guard hook"

  wt=$(spawn_claude linked guard-linked 'enabled = true\nexclude = linked-name\n' linked-name)
  jq -e '.hooks | has("PreToolUse") | not' "$wt/.claude/settings.local.json" >/dev/null \
    || fail "an exclude must match the project's logical name, not the link target"

  wt=$(spawn_claude on guard-on 'enabled = true\n')
  settings="$wt/.claude/settings.local.json"
  jq -e '.hooks.Stop and .hooks.PreToolUse[0].matcher == "Bash" and .hooks.PreToolUse[0].hooks[0].timeout == 15' \
    "$settings" >/dev/null || fail "an armed home must install a Bash PreToolUse hook beside the lifecycle hooks"
  cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")
  reset_server "$FIX/response-force-push.json"
  out=$(payload "git push --force origin main" | bash -c "$cmd")
  assert_contains "$out" '"permissionDecision": "deny"' "the installed hook command must deny a force-push"
  assert_present "$TMP_ROOT/spawn-on/home/state/command-guard.log" "the installed hook must log into the home's state"
  printf 'enabled = false\n' > "$TMP_ROOT/spawn-on/home/config/command-guard"
  out=$(payload "git push --force origin main" | bash -c "$cmd")
  assert_equals "" "$out" "switching the gate off must take effect without a relaunch"
  pass "fm-spawn installs the Bash guard hook only for an armed, unexcluded project by logical name, never Harbour, and the hook honours the live gate"
}

# Exercise the public hook entry with a synthetic judge and stalled bookkeeping.
test_known_deny_survives_bookkeeping_deadline() {
  local home
  home=$(new_home bookkeeping 'enabled = true\n')
  python3 - "$GUARD" "$home" <<'PYTEST' || fail "bookkeeping discarded a deny or exceeded its bound"
import contextlib, importlib.util, io, json, pathlib, signal, sys, time
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
home = pathlib.Path(sys.argv[2])
sys.argv = [sys.argv[1], "hook", "--config", str(home / "config"), "--state", str(home / "state"),
            "--home", str(home), "--task", "fixture", "--project", "demo"]
for boundary in ("outage_over", "append_log"):
    def judge(*_):
        signal.setitimer(signal.ITIMER_REAL, 0.1)
        return "block", "fixture deny", {}, "invented command", "whole"
    def stalled(*_):
        time.sleep(5)
    g.judge = judge
    original = getattr(g, boundary)
    setattr(g, boundary, stalled)
    sys.stdin = io.StringIO(json.dumps({"tool_name": "Bash", "tool_input": {"command": "invented command"}}))
    output, errors = io.StringIO(), io.StringIO(); start = time.monotonic()
    try:
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            assert g.main() == 0
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        setattr(g, boundary, original)
    assert time.monotonic() - start < 2, "bookkeeping was not bounded"
    assert json.loads(output.getvalue())["hookSpecificOutput"]["permissionDecision"] == "deny"
    state = home / "state"
    assert not (state / g.OUTAGE_NAME).exists(), "a judged command opened an outage"
    log = state / g.LOG_NAME
    assert not log.exists() or '"outcome": "error"' not in log.read_text(), "a judged command logged an outage"
    assert "stepping aside" not in errors.getvalue(), "a judged command announced an outage"
PYTEST
  pass "a known deny survives slow outage cleanup and log append under a bounded budget without reporting an outage"
}

test_concurrent_log_rotation_preserves_history() {
  local home
  home=$(new_home rotation)
  python3 - "$GUARD" "$home/state" <<'PYTEST' || fail "concurrent rotation lost history or a decision"
import importlib.util, json, multiprocessing, pathlib, sys, time
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
state = pathlib.Path(sys.argv[2]); path = state / g.LOG_NAME
history = "old history\n" * (g.LOG_ROTATE_BYTES // 12 + 1)
path.write_text(history)
ctx = multiprocessing.get_context("fork")
rotating, release, entered = ctx.Event(), ctx.Event(), ctx.Event()
def first():
    replace = g.os.replace
    def paused_replace(*args):
        rotating.set()
        assert release.wait(5)
        replace(*args)
    g.os.replace = paused_replace
    g.append_log(state, {"who": "A"})
def second():
    entered.set()
    g.append_log(state, {"who": "B"})
a, b = ctx.Process(target=first), ctx.Process(target=second)
a.start()
try:
    assert rotating.wait(5), "first writer never reached rotation"
    b.start(); assert entered.wait(5)
    # B can finish only in the broken, unlocked implementation while A is paused.
    b.join(0.2)
finally:
    release.set()
    a.join(5)
    if b.pid: b.join(5)
    for child in (a, b):
        if child.pid and child.is_alive(): child.kill(); child.join()
assert a.exitcode == b.exitcode == 0
assert pathlib.Path(str(path) + ".1").read_text() == history, "retained history was replaced"
assert {json.loads(line)["who"] for line in path.read_text().splitlines()} == {"A", "B"}
PYTEST
  pass "concurrent log rotation preserves retained history and both decisions"
}

test_known_deny_survives_bookkeeping_deadline
test_concurrent_log_rotation_preserves_history
test_gate
test_unarmed_hook_sends_nothing
test_recorded_block_and_allow
test_thresholds
test_non_bash_tool_ignored
test_redaction
test_quoted_and_short_secrets_are_redacted
test_routine_expansions_are_judged
test_plain_assignments_stay_visible
test_long_command_judged_in_parts
test_parts_failure_falls_back_to_head_and_tail
test_over_cap_command_allowed_and_logged
test_no_key_allows_and_logs_once
test_failures_allow
test_spawn_installs_hook_only_when_armed
