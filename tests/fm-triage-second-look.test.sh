#!/usr/bin/env bash
# tests/fm-triage-second-look.test.sh - the opt-in second look over the status
# lines the deterministic wake classifier drops.
#
# Four surfaces, each with its own failure mode:
#   - status_span_dropped_lines (bin/fm-classify-lib.sh): the pure span read that
#     decides WHICH lines are eligible at all, including the three declarations
#     that are silent by design and must stay silent;
#   - bin/fm-triage-second-look.sh: the opt-in gate, the escalate-only request,
#     the threshold rule and every fail-open path;
#   - the away-mode daemon's catch-all backstop (bin/fm-supervise-daemon.sh):
#     that a promotion actually reaches the escalation buffer with its reason,
#     and that an unarmed home adds nothing;
#   - the always-on watcher's heartbeat backstop (bin/fm-watch.sh): the same
#     against a real fm-watch.sh subprocess. These live here rather than in
#     tests/fm-watch-triage.test.sh so a timing-sensitive case elsewhere in that
#     file cannot end the run before this capability is exercised.
#
# Only the network is stubbed. Every case drives the real classifier, the real
# request build and the real thresholds against the recorded 2026-09-17 probe
# response in tests/fixtures/triage-second-look/, so a THRESHOLD change that
# would have promoted or silenced a different line fails here.
#
# A question change does not. The recording is keyed by synthetic tag, so the
# replay never sees the request it is answering: rewriting a question, or what
# the request carries, leaves every verdict below unchanged. Only the live smoke
# in tests/fm-triage-second-look-live-e2e.test.sh asks the model anything.
set -u

# shellcheck source=tests/wake-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-classify-lib.sh"

TOOL="$ROOT/bin/fm-triage-second-look.sh"
FIXTURES="$(dirname "${BASH_SOURCE[0]}")/fixtures/triage-second-look/fixtures.json"
RESPONSE="$(dirname "${BASH_SOURCE[0]}")/fixtures/triage-second-look/response.json"
TMP_ROOT=$(fm_test_tmproot fm-triage-second-look)

WATCH="$ROOT/bin/fm-watch.sh"

# --- watcher-subprocess scaffolding -----------------------------------------
#
# The watcher cases below drive a real bin/fm-watch.sh. These four helpers are
# the minimum that needs, and match the copies in tests/fm-watch-triage.test.sh.

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# The suppression signature the per-wake scan writes, so a case can pre-mark a
# status log seen and leave the heartbeat backstop as its only reader.
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

# Block until the watcher has completed one full poll cycle without exiting.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# An ambient key must never reach a case: every case here is either inert or
# stubbed, and a real key would turn a stub into a live paid call.
unset TYPESAFE_API_KEY || true

# A home with its own state/, data/ and config/. Armed only when asked, because
# "inert unless opted in" is the property most of these cases rest on.
new_home() {  # <name> [armed]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  [ "${2:-}" = armed ] && printf 'enabled = true\n' > "$home/config/triage-second-look"
  printf '%s\n' "$home"
}

# One task with a brief, a kind and a status log, so the engine's state
# gathering has something real to read.
seed_task() {  # <home> <task> <kind> <goal> <status-line...>
  local home=$1 task=$2 kind=$3 goal=$4
  shift 4
  mkdir -p "$home/data/$task"
  printf 'kind=%s\n' "$kind" > "$home/state/$task.meta"
  printf "# Task\n## Captain's intent\n%s\n\n## Firstmate spec\nnot the goal.\n" "$goal" \
    > "$home/data/$task/brief.md"
  printf '%s\n' "$@" > "$home/state/$task.status"
}

# Every fixture line the REAL classifier drops, as engine input records.
dropped_fixture_records() {  # <task-id>
  python3 - "$FIXTURES" "$1" <<'PY'
import json, sys
task = sys.argv[2]
for fixture in json.loads(open(sys.argv[1]).read())["fixtures"]:
    if fixture["today"] == "drop":
        sys.stdout.write("%s\t%s\n" % (task, fixture["line"]))
PY
}

fixture_field() {  # <fixture-id> <field>
  python3 - "$FIXTURES" "$1" "$2" <<'PY'
import json, sys
for fixture in json.loads(open(sys.argv[1]).read())["fixtures"]:
    if fixture["id"] == sys.argv[2]:
        sys.stdout.write(str(fixture[sys.argv[3]]))
        break
PY
}

# --- status_span_dropped_lines ----------------------------------------------

test_dropped_lines_are_exactly_what_the_classifier_rejected() {
  local dir log out
  dir=$(new_home dropped-basic)
  log="$dir/state/t.status"
  printf '%s\n' \
    'working: setting up the migration' \
    'note: the shipper config has the production password in plaintext' \
    'done: PR https://example.test/pr/1 checks green' \
    'blocked [key=a]: needs a card' \
    'working: still going' \
    > "$log"

  out=$(status_span_dropped_lines "$log" 0)

  assert_contains "$out" 'working: setting up the migration' "a dropped working line was not emitted"
  assert_contains "$out" 'note: the shipper config' "a dropped note line was not emitted"
  assert_not_contains "$out" 'done: PR' "an already-escalating done line was handed to the second look"
  assert_not_contains "$out" 'blocked [key=a]' "an already-escalating blocked line was handed to the second look"
  pass "the span reader emits the dropped lines and never one the classifier already escalates"
}

test_declared_waits_are_never_eligible() {
  local dir log out
  dir=$(new_home dropped-declarations)
  log="$dir/state/t.status"
  # These three are silent BY DESIGN, not because a verb regex missed them.
  # Promoting one would re-open a declaration the fleet has just closed.
  printf '%s\n' \
    'paused: waiting on the upstream release until 2026-10-01T09:00Z' \
    'captain-held: transferred to the backlog' \
    'resolved [key=a]: the captain chose B' \
    'working: back at it' \
    > "$log"

  out=$(status_span_dropped_lines "$log" 0)

  assert_contains "$out" 'working: back at it' "an ordinary dropped line was lost"
  assert_not_contains "$out" 'paused:' "a declared external wait was handed to the second look"
  assert_not_contains "$out" 'captain-held:' "a verified captain-held transfer was handed to the second look"
  assert_not_contains "$out" 'resolved' "a closing resolved line was handed to the second look"
  pass "paused, captain-held and resolved declarations stay out of the second look"
}

