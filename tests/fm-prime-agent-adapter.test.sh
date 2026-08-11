#!/usr/bin/env bash
# prime-agent (Prime Intellect, pi hard fork) worker-adapter regressions (task
# fm-prime-agent-adapter-wire-p2, adoption decision data/fm-prime-agent-trial-t1).
#
# Styled fixtures here are VERBATIM captures from the 2026-08-07 verification lab
# (prime-agent v0.7.0, source tag be9e2fa, OpenCode Zen deepseek-v4-flash-free,
# macOS, tmux on an isolated server); exact commands and raw output are recorded
# in docs/prime-agent-harness.md. These tests pin the five prime-agent-specific
# behaviours that shared monitoring would otherwise get wrong:
#
#   1. ENV-MARKER PRECEDENCE. prime-agent sets PI_CODING_AGENT=true for its
#      children (inherited from pi), so a PI-first test misreports a prime-agent
#      worker as pi and steers it with pi's vocabulary. The PRIME_AGENT_*
#      markers must win, the same shape as CURSOR_AGENT before CLAUDECODE.
#   2. BUSY SIGNATURE. The busy row is `<spinner> (Waiting|Thinking|Executing)
#      · Ns` in the MESSAGES area. The bare state word is NOT safe (model prose
#      can contain "Thinking"); "Operation aborted · Ns" (post-interrupt) must
#      not match - the turn is over.
#   3. IDLE COMPOSER. The placeholder (` >   Try "add tests for @<filepath>"`)
#      is dark-truecolor ghost text, so the shared stripper drops it - but what
#      remains is the lone `>` glyph, which the dead-shell safety rule reads as
#      `unknown` on an unbordered row, deferring every away-mode escalation.
#      Only a POSITIVELY identified prime-agent pane (node COMM + prime-agent
#      argv) may treat that bare glyph row as the agent composer.
#   4. DAEMON-AWARE TEARDOWN. /quit or a dead pane only detaches the TUI; the
#      agent keeps running in the task's daemon. Teardown stops this task's
#      sessions through its own --daemon-socket (never the fleet-wide public
#      `shutdown`) and TERMs the supervisor identified by its socket.
#   5. MODEL-ROUTE GUARD. Subscription-quota routes only: opencode free ids and
#      openai-codex/* pass; anthropic/* (verified per-token extra-usage
#      billing, $0.1845 for a one-liner) and paid/unverified routes are refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-prime-agent-tests)

ESC=$(printf '\033')

# The VERBATIM styled idle-composer row captured from a prime-agent pane
# (2026-08-07, v0.7.0): dark-truecolor placeholder (38;2;113;113;122) after a
# bare " >  " glyph, with the terminal cursor as an SGR-7 cell over a space.
PA_IDLE_ROW="${ESC}[48;2;26;26;31m >  ${ESC}[7m ${ESC}[0m${ESC}[38;2;113;113;122m${ESC}[48;2;26;26;31mTry \"add tests for @<filepath>\"${ESC}[39m"

# A fake tmux serving a single-row pane, in the same shape as the cursor suite:
# FM_FAKE_PANE holds the pane, FM_FAKE_CY the cursor row, FM_FAKE_COMM the pane
# COMM, and the companion fake ps prints FM_FAKE_ARGS so the pane's harness
# identity (fm_tmux_pane_is_prime_agent: node COMM + prime-agent argv) is
# test-controlled.
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

# --- 1. env-marker precedence -------------------------------------------------

test_prime_marker_beats_pi_marker() {
  local out marker
  # Every PRIME_AGENT_* marker must outrank the inherited pi marker, whichever
  # one a worker's environment happens to carry.
  for marker in PRIME_AGENT_INTERNAL_DAEMON_WORKER PRIME_AGENT_CODING_AGENT_DIR \
                PRIME_AGENT_KERNEL_VENV PRIME_AGENT_LAUNCHER_PATH PRIME_AGENT_BUILD_ID; do
    out=$(env -u PRIME_AGENT_INTERNAL_DAEMON_WORKER -u PRIME_AGENT_CODING_AGENT_DIR \
          -u PRIME_AGENT_KERNEL_VENV -u PRIME_AGENT_LAUNCHER_PATH -u PRIME_AGENT_BUILD_ID \
          "$marker"=1 PI_CODING_AGENT=true "$ROOT/bin/fm-harness.sh")
    [ "$out" = prime-agent ] || fail "$marker with PI_CODING_AGENT=true detected '$out', expected prime-agent"
  done
  pass "PRIME_AGENT_* markers outrank the inherited PI_CODING_AGENT=true"
}

