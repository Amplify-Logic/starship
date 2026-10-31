#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - A dirty, offline, wrong-branch, or genuinely unique diverged target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#     Divergence leaves a durable reconciliation record, while a clean local
#     result already present upstream after a squash merge heals automatically.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     the two secondmate action sets are disjoint and correctly gated -
#     restart-secondmates carries EVERY live mate this pass left on origin's tip
#     whose recorded runtime can prove a restart, INCLUDING one that was already
#     there and one whose advance touched no instruction surface, because a
#     restart is also what re-resolves launch-time harness wiring; a live mate
#     whose runtime cannot prove a restart falls to nudge-secondmates; and a mate
#     whose home was skipped or whose endpoint is stopped gets no action at all.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
#   - A home's private add-on (bin/fm-addon.sh) fast-forwards from its own
#     origin under the same guards, a remote home's add-on line is relayed, and
#     a home with no add-on prints nothing about one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/fakebin" "$w/fake"
  : > "$w/fake/windows"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) cat "$FM_FAKE_DIR/windows" ;;
  display-message)
    target=
    for arg in "$@"; do
      case "$arg" in main:fm-*) target=$arg ;; esac
    done
    case "${*: -1}" in
      *pane_current_command*)
        id=${target##*fm-}
        if [ -e "$FM_FAKE_DIR/dead-$id" ]; then printf 'zsh\n'; else printf 'claude\n'; fi
        ;;
      *) printf '\n' ;;
    esac
    ;;
esac
SH
  chmod +x "$w/fakebin/tmux"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/bin/fm-remote-secondmate-control.sh"
  chmod +x "$w/seed/bin/fm-remote-secondmate-control.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
# The recorded runtime matters to the action split, so it is part of the fixture:
# harness defaults to a control-verified adapter on the default (tmux) backend,
# which is what makes a restart provable. Pass a backend to model one that cannot
# prove an agent stopped.
add_sm() {
  local w=$1 id=$2 harness=${3:-claude} backend=${4:-}
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s/%s\n' "$w" "$id"
    printf 'project=%s/%s\n' "$w" "$id"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    [ -z "$backend" ] || printf 'backend=%s\n' "$backend"
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf 'fm-%s\n' "$id" >> "$w/fake/windows"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the whole instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=bin changes only bin/, which
# a running agent re-executes rather than holding; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  if [ "$mode" = bin ]; then
    printf 'echo b-%s\n' "$RANDOM" > "$w/seed/bin/tool.sh"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "restart-secondmates: fm-sm1" "a changed AGENTS.md must move the secondmate into the restart set"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + restart signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The running firstmate reads nothing new, but the mate's agent still holds its
  # launch-time wiring from before the pass, which only a restart re-resolves.
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "a live mate on the new tip must restart even when no instruction file moved"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T3 a non-instruction advance still restarts the live secondmate"
}

# --- T3b: a bin/-only advance restarts too ---------------------------------
# Helpers under bin/ do reload themselves on the next call, but the mate's agent
# still froze its launch-time harness wiring before this pass, so the restart is
# not redundant and the old bin/-only carve-out no longer applies.
test_bin_only_advance_restarts() {
  local w out
  w=$(new_world t3b)
  add_sm "$w" sm1
  bump_origin "$w" bin

  out=$(run_update "$w")

  assert_contains "$out" "reread-firstmate: yes" "a bin/ change is still an instruction-surface advance"
  assert_contains "$out" "restart-secondmates: fm-sm1" "a bin/-only advance must still restart the live mate"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T3b a bin/-only advance restarts the secondmate"
}

# --- T3c: an unverifiable runtime receives the fallback nudge ----------------
test_unprovable_runtime_gets_fallback_nudge() {
  local w out
  w=$(new_world t3c)
  # zellij has no recovery-grade agent-state classifier, so no restart there can
  # ever prove the old agent stopped and the replacement came up.
  add_sm "$w" sm1 claude zellij
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "restart-secondmates: none" "an unprovable runtime must stay out of the restart set"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "an unverifiable runtime must retain the fallback re-read nudge"
  pass "T3c an unverifiable secondmate receives the fallback nudge"
}

