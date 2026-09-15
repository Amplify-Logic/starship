#!/usr/bin/env bash
# Build the human tab title for a managed worker from a resolved outcome.
#
# Usage: fm-visible-title.sh <outcome> [state-label]
#
# The title format is fork-owned presentation, so it lives here rather than in
# the upstream-owned spawn path. Upstream names a worker by its opaque window
# name; this fork names it by what it is doing. Keeping the string here means
# the spawn path carries a guarded call and a fallback, never a format.
#
# The outcome is resolved by bin/fm-task-outcome.sh, which owns its precedence.
# This script deliberately does not resolve it: spawn already needs the raw
# outcome for the task's durable record, so resolving it twice would let the
# recorded outcome and the displayed one drift apart.
#
# The state label defaults to the waiting state a worker is in at spawn, which
# is the only moment spawn needs a title; other surfaces pass their own.
set -eu

usage() {
  echo "usage: fm-visible-title.sh <outcome> [state-label]" >&2
}

main() {
  local outcome=${1:-} state=${2:-'🟡 WAITING'}
  [ -n "$outcome" ] || { usage; return 1; }
  printf 'WORKER · %s · %s\n' "$outcome" "$state"
}

main "$@"
