#!/usr/bin/env bash
# fm-triage-second-look.sh - an opt-in second look over the status lines the
# deterministic wake classifier has already dropped.
#
# Firstmate's shipped classifier (bin/fm-classify-lib.sh) decides what is
# captain-relevant from a status line's leading verb. That is deliberately
# verb-aware and correctly refuses to be fooled by prose, but a verb test cannot
# read a sentence: a worker that writes
#   working: the backfill migration truncated public.users on staging; 4100 rows gone
# is dropped permanently by every caller, and nobody ever learns the table is
# gone. This command closes exactly that gap and nothing else.
#
# ESCALATE-ONLY, and that is the property that makes a paid, networked, semantic
# judgment safe inside a supervision loop. It is only ever handed lines the
# classifier ALREADY dropped, and the only thing it can emit is a promotion.
# There is no output that silences a line, so neither a model answer nor text a
# worker writes into a status line can suppress an escalation Firstmate would
# otherwise make. The worst a hostile status line can achieve is one extra line
# in a digest.
#
# FAIL-OPEN. Not opted in, no key, no python3, a timeout, a rate limit, a
# malformed body - every one of them prints nothing and exits nonzero, and
# supervision behaves exactly as it does today. "The second look is down" and
# "the second look was never built" are the same state, so callers run it with
# `|| true`, read promotions from its stdout, and send its stderr to their own log.
#
# NEVER ON THE PER-WAKE PATH. The two callers are the heartbeat backstops
# (bin/fm-watch.sh and bin/fm-supervise-daemon.sh), which run on the heartbeat
# cadence. The per-wake watcher path must stay cheap and work offline.
#
# Usage:
#   fm-triage-second-look.sh                 read records on stdin, print promotions
#   fm-triage-second-look.sh --dry-run       build and print the request; no network,
#                                           and no gate, so an unarmed home can preview it
#   fm-triage-second-look.sh --help
#
# stdin   one record per line: <task-id> TAB <status-line>
#         Callers produce these from status_span_dropped_lines (fm-classify-lib.sh).
# stdout  one promotion per line: <task-id> TAB <tier> TAB <reason> TAB <status-line>
#         <tier> is alert or digest. <tier> alert means the supervisor should be
#         interrupted; digest means it joins the next batch. <reason> is the
#         +-joined conditions that fired: needs_captain, adverse_event,
#         understated_terminal. Callers carry the reason into the digest so the
#         supervisor reads WHY a line was raised.
# stderr  diagnostics only; never the API key, never a line's content.
#
# Exit 0 when a decision was reached, including "promote nothing". Exit 1 when
# this home is not armed, which --dry-run never returns. Exit 2 on any bounded
# failure. Every nonzero exit means the same thing to a caller: promote nothing.
#
# OPT-IN: per home and per device, through the private gitignored
# config/triage-second-look. With no `enabled = true` line this command is inert
# and makes no network call at all, so cloning this repository, seeding a
# secondmate home, or adding a device never starts making paid calls. The gate is
# deliberately NOT inherited into secondmate homes for the same reason.
# Configuration is `key = value` lines; the only key is `enabled`. Unlike
# config/speak, a malformed gate file reports and leaves this home INERT rather
# than exiting loudly, because the caller is a supervision loop and a config typo
# must never change what that loop does.
#
# Cost: at most ~516 input tokens per dropped line at $42/Btok, measured
# 2026-09-17 before the request was narrowed to the dropped line alone. A heartbeat scan carrying
# five new dropped lines is about $0.0001, and a busy home all day is under $1 a
# month. Most scans carry zero or one line.
#
# Env:
#   FM_HOME                                 operational home (default: this repo root)
#   FM_TRIAGE_SECOND_LOOK_TIMEOUT           per-request bound in seconds (default 8)
#   FM_TRIAGE_SECOND_LOOK_BOUND             hard bound on the whole call (default 20)
#   FM_TRIAGE_SECOND_LOOK_ENDPOINT          API endpoint
#   FM_TRIAGE_SECOND_LOOK_ENV_FILE          .env holding TYPESAFE_API_KEY
#   FM_TRIAGE_SECOND_LOOK_RESPONSE          test seam: a recorded response body,
#                                           used instead of the network so the real
#                                           request build and threshold rule still run
#   TYPESAFE_API_KEY                        wins over the .env; never logged
#
# The request shape, the four questions, the thresholds and the tier rule are
# owned by the engine, bin/fm-triage-second-look.py. docs/configuration.md
# "Status second look" owns the operator-facing contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
ENGINE="$SCRIPT_DIR/fm-triage-second-look.py"
CONFIG_FILE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/triage-second-look"
BOUND="${FM_TRIAGE_SECOND_LOOK_BOUND:-20}"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

