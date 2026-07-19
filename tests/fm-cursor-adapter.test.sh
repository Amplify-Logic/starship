#!/usr/bin/env bash
# Cursor CLI (`agent`) worker-adapter regressions (task
# firstmate-cursor-agent-adapter-verify-c2).
#
# Every fixture here is a VERBATIM capture from the 2026-07-19 verification lab
# (Cursor CLI 2026.07.16-899851b, Cursor Grok 4.5, tmux 3.6a); the exact commands
# and raw output are recorded in docs/cursor-harness.md. These tests pin the four
# cursor-specific behaviours that shared monitoring would otherwise get wrong:
#
#   1. COMPOSER ROW SELECTION. cursor parks the terminal cursor in its bottom
#      status area, so tmux's #{cursor_y} does NOT point at the composer. Reading
#      the cursor_y row found an empty status line and classified a composer
#      holding real unsubmitted text as `empty` - a FALSE-EMPTY, the dangerous
#      direction, because the away-mode injector picks injection targets by
#      emptiness and would type over pending input. The structural scan that
#      fixes this is SCOPED to positively-identified cursor panes (node COMM +
#      cursor-agent argv): arrow-prefixed lines in another harness's OUTPUT must
#      never redirect classification off that pane's real composer row.
#   2. IDLE PLACEHOLDER. cursor draws the terminal cursor as a REVERSE-VIDEO cell
#      (SGR 7) over the placeholder's FIRST character. Reverse video is neither
#      dim/faint nor a dark foreground, so fm_composer_strip_ghost keeps that one
#      bright char and an idle composer reduced to a lone "A" -> `pending`, which
#      would defer every away-mode escalation forever.
#   3. BUSY SIGNATURE. cursor's spinner VERB changes mid-turn ("Working" while
#      reasoning, "Running" during a tool call), so only the phase-stable footer
#      hint "ctrl+c to stop" is a safe busy marker.
#   4. EFFORT AXIS. cursor has no effort flag - reasoning effort is a SUFFIX on
#      the model id - so the effort axis folds into the model instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-tests)

ESC=$(printf '\033')

# The VERBATIM styled composer row captured from an idle cursor pane. Note the
# ESC[0;7m (reverse video) on the "A" of "Add a follow-up" - that is the terminal
# cursor cell, and it is what survives ghost-stripping.
CURSOR_IDLE_ROW="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0;7m${ESC}[48;2;21;21;21mA${ESC}[0;2m${ESC}[48;2;21;21;21mdd a follow-up${ESC}[0m${ESC}[48;2;21;21;21m   ${ESC}[49m"

# A fake tmux serving a MULTI-ROW pane, so the structural composer scan is
# exercised the way the real adapter uses it. FM_FAKE_PANE holds the whole pane;
# capture-pane honours -S/-E for a single row, and #{cursor_y} is FM_FAKE_CY.
# A companion fake ps prints FM_FAKE_ARGS, so the pane's harness identity
# (fm_tmux_pane_is_cursor: node COMM + cursor-agent argv) is test-controlled.
make_fake_tmux() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '%s\n' "${FM_FAKE_CY:-0}"; exit 0 ;;
        *pane_pid*) printf '%s\n' "${FM_FAKE_PID:-4242}"; exit 0 ;;
        *pane_current_command*) printf '%s\n' "${FM_FAKE_COMM:-node}"; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    has_e=0; s=""; e=""
    prev=""
    for a in "$@"; do
      [ "$a" = "-e" ] && has_e=1
      case "$prev" in -S) s=$a ;; -E) e=$a ;; esac
      prev=$a
    done
    f="${FM_FAKE_PANE:-/dev/null}"
    out=$(cat "$f" 2>/dev/null)
    if [ -n "$s" ] && [ -n "$e" ]; then
      out=$(printf '%s\n' "$out" | sed -n "$((s + 1)),$((e + 1))p")
    fi
    if [ "$has_e" = 1 ]; then
      printf '%s\n' "$out"
    else
      printf '%s\n' "$out" | LC_ALL=C awk '{gsub(/\033\[[0-9;:]*[a-zA-Z]/, ""); print}'
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_ARGS:-}"
SH
  chmod +x "$fb/ps"
  printf '%s\n' "$fb"
}

