#!/usr/bin/env bash
# Behavior tests for the declared fork-surface schema, queries, and missing-file gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SURFACE="$ROOT/bin/fm-fork-surface.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-surface)

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

check_current_manifest
check_queries
check_required_surface_deletion_fails
check_personal_surface_deletion_is_optional

echo "# all fm-fork-surface tests passed"
