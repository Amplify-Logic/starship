#!/usr/bin/env bash
# Fleet-field supply regressions: bin/fm-fleet-status-lib.sh.
#
# These cases never call bin/fm-crew-state.sh. A fixture reader stands in for it,
# so the suite exercises the folding, caching, and refusal rules without touching
# a crew, a pane, or the validation pipeline.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-status-lib)
BINDIR="$TMP_ROOT/bin"
mkdir -p "$BINDIR"
# The owner's calls read the backlog through the tasks-axi adapter; this
# stand-in serves each case's markdown rows.
fm_install_markdown_tasks_axi "$TMP_ROOT/axibin"
export PATH="$TMP_ROOT/axibin:$PATH"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

cat > "$BINDIR/fake-crew-state" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FLEET_TEST_READER_FAIL:-}" ] || exit 1
[ -f "$FM_FLEET_FIXTURE/$1" ] || exit 1
cat "$FM_FLEET_FIXTURE/$1"
SH
chmod +x "$BINDIR/fake-crew-state"

# A reader that records every id it was asked about, so a case can prove the
# canonical reader was not consulted at all.
cat > "$BINDIR/counting-crew-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_FLEET_TEST_CALLS"
[ -f "$FM_FLEET_FIXTURE/$1" ] || exit 1
cat "$FM_FLEET_FIXTURE/$1"
SH
chmod +x "$BINDIR/counting-crew-state"

# A reader that DRAINS its stdin before answering, which is what a canonical
# reader shelling out to git, herdr or the pipeline can do. It answers its own id
# correctly, so a fold that still comes up short lost ids to this drain rather
# than to a reader that refused.
cat > "$BINDIR/stdin-draining-crew-state" <<'SH'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf '%s\n' "$1" >> "$FM_FLEET_TEST_CALLS"
[ -f "$FM_FLEET_FIXTURE/$1" ] || exit 1
cat "$FM_FLEET_FIXTURE/$1"
SH
chmod +x "$BINDIR/stdin-draining-crew-state"

# A reader slow enough that a refresh started with it is still in flight when the
# next case looks, which is what makes the claim window observable.
cat > "$BINDIR/slow-crew-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_FLEET_TEST_CALLS"
sleep 3
[ -f "$FM_FLEET_FIXTURE/$1" ] || exit 1
cat "$FM_FLEET_FIXTURE/$1"
SH
chmod +x "$BINDIR/slow-crew-state"

# A fixture endpoint prober standing in for bin/fm-backend.sh's recovery-grade
# classifier, so the liveness cases run with no tmux session, no herdr server and
# no agent process. It answers from the recorded target's own name.
cat > "$BINDIR/fake-probe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1 $2" >> "${FM_FLEET_TEST_PROBES:-/dev/null}"
case "$2" in
  live*) printf 'alive' ;;
  dead*) printf 'dead' ;;
  *) printf 'unknown' ;;
esac
SH
chmod +x "$BINDIR/fake-probe"

task() {  # <id> <kind> <canonical line>
  fm_write_meta "$STATE/$1.meta" "kind=$2"
  printf '%s\n' "$3" > "$FLEET_FIX/$1"
}

# endpoint_task: a task record that also carries the endpoint and worktree the
# liveness fold reads - the shape a real dispatched task's metadata has.
endpoint_task() {  # <id> <window> <worktree> <canonical line>
  fm_write_meta "$STATE/$1.meta" kind=crew backend=tmux "window=$2" "worktree=$3"
  printf '%s\n' "$4" > "$FLEET_FIX/$1"
}

# Every case gets its own state directory, fixtures and call log. A detached
# refresher outlives the frame that started it by design, so a case that leaves
# one in flight would otherwise have it fold the NEXT case's fleet: reading that
# case's tasks, appending to its call log, and publishing into its cache. The
# reader calls and cached readings a case then sees belong to no case at all.
FLEET_CASE=0
reset_state() {
  FLEET_CASE=$((FLEET_CASE + 1))
  STATE="$TMP_ROOT/case$FLEET_CASE/state"
  FLEET_FIX="$TMP_ROOT/case$FLEET_CASE/fleet"
  CALLS="$TMP_ROOT/case$FLEET_CASE/calls"
  mkdir -p "$STATE" "$STATE/../data" "$FLEET_FIX"
  export FM_FLEET_FIXTURE="$FLEET_FIX"
}

counts() {  # [env assignments already exported by the caller]
  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    fm_fleet_status_counts "$2"
  ' _ "$ROOT" "$STATE"
}

# --- folding ---------------------------------------------------------------

test_canonical_states_fold_into_the_six_fields() {
  local out
  reset_state
  task busy crew 'state: working · source: pane · harness busy'
  task pipe crew 'state: working · source: run-step · run ci'
  task wait crew 'state: paused · source: status-log · upstream release'
  task gate crew 'state: parked · source: run-step · awaiting approval'
  task stuck crew 'state: blocked · source: status-log · needs a credential'
  task broke crew 'state: failed · source: run-step · run failed'
  task shipped crew 'state: done · source: run-step · checks passed'
  task landed crew 'state: done · source: run-step · checks green: PR merged (ci monitor ended)'
  task ghost crew 'state: unknown · source: none · backend target gone'
  task mate secondmate 'state: working · source: pane · harness busy'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  # records working stopped validating paused attention ready known
  # No fixture records an endpoint, so the only proof of life available is the
  # busy pane worker the canonical reader saw. The PR ready for review waits on
  # the captain; the merged PR waits on nobody, and the parked gate no human
  # owes is the worker's own turn, so neither claims a field.
  [ "$out" = $'9\t1\t0\t1\t1\t2\t1\t1\t0' ] \
    || fail "canonical states did not fold into the documented fields: $(printf '%s' "$out" | tr '\t' ' ')"
  pass "fleet status: canonical states fold into records, working, stopped, validating, paused, attention and ready"
}

# The whole point of the change: a meta file is a record, and a record is not a
# worker. Second mates are direct reports, not work items, and stay out entirely.
test_records_are_counted_apart_from_live_workers() {
  local out records alive
  reset_state
  task live crew 'state: working · source: pane · harness busy'
  task gone1 crew 'state: unknown · source: none · backend target gone: w8:pV'
  task gone2 crew 'state: unknown · source: none · no metadata'
  task gone3 crew 'state: done · source: run-step · checks passed'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  records=$(printf '%s' "$out" | cut -f1)
  alive=$(printf '%s' "$out" | cut -f2)
  [ "$records" = 4 ] || fail "four task records were not all counted as records: $records"
  [ "$alive" = 1 ] || fail "task records were counted as running workers: $alive"
  pass "fleet status: task records are counted apart from live workers"
}

# --- refusals --------------------------------------------------------------

test_an_incomplete_fold_is_refused_rather_than_published_short() {
  local out
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  task two crew 'state: working · source: pane · harness busy'
  rm -f "$FLEET_FIX/two"

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  [ "$out" = $'2\t0\t0\t0\t0\t0\t0\t0\t0' ] \
    || fail "a fold the reader could not complete was published anyway: $(printf '%s' "$out" | tr '\t' ' ')"
  pass "fleet status: an incomplete fold is refused instead of reported as a quieter fleet"
}

test_a_broken_reader_never_becomes_an_idle_fleet() {
  local out known
  reset_state
  task one crew 'state: working · source: pane · harness busy'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_TEST_READER_FAIL=1 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f8)
  [ "$known" = 0 ] || fail "a reader that answers nothing was treated as a real reading"
  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$TMP_ROOT/not-a-reader" counts)
  known=$(printf '%s' "$out" | cut -f8)
  [ "$known" = 0 ] || fail "a missing reader was treated as a real reading"
  pass "fleet status: a broken or missing canonical reader reports unknown, never an idle fleet"
}

