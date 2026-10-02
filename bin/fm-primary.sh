#!/usr/bin/env bash
# Launch a verified Firstmate primary profile from this tracked Starship root.
#
# Usage:
#   fm-primary.sh <profile> [--account <name>] [--preflight]
#   fm-primary.sh --install-shim
#   fm-primary.sh --help
#
# Profiles and exact launch mechanics (this header/help is the single owner):
#   pi            pi --name FIRSTMATE
#                 Pi has no permission system, so no bypass flag exists or is
#                 needed.
#                 No context-window flag either: see "Context window" below.
#   claude-fable  claude --model claude-fable-5-1 --effort <value> --name FIRSTMATE
#                 --dangerously-skip-permissions
#   claude-opus   claude --model claude-opus-5-5 --effort <value> --name FIRSTMATE
#                 --dangerously-skip-permissions
#                 Both Claude profiles use the first trimmed line of local
#                 gitignored config/primary-effort when that file exists,
#                 otherwise xhigh.
#                 Accepted tokens: low, medium, high, xhigh, max.
#                 Any other content, including an empty token, refuses.
#                 Exports CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1 so
#                 Claude Code does not terminate the tracked watcher-arm
#                 background shell on a memory-pressure signal once 30 minutes
#                 have passed since the last user interaction
#                 (docs/watcher-continuity.md). Requires Claude Code v2.1.193
#                 or later.
#                 Also exports CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000; see
#                 "Context window" below.
#   codex         codex --dangerously-bypass-hook-trust
#                 --dangerously-bypass-approvals-and-sandbox
#                 -c model_auto_compact_token_limit=500000
#   astra         codex --model gpt-6-astra
#                 -c model_reasoning_effort="<value>"
#                 --dangerously-bypass-hook-trust
#                 --dangerously-bypass-approvals-and-sandbox
#                 -c model_auto_compact_token_limit=500000
#                 Uses the first trimmed line of local gitignored
#                 config/astra-effort when that file exists, otherwise xhigh.
#                 Accepted tokens: low, medium, high, xhigh. max is refused,
#                 and that refusal is retained pending the separate follow-up
#                 astra-max-effort.
#                 Adds -c model_context_window=<N> when local gitignored
#                 config/astra-context selects a window. When
#                 config/astra-compact-at sets a compaction point, that value
#                 REPLACES the 500k default above; only one limit is ever
#                 passed. Both files are absent by default, and with both
#                 absent the launch is exactly the line shown above.
#                 docs/configuration.md owns both schemas.
#   opencode      OPENCODE_CONFIG_CONTENT={"permission":{"*":"allow"}}
#                 opencode
#   grok          grok --permission-mode bypassPermissions
#   cursor-grok   agent --yolo --model cursor-grok-4.6-high
#                 Cursor has no effort flag; the tier is a model-id suffix.
#                 It has no context-window flag either: see "Context window"
#                 below.
#                 Grok 4.6 also offers -xhigh, so -high here is a deliberate
#                 cost choice rather than the ceiling it was on Grok 4.5.
#                 Primary lifecycle hooks reuse tracked .claude/settings.json
#                 (Cursor maps SessionStart/PreToolUse/Stop onto its native
#                 events). There is no third-party status-line API, so no
#                 companion status bar is installed.
#   cursor-grok45 agent --yolo --model cursor-grok-4.5-high
#                 The previous Grok generation, kept launchable beside the
#                 certified cursor-grok profile rather than replacing it.
#                 -high is the top tier the 4.5 family offers: `agent
#                 --list-models` lists cursor-grok-4.5-high and its -fast
#                 variant and no 4.5 xhigh id (confirmed 2026-09-13 on Cursor
#                 CLI 2026.09.02-c22c1a3).
#                 Identical launch mechanics to cursor-grok: the same
#                 .claude/settings.json hook set, the same Cursor version
#                 warning and login gate, the same session lock, the same
#                 FM_PRIMARY_HARNESS=cursor, and no companion status bar.
#                 The model id is the only difference.
#
# Context window (captain's order 2026-09-13: cap every future session at 500k
# tokens so the orchestrator compacts itself). The exact per-harness mechanism,
# with the one-sentence evidence for each in docs/configuration.md "Context
# window":
#   claude-fable / claude-opus  export CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000.
#     The CLI reads that variable directly and it outranks the autoCompactWindow
#     user setting, so the cap rides the launch and the captain's global config
#     is never touched. The effective threshold is min(500000, the model's own
#     maximum window), which is also why a smaller model needs no special case.
#   codex / astra  -c model_auto_compact_token_limit=500000 on the launch line.
#     A -c override never touches ~/.codex/config.toml or a pinned account's
#     config.toml, which is the whole reason it is passed here rather than set.
#   pi  nothing is passed. Pi has no context-window or auto-compaction launch
#     knob: its threshold is the selected model's own context window minus
#     compaction.reserveTokens, and reserveTokens exists only in a settings file.
#   cursor-grok  nothing is passed. The Cursor CLI exposes no context or
#     compaction setting.
# opencode and grok are outside that order and are unchanged.
#
# --preflight checks the CLI, integrations, configuration, and account without
# acquiring a session, changing a terminal, or launching the CLI. It permits an
# existing owner so handoff can validate the replacement before stopping it.
# --account <name> is the only other argument a profile accepts; every other one
# still refuses, because that refusal exists to keep resume arguments away from
# the launched CLI.
# It pins the launch to a NAMED VENDOR ACCOUNT: the Claude profiles take a claude
# account, exported as CLAUDE_CONFIG_DIR, and the Codex-backed profiles codex and
# astra take a codex account, exported as CODEX_HOME. A profile whose vendor has no account concept (pi,
# opencode, grok, cursor-grok, cursor-grok45) refuses --account rather
# than ignoring it.
# Accounts are named in local, gitignored config/accounts.json (docs/configuration.md
# owns that schema) and their homes are DERIVED as data/accounts/<vendor>/<name>,
# never read from that file. Omitting the flag uses that vendor's default when the
# file names one. With NO such file there is no pinning at all: every profile's
# argv and environment are exactly what they were before account pinning existed.
# A file that exists but cannot be read warns and launches on the ambient account,
# and refuses only an explicit --account it cannot resolve.
#
# A pinned account home is created and logged in by the CAPTAIN, never by this
# launcher: bin/fm-account.sh create <vendor> <name> makes the empty home and
# prints the login command. No credential directory, auth.json, .credentials.json,
# or keychain entry is ever copied, linked, or seeded between homes. A pinned home
# that does not exist or is explicitly logged out refuses the launch and names the
# exact login command to run; that refusal is the correct outcome, not a failure.
# An account that declares an expect identity is verified against the home before
# exec, and a mismatch refuses naming both the wanted and the actual identity, so
# a pinned session can never silently run on another seat.
#
# Two Claude seats coexist on one machine, proven 2026-09-09 on claude 2.1.258 by
# logging a second seat in: Claude Code NAMESPACES its keychain item per config
# directory, so that login added "Claude Code-credentials-<hash>" beside the
# original item and left the ambient seat untouched. Both then report logged in at
# once, and neither home holds a .credentials.json. A pinned home is unauthenticated
# only until its own login, which is why an unauthenticated pin refuses with the
# login command instead of launching. Codex isolates a different way, through the
# auth.json inside CODEX_HOME.
# Two seats can share one email address, so an email is not enough to tell them
# apart; the org and plan are. That is what an account's expect value is for.
#
# Aliases: claude -> claude-fable; opus -> claude-opus; cursor -> cursor-grok. There is no alias for cursor-grok45; name it in full so
# the previous Grok generation is never launched by accident.
# The aliases are primary-launch conveniences only.
# They never change config/crew-harness, config/secondmate-harness, dispatch
# profiles, or fm-spawn's independently verified worker-adapter set.
#
# Every launch dereferences up to 40 absolute or relative symlink hops from the
# invoked command, resolves the repository root from the resulting tracked
# script, changes to that root, refuses another live Firstmate lock holder,
# checks the selected CLI and its tracked primary integrations, installs only
# that profile's guarded status-bar surface, marks only the current terminal
# surface, then execs the CLI so sessions persist normally and the CLI exit
# status is returned with no launcher process left behind.
# Codex-backed profiles (codex and astra) refuse an explicitly logged-out
# Codex CLI, which would otherwise boot the primary to a login screen.
# Codex prints that negative on stderr and exits non-zero, so the gate reads the
# merged stream and still blocks on the message alone, never on the exit status.
# When local config/primary-handoff is present and enabled, a real launch also
# writes state/.primary-active for bin/fm-primary-handoff.sh; disabled or absent
# config leaves that marker unwritten (docs/primary-handoff.md).
#
# Cursor CLI primary support records the empirically certified agent version
# below and in docs/cursor-harness.md; any other build warns and launches.
# The launch check that can still refuse is an explicitly logged-out CLI, which
# would otherwise boot the primary to a login screen.
# Worker adapter behavior is unchanged; this profile certifies PRIMARY only.
# Never launch a cursor WORKER from the primary checkout (that checkout's
# .claude/settings.json Stop wiring is for the primary session).
#
# --install-shim creates ~/.local/bin/firstmate as a symlink to this command.
# It is idempotent only for that exact symlink and refuses every other existing
# file or symlink.
#
# Test seams:
#   FM_PRIMARY_DRY_RUN=1 prints selected profile env lines and one
#   shell-escaped argv line instead of exec.
#   It exits before the ACCOUNT login and identity gates, so a pinned launch's
#   preview always prints argv. The preview still resolves and prints the
#   account, because an unresolvable pin is a bad request rather than a missing
#   credential. This is a statement about account pinning only: the Codex and
#   Cursor profiles keep their own login gates exactly where they already were.
#   FM_PRIMARY_VISIBLE_PREFIX=LAB is accepted only inside a named fm-lab-*
#   Herdr session and visibly prefixes the role so a lab can never masquerade
#   as the captain's FIRSTMATE.
set -u

