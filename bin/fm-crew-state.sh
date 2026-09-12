#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   2. Matching no-mistakes run for this crew's branch AND current code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      A run matches when its head equals the worktree HEAD, or the worktree HEAD
#      is an ancestor of the run head (pipeline fix commits advanced the run on
#      the same line of history). Local work that advanced past the run head, or
#      diverged from it, invalidates attribution.
#      More than one recorded run can bind at once, so a LIVE run outranks a
#      terminal FAILURE: a failed answer is provisional until the runs ledger has
#      been asked whether this worktree also has a live run, and the ledger's own
#      scan recognizes the pipeline's fix-round head even when this copy never
#      fetched that object (nm_runs_status_and_epoch_for_branch owns that rule,
#      including the exact-head anchor that keeps unrelated, rewritten, and stale
#      same-branch runs rejected). Nothing displaces a run that finished
#      passed/checks-passed - that is a result, not a corpse - on either route.
#      That unverifiable live row is an INFERENCE bounded by the only evidence
#      tied to it, the ledger's record of when that run STARTED: past
#      FM_CREW_STATE_LIVE_ROW_MAX_AGE, with no usable date, or with no readable
#      local clock, it reports unknown rather than claiming the crew works or
#      that the replaced run died. The bound is a backstop against a row nobody
#      reaped, not a verdict on how long a run may take - a run monitoring a
#      green PR overnight keeps reading working. Runs this copy CAN resolve are
#      never aged out.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#      AND except recency against a newer declared pause/block: when the last
#      well-formed status line is paused: or blocked: and is newer than a
#      terminal failed/cancelled run-step, the status log wins (live 2026-07-21
#      declared-pause-lost incident). A failed run that is still the newest
#      signal keeps failed.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows each ledger read
# (nm_runs_status_and_epoch_for_branch, below) scans, whether it is the
# cross-branch fallback or the live-run probe behind a terminal failure
# (docs/configuration.md owns the setting). Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire history
# every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
# How old the ledger date of an UNVERIFIABLE live row may be before the anchored
# pipeline-continuation inference stops claiming this crew is working
# (nm_live_row_freshness, below; docs/configuration.md owns the setting).
# The date is when the run STARTED, not when it ended (nm_parse_runs_date_epoch
# states the evidence), and a healthy run stays `running` for its whole ci
# monitor phase - until a captain merges the PR, which is routinely overnight and
# can be a weekend. So this is a BACKSTOP against a row nobody ever reaps, NOT a
# judgement about how long a run may legitimately take: three days is past any
# plausible live run, which is exactly the point. Stated honestly, that makes the
# rule weak for its purpose - it cannot tell a dead run from a slow one, and an
# unreaped row still reads working for days before it expires - but a tighter
# window would manufacture a false unknown for a crew that is genuinely working,
# which is the same wrong reading this reader exists to prevent. ONLY this
# inference is bounded - a run whose head this copy can resolve, and the `axi
# status` answer itself, are never aged out.
FM_CREW_STATE_LIVE_ROW_MAX_AGE=${FM_CREW_STATE_LIVE_ROW_MAX_AGE:-259200}
case "$FM_CREW_STATE_LIVE_ROW_MAX_AGE" in ''|*[!0-9]*) FM_CREW_STATE_LIVE_ROW_MAX_AGE=259200 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the declared-wait verb set (fm-classify-lib.sh's status_is_paused_or_captain_held,
# covering both the bounded external-wait paused: and the verified captain-held
# transfer): a crew with no active run and an idle pane that declared a wait
# reports `paused` distinctly, so a supervisor reading this sees a declared wait
# rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused_or_captain_held "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Use the shared
# read-only existence check (fm_backend_target_exists): observation must not
# start a session-provider server as a side effect.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  fm_backend_target_exists "$TASK_BACKEND" "$1" "$EXPECTED_LABEL"
}
# crew_pane_is_busy: the busy-signature fallback, backend-aware the same way -
# fm_backend_busy_state's native semantic state (herdr's agent.get) when
# available, else the shared tmux pane-regex reader (fm_pane_is_busy,
# bin/fm-tmux-lib.sh) unchanged for tmux/unknown.
#
# `busy` alone is trusted outright. Both `idle` and unknown/unparseable fall
# through to the shared tail-regex corroboration, NOT just unknown: herdr's
# agent.get reports generation state ("working" while the model is streaming
# a turn, "done"/"idle" once it is not - docs/herdr-backend.md "Busy state"),
# which is a narrower signal than "this crew's turn/tool call is still in
# progress". A crew blocked on its own long-running foreground tool call (e.g.
# `no-mistakes axi run` without --yes, which blocks synchronously until a gate
# or outcome - AGENTS.md section 7) is not generating for that whole span, so
# agent.get can read idle/blocked (bin/backends/herdr.sh maps both to `idle`)
# while the pane's own rendered text still shows the harness's busy banner
# (BUSY_REGEX, e.g. "esc to interrupt") for the entire tool call, exactly like
# tmux's regex-only reader would correctly report. Trusting herdr's `idle`
# outright (skipping that corroboration) is what let a still-working crew read
# as not-busy here, and - combined with a no-mistakes run-step lookup that also
# missed attribution (see nm_runs_status_and_epoch_for_branch) - as not
# provably working in fm-classify-lib.sh, triggering an immediate (non-wedge)
# stale wake instead of the absorb-then-escalate path. A genuinely human-blocked
# agent (a permission dialog, not mid-tool-call) does not render the busy banner,
# so this corroboration does not mask that case: it stays correctly not-busy.
crew_pane_is_busy() {  # <target>
  case "$TASK_BACKEND" in
    tmux) fm_pane_is_busy "$1" ;;
    *)
      local bs tail40
      bs=$(fm_backend_busy_state "$TASK_BACKEND" "$1" 2>/dev/null)
      case "$bs" in
        busy) return 0 ;;
        *)
          tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || return 1
          printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
            | grep -qiE "${FM_BUSY_REGEX:-$FM_BUSY_REGEX_DEFAULT}"
          ;;
      esac
      ;;
  esac
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

