#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A registered Herdr agent resting
# at idle/done is the backend-proved healthy-finish exception: its stale pane is
# absorbed without a wedge timer, while its status/turn-end signals still carry
# the outcome. A declared external-wait pause is the separate idle absorb case
# and re-surfaces only on its long bounded cadence, although its initial no-verb
# status signal still surfaces in normal mode. A captain-held transfer is the
# other declared wait (fm-classify-lib.sh owns the policy): it never re-surfaces
# on any cadence, its quiet state is stream-truth (it ends the moment the hold
# resolves), and only a CONFIDENTLY DEAD agent surfaces once (fm_backend_agent_alive
# tells the two apart, never the verb) because the work is lost the moment the
# captain's answer lands.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge; one re-surface
#                          reports every wait that is due, grouped by blocking
#                          reason, so the queued wake names the trigger window
#                          while its reason stands for all of them. Only when
#                          neither absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A registered Herdr agent at its
#                          idle/done composer is healthy and starts no wedge timer;
#                          a confirmed agent-less shell follows the actionable
#                          stale path. A provably-working stale past the wedge
#                          threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active.
#   check: <script>: <out> authenticated check output, always actionable
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Shared harness busy-footer signatures.
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The DEFAULT EVENT SOURCE: this watcher's poll loop over the pull primitives
# (capture, recorded windows, backend busy-state, and the BUSY_REGEX fallback)
# synthesizes the signal/stale/check/heartbeat wake vocabulary for backends with
# no native event push. tmux always reports unknown busy-state, preserving the
# original regex path. A push-capable backend (herdr) additionally replaces this
# watcher's blind terminal sleep with a bounded wait on its native event stream
# (event_wait_or_sleep below), so a crew entering `blocked` wakes its supervisor
# sub-second; the same wait is also interrupted by a glasses mailbox or bridge
# inbox file event (bin/fm-file-event-lib.sh) so those checks do not sit until
# the next CHECK_INTERVAL. The poll loop stays live every cycle as the
# permanent fail-closed backstop. See bin/fm-backend.sh and docs/herdr-backend.md.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Shared normalized-transition accessors and the single-owner status->action
# policy table, so the event-wait splice reads transition records the same way
# the herdr subscriber writes them (bin/fm-transition-lib.sh).
# shellcheck source=bin/fm-transition-lib.sh
. "$SCRIPT_DIR/fm-transition-lib.sh"
# Glasses mailbox/inbox file-event wait. Interrupts the terminal poll sleep so
# a voice question or bridge photo does not sit until the next CHECK_INTERVAL
# sweep. Path list and wait exit codes are owned by this library.
# shellcheck source=bin/fm-file-event-lib.sh
. "$SCRIPT_DIR/fm-file-event-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report expectations created by fm-send.
# The tick is cheap when no records exist and never reads secondmate chat.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  STAT_STYLE=bsd
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  STAT_STYLE=gnu
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - verified grok 0.2.73, ASCII to avoid the
# locale fragility of matching grok's braille spinner glyph directly);
# cursor: "ctrl+c to stop" (verified 2026-07-19, Cursor CLI 2026.07.16-899851b).
# cursor's spinner VERB is deliberately not matched - it changes mid-turn
# ("Working" -> "Running" during a tool call) while the footer hint stays put.
# kimi: "thinking..." (reasoning phase) or "Running a command" (tool phase);
# verified 2026-07-23 on Kimi Code 0.27.0. Do NOT match bare "thinking" - the idle
# footer is "K3 thinking: max/high" and would false-positive. Moon-phase spinner
# glyphs alone are not matched (not ASCII-stable).
BUSY_REGEX=${FM_BUSY_REGEX:-$FM_BUSY_REGEX_DEFAULT}
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working (except a backend-proved registered
# idle/done agent), a provably-working stale past the threshold, or anything
# unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent still surfaces once.
# These cases re-surface once for a recheck every pause_resurface_secs_for_line
# window - far longer than the wedge threshold, but finite so a forgotten hold
# cannot rot invisibly. Captain-named waits use the longer captain cadence.
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is actively working. Prefers
# a backend's native semantic busy state (fm_backend_busy_state - herdr's
# agent.get; herdr-addendum "busy state" row, "the first backend where
# fm_session_busy_state gets real semantics"). A bare `busy` verdict is trusted
# outright. Both `idle` and unknown/unparseable fall through to the shared
# pane-tail regex over <tail40> - the same corroboration crew_pane_is_busy and
# the away-mode daemon already apply. Herdr maps blocked->idle and can also
# report idle while a long foreground tool call (or a busy cursor turn with
# "ctrl+c to stop") is still in progress; trusting idle outright skipped that
# corroboration and let healthy workers look idle on the poll path. <tail40>
# is the same bounded capture already read for hashing, so the corroboration
# adds no extra backend calls.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 bs
  bs=$(fm_backend_busy_state "$(window_backend "$w")" "$w" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
    *)
      printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
      ;;
  esac
}

