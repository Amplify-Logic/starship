#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the bounded poll loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates pane
# path sequences with a fake tmux and asserts:
#   1. Two consecutive identical non-project reads are required to accept WT.
#   2. A single matching read followed by a different path is NOT accepted.
#   3. A pane that never settles fails cleanly at a short overridden bound
#      (never hangs toward the production 60s default).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query either walks FM_FAKE_PANE_SEQFILE (one path per line; past EOF repeats
# the last line, or returns empty when the file ends with an empty line), or
# returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS calls then
# FM_FAKE_PANE_PATH forever after.
# new-window prints a stable window id so the fork's WT_TARGET path is exercised.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ -n "${FM_FAKE_PANE_SEQFILE:-}" ]; then
      line=$(sed -n "${n}p" "$FM_FAKE_PANE_SEQFILE" || true)
      if [ -z "$line" ] && [ "$n" -gt 1 ]; then
        # Past EOF: repeat the last non-empty line when present; otherwise empty.
        line=$(awk 'NF{l=$0} END{print l}' "$FM_FAKE_PANE_SEQFILE")
      fi
      printf '%s\n' "$line"
      exit 0
    fi
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  new-window) printf '@42\n'; exit 0 ;;
  has-session|new-session|set-window-option|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # CI runners lack real harness binaries; preflight requires a --version-capable
  # stub on PATH (same pattern as fm-spawn-dispatch-profile / launch-preflight).
  fm_fake_exit0 "$fakebin" treehouse codex
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path.
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  # CASE_DIR is part of the record for debugging but unused by callers.
  # shellcheck disable=SC2034
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  shift
  # "$@" may carry extra VAR=value overrides; env applies them before spawn.
  env \
    FM_ROOT_OVERRIDE='' \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" \
    FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$@" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead. Feed an explicit sequence (stale, wt, wt) so
# success does not depend on "forever after" fixture behavior alone.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status seqfile
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 0)
  read_settle_record "$rec"
  seqfile="$TMP_ROOT/settle-single/seq"
  printf '%s\n%s\n%s\n' "$STALE_DIR" "$WT_DIR" "$WT_DIR" > "$seqfile"

  out=$(run_settle_spawn "$id" FM_FAKE_PANE_SEQFILE="$seqfile" FM_SPAWN_SETTLE_SLEEP=0)
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing inter-poll sleep to confirm - not an extra full
# cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# Control: one non-project read, then back to the project forever, must NOT
# accept the single first read. With a short bound and sleep 0 this fails fast.
test_single_then_different_read_is_not_accepted() {
  local rec id out status seqfile start end elapsed
  id=settle-single-then-diff-z3
  rec=$(make_settle_case settle-single-diff "$id" 0)
  read_settle_record "$rec"
  seqfile="$TMP_ROOT/settle-single-diff/seq"
  # One settled read, then the project path forever - never two consecutive
  # identical non-project reads (a follow-on different non-project path would
  # become the new candidate and could still settle; project resets it).
  printf '%s\n%s\n' "$WT_DIR" "$PROJ_DIR" > "$seqfile"

  start=$(date +%s)
  out=$(
    run_settle_spawn "$id" \
      FM_FAKE_PANE_SEQFILE="$seqfile" \
      FM_SPAWN_SETTLE_MAX_POLLS=6 \
      FM_SPAWN_SETTLE_SLEEP=0
  )
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 1 "$status" "single-then-different sequence should refuse"
  assert_contains "$out" "did not enter a worktree within 6 poll(s)" \
    "refusal did not name the short poll bound"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "failed settle wrote task meta"
  [ "$elapsed" -le 5 ] || fail "single-then-different bound took ${elapsed}s - expected near-instant with SLEEP=0"
  pass "a single-then-different path sequence is not accepted and fails at the short bound"
}

# Never settles (always the project path): must fail at the overridden bound
# without approaching the production 60s wait.
test_never_settles_fails_at_short_bound() {
  local rec id out status start end elapsed
  id=settle-never-z4
  rec=$(make_settle_case settle-never "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(
    run_settle_spawn "$id" \
      FM_FAKE_PANE_PATH="$PROJ_DIR" \
      FM_SPAWN_SETTLE_MAX_POLLS=4 \
      FM_SPAWN_SETTLE_SLEEP=0
  )
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 1 "$status" "never-settles should refuse"
  assert_contains "$out" "did not enter a worktree within 4 poll(s)" \
    "refusal did not name the short poll bound"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "never-settles wrote task meta"
  [ "$elapsed" -le 5 ] || fail "never-settles bound took ${elapsed}s - expected near-instant with SLEEP=0"
  pass "a never-settling pane fails cleanly at the short overridden bound"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_single_then_different_read_is_not_accepted
test_never_settles_fails_at_short_bound

echo "# all fm-spawn-worktree-settle tests passed"
