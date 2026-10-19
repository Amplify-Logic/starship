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
  printf '{ "enabled": true }\n' > "$home/config/primary-handoff"
  printf '7500\n' > "$home/config/startup-memory-budget"
}

# Minimal toolchain so verify's bootstrap detect-only check can pass under PATH.
# Read a version floor from the script that owns it, so a floor bump in
# bin/ never leaves these stubs behind reporting a version bootstrap now
# rejects. The floors themselves are asserted by the suites that own them;
# here they only have to be cleared.
floor_of() {  # <bin-file> <constant>
  local file=$1 name=$2 value
  value=$(sed -n 's/^'"$name"'=\([0-9][0-9.]*\)$/\1/p' "$ROOT/bin/$file" | head -1)
  [ -n "$value" ] || fail "could not read $name from bin/$file"
  printf '%s\n' "$value"
}

make_verify_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # Cursor ships its CLI as cursor-agent; `agent` is the legacy alias. A ready home
  # has the real name installed, which is what bin/fm-bootstrap.sh resolves through
  # fm_cursor_resolve_binary - a bare stub named `agent` proves nothing about Cursor
  # and is correctly refused there.
  fm_fake_exit0 "$fakebin" tmux node git chrome-devtools-axi agent cursor-agent prime-agent
  fm_fake_version_tool "$fakebin" gh-axi FM_TEST_GH_AXI_VERSION "$(floor_of fm-bootstrap.sh GH_AXI_MIN)"
  fm_fake_version_tool "$fakebin" lavish-axi FM_TEST_LAVISH_AXI_VERSION "$(floor_of fm-bootstrap.sh LAVISH_AXI_MIN)"
  fm_fake_version_tool "$fakebin" quota-axi FM_TEST_QUOTA_AXI_VERSION "$(floor_of fm-quota-axi-lib.sh FM_QUOTA_AXI_MIN)"
  fm_fake_version_tool "$fakebin" no-mistakes FM_TEST_NO_MISTAKES_VERSION "$(floor_of fm-bootstrap.sh NO_MISTAKES_MIN)"
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
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { printf '%s\\n' '$(floor_of fm-tasks-axi-lib.sh FM_TASKS_AXI_MIN)'; exit 0; }
[ "\${1:-}" = update ] && [ "\${2:-}" = --help ] && {
  printf '%s\\n' 'usage: tasks-axi update'
  printf '%s\\n' '  --archive-body'
  exit 0
}
[ "\${1:-}" = mv ] && [ "\${2:-}" = --help ] && {
  printf '%s\\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
}
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
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
  printf 'synthetic-capability-proof\n' > "$home/config/action-captain-secret"
  mkdir -p "$home/bridge"
  printf 'scrypt-hash\n' > "$home/bridge/passcode.hash"
  printf 'one-shot-passcode\n' > "$home/data/bridge-view-passcode.txt"
  printf 'interval_seconds = 604800\n' > "$home/config/upstream-watch"
  printf 'path = projects/my-addon\norigin = https://example.invalid/my-addon\n' > "$home/config/addon"
  mkdir -p "$dest"

  local out
  out=$("$PORT" export --home "$home" --dest "$dest" 2>&1) || fail "export failed: $out"
  assert_contains "$out" 'REFUSED: .env' "export did not loudly refuse .env"
  assert_contains "$out" 'REFUSED: state/' "export did not loudly refuse state/"
  assert_contains "$out" 'REFUSED: projects/' "export did not loudly refuse projects/"
  assert_contains "$out" 'REFUSED: config/action-captain-secret' "export did not loudly refuse action capability secret"
  assert_contains "$out" 'REFUSED: bridge/' "export did not loudly refuse bridge secrets"
  assert_contains "$out" 'REFUSED: data/bridge-view-passcode.txt' "export did not loudly refuse the one-shot bridge passcode"
  assert_contains "$out" 'PORTABLE: data/captain.md' "export missed captain.md"
  assert_contains "$out" 'EXPORT_OK:' "export missed EXPORT_OK"

  assert_present "$dest/data/captain.md" "captain.md not exported"
  assert_present "$dest/data/learnings.md" "learnings.md not exported"
  assert_present "$dest/data/backlog.md" "backlog.md not exported"
  assert_present "$dest/config/backend" "backend not exported"
  assert_present "$dest/config/primary-handoff" "manifest-declared primary handoff config not exported"
  assert_present "$dest/config/startup-memory-budget" "manifest-declared startup-memory budget not exported"
  assert_present "$dest/config/upstream-watch" "manifest-declared upstream-watch config not exported"
  assert_present "$dest/config/addon" "manifest-declared private add-on config not exported"
  assert_absent "$dest/.env" ".env must not be exported"
  assert_absent "$dest/config/action-captain-secret" "action capability secret must not be exported"
  assert_absent "$dest/bridge" "bridge/ must not be exported"
  assert_absent "$dest/data/bridge-view-passcode.txt" "bridge passcode envelope must not be exported"
  assert_absent "$dest/state" "state/ must not be exported"
  assert_absent "$dest/projects" "projects/ must not be exported"
  assert_absent "$dest/data/projects.md" "projects.md must not be exported"
  pass "export copies portable allowlist and loudly refuses machine-local/secrets"
}