# The verbatim argv the real cursor wrapper leaves behind (exec -a rewrites
# argv[0], the versioned index.js path survives) - what marks a pane as cursor.
CURSOR_ARGS="/Users/x/.local/bin/agent --use-system-ca /Users/x/.local/share/cursor-agent/versions/2026.07.16-899851b/index.js --yolo"

# Build a realistic cursor pane: chrome, a completed turn, the composer row at
# index 5, then the two bottom status rows the terminal cursor actually sits on.
make_cursor_pane() {  # <file> <composer-row>
  local file=$1 composer=$2
  {
    printf '  Cursor Agent\n'
    printf '  v2026.07.16-899851b\n'
    printf '\n'
    printf '  Reply with exactly READY and nothing else.\n'
    printf '\n'
    printf '%s\n' "$composer"
    printf '\n'
    printf '  Cursor Grok 4.5 Low · 7%%                    Run Everything\n'
    printf '  /tmp/lab1 · main\n'
  } > "$file"
}

# --- 1. composer row selection ----------------------------------------------

test_composer_row_found_structurally_not_by_cursor_y() {
  local d fb pane
  d="$TMP_ROOT/rowsel"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  pane="$d/pane.txt"
  make_cursor_pane "$pane" "$CURSOR_IDLE_ROW"
  # cursor_y=8 is the cwd/status row, exactly as the real CLI reports it.
  PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=8 FM_FAKE_ARGS="$CURSOR_ARGS" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_cursor_composer_row t" > "$d/row" 2>/dev/null
  [ "$(cat "$d/row")" = "5" ] || fail "structural scan did not find composer row 5: '$(cat "$d/row")'"
  pass "cursor composer row is located structurally, not from #{cursor_y}"
}

test_real_typed_text_is_pending_despite_wrong_cursor_y() {
  local d fb pane out
  d="$TMP_ROOT/typed"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  pane="$d/pane.txt"
  # A composer holding genuine unsubmitted input.
  make_cursor_pane "$pane" " ${ESC}[2m→ ${ESC}[0msome real unsubmitted text"
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=8 FM_FAKE_ARGS="$CURSOR_ARGS" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_composer_state t" 2>/dev/null)
  # The regression: reading the cursor_y row (empty status line) returned `empty`
  # and the away-mode injector would have typed over this text.
  [ "$out" = pending ] || fail "real typed cursor input classified '$out', expected pending"
  pass "real unsubmitted cursor input is pending, not falsely empty"
}

# A claude-shaped pane: arrow-prefixed bullets in the model's OUTPUT above an
# EMPTY bare-glyph composer sitting on the cursor_y row (index 4).
make_claude_pane() {  # <file>
  local file=$1
  {
    printf '  I will proceed in two steps:\n'
    printf '   → first step\n'
    printf '   → second step\n'
    printf '\n'
    printf ' ❯ \n'
    printf '\n'
  } > "$file"
}

test_noncursor_pane_arrow_output_is_not_hijacked() {
  local d fb pane out
  d="$TMP_ROOT/nonhijack"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  pane="$d/pane.txt"
  make_claude_pane "$pane"
  # The regression class: an unscoped structural scan selected the last "→ "
  # OUTPUT line and classified this idle claude pane `pending`, deferring
  # away-mode escalations. A claude COMM must keep the cursor_y row.
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=4 FM_FAKE_COMM=claude \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_composer_state t" 2>/dev/null)
  [ "$out" = empty ] || fail "claude pane with arrow-bulleted output classified '$out', expected empty"
  # An UNATTRIBUTABLE bare node (pi-like) must also keep the cursor_y row: the
  # scan runs only on a POSITIVE cursor identification, never by default.
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=4 FM_FAKE_COMM=node \
    FM_FAKE_ARGS="/usr/bin/node /opt/somewhere/index.js" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_composer_state t" 2>/dev/null)
  [ "$out" = empty ] || fail "unattributable node pane classified '$out', expected empty"
  pass "arrow-prefixed output on a non-cursor pane cannot hijack the composer row"
}