test_span_reader_returns_and_bounds_match_the_actionable_sibling() {
  local dir log out status size
  dir=$(new_home dropped-returns)
  log="$dir/state/t.status"
  printf 'working: one\nworking: two\n' > "$log"
  size=$(wc -c < "$log" | tr -d ' ')

  out=$(status_span_dropped_lines "$log" "$size") && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an exhausted span should return 1, got $status"
  [ -z "$out" ] || fail "an exhausted span printed lines: $out"

  out=$(status_span_dropped_lines "$dir/state/absent.status" 0) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an absent log should return 1, got $status"

  ln -s "$log" "$dir/state/link.status"
  out=$(status_span_dropped_lines "$dir/state/link.status" 0) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "a symlinked status object should return 2, got $status"
  [ -z "$out" ] || fail "an unreadable status object printed lines: $out"
  pass "the span reader returns 0/1/2 on the same conditions as the actionable reader"
}

test_span_reader_makes_no_network_call() {
  local dir log out
  dir=$(new_home dropped-offline)
  log="$dir/state/t.status"
  printf 'working: something worth a second look\n' > "$log"

  # The per-wake watcher path must work offline; the reader is a pure byte walk
  # and the one bounded call belongs to the call site. Point every plausible
  # endpoint at a closed port and prove the read is unaffected.
  out=$(FM_TRIAGE_SECOND_LOOK_ENDPOINT='http://127.0.0.1:1/never' \
    status_span_dropped_lines "$log" 0)

  assert_contains "$out" 'working: something worth a second look' "the pure span read did not produce its line"
  pass "the span reader is a pure read with no network in it"
}

# --- the opt-in gate --------------------------------------------------------

test_absent_gate_is_inert() {
  local dir out status
  dir=$(new_home gate-absent)
  seed_task "$dir" t1 ship "Backfill a column." 'working: nothing yet'

  out=$(printf 't1\tworking: the migration truncated public.users; 4100 rows gone\n' \
    | FM_HOME="$dir" "$TOOL" 2>/dev/null) && status=0 || status=$?

  [ "$status" -eq 1 ] || fail "an unarmed home should exit 1, got $status"
  [ -z "$out" ] || fail "an unarmed home promoted something: $out"
  pass "a home that never opted in is inert and promotes nothing"
}

