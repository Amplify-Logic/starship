#!/usr/bin/env bash
# fm-addon.sh - this home's private add-on: one checkout of a separate,
# usually private repository whose skills and hooks run on top of the shared
# Starship code, so a home's own tools stay out of the shared repository and
# the two never merge into each other.
#
# WHY. Everything tracked here ships to every home. Tools that serve one home
# only (its own accounts, devices, apps, or other work) belong in a repository
# that only that home pulls. An add-on keeps this repository's layout, so a tool
# moves between the two by moving its files:
#   .agents/skills/<skill>/SKILL.md   linked into the home's checkout by
#                                     bin/fm-opt-in-skills.sh
#   hooks/<point>/<name>              run or sourced at the hook points below
#   bin/, docs/, tests/, ...          whatever its hooks and skills use
#
# CONFIG. The private, gitignored config/addon holds `key = value` lines;
# blank lines and lines starting with # are ignored:
#   path = <checkout>   required: an absolute path, ~/..., or a path relative to
#                       FM_HOME, such as projects/starship-addon
#   origin = <url>      optional: what `install` clones when the checkout is
#                       missing
# With no config/addon there is no add-on, and every command below behaves as
# if the add-on had no skills and no hooks, so such a home runs exactly as it
# did before add-ons existed.
#
# HOOK POINTS. Hooks come from two places: this repository's own hooks/<point>/
# (built-in hooks, which hold a home's tools that have not moved into an add-on
# yet) and the add-on's hooks/<point>/. An add-on hook with the same name as a
# built-in replaces it, so a tool that moves out never runs twice. Hooks run in
# name order, so a numeric prefix such as 10- sets the order.
#   bootstrap      executables run by session-start bootstrap among its
#                  read-only checks; their output lands in the startup digest.
#   session-start  executables run where the session-start digest prints the
#                  operating instructions, on the full and the re-emit path;
#                  their output is printed under ADD-ON INSTRUCTIONS.
#   sentinel       executables run by bin/fm-supervision-sentinel.sh to decide
#                  whether a home with no crew task in flight still needs
#                  watching: each prints one line naming the work it watches
#                  over, or nothing.
#   watcher        bash files named <name>.sh, sourced once into bin/fm-watch.sh
#                  when it starts, with FM_HOOK_ROOT set; hook W1 there owns the
#                  guarded functions such a file may define.
# Executable hooks run with stdin from /dev/null and with FM_HOME, FM_ROOT (this
# repository) and FM_HOOK_ROOT (the repository holding the hook) exported, plus
# any arguments given to `run`. Each is bounded by FM_ADDON_HOOK_TIMEOUT seconds
# (default 20). A hook that fails or runs out of time is named on stderr and
# never stops the caller or the hooks after it. Only entries whose names start
# with a letter or digit and hold letters, digits, dot, dash and underscore are
# hooks; anything else, and anything that is not a regular executable file (a
# readable <name>.sh file for watcher), is ignored.
#
# Usage:
#   fm-addon.sh root                 print the add-on checkout; exits 1 when no
#                                    add-on is configured and 3 when config/addon
#                                    is unusable or names a missing checkout
#   fm-addon.sh hooks <point>        print <hook root><TAB><hook path> per hook
#   fm-addon.sh run <point> [args]   run every hook of an executable point
#   fm-addon.sh install              clone origin into path when the checkout is
#                                    missing; a present checkout is left as it is
# Exits 2 on misuse. Keeping the add-on current is bin/fm-update.sh's job.
#
# Environment overrides, for tests and unusual layouts:
#   FM_HOME, FM_ROOT_OVERRIDE, FM_CONFIG_OVERRIDE, FM_ADDON_HOOK_TIMEOUT
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Built-in hooks live beside this script, whatever FM_ROOT_OVERRIDE names.
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$CODE_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ADDON_CONFIG="$CONFIG/addon"
HOOK_TIMEOUT="${FM_ADDON_HOOK_TIMEOUT:-20}"
HOOK_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {  # [exit-status]
  sed -n '/^# Usage:/,/^# Exits 2 on misuse/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-2}"
}

