#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh named vendor account pinning (--account).
#
# These drive fm-spawn through meta writing and launch construction with a fake
# tmux pane and a real isolated git worktree, exactly like the dispatch-profile
# suite. The fake tmux captures the literal launch command sent with
# `tmux send-keys -l`, so the assertions pin the command firstmate would run
# without starting any real harness or touching any real account.
#
# The compatibility guarantee this suite exists for: with no config/accounts.json
# the launch line and the meta are byte-identical to a spawn from before account
# pinning existed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-account)
SPAWN_HOMES_FILE="$TMP_ROOT/homes"
: > "$SPAWN_HOMES_FILE"

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse opencode pi grok agent
  # claude and codex answer their own login-status surfaces, because that is what
  # the account gate reads. FM_FAKE_LOGGED_OUT flips them to the explicit
  # logged-out answer each CLI really prints: claude writes JSON to stdout either
  # way and exits 1 only when logged out, codex writes one line to stderr.
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  if [ -n "${FM_FAKE_LOGGED_OUT:-}" ]; then
    printf '{\n  "loggedIn": false,\n  "authMethod": "none"\n}\n'
    exit 1
  fi
  printf '{\n  "loggedIn": true,\n  "email": "%s",\n  "orgId": "%s"\n}\n' \
    "${FM_FAKE_CLAUDE_EMAIL:-seat@example.invalid}" \
    "${FM_FAKE_CLAUDE_ORG:-org-fake-0001}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/claude"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  if [ -n "${FM_FAKE_LOGGED_OUT:-}" ]; then
    printf 'Not logged in\n' >&2
    exit 0
  fi
  printf 'Logged in using ChatGPT\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/codex"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <harness> <task-id>...
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

register_spawn_home() {
  printf '%s\n' "$( (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || printf '%s' "$1")" >> "$SPAWN_HOMES_FILE"
}