# --- T3d: an already-stopped mate is left to startup recovery ---------------
test_dead_secondmate_gets_no_action() {
  local w out
  w=$(new_world t3d)
  add_sm "$w" sm1
  : > "$w/fake/dead-sm1"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: updated " "the stopped mate's safe checkout still advances"
  assert_contains "$out" "restart-secondmates: none" "a stopped mate must not be sent to restart"
  assert_contains "$out" "nudge-secondmates: none" "a stopped mate must not receive a queued nudge"
  pass "T3d an already-stopped secondmate is left to startup recovery"
}

# --- T3e: a legacy remote advance still restarts ---------------------------
# The host's instr= suffix is reporting detail; the parent no longer routes on it,
# so an older host that cannot report a diff can no longer suppress the restart.
test_legacy_remote_advance_restarts() {
  local w out fake_ssh
  w=$(new_world t3e)
  fake_ssh="$w/fakebin/fake-ssh"
  cat > "$fake_ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
case "${rargs[1]:-}" in
  update) printf 'synced: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
  state) printf 'alive\n' ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$fake_ssh"
  cat > "$w/home/state/sm1.meta" <<EOF
window=remote:sm1
endpoint_task_id=sm1
worktree=/srv/sm1
project=/srv/sm1
harness=claude
kind=secondmate
home=/srv/sm1
remote_host=remote-mac
remote_backend=herdr
EOF
  printf -- '- sm1 - remote domain (host: remote-mac; root: /srv/fm; home: /srv/sm1; scope: things; projects: p; added 2026-09-03)\n' \
    > "$w/home/data/secondmates.md"

  out=$(FM_TEST_SSH_BIN="$fake_ssh" run_update "$w")

  assert_contains "$out" "remote secondmate sm1: updated on remote-mac" \
    "the legacy remote advance was not accepted"
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "a live remote mate on the new tip must restart even when the host reports no instruction diff"
  assert_contains "$out" "nudge-secondmates: none" \
    "a restarted remote mate must not also be steered"
  pass "T3e a legacy remote advance still restarts the live remote mate"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before marker second_out
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_contains "$out" "reconciliation required (record:" "diverged skip is actionable"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  marker="$w/home/state/.secondmate-update-reconcile/sm1.pending"
  assert_present "$marker" "diverged secondmate did not retain a durable reconciliation record"
  assert_grep 'schema=fm-secondmate-update-reconcile.v1' "$marker" "divergence record schema missing"
  assert_grep "local_commit=$before" "$marker" "divergence record lost the protected local commit"

  second_out=$(run_update "$w")
  assert_contains "$second_out" "reconciliation required (record: $marker)" \
    "a later update did not surface the durable divergence"
  pass "T5 diverged secondmate is preserved and durably actionable"
}

test_squash_merged_divergence_reconciles() {
  local w branch_base local_tip out marker
  w=$(new_world t5b)
  add_sm "$w" sm1
  branch_base=$(git -C "$w/sm1" rev-parse HEAD)

  printf 'v2\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add AGENTS.md
  git -C "$w/sm1" commit -qm local-instructions
  printf 'echo squash-landed\n' > "$w/sm1/bin/tool.sh"
  git -C "$w/sm1" add bin/tool.sh
  git -C "$w/sm1" commit -qm local-tooling
  local_tip=$(git -C "$w/sm1" rev-parse HEAD)

  bump_origin "$w" readme
  out=$(run_update "$w")
  marker="$w/home/state/.secondmate-update-reconcile/sm1.pending"
  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" \
    "unique local work was not initially protected"
  assert_present "$marker" "initial divergence did not leave its durable record"

  git -C "$w/sm1" diff "$branch_base" "$local_tip" | git -C "$w/seed" apply
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm squash-local-contribution
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: reconciled redundant divergence" \
    "the squash-merged local result did not heal"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "reconciled secondmate did not reach origin/main"
  assert_absent "$marker" "successful reconciliation left the divergence marker behind"
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "the reconciled live secondmate was excluded from restart"
  pass "T5b squash-merged divergence heals and rejoins live convergence"
}

