#!/usr/bin/env bash
# Behavior tests for bin/fm-toolchain-lib.sh: the runtime version-drift alarm
# that compares docs/toolchain-manifest.tsv against PATH reality at session
# start.
#
# Contracts under test:
#   - One TOOLCHAIN_DRIFT line per drifted runtime, carrying installed version,
#     certified version, evidence pointer, and rationale.
#   - Several drifted runtimes in one manifest each get their own line. The
#     fixture that covers this is synthetic, not a snapshot of live reality:
#     Claude 2.1.220 against 2.1.217, Codex 0.144.6 against 0.144.4, and Kimi
#     0.31.1 against 0.27.0.
#   - Silent for a runtime whose installed version matches.
#   - Silent for an absent binary (MISSING already owns that) and for a banner
#     with no parseable version.
#   - FAILS OPEN: drift never changes exit status, and bootstrap keeps going.
#   - Version parsing handles every real banner shape in the manifest.
#   - Missing manifest is silent.
#   - The tracked manifest is well formed and every evidence pointer resolves.
#   - bin/fm-primary.sh's KIMI_CERTIFIED_VERSION still transcribes the kimi row's
#     certified column.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-toolchain-lib.sh disable=SC1091
. "$ROOT/bin/fm-toolchain-lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-toolchain-drift-tests)
TAB=$(printf '\t')

# Write a manifest at <path> from "runtime|command|certified|why|evidence" rows.
write_manifest() {
  local path=$1 row
  shift
  {
    printf '# a comment line, ignored\n'
    printf '\n'
    for row in "$@"; do
      printf '%s\n' "$row" | tr '|' "$TAB"
    done
  } > "$path"
}

# Drop a stub binary at <dir>/<name> printing <banner> for --version.
stub_runtime() {
  local dir=$1 name=$2 banner=$3
  cat > "$dir/$name" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { printf '%s\n' '$banner'; exit 0; }
exit 0
SH
  chmod +x "$dir/$name"
}

new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/bin"
  printf '%s\n' "$w"
}

test_reports_one_line_per_drifted_runtime() {
  local w out
  w=$(new_world three-gaps)
  stub_runtime "$w/bin" claude '2.1.220 (Claude Code)'
  stub_runtime "$w/bin" codex 'codex-cli 0.144.6'
  stub_runtime "$w/bin" kimi '0.31.1'
  write_manifest "$w/manifest.tsv" \
    'claude|claude|2.1.217|subagent-guard deny keys certified here|docs/subagent-guard.md' \
    'codex|codex|0.144.4|native SessionStart injection certified here|docs/sessionstart-nudge.md' \
    'kimi|kimi|0.27.0|the primary launcher warns on drift instead of blocking|docs/kimi-harness.md'
  out=$(
    PATH="$w/bin:/usr/bin:/bin" FM_TOOLCHAIN_MANIFEST="$w/manifest.tsv" \
      bash -c '. "$0"; fm_toolchain_check /unused' "$ROOT/bin/fm-toolchain-lib.sh"
  )
  assert_contains "$out" \
    'TOOLCHAIN_DRIFT: claude installed 2.1.220, certified 2.1.217 (docs/subagent-guard.md)' \
    "Claude drift was not reported"
  assert_contains "$out" \
    'TOOLCHAIN_DRIFT: codex installed 0.144.6, certified 0.144.4 (docs/sessionstart-nudge.md)' \
    "Codex drift was not reported"
  assert_contains "$out" \
    'TOOLCHAIN_DRIFT: kimi installed 0.31.1, certified 0.27.0 (docs/kimi-harness.md)' \
    "Kimi drift was not reported"
  assert_contains "$out" 'the primary launcher warns on drift instead of blocking' \
    "the drift line dropped the manifest rationale"
  [ "$(printf '%s\n' "$out" | grep -c '^TOOLCHAIN_DRIFT: ')" = 3 ] \
    || fail "expected exactly three drift lines, got: $out"
  pass "reports one drift line per drifted runtime"
}

