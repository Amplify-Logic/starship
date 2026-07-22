#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by both the away-mode
# daemon (bin/fm-supervise-daemon.sh) and bin/fm-send.sh so the composer/submit
# logic cannot drift between the two.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders ("│ > … │"), so every idle claude pane read
# as "pending input" and the away-mode daemon deferred 100% of escalations for
# 9.5 hours with no escape. The detector below strips the box borders before
# deciding, so a bordered-but-empty composer is correctly seen as empty. The same
# corrected detector backs the submit acknowledgement (a submit "landed" iff the
# composer is empty afterward), fixing the parallel false "Enter swallowed".
#
# Ghost text (incident composer-robust): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text inside an otherwise-empty composer. A plain
# capture cannot tell it apart from text a human typed, so the old reader saw an
# idle pane as holding pending input and the daemon deferred injection / firstmate
# misjudged the pane. The composer reader now captures just the cursor line WITH
# ANSI styling (tmux capture-pane -e) and extracts the real typed content with the
# shared, fleet-wide fm_composer_strip_ghost (bin/fm-composer-lib.sh), which drops
# every de-emphasised run - dim/faint (SGR 2) AND a dark/muted truecolor
# foreground - so ghost/placeholder text never counts as real input. The styled
# capture is consumed internally and parsed into a boolean here; it is NEVER
# surfaced (fm-peek and every human/LLM-facing path stay plain), and only the
# single composer row is captured, so no escape-laden pane bulk is produced. This
# is harness-generic: any harness that de-emphasises placeholder/ghost text
# benefits, and the herdr adapter routes through the same owner (task
# afk-herdr-false-pending), so the two backends cannot drift.
#
# Busy-queued Enter (opencode 1.18.4, on the tmux backend only for now): when
# the agent is mid-turn, opencode accepts Enter as a "send when the turn ends"
# keystroke but does NOT clear the composer until then, so the composer keeps
# showing the typed text the whole time. The plain "empty iff composer cleared"
# acknowledgement above false-positives on a swallowed Enter for every steer
# sent to a busy opencode pane, and `fm-send` exits non-zero on a normal
# captain instruction. The submit core now falls back to `fm_pane_is_busy` once
# the Enter-retry budget is spent: a busy pane means the harness accepted and
# queued the Enter (report `empty` so the caller does not re-send), while an
# idle pane keeps the `pending` verdict (a genuine swallow). The herdr backend
# observes the same opencode behavior but needs a separate fix; it is recorded
# as a known gap in `docs/herdr-backend.md` rather than patched here, so the
# tmux adapter does not paper over a herdr-specific shape.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / the daemon).
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.
#
# Composer-content classification (empty|pending|unknown, and the fleet-wide
# rule that a BARE shell prompt glyph is a dead shell, not an empty agent
# composer) is NOT owned here: it is the shared bin/fm-composer-lib.sh, sourced
# below and reused by every backend adapter so the decision cannot drift.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-lib.sh"

# Busy footers per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel"
# (grok's mid-turn cancel hint, shown iff a turn is running - verified grok 0.2.73);
# cursor: "ctrl+c to stop" (verified 2026-07-19, Cursor CLI 2026.07.16-899851b).
# cursor's SPINNER VERB is deliberately NOT matched: it changes with the phase
# ("Working" while reasoning, "Running" during a tool call), so matching the verb
# reads a tool-executing pane as idle and trips premature stale detection. The
# footer hint is the phase-stable, ASCII, locale-safe signal, and it is absent
# when idle.
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel|ctrl\+c to stop'

# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# fm_tmux_composer_state: classify the cursor/composer line of <target> as
#   empty   - no pending input (blank, a busy footer, an empty agent composer, or
#             only de-emphasised ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the pane could not be read (tmux error), OR the cursor line is a
#             bare shell prompt (`$`/`%`/`#`/`>`) - a dead shell, not an agent
#             composer, so NOT a safe injection target. The caller decides.
#
# The cursor line is captured WITH ANSI styling (capture-pane -e) and bounded to
# the single composer row (-S/-E). The bordered flag (a genuine composer box) is
# read from the PLAIN row (fm_composer_strip_ansi keeps ghost text so the box
# border is still visible), while the real-typed CONTENT is extracted with the
# shared fm_composer_strip_ghost so dim/faint AND dark-truecolor ghost text drops
# out before classification (grok's dark box border drops with the ghost, which
# is why the bordered flag is read from the plain row, not the ghost-stripped
# one). Both are internal only, never surfaced. The detector strips the harness's
# box-drawing composer borders ("│ … │", heavy "┃", or a plain ASCII "|") using
# literal-string substitution (bash 3.2 safe, locale-independent - no \u escapes,
# no multibyte character classes), and delegates the empty/pending/unknown
# decision to the shared owner fm_composer_classify_content
# (bin/fm-composer-lib.sh). The bordered flag is what lets a bordered `│ > │`
# (claude's own idle composer) read empty while a bare, unbordered `$ ` dead-shell
# prompt reads unknown.
# fm_tmux_pane_is_cursor: 0 iff <target>'s foreground process is POSITIVELY
# identified as the Cursor CLI. Cursor's ~/.local/bin/agent wrapper execs a
# bundled Node app, so the pane COMM is a bare "node"; the versioned
# cursor-agent bundle path survives in argv (verified 2026-07-19, Cursor CLI
# 2026.07.16-899851b: `ps -o args=` shows .../cursor-agent/versions/<v>/index.js
# while pane_current_command reads "node"). This is the same marker
# fm_backend_tmux_agent_alive (bin/backends/tmux.sh) resolves liveness through.
# An unreadable pane or an unmatched argv is NOT cursor - identification fails
# toward the generic (non-cursor) path.
fm_tmux_pane_is_cursor() {  # <target>
  local target=$1 comm pid args
  comm=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || return 1
  comm=${comm#-}
  case "$comm" in node*) ;; *) return 1 ;; esac
  pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 1
  [ -n "$pid" ] || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case "$args" in *cursor-agent*) return 0 ;; esac
  return 1
}