# window_liveness_state: distinguish a busy turn, a registered agent resting at
# its idle composer, and a confidently agent-less endpoint. Semantic `blocked`
# remains attention-worthy so the poll path still backs up Herdr's push stream.
# Backends without a recovery-grade classifier report unknown and retain the
# existing stale policy.
window_liveness_state() {  # <window> <tail40>
  local w=$1 tail40=$2 backend agent_state agent_status
  if window_is_busy "$w" "$tail40"; then
    printf 'busy'
    return 0
  fi
  backend=$(window_backend "$w")
  agent_state=$(fm_backend_agent_state "$backend" "$w" 2>/dev/null)
  case "$agent_state" in
    alive)
      agent_status=$(fm_backend_agent_status "$backend" "$w" 2>/dev/null)
      case "$agent_status" in
        working) printf 'busy' ;;
        idle|done) printf 'finished-idle' ;;
        blocked) printf 'attention' ;;
        *) printf 'unknown' ;;
      esac
      ;;
    dead|missing) printf 'gone' ;;
    *) printf 'unknown' ;;
  esac
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# Collect every declared pause that is due for re-surface into the shared TSV
# work file. bin/fm-classify-lib.sh owns the record format and the fold, so the
# watcher and the away-mode daemon group identically. EVERY due task is appended,
# including several that resolve to one backend window: collapsing a window is the
# fold's job, and filtering here would hide the older task's age and its blocker
# from the group the fold builds. Only paused: waits are collected: a
# captain-held transfer never re-surfaces on any cadence (fm-classify-lib.sh owns
# that call), so grouping one in would reintroduce the nag through the back door.
pause_recheck_collect_due() {  # <due-file>
  local due=$1 meta task win last statusf mtime age rf rf_age pause_secs
  rm -f "$due"
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    win=$(fm_backend_target_of_meta "$meta")
    [ -n "$win" ] || continue
    last=$(last_status_line "$STATE/$task.status")
    status_is_paused "$last" || continue
    statusf="$STATE/$task.status"
    mtime=$(stat_mtime "$statusf")
    case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
    age=$(( $(date +%s) - mtime ))
    rf="$STATE/.paused-resurfaced-$(printf '%s' "$win" | tr ':/.' '___')"
    rf_age=$(age_of "$rf")
    pause_secs=$(pause_resurface_secs_for_line "$last")
    [ "$age" -ge "$pause_secs" ] && [ "$rf_age" -ge "$pause_secs" ] || continue
    pause_due_append "$due" "$last" "$age" "$win" "$rf"
  done
}

# Wake wording for one grouped blocker. A lone due pause keeps the historical
# single-window phrasing so existing triage stays stable.
pause_recheck_wake_line() {  # <count> <max-age> <note> <windows> <gated>
  local count=$1 max_age=$2 note=$3 wins=$4 gated=$5 line
  if [ "$count" -eq 1 ]; then
    line="stale: $wins (paused ${max_age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
  else
    line="stale: $count tasks sharing one wait (paused, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds): $note [$wins]"
  fi
  if [ "$gated" = 1 ]; then
    line="$line (cannot clear until the captain acts)"
  fi
  printf '%s\n' "$line"
}

# One wake reason for the whole due set: shared-reason waits become a single
# item, distinct reasons join with " | ". An empty due set (the trigger raced a
# status write, or was classified paused from crew state alone) falls back to
# the historical single-window wording for the trigger.
pause_recheck_reason_for_due() {  # <trigger-window> <due-file>
  local trigger=$1 due=$2 line parts=""
  if [ ! -s "$due" ]; then
    printf 'stale: %s (paused, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)' "$trigger"
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -z "$parts" ]; then
      parts=$line
    else
      parts="$parts | $line"
    fi
  done < <(pause_due_fold "$due" pause_recheck_wake_line)
  printf '%s' "$parts"
}