test_silent_when_installed_matches_certified() {
  local w out
  w=$(new_world matching)
  stub_runtime "$w/bin" pi '0.80.10'
  write_manifest "$w/manifest.tsv" \
    'pi|pi|0.80.10|primary turn-end extension certified here|docs/watcher-continuity.md'
  out=$(
    PATH="$w/bin:/usr/bin:/bin" FM_TOOLCHAIN_MANIFEST="$w/manifest.tsv" \
      bash -c '. "$0"; fm_toolchain_check /unused' "$ROOT/bin/fm-toolchain-lib.sh"
  )
  [ -z "$out" ] || fail "a matching runtime must be silent, got: $out"
  pass "silent when the installed version matches the certified one"
}

test_silent_for_absent_binary_and_unparseable_banner() {
  local w out
  w=$(new_world absent-and-garbled)
  stub_runtime "$w/bin" weird 'unstable build, no version here'
  write_manifest "$w/manifest.tsv" \
    'ghost|definitely-not-installed-runtime|1.0.0|nothing here|docs/architecture.md' \
    'weird|weird|1.0.0|banner shape changed|docs/architecture.md'
  out=$(
    PATH="$w/bin:/usr/bin:/bin" FM_TOOLCHAIN_MANIFEST="$w/manifest.tsv" \
      bash -c '. "$0"; fm_toolchain_check /unused' "$ROOT/bin/fm-toolchain-lib.sh"
  )
  [ -z "$out" ] || fail "an absent binary or unparseable banner must be silent, got: $out"
  pass "silent for an absent binary and for an unparseable version banner"
}

test_silent_when_manifest_is_missing() {
  local w out
  w=$(new_world no-manifest)
  out=$(
    FM_TOOLCHAIN_MANIFEST="$w/nope.tsv" \
      bash -c '. "$0"; fm_toolchain_check /unused' "$ROOT/bin/fm-toolchain-lib.sh"
  )
  [ -z "$out" ] || fail "a missing manifest must be silent, got: $out"
  pass "silent when the manifest is missing"
}

test_fails_open_on_drift() {
  local w rc
  w=$(new_world fail-open)
  stub_runtime "$w/bin" claude '2.1.220 (Claude Code)'
  write_manifest "$w/manifest.tsv" \
    'claude|claude|2.1.217|certified here|docs/subagent-guard.md'
  set +e
  PATH="$w/bin:/usr/bin:/bin" FM_TOOLCHAIN_MANIFEST="$w/manifest.tsv" \
    bash -c '. "$0"; fm_toolchain_check /unused' "$ROOT/bin/fm-toolchain-lib.sh" >/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "drift must not change exit status; got $rc"
  pass "fails open: reported drift leaves exit status 0"
}

test_parses_every_real_banner_shape() {
  local banner expected got
  # Exactly the banners the manifest's runtimes print on a real machine.
  while IFS='|' read -r banner expected; do
    [ -n "$banner" ] || continue
    got=$(printf '%s\n' "$banner" | fm_toolchain_parse_version)
    [ "$got" = "$expected" ] \
      || fail "banner '$banner' parsed as '$got', expected '$expected'"
  done <<'EOF'
2.1.220 (Claude Code)|2.1.220
codex-cli 0.144.6|0.144.6
0.31.1|0.31.1
2026.07.23-e383d2b|2026.07.23-e383d2b
0.80.10|0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]|0.2.103
EOF
  pass "parses every real runtime --version banner shape"
}

test_tracked_manifest_is_well_formed() {
  local manifest rows
  manifest="$ROOT/docs/toolchain-manifest.tsv"
  [ -f "$manifest" ] || fail "docs/toolchain-manifest.tsv is missing"
  rows=0
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    # Five tab-separated columns, none empty.
    printf '%s\n' "$line" | awk -F'\t' '
      NF != 5 { exit 1 }
      { for (i = 1; i <= NF; i++) if ($i ~ /^[ \t]*$/) exit 1 }
    ' || fail "manifest row is not five non-empty tab-separated columns: $line"
    # The evidence column must point at tracked material that exists.
    evidence=$(printf '%s\n' "$line" | awk -F'\t' '{ print $5 }')
    [ -f "$ROOT/$evidence" ] \
      || fail "manifest evidence pointer does not resolve: $evidence"
    # The certified version must actually appear in its evidence file, so a row
    # can never record a version nobody wrote down.
    certified=$(printf '%s\n' "$line" | awk -F'\t' '{ print $3 }')
    grep -qF "$certified" "$ROOT/$evidence" \
      || fail "certified version $certified is not recorded in $evidence"
    rows=$((rows + 1))
  done < "$manifest"
  [ "$rows" -ge 3 ] || fail "expected at least three manifest rows, got $rows"
  pass "the tracked manifest is well formed and every certified version is evidenced"
}