note() {
  printf 'fm-addon: %s\n' "$*" >&2
}

# config_value <key>: the last value given for <key> in config/addon.
config_value() {
  awk -F= -v want="$1" '
    /^[[:space:]]*(#|$)/ { next }
    {
      key = $1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
      if (key != want) next
      value = substr($0, index($0, "=") + 1)
      sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
      found = value
    }
    END { if (found != "") print found }
  ' "$ADDON_CONFIG"
}

# config_problem: name the first line of config/addon this script cannot use.
config_problem() {
  awk -F= '
    /^[[:space:]]*(#|$)/ { next }
    index($0, "=") == 0 { print "line " NR " is not key = value"; exit }
    {
      key = $1; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
      if (key != "path" && key != "origin") { print "line " NR " has unknown key " key; exit }
    }
  ' "$ADDON_CONFIG"
}

# expand_path <path>: absolute as given, ~/ under HOME, anything else under FM_HOME.
expand_path() {
  local tilde='~'
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    "$tilde") printf '%s\n' "$HOME" ;;
    "$tilde"/*) printf '%s/%s\n' "$HOME" "${1#"$tilde"/}" ;;
    *) printf '%s/%s\n' "$FM_HOME" "$1" ;;
  esac
}

# Sets ADDON_ROOT to the canonical checkout and returns 0; returns 1 with no
# config/addon, or 3 with ADDON_PROBLEM naming why the configured add-on is
# unusable. ADDON_PATH holds the configured path, expanded, whenever one is set.
ADDON_ROOT=
ADDON_PATH=
ADDON_PROBLEM=
resolve_addon() {
  local problem raw
  ADDON_ROOT=
  ADDON_PATH=
  ADDON_PROBLEM=
  [ -e "$ADDON_CONFIG" ] || [ -L "$ADDON_CONFIG" ] || return 1
  if [ ! -f "$ADDON_CONFIG" ] || [ ! -r "$ADDON_CONFIG" ]; then
    ADDON_PROBLEM="$ADDON_CONFIG is not a readable file"
    return 3
  fi
  problem=$(config_problem)
  if [ -n "$problem" ]; then
    ADDON_PROBLEM="$ADDON_CONFIG $problem"
    return 3
  fi
  raw=$(config_value path)
  if [ -z "$raw" ]; then
    ADDON_PROBLEM="$ADDON_CONFIG has no path = line"
    return 3
  fi
  ADDON_PATH=$(expand_path "$raw")
  if [ ! -d "$ADDON_PATH" ]; then
    ADDON_PROBLEM="the add-on checkout $ADDON_PATH is missing; run bin/fm-addon.sh install"
    return 3
  fi
  ADDON_ROOT=$(cd "$ADDON_PATH" && pwd -P) || {
    ADDON_PROBLEM="the add-on checkout $ADDON_PATH cannot be entered"
    return 3
  }
  if [ "$ADDON_ROOT" = "$(cd "$CODE_ROOT" && pwd -P)" ]; then
    ADDON_ROOT=
    ADDON_PROBLEM="$ADDON_CONFIG names this Firstmate checkout itself, not an add-on"
    return 3
  fi
  return 0
}

valid_point() {
  case "$1" in
    bootstrap|session-start|sentinel|watcher) return 0 ;;
  esac
  return 1
}

# is_hook <point> <path>: whether <path> is a hook for <point>.
is_hook() {
  local point=$1 path=$2 name
  name=${path##*/}
  [[ $name =~ $HOOK_NAME_RE ]] || return 1
  [ -f "$path" ] || return 1
  if [ "$point" = watcher ]; then
    case "$name" in *.sh) ;; *) return 1 ;; esac
    [ -r "$path" ]
  else
    [ -x "$path" ]
  fi
}