test_malformed_gate_stays_inert_instead_of_failing_loudly() {
  local dir out status err
  dir=$(new_home gate-malformed)
  # A config typo must never change what a supervision loop does, so unlike
  # config/speak this reports and stays inert rather than exiting loudly.
  printf 'enabled = yes-please\n' > "$dir/config/triage-second-look"

  err="$dir/err"
  out=$(printf 't1\tworking: anything\n' | FM_HOME="$dir" "$TOOL" 2>"$err") && status=0 || status=$?

  [ "$status" -eq 1 ] || fail "a malformed gate should leave the home inert (exit 1), got $status"
  [ -z "$out" ] || fail "a malformed gate promoted something: $out"
  assert_contains "$(cat "$err")" 'staying inert' "a malformed gate did not say why it stayed inert"

  printf 'unknown_key = true\n' > "$dir/config/triage-second-look"
  out=$(printf 't1\tworking: anything\n' | FM_HOME="$dir" "$TOOL" 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an unknown gate key should leave the home inert, got $status"
  pass "a malformed gate reports and stays inert rather than failing a supervision loop"
}

# --- the request ------------------------------------------------------------

test_request_carries_the_dropped_line_and_nothing_else() {
  local dir request fields
  dir=$(new_home request-state armed)
  seed_task "$dir" t1 scout "Investigate why the log shipper is slow; ask ACME first." \
    'working: reading the shipper config' \
    'working: checking the disk' \
    'note: found the production password in plaintext'

  request=$(printf 't1\tnote: found the production password in plaintext\n' \
    | FM_HOME="$dir" "$TOOL" --dry-run)

  # A brief can carry a client name, a hostname or an unreleased plan. Arming a
  # supervision backstop is not consent to ship any of that to a third party, so
  # the dropped line is the whole of what leaves the machine.
  fields=$(printf '%s' "$request" | python3 -c '
import json, sys
state = json.load(sys.stdin)["state"]["lines"]["l1"]
print(",".join(sorted(state)))
print(state["line"])')

  assert_contains "$fields" 'line' "the request did not carry the dropped line"
  assert_contains "$fields" 'found the production password in plaintext' \
    "the request did not carry the dropped line verbatim"
  [ "$(printf '%s' "$request" | python3 -c '
import json, sys
print(",".join(sorted(json.load(sys.stdin)["state"]["lines"]["l1"])))')" = line ] \
    || fail "the request carried task state beyond the dropped line"
  assert_not_contains "$request" 'ACME' "the brief's intent left the machine"
  assert_not_contains "$request" 'scout' "the worker kind left the machine"
  assert_not_contains "$request" 'reading the shipper config' "a prior status line left the machine"
  assert_contains "$(printf '%s' "$request" | python3 -c '
import json, sys
print(json.load(sys.stdin)["model"])')" 'jev-1.13.0' "the request did not pin the model version"
  pass "the request carries the pinned model and the dropped line, and no other task state"
}

test_request_is_one_batch_for_the_whole_scan() {
  local dir request count
  dir=$(new_home request-batched armed)
  seed_task "$dir" t1 ship "Tidy the branches." 'working: one'

  # Batching is a SECURITY property, not only the cheaper shape: a status line
  # arguing for its own escalation measurably wins alone and measurably loses
  # beside its peers. One request per scan is what preserves that.
  request=$(dropped_fixture_records t1 | FM_HOME="$dir" "$TOOL" --dry-run)
  count=$(printf '%s' "$request" | python3 -c '
import json, sys
print(len(json.load(sys.stdin)["state"]["lines"]))')

  [ "$count" -eq 16 ] || fail "the 16 dropped fixture lines did not arrive as one batch of 16 (got $count)"
  pass "every dropped line in a scan goes out in one request, never one request per line"
}

test_only_lines_the_real_classifier_dropped_can_reach_the_request() {
  local dir escalating request
  dir=$(new_home request-escalate-only armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  # Escalate-only is the property that makes a paid, networked, semi-trusted
  # judgment safe here. Prove it against the REAL classifier rather than the
  # fixture labels: every line the classifier escalates must be absent from the
  # request the engine would send.
  request=$(dropped_fixture_records t1 | FM_HOME="$dir" "$TOOL" --dry-run)
  while IFS= read -r escalating; do
    [ -n "$escalating" ] || continue
    status_is_captain_relevant "$escalating" \
      || fail "control line is not actually captain-relevant: $escalating"
    assert_not_contains "$request" "$escalating" \
      "an already-escalating line reached the second look: $escalating"
  done <<EOF
$(python3 - "$FIXTURES" <<'PY'
import json, sys
for fixture in json.loads(open(sys.argv[1]).read())["fixtures"]:
    if fixture["today"] == "escalate":
        print(fixture["line"])
PY
)
EOF
  pass "a line the deterministic classifier already escalates is never sent to the second look"
}

test_the_batch_is_bounded() {
  local dir request count i lines
  dir=$(new_home request-bounded armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  lines=''
  i=0
  while [ "$i" -lt 60 ]; do
    lines="${lines}t1"$'\t'"working: line number $i"$'\n'
    i=$((i + 1))
  done
  request=$(printf '%s' "$lines" | FM_HOME="$dir" "$TOOL" --dry-run 2>/dev/null)
  count=$(printf '%s' "$request" | python3 -c '
import json, sys
print(len(json.load(sys.stdin)["state"]["lines"]))')

  [ "$count" -eq 25 ] || fail "a 60-line scan was not bounded to 25 lines (got $count)"
  # A status log is append-only, so the tail is what just happened. Keeping the
  # head would spend a first-ever scan's whole batch on backlog and look past
  # the event a supervisor actually needs.
  assert_contains "$request" 'working: line number 59' "the newest line was dropped by the bound"
  assert_not_contains "$request" 'working: line number 0"' "the oldest line survived the bound"
  pass "a large scan is truncated to its newest lines rather than growing without limit"
}

test_the_api_key_never_leaves_the_process() {
  local dir out err sentinel
  dir=$(new_home key-secrecy armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'
  sentinel='apikey_THIS_MUST_NEVER_BE_PRINTED'

  err="$dir/err"
  out=$(printf 't1\tworking: something\n' \
    | TYPESAFE_API_KEY="$sentinel" FM_HOME="$dir" "$TOOL" --dry-run 2>"$err")

  assert_not_contains "$out" "$sentinel" "the API key appeared on stdout"
  assert_not_contains "$(cat "$err")" "$sentinel" "the API key appeared on stderr"
  pass "the API key never reaches stdout, stderr or the request body"
}

# --- the threshold rule -----------------------------------------------------

test_recorded_probe_response_reproduces_the_measured_verdicts() {
  local dir promotions want got id
  dir=$(new_home rule-fixtures armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  promotions=$(dropped_fixture_records t1 \
    | FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$RESPONSE" "$TOOL")

  # The 8/8 captain-worthy, 0/8 false split measured live on 2026-09-17, against
  # the richer request of that date. What this replay still proves is the rule:
  # a threshold change that moves any line fails here. A question change cannot,
  # because the recording is keyed by tag and never sees the request.
  got=$(printf '%s\n' "$promotions" | grep -c '[^[:space:]]' || true)
  [ "$got" -eq 8 ] || fail "expected 8 promotions from the recorded response, got $got: $promotions"

  for id in g01 g02 g03 g04 g05 g06 g07 g08; do
    want=$(fixture_field "$id" line)
    assert_contains "$promotions" "$want" "$id should have been promoted but was not"
  done
  for id in n01 n02 n03 n04 n05 n06 n07 n08; do
    want=$(fixture_field "$id" line)
    assert_not_contains "$promotions" "$want" "$id was promoted but should have stayed silent"
  done
  pass "the recorded probe response still promotes exactly the 8 captain-worthy lines and no others"
}

test_conditions_are_separate_not_blended() {
  local dir promotions line
  dir=$(new_home rule-separate armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  # g05 - a production password in a world-readable file - scored 0.38 on
  # needs_captain, UNDER its threshold, and was caught only by adverse_event at
  # 0.76 (2026-09-17, against the richer request of that date). Any blended score
  # would have buried it, which is why the rule is three separate ORed
  # conditions. What this case still proves is that the rule keeps ORing them.
  promotions=$(dropped_fixture_records t1 \
    | FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$RESPONSE" "$TOOL")
  line=$(printf '%s\n' "$promotions" | grep -F "$(fixture_field g05 line)")

  assert_contains "$line" 'adverse_event' "g05 was not promoted by adverse_event"
  assert_not_contains "$line" 'needs_captain' "g05 reported needs_captain, which scored under its threshold"
  pass "a hazard only one condition sees is still promoted, by that condition alone"
}

test_low_confidence_demotes_but_never_silences() {
  local dir response promotions line
  dir=$(new_home rule-confidence armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  # The model's own uncertainty decides how LOUDLY to speak, never whether to
  # speak. Same urgency, opposite confidence: alert becomes digest, not silence.
  response="$dir/resp.json"
  cat > "$response" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","noul":0.05},
"l1__needs_captain":{"type":"noul","noul":0.92},
"l1__adverse_event":{"type":"noul","noul":0.10},
"l1__urgency":{"type":"score","score":1.90,"confidence":0.85}}}
EOF
  promotions=$(printf 't1\tworking: about to delete 34 remote branches\n' \
    | FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$response" "$TOOL")
  assert_contains "$promotions" 'alert' "a confident, urgent promotion did not reach the alert tier"

  cat > "$response" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","noul":0.05},
"l1__needs_captain":{"type":"noul","noul":0.92},
"l1__adverse_event":{"type":"noul","noul":0.10},
"l1__urgency":{"type":"score","score":1.90,"confidence":0.00}}}
EOF
  promotions=$(printf 't1\tworking: about to delete 34 remote branches\n' \
    | FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$response" "$TOOL")
  line=$promotions
  assert_contains "$line" 'digest' "zero confidence did not demote the promotion to the digest tier"
  assert_not_contains "$line" 'alert' "zero confidence still produced an alert"
  assert_contains "$line" 'needs_captain' "the demoted promotion lost its reason"
  pass "low confidence demotes alert to digest and can never silence a promotion"
}

test_promotions_carry_their_reason() {
  local dir promotions
  dir=$(new_home rule-reason armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  promotions=$(dropped_fixture_records t1 \
    | FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$RESPONSE" "$TOOL")

  [ -n "$promotions" ] || fail "the fixture batch promoted nothing to check"

  while IFS=$(printf '\t') read -r _task tier reason _line; do
    [ -n "$reason" ] || fail "a promotion carried no reason"
    case "$tier" in alert|digest) ;; *) fail "a promotion carried an unknown tier: $tier" ;; esac
    case "$reason" in
      *needs_captain*|*adverse_event*|*understated_terminal*) ;;
      *) fail "a promotion carried an unrecognised reason: $reason" ;;
    esac
  done <<EOF
$promotions
EOF
  pass "every promotion names the tier and the conditions that fired"
}

# --- fail-open --------------------------------------------------------------

test_every_failure_promotes_nothing() {
  local dir out status response
  dir=$(new_home fail-open armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  # No key at all: the same state as "the second look was never built".
  out=$(printf 't1\tworking: something\n' | FM_HOME="$dir" \
    FM_TRIAGE_SECOND_LOOK_ENV_FILE=/dev/null "$TOOL" 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "a missing key should exit 2, got $status"
  [ -z "$out" ] || fail "a missing key promoted something: $out"

  # A body that is not JSON at all.
  response="$dir/bad.json"
  printf 'not json {{{\n' > "$response"
  out=$(printf 't1\tworking: something\n' | FM_HOME="$dir" \
    FM_TRIAGE_SECOND_LOOK_RESPONSE="$response" "$TOOL" 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "a malformed body should exit 2, got $status"
  [ -z "$out" ] || fail "a malformed body promoted something: $out"

  # A well-formed body with no answers in it.
  printf '{"model":"jev-1.13.0"}\n' > "$response"
  out=$(printf 't1\tworking: something\n' | FM_HOME="$dir" \
    FM_TRIAGE_SECOND_LOOK_RESPONSE="$response" "$TOOL" 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "an answerless body should exit 2, got $status"
  [ -z "$out" ] || fail "an answerless body promoted something: $out"

  # An unreachable endpoint, with no canned response to fall back on.
  out=$(printf 't1\tworking: something\n' | FM_HOME="$dir" TYPESAFE_API_KEY=unused \
    FM_TRIAGE_SECOND_LOOK_ENDPOINT='http://127.0.0.1:1/never' \
    FM_TRIAGE_SECOND_LOOK_TIMEOUT=2 "$TOOL" 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "an unreachable endpoint should exit 2, got $status"
  [ -z "$out" ] || fail "an unreachable endpoint promoted something: $out"
  pass "no key, a malformed body, an answerless body and an unreachable endpoint all promote nothing"
}

test_one_unusable_answer_does_not_lose_the_rest_of_the_batch() {
  local dir response promotions
  dir=$(new_home fail-open-partial armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  response="$dir/partial.json"
  cat > "$response" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","noul":0.05},
"l1__needs_captain":{"type":"noul"},
"l2__understated_terminal":{"type":"noul","noul":0.05},
"l2__needs_captain":{"type":"noul","noul":0.92},
"l2__adverse_event":{"type":"noul","noul":0.10},
"l2__urgency":{"type":"score","score":0.90,"confidence":0.80}}}
EOF
  promotions=$(printf 't1\tworking: first line\nt1\tworking: second line\n' \
    | FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$response" "$TOOL" 2>/dev/null)

  assert_not_contains "$promotions" 'working: first line' "an unusable answer still promoted its line"
  assert_contains "$promotions" 'working: second line' "one unusable answer lost the rest of the batch"
  pass "an unusable answer for one line promotes nothing for it and keeps the rest of the batch"
}

test_dry_run_previews_the_request_before_a_home_is_armed() {
  local dir request status out
  dir=$(new_home gate-preview)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  # The gate guards the paid call. An operator deciding whether to arm needs to
  # see what would leave the machine first, and the preview reaches no network.
  request=$(printf 't1\tworking: the migration truncated public.users\n' \
    | FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_ENDPOINT='http://127.0.0.1:1/never' \
      "$TOOL" --dry-run) && status=0 || status=$?

  [ "$status" -eq 0 ] || fail "--dry-run on an unarmed home exited $status instead of previewing"
  assert_contains "$request" 'truncated public.users' "the preview did not carry the dropped line"
  assert_contains "$request" 'jev-1.13.0' "the preview did not carry the pinned model"

  # The live path is still gated: same home, no --dry-run, nothing happens.
  out=$(printf 't1\tworking: the migration truncated public.users\n' \
    | FM_HOME="$dir" TYPESAFE_API_KEY=unused "$TOOL" 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "an unarmed home ran the live path, got $status"
  [ -z "$out" ] || fail "an unarmed home promoted something: $out"
  pass "--dry-run previews the request without the gate while the live path still needs it"
}

test_a_gate_under_a_config_override_arms_the_home() {
  local dir out status
  dir=$(new_home gate-override)
  mkdir -p "$dir/elsewhere"
  printf 'enabled = true\n' > "$dir/elsewhere/triage-second-look"

  # A home whose config lives elsewhere must arm from the file the watcher
  # checks, not from one nobody wrote.
  out=$(printf 't1\tworking: anything\n' | FM_HOME="$dir" \
    FM_CONFIG_OVERRIDE="$dir/elsewhere" FM_TRIAGE_SECOND_LOOK_ENV_FILE=/dev/null \
    "$TOOL" 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 2 ] || fail "an overridden gate did not arm the home (got $status, wanted 2)"
  [ -z "$out" ] || fail "an armed home with no key promoted something: $out"

  # And an armed gate in the DEFAULT location is ignored once an override is
  # set, so the override replaces $FM_HOME/config rather than adding to it.
  printf 'enabled = true\n' > "$dir/config/triage-second-look"
  out=$(printf 't1\tworking: anything\n' | FM_HOME="$dir" \
    FM_CONFIG_OVERRIDE="$dir/empty" "$TOOL" 2>/dev/null) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "the default home gate was still consulted under an override, got $status"
  pass "the gate is read from the overridden config directory, not always from the home"
}

test_an_overridden_root_arms_the_home_it_points_at() {
  local dir out status
  dir=$(new_home root-override armed)

  # fm-afk-start.sh execs the daemon with FM_ROOT_OVERRIDE and no FM_HOME, so a
  # tool that reads only FM_ROOT resolves the repo root and finds no gate there.
  out=$(printf 't1\tworking: anything\n' | env -u FM_HOME -u FM_ROOT \
    FM_ROOT_OVERRIDE="$dir" FM_TRIAGE_SECOND_LOOK_ENV_FILE=/dev/null \
    "$TOOL" 2>/dev/null) && status=0 || status=$?

  [ "$status" -eq 2 ] || fail "an overridden root did not arm the home it points at (got $status, wanted 2)"
  [ -z "$out" ] || fail "an armed home with no key promoted something: $out"
  pass "the home is resolved through FM_ROOT_OVERRIDE the way every sibling script resolves it"
}

test_unreadable_answers_are_reported_not_silently_read_as_zero() {
  local dir response out err
  dir=$(new_home fail-open-rename armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  # The vendor renames the answer field. Every condition reads 0.0 and nothing
  # promotes, which must not look like "the model judged nothing captain-worthy".
  response="$dir/renamed.json"
  cat > "$response" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","value":0.05},
"l1__needs_captain":{"type":"noul","value":0.97},
"l1__adverse_event":{"type":"noul","value":0.97},
"l1__urgency":{"type":"score","value":1.90}}}
EOF
  err="$dir/stderr"
  out=$(printf 't1\tworking: the backfill migration truncated public.users\n' \
    | FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$response" "$TOOL" 2>"$err")

  [ -z "$out" ] || fail "unreadable answers promoted something: $out"
  assert_contains "$(cat "$err")" 'unusable answer' \
    "unreadable answers produced no diagnostic, so silence looks like a verdict"
  assert_contains "$(cat "$err")" 'needs_captain' \
    "the diagnostic did not name which answers were unreadable"
  assert_not_contains "$(cat "$err")" 'public.users' \
    "the diagnostic leaked the status line content"

  # A genuinely below-threshold batch stays quiet on both streams.
  cat > "$response" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","noul":0.05},
"l1__needs_captain":{"type":"noul","noul":0.10},
"l1__adverse_event":{"type":"noul","noul":0.10},
"l1__urgency":{"type":"score","score":0.10,"confidence":0.90}}}
EOF
  out=$(printf 't1\tworking: tidying the branches\n' \
    | FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$response" "$TOOL" 2>"$err")
  [ -z "$out" ] || fail "a below-threshold batch promoted something: $out"
  [ ! -s "$err" ] || fail "a below-threshold batch produced a diagnostic: $(cat "$err")"
  pass "unreadable answers are reported on stderr and never mistaken for a quiet verdict"
}

test_an_unusable_condition_cannot_veto_the_ones_that_fired() {
  local dir response promotions
  dir=$(new_home fail-open-veto armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  # Escalate-only: a condition the model failed to answer, and an urgency it
  # failed to score, must not hold back the two conditions that did fire.
  response="$dir/veto.json"
  cat > "$response" <<'EOF'
{"answers":{
"l1__needs_captain":{"type":"noul","noul":0.92},
"l1__adverse_event":{"type":"noul","noul":0.97}}}
EOF
  promotions=$(printf 't1\tworking: the backfill migration truncated public.users\n' \
    | FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$response" "$TOOL" 2>/dev/null)

  assert_contains "$promotions" 'working: the backfill migration truncated public.users' \
    "a missing condition silenced a line two other conditions fired on"
  assert_contains "$promotions" 'needs_captain+adverse_event' \
    "the promotion lost the conditions that fired"
  assert_contains "$promotions" 'digest' \
    "an unusable urgency answer did not fall back to the digest tier"
  pass "an unusable condition or urgency answer can never silence a line that fired"
}

test_the_batch_reaches_the_engine_under_an_external_timeout() {
  local dir fakebin response promotions
  dir=$(new_home external-timeout armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  # fm_run_timed picks GNU/BSD `timeout` over its perl and bash fallbacks
  # whenever one is on PATH - every Linux home and this repo's own CI runner.
  # That mechanism launches its runner asynchronously, and bash points an async
  # command's stdin at /dev/null, so a batch piped into this tool has to survive
  # that. FM_TIMEOUT_MECHANISM_OVERRIDE cannot reach this path, so the mechanism
  # is selected the way a real host selects it: by what is on PATH.
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
set -u
while [ $# -gt 0 ]; do
  case "$1" in
    -k) shift 2 ;;
    [0-9]*) shift; break ;;
    *) shift ;;
  esac
done
exec "$@"
SH
  chmod +x "$fakebin/timeout"

  response="$dir/resp.json"
  cat > "$response" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","noul":0.05},
"l1__needs_captain":{"type":"noul","noul":0.92},
"l1__adverse_event":{"type":"noul","noul":0.97},
"l1__urgency":{"type":"score","score":1.90,"confidence":0.85}}}
EOF
  promotions=$(printf 't1\tworking: the migration truncated public.users\n' \
    | PATH="$fakebin:$PATH" FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$response" "$TOOL")

  assert_contains "$promotions" 'truncated public.users' \
    "the batch never reached the engine under an external timeout, so the home is silently inert"
  assert_contains "$promotions" 'needs_captain+adverse_event' "the promotion lost its reason"

  # The same stdin has to reach --dry-run, the operator-facing request preview.
  promotions=$(printf 't1\tworking: the migration truncated public.users\n' \
    | PATH="$fakebin:$PATH" FM_HOME="$dir" "$TOOL" --dry-run)
  assert_contains "$promotions" 'truncated public.users' \
    "--dry-run built an empty request under an external timeout"
  pass "the batch reaches the engine on hosts where an external timeout is the bounding mechanism"
}

test_the_bound_is_enforced() {
  local dir out status started elapsed
  dir=$(new_home bound armed)
  seed_task "$dir" t1 ship "Ship it." 'working: one'

  # A wedged interpreter or a stalled lookup must not hold a supervision loop
  # open, so the call site's bound is enforced independently of the request's.
  started=$(date +%s)
  out=$(printf 't1\tworking: something\n' | FM_HOME="$dir" TYPESAFE_API_KEY=unused \
    FM_TRIAGE_SECOND_LOOK_ENDPOINT='http://10.255.255.1:9/never' \
    FM_TRIAGE_SECOND_LOOK_TIMEOUT=60 FM_TRIAGE_SECOND_LOOK_BOUND=3 \
    "$TOOL" 2>/dev/null) && status=0 || status=$?
  elapsed=$(( $(date +%s) - started ))

  [ "$status" -eq 2 ] || fail "hitting the bound should exit 2, got $status"
  [ -z "$out" ] || fail "hitting the bound promoted something: $out"
  [ "$elapsed" -lt 30 ] || fail "the ${elapsed}s call was not bounded by FM_TRIAGE_SECOND_LOOK_BOUND=3"
  pass "a stalled call is cut at the bound and promotes nothing"
}

# --- call site: the always-on watcher's heartbeat backstop -------------------

second_look_case() {  # <name> [armed]
  local dir state sig
  dir=$(make_case "$1"); state="$dir/state"
  mkdir -p "$dir/config" "$dir/data/miss"
  [ "${2:-}" = armed ] && printf 'enabled = true\n' > "$dir/config/triage-second-look"
  printf 'kind=ship\n' > "$state/miss.meta"
  printf "# Task\n## Captain's intent\nAdd a users.last_seen column and backfill it.\n" \
    > "$dir/data/miss/brief.md"
  # Already marked seen, so the per-wake signal scan stays quiet and the
  # heartbeat backstop is the only thing that can reach these lines.
  printf '%s\n' \
    'working: writing the backfill migration' \
    'working: the backfill migration truncated public.users on staging before I caught it; 4100 rows gone' \
    > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status")
  printf '%s' "$sig" > "$state/.seen-miss_status"
  # A recorded response for the two dropped lines, in the order the scan reads
  # them: the first stays silent, the second is promoted on adverse_event.
  cat > "$dir/resp.json" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","noul":0.05},
"l1__needs_captain":{"type":"noul","noul":0.10},
"l1__adverse_event":{"type":"noul","noul":0.10},
"l1__urgency":{"type":"score","score":0.20,"confidence":0.80},
"l2__understated_terminal":{"type":"noul","noul":0.12},
"l2__needs_captain":{"type":"noul","noul":0.74},
"l2__adverse_event":{"type":"noul","noul":0.97},
"l2__urgency":{"type":"score","score":1.90,"confidence":0.85}}}
EOF
  printf '%s\n' "$dir"
}

test_heartbeat_second_look_inert_when_the_home_is_not_armed() {
  local dir state fakebin out pid i
  dir=$(second_look_case second-look-inert); state="$dir/state"
  fakebin="$dir/fakebin"; out="$dir/watch.out"
  # The control: a home that never opted in absorbs this heartbeat exactly as it
  # did before the capability existed, and makes no call at all.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    FM_TRIAGE_SECOND_LOOK_RESPONSE="$dir/resp.json" "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited without an armed second look: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 200 ]; do
    [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -s "$out" ] || fail "an unarmed home surfaced a wake: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "an unarmed home enqueued a wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] \
    || fail "an unarmed home did not absorb and back off as it does today"
  reap "$pid"
  pass "a home that never opted in absorbs the heartbeat exactly as it does today"
}

test_heartbeat_second_look_promotes_a_dropped_line_with_its_reason() {
  local dir state fakebin out pid queue
  dir=$(second_look_case second-look-armed armed); state="$dir/state"
  fakebin="$dir/fakebin"; out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    FM_TRIAGE_SECOND_LOOK_RESPONSE="$dir/resp.json" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 300 \
    || { reap "$pid"; fail "the second look did not surface a promoted dropped line"; }
  grep -Fx "heartbeat" "$out" >/dev/null || fail "the promotion did not exit with a heartbeat wake"
  queue=$(cat "$state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" 'second look promoted' "the queued wake did not say a line was promoted"
  assert_contains "$queue" 'adverse_event' "the queued wake did not carry why the line was raised"
  assert_contains "$queue" 'truncated public.users' "the queued wake did not carry the promoted line"
  assert_not_contains "$queue" 'writing the backfill migration' \
    "a line the second look left silent was still named in the wake"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-miss" "$state/miss.status")" = \
    "$(size_of "$state/miss.status")" ] \
    || fail "a promotion did not record the status as surfaced through its end (would re-fire next heartbeat)"
  pass "an armed watcher turns an absorbed heartbeat into a wake naming the promoted line and why"
}

test_heartbeat_backstop_without_a_promotion_keeps_the_ordinary_key() {
  local dir state fakebin out sig pid keys
  dir=$(make_case heartbeat-bare-key); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # The backstop branch on a home that never opted in: there is nothing to
  # promote, so the queued row must keep the key it has always had. A row keyed
  # for the second look while carrying no promotion would collapse onto a real
  # promotion queued earlier and replace it, and the status log it came from was
  # already marked surfaced, so nothing would re-read it.
  printf 'working: setup\nneeds-decision: pick A or B\nworking: tidying the branch\n' \
    > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "the heartbeat backstop did not surface the masked decision"; }

  keys=$(awk -F '\t' 'NF >= 5 { print $4 }' "$state/.wake-queue" 2>/dev/null || true)
  [ -n "$keys" ] || fail "the backstop queued no wake record"
  case "$keys" in
    *second-look*) fail "a heartbeat carrying no promotion took the second-look dedupe key: $keys" ;;
  esac
  pass "an actionable heartbeat with nothing promoted keeps the ordinary heartbeat key"
}

# --- call site: the away-mode daemon's catch-all backstop --------------------

test_a_promoted_heartbeat_is_never_an_unknown_wake() {
  local dir payload out
  dir=$(new_home daemon-wake-label armed)
  seed_task "$dir" miss ship "Ship it." 'working: writing the backfill migration'

  # The watcher promotes while the captain is present and exits; the away marker
  # appears before firstmate drains, so the away-mode daemon handles the queued
  # row. It dispatches on the PAYLOAD, and a payload it cannot place is escalated
  # as an "unknown wake" - a label that would misdescribe a wake this capability
  # deliberately creates. The payload is built by the real producer, in a
  # subshell so the watcher's globals cannot reach the daemon functions this
  # file already sourced.
  payload=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1" >/dev/null 2>&1
    heartbeat_second_look_payload "$(cat)"
  ' _ "$ROOT/bin/fm-watch.sh" \
    <<< "$(printf 'miss\talert\tadverse_event\tworking: the backfill migration truncated public.users')")
  [ -n "$payload" ] || fail "the watcher produced no promotion payload to dispatch"

  FM_HOME="$dir" LOG="$dir/daemon.log" handle_wake "$payload" "$dir/state"

  out=$(cat "$dir/state/.subsuper-escalations" 2>/dev/null || true)
  assert_not_contains "$out" 'unknown wake' \
    "a wake this capability creates was escalated as an unknown wake"
  assert_not_contains "$(cat "$dir/daemon.log" 2>/dev/null || true)" 'unknown wake' \
    "the daemon logged an unknown-wake escalation for a wake it knows about"
  pass "a promoted heartbeat is dispatched as the heartbeat it is, never as an unknown wake"
}

test_the_away_scan_repromotes_what_a_drained_heartbeat_absorbed() {
  local dir out
  dir=$(new_home daemon-rescan armed)
  seed_task "$dir" miss ship "Ship it." 'working: writing the backfill migration'
  # The watcher already marked this log surfaced through its end before exiting.
  printf 'v2\tx\t4096@y\n' > "$dir/state/.hb-surfaced-miss"

  # The away daemon keeps its own offset marker, so the lines the watcher
  # promoted are still unread by IT and are promoted again on its next scan.
  # That is what makes the heartbeat: payload safe to absorb on the drain path.
  [ "$(status_seen_offset "$dir/state" miss)" = 0 ] \
    || fail "the watcher's marker moved the away scan's offset off the start of the log"

  cat > "$dir/resp.json" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","noul":0.12},
"l1__needs_captain":{"type":"noul","noul":0.74},
"l1__adverse_event":{"type":"noul","noul":0.97},
"l1__urgency":{"type":"score","score":0.90,"confidence":0.85}}}
EOF
  FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$dir/resp.json" \
    second_look_escalate "$dir/state" \
    "$(printf 'miss\tworking: the backfill migration truncated public.users; 4100 rows gone\n')"

  out=$(cat "$dir/state/.subsuper-escalations" 2>/dev/null || true)
  assert_contains "$out" 'truncated public.users' "the away scan did not re-promote the dropped line"
  assert_contains "$out" 'adverse_event' "the re-promotion lost why the line was raised"
  pass "the away-mode scan re-promotes dropped lines the watcher already marked surfaced"
}

test_daemon_catch_all_escalates_a_promotion_with_its_reason() {
  local dir out
  dir=$(new_home daemon-armed armed)
  seed_task "$dir" miss ship "Add a users.last_seen column and backfill it." \
    'working: writing the backfill migration'

  cat > "$dir/resp.json" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","noul":0.12},
"l1__needs_captain":{"type":"noul","noul":0.74},
"l1__adverse_event":{"type":"noul","noul":0.97},
"l1__urgency":{"type":"score","score":0.90,"confidence":0.85}}}
EOF
  # Away mode is where this silence gap bites hardest: nobody is watching the
  # pane and hours pass. A digest-tier promotion must reach the buffer the next
  # batch is built from, carrying its reason.
  FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$dir/resp.json" \
    second_look_escalate "$dir/state" \
    "$(printf 'miss\tworking: the backfill migration truncated public.users; 4100 rows gone\n')"

  out=$(cat "$dir/state/.subsuper-escalations" 2>/dev/null || true)
  assert_contains "$out" 'truncated public.users' "the promoted line never reached the escalation buffer"
  assert_contains "$out" 'second look' "the escalation did not say where it came from"
  assert_contains "$out" 'adverse_event' "the escalation did not carry the reason the line was raised"
  pass "an armed daemon escalates a promoted dropped line and names why it was raised"
}

test_daemon_reports_an_unusable_answer_instead_of_discarding_it() {
  local dir out
  dir=$(new_home daemon-diagnostic armed)
  seed_task "$dir" miss ship "Ship it." 'working: writing the backfill migration'

  # The vendor renames the answer field. Nothing can promote any more, and the
  # offsets advance regardless, so the only thing standing between that and an
  # unbounded silent spend is the diagnostic reaching the daemon's own log.
  cat > "$dir/resp.json" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","value":0.12},
"l1__needs_captain":{"type":"noul","value":0.74},
"l1__adverse_event":{"type":"noul","value":0.97},
"l1__urgency":{"type":"score","value":0.90}}}
EOF
  LOG="$dir/daemon.log" FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$dir/resp.json" \
    second_look_escalate "$dir/state" \
    "$(printf 'miss\tworking: the backfill migration truncated public.users; 4100 rows gone\n')"

  [ ! -s "$dir/state/.subsuper-escalations" ] \
    || fail "an unreadable answer escalated: $(cat "$dir/state/.subsuper-escalations")"
  out=$(cat "$dir/daemon.log" 2>/dev/null || true)
  assert_contains "$out" 'unusable answer' \
    "the daemon discarded the second look's diagnostic, so a dead call looks like a quiet scan"
  assert_not_contains "$out" 'public.users' "the daemon log leaked the status line content"
  ls "$dir/state"/.second-look-stderr.* >/dev/null 2>&1 \
    && fail "the stderr capture file was left behind in state/"
  pass "an unusable answer reaches the daemon log rather than /dev/null"
}

test_one_away_scan_produces_one_digest_not_one_per_alert() {
  local dir out attempts
  dir=$(new_home daemon-one-digest armed)
  seed_task "$dir" miss ship "Ship it." 'working: writing the backfill migration'

  # A span that destroys data usually writes several such lines at once, so a
  # scan carrying two alert-tier promotions is the realistic case. Flushing per
  # row would empty the buffer between them and inject one message each.
  cat > "$dir/resp.json" <<'EOF'
{"answers":{
"l1__understated_terminal":{"type":"noul","noul":0.12},
"l1__needs_captain":{"type":"noul","noul":0.74},
"l1__adverse_event":{"type":"noul","noul":0.97},
"l1__urgency":{"type":"score","score":1.90,"confidence":0.85},
"l2__understated_terminal":{"type":"noul","noul":0.12},
"l2__needs_captain":{"type":"noul","noul":0.91},
"l2__adverse_event":{"type":"noul","noul":0.10},
"l2__urgency":{"type":"score","score":1.95,"confidence":0.90},
"l3__understated_terminal":{"type":"noul","noul":0.12},
"l3__needs_captain":{"type":"noul","noul":0.74},
"l3__adverse_event":{"type":"noul","noul":0.80},
"l3__urgency":{"type":"score","score":0.50,"confidence":0.85}}}
EOF
  LOG="$dir/daemon.log" FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_RESPONSE="$dir/resp.json" \
    second_look_escalate "$dir/state" "$(printf 'miss\tworking: the backfill migration truncated public.users\nmiss\tworking: the shipper config has the production password\nmiss\tworking: the retry loop is on its sixth attempt\n')"

  # afk is inactive here, so each flush attempt defers and preserves the buffer.
  # The count of attempts is the number of messages an operator would have read.
  attempts=$(grep -c 'inject deferred' "$dir/daemon.log" 2>/dev/null || true)
  [ "$attempts" -eq 1 ] || fail "one scan made $attempts flush attempts, not 1"

  out=$(cat "$dir/state/.subsuper-escalations" 2>/dev/null || true)
  assert_contains "$out" 'truncated public.users' "the first alert promotion is missing from the digest"
  assert_contains "$out" 'production password' "the second alert promotion is missing from the digest"
  assert_contains "$out" 'sixth attempt' "the digest-tier promotion is missing from the digest"
  pass "one away scan builds one digest, whatever mix of alert and digest tiers it promotes"
}

test_daemon_catch_all_is_unchanged_when_the_home_is_not_armed() {
  local dir
  dir=$(new_home daemon-inert)
  seed_task "$dir" miss ship "Add a users.last_seen column." 'working: writing the migration'

  FM_HOME="$dir" second_look_escalate "$dir/state" \
    "$(printf 'miss\tworking: the backfill migration truncated public.users; 4100 rows gone\n')"

  [ ! -s "$dir/state/.subsuper-escalations" ] \
    || fail "an unarmed home escalated: $(cat "$dir/state/.subsuper-escalations")"
  pass "an unarmed home adds nothing to the away-mode escalation buffer"
}

test_daemon_second_look_never_runs_without_dropped_lines() {
  local dir
  dir=$(new_home daemon-empty armed)
  # No records means no request and no spend, which is the ordinary case: most
  # scans carry zero new dropped lines.
  FM_HOME="$dir" FM_TRIAGE_SECOND_LOOK_ENDPOINT='http://127.0.0.1:1/never' \
    second_look_escalate "$dir/state" ''
  [ ! -s "$dir/state/.subsuper-escalations" ] || fail "an empty scan escalated something"
  pass "a scan with no dropped lines makes no call and escalates nothing"
}

# Source the daemon's pure functions for the two cases above. Its main loop is
# skipped under sourcing via its own BASH_SOURCE guard.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-supervise-daemon.sh"
fi

test_dropped_lines_are_exactly_what_the_classifier_rejected
test_declared_waits_are_never_eligible
test_span_reader_returns_and_bounds_match_the_actionable_sibling
test_span_reader_makes_no_network_call
test_absent_gate_is_inert
test_malformed_gate_stays_inert_instead_of_failing_loudly
test_dry_run_previews_the_request_before_a_home_is_armed
test_a_gate_under_a_config_override_arms_the_home
test_request_carries_the_dropped_line_and_nothing_else
test_request_is_one_batch_for_the_whole_scan
test_only_lines_the_real_classifier_dropped_can_reach_the_request
test_the_batch_is_bounded
test_the_api_key_never_leaves_the_process
test_recorded_probe_response_reproduces_the_measured_verdicts
test_conditions_are_separate_not_blended
test_low_confidence_demotes_but_never_silences
test_promotions_carry_their_reason
test_every_failure_promotes_nothing
test_one_unusable_answer_does_not_lose_the_rest_of_the_batch
test_an_unusable_condition_cannot_veto_the_ones_that_fired
test_unreadable_answers_are_reported_not_silently_read_as_zero
test_an_overridden_root_arms_the_home_it_points_at
test_the_batch_reaches_the_engine_under_an_external_timeout
test_the_bound_is_enforced
test_heartbeat_second_look_inert_when_the_home_is_not_armed
test_heartbeat_second_look_promotes_a_dropped_line_with_its_reason
test_heartbeat_backstop_without_a_promotion_keeps_the_ordinary_key
test_a_promoted_heartbeat_is_never_an_unknown_wake
test_the_away_scan_repromotes_what_a_drained_heartbeat_absorbed
test_daemon_catch_all_escalates_a_promotion_with_its_reason
test_one_away_scan_produces_one_digest_not_one_per_alert
test_daemon_catch_all_is_unchanged_when_the_home_is_not_armed
test_daemon_reports_an_unusable_answer_instead_of_discarding_it
test_daemon_second_look_never_runs_without_dropped_lines
