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
# A live agent is still not a busy one. A worker whose PR is green and that sits
# idle until the captain says merge has an agent on its endpoint, and counting
# it as working told the captain two workers were busy when one was waiting for
# them. So a task whose current state already places it in another field - the
# pipeline carrying it, a declared wait, a blocker or failure, or work waiting
# on the captain - is counted there and only there, finished work whose PR was
# merged or closed is counted nowhere, and the working figure is what is left.
#
# Finished is not the same as waiting on the captain either. A no-mistakes
# ship whose worker committed its build and handed it off before validation has
# no PR and nothing for the captain to act on - it is firstmate's turn to send
# it into the pipeline - and counting it as waiting for the captain told him a
# job needed him when it did not. The reader reports that handoff blocked, so it
# counts as attention for firstmate, never as ready. So a done waits on the
# captain only when the delivery contract reads it as the ready report. A done
# that is firstmate's turn, such as a scout report firstmate reads first, has no
# busy worker behind it either, so like merged work it is counted nowhere.
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
#   working     an agent is running on the task's recorded endpoint right now and
#               no other field below claims the task. This is the headline,
#               because it answers "how many workers are busy for me".
#   stopped     the record is still here but its worker is not: the endpoint is
#               proven dead or absent, or the recorded worktree is gone. Done
#               work is never counted here, because a worker that exits once its
#               work is done is not a lost worker; a task parked at a decision is
#               not done, so its lost worker is.
#   validating  the validation pipeline owns the task - it is progressing, but
#               no worker is typing at it.
#   paused      a declared bounded external wait.
#   attention   firstmate has to act: a blocker, a failure, or a question a
#               worker or the checks put to firstmate (a status-log needs-decision
#               or an ask-user review finding, which ask-user-authority gives
#               firstmate to decide, never the captain).
#   ready       the owner's calls: fm_owner_calls below, the one count of what
#               really waits on the captain - the held decisions that wait on
#               him now plus the PRs and ready branches waiting for his merge
#               word.
#   decisions   the part of ready that is a held decision rather than work
#               ready to land. It is a subset of ready, never added to it,
#               because the overview shows "decisions for you" and "ready to
#               merge" as two figures.
#
# The overview - the bridge strip, the status bar and the Factory pane's count
# line - also asks (fm_fleet_status_counts `overview`) for the readings no
# other field carries, taken by the same fold so they never disagree with the
# counts. docs/status-bar.md "Fleet words" owns the one word each surface
# shows for each of them:
#   failed      tasks whose current state is failed: a worker's failure or a
#               failed validation run. It is part of attention, never added to
#               it.
#   lost        the stopped tasks that are not also failed, so the overview's
#               failed and stopped figures, which show failed and lost, count
#               each broken task once. It is part of stopped, which keeps
#               counting a failed task whose worker is gone.
#   night       how much finished in the night shift that ended last, as
#               <count>@<window-end-epoch>, or `-` when the home has no night
#               shift window (fm_night_shift_window owns the window and
#               _fm_fleet_night_done what counts).
#   first call  the owner's most urgent call, the first line fm_owner_calls
#               prints, as its kind, its id and a plain one-line title.
#   ready list  the tasks whose work read ready in the fold, which
#               fm_owner_calls turned into the merges behind ready, so the
#               Factory pane lists exactly the calls the overview counts.
#
# working and stopped are separate readings of the same fleet rather than two
# ends of one axis, and a task counts toward NEITHER unless its state was
# proven: a backend with no recovery classifier, an unreachable remote
# secondmate, or a record with no endpoint at all leaves the task in records
# only. Overstating either side is the failure this library exists to prevent.
#
# The six live fields are all-or-nothing: without a good reading they are
# reported unknown together, and the renderer shows placeholders. They are never
# reported as zero to stand in for "not read yet", because zero live workers is
# a real and meaningful fleet state that the captain must be able to trust.
#
# The owner's calls (ready, decisions and the first call) are the exception to
# that cadence. They are a cheap backlog read, so the moment the owner's calls
# signal moves they are recomputed on their own and shown in place of the
# reading's, without waiting for the workers; the block above
# _fm_fleet_calls_refresh_detached owns how.
#
# A cached reading also carries the exact set of tasks it covered. If the fleet
# has changed since - a task torn down, another dispatched - or the reading is
# past its maximum age, it is no longer a current statement about this fleet.
# It is then reported as the last good reading, with its age, rather than as
# current, and a refresh is started at once; fm_fleet_status_counts owns why.
#
# Test seams:
#   FM_FLEET_STATE_TTL       seconds before a reading is refreshed (default 120)
#   FM_FLEET_STATE_MAX_AGE   seconds before a reading is only the last good one
#                            rather than current (default 420)
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
#   FM_FLEET_CALLS_WAIT      wall-clock bound on, and claim for, one refresh of
#                            the owner's calls on their own (default 20)
set -u