test_export_skips_absent_upstream_watch() {
  local home="$TMP_ROOT/export-no-watch"
  local dest="$TMP_ROOT/export-no-watch-dest"
  seed_home "$home"
  mkdir -p "$dest"

  local out
  out=$("$PORT" export --home "$home" --dest "$dest" 2>&1) \
    || fail "export without optional upstream-watch failed: $out"
  assert_contains "$out" 'EXPORT_OK:' "export without upstream-watch missed EXPORT_OK"
  assert_absent "$dest/config/upstream-watch" "absent optional upstream-watch must not be invented"
  pass "export skips absent optional upstream-watch"
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
  # kimi is a verified worker (2026-07-23); use a deliberately unverified name here.
  printf 'spaceship\n' > "$home/config/crew-harness"
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
  assert_contains "$out" 'VERIFY_INFO: env' "env check is informational (port refuses .env by construction)"
  assert_contains "$out" 'VERIFY_PASS: backend' "backend should pass"
  assert_contains "$out" 'VERIFY_PASS: crew-harness' "crew-harness should pass"
  assert_contains "$out" 'VERIFY_OK:' "expected VERIFY_OK summary"
  pass "verify passes a ready destination home"
}

test_verify_reports_the_private_addon() {
  local home="$TMP_ROOT/verify-addon" out rc=0 fakebin
  seed_home "$home"
  printf 'tmux\n' > "$home/config/backend"
  rm -f "$home/config/crew-dispatch.json"
  fakebin=$(make_verify_fakebin "$TMP_ROOT/verify-addon-bin")
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$PORT" verify --home "$home" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "verify should pass a home with no add-on, got rc=$rc out=$out"
  assert_contains "$out" 'VERIFY_PASS: addon - no private add-on configured' "a home with no add-on must pass the add-on check"

  printf 'path = projects/my-addon\n' > "$home/config/addon"
  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$PORT" verify --home "$home" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify must fail while the configured add-on is missing, got: $out"
  assert_contains "$out" "VERIFY_FAIL: addon - the add-on checkout $home/projects/my-addon is missing; run bin/fm-addon.sh install" \
    "a missing add-on must fail with its repair"

  mkdir -p "$home/projects/my-addon"
  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$PORT" verify --home "$home" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "verify should pass once the add-on is present, got rc=$rc out=$out"
  assert_contains "$out" 'VERIFY_PASS: addon - private add-on present at' "a present add-on must pass"
  pass "verify reports whether a configured private add-on's checkout is present"
}

test_verify_accepts_prime_agent_worker() {
  local home="$TMP_ROOT/verify-prime-agent" out rc=0 fakebin
  seed_home "$home"
  printf 'tmux\n' > "$home/config/backend"
  printf 'prime-agent\n' > "$home/config/crew-harness"
  rm -f "$home/config/crew-dispatch.json"
  fakebin=$(make_verify_fakebin "$TMP_ROOT/verify-prime-agent-bin")
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$PORT" verify --home "$home" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "verify should accept prime-agent as a ready worker harness, got rc=$rc out=$out"
  assert_contains "$out" "VERIFY_PASS: crew-harness - config/crew-harness=prime-agent is verified and launch binary 'prime-agent' is on PATH" \
    "prime-agent crew-harness should resolve to its launch binary"
  pass "verify accepts prime-agent and checks its launch binary"
}

# Names come from FM_PORT_VERIFIED_HARNESSES so a new verified harness without a
# launch-binary mapping is caught here instead of as a silent mid-verify death.
port_verified_harnesses() {
  local names
  names=$(awk -F'"' '/^FM_PORT_VERIFIED_HARNESSES=/{print $2; exit}' "$PORT")
  [ -n "$names" ] || fail "could not read FM_PORT_VERIFIED_HARNESSES from $PORT"
  printf '%s\n' "$names"
}

