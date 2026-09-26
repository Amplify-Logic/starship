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
        *pane_tty*) printf '%s\n' "${FM_FAKE_TTY:-/dev/ttyfake}"; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  list-windows)
    printf '%s\n' "${FM_FAKE_WINDOW:-cur}"; exit 0 ;;
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
    # `-E -` means "to the last line", which is how the real capture asks for
    # the whole visible pane.
    if [ -n "$s" ] && [ "$e" = "-" ]; then
      out=$(printf '%s\n' "$out" | sed -n "$((s + 1)),\$p")
    elif [ -n "$s" ] && [ -n "$e" ]; then
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
# The two reads the shared foreground-process-group probe makes:
# `ps -t <tty> -o pid=,pgid=,tpgid=,comm=` lists the tty's processes (the single
# fake entry is a foreground one, pgid = tpgid, with FM_FAKE_COMM as its COMM),
# and `ps -p <pid> -o args=` answers that process's argv from FM_FAKE_ARGS.
for a in "$@"; do
  case "$a" in
    -t) printf '%s %s %s %s\n' "${FM_FAKE_PID:-4242}" 900 900 "${FM_FAKE_COMM:-node}"; exit 0 ;;
  esac
done
printf '%s\n' "${FM_FAKE_ARGS:-}"
SH
  chmod +x "$fb/ps"
  printf '%s\n' "$fb"
}

# The verbatim argv the real cursor wrapper leaves behind - what marks a pane
# as cursor. The launcher on PATH is a symlink into the versioned install tree
# (verified: ~/.local/bin/agent -> .../cursor-agent/versions/<v>/cursor-agent),
# and the identity owner canonicalizes argv[0] before matching, so argv[0] is
# spelled here already resolved rather than through the launcher alias.
CURSOR_ARGS="/Users/x/.local/share/cursor-agent/versions/2026.07.16-899851b/cursor-agent --use-system-ca /Users/x/.local/share/cursor-agent/versions/2026.07.16-899851b/index.js --yolo"

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
  local d fb pane out
  d="$TMP_ROOT/rowsel"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  pane="$d/pane.txt"
  # cursor_y=8 is the cwd/status row, exactly as the real CLI reports it, while
  # the composer is row 5. The guarantee is that the verdict comes from the
  # structurally located composer and never from the cursor row: with the SAME
  # wrong cursor row, an idle composer must read empty and a composer holding
  # text must read pending, which no reading of row 8 can produce.
  make_cursor_pane "$pane" "$CURSOR_IDLE_ROW"
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=8 FM_FAKE_ARGS="$CURSOR_ARGS" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_composer_state t" 2>/dev/null)
  [ "$out" = empty ] || fail "idle cursor composer under a wrong cursor row classified '$out', expected empty"
  make_cursor_pane "$pane" " ${ESC}[2m→ ${ESC}[0mrow five is the composer"
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=8 FM_FAKE_ARGS="$CURSOR_ARGS" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_composer_state t" 2>/dev/null)
  [ "$out" = pending ] || fail "text on the cursor composer row classified '$out', expected pending"
  pass "cursor composer verdict comes from the structural composer row, not #{cursor_y}"
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
  # The shared default must not regress the harness it already covered. grok
  # draws its placeholder at the prompt row of a bordered box, which is the
  # proven placeholder position a plain read is allowed to call empty.
  out=$(fm_composer_classify_content 1 "Type a message..." "$FM_COMPOSER_IDLE_RE_DEFAULT" \
        insensitive "Type a message..." 1 0)
  [ "$out" = empty ] || fail "grok placeholder classified '$out', expected empty"
  pass "shared idle default still covers grok's placeholder"
}

# --- 3. busy signature ------------------------------------------------------

# The busy signature is a DELIVERY guard: it acknowledges a submit and gates
# away-mode injection. Cursor's recorded worker state comes from its own
# conversation-transcript fold (bin/fm-busy-lib.sh), never from this row.
busy_row_matches() {  # <row> [harness]
  printf '%s\0' "$1" | fm_busy_lines_match "${2:-}"
}

