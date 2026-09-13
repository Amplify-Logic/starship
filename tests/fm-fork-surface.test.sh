#!/usr/bin/env bash
# Behavior tests for the declared fork-surface schema, queries, and missing-file gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SURFACE="$ROOT/bin/fm-fork-surface.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-surface)
fm_git_identity

assert_present "$SURFACE" "bin/fm-fork-surface.sh is missing"
[ -x "$SURFACE" ] || fail "bin/fm-fork-surface.sh must be executable"

check_current_manifest() {
  local out
  out=$("$SURFACE" check 2>&1) || fail "current fork surface must pass: $out"
  assert_contains "$out" 'FORK_SURFACE OK capabilities=' "check success marker"
  pass "current fork surface passes every declaration assertion"
}

check_queries() {
  local out fallback
  out=$("$SURFACE" list --topology herdr-topology) || fail "topology query failed"
  assert_contains "$out" $'herdr-worker-presentation\t' "Herdr topology query"
  out=$("$SURFACE" list --config) || fail "config query failed"
  assert_contains "$out" 'primary-handoff' "config query misses primary handoff"
  assert_contains "$out" 'config/action-captain-secret' "config query misses action secret"
  out=$("$SURFACE" port-allowlist) || fail "port allowlist query failed"
  assert_contains "$out" 'config/primary-handoff' "port allowlist misses primary handoff"
  assert_contains "$out" 'config/upstream-watch' "port allowlist misses upstream-watch"
  assert_not_contains "$out" 'action-captain-secret' "port allowlist must exclude secrets"
  fallback=$("$ROOT/bin/fm-home-port.sh" portable-config-files) \
    || fail "home-port fallback allowlist query failed"
  [ "$(printf '%s\n' "$out" | LC_ALL=C sort)" = "$(printf '%s\n' "$fallback" | LC_ALL=C sort)" ] \
    || fail "declared port-allowlist and home-port fallback disagree"
  pass "list, topology, config, and port queries expose declared data"
}

