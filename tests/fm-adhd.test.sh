#!/usr/bin/env bash
# Behavior tests for bin/fm-adhd.sh: bounded ADHD CLI wrapper.
#
# Covers the CLI-absent refusal path (install instructions, exit 127) and a
# hermetic happy path that stubs the `adhd` binary so the suite never spends a
# real ADHD run or requires a global install.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADHD_SH="$ROOT/bin/fm-adhd.sh"
TMP=$(fm_test_tmproot fm-adhd)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

test_cli_absent_refuses_with_install_instructions() {
  local out rc fakebin
  fakebin=$(fm_fakebin "$TMP/absent")
  # Empty fakebin first on PATH so a host-installed `adhd` cannot win.
  set +e
  out=$(
    PATH="$fakebin:$BASE_PATH" \
    env -u FM_ADHD_BIN \
      "$ADHD_SH" --out "$TMP/absent/out.md" "name this API" 2>&1
  )
  rc=$?
  set -e

  expect_code 127 "$rc" "cli-absent refusal exit"
  assert_contains "$out" 'adhd CLI not found on PATH' \
    "cli-absent: missing-CLI message"
  assert_contains "$out" 'npm install -g adhd-agent' \
    "cli-absent: install instructions"
  assert_contains "$out" 'npm uninstall -g adhd-agent' \
    "cli-absent: uninstall instructions"
  assert_contains "$out" 'docs/adhd.md' \
    "cli-absent: docs pointer"
  assert_absent "$TMP/absent/out.md" \
    "cli-absent: must not write --out when CLI is missing"
  pass "fm-adhd refuses loudly with install instructions when adhd CLI is absent"
}

test_stub_cli_writes_out_with_bounded_defaults() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP/happy")
  cat > "$fakebin/adhd" <<'SH'
#!/usr/bin/env bash
set -u
# Record argv for assertions; emit a tiny distilled payload on stdout.
printf '%s\n' "$*" > "${FM_ADHD_TEST_ARGV_LOG:?}"
if [ -n "${ANTHROPIC_API_KEY+x}" ]; then
  printf 'ANTHROPIC_API_KEY was set\n' >&2
  exit 9
fi
printf 'distilled: %s\n' "$1"
SH
  chmod +x "$fakebin/adhd"

  set +e
  out=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_ADHD_TEST_ARGV_LOG="$TMP/happy/argv.txt" \
    ANTHROPIC_API_KEY=should-be-stripped \
    env -u FM_ADHD_BIN \
      "$ADHD_SH" --out "$TMP/happy/out.md" --quiet -- "design the schema" 2>&1
  )
  rc=$?
  set -e

  expect_code 0 "$rc" "happy-path exit"
  assert_contains "$(cat "$TMP/happy/out.md")" 'distilled: design the schema' \
    "happy-path: distilled stdout written to --out"
  assert_contains "$(cat "$TMP/happy/argv.txt")" '--frames 3' \
    "happy-path: default --frames is bounded"
  assert_contains "$(cat "$TMP/happy/argv.txt")" '--ideas 4' \
    "happy-path: default --ideas is bounded"
  assert_contains "$(cat "$TMP/happy/argv.txt")" '--top 2' \
    "happy-path: default --top is bounded"
  assert_contains "$out" 'wrote' \
    "happy-path: wrapper reports the output path"
  assert_not_contains "$out" 'ANTHROPIC_API_KEY was set' \
    "happy-path: must not pass ANTHROPIC_API_KEY into adhd"
  pass "fm-adhd writes distilled output with bounded defaults and no API key"
}

test_help_exits_zero() {
  local out rc
  set +e
  out=$("$ADHD_SH" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-adhd.sh --out' "--help usage"
  assert_contains "$out" 'docs/adhd.md' "--help docs pointer"
  pass "fm-adhd --help exits 0"
}

test_cli_absent_refuses_with_install_instructions
test_stub_cli_writes_out_with_bounded_defaults
test_help_exits_zero
