#!/usr/bin/env bash
# Behavior tests for capability outcome log write + dispatch-time reader.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-capability-tests)
# shellcheck source=bin/fm-capability-lib.sh
. "$ROOT/bin/fm-capability-lib.sh"

export FM_CAPABILITY_LOG="$TMP_ROOT/capability-outcomes.log"
export FM_CAPABILITY_NOW=1700000000
export FM_CAPABILITY_WINDOW_SECS=604800
export FM_CAPABILITY_SCOUT_TAX=0

test_log_append_and_recent_window() {
  rm -f "$FM_CAPABILITY_LOG"
  fm_capability_log_append ship cursor cursor-grok-4.5-medium-fast medium green \
    || fail "append green should succeed"
  fm_capability_log_append ship cursor cursor-grok-4.5-medium-fast medium discarded \
    || fail "append discarded should succeed"
  # Outside the 7-day window relative to FM_CAPABILITY_NOW.
  printf '%s\n' '1699000000|ship|claude|sonnet|high|green' >> "$FM_CAPABILITY_LOG"
  fm_capability_log_append scout claude sonnet high green \
    || fail "append scout should succeed"

  local recent
  recent=$(fm_capability_recent_lines ship)
  assert_contains "$recent" '1700000000|ship|cursor|cursor-grok-4.5-medium-fast|medium|green' \
    "recent ship lines should include in-window green"
  assert_contains "$recent" '1700000000|ship|cursor|cursor-grok-4.5-medium-fast|medium|discarded' \
    "recent ship lines should include in-window discarded"
  case "$recent" in
    *1699000000*) fail "expired lines must be excluded from the window" ;;
  esac
  case "$recent" in
    *'|scout|'*) fail "ship reader must not return scout lines" ;;
  esac
  pass "log append writes wire lines and the reader applies the 7-day window"
}

test_summarize_green_density() {
  rm -f "$FM_CAPABILITY_LOG"
  FM_CAPABILITY_NOW=1700000000
  fm_capability_log_append refactor cursor composer-2.5-fast low green
  fm_capability_log_append refactor cursor composer-2.5-fast low green
  fm_capability_log_append refactor cursor composer-2.5-fast low discarded
  fm_capability_log_append refactor claude sonnet high green

  local summary
  summary=$(fm_capability_summarize refactor)
  assert_contains "$summary" 'claude|sonnet|high|1|1|100' \
    "perfect green density should be 100"
  assert_contains "$summary" 'cursor|composer-2.5-fast|low|2|3|66' \
    "mixed outcomes should report integer density"
  pass "summarize reports green density per harness/model/effort"
}

test_record_teardown_outcomes() {
  rm -f "$FM_CAPABILITY_LOG"
  fm_capability_record_teardown ship '' cursor grok medium bugfix
  fm_capability_record_teardown ship --force cursor grok medium bugfix
  fm_capability_record_teardown secondmate '' claude sonnet high ''
  local body
  body=$(cat "$FM_CAPABILITY_LOG")
  assert_contains "$body" '|bugfix|cursor|grok|medium|green' \
    "normal teardown should log green with task_type"
  assert_contains "$body" '|bugfix|cursor|grok|medium|discarded' \
    "force teardown should log discarded"
  case "$body" in
    *secondmate*|*'|claude|'*) fail "secondmate teardown must not write capability lines" ;;
  esac
  pass "teardown recorder writes green/discarded and skips secondmate"
}

test_capability_recent_select_and_scout_tax_advisory() {
  rm -f "$FM_CAPABILITY_LOG"
  FM_CAPABILITY_NOW=1700000000
  fm_capability_log_append big-feature claude sonnet high green
  fm_capability_log_append big-feature claude sonnet high green
  fm_capability_log_append big-feature codex gpt-5.5 high discarded

  local profiles out err
  profiles='[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"claude","model":"sonnet","effort":"high"}]'
  out=$("$ROOT/bin/fm-dispatch-select.sh" \
    --select capability-recent \
    --task-type big-feature \
    "$profiles" 2>"$TMP_ROOT/cap.err")
  err=$(cat "$TMP_ROOT/cap.err")
  [ "$out" = '{"harness":"claude","model":"sonnet","effort":"high"}' ] \
    || fail "capability-recent should prefer higher green density inside the allowed set, got: $out"
  assert_contains "$err" 'CAPABILITY_EVIDENCE: task-type=big-feature' \
    "dispatch-select should surface evidence on stderr"
  case "$err" in
    *CAPABILITY_SCOUT_TAX*) fail "scout tax must stay off when FM_CAPABILITY_SCOUT_TAX=0" ;;
  esac

  out=$(FM_CAPABILITY_SCOUT_TAX=1 "$ROOT/bin/fm-dispatch-select.sh" \
    --select capability-recent \
    --task-type big-feature \
    "$profiles" 2>"$TMP_ROOT/tax.err")
  err=$(cat "$TMP_ROOT/tax.err")
  [ "$out" = '{"harness":"claude","model":"sonnet","effort":"high"}' ] \
    || fail "scout tax must not change stdout selection, got: $out"
  assert_contains "$err" 'CAPABILITY_SCOUT_TAX: task-type=big-feature consider {"harness":"codex","model":"gpt-5.5","effort":"high"}' \
    "forced scout tax should suggest a different cost-allowed profile"
  pass "capability-recent ranks within cost rules and scout tax stays advisory"
}