test_busy_signature_is_the_footer_not_the_spinner_verb() {
  # Verbatim busy footer, and the two spinner verbs seen in one turn.
  busy_row_matches '  → Add a follow-up                    ctrl+c to stop' cursor \
    || fail "busy footer 'ctrl+c to stop' is not cursor's busy signature"
  # The verb alone must NOT be the signal: matching it would read a
  # tool-executing pane as idle when the verb flips Working -> Running.
  busy_row_matches '⠠⠛ Running  67 tokens' cursor \
    && fail "spinner verb 'Running' must not be the busy signal on its own"
  # An idle cursor footer must not match.
  busy_row_matches '  Cursor Grok 4.5 Low · 7%            Run Everything' cursor \
    && fail "idle cursor status line matched cursor's busy signature"
  pass "cursor busy signature is the stable footer hint, not the spinner verb"
}

test_harnessless_union_still_carries_the_cursor_footer() {
  # A pane reached with no recorded harness reads the union of every harness
  # signature. Cursor has to be in it: cursor parks its terminal cursor outside
  # its composer, so the composer verdict is always unknown and this footer is
  # the only turn-started acknowledgement that path can read.
  busy_row_matches '  → Add a follow-up                    ctrl+c to stop' \
    || fail "the harness-less busy union is missing cursor's footer"
  pass "the harness-less busy union still carries cursor's footer"
}

# --- 4. launch flags and the effort-in-model axis ---------------------------