test_noncursor_pane_submit_verdict_is_not_false_pending() {
  local d fb pane out
  d="$TMP_ROOT/nonhijack-submit"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  pane="$d/pane.txt"
  make_claude_pane "$pane"
  # The fm-send consequence of the same hijack: a false `pending` verdict from
  # fm_tmux_submit_enter_core reads as a swallowed Enter and fails the steer.
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=4 FM_FAKE_COMM=claude \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_submit_enter_core t 2 0.01" 2>/dev/null)
  [ "$out" = empty ] || fail "submit verdict on a claude pane with arrow output was '$out', expected empty"
  pass "a non-cursor pane with arrow output cannot produce a false pending swallow verdict"
}

# --- 2. idle placeholder / reverse-video cursor cell -------------------------

test_reverse_video_cursor_cell_survives_ghost_strip() {
  local out
  out=$(printf '%s\n' "$CURSOR_IDLE_ROW" | fm_composer_strip_ghost \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # Pins the ROOT CAUSE: the reverse-video cell is not de-emphasised, so exactly
  # one bright character remains. If a future strip drops reverse video too, this
  # test tells the next reader why the plain-row idle match exists.
  [ "$out" = "A" ] || fail "expected lone reverse-video 'A' to survive strip, got '$out'"
  pass "reverse-video cursor cell survives ghost-strip (root cause pinned)"
}

test_idle_placeholder_reads_empty() {
  local d fb pane out
  d="$TMP_ROOT/idle"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  pane="$d/pane.txt"
  make_cursor_pane "$pane" "$CURSOR_IDLE_ROW"
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=8 FM_FAKE_ARGS="$CURSOR_ARGS" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_composer_state t" 2>/dev/null)
  [ "$out" = empty ] || fail "idle cursor composer classified '$out', expected empty"
  pass "idle cursor composer ('Add a follow-up') reads empty"
}

test_fresh_session_placeholder_reads_empty() {
  local out
  # The other placeholder variant, shown before the first turn.
  out=$(fm_composer_classify_content 0 "P" "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive \
        "→ Plan, search, build anything")
  [ "$out" = empty ] || fail "fresh-session placeholder classified '$out', expected empty"
  pass "fresh-session cursor placeholder reads empty"
}

test_idle_regex_does_not_swallow_real_text() {
  local out
  for txt in "/no-mistakes" "hello world" "Add a follow-up to the PR description"; do
    out=$(fm_composer_classify_content 0 "$txt" "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive "→ $txt")
    [ "$out" = pending ] || fail "real text '$txt' classified '$out', expected pending"
  done
  pass "cursor idle regex is anchored: real text stays pending"
}

test_grok_placeholder_still_empty() {
  local out
  # The shared default must not regress the harness it already covered.
  out=$(fm_composer_classify_content 1 "Type a message..." "$FM_COMPOSER_IDLE_RE_DEFAULT" \
        insensitive "Type a message...")
  [ "$out" = empty ] || fail "grok placeholder classified '$out', expected empty"
  pass "shared idle default still covers grok's placeholder"
}

# --- 3. busy signature ------------------------------------------------------

test_busy_regex_matches_footer_not_spinner_verb() {
  # Verbatim busy footer, and the two spinner verbs seen in one turn.
  printf '  → Add a follow-up                    ctrl+c to stop\n' \
    | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    || fail "busy footer 'ctrl+c to stop' did not match the busy regex"
  # The verb alone must NOT be the signal: matching it would read a
  # tool-executing pane as idle when the verb flips Working -> Running.
  printf '⠠⠛ Running  67 tokens\n' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    && fail "spinner verb 'Running' must not be the busy signal on its own"
  # An idle cursor footer must not match.
  printf '  Cursor Grok 4.5 Low · 7%%            Run Everything\n' \
    | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    && fail "idle cursor status line matched the busy regex"
  pass "cursor busy signature is the stable footer hint, not the spinner verb"
}

test_watch_and_tmux_busy_regexes_agree() {
  local watch_re
  watch_re=$(grep -m1 '^BUSY_REGEX=' "$ROOT/bin/fm-watch.sh")
  case "$watch_re" in
    *'ctrl\+c to stop'*) : ;;
    *) fail "bin/fm-watch.sh BUSY_REGEX is missing cursor's footer: $watch_re" ;;
  esac
  case "$FM_TMUX_BUSY_REGEX_DEFAULT" in
    *'ctrl\+c to stop'*) : ;;
    *) fail "FM_TMUX_BUSY_REGEX_DEFAULT is missing cursor's footer" ;;
  esac
  pass "fm-watch.sh and fm-tmux-lib.sh busy signatures both carry cursor"
}

