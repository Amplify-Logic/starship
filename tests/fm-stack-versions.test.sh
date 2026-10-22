#!/usr/bin/env bash
# Behavior tests for the report-only stack tool-version check.
#
# Contracts under test:
#   - Each tool's installed version is compared with its latest release and
#     reported in plain words: behind, up to date, not installed, or not
#     comparable when the version or the release cannot be read.
#   - The version Starship expects is read from the checkout's own pin owners at
#     run time: an exact Herdr pin is named whenever it differs, and a version
#     below a floor is called out.
#   - Herdr and treehouse upgrades are flagged for a quiet window with no
#     workers running; any other update is small and waits for a yes.
#   - It only reports: no package manager or installer is ever invoked.
#   - `notice` prints one line naming each installed tool that is behind, as a
#     small update or a quiet-window upgrade, judging Herdr against Starship's
#     exact pin and every other tool against its latest release, and nothing
#     when no installed tool is known to be behind.
#   - `notice` caches the whole lookup result, failed lookups included, for a
#     day per home, names a tool it could not check only on the run that
#     refreshed that result, and probes installed versions on every run.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERSIONS="$ROOT/bin/fm-stack-versions.sh"
TMP_ROOT=$(fm_test_tmproot fm-stack-versions-tests)
command -v jq >/dev/null 2>&1 || fail 'jq is required by fm-stack-versions.sh and this test'

# A checkout whose pin owners carry known values, so the test never depends on
# the live pins.
new_root() {
  local root=$1
  mkdir -p "$root/bin"
  printf 'FM_HERDR_CI_VERSION=0.9.5\nFM_HERDR_CI_REPO=example/herdr\n' >"$root/bin/fm-install-herdr.sh"
  printf 'NO_MISTAKES_MIN=1.59.2\nGH_AXI_MIN=0.1.29\nLAVISH_AXI_MIN=0.1.80\n' >"$root/bin/fm-bootstrap.sh"
  printf 'FM_QUOTA_AXI_MIN=0.1.51\n' >"$root/bin/fm-quota-axi-lib.sh"
  printf 'FM_TASKS_AXI_MIN=0.2.6\n' >"$root/bin/fm-tasks-axi-lib.sh"
}

# fake_tool <bin> <name> <banner>
fake_tool() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$3" >"$1/$2"
  chmod +x "$1/$2"
}

# A bin directory holding only the fakes, plus a fake curl that answers each
# release lookup from the case table below, and installers that record a call.
new_bin() {
  local bin=$1
  mkdir -p "$bin"
  ln -s "$(command -v jq)" "$bin/jq"
  cat >"$bin/curl" <<'STUB'
#!/usr/bin/env bash
url=
for arg in "$@"; do url=$arg; done
[ "${FM_TEST_OFFLINE:-0}" = 1 ] && exit 6
case "$url" in
  https://api.github.com/repos/example/herdr/releases/latest) printf '{"tag_name":"%s"}\n' "${FM_TEST_HERDR_LATEST:-v0.9.5}" ;;
  https://api.github.com/repos/kunchenguid/treehouse/releases/latest) printf '{"tag_name":"v3.1.4"}\n' ;;
  https://api.github.com/repos/kunchenguid/no-mistakes/releases/latest) printf '{"tag_name":"v1.84.0"}\n' ;;
  https://registry.npmjs.org/gh-axi/latest) printf '{"name":"gh-axi","version":"0.1.43"}\n' ;;
  https://registry.npmjs.org/quota-axi/latest) printf '{"name":"quota-axi","version":"0.1.65"}\n' ;;
  https://registry.npmjs.org/tasks-axi/latest) printf '{"name":"tasks-axi","version":"0.2.6"}\n' ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$bin/curl"
  for installer in npm brew pip3; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %q "$*" >>"%s/installer-calls"\n' "$installer" "$bin" >"$bin/$installer"
    chmod +x "$bin/$installer"
  done
}

run_report() {
  local root=$1 bin=$2
  shift 2
  env "$@" PATH="$bin:/usr/bin:/bin" FM_ROOT_OVERRIDE="$root" FM_STACK_VERSIONS_TIMEOUT=5 "$VERSIONS" report
}

# run_notice <root> <bin> <state> [env...]
run_notice() {
  local root=$1 bin=$2 state=$3
  shift 3
  env FM_TEST_STACK_VERSIONS_NOTICE=1 "$@" PATH="$bin:/usr/bin:/bin" FM_ROOT_OVERRIDE="$root" \
    FM_STATE_OVERRIDE="$state" FM_STACK_VERSIONS_TIMEOUT=5 "$VERSIONS" notice
}