test_launch_template_flags() {
  local tpl
  # Read the arm from launch_template() itself, whatever its indentation, so an
  # install hint or another case arm with the same label cannot stand in for it.
  tpl=$(awk '/^launch_template\(\) \{/ { f = 1 } f && /^\}/ { f = 0 } f' "$ROOT/bin/fm-spawn.sh" \
    | grep -m1 -E "^ +cursor\) printf")
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
# sourceable library, so extract it (and the catalog probe it calls) to exercise
# them directly.
#
# The catalog is ALWAYS pinned to a fixture path so the tier ladder is decided by
# the fixture rather than by whichever Cursor build the test machine has
# installed. A path that does not exist is the deterministic "catalog
# unavailable" case: fm_cursor_list_models_text returns non-zero without ever
# shelling out to `agent`.
CATALOG_45="" CATALOG_46=""

run_model_with_effort() {  # <model> <effort> <catalog-file>
  { sed -n '/^cursor_model_tier_offered() {/,/^}/p' "$ROOT/bin/fm-spawn.sh"
    sed -n '/^cursor_model_with_effort() {/,/^}/p' "$ROOT/bin/fm-spawn.sh"
  } > "$TMP_ROOT/mwe.sh"
  FM_CURSOR_MODEL_CATALOG="$3" bash -c \
    ". '$ROOT/bin/fm-cursor-model-lib.sh'; . '$TMP_ROOT/mwe.sh'; cursor_model_with_effort '$1' '$2'"
}

# Grok 4.5: the ladder verified 2026-07-19, which stops at -high.
write_catalog_45() {
  CATALOG_45="$TMP_ROOT/catalog-4.5.txt"
  cat > "$CATALOG_45" <<'EOF'
Available models
cursor-grok-4.5-low - Cursor Grok 4.5 Low
cursor-grok-4.5-medium - Cursor Grok 4.5 Medium
cursor-grok-4.5-high - Cursor Grok 4.5
cursor-grok-4.5-high-fast - Cursor Grok 4.5 Fast
EOF
}

# Grok 4.6: verbatim ids from `agent --list-models` on Cursor CLI
# 2026.08.11-e8db854 (2026-08-13), which DO include an -xhigh tier.
write_catalog_46() {
  CATALOG_46="$TMP_ROOT/catalog-4.6.txt"
  cat > "$CATALOG_46" <<'EOF'
Available models
cursor-grok-4.6-low - Cursor Grok 4.6 Low
cursor-grok-4.6-low-fast - Cursor Grok 4.6 Low Fast
cursor-grok-4.6-medium - Cursor Grok 4.6 Medium
cursor-grok-4.6-medium-fast - Cursor Grok 4.6 Medium Fast
cursor-grok-4.6-high - Cursor Grok 4.6
cursor-grok-4.6-high-fast - Cursor Grok 4.6 Fast
cursor-grok-4.6-xhigh - Cursor Grok 4.6 Extra High
cursor-grok-4.6-xhigh-fast - Cursor Grok 4.6 Extra High Fast
EOF
}

test_effort_folds_into_model_id() {
  local out
  out=$(run_model_with_effort cursor-grok-4.5 low "$CATALOG_45")
  [ "$out" = "cursor-grok-4.5-low" ] || fail "low did not fold into model id: '$out'"
  out=$(run_model_with_effort cursor-grok-4.5 medium "$CATALOG_45")
  [ "$out" = "cursor-grok-4.5-medium" ] || fail "medium did not fold into model id: '$out'"
  out=$(run_model_with_effort cursor-grok-4.5 high "$CATALOG_45")
  [ "$out" = "cursor-grok-4.5-high" ] || fail "high did not fold into model id: '$out'"
  pass "cursor effort axis folds into the model id (low/medium/high)"
}

test_effort_above_ceiling_caps_at_high() {
  local out
  # Grok 4.5 has no xhigh tier, so the harness-adapters fallback caps at the
  # highest tier that model really has rather than dropping the intent silently.
  for e in xhigh max; do
    out=$(run_model_with_effort cursor-grok-4.5 "$e" "$CATALOG_45")
    [ "$out" = "cursor-grok-4.5-high" ] || fail "effort '$e' did not cap at high on a 4.5 catalog: '$out'"
  done
  # An unreadable catalog takes the same conservative floor: -high is the tier
  # every verified cursor model has, so it can never be a fabricated id.
  for e in xhigh max; do
    out=$(run_model_with_effort cursor-grok-4.6 "$e" "$TMP_ROOT/no-such-catalog.txt")
    [ "$out" = "cursor-grok-4.6-high" ] || fail "effort '$e' without a catalog did not fall back to high: '$out'"
  done
  pass "cursor caps xhigh/max at high when the model (or the catalog) offers no xhigh"
}

test_effort_uses_xhigh_when_the_model_offers_it() {
  local out
  # Grok 4.6 (2026-08-12) added -xhigh, so capping it at -high would silently
  # under-tier every xhigh/max request against a model that can serve it.
  for e in xhigh max; do
    out=$(run_model_with_effort cursor-grok-4.6 "$e" "$CATALOG_46")
    [ "$out" = "cursor-grok-4.6-xhigh" ] || fail "effort '$e' did not reach the real xhigh tier: '$out'"
  done
  # The lower tiers are unaffected by the ladder being longer.
  out=$(run_model_with_effort cursor-grok-4.6 high "$CATALOG_46")
  [ "$out" = "cursor-grok-4.6-high" ] || fail "high must stay high on a model with xhigh: '$out'"
  pass "cursor xhigh/max resolve to a real -xhigh tier when the model has one"
}

test_explicit_tiered_model_is_never_retiered() {
  local out
  # A captain naming an exact model id wins over the effort axis.
  out=$(run_model_with_effort cursor-grok-4.5-high low "$CATALOG_45")
  [ "$out" = "cursor-grok-4.5-high" ] || fail "explicit tiered model was retiered: '$out'"
  out=$(run_model_with_effort cursor-grok-4.5-medium-fast high "$CATALOG_45")
  [ "$out" = "cursor-grok-4.5-medium-fast" ] || fail "explicit fast variant was retiered: '$out'"
  # -xhigh does NOT end in -high, so it needs its own passthrough: without one
  # an explicit xhigh id became "cursor-grok-4.6-xhigh-high", an id no catalog
  # lists, and the spawn preflight refused the task outright.
  out=$(run_model_with_effort cursor-grok-4.6-xhigh high "$CATALOG_46")
  [ "$out" = "cursor-grok-4.6-xhigh" ] || fail "explicit xhigh model was retiered: '$out'"
  out=$(run_model_with_effort cursor-grok-4.6-xhigh-fast low "$CATALOG_46")
  [ "$out" = "cursor-grok-4.6-xhigh-fast" ] || fail "explicit xhigh fast variant was retiered: '$out'"
  pass "an explicit tiered/fast cursor model id is never silently retiered"
}

test_fast_variant_is_never_implicit() {
  local out
  # Fast is a separate cost/speed choice: the effort axis must never select it.
  for e in low medium high xhigh max; do
    out=$(run_model_with_effort cursor-grok-4.5 "$e" "$CATALOG_45")
    case "$out" in *-fast) fail "effort '$e' implicitly selected a fast variant: '$out'" ;; esac
    out=$(run_model_with_effort cursor-grok-4.6 "$e" "$CATALOG_46")
    case "$out" in *-fast) fail "effort '$e' implicitly selected a fast variant: '$out'" ;; esac
  done
  pass "cursor fast variants are never selected implicitly by the effort axis"
}