# --- T6: the git side is idempotent; the restart set is not -----------------
# This is the SSHHIP case: that mate's home was already at the target commit, so
# the old classifier skipped it entirely and its agent kept running the launch-time
# wiring it started with. An already-current live mate must still be restarted.
test_already_current_secondmate_still_restarts() {
  local w out restart_line
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing left to fast-forward

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" \
    "an already-current live secondmate must still be in the restart set"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T6 an already-current live secondmate is still restarted"
}

# --- T6b: an already-current mate that cannot be restarted stays honest -----
# Unconditional restart must not become an unconditional CLAIM of one.
test_already_current_unprovable_mate_is_nudged() {
  local w out restart_line nudge_line
  w=$(new_world t6b)
  add_sm "$w" sm1 claude zellij
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: the home is already on the tip

  assert_contains "$out" "secondmate sm1: already current" "the mate must need no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_not_contains "$restart_line" "sm1" "an unprovable runtime must stay out of the restart set"
  assert_contains "$nudge_line" "fm-sm1" "an unprovable runtime must keep the honest re-read steer"
  pass "T6b an already-current mate with an unprovable runtime is steered, not claimed as reloaded"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  local restart_line
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" "live-meta secondmate is restarted"
  assert_not_contains "$restart_line" "reg1" "registry-only secondmate without live metadata gets no action"
  assert_not_contains "$nudge_line" "sm1" "a restarted secondmate must not also be nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

# --- T12: a self-update rebinds a locally armed watch on the primary --------
# A self-update fast-forwards bin/ in place, changing bytes an armed
# fm-procevent-when watch's trust binding was hashed against with no
# tampering involved; without a rebind the very next fire would be refused.
test_primary_update_rebinds_local_watch() {
  local w before_hash after_hash out spec
  w=$(new_world t12)
  mkdir -p "$w/seed/bin"
  printf "#!/usr/bin/env bash\necho v1 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  chmod +x "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm add-watched-action
  git -C "$w/seed" push -q origin main
  git -C "$w/main" pull -q origin main

  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$ROOT/bin/fm-procevent-when.sh" \
    arm rebind-primary --interval 60 --stable 1 \
    --condition true --action "$w/main/bin/watched-action.sh" "$w/rebind.log" >/dev/null
  spec="$w/home/state/when/when-rebind-primary.spec"
  before_hash=$(grep '^action_sha256=' "$spec")

  printf "#!/usr/bin/env bash\necho v2 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm bump-watched-action
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "the primary still advanced"
  assert_contains "$out" "rebound: when-rebind-primary" "the primary self-update rebound its own locally armed watch"
  after_hash=$(grep '^action_sha256=' "$spec")
  [ "$before_hash" != "$after_hash" ] \
    || fail "the watch's trust binding was not refreshed to match the updated action bytes"
  pass "T12 a self-update rebinds a locally armed watch on the primary"
}

# --- T13: a home's private add-on moves with the update -------------------
# new_addon <world>: a bare add-on origin and a clone of it checked out beside
# the home, named by the home's config/addon.
new_addon() {
  local w=$1
  git init -q --bare "$w/addon.git"
  git -C "$w/addon.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/addon.git" "$w/addon-seed" 2>/dev/null
  mkdir -p "$w/addon-seed/hooks/bootstrap"
  printf '#!/usr/bin/env bash\necho one\n' > "$w/addon-seed/hooks/bootstrap/10-mine"
  chmod +x "$w/addon-seed/hooks/bootstrap/10-mine"
  git -C "$w/addon-seed" add -A
  git -C "$w/addon-seed" commit -qm a1
  git -C "$w/addon-seed" push -q origin main
  git clone -q "$w/addon.git" "$w/addon"
  mkdir -p "$w/home/config"
  printf 'path = %s\n' "$w/addon" > "$w/home/config/addon"
}

bump_addon() {
  local w=$1
  printf '#!/usr/bin/env bash\necho two\n' > "$w/addon-seed/hooks/bootstrap/10-mine"
  git -C "$w/addon-seed" commit -qam a2
  git -C "$w/addon-seed" push -q origin main
}

test_addon_fast_forwards_with_the_update() {
  local w out
  w=$(new_world t13)
  new_addon "$w"
  bump_addon "$w"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: already current" "the shared code had nothing new"
  assert_contains "$out" "add-on: updated " "the add-on must fast-forward from its own origin"
  assert_contains "$out" "(instructions changed: hooks)" "a hook change is an instruction change"
  assert_contains "$out" "reread-firstmate: yes" "a changed add-on hook must ask the running firstmate to re-read"
  [ "$(git -C "$w/addon" rev-parse HEAD)" = "$(git -C "$w/addon" rev-parse origin/main)" ] \
    || fail "the add-on HEAD is not at its origin/main"

  out=$(run_update "$w")
  assert_contains "$out" "add-on: already current" "a current add-on must say so"
  assert_contains "$out" "reread-firstmate: no" "a current add-on asks for no re-read"
  pass "T13 the private add-on fast-forwards with the update and an instruction change asks for a re-read"
}

test_addon_that_cannot_advance_is_reported_and_left() {
  local w out
  w=$(new_world t14)
  out=$(run_update "$w")
  assert_not_contains "$out" "add-on" "a home with no add-on must print nothing about one"

  new_addon "$w"
  bump_addon "$w"
  printf 'local edit\n' > "$w/addon/scratch.txt"
  out=$(run_update "$w")
  assert_contains "$out" "add-on: skipped: dirty working tree" "a dirty add-on must be skipped and reported"
  assert_equals "local edit" "$(cat "$w/addon/scratch.txt")" "the add-on's local work must survive"

  rm -rf "$w/addon"
  out=$(run_update "$w")
  assert_contains "$out" "add-on: skipped: the add-on checkout $w/addon is missing; run bin/fm-addon.sh install" \
    "a missing add-on checkout must be reported with its repair"
  assert_contains "$out" "reread-firstmate: no" "a skipped add-on asks for no re-read"
  pass "T14 an add-on that cannot advance is reported and left as it is, and no add-on prints nothing"
}

# remote_world <world> <update reply>: give the world one live remote
# secondmate sm1 on remote-mac, reached through a fake ssh whose remote
# `fm-remote-secondmate-control.sh update` runs <update reply> as bash, and
# print that fake ssh.
remote_world() {
  local w=$1 fake_ssh
  fake_ssh="$w/fakebin/fake-ssh"
  printf '%s\n' "$2" > "$w/fakebin/remote-update.sh"
  cat > "$fake_ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
case "${rargs[1]:-}" in
  update) . "${0%/*}/remote-update.sh" ;;
  state) printf 'alive\n' ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$fake_ssh"
  cat > "$w/home/state/sm1.meta" <<EOF