# Stamp the re-surface throttle for every window this recheck covers and put
# each on the bounded pause cadence. Called ONLY once the wake is durably
# queued, so a failed enqueue cannot silence a due wait for a full window. The
# trigger is always throttled - it is what the wake is keyed on - whether or not
# the sweep saw it, so a trigger the sweep missed cannot re-fire every poll.
pause_recheck_commit_due() {  # <due-file> <fallback-marker>
  local due=$1 fallback=$2 now marker win
  now=$(date +%s)
  printf '%s\n' "$now" > "$fallback"
  if [ ! -s "$due" ]; then
    return 0
  fi
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    printf '%s\n' "$now" > "$marker"
  done < <(pause_due_markers "$due")
  while IFS= read -r win; do
    [ -n "$win" ] || continue
    : > "$STATE/.paused-$(printf '%s' "$win" | tr ':/.' '___')"
  done < <(pause_due_windows "$due")
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# captain-held transfer. A paused: wait re-surfaces once every
# pause_resurface_secs_for_line window for a recheck - its wait may clear on its
# own (upstream landed, rate-limit reset) and the recheck detects that, and one
# re-surface covers every paused: wait that is due fleet-wide, grouped by
# blocking reason, so a shared blocker costs one wake instead of one per task. A
# captain-held transfer never re-surfaces on any cadence: only the captain's
# answer clears it, and nothing the recheck can observe changes. Live vs dead is
# told apart by fm_backend_agent_alive, never by the status verb: a HEALTHY idle
# pane absorbs completely silently (the decision is durably tracked), while a
# CONFIDENTLY DEAD agent surfaces exactly once because the work is lost the
# moment the answer arrives - the hold must not suppress that reading. The
# .captain-held-surfaced-<key> marker records the surfaced line so one hold
# state wakes at most once; the .paused-resurfaced-<key> throttle records the
# last paused: re-surface epoch so that cadence fires once per window rather
# than every poll (fm-classify-lib.sh owns the vocabulary call). Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it reads exactly one status line beyond what it already has, never
# crew state. The re-surface age is anchored on the status file mtime, not a
# per-hash marker, so a churny idle pane (a ticking clock, a token counter)
# cannot keep resetting the cadence the way a hash-tied timer would. Advances
# the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason last surf surf_away digest alive pause_secs due
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  last=$(last_status_line "$statusf")
  pause_secs=$(pause_resurface_secs_for_line "$last")
  # Only the captain-held verb is withheld from the re-surface: its wait clears
  # solely when the captain answers, so a recheck can find no change and would
  # be a pure nag. Every other line keeps the bounded cadence, including a pane
  # classified paused from crew state alone, whose own status log names no verb
  # for the sweep to find - withholding that one would leave its trigger
  # unthrottled and re-firing every poll. Both verbs stay on this declared-wait
  # absorb path and never reach the wedge timer.
  digest=$(status_open_captain_holds "$statusf")
  if [ -n "$digest" ] && status_declared_wait "$statusf"; then
    # An open captain-held transfer (stream-truth fold, fm-classify-lib.sh): a
    # declared wait that never wedge-ages and never re-surfaces on any cadence.
    # A healthy idle pane (fm_backend_agent_alive says alive/unknown) absorbs
    # silently; a confidently dead agent surfaces once with the loss-risk
    # reason, then stays silent. The surfaced marker stores the OPEN-HOLD
    # DIGEST (status_open_captain_holds), so one hold state wakes at most once
    # and a later resolution (which empties or changes the fold) naturally
    # supersedes it.
    # Both paths come from fm-classify-lib.sh's captain_held_surfaced_markers,
    # the ONE owner of the namespace pair, in its documented order: the
    # window-keyed marker this mode writes first, then away mode's task-keyed
    # one. Away mode records the same one-shot, so the surface is global across
    # supervision modes: if either marker already holds this fold digest, this
    # hold state woke before and must not wake again when supervision changes
    # hands. Reading the paths from the owner is what keeps a surface from being
    # written under one name and swept under another.
    { IFS= read -r surf; IFS= read -r surf_away; } < <(captain_held_surfaced_markers "$STATE" "$win" "$task")
    if [ "$(cat "$surf" 2>/dev/null || true)" != "$digest" ] \
      && [ "$(cat "$surf_away" 2>/dev/null || true)" != "$digest" ]; then
      alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || alive=unknown
      if [ "$alive" = dead ]; then
        reason="stale: $win (captain-held, agent exited: the worker is gone while a decision is owed, so its work is at risk once the answer lands)"
        fm_wake_append stale "$win" "$reason" || exit 1
        printf '%s' "$digest" > "$surf"
        printf '%s' "$digest" > "$surf_away"
        wake "$reason"
      fi
    fi
  elif [ "$age" -ge "$pause_secs" ] && [ "$rf_age" -ge "$pause_secs" ] \
     && ! status_is_captain_held "$last"; then
    due="$STATE/.paused-recheck-due.$$"
    pause_recheck_collect_due "$due"
    reason=$(pause_recheck_reason_for_due "$win" "$due")
    fm_wake_append stale "$win" "$reason" || { rm -f "$due"; exit 1; }
    pause_recheck_commit_due "$due" "$rf"
    rm -f "$due"
    wake "$reason"
  fi
  triage_log "absorbed stale (declared wait, age ${age}s): $win"
}