test_pi_detection_unregressed() {
  local out
  out=$(env -u PRIME_AGENT_INTERNAL_DAEMON_WORKER -u PRIME_AGENT_CODING_AGENT_DIR \
        -u PRIME_AGENT_KERNEL_VENV -u PRIME_AGENT_LAUNCHER_PATH -u PRIME_AGENT_BUILD_ID \
        -u CURSOR_AGENT -u CLAUDECODE PI_CODING_AGENT=true "$ROOT/bin/fm-harness.sh")
  [ "$out" = pi ] || fail "pi detection regressed: '$out'"
  pass "pi detection is unchanged when no PRIME_AGENT_* marker is present"
}

# --- 2. busy signature ---------------------------------------------------------

test_busy_regex_matches_state_row_not_prose() {
  # Verbatim busy rows from the lab and trial.
  printf ' ⠴ Waiting · 0s\n' | grep -qiE "$FM_BUSY_REGEX_DEFAULT" \
    || fail "busy row 'Waiting · 0s' did not match"
  printf ' ⠏ Thinking · 3s · ↓ 52 tokens\n' | grep -qiE "$FM_BUSY_REGEX_DEFAULT" \
    || fail "busy row 'Thinking · 3s' did not match"
  printf ' ⠹ Executing · 19s · ↑ 111 tokens\n' | grep -qiE "$FM_BUSY_REGEX_DEFAULT" \
    || fail "busy row 'Executing · 19s' did not match"
  # The bare state word in model prose must NOT be the signal.
  printf 'Let me explain Thinking processes\n' | grep -qiE "$FM_BUSY_REGEX_DEFAULT" \
    && fail "bare 'Thinking' prose must not match the busy regex"
  # The post-interrupt row is transient and the turn is over: not busy.
  printf ' Operation aborted · 2s\n' | grep -qiE "$FM_BUSY_REGEX_DEFAULT" \
    && fail "'Operation aborted · 2s' must not read as busy"
  # The idle footer must not match either.
  printf '← agents/resume  DeepSeek V4 Flash Free • high  ? for shortcuts\n' \
    | grep -qiE "$FM_BUSY_REGEX_DEFAULT" \
    && fail "idle prime-agent footer matched the busy regex"
  pass "prime-agent busy signature is the state-word + seconds-suffix row"
}

test_busy_default_still_defined_once() {
  local literal_count
  assert_grep 'FM_BUSY_REGEX_DEFAULT' "$ROOT/bin/fm-watch.sh" \
    "fm-watch.sh does not consume the shared busy default"
  assert_grep 'FM_BUSY_REGEX_DEFAULT' "$ROOT/bin/fm-tmux-lib.sh" \
    "fm-tmux-lib.sh does not consume the shared busy default"
  literal_count=$(grep -R '^FM_BUSY_REGEX_DEFAULT=' "$ROOT/bin" | wc -l | tr -d '[:space:]')
  [ "$literal_count" = 1 ] || fail "busy default is defined $literal_count times, expected exactly once"
  pass "one shared busy default carries the prime-agent signature"
}

# --- 3. idle composer ----------------------------------------------------------