# --- 4b. live footer model identity (model-label-truth) ---------------------

# shellcheck source=bin/fm-cursor-model-lib.sh
. "$ROOT/bin/fm-cursor-model-lib.sh"

test_parse_footer_model_from_idle_capture() {
  local out
  out=$(fm_cursor_parse_footer_model "$(printf 'READY1\n\n  → Add a follow-up\n\n  Cursor Grok 4.5 Medium Fast · 7%%                                   Run Everything\n')")
  [ "$out" = 'Cursor Grok 4.5 Medium Fast' ] \
    || fail "idle footer model parse failed: '$out'"
  out=$(fm_cursor_parse_footer_model "$(printf '  → Add a follow-up                                          ctrl+c to stop\n')")
  [ -z "$out" ] || fail "busy footer must not invent a model, got '$out'"
  pass "cursor footer parser reads idle model labels and ignores busy panes"
}

test_catalog_has_model_and_equivalence() {
  local catalog
  catalog="$TMP_ROOT/models.txt"
  cat > "$catalog" <<'EOF'
Available models
cursor-grok-4.5-medium-fast - Cursor Grok 4.5 Medium Fast
gpt-5.6-sol-xhigh - GPT-5.6 Sol 1M Extra High
EOF
  FM_CURSOR_MODEL_CATALOG="$catalog" fm_fork_cursor_catalog_has_model gpt-5.6-sol-xhigh \
    || fail "known catalog id should match"
  if FM_CURSOR_MODEL_CATALOG="$catalog" fm_fork_cursor_catalog_has_model definitely-not-a-real-model-xyz; then
    fail "unknown catalog id must not match"
  fi
  FM_CURSOR_MODEL_CATALOG="$catalog" fm_cursor_models_equivalent \
    cursor-grok-4.5-medium-fast 'Cursor Grok 4.5 Medium Fast' \
    || fail "id and matching footer display should be equivalent"
  if FM_CURSOR_MODEL_CATALOG="$catalog" fm_cursor_models_equivalent \
    gpt-5.6-sol-xhigh 'Cursor Grok 4.5 Medium Fast'; then
    fail "sol-xhigh must not be equivalent to a Grok footer (atelier mismatch shape)"
  fi
  pass "cursor catalog membership and requested-vs-live equivalence"
}

test_catalog_has_model_through_ansi_color() {
  local catalog out
  catalog="$TMP_ROOT/models-ansi.txt"
  # Verbatim CSI from Cursor CLI 2026.08.25-3e8eec8 `agent --list-models`
  # (FORCE_COLOR=1, 2026-08-28): cyan id, then dim " - display". The dim SGR
  # sits between the space and the dash, so a literal ` - ` split misses the id
  # unless CSI is stripped first. A plain sibling line pins that unstyled
  # catalogs keep working in the same file.
  {
    printf '%s\n' "${ESC}[2mAvailable models${ESC}[22m"
    printf '\n'
    printf '%s\n' "${ESC}[36mcursor-grok-4.6-high-fast${ESC}[39m ${ESC}[2m- Cursor Grok 4.6 Fast${ESC}[22m"
    printf '%s\n' "cursor-grok-4.6-high - Cursor Grok 4.6"
  } > "$catalog"
  FM_CURSOR_MODEL_CATALOG="$catalog" fm_fork_cursor_catalog_has_model cursor-grok-4.6-high-fast \
    || fail "ANSI-colored catalog id should match after CSI strip"
  FM_CURSOR_MODEL_CATALOG="$catalog" fm_fork_cursor_catalog_has_model cursor-grok-4.6-high \
    || fail "plain catalog id in a mixed ANSI file should still match"
  if FM_CURSOR_MODEL_CATALOG="$catalog" fm_fork_cursor_catalog_has_model definitely-not-a-real-model-xyz; then
    fail "unknown id must still miss on an ANSI-colored catalog"
  fi
  out=$(FM_CURSOR_MODEL_CATALOG="$catalog" fm_cursor_catalog_display_for_id cursor-grok-4.6-high-fast)
  [ "$out" = 'Cursor Grok 4.6 Fast' ] \
    || fail "ANSI-colored catalog display lookup failed: '$out'"
  pass "cursor catalog parser matches ids through ANSI-colored --list-models lines"
}