check_required_surface_deletion_fails() {
  local repo out rc=0
  repo="$TMP_ROOT/required-delete"
  git clone -q "$ROOT" "$repo" || fail "could not clone fork-surface fixture"
  cp "$ROOT/fork-surface.conf" "$repo/fork-surface.conf" \
    || fail "could not copy current fork-surface manifest into fixture"
  git -C "$repo" rm -q bin/fm-leak-guard.sh || fail "could not remove required fixture surface"
  out=$(cd "$repo" && bin/fm-fork-surface.sh check 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "required surface deletion must fail"
  assert_contains "$out" 'pii-scrub-leak-guard' "failure must name capability"
  assert_contains "$out" 'bin/fm-leak-guard.sh' "failure must name missing surface"
  assert_contains "$out" 'FORK_SURFACE FAIL' "failure summary"
  pass "required core surface deletion fails and names the capability and path"
}

check_personal_surface_deletion_is_optional() {
  local repo out
  repo="$TMP_ROOT/personal-delete"
  git clone -q "$ROOT" "$repo" || fail "could not clone personal-surface fixture"
  cp "$ROOT/fork-surface.conf" "$repo/fork-surface.conf" \
    || fail "could not copy current fork-surface manifest into fixture"
  git -C "$repo" rm -q bin/fm-adhd.sh docs/adhd.md .agents/skills/adhd/SKILL.md \
    .agents/skills/adhd-auto-fire/SKILL.md tests/fm-adhd.test.sh \
    || fail "could not remove personal fixture surface"
  out=$(cd "$repo" && bin/fm-fork-surface.sh check 2>&1) \
    || fail "declared personal surface must be optional: $out"
  assert_contains "$out" 'FORK_SURFACE OK' "personal omission success marker"
  pass "declared personal capability may be omitted without weakening core and team checks"
}

# build_squash_fixture <repo> <commits-value>: clone the repo, declare a fixture
# capability carrying <commits-value> on a branch, squash-merge that branch into
# a fixture base branch, and echo the branch commit the squash orphaned. The squash
# is what a landed pull request does to every entry that named a branch commit.
# The clone is detached first so the fixture never depends on the source checkout
# having a branch name: CI pull_request checkouts and pipeline worktrees are detached.
build_squash_fixture() {
  local repo=$1 commits=$2 branch_sha
  git clone -q "$ROOT" "$repo" || fail "could not clone squash fixture"
  git -C "$repo" checkout -q --detach HEAD || fail "could not detach the squash fixture"
  git -C "$repo" symbolic-ref -q HEAD >/dev/null \
    && fail "squash fixture must start from a detached HEAD"
  git -C "$repo" checkout -q -B fixture-base || fail "could not create the fixture base branch"
  git -C "$repo" checkout -q -b fixture-capability || fail "could not branch squash fixture"
  cp "$SURFACE" "$repo/bin/fm-fork-surface.sh" || fail "could not copy the fork-surface owner into the fixture"
  cp "$ROOT/fork-surface.conf" "$repo/fork-surface.conf" \
    || fail "could not copy the current fork-surface manifest into the fixture"
  printf '# Squash fixture\n' >"$repo/docs/squash-fixture.md"
  cat >>"$repo/fork-surface.conf" <<CONF

[capability]
id = squash-fixture
title = Squash fixture capability
layer = personal
scope = personal
status = active
why = A fixture capability proves a declared entry survives a squash merge.
owns = docs/squash-fixture.md
proves = none
proves_note = Exercised only by tests/fm-fork-surface.test.sh.
assert = test
commits = $commits
topology = independent
CONF
  git -C "$repo" add bin/fm-fork-surface.sh docs/squash-fixture.md fork-surface.conf \
    || fail "could not stage squash fixture capability"
  git -C "$repo" commit -qm 'add squash fixture capability' \
    || fail "could not commit squash fixture capability"
  branch_sha=$(git -C "$repo" rev-parse --short=8 HEAD) || fail "could not read fixture branch commit"
  git -C "$repo" checkout -q fixture-base || fail "could not return to the fixture base branch"
  git -C "$repo" merge -q --squash fixture-capability >/dev/null \
    || fail "could not squash-merge the fixture branch"
  git -C "$repo" commit -qm 'squash-merge the fixture capability' \
    || fail "could not commit the squashed fixture"
  git -C "$repo" branch -q -D fixture-capability || fail "could not delete the squashed fixture branch"
  printf '%s\n' "$branch_sha"
}

check_pre_merge_entry_survives_squash() {
  local repo out
  repo="$TMP_ROOT/squash-survives"
  build_squash_fixture "$repo" pre-merge >/dev/null
  out=$(cd "$repo" && bin/fm-fork-surface.sh check 2>&1) \
    || fail "a pre-merge entry must survive a squash merge: $out"
  assert_contains "$out" 'FORK_SURFACE OK' "squash survival success marker"
  pass "a pre-merge entry still passes after its branch is squash-merged"
}

check_branch_commit_entry_fails_after_squash() {
  local repo branch_sha out rc=0
  repo="$TMP_ROOT/squash-orphans"
  branch_sha=$(build_squash_fixture "$repo" placeholder)
  git -C "$repo" cat-file -e "$branch_sha^{commit}" \
    || fail "the squashed branch commit must still be a local object"
  sed "s/^commits = placeholder\$/commits = $branch_sha/" "$repo/fork-surface.conf" \
    >"$repo/fork-surface.conf.new" || fail "could not record the orphaned branch commit"
  mv "$repo/fork-surface.conf.new" "$repo/fork-surface.conf"
  out=$(cd "$repo" && bin/fm-fork-surface.sh check 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a branch commit orphaned by a squash must fail even while it resolves locally"
  assert_contains "$out" 'squash-fixture' "failure must name the capability"
  assert_contains "$out" "$branch_sha" "failure must name the orphaned commit"
  assert_contains "$out" 'not an ancestor of the checked-out history' "failure must name the ancestry rule"
  pass "a branch commit orphaned by a squash fails even while the local clone still holds it"
}

check_current_manifest
check_queries
check_required_surface_deletion_fails
check_personal_surface_deletion_is_optional
check_pre_merge_entry_survives_squash
check_branch_commit_entry_fails_after_squash

echo "# all fm-fork-surface tests passed"