test_placeholder_ghost_strips_to_bare_glyph() {
  local out
  out=$(printf '%s\n' "$PA_IDLE_ROW" | fm_composer_strip_ghost \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # Pins the mechanism: the dark-truecolor placeholder drops and the
  # reverse-video space trims away, leaving the lone bare `>` glyph.
  [ "$out" = ">" ] || fail "expected lone '>' after ghost strip, got '$out'"
  pass "prime-agent placeholder ghost-strips to the bare prompt glyph"
}

test_bare_glyph_unidentified_pane_stays_unknown() {
  local out
  # The shared dead-shell safety rule must stay intact: an UNIDENTIFIED pane
  # with a bare `>` row is never promoted to an agent composer.
  out=$(fm_composer_classify_content 0 ">" "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive ">")
  [ "$out" = unknown ] || fail "bare '>' on an unbordered row classified '$out', expected unknown"
  pass "dead-shell safety rule intact for bare '>' on unidentified panes"
}

test_idle_placeholder_patterns_read_empty() {
  local out
  # Plain-row backstop (styling surprises, plain-read backends): the shared
  # idle default covers the rotating Try "..." tips with or without the glyph.
  out=$(fm_composer_classify_content 0 'Try "add tests for @<filepath>"' \
        "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive '>   Try "add tests for @<filepath>"')
  [ "$out" = empty ] || fail "placeholder content classified '$out', expected empty"
  out=$(fm_composer_classify_content 0 ' >   Try "explain how @<filepath> works"' \
        "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive ' >   Try "explain how @<filepath> works"')
  [ "$out" = empty ] || fail "glyph-prefixed placeholder classified '$out', expected empty"
  pass "prime-agent idle placeholder reads empty through the shared idle default"
}

test_idle_regex_does_not_swallow_real_text() {
  local out
  for txt in "refactor the auth module" 'Try "x" but keep going' "try the tests"; do
    out=$(fm_composer_classify_content 1 "$txt" "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive "> $txt")
    [ "$out" = pending ] || fail "real text '$txt' classified '$out', expected pending"
  done
  pass "prime-agent idle pattern is anchored: real text stays pending"
}

test_identified_prime_agent_pane_idle_reads_empty() {
  local d fb pane out
  d="$TMP_ROOT/pa-idle"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  pane="$d/pane.txt"
  printf '%s\n' "$PA_IDLE_ROW" > "$pane"
  # Positively identified prime-agent pane (node COMM, prime-agent argv): the
  # bare `>` row is the agent composer and must read empty - otherwise every
  # away-mode escalation defers forever on an idle prime-agent worker.
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=0 FM_FAKE_COMM=node \
    FM_FAKE_ARGS="prime-agent" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_composer_state t" 2>/dev/null)
  [ "$out" = empty ] || fail "identified prime-agent idle composer classified '$out', expected empty"
  pass "positively identified prime-agent idle composer reads empty"
}

test_unidentified_pane_same_row_is_not_promoted() {
  local d fb pane out
  d="$TMP_ROOT/pa-unid"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  pane="$d/pane.txt"
  printf '%s\n' "$PA_IDLE_ROW" > "$pane"
  # A pane that merely SHOWS the same bytes but is not prime-agent (a dead
  # shell's COMM, an unattributable argv) keeps the safe unknown/pending path.
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=0 FM_FAKE_COMM=bash \
    FM_FAKE_ARGS="-bash" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_composer_state t" 2>/dev/null)
  [ "$out" != empty ] || fail "non-prime-agent pane with the same row was promoted to empty"
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=0 FM_FAKE_COMM=node \
    FM_FAKE_ARGS="/usr/bin/node /opt/somewhere/index.js" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; fm_tmux_composer_state t" 2>/dev/null)
  [ "$out" != empty ] || fail "unattributable node pane with the same row was promoted to empty"
  pass "composer promotion is scoped to positively identified prime-agent panes"
}

# --- liveness ------------------------------------------------------------------

test_liveness_uses_argv_for_node_comm() {
  local d fb out
  d="$TMP_ROOT/pa-live"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  out=$(PATH="$fb:$PATH" FM_FAKE_COMM=node FM_FAKE_ARGS="prime-agent" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; . '$ROOT/bin/backends/tmux.sh'; fm_backend_tmux_agent_alive t" 2>/dev/null)
  [ "$out" = alive ] || fail "prime-agent pane (node comm + prime-agent argv) classified '$out', expected alive"
  pass "prime-agent liveness resolves through argv when COMM is a bare node"
}

test_unattributable_node_stays_unknown() {
  local d fb out
  d="$TMP_ROOT/pa-live2"; mkdir -p "$d"
  fb=$(make_fake_tmux "$d")
  out=$(PATH="$fb:$PATH" FM_FAKE_COMM=node FM_FAKE_ARGS="/usr/bin/node /opt/somewhere/index.js" \
    bash -c ". '$ROOT/bin/fm-tmux-lib.sh'; . '$ROOT/bin/backends/tmux.sh'; fm_backend_tmux_agent_alive t" 2>/dev/null)
  [ "$out" = unknown ] || fail "unattributable node classified '$out', expected unknown"
  pass "a non-prime-agent bare node stays unknown, never dead"
}

# --- 4. daemon-aware teardown --------------------------------------------------

# prime_agent_daemon_stop lives in fm-teardown.sh, which is a script rather than
# a sourceable library, so extract just that function to exercise it directly
# (same technique as the cursor suite's cursor_model_with_effort extraction).
extract_daemon_stop() {
  sed -n '/^prime_agent_daemon_stop() {/,/^}/p' "$ROOT/bin/fm-teardown.sh" > "$TMP_ROOT/pa-stop.sh"
}

test_daemon_stop_is_scoped_to_task_socket() {
  local d fb pastate log
  extract_daemon_stop
  d="$TMP_ROOT/pa-stop"; mkdir -p "$d"
  fb=$(fm_fakebin "$d")
  # Work through RELATIVE paths: the absolute macOS temp path exceeds the
  # 104-char AF_UNIX sun_path limit once "state/t1.prime-agent-home/daemon.sock"
  # is appended, so the socket fixture binds "./daemon.sock" from inside the
  # containment dir and the function is exercised from the task root.
  pastate="state/t1.prime-agent-home"
  mkdir -p "$d/$pastate"
  log="$d/calls.log"
  : > "$log"
  # A real socket file so the function's -S gate passes.
  ( cd "$d/$pastate" && python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind('./daemon.sock')" ) 2>/dev/null \
    || { pass "python3 unavailable for socket fixture - skipped (environmental)"; return 0; }
  # Fake prime-agent records its argv; list prints one session row in the real
  # 12-hex id shape captured in the lab.
  cat > "$fb/prime-agent" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_PA_LOG:?}"
case "$*" in
  "list --daemon-socket"*)
    printf 'name  id            status  age  model                            messages  clients\n'
    printf '      bb9c4f2f8830  idle    13s  opencode/deepseek-v4-flash-free  2         0\n'
    ;;
esac
exit 0
SH
  chmod +x "$fb/prime-agent"
  ( cd "$d" && PATH="$fb:$PATH" FM_FAKE_PA_LOG="$log" \
    bash -c ". '$TMP_ROOT/pa-stop.sh'; prime_agent_daemon_stop state t1" )
  # The function resolves the containment dir physically (lsof prints physical
  # socket paths), so the fake CLI sees the resolved socket path.
  local rsock
  rsock="$(cd "$d/$pastate" && pwd -P)/daemon.sock"
  assert_grep "list --daemon-socket $rsock" "$log" "daemon stop did not list through the task socket"
  assert_grep "stop bb9c4f2f8830 --daemon-socket $rsock" "$log" \
    "daemon stop did not stop the session through the task socket"
  # The fleet-wide public shutdown must never appear.
  if grep -qE '(^| )shutdown( |$)' "$log"; then
    fail "daemon stop used the fleet-wide public shutdown"
  fi
  pass "daemon stop lists and stops only through the task's own daemon socket"
}

test_daemon_stop_noops_without_socket_or_binary() {
  local d fb out
  extract_daemon_stop
  d="$TMP_ROOT/pa-stop-noop"; mkdir -p "$d/state"
  fb=$(fm_fakebin "$d")
  # No socket present: immediate no-op, no prime-agent invocation.
  out=$(PATH="$fb:/usr/bin:/bin" \
    bash -c ". '$TMP_ROOT/pa-stop.sh'; prime_agent_daemon_stop '$d/state' t1; echo rc=\$?" 2>&1)
  assert_contains "$out" "rc=0" "daemon stop without a socket did not no-op cleanly"
  pass "daemon stop is a clean no-op when the task socket is absent"
}

# shellcheck disable=SC2016  # single quotes are deliberate: literal source expressions
test_teardown_wires_daemon_stop_and_cleanup() {
  local td="$ROOT/bin/fm-teardown.sh"
  assert_grep 'prime_agent_daemon_stop "$STATE" "$ID"' "$td" \
    "fm-teardown does not call the daemon-aware stop"
  assert_grep '$ID.prime-agent-home' "$td" \
    "fm-teardown does not remove the prime-agent containment home"
  assert_grep '$ID.prime-ext.ts' "$td" \
    "fm-teardown does not remove the prime-agent turn-end extension"
  pass "fm-teardown wires the daemon-aware stop and containment cleanup"
}

# --- 5. launch template and model-route guard ---------------------------------

test_launch_template_shape() {
  local spawn="$ROOT/bin/fm-spawn.sh" tpl
  tpl=$(grep -m1 "^    prime-agent) printf" "$spawn")
  [ -n "$tpl" ] || fail "fm-spawn missing prime-agent launch_template branch"
  case "$tpl" in *'PRIME_AGENT_CODING_AGENT_DIR=__PASTATE__'*) : ;; *) fail "template lacks agent-dir containment: $tpl" ;; esac
  case "$tpl" in *'PRIME_AGENT_KERNEL_VENV=__PASTATE__/kernel-venv'*) : ;; *) fail "template lacks kernel-venv containment: $tpl" ;; esac
  case "$tpl" in *'--daemon-socket __PASTATE__/daemon.sock'*) : ;; *) fail "template lacks per-task daemon socket: $tpl" ;; esac
  case "$tpl" in *'-e __PRIMEEXT__'*) : ;; *) fail "template lacks the turn-end extension: $tpl" ;; esac
  case "$tpl" in *'__MODELFLAG__'*) : ;; *) fail "template lacks an explicit model flag: $tpl" ;; esac
  # Autonomy budget flags belong to a different, non-interactive launch mode;
  # firstmate's supervised template must not set them.
  case "$tpl" in *'--autonomous'*) fail "template must not pass --autonomous: $tpl" ;; esac
  assert_grep "prime-agent) printf '%s' 'curl -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh'" \
    "$spawn" "prime-agent install hint missing"
  pass "prime-agent launch template: contained, socket-scoped, explicit model, no autonomy flags"
}

