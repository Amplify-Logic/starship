#!/usr/bin/env bash
# Behavior tests for bin/fm-home-port.sh: portable allowlist, loud secret
# refusal, machine-local refuse list, and secret-content scan.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PORT="$ROOT/bin/fm-home-port.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-port)

seed_home() {
  local home=$1
  mkdir -p "$home/data" "$home/config" "$home/state" "$home/projects"
  printf '# Captain\n- test captain\n' > "$home/data/captain.md"
  printf '# Learnings\n- test learning\n' > "$home/data/learnings.md"
  printf '## Queued\n- [ ] demo - demo item (repo: alpha)\n' > "$home/data/backlog.md"
  printf 'herdr\n' > "$home/config/backend"
  printf 'cursor\n' > "$home/config/crew-harness"
  printf '{ "default": { "harness": "cursor" } }\n' > "$home/config/crew-dispatch.json"
}

test_export_copies_portable_only() {
  local home="$TMP_ROOT/export-home"
  local dest="$TMP_ROOT/export-dest"
  seed_home "$home"
  printf 'SECRET=1\n' > "$home/.env"
  printf 'live-pane\n' > "$home/state/task.meta"
  printf 'clone\n' > "$home/projects/README"
  printf 'registry\n' > "$home/data/projects.md"
  mkdir -p "$dest"

  local out
  out=$("$PORT" export --home "$home" --dest "$dest" 2>&1) || fail "export failed: $out"
  assert_contains "$out" 'REFUSED: .env' "export did not loudly refuse .env"
  assert_contains "$out" 'REFUSED: state/' "export did not loudly refuse state/"
  assert_contains "$out" 'REFUSED: projects/' "export did not loudly refuse projects/"
  assert_contains "$out" 'PORTABLE: data/captain.md' "export missed captain.md"
  assert_contains "$out" 'EXPORT_OK:' "export missed EXPORT_OK"

  assert_present "$dest/data/captain.md" "captain.md not exported"
  assert_present "$dest/data/learnings.md" "learnings.md not exported"
  assert_present "$dest/data/backlog.md" "backlog.md not exported"
  assert_present "$dest/config/backend" "backend not exported"
  assert_absent "$dest/.env" ".env must not be exported"
  assert_absent "$dest/state" "state/ must not be exported"
  assert_absent "$dest/projects" "projects/ must not be exported"
  assert_absent "$dest/data/projects.md" "projects.md must not be exported"
  pass "export copies portable allowlist and loudly refuses machine-local/secrets"
}

test_export_refuses_explicit_env_include() {
  local home="$TMP_ROOT/refuse-include-home"
  seed_home "$home"
  printf 'FMX_PAIRING_TOKEN=nope\n' > "$home/.env"

  local out rc=0
  out=$("$PORT" export --home "$home" --dest "$TMP_ROOT/refuse-include-dest" --include .env 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "export --include .env must fail loudly, got: $out"
  assert_contains "$out" 'REFUSED:' "explicit .env include did not print REFUSED"
  pass "export refuses explicit .env include with non-zero exit"
}

test_scan_detects_embedded_secret() {
  local dirty="$TMP_ROOT/dirty-file.md"
  # Deliberate fake token shape for the scanner; not a real credential.
  printf 'token ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa embedded\n' > "$dirty"

  local out rc=0
  out=$("$PORT" scan "$dirty" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "scan must fail on ghp_ token, got: $out"
  assert_contains "$out" 'SECRET_HIT:' "scan missed SECRET_HIT marker"
  pass "scan fails loudly on embedded GitHub token"
}

test_scan_detects_secret_without_leading_space() {
  local dirty="$TMP_ROOT/dirty-env-file.md"
  # Deliberate fake token shape for the scanner; not a real credential.
  printf 'GITHUB_TOKEN=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$dirty"

  local out rc=0
  out=$("$PORT" scan "$dirty" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "scan must fail on GITHUB_TOKEN=ghp_ shape, got: $out"
  assert_contains "$out" 'SECRET_HIT:' "no-space token scan missed SECRET_HIT marker"
  pass "scan fails loudly on token without leading whitespace"
}

test_export_aborts_when_portable_file_contains_secret() {
  local home="$TMP_ROOT/secret-in-portable"
  local dest="$TMP_ROOT/secret-in-portable-dest"
  seed_home "$home"
  # Deliberate fake token shape for the scanner; not a real credential.
  printf 'leak sk-ant-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >> "$home/data/captain.md"
  mkdir -p "$dest"

  local out rc=0
  out=$("$PORT" export --home "$home" --dest "$dest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "export must abort when portable file has a secret, got: $out"
  assert_contains "$out" 'SECRET_HIT:' "export secret abort missing SECRET_HIT"
  pass "export aborts when allowlisted file embeds a credential"
}

test_import_round_trip_and_refuses_contaminated_source() {
  local home="$TMP_ROOT/import-src-home"
  local stage="$TMP_ROOT/import-stage"
  local dest_home="$TMP_ROOT/import-dest-home"
  seed_home "$home"
  mkdir -p "$stage" "$dest_home/data" "$dest_home/config"

  "$PORT" export --home "$home" --dest "$stage" >/dev/null 2>&1 \
    || fail "export for import round-trip failed"
  local out
  out=$("$PORT" import --source "$stage" --home "$dest_home" 2>&1) \
    || fail "import failed: $out"
  assert_contains "$out" 'IMPORT_OK:' "import missed IMPORT_OK"
  assert_present "$dest_home/data/captain.md" "import did not write captain.md"
  assert_present "$dest_home/config/crew-harness" "import did not write crew-harness"

  mkdir -p "$stage/state"
  printf 'bad\n' > "$stage/state/x.meta"
  local rc=0
  out=$("$PORT" import --source "$stage" --home "$dest_home" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "import must refuse source with state/, got: $out"
  assert_contains "$out" 'REFUSED:' "contaminated import missing REFUSED"
  pass "import round-trips portable files and refuses contaminated source"
}

test_help_mentions_secrets_policy() {
  local out
  out=$("$PORT" --help 2>&1) || fail "help failed"
  assert_contains "$out" 'docs/porting.md' "help missing docs/porting.md pointer"
  assert_contains "$out" 'Secrets' "help missing secrets policy mention"
  pass "help points at porting doc and states secrets policy"
}

test_export_copies_portable_only
test_export_refuses_explicit_env_include
test_scan_detects_embedded_secret
test_scan_detects_secret_without_leading_space
test_export_aborts_when_portable_file_contains_secret
test_import_round_trip_and_refuses_contaminated_source
test_help_mentions_secrets_policy

echo "# all fm-home-port tests passed"