_FM_FLEET_LIB_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-status-cache-lib.sh
. "$_FM_FLEET_LIB_DIR/fm-status-cache-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_FLEET_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-owner-calls-signal-lib.sh
. "$_FM_FLEET_LIB_DIR/fm-owner-calls-signal-lib.sh"

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
# excluded here exactly as they were from the count this replaces: a record
# whose first kind= line says secondmate. One awk reads every record, because
# every frame of every overview surface lists the fleet, twice.
_fm_fleet_ids() {  # <state-dir>
  local meta id mates
  local metas=()
  for meta in "$1"/*.meta; do
    [ -e "$meta" ] && metas+=("$meta")
  done
  [ "${#metas[@]}" -gt 0 ] || return 0
  mates=$(awk -F= 'FNR == 1 { seen = 0 }
    !seen && $1 == "kind" { seen = 1; if (substr($0, index($0, "=") + 1) == "secondmate") print FILENAME }' \
    "${metas[@]}" 2>/dev/null)
  for meta in "${metas[@]}"; do
    case $'\n'"$mates"$'\n' in
      *$'\n'"$meta"$'\n'*) continue ;;
    esac
    id=${meta##*/}
    printf '%s\n' "${id%.meta}"
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
# The `working` bucket is not a displayed field of its own: the fold consumes it
# as proof of life for the liveness reading below, where a worker the busy
# classifier just watched is alive whatever an endpoint probe can say.
#
# `done` splits on the PR disposition the reader already put in its detail: a
# merged or closed PR leaves nothing for the captain and is `finished`, which no
# field counts. A run-step done is the pipeline's own verdict on a PR, so it is
# `ready`, waiting on them. A status-log done is the worker's report, and it is
# `ready` only when bin/fm-dod-lib.sh's fm_dod_should_gate_ship_done - the one
# owner of which ship done is the ready report - says so: a green PR, or any
# done in a mode whose done is the PR or ready branch itself. Every other one -
# a scout report, or a no-mistakes handoff from a reader older than its blocked
# handoff reading - is firstmate's turn, with no busy worker and nothing for the
# captain, so it is `finished` too.
#
# `parked` alone does not say who owes the answer. It is a `decision` only when
# the reader says the worker is waiting on an answer from above it: a status-log
# needs-decision, or a gate line carrying the reader's whole
# FM_GATE_HUMAN_DECISION component (an ask-user review finding). Both are put to
# firstmate, which answers them or takes them to the captain as a held decision,
# so a `decision` is firstmate's to act on and never one of the owner's calls by
# itself; the fold counts it under attention. Any other parked gate is the
# worker's or firstmate's turn, so it claims no field and is read by liveness
# alone, like any other unclaimed task.
_fm_fleet_bucket() {  # <canonical line> [<meta>]
  local line=$1 meta=${2:-} state source kind
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
    parked)
      if [ "$source" = status-log ]; then
        printf 'decision'
      else
        case "$line · " in
          *" · $FM_GATE_HUMAN_DECISION · "*) printf 'decision' ;;
        esac
      fi
      ;;
    done)
      case "$line" in
        *'PR merged'*|*'PR closed'*) printf 'finished' ;;
        *)
          [ "$source" = status-log ] || {
            printf 'ready'
            return 0
          }
          kind=$(fm_dod_meta_value "$meta" kind)
          if fm_dod_should_gate_ship_done "${kind:-ship}" \
            "$(fm_dod_meta_value "$meta" mode)" \
            "done: ${line#*source: status-log · }"; then
            printf 'ready'
          else
            printf 'finished'
          fi
          ;;
      esac
      ;;
    blocked|failed) printf 'attention' ;;
    *) ;;
  esac
}

# fm_fleet_task_bucket: the field one task belongs in, as _fm_fleet_bucket reads
# the canonical reader's line for it; nothing for a record no field claims. It
# fails when the reader cannot answer. The fold below and fm_owner_calls share
# this one reading.
fm_fleet_task_bucket() {  # <state-dir> <id> [reader]
  local line
  line=$(_fm_fleet_task_line "$@") || return 1
  _fm_fleet_bucket "$line" "$1/$2.meta"
}