test_turn_end_hook_written_outside_worktree() {
  local blk
  blk=$(sed -n '/^    prime-agent\*)/,/^      ;;/p' "$ROOT/bin/fm-spawn.sh")
  case "$blk" in *'prime-ext.ts'*) : ;; *) fail "prime-agent spawn does not write the turn-end extension" ;; esac
  case "$blk" in *'turn_end'*) : ;; *) fail "prime-agent extension does not listen for turn_end" ;; esac
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source expression
  case "$blk" in *'$STATE/'*) : ;; *) fail "prime-agent extension is not kept in state/ (outside the worktree)" ;; esac
  pass "prime-agent spawn installs the pi-fork turn_end extension in state/"
}

run_route_guard() {  # <model>
  sed -n '/^prime_agent_model_route_ok() {/,/^}/p' "$ROOT/bin/fm-spawn.sh" > "$TMP_ROOT/route.sh"
  bash -c ". '$TMP_ROOT/route.sh'; prime_agent_model_route_ok '$1'"
}

test_model_route_guard() {
  local m
  for m in opencode/big-pickle opencode/deepseek-v4-flash-free opencode/some-future-free openai-codex/gpt-5.6-sol; do
    run_route_guard "$m" || fail "subscription-quota route '$m' was refused"
  done
  for m in anthropic/claude-opus-5 anthropic/anything opencode/gpt-5.6-sol openai/gpt-5 "" default; do
    if run_route_guard "$m"; then
      fail "billed/unverified route '$m' was allowed"
    fi
  done
  pass "model-route guard: subscription-quota routes allowed, billed/unverified refused"
}

