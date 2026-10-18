#!/usr/bin/env bash
# Contract tests for the pinned Herdr / Treehouse CI installers and the
# bounded Herdr lab cleanup helper. These tests do not download release assets
# and never start or stop the captain's default Herdr session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERDR_INSTALL="$ROOT/bin/fm-install-herdr.sh"
TREEHOUSE_INSTALL="$ROOT/bin/fm-install-treehouse.sh"
CLEANUP="$ROOT/bin/fm-herdr-ci-cleanup.sh"
CI="$ROOT/.github/workflows/ci.yml"

assert_present "$HERDR_INSTALL" "bin/fm-install-herdr.sh is missing"
assert_present "$TREEHOUSE_INSTALL" "bin/fm-install-treehouse.sh is missing"
assert_present "$CLEANUP" "bin/fm-herdr-ci-cleanup.sh is missing"
[ -x "$HERDR_INSTALL" ] || fail "fm-install-herdr.sh must be executable"
[ -x "$TREEHOUSE_INSTALL" ] || fail "fm-install-treehouse.sh must be executable"
[ -x "$CLEANUP" ] || fail "fm-herdr-ci-cleanup.sh must be executable"

TMP_ROOT=$(fm_test_tmproot fm-install-herdr)
HERDR_PIN_SHA256=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d
TREEHOUSE_PIN_SHA256=78c820c5872bf9d9d3eb19bbedd75e4804b9258c862238993fa160cf9d215ed8

# installer_world <name>: a fresh case dir with a fakebin that reports a Linux
# x86_64 host and serves $FAKE_ASSET for any curl download, logging curl's
# arguments one per line to <case>/curl.log. No network is touched.
installer_world() {
  local case_dir="$TMP_ROOT/$1" fakebin
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
esac
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_LOG"
out=
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { shift; out=$1; }
  shift
done
cp "$FAKE_ASSET" "$out"
SH
  chmod +x "$fakebin/uname" "$fakebin/curl"
  printf '%s\n' "$case_dir"
}

# fake_sha256 <case_dir> <digest>: make sha256sum report <digest> for any file,
# standing in for a real pinned release asset the test cannot reproduce.
fake_sha256() {
  cat > "$1/fakebin/sha256sum" <<SH
#!/usr/bin/env bash
printf '%s  %s\\n' '$2' "\$1"
SH
  chmod +x "$1/fakebin/sha256sum"
}

# run_installer <installer> <case_dir>: install into <case_dir>/dest; sets
# RUN_RC and RUN_ERR.
run_installer() {
  local installer=$1 case_dir=$2
  RUN_RC=0
  RUN_ERR=$(PATH="$case_dir/fakebin:$PATH" RUNNER_TEMP="$case_dir" \
    CURL_LOG="$case_dir/curl.log" FAKE_ASSET="$case_dir/asset" \
    "$installer" "$case_dir/dest" 2>&1 >/dev/null) || RUN_RC=$?
}

write_fake_herdr() {  # <path> <version> <protocol>
  cat > "$1" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo 'herdr $2' ;;
  status) echo '{"client":{"protocol":$3}}' ;;
esac
SH
}

write_fake_treehouse_archive() {  # <case_dir> <version>
  mkdir -p "$1/archive"
  printf '#!/usr/bin/env bash\necho v%s\n' "$2" > "$1/archive/treehouse"
  chmod +x "$1/archive/treehouse"
  tar -czf "$1/asset" -C "$1/archive" treehouse
}

test_herdr_installer_pins_exact_version_and_checksums() {
  local case_dir
  case_dir=$(installer_world herdr-mismatch)
  write_fake_herdr "$case_dir/asset" 0.9.5 16
  run_installer "$HERDR_INSTALL" "$case_dir"
  expect_code 1 "$RUN_RC" "Herdr installer with an off-pin asset"
  assert_contains "$RUN_ERR" "checksum mismatch for herdr-linux-x86_64 (expected $HERDR_PIN_SHA256" \
    "Herdr installer must refuse an asset whose SHA-256 is not the pin"
  assert_absent "$case_dir/dest/herdr" "Herdr installer must not install an off-pin asset"
  assert_equals "https://github.com/herdrdev/herdr/releases/download/v0.9.5/herdr-linux-x86_64" \
    "$(grep '^https://' "$case_dir/curl.log")" \
    "Herdr installer must fetch the 0.9.5 Linux x86_64 asset from herdrdev/herdr"
  assert_equals "--max-filesize" "$(grep -x -- '--max-filesize' "$case_dir/curl.log")" \
    "Herdr installer must bound the download size"

  case_dir=$(installer_world herdr-match)
  write_fake_herdr "$case_dir/asset" 0.9.5 16
  fake_sha256 "$case_dir" "$HERDR_PIN_SHA256"
  run_installer "$HERDR_INSTALL" "$case_dir"
  expect_code 0 "$RUN_RC" "Herdr installer with the pinned asset: $RUN_ERR"
  [ -x "$case_dir/dest/herdr" ] || fail "Herdr installer must install the pinned asset"
  assert_equals "herdr 0.9.5" "$("$case_dir/dest/herdr" --version)" \
    "Herdr installer must install the downloaded asset"

  case_dir=$(installer_world herdr-old-protocol)
  write_fake_herdr "$case_dir/asset" 0.9.5 15
  fake_sha256 "$case_dir" "$HERDR_PIN_SHA256"
  run_installer "$HERDR_INSTALL" "$case_dir"
  expect_code 1 "$RUN_RC" "Herdr installer with a protocol 15 build"
  assert_contains "$RUN_ERR" "below the required floor 16" \
    "Herdr installer must refuse a build below protocol floor 16"
  pass "Herdr installer fetches the pinned 0.9.5 asset, verifies its checksum, and gates the protocol floor"
}

