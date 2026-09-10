# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_ACCOUNT_ERROR is an output global for sourcing callers.
# bin/fm-account-lib.sh - named vendor account resolution for primary launches
# and crewmate spawns.
# Usage: . bin/fm-account-lib.sh
#
# One concept for both vendors: a NAMED ACCOUNT, per vendor, backed by its own
# isolated home directory under this Firstmate home's private data dir.
#   claude -> $DATA/accounts/claude/<name>, exported as CLAUDE_CONFIG_DIR
#   codex  -> $DATA/accounts/codex/<name>,  exported as CODEX_HOME
# Home paths are DERIVED from vendor and name, never read from the registry, so
# a registry file can never point a launch at an arbitrary directory.
#
# The registry is local, gitignored config/accounts.json; docs/configuration.md
# owns its schema and bin/fm-bootstrap.sh validates it. An ABSENT registry means
# one thing only: no pinning, every launch uses the ambient vendor home exactly
# as it did before account pinning existed.
#
# Credentials are never copied, linked, or seeded between homes. A fresh account
# home is empty and unauthenticated, and the captain logs into it by hand with
# the command fm_account_login_command prints (data/captain.md Accounts).
#
# Error reporting: a function that refuses sets FM_ACCOUNT_ERROR to the reason
# and returns 1, so each caller can raise it through its own die/refusal prefix
# instead of this library guessing which script it is running inside.
# FM_ACCOUNT_PIN_NAME and FM_ACCOUNT_PIN_HOME are the matching output globals,
# and FM_ACCOUNT_WARNING carries a non-fatal note the caller should print. The
# PIN_ infix is deliberate: FM_ACCOUNT_NAME is already an INBOUND status-bar
# variable naming the account owner (docs/status-bar.md), so a pinned launch
# must not overwrite it.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_ACCOUNT_ERROR=
FM_ACCOUNT_WARNING=
FM_ACCOUNT_PIN_NAME=
FM_ACCOUNT_PIN_HOME=

# fm_account_vendors: every vendor with an account concept, in help order.
fm_account_vendors() {
  printf 'claude codex'
}

# fm_account_env_var: the isolation variable a vendor's account home is exported
# as. Both were re-verified on this machine on 2026-09-09 (see the
# harness-adapters skill); an unknown vendor returns 1 rather than guessing.
fm_account_env_var() {  # <vendor>
  case "$1" in
    claude) printf 'CLAUDE_CONFIG_DIR' ;;
    codex) printf 'CODEX_HOME' ;;
    *) return 1 ;;
  esac
}

# fm_account_registry_file: the local registry path for a config dir.
fm_account_registry_file() {  # <config-dir>
  printf '%s/accounts.json' "$1"
}

# fm_account_home: the derived isolated home for one named account.
fm_account_home() {  # <data-dir> <vendor> <name>
  printf '%s/accounts/%s/%s' "$1" "$2" "$3"
}