# --- 4. launch flags and the effort-in-model axis ---------------------------

test_launch_template_flags() {
  local tpl
  tpl=$(grep -m1 "^    cursor) printf" "$ROOT/bin/fm-spawn.sh")
  case "$tpl" in *'--yolo'*) : ;; *) fail "cursor launch template lacks --yolo autonomy: $tpl" ;; esac
  case "$tpl" in *'--workspace __WORKTREE__'*) : ;; *) fail "cursor launch template lacks --workspace pin: $tpl" ;; esac
  # The safety-critical negative: -w/--worktree would let cursor allocate a
  # SECOND worktree alongside firstmate's own isolated copy.
  case "$tpl" in *' -w '*|*'--worktree'*) fail "cursor launch template must not request a cursor worktree: $tpl" ;; esac
  # cursor has no effort flag; an __EFFORTFLAG__ here would render empty and
  # silently drop the axis instead of folding it into the model id.
  case "$tpl" in *'__EFFORTFLAG__'*) fail "cursor template must not use __EFFORTFLAG__: $tpl" ;; esac
  pass "cursor launch template: --yolo, pinned --workspace, no cursor worktree"
}

# cursor_model_with_effort lives in fm-spawn.sh, which is a script rather than a
# sourceable library, so extract just that function to exercise it directly.
run_model_with_effort() {  # <model> <effort>
  sed -n '/^cursor_model_with_effort() {/,/^}/p' "$ROOT/bin/fm-spawn.sh" \
    > "$TMP_ROOT/mwe.sh"
  bash -c ". '$TMP_ROOT/mwe.sh'; cursor_model_with_effort '$1' '$2'"
}

test_effort_folds_into_model_id() {
  local out
  out=$(run_model_with_effort cursor-grok-4.5 low)
  [ "$out" = "cursor-grok-4.5-low" ] || fail "low did not fold into model id: '$out'"
  out=$(run_model_with_effort cursor-grok-4.5 medium)
  [ "$out" = "cursor-grok-4.5-medium" ] || fail "medium did not fold into model id: '$out'"
  out=$(run_model_with_effort cursor-grok-4.5 high)
  [ "$out" = "cursor-grok-4.5-high" ] || fail "high did not fold into model id: '$out'"
  pass "cursor effort axis folds into the model id (low/medium/high)"
}

test_effort_above_ceiling_caps_at_high() {
  local out
  # cursor exposes no xhigh/max tier; the harness-adapters fallback caps at the
  # highest supported non-max level rather than dropping the intent silently.
  for e in xhigh max; do
    out=$(run_model_with_effort cursor-grok-4.5 "$e")
    [ "$out" = "cursor-grok-4.5-high" ] || fail "effort '$e' did not cap at high: '$out'"
  done
  pass "cursor caps xhigh/max at its highest real tier (high)"
}

test_explicit_tiered_model_is_never_retiered() {
  local out
  # A captain naming an exact model id wins over the effort axis.
  out=$(run_model_with_effort cursor-grok-4.5-high low)
  [ "$out" = "cursor-grok-4.5-high" ] || fail "explicit tiered model was retiered: '$out'"
  out=$(run_model_with_effort cursor-grok-4.5-medium-fast high)
  [ "$out" = "cursor-grok-4.5-medium-fast" ] || fail "explicit fast variant was retiered: '$out'"
  pass "an explicit tiered/fast cursor model id is never silently retiered"
}

test_fast_variant_is_never_implicit() {
  local out
  # Fast is a separate cost/speed choice: the effort axis must never select it.
  for e in low medium high xhigh max; do
    out=$(run_model_with_effort cursor-grok-4.5 "$e")
    case "$out" in *-fast) fail "effort '$e' implicitly selected a fast variant: '$out'" ;; esac
  done
  pass "cursor fast variants are never selected implicitly by the effort axis"
}

# --- 5. liveness ------------------------------------------------------------