test_first_profile_unchanged_without_capability_select() {
  local profiles out
  profiles='[{"harness":"codex","effort":"high"},{"harness":"claude","effort":"high"}]'
  out=$(FM_CAPABILITY_SCOUT_TAX=0 "$ROOT/bin/fm-dispatch-select.sh" \
    --task-type unused \
    "$profiles" 2>/dev/null)
  [ "$out" = '{"harness":"codex","effort":"high"}' ] \
    || fail "absent select must still prefer first profile, got: $out"
  pass "absent select keeps first-profile selection with evidence only advisory"
}

test_zero_green_sampled_does_not_beat_earlier_untried() {
  rm -f "$FM_CAPABILITY_LOG"
  FM_CAPABILITY_NOW=1700000000
  # Three discarded codex runs => 0% green; claude is untried and configured first.
  fm_capability_log_append bugfix codex gpt-5.5 high discarded
  fm_capability_log_append bugfix codex gpt-5.5 high discarded
  fm_capability_log_append bugfix codex gpt-5.5 high discarded

  local profiles out
  profiles='[{"harness":"claude","model":"sonnet","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'
  out=$(FM_CAPABILITY_SCOUT_TAX=0 "$ROOT/bin/fm-dispatch-select.sh" \
    --select capability-recent \
    --task-type bugfix \
    "$profiles" 2>/dev/null)
  [ "$out" = '{"harness":"claude","model":"sonnet","effort":"high"}' ] \
    || fail "0%-green sampled must not beat earlier untried profile, got: $out"
  pass "0%-green sampled keeps configured order over earlier untried"
}

test_scout_tax_rate_clamped_to_100() {
  rm -f "$FM_CAPABILITY_LOG"
  FM_CAPABILITY_NOW=1700000000
  fm_capability_log_append clamp-tax claude sonnet high green

  local profiles out err
  profiles='[{"harness":"claude","model":"sonnet","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'
  # Rate > 100 must clamp; roll 99 fires only when rate is treated as >= 100.
  out=$(FM_CAPABILITY_SCOUT_TAX='' \
    FM_CAPABILITY_SCOUT_TAX_RATE=999 \
    FM_CAPABILITY_SCOUT_ROLL=99 \
    "$ROOT/bin/fm-dispatch-select.sh" \
    --select capability-recent \
    --task-type clamp-tax \
    "$profiles" 2>"$TMP_ROOT/clamp.err")
  err=$(cat "$TMP_ROOT/clamp.err")
  [ "$out" = '{"harness":"claude","model":"sonnet","effort":"high"}' ] \
    || fail "scout tax clamp must not change stdout, got: $out"
  assert_contains "$err" 'CAPABILITY_SCOUT_TAX: task-type=clamp-tax consider' \
    "rate above 100 must clamp to 100 so roll 99 still fires"
  pass "scout tax rate above 100 clamps to 100"
}

test_reject_pipe_in_fields() {
  rm -f "$FM_CAPABILITY_LOG"
  if fm_capability_log_append 'bad|type' cursor grok medium green 2>/dev/null; then
    fail "pipe in task-type must refuse append"
  fi
  [ ! -e "$FM_CAPABILITY_LOG" ] || [ ! -s "$FM_CAPABILITY_LOG" ] \
    || fail "rejected append must not create a polluted log line"
  pass "log append refuses pipe-bearing fields"
}

test_log_append_and_recent_window
test_summarize_green_density
test_record_teardown_outcomes
test_capability_recent_select_and_scout_tax_advisory
test_first_profile_unchanged_without_capability_select
test_zero_green_sampled_does_not_beat_earlier_untried
test_scout_tax_rate_clamped_to_100
test_reject_pipe_in_fields

echo "# all fm-capability tests passed"
