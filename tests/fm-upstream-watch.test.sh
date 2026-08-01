#!/usr/bin/env bash
# Behavior tests for the private standing upstream watch.
#
# Contracts under test:
#   - The first report uses the existing ported-ledger derivation for its raw
#     and outstanding counts, gives every new item a plain gain, and names fork
#     collisions.
#   - A durable watermark makes an unchanged second run produce a one-line
#     nothing-to-do report instead of repeating known work.
#   - Delivery fetches only in a standalone bare cache and never moves a live
#     checkout ref.
#   - Reports and pending pointers are private under ignored data/; bootstrap
#     surfaces the pending report through the established diagnostic section.
#   - The launchd schedule is inspectable, weekly by default, and configurable.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-upstream-watch.sh"
SCHEDULE="$ROOT/bin/fm-upstream-watch-schedule.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-watch-tests)
fm_git_identity fmtest fmtest@example.invalid

new_world() {
  local w=$1 seed upstream_work
  mkdir -p "$w"
  seed="$w/seed"
  git init -q -b main "$seed"
  printf 'base\n' >"$seed/shared.txt"
  printf 'base\n' >"$seed/other.txt"
  git -C "$seed" add .
  git -C "$seed" commit -qm 'initial'
  git clone -q --bare "$seed" "$w/upstream.git"
  git clone -q --bare "$seed" "$w/origin.git"
  git clone -q "$w/origin.git" "$w/fork"
  git -C "$w/fork" remote add upstream "file://$w/upstream.git"
  git -C "$w/fork" remote set-head upstream main >/dev/null 2>&1 || true

  # Fork-only edit creates a real collision against one upstream item.
  printf 'fork behavior\n' >>"$w/fork/shared.txt"
  git -C "$w/fork" add shared.txt
  git -C "$w/fork" commit -qm 'fork: preserve private behavior'

  upstream_work="$w/upstream-work"
  git clone -q "$w/upstream.git" "$upstream_work"
  printf 'upstream behavior\n' >>"$upstream_work/shared.txt"
  git -C "$upstream_work" add shared.txt
  git -C "$upstream_work" commit -qm 'fix(watch): prevent finished workers looking stuck (#701)'
  printf 'feature\n' >>"$upstream_work/other.txt"
  git -C "$upstream_work" add other.txt
  git -C "$upstream_work" commit -qm 'feat: add bounded summaries (#702)'
  printf 'docs\n' >"$upstream_work/docs.txt"
  git -C "$upstream_work" add docs.txt
  git -C "$upstream_work" commit -qm 'docs: define operator precedence (#703)'
  git -C "$upstream_work" push -q origin main

  mkdir -p "$w/home/data"
  printf 'CAPTAIN-PRIVATE-SENTINEL\n' >"$w/home/data/captain.md"
  git -C "$w/upstream-work" rev-parse 'HEAD^' >"$w/ported-sha"
  printf '%s ported fixture-delivery\n' "$(cat "$w/ported-sha")" >"$w/ledger.txt"
}

report_path() {
  cat "$1/home/data/upstream-watch/pending-report"
}

run_watch() {
  local w=$1 stamp=$2
  FM_HOME="$w/home" \
  FM_ROOT_OVERRIDE="$w/fork" \
  FM_UPSTREAM_LEDGER="$w/ledger.txt" \
  FM_UPSTREAM_WATCH_STAMP="$stamp" \
  FM_UPSTREAM_WATCH_DATE=2026-08-01 \
    "$WATCH" run
}