# Bounded no-mistakes call in the worktree; stdout only, never fails the script.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
nm_run() {  # <args...>
  case "$HAVE_TIMEOUT" in
    timeout)  ( cd "$WT" && timeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    gtimeout) ( cd "$WT" && gtimeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    perl)     ( cd "$WT" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    *)        true ;;
  esac
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  printf '%s\n' "$RUN_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" | head -1
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Full commit sha for a run-recorded sha-ish, or empty when this copy holds no
# such object. ONE owner for that question: both head-binding rules and the
# ledger scan below distinguish "resolves but is the wrong history" (a rewritten
# or diverged tip, which must stay rejected) from "resolves to nothing here" (a
# commit this copy simply never fetched, which proves nothing on its own).
nm_resolve_commit() {  # <sha-ish>
  local sha=${1:-}
  [ -n "$sha" ] || return 0
  git -C "$WT" rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null || true
}

# Liveness class of a run status word: live, failure, result, unverified, or
# unknown. ONE owner of that vocabulary for every reader: the ledger's status
# column (which emits running/completed/failed/cancelled), the `axi status`
# outcome/status fields that share those words (nm_run_is_terminal_failure), and
# the unverified-* synthetic words the anchored inference below emits when it
# cannot stand behind its own answer - one per reason, all one class, since no
# ledger word can collide with that prefix. failure and result are split because only a
# FAILURE is ever displaced - a passed/checks-passed result is a verdict, not a
# corpse - so no caller needs a second copy of the failed/cancelled list.
nm_run_status_class() {  # <status-word>
  case "${1:-}" in
    running)                    printf 'live' ;;
    failed|cancelled)           printf 'failure' ;;
    completed)                  printf 'result' ;;
    unverified-*)               printf 'unverified' ;;
    *)                          printf 'unknown' ;;
  esac
}

