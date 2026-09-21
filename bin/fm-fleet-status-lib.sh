#!/usr/bin/env bash
# fm-fleet-status-lib.sh - truthful fleet fields for the primary status bar.
#
# Why this exists: the status row used to count every state/<id>.meta as a ship
# and fold the last line of each status log into "paused" and "attention". Both
# readings are wrong in the same direction - they make records look like running
# workers. A meta file outlives its worker, so a fleet of two live agents and ten
# finished records rendered as twelve ships; and AGENTS.md section 8 defines a
# status line as a wake EVENT, not current state, so a task that resumed after a
# decision kept counting as parked for as long as its log's last line said so.
#
# The fix is to stop deriving state here at all. bin/fm-crew-state.sh is the
# canonical current-state reader - it owns run attribution, the pane fallback,
# and the stale-log reconciliation - and this library only folds its answers into
# counts. Nothing here selects a run, re-implements attribution, or second-
# guesses a state word; a change to how a run is chosen belongs in that reader.
#
# Folding current state was not enough on its own. A state word describes the
# WORK, and the captain's question is about the WORKERS: on 2026-09-21 fifteen
# records rendered while ten of them had a dead endpoint or a worktree that was
# already gone, and nothing in the row said so. So the fold also asks each task's
# recorded endpoint whether an agent is running on it, through the one
# recovery-grade classifier in bin/fm-backend.sh, and reports the live count and
# the recorded-but-stopped count as separate figures. The probe rides the same
# out-of-band refresh as the canonical read, so it costs a frame nothing.
#
# The cost is why the answers are cached. A canonical read is about a second per
# task because it consults the pipeline, so a twelve-task fleet is over ten
# seconds - three orders of magnitude more than the renderer's one-second frame.
# The reading is therefore taken out of band, by ONE detached refresher at a
# time, and every frame renders whatever the cache already holds. A frame never
# waits, never forks per task, and never blocks the pane.
#
# What the fields mean, and what keeps them honest:
#
#   records     ordinary task records in this home, excluding second mates.
#               Free to count and always exact. It is the one number that is
#               deliberately NOT a claim about running workers.
#   alive       an agent is running on the task's recorded endpoint right now.
#               This is the headline, because it is the only number that answers
#               "how many workers do I actually have".
#   stopped     the record is still here but its worker is not: the endpoint is
#               proven dead or absent, or the recorded worktree is gone.
#   validating  the validation pipeline owns the task - it is progressing, but
#               no worker is typing at it.
#   paused      a declared bounded external wait.
#   attention   firstmate has to act: a decision, a blocker, or a failure.
#
# alive and stopped are separate readings of the same fleet rather than two ends
# of one axis, and a task counts toward NEITHER unless its state was proven: a
# backend with no recovery classifier, an unreachable remote secondmate, or a
# record with no endpoint at all leaves the task in records only. Overstating
# either side is the failure this library exists to prevent.
#
# The five live fields are all-or-nothing: without a usable reading they are
# reported unknown together, and the renderer shows placeholders. They are never
# reported as zero to stand in for "not read yet", because zero live workers is
# a real and meaningful fleet state that the captain must be able to trust.
#
# A cached reading also carries the exact set of tasks it covered. If the fleet
# has changed since - a task torn down, another dispatched - the reading is about
# a different fleet and is discarded rather than re-applied to this one.
#
# Test seams:
#   FM_FLEET_STATE_TTL       seconds before a reading is refreshed (default 120)
#   FM_FLEET_STATE_MAX_AGE   seconds before a reading is unusable (default 420)
#   FM_FLEET_STATE_WAIT      wall-clock bound on one refresh (default 90)
#   FM_FLEET_STATE_WARM_TTL  how long one refresh is considered in flight (90,
#                            and never less than FM_FLEET_STATE_WAIT)
#   FM_FLEET_STATE_NOW       override the current epoch
#   FM_FLEET_STATE_READER    canonical reader to fold (default fm-crew-state.sh)
#   FM_FLEET_STATE_PROBE     endpoint liveness prober invoked as
#                            `<probe> <backend> <target>` and answering
#                            alive|dead|unknown (default: fm_backend_agent_alive
#                            from bin/fm-backend.sh)
#   FM_FLEET_STATE_NO_CACHE  1 to read inline and bypass the cache entirely
set -u

_FM_FLEET_LIB_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-status-cache-lib.sh
. "$_FM_FLEET_LIB_DIR/fm-status-cache-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_FLEET_LIB_DIR/fm-timeout-lib.sh"

