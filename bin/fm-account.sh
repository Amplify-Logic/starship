#!/usr/bin/env bash
# Inspect and create the isolated account homes named by config/accounts.json.
#
# Usage:
#   fm-account.sh list [<vendor>]
#   fm-account.sh create <vendor> <name>
#   fm-account.sh login-command <vendor> <name>
#   fm-account.sh --help
#
# Vendors: claude (home exported as CLAUDE_CONFIG_DIR) and codex (CODEX_HOME).
# Account names come from local, gitignored config/accounts.json, whose schema
# docs/configuration.md owns; homes are DERIVED as data/accounts/<vendor>/<name>
# and never read from that file. An account this script does not know is one the
# registry does not define: add it there first, then create its home here.
#
# create makes ONE empty directory, mode 0700, and prints the exact login command
# for it. It never copies, links, or seeds a credential directory, auth.json,
# .credentials.json, or keychain entry from another account home or from the
# ambient one, and it never runs the login itself. Logging in is the captain's
# hands, deliberately: separate accounts are the entire point, so each home gets
# its own fresh login.
#
# list reports each defined account's label, its expected identity when it
# declares one, its derived home, and whether that home exists yet. It performs
# no login and reads no credential.
#
# Launch-time selection lives elsewhere: bin/fm-primary.sh --account for a
# primary and bin/fm-spawn.sh --account for a worker.
set -u

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="$(CDPATH='' cd -P -- "$SCRIPT_DIR/.." && pwd -P)"
FM_HOME=${FM_HOME:-$FM_ROOT}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}

# shellcheck source=bin/fm-account-lib.sh
. "$SCRIPT_DIR/fm-account-lib.sh"

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-account: %s\n' "$*" >&2
  exit 1
}

require_vendor() {  # <vendor>
  fm_account_env_var "$1" >/dev/null \
    || die "unknown vendor '$1' (accounts exist for: $(fm_account_vendors))"
}

registry() {
  fm_account_registry_file "$CONFIG"
}

require_registry() {
  [ -f "$(registry)" ] \
    || die "no accounts are defined: $(registry) does not exist (an absent registry means no account pinning at all)"
  command -v jq >/dev/null 2>&1 || die "'jq' is required to read $(registry)"
}

# Resolve one defined account, refusing exactly the way a launch would so this
# helper can never create a home the launcher would then reject.
resolve_or_die() {  # <vendor> <name>
  require_vendor "$1"
  require_registry
  fm_account_resolve "$CONFIG" "$DATA" "$1" "$2" || die "$FM_ACCOUNT_ERROR"
  [ -n "$FM_ACCOUNT_PIN_HOME" ] || die "no $1 account named '$2' is defined in $(registry)"
}

cmd_list() {  # [<vendor>]
  local vendor names name home expect label wanted=${1:-}
  [ -z "$wanted" ] || require_vendor "$wanted"
  require_registry
  for vendor in $(fm_account_vendors); do
    [ -z "$wanted" ] || [ "$wanted" = "$vendor" ] || continue
    names=$(fm_account_defined_names "$(registry)" "$vendor")
    if [ -z "$names" ]; then
      printf '%s: no accounts defined\n' "$vendor"
      continue
    fi
    printf '%s (%s)\n' "$vendor" "$(fm_account_env_var "$vendor")"
    for name in $names; do
      home=$(fm_account_home "$DATA" "$vendor" "$name")
      expect=$(fm_account_expect "$(registry)" "$vendor" "$name")
      label=$(jq -r --arg v "$vendor" --arg n "$name" \
        '.[$v]?.accounts?[$n]?.label? // "" | tostring' "$(registry)" 2>/dev/null || true)
      printf '  %-12s %s\n' "$name" "${label:-(no label)}"
      printf '    home:   %s%s\n' "$home" "$([ -d "$home" ] || printf ' (not created yet)')"
      [ -z "$expect" ] || printf '    expect: %s\n' "$expect"
    done
  done
}

cmd_create() {  # <vendor> <name>
  local vendor=$1 name=$2 home login
  resolve_or_die "$vendor" "$name"
  home=$FM_ACCOUNT_PIN_HOME
  login=$(fm_account_login_command "$vendor" "$home")
  if [ -d "$home" ]; then
    printf 'account home already exists: %s\n' "$home"
  else
    fm_account_create_home "$home" || die "$FM_ACCOUNT_ERROR"
    printf 'created account home: %s\n' "$home"
  fi
  printf 'log this account in yourself, with no credential copied from anywhere:\n  %s\n' "$login"
}

cmd_login_command() {  # <vendor> <name>
  resolve_or_die "$1" "$2"
  fm_account_login_command "$1" "$FM_ACCOUNT_PIN_HOME" || die "no login command for vendor '$1'"
  printf '\n'
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
  list)
    [ "$#" -le 2 ] || die "list accepts at most one vendor"
    cmd_list "${2:-}"
    ;;
  create)
    [ "$#" -eq 3 ] || die "usage: fm-account.sh create <vendor> <name>"
    cmd_create "$2" "$3"
    ;;
  login-command)
    [ "$#" -eq 3 ] || die "usage: fm-account.sh login-command <vendor> <name>"
    cmd_login_command "$2" "$3"
    ;;
  *) die "unknown subcommand '$1' (list, create, login-command)" ;;
esac
