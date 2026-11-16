#!/usr/bin/env bash
# The three places the owner reads the fleet - the bridge strip, the status bar
# and the Factory pane's count line - read one shared reading
# (fm_fleet_status_counts `overview` in bin/fm-fleet-status-lib.sh) and say
# the same thing in the same words (docs/status-bar.md "Fleet words").
#
# One fixture fleet goes in; each surface renders it and every shared figure
# is checked word for word on all three. A fixture reader stands in for
# bin/fm-crew-state.sh, a fixture prober for the endpoint classifier, and a
# snapshot built from the same fixture for the Factory pane's own reading, so no
# crew, pane, pipeline or Herdr server is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-overview)
BINDIR="$TMP_ROOT/bin"
mkdir -p "$BINDIR"
fm_install_markdown_tasks_axi "$TMP_ROOT/axibin"
export PATH="$TMP_ROOT/axibin:$PATH"
NOW=1794643200   # 2026-11-14T08:00:00Z
export TZ=UTC FM_FACTORY_NOW=$NOW FM_FACTORY_PEEK='' FM_SNAPSHOT_NOW=2026-11-14T08:00:00Z

cat > "$BINDIR/fake-crew-state" <<'SH'
#!/usr/bin/env bash
[ -f "$FM_FLEET_FIXTURE/$1" ] || exit 1
cat "$FM_FLEET_FIXTURE/$1"
SH
cat > "$BINDIR/fake-probe" <<'SH'
#!/usr/bin/env bash
case "$2" in
  live*) printf 'alive' ;;
  dead*) printf 'dead' ;;
  *) printf 'unknown' ;;