# The catalog probe must read the executable the spawn resolved and will launch,
# not whatever `agent` happens to sit on PATH. Cursor's user-local install is
# routinely absent from a non-interactive login PATH, and a probe that misses it
# reports "catalog unavailable", which silently degrades the effort tier.
#
# Each case runs in its own process so it gets its own catalog cache and its own
# HOME/PATH, the way a spawn does.
write_fake_cursor_agent() {  # <path>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --list-models ] || exit 1
printf 'Available models\ncursor-grok-4.6-high - Cursor Grok 4.6\ncursor-grok-4.6-xhigh - Cursor Grok 4.6 Extra High\n'
EOF
  chmod +x "$1"
}

probe_catalog_has_model() {  # <model-id> <bin-arg> <home> <path> [probe-timeout]
  cat > "$TMP_ROOT/catalog-probe.sh" <<'PROBE'
. "$1/bin/fm-cursor-model-lib.sh"
fm_fork_cursor_catalog_has_model "$2" "$3"
PROBE
  env -u FM_CURSOR_MODEL_CATALOG HOME="$3" PATH="$4" \
    FM_CURSOR_PROBE_TIMEOUT="${5:-}" \
    bash "$TMP_ROOT/catalog-probe.sh" "$ROOT" "$1" "$2"
}

test_catalog_reads_the_binary_the_spawn_resolved() {
  local home bare_path rc
  home="$TMP_ROOT/offpath-home"
  write_fake_cursor_agent "$home/.local/bin/cursor-agent"
  mkdir -p "$TMP_ROOT/emptybin"
  bare_path="$TMP_ROOT/emptybin:/usr/bin:/bin"

  rc=0
  probe_catalog_has_model cursor-grok-4.6-xhigh "$home/.local/bin/cursor-agent" "$home" "$bare_path" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a resolved cursor binary off PATH must still answer the catalog, got rc=$rc"

  rc=0
  probe_catalog_has_model definitely-not-a-real-model-xyz "$home/.local/bin/cursor-agent" "$home" "$bare_path" || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "an absent id read through the resolved binary must be 'absent' (1), got rc=$rc"

  rc=0
  probe_catalog_has_model cursor-grok-4.6-xhigh '' "$home" "$bare_path" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "with no binary threaded, the shared resolver must still find ~/.local/bin/cursor-agent, got rc=$rc"

  rc=0
  probe_catalog_has_model cursor-grok-4.6-xhigh '' "$TMP_ROOT/no-cursor-home" "$bare_path" || rc=$?
  [ "$rc" -eq 2 ] \
    || fail "no resolvable cursor binary must report the catalog unavailable (2), got rc=$rc"

  pass "cursor catalog is read from the resolved launch binary, not a bare PATH lookup"
}

# `--list-models` is an account-scoped network call, so a stalled CLI must not
# wedge the spawn that is asking which tiers a model offers, nor the
# presentation refresh that asks what a pane is running. The read is bounded by
# FM_CURSOR_PROBE_TIMEOUT and fails closed: a bound that expires reports the
# catalog unavailable, which drops the fold to the safe tier rather than
# claiming the model does not exist.
#
# No timeout binary is staged here. The bound comes from the repo's own owner,
# which has a mechanism on every host, and
# test_catalog_on_a_runnerless_host_is_still_read_and_still_bounded below pins
# that a host with no timeout, gtimeout or perl still gets both halves.
write_stalling_cursor_agent() {  # <path>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --list-models ] || exit 1
exec sleep 30
EOF
  chmod +x "$1"
}