# _fm_fleet_now: current epoch, or failure when it cannot be read.
_fm_fleet_now() {
  local now=${FM_FLEET_STATE_NOW:-}
  [ -n "$now" ] || now=$(date +%s 2>/dev/null)
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$now"
}

# _fm_fleet_ids: the ordinary task ids in <state>, one per line, sorted.
# Second mates are persistent direct reports rather than work items, so they are
# excluded here exactly as they were from the count this replaces.
_fm_fleet_ids() {  # <state-dir>
  local meta id kind
  for meta in "$1"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(awk -F= '$1 == "kind" { print substr($0, index($0, "=") + 1); exit }' "$meta" 2>/dev/null)
    [ "$kind" = secondmate ] && continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done | LC_ALL=C sort
}

# _fm_fleet_signature: a compact, order-stable token for a set of task ids, so a
# reading taken for one fleet is never applied to a different one.
#
# It digests the id STREAM, so every caller must feed it the bytes _fm_fleet_ids
# emits and nothing else. Re-emitting a captured list with `printf '%s\n'` is not
# the same stream: command substitution strips the trailing newline, which that
# printf restores for a non-empty list but ADDS for an empty one, so an empty
# fleet would sign one newline here and zero bytes there and never match itself.
# _fm_fleet_id_stream exists so a captured list can be replayed exactly.
_fm_fleet_signature() {  # <ids on stdin>
  local digest
  digest=$(cksum 2>/dev/null) || return 1
  [ -n "$digest" ] || return 1
  printf '%s' "${digest// /-}"
}

# _fm_fleet_id_stream: re-emit a captured id list byte-for-byte as _fm_fleet_ids
# wrote it, including the empty stream for a fleet of zero records.
_fm_fleet_id_stream() {  # <id>...
  local id
  for id in "$@"; do
    printf '%s\n' "$id"
  done
}

# _fm_fleet_bucket: the field a canonical state line belongs in, or nothing when
# the task is a record rather than live work.
#
# The distinction the captain actually asked for lives in the SOURCE, not the
# state word: `working · run-step` means the pipeline is carrying the task, while
# `working · pane` means a worker is busy on it. Folding both into one "active"
# number is what made a validating task indistinguishable from a typing one.
#
# The `working` bucket is not a displayed field of its own any more: the fold
# consumes it as proof of life for the liveness reading below, where a worker
# the busy classifier just watched is alive whatever an endpoint probe can say.
_fm_fleet_bucket() {  # <canonical line>
  local line=$1 state source
  state=${line#*state: }
  state=${state%% *}
  source=${line#*source: }
  source=${source%% *}
  case "$state" in
    working)
      case "$source" in
        run-step) printf 'validating' ;;
        *) printf 'working' ;;
      esac
      ;;
    paused) printf 'paused' ;;
    parked|blocked|failed) printf 'attention' ;;
    *) ;;
  esac
}

# _fm_fleet_backend_ready: load bin/fm-backend.sh once, on first use.
#
# It is sourced HERE rather than at library load because the renderer sources
# this library in the frame process and a frame never reads metadata or probes
# an endpoint. Only the out-of-band fold pays for it.
_fm_fleet_backend_ready() {
  [ "${_FM_FLEET_BACKEND_READY:-}" = 1 ] && return 0
  # shellcheck source=bin/fm-backend.sh
  . "$_FM_FLEET_LIB_DIR/fm-backend.sh" 2>/dev/null || return 1
  _FM_FLEET_BACKEND_READY=1
  return 0
}

# _fm_fleet_probe_default: the shipped endpoint prober. It is the recovery-grade
# classifier in bin/fm-backend.sh and nothing else, so "alive" here means the
# same proven-at-process-level thing it means to recovery, and an endpoint that
# merely failed to answer stays unknown instead of being called dead.
_fm_fleet_probe_default() {  # <backend> <target>
  fm_backend_agent_alive "$1" "$2" 2>/dev/null || printf 'unknown'
}