# fm_account_name_ok: an account name is one path segment of safe characters, so
# it can never escape the derived vendor directory.
#
# This is the SAME rule accounts_validate applies in bin/fm-bootstrap.sh
# (^[A-Za-z0-9][A-Za-z0-9._-]*$), deliberately: a name the session-start
# diagnostic reports as invalid must also be refused at creation and at launch,
# or the captain gets a permanent ACCOUNTS diagnostic for a pin that keeps
# working. The leading character carries the same weight as the rest - a name
# starting with a dot, dash, or underscore is refused here and there.
fm_account_name_ok() {  # <name>
  case "$1" in
    ''|[!A-Za-z0-9]*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_account_defined_names: the account names the registry defines for a vendor,
# space separated, or nothing at all. Callers use it to name the real options in
# a refusal.
fm_account_defined_names() {  # <registry-file> <vendor>
  local file=$1 vendor=$2
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg v "$vendor" '
    (.[$v]?.accounts? // {}) | keys_unsorted | join(" ")
  ' "$file" 2>/dev/null || true
}

# fm_account_resolve: decide which account a launch runs on.
#
# Sets FM_ACCOUNT_PIN_NAME and FM_ACCOUNT_PIN_HOME as output globals, both empty
# when no pin applies. No pin applies when the registry is absent, when the
# vendor has no entry, or when the vendor has no default and no account was
# requested - all of which leave the ambient vendor home in charge.
#
# Returns 1 with FM_ACCOUNT_ERROR set when a requested or default account is not
# defined, when a name is unsafe, or when the registry exists but cannot be read.
#
# Output globals rather than stdout on purpose: a caller reading this through
# command substitution would run it in a subshell, where the refusal reason set
# on failure could never reach the caller that has to print it.
fm_account_resolve() {  # <config-dir> <data-dir> <vendor> [<requested-name>]
  local config_dir=$1 data_dir=$2 vendor=$3 requested=${4:-}
  local file names name
  FM_ACCOUNT_ERROR=
  FM_ACCOUNT_WARNING=
  FM_ACCOUNT_PIN_NAME=
  FM_ACCOUNT_PIN_HOME=
  file=$(fm_account_registry_file "$config_dir")
  if [ ! -f "$file" ]; then
    if [ -n "$requested" ]; then
      FM_ACCOUNT_ERROR="no accounts are defined: $file does not exist, so --account $requested cannot be resolved"
      return 1
    fi
    return 0
  fi
  # An unreadable registry refuses an EXPLICIT pin, because that request cannot
  # be honored - but it must never take down a launch that asked for no pin at
  # all. Bootstrap reports the broken file as its own ACCOUNTS diagnostic; here
  # the launch warns and continues on the ambient vendor home, which is exactly
  # what it would have used with no registry present.
  if ! command -v jq >/dev/null 2>&1; then
    if [ -n "$requested" ]; then
      FM_ACCOUNT_ERROR="$file exists but 'jq' is not on PATH, so account '$requested' cannot be resolved"
      return 1
    fi
    FM_ACCOUNT_WARNING="$file cannot be read without 'jq'; launching on the ambient account"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    if [ -n "$requested" ]; then
      FM_ACCOUNT_ERROR="$file is not valid JSON, so account '$requested' cannot be resolved; fix it or remove it (an absent file means no account pinning)"
      return 1
    fi
    FM_ACCOUNT_WARNING="$file is not valid JSON; launching on the ambient account"
    return 0
  fi
  names=$(fm_account_defined_names "$file" "$vendor")
  name=$requested
  if [ -z "$name" ]; then
    name=$(jq -r --arg v "$vendor" '.[$v]?.default? // "" | tostring' "$file" 2>/dev/null || true)
    [ -n "$name" ] || return 0
  fi
  if ! fm_account_name_ok "$name"; then
    FM_ACCOUNT_ERROR="invalid $vendor account name '$name'; use letters, digits, dot, dash, or underscore, starting with a letter or digit"
    return 1
  fi
  case " $names " in
    *" $name "*) ;;
    *)
      if [ -n "$names" ]; then
        FM_ACCOUNT_ERROR="unknown $vendor account '$name'; $file defines: $names"
      else
        FM_ACCOUNT_ERROR="unknown $vendor account '$name'; $file defines no $vendor accounts"
      fi
      return 1
      ;;
  esac
  FM_ACCOUNT_PIN_NAME=$name
  FM_ACCOUNT_PIN_HOME=$(fm_account_home "$data_dir" "$vendor" "$name")
}

# fm_account_login_command: the exact command the captain runs to log one account
# home in. Firstmate never runs it: a login is the captain's hands, and no
# credential is ever copied from another home.
fm_account_login_command() {  # <vendor> <home>
  case "$1" in
    claude) printf "CLAUDE_CONFIG_DIR=%s claude" "$2" ;;
    codex) printf "CODEX_HOME=%s codex login" "$2" ;;
    *) return 1 ;;
  esac
}

# fm_account_logged_out: 0 only when the vendor CLI gives an EXPLICIT logged-out
# reading for that home. An unreadable, timed-out, or unrecognized answer is not
# evidence of a logged-out account and must never refuse a launch that would
# otherwise work - the same rule the Cursor primary login gate follows.
fm_account_logged_out() {  # <vendor> <home> <cli-binary>
  local vendor=$1 home=$2 cli=$3 out
  command -v "$cli" >/dev/null 2>&1 || return 1
  case "$vendor" in
    claude)
      # `claude auth status` prints its JSON on stdout either way, exiting 0 when
      # that home is logged in and 1 when it is not (verified 2.1.258,
      # 2026-09-09). The exit status cannot separate a logged-out home from a CLI
      # that failed to answer, so the explicit loggedIn field is the signal.
      out=$(CLAUDE_CONFIG_DIR="$home" fm_run_timeout 10 "$cli" auth status 2>/dev/null) || true
      case "$out" in
        *'"loggedIn": false'*|*'"loggedIn":false'*) return 0 ;;
      esac
      ;;
    codex)
      # `codex login status` writes "Not logged in" to stderr and prints nothing
      # on stdout, so this must read both streams.
      out=$(CODEX_HOME="$home" fm_run_timeout 10 "$cli" login status 2>&1) || true
      case "$out" in
        *'Not logged in'*|*'not logged in'*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# fm_account_expect: the optional identity a named account must resolve to, or
# nothing when the account does not declare one.
fm_account_expect() {  # <registry-file> <vendor> <name>
  local file=$1 vendor=$2 name=$3
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg v "$vendor" --arg n "$name" '
    .[$v]?.accounts?[$n]?.expect? // "" | tostring
  ' "$file" 2>/dev/null || true
}

# fm_account_expect_supported: whether a vendor exposes an identity this
# launcher can actually match an expect value against.
#
# claude does: `claude auth status` prints email, orgId, orgName, and
# subscriptionType as JSON on stdout.
# codex does NOT: `codex login status` prints only "Logged in using ChatGPT"
# with no identity at all (verified codex-cli 0.153.4, 2026-09-09), so an expect
# value there would be unverifiable and is refused rather than matched against
# something invented.
fm_account_expect_supported() {  # <vendor>
  case "$1" in
    claude) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_account_identity: every identity token the vendor reports for one home, one
