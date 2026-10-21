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

test_plain_words_per_tool
test_exact_pin_named_when_latest_moves_past_it
test_offline_reports_without_failing