# Freshness verdict for the ledger date of a HELD live row (see the anchored
# pipeline-continuation rule below): fresh, stale, undated, or local-clock.
# HONEST SEMANTICS: the date column records when the run STARTED, so this bounds
# how long ago that record was created, and nothing here observes the process.
# A stale or undated verdict therefore means "this copy cannot stand behind the
# inference", never "that run died" - callers represent every non-fresh verdict
# as unknown rather than converting it into a failure. Clock skew that dates a
# row in the future reads fresh rather than inventing an expiry.
# The LOCAL clock is read first, and its failure gets its own verdict, because
# the same `date` binary parses the row's date: a machine whose clock cannot be
# read would otherwise report every row as a defective RECORD and send an
# operator to the ledger for a fault that is entirely local.
nm_live_row_freshness() {  # <epoch>
  local epoch=${1:-} now
  now=$(date +%s 2>/dev/null) || now=""
  case "$now" in ''|*[!0-9]*) printf 'local-clock'; return ;; esac
  case "$epoch" in ''|*[!0-9]*) printf 'undated'; return ;; esac
  if [ "$((now - epoch))" -gt "$FM_CREW_STATE_LIVE_ROW_MAX_AGE" ]; then
    printf 'stale'
  else
    printf 'fresh'
  fi
}

# Unpack a "status<TAB>epoch" pair from nm_runs_status_and_epoch_for_branch into
# NM_PAIR_STATUS and NM_PAIR_EPOCH. ONE owner of that format and of the epoch
# sanity check, so no reader can feed a missing or unparseable date into a
# numeric comparison: an epoch that is not all digits becomes empty.
nm_read_runs_pair() {  # <pair>
  local pair=${1:-}
  NM_PAIR_STATUS=${pair%%$'\t'*}
  case "$pair" in
    *$'\t'*) NM_PAIR_EPOCH=${pair#*$'\t'} ;;
    *)       NM_PAIR_EPOCH="" ;;
  esac
  case "$NM_PAIR_EPOCH" in ''|*[!0-9]*) NM_PAIR_EPOCH="" ;; esac
}

# Coarse ledger read, used for cross-branch attribution (this comment) and, since
# the live-over-terminal rule, as the probe behind a terminal `axi status`
# failure. `no-mistakes axi status` (bare) reports the active-or-most-recent run
# for the CURRENT branch when one exists,
# else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Echoes the first (most recent)
# binding row's status word (running/completed/cancelled/failed) plus a TAB and
# the optional start-time epoch from the date column, subject to the anchored
# pipeline-continuation exception stated with the function below, or empty when
# the branch has no run within FM_CREW_STATE_RUNS_LIMIT rows.
# Parse a `no-mistakes runs` date column ("YYYY-MM-DD HH:MM") to epoch seconds.
# Empty on failure so callers can fall back without treating parse errors as "old".
# WHAT THAT DATE IS, established from recorded runs rather than assumed: run
# 01M2AB3H8Y2AW1AVJDK0SH19G7 (fm/fm-cursor-lock-identity) is listed with date
# 2026-09-12 10:17 while still `running` at about 10:19, its head later advanced
# and its status later became failed, and its review step alone recorded
# duration_ms 1767690 (~29.5 min), so 10:17 cannot be an end time. The column is
# the run's START/creation time and does not move when the run later ends.
nm_parse_runs_date_epoch() {  # <YYYY-MM-DD> <HH:MM>
  local day=$1 clock=$2
  [ -n "$day" ] && [ -n "$clock" ] || return 0
  case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 0 ;; esac
  case "$clock" in [0-9][0-9]:[0-9][0-9]) ;; *) return 0 ;; esac
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    date -j -f '%Y-%m-%d %H:%M' "$day $clock" '+%s' 2>/dev/null || true
  else
    date -d "$day $clock" '+%s' 2>/dev/null || true
  fi
}