test_effort_maps_to_thinking_flag() {
  local blk
  blk=$(sed -n '/^effort_flag_for_harness() {/,/^}/p' "$ROOT/bin/fm-spawn.sh")
  case "$blk" in *'prime-agent)'*'--thinking'*) : ;; *) fail "prime-agent effort does not map to --thinking" ;; esac
  pass "prime-agent effort axis maps to --thinking"
}

# --- suite ---------------------------------------------------------------------

test_prime_marker_beats_pi_marker
test_pi_detection_unregressed
test_busy_regex_matches_state_row_not_prose
test_busy_default_still_defined_once
test_placeholder_ghost_strips_to_bare_glyph
test_bare_glyph_unidentified_pane_stays_unknown
test_idle_placeholder_patterns_read_empty
test_idle_regex_does_not_swallow_real_text
test_identified_prime_agent_pane_idle_reads_empty
test_unidentified_pane_same_row_is_not_promoted
test_liveness_uses_argv_for_node_comm
test_unattributable_node_stays_unknown
test_daemon_stop_is_scoped_to_task_socket
test_daemon_stop_noops_without_socket_or_binary
test_teardown_wires_daemon_stop_and_cleanup
test_launch_template_shape
test_turn_end_hook_written_outside_worktree
test_model_route_guard
test_effort_maps_to_thinking_flag

echo "# all fm-prime-agent-adapter tests passed"
