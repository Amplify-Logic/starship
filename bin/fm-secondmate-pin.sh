#!/usr/bin/env bash
# fm-secondmate-pin.sh - read or change one second mate's model pin safely.
#
# Usage (FM_HOME must be set explicitly):
#   fm-secondmate-pin.sh show <mate-id>
#   fm-secondmate-pin.sh set <mate-id> <harness> [<model> [<effort>]]
#   fm-secondmate-pin.sh clear <mate-id>
#
# docs/configuration.md "Choose the secondmate harness" owns the pin file,
# config/secondmate-harness, and its resolution; bin/fm-harness.sh owns the
# resolver. This script only edits the one `mate <id>:` line for a mate, so a
# page or a person can change a mate's model without hand-editing the file:
#   - <mate-id> must be registered in this home's data/secondmates.md;
#   - <harness> must be a harness the control plane can relaunch
#     (bin/fm-control-lib.sh fm_control_harnesses) or `default`;
#   - <effort>, when given, is one of low, medium, high, xhigh, max;
#   - the edit is written to a copy, the whole copy must still resolve through
#     bin/fm-harness.sh for that mate (so a malformed or legacy file the new
#     line would break is refused with the resolver's own error), and only
#     then does the copy replace the file, under a lock.
# The change takes effect at the mate's next launch; relaunch it with
# `bin/fm-control.sh <mate-id> relaunch` (a remote mate:
# bin/fm-remote-secondmate-relaunch.sh). Nothing here relaunches anything.
#
# Every command prints one JSON document (schema fm-secondmate-pin.v1): mate,
# harness, model, effort (the resolved values, null when absent) and source:
#   mate      a `mate <id>:` line pins this mate
#   default   the file's default line applies
#   none      the file pins nothing, so the crew harness or the first mate's
#             own harness applies
# Exit: 0 ok, 1 failure, 2 refused or bad usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}
die() { printf 'fm-secondmate-pin: %s\n' "$*" >&2; exit 1; }
refuse() { printf 'fm-secondmate-pin: %s\n' "$*" >&2; exit 2; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  show|set|clear) ;;
  *) usage >&2; exit 2 ;;
esac
[ -n "${FM_HOME:-}" ] || refuse "FM_HOME is not set; a pin belongs to an explicit home"
[ -d "$FM_HOME" ] || refuse "FM_HOME '$FM_HOME' is not a directory"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PIN_FILE="$CONFIG/secondmate-harness"
command -v jq >/dev/null 2>&1 || die "jq is required"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

verb=$1
shift
ID=${1:-}
[ -n "$ID" ] || refuse "usage: fm-secondmate-pin.sh $verb <mate-id> ..."
case "$ID" in .*|-*|*[!A-Za-z0-9._-]*) refuse "not a second mate id: '$ID'" ;; esac
shift
rc=0
secondmate_registry_line_for_id "$DATA/secondmates.md" "$ID" || rc=$?
case "$rc" in
  0) ;;
  2) refuse "$SECONDMATE_REGISTRY_ERROR" ;;
  *) refuse "second mate '$ID' is not registered (exactly once) in $DATA/secondmates.md" ;;
esac

# The resolver, run against config dir <dir>.
resolve() {  # <config-dir> <secondmate|secondmate-model|secondmate-effort>
  FM_CONFIG_OVERRIDE=$1 "$SCRIPT_DIR/fm-harness.sh" "$2" "$ID"
}

# 0 when the pin file in <dir> has a `mate <ID>:` line.
has_mate_line() {  # <config-dir>
  [ -f "$1/secondmate-harness" ] || return 1
  grep -Eq "^[[:space:]]*mate[[:space:]]+${ID//./\\.}[[:space:]]*:" "$1/secondmate-harness"
}

has_default_line() {  # <config-dir>
  [ -f "$1/secondmate-harness" ] || return 1
  grep -Ev '^[[:space:]]*(#|$)' "$1/secondmate-harness" \
    | grep -Ev '^[[:space:]]*mate([[:space:]]|:|$)' 2>/dev/null | grep -q .
}

print_pin() {  # <config-dir>
  local harness model effort source=none
  if [ -f "$1/secondmate-harness" ]; then
    harness=$(resolve "$1" secondmate) || exit 1
    model=$(resolve "$1" secondmate-model) || exit 1
    effort=$(resolve "$1" secondmate-effort) || exit 1
    if has_mate_line "$1"; then
      source=mate
    elif has_default_line "$1"; then
      source=default
    fi
  else
    harness=$(resolve "$1" secondmate) || exit 1
    model='' effort=''
  fi
  jq -cn --arg mate "$ID" --arg harness "$harness" --arg model "$model" --arg effort "$effort" --arg source "$source" \
    '{schema:"fm-secondmate-pin.v1", mate:$mate,
      harness:(if $harness == "" then null else $harness end),
      model:(if $model == "" then null else $model end),
      effort:(if $effort == "" then null else $effort end), source:$source}'
}