test_stalled_catalog_read_is_bounded_and_reads_unavailable() {
  local home started elapsed rc
  home="$TMP_ROOT/stalling-home"
  write_stalling_cursor_agent "$home/.local/bin/cursor-agent"

  started=$SECONDS
  rc=0
  probe_catalog_has_model cursor-grok-4.6-xhigh "$home/.local/bin/cursor-agent" \
    "$home" "/usr/bin:/bin" 1 || rc=$?
  elapsed=$((SECONDS - started))

  [ "$rc" -eq 2 ] \
    || fail "a catalog read that never completes must report unavailable (2), got rc=$rc"
  [ "$elapsed" -lt 15 ] \
    || fail "the catalog read was not bounded: ${elapsed}s against a 1s budget"
  pass "a stalled cursor catalog read is bounded and reads as unavailable, not absent"
}

# A host with no timeout, gtimeout or perl installed - the captain's macOS home
# is the runnerless case, minus perl - must still READ the catalog and must
# still bound the read. Refusing to read there would be silent under-tiering on
# the spawn path and, worse, a false model-mismatch claim on the presentation
# path, where bin/fm-visible-status.sh compares a pane's live footer label
# against the id the task recorded.
runnerless_path() {  # <dir>
  local dir=$1 tool src
  mkdir -p "$dir"
  for tool in bash env cat sed rm mktemp dirname stat sleep; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$src" "$dir/$tool"
  done
  printf '%s' "$dir"
}

test_catalog_on_a_runnerless_host_is_still_read_and_still_bounded() {
  local home stalling path started elapsed rc
  home="$TMP_ROOT/runnerless-home"
  stalling="$TMP_ROOT/runnerless-stalling-home"
  write_fake_cursor_agent "$home/.local/bin/cursor-agent"
  write_stalling_cursor_agent "$stalling/.local/bin/cursor-agent"
  path=$(runnerless_path "$TMP_ROOT/runnerless-bin")
  for tool in timeout gtimeout perl; do
    if PATH="$path" command -v "$tool" >/dev/null 2>&1; then
      fail "the fixture PATH still resolves $tool; the runnerless case proves nothing"
    fi
  done

  rc=0
  probe_catalog_has_model cursor-grok-4.6-xhigh "$home/.local/bin/cursor-agent" \
    "$home" "$path" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a runnerless host must still read the catalog, got rc=$rc"

  started=$SECONDS
  rc=0
  probe_catalog_has_model cursor-grok-4.6-xhigh "$stalling/.local/bin/cursor-agent" \
    "$stalling" "$path" 1 || rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 2 ] \
    || fail "a stalled read on a runnerless host must report unavailable (2), got rc=$rc"
  [ "$elapsed" -lt 15 ] \
    || fail "the runnerless bound did not hold: ${elapsed}s against a 1s budget"

  pass "a runnerless host reads the cursor catalog and still bounds the read"
}

# A budget that cannot bound anything is not a reason to run unbounded.
# bin/fm-timeout-lib.sh's own header states that `timeout 0` and the perl
# fallback's `alarm 0` disable the deadline outright, so FM_CURSOR_PROBE_TIMEOUT=0
# would hand a stalled --list-models an open-ended run on the spawn path.
test_a_budget_that_is_not_a_bound_falls_back_to_the_default() {
  local home healthy started elapsed rc
  home="$TMP_ROOT/zero-budget-home"
  healthy="$TMP_ROOT/zero-budget-healthy"
  write_stalling_cursor_agent "$home/.local/bin/cursor-agent"
  write_fake_cursor_agent "$healthy/.local/bin/cursor-agent"

  # Falling back is not the same as refusing, and only a readable catalog tells
  # them apart: a clamp that failed closed would report this listed id absent.
  rc=0
  probe_catalog_has_model cursor-grok-4.6-xhigh "$healthy/.local/bin/cursor-agent" \
    "$healthy" "/usr/bin:/bin" 0 || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a zero budget must still read a healthy catalog, got rc=$rc"

  started=$SECONDS
  rc=0
  probe_catalog_has_model cursor-grok-4.6-xhigh "$home/.local/bin/cursor-agent" \
    "$home" "/usr/bin:/bin" 0 || rc=$?
  elapsed=$((SECONDS - started))

  [ "$rc" -eq 2 ] \
    || fail "a zero budget must still end in an unavailable catalog (2), got rc=$rc"
  # The fixture stalls for 30s; the 10s probe default must cut it off first.
  [ "$elapsed" -lt 25 ] \
    || fail "a zero budget ran unbounded: ${elapsed}s against a 30s stall"
  # And the read must actually have run for that default. An instant return
  # would mean the clamp refused rather than fell back.
  [ "$elapsed" -ge 8 ] \
    || fail "the read returned in ${elapsed}s, so no 10s bound was ever applied"
  pass "a budget that is not a bound falls back to the probe default rather than running unbounded"
}