# Echo "status<TAB>epoch" for the newest head-matching runs-list row for <branch>,
# or empty when none. Epoch may be empty when the date column is missing/unparseable.
# The status is a ledger word (running/completed/cancelled/failed), or one of the
# synthetic unverified-* words the anchored rule below emits for an inference it
# cannot stand behind; nm_run_status_class classifies both vocabularies.
#
# ANCHORED PIPELINE CONTINUATION (fm-crew-state-stale-run, live 2026-09-12).
# The pipeline commits its fix rounds in its own gate repo, never in the task
# worktree, so a healthy run's head is routinely an object this copy has never
# fetched while the worktree still sits at the head it submitted. Rejecting
# every unresolvable row outright let the scan walk on to an OLDER TERMINAL row
# that ended at exactly that submitted head and report its terminal state as
# current - an actively validating crew read `failed`.
# A LIVE row whose head does not resolve here is therefore HELD rather than
# skipped, and it is attributed only when the row immediately older on the same
# branch is a terminal FAILURE that resolves to EXACTLY this worktree's HEAD:
# that row is the failed submission this worktree made, so the live row above it
# is that work still being validated. Nothing else widens - a held row whose
# anchor fails is dropped and the scan continues exactly as before, a live row
# that RESOLVES must still bind by the ordinary head rule, so a rewritten or
# diverged tip stays rejected, an anchor that finished passed/checks-passed is a
# result rather than a corpse and keeps its own verdict, and branch-name
# coincidence never attributes a run on its own.
#
# The held row is an INFERENCE, not an observation: its head is an object this
# copy does not have, so nothing here can see whether that run still breathes.
# The ledger date of the held row is the only evidence tied to that exact run,
# so the inference is bounded by it (nm_live_row_freshness). That date is the
# run's START time, so the bound is only a backstop against a row nobody reaped -
# deliberately set past any plausible live run, because a run legitimately stays
# `running` through an overnight ci-monitor wait for a captain merge and must
# keep reading working. A row past FM_CREW_STATE_LIVE_ROW_MAX_AGE, one this copy
# cannot date, or a local clock this copy cannot read yields the matching
# synthetic word (unverified-stale, unverified-undated, unverified-local-clock).
# All three say "insufficient evidence" and are reported as unknown - a gate
# process that died without reaping its row must not pin a crew as working
# forever, and equally an unreaped row is no proof the run died, so the older
# failure is not resurrected as the current state either. Only this inference is
# bounded; a run whose head resolves here, and the `axi status` answer itself,
# are never aged out.
nm_runs_status_and_epoch_for_branch() {  # <branch>
  local branch=$1 out row st rest br sha day clock epoch
  local held_st="" held_epoch="" local_full
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || local_full=""
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    sha=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    day=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    clock=${rest%% *}
    [ "$br" = "$branch" ] || continue
    epoch=$(nm_parse_runs_date_epoch "$day" "$clock")
    if [ -n "$held_st" ]; then
      # The row immediately older than a held live row is its only admissible
      # anchor: only exact equality proves this worktree submitted it, and only
      # a terminal FAILURE may be displaced by the row above it.
      if [ -n "$local_full" ] && [ "$(nm_run_status_class "$st")" = failure ] \
        && [ "$(nm_resolve_commit "$sha")" = "$local_full" ]; then
        case "$(nm_live_row_freshness "$held_epoch")" in
          fresh)       printf '%s\t%s' "$held_st" "$held_epoch" ;;
          stale)       printf 'unverified-stale\t%s' "$held_epoch" ;;
          local-clock) printf 'unverified-local-clock\t' ;;
          *)           printf 'unverified-undated\t' ;;
        esac
        return 0
      fi
      held_st=""
      held_epoch=""
    fi
    # Same code-identity rule as axi status: a same-branch row whose short-sha
    # does not bind to this worktree (rewritten or advanced tip) is not ours.
    if nm_coarse_head_matches_worktree "$sha"; then
      printf '%s\t%s' "$st" "$epoch"
      return 0
    fi
    if [ "$(nm_run_status_class "$st")" = live ] && [ -z "$(nm_resolve_commit "$sha")" ]; then
      held_st=$st
      held_epoch=$epoch
    fi
  done <<< "$out"
  return 0
}

# Epoch mtime of this crew's status log, or empty when unreadable.
status_log_mtime_epoch() {
  [ -f "$LOG" ] || return 0
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f %m "$LOG" 2>/dev/null || true
  else
    stat -c %Y "$LOG" 2>/dev/null || true
  fi
}