window=remote:sm1
endpoint_task_id=sm1
worktree=/srv/sm1
project=/srv/sm1
harness=claude
kind=secondmate
home=/srv/sm1
remote_host=remote-mac
remote_backend=herdr
EOF
  printf -- '- sm1 - remote domain (host: remote-mac; root: /srv/fm; home: /srv/sm1; scope: things; projects: p; added 2026-09-03)\n' \
    > "$w/home/data/secondmates.md"
  printf '%s\n' "$fake_ssh"
}

test_remote_addon_line_is_relayed() {
  local w out fake_ssh
  w=$(new_world t15)
  fake_ssh=$(remote_world "$w" "printf 'add-on: updated 1111111..2222222\\ncurrent: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n'")

  out=$(FM_TEST_SSH_BIN="$fake_ssh" run_update "$w")

  assert_contains "$out" "remote secondmate sm1: already current on remote-mac" "the remote result must still be read from its last line"
  assert_contains "$out" "remote secondmate sm1 add-on: updated 1111111..2222222" "the remote home's add-on line must be relayed"
  assert_contains "$out" "restart-secondmates: fm-sm1" "the remote add-on line must not disturb the restart routing"
  pass "T15 a remote home's add-on update is relayed beside its own result"
}

# --- T16: a remote home that fails after its add-on line names its own error -
test_remote_failure_after_addon_line_names_its_error() {
  local w out fake_ssh
  w=$(new_world t16)
  fake_ssh=$(remote_world "$w" "printf 'add-on: skipped: dirty working tree\\n'; echo 'error: remote secondmate home sync skipped: dirty working tree' >&2; exit 1")

  out=$(PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" FM_SSH_BIN="$fake_ssh" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1)

  assert_contains "$out" "remote secondmate sm1: skipped on remote-mac: error: remote secondmate home sync skipped: dirty working tree" \
    "the skip line must name the remote home's own error, not its add-on line"
  assert_contains "$out" "remote secondmate sm1 add-on: skipped: dirty working tree" "the remote home's add-on line must still be relayed"
  assert_contains "$out" "restart-secondmates: none" "a remote home that failed must not be restarted"
  pass "T16 a remote home that fails after its add-on line names its own error and still relays the add-on"
}


# --- Release channel ----------------------------------------------------------
# config/update-channel chooses what the update follows (bin/fm-release-lib.sh).

# Tag origin's current main tip with a release name.
tag_origin() {
  local w=$1 name=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  git -C "$w/seed" tag -a -m "$name" "$name"
  git -C "$w/seed" push -q origin "refs/tags/$name"
}

# Origin history c1 (home starts here), c2=starship-2026.09, c3=starship-2026.10,
# c4=starship-2026.10.1 (a fix release that sorts after 2026.10), c5 untagged,
# plus a release-shaped tag on a side branch that is not a release.
release_world() {
  local w=$1
  bump_origin "$w" readme
  tag_origin "$w" starship-2026.09
  bump_origin "$w" instr
  tag_origin "$w" starship-2026.10
  bump_origin "$w" bin
  tag_origin "$w" starship-2026.10.1
  bump_origin "$w" readme
  git -C "$w/seed" checkout -q -b side
  printf 'side\n' > "$w/seed/side.txt"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm side
  git -C "$w/seed" tag starship-2026.12
  git -C "$w/seed" push -q origin refs/tags/starship-2026.12
  git -C "$w/seed" checkout -q main
}

release_commit() {  # <world> <name>
  git -C "$1/seed" rev-parse "refs/tags/$2^{commit}"
}

set_channel() {  # <world> <value>
  mkdir -p "$1/home/config"
  printf '%s\n' "$2" > "$1/home/config/update-channel"
}

test_default_channel_follows_main_past_releases() {
  local w out
  w=$(new_world r1)
  release_world "$w"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "with no channel file the home still updates"
  assert_not_contains "$out" "release" "the default channel says nothing about releases"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/seed" rev-parse main)" ] \
    || fail "the default channel must move the home to origin's newest main, past every release"

  w=$(new_world r1b)
  release_world "$w"
  set_channel "$w" main
  run_update "$w" >/dev/null
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/seed" rev-parse main)" ] \
    || fail "an explicit main channel must behave exactly like no channel file"
  pass "R1 the default and main channels follow origin's newest main"
}

