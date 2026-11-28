#!/usr/bin/env bash
# Opt-in live guard for Antigravity CLI (agy) as a firstmate PRIMARY and
# SECONDMATE.
#
# Exercises live agy CLI invocation with .agents/hooks.json in an isolated
# temporary Firstmate home so SessionStart, PreToolUse, and Stop hooks run
# end-to-end against the installed agy binary, including a turn whose model
# call ends on a transport error (forced through a local CONNECT proxy), then
# pre-seeds workspace trust for a --secondmate agy home and launches agy into it.
# FM_AGY_LIVE_MODEL selects a model; without it agy uses its own default.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_PRIMARY_LIVE,FM_AGY_PRIMARY_LIVE_E2E agy jq python3

AGY_BIN=${FM_AGY_BIN:-$(command -v agy 2>/dev/null || true)}
[ -n "$AGY_BIN" ] && [ -x "$AGY_BIN" ] \
  || fail "agy not found; install it or set FM_AGY_BIN"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-primary-live.XXXXXX") || fail "could not create isolated agy lab"
HOME_DIR="$LAB/home"
SM_HOME="$LAB/sm-home"
SM_ID="live-agy-sm"
AGY_USER_HOME="$LAB/user-home"
MARKER="FM_AGY_LIVE_MARKER_$$"
SM_MARKER="FM_AGY_SM_LIVE_MARKER_$$"

AGY_MODEL_ARGS=()
[ -z "${FM_AGY_LIVE_MODEL:-}" ] || AGY_MODEL_ARGS=(--model "$FM_AGY_LIVE_MODEL")

stop_watchers() {
  local home
  for home in "$HOME_DIR" "$SM_HOME"; do
    [ -x "$home/bin/fm-watch-arm.sh" ] || continue
    FM_HOME="$home" "$home/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  done
}

PROXY_PID=
cleanup_all() {
  stop_watchers
  [ -z "$PROXY_PID" ] || kill "$PROXY_PID" 2>/dev/null || true
  [ -n "${LAB:-}" ] && rm -rf -- "$LAB"
}
trap cleanup_all EXIT

run_agy() {  # <home> <prompt> [env...]
  local home=$1 prompt=$2
  shift 2
  (cd "$home" && env HOME="$AGY_USER_HOME" FM_HOME="$home" "$@" \
    timeout 600 "$AGY_BIN" -p "$prompt" ${AGY_MODEL_ARGS[@]+"${AGY_MODEL_ARGS[@]}"} \
    --effort low --dangerously-skip-permissions 2>&1 || true)
}

mkdir -p "$HOME_DIR" "$AGY_USER_HOME/.gemini/antigravity-cli"
for auth_file in antigravity-oauth-token installation_id jetski_state.pbtxt settings.json; do
  if [ -f "$HOME/.gemini/antigravity-cli/$auth_file" ]; then
    cp "$HOME/.gemini/antigravity-cli/$auth_file" "$AGY_USER_HOME/.gemini/antigravity-cli/$auth_file"
  fi
done

(cd "$ROOT" && tar --exclude=.git --exclude=state --exclude=projects --exclude=node_modules -cf - .) \
  | (cd "$HOME_DIR" && tar -xf -) \
  || fail "could not stage the working tree into the throwaway home"

git init -q -b main "$HOME_DIR"
git -C "$HOME_DIR" add -A >/dev/null 2>&1 || true
git -C "$HOME_DIR" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q -m "live-e2e fixture" >/dev/null 2>&1 || true

[ -f "$HOME_DIR/.agents/hooks.json" ] \
  || fail "working tree ships no .agents/hooks.json"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
printf 'Live marker: %s\n' "$MARKER" > "$HOME_DIR/data/learnings.md"
printf '# Backlog\n\n- live probe\n' > "$HOME_DIR/data/backlog.md"

HOME="$AGY_USER_HOME" "$HOME_DIR/bin/fm-agy-trust.sh" "$HOME_DIR" "live-primary" >/dev/null 2>&1 || true

# --- SessionStart -------------------------------------------------------------
OUT=$(run_agy "$HOME_DIR" "Reply with the exact live marker token from session start context and nothing else.")
[ -f "$HOME_DIR/state/.lock" ] || fail "SessionStart hook did not create state/.lock in live agy run"
assert_contains "$OUT" "$MARKER" "SessionStart injectSteps systemMessage did not reach live agy context"
pass "agy primary live: SessionStart hook acquires lock and injects digest into live model context"