# 0 when the status log's last paused:/blocked: line is newer than the terminal
# failed/cancelled run we attributed. Recency, not source rank, decides.
# captain-held is deliberately NOT in the set: a hold is routing state, never a
# fact, so it must never mask the terminal failure it follows (the failed run
# wins and the hold is reported alongside it - see the failed-run emit below).
# When the run's end time cannot be determined, a trailing paused:/blocked: is
# treated as newer (the worker's last append after observing the failure).
# Accuracy note, no behaviour change: when no axi-status timestamp field exists
# the runs-ledger fallback below supplies the run's START time, not its end
# (nm_parse_runs_date_epoch), so this comparison can read a pause appended while
# the run was still going as "newer" than the run. That is knowingly left exactly
# as it was - the comparison predates the live-row rule, it is the 2026-07-21
# declared-pause-lost fix's own behaviour, and swapping which timestamp it trusts
# is a separate decision with its own incident history.
status_log_newer_than_terminal_run() {
  local log_epoch run_epoch pair field
  if [ "$LOG_VERB" = blocked ]; then :
  else status_is_paused "$LOG_LINE" || return 1; fi
  log_epoch=$(status_log_mtime_epoch)
  case "$log_epoch" in ''|*[!0-9]*) return 1 ;; esac

  run_epoch=""
  # Prefer an explicit axi-status timestamp when the CLI exposes one.
  for field in ended_at finished_at updated_at completed_at; do
    run_epoch=$(strip_quotes "$(nm_field "$field")")
    case "$run_epoch" in ''|*[!0-9]*) run_epoch="" ;; *) break ;; esac
  done
  # Otherwise use the matching `no-mistakes runs` date (full and coarse paths).
  if [ -z "$run_epoch" ] && [ -n "$CREW_BRANCH" ]; then
    if [ -n "${COARSE_RUN_EPOCH:-}" ]; then
      run_epoch=$COARSE_RUN_EPOCH
    else
      pair=$(nm_runs_status_and_epoch_for_branch "$CREW_BRANCH")
      nm_read_runs_pair "$pair"
      run_epoch=$NM_PAIR_EPOCH
    fi
  fi
  if [ -z "$run_epoch" ]; then
    return 0
  fi
  [ "$log_epoch" -gt "$run_epoch" ]
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# 0 if the active axi-status run's head field matches this worktree's code
# identity. Branch match is a precondition (caller). Rules:
#   - missing/empty head field: cannot bind; reject the run
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip)
#   - run head is a strict ancestor of worktree HEAD: no match (local work
#     advanced outside the run)
#   - diverged / run head not in this worktree: no match (rewritten branch tip)
nm_run_head_matches_worktree() {
  local run_head local_full run_full
  run_head=$(strip_quotes "$(nm_field head)")
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  if git -C "$WT" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    return 0
  fi
  return 1
}

# 0 when the captured `axi status` run is a terminal FAILURE (failed/cancelled,
# by outcome or by status - nm_run_status_class owns that word list for every
# reader). Only that class is provisional against the ledger below: a failed
# record can be the corpse of an attempt the pipeline has already replaced,
# while a run that finished passed/checks-passed is a real result whose PR-ready
# verdict must not be downgraded back to "validating". An outcome, once present,
# is the whole answer; only a run with no outcome yet is judged by its status.
nm_run_is_terminal_failure() {
  local outcome status
  outcome=$(strip_quotes "$(nm_field outcome)")
  if [ -n "$outcome" ]; then
    [ "$(nm_run_status_class "$outcome")" = failure ]
    return
  fi
  status=$(strip_quotes "$(nm_field status)")
  [ "$(nm_run_status_class "$status")" = failure ]
}

