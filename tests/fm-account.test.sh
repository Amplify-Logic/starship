#!/usr/bin/env bash
# Behavior tests for bin/fm-account.sh, the account-home helper.
#
# The safety property under test is that creating an account home is inert: one
# empty directory and a printed login command, with no credential material
# copied, linked, or seeded from anywhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACCOUNT="$ROOT/bin/fm-account.sh"
TMP_ROOT=$(fm_test_tmproot fm-account)
HOME_FIX="$TMP_ROOT/home"
mkdir -p "$HOME_FIX/config" "$HOME_FIX/data"

# Portable mode bits. Platform-detected, never the `stat -f || stat -c` fallback:
# GNU stat reads the FILE SYSTEM under -f, so it dumps that block for the home
# and fails only on the format operand, mixing both into one substitution.
dir_mode() {  # <dir>
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

run_account() {  # <args...>
  FM_HOME="$HOME_FIX" FM_DATA_OVERRIDE="$HOME_FIX/data" FM_CONFIG_OVERRIDE="$HOME_FIX/config" \
    "$ACCOUNT" "$@" 2>&1
}

write_registry() {
  cat > "$HOME_FIX/config/accounts.json" <<'JSON'
{
  "claude": {
    "default": "team",
    "accounts": {
      "team": {"label": "Company Team (connectors)", "expect": "org-team-0001"},
      "max": {"label": "Personal Max"}
    }
  },
  "codex": {
    "accounts": {"alex": {"label": "Alex"}}
  }
}
JSON
}

test_absent_registry_refuses_every_subcommand() {
  local out status
  rm -f "$HOME_FIX/config/accounts.json"
  for args in "list" "create claude team" "login-command codex alex"; do
    status=0
    # shellcheck disable=SC2086 # each case is a deliberate argument list
    out=$(run_account $args) || status=$?
    [ "$status" -ne 0 ] || fail "'$args' was accepted with no registry"
    assert_contains "$out" "no accounts are defined" "'$args' did not explain the absent registry"
  done
  pass "fm-account: an absent registry refuses every subcommand and says why"
}

test_list_reports_definitions_without_touching_anything() {
  local out
  write_registry
  out=$(run_account list)
  assert_contains "$out" "claude (CLAUDE_CONFIG_DIR)" "list did not name the Claude isolation variable"
  assert_contains "$out" "codex (CODEX_HOME)" "list did not name the Codex isolation variable"
  assert_contains "$out" "Company Team (connectors)" "list did not print the account label"
  assert_contains "$out" "$HOME_FIX/data/accounts/claude/team" "list did not print the derived home"
  assert_contains "$out" "not created yet" "list did not report an uncreated home"
  assert_contains "$out" "expect: org-team-0001" "list did not report the expected identity"
  assert_absent "$HOME_FIX/data/accounts" "list created account homes as a side effect"

  out=$(run_account list codex)
  assert_contains "$out" "Alex" "vendor-filtered list dropped the codex account"
  assert_not_contains "$out" "Company Team" "vendor-filtered list still printed the other vendor"
  pass "fm-account: list reports the registry and derived homes without creating anything"
}

test_create_makes_one_empty_home_and_prints_the_login_command() {
  local out home
  write_registry
  home="$HOME_FIX/data/accounts/claude/max"
  out=$(run_account create claude max)
  assert_contains "$out" "created account home: $home" "create did not report the derived home"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$home claude" "create did not print the exact login command"
  assert_contains "$out" "no credential copied" "create did not state the no-copy rule"
  assert_present "$home" "create did not make the account home"
  [ -z "$(ls -A "$home")" ] || fail "create seeded the account home with something"
  [ "$(dir_mode "$home")" = 700 ] \
    || fail "create did not restrict the account home to 0700"

  # Idempotent: an existing home is reported, never re-seeded or replaced.
  printf 'captain login artifact\n' > "$home/.credentials.json"
  out=$(run_account create claude max)
  assert_contains "$out" "already exists" "create did not report an existing home"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$home claude" "create on an existing home dropped the login command"
  assert_grep "captain login artifact" "$home/.credentials.json" "create overwrote existing account material"
  pass "fm-account: create makes one empty 0700 home, prints the login command, and never re-seeds"
}

test_unknown_vendor_and_account_refuse() {
  local out status
  write_registry
  status=0
  out=$(run_account create gemini team) || status=$?
  [ "$status" -ne 0 ] || fail "an unknown vendor was accepted"
  assert_contains "$out" "unknown vendor 'gemini'" "refusal did not name the unknown vendor"

  status=0
  out=$(run_account create claude ghost) || status=$?
  [ "$status" -ne 0 ] || fail "an undefined account was accepted"
  assert_contains "$out" "unknown claude account 'ghost'" "refusal did not name the undefined account"
  assert_contains "$out" "team max" "refusal did not name the accounts that ARE defined"
  assert_absent "$HOME_FIX/data/accounts/claude/ghost" "an undefined account still created a home"

  status=0
  out=$(run_account frobnicate) || status=$?
  [ "$status" -ne 0 ] || fail "an unknown subcommand was accepted"
  assert_contains "$out" "unknown subcommand" "refusal did not name the unknown subcommand"
  pass "fm-account: unknown vendors, undefined accounts, and unknown subcommands refuse"
}

# The name rule has exactly one meaning across the whole feature: what
# bin/fm-bootstrap.sh's accounts_validate reports as an invalid account name at
# session start is also refused here, at creation, and at launch. A name that
# only the diagnostic rejects would leave a permanent ACCOUNTS complaint about a
# pin that keeps working.
test_unsafe_account_names_refuse_everywhere() {
  local out status name
  for name in _team -team .team ../escape 'a b'; do
    cat > "$HOME_FIX/config/accounts.json" <<JSON
{"claude": {"accounts": {"$name": {"label": "unsafe"}}}}
JSON
    status=0
    out=$(run_account create claude "$name") || status=$?
    [ "$status" -ne 0 ] || fail "unsafe account name '$name' was accepted"
    assert_contains "$out" "invalid claude account name '$name'" \
      "refusal did not name the invalid account '$name'"
    assert_absent "$HOME_FIX/data/accounts/claude/$name" "unsafe name '$name' still created a home"
  done
  assert_absent "$HOME_FIX/data/accounts/claude/escape" "a traversing name escaped the vendor directory"
  pass "fm-account: unsafe account names refuse at creation exactly as bootstrap reports them"
}

test_login_command_prints_only_the_command() {
  local out
  write_registry
  out=$(run_account login-command codex alex)
  [ "$out" = "CODEX_HOME=$HOME_FIX/data/accounts/codex/alex codex login" ] \
    || fail "login-command printed more than the command: $out"
  pass "fm-account: login-command prints exactly the command to run"
}

test_absent_registry_refuses_every_subcommand
test_list_reports_definitions_without_touching_anything
test_create_makes_one_empty_home_and_prints_the_login_command
test_unknown_vendor_and_account_refuse
test_unsafe_account_names_refuse_everywhere
test_login_command_prints_only_the_command