test_release_channel_follows_newest_release() {
  local w out target
  w=$(new_world r2)
  add_sm "$w" sm1
  release_world "$w"
  set_channel "$w" release
  target=$(release_commit "$w" starship-2026.10.1)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "the release channel moves the home"
  assert_contains "$out" "to release starship-2026.10.1" "the update names the release it moved to"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$target" ] \
    || fail "the home must land exactly on the newest release on main, not on main's tip or a side-branch tag"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD)" = main ] || fail "the home left its default branch"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$target" ] \
    || fail "a local second mate must follow the same release as its primary"
  assert_contains "$out" "restart-secondmates: fm-sm1" "a second mate settled on the release still restarts"

  out=$(run_update "$w")
  assert_contains "$out" "firstmate: already current on release starship-2026.10.1" \
    "a home on the newest release reports which release it is on"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$target" ] || fail "a second pass moved the home past the release"
  pass "R2 the release channel follows the newest release and never moves past it"
}

test_release_channel_moves_a_newer_home_onto_the_release() {
  local w out tip target
  w=$(new_world r3)
  add_sm "$w" sm1
  release_world "$w"
  run_update "$w" >/dev/null
  tip=$(git -C "$w/main" rev-parse HEAD)
  [ "$tip" = "$(git -C "$w/seed" rev-parse main)" ] || fail "the fixture home must start on main's tip"
  set_channel "$w" release
  target=$(release_commit "$w" starship-2026.10.1)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "a home past the newest release only by origin's commits moves"
  assert_contains "$out" "to release starship-2026.10.1" "the move names the release it landed on"
  assert_contains "$out" "secondmate sm1: updated " "a local second mate moves with its primary"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$target" ] \
    || fail "a home on main's tip that switches to release must land exactly on the newest release"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD)" = main ] || fail "the home left its default branch"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$target" ] \
    || fail "a local second mate must land on the same release as its primary"
  assert_contains "$out" "restart-secondmates: fm-sm1" "a second mate moved onto the release still restarts"
  [ ! -e "$w/home/state/.secondmate-update-reconcile/sm1.pending" ] \
    || fail "moving onto a release whose skipped commits are on origin is not a divergence"

  out=$(run_update "$w")
  assert_contains "$out" "firstmate: already current on release starship-2026.10.1" \
    "a home moved onto the release stays there"
  pass "R3 a home past the release only by origin's commits moves onto the release"
}