test_first_report_and_quiet_second_run() {
  local w first second out before after gains lines
  w="$TMP_ROOT/world"
  new_world "$w"
  before=$(git -C "$w/fork" for-each-ref --format='%(refname) %(objectname)')

  out=$(run_watch "$w" first)
  assert_contains "$out" 'UPSTREAM_REPORT: wrote private report' 'first run did not report its private output path'
  first=$(report_path "$w")
  assert_present "$first" 'first report was not written'
  assert_grep 'Outstanding: 2 of 3 raw upstream commits remain after the ported-ledger derivation.' "$first" \
    'first report did not use the honest-ledger count'
  assert_grep 'New since the previous report: 2.' "$first" 'first report did not classify both outstanding items as new'
  gains=$(grep -c 'Gain:' "$first" || true)
  [ "$gains" -eq 2 ] || fail "expected one gain per new item, got $gains"
  assert_grep 'Gain: Stops finished workers looking stuck.' "$first" 'fix subject was not translated into a plain gain'
  assert_no_grep 'fix(watch):' "$first" 'report repeated a conventional commit subject instead of its gain'
  assert_grep 'Collision: overlaps fork changes at shared.txt' "$first" 'report did not name the fork collision'
  assert_no_grep 'CAPTAIN-PRIVATE-SENTINEL' "$first" 'report leaked captain-private data'

  after=$(git -C "$w/fork" for-each-ref --format='%(refname) %(objectname)')
  [ "$before" = "$after" ] || fail 'delivery moved a ref in the live checkout'
  [ "$(git -C "$w/home/data/upstream-watch/cache.git" rev-parse --is-bare-repository)" = true ] \
    || fail 'delivery cache is not standalone bare git storage'

  out=$(run_watch "$w" second)
  assert_contains "$out" 'UPSTREAM_REPORT: wrote private report' 'second run did not deliver its quiet report'
  second=$(report_path "$w")
  lines=$(wc -l <"$second" | tr -d ' ')
  [ "$lines" -eq 1 ] || fail "quiet report must be exactly one line, got $lines"
  [ "$(cat "$second")" = 'Upstream watch: nothing to do - no new outstanding upstream work since the last report.' ] \
    || fail "quiet report wording changed: $(cat "$second")"
  [ "$(grep -c 'Gain:' "$second" || true)" -eq 0 ] || fail 'second run repeated known upstream items'

  pass 'standing watch reports ledger-derived gains/collisions once, then one quiet line without moving live refs'
}

test_pending_bootstrap_surface_and_acknowledgement() {
  local w report out
  w="$TMP_ROOT/world"
  report=$(report_path "$w")

  out=$(FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/fork" "$WATCH" pending)
  [ "$out" = "UPSTREAM_REPORT: new private report at $report" ] \
    || fail "pending diagnostic mismatch: $out"

  # Session start composes bootstrap verbatim; pin the actual bootstrap owner
  # invocation rather than adding another report channel to session-start.
  assert_grep '"$SCRIPT_DIR/fm-upstream-watch.sh" pending' "$ROOT/bin/fm-bootstrap.sh" \
    'bootstrap no longer surfaces the pending report'
  assert_grep 'BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 "$SCRIPT_DIR/fm-bootstrap.sh"' "$ROOT/bin/fm-session-start.sh" \
    'session start no longer composes detect-only bootstrap output'

  FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/fork" "$WATCH" acknowledge "$report"
  out=$(FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/fork" "$WATCH" pending)
  [ -z "$out" ] || fail "acknowledged report still surfaced: $out"
  assert_present "$report" 'acknowledgement deleted the durable report'

  pass 'session-start bootstrap surfaces one pending report until explicit acknowledgement'
}

test_private_path_and_schedule() {
  local ignored rendered custom config
  ignored="$ROOT/data/upstream-watch/reports/example.md"
  git -C "$ROOT" check-ignore -q "$ignored" || fail 'data/upstream-watch reports are not gitignored'

  rendered=$(FM_HOME="$TMP_ROOT/schedule-home" FM_ROOT_OVERRIDE="$ROOT" "$SCHEDULE" render)
  assert_contains "$rendered" '<key>StartInterval</key>' 'rendered launchd schedule omitted StartInterval'
  assert_contains "$rendered" '<integer>604800</integer>' 'default launchd cadence is not weekly'
  assert_contains "$rendered" '<string>run</string>' 'launchd schedule does not call the delivery runner'

  config="$TMP_ROOT/schedule-home/config"
  mkdir -p "$config"
  printf 'interval_seconds = 1209600\n' >"$config/upstream-watch"
  custom=$(FM_HOME="$TMP_ROOT/schedule-home" FM_ROOT_OVERRIDE="$ROOT" "$SCHEDULE" render)
  assert_contains "$custom" '<integer>1209600</integer>' 'private cadence configuration was ignored'

  assert_no_grep 'git -C "$ROOT" fetch' "$WATCH" 'delivery contains a fetch against the live checkout'
  assert_no_grep 'git fetch' "$ROOT/bin/fm-upstream-watch-generate.sh" 'fetch-free generator contains a git fetch'
  assert_no_grep 'merge\|rebase\|cherry-pick' "$ROOT/bin/fm-upstream-watch-generate.sh" \
    'generator contains an automatic integration command'

  pass 'reports are ignored and the explicit launchd schedule is weekly, configurable, and fetch-safe'
}

test_first_report_and_quiet_second_run
test_pending_bootstrap_surface_and_acknowledgement
test_private_path_and_schedule