# _fm_fleet_liveness: alive, stopped, or unknown for one task record.
#
# Order matters, and it is an order of PROOF rather than of preference:
#
#   1. A remote secondmate's endpoint lives on another host, so nothing local
#      can judge it. Ordinary tasks are local; this is the belt-and-braces arm
#      for a record that carries remote_host= anyway.
#   2. A recorded worktree that is gone is checked FIRST, and it is decisive.
#      The work that record describes no longer exists on disk, so whatever is
#      or is not still attached to its endpoint is not a worker carrying it -
#      which is exactly the case the captain kept being shown as a ship. It is
#      also a local stat, so it spends no probe.
#   3. The endpoint prober's own "alive" is the strongest evidence of a worker
#      there is: bin/fm-backend.sh proves it at process level.
#   4. A canonical `working` fold - the reader saw `working · pane`, a worker
#      busy at the task - is also proof of life: the busy classifier just watched
#      that worker do something. This arm is what keeps the count honest on a
#      backend with no recovery classifier, where the prober can only ever
#      answer unknown.
#   5. The prober's own "dead" - the endpoint exists with no agent, or is
#      authoritatively absent.
#
# Anything left over is unknown, and an unknown task is counted in neither
# figure. A record with no endpoint recorded at all lands here: it cannot hold a
# live agent, but calling it stopped would assert a death this library never
# established, and the record count already says the task is here.
_fm_fleet_liveness() {  # <meta> <busy: 1 when the fold read a busy pane worker> <prober>
  local meta=$1 busy=$2 probe=$3 backend target worktree verdict

  _fm_fleet_backend_ready || {
    printf 'unknown'
    return 0
  }
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || {
    printf 'unknown'
    return 0
  }
  worktree=$(fm_meta_get "$meta" worktree)
  if [ -n "$worktree" ] && [ ! -d "$worktree" ]; then
    printf 'stopped'
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  verdict=unknown
  if [ -n "$target" ]; then
    verdict=$("$probe" "$backend" "$target" 2>/dev/null) || verdict=unknown
    [ "$verdict" = alive ] && {
      printf 'alive'
      return 0
    }
  fi
  [ "$busy" = 1 ] && {
    printf 'alive'
    return 0
  }
  [ "$verdict" = dead ] && {
    printf 'stopped'
    return 0
  }
  printf 'unknown'
}

# _fm_fleet_collect: fold the canonical reader and the endpoint prober over every
# ordinary task and print one reading:
#   <stamp> <alive> <stopped> <validating> <paused> <attention> <signature>
#
# A reading is COMPLETE or it is not a reading. If the canonical reader cannot
# answer for even one task - it is missing, it failed, the fleet changed under
# the fold - the whole collection is refused rather than published short. A
# partial fold's counts are indistinguishable from a quieter fleet, and the one
# thing this library exists to prevent is a confident number that is not true.
#
# Completeness is measured against the id list captured BEFORE the fold, and the
# fold walks that list rather than a pipe. Counting only the iterations that ran
# cannot detect a fold that ended early, and the canonical reader shells out to
# other tools: given the id stream as its own stdin, one of them draining stdin
# would swallow the remaining ids and end the loop with asked == answered on a
# fraction of the fleet. The reader's stdin is detached for the same reason.
_fm_fleet_collect() {  # <state-dir> <now> <reader> [prober]
  local state=$1 now=$2 reader=$3 probe=${4:-} id line bucket signature life busy
  local alive=0 stopped=0 validating=0 paused=0 attention=0 asked=0 answered=0
  local ids=()
  [ -n "$probe" ] || probe=${FM_FLEET_STATE_PROBE:-_fm_fleet_probe_default}
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ids+=("$id")
  done < <(_fm_fleet_ids "$state")
  asked=${#ids[@]}
  signature=$(_fm_fleet_id_stream ${ids[@]+"${ids[@]}"} | _fm_fleet_signature) || return 1
  for id in ${ids[@]+"${ids[@]}"}; do
    line=$("$reader" "$id" </dev/null 2>/dev/null) || continue
    [ -n "$line" ] || continue
    answered=$((answered + 1))
    bucket=$(_fm_fleet_bucket "$line")
    busy=0
    case "$bucket" in
      working) busy=1 ;;
      validating) validating=$((validating + 1)) ;;
      paused) paused=$((paused + 1)) ;;
      attention) attention=$((attention + 1)) ;;
    esac
    life=$(_fm_fleet_liveness "$state/$id.meta" "$busy" "$probe")
    case "$life" in
      alive) alive=$((alive + 1)) ;;
      stopped) stopped=$((stopped + 1)) ;;
    esac
  done
  [ "$answered" -eq "$asked" ] || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$now" "$alive" "$stopped" "$validating" "$paused" "$attention" "$signature"
}