resolve_script_path() {
  local source=$1 dir target hops=0
  while [ -L "$source" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 40 ]; then
      printf 'fm-primary: refusing to resolve more than 40 symlink hops: %s\n' "$1" >&2
      return 1
    fi
    dir=$(CDPATH='' cd -P -- "$(dirname -- "$source")" && pwd -P) || return 1
    target=$(readlink "$source") || return 1
    case "$target" in
      /*) source=$target ;;
      *) source=$dir/$target ;;
    esac
  done
  printf '%s\n' "$source"
}

SCRIPT_PATH=$(resolve_script_path "${BASH_SOURCE[0]}") || exit 1
SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)
FM_ROOT=$(CDPATH='' cd -P -- "$SCRIPT_DIR/.." && pwd -P)
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
# shellcheck source=bin/fm-account-lib.sh
. "$SCRIPT_DIR/fm-account-lib.sh"
# Cursor's exact-match BLOCK existed only because its Stop turn-end hook was
# unverified on 2026.07.20-8cc9c0b, which made drift there unsafe rather than
# merely uncertified. Stop now fires (docs/cursor-harness.md, re-certified
# 2026-08-13 on the build below), so cursor joins the fleet-wide rule that
# bin/fm-toolchain-lib.sh applies: an unrecognized build warns and still
# launches, instead of turning every publisher release into an unscheduled
# outage of the certified primary.
CURSOR_CERTIFIED_VERSION=2026.08.11-e8db854

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-primary: %s\n' "$*" >&2
  exit 1
}

shell_quote() {
  local value=${1:-}
  printf "'"
  printf '%s' "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

print_argv() {
  local arg first=1
  for arg in "$@"; do
    [ "$first" -eq 1 ] || printf ' '
    shell_quote "$arg"
    first=0
  done
  printf '\n'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "profile '$PROFILE' requires '$1' on PATH"
}

require_file() {
  [ -f "$FM_ROOT/$1" ] || die "profile '$PROFILE' is missing tracked primary integration: $1"
}

refuse_active_session() {
  local out
  out=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-lock.sh" status 2>&1) || die "could not inspect the Firstmate session lock: $out"
  case "$out" in
    *"held by live harness pid"*) die "another Firstmate session is active; refusing to kill, replace, or steal from it ($out)" ;;
  esac
}

install_shim() {
  local dir=${FM_PRIMARY_SHIM_DIR:-$HOME/.local/bin} target="$FM_ROOT/bin/fm-primary.sh" shim
  shim="$dir/firstmate"
  mkdir -p "$dir" || die "could not create shim directory: $dir"
  if [ -L "$shim" ]; then
    [ "$(readlink "$shim" 2>/dev/null)" = "$target" ] || die "refusing to replace a different symlink: $shim"
    printf 'firstmate shim already installed: %s -> %s\n' "$shim" "$target"
    return 0
  fi
  [ ! -e "$shim" ] || die "refusing to replace an existing file: $shim"
  ln -s "$target" "$shim" || die "could not install shim: $shim"
  printf 'installed firstmate shim: %s -> %s\n' "$shim" "$target"
}

validate_visible_prefix() {
  VISIBLE_PREFIX=${FM_PRIMARY_VISIBLE_PREFIX:-}
  [ -n "$VISIBLE_PREFIX" ] || return 0
  [ "$VISIBLE_PREFIX" = LAB ] || die "FM_PRIMARY_VISIBLE_PREFIX accepts only LAB"
  [ "${HERDR_ENV:-}" = 1 ] || die "LAB visibility is accepted only inside Herdr"
  case "${HERDR_SESSION:-}" in
    fm-lab-*) ;;
    *) die "LAB visibility requires a named fm-lab-* Herdr session, never default" ;;
  esac
}

visible_role() {
  if [ -n "${VISIBLE_PREFIX:-}" ]; then
    printf '%s · PRIMARY' "$VISIBLE_PREFIX"
  else
    printf 'FIRSTMATE'
  fi
}

# chrome_role: the same identity as visible_role, compressed to a marker that
# fits a border title alongside every canonical status field. The role is never
# dropped - it leads the row, so it is the one part a clip cannot reach - and a
# lab primary stays visibly a lab, which is a safety property rather than
# decoration.
chrome_role() {
  if [ -n "${VISIBLE_PREFIX:-}" ]; then
    printf '%s' "$VISIBLE_PREFIX"
  else
    printf 'FM'
  fi
}

# Chrome mode's capability gate, local to this launcher on purpose.
#
# The protocol floor is only a CHEAP PRE-FILTER. Protocol 16 attests the
# managed presentation surfaces the adapter uses - workspace/pane
# report-metadata, hidden tokens, workspace/tab rename - and nothing more; the
# three surfaces chrome mode actually depends on (report-metadata --ttl-ms,
# pane get's resolved title, pane layout) are not covered by it, and the same
# protocol number also matches older herdr builds. Passing the pre-filter
# therefore proves nothing on its own.
#
# So the verdict is positive evidence, taken against the real pane, and nothing
# is hidden until every part of it succeeds: the row is published, read back,
# and required to match byte for byte, and the layout is required to return a
# parseable pane count. Any failure leaves the companion visible with its
# in-pane row as the only surface, which is exactly the pre-chrome behavior.
FM_PRIMARY_HERDR_MIN_PRESENTATION_PROTOCOL=16
FM_PRIMARY_CHROME_SOURCE=firstmate-primary-status-v1

herdr_chrome_protocol_ok() {  # <session>
  local protocol
  protocol=$(herdr --session "$1" status --json 2>/dev/null \
    | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in ''|*[!0-9]*) return 1 ;; esac
  [ "$protocol" -ge "$FM_PRIMARY_HERDR_MIN_PRESENTATION_PROTOCOL" ]
}

# herdr_chrome_pane_count: the tab's pane count, or empty when `pane layout`
# is missing, fails, or answers in a shape this launcher cannot read. Empty is
# a capability failure, not a count of zero.
herdr_chrome_pane_count() {  # <session> <pane>
  local panes
  panes=$(herdr --session "$1" pane layout --pane "$2" 2>/dev/null \
    | jq -r '.result.layout.panes | length' 2>/dev/null)
  case "$panes" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$panes"
}

# herdr_chrome_capable: publish, read back, and require an exact match.
#
# The probe row is the role marker the real row leads with, published under
# chrome mode's own source with a short ttl, so a probe that is never followed
# by a renderer expires on its own instead of freezing on the border. The
# renderer replaces it within one refresh. Nothing else publishes a title
# between these two calls: mark_current_surface has already run, and the
# companion has not started yet.
herdr_chrome_capable() {  # <session> <pane> <probe row>
  local session=$1 pane=$2 probe=$3 stored
  herdr --session "$session" pane report-metadata "$pane" \
    --source "$FM_PRIMARY_CHROME_SOURCE" \
    --title "$probe" \
    --ttl-ms 5000 >/dev/null 2>&1 || return 1
  stored=$(herdr --session "$session" pane get "$pane" 2>/dev/null \
    | jq -r '.result.pane.title // empty' 2>/dev/null)
  [ "$stored" = "$probe" ] || return 1
  herdr_chrome_pane_count "$session" "$pane" >/dev/null
}

# Resolve Claude primary effort from local config/primary-effort.
# An absent file defaults to xhigh. A present file must have a first line that
# trims to exactly one accepted token; anything else, including an empty token,
# refuses rather than falling back. Call this only for a Claude profile so a bad
# file cannot block other primaries.
resolve_claude_effort() {
  local file value
  file="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/primary-effort"
  if [ ! -f "$file" ]; then
    CLAUDE_EFFORT=xhigh
    return 0
  fi
  IFS= read -r value < "$file" || true
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    low|medium|high|xhigh|max) CLAUDE_EFFORT=$value ;;
    *) die "invalid effort in $file: '$value' (accepted: low medium high xhigh max)" ;;
  esac
}

# Resolve Astra primary effort from local config/astra-effort.
# An absent file defaults to xhigh. A present file must have a first line that
# trims to exactly one accepted token; anything else, including an empty token,
# refuses rather than falling back. Call this only for the astra profile so a
# bad file cannot block other primaries.
# Accepted tokens are low, medium, high, and xhigh only. max is refused, and that
# refusal is retained pending the separate follow-up astra-max-effort rather than
# widened here.
# This deliberately stays a sibling of resolve_claude_effort rather than a shared
# parameterised helper: the accepted token sets differ on purpose, and folding
# them together would rewrite the reader the live Fable and Opus primaries
# depend on for no real saving. Revisit only if a third caller appears.
resolve_astra_effort() {
  local file value
  file="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/astra-effort"
  if [ ! -f "$file" ]; then
    ASTRA_EFFORT=xhigh
    return 0
  fi
  IFS= read -r value < "$file" || true
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    low|medium|high|xhigh) ASTRA_EFFORT=$value ;;
    *) die "invalid effort in $file: '$value' (accepted: low medium high xhigh)" ;;
  esac
}

# Resolve the Astra launch context window from local config/astra-context.
#
# Astra ships with a default window well below what this Codex installation can
# actually grant it, and the larger window is only ever reached by asking for it
# at launch. This resolver is how that ask becomes persistent and repeatable
# instead of a private profile that only exists on one machine.
#
# An absent file changes nothing: no override is passed and Codex uses its own
# catalog default, exactly as before this setting existed.
# A present file's first line must trim to either `max` or a positive integer.
#   max        -> the installed catalog's own max_context_window for the model
#   <integer>  -> that exact window
# Either way the value is checked against the installed catalog's ceiling and a
# request above it REFUSES. The point of the setting is to reach the window this
# installation actually supports; silently clamping a too-large number, or
# passing one through, would both end in a launcher that claims a window the
# provider never granted.
# An unreadable or malformed catalog refuses `max` rather than inventing a
# number, and refuses to validate an explicit one it cannot check.
resolve_astra_context() {
  local file value ceiling
  ASTRA_CONTEXT_WINDOW=
  file="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/astra-context"
  [ -f "$file" ] || return 0
  IFS= read -r value < "$file" || true
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    ''|0|*[!0-9]*)
      [ "$value" = max ] \
        || die "invalid context window in $file: '$value' (accepted: max, or a positive integer)"
      ;;
  esac
  ceiling=$(astra_catalog_max_context_window) \
    || die "cannot read max_context_window for gpt-6-astra from the installed Codex model catalog, so $file cannot be honoured safely"
  if [ "$value" = max ]; then
    ASTRA_CONTEXT_WINDOW=$ceiling
  else
    [ "$value" -le "$ceiling" ] \
      || die "context window $value in $file exceeds what this Codex installation grants gpt-6-astra ($ceiling); lower it or use 'max'"
    ASTRA_CONTEXT_WINDOW=$value
  fi
}

# The installed catalog's max_context_window for gpt-6-astra, or failure.
# models_cache.json is Codex's own cache of what the provider currently grants
# this installation, so it - not a remembered number and not the API model
# page - is what decides the ceiling. The API maximum for a model and the window
# a subscription CLI will actually open are different quantities.
astra_catalog_max_context_window() {
  local catalog value
  catalog="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
  [ -f "$catalog" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  value=$(jq -r '
    [.models[]? | select(.slug == "gpt-6-astra") | .max_context_window]
    | map(select(type == "number")) | first // empty
  ' "$catalog" 2>/dev/null) || return 1
  case "$value" in
    ''|0|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$value"
}

# Resolve the Astra auto-compaction point from local config/astra-compact-at.
#
# Raising the window without moving this leaves Codex compacting where it always
# did, so the extra room goes unused. The right value is an operational headroom
# choice - how much of the window to spend before summarising - and nothing in
# the catalog or the provider documentation prescribes one. So the launcher
# never derives it: absent means no override at all, and the captain writes the
# number they want.
# A present value must be a positive integer strictly below the resolved window,
# and it is only meaningful alongside one.
resolve_astra_compact_at() {
  local file value
  ASTRA_COMPACT_AT=
  file="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/astra-compact-at"
  [ -f "$file" ] || return 0
  IFS= read -r value < "$file" || true
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    ''|0|*[!0-9]*) die "invalid compaction point in $file: '$value' (accepted: a positive integer)" ;;
  esac
  [ -n "$ASTRA_CONTEXT_WINDOW" ] \
    || die "$file sets a compaction point but config/astra-context selects no window; set the window first"
  [ "$value" -lt "$ASTRA_CONTEXT_WINDOW" ] \
    || die "compaction point $value in $file is not below the selected context window $ASTRA_CONTEXT_WINDOW"
  ASTRA_COMPACT_AT=$value
}

# Map a profile onto the vendor whose named accounts it can be pinned to.
# A profile with no vendor account concept has no mapping at all, so --account
# on one refuses instead of being silently ignored.
profile_account_vendor() {
  case "$PROFILE" in
    claude-fable|claude-opus) printf 'claude' ;;
    codex|astra) printf 'codex' ;;
    *) return 1 ;;
  esac
}

# Resolve the account this launch runs on, if any (bin/fm-account-lib.sh owns
# the registry contract). Sets ACCOUNT_NAME, ACCOUNT_HOME, ACCOUNT_ENV, and
# ACCOUNT_VENDOR, all empty when no pin applies - which is exactly what an
# absent config/accounts.json produces, leaving the launch unchanged.
resolve_account() {
  local vendor
  ACCOUNT_VENDOR=
  ACCOUNT_NAME=
  ACCOUNT_HOME=
  ACCOUNT_ENV=
  ACCOUNT_EXPECT=
  if ! vendor=$(profile_account_vendor); then
    [ "$ACCOUNT_SET" -eq 0 ] \
      || die "profile '$PROFILE' has no vendor account to pin; --account applies to $(fm_account_vendors) profiles only"
    return 0
  fi
  # Called directly, never through command substitution: fm_account_resolve
  # reports both its result and its refusal reason through globals.
  fm_account_resolve "$CONFIG" "$DATA" "$vendor" "$ACCOUNT_ARG" || die "$FM_ACCOUNT_ERROR"
  [ -z "$FM_ACCOUNT_WARNING" ] || printf 'fm-primary: %s\n' "$FM_ACCOUNT_WARNING" >&2
  [ -n "$FM_ACCOUNT_PIN_HOME" ] || return 0
  ACCOUNT_VENDOR=$vendor
  ACCOUNT_NAME=$FM_ACCOUNT_PIN_NAME
  ACCOUNT_HOME=$FM_ACCOUNT_PIN_HOME
  ACCOUNT_ENV=$(fm_account_env_var "$vendor")
  ACCOUNT_EXPECT=$(fm_account_expect "$(fm_account_registry_file "$CONFIG")" "$vendor" "$ACCOUNT_NAME")
}

# Refuse a pinned launch whose account home is missing, logged out, or signed in
# as a different seat than the registry declares. bin/fm-account-lib.sh owns the
# three-step gate and its wording so this launcher and bin/fm-spawn.sh cannot
# drift apart; here it only supplies the profile's CLI and the create command,
# and raises the refusal through this script's own die prefix. No credential is
# ever copied, linked, or seeded from another home, so a refusal here is the
# correct outcome rather than a failure to work around.
require_account_usable() {
  [ -n "$ACCOUNT_HOME" ] || return 0
  fm_account_require_usable "$ACCOUNT_VENDOR" "$ACCOUNT_HOME" "$CLI" "$ACCOUNT_NAME" \
    "$ACCOUNT_EXPECT" "$FM_ROOT/bin/fm-account.sh create $ACCOUNT_VENDOR $ACCOUNT_NAME" \
    || die "$FM_ACCOUNT_ERROR"
}

mark_current_surface() {
  local role session pane source title
  role=$(visible_role)
  title="$role · WAITING"
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    require_command herdr
    session=${HERDR_SESSION:-default}
    pane=$HERDR_PANE_ID
    source=firstmate-primary-visible-v1
    HERDR_SESSION="$session" herdr pane report-metadata "$pane" \
      --source "$source" \
      --title "$title" \
      --display-agent "$title" \
      --state-label "working=SUPERVISING" \
      --state-label "blocked=NEEDS YOU" \
      --state-label "idle=WAITING" \
      --state-label "done=WAITING" \
      --token "fm_role=$role" \
      --token "fm_state=WAITING" \
      --session "$session" >/dev/null 2>&1 \
      || die "could not mark the current Herdr pane as $role"
  elif [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    tmux rename-window -t "$TMUX_PANE" "$title" >/dev/null 2>&1 \
      || die "could not mark the current tmux window as $role"
  elif [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
    printf '\033]2;%s\007' "$title"
  fi
}

# Companion status rows for the profiles whose CLI exposes no third-party
# status-bar API that can carry Firstmate's fleet fields (Codex, Astra).
# Claude, Pi and Cursor use their own native surfaces instead.
#
# The companion is presentation only: if the session provider refuses the
# split, the guarded launch continues with the native TUI untouched rather
# than failing the primary.
companion_status_profile() {  # -> "adapter<TAB>model<TAB>effort", or 1
  case "$PROFILE" in
    codex) printf 'codex\tcodex\t--' ;;
    astra) printf 'codex\tgpt-6-astra\t%s' "${ASTRA_EFFORT:---}" ;;
    *) return 1 ;;
  esac
}

# install_primary_status_bar: attach the companion row through whichever
# session provider actually owns this terminal. tmux and herdr are the two
# verified companion providers; anything else leaves the native TUI alone.
install_primary_status_bar() {
  local spec adapter model effort command envs role

  spec=$(companion_status_profile) || return 0

  IFS=$'\t' read -r adapter model effort <<EOF
$spec
EOF

  # An account role is rendered only when the account owner already resolved a
  # verified name into the environment. Unknown stays unknown.
  role=${FM_ACCOUNT_NAME:-}

  # adapter, model, and effort come from the fixed profile table above (effort
  # via the validated ASTRA_EFFORT), so they are emitted literally; the paths
  # and the externally-resolved role are quoted.
  envs="FM_HOME=$(shell_quote "$FM_HOME") FM_PRIMARY_HARNESS=$adapter"
  [ -z "$role" ] || envs="$envs FM_PRIMARY_ACCOUNT_ROLE=$(shell_quote "$role")"
  command="$(shell_quote "$FM_ROOT/bin/fm-status-bar.sh") --adapter $adapter"
  command="$command --model $model --effort $effort"

  if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    command="exec env $envs $command --follow-pane $(shell_quote "$TMUX_PANE") --follow-backend tmux"
    tmux split-window -d -v -l 1 -t "$TMUX_PANE" -c "$FM_ROOT" "$command" >/dev/null 2>&1 || {
      printf 'fm-primary: status companion unavailable; continuing with the native TUI\n' >&2
    }
    return 0
  fi

  if [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    local session companion split_out panes chrome=0 zoomed=0
    session=${HERDR_SESSION:-default}
    # The companion follows the session it was launched from; a pane's
    # environment does not carry HERDR_SESSION, so re-deriving it inside the new
    # pane would silently fall back to 'default' and never resolve the primary.
    envs="$envs FM_STATUS_HERDR_SESSION=$(shell_quote "$session")"
    command="exec env $envs $command --follow-pane $(shell_quote "$HERDR_PANE_ID") --follow-backend herdr"
    # Chrome mode: publish the canonical row onto the PRIMARY pane's own border
    # title, which costs no rows, so the companion can be hidden by zoom and the
    # captain gets its rows back. Measured on herdr 0.7.4: a pane with no split
    # has no border at all, so the companion pane must keep existing for the
    # border to exist - hiding it by zoom is the reclaim, not closing it.
    # The in-pane row keeps being drawn as the fallback, so a home whose Herdr
    # cannot carry the border row behaves exactly as it did before.
    #
    # Only the cheap protocol pre-filter can run here: the real evidence needs
    # a border, and a border needs the split that has not happened yet.
    herdr_chrome_protocol_ok "$session" && chrome=1
    # Herdr's split ratio is the share the ORIGINAL pane keeps, so the agent
    # pane needs the large share and the companion takes the remainder. Herdr
    # clamps that share to 0.9, so the companion floor is a TENTH OF THE TAB,
    # not a fixed row count: two rows on a 23-row terminal, six on a 63-row one.
    # A higher ratio is still requested so a future Herdr that raises the cap
    # yields a smaller companion without another change here.
    #
    # The split response is the only authority for the pane this call created.
    # Both running the renderer and closing an unused companion use that exact
    # id: a pane inferred from the tab - positionally, or by diffing the tab
    # before and after - can be a co-tenant created by something else (an AFK
    # split, the Action Deck), and closing one of those destroys live work.
    #
    # A refused split and a split that succeeded but named no pane are different
    # outcomes: the second has already shrunk the primary, so herdr's own exit
    # status is read separately from the parse that follows it.
    split_out=$(herdr --session "$session" pane split "$HERDR_PANE_ID" --direction down \
      --ratio 0.93 --no-focus --cwd "$FM_ROOT" 2>/dev/null) || {
      printf 'fm-primary: status companion unavailable; continuing with the native TUI\n' >&2
      return 0
    }
    companion=$(printf '%s' "$split_out" \
      | jq -r '(.result.pane.pane_id // .result.root_pane.pane_id // .result.pane_id) // empty' 2>/dev/null)
    if [ -z "$companion" ] || [ "$companion" = "$HERDR_PANE_ID" ]; then
      printf 'fm-primary: herdr split the pane but did not name it, so no pane can be safely closed; the primary is sharing its tab with an empty pane\n' >&2
      return 0
    fi
    # The border now exists, so chrome mode's verdict can be EVIDENCE rather
    # than an inference from a protocol number: the row is published, read
    # back, and required to match, and the layout is required to answer with a
    # pane count. Only then is anything hidden. A failure at any step leaves
    # the companion visible and its in-pane row as the only surface, which is
    # the behavior that shipped before chrome mode.
    if [ "$chrome" = 1 ] && herdr_chrome_capable "$session" "$HERDR_PANE_ID" "$(chrome_role)"; then
      command="$command --chrome-pane $(shell_quote "$HERDR_PANE_ID")"
      command="$command --chrome-role $(shell_quote "$(chrome_role)")"

      # Zoom is applied exactly once, here, and only when this tab holds
      # nothing but the primary and the companion just created - zooming a
      # crowded tab would hide a co-tenant pane's live work. The renderer never
      # re-applies it: it only releases this zoom if a third pane shows up
      # later, so a captain who deliberately unzooms is not fought once a
      # second.
      #
      # A refused zoom is not a failure. The companion keeps rendering its own
      # row, which is the surface that shipped before chrome mode, so the only
      # consequence is that the empty rows are not reclaimed.
      panes=$(herdr_chrome_pane_count "$session" "$HERDR_PANE_ID") || panes=
      if [ "$panes" = 2 ]; then
        if herdr --session "$session" pane zoom "$HERDR_PANE_ID" --on >/dev/null 2>&1; then
          zoomed=1
          # The renderer releases only a zoom it is told this launcher applied,
          # so it can never turn off a zoom that belongs to someone else.
          command="$command --chrome-zoomed"
        else
          printf 'fm-primary: could not hide the status companion, so its rows stay visible; the status row itself is unaffected\n' >&2
        fi
      fi
    fi

    herdr --session "$session" pane run "$companion" "$command" >/dev/null 2>&1 || {
      # The zoom belongs to this launcher, so this launcher gives it back
      # before the pane it was taken for goes away.
      [ "$zoomed" = 0 ] || herdr --session "$session" pane zoom "$HERDR_PANE_ID" --off >/dev/null 2>&1
      if herdr --session "$session" pane close "$companion" >/dev/null 2>&1; then
        printf 'fm-primary: the status companion could not start; closed its pane %s and continued with the native TUI\n' \
          "$companion" >&2
      else
        printf 'fm-primary: the status companion could not start and its pane %s could not be closed; the primary is sharing its tab with an empty pane\n' \
          "$companion" >&2
      fi
      return 0
    }
    return 0
  fi

  return 0
}

verify_integrations() {
  case "$PROFILE" in
    pi)
      require_file .pi/extensions/fm-primary-turnend-guard.ts
      require_file .pi/extensions/fm-primary-pi-watch.ts
      require_file .pi/extensions/fm-primary-status-bar.ts
      require_file bin/fm-status-bar.sh
      ;;
    claude-fable|claude-opus)
      require_file .claude/settings.json
      require_file bin/fm-status-bar.sh
      require_command jq
      jq -e '
        .hooks.SessionStart
        and .hooks.PreToolUse
        and .hooks.Stop
        and (.statusLine.command | contains("bin/fm-status-bar.sh --adapter claude"))
      ' "$FM_ROOT/.claude/settings.json" >/dev/null 2>&1 \
        || die "Claude primary integrations are incomplete"
      ;;
    codex|astra)
      require_file .codex/hooks.json
      require_file bin/fm-status-bar.sh
      require_command jq
      jq -e '.hooks.SessionStart and .hooks.PreToolUse and .hooks.Stop' "$FM_ROOT/.codex/hooks.json" >/dev/null 2>&1 \
        || die "Codex primary hooks are incomplete"
      ;;
    opencode)
      require_file .opencode/plugins/fm-primary-sessionstart-nudge.js
      require_file .opencode/plugins/fm-primary-pretool-check.js
      require_file .opencode/plugins/fm-primary-cd-check.js
      require_file .opencode/plugins/fm-primary-turnend-guard.js
      require_file .opencode/plugins/fm-primary-watch-arm.js
      ;;
    grok)
      require_file .grok/hooks/fm-primary-sessionstart-nudge.json
      require_file .grok/hooks/fm-primary-pretool-check.json
      require_file .grok/hooks/fm-primary-cd-check.json
      require_file .grok/hooks/fm-primary-turnend-guard.json
      ;;
    cursor-grok|cursor-grok45)
      require_file .claude/settings.json
      require_file docs/supervision-protocols/cursor.md
      require_command jq
      jq -e '
        .hooks.SessionStart
        and .hooks.PreToolUse
        and .hooks.Stop
      ' "$FM_ROOT/.claude/settings.json" >/dev/null 2>&1 \
        || die "Cursor primary integrations are incomplete (need SessionStart, PreToolUse, and Stop in .claude/settings.json)"
      ;;
  esac
}

PROFILE=${1:-}
case "$PROFILE" in
  -h|--help|'') usage; exit 0 ;;
  --install-shim)
    [ "$#" -eq 1 ] || die "--install-shim accepts no profile or extra arguments"
    install_shim
    exit 0
    ;;
esac
# Account selection and read-only preflight ride alongside a profile. Every
# other extra argument still refuses, because that refusal exists to stop resume
# arguments reaching the launched CLI.
ACCOUNT_ARG=
ACCOUNT_SET=0
PREFLIGHT=0
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --preflight) PREFLIGHT=1; shift ;;
    --account)
      [ "$ACCOUNT_SET" -eq 0 ] || die "--account may be given only once"
      [ "$#" -ge 2 ] || die "--account requires an account name"
      ACCOUNT_ARG=$2
      ACCOUNT_SET=1
      shift 2
      ;;
    --account=*)
      [ "$ACCOUNT_SET" -eq 0 ] || die "--account may be given only once"
      ACCOUNT_ARG=${1#--account=}
      ACCOUNT_SET=1
      shift
      ;;
    *) die "profiles accept no extra arguments; use the launched CLI's normal resume UI" ;;
  esac
done
[ "$ACCOUNT_SET" -eq 0 ] || [ -n "$ACCOUNT_ARG" ] || die "--account requires an account name"
case "$PROFILE" in
  claude) PROFILE=claude-fable ;;
  opus) PROFILE=claude-opus ;;
  cursor) PROFILE=cursor-grok ;;
esac
case "$PROFILE" in
  pi|claude-fable|claude-opus|codex|astra|opencode|grok|cursor-grok|cursor-grok45) ;;
  *) die "unknown or unverified primary profile '$PROFILE' (verified: pi claude-fable claude-opus codex astra opencode grok cursor-grok cursor-grok45)" ;;
esac

validate_visible_prefix
resolve_account
if [ "$PREFLIGHT" -ne 1 ]; then
  mkdir -p "$STATE" "$DATA" || die "could not create Firstmate private state directories"
  refuse_active_session
fi

case "$PROFILE" in
  pi) CLI=pi ;;
  claude-fable) CLI=claude; CLAUDE_MODEL=claude-fable-5-1 ;;
  claude-opus) CLI=claude; CLAUDE_MODEL=claude-opus-5-5 ;;
  codex) CLI=codex ;;
  astra) CLI=codex ;;
  opencode) CLI=opencode ;;
  grok) CLI=grok ;;
  cursor-grok|cursor-grok45) CLI=${FM_CURSOR_BIN:-agent} ;;
esac
require_command "$CLI"
# Exported here, before the remaining profile checks, so anything this launcher
# asks the CLI from now on answers for the PINNED home instead of the ambient
# one. With no pin resolved this is a no-op and the environment is untouched.
[ -z "$ACCOUNT_HOME" ] || export "$ACCOUNT_ENV=$ACCOUNT_HOME"
verify_integrations

case "$PROFILE" in cursor-grok|cursor-grok45)
  version=$("$CLI" --version 2>/dev/null | head -1 | tr -d '\r')
  if [ "$version" != "$CURSOR_CERTIFIED_VERSION" ]; then
    printf 'fm-primary: Cursor primary is certified on %s; found %s (docs/cursor-harness.md) - launching anyway\n' \
      "$CURSOR_CERTIFIED_VERSION" "${version:-unknown}" >&2
  fi
  # Only an EXPLICIT negative blocks: "Not logged in" contains "logged in", and
  # an unreadable status is not evidence of a logged-out CLI.
  cursor_status=$("$CLI" status 2>/dev/null | head -5)
  case "$cursor_status" in
    *'Not logged in'*|*'not logged in'*)
      die "Cursor CLI is not logged in ('$CLI status'); the primary would boot to its login screen instead of a session" ;;
  esac
  ;;
esac

cd "$FM_ROOT" || die "could not enter tracked Starship root: $FM_ROOT"
role=$(visible_role)

case "$PROFILE" in
  pi)
    argv=(pi --name "$role")
    ;;
  claude-fable|claude-opus)
    resolve_claude_effort
    # Vendor escape hatch (Claude Code v2.1.193+): without this, the
    # primary reaps the tracked watcher-arm background shell on a
    # memory-pressure signal once 30 minutes have passed since the last
    # user interaction (docs/watcher-continuity.md).
    export CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1
    # Cap this primary's auto-compaction window at 500k TOKENS so the
    # orchestrator compacts itself instead of being managed by hand. The CLI
    # reads this variable directly and it outranks the autoCompactWindow user
    # setting, so the cap rides the launch and the captain's global config is
    # never touched. The effective threshold is min(500000, the model's own
    # maximum window).
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000
    argv=(claude --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" --name "$role" --dangerously-skip-permissions)
    printf 'fm-primary: launching model %s at effort %s\n' "$CLAUDE_MODEL" "$CLAUDE_EFFORT" >&2
    ;;
  codex)
    argv=(codex --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox -c model_auto_compact_token_limit=500000)
    ;;
  astra)
    resolve_astra_effort
    resolve_astra_context
    resolve_astra_compact_at
    argv=(codex --model gpt-6-astra -c "model_reasoning_effort=\"$ASTRA_EFFORT\"" --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox)
    [ -z "$ASTRA_CONTEXT_WINDOW" ] \
      || argv+=(-c "model_context_window=$ASTRA_CONTEXT_WINDOW")
    # The 500k cap is the default compaction point for every launch. A window
    # selected through config/astra-context is only useful with a compaction
    # point inside it, so config/astra-compact-at REPLACES the cap rather than
    # adding a second limit: exactly one value is ever passed.
    argv+=(-c "model_auto_compact_token_limit=${ASTRA_COMPACT_AT:-500000}")
    printf 'fm-primary: launching model gpt-6-astra at effort %s\n' "$ASTRA_EFFORT" >&2
    if [ -n "$ASTRA_CONTEXT_WINDOW" ]; then
      printf 'fm-primary: requesting context window %s%s (verify the first token_count model_context_window in the new session)\n' \
        "$ASTRA_CONTEXT_WINDOW" \
        "${ASTRA_COMPACT_AT:+, compacting at $ASTRA_COMPACT_AT}" >&2
    fi
    ;;
  opencode)
    argv=(opencode)
    ;;
  grok)
    argv=(grok --permission-mode bypassPermissions)
    ;;
  cursor-grok)
    argv=("$CLI" --yolo --model cursor-grok-4.6-high)
    ;;
  cursor-grok45)
    argv=("$CLI" --yolo --model cursor-grok-4.5-high)
    ;;
esac

if [ "${FM_PRIMARY_DRY_RUN:-0}" = 1 ] && [ "$PREFLIGHT" -ne 1 ]; then
  printf 'root=%s\n' "$PWD"
  printf 'profile=%s\n' "$PROFILE"
  printf 'role=%s\n' "$role"
  [ -z "${CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP:-}" ] || \
    printf 'CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=%s\n' "$CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP"
  [ -z "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" ] || \
    printf 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=%s\n' "$CLAUDE_CODE_AUTO_COMPACT_WINDOW"
  if [ -n "$ACCOUNT_HOME" ]; then
    printf 'account=%s\n' "$ACCOUNT_NAME"
    printf '%s=%s\n' "$ACCOUNT_ENV" "$ACCOUNT_HOME"
  fi
  print_argv "${argv[@]}"
  exit 0
fi

# The account login and identity gates sit below the dry-run exit, so a pinned
# launch's preview still prints argv. Account RESOLUTION stays above it: which
# account a launch would use is part of the preview, and an unresolvable pin is
# a bad request rather than a missing credential. That ordering is this feature's
# own; the Codex gate below and the Cursor gate above keep their pre-existing
# placement, so this is not a fleet-wide promise about every credential check.
require_account_usable

if [ "$PROFILE" = codex ] || [ "$PROFILE" = astra ]; then
  # Only an EXPLICIT negative blocks: "Not logged in" contains "logged in", and
  # an unreadable status is not evidence of a logged-out CLI.
  # Dry-run exits above so a missing credential cannot hide argv.
  # Codex reports the logged-out state on stderr and exits non-zero, so the
  # merged stream is the only place the negative can be read; the exit status
  # stays deliberately unread.
  codex_status=$("$CLI" login status 2>&1)
  case "$codex_status" in
    *'Not logged in'*|*'not logged in'*)
      die "Codex CLI is not logged in ('$CLI login status'); the primary would boot to its login screen instead of a session" ;;
  esac
fi

[ "$PREFLIGHT" -ne 1 ] || exit 0

mark_current_surface
export FM_PRIMARY_HARNESS=${PROFILE%%-*}
export FM_PRIMARY_ROLE=$role
# When optional primary handoff is enabled, record the live profile so the
# supervisor can rotate without guessing from process args (docs/primary-handoff.md).
# Absent or disabled config/primary-handoff leaves this path inert.
if [ -f "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/primary-handoff" ] \
  && command -v jq >/dev/null 2>&1 \
  && jq -e '.enabled == true' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/primary-handoff" >/dev/null 2>&1; then
  {
    printf 'schema=fm-primary-active.v1\n'
    printf 'profile=%s\n' "$PROFILE"
    printf 'pid=\n'
    printf 'started_at=%s\n' "$(date +%s)"
    printf 'updated_at=%s\n' "$(date +%s)"
  } > "$STATE/.primary-active"
fi
install_primary_status_bar
case "$PROFILE" in
  opencode)
    export OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}'
    exec "${argv[@]}"
    ;;
  cursor-grok|cursor-grok45)
    export FM_PRIMARY_HARNESS=cursor
    exec "${argv[@]}"
    ;;
  astra)
    export FM_PRIMARY_HARNESS=codex
    exec "${argv[@]}"
    ;;
  *) exec "${argv[@]}" ;;
esac