# fm_tmux_cursor_composer_row: 0-indexed row of a cursor (Cursor CLI) composer,
# found STRUCTURALLY rather than through tmux's #{cursor_y}. Prints nothing when
# <target> is not a positively-identified cursor pane, or when the pane holds no
# cursor composer.
#
# WHY (verified 2026-07-19, Cursor CLI 2026.07.16-899851b, tmux 3.6a): cursor
# parks the terminal cursor in its bottom status area, NOT in the composer. A
# pane with "→ some real unsubmitted text" on row 15 reported #{cursor_y}=20 (the
# cwd/status row). Reading the cursor_y row therefore finds an EMPTY status line
# and classifies a composer holding real unsubmitted text as `empty` - a
# FALSE-EMPTY, which is the dangerous direction: bin/fm-supervise-daemon.sh reads
# emptiness to pick a safe injection target, so an away-mode escalation would be
# typed on top of text already sitting in the composer. This is the same
# cursor_y-row-selection class as the grok residual gap documented in the
# harness-adapters skill, but several rows off instead of one.
#
# cursor always draws its composer as a "→ " prefixed row (both the idle
# placeholder and real typed input), so the last such row is the composer. This
# mirrors the herdr adapter's structural composer scan, which is why herdr is
# unaffected by the same quirk.
#
# SCOPE: the scan runs ONLY on a pane fm_tmux_pane_is_cursor positively
# identifies. Other harnesses' OUTPUT may legitimately contain "→ "-prefixed
# lines (e.g. arrow bullets in a claude answer), and an unscoped scan would
# redirect classification from the real (empty) composer onto that output row -
# a false-pending that defers away-mode escalations and makes fm-send report a
# swallowed Enter. Every non-cursor or unidentifiable pane keeps the plain
# #{cursor_y} behaviour.
fm_tmux_cursor_composer_row() {  # <target>
  local target=$1 plain n
  fm_tmux_pane_is_cursor "$target" || return 0
  plain=$(tmux capture-pane -p -t "$target" 2>/dev/null) || return 0
  n=$(printf '%s\n' "$plain" | grep -nE '^[[:space:]]*→ ' | tail -1 | cut -d: -f1)
  [ -n "$n" ] || return 0
  printf '%s' "$((n - 1))"
}

fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cy raw plain stripped bordered=0 crow
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  # cursor's composer is not on the cursor_y row (see above): prefer its
  # structurally-located row. The scan is scoped to positively-identified
  # cursor panes, so every other harness keeps the cursor_y row untouched.
  crow=$(fm_tmux_cursor_composer_row "$target")
  [ -z "$crow" ] || cy=$crow
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) || { printf 'unknown'; return 0; }
  # bordered: from the plain row (borders survive an all-ANSI strip).
  plain=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  plain="${plain#"${plain%%[![:space:]]*}"}"
  plain="${plain%"${plain##*[![:space:]]}"}"
  case "$plain" in
    '│'*'│'|'┃'*'┃'|'|'*'|') bordered=1 ;;
  esac
  # content: from the ghost-stripped row (real typed text only).
  stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # A busy footer landing on the cursor line is not pending input (tmux-specific:
  # only tmux captures the raw cursor row, which may BE the footer).
  if [ -n "$stripped" ] \
     && printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  fm_composer_classify_content "$bordered" "$stripped" "${FM_COMPOSER_IDLE_RE:-$FM_COMPOSER_IDLE_RE_DEFAULT}" insensitive "$plain"
}

# fm_pane_input_pending: 0 (pending) if the cursor line holds real unsubmitted
# text, 1 otherwise. An unreadable pane is treated as NOT pending (fail-safe:
# the same bias the old daemon used — an unknown pane defers nothing here).
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_is_busy() {  # <target>
  local win=$1 tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown|send-failed) so callers can
# pick their own success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
# Busy-queued Enter (opencode 1.18.4): the harness accepts Enter while mid-turn
# and queues it for after the current turn, but keeps the typed text visible in
# the composer. Once the Enter-retry budget is spent and the composer still
# reads "pending", the submit core falls back to `fm_pane_is_busy`: a busy pane
# means the Enter was accepted and queued (report `empty` so the caller does
# not re-send), while an idle pane keeps `pending` as a genuine swallow. This
# is the only place that exception lives, so the daemon's strict and
# fm-send's lenient success policies both treat a busy-queued Enter as
# delivered.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || break
  done
  # Retries exhausted, composer still shows pending.
  # If the pane is busy (agent mid-turn), the harness accepted the Enter
  # and queued the message for processing when the current turn ends.
  # Treat it as submitted so the caller does not re-send.
  # On an idle pane, keep reporting pending - a genuine swallow.
  if fm_pane_is_busy "$target"; then
    printf 'empty'
  else
    printf 'pending'
  fi
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}
