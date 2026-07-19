#!/usr/bin/env bash
# Resolve the concise human outcome used for a managed worker.
#
# Usage: fm-task-outcome.sh <task-id> [explicit-outcome]
#
# Precedence is an explicit spawn/meta outcome, then the structured title of the
# matching tasks-axi backlog row, then a safe humanized task-id fallback.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
id=${1:?usage: fm-task-outcome.sh <task-id> [explicit-outcome]}
outcome=${2:-}

one_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

if [ -z "$outcome" ] && [ -f "$DATA/backlog.md" ]; then
  outcome=$(awk -v id="$id" '
    {
      prefix = "- [ ] " id " - "
      done_prefix = "- [x] " id " - "
      done_prefix_upper = "- [X] " id " - "
      if (index($0, prefix) == 1 || index($0, done_prefix) == 1 || index($0, done_prefix_upper) == 1) {
        line = $0
        sub(/^- \[[ xX]\] [^ ]+ - /, "", line)
        sub(/[[:space:]]+\(repo:[[:space:]].*$/, "", line)
        print line
        exit
      }
    }
  ' "$DATA/backlog.md")
fi
[ -n "$outcome" ] || outcome=$(printf '%s' "$id" | tr '._-' '   ')
one_line "$outcome"
printf '\n'
