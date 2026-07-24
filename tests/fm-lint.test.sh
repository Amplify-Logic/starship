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
# The authoritative file set the one owner must run.
CANON='shellcheck --norc bin/*.sh bin/backends/*.sh tests/*.sh'
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
  assert_grep "$CANON" "$LINT" "fm-lint.sh must run the canonical shellcheck file set"
  # It must not weaken CI: no severity downgrade and no blanket disable/exclude
  # that would hide findings CI fails on.
  assert_no_grep '--severity' "$LINT" "fm-lint.sh must not lower severity below the CI default"
  assert_no_grep '--exclude' "$LINT" "fm-lint.sh must not blanket-exclude checks CI enforces"
  [ "$(grep -Fc 'exec shellcheck --norc' "$LINT")" -eq 2 ] || fail "both lint modes must ignore ambient ShellCheck configuration"
  pass "fm-lint.sh is the sole authoritative definition at CI-default severity"
}

test_ci_invokes_the_owner() {
  grep -Eq '^      - run: bin/fm-lint\.sh$' "$CI" || fail "CI lint job must invoke the one-owner script as a run step"
  # Guard against regression to an inline re-spelling of the command.
  assert_no_grep 'run: shellcheck' "$CI" "CI must call fm-lint.sh, not re-spell shellcheck inline"
  pass "CI lint job calls the one-owner script, not an inline command"
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
test_ci_invokes_the_owner
test_nomistakes_invokes_the_owner
test_pins_an_explicit_version
test_ci_installs_and_logs_the_pinned_version
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
test_rejects_non_executable_tracked_test
test_accepts_executable_tracked_test