reconcile_captain_held_surfaced() {  # <window> <task>
  local win=$1 task=$2 fold surf surf_away
  fold=$(status_open_captain_holds "$STATE/$task.status")
  { IFS= read -r surf; IFS= read -r surf_away; } \
    < <(captain_held_surfaced_markers "$STATE" "$win" "$task")
  reconcile_captain_held_surfaced_markers "$fold" "$surf" "$surf_away"
}

clear_pause_state() {  # <window> [task]
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window> [task]
  local win=$1 task=${2:-} key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  clear_pause_state "$win" "$task"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# Only a confidently dead ordinary crew may recover paused classification after
# fm-crew-state has fallen back to stopped or unknown.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_declared_wait "$STATE/$task.status"; then
    rm -f "$recheck_file"
    reconcile_captain_held_surfaced "$win" "$task"
    class=$(crew_absorb_class "$task")
    if [ "$class" = paused ] && status_is_captain_held "$last"; then
      # A paused verdict behind a captain-held last line that is NOT a declared
      # wait (a malformed hold: invalid key slug, so the fold never opened) comes
      # only from the captain-held -> paused mapping, and handle_paused_stale's
      # paused branch requires status_is_paused on the last line, which such a
      # line never satisfies - so passing 'paused' would swallow the agent
      # forever. Treat it as a stopped crew (normal stale handling, surfaced
      # once); a provably-working one already reports working.
      printf 'none'
      return
    fi
    printf '%s' "$class"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$(window_kind "$win")" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if status_has_open_captain_hold "$STATE/$task.status"; then
    # An open captain-held transfer is a declared wait (fm-classify-lib.sh's
    # status_open_captain_holds fold, stream-truth not the last line): route it
    # to handle_paused_stale, which absorbs a healthy idle pane silently and
    # surfaces a confidently dead agent exactly once. Checked only after the
    # provably-working branch so a validating crew behind a stale hold line
    # keeps its wedge timer and a frozen run still escalates. Stamp the recheck
    # file instead of removing it so a confidently dead held pane is re-read by
    # the expensive crew_absorb_class at most once per STALE_ESCALATE_SECS (the
    # cheap branch returns 'paused' for a dead agent without clearing the
    # stamp); live panes clear it and keep the base per-poll re-check.
    date +%s > "$recheck_file"
    printf 'paused'
    return
  fi
  if [ "$(window_kind "$win")" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  [ "$class" = none ] && [ "${agent_alive:-unknown}" = dead ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(printf '%s' "$win" | tr ':/.' '___')
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_declared_wait "$STATE/$task.status"; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. When default glasses watch paths exist (mailbox DB or bridge
# inbox; bin/fm-file-event-lib.sh), the same wait is also interrupted by a
# filesystem change so a voice question or photo does not sit until the next
# CHECK_INTERVAL sweep. For every other home - no push-capable window, backend
# not capable, or the event path proven unreliable this process - it sleeps
# POLL, or file-waits POLL when glasses paths exist, byte-for-byte today's
# behavior when those paths are absent. The poll loop above still runs every
# cycle, so this only ever SHORTENS latency; it can never drop an escalation
# (the poll loop is the permanent fail-closed backstop). This preserves the
# single live supervision cycle: the reader is a short-lived subprocess of THIS
# watcher, not a second watcher, so every guard/beacon/arm/turn-end mechanism
# is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc p
  local windows=()
  local paths=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    paths+=("$p")
  done < <(fm_glasses_watch_paths "$FM_HOME")

  if [ "${#windows[@]}" -eq 0 ]; then
    if [ "${#paths[@]}" -gt 0 ]; then
      file_event_wait_or_sleep "${paths[@]}"
    else
      sleep "$POLL"
    fi
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    if [ "${#paths[@]}" -gt 0 ]; then
      file_event_wait_or_sleep "${paths[@]}"
    else
      sleep "$POLL"
    fi
    return
  fi

  if [ "${#paths[@]}" -gt 0 ]; then
    EVENT_WAIT_WINDOWS=("${windows[@]}")
    FILE_EVENT_PATHS=("${paths[@]}")
    race_push_and_file_wait "$first_backend" "$first_session"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  apply_push_wait_result "$first_backend" "$first_session" "$rec" "$rc"
}

# file_event_sig: one-line signature of the current glasses watch paths so a
# post-wait stat catch-up can expire .last-check even if the event waiter was
# killed when a competing herdr wait returned first.
file_event_sig() {  # <path>...
  local p
  for p in "$@"; do
    if [ "$STAT_STYLE" = bsd ]; then
      printf '%s:%s\n' "$p" "$(stat -f '%z:%Fm:%Fc' "$p" 2>/dev/null || printf missing)"
    else
      printf '%s:%s\n' "$p" "$(stat -c '%s:%y:%z' "$p" 2>/dev/null || printf missing)"
    fi
  done
}

# expire_check_sweep: make the next loop iteration run authenticated checks now
# instead of waiting out CHECK_INTERVAL. Used when a glasses path changed.
expire_check_sweep() {
  rm -f "$STATE/.last-check"
  triage_log "glasses file event; next cycle runs checks immediately"
}

# file_event_wait_or_sleep: replace sleep POLL with a bounded file wait when
# glasses paths exist. A change expires the slow-check timer; an unusable
# waiter falls back to sleep POLL.
file_event_wait_or_sleep() {  # <path>...
  local before after rc
  [ "$#" -gt 0 ] || { sleep "$POLL"; return; }
  before=$(file_event_sig "$@")
  fm_file_event_wait "$POLL" "$@"
  rc=$?
  after=$(file_event_sig "$@")
  if [ "$rc" -eq 0 ] || [ "$before" != "$after" ]; then
    expire_check_sweep
    return
  fi
  if [ "$rc" -eq 2 ]; then
    sleep "$POLL"
  fi
}

# fm_kill_pid_tree: stop a raced waiter and its descendants so a herdr socket
# reader cannot outlive the cycle that lost the race.
fm_kill_pid_tree() {  # <pid>
  local pid=$1 child
  [ -n "$pid" ] || return 0
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    fm_kill_pid_tree "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill "$pid" 2>/dev/null || true
}

# apply_push_wait_result: the herdr-only half of event_wait_or_sleep, shared
# with the file-event race so a herdr timeout/failure still follows the same
# fail-closed disable rule.
apply_push_wait_result() {  # <backend> <session> <record> <rc>
  local backend=$1 session=$2 record=$3 rc=$4
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$backend" "$session" "$record"
      ;;
    2)
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      _event_cap_fails=0
      ;;
  esac
}

# race_push_and_file_wait: run the herdr transition wait and the glasses file
# wait together. The first completion unblocks this cycle. A file change (or a
# post-wait signature change) expires .last-check. A herdr result is applied
# only when the file waiter did not win, so an interrupted herdr reader is not
# treated as a connect failure.
# Reads EVENT_WAIT_WINDOWS and FILE_EVENT_PATHS because bash functions cannot
# see the caller's local arrays.
# Winner is a regular noclobber file, not a fifo: a fifo read is interrupted
# by SIGCHLD when the other waiter exits, which dropped blocked escalations.
race_push_and_file_wait() {  # <backend> <session>
  local backend=$1 session=$2
  local race_dir winner_file recfile herdr_rc_file file_rc_file winner fpid hpid
  local file_rc=1 before after rec rc="" spins=0 poll_whole max_spins
  local -a race_windows=("${EVENT_WAIT_WINDOWS[@]}")
  local -a race_paths=("${FILE_EVENT_PATHS[@]}")
  [ "${#race_windows[@]}" -gt 0 ] || return
  [ "${#race_paths[@]}" -gt 0 ] || return

  before=$(file_event_sig "${race_paths[@]}")
  race_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-file-eventwait.XXXXXX") || {
    file_event_wait_or_sleep "${race_paths[@]}"
    return
  }
  winner_file="$race_dir/winner"
  recfile="$race_dir/rec"
  herdr_rc_file="$race_dir/herdr_rc"
  file_rc_file="$race_dir/file_rc"

  (
    fm_file_event_wait "$POLL" "${race_paths[@]}"
    rc=$?
    printf '%s\n' "$rc" > "$file_rc_file"
    if [ "$rc" -eq 0 ]; then
      set -C
      { printf 'file\n' > "$winner_file"; } 2>/dev/null || true
    fi
  ) &
  fpid=$!
  (
    rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition \
      "$backend" "$session" "$POLL" "$STATE" "${race_windows[@]}")
    rc=$?
    printf '%s' "$rec" > "$recfile"
    printf '%s\n' "$rc" > "$herdr_rc_file"
    set -C
    { printf 'herdr:%s\n' "$rc" > "$winner_file"; } 2>/dev/null || true
  ) &
  hpid=$!

  poll_whole=${POLL%%.*}
  [[ "$poll_whole" =~ ^[0-9]+$ ]] || poll_whole=0
  max_spins=$(((poll_whole + 3) * 20))
  while [ ! -s "$winner_file" ]; do
    if ! kill -0 "$fpid" 2>/dev/null && ! kill -0 "$hpid" 2>/dev/null; then
      break
    fi
    command sleep 0.05
    spins=$((spins + 1))
    [ "$spins" -ge "$max_spins" ] && break
  done
  winner=$(cat "$winner_file" 2>/dev/null || true)
  if [ "$winner" = herdr:2 ]; then
    wait "$fpid" 2>/dev/null || true
  else
    fm_kill_pid_tree "$fpid"
  fi
  fm_kill_pid_tree "$hpid"
  wait "$fpid" 2>/dev/null || true
  wait "$hpid" 2>/dev/null || true
  [ -f "$file_rc_file" ] && file_rc=$(cat "$file_rc_file")
  winner=$(cat "$winner_file" 2>/dev/null || true)
  rec=$(cat "$recfile" 2>/dev/null || true)
  if [ -z "$winner" ] && [ -f "$herdr_rc_file" ]; then
    winner="herdr:$(cat "$herdr_rc_file")"
  fi
  rm -rf "$race_dir"

  after=$(file_event_sig "${race_paths[@]}")
  if [ "$winner" = file ] || [ "$file_rc" -eq 0 ] || [ "$before" != "$after" ]; then
    expire_check_sweep
  fi
  if [ "$winner" = file ]; then
    return
  fi
  case "$winner" in
    herdr:0|herdr:1)
      rc=${winner#herdr:}
      apply_push_wait_result "$backend" "$session" "$rec" "$rc"
      ;;
    herdr:2)
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      [ "$file_rc" -eq 2 ] && sleep "$POLL"
      ;;
  esac
}

