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
  # Truegreen contract: the caller derives the outcome from recorded validation
  # evidence; counts ride along only when derivable.
  fm_capability_record_teardown ship '' cursor grok medium bugfix green 0 3
  fm_capability_record_teardown ship '' cursor grok medium bugfix fixed 2 ''
  fm_capability_record_teardown ship '' cursor grok medium bugfix failed '' 1
  fm_capability_record_teardown scout '' claude sonnet high report unknown '' ''
  fm_capability_record_teardown ship --force cursor grok medium bugfix green 0 3
  fm_capability_record_teardown secondmate '' claude sonnet high '' unknown '' ''
  local body
  body=$(cat "$FM_CAPABILITY_LOG")
  assert_contains "$body" '|bugfix|cursor|grok|medium|green|0|3' \
    "first-try pass should log green with both counts"
  assert_contains "$body" '|bugfix|cursor|grok|medium|fixed|2' \
    "pass after fix rounds should log fixed with its fix-round count"
  assert_contains "$body" '|bugfix|cursor|grok|medium|failed||1' \
    "a steer-only record should retain the empty fix-rounds slot"
  case "$body" in
    *'|fixed|2|'*) fail "a fix-round-only record must omit the absent steer slot: $body" ;;
  esac
  assert_contains "$body" '|report|claude|sonnet|high|unknown' \
    "underivable validation should log unknown without counts"
  assert_contains "$body" '|bugfix|cursor|grok|medium|discarded' \
    "force teardown should still log discarded"
  local discarded_line
  discarded_line=$(grep discarded "$FM_CAPABILITY_LOG")
  case "$discarded_line" in
    *'|discarded|0|3') fail "force teardown must not carry derived counts: $discarded_line" ;;
  esac
  case "$body" in
    *secondmate*|*'|claude|sonnet|high|green'*) fail "secondmate teardown must not write capability lines" ;;
  esac
  pass "teardown recorder writes derived outcomes with optional counts and skips secondmate"
}

test_outcome_derivation_from_runs_rows() {
  local got runs
  # Rows are newest-first, matching `no-mistakes runs` output exactly.
  runs='  completed    fm/task-x1 c301eb14  2026-08-20 17:12  https://github.com/example/repo/pull/9'
  got=$(fm_capability_outcome_from_runs fm/task-x1 "$runs")
  [ "$got" = 'green|0' ] || fail "single completed attempt should be green|0, got: $got"

  runs='  completed    fm/task-x1 c301eb14  2026-08-20 17:12  https://github.com/example/repo/pull/9
  failed       fm/task-x1 d7bf67d7  2026-08-14 03:37'
  got=$(fm_capability_outcome_from_runs fm/task-x1 "$runs")
  [ "$got" = 'fixed|1' ] || fail "completed after one earlier attempt should be fixed|1, got: $got"

  runs='  completed    fm/task-x1 c301eb14  2026-08-20 17:12
  failed       fm/task-x1 d7bf67d7  2026-08-14 03:37
  cancelled    fm/task-x1 365e7449  2026-08-12 01:12
  cancelled    fm/other-task 99e19551  2026-08-11 21:58
  (171 more runs, use --limit to see more)'
  got=$(fm_capability_outcome_from_runs fm/task-x1 "$runs")
  [ "$got" = 'fixed|2' ] || fail "other branches and footer rows must be ignored, got: $got"

  runs='  cancelled    fm/task-x1 365e7449  2026-08-12 01:12
  failed       fm/task-x1 d7bf67d7  2026-08-14 03:37'
  got=$(fm_capability_outcome_from_runs fm/task-x1 "$runs")
  [ "$got" = 'failed|' ] || fail "no completed attempt should be failed, got: $got"

  got=$(fm_capability_outcome_from_runs fm/task-x1 '')
  [ "$got" = 'unknown|' ] || fail "empty run records must be unknown, got: $got"
  got=$(fm_capability_outcome_from_runs '' '  completed fm/task-x1 a b c')
  [ "$got" = 'unknown|' ] || fail "missing branch must be unknown, got: $got"
  got=$(fm_capability_outcome_from_runs fm/task-x1 '  completed    fm/other x 2026-08-20 17:12')
  [ "$got" = 'unknown|' ] || fail "unmatched branch must be unknown, got: $got"
  pass "run-table derivation yields first-try green, fixed, failed, or unknown"
}

test_reader_handles_old_and_new_lines() {
  rm -f "$FM_CAPABILITY_LOG"
  FM_CAPABILITY_NOW=1700000000
  # Old six-field wire format written by pre-truegreen teardowns, alongside
  # new seven- and eight-field lines.
  printf '%s\n' \
    '1699999000|legacy|claude|sonnet|high|green' \
    '1699999100|truegreen|claude|sonnet|high|green|0|4' \
    '1699999200|truegreen|claude|sonnet|high|fixed|2' \
    >> "$FM_CAPABILITY_LOG"

  local recent summary out
  recent=$(fm_capability_recent_lines truegreen)
  assert_contains "$recent" '|claude|sonnet|high|green|0|4' \
    "reader should return new eight-field lines intact"
  summary=$(fm_capability_summarize truegreen)
  assert_contains "$summary" 'claude|sonnet|high|1|2|50' \
    "density must count only first-try greens over all samples"
  summary=$(fm_capability_summarize legacy)
  assert_contains "$summary" 'claude|sonnet|high|1|1|100' \
    "old six-field lines must still parse and rank"

  local profiles
  profiles='[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"claude","model":"sonnet","effort":"high"}]'
  fm_capability_log_append truegreen codex gpt-5.5 high green 0 0
  out=$(FM_CAPABILITY_SCOUT_TAX=0 "$ROOT/bin/fm-dispatch-select.sh" \
    --select capability-recent \
    --task-type truegreen \
    "$profiles" 2>/dev/null)
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "capability-recent should rank on true greens across mixed-format lines, got: $out"
  pass "reader handles old and new wire lines side by side"
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
test_outcome_derivation_from_runs_rows
test_reader_handles_old_and_new_lines
test_capability_recent_select_and_scout_tax_advisory
test_first_profile_unchanged_without_capability_select
test_zero_green_sampled_does_not_beat_earlier_untried
test_scout_tax_rate_clamped_to_100
test_reject_pipe_in_fields

echo "# all fm-capability tests passed"