esac
SH
cat > "$BINDIR/shapes" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-tap-shapes.v1","not_shown":[],"decisions":[]}\n'
SH
cat > "$BINDIR/inbox" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = receipts ] && printf '{"pending":[],"handled":[]}\n'
exit 0
SH
chmod +x "$BINDIR"/*
export FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" FM_FLEET_STATE_PROBE="$BINDIR/fake-probe"
export FM_FACTORY_SHAPES="$BINDIR/shapes" FM_FACTORY_INBOX="$BINDIR/inbox"

CASE=0
reset_case() {
  CASE=$((CASE + 1))
  HOME_FIX="$TMP_ROOT/case$CASE/home"
  FLEET_FIX="$TMP_ROOT/case$CASE/fleet"
  mkdir -p "$HOME_FIX/state" "$HOME_FIX/data" "$HOME_FIX/config" "$FLEET_FIX" "$TMP_ROOT/case$CASE/wt"
  printf -- '- sample [no-mistakes] - a sample project (added 2026-11-01)\n' > "$HOME_FIX/data/projects.md"
  : > "$TMP_ROOT/case$CASE/in-flight"
  : > "$TMP_ROOT/case$CASE/queued"
  export FM_HOME="$HOME_FIX" FM_FLEET_FIXTURE="$FLEET_FIX" FM_FACTORY_SNAPSHOT="$HOME_FIX/snapshot.json"
  export FM_FLEET_STATE_NO_CACHE=1
  unset FM_FLEET_STATE_NOW FM_FLEET_STATE_MAX_AGE FM_FLEET_STATE_TTL
}

# task <id> <window> <worktree> <canonical line> [metadata...]: a task record,
# its endpoint and the line the canonical reader prints for it.
task() {
  local id=$1 window=$2 worktree=$3 line=$4
  shift 4
  fm_write_meta "$HOME_FIX/state/$id.meta" kind=ship mode=no-mistakes backend=tmux "window=$window" \
    "worktree=$worktree" "$@"
  printf '%s\n' "$line" > "$FLEET_FIX/$id"
  printf -- '- [ ] %s - Work called %s (repo: sample) (kind: ship)\n' "$id" "$id" >> "$TMP_ROOT/case$CASE/in-flight"
}

held() {  # <id> <title>: a decision held for the owner that waits on him now
  printf -- '- [ ] %s - %s (repo: sample) (kind: captain) (hold: choose one) (hold-kind: captain)\n' \
    "$1" "$2" >> "$TMP_ROOT/case$CASE/queued"
}

# write_snapshot: the home's backlog from the rows above, and the fleet
# snapshot the Factory pane reads, built from the same fixture lines and
# backlog the overview folds.
write_snapshot() {
  local backlog
  { printf '## In flight\n\n'; cat "$TMP_ROOT/case$CASE/in-flight"; printf '\n## Queued\n\n'
    cat "$TMP_ROOT/case$CASE/queued"; } > "$HOME_FIX/data/backlog.md"
  backlog=$(FM_HOME="$HOME_FIX" bash "$ROOT/bin/fm-fleet-snapshot.sh" --backlog) \
    || fail "the fixture backlog could not be read"
  python3 - "$HOME_FIX" "$FLEET_FIX" "$backlog" <<'PY'
import json, os, re, sys
home, fleet, backlog = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
state = os.path.join(home, "state")
tasks = []
for name in sorted(os.listdir(fleet)):
    raw = open(os.path.join(fleet, name)).read().strip()
    found = re.match(r"state: (\S+) · source: (\S+) · (.*)", raw)
    tasks.append({"id": name, "kind": "ship", "project": "/projects/sample",
                  "current_state": {"state": found.group(1), "source": found.group(2), "detail": found.group(3),
                                    "raw": raw},
                  "paths": {"meta": {"path": os.path.join(state, name + ".meta")},
                            "status_log": {"path": os.path.join(state, name + ".status")}},
                  "hints": {"open_decisions": []}, "pr": {"url": None}})
json.dump({"schema": "fm-fleet-snapshot.v1", "generated": "2026-11-14T08:00:00Z", "tasks": tasks,
           "backlog": backlog}, open(os.path.join(home, "snapshot.json"), "w"))
PY
}

# One fleet that touches every shared figure: two busy (a worker typing and a
# run in the checks), a declared wait, a blocker and a worker's question for
# Starship to look at, a failed run whose worker is gone too, a worker that is
# gone, work ready to merge, and a held decision.
a_fleet() {
  local wt="$TMP_ROOT/case$CASE/wt" gone="$TMP_ROOT/case$CASE/gone"
  task typing live-1 "$wt" 'state: working · source: pane · harness busy'
  task checking live-2 "$wt" 'state: working · source: run-step · run ci'
  task carrier live-3 "$wt" 'state: paused · source: status-log · waiting on the carrier'
  task images live-4 "$wt" 'state: blocked · source: status-log · cannot reach the image store'
  task asking live-5 "$wt" 'state: parked · source: status-log · needs-decision: titles only?'
  task broke dead-1 "$gone" 'state: failed · source: status-log · the tests would not build'
  task lost dead-2 "$wt" 'state: unknown · source: none · backend target gone'
  task green live-6 "$wt" 'state: done · source: run-step · checks green: PR ready for review'
  held pick-design 'Which of two designs'
  write_snapshot
}

strip_row() {
  FM_BRIDGE_STRIP_PMSET='' bash "$ROOT/bin/fm-bridge-strip.sh" render --width 200 --height 1 \
    | sed $'s/\033\\[[0-9;]*m//g' | tr -s ' '
}

status_row() {
  PATH="$BINDIR:$PATH" FM_PRIMARY_HARNESS=pi FM_STATUS_BAR_NOW=1000 \
    bash "$ROOT/bin/fm-status-bar.sh" --adapter pi --model Opus --effort high \
    | sed $'s/\033\\[[0-9;]*m//g'
}

factory_record() {
  python3 "$ROOT/bin/fm-factory.py" --data > "$TMP_ROOT/case$CASE/record.json" || fail "the Factory record failed"
}
q() { jq -r "$1" "$TMP_ROOT/case$CASE/record.json"; }

test_the_three_surfaces_show_the_same_figures_in_the_same_words() {
  local strip bar
  reset_case
  a_fleet
  strip=$(strip_row)
  bar=$(status_row)
  factory_record

  assert_contains "$strip" ' 2 busy ■ 1 decision for you ■ 1 ready to merge ' "the strip's lamps"
  assert_contains "$strip" ' 1 failed, 1 stopped ' "the strip's alert"
  assert_contains "$bar" '│ 2 busy, 1 waiting, 1 decision for you, 1 ready to merge, 2 need a look, 1 failed, 1 stopped │' \
    "the status bar's figures"
  assert_equals "$(q .count_line)" "2 busy · 1 decision for you · 1 ready to merge · 0 idle" \
    "the Factory pane's count line"
  assert_equals "$(q '"\(.counts.busy) \(.counts.decisions) \(.counts.ready_to_merge)"')" "2 1 1" \
    "the Factory pane's counts"

  # Each shared figure, read from each surface by its word, is one number.
  local word n_strip n_bar n_factory
  for word in busy 'decision for you' 'ready to merge' failed stopped; do
    n_strip=$(printf '%s' "$strip" | grep -oE "[0-9]+ $word" | head -n 1)
    n_bar=$(printf '%s' "$bar" | grep -oE "[0-9]+ $word" | head -n 1)
    [ -n "$n_strip" ] && [ "$n_strip" = "$n_bar" ] \
      || fail "the strip and the status bar disagree on '$word': '$n_strip' and '$n_bar'"
    case "$word" in failed|stopped) continue ;; esac
    n_factory=$(q .count_line | grep -oE "[0-9]+ $word" | head -n 1)
    [ "$n_strip" = "$n_factory" ] || fail "the strip and the Factory pane disagree on '$word': '$n_strip' and '$n_factory'"
  done

  # The Factory pane's detail uses the same word for the same thing.
  assert_equals "$(q '[.factories[].jobs[] | "\(.id)=\(.state)"] | sort | join(" ")')" \
    "asking=needs a look broke=failed carrier=waiting checking=busy green=ready to merge images=needs a look lost=stopped pick-design=decision for you typing=busy" \
    "the Factory pane's job words"
  assert_equals "$(q '[.needs_you[] | "\(.id):\(.kind)"] | join(" ")')" "pick-design:question green:finished work" \
    "NEEDS YOU is the calls the overview counts"
  assert_equals "$(q '.needs_you[1].ask')" "Work called green is ready to merge" "a merge call is ready to merge"
  pass "fleet overview: the strip, the status bar and the Factory pane show the same figures in the same words"
}

# The Factory pane's count line is the overview reading itself, not a count of
# its own: work the overview has not read yet is not in the count line, and a
# reading that is only the last good one is marked with its age everywhere.
test_the_factory_count_line_is_the_shared_reading() {
  local stamp sig calls strip bar
  reset_case
  a_fleet
  stamp=$((NOW - 600))
  sig=$(bash -c '. "$1/bin/fm-fleet-status-lib.sh"; _fm_fleet_ids "$2" | _fm_fleet_signature' _ "$ROOT" "$HOME_FIX/state")
  calls=$(bash -c '. "$1/bin/fm-owner-calls-signal-lib.sh"; fm_owner_calls_signal "$2"' _ "$ROOT" "$HOME_FIX/state")
  # A good reading ten minutes old, of this fleet and of the current calls,
  # with every refresh held off as if one were already under way: every
  # surface shows its figures, marked as past.
  printf '%s\t3\t0\t1\t0\t0\t2\t%s\t1\tcalls\t0\t0\t-\tdecision\tpick-design\tWhich of two designs\t%s\tgreen' \
    "$stamp" "$sig" "$calls" > "$HOME_FIX/state/.status-fleet-state"
  printf '%s\n' "$NOW" > "$HOME_FIX/state/.status-fleet-state.refreshing"
  printf '%s\n' "$NOW" > "$HOME_FIX/state/.status-fleet-calls.refreshing"
  export FM_FLEET_STATE_NO_CACHE=0 FM_FLEET_STATE_NOW=$NOW FM_FLEET_STATE_TTL=3600 FM_FLEET_STATE_MAX_AGE=300
  strip=$(strip_row)
  bar=$(status_row)
  factory_record
  assert_contains "$strip" ' 4 busy ■ 1 decision for you ■ 1 ready to merge (10m ago) ' "the strip's past reading"
  assert_contains "$bar" '│ 4 busy, 1 decision for you, 1 ready to merge (10m ago) │' "the status bar's past reading"
  assert_equals "$(q .count_line)" "4 busy · 1 decision for you · 1 ready to merge (10m ago) · 0 idle" \
    "the Factory pane counted on its own instead of showing the shared reading"
  pass "fleet overview: the Factory pane's count line is the shared reading, past readings marked everywhere"
}

fm_test_run \
  test_the_three_surfaces_show_the_same_figures_in_the_same_words \
  test_the_factory_count_line_is_the_shared_reading