# --- PreToolUse deny ----------------------------------------------------------
# A direct foreground watcher is denied by the shared arm-command policy, so the
# whole command line never runs and its trailing touch leaves no marker.
DENY_MARK="$HOME_DIR/state/live-deny-ran"
rm -f "$HOME_DIR/state/.lock"
OUT=$(run_agy "$HOME_DIR" "Run exactly this one shell command with your command tool: bin/fm-watch.sh; touch state/live-deny-ran
If the command is blocked or denied, do not run any other command; reply with the word BLOCKED and the reason you were given.")
[ ! -e "$DENY_MARK" ] || fail "PreToolUse did not deny a direct bin/fm-watch.sh command in live agy: $OUT"
assert_contains "$OUT" "BLOCKED" "live agy never reported the watcher command as blocked"
assert_contains "$OUT" "watcher-direct" \
  "live agy reply lacked the [watcher-direct] reason bin/fm-arm-pretool-check.sh --agy returns, so the PreToolUse deny is unproven"
pass "agy primary live: PreToolUse --agy deny blocks a direct watcher command"

# --- Stop-hook park -----------------------------------------------------------
# An in-flight task makes supervision needed, so the turn end must park on a
# real watcher. Once the watcher beats, a task status line wakes it, and the
# wake must reach a follow-up turn; a short park bound keeps the run bounded.
rm -f "$HOME_DIR/state/.lock" "$HOME_DIR/state/.agy-park-owner" \
  "$HOME_DIR/state/.last-watcher-beat" "$HOME_DIR/state/live-watcher-started" \
  "$HOME_DIR/state/live-task.status" "$HOME_DIR/state/.wake-queue"
: > "$HOME_DIR/state/live-task.meta"
(
  i=0
  while [ "$i" -lt 240 ]; do
    if [ -s "$HOME_DIR/state/.agy-park-owner" ] && [ -e "$HOME_DIR/state/.last-watcher-beat" ]; then
      : > "$HOME_DIR/state/live-watcher-started"
      sleep 1
      printf 'done: live-park-wake\n' >> "$HOME_DIR/state/live-task.status"
      j=0
      while [ "$j" -lt 80 ] && [ -d "$HOME_DIR/state/.watch.lock" ]; do
        sleep 0.25
        j=$((j + 1))
      done
      sleep 2
      rm -f "$HOME_DIR/state/live-task.meta" "$HOME_DIR/state/.wake-queue" "$HOME_DIR/state/live-task.status"
      exit 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
) &
WAKE_PID=$!
OUT=$(run_agy "$HOME_DIR" "If you have not yet seen a firstmate watcher wake message in this conversation, reply with the single word READY and end your turn without running any command. Once you receive a firstmate watcher wake message, reply with the single word DONE and end your turn without running any command." \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_AGY_PARK_TIMEOUT=30 FM_AGY_TURNEND_LOOP_CEILING=2)
wait "$WAKE_PID" 2>/dev/null || true
[ -s "$HOME_DIR/state/.agy-park-owner" ] \
  || fail "Stop hook never claimed a park in state/.agy-park-owner in live agy run: $OUT"
[ -e "$HOME_DIR/state/live-watcher-started" ] \
  || fail "Stop hook never started a real watcher with state/.last-watcher-beat in live agy run: $OUT"
assert_contains "$OUT" "DONE" "Stop hook watcher wake did not reach a follow-up turn in live agy run"
rm -f "$HOME_DIR/state/live-task.meta" "$HOME_DIR/state/.wake-queue" "$HOME_DIR/state/live-task.status"
stop_watchers
pass "agy primary live: Stop hook parks on a real watcher and delivers its wake to a follow-up turn"

# --- Error-ended turn ----------------------------------------------------------
# A local CONNECT proxy passes agy's traffic until state/live-error-flag exists,
# then cuts and refuses the model endpoint, so the next model call fails the
# way a provider error does and agy ends the turn with terminationReason ERROR.
# With a task in flight the Stop hook must still park on a real watcher and
# deliver the wake to a follow-up turn, as it does after a normal end.
PROXY_PY="$LAB/connect-proxy.py"
cat > "$PROXY_PY" <<'PY'
import os, socket, sys, threading, time
port, flag = int(sys.argv[1]), sys.argv[2]
tunnels = []
def cutter():
    while True:
        if os.path.exists(flag):
            for pair in list(tunnels):
                for s in pair:
                    try: s.shutdown(socket.SHUT_RDWR); s.close()
                    except OSError: pass
            tunnels.clear()
        time.sleep(0.2)
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError: pass
    finally:
        for s in (a, b):
            try: s.close()
            except OSError: pass
def handle(c):
    try:
        req = b''
        while b'\r\n\r\n' not in req:
            d = c.recv(4096)
            if not d: return
            req += d
        host = req.split(b'\r\n')[0].split()[1].decode()
        model = 'cloudcode-pa' in host
        if model and os.path.exists(flag):
            c.sendall(b'HTTP/1.1 403 Forbidden\r\n\r\n'); c.close(); return
        name, p = host.rsplit(':', 1)
        u = socket.create_connection((name, int(p)))
        if model: tunnels.append((c, u))
        c.sendall(b'HTTP/1.1 200 OK\r\n\r\n')
        threading.Thread(target=pipe, args=(c, u), daemon=True).start()
        pipe(u, c)
    except OSError: pass
threading.Thread(target=cutter, daemon=True).start()
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', port)); srv.listen(64)
print('listening', flush=True)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
ERROR_FLAG="$HOME_DIR/state/live-error-flag"
PROXY_PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -I "$PROXY_PY" "$PROXY_PORT" "$ERROR_FLAG" > "$LAB/proxy.out" 2>&1 &
PROXY_PID=$!
i=0
until grep -q listening "$LAB/proxy.out" 2>/dev/null; do
  sleep 0.1
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail "the local CONNECT proxy never started: $(cat "$LAB/proxy.out" 2>/dev/null)"
done
rm -f "$HOME_DIR/state/.lock" "$HOME_DIR/state/.agy-park-owner" "$HOME_DIR/state/.agy-error-rewake" \
  "$HOME_DIR/state/.last-watcher-beat" "$HOME_DIR/state/live-watcher-started" \
  "$HOME_DIR/state/live-task.status" "$HOME_DIR/state/.wake-queue" "$ERROR_FLAG"
: > "$HOME_DIR/state/live-task.meta"
(
  i=0
  while [ "$i" -lt 480 ]; do
    if [ -e "$ERROR_FLAG" ] && [ -s "$HOME_DIR/state/.agy-park-owner" ] && [ -e "$HOME_DIR/state/.last-watcher-beat" ]; then
      : > "$HOME_DIR/state/live-watcher-started"
      rm -f "$ERROR_FLAG"
      sleep 1
      printf 'done: live-error-park-wake\n' >> "$HOME_DIR/state/live-task.status"
      j=0
      while [ "$j" -lt 80 ] && [ -d "$HOME_DIR/state/.watch.lock" ]; do
        sleep 0.25
        j=$((j + 1))
      done
      sleep 2
      rm -f "$HOME_DIR/state/live-task.meta" "$HOME_DIR/state/.wake-queue" "$HOME_DIR/state/live-task.status"
      exit 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
) &
WAKE_PID=$!
OUT=$(run_agy "$HOME_DIR" "If you have not yet seen a firstmate watcher wake message in this conversation, run exactly this one shell command with your command tool and nothing else: touch state/live-error-flag
then reply with the single word READY. Once you receive a firstmate watcher wake message, reply with the single word DONE and end your turn without running any command." \
  HTTPS_PROXY="http://127.0.0.1:$PROXY_PORT" https_proxy="http://127.0.0.1:$PROXY_PORT" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_AGY_PARK_TIMEOUT=60 FM_AGY_TURNEND_LOOP_CEILING=3)
wait "$WAKE_PID" 2>/dev/null || true
kill "$PROXY_PID" 2>/dev/null || true
PROXY_PID=
# Only a Stop payload whose terminationReason is ERROR writes this marker.
[ -e "$HOME_DIR/state/.agy-error-rewake" ] \
  || fail "the forced model-endpoint failure never reached the Stop hook as an error end: $OUT"
[ -e "$HOME_DIR/state/live-watcher-started" ] \
  || fail "the Stop hook never parked on a real watcher after a live agy error end: $OUT"
assert_contains "$OUT" "DONE" "the watcher wake did not reach a follow-up turn after a live agy error end"
rm -f "$HOME_DIR/state/live-task.meta" "$HOME_DIR/state/.wake-queue" "$HOME_DIR/state/live-task.status"
stop_watchers
pass "agy primary live: after an error-ended turn the Stop hook parks on a real watcher and delivers its wake"

# --- --secondmate agy trust pre-seeding and launch -----------------------------
git -C "$HOME_DIR" worktree add -q -b "fm/$SM_ID" "$SM_HOME" >/dev/null 2>&1 \
  || fail "could not create the secondmate home worktree"
mkdir -p "$SM_HOME/state" "$SM_HOME/data" "$SM_HOME/config" "$SM_HOME/projects"
printf '%s\n' "$SM_ID" > "$SM_HOME/.fm-secondmate-home"
printf 'Live marker: %s\n' "$SM_MARKER" > "$SM_HOME/data/learnings.md"
printf '# Charter\n\nLive secondmate charter.\n' > "$SM_HOME/data/charter.md"

HOME="$AGY_USER_HOME" "$SM_HOME/bin/fm-agy-trust.sh" --secondmate-home "$SM_HOME" "$SM_ID" >/dev/null \
  || fail "fm-agy-trust.sh --secondmate-home refused the seeded secondmate home"
jq -e --arg p "$SM_HOME" '.trustedWorkspaces | index($p) != null' \
  "$AGY_USER_HOME/.gemini/antigravity-cli/settings.json" >/dev/null 2>&1 \
  || fail "secondmate home was not recorded in agy trustedWorkspaces"

OUT=$(run_agy "$SM_HOME" "Reply with the exact live marker token from session start context and nothing else.")
[ -f "$SM_HOME/state/.lock" ] || fail "SessionStart hook did not create state/.lock in the live secondmate home"
assert_contains "$OUT" "$SM_MARKER" "a pre-trusted secondmate home did not reach its own SessionStart digest in live agy"
pass "agy secondmate live: pre-seeded workspace trust launches straight into the secondmate home's digest"

cleanup_all
trap - EXIT
