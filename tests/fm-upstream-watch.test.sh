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
#   - Every report ends with the report-only tool-version section.
#   - Catch-up is off by default: no plan, no catch-up line, no live notice,
#     and arming refuses until config/upstream-watch says `catchup = on`.
#   - Opted in, a run with new upstream work adds the catch-up plan (this
#     home's own commits, files both sides changed, trial-merge conflicts),
#     surfaces UPSTREAM_CATCHUP at session start, and notifies a live watcher
#     once per pending catch-up.
#   - On demand, `catchup` needs no opt-in, plans every outstanding commit even
#     after the watermark has passed them, says plainly when there is nothing
#     to catch up, and never moves a live checkout ref.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-upstream-watch.sh"
SCHEDULE="$ROOT/bin/fm-upstream-watch-schedule.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-watch-tests)
fm_git_identity fmtest fmtest@example.invalid

# Release lookups for the tool-version section must never reach the network
# from a test, so curl always fails here; the section then reports that it
# could not compare, which is still a complete report.
OFFLINE_BIN="$TMP_ROOT/offline-bin"
mkdir -p "$OFFLINE_BIN"
printf '#!/usr/bin/env bash\nexit 7\n' >"$OFFLINE_BIN/curl"
chmod +x "$OFFLINE_BIN/curl"
export PATH="$OFFLINE_BIN:$PATH"

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
  local w=$1 stamp=$2 mode=${3:-run}
  FM_HOME="$w/home" \
  FM_ROOT_OVERRIDE="$w/fork" \
  FM_UPSTREAM_LEDGER="$w/ledger.txt" \
  FM_UPSTREAM_WATCH_STAMP="$stamp" \
  FM_UPSTREAM_WATCH_DATE=2026-08-01 \
    "$WATCH" "$mode"
}

home_watch() {
  local w=$1
  shift
  FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/fork" "$WATCH" "$@"
}

catchup_on() {
  mkdir -p "$1/home/config"
  printf 'catchup = on\n' >"$1/home/config/upstream-watch"
}

test_first_report_and_quiet_second_run() {
  local w first second out before after gains
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

  assert_grep '## Tool versions' "$first" 'report omitted the tool-version section'
  assert_grep 'This is a report only. Nothing was installed or upgraded.' "$first" \
    'tool-version section did not say it only reports'
  assert_no_grep '## Catch-up plan' "$first" 'catch-up plan appeared without the opt-in'
  assert_not_contains "$out" 'UPSTREAM_CATCHUP' 'a run without the opt-in announced a catch-up'

  out=$(run_watch "$w" second)
  assert_contains "$out" 'UPSTREAM_REPORT: wrote private report' 'second run did not deliver its quiet report'
  second=$(report_path "$w")
  # The upstream part of a quiet report is exactly one line, before the tool
  # versions that every report carries.
  [ "$(head -n 1 "$second")" = 'Upstream watch: nothing to do - no new outstanding upstream work since the last report.' ] \
    || fail "quiet report wording changed: $(head -n 1 "$second")"
  [ "$(sed -n 3p "$second")" = '## Tool versions' ] \
    || fail "quiet report must be one upstream line then the tool versions: $(cat "$second")"
  [ "$(grep -c 'Gain:' "$second" || true)" -eq 0 ] || fail 'second run repeated known upstream items'

  pass 'standing watch reports ledger-derived gains/collisions once, then one quiet line without moving live refs, with tool versions'
}