test_plain_words_per_tool() {
  local root="$TMP_ROOT/plain/root" bin="$TMP_ROOT/plain/bin" out
  new_root "$root"
  new_bin "$bin"
  fake_tool "$bin" herdr 'herdr 0.7.4'
  fake_tool "$bin" treehouse 'v2.0.0'
  fake_tool "$bin" no-mistakes 'no-mistakes version v1.84.0 (4822244) 2026-09-26T08:31:07Z'
  fake_tool "$bin" gh-axi '0.1.20'
  fake_tool "$bin" chrome-devtools-axi '0.1.42'
  fake_tool "$bin" quota-axi 'quota-axi development build'
  fake_tool "$bin" tasks-axi '0.2.6'
  out=$(run_report "$root" "$bin")

  assert_contains "$out" '## Tool versions' 'report has no section heading'
  assert_contains "$out" 'Behind: Herdr, treehouse, gh-axi.' 'summary did not list the tools that are behind'
  assert_contains "$out" 'Up to date: no-mistakes, tasks-axi.' 'summary did not list the current tools'
  assert_contains "$out" 'Could not compare: chrome-devtools-axi, quota-axi.' 'summary did not list the unreadable tools'
  assert_contains "$out" 'Not installed: lavish-axi.' 'summary did not list the missing tool'
  assert_contains "$out" "- Herdr: installed 0.7.4, latest 0.9.5 - behind. Starship's own tests are verified on 0.9.5. Upgrade only in a quiet window with no workers running, because every worker window, including firstmate's, runs inside Herdr." \
    'Herdr line lost its pin or quiet-window warning'
  assert_contains "$out" "- treehouse: installed 2.0.0, latest 3.1.4 - behind. Upgrade only in a quiet window with no workers running, because every worker's isolated copy comes from treehouse." \
    'treehouse line lost its quiet-window warning'
  assert_contains "$out" '- no-mistakes: installed 1.84.0, latest 1.84.0 - up to date.' 'no-mistakes line wrong'
  assert_contains "$out" '- gh-axi: installed 0.1.20, latest 0.1.43 - behind. Below the 0.1.29 Starship needs. A small update: install it only after a yes.' \
    'gh-axi line did not flag the floor and the small update'
  assert_contains "$out" '- chrome-devtools-axi: installed 0.1.42; the latest release could not be read (offline or rate-limited).' \
    'an unreadable release was not said plainly'
  assert_contains "$out" '- quota-axi: installed, but its version could not be read; latest release 0.1.65.' \
    'an unreadable installed version was not said plainly'
  assert_contains "$out" '- lavish-axi: not installed here.' 'missing tool was not said plainly'
  assert_contains "$out" 'This is a report only. Nothing was installed or upgraded.' 'report did not say it only reports'
  [ ! -e "$bin/installer-calls" ] || fail "the report invoked an installer: $(cat "$bin/installer-calls")"
  pass 'each tool is reported in plain words against its latest release and Starship pins, installing nothing'
}

test_exact_pin_named_when_latest_moves_past_it() {
  local root="$TMP_ROOT/pin/root" bin="$TMP_ROOT/pin/bin" out
  new_root "$root"
  new_bin "$bin"
  fake_tool "$bin" herdr 'herdr 0.9.5'
  out=$(run_report "$root" "$bin" FM_TEST_HERDR_LATEST=v1.0.0)
  assert_contains "$out" "- Herdr: installed 0.9.5, latest 1.0.0 - behind. Starship's own tests are verified on 0.9.5." \
    'a latest release past the exact pin was not flagged as unverified'
  out=$(run_report "$root" "$bin")
  assert_contains "$out" '- Herdr: installed 0.9.5, latest 0.9.5 - up to date.' 'Herdr on its pin was not up to date'
  assert_not_contains "$out" 'verified on' 'Herdr on its pin and latest still named the pin'
  pass 'the exact Herdr pin is named whenever the installed or latest version differs from it'
}

test_offline_reports_without_failing() {
  local root="$TMP_ROOT/offline/root" bin="$TMP_ROOT/offline/bin" out rc
  new_root "$root"
  new_bin "$bin"
  fake_tool "$bin" herdr 'herdr 0.7.4'
  out=$(run_report "$root" "$bin" FM_TEST_OFFLINE=1) && rc=0 || rc=$?
  expect_code 0 "$rc" 'an offline report must still succeed'
  assert_contains "$out" 'Behind: none.' 'offline report claimed a tool was behind'
  assert_contains "$out" '- Herdr: installed 0.7.4; the latest release could not be read (offline or rate-limited).' \
    'offline Herdr line was not said plainly'
  pass 'with no network the report still completes and says what it could not compare'
}