# handle_push_transition: act on a fresh actionable (blocked) transition record
# the backend returned. Maps the pane back to its window and task, applies the
# park exemption (a declared paused: wait OR a captain-held: transfer is not a
# surprise block - the idle pane is expected; absorb it and leave rechecks to
# the poll loop's long pause cadence instead of forcing a re-arm), corroborates
# against the rendered busy footer (herdr can report blocked while a harness is
# mid-turn - cursor's "ctrl+c to stop" on default:wP:p4, 2026-07-19; a genuine
# human-blocked pane has no busy banner), and otherwise enqueues an immediate
# `stale` wake and wakes the supervisor. The `stale` kind is deliberate: the
# supervisor's handler for it ("peek the pane to diagnose") is exactly right for
# a blocked crew, and the drain/dedupe/guard machinery already understands it
# (queued by key=window, so a later poll-path stale for the same pane collapses
# on drain).
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason tail40 last
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  "$SCRIPT_DIR/fm-visible-status.sh" "$task" >/dev/null 2>&1 || true
  last=$(last_status_line "$STATE/$task.status")
  if status_declared_wait "$STATE/$task.status"; then
    triage_log "absorbed push $to (parked status, awaiting external or captain): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  # Defense-in-depth for direct callers and any path that surfaces blocked
  # without apply_transition's busy-footer gate: absorb mid-turn busy panes
  # without committing the dedupe marker so a later genuine blocked (no busy
  # footer) can still escalate on reconcile.
  tail40=$(fm_backend_capture "$backend" "$window" 40 2>/dev/null) || tail40=""
  if [ -n "$tail40" ] && printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
       | grep -qiE "$BUSY_REGEX"; then
    triage_log "absorbed push $to (busy footer, not waiting on human): $window"
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Startup hygiene before the migration competes for the same lock: a process
# killed mid-run (an interrupted migration sweep is the observed case) can leave
# a lock recording a dead holder and an unreferenced owner staging dir that
# nothing else ever revisits. Reclaim touches neither a live holder nor an
# acquire still in flight.
fm_lock_reclaim_orphans "$WATCH_LOCK"

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
watcher_cleanup() {
  fm_active_check_stop || return 1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  fm_lock_release "$WATCH_LOCK"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Resolve correlated secondmate reports, send at most one recovery request,
  # and escalate once when the answer still cannot reach the parent.
  fm_pending_reply_tick "$STATE" || true

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          provider=$FM_PR_DATA_PROVIDER
          url=$FM_PR_DATA_URL
          host=$FM_PR_DATA_HOST
          path=$FM_PR_DATA_PATH
          number=$FM_PR_DATA_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    # Status writes and turn-end markers are bounded authoritative-state
    # refresh points for captain-facing Herdr presentation.
    "$SCRIPT_DIR/fm-visible-status.sh" --all >/dev/null 2>&1 || true
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature need semantic liveness classification: a registered idle/done Herdr
  # agent is a healthy finish, while an agent-less shell is gone and ambiguous
  # backends retain the existing stopped/waiting/wedged policy. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=${w//:/_}
    key=${key//\//_}
    key=${key//./_}
    last=$(last_status_line "$STATE/$task.status")
    reconcile_captain_held_surfaced "$w" "$task"
    if [ -e "$STATE/.paused-$key" ] && ! status_declared_wait "$STATE/$task.status"; then
      clear_pause_tracking "$w" "$task"
    fi
    if [ "$kind" = secondmate ] && ! status_declared_wait "$STATE/$task.status"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Prefer semantic liveness after the pane has held one stable hash. A
      # registered Herdr agent at idle/done is a healthy finished worker, not a
      # wedge; a bare shell remains gone and follows the actionable stale path.
      # Busy corroboration still includes the shared footer regex.
      liveness=$(window_liveness_state "$w" "$tail40")
      if [ "$n" -ge 2 ] && [ "$liveness" = finished-idle ]; then
        clear_pause_tracking "$w" "$task"
        rm -f "$ssf" "$ewf"
        triage_log "absorbed stale (registered agent idle at composer, healthy finish): $w"
      elif [ "$n" -ge 2 ] && [ "$liveness" != busy ]; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. A confidently gone agent follows this path immediately.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" "$task" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew declared an external wait, or a declared pause or
          #     captain hold is paired with a confidently dead agent, so absorb on
          #     the long declared-pause re-surface cadence instead of wedge-escalating;
          #   - none: no running pipeline, idle pane, no busy signature, no declared
          #     pause - the crew has STOPPED. Surface immediately so firstmate peeks
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$w" "$task"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_declared_wait "$STATE/$task.status"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w" "$task"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              # The hold's quiet-state ended (resolved or superseded): drop the
              # dead-agent one-shot marker so a later re-opened identical hold
              # still surfaces (deterministic hold ids make digests repeatable).
              reconcile_captain_held_surfaced "$w" "$task"
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping.
        rm -f "$ssf" "$ewf"
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_declared_wait "$STATE/$(window_to_task "$w" "$STATE").status"; }; then
          clear_pause_tracking "$w" "$task"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      rm -f "$ssf" "$ewf"
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_declared_wait "$STATE/$task.status" && ! window_is_busy "$w" "$tail40"; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$w" "$task" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w" "$task"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