# list_hooks <point>: <root><TAB><path> per hook in name order, built-ins first
# considered and replaced by an add-on hook of the same name.
list_hooks() {
  local point=$1 rank root entry status=0
  resolve_addon || status=$?
  [ "$status" -ne 3 ] || note "$ADDON_PROBLEM"
  {
    rank=0
    for root in "$CODE_ROOT" ${ADDON_ROOT:+"$ADDON_ROOT"}; do
      for entry in "$root/hooks/$point"/*; do
        is_hook "$point" "$entry" || continue
        printf '%s\t%s\t%s\t%s\n' "${entry##*/}" "$rank" "$root" "$entry"
      done
      rank=1
    done
  } | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n \
    | awk -F '\t' '
        $1 != name && name != "" { print kept }
        { name = $1; kept = $3 "\t" $4 }
        END { if (name != "") print kept }
      '
}

run_hooks() {
  local point=$1 root hook rc
  shift
  export FM_HOME
  FM_ROOT=$CODE_ROOT
  export FM_ROOT
  while IFS="$(printf '\t')" read -r root hook; do
    [ -n "$hook" ] || continue
    rc=0
    fm_run_timed "$HOOK_TIMEOUT" env FM_HOOK_ROOT="$root" "$hook" "$@" </dev/null || rc=$?
    if fm_timed_out "$rc"; then
      note "$point hook $hook ran out of time after ${HOOK_TIMEOUT}s"
    elif [ "$rc" -ne 0 ]; then
      note "$point hook $hook failed (exit $rc)"
    fi
  done <<EOF
$(list_hooks "$point")
EOF
  return 0
}

install_addon() {
  local status=0 origin out
  resolve_addon || status=$?
  case "$status" in
    0)
      printf 'add-on: present at %s\n' "$ADDON_ROOT"
      return 0
      ;;
    1)
      note "no add-on is configured; write $ADDON_CONFIG first (docs/configuration.md \"Private add-on\")"
      return 1
      ;;
  esac
  if [ -z "$ADDON_PATH" ] || [ -e "$ADDON_PATH" ] || [ -L "$ADDON_PATH" ]; then
    note "$ADDON_PROBLEM"
    return 1
  fi
  origin=$(config_value origin)
  if [ -z "$origin" ]; then
    note "$ADDON_CONFIG has no origin = line, so there is nothing to clone into $ADDON_PATH"
    return 1
  fi
  mkdir -p "$(dirname "$ADDON_PATH")" || { note "cannot create the parent of $ADDON_PATH"; return 1; }
  if ! out=$(GIT_TERMINAL_PROMPT=0 git clone --quiet -- "$origin" "$ADDON_PATH" 2>&1 </dev/null); then
    note "cloning $origin failed: ${out%%$'\n'*}; a private add-on needs a GitHub sign-in that git can use (gh auth login, then gh auth setup-git)"
    return 1
  fi
  printf 'add-on: cloned %s into %s\n' "$origin" "$ADDON_PATH"
}

case "${1:-}" in
  root)
    [ "$#" -eq 1 ] || usage
    status=0
    resolve_addon || status=$?
    case "$status" in
      0) printf '%s\n' "$ADDON_ROOT" ;;
      3) note "$ADDON_PROBLEM" ;;
    esac
    exit "$status"
    ;;
  hooks)
    if [ "$#" -ne 2 ] || ! valid_point "$2"; then usage; fi
    list_hooks "$2"
    ;;
  run)
    if [ "$#" -lt 2 ] || ! valid_point "$2" || [ "$2" = watcher ]; then usage; fi
    shift
    run_hooks "$@"
    ;;
  install)
    [ "$#" -eq 1 ] || usage
    install_addon
    ;;
  -h|--help|help) usage 0 ;;
  *) usage ;;
esac
