#!/usr/bin/env bash
# Cursor primary-profile detection, and the worker-boundary regression.
#
# bin/fm-primary.sh establishes the primary's identity at the launch boundary and
# states it in FM_PRIMARY_HARNESS, because a Cursor primary does not clear an
# inherited CLAUDECODE. That claim
# is observable through `fm-harness.sh marker`; `detect_own` deliberately lets a
# contradicting harness ANCESTOR outrank it, so a variable leaked into an
# unrelated pane cannot rename that session. The detect_own case below builds
# the contradicting ancestor it needs, because detect_own's verdict otherwise
# depends on the ancestry of whatever ran the test - and with no harness above
# the runner at all the marker is the only evidence there is, so cursor is then
# the CORRECT answer rather than a leak.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_primary_marker_states_the_launched_identity() {
  local out
  out=$(FM_PRIMARY_HARNESS=cursor CLAUDECODE=1 "$ROOT/bin/fm-harness.sh" marker)
  [ "$out" = cursor ] || fail "Cursor primary marker lost to an inherited CLAUDECODE (got '$out')"
  pass "fm-harness: the primary launcher's established identity survives an inherited foreign marker"
}

test_ancestry_still_outranks_a_leaked_marker() {
  local dir out
  # Build the contradicting ancestor rather than borrowing whatever launched the
  # suite: with an EMPTY ancestry the marker is the only evidence there is and
  # cursor is the correct verdict, so a runner with no harness above it (CI)
  # would read this case as a leak. A process whose kernel-recorded name is
  # `claude` is a structural (comm) ancestor of another harness, which is the
  # one thing detect_own lets outrank the marker. Symlink to the system shell,
  # never a copy: a copied platform binary fails macOS code signing
  # (tests/fm-omp-harness.test.sh:49). The command substitution around the probe
  # is load-bearing - a bare `-c <cmd>` lets bash exec the probe in place and
  # REPLACE the `claude` process the walk has to find.
  dir=$(fm_test_tmproot fm-cursor-leaked-marker)
  mkdir -p "$dir"
  ln -sf "$(command -v bash)" "$dir/claude"
  out=$("$dir/claude" -c "r=\$(FM_PRIMARY_HARNESS=cursor \"$ROOT/bin/fm-harness.sh\"); printf '%s' \"\$r\"")
  [ "$out" = claude ] || \
    fail "a leaked FM_PRIMARY_HARNESS renamed a session under a live claude ancestor (got '$out')"
  pass "fm-harness: ancestry still arbitrates a marker that a live process contradicts"
}

test_configured_worker_selection_stays_separate() {
  local out config
  config=$(fm_test_tmproot fm-cursor-harness-config)
  mkdir -p "$config"
  printf 'codex\n' > "$config/crew-harness"
  out=$(FM_PRIMARY_HARNESS=cursor FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh" crew)
  [ "$out" = codex ] || fail "configured worker runtime was coupled to the Cursor primary (got $out)"
  pass "fm-harness: configured worker selection stays separate from the primary profile"
}

test_worker_set_still_includes_the_fork_adapters() {
  local usage
  usage=$("$ROOT/bin/fm-spawn.sh" --help 2>&1 || true)
  assert_contains "$usage" 'cursor' "fm-spawn lost cursor from its documented worker set"
  assert_contains "$usage" 'kimi' "fm-spawn lost kimi from its documented worker set"
  assert_contains "$usage" 'prime-agent' "fm-spawn lost prime-agent from its documented worker set"
  pass "fm-spawn: primary-profile support does not remove the fork's verified worker adapters"
}

test_primary_marker_states_the_launched_identity
test_ancestry_still_outranks_a_leaked_marker
test_configured_worker_selection_stays_separate
test_worker_set_still_includes_the_fork_adapters