# bin/fm-primary.sh's KIMI_CERTIFIED_VERSION is a hand-copied second copy of the
# kimi row's certified column, and a version constant silently drifting from its
# source is the exact failure this manifest exists to prevent, so the
# transcription is proved here instead of parsed at launch time.
# KIMI_VALIDATED_VERSION has no manifest counterpart and is deliberately free to
# differ, so it gets no such guard. This lives in the manifest's own suite so a
# manifest-only bump selects it, which the launcher's suite would not.
test_kimi_certified_constant_matches_manifest() {
  local constant certified
  constant=$(sed -n 's/^KIMI_CERTIFIED_VERSION=\(.*\)$/\1/p' "$ROOT/bin/fm-primary.sh")
  [ -n "$constant" ] || fail "bin/fm-primary.sh no longer defines KIMI_CERTIFIED_VERSION"
  # Match the row by its tab-separated runtime column, never a loose substring,
  # so a mention of kimi elsewhere in the manifest cannot satisfy this.
  certified=$(awk -F'\t' '
    /^#/ { next }
    $1 == "kimi" { print $3; found = 1 }
    END { exit !found }
  ' "$ROOT/docs/toolchain-manifest.tsv") \
    || fail "docs/toolchain-manifest.tsv has no kimi row to transcribe"
  [ "$constant" = "$certified" ] \
    || fail "KIMI_CERTIFIED_VERSION is $constant but the manifest's kimi certified column is $certified"
  pass "bin/fm-primary.sh's KIMI_CERTIFIED_VERSION transcribes the manifest's kimi certified column"
}

test_bootstrap_wires_the_drift_line() {
  local w fakebin out
  w=$(new_world bootstrap-wire)
  fakebin=$(fm_fakebin "$w/fakebin")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi quota-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 'no-mistakes version v1.31.2'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' '0.1.1'; exit 0; }
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path>'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  stub_runtime "$fakebin" kimi '0.31.1'
  write_manifest "$w/manifest.tsv" \
    'kimi|kimi|0.27.0|the primary launcher warns on drift instead of blocking|docs/kimi-harness.md'

  mkdir -p "$w/repo" "$w/home/config" "$w/home/state" "$w/home/data" "$w/home/projects"
  git -C "$w/repo" init -q
  git -C "$w/repo" checkout -q -b main
  printf 'x\n' > "$w/repo/README.md"
  git -C "$w/repo" add README.md
  git -C "$w/repo" commit -qm init

  out=$(
    PATH="$fakebin:/usr/bin:/bin" \
    FM_ROOT_OVERRIDE="$w/repo" \
    FM_HOME="$w/home" \
    FM_TOOLCHAIN_MANIFEST="$w/manifest.tsv" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
      "$ROOT/bin/fm-bootstrap.sh" 2>&1
  )
  rc=$?
  assert_contains "$out" \
    'TOOLCHAIN_DRIFT: kimi installed 0.31.1, certified 0.27.0 (docs/kimi-harness.md)' \
    "bootstrap did not surface the TOOLCHAIN_DRIFT line"
  [ "$rc" -eq 0 ] || fail "bootstrap must stay fail-open on drift; exited $rc"
  pass "bootstrap wires the TOOLCHAIN_DRIFT diagnostic and stays fail-open"
}

test_skill_documents_the_drift_line() {
  assert_grep 'TOOLCHAIN_DRIFT' "$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md" \
    "bootstrap-diagnostics skill lost TOOLCHAIN_DRIFT handling"
  assert_grep 'TOOLCHAIN_DRIFT' "$ROOT/bin/fm-bootstrap.sh" \
    "fm-bootstrap.sh header lost the TOOLCHAIN_DRIFT line format"
  pass "the handling skill and the bootstrap header document the drift line"
}

test_reports_one_line_per_drifted_runtime
test_silent_when_installed_matches_certified
test_silent_for_absent_binary_and_unparseable_banner
test_silent_when_manifest_is_missing
test_fails_open_on_drift
test_parses_every_real_banner_shape
test_tracked_manifest_is_well_formed
test_kimi_certified_constant_matches_manifest
test_bootstrap_wires_the_drift_line
test_skill_documents_the_drift_line