test_release_channel_leaves_local_commits_alone() {
  local w out main_before sm_before marker
  w=$(new_world r3b)
  add_sm "$w" sm1
  release_world "$w"
  set_channel "$w" release
  run_update "$w" >/dev/null
  printf 'local only\n' > "$w/main/LOCAL.md"
  git -C "$w/main" add LOCAL.md
  git -C "$w/main" commit -qm local-primary
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" commit -qam local-sm
  main_before=$(git -C "$w/main" rev-parse HEAD)
  sm_before=$(git -C "$w/sm1" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: diverged from release starship-2026.10.1" \
    "a home with an unpushed commit on top of a release is reported as diverged"
  assert_contains "$out" "secondmate sm1: skipped: diverged from release starship-2026.10.1; reconciliation required (record:" \
    "a second mate with an unpushed commit is diverged and durably actionable"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$main_before" ] || fail "the release channel moved a home with a local commit"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$sm_before" ] || fail "the release channel moved a second mate with a local commit"
  grep -q 'local only' "$w/main/LOCAL.md" || fail "the primary's local commit was lost"
  marker="$w/home/state/.secondmate-update-reconcile/sm1.pending"
  assert_present "$marker" "a diverged second mate on the release channel needs a durable reconciliation record"
  assert_grep "local_commit=$sm_before" "$marker" "the record lost the second mate's local commit"
  assert_not_contains "$out" "fm-sm1" "a diverged second mate is not restarted or nudged"
  pass "R3b the release channel leaves a home with local commits alone and reports it diverged"
}

test_release_channel_never_moves_a_dirty_home() {
  local w out before
  w=$(new_world r4)
  release_world "$w"
  set_channel "$w" release
  before=$(git -C "$w/main" rev-parse HEAD)
  printf 'local edit\n' >> "$w/main/README.md"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: dirty working tree" "a dirty home on the release channel is skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "a dirty home was moved"
  grep -q 'local edit' "$w/main/README.md" || fail "the dirty edit was discarded"
  pass "R4 the release channel never moves a dirty home"
}

test_malformed_channel_refuses_before_anything_moves() {
  local w out before
  w=$(new_world r5)
  release_world "$w"
  set_channel "$w" nightly
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" 2>&1) && fail "a malformed channel file must refuse the update"

  assert_contains "$out" "config/update-channel must hold one line" "the refusal names the file and its values"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "a malformed channel still moved the home"
  pass "R5 a malformed channel file refuses before anything moves"
}