note() {
  printf 'fm-triage-second-look: %s\n' "$*" >&2
}

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
}

# 0 when this home has opted in. A missing file is the ordinary inert case and
# says nothing; a malformed one says so once and stays inert.
armed() {
  local line key value enabled=false
  [ -f "$CONFIG_FILE" ] || return 1
  if [ -L "$CONFIG_FILE" ]; then
    note "gate must be a regular file, not a symlink: $CONFIG_FILE"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) ;;
      *) note "gate line is not key = value, staying inert: $line"; return 1 ;;
    esac
    key=$(printf '%s\n' "${line%%=*}" | tr -d '[:space:]')
    value=$(printf '%s\n' "${line#*=}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$key" in
      enabled)
        case "$value" in
          true|false) enabled=$value ;;
          *) note "enabled must be true or false, staying inert: $value"; return 1 ;;
        esac
        ;;
      *) note "unknown gate key, staying inert: $key"; return 1 ;;
    esac
  done < "$CONFIG_FILE"
  [ "$enabled" = true ]
}

DRY_RUN=0
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --dry-run) DRY_RUN=1 ;;
  '') ;;
  *) note "unknown argument: $1"; exit 2 ;;
esac

# The gate guards the paid call, not the preview. --dry-run reaches no network
# and costs nothing, and it is the one command that shows an operator what would
# leave this machine, so it must answer before anyone decides whether to arm.
[ "$DRY_RUN" -eq 1 ] || armed || exit 1

if [ ! -r "$ENGINE" ]; then
  note "engine missing: $ENGINE"
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  note "python3 is not installed (promoting nothing)"
  exit 2
fi
case "$BOUND" in
  ''|*[!0-9]*|0) note "bound must be a positive integer: $BOUND"; exit 2 ;;
esac

# The bound is the caller's protection, not the request's: the engine already
# bounds its own HTTP read, and this is what stops a wedged interpreter or a
# stalled DNS lookup from holding a supervision loop open.
export FM_HOME

# The batch is spooled and redirected INSIDE the bounded command. fm_run_timed's
# external-timeout mechanism launches its runner asynchronously without job
# control, and bash points an async command's stdin at /dev/null, so a pipe into
# this script would otherwise reach the engine as an empty batch on every host
# that has GNU or BSD timeout - silently, since an empty batch promotes nothing.
SPOOL=$(mktemp "${TMPDIR:-/tmp}/fm-triage-second-look.XXXXXX") || {
  note "could not spool the batch (promoting nothing)"
  exit 2
}
trap 'rm -f "$SPOOL"' EXIT
cat > "$SPOOL"

status=0
# shellcheck disable=SC2016 # $1 and $2 are the INNER shell's positional
# parameters, supplied after the -c script; expanding them here would bake this
# shell's values into the script text instead of passing them.
if [ "$DRY_RUN" -eq 1 ]; then
  fm_run_timed "$BOUND" bash -c 'exec python3 "$1" --dry-run < "$2"' _ "$ENGINE" "$SPOOL" || status=$?
else
  fm_run_timed "$BOUND" bash -c 'exec python3 "$1" < "$2"' _ "$ENGINE" "$SPOOL" || status=$?
fi
case "$status" in
  0) exit 0 ;;
  124) note "bound of ${BOUND}s hit (promoting nothing)"; exit 2 ;;
  *) exit 2 ;;
esac