# _fm_fleet_task_line: the canonical reader's line for one task, which
# fm_fleet_task_bucket folds; the fold also reads its state word for <failed>.
_fm_fleet_task_line() {  # <state-dir> <id> [reader]
  local id=$2 reader=${3:-${FM_FLEET_STATE_READER:-$_FM_FLEET_LIB_DIR/fm-crew-state.sh}} line
  _fm_fleet_classify_ready || return 1
  line=$("$reader" "$id" </dev/null 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

# fm_fleet_status_bucket: the same fold for one task, for a view that draws
# each task rather than counting them (bin/fm-factory.py). It prints the field
# name above, or nothing for a record that is not live work, so a per-task view
# can never disagree with the counts on what a state means.
fm_fleet_status_bucket() {  # <canonical line> [<meta>]
  _fm_fleet_classify_ready || return 1
  _fm_fleet_bucket "$@"
}

# fm_owner_calls: the owner's calls - what really waits on the captain - one per
# line, decisions first, then merges:
#
#   decision<TAB><id>   a decision held for the captain that waits on him now
#   merge<TAB><id>      a PR or ready branch waiting for his merge word
#   mate-merge<TAB><mate><TAB><child><TAB><url><TAB><at>
#                       a PR a second mate's child has ready for the
#                       owner's merge word, and the epoch its done outcome
#                       was reported at (fm_secondmate_ready_prs below)
#
# This is the one definition of that count. The fold below publishes it as
# <ready> and <decisions>, so the bridge strip and the status bar show it;
# bin/fm-factory.py lists exactly these as NEEDS YOU; and bin/fm-tap-desk.sh
# export makes its cards from exactly these. On 2026-11-14 those three surfaces
# showed 0 to 2, 17 to 36 and 112 at the same moment, because each had its own
# reading of what needs him.
#
# A decision is a captain hold as bin/fm-fleet-snapshot.sh classifies it, the
# one classifier of a captain hold, whose hold_bucket is `live`: the same
# captain_actionable test bin/fm-bearings-snapshot.sh's Captain's Call uses. An
# undated hold past the snapshot's aging threshold (`aged`), a hold deferred to
# a date that has not come (`dated`) and one waiting on other work (`blocked`)
# are never counted. A merge is a task whose work reads `ready`
# (fm_fleet_task_bucket), unless its row is done or it carries any captain hold
# that is not done: the merge of held work waits on the answer, so it is one
# call, not two, and never a call while that hold is not his call right now.
#
# Nothing else is ever a call. A worker's question and an ask-user review
# finding are firstmate's to answer (ask-user-authority) and reach the captain
# only as a held decision; a worker's pause and work in the checks wait on time
# or the pipeline, not on him.
#
# <buckets> is an optional file of `<id><TAB><bucket>` lines for a caller that
# has already read every ordinary task's bucket, so no task is read twice; only
# `ready` lines matter. Without it each ordinary task is read here. <backlog> is
# an optional file holding the backlog object of a snapshot the caller already
# took (`fm-fleet-snapshot.sh --backlog`, or the `backlog` of `--json`); without
# it the backlog is read for the home that owns <state-dir> through its
# configured tasks-axi adapter, so a home whose backlog is not markdown keeps
# its calls. It fails, printing
# nothing, when the backlog or any task cannot be read, because a short list of
# calls reads exactly like fewer calls. The second mates' PRs come last and
# never fail it: a PR whose state cannot be read stays listed.
fm_owner_calls() {  # <state-dir> [<buckets-file> [<backlog-file>]]
  local state=$1 buckets=${2:-} backlog=${3:-} dir id bucket out rc=0
  command -v jq >/dev/null 2>&1 || return 1
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-owner-calls.XXXXXX") || return 1
  if [ -z "$buckets" ]; then
    buckets="$dir/buckets"
    : > "$buckets"
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      bucket=$(fm_fleet_task_bucket "$state" "$id") || { rc=1; break; }
      printf '%s\t%s\n' "$id" "$bucket" >> "$buckets"
    done < <(_fm_fleet_ids "$state")
  fi
  if [ "$rc" = 0 ] && [ -z "$backlog" ]; then
    backlog="$dir/backlog"
    _fm_owner_backlog "$state" > "$backlog" || rc=1
  fi
  if [ "$rc" = 0 ]; then
    out=$(jq -r --rawfile buckets "$buckets" '
      [(.records // [])[] | select(.structured == true and (.id | type) == "string")] as $rows
      | [$rows[] | select(.state != "done" and .hold_bucket == "live") | .id] as $decisions
      | (reduce ($rows[] | select(.state == "done" or .hold_bucket != null) | .id) as $id ({}; .[$id] = true)) as $taken
      | ($decisions[] | "decision\t\(.)"),
        ($buckets | split("\n")[] | split("\t") | select(length >= 2 and .[1] == "ready" and .[0] != "")
          | .[0] | select($taken[.] != true) | "merge\t\(.)")
    ' "$backlog" 2>/dev/null) || rc=1
  fi
  rm -rf "$dir"
  [ "$rc" = 0 ] || return 1
  [ -z "$out" ] || printf '%s\n' "$out"
  fm_secondmate_ready_prs "$state"
}

# fm_secondmate_ready_prs: the PRs this home's second mates have ready for the
# owner's merge word, one `mate-merge<TAB><mate><TAB><child><TAB><url><TAB><at>`
# line each, by mate id and then in the order they were reported. <at> is the
# `[at=]` epoch of the child's done outcome that lists the PR, empty when that
# line carries none, so each new done outcome is a new asking of the owner.
#
# A second mate's PRs are not this home's tasks, so they are read from what the
# mate already reports here: its parent channel, state/<mate>.status, which a
# local mate appends to directly and a remote mate's reply mirror copies into
# (docs/secondmate-parent-channel.md). Only the lines its scripts write count,
# never the mate's own prose. A child's done outcome
# (`[key=child-outcome-<child>-done-...]: child <child> done: ... pr=<url>`,
# bin/fm-inactive-reconcile.sh) lists the PR, as this home's own work waits
# for the merge word only once its task reads done; a PR registration alone
# (`[key=child-pr-<child>]`, bin/fm-pr-check.sh) does not. An outcome carrying
# `yolo=on` is not listed, because that mate merges green, in-scope work
# itself (AGENTS.md); its lines carry no mark for the PRs standing yolo never
# covers. Each child's newest outcome stands: a later outcome that is not done
# (`failed [key=child-outcome-<child>-failed-...]`) drops its PR, and a later
# done outcome with another pr= replaces it. A merge
# (`[key=merged-<child>]: merged <child> <url>`, bin/fm-merge-outcome-lib.sh)
# drops the PR for good, even when an outcome for it arrives later. Nothing
# here reads the mate's home or reaches its machine.
#
# A PR closed without merging leaves no line, and a merge can reach the channel
# late, so each listed PR's own state is also read from its forge
# (_fm_secondmate_pr_state) and a merged or closed one is dropped.
fm_secondmate_ready_prs() {  # <state-dir>
  local state=$1 meta mate kind child url at
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(awk -F= '$1 == "kind" { print substr($0, index($0, "=") + 1); exit }' "$meta" 2>/dev/null)
    [ "$kind" = secondmate ] || continue
    mate=$(basename "$meta" .meta)
    [ -f "$state/$mate.status" ] || continue
    while IFS=$'\t' read -r child url at; do
      [ -n "$url" ] || continue
      case "$(_fm_secondmate_pr_state "$state" "$url" "$at")" in
        merged|closed) continue ;;
      esac
      printf 'mate-merge\t%s\t%s\t%s\t%s\n' "$mate" "$child" "$url" "$at"
    done < <(awk '
      function drop(u,  c) { for (c in pr) if (pr[c] == u) delete pr[c] }
      !/^[a-z-]+( \[[^]]*\])*: / { next }
      {
        if (!match($0, /\[key=[^]]*\]/)) next
        key = substr($0, RSTART + 5, RLENGTH - 6)
        note = $0
        sub(/^[a-z-]+( \[[^]]*\])*: /, "", note)
        n = split(note, w, " ")
        if (key ~ /^merged-/ && w[1] == "merged") {
          merged[w[3]] = 1
          drop(w[3])
          next
        }
        child = w[2]
        if (w[1] != "child" || index(key, "child-outcome-" child "-") != 1) next
        delete pr[child]
        if (w[3] != "done:") next
        url = ""; yolo = ""
        for (i = 4; i <= n; i++) {
          if (w[i] ~ /^pr=/) url = substr(w[i], 4)
          else if (w[i] ~ /^yolo=/) yolo = substr(w[i], 6)
        }
        if (url !~ /^https?:\/\/[^ ]+$/ || (url in merged) || yolo == "on") next
        drop(url)
        if (!(child in seen)) { seen[child] = 1; order[++count] = child }
        pr[child] = url
        at[child] = match($0, /\[at=[0-9]+\]/) ? substr($0, RSTART + 4, RLENGTH - 5) : ""
      }
      END { for (i = 1; i <= count; i++) if (order[i] in pr) printf "%s\t%s\t%s\n", order[i], pr[order[i]], at[order[i]] }
    ' "$state/$mate.status" 2>/dev/null)
  done
}

# _fm_secondmate_pr_state: open, merged, closed or unknown for one second
# mate's PR. Each answer is kept in state/secondmate-prs/, one file per PR,
# with when it was read. A merged answer is kept for good. A closed one is too,
# unless the child reported done on it again after that reading (<reported>,
# the done outcome's epoch), since a closed PR can be reopened. Any other is
# read again once it is FM_SECONDMATE_PR_TTL seconds old (default 300), so the
# owner's calls, which are read often, ask the forge at most that often per PR.
# The forge is read through bin/fm-pr-lib.sh for GitHub and GitLab, bounded
# to 5 seconds; any other forge, or a read that fails, is unknown.
# Test seam: FM_SECONDMATE_PR_READER, a command run as `<reader> <url>` that
# prints the state in place of the forge read.
_fm_secondmate_pr_state() {  # <state-dir> <url> [<reported>]
  local state=$1 url=$2 reported=${3:-} dir file name now ttl cached at answer
  dir="$state/secondmate-prs"
  name=$(printf '%s' "${url#*://}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
  file="$dir/$name"
  now=$(_fm_fleet_now) || now=0
  ttl=$(fm_status_ttl "${FM_SECONDMATE_PR_TTL:-}" 300)
  if [ -f "$file" ] && read -r cached at < "$file" 2>/dev/null; then
    case "$cached" in
      merged) printf '%s' "$cached"; return 0 ;;
      closed) [ "$reported" -gt "$at" ] 2>/dev/null || { printf '%s' "$cached"; return 0; } ;;
    esac
    case "$at" in
      ''|*[!0-9]*) ;;
      *) if [ $((now - at)) -lt "$ttl" ] && [ "$now" -ge "$at" ]; then printf '%s' "$cached"; return 0; fi ;;
    esac
  fi
  if [ -n "${FM_SECONDMATE_PR_READER:-}" ]; then
    answer=$($FM_SECONDMATE_PR_READER "$url" 2>/dev/null) || answer=unknown
  else
    # shellcheck disable=SC2016 # the INNER shell's positional parameters.
    answer=$(fm_run_timed 5 bash -c '
      . "$0" || exit 1
      fm_pr_url_parse "$1" || exit 1
      case "$FM_PR_PROVIDER" in
        github) fm_pr_github_read_record "$FM_PR_HOST" "${FM_PR_PATH%%/*}" "${FM_PR_PATH#*/}" "$FM_PR_NUMBER" || exit 1 ;;
        gitlab) fm_pr_gitlab_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || exit 1 ;;
        *) exit 1 ;;
      esac
      if [ "$FM_PR_RECORD_MERGED" = true ]; then echo merged; exit 0; fi
      case "$FM_PR_RECORD_STATE" in
        OPEN|open|opened|locked) echo open ;;
        CLOSED|closed) echo closed ;;
        *) exit 1 ;;
      esac
    ' "$_FM_FLEET_LIB_DIR/fm-pr-lib.sh" "$url" 2>/dev/null) || answer=unknown
  fi
  case "$answer" in
    open|merged|closed) ;;
    *) answer=unknown ;;
  esac
  mkdir -p "$dir" 2>/dev/null && printf '%s %s\n' "$answer" "$now" > "$file.$$" 2>/dev/null \
    && mv -f "$file.$$" "$file" 2>/dev/null || rm -f "$file.$$" 2>/dev/null || :
  printf '%s' "$answer"
}