test_treehouse_installer_pins_exact_version_and_checksums() {
  local case_dir
  case_dir=$(installer_world treehouse-mismatch)
  write_fake_treehouse_archive "$case_dir" 3.1.3
  run_installer "$TREEHOUSE_INSTALL" "$case_dir"
  expect_code 1 "$RUN_RC" "Treehouse installer with an off-pin archive"
  assert_contains "$RUN_ERR" "checksum mismatch for treehouse-v3.1.3-linux-amd64.tar.gz (expected $TREEHOUSE_PIN_SHA256" \
    "Treehouse installer must refuse an archive whose SHA-256 is not the pin"
  assert_absent "$case_dir/dest/treehouse" "Treehouse installer must not install an off-pin archive"
  assert_equals "https://github.com/kunchenguid/treehouse/releases/download/v3.1.3/treehouse-v3.1.3-linux-amd64.tar.gz" \
    "$(grep '^https://' "$case_dir/curl.log")" \
    "Treehouse installer must fetch the 3.1.3 Linux amd64 archive from kunchenguid/treehouse"
  assert_equals "--max-filesize" "$(grep -x -- '--max-filesize' "$case_dir/curl.log")" \
    "Treehouse installer must bound the download size"

  case_dir=$(installer_world treehouse-match)
  write_fake_treehouse_archive "$case_dir" 3.1.3
  fake_sha256 "$case_dir" "$TREEHOUSE_PIN_SHA256"
  run_installer "$TREEHOUSE_INSTALL" "$case_dir"
  expect_code 0 "$RUN_RC" "Treehouse installer with the pinned archive: $RUN_ERR"
  [ -x "$case_dir/dest/treehouse" ] || fail "Treehouse installer must install the pinned archive's binary"
  assert_equals "v3.1.3" "$("$case_dir/dest/treehouse" --version)" \
    "Treehouse installer must install the archive's treehouse binary"
  pass "Treehouse installer fetches the pinned 3.1.3 archive and verifies its checksum"
}

test_cleanup_only_targets_job_owned_lab_sessions() {
  assert_grep 'fm-lab-' "$CLEANUP" \
    "cleanup must only consider fm-lab-* session names"
  assert_grep 'default == false' "$CLEANUP" \
    "cleanup must refuse default sessions"
  assert_grep 'snapshot' "$CLEANUP" \
    "cleanup must support a pre-suite snapshot"
  assert_grep 'teardown' "$CLEANUP" \
    "cleanup must support post-suite teardown of the delta"
  # Must not call ambient server stop.
  assert_no_grep 'server stop' "$CLEANUP" \
    "cleanup must never call ambient herdr server stop"
  pass "cleanup is bounded to job-owned fm-lab-* sessions"
}

test_ci_wires_installers_and_required_lane() {
  assert_grep 'tests-herdr:' "$CI" "CI must define the required Herdr Behavior job"
  assert_grep 'fm-install-herdr.sh' "$CI" "CI must call the Herdr installer"
  assert_grep 'fm-install-treehouse.sh' "$CI" "CI must call the Treehouse installer"
  assert_grep 'fm-herdr-ci-cleanup.sh snapshot' "$CI" "CI must snapshot sessions before the suite"
  assert_grep 'fm-herdr-ci-cleanup.sh teardown' "$CI" "CI must teardown job-owned sessions after"
  assert_grep "fail-on-gate-skip 'herdr not found'" "$CI" \
    "CI Herdr lane must fail on herdr-not-found"
  assert_grep 'family real-herdr-gated' "$CI" \
    "CI Herdr lane must run only the real-herdr-gated family"
  assert_grep 'lane portable-parallel-1' "$CI" \
    "portable CI must run parallel shard 1"
  assert_grep 'lane portable-parallel-2' "$CI" \
    "portable CI must run parallel shard 2"
  # The serial lanes are a matrix job, so each shard's lane name is composed
  # from its own matrix entry rather than written out once per shard.
  # shellcheck disable=SC2016 # The workflow's own literal, matched verbatim.
  assert_grep 'portable-serial-${{ matrix.shard }}of${{ strategy.job-total }}' "$CI" \
    "portable CI must compose each serial shard lane from its matrix entry"
  assert_grep 'shard: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]' "$CI" \
    "portable CI must run every serial shard"
  assert_grep 'fm-test-run.sh --check-coverage' "$CI" \
    "CI must prove portable lanes and Herdr partition the complete inventory"
  # Live harness credential tests must stay out of the default Herdr lane.
  assert_no_grep 'live-harness-optin' "$CI" \
    "CI must not run live-harness-optin in the required Herdr lane"
  assert_no_grep 'FM_AFK_PI_HERDR_E2E' "$CI" \
    "CI must not enable live Pi/Herdr credential tests"
  assert_no_grep 'FM_SEND_MARKER_HERDR_E2E' "$CI" \
    "CI must not enable live marker Herdr credential tests"
  pass "CI wires pinned installers into a required serial Herdr lane"
}

test_herdr_installer_pins_exact_version_and_checksums
test_treehouse_installer_pins_exact_version_and_checksums
test_cleanup_only_targets_job_owned_lab_sessions
test_ci_wires_installers_and_required_lane