test_verify_completes_for_every_verified_harness() {
  local names harness home out rc fakebin
  names=$(port_verified_harnesses)
  fakebin=$(make_verify_fakebin "$TMP_ROOT/verify-every-harness-bin")
  # Identity-named stubs cover mappings like kimi -> kimi; cursor still uses
  # `agent`, which make_verify_fakebin already installs.
  # shellcheck disable=SC2086
  fm_fake_exit0 "$fakebin" $names

  for harness in $names; do
    home="$TMP_ROOT/verify-harness-$harness"
    seed_home "$home"
    printf 'tmux\n' > "$home/config/backend"
    printf '%s\n' "$harness" > "$home/config/crew-harness"
    rm -f "$home/config/crew-dispatch.json"
    rc=0
    out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$PORT" verify --home "$home" 2>&1) || rc=$?
    case "$out" in
      *"VERIFY_PASS: crew-harness"*|*"VERIFY_FAIL: crew-harness"*) ;;
      *)
        fail "verify for crew-harness=$harness died without VERIFY_PASS/VERIFY_FAIL (rc=$rc): $out"
        ;;
    esac
    case "$out" in
      *"VERIFY_OK:"*|*"VERIFY_FAILED:"*) ;;
      *)
        fail "verify for crew-harness=$harness died without a ready aggregate (rc=$rc): $out"
        ;;
    esac
  done
  pass "verify completes for every FM_PORT_VERIFIED_HARNESSES name"
}

seed_charters() {
  local home=$1
  mkdir -p "$home/data/goals"
  printf '# Alpha\n\n## Port of arrival\nsource alpha\n' > "$home/data/goals/alpha.md"
  printf '# Beta\n\n## Port of arrival\nsource beta\n' > "$home/data/goals/beta.md"
  printf 'scratch note\n' > "$home/data/goals/notes.txt"
}

test_goal_charters_travel_and_import_keeps_local_ones() {
  local home="$TMP_ROOT/charter-home"
  local stage="$TMP_ROOT/charter-stage"
  local dest_home="$TMP_ROOT/charter-dest-home"
  local out
  seed_home "$home"
  seed_charters "$home"
  mkdir -p "$stage" "$dest_home/data/goals"
  printf 'destination alpha\n' > "$dest_home/data/goals/alpha.md"
  printf 'destination only\n' > "$dest_home/data/goals/gamma.md"

  out=$("$PORT" export --home "$home" --dest "$stage" 2>&1) || fail "export with charters failed: $out"
  assert_contains "$out" 'PORTABLE: data/goals/alpha.md' "export missed the alpha charter"
  assert_contains "$out" 'PORTABLE: data/goals/beta.md' "export missed the beta charter"
  assert_present "$stage/data/goals/alpha.md" "alpha charter not exported"
  assert_present "$stage/data/goals/beta.md" "beta charter not exported"
  assert_absent "$stage/data/goals/notes.txt" "a non-charter file in data/goals/ must not travel"

  out=$("$PORT" import --source "$stage" --home "$dest_home" 2>&1) || fail "import with charters failed: $out"
  assert_contains "$out" 'IMPORTED: data/goals/beta.md' "import missed the beta charter"
  assert_equals "$(cat "$home/data/goals/alpha.md")" "$(cat "$dest_home/data/goals/alpha.md")" \
    "import must replace the destination copy of a charter that travelled"
  assert_equals 'destination only' "$(cat "$dest_home/data/goals/gamma.md")" \
    "import must keep a destination-only charter"
  pass "goal charters travel through export and import without deleting local charters"
}