test_pending_bootstrap_surface_and_acknowledgement() {
  local w report out boot
  w="$TMP_ROOT/world"
  report=$(report_path "$w")

  out=$(FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/fork" "$WATCH" pending)
  [ "$out" = "UPSTREAM_REPORT: new private report at $report" ] \
    || fail "pending diagnostic mismatch: $out"

  # Session start composes bootstrap's output verbatim, so driving bootstrap in
  # the same detect-only mode session start uses is the observable proof that
  # the pending report reaches the digest - rather than adding another report
  # channel to session-start, or asserting against either script's source text.
  boot=$(FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/fork" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_contains "$boot" "UPSTREAM_REPORT: new private report at $report" \
    'detect-only bootstrap did not surface the pending report'

  FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/fork" "$WATCH" acknowledge "$report"
  out=$(FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/fork" "$WATCH" pending)
  [ -z "$out" ] || fail "acknowledged report still surfaced: $out"
  # The same run after acknowledgement must go quiet, so the assertion above
  # cannot pass on a bootstrap that surfaces the line unconditionally.
  boot=$(FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/fork" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_not_contains "$boot" 'UPSTREAM_REPORT:' \
    'bootstrap kept surfacing the report after acknowledgement'
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
  assert_contains "$rendered" '<key>PATH</key>' 'launchd schedule drops PATH, so the tool versions would read as missing'

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

test_crashed_owner_and_slow_fetch_recover() {
  local w fakebin out rc started elapsed real_git
  w="$TMP_ROOT/recovery"
  new_world "$w"
  fakebin="$w/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat >"$fakebin/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *' fetch '*)
    case "${FM_TEST_FETCH_MODE:-}" in
      crash)
        kill -KILL "$(cat "$FM_HOME/data/upstream-watch/.run-lock/pid")"
        exit 0
        ;;
      slow) exec sleep 30 ;;
    esac
    ;;
esac
exec "$FM_TEST_REAL_GIT" "$@"
STUB
  chmod +x "$fakebin/git"
  out=$(PATH="$fakebin:$PATH" FM_TEST_REAL_GIT="$real_git" FM_TEST_FETCH_MODE=crash     FM_UPSTREAM_WATCH_FETCH_TIMEOUT=2 run_watch "$w" killed 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail 'the owner was not killed'
  [ -e "$w/home/data/upstream-watch/.run-lock" ] || fail 'crash did not leave its lock'
  out=$(run_watch "$w" recovered)
  assert_contains "$out" 'wrote private report' 'dead owner stranded the next run'

  started=$(date +%s)
  out=$(PATH="$fakebin:$PATH" FM_TEST_REAL_GIT="$real_git" FM_TEST_FETCH_MODE=slow     FM_UPSTREAM_WATCH_FETCH_TIMEOUT=1 run_watch "$w" slow 2>&1) && rc=0 || rc=$?
  expect_code 124 "$rc" 'stalled fetch is bounded'
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] || fail "fetch exceeded its bounded budget: ${elapsed}s"
  [ ! -e "$w/home/data/upstream-watch/.run-lock" ] || fail 'timeout kept the mutex'
  out=$(run_watch "$w" after-timeout)
  assert_contains "$out" 'wrote private report' 'timeout stranded subsequent reports'
  pass 'a killed owner is reclaimed and a stalled fetch times out without stranding reports'
}

test_catchup_off_by_default() {
  local w out
  w="$TMP_ROOT/off"
  new_world "$w"
  run_watch "$w" first >/dev/null
  out=$(home_watch "$w" notify)
  [ -z "$out" ] || fail "notify spoke while catch-up is off: $out"
  out=$(home_watch "$w" pending)
  assert_contains "$out" 'UPSTREAM_REPORT:' 'pending lost the plain report line'
  mkdir -p "$w/home/state"
  out=$(home_watch "$w" arm 2>&1) && fail 'arm succeeded while catch-up is off'
  assert_contains "$out" 'catch-up is off for this home' 'arm refusal did not name the missing opt-in'
  [ ! -e "$w/home/state/upstream-catchup.check.sh" ] || fail 'a refused arm left a check behind'
  pass 'catch-up is off by default: no plan, no notice, and arming refuses'
}

test_scheduled_catchup_when_opted_in() {
  local w out report boot again
  w="$TMP_ROOT/opted-in"
  new_world "$w"
  catchup_on "$w"
  out=$(run_watch "$w" first)
  assert_contains "$out" 'UPSTREAM_CATCHUP: catch-up ready to prepare through' 'opted-in run did not announce the catch-up'
  report=$(report_path "$w")
  assert_grep '## Catch-up plan' "$report" 'opted-in run omitted the catch-up plan'
  assert_grep "This home's own changes: 1 commit the upstream does not have, newest first." "$report" \
    "plan did not count this home's own commits"
  assert_grep 'fork: preserve private behavior' "$report" "plan did not list this home's own commit"
  assert_grep 'Files the upstream changes that this home has also changed since they last met: 1.' "$report" \
    'plan did not count the files both sides changed'
  assert_grep '- shared.txt' "$report" 'plan did not name the file both sides changed'
  assert_grep 'A trial merge conflicts in 1 file:' "$report" 'plan did not preview the conflict'
  assert_grep '## Tool versions' "$report" 'catch-up report omitted the tool versions'

  out=$(home_watch "$w" pending)
  [ "$out" = "UPSTREAM_CATCHUP: catch-up ready to prepare, private report at $report" ] \
    || fail "pending did not surface the catch-up: $out"
  boot=$(FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/fork" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_contains "$boot" "UPSTREAM_CATCHUP: catch-up ready to prepare, private report at $report" \
    'session start did not surface the pending catch-up'

  out=$(home_watch "$w" notify)
  [ "$out" = "upstream-catchup: catch-up ready to prepare, private report at $report" ] \
    || fail "notify did not announce the pending catch-up: $out"
  again=$(home_watch "$w" notify)
  [ -z "$again" ] || fail "notify repeated an announced catch-up: $again"

  # A quiet week neither re-announces nor drops the catch-up still waiting.
  out=$(run_watch "$w" second)
  assert_not_contains "$out" 'UPSTREAM_CATCHUP' 'a quiet run announced a catch-up'
  out=$(home_watch "$w" pending)
  assert_contains "$out" "UPSTREAM_CATCHUP: catch-up ready to prepare, private report at $report" \
    'a quiet run dropped the pending catch-up'

  home_watch "$w" acknowledge "$report"
  out=$(home_watch "$w" pending)
  assert_not_contains "$out" 'UPSTREAM_CATCHUP' 'acknowledged catch-up still surfaced'
  assert_contains "$out" 'UPSTREAM_REPORT:' 'acknowledging the catch-up also hid the newer quiet report'
  pass 'opted in, a run with new work plans the catch-up, surfaces it at session start, and notifies once'
}

test_on_demand_catchup() {
  local w out report before after
  w="$TMP_ROOT/on-demand"
  new_world "$w"
  run_watch "$w" first >/dev/null
  before=$(git -C "$w/fork" for-each-ref --format='%(refname) %(objectname)')

  # The scheduled run already moved the watermark past both commits, yet the
  # on-demand catch-up must still plan all outstanding work, without an opt-in.
  out=$(run_watch "$w" asked catchup)
  assert_contains "$out" 'UPSTREAM_CATCHUP: catch-up ready to prepare through' 'on-demand catch-up did not report readiness'
  assert_not_contains "$out" 'UPSTREAM_REPORT:' 'on-demand catch-up printed more than its one line'
  report=$(report_path "$w")
  assert_grep 'New since the previous report: 2.' "$report" 'on-demand catch-up applied the watermark cut'
  assert_grep '## Catch-up plan' "$report" 'on-demand catch-up omitted the plan'
  after=$(git -C "$w/fork" for-each-ref --format='%(refname) %(objectname)')
  [ "$before" = "$after" ] || fail 'on-demand catch-up moved a ref in the live checkout'

  # Once the home has merged the upstream, keeping both behaviours, there is
  # nothing left to catch up and the stale pending catch-up is cleared.
  git -C "$w/fork" fetch -q upstream
  git -C "$w/fork" merge -q --no-edit upstream/main >/dev/null 2>&1 || true
  printf 'base\nfork behavior\nupstream behavior\n' >"$w/fork/shared.txt"
  git -C "$w/fork" add shared.txt
  git -C "$w/fork" commit -qm 'Merge upstream' >/dev/null
  out=$(run_watch "$w" merged catchup)
  assert_contains "$out" 'UPSTREAM_CATCHUP: nothing to catch up from' 'caught-up home was not told there is nothing to catch up'
  out=$(home_watch "$w" pending)
  assert_not_contains "$out" 'UPSTREAM_CATCHUP' 'a stale catch-up survived an empty on-demand run'
  pass 'on demand, catch-up plans all outstanding work without an opt-in and says when nothing is left'
}

test_arm_and_disarm_live_notice() {
  local w out shim
  w="$TMP_ROOT/arm"
  new_world "$w"
  catchup_on "$w"
  mkdir -p "$w/home/state"
  out=$(home_watch "$w" arm)
  [ "$out" = 'armed: state/upstream-catchup.check.sh' ] || fail "arm output: $out"
  shim="$w/home/state/upstream-catchup.check.sh"
  # shellcheck disable=SC1091
  bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"; fm_custom_check_registered "$2" upstream-catchup' \
    _ "$ROOT" "$w/home/state" || fail 'armed check is not registered with the watcher trust binding'
  out=$(env -u FM_HOME "$shim")
  [ -z "$out" ] || fail "armed check spoke with nothing pending: $out"
  run_watch "$w" first >/dev/null
  out=$(env -u FM_HOME FM_ROOT_OVERRIDE="$w/fork" "$shim")
  assert_contains "$out" 'upstream-catchup: catch-up ready to prepare' 'armed check did not announce the pending catch-up'
  out=$(home_watch "$w" disarm)
  [ "$out" = 'disarmed: state/upstream-catchup.check.sh' ] || fail "disarm output: $out"
  [ ! -e "$shim" ] && [ ! -e "$w/home/state/upstream-catchup.check-trust" ] || fail 'disarm left the check behind'
  pass 'arm binds a watcher check that announces a pending catch-up, and disarm retires it'
}

test_live_notice_through_symlinked_home() {
  local w link out shim
  w="$TMP_ROOT/linked"
  new_world "$w"
  catchup_on "$w"
  mkdir -p "$w/home/state"
  # The weekly job keeps FM_HOME as spelled, while the armed check pins the
  # physical path, so the two must still agree on which reports are pending.
  link="$TMP_ROOT/linked-home"
  ln -s "$w/home" "$link"
  FM_HOME="$link" FM_ROOT_OVERRIDE="$w/fork" "$WATCH" arm >/dev/null
  FM_HOME="$link" FM_ROOT_OVERRIDE="$w/fork" FM_UPSTREAM_LEDGER="$w/ledger.txt" \
    FM_UPSTREAM_WATCH_STAMP=first FM_UPSTREAM_WATCH_DATE=2026-08-01 "$WATCH" run >/dev/null
  shim="$w/home/state/upstream-catchup.check.sh"
  out=$(env -u FM_HOME FM_ROOT_OVERRIDE="$w/fork" "$shim")
  assert_contains "$out" 'upstream-catchup: catch-up ready to prepare' \
    'armed check stayed silent for a catch-up recorded through a symlinked home'
  pass 'the live notice fires when the job reaches the home through a symlink'
}

test_config_validation() {
  local w out rendered
  w="$TMP_ROOT/config"
  new_world "$w"
  mkdir -p "$w/home/config"
  printf 'catchup = maybe\n' >"$w/home/config/upstream-watch"
  out=$(run_watch "$w" bad 2>&1) && fail 'run accepted an invalid catchup value'
  assert_contains "$out" 'catchup must be on or off' 'invalid catchup value was not named'
  printf 'catchup = on\ncolour = blue\n' >"$w/home/config/upstream-watch"
  out=$(run_watch "$w" bad 2>&1) && fail 'run accepted an unknown key'
  assert_contains "$out" 'unknown key: colour' 'unknown key was not named'
  printf 'catchup = on\ninterval_seconds = 1209600\n' >"$w/home/config/upstream-watch"
  rendered=$(FM_HOME="$w/home" FM_ROOT_OVERRIDE="$ROOT" "$SCHEDULE" render)
  assert_contains "$rendered" '<integer>1209600</integer>' 'schedule ignored its cadence beside the catch-up opt-in'
  pass 'config/upstream-watch refuses unknown keys and values, and the cadence lives beside the opt-in'
}

test_first_report_and_quiet_second_run
test_pending_bootstrap_surface_and_acknowledgement
test_catchup_off_by_default
test_scheduled_catchup_when_opted_in
test_on_demand_catchup
test_arm_and_disarm_live_notice
test_live_notice_through_symlinked_home
test_config_validation
test_private_path_and_schedule
test_crashed_owner_and_slow_fetch_recover