# _fm_owner_backlog: the backlog object of the home that owns <state-dir>, read
# through its configured tasks-axi adapter and classified as
# bin/fm-fleet-snapshot.sh classifies every captain hold (--axi-backlog). The
# home is the state directory's parent, which is where every caller keeps it.
_fm_owner_backlog() {  # <state-dir>
  local home
  home=$(CDPATH='' cd -P -- "$1/.." 2>/dev/null && pwd -P) || return 1
  FM_HOME=$home FM_STATE_OVERRIDE=$1 bash "$_FM_FLEET_LIB_DIR/fm-fleet-snapshot.sh" --axi-backlog </dev/null 2>/dev/null
}

# _fm_fleet_call_title: the plain one-line title of one of the owner's calls:
# its backlog row's title, else its task's recorded outcome, else its id. It is
# cut to its first line (the tasks-axi adapter appends a truncation note on a
# second line) and to printable ASCII, so a renderer can count its columns as
# characters: common dashes, quotes and the ellipsis become their ASCII forms
# and any other run of non-ASCII becomes one `?`.
_fm_fleet_call_title() {  # <state-dir> <backlog-file> <id>
  local title
  title=$(jq -r --arg id "$3" \
    '[(.records // [])[] | select(.id == $id) | .title // empty | strings][0] // empty' \
    "$2" 2>/dev/null) || title=
  [ -n "$title" ] || title=$(fm_dod_meta_value "$1/$3.meta" outcome)
  title=${title%%$'\n'*}
  title=$(printf '%s' "$title" | LC_ALL=C sed \
    -e $'s/\xe2\x80[\x90-\x95]/-/g' -e $'s/\xe2\x80[\x98\x99]/\'/g' \
    -e $'s/\xe2\x80[\x9c\x9d]/"/g' -e $'s/\xe2\x80\xa6/.../g' \
    -e 's/[^ -~][^ -~]*/?/g' -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
  [ -n "$title" ] || title=$3
  printf '%s' "${title:0:160}"
}

# _fm_fleet_clock: the local hour, minute and second of <epoch>, space
# separated, from macOS (-r) or GNU (-d @) date.
_fm_fleet_clock() {  # <epoch>
  date -r "$1" '+%H %M %S' 2>/dev/null || date -d "@$1" '+%H %M %S' 2>/dev/null
}

# fm_night_shift_window: where the home's night shift stands at <now>, from its
# window file (config/night-shift-window: one line `HH:MM-HH:MM`, local time,
# the start before the end; an end at or before the start is the next day).
# Prints, tab separated:
#   <phase> <start HH:MM> <last start epoch> <last end epoch>
# where the last window is the newest one that has already ended, and <phase>
# is `on` inside a window, `morning` for six hours after one ends, `evening`
# for six hours before the next one starts, and `day` otherwise; a morning
# that runs into the next evening stays morning. It fails, printing nothing,
# when the file is absent or not that shape, which is how a home says it has
# no night shift. A day is taken as 86400 seconds, so on the day a clock
# change happens a window can read an hour off.
fm_night_shift_window() {  # <window-file> <now>
  local file=$1 now=$2 text s_m e_m dur clock h m sec midnight d ws we
  local phase=day last_s='' last_e='' next_s='' span=21600
  [ -f "$file" ] || return 1
  text=$(head -n 1 "$file" 2>/dev/null | tr -d '[:space:]')
  case "$text" in
    [0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  s_m=$((10#${text:0:2} * 60 + 10#${text:3:2}))
  e_m=$((10#${text:6:2} * 60 + 10#${text:9:2}))
  [ "$s_m" -lt 1440 ] && [ "$e_m" -lt 1440 ] || return 1
  dur=$(((e_m - s_m + 1440) % 1440))
  [ "$dur" -gt 0 ] || return 1
  clock=$(_fm_fleet_clock "$now") || return 1
  read -r h m sec <<CLOCK
$clock
CLOCK
  case "$h$m$sec" in ''|*[!0-9]*) return 1 ;; esac
  midnight=$((now - 10#$h * 3600 - 10#$m * 60 - 10#$sec))
  for d in -2 -1 0 1; do
    ws=$((midnight + d * 86400 + s_m * 60))
    we=$((ws + dur * 60))
    if [ "$ws" -le "$now" ] && [ "$now" -lt "$we" ]; then
      phase=on
    elif [ "$we" -le "$now" ]; then
      last_s=$ws
      last_e=$we
    elif [ -z "$next_s" ]; then
      next_s=$ws
    fi
  done
  if [ "$phase" != on ]; then
    if [ -n "$last_e" ] && [ $((now - last_e)) -lt "$span" ]; then
      phase=morning
    elif [ -n "$next_s" ] && [ $((next_s - now)) -le "$span" ]; then
      phase=evening
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$phase" "${text:0:5}" "$last_s" "$last_e"
}

# _fm_fleet_night_done: how many tasks finished or landed between <start> and
# <end>, each counted once:
#   - finished: a task record in <state-dir> whose status log has a done line
#     stamped [at=] inside the window that is its finished report - any done
#     of a scout or other non-ship task, and a ship's done only when
#     fm_dod_should_gate_ship_done reads it as the ready report, the same
#     reading the fold and the Factory pane's feed use;
#   - landed: a contribution record (data/<task>/contributions.json, which
#     outlives the task's cleanup) whose PR was first seen merged inside the
#     window. A merged record is final and never read again, so its checked_at
#     is when the merge was seen.
# Work cleaned up before the reading that left neither record is not counted,
# so the figure can be short but never counts work twice or outside the window.
_fm_fleet_night_done() {  # <state-dir> <start> <end> <now>
  local state=$1 ws=$2 we=$3 now=$4 home id file line at kind mode mins
  home=$(CDPATH='' cd -P -- "$state/.." 2>/dev/null && pwd -P) || return 1
  _fm_fleet_classify_ready || return 1
  {
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      file="$state/$id.status"
      [ -f "$file" ] || continue
      kind=$(fm_dod_meta_value "$state/$id.meta" kind)
      mode=$(fm_dod_meta_value "$state/$id.meta" mode)
      while IFS= read -r line || [ -n "$line" ]; do
        [ "$(status_line_verb "$line")" = "done" ] || continue
        at=$(status_line_at_epoch "$line") || continue
        [ "$at" -ge "$ws" ] && [ "$at" -lt "$we" ] || continue
        if [ "${kind:-ship}" != ship ] || fm_dod_should_gate_ship_done ship "$mode" "$line"; then
          printf '%s\n' "$id"
          break
        fi
      done < "$file"
    done < <(_fm_fleet_ids "$state")
    # A contribution file seen merged in the window was written at or after it.
    mins=$(((now - ws) / 60 + 2))
    if [ -d "$home/data" ] && command -v jq >/dev/null 2>&1; then
      find "$home/data" -mindepth 2 -maxdepth 2 -name contributions.json -mmin "-$mins" -print 2>/dev/null \
        | while IFS= read -r file; do
            jq -r --argjson ws "$ws" --argjson we "$we" '
              select(.schema == "fm-contributions.v1" and (.task | type) == "string") | .task as $task
              | (.records // [])[]
              | select(.kind == "pr" and .observation.state == "merged" and (.checked_at | type) == "string")
              | (.checked_at | try fromdateiso8601 catch null) as $at
              | select($at != null and $at >= $ws and $at < $we) | $task
            ' "$file" 2>/dev/null
          done
    fi
  } | LC_ALL=C sort -u | grep -c .
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

# _fm_fleet_classify_ready: load bin/fm-classify-lib.sh once, on first use, for
# FM_GATE_HUMAN_DECISION, the one spelling of a gate owed by a human, and
# bin/fm-dod-lib.sh for the one reading of which done is the ready report. Like
# the backend they are a fold-only cost that a frame never pays.
_fm_fleet_classify_ready() {
  [ "${_FM_FLEET_CLASSIFY_READY:-}" = 1 ] && return 0
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_FLEET_LIB_DIR/fm-classify-lib.sh" 2>/dev/null || return 1
  # shellcheck source=bin/fm-dod-lib.sh
  . "$_FM_FLEET_LIB_DIR/fm-dod-lib.sh" 2>/dev/null || return 1
  _FM_FLEET_CLASSIFY_READY=1
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

# _fm_fleet_calls_fold: the owner's calls folded into the fields a reading
# carries, tab separated:
#   <ready> <decisions> <first-kind> <first-id> <first-title>
# from one backlog read and <ready-list>, the space-separated ids of the tasks
# whose work reads ready (`-` for none). The full fold and the calls-only
# refresh below both fold the calls here, so the two never disagree. It fails,
# printing nothing, when the backlog or the calls cannot be read.
_fm_fleet_calls_fold() {  # <state-dir> <ready-list>
  local state=$1 list=$2 readyfile backlogfile calls kind id rc=0
  local ready=0 decisions=0 first_kind=- first_id=- first_title=-
  local ids=()
  _fm_fleet_classify_ready || return 1
  [ "$list" = - ] || read -r -a ids <<<"$list"
  # The ready tasks go in a file rather than a process substitution, whose
  # descriptor bash may close before the function reading it gets there.
  readyfile=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-ready.XXXXXX") || return 1
  backlogfile=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-backlog.XXXXXX") || {
    rm -f "$readyfile"
    return 1
  }
  for id in ${ids[@]+"${ids[@]}"}; do printf '%s\tready\n' "$id"; done > "$readyfile"
  # The backlog is read once here, so the first call's title comes from the
  # same reading as the calls themselves.
  if _fm_owner_backlog "$state" > "$backlogfile"; then
    calls=$(fm_owner_calls "$state" "$readyfile" "$backlogfile") || rc=1
  else
    rc=1
  fi
  if [ "$rc" = 0 ]; then
    while IFS=$'\t' read -r kind id child _url; do
      case "$kind" in
        decision) ready=$((ready + 1)); decisions=$((decisions + 1)) ;;
        merge|mate-merge) ready=$((ready + 1)) ;;
        *) continue ;;
      esac
      if [ "$first_kind" = - ] && [ "$kind" = mate-merge ]; then
        # A second mate's PR: merge work like any other, named by its child
        # and the mate that has it ready; its id is the Factory pane's.
        first_kind=merge
        first_id=$id:$child
        first_title=$(printf '%s from %s' "$child" "$id" | LC_ALL=C tr -cd ' -~')
        first_title=${first_title:0:160}
      elif [ "$first_kind" = - ]; then
        first_kind=$kind
        first_id=$id
        first_title=$(_fm_fleet_call_title "$state" "$backlogfile" "$id")
      fi
    done <<CALLS
$calls
CALLS
  fi
  rm -f "$readyfile" "$backlogfile"
  [ "$rc" = 0 ] || return 1
  printf '%s\t%s\t%s\t%s\t%s' "$ready" "$decisions" "$first_kind" "$first_id" "$first_title"
}

# The owner's calls between full readings. A full reading is slow because of
# its workers, and it is refreshed only every FM_FLEET_STATE_TTL seconds. The
# calls are only a backlog read, so whenever the owner's calls signal
# (bin/fm-owner-calls-signal-lib.sh) has moved past the one a full reading was
# taken under, they are recomputed on their own, from the same reading's ready
# tasks, into state/.status-fleet-calls:
#   <signal> <ready-list> <epoch> <ready> <decisions> <first-kind> <first-id>
#   <first-title>
# tab separated. A frame shows those calls in place of the full reading's only
# while both the signal and the ready tasks still match, so a stale entry is
# never shown and the slow reading is never refreshed for it.

# _fm_fleet_calls_refresh_detached: start at most ONE bounded calls refresh,
# claimed exactly as _fm_fleet_refresh_detached claims its fold, and return at
# once. <signal> is the one the frame just read, so a call that changes while
# the backlog is read leaves the entry behind the signal and the next frame
# starts another.
_fm_fleet_calls_refresh_detached() {  # <state-dir> <now> <ready-list> <signal>
  local state=$1 now=$2 list=$3 signal=$4 cache bound
  cache="$state/.status-fleet-calls"
  bound=$(fm_status_ttl "${FM_FLEET_CALLS_WAIT:-}" 20)
  fm_status_claim_refresh "$cache.refreshing" "$now" "$bound" || return 0
  (
    # shellcheck disable=SC2016 # the INNER shell's positional parameters.
    calls=$(fm_run_timed "$bound" bash -c '
      . "$0"
      _fm_fleet_calls_fold "$1" "$2"
    ' "$_FM_FLEET_LIB_DIR/fm-fleet-status-lib.sh" "$state" "$list" 2>/dev/null) \
      || calls=
    [ -z "$calls" ] || {
      fm_status_cache_write "$cache" "$(printf '%s\t%s\t%s\t%s' "$signal" "$list" "$now" "$calls")"
      rm -f "$cache.refreshing" 2>/dev/null || true
    }
  ) >/dev/null 2>&1 &
  return 0
}

# _fm_fleet_collect: fold the canonical reader and the endpoint prober over every
# ordinary task and print one reading:
#   <stamp> <working> <stopped> <validating> <paused> <attention> <ready>
#   <signature> <decisions> calls <failed> <lost> <night> <first-kind>
#   <first-id> <first-title> <calls-signal> <ready-list>
#
# <decisions> and the `calls` mark come after the older fields, and the overview's
# readings (the header's failed, lost, night and first call) after the mark, so a
# reading written before them still parses for every older field;
# fm_fleet_status_counts owns how such a reading is treated. An absent first
# call is `-` in all three of its fields, and the title may hold spaces; it never
# holds a tab. <ready> and <decisions> are fm_owner_calls over the buckets this
# fold read, so they can count a held decision that has no task record at all.
# <calls-signal> is the owner's calls signal taken before the fold, and
# <ready-list> the ids whose work read ready, which a calls-only refresh folds
# again (_fm_fleet_calls_fold).
#
# Every task field but stopped claims a task for itself: working is a live agent
# on a task no state field claimed. Done work spends no endpoint probe at all,
# because its worker is never a lost one; a worker's question is still probed,
# so a worker lost while it waits is counted stopped.
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
  local state=$1 now=$2 reader=$3 probe=${4:-} id bucket signature life busy line
  local working=0 stopped=0 validating=0 paused=0 attention=0 ready=0
  local decisions=0 asked=0 answered=0 calls calls_signal ready_list
  local failed=0 lost=0 night=- first_kind=- first_id=- first_title=- window ws we
  local word
  local ids=() ready_ids=()
  [ -n "$probe" ] || probe=${FM_FLEET_STATE_PROBE:-_fm_fleet_probe_default}
  _fm_fleet_classify_ready || return 1
  # Taken before anything is read, so a call that changes during the fold
  # leaves this reading behind the signal rather than passing as current.
  calls_signal=$(fm_owner_calls_signal "$state")
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ids+=("$id")
  done < <(_fm_fleet_ids "$state")
  asked=${#ids[@]}
  signature=$(_fm_fleet_id_stream ${ids[@]+"${ids[@]}"} | _fm_fleet_signature) || return 1
  for id in ${ids[@]+"${ids[@]}"}; do
    line=$(_fm_fleet_task_line "$state" "$id" "$reader") || continue
    bucket=$(_fm_fleet_bucket "$line" "$state/$id.meta")
    answered=$((answered + 1))
    word=${line#*state: }
    word=${word%% *}
    [ "$word" != failed ] || failed=$((failed + 1))
    busy=0
    case "$bucket" in
      working) busy=1 ;;
      validating) validating=$((validating + 1)) ;;
      paused) paused=$((paused + 1)) ;;
      attention|decision) attention=$((attention + 1)) ;;
      ready) ready_ids+=("$id"); continue ;;
      finished) continue ;;
    esac
    life=$(_fm_fleet_liveness "$state/$id.meta" "$busy" "$probe")
    case "$life" in
      alive)
        case "$bucket" in
          ''|working) working=$((working + 1)) ;;
        esac
        ;;
      stopped)
        stopped=$((stopped + 1))
        [ "$word" = failed ] || lost=$((lost + 1))
        ;;
    esac
  done
  [ "$answered" -eq "$asked" ] || return 1
  if [ "${#ready_ids[@]}" -gt 0 ]; then
    ready_list="${ready_ids[*]}"
  else
    ready_list=-
  fi
  calls=$(_fm_fleet_calls_fold "$state" "$ready_list") || return 1
  IFS=$'\t' read -r ready decisions first_kind first_id first_title <<CALLS