test_export_refuses_symlinked_charter() {
  local home="$TMP_ROOT/charter-symlink-home"
  local dest="$TMP_ROOT/charter-symlink-dest"
  local out rc=0
  seed_home "$home"
  seed_charters "$home"
  printf 'outside the home\n' > "$TMP_ROOT/charter-symlink-target"
  ln -s "$TMP_ROOT/charter-symlink-target" "$home/data/goals/linked.md"
  mkdir -p "$dest"

  out=$("$PORT" export --home "$home" --dest "$dest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "export must stop on a symlinked charter, got: $out"
  assert_contains "$out" 'not a regular file' "symlinked charter refusal must say why"
  assert_absent "$dest/data/goals/linked.md" "a symlinked charter must not be exported"
  pass "export stops on a symlinked charter instead of following it"
}

test_import_refuses_symlinked_charter_before_writing() {
  local stage="$TMP_ROOT/charter-bad-stage"
  local dest_home="$TMP_ROOT/charter-bad-dest"
  local out rc=0
  mkdir -p "$stage/data/goals" "$dest_home"
  printf '# Captain\n- staged\n' > "$stage/data/captain.md"
  printf 'outside the bundle\n' > "$TMP_ROOT/charter-bad-target"
  ln -s "$TMP_ROOT/charter-bad-target" "$stage/data/goals/linked.md"

  out=$("$PORT" import --source "$stage" --home "$dest_home" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "import must stop on a symlinked charter, got: $out"
  assert_absent "$dest_home/data/goals/linked.md" "a symlinked charter must not be imported"
  assert_absent "$dest_home/data/captain.md" "a refused import must leave the home untouched"
  pass "import stops on a symlinked charter before writing into the home"
}

# write_data_manifest <file> <data-line>: copy the live manifest with its
# goal-charter data entry replaced, so a per-file or invalid entry is exercised
# without touching the tracked manifest.
write_data_manifest() {
  local file=$1 line=$2
  DATA_LINE="$line" awk '$0 == "data = data/goals/" { print ENVIRON["DATA_LINE"]; next } { print }' \
    "$ROOT/fork-surface.conf" > "$file" || fail "could not write fixture manifest"
  grep -qxF "$line" "$file" || fail "fixture manifest did not take data line: $line"
}

test_per_file_entry_carries_only_the_chosen_charter() {
  local home="$TMP_ROOT/charter-chosen-home"
  local dest="$TMP_ROOT/charter-chosen-dest"
  local manifest="$TMP_ROOT/charter-chosen.conf"
  local out
  seed_home "$home"
  seed_charters "$home"
  write_data_manifest "$manifest" 'data = data/goals/alpha.md'
  mkdir -p "$dest"

  out=$(FM_FORK_SURFACE_MANIFEST="$manifest" "$PORT" export --home "$home" --dest "$dest" 2>&1) \
    || fail "export with a per-file charter entry failed: $out"
  assert_present "$dest/data/goals/alpha.md" "the chosen charter must travel"
  assert_absent "$dest/data/goals/beta.md" "an unchosen charter must stay behind"
  pass "a per-file data entry carries only the chosen charter"
}

test_per_file_entry_refuses_symlinked_goals_dir() {
  local home="$TMP_ROOT/charter-linkdir-home"
  local dest="$TMP_ROOT/charter-linkdir-dest"
  local manifest="$TMP_ROOT/charter-linkdir.conf"
  local out rc=0
  seed_home "$home"
  mkdir -p "$TMP_ROOT/charter-linkdir-target" "$dest"
  printf 'outside the home\n' > "$TMP_ROOT/charter-linkdir-target/alpha.md"
  ln -s "$TMP_ROOT/charter-linkdir-target" "$home/data/goals"
  write_data_manifest "$manifest" 'data = data/goals/alpha.md'

  out=$(FM_FORK_SURFACE_MANIFEST="$manifest" "$PORT" export --home "$home" --dest "$dest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "export must stop on a symlinked data/goals with a per-file entry, got: $out"
  assert_contains "$out" 'is a symlink' "symlinked data/goals refusal must say why"
  assert_absent "$dest/data/goals/alpha.md" "a charter behind a symlinked data/goals must not be exported"
  pass "a per-file data entry refuses a symlinked data/goals directory"
}

test_push_prunes_charters_no_longer_selected() {
  local home="$TMP_ROOT/charter-push-home"
  local bare="$TMP_ROOT/charter-push-remote.git"
  local fakebin out files
  seed_home "$home"
  seed_charters "$home"
  git init -q --bare "$bare" || fail "could not create bare transport"
  fakebin=$(fm_fakebin "$TMP_ROOT/charter-push")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *--jq\ .visibility*) printf 'private\n' ;;
  *--jq\ .private*) printf 'true\n' ;;
esac
SH
  chmod +x "$fakebin/gh"

  push_charters() {
    PATH="$fakebin:$PATH" TMPDIR="$TMP_ROOT" GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0="url.file://$bare.insteadOf" \
      GIT_CONFIG_VALUE_0=https://github.com/captain/portable.git \
      "$PORT" push --remote captain/portable --home "$home" 2>&1
  }

  out=$(push_charters) || fail "first push failed: $out"
  files=$(git -C "$bare" ls-tree -r --name-only main)
  assert_contains "$files" 'data/goals/alpha.md' "first push must carry alpha"
  assert_contains "$files" 'data/goals/beta.md' "first push must carry beta"

  rm "$home/data/goals/beta.md"
  out=$(push_charters) || fail "second push failed: $out"
  files=$(git -C "$bare" ls-tree -r --name-only main)
  assert_contains "$files" 'data/goals/alpha.md' "second push must keep alpha"
  case "$files" in
    *data/goals/beta.md*) fail "a charter no longer selected must leave the transport: $files" ;;
  esac
  git -C "$bare" cat-file -e main~1:data/goals/beta.md \
    || fail "the removed charter must stay recoverable from transport history"
  pass "push removes a charter the source no longer selects from the transport"
}