test_notice_names_behind_tools_on_one_line() {
  local root="$TMP_ROOT/notice/root" bin="$TMP_ROOT/notice/bin" state="$TMP_ROOT/notice/state" out
  new_root "$root"
  new_bin "$bin"
  mkdir -p "$state"
  fake_tool "$bin" herdr 'herdr 0.7.4'
  fake_tool "$bin" treehouse 'v2.0.0'
  fake_tool "$bin" no-mistakes 'no-mistakes version v1.84.0 (4822244) 2026-09-26T08:31:07Z'
  fake_tool "$bin" gh-axi '0.1.20'
  fake_tool "$bin" chrome-devtools-axi '0.1.42'
  fake_tool "$bin" quota-axi 'quota-axi development build'
  fake_tool "$bin" tasks-axi '0.2.6'
  out=$(run_notice "$root" "$bin" "$state" FM_TEST_HERDR_LATEST=v0.10.0)
  [ "$out" = 'STACK_TOOLS: behind: Herdr installed 0.7.4, pinned 0.9.5 (quiet-window upgrade); treehouse installed 2.0.0, latest 3.1.4 (quiet-window upgrade); gh-axi installed 0.1.20, latest 0.1.43 (small update) - could not check: chrome-devtools-axi, quota-axi' ] \
    || fail "notice line was not the one plain line expected: $out"
  [ ! -e "$bin/installer-calls" ] || fail "the notice invoked an installer: $(cat "$bin/installer-calls")"

  out=$(run_notice "$root" "$bin" "$state" FM_TEST_HERDR_LATEST=v0.10.0)
  [ "$out" = 'STACK_TOOLS: behind: Herdr installed 0.7.4, pinned 0.9.5 (quiet-window upgrade); treehouse installed 2.0.0, latest 3.1.4 (quiet-window upgrade); gh-axi installed 0.1.20, latest 0.1.43 (small update)' ] \
    || fail "a later run the same day did not repeat only the behind tools: $out"

  rm -f "$bin/chrome-devtools-axi" "$bin/treehouse"
  fake_tool "$bin" herdr 'herdr 0.9.5'
  fake_tool "$bin" gh-axi '0.1.43'
  out=$(run_notice "$root" "$bin" "$state" FM_TEST_HERDR_LATEST=v0.10.0)
  [ -z "$out" ] || fail "notice was not silent with Herdr on its pin and the rest current: $out"
  pass 'notice names every behind tool with its kind of update on one line, judges Herdr by its pin, and says what it could not check once'
}

test_notice_caches_the_whole_result_for_a_day() {
  local root="$TMP_ROOT/cache/root" bin="$TMP_ROOT/cache/bin" state="$TMP_ROOT/cache/state" out
  new_root "$root"
  new_bin "$bin"
  mkdir -p "$state"
  fake_tool "$bin" gh-axi '0.1.20'
  out=$(run_notice "$root" "$bin" "$state")
  assert_contains "$out" 'gh-axi installed 0.1.20, latest 0.1.43 (small update)' 'first notice did not look up the release'
  assert_contains "$(cat "$state/.stack-versions.latest")" $'npm:gh-axi\t0.1.43' 'the successful lookup was not cached'

  out=$(run_notice "$root" "$bin" "$state" FM_TEST_OFFLINE=1)
  assert_contains "$out" 'gh-axi installed 0.1.20, latest 0.1.43 (small update)' 'a fresh cache was not used while offline'

  fake_tool "$bin" gh-axi '0.1.43'
  out=$(run_notice "$root" "$bin" "$state" FM_TEST_OFFLINE=1)
  [ -z "$out" ] || fail "an upgrade did not show at once against the cached release: $out"

  fake_tool "$bin" gh-axi '0.1.20'
  printf '%s\nnpm:gh-axi\t0.1.43\n' "$(( $(date +%s) - 86400 ))" >"$state/.stack-versions.latest"
  out=$(run_notice "$root" "$bin" "$state" FM_TEST_OFFLINE=1)
  [ "$out" = 'STACK_TOOLS: could not check: gh-axi' ] \
    || fail "a day-old cache with a failed lookup was not reported as unknown: $out"

  out=$(run_notice "$root" "$bin" "$state")
  [ -z "$out" ] || fail "a failed lookup was not cached for the day, or was named again: $out"

  fake_tool "$bin" tasks-axi '0.2.5'
  out=$(run_notice "$root" "$bin" "$state")
  [ "$out" = 'STACK_TOOLS: behind: gh-axi installed 0.1.20, latest 0.1.43 (small update); tasks-axi installed 0.2.5, latest 0.2.6 (small update)' ] \
    || fail "a newly installed tool did not refresh the day's lookups: $out"
  pass 'notice reuses the whole lookup result for a day, failures included, and reads installed versions every run'
}

test_notice_is_silent_under_the_suite_unless_asked() {
  local root="$TMP_ROOT/seam/root" bin="$TMP_ROOT/seam/bin" state="$TMP_ROOT/seam/state" out
  new_root "$root"
  new_bin "$bin"
  mkdir -p "$state"
  fake_tool "$bin" gh-axi '0.1.20'
  out=$(env PATH="$bin:/usr/bin:/bin" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$state" "$VERSIONS" notice)
  [ -z "$out" ] || fail "notice reached for releases under the test suite without being asked: $out"
  [ ! -e "$state/.stack-versions.latest" ] || fail 'notice wrote a cache under the test suite without being asked'
  pass 'notice stays silent under the test suite unless a case asks for it'
}

test_plain_words_per_tool
test_exact_pin_named_when_latest_moves_past_it
test_offline_reports_without_failing
test_notice_names_behind_tools_on_one_line
test_notice_caches_the_whole_result_for_a_day
test_notice_is_silent_under_the_suite_unless_asked