$calls
CALLS
  if window=$(fm_night_shift_window "$state/../config/night-shift-window" "$now"); then
    IFS=$'\t' read -r _ _ ws we <<WINDOW
$window
WINDOW
    if [ -n "$we" ]; then
      night=$(_fm_fleet_night_done "$state" "$ws" "$we" "$now")
      case "$night" in ''|*[!0-9]*) night=- ;; *) night="$night@$we" ;; esac
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tcalls\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$now" "$working" "$stopped" "$validating" "$paused" "$attention" \
    "$ready" "$signature" "$decisions" "$failed" "$lost" "$night" \
    "$first_kind" "$first_id" "$first_title" "$calls_signal" "$ready_list"
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
_fm_fleet_unknown() {  # <records> [decisions|overview]
  printf '%s\t0\t0\t0\t0\t0\t0\t0\t0' "$1"
  case "${2:-}" in
    decisions) printf '\t0' ;;
    overview) printf '\t0\t-\t-\t-\t-\t-\t-\t-\t-' ;;
  esac
}

# fm_fleet_status_counts: the fleet fields for one frame, as
#   <records> <working> <stopped> <validating> <paused> <attention> <ready>
#   <known> <age>
# and, only when the second argument is the word `decisions`, a tenth field
# <decisions>: how many of <ready> are held decisions. A cached reading taken
# before fm_owner_calls supplied <ready> and <decisions> (it lacks the closing
# `calls` mark) cannot be trusted to split <ready>, so with `decisions` it is
# reported exactly as no reading (<known> 0), and either way a refresh is
# started at once so the next frame has the field.
# With the word `overview` instead (`strip` is the older name for it), the
# overview's readings follow those ten:
#   <failed> <lost> <night> <first-kind> <first-id> <first-title> <calls-signal>
#   <ready-list>
# as the header and _fm_fleet_collect describe them. Each is `-` when the
# reading has no such field, as one taken before the overview asked for them
# does not, and such a reading is refreshed at once; the ten fields stand as
# above. <calls-signal> is the owner's calls signal the shown calls were read
# under, so a renderer that sees the signal move past it knows to draw again.
# <ready-list> is the space-separated ids behind the merges in <ready>.
# tab separated. <known> is 1 when the six live fields are a current reading of
# THIS fleet, 2 when they are the last good reading but no longer current - it
# aged past its maximum, or the fleet changed since - and 0 when no good reading
# exists at all. <age> is how many seconds old the reading is, and 0 when
# <known> is 0. The six live fields are 0 and meaningless when <known> is 0; the
# renderer must show placeholders, and must mark a <known> 2 reading as past.
#
# Why a past reading is shown rather than refused: under load the out-of-band
# fold can miss its bound for longer than a reading lives, and on 2026-10-25 the
# row read "workers unknown" with five workers running. A reading the captain
# can see is old, beside a refresh that keeps being tried, tells him more than a
# placeholder; unknown is kept for a home that has never had a good reading.
# Records stay the live count either way, so a dispatch shows up at once.
fm_fleet_status_counts() {  # <state-dir> [decisions|overview]
  local state=$1 want=${2:-} now cache reader records ttl max_age
  local cached='' stamp='' working='' stopped='' validating='' paused=''
  local attention='' ready='' signature='' decisions='' mark='' current known age fresh=1
  local failed='' lost='' night='' first_kind='' first_id='' first_title=''
  local calls_signal='' ready_list='' now_signal shown_signal=- shown_list=- _newer
  [ "$want" != strip ] || want=overview
  records=$(_fm_fleet_ids "$state" | grep -c '') || records=0
  now=$(_fm_fleet_now) || {
    _fm_fleet_unknown "$records" "$want"
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
    fm_status_cache_read "$cache" "$now" "$ttl" >/dev/null 2>&1 || fresh=0
  fi

  # A saved reading or calls entry is read with one name past the fields this
  # code knows (_newer), so a field a newer writer adds is dropped rather than
  # run into the last known one: on 2026-11-15 a strip running older code read
  # a call's title with the newer reading's signal joined to it.
  if [ -n "$cached" ]; then
    IFS=$'\t' read -r stamp working stopped validating paused attention ready \
      signature decisions mark failed lost night first_kind first_id first_title \
      calls_signal ready_list _newer <<READING
$cached
READING
  fi
  # A reading that is malformed is no reading at all, and is never shown.
  case "$stamp$working$stopped$validating$paused$attention$ready" in
    ''|*[!0-9]*) cached= ;;
  esac
  [ -n "$signature" ] || cached=
  # A reading from before the owner's calls supplied <ready> and <decisions> is
  # still good for every older field, but it cannot split ready, so it is
  # refreshed now and, for a caller that asked for the split, it is no reading.
  [ "$mark" = calls ] || decisions=
  case "$decisions" in
    ''|*[!0-9]*)
      decisions=
      fresh=0
      [ "$want" != decisions ] && [ "$want" != overview ] || cached=
      ;;
  esac
  # The overview's readings are all there or none are.
  case "$failed$lost" in
    ''|*[!0-9]*) failed= ;;
  esac
  if [ -z "$failed" ] || [ -z "$night" ] || [ -z "$first_kind" ] || [ -z "$first_id" ] \
    || [ -z "$first_title" ]; then
    failed=- lost=- night=- first_kind=- first_id=- first_title=-
    [ "$want" != overview ] || fresh=0
  fi
  [ -n "$cached" ] || fresh=0
  # The owner's calls are kept as current as their signal, whatever the age of
  # the rest of the reading; the block above the refresh helpers owns why.
  if [ -n "$cached" ] && [ "$failed" != - ]; then
    if [ -z "$calls_signal" ] || [ -z "$ready_list" ]; then
      # A reading from before the calls carried their signal cannot be caught
      # up on its own, so the whole reading is refreshed now.
      fresh=0
    elif [ "${FM_FLEET_STATE_NO_CACHE:-}" = 1 ]; then
      shown_signal=$calls_signal
      shown_list=$ready_list
    else
      shown_list=$ready_list
      now_signal=$(fm_owner_calls_signal "$state")
      if [ "$calls_signal" = "$now_signal" ]; then
        shown_signal=$calls_signal
      elif _fm_fleet_calls_current "$state" "$now_signal" "$ready_list"; then
        ready=$FM_FLEET_CALLS_READY
        decisions=$FM_FLEET_CALLS_DECISIONS
        first_kind=$FM_FLEET_CALLS_KIND
        first_id=$FM_FLEET_CALLS_ID
        first_title=$FM_FLEET_CALLS_TITLE
        shown_signal=$now_signal
      else
        # The reading's own calls stand until the refresh lands, still marked
        # with the signal they were read under.
        shown_signal=$calls_signal
        _fm_fleet_calls_refresh_detached "$state" "$now" "$ready_list" "$now_signal"
      fi
    fi
  fi
  known=1
  if [ -n "$cached" ]; then
    current=$(_fm_fleet_ids "$state" | _fm_fleet_signature) || current=
    # Two independent reasons a good reading is no longer current: it is about
    # a different fleet, or it is past its maximum age.
    if [ "$signature" != "$current" ] \
      || ! fm_status_age_within "$now" "$stamp" "$max_age"; then
      known=2
      fresh=0
    fi
  fi
  # A frame that has no current reading starts a refresh, whatever the cache
  # TTL says, so a dispatch is folded without waiting out the window.
  if [ "$fresh" = 0 ] && [ "${FM_FLEET_STATE_NO_CACHE:-}" != 1 ]; then
    _fm_fleet_refresh_detached "$cache" "$state" "$now" "$reader"
  fi

  [ -n "$cached" ] || {
    _fm_fleet_unknown "$records" "$want"
    return 0
  }
  age=$((now - stamp))
  [ "$age" -ge 0 ] || age=0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$records" "$working" "$stopped" "$validating" "$paused" "$attention" \
    "$ready" "$known" "$age"
  case "$want" in
    decisions) printf '\t%s' "$decisions" ;;
    overview)
      printf '\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$decisions" "$failed" "$lost" "$night" \
        "$first_kind" "$first_id" "$first_title" "$shown_signal" "$shown_list"
      ;;
  esac
}

# _fm_fleet_calls_current: 0 iff state/.status-fleet-calls holds the owner's
# calls for exactly <signal> and <ready-list>, which it then sets as
# FM_FLEET_CALLS_READY, _DECISIONS, _KIND, _ID and _TITLE.
_fm_fleet_calls_current() {  # <state-dir> <signal> <ready-list>
  local entry signal list stamp ready decisions kind id title _newer
  entry=$(fm_status_cache_load "$1/.status-fleet-calls") || return 1
  IFS=$'\t' read -r signal list stamp ready decisions kind id title _newer <<ENTRY
$entry
ENTRY
  [ "$signal" = "$2" ] && [ "$list" = "$3" ] || return 1
  case "$stamp$ready$decisions" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$decisions" -le "$ready" ] && [ -n "$kind" ] && [ -n "$id" ] && [ -n "$title" ] || return 1
  FM_FLEET_CALLS_READY=$ready
  FM_FLEET_CALLS_DECISIONS=$decisions
  FM_FLEET_CALLS_KIND=$kind
  FM_FLEET_CALLS_ID=$id
  FM_FLEET_CALLS_TITLE=$title
}