test_per_file_push_prunes_charters_a_directory_push_carried() {
  local home="$TMP_ROOT/charter-switch-home"
  local bare="$TMP_ROOT/charter-switch-remote.git"
  local manifest="$TMP_ROOT/charter-switch.conf"
  local fakebin out files
  seed_home "$home"
  seed_charters "$home"
  write_data_manifest "$manifest" 'data = data/goals/alpha.md'
  git init -q --bare "$bare" || fail "could not create bare transport"
  fakebin=$(fm_fakebin "$TMP_ROOT/charter-switch")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *--jq\ .visibility*) printf 'private\n' ;;
  *--jq\ .private*) printf 'true\n' ;;
esac
SH
  chmod +x "$fakebin/gh"

  push_switch() {
    PATH="$fakebin:$PATH" TMPDIR="$TMP_ROOT" GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0="url.file://$bare.insteadOf" \
      GIT_CONFIG_VALUE_0=https://github.com/captain/portable.git \
      "$@" "$PORT" push --remote captain/portable --home "$home" 2>&1
  }

  out=$(push_switch env) || fail "directory-entry push failed: $out"
  files=$(git -C "$bare" ls-tree -r --name-only main)
  assert_contains "$files" 'data/goals/beta.md' "directory-entry push must carry beta"

  out=$(push_switch env FM_FORK_SURFACE_MANIFEST="$manifest") \
    || fail "per-file push failed: $out"
  files=$(git -C "$bare" ls-tree -r --name-only main)
  assert_contains "$files" 'data/goals/alpha.md' "per-file push must keep the chosen charter"
  case "$files" in
    *data/goals/beta.md*) fail "an unchosen charter must leave the transport after a per-file push: $files" ;;
  esac
  pass "a per-file push removes charters an earlier directory-entry push carried"
}

test_manifest_data_entry_outside_goals_is_refused() {
  local home="$TMP_ROOT/charter-bad-entry-home"
  local dest="$TMP_ROOT/charter-bad-entry-dest"
  local manifest="$TMP_ROOT/charter-bad-entry.conf"
  local out rc=0 entry
  seed_home "$home"
  mkdir -p "$home/data/accounts" "$dest"
  printf 'account home\n' > "$home/data/accounts/marker.md"
  write_data_manifest "$manifest" 'data = data/accounts/'

  out=$(FM_FORK_SURFACE_MANIFEST="$manifest" "$PORT" export --home "$home" --dest "$dest" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "export must refuse a non-charter data entry, got: $out"
  assert_contains "$out" 'data/accounts/' "refusal must name the declared entry"
  assert_absent "$dest/data/accounts" "a non-charter data entry must not travel"

  for entry in data/goals/ data/goals/alpha.md data/goals/my-project_2.md; do
    "$PORT" portable-data-entry "$entry" || fail "portable-data-entry must accept $entry"
  done
  for entry in data/goals data/goals/sub/x.md data/goals/.hidden.md data/goals/alpha.txt \
    data/accounts/ data/captain.md data/goals/../projects.md; do
    if "$PORT" portable-data-entry "$entry"; then
      fail "portable-data-entry must reject $entry"
    fi
  done
  pass "only goal-charter directory and file entries are portable data entries"
}

test_export_copies_portable_only
test_export_skips_absent_upstream_watch
test_export_refuses_explicit_env_include
test_scan_detects_embedded_secret
test_scan_detects_secret_without_leading_space
test_export_aborts_when_portable_file_contains_secret
test_import_round_trip_and_refuses_contaminated_source
test_goal_charters_travel_and_import_keeps_local_ones
test_export_refuses_symlinked_charter
test_import_refuses_symlinked_charter_before_writing
test_per_file_entry_carries_only_the_chosen_charter
test_per_file_entry_refuses_symlinked_goals_dir
test_push_prunes_charters_no_longer_selected
test_per_file_push_prunes_charters_a_directory_push_carried
test_manifest_data_entry_outside_goals_is_refused
test_help_mentions_secrets_policy
test_scan_warn_machine_local_is_advisory
test_scan_warn_machine_local_does_not_mask_secrets
test_verify_fails_missing_portable_files
test_verify_fails_unknown_backend_and_unverified_harness
test_verify_passes_ready_home
test_verify_reports_the_private_addon
test_verify_accepts_prime_agent_worker
test_verify_completes_for_every_verified_harness

echo "# all fm-home-port tests passed"
