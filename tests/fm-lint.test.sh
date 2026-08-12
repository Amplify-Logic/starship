#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml) and the pre-push gate (.no-mistakes.yaml
# commands.lint) invoke, so the local lint can never diverge from CI again.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic
# `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`, so PRs passed local
# validation yet failed that exact check in CI on info/warning findings such as
# SC2015, SC1007, and SC2034. A second axis was tool-version skew: CI's
# ShellCheck floated with the runner image and still emitted SC2015, which
# ShellCheck retired in 0.11.0. fm-lint.sh now pins one exact version and both
# gates resolve it, so command, file set, config, AND version all match.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

test_owner_exists_and_executable() {
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable so CI/gate can run it directly"
  pass "one-owner lint script exists and is executable"
}

test_owner_defines_canonical_set() {
  local listed expected
  listed=$(FM_LINT_JOBS=2 "$LINT" --list-files | LC_ALL=C sort)
  # The owner globs these directories, and a glob includes symlinked scripts.
  # Plain -type f would omit them and false-fail the moment a symlinked test is
  # added, which tests/fm-gotmp.test.sh already does for bin/ siblings.
  expected=$(find -L bin bin/backends tests -maxdepth 1 \( -type f -o -type l \) -name '*.sh' -print | LC_ALL=C sort)
  [ "$listed" = "$expected" ] || fail "fm-lint.sh --list-files omitted canonical shell files"
  pass "fm-lint.sh owns the complete canonical shell inventory"
}

# The canonical-set assertion above legitimately replaced a source grep, but the
# two guards that kept bin/fm-lint.sh from lowering severity below the CI default
# or blanket-excluding checks CI enforces were dropped with nothing in their
# place. Prove that contract through the real lint interface instead: a fixture
# carrying a default-severity finding must still fail.
test_default_severity_still_fails() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): default-severity guard"
    return
  fi
  local tmp fixture out rc=0
  tmp=$(fm_test_tmproot fm-lint-severity)
  mkdir -p "$tmp"
  fixture="$tmp/severity-fixture.sh"
  # SC2034 is a warning, below ShellCheck's "error" severity: it is exactly what
  # a lowered --severity or a blanket --exclude would silently stop reporting.
  printf '%s\n' '#!/usr/bin/env bash' 'unused_variable=1' > "$fixture"
  out=$("$LINT" "$fixture" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a default-severity finding; severity or exclusions were weakened"
  case "$out" in
    *SC2034*) ;;
    *) fail "fm-lint.sh did not report the default-severity finding: $out" ;;
  esac
  pass "fm-lint.sh still fails on a default-severity finding"
}

test_ci_invokes_the_owner() {
  grep -Eq '^      - run: bin/fm-lint\.sh$' "$CI" || fail "CI lint job must invoke the one-owner script as a run step"
  # Guard against regression to an inline re-spelling of the command.
  assert_no_grep 'run: shellcheck' "$CI" "CI must call fm-lint.sh, not re-spell shellcheck inline"
  pass "CI lint job calls the one-owner script, not an inline command"
}

test_list_files_rejects_explicit_paths() {
  local out rc=0
  out=$("$LINT" --list-files bin/fm-brief.sh 2>&1) || rc=$?
  expect_code 2 "$rc" "--list-files with explicit paths must be rejected"
  assert_contains "$out" "does not accept explicit paths" "--list-files rejection must explain the conflict"
  pass "fm-lint.sh keeps canonical inventory listing separate from explicit-path linting"
}