# The creator's own bounded probe (fm_cursor_bounded_output, behind
# fm_cursor_list_models and fm_cursor_probe_is_cursor) runs only where a
# coreutils/BSD timeout exists, so this Mac never reaches it - but every Linux
# home and every CI runner does, and that is the path the cursor spawn takes
# first, at its pre-fold catalog check. A budget of 0 must not reach the runner
# there either: `timeout 0` runs without a deadline, which would wedge the spawn
# on a stalled --list-models.
#
# The stand-in runner reproduces that documented "0 means no deadline"
# behaviour, so an unclamped budget is observable as the stall running to
# completion rather than as an argument.
write_faithful_timeout() {  # <dir>
  mkdir -p "$1"
  cat > "$1/timeout" <<'EOF'
#!/usr/bin/env bash
secs=$1
shift
if [ "$secs" -le 0 ] 2>/dev/null; then
  exec "$@"
fi
"$@" &
child=$!
( sleep "$secs"; kill -TERM "$child" 2>/dev/null ) >/dev/null 2>&1 &
guard=$!
wait "$child"
rc=$?
kill -TERM "$guard" 2>/dev/null
exit "$rc"
EOF
  chmod +x "$1/timeout"
}

probe_bounded_list_models() {  # <cursor-bin> <path> <probe-timeout>
  cat > "$TMP_ROOT/bounded-probe.sh" <<'PROBE'
. "$1/bin/fm-cursor-lib.sh"
fm_cursor_list_models "$2"
PROBE
  env PATH="$2" FM_CURSOR_PROBE_TIMEOUT="$3" \
    bash "$TMP_ROOT/bounded-probe.sh" "$ROOT" "$1"
}

test_a_zero_budget_cannot_disable_the_creator_probe_bound() {
  local home stalling runner path started elapsed rc out
  home="$TMP_ROOT/runner-host-home"
  stalling="$TMP_ROOT/runner-host-stalling"
  runner="$TMP_ROOT/faithful-runner"
  write_fake_cursor_agent "$home/.local/bin/cursor-agent"
  write_stalling_cursor_agent "$stalling/.local/bin/cursor-agent"
  write_faithful_timeout "$runner"
  path="$runner:/usr/bin:/bin"

  # Without this the zero case below could pass on a runnerless host, where the
  # bounded probe refuses instantly for an entirely different reason.
  rc=0
  out=$(probe_bounded_list_models "$home/.local/bin/cursor-agent" "$path" 1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the stand-in runner did not carry a normal bounded read, got rc=$rc"
  case "$out" in
    *cursor-grok-4.6-xhigh*) ;;
    *) fail "the bounded read returned no catalog: '$out'" ;;
  esac

  # A clamp that refused an unusable budget instead of falling back would starve
  # every caller on a host that sets one, so the healthy catalog must still come
  # back whole under a budget of zero.
  rc=0
  out=$(probe_bounded_list_models "$home/.local/bin/cursor-agent" "$path" 0) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a zero budget must still read a healthy catalog, got rc=$rc"
  case "$out" in
    *cursor-grok-4.6-xhigh*) ;;
    *) fail "a zero budget returned no catalog: '$out'" ;;
  esac

  started=$SECONDS
  rc=0
  probe_bounded_list_models "$stalling/.local/bin/cursor-agent" "$path" 0 >/dev/null || rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -ne 0 ] \
    || fail "a stalled catalog read must not report success"
  [ "$elapsed" -lt 20 ] \
    || fail "a zero budget reached the runner unclamped: ${elapsed}s against a 30s stall"
  [ "$elapsed" -ge 8 ] \
    || fail "the runner returned in ${elapsed}s, so it never ran under the 10s default"

  pass "a zero budget cannot disable the bound on hosts that have a timeout runner"
}

