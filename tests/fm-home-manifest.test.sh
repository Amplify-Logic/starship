#!/usr/bin/env bash
# Behavior tests for the fork-owned environment-fidelity manifest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST="$ROOT/bin/fm-home-manifest.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-manifest)

assert_present "$MANIFEST" "bin/fm-home-manifest.sh is missing"
[ -x "$MANIFEST" ] || fail "bin/fm-home-manifest.sh must be executable"

# A tool that answers --version, one that answers only version, and one that
# answers nothing, so each probe branch is exercised by a real execution.
make_probe_bin() {
  local dir=$1
  mkdir -p "$dir"
  # Quoted heredocs: the $1 below belongs to the generated probe, not to this
  # test, so it must reach the file unexpanded.
  cat <<'ALPHA' > "$dir/probe-alpha"
#!/bin/sh
[ "$1" = --version ] && { echo "alpha 1.2.3"; exit 0; }
exit 1
ALPHA
  cat <<'BETA' > "$dir/probe-beta"
#!/bin/sh
[ "$1" = version ] && { echo "beta v9"; exit 0; }
exit 1
BETA
  cat <<'SILENT' > "$dir/probe-silent"
#!/bin/sh
exit 1
SILENT
  chmod +x "$dir/probe-alpha" "$dir/probe-beta" "$dir/probe-silent"
  printf '%s\n' "$dir"
}

test_reports_backend_and_tool_versions() {
  local bin out
  bin=$(make_probe_bin "$TMP_ROOT/versions/bin")
  out=$(PATH="$bin:$PATH" "$MANIFEST" tmux probe-alpha probe-beta) \
    || fail "manifest should exit 0"
  assert_contains "$out" 'backend=tmux' "manifest missing the resolved backend"
  assert_contains "$out" 'generated=' "manifest missing the generated stamp"
  assert_contains "$out" 'probe-alpha=alpha 1.2.3' "--version probe not used"
  assert_contains "$out" 'probe-beta=beta v9' "version probe not used"
  pass "manifest reports the backend and a version line per resolved tool"
}

test_distinguishes_missing_from_unparseable() {
  local bin out
  bin=$(make_probe_bin "$TMP_ROOT/missing/bin")
  out=$(PATH="$bin:$PATH" "$MANIFEST" tmux probe-silent definitely-not-installed) \
    || fail "manifest should exit 0 with a missing tool"
  assert_contains "$out" 'definitely-not-installed=MISSING' \
    "a tool absent from PATH must report MISSING"
  assert_contains "$out" 'probe-silent=unknown' \
    "a present tool with no parseable version must report unknown"
  pass "manifest separates an absent binary from an unparseable one"
}

test_output_is_stable_and_deduplicated() {
  local bin out first second
  bin=$(make_probe_bin "$TMP_ROOT/stable/bin")
  out=$(PATH="$bin:$PATH" "$MANIFEST" tmux probe-beta probe-alpha probe-beta)
  [ "$(printf '%s\n' "$out" | grep -c '^probe-beta=')" -eq 1 ] \
    || fail "a repeated tool must appear once"
  first=$(printf '%s\n' "$out" | sed -n '1p')
  second=$(printf '%s\n' "$out" | sed -n '2p')
  case "$first" in backend=*) ;; *) fail "backend must come first, got: $first" ;; esac
  case "$second" in generated=*) ;; *) fail "generated must come second, got: $second" ;; esac
  printf '%s\n' "$out" | sed -n '3,$p' | grep -v '^$' > "$TMP_ROOT/stable/tools"
  sort -u "$TMP_ROOT/stable/tools" > "$TMP_ROOT/stable/tools.sorted"
  cmp -s "$TMP_ROOT/stable/tools" "$TMP_ROOT/stable/tools.sorted" \
    || fail "tool lines must be sorted so two manifests diff cleanly"
  pass "manifest output is ordered and deduplicated for diffing"
}

test_refuses_without_a_backend() {
  local rc=0
  "$MANIFEST" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "manifest must refuse when no backend is given"
  pass "manifest refuses an empty argument list"
}

# Bootstrap's dispatch into this script: the plain subcommand must still
# produce a manifest, and a trailing argument must be refused with the usage
# line rather than silently dropped.
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_bootstrap_home() {
  local case_dir=$1
  mkdir -p "$case_dir/home/config"
  printf 'tmux\n' > "$case_dir/home/config/backend"
  printf '%s\n' "$case_dir/home"
}

test_bootstrap_dispatch_prints_manifest() {
  local case_dir home fakebin out
  case_dir="$TMP_ROOT/dispatch-ok"
  home=$(make_bootstrap_home "$case_dir")
  fakebin=$(fm_fakebin "$case_dir")
  fm_fake_exit0 "$fakebin" node
  out=$(
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-bootstrap.sh" manifest
  ) || fail "fm-bootstrap.sh manifest should exit 0, got: $out"
  assert_contains "$out" 'backend=tmux' "dispatched manifest missing the backend"
  assert_contains "$out" 'generated=' "dispatched manifest missing the generated stamp"
  pass "fm-bootstrap.sh manifest dispatches into the fork script"
}

test_bootstrap_dispatch_refuses_extra_arguments() {
  local case_dir home fakebin out err rc=0
  case_dir="$TMP_ROOT/dispatch-extra"
  home=$(make_bootstrap_home "$case_dir")
  fakebin=$(fm_fakebin "$case_dir")
  fm_fake_exit0 "$fakebin" node
  err="$case_dir/stderr"
  out=$(
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-bootstrap.sh" manifest extra 2>"$err"
  ) || rc=$?
  [ "$rc" -eq 1 ] || fail "manifest with a trailing argument must exit 1, got $rc: $out"
  assert_contains "$(cat "$err")" 'usage: fm-bootstrap.sh manifest' \
    "manifest with a trailing argument must print the usage line on stderr"
  assert_not_contains "$out" 'backend=' "a refused manifest must not print a manifest"
  pass "fm-bootstrap.sh manifest refuses trailing arguments with the usage line"
}

test_reports_backend_and_tool_versions
test_distinguishes_missing_from_unparseable
test_output_is_stable_and_deduplicated
test_refuses_without_a_backend
test_bootstrap_dispatch_prints_manifest
test_bootstrap_dispatch_refuses_extra_arguments

echo "# all fm-home-manifest tests passed"