# Coarse runs-list rows are "<status> <branch> <short-sha> ...". 0 if the short
# sha for this branch row matches the worktree head under the same rules as
# nm_run_head_matches_worktree (equal, or local is ancestor of run tip).
nm_coarse_head_matches_worktree() {  # <short-sha>
  local run_head=$1 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(nm_resolve_commit "$run_head")
  [ -n "$run_full" ] || return 1
  [ "$run_full" = "$local_full" ] && return 0
  if git -C "$WT" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    return 0
  fi
  return 1
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means the
# state comes from a bare runs-list word instead, either because `axi status`
# could not be attributed to this worktree at all or because a live ledger row
# displaced its terminal failure (the live-over-terminal rule below). Either
# way the run-step block skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
COARSE_RUN_EPOCH=""
# Set by nm_read_runs_pair, the single owner of the "status<TAB>epoch" format.
NM_PAIR_STATUS=""
NM_PAIR_EPOCH=""
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && nm_run_head_matches_worktree; then
      HAVE_RUN=1
      # Live-over-terminal (fm-crew-state-stale-run, live 2026-09-12). More than
      # one recorded run can bind to this worktree at once: a run that died at
      # the worktree's exact commit still binds by the equal-commit rule while
      # the run that replaced it validates the pipeline's fix commits on the
      # same branch. Bare `axi status` answers with one of them, so a terminal
      # FAILURE here is provisional until the ledger has been asked whether this
      # worktree also has a live run - reporting the corpse as current is what
      # produced a wrong captain report, a wrong stuck-crew recovery, and a
      # premature teardown attempt on a run that was still progressing.
      # Only a live word displaces it; a failed run with no live sibling keeps
      # its full `axi status` step and gate detail rather than degrading to the
      # ledger, and the ledger's own answer for the terminal row pre-fills the
      # epoch the recency override below would otherwise re-query.
      if nm_run_is_terminal_failure; then
        nm_read_runs_pair "$(nm_runs_status_and_epoch_for_branch "$CREW_BRANCH")"
        case "$(nm_run_status_class "$NM_PAIR_STATUS")" in
          live)
            COARSE_STATUS=$NM_PAIR_STATUS
            COARSE_RUN_EPOCH=$NM_PAIR_EPOCH
            RUN_SOURCE=coarse
            ;;
          unverified)
            # The ledger found a live row anchored to this worktree's failed
            # submission but cannot vouch for it. Reporting the failure as
            # current would assert a death this copy cannot see, so the crew
            # reads unknown and surfaces instead of being absorbed either way.
            COARSE_STATUS=$NM_PAIR_STATUS
            RUN_SOURCE=coarse
            ;;
          failure|result)
            COARSE_RUN_EPOCH=$NM_PAIR_EPOCH
            ;;
        esac
      fi
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      coarse_pair=$(nm_runs_status_and_epoch_for_branch "$CREW_BRANCH")
      if [ -n "$coarse_pair" ]; then
        nm_read_runs_pair "$coarse_pair"
        COARSE_STATUS=$NM_PAIR_STATUS
        COARSE_RUN_EPOCH=$NM_PAIR_EPOCH
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    # The unverified-* words are not ledger status words: they are the anchored
    # inference reporting that it cannot stand behind itself (see
    # nm_runs_status_and_epoch_for_branch). Neither working nor failed is
    # honest there, so the crew reads unknown and the detail names the gap.
    case "$COARSE_STATUS" in
      running)            RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed)          RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)             RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled)          RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      unverified-stale)   RUN_STATE=unknown; RUN_DETAIL="live run unverifiable: record started before the freshness bound" ;;
      unverified-undated) RUN_STATE=unknown; RUN_DETAIL="live run unverifiable: record carries no usable date" ;;
      unverified-local-clock)
                          RUN_STATE=unknown; RUN_DETAIL="live run unverifiable: local clock unreadable here" ;;
      *)                  RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: captain decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              RUN_STATE="done"
              RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  # Recency override: a terminal failed/cancelled run must not outrank a newer
  # declared pause or block. Without this, crew_absorb_class returns none and
  # the watcher floods bare stale: wakes every poll (declared-pause-lost). The
  # verb test lives inside status_log_newer_than_terminal_run (one site, not a
  # second list that must stay in sync with the caller). A captain-held transfer
  # after a terminal failure is reported ALONGSIDE the failure, never instead of
  # it: the failed run is a fact about what happened, the hold is only routing
  # state, so the failure wins and the hold is named so no reader loses it
  # (fm-classify-lib.sh's status_is_captain_held). Both belong to the same
  # failed state, so they share one block (the recency emit exits when it
  # fires; the hold append applies only when the failure is not superseded).
  case "$RUN_STATE" in
    failed)
      if status_log_newer_than_terminal_run; then
        emit "$(map_log_state "$LOG_LINE")" status-log \
          "$(status_line_note "$LOG_LINE")${SEP}terminal run superseded by newer status-log"
      fi
      if status_is_captain_held "$LOG_LINE"; then
        RUN_DETAIL="$RUN_DETAIL${SEP}hold: $(status_line_note "$LOG_LINE")"
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# signature is not meaningful for them; read their state from the status log only.
if [ "$KIND" != secondmate ] && crew_pane_is_busy "$BACKEND_TARGET"; then
  emit working pane "harness busy"
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