test_nomistakes_invokes_the_owner() {
  grep -Fqx "  lint: 'bin/fm-lint.sh'" "$NM" || fail "no-mistakes commands.lint must map exactly to the one-owner script"
  pass "no-mistakes pre-push lint calls the one-owner script"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_ci_installs_and_logs_the_pinned_version() {
  # CI must derive the version from the one owner (never hardcode a divergent
  # number) and log the resolved version as parity evidence.
  assert_grep "VERSION=\"\$(\"\$ROOT/bin/fm-lint.sh\" --required-version)\"" "$INSTALLER" "installer must read the version fm-lint.sh pins"
  [ "$(grep -Fc "bin/fm-install-shellcheck.sh \"\$RUNNER_TEMP/bin\"" "$CI")" -eq 4 ] || fail "lint and all three portable behavior jobs must use the shared ShellCheck installer"
  assert_grep "ACTUAL_SHA256=\$(sha256sum" "$INSTALLER" "installer must calculate the ShellCheck archive checksum"
  assert_grep "[ \"\$ACTUAL_SHA256\" = \"\$SHA256\" ]" "$INSTALLER" "installer must verify the ShellCheck archive checksum"
  assert_grep "\"\$DESTINATION/shellcheck\" --version" "$INSTALLER" "installer must log the resolved ShellCheck version as evidence"
  pass "CI installs and logs the pinned ShellCheck version from the one owner"
}


test_rejects_wrong_shellcheck_version() {
  # Version-independent: a fake shellcheck reporting a different version must be
  # refused before any lint, proving local and CI cannot silently diverge.
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-ver)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\nlicense: x\nwebsite: y\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

test_source_graph_boundaries_keep_every_owner() {
  local adapter
  [ "$(grep -Fc '# shellcheck source=/dev/null' "$ROOT/bin/fm-backend.sh")" -eq 5 ] \
    || fail "the dispatcher must stop static source following at all five dynamic adapters"
  for adapter in tmux herdr zellij orca cmux; do
    assert_present "$ROOT/bin/backends/$adapter.sh" "canonical adapter root is missing: $adapter"
  done
  pass "dynamic dispatch stops source expansion while every adapter remains a canonical root"
}

test_jobs_are_deterministic_and_complete() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): deterministic bounded jobs check"
    return
  fi
  local tmp good bad_a bad_b out_clean_1 out_clean_2 out_fail_1 out_fail_2 out_fail_2b
  local cleanup_tmp cleanup_out rc_clean_1 rc_clean_2 rc_fail_1 rc_fail_2 rc_fail_2b rc_bad_jobs
  tmp=$(fm_test_tmproot fm-lint-jobs)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  bad_a="$tmp/bad-a.sh"
  bad_b="$tmp/bad-b.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$bad_a" <<'SH'
#!/usr/bin/env bash
bad_a() {
  local a= b=
  printf '%s\n' "$a$b"
}
SH
  cat > "$bad_b" <<'SH'