test_liveness_uses_argv_for_node_comm() {
  local d fb out
  d="$TMP_ROOT/live"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  # Fake ps (from make_fake_tmux): argv carries the versioned cursor-agent
  # bundle path, exactly as the real wrapper leaves it.
  out=$(PATH="$fb:$PATH" FM_FAKE_COMM=node FM_FAKE_ARGS="$CURSOR_ARGS" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; . '$ROOT/bin/backends/tmux.sh'; fm_backend_tmux_agent_alive t" 2>/dev/null)
  [ "$out" = alive ] || fail "cursor pane (node comm + cursor-agent argv) classified '$out', expected alive"
  pass "cursor liveness resolves through argv when COMM is a bare node"
}

test_unattributable_node_stays_unknown() {
  local d fb out
  d="$TMP_ROOT/live2"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  # pi's generic node: still unknown, and NEVER inferred dead (a wrong `dead`
  # would let the secondmate-liveness sweep respawn over a live agent).
  out=$(PATH="$fb:$PATH" FM_FAKE_COMM=node FM_FAKE_ARGS="/usr/bin/node /opt/somewhere/index.js" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; . '$ROOT/bin/backends/tmux.sh'; fm_backend_tmux_agent_alive t" 2>/dev/null)
  [ "$out" = unknown ] || fail "unattributable node classified '$out', expected unknown"
  pass "a non-cursor bare node stays unknown, never dead"
}

# --- 6. harness detection ---------------------------------------------------

test_cursor_env_marker_beats_inherited_claudecode() {
  local out
  # cursor does not clear an INHERITED CLAUDECODE=1, so a cursor worker spawned
  # from a claude-hosted firstmate carries both markers. CURSOR_AGENT must win,
  # or that pane is steered with claude's interrupt/exit/resume vocabulary.
  out=$(CURSOR_AGENT=1 CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 with inherited CLAUDECODE=1 detected '$out', expected cursor"
  pass "CURSOR_AGENT=1 outranks an inherited CLAUDECODE=1"
}

test_claude_detection_unregressed() {
  local out
  out=$(CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "claude detection regressed: '$out'"
  pass "claude detection is unchanged when CURSOR_AGENT is absent"
}

# --- 7. turn-end hook shape -------------------------------------------------

test_spawn_installs_cursor_stop_hook() {
  local blk
  blk=$(sed -n '/^    cursor\*)/,/^      ;;/p' "$ROOT/bin/fm-spawn.sh")
  case "$blk" in *'.cursor/hooks.json'*) : ;; *) fail "cursor spawn does not write .cursor/hooks.json" ;; esac
  case "$blk" in *'"stop"'*) : ;; *) fail "cursor hook does not register the stop event" ;; esac
  case "$blk" in *'exclude_path'*) : ;; *) fail "cursor hook file is not kept out of git's view" ;; esac
  pass "cursor spawn installs a gitignored per-task stop hook"
}

test_composer_ghost_suite_still_passes() {
  # The shared owner changed (idle regex is now matched against the plain row
  # too), so the pre-existing ghost suite is the cross-check that no other
  # harness regressed.
  bash "$ROOT/tests/fm-composer-ghost.test.sh" >/dev/null 2>&1 \
    || fail "tests/fm-composer-ghost.test.sh regressed"
  pass "pre-existing composer ghost suite still passes"
}

test_composer_row_found_structurally_not_by_cursor_y
test_real_typed_text_is_pending_despite_wrong_cursor_y
test_noncursor_pane_arrow_output_is_not_hijacked
test_noncursor_pane_submit_verdict_is_not_false_pending
test_reverse_video_cursor_cell_survives_ghost_strip
test_idle_placeholder_reads_empty
test_fresh_session_placeholder_reads_empty
test_idle_regex_does_not_swallow_real_text
test_grok_placeholder_still_empty
test_busy_regex_matches_footer_not_spinner_verb
test_watch_and_tmux_busy_regexes_agree
test_launch_template_flags
test_effort_folds_into_model_id
test_effort_above_ceiling_caps_at_high
test_explicit_tiered_model_is_never_retiered
test_fast_variant_is_never_implicit
test_liveness_uses_argv_for_node_comm
test_unattributable_node_stays_unknown
test_cursor_env_marker_beats_inherited_claudecode
test_claude_detection_unregressed
test_spawn_installs_cursor_stop_hook
test_composer_ghost_suite_still_passes