# Write <new-line> (empty: remove) as this mate's line in a copy, validate
# the copy, then replace the file under the config lock.
PIN_LOCK=
PIN_TMP=
rewrite() {  # <new-line> [<harness> <model> <effort>]
  local new=$1 out got want
  [ ! -L "$PIN_FILE" ] || refuse "$PIN_FILE is a symlink; refusing to rewrite it"
  mkdir -p "$CONFIG" || die "cannot create $CONFIG"
  PIN_LOCK="$CONFIG/.secondmate-harness.lock"
  fm_lock_try_acquire "$PIN_LOCK" || die "another change to $PIN_FILE is in progress"
  trap 'fm_lock_release "$PIN_LOCK"; [ -z "$PIN_TMP" ] || rm -rf "$PIN_TMP"' EXIT
  PIN_TMP=$(mktemp -d "$CONFIG/.pin.XXXXXX") || die "cannot create a temporary copy"
  local tmpdir=$PIN_TMP
  if [ -f "$PIN_FILE" ]; then
    awk -v id="$ID" -v new="$new" '
      {
        line = $0
        sub(/^[ \t]+/, "", line)
        if (line ~ /^mate[ \t]+/) {
          rest = line
          sub(/^mate[ \t]+/, "", rest)
          name = rest
          sub(/[ \t]*:.*/, "", name)
          if (name == id) {
            if (!done && new != "") print new
            done = 1
            next
          }
        }
        print
      }
      END { if (!done && new != "") print new }
    ' "$PIN_FILE" > "$tmpdir/secondmate-harness" || die "cannot write the copy"
  elif [ -n "$new" ]; then
    printf '%s\n' "$new" > "$tmpdir/secondmate-harness" || die "cannot write the copy"
  else
    print_pin "$CONFIG"
    return 0
  fi
  if ! out=$(resolve "$tmpdir" secondmate 2>&1 >/dev/null); then
    refuse "the changed pin file would not resolve, so nothing was changed: ${out#error: }"
  fi
  # A set must read back as exactly the harness, model and effort it wrote.
  if [ -n "$new" ] && [ "${2:-default}" != default ]; then
    for want in "secondmate:$2" "secondmate-model:$3" "secondmate-effort:$4"; do
      got=$(resolve "$tmpdir" "${want%%:*}" 2>/dev/null) \
        || refuse "the changed pin file would not resolve its ${want%%:*}, so nothing was changed"
      [ "$got" = "${want#*:}" ] \
        || refuse "the changed pin would read back as '$got', not '${want#*:}', so nothing was changed"
    done
  fi
  chmod 600 "$tmpdir/secondmate-harness" 2>/dev/null || true
  mv -f "$tmpdir/secondmate-harness" "$PIN_FILE" || die "cannot replace $PIN_FILE"
  print_pin "$CONFIG"
}

case "$verb" in
  show)
    [ "$#" -eq 0 ] || refuse "usage: fm-secondmate-pin.sh show <mate-id>"
    print_pin "$CONFIG"
    ;;
  clear)
    [ "$#" -eq 0 ] || refuse "usage: fm-secondmate-pin.sh clear <mate-id>"
    rewrite ''
    ;;
  set)
    [ "$#" -ge 1 ] && [ "$#" -le 3 ] || refuse "usage: fm-secondmate-pin.sh set <mate-id> <harness> [<model> [<effort>]]"
    harness=$1 model=${2:-} effort=${3:-}
    [ "$harness" = default ] || fm_control_harness_supported "$harness" \
      || refuse "'$harness' is not a harness the control plane can relaunch; one of: default $(fm_control_harnesses | tr '\n' ' ')"
    case "$model" in -*|*[!A-Za-z0-9._:/@+-]*) refuse "not a model name: $model" ;; esac
    case "$effort" in ''|low|medium|high|xhigh|max) ;; *) refuse "effort must be one of low, medium, high, xhigh, max" ;; esac
    [ "$harness" != default ] || [ -z "$model$effort" ] || refuse "a 'default' pin takes no model or effort"
    rewrite "mate $ID: $harness${model:+ $model}${effort:+ $effort}" "$harness" "$model" "$effort"
    ;;
esac
