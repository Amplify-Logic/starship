#!/usr/bin/env bash
# Behavior tests for bin/fm-home-port.sh: portable allowlist, loud secret
# refusal, machine-local refuse list, secret-content scan, advisory
# --warn-machine-local, and destination verify.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PORT="$ROOT/bin/fm-home-port.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-port)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# Hermetic backend detection for verify cases that pin config/backend.
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

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

# Minimal toolchain so verify's bootstrap detect-only check can pass under PATH.
make_verify_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node git gh-axi chrome-devtools-axi lavish-axi agent
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] && exit 0
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 'no-mistakes version v1.31.2 (fake)'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' '0.1.1'; exit 0; }
[ "${1:-}" = update ] && [ "${2:-}" = --help ] && {
  printf '%s\n' 'usage: tasks-axi update'
  printf '%s\n' '  --archive-body'
  exit 0
}
[ "${1:-}" = mv ] && [ "${2:-}" = --help ] && {
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
}
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
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
  assert_contains "$out" 'verify' "help missing verify subcommand"
  assert_contains "$out" '--warn-machine-local' "help missing --warn-machine-local"
  pass "help points at porting doc and states secrets policy"
}

test_scan_warn_machine_local_is_advisory() {
  local dirty="$TMP_ROOT/machine-local.md" out rc=0
  # Deliberate synthetic PII shapes for the advisory scanner; not real contact data.
  # Use a non-placeholder email so the shared allowlist does not filter it.
  printf 'contact port-test@example.com\n' > "$dirty"
  printf 'CLAUDE_CONFIG_DIR=/Users/exampleuser/starship/state/claude-alt-account\n' >> "$dirty"

  out=$("$PORT" scan --warn-machine-local "$dirty" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "advisory machine-local hits must not change exit code, got rc=$rc out=$out"
  assert_contains "$out" 'SCAN_CLEAN:' "credential scan should still be clean"
  assert_contains "$out" 'MACHINE_LOCAL_HIT:' "expected MACHINE_LOCAL_HIT for email or /Users path"
  assert_contains "$out" 'MACHINE_LOCAL_WARN:' "expected MACHINE_LOCAL_WARN summary"
  pass "scan --warn-machine-local reports machine-local hits without failing"
}

test_scan_warn_machine_local_does_not_mask_secrets() {
  local dirty="$TMP_ROOT/secret-and-path.md" out rc=0
  printf 'token ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$dirty"
  printf 'path=/Users/exampleuser/starship\n' >> "$dirty"

  out=$("$PORT" scan --warn-machine-local "$dirty" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "secret hit must still fail with --warn-machine-local, got: $out"
  assert_contains "$out" 'SECRET_HIT:' "secret scan must still report SECRET_HIT"
  assert_contains "$out" 'MACHINE_LOCAL_HIT:' "advisory pass should still report /Users path"
  pass "scan --warn-machine-local keeps credential failures hard"
}

test_verify_fails_missing_portable_files() {
  local home="$TMP_ROOT/verify-missing" out rc=0 fakebin
  mkdir -p "$home/data" "$home/config" "$home/state" "$home/projects"
  fakebin=$(make_verify_fakebin "$TMP_ROOT/verify-missing-bin")
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" "$PORT" verify --home "$home" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify must fail without portable files, got: $out"
  assert_contains "$out" 'VERIFY_FAIL: portable-files' "missing portable-files failure"
  assert_contains "$out" 'VERIFY_FAILED:' "expected VERIFY_FAILED summary"
  pass "verify fails when portable files are missing"
}

test_verify_fails_unknown_backend_and_unverified_harness() {
  local home="$TMP_ROOT/verify-bad-config" out rc=0 fakebin
  seed_home "$home"
  printf 'not-a-backend\n' > "$home/config/backend"
  printf 'kimi\n' > "$home/config/crew-harness"
  rm -f "$home/config/crew-dispatch.json"
  fakebin=$(make_verify_fakebin "$TMP_ROOT/verify-bad-config-bin")
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" "$PORT" verify --home "$home" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify must fail on unknown backend / unverified harness, got: $out"
  assert_contains "$out" 'VERIFY_FAIL: backend' "expected backend failure"
  assert_contains "$out" 'VERIFY_FAIL: crew-harness' "expected crew-harness failure"
  pass "verify fails on unknown backend and unverified crew-harness"
}

test_verify_passes_ready_home() {
  local home="$TMP_ROOT/verify-ok" out rc=0 fakebin
  seed_home "$home"
  printf 'tmux\n' > "$home/config/backend"
  printf 'cursor\n' > "$home/config/crew-harness"
  rm -f "$home/config/crew-dispatch.json"
  fakebin=$(make_verify_fakebin "$TMP_ROOT/verify-ok-bin")
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$PORT" verify --home "$home" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "verify should pass a ready home, got rc=$rc out=$out"
  assert_contains "$out" 'VERIFY_PASS: portable-files' "portable-files should pass"
  assert_contains "$out" 'VERIFY_PASS: backend' "backend should pass"
  assert_contains "$out" 'VERIFY_PASS: crew-harness' "crew-harness should pass"
  assert_contains "$out" 'VERIFY_OK:' "expected VERIFY_OK summary"
  pass "verify passes a ready destination home"
}

test_export_copies_portable_only
test_export_refuses_explicit_env_include
test_scan_detects_embedded_secret
test_scan_detects_secret_without_leading_space
test_export_aborts_when_portable_file_contains_secret
test_import_round_trip_and_refuses_contaminated_source
test_help_mentions_secrets_policy
test_scan_warn_machine_local_is_advisory
test_scan_warn_machine_local_does_not_mask_secrets
test_verify_fails_missing_portable_files
test_verify_fails_unknown_backend_and_unverified_harness
test_verify_passes_ready_home

echo "# all fm-home-port tests passed"