run_spawn() {  # <home> <worktree> <fakebin> <launchlog> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  register_spawn_home "$home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" \
    FM_FAKE_LOGGED_OUT="${FM_FAKE_LOGGED_OUT:-}" \
    FM_FAKE_CLAUDE_EMAIL="${FM_FAKE_CLAUDE_EMAIL:-}" \
    FM_FAKE_CLAUDE_ORG="${FM_FAKE_CLAUDE_ORG:-}" \
    CLAUDE_CONFIG_DIR='' CODEX_HOME='' PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

write_registry() {  # <home>
  cat > "$1/config/accounts.json" <<'JSON'
{
  "claude": {
    "default": "team",
    "accounts": {
      "team": {"label": "Company Team (connectors)"},
      "max": {"label": "Personal Max"}
    }
  },
  "codex": {
    "default": "robin",
    "accounts": {
      "robin": {"label": "Robin personal"},
      "alex": {"label": "Alex"}
    }
  }
}
JSON
}

spawn_task_tmp_from_meta() {
  grep '^tasktmp=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

clear_spawn_task_tmps() {
  local home meta root
  [ -f "$SPAWN_HOMES_FILE" ] || return 0
  while IFS= read -r home || [ -n "$home" ]; do
    [ -d "$home/state" ] || continue
    for meta in "$home"/state/*.meta; do
      [ -f "$meta" ] || continue
      root=$(spawn_task_tmp_from_meta "$meta")
      case "$root" in ''|/) continue ;; esac
      rm -rf "$root"
    done
  done < "$SPAWN_HOMES_FILE"
}
trap 'clear_spawn_task_tmps' EXIT

# The compatibility guarantee: with no registry, the launch line and the meta are
# exactly what they were before account pinning existed.
test_absent_registry_changes_nothing() {
  local rec id out status launch encoded expected
  id=account-absent-a1
  rec=$(make_spawn_case account-absent claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without a registry should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"

  launch=$(cat "$LAUNCH_LOG")
  encoded=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$HOME_DIR/data/$id/brief.md")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions '$encoded'"
  [ "$launch" = "$expected" ] || fail "absent registry changed the claude launch line"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_no_grep 'account=' "$HOME_DIR/state/$id.meta" "absent registry still recorded an account in meta"
  assert_no_grep 'CLAUDE_CONFIG_DIR' "$LAUNCH_LOG" "absent registry still pinned a Claude home"
  pass "fm-spawn: an absent config/accounts.json leaves the launch and meta unchanged"
}

# The degrade guarantee the guarded hook exists for: with bin/fm-account-lib.sh
# absent, an unpinned spawn is byte-identical to one from before pinning
# existed and prints no shell error, while an explicit --account is refused
# rather than silently launched on the ambient login.
test_absent_library_degrades_without_error() {
  local rec id out status launch encoded expected bin
  id=account-nolib-a8
  rec=$(make_spawn_case account-nolib claude "$id")
  read_case_record "$rec"
  bin="$TMP_ROOT/account-nolib/bin"
  cp -R "$ROOT/bin" "$bin"
  rm -f "$bin/fm-account-lib.sh"
  write_registry "$HOME_DIR"

  out=$(SPAWN="$bin/fm-spawn.sh" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without the account library should succeed: $out"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_not_contains "$out" "fm-account-lib.sh" "an absent account library leaked a shell error"
  assert_not_contains "$out" "No such file" "an absent account library leaked a shell error"

  launch=$(cat "$LAUNCH_LOG")
  encoded=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$HOME_DIR/data/$id/brief.md")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions '$encoded'"
  [ "$launch" = "$expected" ] || fail "absent account library changed the claude launch line"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_no_grep 'account=' "$HOME_DIR/state/$id.meta" "absent account library still recorded an account in meta"
  assert_no_grep 'CLAUDE_CONFIG_DIR' "$LAUNCH_LOG" "absent account library still pinned a Claude home"

  id=account-nolib-a9
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(SPAWN="$bin/fm-spawn.sh" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --account team)
  status=$?
  [ "$status" -ne 0 ] || fail "an explicit --account launched without the account library"
  assert_contains "$out" "error: --account needs bin/fm-account-lib.sh" "refusal did not name the missing library"
  [ -z "$(cat "$LAUNCH_LOG")" ] || fail "an explicit --account without the library still launched something"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused --account still created task metadata"
  pass "fm-spawn: an absent bin/fm-account-lib.sh degrades silently and refuses an explicit --account"
}

test_pinned_claude_account_exports_home_and_records_meta() {
  local rec id out status launch home
  id=account-claude-a2
  rec=$(make_spawn_case account-claude claude "$id")
  read_case_record "$rec"
  write_registry "$HOME_DIR"
  home="$HOME_DIR/data/accounts/claude/max"
  mkdir -p "$home"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --account max)
  status=$?
  expect_code 0 "$status" "pinned claude spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "CLAUDE_CONFIG_DIR='$home' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude "*) ;;
    *) fail "pinned claude launch did not export the derived home first"$'\n'"actual: $launch" ;;
  esac
  assert_grep "account=max" "$HOME_DIR/state/$id.meta" "meta did not record the pinned account"
  pass "fm-spawn: --account exports the derived Claude home and records account= in meta"
}

test_vendor_default_applies_without_the_flag() {
  local rec id out status launch home
  id=account-default-a3
  rec=$(make_spawn_case account-default codex "$id")
  read_case_record "$rec"
  write_registry "$HOME_DIR"
  home="$HOME_DIR/data/accounts/codex/robin"
  mkdir -p "$home"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn on the vendor default should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "CODEX_HOME='$home' codex "*) ;;
    *) fail "omitted --account did not fall back to the codex default account"$'\n'"actual: $launch" ;;
  esac
  assert_grep "account=robin" "$HOME_DIR/state/$id.meta" "meta did not record the default account"
  pass "fm-spawn: the vendor default account applies when --account is omitted"
}

test_unknown_account_refuses_and_names_the_defined_ones() {
  local rec id out status
  id=account-unknown-a4
  rec=$(make_spawn_case account-unknown claude "$id")
  read_case_record "$rec"
  write_registry "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --account nope)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown account name was accepted"
  assert_contains "$out" "unknown claude account 'nope'" "refusal did not name the bad account"
  assert_contains "$out" "team max" "refusal did not name the accounts that ARE defined"
  assert_absent "$HOME_DIR/state/$id.meta" "an unknown account still created task metadata"
  pass "fm-spawn: an unknown account refuses and names the defined accounts"
}

test_account_on_a_vendorless_harness_refuses() {
  local rec id out status
  id=account-vendorless-a5
  rec=$(make_spawn_case account-vendorless pi "$id")
  read_case_record "$rec"
  write_registry "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --account max)
  status=$?
  [ "$status" -ne 0 ] || fail "--account was silently ignored on a vendorless harness"
  assert_contains "$out" "no vendor account to pin" "refusal did not explain the vendorless harness"
  assert_absent "$HOME_DIR/state/$id.meta" "a vendorless --account still created task metadata"
  pass "fm-spawn: --account on a harness with no account concept refuses instead of being ignored"
}

test_missing_and_logged_out_homes_refuse_with_the_login_command() {
  local rec id out status home
  id=account-loggedout-a6
  rec=$(make_spawn_case account-loggedout claude "$id")
  read_case_record "$rec"
  write_registry "$HOME_DIR"
  home="$HOME_DIR/data/accounts/claude/team"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --account team)
  status=$?
  [ "$status" -ne 0 ] || fail "a missing account home was accepted"
  assert_contains "$out" "has no home yet" "refusal did not report the missing account home"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$home claude" "refusal did not name the exact login command"

  mkdir -p "$home"
  out=$(FM_FAKE_LOGGED_OUT=1 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --account team)
  status=$?
  [ "$status" -ne 0 ] || fail "a logged-out account home was accepted"
  assert_contains "$out" "is not logged in" "refusal did not report the logged-out home"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$home claude" "logged-out refusal did not name the login command"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused account pin still created task metadata"
  [ -z "$(cat "$LAUNCH_LOG")" ] || fail "a refused account pin still launched something"
  pass "fm-spawn: a missing or logged-out account home refuses before any endpoint exists"
}

test_expect_identity_is_verified_before_launch() {
  local rec id out status home
  id=account-expect-a7
  rec=$(make_spawn_case account-expect claude "$id")
  read_case_record "$rec"
  home="$HOME_DIR/data/accounts/claude/team"
  mkdir -p "$home"
  cat > "$HOME_DIR/config/accounts.json" <<'JSON'
{
  "claude": {
    "accounts": {
      "team": {"label": "Company Team", "expect": "org-team-0001"}
    }
  }
}
JSON

  out=$(FM_FAKE_CLAUDE_ORG=org-personal-0002 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --account team)
  status=$?
  [ "$status" -ne 0 ] || fail "a pinned home signed in as another account was accepted"
  assert_contains "$out" "expects 'org-team-0001'" "refusal did not name the expected identity"
  assert_contains "$out" "org-personal-0002" "refusal did not name the actual identity"
  [ -z "$(cat "$LAUNCH_LOG")" ] || fail "a wrong-identity account still launched something"

  out=$(FM_FAKE_CLAUDE_ORG=org-team-0001 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --account team)
  status=$?
  expect_code 0 "$status" "a pinned home with the expected identity should launch: $out"
  assert_grep "account=team" "$HOME_DIR/state/$id.meta" "verified account was not recorded in meta"
  pass "fm-spawn: a declared expect identity is verified against the pinned home before launch"
}

test_absent_registry_changes_nothing
test_absent_library_degrades_without_error
test_pinned_claude_account_exports_home_and_records_meta
test_vendor_default_applies_without_the_flag
test_unknown_account_refuses_and_names_the_defined_ones
test_account_on_a_vendorless_harness_refuses
test_missing_and_logged_out_homes_refuse_with_the_login_command
test_expect_identity_is_verified_before_launch