# A reading is about the fleet it was taken for. Applying it to a different set
# of tasks as current would report, with full confidence, numbers for work that
# is not there any more, so it is shown only as the last good reading.
test_a_reading_for_another_fleet_is_not_current() {
  local out known
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  out=$(FM_FLEET_STATE_NOW=1000 FM_FLEET_STATE_TTL=600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  # Prime the cache directly, the way a completed refresh would.
  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    _fm_fleet_collect "$2" 1000 "$3" > "$2/.status-fleet-state"
  ' _ "$ROOT" "$STATE" "$BINDIR/fake-crew-state"
  out=$(FM_FLEET_STATE_NOW=1010 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f8)
  [ "$known" = 1 ] || fail "a fresh cached reading for this fleet was not used: $out"

  task two crew 'state: paused · source: status-log · upstream release'
  out=$(FM_FLEET_STATE_NOW=1010 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f8)
  [ "$known" = 2 ] || fail "a reading taken before the fleet changed was applied to the new fleet as current: $out"
  pass "fleet status: a cached reading is no longer current once the fleet it covered has changed"
}

# A dispatch or a cleanup changes the fleet inside the cache TTL. Waiting out the
# TTL before refreshing left the row without a current reading for minutes after
# every spawn, so a changed fleet starts a refresh on the very next frame, while
# a fresh reading for an unchanged fleet starts none.
test_a_changed_fleet_starts_a_refresh_without_waiting_for_the_ttl() {
  local now out
  reset_state
  now=$(date +%s)
  task one crew 'state: working · source: pane · harness busy'
  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    _fm_fleet_collect "$2" "$4" "$3" > "$2/.status-fleet-state"
  ' _ "$ROOT" "$STATE" "$BINDIR/fake-crew-state" "$now"
  now=$(date +%s)

  # The reader does not exist, so a refresh this frame starts never publishes
  # and its claim stays behind as the proof that it was started.
  out=$(FM_FLEET_STATE_NOW=$now FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=600 \
    FM_FLEET_STATE_READER="$BINDIR/no-such-crew-state" counts)
  [ "$(printf '%s' "$out" | cut -f8)" = 1 ] \
    || fail "a fresh reading for an unchanged fleet was not current: $(printf '%s' "$out" | tr '\t' ' ')"
  [ ! -e "$STATE/.status-fleet-state.refreshing" ] \
    || fail "a fresh reading for an unchanged fleet started a refresh"

  task two crew 'state: paused · source: status-log · upstream release'
  out=$(FM_FLEET_STATE_NOW=$now FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=600 \
    FM_FLEET_STATE_READER="$BINDIR/no-such-crew-state" counts)
  [ "$(printf '%s' "$out" | cut -f8)" = 2 ] \
    || fail "a reading for the fleet before a dispatch was reported as current: $(printf '%s' "$out" | tr '\t' ' ')"
  [ -e "$STATE/.status-fleet-state.refreshing" ] \
    || fail "a changed fleet waited out the cache TTL instead of starting a refresh"
  pass "fleet status: a changed fleet starts a refresh at once, and an unchanged fresh one does not"
}

test_a_reading_that_has_aged_out_is_not_current() {
  local out known
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    _fm_fleet_collect "$2" 1000 "$3" > "$2/.status-fleet-state"
  ' _ "$ROOT" "$STATE" "$BINDIR/fake-crew-state"

  out=$(FM_FLEET_STATE_NOW=1100 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=300 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  [ "$(printf '%s' "$out" | cut -f8)" = 1 ] \
    || fail "a reading inside its maximum age was discarded: $out"

  out=$(FM_FLEET_STATE_NOW=2000 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=300 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f8)
  [ "$known" = 2 ] || fail "a reading past its maximum age was still reported as current: $out"
  pass "fleet status: a reading past its maximum age is shown as past rather than as current"
}

test_a_malformed_cached_reading_is_refused() {
  local out known
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  printf '1000\tnot-a-number\t0\t0\t0\t0\tsig\n' > "$STATE/.status-fleet-state"
  out=$(FM_FLEET_STATE_NOW=1010 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f8)
  [ "$known" = 0 ] || fail "a malformed cached reading was rendered as a real one"

  # A reading cached before work waiting on the captain got a field carries this
  # fleet's real signature in what is now the ready column. It must be refused
  # rather than read with its signature shifted into a count.
  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    printf "1000\t2\t0\t0\t0\t0\t%s\n" "$(_fm_fleet_ids "$2" | _fm_fleet_signature)"
  ' _ "$ROOT" "$STATE" > "$STATE/.status-fleet-state"
  out=$(FM_FLEET_STATE_NOW=1010 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f8)
  [ "$known" = 0 ] || fail "a reading in the earlier seven-field shape was rendered as a real one: $out"
  pass "fleet status: a malformed cached reading is refused"
}

# --- cost ------------------------------------------------------------------

# The renderer draws once a second and the canonical reader costs about a second
# per task, so the frame must never be the thing that calls it.
test_a_frame_never_calls_the_canonical_reader() {
  local calls
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  task two crew 'state: paused · source: status-log · upstream release'
  export FM_FLEET_TEST_CALLS="$CALLS"
  : > "$FM_FLEET_TEST_CALLS"

  # A claimed refresh is already in flight, so this frame may not start one.
  printf '' > "$STATE/.status-fleet-state.refreshing"
  FM_FLEET_STATE_NOW=$(date +%s) FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_WARM_TTL=600 \
    FM_FLEET_STATE_READER="$BINDIR/counting-crew-state" counts >/dev/null

  calls=$(wc -l < "$FM_FLEET_TEST_CALLS" | tr -d ' ')
  [ "$calls" = 0 ] \
    || fail "a single frame consulted the canonical reader $calls times; the frame must only read the cache"
  unset FM_FLEET_TEST_CALLS
  pass "fleet status: a frame reads the cache and never calls the canonical reader itself"
}

test_only_one_refresh_is_claimed_at_a_time() {
  local now
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  now=$(date +%s)
  bash -c '
    . "$1/bin/fm-status-cache-lib.sh"
    fm_status_claim_refresh "$2" "$3" 600 || exit 1
    fm_status_claim_refresh "$2" "$3" 600 && exit 1
    # A frame carries the clock it was stamped with, so the next caller can
    # reach a claim that was taken a shade LATER than its own now. That is a
    # claim someone just took, never an expired one; reading it as expired put
    # a second refresher on the same fleet.
    fm_status_claim_refresh "$2" "$(($3 - 1))" 600 && exit 1
    # A claim older than its window is reclaimable, so a refresher that died
    # without writing cannot wedge the field at unknown forever.
    fm_status_claim_refresh "$2" "$(($3 + 601))" 600 || exit 1
    exit 0
  ' _ "$ROOT" "$STATE/claim" "$now" \
    || fail "the refresh claim did not serialize one refresher and then release"
  pass "fleet status: exactly one refresh is claimed at a time, and a dead claim is reclaimable"
}

# An empty fleet is a real fleet state, and zero live workers is exactly the
# number the captain has to be able to trust. It was reported unknown forever
# because the two sides of the fleet signature hashed different bytes at zero
# records only, so the reading could never be recognized as covering this fleet -
# which also meant every frame re-forked a fold that could never be accepted.
test_a_zero_record_fleet_reports_a_trusted_zero() {
  local out waited
  reset_state

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  [ "$out" = $'0\t0\t0\t0\t0\t0\t0\t1\t0' ] \
    || fail "an empty fleet was not read as a trusted zero: $(printf '%s' "$out" | tr '\t' ' ')"

  # And end to end through the cache, the way a frame actually reaches it: the
  # first frame starts the fold, and a later frame accepts its reading.
  export FM_FLEET_TEST_CALLS="$CALLS"
  : > "$FM_FLEET_TEST_CALLS"
  FM_FLEET_STATE_READER="$BINDIR/counting-crew-state" counts >/dev/null
  waited=0
  while [ ! -f "$STATE/.status-fleet-state" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  out=$(FM_FLEET_STATE_READER="$BINDIR/counting-crew-state" counts)
  [ "$(printf "%s" "$out" | cut -f1-8)" = $'0\t0\t0\t0\t0\t0\t0\t1' ] \
    || fail "a cached empty-fleet reading was not accepted for the fleet it covered: $(printf '%s' "$out" | tr '\t' ' ')"
  unset FM_FLEET_TEST_CALLS
  pass "fleet status: a fleet of zero records reports a real zero rather than permanent placeholders"
}

# The canonical reader shells out to other tools, and one of them draining stdin
# must not be able to eat the ids the fold has not reached yet. A fold that ends
# early is refused (see the incomplete-fold case above), so the failure this
# guards against is the silent one: a short fold published as authoritative.
test_a_reader_that_drains_stdin_cannot_truncate_the_fold() {
  local out asked
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  task two crew 'state: working · source: pane · harness busy'
  task three crew 'state: paused · source: status-log · upstream release'
  task four crew 'state: blocked · source: status-log · needs a credential'
  export FM_FLEET_TEST_CALLS="$CALLS"
  : > "$FM_FLEET_TEST_CALLS"

  out=$(FM_FLEET_STATE_NO_CACHE=1 \
    FM_FLEET_STATE_READER="$BINDIR/stdin-draining-crew-state" counts)
  asked=$(wc -l < "$FM_FLEET_TEST_CALLS" | tr -d ' ')
  [ "$asked" = 4 ] \
    || fail "a reader that drained stdin swallowed the remaining ids; only $asked of 4 tasks were folded"
  [ "$out" = $'4\t2\t0\t0\t1\t1\t0\t1\t0' ] \
    || fail "a stdin-draining reader produced a short fold reported as complete: $(printf '%s' "$out" | tr '\t' ' ')"
  unset FM_FLEET_TEST_CALLS
  pass "fleet status: a canonical reader that drains stdin cannot truncate the fold or publish it short"
}

# The claim exists to make "at most one refresh in flight" true. A claim shorter
# than the refresh's own bound expires under a still-running fold and lets the
# next frame start a second reader over the same fleet - worst exactly when the
# fleet is already slow enough to need the bound.
test_the_refresh_claim_covers_the_whole_refresh_bound() {
  local now started
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  export FM_FLEET_TEST_CALLS="$CALLS"
  : > "$FM_FLEET_TEST_CALLS"
  now=$(date +%s)

  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    FM_FLEET_STATE_WAIT=90 FM_FLEET_STATE_WARM_TTL=10 \
      _fm_fleet_refresh_detached "$2/.status-fleet-state" "$2" "$3" "$4"
    # 40 seconds on, past the requested warm window but still well inside the
    # bound the in-flight fold is running under.
    FM_FLEET_STATE_WAIT=90 FM_FLEET_STATE_WARM_TTL=10 \
      _fm_fleet_refresh_detached "$2/.status-fleet-state" "$2" "$(($3 + 40))" "$4"
  ' _ "$ROOT" "$STATE" "$now" "$BINDIR/slow-crew-state"
  # Long enough for a second refresher to have entered the reader if one had
  # been started, and for the first to finish rather than outlive this case.
  sleep 4

  started=$(wc -l < "$FM_FLEET_TEST_CALLS" | tr -d ' ')
  [ "$started" = 1 ] \
    || fail "a second refresher was started underneath a still-running fold; the canonical reader was entered $started times"
  unset FM_FLEET_TEST_CALLS
  pass "fleet status: the refresh claim covers the whole refresh bound, so a slow fold is never doubled"
}

# The other direction: a claim must not outlive the work it protects. A fold that
# published is done, and holding the rest of its window would block the next
# refresh for no reason. A fold that published nothing keeps its claim, which is
# what paces the retry - and that claim still ages out on its own, so the field
# can never wedge at unknown.
test_a_published_refresh_releases_its_claim_and_a_silent_one_ages_out() {
  local waited
  reset_state
  task one crew 'state: working · source: pane · harness busy'

  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    _fm_fleet_refresh_detached "$2/.status-fleet-state" "$2" "$3" "$4"
  ' _ "$ROOT" "$STATE" "$(date +%s)" "$BINDIR/fake-crew-state"
  waited=0
  while [ ! -f "$STATE/.status-fleet-state" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$STATE/.status-fleet-state" ] || fail "the detached refresh never published a reading"
  waited=0
  while [ -f "$STATE/.status-fleet-state.refreshing" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ ! -f "$STATE/.status-fleet-state.refreshing" ] \
    || fail "a refresh that published its reading still held its claim afterwards"

  # A fold that published nothing keeps the claim, so the retry is paced rather
  # than re-forked every tick, and the claim is reclaimable once it ages out.
  rm -f "$STATE/.status-fleet-state"
  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    FM_FLEET_TEST_READER_FAIL=1 \
      _fm_fleet_refresh_detached "$2/.status-fleet-state" "$2" "$3" "$4"
    wait
  ' _ "$ROOT" "$STATE" "$(date +%s)" "$BINDIR/fake-crew-state"
  [ -f "$STATE/.status-fleet-state.refreshing" ] \
    || fail "a refresh that published nothing released its claim, so every tick would re-fork a reader"
  bash -c '
    . "$1/bin/fm-status-cache-lib.sh"
    fm_status_claim_refresh "$2" "$(($(date +%s) + 200))" 90 || exit 1
  ' _ "$ROOT" "$STATE/.status-fleet-state.refreshing" \
    || fail "a claim left behind by a refresher that wrote nothing was not reclaimable once aged out"
  pass "fleet status: a published refresh releases its claim, and a silent one is reclaimed by ageing out"
}

# --- liveness --------------------------------------------------------------

# The question the row exists to answer. A record is not a worker: the headline
# counts endpoints an agent is actually running on, and the records whose worker
# is gone are their own figure rather than being folded into the same number.
test_live_agents_and_stopped_records_are_separate_figures() {
  local out
  reset_state
  mkdir -p "$TMP_ROOT/case$FLEET_CASE/wt"
  endpoint_task busy live-1 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: working · source: pane · harness busy'
  # Alive but idle: no run, no busy pane, and the captain still has a worker.
  endpoint_task idle live-2 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: unknown · source: none · nothing attributed'
  endpoint_task gone dead-1 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: unknown · source: none · backend target gone'
  endpoint_task shed live-3 "$TMP_ROOT/case$FLEET_CASE/no-such-worktree" \
    'state: unknown · source: none · worktree gone (torn down?)'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_PROBE="$BINDIR/fake-probe" \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  # records working stopped validating paused attention ready finished known
  [ "$out" = $'4\t2\t2\t0\t0\t0\t0\t1\t0' ] \
    || fail "live agents and stopped records were not reported as separate figures: $(printf '%s' "$out" | tr '\t' ' ')"
  pass "fleet status: the headline counts live agents and stopped records carry their own figure"
}

# A worktree that is gone is decisive and is checked before the endpoint, so a
# record whose work no longer exists on disk can never be counted as a worker -
# and it costs no probe at all.
test_a_gone_worktree_is_stopped_without_probing_the_endpoint() {
  local out probes
  reset_state
  export FM_FLEET_TEST_PROBES="$TMP_ROOT/case$FLEET_CASE/probes"
  : > "$FM_FLEET_TEST_PROBES"
  endpoint_task shed live-1 "$TMP_ROOT/case$FLEET_CASE/no-such-worktree" \
    'state: working · source: pane · harness busy'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_PROBE="$BINDIR/fake-probe" \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  probes=$(wc -l < "$FM_FLEET_TEST_PROBES" | tr -d ' ')
  [ "$out" = $'1\t0\t1\t0\t0\t0\t0\t1\t0' ] \
    || fail "a record whose worktree is gone was not counted as stopped: $(printf '%s' "$out" | tr '\t' ' ')"
  [ "$probes" = 0 ] \
    || fail "a record whose worktree is gone still spent $probes endpoint probes"
  unset FM_FLEET_TEST_PROBES
  pass "fleet status: a record whose worktree is gone is stopped, and costs no endpoint probe"
}

# Overstating either figure is the failure this library exists to prevent, so a
# task whose liveness was never established is counted in neither. A remote
# secondmate's endpoint is on another host; an unverified backend's prober can
# only answer unknown; a record with no endpoint at all proves nothing either.
test_unproven_liveness_is_counted_in_neither_figure() {
  local out
  reset_state
  mkdir -p "$TMP_ROOT/case$FLEET_CASE/wt"
  fm_write_meta "$STATE/afar.meta" kind=crew backend=tmux window=live-1 \
    "worktree=$TMP_ROOT/case$FLEET_CASE/wt" remote_host=elsewhere
  printf '%s\n' 'state: unknown · source: remote-endpoint · unreachable' \
    > "$FLEET_FIX/afar"
  endpoint_task murky maybe-1 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: unknown · source: none · endpoint unreadable'
  fm_write_meta "$STATE/bare.meta" kind=crew backend=tmux \
    "worktree=$TMP_ROOT/case$FLEET_CASE/wt"
  printf '%s\n' 'state: unknown · source: none · no window recorded' \
    > "$FLEET_FIX/bare"

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_PROBE="$BINDIR/fake-probe" \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  [ "$out" = $'3\t0\t0\t0\t0\t0\t0\t1\t0' ] \
    || fail "liveness that was never established was still claimed: $(printf '%s' "$out" | tr '\t' ' ')"
  pass "fleet status: a task whose liveness is unproven is counted as neither alive nor stopped"
}

# A worker on a backend with no recovery classifier still exists. The busy pane
# reading the canonical reader already took is proof of life in its own right,
# so an unknown probe verdict never costs the captain a worker they have.
test_a_busy_worker_counts_as_alive_when_the_prober_cannot_answer() {
  local out
  reset_state
  mkdir -p "$TMP_ROOT/case$FLEET_CASE/wt"
  endpoint_task busy maybe-1 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: working · source: pane · harness busy'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_PROBE="$BINDIR/fake-probe" \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  [ "$out" = $'1\t1\t0\t0\t0\t0\t0\t1\t0' ] \
    || fail "a busy worker was lost because its backend has no recovery classifier: $(printf '%s' "$out" | tr '\t' ' ')"
  pass "fleet status: a busy worker counts as alive even when the endpoint prober cannot answer"
}

# The row once read "2 working" while one of two live workers had finished: its
# PR was green and it sat idle until the captain gave the merge word. Done work
# waits on the captain, or on nobody once its PR is merged or closed, and is
# never working, never a stopped worker when the agent has exited, and spends no
# endpoint probe.
test_finished_work_is_neither_working_nor_stopped() {
  local out probes
  reset_state
  mkdir -p "$TMP_ROOT/case$FLEET_CASE/wt"
  export FM_FLEET_TEST_PROBES="$TMP_ROOT/case$FLEET_CASE/probes"
  : > "$FM_FLEET_TEST_PROBES"
  endpoint_task busy live-1 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: working · source: pane · harness busy'
  endpoint_task review live-2 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: done · source: run-step · checks green: PR ready for review'
  endpoint_task branch dead-1 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: done · source: status-log · ready branch fm/x at abc123'
  printf 'kind=ship\nmode=local-only\n' >> "$STATE/branch.meta"
  endpoint_task landed live-4 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: done · source: run-step · run passed: PR merged'
  endpoint_task dropped dead-2 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: done · source: run-step · run passed: PR closed'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_PROBE="$BINDIR/fake-probe" \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  probes=$(wc -l < "$FM_FLEET_TEST_PROBES" | tr -d ' ')
  # records working stopped validating paused attention ready known
  [ "$out" = $'5\t1\t0\t0\t0\t0\t2\t1\t0' ] \
    || fail "finished work was counted as working or stopped: $(printf '%s' "$out" | tr '\t' ' ')"
  [ "$probes" = 1 ] \
    || fail "finished work spent endpoint probes: $probes probes for one unfinished task"
  unset FM_FLEET_TEST_PROBES
  pass "fleet status: finished work waits on the captain or on nobody, never working or stopped"
}

# `parked` alone does not say who owes the answer. A status-log needs-decision
# and a gate carrying the reader's whole human-decision component (an ask-user
# review finding) are questions put to firstmate, which ask-user-authority gives
# it to answer, so they need firstmate to act and never wait on the captain: on
# 2026-11-14 the bridge strip counted them as his decisions. Every other gate is
# the worker's or firstmate's turn and reads as working or stopped by liveness
# alone. Either way a parked task is not done, so a worker lost while it waits
# is still counted stopped.
test_a_workers_question_needs_firstmate_not_the_captain() {
  local out
  reset_state
  mkdir -p "$TMP_ROOT/case$FLEET_CASE/wt"
  endpoint_task owed live-1 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: parked · source: run-step · parked at review: 2 finding(s) · ask-user: authority decision · run: r1'
  endpoint_task asked dead-1 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: parked · source: status-log · needs-decision: pick a schema'
  endpoint_task review live-2 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: parked · source: run-step · parked at review: 2 finding(s) · run: r2'
  endpoint_task quoted live-3 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: parked · source: run-step · parked at review: ask-user: authority decision pending · run: r3'
  endpoint_task lost dead-2 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: parked · source: run-step · parked at fix_review · run: r4'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_PROBE="$BINDIR/fake-probe" \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  # records working stopped validating paused attention ready known
  [ "$out" = $'5\t2\t2\t0\t0\t2\t0\t1\t0' ] \
    || fail "a worker's question was not counted as firstmate's to act on: $(printf '%s' "$out" | tr '\t' ' ')"
  pass "fleet status: a worker's question or an ask-user finding needs firstmate, never the captain, and a lost parked worker is stopped"
}

# backlog_row <line>: append one row to this case's backlog, the home that owns
# $STATE, in the markdown shape tasks-axi writes.
backlog_row() {
  local file="$STATE/../data/backlog.md"
  mkdir -p "$STATE/../data"
  [ -e "$file" ] || printf '## In flight\n\n## Queued\n\n## Done\n' > "$file"
  python3 - "$file" "$1" <<'PY2'
import sys
path, row = sys.argv[1], sys.argv[2]
text = open(path).read()
before, after = text.split("## Done\n", 1)
if row.startswith("- [x]"):
    after = after + row + "\n"
else:
    before = before.rstrip("\n") + "\n" + row + "\n\n"
open(path, "w").write(before + "## Done\n" + after)
PY2
}

# The owner's calls are one list: every held decision that waits on him now,
# and every PR or ready branch waiting for the merge word whose task carries no
# open captain hold and is not finished work. An aged undated hold, a hold
# deferred to a date and one waiting on other work are never counted, and ready
# work under any of those holds is no merge call either.
test_the_owners_calls_are_live_decisions_and_ready_merges() {
  local out
  reset_state
  task green crew 'state: done · source: run-step · checks passed'
  task gated crew 'state: done · source: run-step · checks passed'
  task landed crew 'state: done · source: run-step · checks passed'
  task asked crew 'state: parked · source: status-log · needs-decision: pick a schema'
  task deferred crew 'state: done · source: run-step · checks passed'
  backlog_row '- [ ] pick-a - Pick a colour (repo: r) (kind: captain) (hold: choose red or blue) (hold-kind: captain)'
  backlog_row '- [ ] gated - Gated work (repo: r) (kind: ship) (hold: merge only after the launch call) (hold-kind: captain)'
  backlog_row '- [ ] later - Revisit later (repo: r) (kind: captain) (hold: later) (hold-kind: captain) (hold-until: 2099-01-01)'
  backlog_row '- [ ] waits - After other work (repo: r) (kind: captain) (blocked-by: other) (hold: after other) (hold-kind: captain)'
  backlog_row '- [ ] other - The other work (repo: r) (kind: ship)'
  backlog_row '- [ ] stale - An old call (repo: r) (kind: captain) (since 2020-01-01) (hold: old) (hold-kind: captain)'
  backlog_row '- [ ] deferred - Merge after the release (repo: r) (kind: ship) (hold: merge after the release) (hold-kind: captain) (hold-until: 2099-01-01)'
  backlog_row '- [ ] parked - Parked for later (repo: r) (kind: ship) (hold: someday) (hold-kind: future)'
  backlog_row '- [x] landed - Landed work (repo: r) (kind: ship) (done 2026-11-01)'

  out=$(FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2"' _ "$ROOT" "$STATE") \
    || fail "the owner's calls could not be read"
  assert_equals "$(printf 'decision\tpick-a\ndecision\tgated\nmerge\tgreen')" \
    "$out" "the owner's calls"

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_fleet_status_counts "$2" decisions' _ "$ROOT" "$STATE")
  # records working stopped validating paused attention ready known age decisions
  [ "$out" = $'5\t0\t0\t0\t0\t1\t3\t1\t0\t2' ] \
    || fail "the fold did not count the owner's calls: $(printf '%s' "$out" | tr '\t' ' ')"

  # A caller that already read the buckets and the backlog passes them in, and
  # gets the same calls without a second read.
  printf 'green\tready\ngated\tready\nlanded\tready\ndeferred\tready\nasked\tdecision\n' > "$STATE/../buckets"
  FM_HOME="$STATE/.." FM_STATE_OVERRIDE="$STATE" bash "$ROOT/bin/fm-fleet-snapshot.sh" --backlog > "$STATE/../backlog.json" \
    || fail "the backlog snapshot failed"
  out=$(FM_FLEET_STATE_READER="$BINDIR/no-such-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2" "$3" "$4"' _ "$ROOT" "$STATE" \
    "$STATE/../buckets" "$STATE/../backlog.json") || fail "the owner's calls from given readings failed"
  assert_equals "$(printf 'decision\tpick-a\ndecision\tgated\nmerge\tgreen')" \
    "$out" "the owner's calls from given readings"

  # A task the reader cannot answer for makes no list at all.
  task lost crew 'state: done · source: run-step · checks passed'
  rm -f "$FLEET_FIX/lost"
  if FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2"' _ "$ROOT" "$STATE" >/dev/null; then
    fail "a task that could not be read still gave a list of calls"
  fi
  pass "fleet status: the owner's calls are his live held decisions and the ready merges no captain hold holds, nothing else"
}

# A home whose backlog is not markdown (here Beads, answered by a stand-in for
# tasks-axi) keeps its calls: the held decisions come through the adapter, with
# the same live rule, and a backlog the adapter cannot read is no list at all.
test_the_owners_calls_come_through_a_non_markdown_adapter() {
  local out dir stamp
  reset_state
  dir="$TMP_ROOT/case$FLEET_CASE/beads-axi"
  mkdir -p "$dir"
  printf 'backend = "beads"\n' > "$STATE/../.tasks.toml"
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  task green crew 'state: done · source: run-step · checks passed'
  task held-work crew 'state: done · source: run-step · checks passed'
  cat > "$dir/tasks-axi" <<SH
#!/usr/bin/env bash
[ -z "\${TASKS_AXI_FILE:-}" ] || exit 3
[ ! -e "$STATE/../list-fails" ] || [ "\$1" != list ] || exit 1
case "\$1" in
  list)
    printf 'count: 5 of 5 total\n'
    printf 'tasks[5]{id,state,kind,repo,title,hold_kind,hold_reason,hold_until,blocked_by,created,body}:\n'
    printf '  beads-call,queued,captain,r,"Pick a colour, red or blue",captain,"choose red or blue",-,none,2026-01-01,"Captain hold set: $stamp\\\\nwhy"\n'
    printf '  held-work,in_flight,ship,r,"Held work",captain,"merge after the call",-,none,2026-01-01,"Captain hold set: $stamp\\\\nwhy"\n'
    printf '  old-call,queued,captain,r,"An old call",captain,"old",-,none,2020-01-01,""\n'
    printf '  waits,queued,captain,r,"After other work",captain,"after other",-,other,2026-01-01,"Captain hold set: $stamp\\\\nwhy"\n'
    printf '  other,queued,ship,r,"The other work",-,-,-,none,2026-01-01,""\n'
    printf 'help[1]:\n  - Run \`tasks-axi show <id> --full\` for full notes on a task\n'
    ;;
  *)
    printf 'unexpected tasks-axi %s: the listing alone carries every field\n' "\$1" >&2
    exit 9
    ;;
esac
SH
  chmod +x "$dir/tasks-axi"
  out=$(PATH="$dir:$PATH" FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2"' _ "$ROOT" "$STATE") \
    || fail "the owner's calls could not be read through a non-markdown adapter"
  assert_equals "$(printf 'decision\tbeads-call\ndecision\theld-work\nmerge\tgreen')" "$out" \
    "the owner's calls through a non-markdown adapter"
  touch "$STATE/../list-fails"
  if PATH="$dir:$PATH" FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2"' _ "$ROOT" "$STATE" >/dev/null; then
    fail "a backlog the adapter could not read still gave a list of calls"
  fi
  pass "fleet status: the owner's calls come through a non-markdown adapter, and an unreadable backlog is no list"
}

# A second mate's PRs are the owner's calls too. They are read from what the mate
# already reports to this home, its parent channel state/<mate>.status, which a
# local mate appends to and a remote mate's reply mirror copies into: the lines
# its scripts write list a child's PR once it is done and drop it once merged,
# the mate's own prose never counts, and a PR its forge reports merged or
# closed is dropped.
test_a_second_mates_ready_prs_are_the_owners_calls() {
  local out reader forge
  reset_state
  forge="$TMP_ROOT/case$FLEET_CASE/forge"
  reader="$TMP_ROOT/case$FLEET_CASE/pr-reader"
  : > "$forge"
  cat > "$reader" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$forge"
case "\$1" in
  */pull/69) echo closed ;;
  */pull/70) echo merged ;;
  */pull/71) exit 1 ;;
  *) echo open ;;
esac
SH
  chmod +x "$reader"
  task green crew 'state: done · source: run-step · checks passed'
  backlog_row '- [ ] pick-a - Pick a colour (repo: r) (kind: captain) (hold: choose red or blue) (hold-kind: captain)'
  # A local second mate: its scripts append straight into this home.
  fm_write_meta "$STATE/near.meta" kind=secondmate mode=secondmate window=tmux:near home=/homes/near
  cat > "$STATE/near.status" <<'LOG'
working [at=100]: corr=aa11 started child-a and child-b
done [key=child-outcome-child-a-done-0f0e0d0c] [at=110]: child child-a done: checks green pr=https://github.com/o/r/pull/101 mode=no-mistakes yolo=off
done [key=child-outcome-child-b-done-1a2b3c4d] [at=120]: child child-b done: PR https://github.com/o/r/pull/102 checks green pr=https://github.com/o/r/pull/102 mode=no-mistakes yolo=off
done [key=child-a] [at=121]: the child-a PR is ready for the owner's merge word: https://github.com/o/r/pull/103
done [key=merged-child-a] [at=130]: merged child-a https://github.com/o/r/pull/101 external
LOG
  # A remote second mate: its reply mirror copies its channel into this home.
  fm_write_meta "$STATE/far.meta" kind=secondmate mode=secondmate window=remote:far home=/homes/far \
    remote_host=far-host remote_root=/far/firstmate remote_backend=herdr
  cat > "$STATE/far.status" <<'LOG'
done [key=child-outcome-child-c-done-5e6f7a8b] [at=200]: child child-c done: checks green pr=https://github.com/o/r/pull/68 mode=no-mistakes yolo=off
done [key=child-outcome-child-d-done-5e6f7a8b] [at=210]: child child-d done: checks green pr=https://github.com/o/r/pull/69 mode=no-mistakes yolo=off
done [key=child-outcome-child-e-done-5e6f7a8b] [at=220]: child child-e done: checks green pr=https://github.com/o/r/pull/70 mode=no-mistakes yolo=off
done [key=child-outcome-child-f-done-5e6f7a8b] [at=230]: child child-f done: checks green pr=https://github.com/o/r/pull/71 mode=no-mistakes yolo=off
LOG

  out=$(FM_SECONDMATE_PR_READER="$reader" FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2"' _ "$ROOT" "$STATE") \
    || fail "the owner's calls could not be read with second mates"
  assert_equals "$(printf 'decision\tpick-a\nmerge\tgreen\nmate-merge\tfar\tchild-c\thttps://github.com/o/r/pull/68\t200\nmate-merge\tfar\tchild-f\thttps://github.com/o/r/pull/71\t230\nmate-merge\tnear\tchild-b\thttps://github.com/o/r/pull/102\t120')" \
    "$out" "the owner's calls with second mates' PRs"
  assert_equals "$(LC_ALL=C sort "$forge" | tr '\n' ' ')" \
    "https://github.com/o/r/pull/102 https://github.com/o/r/pull/68 https://github.com/o/r/pull/69 https://github.com/o/r/pull/70 https://github.com/o/r/pull/71 " \
    "the forge reads"

  # The forge is asked again only for a PR still open or unread, and only once
  # its reading is old; a merged or closed PR is not asked about again, unless
  # a closed one's child reports done on it again, as it would once reopened.
  : > "$forge"
  FM_SECONDMATE_PR_READER="$reader" FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2"' _ "$ROOT" "$STATE" >/dev/null \
    || fail "the owner's calls could not be read again"
  assert_equals "$(cat "$forge")" "" "a fresh reading asked the forge again"
  FM_SECONDMATE_PR_TTL=0 FM_SECONDMATE_PR_READER="$reader" FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2"' _ "$ROOT" "$STATE" >/dev/null \
    || fail "the owner's calls could not be read once their readings were old"
  assert_equals "$(LC_ALL=C sort "$forge" | tr '\n' ' ')" \
    "https://github.com/o/r/pull/102 https://github.com/o/r/pull/68 https://github.com/o/r/pull/71 " \
    "an old reading was not read again, or a merged or closed one was"
  sed -i.bak 's|\*/pull/69) echo closed ;;|*/pull/69) echo open ;;|' "$reader" && rm -f "$reader.bak"
  : > "$forge"
  out=$(FM_SECONDMATE_PR_TTL=0 FM_SECONDMATE_PR_READER="$reader" FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2"' _ "$ROOT" "$STATE") \
    || fail "the owner's calls could not be read with a closed PR reopened"
  assert_not_contains "$out" "pull/69" "a closed PR was listed again with no new done outcome"
  assert_not_contains "$(cat "$forge")" "pull/69" "a closed PR was read again with no new done outcome"
  local again
  again=$(( $(date +%s) + 1 ))
  printf 'done [key=child-outcome-child-d-done-9a8b7c6d] [at=%s]: child child-d done: checks green again pr=https://github.com/o/r/pull/69 mode=no-mistakes yolo=off\n' \
    "$again" >> "$STATE/far.status"
  out=$(FM_SECONDMATE_PR_TTL=0 FM_SECONDMATE_PR_READER="$reader" FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2"' _ "$ROOT" "$STATE") \
    || fail "the owner's calls could not be read once a reopened PR was reported done again"
  assert_contains "$out" "$(printf 'mate-merge\tfar\tchild-d\thttps://github.com/o/r/pull/69\t%s' "$again")" \
    "a closed PR that was reopened and reported done again is not listed again"
  sed -i.bak 's|\*/pull/69) echo open ;;|*/pull/69) echo closed ;;|' "$reader" && rm -f "$reader.bak"
  FM_SECONDMATE_PR_TTL=0 FM_SECONDMATE_PR_READER="$reader" FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_owner_calls "$2"' _ "$ROOT" "$STATE" >/dev/null \
    || fail "the owner's calls could not be read once the PR was closed again"

  # The status bar and the bridge strip count them as ready to merge, and the
  # first one is the strip's call when nothing else waits.
  out=$(FM_SECONDMATE_PR_READER="$reader" FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_fleet_status_counts "$2" decisions' _ "$ROOT" "$STATE")
  [ "$(printf '%s' "$out" | cut -f7,10 | tr '\t' ' ')" = "5 1" ] \
    || fail "the fold did not count the second mates' PRs: $(printf '%s' "$out" | tr '\t' ' ')"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$STATE/../data/backlog.md"
  out=$(FM_SECONDMATE_PR_READER="$reader" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; _fm_fleet_calls_fold "$2" -' _ "$ROOT" "$STATE") \
    || fail "the calls could not be folded with second mates"
  assert_equals "$(printf '%s' "$out" | tr '\t' '|')" "3|0|merge|far:child-c|child-c from far" \
    "the strip's first call for a second mate's PR"
  pass "fleet status: a second mate's ready PRs are the owner's calls, local and remote, dropped once merged or closed"
}

# A second mate's PR waits on the owner only while its child's newest outcome
# is done, and only when that mate does not merge it itself: a PR registration
# alone, or a done outcome carrying yolo=on (AGENTS.md: with yolo on, firstmate
# merges green, in-scope work itself), is not listed, while a yolo=off done
# outcome is. A later failed outcome drops the child's PR, as this home's own
# work leaves the merge list once its task no longer reads done, and a later
# done outcome on a new PR replaces the old one rather than listing both. A
# merge drops the PR for good: a done outcome for it that reaches this home
# after the merge does not list it again, and a PR reported done twice is
# listed once, even when its forge cannot be read.
test_a_second_mates_pr_waits_on_the_owner_only_when_done_and_not_yolo() {
  local out reader
  reset_state
  reader="$TMP_ROOT/case$FLEET_CASE/pr-reader"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"
  fm_write_meta "$STATE/far.meta" kind=secondmate mode=secondmate window=remote:far home=/homes/far remote_host=far-host
  cat > "$STATE/far.status" <<'LOG'
done [key=child-pr-reg] [at=100]: child reg PR ready: https://github.com/o/r/pull/80 mode=no-mistakes yolo=off
done [key=child-outcome-auto-done-11111111] [at=110]: child auto done: checks green pr=https://github.com/o/r/pull/81 mode=no-mistakes yolo=on
done [key=child-outcome-held-done-22222222] [at=120]: child held done: checks green pr=https://github.com/o/r/pull/82 mode=no-mistakes yolo=off
done [key=child-pr-c] [at=130]: child c PR ready: https://github.com/o/r/pull/68 mode=no-mistakes yolo=off
done [key=merged-c] [at=140]: merged c https://github.com/o/r/pull/68 external
done [key=child-outcome-c-done-33333333] [at=150]: child c done: checks green pr=https://github.com/o/r/pull/68 mode=no-mistakes yolo=off
done [key=child-outcome-twice-done-44444444] [at=160]: child twice done: checks green pr=https://github.com/o/r/pull/83 mode=no-mistakes yolo=off
done [key=child-outcome-twice-done-55555555] [at=170]: child twice done: checks green again pr=https://github.com/o/r/pull/83 mode=no-mistakes yolo=off
done [key=child-outcome-redo-done-66666666] [at=180]: child redo done: checks green pr=https://github.com/o/r/pull/84 mode=no-mistakes yolo=off
failed [key=child-outcome-redo-failed-77777777] [at=190]: child redo failed: checks red after the asked change pr=https://github.com/o/r/pull/84 mode=no-mistakes yolo=off
done [key=child-outcome-moved-done-88888888] [at=200]: child moved done: checks green pr=https://github.com/o/r/pull/85 mode=no-mistakes yolo=off
done [key=child-outcome-moved-done-99999999] [at=210]: child moved done: checks green on a new PR pr=https://github.com/o/r/pull/86 mode=no-mistakes yolo=off
LOG
  out=$(FM_SECONDMATE_PR_READER="$reader" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_secondmate_ready_prs "$2"' _ "$ROOT" "$STATE") \
    || fail "a second mate's ready PRs could not be read"
  assert_equals "$(printf 'mate-merge\tfar\theld\thttps://github.com/o/r/pull/82\t120\nmate-merge\tfar\ttwice\thttps://github.com/o/r/pull/83\t170\nmate-merge\tfar\tmoved\thttps://github.com/o/r/pull/86\t210')" \
    "$out" "only a child's newest done, yolo=off, unmerged PR is listed, once, with when its newest done outcome was reported"
  pass "fleet status: a second mate's PR waits on the owner only while its child's newest outcome is done and not under yolo, and a merged one stays dropped"
}

# The bridge strip shows "decisions for you" and "ready to merge" as two lamps, so
# it asks for the decisions inside ready as a tenth field. The status bar's nine
# fields are unchanged, and a reading taken before the owner's calls supplied
# the split is never split by guesswork.
test_decisions_are_counted_apart_inside_ready() {
  local out now=1000
  reset_state
  task asked crew 'state: parked · source: status-log · needs-decision: pick a schema'
  task green crew 'state: done · source: run-step · checks passed'
  backlog_row '- [ ] pick-a - Pick a colour (repo: r) (kind: captain) (hold: choose red or blue) (hold-kind: captain)'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  [ "$out" = $'2\t0\t0\t0\t0\t1\t2\t1\t0' ] \
    || fail "the status bar's fields changed shape: $(printf '%s' "$out" | tr '\t' ' ')"
  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_fleet_status_counts "$2" decisions' _ "$ROOT" "$STATE")
  [ "$out" = $'2\t0\t0\t0\t0\t1\t2\t1\t0\t1' ] \
    || fail "the decisions inside ready were not counted apart: $(printf '%s' "$out" | tr '\t' ' ')"

  # Cached readings from before the split, and from before the owner's calls
  # supplied it: still good for the status bar, no reading at all for a caller
  # that needs the split, and refreshed at once.
  local old
  for old in '' $'\t2'; do
    bash -c '
      . "$1/bin/fm-fleet-status-lib.sh"
      printf "%s\t0\t0\t0\t0\t0\t3\t%s%s" "$3" "$(_fm_fleet_ids "$2" | _fm_fleet_signature)" "$4"
    ' _ "$ROOT" "$STATE" "$now" "$old" > "$STATE/.status-fleet-state"
    rm -f "$STATE/.status-fleet-state.refreshing"
    out=$(FM_FLEET_STATE_NOW=$now FM_FLEET_STATE_READER="$BINDIR/no-such-crew-state" \
      bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_fleet_status_counts "$2" decisions' _ "$ROOT" "$STATE")
    [ "$out" = $'2\t0\t0\t0\t0\t0\t0\t0\t0\t0' ] \
      || fail "a reading from before the split was split by guesswork: $(printf '%s' "$out" | tr '\t' ' ')"
    [ -e "$STATE/.status-fleet-state.refreshing" ] \
      || fail "a reading from before the split did not start a refresh"
    rm -f "$STATE/.status-fleet-state.refreshing"
    out=$(FM_FLEET_STATE_NOW=$now FM_FLEET_STATE_READER="$BINDIR/no-such-crew-state" counts)
    [ "$out" = $'2\t0\t0\t0\t0\t0\t3\t1\t0' ] \
      || fail "a reading from before the split was lost to the status bar: $(printf '%s' "$out" | tr '\t' ' ')"
  done
  pass "fleet status: decisions are counted apart inside ready, and an older reading is never split by guesswork"
}

# AGENTS.md section 8: a status line is a wake EVENT, not current state. A task
# that paused and then resumed leaves `paused:` as the last line of its log
# forever, and the old row counted it as parked for as long as that line sat
# there. The fold reads the reconciled current state instead, and never the log.
test_a_resolved_pause_is_not_counted_as_paused() {
  local out
  reset_state
  mkdir -p "$TMP_ROOT/case$FLEET_CASE/wt"
  endpoint_task resumed live-1 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: working · source: pane · harness busy'
  printf '%s\n' 'working: started' 'paused: waiting on an upstream release' \
    > "$STATE/resumed.status"
  endpoint_task waiting live-2 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: paused · source: status-log · upstream release'
  printf '%s\n' 'paused: waiting on an upstream release' > "$STATE/waiting.status"
  # And the mirror image: a log whose last line reads resolved, over a task the
  # canonical reader still reports as blocked, stays counted for attention.
  endpoint_task stuck live-3 "$TMP_ROOT/case$FLEET_CASE/wt" \
    'state: blocked · source: status-log · needs a credential'
  printf '%s\n' 'blocked: needs a credential' 'resolved: [key=cred] supplied' \
    > "$STATE/stuck.status"

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_PROBE="$BINDIR/fake-probe" \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  # Only the resumed worker is working: the paused and blocked ones have live
  # agents too, but each is counted in the field its state names, never twice.
  [ "$out" = $'3\t1\t0\t0\t1\t1\t0\t1\t0' ] \
    || fail "paused and attention were read from the status log rather than the reconciled state: $(printf '%s' "$out" | tr '\t' ' ')"
  pass "fleet status: paused and attention follow the reconciled current state, not the last status line"
}

# After a run of PR-ready work the row read "1 waiting for you" for a ship whose
# worker had only committed its build: no PR existed and nothing waited on the
# captain, because it was firstmate's turn to send the work into validation. A
# status-log done waits on the captain only when the delivery contract reads it
# as the ready report - a PR that is green, or a ready branch or PR in the modes
# whose done is the ready report. A pre-validation handoff, and a scout report
# that firstmate reads first, are firstmate's turn: no worker is busy on them,
# so they count in no figure, without an endpoint probe and never as stopped.
test_a_done_waits_on_the_captain_only_when_it_is_the_ready_report() {
  local out probes wt
  reset_state
  wt="$TMP_ROOT/case$FLEET_CASE/wt"
  mkdir -p "$wt"
  export FM_FLEET_TEST_PROBES="$TMP_ROOT/case$FLEET_CASE/probes"
  : > "$FM_FLEET_TEST_PROBES"
  endpoint_task built dead-1 "$wt" \
    'state: done · source: status-log · committed 1a2b3c4 on fm/built'
  printf 'kind=ship\nmode=no-mistakes\n' >> "$STATE/built.meta"
  endpoint_task green live-1 "$wt" \
    'state: done · source: status-log · PR https://github.com/o/r/pull/7 checks green · run still monitoring PR'
  printf 'kind=ship\nmode=no-mistakes\n' >> "$STATE/green.meta"
  endpoint_task review live-2 "$wt" \
    'state: done · source: run-step · checks green: PR ready for review · run: r1'
  endpoint_task branch dead-2 "$wt" \
    'state: done · source: status-log · ready branch fm/branch at 5d6e7f8'
  printf 'kind=ship\nmode=local-only\n' >> "$STATE/branch.meta"
  endpoint_task landed live-3 "$wt" \
    'state: done · source: run-step · run passed: PR merged · run: r2'
  endpoint_task report dead-3 "$wt" \
    'state: done · source: status-log · report at data/report/report.md'
  printf 'kind=scout\n' >> "$STATE/report.meta"

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_PROBE="$BINDIR/fake-probe" \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  probes=$(wc -l < "$FM_FLEET_TEST_PROBES" | tr -d ' ')
  unset FM_FLEET_TEST_PROBES
  # records working stopped validating paused attention ready known
  [ "$out" = $'6\t0\t0\t0\t0\t0\t3\t1\t0' ] \
    || fail "a done that is firstmate's turn was counted as waiting for the captain: $(printf '%s' "$out" | tr '\t' ' ')"
  [ "$probes" = 0 ] \
    || fail "finished work spent endpoint probes: $probes"
  pass "fleet status: a done waits on the captain only when it is the ready report, and firstmate's turn counts in no figure"
}

# Under load the out-of-band fold can miss its bound for longer than a reading
# lives, and the row used to fall back to "workers unknown" with five workers
# running. The last good reading now stands in, marked as a past reading with
# its age, while a refresh keeps being tried in the background. Unknown is left
# for a home that has never had a good reading at all.
test_under_load_the_last_good_reading_stands_in_for_unknown() {
  local out reader
  reset_state
  reader="$BINDIR/no-such-crew-state"
  task one crew 'state: working · source: pane · harness busy'

  # The reader does not exist, so a refresh a frame starts can never publish
  # over the reading this case seeds by hand. No reading has been taken yet, so
  # the row is unknown.
  out=$(FM_FLEET_STATE_NOW=1000 FM_FLEET_STATE_READER="$reader" counts)
  [ "$(printf '%s' "$out" | cut -f8)" = 0 ] \
    || fail "a home with no good reading yet claimed one: $(printf '%s' "$out" | tr '\t' ' ')"

  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    _fm_fleet_collect "$2" 1000 "$3" > "$2/.status-fleet-state"
  ' _ "$ROOT" "$STATE" "$BINDIR/fake-crew-state"
  rm -f "$STATE/.status-fleet-state.refreshing"

  # The reading is long past its maximum age and no refresh has landed, so
  # the last good counts stand in, marked old with their age.
  out=$(FM_FLEET_STATE_NOW=2000 FM_FLEET_STATE_TTL=60 FM_FLEET_STATE_MAX_AGE=300 \
    FM_FLEET_STATE_READER="$reader" counts)
  [ "$out" = $'1\t1\t0\t0\t0\t0\t0\t2\t1000' ] \
    || fail "an aged reading under load was not shown as the last good one: $(printf '%s' "$out" | tr '\t' ' ')"
  [ -e "$STATE/.status-fleet-state.refreshing" ] \
    || fail "showing the last good reading did not keep a refresh going"

  # A dispatch while no refresh lands changes the fleet; the last good counts
  # still stand in, beside the current record count.
  task two crew 'state: paused · source: status-log · upstream release'
  out=$(FM_FLEET_STATE_NOW=1010 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=600 \
    FM_FLEET_STATE_READER="$reader" counts)
  [ "$out" = $'2\t1\t0\t0\t0\t0\t0\t2\t10' ] \
    || fail "a reading for the fleet before a dispatch was not shown as the last good one: $(printf '%s' "$out" | tr '\t' ' ')"
  pass "fleet status: under load the last good reading stands in, marked old, and unknown means never read"
}

# --- the owner's calls between readings ---------------------------------------

calls_signal() {
  bash -c '. "$1/bin/fm-owner-calls-signal-lib.sh"; fm_owner_calls_signal "$2"' _ "$ROOT" "$STATE"
}

test_every_command_that_changes_a_call_moves_the_calls_signal() {
  local home before
  reset_state
  home=$(cd "$STATE/.." && pwd)
  backlog_row '- [ ] pick-a - Pick a colour (repo: r) (kind: captain) (hold: choose red or blue) (hold-kind: captain)'
  touch "$STATE/.afk"   # the inbox then rings no primary session
  before=$(calls_signal)
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" list >/dev/null || fail "the backlog could not be listed"
  assert_equals "$(calls_signal)" "$before" "reading the backlog moved the calls signal"
  FM_HOME="$home" bash "$ROOT/bin/fm-captain-hold.sh" open pick-a >/dev/null 2>&1
  assert_equals "$(calls_signal)" "$before" "asking whether a call is open moved the calls signal"
  FM_HOME="$home" bash "$ROOT/bin/fm-captain-hold.sh" reconcile list >/dev/null 2>&1
  assert_equals "$(calls_signal)" "$before" "listing the pending reconcile requests moved the calls signal"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" hold pick-a --until 2099-01-01 >/dev/null \
    || fail "the backlog write failed"
  [ "$(calls_signal)" != "$before" ] || fail "a backlog write through fm-tasks-axi.sh did not move the calls signal"
  before=$(calls_signal)
  # The stand-in adapter is not one the captain-hold contract accepts, so the
  # hold is refused; a call it may have touched still moves the signal.
  FM_HOME="$home" bash "$ROOT/bin/fm-captain-hold.sh" hold pick-a --reason 'choose red or blue' >/dev/null 2>&1
  [ "$(calls_signal)" != "$before" ] || fail "fm-captain-hold.sh hold did not move the calls signal"
  before=$(calls_signal)
  FM_HOME="$home" bash "$ROOT/bin/fm-inbox.sh" note "Answer for Pick a colour: red" >/dev/null 2>&1 \
    || fail "the note could not be saved"
  [ "$(calls_signal)" != "$before" ] || fail "a note to Starship did not move the calls signal"
  before=$(calls_signal)
  backlog_row '- [ ] name-b - Name the shop (repo: r) (kind: captain) (hold: pick a name) (hold-kind: captain)'
  [ "$(calls_signal)" != "$before" ] || fail "a write straight to the markdown backlog did not move the calls signal"
  pass "fleet status: every command that changes a call moves the calls signal, and a read does not"
}

# calls_frame: the strip's frame from the cache, the worker reading's own
# refresh an hour away and a reader that records any call made to it.
calls_frame() {
  FM_FLEET_STATE_TTL=3600 FM_FLEET_STATE_MAX_AGE=3600 \
    FM_FLEET_STATE_READER="$BINDIR/counting-crew-state" FM_FLEET_TEST_CALLS="$CALLS" \
    bash -c '. "$1/bin/fm-fleet-status-lib.sh"; fm_fleet_status_counts "$2" strip' _ "$ROOT" "$STATE"
}

test_the_owners_calls_follow_their_signal_between_readings() {
  local out reading waited
  reset_state
  task green crew 'state: done · source: run-step · checks passed'
  backlog_row '- [ ] pick-a - Pick a colour (repo: r) (kind: captain) (hold: choose red or blue) (hold-kind: captain)'
  backlog_row '- [ ] name-b - Name the shop (repo: r) (kind: captain) (hold: pick a name) (hold-kind: captain)'
  FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    _fm_fleet_collect "$2" "$(date +%s)" "$3" > "$2/.status-fleet-state"
  ' _ "$ROOT" "$STATE" "$BINDIR/fake-crew-state" || fail "the fleet could not be read"
  reading=$(cat "$STATE/.status-fleet-state")
  : > "$CALLS"
  out=$(calls_frame)
  # ... ready known age decisions failed lost night kind id title signal
  assert_equals "$(printf '%s' "$out" | cut -f7,10,14,15,17 | tr '\t' ' ')" "3 2 decision pick-a $(calls_signal)" \
    "the reading's own calls"
  sed "s/^\(- \[ \] pick-a - .*\)\$/\1 (hold-until: 2099-01-01)/" "$STATE/../data/backlog.md" > "$STATE/../backlog.new"
  mv "$STATE/../backlog.new" "$STATE/../data/backlog.md"
  out=$(calls_frame)
  assert_equals "$(printf '%s' "$out" | cut -f14,15 | tr '\t' ' ')" "decision pick-a" \
    "the reading's calls stand until the calls are read again"
  [ "$(printf '%s' "$out" | cut -f17)" != "$(calls_signal)" ] \
    || fail "calls read before the change were marked as current"
  waited=0
  while [ ! -s "$STATE/.status-fleet-calls" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  out=$(calls_frame)
  assert_equals "$(printf '%s' "$out" | cut -f7,10,14,15,16,17 | tr '\t' ' ')" \
    "2 1 decision name-b Name the shop $(calls_signal)" "the calls were not caught up on their own"
  assert_equals "$(cat "$STATE/.status-fleet-state")" "$reading" "the worker reading was refreshed for a call"
  assert_equals "$(cat "$CALLS")" "" "the canonical reader was asked about a worker for a call"
  # Calls read for other ready work are never shown for this reading.
  printf '%s' "$reading" | awk -F'\t' 'BEGIN { OFS = "\t" } { $NF = "green other"; print }' \
    | tr -d '\n' > "$STATE/.status-fleet-state"
  assert_equals "$(calls_frame | cut -f14,15 | tr '\t' ' ')" "decision pick-a" \
    "calls read for other ready work were shown"
  pass "fleet status: the owner's calls follow their signal between readings, without refreshing the workers"
}

# The calls-only refresh runs in a fresh shell, and must title the first call
# just as the full fold does: from the task's recorded outcome when its backlog
# row has no title.
test_the_calls_only_fold_titles_a_call_from_its_recorded_outcome() {
  local out
  reset_state
  fm_write_meta "$STATE/green.meta" kind=crew "outcome=Cups sorted by colour"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$STATE/../data/backlog.md"
  out=$(bash -c '. "$1/bin/fm-fleet-status-lib.sh"; _fm_fleet_calls_fold "$2" green' _ "$ROOT" "$STATE") \
    || fail "the calls could not be folded"
  assert_equals "$(printf '%s' "$out" | cut -f3-5 | tr '\t' ' ')" "merge green Cups sorted by colour" \
    "the calls-only fold did not title the call from its outcome"
  pass "fleet status: the calls-only fold titles a call from its recorded outcome"
}

test_finished_work_is_neither_working_nor_stopped
test_under_load_the_last_good_reading_stands_in_for_unknown
test_a_done_waits_on_the_captain_only_when_it_is_the_ready_report
test_a_workers_question_needs_firstmate_not_the_captain
test_the_owners_calls_are_live_decisions_and_ready_merges
test_the_owners_calls_come_through_a_non_markdown_adapter
test_a_second_mates_ready_prs_are_the_owners_calls
test_a_second_mates_pr_waits_on_the_owner_only_when_done_and_not_yolo
test_decisions_are_counted_apart_inside_ready
test_canonical_states_fold_into_the_six_fields
test_records_are_counted_apart_from_live_workers
test_an_incomplete_fold_is_refused_rather_than_published_short
test_a_broken_reader_never_becomes_an_idle_fleet
test_a_reading_for_another_fleet_is_not_current
test_a_changed_fleet_starts_a_refresh_without_waiting_for_the_ttl
test_a_reading_that_has_aged_out_is_not_current
test_a_malformed_cached_reading_is_refused
test_a_frame_never_calls_the_canonical_reader
test_only_one_refresh_is_claimed_at_a_time
test_a_zero_record_fleet_reports_a_trusted_zero
test_a_reader_that_drains_stdin_cannot_truncate_the_fold
test_the_refresh_claim_covers_the_whole_refresh_bound
test_a_published_refresh_releases_its_claim_and_a_silent_one_ages_out
test_live_agents_and_stopped_records_are_separate_figures
test_a_gone_worktree_is_stopped_without_probing_the_endpoint
test_unproven_liveness_is_counted_in_neither_figure
test_a_busy_worker_counts_as_alive_when_the_prober_cannot_answer
test_a_resolved_pause_is_not_counted_as_paused
test_every_command_that_changes_a_call_moves_the_calls_signal
test_the_owners_calls_follow_their_signal_between_readings
test_the_calls_only_fold_titles_a_call_from_its_recorded_outcome