# --- 5. liveness ------------------------------------------------------------

test_liveness_uses_argv_for_node_comm() {
  local d fb out
  d="$TMP_ROOT/live"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  # Fake ps (from make_fake_tmux): argv carries the versioned cursor-agent
  # bundle path, exactly as the real wrapper leaves it. The recorded window is
  # in the session inventory, so the foreground read is trusted at all.
  out=$(PATH="$fb:$PATH" FM_FAKE_COMM=node FM_FAKE_ARGS="$CURSOR_ARGS" \
    FM_BACKEND_LIB_DIR="$ROOT/bin" \
    bash -c ". '$ROOT/bin/backends/tmux.sh'; fm_backend_tmux_agent_alive fm:cur" 2>/dev/null)
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
    FM_BACKEND_LIB_DIR="$ROOT/bin" \
    bash -c ". '$ROOT/bin/backends/tmux.sh'; fm_backend_tmux_agent_alive fm:cur" 2>/dev/null)
  [ "$out" = unknown ] || fail "unattributable node classified '$out', expected unknown"
  pass "a non-cursor bare node stays unknown, never dead"
}

# --- 6. harness detection ---------------------------------------------------
#
# What this capability owns is the ENV-MARKER verdict. The full detection above
# it arbitrates the marker against process ancestry, which is a separate
# contract and would otherwise let the ancestry of whatever runs this suite
# decide the answer; `fm-harness.sh marker` is that marker read on its own.

test_cursor_env_marker_beats_inherited_claudecode() {
  local out
  # cursor does not clear an INHERITED CLAUDECODE=1, so a cursor worker spawned
  # from a claude-hosted firstmate carries both markers. CURSOR_AGENT must win,
  # or that pane is steered with claude's interrupt/exit/resume vocabulary.
  out=$(CURSOR_AGENT=1 CLAUDECODE=1 "$ROOT/bin/fm-harness.sh" marker)
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 with inherited CLAUDECODE=1 detected '$out', expected cursor"
  pass "CURSOR_AGENT=1 outranks an inherited CLAUDECODE=1"
}

test_claude_detection_unregressed() {
  local out
  # Unset CURSOR_AGENT explicitly: this suite itself often runs inside a cursor
  # worker whose ambient CURSOR_AGENT=1 would otherwise make the probe report
  # cursor even when the test only sets CLAUDECODE=1.
  out=$(env -u CURSOR_AGENT CLAUDECODE=1 "$ROOT/bin/fm-harness.sh" marker)
  [ "$out" = claude ] || fail "claude detection regressed: '$out'"
  pass "claude detection is unchanged when CURSOR_AGENT is absent"
}

# --- 7. turn-end binding shape ----------------------------------------------


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
test_busy_signature_is_the_footer_not_the_spinner_verb
test_harnessless_union_still_carries_the_cursor_footer
test_launch_template_flags
write_catalog_45
write_catalog_46
test_effort_folds_into_model_id
test_effort_above_ceiling_caps_at_high
test_effort_uses_xhigh_when_the_model_offers_it
test_explicit_tiered_model_is_never_retiered
test_fast_variant_is_never_implicit
test_parse_footer_model_from_idle_capture
test_catalog_has_model_and_equivalence
test_catalog_has_model_through_ansi_color
test_catalog_reads_the_binary_the_spawn_resolved
test_stalled_catalog_read_is_bounded_and_reads_unavailable
test_catalog_on_a_runnerless_host_is_still_read_and_still_bounded
test_a_budget_that_is_not_a_bound_falls_back_to_the_default
test_a_zero_budget_cannot_disable_the_creator_probe_bound
test_liveness_uses_argv_for_node_comm
test_unattributable_node_stays_unknown
test_cursor_env_marker_beats_inherited_claudecode
test_claude_detection_unregressed
test_composer_ghost_suite_still_passes