# "field=value" line each, or return 1 when no identity could be read.
#
# Two Claude seats can share one email - a Team seat and a personal Max seat on
# the same address do exactly that on the captain's machine - so the ORG is what
# separates them and every field is offered for matching rather than the email
# alone.
fm_account_identity() {  # <vendor> <home> <cli-binary>
  local vendor=$1 home=$2 cli=$3 out
  command -v "$cli" >/dev/null 2>&1 || return 1
  case "$vendor" in
    claude)
      command -v jq >/dev/null 2>&1 || return 1
      out=$(CLAUDE_CONFIG_DIR="$home" fm_run_timeout 10 "$cli" auth status 2>/dev/null) || true
      [ -n "$out" ] || return 1
      printf '%s' "$out" | jq -e -r '
        select(.loggedIn == true)
        | to_entries[]
        | select(.key == "email" or .key == "orgId" or .key == "orgName"
            or .key == "subscriptionType" or .key == "accountUuid")
        | select(.value != null and (.value | tostring) != "")
        | "\(.key)=\(.value)"
      ' 2>/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
}

# fm_account_verify_expect: confirm a pinned home really resolves to the identity
# its account declares, BEFORE anything is launched on it.
#
# A pin selects a HOME, not an identity: exporting the right directory proves
# nothing about which account actually answers inside it, and a home logged into
# the wrong seat would silently run the captain there. Reading the identity back
# is the only thing that proves the seat. An expect value is an explicit demand
# for that proof, so an identity that cannot be read at all refuses too - unlike
# the login gate, where only an explicit negative refuses.
# Two seats sharing one email make this concrete: on the captain's machine the
# ambient seat and the pinned Team seat differ only by organization and plan.
#
# Returns 0 when the account declares no expect value, or when the identity
# matches one of the vendor's reported fields. Returns 1 with FM_ACCOUNT_ERROR
# otherwise.
fm_account_verify_expect() {  # <vendor> <home> <cli-binary> <name> <expect>
  local vendor=$1 home=$2 cli=$3 name=$4 expect=$5 identity line value want
  FM_ACCOUNT_ERROR=
  [ -n "$expect" ] || return 0
  if ! fm_account_expect_supported "$vendor"; then
    FM_ACCOUNT_ERROR="$vendor account '$name' declares expect '$expect', but $vendor's login status reports no identity to check it against; remove expect from that account or pin it without one"
    return 1
  fi
  if ! identity=$(fm_account_identity "$vendor" "$home" "$cli"); then
    FM_ACCOUNT_ERROR="$vendor account '$name' declares expect '$expect', but no identity could be read from $home; log that home in, or remove expect to launch without the check"
    return 1
  fi
  want=$(printf '%s' "$expect" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r line; do
    value=${line#*=}
    [ "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" = "$want" ] || continue
    return 0
  done <<EOF
$identity
EOF
  FM_ACCOUNT_ERROR="$vendor account '$name' expects '$expect' but $home is signed in as: $(printf '%s' "$identity" | tr '\n' ' ')"
  return 1
}

# fm_account_require_usable: the whole pre-launch gate for one pinned account, in
# one place, so a primary and a spawn can never refuse the same situation with
# different words.
#
# Three steps, in the order that makes the refusal actionable:
#   1. no home yet      -> name the create command AND the login command
#   2. explicitly out   -> name the login command, and say plainly that no
#                          credential is ever copied from another account
#   3. declares expect  -> fm_account_verify_expect proves the seat
#
# An empty <home> means no pin applies, which is a silent success. Callers raise
# FM_ACCOUNT_ERROR through their own die/refusal prefix.
fm_account_require_usable() {  # <vendor> <home> <cli-binary> <name> <expect> <create-command>
  local vendor=$1 home=$2 cli=$3 name=$4 expect=$5 create=$6 login
  FM_ACCOUNT_ERROR=
  [ -n "$home" ] || return 0
  if ! login=$(fm_account_login_command "$vendor" "$home"); then
    FM_ACCOUNT_ERROR="no login command is known for vendor '$vendor'"
    return 1
  fi
  if [ ! -d "$home" ]; then
    FM_ACCOUNT_ERROR="$vendor account '$name' has no home yet: create it with '$create', then log in with: $login"
    return 1
  fi
  if fm_account_logged_out "$vendor" "$home" "$cli"; then
    FM_ACCOUNT_ERROR="$vendor account '$name' is not logged in at $home; log in with: $login (no credential is ever copied from another account)"
    return 1
  fi
  fm_account_verify_expect "$vendor" "$home" "$cli" "$name" "$expect"
}

# fm_account_create_home: create one empty account home, 0700, and nothing else.
# It never seeds config or credentials from anywhere.
fm_account_create_home() {  # <home>
  local home=$1
  FM_ACCOUNT_ERROR=
  if [ -L "$home" ]; then
    FM_ACCOUNT_ERROR="account home is a symlink; refusing to use it: $home"
    return 1
  fi
  if ! mkdir -p "$home"; then
    FM_ACCOUNT_ERROR="could not create account home: $home"
    return 1
  fi
  chmod 0700 "$home" 2>/dev/null || true
}