# _fm_fleet_refresh_detached: start at most ONE bounded refresh and return at
# once. The prober is not a parameter: the detached shell re-sources this
# library and _fm_fleet_collect resolves it from the environment, so a home or a
# test that overrides FM_FLEET_STATE_PROBE reaches the refresh too. The claim is what keeps a one-second loop from stacking readers: a tick
# during an in-flight refresh, or right after one died without writing, is
# refused until the claim ages out.
#
# Two things keep "at most one" true rather than merely intended. The claim is
# never shorter than the refresh's own bound, because a claim that expired under
# a still-running fold would let the next frame start a second refresher over the
# same fleet - and the header budgets about a second per task, so a large fleet
# reaches the old 60s claim while the 90s bound still has room. And a fold that
# PUBLISHED releases its claim immediately rather than holding the window it did
# not need. A fold that produced nothing deliberately does not release: that is
# the died-without-writing case, and leaving it to age out is what paces the
# retry instead of re-forking a reader every tick. Either way the claim expires
# on its own, so the field can never wedge at unknown.
_fm_fleet_refresh_detached() {  # <cache> <state-dir> <now> <reader>
  local cache=$1 state=$2 now=$3 reader=$4 bound warm
  bound=$(fm_status_ttl "${FM_FLEET_STATE_WAIT:-}" 90)
  warm=$(fm_status_ttl "${FM_FLEET_STATE_WARM_TTL:-}" 90)
  [ "$warm" -ge "$bound" ] || warm=$bound
  fm_status_claim_refresh "$cache.refreshing" "$now" "$warm" || return 0
  (
    # shellcheck disable=SC2016 # $0..$3 are the INNER shell's positional
    # parameters, supplied after the -c script; expanding them here would bake
    # this shell's values into the script text instead of passing them.
    reading=$(fm_run_timed "$bound" bash -c '
      . "$0"
      _fm_fleet_collect "$1" "$2" "$3"
    ' "$_FM_FLEET_LIB_DIR/fm-fleet-status-lib.sh" "$state" "$now" "$reader" 2>/dev/null) \
      || reading=
    [ -z "$reading" ] || {
      fm_status_cache_write "$cache" "$reading"
      rm -f "$cache.refreshing" 2>/dev/null || true
    }
  ) >/dev/null 2>&1 &
  return 0
}

# _fm_fleet_unknown: the reading a frame gets when the live fields are not known.
_fm_fleet_unknown() {  # <records>
  printf '%s\t0\t0\t0\t0\t0\t0' "$1"
}

# fm_fleet_status_counts: the fleet fields for one frame, as
#   <records> <alive> <stopped> <validating> <paused> <attention> <known>
# tab separated, where <known> is 1 when the five live fields are a real reading
# of THIS fleet and 0 when they are not yet known. The five live fields are 0
# and meaningless when <known> is 0; the renderer must show placeholders.
fm_fleet_status_counts() {  # <state-dir>
  local state=$1 now cache reader records ttl max_age
  local cached stamp alive stopped validating paused attention signature current
  records=$(_fm_fleet_ids "$state" | grep -c '') || records=0
  now=$(_fm_fleet_now) || {
    _fm_fleet_unknown "$records"
    return 0
  }
  reader=${FM_FLEET_STATE_READER:-$_FM_FLEET_LIB_DIR/fm-crew-state.sh}
  ttl=$(fm_status_ttl "${FM_FLEET_STATE_TTL:-}" 120)
  max_age=$(fm_status_ttl "${FM_FLEET_STATE_MAX_AGE:-}" 420)
  cache="$state/.status-fleet-state"

  if [ "${FM_FLEET_STATE_NO_CACHE:-}" = 1 ]; then
    cached=$(_fm_fleet_collect "$state" "$now" "$reader") || cached=
  else
    cached=$(fm_status_cache_load "$cache") || cached=
    fm_status_cache_read "$cache" "$now" "$ttl" >/dev/null 2>&1 \
      || _fm_fleet_refresh_detached "$cache" "$state" "$now" "$reader"
  fi

  [ -n "$cached" ] || {
    _fm_fleet_unknown "$records"
    return 0
  }
  IFS=$'\t' read -r stamp alive stopped validating paused attention signature <<READING
$cached
READING
  current=$(_fm_fleet_ids "$state" | _fm_fleet_signature) || current=
  # Three independent reasons to refuse a reading, all of which mean the same
  # thing to the captain: this is not a current statement about this fleet.
  if [ -z "$signature" ] || [ "$signature" != "$current" ] \
    || ! fm_status_age_within "$now" "$stamp" "$max_age"; then
    _fm_fleet_unknown "$records"
    return 0
  fi
  case "$alive$stopped$validating$paused$attention" in
    ''|*[!0-9]*)
      _fm_fleet_unknown "$records"
      return 0
      ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t1' \
    "$records" "$alive" "$stopped" "$validating" "$paused" "$attention"
}