#!/usr/bin/env bash
bad_b() {
  printf '%s\n' $1
}
SH

  rc_clean_1=0
  out_clean_1=$(FM_LINT_JOBS=1 "$LINT" "$good" 2>&1) || rc_clean_1=$?
  rc_clean_2=0
  out_clean_2=$(FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) || rc_clean_2=$?
  [ "$rc_clean_1" -eq 0 ] && [ "$rc_clean_2" -eq 0 ] || fail "clean jobs=1/jobs=2 paths must both pass"
  [ "$out_clean_1" = "$out_clean_2" ] || fail "clean jobs=1/jobs=2 output differs"

  rc_fail_1=0
  out_fail_1=$(FM_LINT_JOBS=1 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_1=$?
  rc_fail_2=0
  out_fail_2=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2=$?
  rc_fail_2b=0
  out_fail_2b=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2b=$?
  [ "$rc_fail_1" -ne 0 ] && [ "$rc_fail_1" -eq "$rc_fail_2" ] && [ "$rc_fail_2" -eq "$rc_fail_2b" ] \
    || fail "failing jobs=1/jobs=2 exit results differ: $rc_fail_1/$rc_fail_2/$rc_fail_2b"
  [ "$out_fail_1" = "$out_fail_2" ] && [ "$out_fail_2" = "$out_fail_2b" ] \
    || fail "failing diagnostics are not byte-identical and deterministic across jobs"
  assert_contains "$out_fail_1" "SC1007" "the first failing root diagnostic was lost"
  assert_contains "$out_fail_1" "SC2086" "the later failing root diagnostic was lost"
  rc_bad_jobs=0
  FM_LINT_JOBS=3 "$LINT" "$good" >/dev/null 2>&1 || rc_bad_jobs=$?
  [ "$rc_bad_jobs" -eq 2 ] || fail "the lint owner must reject unbounded worker counts"

  cleanup_tmp="$tmp/lint-tmp"
  mkdir -p "$cleanup_tmp"
  cleanup_out=$(TMPDIR="$cleanup_tmp" FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) \
    || fail "cleanup fixture lint failed"
  [ "$cleanup_out" = "$out_clean_2" ] || fail "cleanup fixture changed routine diagnostics"
  [ -z "$(find "$cleanup_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
    || fail "bounded lint left temporary worker state behind"
  pass "jobs=1 and jobs=2 preserve deterministic diagnostics, failures, and cleanup bounds"
}

test_worker_trees_stop_on_signal() {
  local tmp fakebin fixture jobs lint_tmp pid_file out_file
  local parent_pid shellcheck_pid i parent_rc survivor
  tmp=$(fm_test_tmproot fm-lint-signal)
  mkdir -p "$tmp"
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/good.sh"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
printf '%s\n' "$$" > "$FM_TEST_SHELLCHECK_PID"
trap 'exit 143' HUP INT TERM
while :; do
  sleep 1
done
SH
  chmod +x "$fakebin/shellcheck"

  for jobs in 1 2; do
      lint_tmp="$tmp/lint-$jobs"
      pid_file="$tmp/shellcheck-$jobs.pid"
      out_file="$tmp/output-$jobs"
      mkdir -p "$lint_tmp"
      PATH="$fakebin:$PATH" TMPDIR="$lint_tmp" FM_LINT_JOBS="$jobs" \
        FM_TEST_SHELLCHECK_PID="$pid_file" \
        "$LINT" "$fixture" > "$out_file" 2>&1 &
      parent_pid=$!
      i=0
      while [ "$i" -lt 500 ] && [ ! -s "$pid_file" ]; do
        kill -0 "$parent_pid" 2>/dev/null || break
        sleep 0.01
        i=$((i + 1))
      done
      [ -s "$pid_file" ] || {
        kill -TERM "$parent_pid" 2>/dev/null || true
        wait "$parent_pid" 2>/dev/null || true
        fail "jobs=$jobs did not start ShellCheck"
      }
      shellcheck_pid=$(cat "$pid_file")
      kill -TERM "$parent_pid" 2>/dev/null \
        || fail "jobs=$jobs parent could not be interrupted"
      parent_rc=0
      wait "$parent_pid" 2>/dev/null || parent_rc=$?
      survivor=0
      i=0
      while [ "$i" -lt 100 ] && kill -0 "$shellcheck_pid" 2>/dev/null; do
        sleep 0.01
        i=$((i + 1))
      done
      if kill -0 "$shellcheck_pid" 2>/dev/null; then
        survivor=1
        kill -KILL "$shellcheck_pid" 2>/dev/null || true
      fi
      [ "$parent_rc" -eq 143 ] \
        || fail "jobs=$jobs signal exit was $parent_rc, expected 143"
      [ "$survivor" -eq 0 ] \
        || fail "jobs=$jobs left ShellCheck running"
      [ -z "$(find "$lint_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
        || fail "jobs=$jobs left temporary worker state"
  done
  pass "jobs=1 and jobs=2 stop complete worker trees"
}

test_seeded_module_boundary_parity() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): seeded source-boundary parity check"
    return
  fi
  local tmp rel adapter dispatcher dep owner test_root out rc
  tmp=$(mktemp -d "$ROOT/.fm-lint-parity.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$tmp")
  rel=${tmp#"$ROOT/"}
  adapter="$tmp/adapter.sh"
  dispatcher="$tmp/dispatcher.sh"
  dep="$tmp/owner-dep.sh"
  owner="$tmp/owner.sh"
  test_root="$tmp/test-local.sh"

  cat > "$adapter" <<'SH'
#!/usr/bin/env bash
adapter_bad() {
  rm $1
}
SH
  cat > "$dispatcher" <<SH
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$adapter"
dispatcher_bad() {
  local a= b=
  printf '%s\n' "\$a\$b"
}
SH
  cat > "$dep" <<'SH'
#!/usr/bin/env bash
owner_dependency_value=ok
SH
  cat > "$owner" <<SH
#!/usr/bin/env bash
# shellcheck source=$rel/owner-dep.sh
. "$dep"
owner_bad() {
  printf '%s\n' "\$owner_dependency_value"
  cd "\$1"
}
SH
  cat > "$test_root" <<SH
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$owner"
test_local_bad() {
  local output=\$(printf ok)
  printf '%s\n' "\$output"
}
SH

  rc=0
  out=$(FM_LINT_JOBS=2 "$LINT" "$dispatcher" "$adapter" "$owner" "$test_root" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "seeded module-boundary defects unexpectedly passed"
  assert_contains "$out" "SC1007" "representative dispatcher defect was hidden"
  assert_contains "$out" "SC2086" "representative canonical adapter defect was hidden"
  assert_contains "$out" "SC2164" "representative production-owner defect was hidden"
  assert_contains "$out" "SC2155" "representative test-local defect was hidden"
  assert_not_contains "$out" "SC2154" "the production owner lost source-aware dependency context"
  [ "$(printf '%s\n' "$out" | grep -Fc 'SC2086 (info)')" -eq 1 ] \
    || fail "the dispatcher boundary re-imported the adapter diagnostic"
  [ "$(printf '%s\n' "$out" | grep -Fc 'SC2164 (warning)')" -eq 1 ] \
    || fail "the test boundary re-imported the production-owner diagnostic"
  pass "seeded dispatcher, adapter, production-owner, and test-local diagnostics preserve parity"
}

# Install a PATH-shadowing shellcheck that reports the pinned version and exits 0
# on lint, so fixture repos can exercise the exec-bit invariant without a real
# ShellCheck install or a real script corpus.
install_pinned_shellcheck_stub() {
  local fakebin=$1
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\\nversion: ${REQUIRED}\\nlicense: x\\nwebsite: y\\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
}

# Build a minimal firstmate-shaped git repo under <repo> with one tests/*.test.sh
# entry at the requested index mode (100644 or 100755), plus a copy of fm-lint.sh.
make_execbit_fixture_repo() {
  local repo=$1 mode=$2
  local test_path="tests/mode-fixture.test.sh"
  mkdir -p "$repo/bin/backends" "$repo/tests"
  cp "$LINT" "$repo/bin/fm-lint.sh"
  chmod +x "$repo/bin/fm-lint.sh"
  # Keep the canonical shellcheck globs from expanding to literal unmatched paths.
  printf '#!/usr/bin/env bash\ntrue\n' > "$repo/bin/dummy.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$repo/bin/backends/dummy.sh"
  chmod +x "$repo/bin/dummy.sh" "$repo/bin/backends/dummy.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$repo/$test_path"
  if [ "$mode" = "100755" ]; then
    chmod +x "$repo/$test_path"
  else
    chmod a-x "$repo/$test_path"
  fi
  git -C "$repo" init -q
  fm_git_identity
  git -C "$repo" add bin/fm-lint.sh bin/dummy.sh bin/backends/dummy.sh "$test_path"
  if [ "$mode" = "100755" ]; then
    git -C "$repo" update-index --chmod=+x "$test_path"
  else
    git -C "$repo" update-index --chmod=-x "$test_path"
  fi
  local got
  got=$(git -C "$repo" ls-files -s -- "$test_path" | awk '{print $1}')
  [ "$got" = "$mode" ] || fail "fixture index mode for $test_path was $got, want $mode"
}

test_rejects_non_executable_tracked_test() {
  local tmp repo fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-execbit-bad)
  repo="$tmp/repo"
  fakebin=$(fm_fakebin "$tmp")
  install_pinned_shellcheck_stub "$fakebin"
  make_execbit_fixture_repo "$repo" "100644"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a 100644 tests/*.test.sh index entry"$'\n'"$out"
  assert_contains "$out" "tests/mode-fixture.test.sh" \
    "fm-lint.sh did not name the non-executable tracked test"
  assert_contains "$out" "100644" \
    "fm-lint.sh did not report the bad index mode"
  assert_contains "$out" "chmod +x tests/mode-fixture.test.sh" \
    "fm-lint.sh did not name the exact chmod +x repair"
  pass "fm-lint.sh fails when a tracked tests/*.test.sh is mode 100644"
}

test_accepts_executable_tracked_test() {
  local tmp repo fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-execbit-good)
  repo="$tmp/repo"
  fakebin=$(fm_fakebin "$tmp")
  install_pinned_shellcheck_stub "$fakebin"
  make_execbit_fixture_repo "$repo" "100755"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$repo/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh rejected a 100755 tests/*.test.sh index entry"$'\n'"$out"
  assert_not_contains "$out" "chmod +x" \
    "fm-lint.sh printed a chmod repair on a clean executable index"
  pass "fm-lint.sh passes when tracked tests/*.test.sh entries are mode 100755"
}

test_owner_exists_and_executable
test_owner_defines_canonical_set
test_default_severity_still_fails
test_ci_invokes_the_owner
test_list_files_rejects_explicit_paths
test_nomistakes_invokes_the_owner
test_pins_an_explicit_version
test_ci_installs_and_logs_the_pinned_version
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
test_source_graph_boundaries_keep_every_owner
test_jobs_are_deterministic_and_complete
test_worker_trees_stop_on_signal
test_seeded_module_boundary_parity
test_rejects_non_executable_tracked_test
test_accepts_executable_tracked_test