test_step_back_one_release() {
  local w out
  w=$(new_world r6)
  release_world "$w"
  set_channel "$w" release
  run_update "$w" >/dev/null
  sb() { PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --step-back 2>&1; }

  out=$(sb) || fail "step back from the newest release failed: $out"
  assert_contains "$out" "from release starship-2026.10.1 to release starship-2026.10" "step back names both releases"
  assert_contains "$out" "reread-firstmate: yes" "stepping back across bin/ changes asks for a re-read"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(release_commit "$w" starship-2026.10)" ] \
    || fail "step back must land exactly on the previous release"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD)" = main ] || fail "step back left the default branch"
  [ "$(cat "$w/home/config/update-channel")" = starship-2026.10 ] \
    || fail "step back must hold the home on that release"

  out=$(run_update "$w")
  assert_contains "$out" "firstmate: already current on release starship-2026.10" \
    "a held home stays on its release across later updates"

  out=$(sb) || fail "a second step back failed: $out"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(release_commit "$w" starship-2026.09)" ] \
    || fail "a second step back must go one more release back"
  out=$(sb) && fail "stepping back from the oldest release must refuse"
  assert_contains "$out" "starship-2026.09 is the oldest release" "the refusal names the oldest release"

  set_channel "$w" release
  out=$(run_update "$w")
  assert_contains "$out" "to release starship-2026.10.1" "writing release again follows the newest release"

  printf 'local edit\n' >> "$w/main/README.md"
  out=$(sb) && fail "step back must refuse a dirty home"
  assert_contains "$out" "dirty working tree" "the dirty refusal names why"
  grep -q 'local edit' "$w/main/README.md" || fail "step back discarded a local edit"
  git -C "$w/main" checkout -q -- README.md

  set_channel "$w" main
  out=$(sb) && fail "step back must refuse on the main channel"
  assert_contains "$out" "step back works on the release channel" "the main-channel refusal names why"

  set_channel "$w" release
  add_sm "$w" sm1
  out=$(sb) && fail "step back must refuse on a home with second mates"
  assert_contains "$out" "step back covers only a home without second mates" \
    "the second-mate refusal says step back covers only a home without them"
  assert_contains "$out" "write the name of the release this home is on now" \
    "the second-mate refusal names what such a home does instead"
  assert_contains "$out" "into config/update-channel" "the second-mate refusal names the file to write"
  pass "R6 a home on the release channel steps back one release at a time and stays there"
}

test_remote_secondmate_follows_the_release() {
  local w out fake_ssh
  w=$(new_world r7)
  release_world "$w"
  set_channel "$w" release
  fake_ssh=$(remote_world "$w" "printf '%s\\n' \"\${rargs[*]}\" > \"\${0%/*}/remote-args\"; printf 'current: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n'")

  out=$(FM_TEST_SSH_BIN="$fake_ssh" run_update "$w")

  assert_contains "$out" "remote secondmate sm1: already current on remote-mac" "the remote home still updates"
  assert_contains "$(cat "$w/fakebin/remote-args")" "update sm1 starship-2026.10.1" \
    "a remote second mate must be told to follow the primary's release"
  pass "R7 a remote second mate follows the primary's release"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_bin_only_advance_restarts
test_unprovable_runtime_gets_fallback_nudge
test_dead_secondmate_gets_no_action
test_legacy_remote_advance_restarts
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_squash_merged_divergence_reconciles
test_already_current_secondmate_still_restarts
test_already_current_unprovable_mate_is_nudged
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_primary_update_rebinds_local_watch
test_addon_fast_forwards_with_the_update
test_addon_that_cannot_advance_is_reported_and_left
test_remote_addon_line_is_relayed
test_remote_failure_after_addon_line_names_its_error
test_default_channel_follows_main_past_releases
test_release_channel_follows_newest_release
test_release_channel_moves_a_newer_home_onto_the_release
test_release_channel_leaves_local_commits_alone
test_release_channel_never_moves_a_dirty_home
test_malformed_channel_refuses_before_anything_moves
test_step_back_one_release
test_remote_secondmate_follows_the_release

echo "# all fm-update tests passed"
