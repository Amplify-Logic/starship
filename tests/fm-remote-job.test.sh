#!/usr/bin/env bash
# Behavior tests for the bounded remote job queue and worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
RUNTIME_BIN="$TMP_ROOT/runtime-bin"
FAKE_PERL_LOG="$TMP_ROOT/perl.log"
REAL_GIT=$(command -v git)
OTHER_PID=
RECOVERY_WORKER_PID=
REPEAT_WORKER_PID=
STALE_LOCK_WORKER_PID=
LIVE_LOCK_WORKER_PID=
LIVE_LOCK_CHALLENGER_PID=
LIVE_CLAIM_WORKER_PID=
SCRATCH_FAIL_WORKER_PID=
LATE_QUARANTINE_WORKER_PID=
LATE_QUARANTINE_PROCESS_PID=
FINISHED_RECLAIM_WORKER_PID=
FINISHED_RECLAIM_OWNER_PID=
SHUTDOWN_TEMP_WORKER_PID=
SWEPT_QUARANTINE_WORKER_PID=
DRIFT_OWNER_PID=
DRIFT_HEARTBEAT_PID=
DRIFT_CHALLENGER_PID=
ABANDONED_CLAIM_WORKER_PID=
RESTART_SUPERVISOR_PID=
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$RUNTIME_BIN"
# worker.pid records the serving child, not its restart supervisor, so stopping
# that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup_remote_job_fixture() {
  [ -z "$OTHER_PID" ] || kill "$OTHER_PID" 2>/dev/null || true
  [ -z "$RECOVERY_WORKER_PID" ] || kill "$RECOVERY_WORKER_PID" 2>/dev/null || true
  [ -z "$REPEAT_WORKER_PID" ] || kill "$REPEAT_WORKER_PID" 2>/dev/null || true
  [ -z "$STALE_LOCK_WORKER_PID" ] || kill "$STALE_LOCK_WORKER_PID" 2>/dev/null || true
  [ -z "$LIVE_LOCK_WORKER_PID" ] || kill "$LIVE_LOCK_WORKER_PID" 2>/dev/null || true
  [ -z "$LIVE_LOCK_CHALLENGER_PID" ] || kill "$LIVE_LOCK_CHALLENGER_PID" 2>/dev/null || true
  [ -z "$DRIFT_HEARTBEAT_PID" ] || kill "$DRIFT_HEARTBEAT_PID" 2>/dev/null || true
  [ -z "$DRIFT_OWNER_PID" ] || kill "$DRIFT_OWNER_PID" 2>/dev/null || true
  [ -z "$DRIFT_CHALLENGER_PID" ] || kill "$DRIFT_CHALLENGER_PID" 2>/dev/null || true
  [ -z "$ABANDONED_CLAIM_WORKER_PID" ] || kill "$ABANDONED_CLAIM_WORKER_PID" 2>/dev/null || true
  [ -z "$LIVE_CLAIM_WORKER_PID" ] || kill "$LIVE_CLAIM_WORKER_PID" 2>/dev/null || true
  [ -z "$SCRATCH_FAIL_WORKER_PID" ] || kill "$SCRATCH_FAIL_WORKER_PID" 2>/dev/null || true
  [ -z "$LATE_QUARANTINE_WORKER_PID" ] || kill -KILL "$LATE_QUARANTINE_WORKER_PID" 2>/dev/null || true
  [ -z "$LATE_QUARANTINE_PROCESS_PID" ] || kill "$LATE_QUARANTINE_PROCESS_PID" 2>/dev/null || true
  [ -z "$FINISHED_RECLAIM_WORKER_PID" ] || kill -KILL "$FINISHED_RECLAIM_WORKER_PID" 2>/dev/null || true
  [ -z "$FINISHED_RECLAIM_OWNER_PID" ] || kill "$FINISHED_RECLAIM_OWNER_PID" 2>/dev/null || true
  [ -z "$SHUTDOWN_TEMP_WORKER_PID" ] || kill -KILL "$SHUTDOWN_TEMP_WORKER_PID" 2>/dev/null || true
  [ -z "$SWEPT_QUARANTINE_WORKER_PID" ] || kill -KILL "$SWEPT_QUARANTINE_WORKER_PID" 2>/dev/null || true
  [ -z "$RESTART_SUPERVISOR_PID" ] || kill -KILL "$RESTART_SUPERVISOR_PID" 2>/dev/null || true
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_remote_job_fixture EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$ROOT/bin/fm-remote-delta-read.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
set -u
printf 'home=%s\nroot=%s\nactive=%s\npath=%s\n' "$FM_HOME" "$FM_ROOT_OVERRIDE" "${FM_REMOTE_JOB_ACTIVE:-}" "$PATH"
printf 'args:'
printf ' <%s>' "$@"
printf '\n'
if [ -n "${TOP_SECRET:-}" ]; then printf 'secret=leaked\n'; else printf 'secret=absent\n'; fi
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin=%s\n' "$line"; done
exit "${FM_PROBE_EXIT:-0}"
SH
cat > "$REMOTE_ROOT/bin/fm-timeout-job.sh" <<'SH'
#!/bin/bash
sleep 3
SH
cat > "$REMOTE_ROOT/bin/fm-delay-job.sh" <<'SH'
#!/bin/bash
sleep "$1"
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
cat > "$REMOTE_ROOT/bin/fm-shutdown-job.sh" <<'SH'
#!/bin/bash
trap '' HUP INT TERM
printf 'started\n' > "$1"
sleep 3
printf 'ran\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-output-job.sh" <<'SH'
#!/bin/bash
set -e
head -c 1200000 < /dev/zero
head -c 1200000 < /dev/zero >&2
exit 23
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
cat > "$RUNTIME_BIN/perl" <<'SH'
#!/bin/bash
printf 'invoked\n' >> "$FM_FAKE_PERL_LOG"
exit 127
SH
chmod +x "$RUNTIME_BIN/perl"

git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

DEFAULT_STATE="$TMP_ROOT/default-timeout-jobs"
DEFAULT_BOUNDS=$(
  unset FM_REMOTE_JOB_QUEUE_TIMEOUT
  unset FM_REMOTE_JOB_TIMEOUT
  # shellcheck disable=SC2030 # This source intentionally initializes subshell-only defaults.
  FM_REMOTE_JOB_STATE_ROOT="$DEFAULT_STATE"
  export FM_REMOTE_JOB_STATE_ROOT
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$ROOT/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh </dev/null >/dev/null
  printf '%s %s\n' \
    "$(cat "$DEFAULT_STATE/jobs/$FM_REMOTE_JOB_ID/queue_deadline")" \
    "$(cat "$DEFAULT_STATE/jobs/$FM_REMOTE_JOB_ID/timeout")"
)
read -r DEFAULT_QUEUE_DEADLINE DEFAULT_EXECUTION_TIMEOUT <<< "$DEFAULT_BOUNDS"
DEFAULT_QUEUE_REMAINING=$((DEFAULT_QUEUE_DEADLINE - $(date +%s)))
[ "$DEFAULT_QUEUE_REMAINING" -ge 350 ] || fail "the default queue bound is too short"
[ "$DEFAULT_EXECUTION_TIMEOUT" -ge 350 ] || fail "the default execution bound cannot contain a 300-second long poll"
pass "default queue and execution bounds independently cover long polls"

# shellcheck disable=SC2031 # The earlier assignment was confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5
# shellcheck disable=SC2031 # The sourced defaults above were confined to DEFAULT_BOUNDS.
export FM_REMOTE_JOB_TIMEOUT=5
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

LOCAL_BIN_PARENT="$ACCOUNT_HOME/.local"
LOCAL_BIN_TARGET="$TMP_ROOT/local-bin-target"
mkdir -p "$LOCAL_BIN_PARENT" "$LOCAL_BIN_TARGET"
ln -s "$LOCAL_BIN_TARGET" "$LOCAL_BIN_PARENT/bin"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$LOCAL_BIN_PARENT/bin:"*|*":$LOCAL_BIN_TARGET:"*) fail "the composed PATH followed a symlinked local bin" ;;
esac
rm -f "$LOCAL_BIN_PARENT/bin"
mkdir "$LOCAL_BIN_PARENT/bin"
pass "operator PATH excludes a symlinked local bin"

NVM_ROOT="$ACCOUNT_HOME/.nvm"
NVM_V20="$NVM_ROOT/versions/node/v20.18.0/bin"
NVM_V24="$NVM_ROOT/versions/node/v24.14.1/bin"
mkdir -p "$NVM_ROOT/alias" "$NVM_V20" "$NVM_V24"
printf '20\n' > "$NVM_ROOT/alias/default"
printf '#!/bin/bash\nprintf "20\\n"\n' > "$NVM_V20/node"
printf '#!/bin/bash\nprintf "24\\n"\n' > "$NVM_V24/node"
chmod +x "$NVM_V20/node" "$NVM_V24/node"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
NVM_SELECTED=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" node)
[ "$NVM_SELECTED" = 20 ] || fail "the composed PATH ignored nvm's default alias"
rm -f "$NVM_ROOT/alias/default"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
NVM_SELECTED=$(PATH="$FM_REMOTE_JOB_OPERATOR_PATH" node)
[ "$NVM_SELECTED" = 24 ] || fail "the nvm fallback did not select the highest installed version"
printf 'system\n' > "$NVM_ROOT/alias/default"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$NVM_V20:"*|*":$NVM_V24:"*) fail "the composed PATH ignored nvm's system default" ;;
esac
printf '20\n' > "$NVM_ROOT/alias/default"
pass "operator PATH honors nvm defaults with a deterministic fallback"

NIX_PROFILE="$ACCOUNT_HOME/.nix-profile"
NIX_BIN="$TMP_ROOT/nix-profile-bin"
mkdir -p "$NIX_PROFILE" "$NIX_BIN"
ln -s "$NIX_BIN" "$NIX_PROFILE/bin"
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
case ":$FM_REMOTE_JOB_OPERATOR_PATH:" in
  *":$NIX_BIN:"*) ;;
  *) fail "the composed PATH omitted a resolved Nix profile bin link" ;;
esac
pass "operator PATH resolves the authorized Nix profile bin link"

# Which install of a multi-version tool a remote job resolves is decided by the
# order these directories land on PATH, so the composition has to be sorted
# rather than whatever order the filesystem returns. The fixture is created in
# a deliberately unsorted order, and the expectation is the shell's own
# pathname expansion - the mechanism the portable-PATH contract in
# tests/fm-on.test.sh reconstructs.
MISE_INSTALLS="$ACCOUNT_HOME/.local/share/mise/installs"
for TOOL_VERSION in node/26.7.0 node/8.1 node/26 bun/1.4 bun/1.3.14 python/3.12.7; do
  mkdir -p "$MISE_INSTALLS/$TOOL_VERSION/bin"
done
fm_remote_job_compose_operator_path "$ACCOUNT_HOME" >/dev/null
MISE_COMPOSED=$(printf '%s\n' "$FM_REMOTE_JOB_OPERATOR_PATH" | tr ':' '\n' | grep -F "$MISE_INSTALLS/" || true)
MISE_EXPECTED=$(printf '%s\n' "$MISE_INSTALLS"/*/*/bin)
[ "$MISE_COMPOSED" = "$MISE_EXPECTED" ] \
  || fail "the composed operator PATH did not order tool installs like the shell's own expansion"$'\n'"expected: $MISE_EXPECTED"$'\n'"actual:   $MISE_COMPOSED"
# This assertion detects the defect on bash 3.2 and 5.2, where compgen -G returns unsorted glob matches, but reads green on bash 5.3+ because glob sorting moved into the glob library so both mechanisms agree there.
rm -rf -- "$ACCOUNT_HOME/.local/share/mise"
pass "operator PATH orders discovered tool installs deterministically"

HOME="$ACCOUNT_HOME" PATH="$RUNTIME_BIN:/usr/bin:/bin:/usr/sbin:/sbin" FM_FAKE_PERL_LOG="$FAKE_PERL_LOG" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=5 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the worker did not publish its readiness heartbeat"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

printf 'first line\nsecond line\n' > "$TMP_ROOT/stdin"
# shellcheck disable=SC2016 # Literal shell-looking argv is an injection probe.
TOP_SECRET=must-not-cross fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-probe-job.sh 'two words' '$(not executed)' < "$TMP_ROOT/stdin" > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
[ "$(file_mode "$JOB_DIR")" = 700 ] \
  || fail "staged job directory is not mode 0700"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the completed probe did not preserve exit status"
OUT=$(<"$FM_REMOTE_JOB_STDOUT")
assert_contains "$OUT" "home=$REMOTE_HOME" "the worker did not pass the staged FM_HOME"
assert_contains "$OUT" "root=$REMOTE_ROOT" "the worker did not pass the configured root"
assert_contains "$OUT" 'active=1' "the target did not execute inside the worker environment"
# shellcheck disable=SC2016 # Literal shell-looking expected output is an injection probe.
assert_contains "$OUT" 'args: <two words> <$(not executed)>' "the worker changed argv boundaries"
assert_contains "$OUT" 'stdin=first line' "the worker lost staged stdin"
assert_contains "$OUT" 'stdin=second line' "the worker lost staged stdin"
assert_contains "$OUT" 'secret=absent' "ambient environment crossed into the worker child"
case "$OUT" in *"$REMOTE_ROOT/bin:$ACCOUNT_HOME/.local/bin:"*) : ;; *) fail "worker PATH omitted its fixed root and account head" ;; esac
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the completed job could not be reaped"
assert_absent "$JOB_DIR" "reap retained a completed job record"
assert_absent "$FAKE_PERL_LOG" "the worker invoked an unavailable Perl runtime"
pass "the worker preserves bounded argv and stdin in an empty environment"

ACTIVE_SIDE_EFFECT="$TMP_ROOT/active-side-effect"
FM_REMOTE_JOB_TIMEOUT=10
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 4 "$ACTIVE_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the active-job readiness fixture did not begin running"
ACTIVE_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
touch -t 200001010000 "$STATE_ROOT/worker.ready"
for _ in $(seq 1 40); do
  fm_remote_job_probe "$ACCOUNT_HOME" && break
  sleep 0.05
done
fm_remote_job_probe "$ACCOUNT_HOME" || fail "the active worker did not refresh its readiness heartbeat"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
[ "$(cat "$STATE_ROOT/worker.pid")" = "$ACTIVE_WORKER_PID" ] \
  || fail "ensure replaced a healthy worker during an active job"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the active job did not complete after the readiness probe"
assert_present "$ACTIVE_SIDE_EFFECT" "the active job was interrupted by the concurrent readiness check"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the active readiness job could not be reaped"
pass "active jobs keep the worker ready for concurrent requests"

OLD_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
printf '\n' >> "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OLD_WORKER_PID" ] || fail "ensure retained a worker running stale code"
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "the replacement worker did not publish the current code identity"
pass "ensure replaces a live worker after its code changes"

RELOCATED_ROOT="$TMP_ROOT/relocated-root"
cp -R "$REMOTE_ROOT" "$RELOCATED_ROOT"
OLD_WORKER_PID=$NEW_WORKER_PID
OLD_WORKER_PGID=$(fm_remote_job_process_pgid "$OLD_WORKER_PID") \
  || fail "the worker replacement fixture could not resolve its process group"
fm_remote_job_ensure_worker "$RELOCATED_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OLD_WORKER_PID" ] || fail "ensure retained a worker bound to a different code root"
! kill -0 -- "-$OLD_WORKER_PGID" 2>/dev/null \
  || fail "ensure left the replaced worker supervisor group alive"
fm_remote_job_stage "$ACCOUNT_HOME" "$RELOCATED_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the relocated worker rejected its configured code root"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the relocated-root probe could not be reaped"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
pass "worker identity binds the canonical configured code root"

CRASHED_WORKER_PID=$NEW_WORKER_PID
kill -KILL "$CRASHED_WORKER_PID"
wait "$CRASHED_WORKER_PID" 2>/dev/null || true
assert_present "$STATE_ROOT/worker.lock" "an unclean exit did not retain the worker ownership lock"
sleep 20 &
OTHER_PID=$!
printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.pid"
printf '%s\n' "$OTHER_PID" > "$STATE_ROOT/worker.lock/pid"
touch -t 200001010000 "$STATE_ROOT/worker.ready" "$STATE_ROOT/worker.lock"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "$FM_REMOTE_JOB_ERROR"
kill -0 "$OTHER_PID" 2>/dev/null || fail "stale worker state caused an unrelated process to be signaled"
NEW_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
[ "$NEW_WORKER_PID" != "$OTHER_PID" ] || fail "the replacement adopted an unrelated persisted pid"
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail "stale ownership recovery did not start the current worker"
kill "$OTHER_PID" 2>/dev/null || true
wait "$OTHER_PID" 2>/dev/null || true
OTHER_PID=
pass "stale ownership is reclaimed without signaling a reused pid"

FM_REMOTE_JOB_TIMEOUT=1
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "the worker did not terminate an over-time job"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the timed-out job could not be reaped"
pass "the worker enforces the job timeout and publishes its result"

QUEUED_SIDE_EFFECT="$TMP_ROOT/queued-side-effect"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the blocking job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$QUEUED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
printf '%s\n' "$(fm_remote_job_read_deadline "$FIRST_JOB_DIR")" > "$STATE_ROOT/jobs/$JOB_ID/queue_deadline"
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "an expired queued job did not publish a timeout result"
assert_absent "$QUEUED_SIDE_EFFECT" "the worker executed a queued job after its durable deadline"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the blocking job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the expired queued job could not be reaped"
pass "the worker expires queued jobs before they can mutate"

FIRST_DELAYED_SIDE_EFFECT="$TMP_ROOT/first-delayed-side-effect"
SECOND_DELAYED_SIDE_EFFECT="$TMP_ROOT/second-delayed-side-effect"
FM_REMOTE_JOB_QUEUE_TIMEOUT=5
FM_REMOTE_JOB_TIMEOUT=3
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 1.8 "$FIRST_DELAYED_SIDE_EFFECT" < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the first delayed job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 1.8 "$SECOND_DELAYED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "queue time consumed the second job's execution timeout"
assert_present "$SECOND_DELAYED_SIDE_EFFECT" "the queued job did not receive its full execution timeout"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the first delayed job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the second delayed job could not be reaped"
pass "queued jobs receive a fresh bounded execution window"

if command -v shasum >/dev/null 2>&1; then
  EMPTY_SHA=$(: | shasum -a 256 | awk '{print $1}')
else
  EMPTY_SHA=$(: | sha256sum | awk '{print $1}')
fi
mkdir -p "$REMOTE_HOME/state"
REPLY_LOG_REL=state/parent-replies.status
PREEMPT_SIDE_EFFECT="$TMP_ROOT/preempt-side-effect"
FM_REMOTE_JOB_QUEUE_TIMEOUT=60
FM_REMOTE_JOB_TIMEOUT=40
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 30 < /dev/null > /dev/null
POLL_JOB_ID=$FM_REMOTE_JOB_ID
POLL_JOB_DIR="$STATE_ROOT/jobs/$POLL_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$POLL_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$POLL_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the long-poll job did not begin running"
PREEMPT_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-touch-job.sh "$PREEMPT_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
PREEMPT_ELAPSED=$(( $(date +%s) - PREEMPT_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the short command behind a long poll did not complete"
assert_present "$PREEMPT_SIDE_EFFECT" "the short command behind a long poll did not run"
[ "$PREEMPT_ELAPSED" -le 10 ] || fail "a queued short command waited a full poll window behind the long poll"
fm_remote_job_wait "$ACCOUNT_HOME" "$POLL_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq "$FM_REMOTE_JOB_PREEMPTED_EXIT" ] \
  || fail "a preempted long poll was not distinguished from an elapsed window"
[ ! -s "$FM_REMOTE_JOB_STDOUT" ] || fail "a preempted long poll published partial stdout"
[ ! -s "$FM_REMOTE_JOB_STDERR" ] || fail "a preempted long poll published partial stderr"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the short command could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$POLL_JOB_ID" || fail "the preempted poll could not be reaped"
pass "a queued short command preempts a running long poll instead of waiting its window"

printf 'hello after preemption\n' > "$REMOTE_HOME/$REPLY_LOG_REL"
FM_REMOTE_JOB_TIMEOUT=10
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 5 < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the re-armed poll after preemption did not complete"
OUT=$(<"$FM_REMOTE_JOB_STDOUT")
assert_contains "$OUT" 'status=delta' "the re-armed poll did not return a delta from the preserved cursor"
assert_contains "$OUT" 'hello after preemption' "the re-armed poll lost data appended around the preemption"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the re-armed poll could not be reaped"
rm -f -- "$REMOTE_HOME/$REPLY_LOG_REL"
pass "a poll re-armed after preemption reads the same cursor with nothing lost"

FM_REMOTE_JOB_TIMEOUT=15
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 6 < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || fail "the first sibling poll did not begin running"
POLL_PAIR_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-remote-delta-read.sh "$REPLY_LOG_REL" 0 "$EMPTY_SHA" 1 < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
POLL_PAIR_ELAPSED=$(( $(date +%s) - POLL_PAIR_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 75 ] || fail "the first sibling poll did not close its own window"
[ "$POLL_PAIR_ELAPSED" -ge 4 ] || fail "a queued sibling poll preempted a running poll"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 75 ] || fail "the queued sibling poll did not run after the first window"
fm_remote_job_reap "$ACCOUNT_HOME" "$FIRST_JOB_ID" || fail "the first sibling poll could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the queued sibling poll could not be reaped"
FM_REMOTE_JOB_QUEUE_TIMEOUT=5
pass "sibling polls never preempt each other into a re-arm churn loop"

STARTED="$TMP_ROOT/shutdown-started"
SHUTDOWN_SIDE_EFFECT="$TMP_ROOT/shutdown-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$STARTED" "$SHUTDOWN_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
for _ in $(seq 1 100); do
  [ -f "$STARTED" ] && break
  sleep 0.05
done
assert_present "$STARTED" "the shutdown fixture did not begin executing"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
for _ in $(seq 1 100); do
  kill -0 "$WORKER_PID" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$WORKER_PID" 2>/dev/null && fail "the worker did not finish its TERM shutdown"
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=1 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the replacement worker did not become ready"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 125 ] || fail "the interrupted job did not publish an unknown-completion result"
sleep 3
assert_absent "$SHUTDOWN_SIDE_EFFECT" "the active command mutated after worker shutdown"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the interrupted job could not be reaped"
pass "worker shutdown terminates the active command tree before replacement"

CRASH_STARTED="$TMP_ROOT/crash-started"
CRASH_SIDE_EFFECT="$TMP_ROOT/crash-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$CRASH_STARTED" "$CRASH_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
for _ in $(seq 1 100); do
  [ -f "$CRASH_STARTED" ] && break
  sleep 0.05
done
assert_present "$CRASH_STARTED" "the crash fixture did not begin executing"
CRASHED_WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -KILL "$CRASHED_WORKER_PID"
for _ in $(seq 1 200); do
  RESTARTED_WORKER_PID=$(cat "$STATE_ROOT/worker.pid" 2>/dev/null || true)
  [ -n "$RESTARTED_WORKER_PID" ] && [ "$RESTARTED_WORKER_PID" != "$CRASHED_WORKER_PID" ] && break
  sleep 0.05
done
[ -n "${RESTARTED_WORKER_PID:-}" ] && [ "$RESTARTED_WORKER_PID" != "$CRASHED_WORKER_PID" ] \
  || fail "the Linux supervisor did not restart a crashed worker"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 125 ] || fail "worker crash recovery did not publish unknown completion"
sleep 3
assert_absent "$CRASH_SIDE_EFFECT" "an orphaned command mutated after worker crash recovery"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the crash-recovered job could not be reaped"
fm_remote_job_probe "$ACCOUNT_HOME" || fail "the restarted worker did not remain ready"
pass "Linux supervision recovers crashes and stops orphaned commands"

mkdir -p "$ACCOUNT_HOME/.local/bin"
PREEXEC_STARTED="$TMP_ROOT/preexecution-started"
PREEXEC_FINISHED="$TMP_ROOT/preexecution-finished"
cat > "$ACCOUNT_HOME/.local/bin/git" <<SH
#!/bin/bash
if [ "\${3:-}" = ls-files ]; then
  printf 'started\n' > "$PREEXEC_STARTED"
  sleep 30
  printf 'finished\n' > "$PREEXEC_FINISHED"
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$ACCOUNT_HOME/.local/bin/git"
FM_REMOTE_JOB_TIMEOUT=3
PREEXEC_BEGAN=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
PREEXEC_ELAPSED=$(( $(date +%s) - PREEXEC_BEGAN ))
[ "$FM_REMOTE_JOB_EXIT" -eq 124 ] || fail "the pre-execution deadline did not publish a timeout result"
assert_present "$PREEXEC_STARTED" "the pre-execution timeout fixture did not enter tracked-command validation"
assert_absent "$PREEXEC_FINISHED" "tracked-command validation continued after the job timeout"
[ "$PREEXEC_ELAPSED" -le 7 ] || fail "tracked-command validation exceeded the job timeout bound"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the pre-execution timeout leaked output readers or FIFOs"
rm -f -- "$ACCOUNT_HOME/.local/bin/git"
pass "pre-execution validation obeys the job timeout"

fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-output-job.sh < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 23 ] || fail "bounded output changed the command exit status"
OUTPUT_BYTES=$(LC_ALL=C wc -c < "$FM_REMOTE_JOB_STDOUT" | tr -d ' ')
[ "$OUTPUT_BYTES" -le "$FM_REMOTE_JOB_MAX_BYTES" ] || fail "the worker retained output beyond its byte bound"
ERROR_BYTES=$(LC_ALL=C wc -c < "$FM_REMOTE_JOB_STDERR" | tr -d ' ')
[ "$ERROR_BYTES" -le "$FM_REMOTE_JOB_MAX_BYTES" ] || fail "the worker retained stderr beyond its byte bound"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "the bounded-output job could not be reaped"
pass "the worker drains bounded output without changing command results"

SIDE_EFFECT="$TMP_ROOT/side-effect"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
fm_remote_job_stop_worker_tree "$WORKER_PID" \
  || fail "the worker tree did not stop before the staged-record tamper"
assert_absent "$STATE_ROOT/worker.pid" "the worker did not clear its pid before the staged-record tamper"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
rm -f -- "$JOB_DIR/argv"
ln -s "$TMP_ROOT/not-an-argv" "$JOB_DIR/argv"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 126 ] || fail "the worker accepted a symlinked argv record"
assert_absent "$SIDE_EFFECT" "the worker executed a job after its argv changed to a symlink"
pass "the worker refuses symlinked job fields before command execution"

QUARANTINE_STARTED="$TMP_ROOT/quarantine-started"
QUARANTINE_SIDE_EFFECT="$TMP_ROOT/quarantine-side-effect"
FM_REMOTE_JOB_TIMEOUT=5
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-shutdown-job.sh "$QUARANTINE_STARTED" "$QUARANTINE_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
for _ in $(seq 1 100); do
  [ -f "$QUARANTINE_STARTED" ] && break
  sleep 0.05
done
assert_present "$QUARANTINE_STARTED" "the quarantine fixture did not begin executing"
GROUP_PID=$(cat "$JOB_DIR/.claim/group")
printf 'invalid\n' > "$JOB_DIR/.claim/group"
WORKER_PID=$(cat "$STATE_ROOT/worker.pid")
kill -TERM "$WORKER_PID"
wait "$WORKER_PID" 2>/dev/null || true
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.lock/quarantine" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.lock/quarantine" "failed shutdown released worker ownership"
fm_remote_job_probe "$ACCOUNT_HOME" && fail "quarantined worker ownership still reported ready"
set +e
HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  >> "$TMP_ROOT/worker.out" 2>> "$TMP_ROOT/worker.err"
REPLACEMENT_RC=$?
set -e
[ "$REPLACEMENT_RC" -ne 0 ] || fail "a replacement worker ignored quarantined ownership"
assert_present "$STATE_ROOT/worker.lock/quarantine" "a replacement removed quarantined ownership"
kill -KILL -- "-$GROUP_PID" 2>/dev/null || true
sleep 3
assert_absent "$QUARANTINE_SIDE_EFFECT" "the quarantined command mutated after explicit termination"
pass "failed shutdown quarantines ownership against replacement workers"

RECOVERY_HOME="$TMP_ROOT/recovery-account"
RECOVERY_STATE="$TMP_ROOT/recovery-jobs"
RECOVERY_JOB="$RECOVERY_STATE/jobs/job-quarantine"
mkdir -p "$RECOVERY_HOME" "$RECOVERY_STATE/jobs" "$RECOVERY_STATE/logs" \
  "$RECOVERY_STATE/worker.lock" "$RECOVERY_JOB/.claim"
chmod 700 "$RECOVERY_HOME" "$RECOVERY_STATE" "$RECOVERY_STATE/jobs" "$RECOVERY_STATE/logs" \
  "$RECOVERY_STATE/worker.lock" "$RECOVERY_JOB" "$RECOVERY_JOB/.claim"
sleep 20 &
QUARANTINED_PROCESS_PID=$!
sleep 0.01 &
QUARANTINE_OWNER_PID=$!
wait "$QUARANTINE_OWNER_PID" 2>/dev/null || true
printf '%s\n' "$QUARANTINE_OWNER_PID" > "$RECOVERY_STATE/worker.lock/pid"
printf 'stale\n' > "$RECOVERY_STATE/worker.lock/start"
printf 'stale\n' > "$RECOVERY_STATE/worker.lock/command"
printf 'active execution could not be confirmed stopped\n' > "$RECOVERY_STATE/worker.lock/quarantine"
printf 'running\n' > "$RECOVERY_JOB/state"
printf '%s\n' "$QUARANTINE_OWNER_PID" > "$RECOVERY_JOB/.claim/owner"
printf '%s\n' "$QUARANTINED_PROCESS_PID" > "$RECOVERY_JOB/.claim/supervisor"
: > "$RECOVERY_JOB/stdout"
: > "$RECOVERY_JOB/stderr"
chmod 600 "$RECOVERY_STATE/worker.lock"/* "$RECOVERY_JOB/state" "$RECOVERY_JOB/.claim"/* \
  "$RECOVERY_JOB/stdout" "$RECOVERY_JOB/stderr"
touch -t 200001010000 "$RECOVERY_STATE/worker.lock"
set +e
HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RECOVERY_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/recovery-refused.out" 2> "$TMP_ROOT/recovery-refused.err"
RECOVERY_REFUSED_RC=$?
set -e
[ "$RECOVERY_REFUSED_RC" -ne 0 ] || fail "quarantine recovery ignored a recorded live process"
assert_present "$RECOVERY_STATE/worker.lock/quarantine" "a live recorded process lost quarantine protection"
printf '%s\n' "$QUARANTINED_PROCESS_PID" > "$RECOVERY_JOB/.claim/owner"
printf 'stale owner identity\n' > "$RECOVERY_JOB/.claim/owner_start"
printf 'stale supervisor identity\n' > "$RECOVERY_JOB/.claim/supervisor_start"
chmod 600 "$RECOVERY_JOB/.claim/owner" "$RECOVERY_JOB/.claim/owner_start" \
  "$RECOVERY_JOB/.claim/supervisor_start"
HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$RECOVERY_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" \
  > "$TMP_ROOT/recovery-worker.out" 2> "$TMP_ROOT/recovery-worker.err" &
RECOVERY_WORKER_PID=$!
for _ in $(seq 1 300); do
  [ -f "$RECOVERY_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$RECOVERY_STATE/worker.ready" "a reused supervisor pid did not permit worker recovery"
assert_absent "$RECOVERY_STATE/worker.lock/quarantine" "recovered worker retained stale quarantine"
kill -0 "$QUARANTINED_PROCESS_PID" 2>/dev/null \
  || fail "worker recovery signalled a process whose supervisor identity did not match"
kill -TERM "$RECOVERY_WORKER_PID"
wait "$RECOVERY_WORKER_PID" 2>/dev/null || true
RECOVERY_WORKER_PID=
kill "$QUARANTINED_PROCESS_PID" 2>/dev/null || true
wait "$QUARANTINED_PROCESS_PID" 2>/dev/null || true
pass "quarantine recovery refuses unverifiable supervisors and ignores reused pids"

# A replacement stops a Linux worker by signalling its whole isolated group, and
# the supervisor in that group forwards a second stop signal to the same serving
# child, so the serving child is always signalled more than once. Signal a small
# bounded burst and then keep signalling until it is gone: the first signal
# starts the shutdown and every later one lands inside it, the same way the group
# signal and the forwarded signal do. A shutdown that dies part way through
# leaves its ownership lock behind holding a half-written temp file. Acquire
# reclaim clears those leftovers, but this case still pins that shutdown itself
# ignores the repeat so it can finish and release ownership without a race.
#
# The burst is bounded and the follow-up signals are paced deliberately. An
# unpaced signal loop delivers hundreds of thousands of signals per second,
# which corrupts the signalled bash's own pending-trap bookkeeping ("warning:
# run_pending_traps: bad value in trap_list[15]") and then kills it part way
# through the shutdown with SIGTERM or SIGSEGV. That reports a shutdown defect
# this worker does not have. Ten back-to-back signals still all land inside the
# shutdown's first file operation, so the repeat this pins is unchanged: with
# the default disposition restored instead of ignored, the ownership lock is
# left behind every run.
REPEAT_HOME="$TMP_ROOT/repeat-signal-account"
REPEAT_STATE="$TMP_ROOT/repeat-signal-jobs"
mkdir -p "$REPEAT_HOME"
chmod 700 "$REPEAT_HOME"
HOME="$REPEAT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$REPEAT_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/repeat-signal.out" 2> "$TMP_ROOT/repeat-signal.err" &
REPEAT_WORKER_PID=$!
for _ in $(seq 1 300); do
  [ -f "$REPEAT_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$REPEAT_STATE/worker.ready" "the repeated-signal worker did not become ready"
REPEAT_DEADLINE=$((SECONDS + 30))
REPEAT_BURST=0
while [ "$REPEAT_BURST" -lt 10 ]; do
  kill -TERM "$REPEAT_WORKER_PID" 2>/dev/null || true
  REPEAT_BURST=$((REPEAT_BURST + 1))
done
while kill -0 "$REPEAT_WORKER_PID" 2>/dev/null && [ "$SECONDS" -lt "$REPEAT_DEADLINE" ]; do
  kill -TERM "$REPEAT_WORKER_PID" 2>/dev/null || true
  sleep 0.05
done
if kill -0 "$REPEAT_WORKER_PID" 2>/dev/null; then
  kill -KILL "$REPEAT_WORKER_PID" 2>/dev/null || true
  wait "$REPEAT_WORKER_PID" 2>/dev/null || true
  REPEAT_WORKER_PID=
  fail "the repeatedly signalled worker never finished its shutdown"
fi
wait "$REPEAT_WORKER_PID" 2>/dev/null || true
REPEAT_WORKER_PID=
assert_absent "$REPEAT_STATE/worker.lock" \
  "a repeatedly signalled shutdown left its ownership lock behind"
assert_absent "$REPEAT_STATE/worker.ready" \
  "a repeatedly signalled shutdown left its readiness heartbeat behind"
HOME="$REPEAT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$REPEAT_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  >> "$TMP_ROOT/repeat-signal.out" 2>> "$TMP_ROOT/repeat-signal.err" &
REPEAT_WORKER_PID=$!
for _ in $(seq 1 600); do
  [ -f "$REPEAT_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$REPEAT_STATE/worker.ready" \
  "the worker after a repeatedly signalled shutdown never reported ready"
kill -TERM "$REPEAT_WORKER_PID"
wait "$REPEAT_WORKER_PID" 2>/dev/null || true
REPEAT_WORKER_PID=
pass "a repeatedly signalled shutdown still releases ownership for the next worker"

# Crash or a shutdown killed part way through leaves the ownership directory
# holding half-written mktemp files. Reclaim used to remove only pid/start/command
# and then rmdir, so those leftovers made every later worker exit 1 and the
# supervisor restart-storm. A dead owner, leftover temps, and a leftover
# heartbeat must all be reclaimable; a live owner that still heartbeats must not
# be stolen.
STALE_LOCK_HOME="$TMP_ROOT/stale-lock-account"
STALE_LOCK_STATE="$TMP_ROOT/stale-lock-jobs"
mkdir -p "$STALE_LOCK_HOME" "$STALE_LOCK_STATE/worker.lock"
chmod 700 "$STALE_LOCK_HOME" "$STALE_LOCK_STATE" "$STALE_LOCK_STATE/worker.lock"
printf '999999\n' > "$STALE_LOCK_STATE/worker.lock/pid"
printf 'stale-start\n' > "$STALE_LOCK_STATE/worker.lock/start"
printf 'stale-command\n' > "$STALE_LOCK_STATE/worker.lock/command"
printf 'interrupted\n' > "$STALE_LOCK_STATE/worker.lock/.pid.XXXXXX"
printf 'interrupted\n' > "$STALE_LOCK_STATE/worker.lock/.start.XXXXXX"
printf 'interrupted\n' > "$STALE_LOCK_STATE/worker.lock/.command.XXXXXX"
printf 'interrupted\n' > "$STALE_LOCK_STATE/worker.lock/.quarantine.XXXXXX"
printf '999999\n' > "$STALE_LOCK_STATE/worker.pid"
printf '999999\n' > "$STALE_LOCK_STATE/worker.ready"
chmod 600 "$STALE_LOCK_STATE/worker.lock"/* "$STALE_LOCK_STATE/worker.lock"/.[!.]* \
  "$STALE_LOCK_STATE/worker.pid" "$STALE_LOCK_STATE/worker.ready"
touch -t 200001010000 "$STALE_LOCK_STATE/worker.lock" "$STALE_LOCK_STATE/worker.ready" \
  "$STALE_LOCK_STATE/worker.pid"
HOME="$STALE_LOCK_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STALE_LOCK_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/stale-lock.out" 2> "$TMP_ROOT/stale-lock.err" &
STALE_LOCK_WORKER_PID=$!
STALE_LOCK_READY=
for _ in $(seq 1 300); do
  STALE_LOCK_READY=$(cat "$STALE_LOCK_STATE/worker.ready" 2>/dev/null || true)
  case "$STALE_LOCK_READY" in
    ''|999999) ;;
    *) kill -0 "$STALE_LOCK_READY" 2>/dev/null && break ;;
  esac
  if ! kill -0 "$STALE_LOCK_WORKER_PID" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if ! kill -0 "$STALE_LOCK_WORKER_PID" 2>/dev/null; then
  wait "$STALE_LOCK_WORKER_PID" 2>/dev/null || true
  STALE_LOCK_WORKER_PID=
  fail "a stale leftover lock made the next worker exit instead of reclaiming: $(cat "$TMP_ROOT/stale-lock.err")"
fi
case "$STALE_LOCK_READY" in
  ''|999999) fail "the worker did not reclaim a stale leftover ownership lock" ;;
esac
kill -0 "$STALE_LOCK_READY" 2>/dev/null \
  || fail "the reclaimed worker pid is not alive"
kill -TERM "$STALE_LOCK_WORKER_PID"
wait "$STALE_LOCK_WORKER_PID" 2>/dev/null || true
STALE_LOCK_WORKER_PID=
pass "a stale leftover ownership lock is reclaimed by the next worker"

LIVE_LOCK_HOME="$TMP_ROOT/live-lock-account"
LIVE_LOCK_STATE="$TMP_ROOT/live-lock-jobs"
mkdir -p "$LIVE_LOCK_HOME"
chmod 700 "$LIVE_LOCK_HOME"
HOME="$LIVE_LOCK_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$LIVE_LOCK_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/live-lock.out" 2> "$TMP_ROOT/live-lock.err" &
LIVE_LOCK_WORKER_PID=$!
for _ in $(seq 1 300); do
  [ -f "$LIVE_LOCK_STATE/worker.ready" ] && break
  sleep 0.05
done
assert_present "$LIVE_LOCK_STATE/worker.ready" "the live owner did not become ready"
LIVE_LOCK_PID=$(cat "$LIVE_LOCK_STATE/worker.ready")
kill -0 "$LIVE_LOCK_PID" 2>/dev/null || fail "the live owner pid is not alive"
HOME="$LIVE_LOCK_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$LIVE_LOCK_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/live-lock-challenger.out" 2> "$TMP_ROOT/live-lock-challenger.err" &
LIVE_LOCK_CHALLENGER_PID=$!
LIVE_LOCK_CHALLENGER_DEADLINE=$((SECONDS + 5))
while kill -0 "$LIVE_LOCK_CHALLENGER_PID" 2>/dev/null && [ "$SECONDS" -lt "$LIVE_LOCK_CHALLENGER_DEADLINE" ]; do
  sleep 0.05
done
if kill -0 "$LIVE_LOCK_CHALLENGER_PID" 2>/dev/null; then
  kill -TERM "$LIVE_LOCK_CHALLENGER_PID" 2>/dev/null || true
  wait "$LIVE_LOCK_CHALLENGER_PID" 2>/dev/null || true
  LIVE_LOCK_CHALLENGER_PID=
  fail "a challenger waited on a live owner instead of leaving the lock in place"
fi
set +e
wait "$LIVE_LOCK_CHALLENGER_PID"
LIVE_LOCK_CHALLENGER_RC=$?
set -e
LIVE_LOCK_CHALLENGER_PID=
[ "$LIVE_LOCK_CHALLENGER_RC" -eq 0 ] \
  || fail "a challenger stole or failed against a live owner (rc=$LIVE_LOCK_CHALLENGER_RC): $(cat "$TMP_ROOT/live-lock-challenger.err")"
[ "$(cat "$LIVE_LOCK_STATE/worker.lock/pid")" = "$LIVE_LOCK_PID" ] \
  || fail "a challenger replaced a live owner's lock pid"
kill -0 "$LIVE_LOCK_PID" 2>/dev/null || fail "a challenger killed the live owner"
kill -TERM "$LIVE_LOCK_WORKER_PID"
wait "$LIVE_LOCK_WORKER_PID" 2>/dev/null || true
LIVE_LOCK_WORKER_PID=
pass "a live owner that still heartbeats is not stolen"

# A live owner is only recognised by its recorded ps start and command, and a
# suspend/resume can change what ps reports for a process that never died. The
# owner is still alive and still refreshing its heartbeat, so that fresh
# heartbeat has to keep the lock: a challenger must leave the records alone
# rather than sweep a live owner out and serve the same account queue alongside
# it. Once the heartbeat does go stale the same challenger must still reclaim,
# so the guard cannot become the restart storm it replaced.
DRIFT_HOME="$TMP_ROOT/drift-lock-account"
DRIFT_STATE="$TMP_ROOT/drift-lock-jobs"
mkdir -p "$DRIFT_HOME" "$DRIFT_STATE/worker.lock"
chmod 700 "$DRIFT_HOME" "$DRIFT_STATE" "$DRIFT_STATE/worker.lock"
sleep 300 &
DRIFT_OWNER_PID=$!
printf '%s\n' "$DRIFT_OWNER_PID" > "$DRIFT_STATE/worker.lock/pid"
printf 'Thu Jan  1 00:00:00 2000\n' > "$DRIFT_STATE/worker.lock/start"
printf 'a command ps no longer reports\n' > "$DRIFT_STATE/worker.lock/command"
printf '%s\n' "$DRIFT_OWNER_PID" > "$DRIFT_STATE/worker.pid"
printf '%s\n' "$DRIFT_OWNER_PID" > "$DRIFT_STATE/worker.ready"
chmod 600 "$DRIFT_STATE/worker.lock"/* "$DRIFT_STATE/worker.pid" "$DRIFT_STATE/worker.ready"
touch -t 200001010000 "$DRIFT_STATE/worker.lock"
while kill -0 "$DRIFT_OWNER_PID" 2>/dev/null; do
  touch "$DRIFT_STATE/worker.ready" 2>/dev/null || break
  sleep 1
done &
DRIFT_HEARTBEAT_PID=$!
HOME="$DRIFT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$DRIFT_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/drift-lock.out" 2> "$TMP_ROOT/drift-lock.err" &
DRIFT_CHALLENGER_PID=$!
DRIFT_DEADLINE=$((SECONDS + 2))
while [ "$SECONDS" -lt "$DRIFT_DEADLINE" ]; do
  [ "$(cat "$DRIFT_STATE/worker.lock/pid" 2>/dev/null || true)" = "$DRIFT_OWNER_PID" ] \
    || fail "a challenger swept a live owner whose recorded ps records had drifted"
  kill -0 "$DRIFT_CHALLENGER_PID" 2>/dev/null \
    || fail "a challenger failed against a heartbeating owner: $(cat "$TMP_ROOT/drift-lock.err")"
  sleep 0.25
done
kill -0 "$DRIFT_OWNER_PID" 2>/dev/null || fail "a challenger killed the drifted owner"
kill "$DRIFT_HEARTBEAT_PID" 2>/dev/null || true
wait "$DRIFT_HEARTBEAT_PID" 2>/dev/null || true
DRIFT_HEARTBEAT_PID=
DRIFT_DEAD_OWNER_PID=$DRIFT_OWNER_PID
kill "$DRIFT_OWNER_PID" 2>/dev/null || true
wait "$DRIFT_OWNER_PID" 2>/dev/null || true
DRIFT_OWNER_PID=
DRIFT_READY=
for _ in $(seq 1 600); do
  DRIFT_READY=$(cat "$DRIFT_STATE/worker.ready" 2>/dev/null || true)
  case "$DRIFT_READY" in
    ''|"$DRIFT_DEAD_OWNER_PID") ;;
    *) kill -0 "$DRIFT_READY" 2>/dev/null && break ;;
  esac
  kill -0 "$DRIFT_CHALLENGER_PID" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$DRIFT_CHALLENGER_PID" 2>/dev/null \
  || fail "the deferring challenger exited instead of reclaiming a lock gone stale: $(cat "$TMP_ROOT/drift-lock.err")"
kill -0 "${DRIFT_READY:-0}" 2>/dev/null \
  || fail "the deferring challenger never reclaimed the lock once the heartbeat went stale"
kill -TERM "$DRIFT_CHALLENGER_PID"
wait "$DRIFT_CHALLENGER_PID" 2>/dev/null || true
DRIFT_CHALLENGER_PID=
pass "a heartbeating owner with drifted ps records is deferred to until it goes stale"

# Reclaim is single-writer: the winner holds a claim marker inside the ownership
# directory while it sweeps, so a loser cannot delete the records the winner
# publishes. A reclaimer killed while holding that marker must not wedge the
# account forever, so a marker left behind on an otherwise stale lock is taken
# over by the next worker once the marker itself has gone stale.
ABANDONED_HOME="$TMP_ROOT/abandoned-claim-account"
ABANDONED_STATE="$TMP_ROOT/abandoned-claim-jobs"
mkdir -p "$ABANDONED_HOME" "$ABANDONED_STATE/worker.lock/claim"
chmod 700 "$ABANDONED_HOME" "$ABANDONED_STATE" "$ABANDONED_STATE/worker.lock" \
  "$ABANDONED_STATE/worker.lock/claim"
printf '999999\n' > "$ABANDONED_STATE/worker.lock/pid"
printf 'stale-start\n' > "$ABANDONED_STATE/worker.lock/start"
printf 'stale-command\n' > "$ABANDONED_STATE/worker.lock/command"
printf '999999\n' > "$ABANDONED_STATE/worker.ready"
chmod 600 "$ABANDONED_STATE/worker.lock"/pid "$ABANDONED_STATE/worker.lock"/start \
  "$ABANDONED_STATE/worker.lock"/command "$ABANDONED_STATE/worker.ready"
touch -t 200001010000 "$ABANDONED_STATE/worker.lock/claim" "$ABANDONED_STATE/worker.ready" \
  "$ABANDONED_STATE/worker.lock"
HOME="$ABANDONED_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$ABANDONED_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/abandoned-claim.out" 2> "$TMP_ROOT/abandoned-claim.err" &
ABANDONED_CLAIM_WORKER_PID=$!
ABANDONED_READY=
for _ in $(seq 1 300); do
  ABANDONED_READY=$(cat "$ABANDONED_STATE/worker.ready" 2>/dev/null || true)
  case "$ABANDONED_READY" in
    ''|999999) ;;
    *) kill -0 "$ABANDONED_READY" 2>/dev/null && break ;;
  esac
  kill -0 "$ABANDONED_CLAIM_WORKER_PID" 2>/dev/null || break
  sleep 0.05
done
if ! kill -0 "$ABANDONED_CLAIM_WORKER_PID" 2>/dev/null; then
  wait "$ABANDONED_CLAIM_WORKER_PID" 2>/dev/null || true
  ABANDONED_CLAIM_WORKER_PID=
  fail "an abandoned reclaim marker wedged the next worker: $(cat "$TMP_ROOT/abandoned-claim.err")"
fi
case "$ABANDONED_READY" in
  ''|999999) fail "the worker did not take over a lock left behind by a killed reclaimer" ;;
esac
assert_absent "$ABANDONED_STATE/worker.lock/claim" \
  "the reclaiming worker left its claim marker behind"
kill -TERM "$ABANDONED_CLAIM_WORKER_PID"
wait "$ABANDONED_CLAIM_WORKER_PID" 2>/dev/null || true
ABANDONED_CLAIM_WORKER_PID=
pass "a lock left claimed by a killed reclaimer is taken over, not wedged"

# The marker a reclaiming worker holds is only abandoned once the marker itself
# has gone stale. The ownership directory around it can be arbitrarily old - a
# dead owner published its records long ago - so reading that directory's age
# instead would let a challenger rename a peer's live marker aside and reclaim
# alongside it. A fresh marker on an otherwise stale lock has to be left exactly
# as it stands while the challenger exits 0.
LIVE_CLAIM_HOME="$TMP_ROOT/live-claim-account"
LIVE_CLAIM_STATE="$TMP_ROOT/live-claim-jobs"
mkdir -p "$LIVE_CLAIM_HOME" "$LIVE_CLAIM_STATE/worker.lock"
chmod 700 "$LIVE_CLAIM_HOME" "$LIVE_CLAIM_STATE" "$LIVE_CLAIM_STATE/worker.lock"
printf '999999\n' > "$LIVE_CLAIM_STATE/worker.lock/pid"
printf 'stale-start\n' > "$LIVE_CLAIM_STATE/worker.lock/start"
printf 'stale-command\n' > "$LIVE_CLAIM_STATE/worker.lock/command"
printf '999999\n' > "$LIVE_CLAIM_STATE/worker.ready"
chmod 600 "$LIVE_CLAIM_STATE/worker.lock"/* "$LIVE_CLAIM_STATE/worker.ready"
mkdir "$LIVE_CLAIM_STATE/worker.lock/claim"
chmod 700 "$LIVE_CLAIM_STATE/worker.lock/claim"
touch -t 200001010000 "$LIVE_CLAIM_STATE/worker.lock" "$LIVE_CLAIM_STATE/worker.ready"
HOME="$LIVE_CLAIM_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$LIVE_CLAIM_STATE" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/live-claim.out" 2> "$TMP_ROOT/live-claim.err" &
LIVE_CLAIM_WORKER_PID=$!
LIVE_CLAIM_DEADLINE=$((SECONDS + 8))
while kill -0 "$LIVE_CLAIM_WORKER_PID" 2>/dev/null && [ "$SECONDS" -lt "$LIVE_CLAIM_DEADLINE" ]; do
  sleep 0.05
done
if kill -0 "$LIVE_CLAIM_WORKER_PID" 2>/dev/null; then
  kill -TERM "$LIVE_CLAIM_WORKER_PID" 2>/dev/null || true
  wait "$LIVE_CLAIM_WORKER_PID" 2>/dev/null || true
  LIVE_CLAIM_WORKER_PID=
  fail "a challenger did not defer to a peer's fresh reclaim marker"
fi
set +e
wait "$LIVE_CLAIM_WORKER_PID"
LIVE_CLAIM_RC=$?
set -e
LIVE_CLAIM_WORKER_PID=
[ "$LIVE_CLAIM_RC" -eq 0 ] \
  || fail "a challenger failed instead of deferring to a peer's reclaim marker (rc=$LIVE_CLAIM_RC): $(cat "$TMP_ROOT/live-claim.err")"
assert_present "$LIVE_CLAIM_STATE/worker.lock/claim" \
  "a challenger took over a peer's fresh reclaim marker"
[ "$(cat "$LIVE_CLAIM_STATE/worker.lock/pid")" = 999999 ] \
  || fail "a challenger reclaimed a lock a peer was still claiming"
pass "a peer's fresh reclaim marker is deferred to, not taken over"

# Taking over an abandoned marker needs a scratch directory, and failing to make
# one is a local resource failure - a full or read-only state root - not proof
# that a peer owns the lock. Reporting it as ownership would exit 0, which the
# Linux supervisor reads as a clean stop and never restarts, leaving the account
# with no worker at all. It has to stay retryable instead.
SCRATCH_FAIL_HOME="$TMP_ROOT/scratch-fail-account"
SCRATCH_FAIL_STATE="$TMP_ROOT/scratch-fail-jobs"
SCRATCH_FAIL_BIN="$TMP_ROOT/scratch-fail-bin"
mkdir -p "$SCRATCH_FAIL_HOME" "$SCRATCH_FAIL_STATE/worker.lock/claim" "$SCRATCH_FAIL_BIN"
chmod 700 "$SCRATCH_FAIL_HOME" "$SCRATCH_FAIL_STATE" "$SCRATCH_FAIL_STATE/worker.lock" \
  "$SCRATCH_FAIL_STATE/worker.lock/claim"
cat > "$SCRATCH_FAIL_BIN/mktemp" <<SH
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in *.claim.XXXXXX) exit 1 ;; esac
done
exec $(command -v mktemp) "\$@"
SH
chmod 755 "$SCRATCH_FAIL_BIN/mktemp"
printf '999999\n' > "$SCRATCH_FAIL_STATE/worker.lock/pid"
printf 'stale-start\n' > "$SCRATCH_FAIL_STATE/worker.lock/start"
printf 'stale-command\n' > "$SCRATCH_FAIL_STATE/worker.lock/command"
printf '999999\n' > "$SCRATCH_FAIL_STATE/worker.ready"
chmod 600 "$SCRATCH_FAIL_STATE/worker.lock"/pid "$SCRATCH_FAIL_STATE/worker.lock"/start \
  "$SCRATCH_FAIL_STATE/worker.lock"/command "$SCRATCH_FAIL_STATE/worker.ready"
touch -t 200001010000 "$SCRATCH_FAIL_STATE/worker.lock/claim" "$SCRATCH_FAIL_STATE/worker.ready" \
  "$SCRATCH_FAIL_STATE/worker.lock"
HOME="$SCRATCH_FAIL_HOME" PATH="$SCRATCH_FAIL_BIN:$PATH" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$SCRATCH_FAIL_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/scratch-fail.out" 2> "$TMP_ROOT/scratch-fail.err" &
SCRATCH_FAIL_WORKER_PID=$!
SCRATCH_FAIL_DEADLINE=$((SECONDS + 3))
while [ "$SECONDS" -lt "$SCRATCH_FAIL_DEADLINE" ]; do
  kill -0 "$SCRATCH_FAIL_WORKER_PID" 2>/dev/null || break
  sleep 0.1
done
if ! kill -0 "$SCRATCH_FAIL_WORKER_PID" 2>/dev/null; then
  set +e
  wait "$SCRATCH_FAIL_WORKER_PID"
  SCRATCH_FAIL_RC=$?
  set -e
  SCRATCH_FAIL_WORKER_PID=
  [ "$SCRATCH_FAIL_RC" -ne 0 ] \
    || fail "a worker that could not make its reclaim scratch directory reported peer ownership"
  fail "a worker that could not make its reclaim scratch directory stopped retrying (rc=$SCRATCH_FAIL_RC)"
fi
[ "$(cat "$SCRATCH_FAIL_STATE/worker.lock/pid")" = 999999 ] \
  || fail "a worker reclaimed the lock without its reclaim scratch directory"
kill -TERM "$SCRATCH_FAIL_WORKER_PID"
wait "$SCRATCH_FAIL_WORKER_PID" 2>/dev/null || true
SCRATCH_FAIL_WORKER_PID=
pass "a failed reclaim scratch directory keeps retrying instead of reporting peer ownership"

# An owner whose shutdown cannot confirm its execution stopped publishes the
# quarantine guard before it starts the slow part of stopping, so the guard can
# land in the ownership directory after a reclaiming worker has already checked
# for it and won its claim marker. Reclaim sweeps that directory, and sweeping
# the guard away would let the replacement serve the account queue beside a
# command tree nobody confirmed dead. The guard has to survive the sweep and
# send the reclaimer back to the quarantine branch. The staged mkdir publishes
# it exactly in that window, which is the only way to reach it deterministically.
LATE_QUARANTINE_HOME="$TMP_ROOT/late-quarantine-account"
LATE_QUARANTINE_STATE="$TMP_ROOT/late-quarantine-jobs"
LATE_QUARANTINE_BIN="$TMP_ROOT/late-quarantine-bin"
LATE_QUARANTINE_JOB="$LATE_QUARANTINE_STATE/jobs/job-late-quarantine"
LATE_QUARANTINE_ONCE="$TMP_ROOT/late-quarantine-published"
mkdir -p "$LATE_QUARANTINE_HOME" "$LATE_QUARANTINE_STATE/jobs" "$LATE_QUARANTINE_STATE/logs" \
  "$LATE_QUARANTINE_STATE/worker.lock" "$LATE_QUARANTINE_JOB/.claim" "$LATE_QUARANTINE_BIN"
chmod 700 "$LATE_QUARANTINE_HOME" "$LATE_QUARANTINE_STATE" "$LATE_QUARANTINE_STATE/jobs" \
  "$LATE_QUARANTINE_STATE/logs" "$LATE_QUARANTINE_STATE/worker.lock" "$LATE_QUARANTINE_JOB" \
  "$LATE_QUARANTINE_JOB/.claim"
cat > "$LATE_QUARANTINE_BIN/mkdir" <<SH
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in
    */worker.lock/claim)
      $(command -v mkdir) "\$@" || exit \$?
      if [ ! -e "$LATE_QUARANTINE_ONCE" ]; then
        : > "$LATE_QUARANTINE_ONCE"
        printf 'active execution could not be confirmed stopped\n' > "\${arg%/claim}/quarantine"
        chmod 600 "\${arg%/claim}/quarantine"
      fi
      exit 0
      ;;
  esac
done
exec $(command -v mkdir) "\$@"
SH
chmod 755 "$LATE_QUARANTINE_BIN/mkdir"
sleep 20 &
LATE_QUARANTINE_PROCESS_PID=$!
sleep 0.01 &
LATE_QUARANTINE_OWNER_PID=$!
wait "$LATE_QUARANTINE_OWNER_PID" 2>/dev/null || true
printf '%s\n' "$LATE_QUARANTINE_OWNER_PID" > "$LATE_QUARANTINE_STATE/worker.lock/pid"
printf 'stale\n' > "$LATE_QUARANTINE_STATE/worker.lock/start"
printf 'stale\n' > "$LATE_QUARANTINE_STATE/worker.lock/command"
printf 'running\n' > "$LATE_QUARANTINE_JOB/state"
printf '%s\n' "$LATE_QUARANTINE_OWNER_PID" > "$LATE_QUARANTINE_JOB/.claim/owner"
printf '%s\n' "$LATE_QUARANTINE_PROCESS_PID" > "$LATE_QUARANTINE_JOB/.claim/supervisor"
: > "$LATE_QUARANTINE_JOB/stdout"
: > "$LATE_QUARANTINE_JOB/stderr"
chmod 600 "$LATE_QUARANTINE_STATE/worker.lock"/* "$LATE_QUARANTINE_JOB/state" \
  "$LATE_QUARANTINE_JOB/.claim"/* "$LATE_QUARANTINE_JOB/stdout" "$LATE_QUARANTINE_JOB/stderr"
touch -t 200001010000 "$LATE_QUARANTINE_STATE/worker.lock"
HOME="$LATE_QUARANTINE_HOME" PATH="$LATE_QUARANTINE_BIN:$PATH" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$LATE_QUARANTINE_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/late-quarantine.out" 2> "$TMP_ROOT/late-quarantine.err" &
LATE_QUARANTINE_WORKER_PID=$!
LATE_QUARANTINE_DEADLINE=$((SECONDS + 20))
while kill -0 "$LATE_QUARANTINE_WORKER_PID" 2>/dev/null && [ "$SECONDS" -lt "$LATE_QUARANTINE_DEADLINE" ]; do
  sleep 0.1
done
if kill -0 "$LATE_QUARANTINE_WORKER_PID" 2>/dev/null; then
  kill -KILL "$LATE_QUARANTINE_WORKER_PID" 2>/dev/null || true
  wait "$LATE_QUARANTINE_WORKER_PID" 2>/dev/null || true
  LATE_QUARANTINE_WORKER_PID=
  fail "a reclaiming worker kept serving after a quarantine landed inside its claim window"
fi
set +e
wait "$LATE_QUARANTINE_WORKER_PID"
LATE_QUARANTINE_RC=$?
set -e
LATE_QUARANTINE_WORKER_PID=
assert_present "$LATE_QUARANTINE_ONCE" "the staged quarantine was never published into the claim window"
[ "$LATE_QUARANTINE_RC" -ne 0 ] \
  || fail "a reclaiming worker accepted ownership after a quarantine landed inside its claim window"
assert_present "$LATE_QUARANTINE_STATE/worker.lock/quarantine" \
  "reclaim swept away a quarantine published inside its claim window"
[ "$(cat "$LATE_QUARANTINE_STATE/worker.lock/pid")" = "$LATE_QUARANTINE_OWNER_PID" ] \
  || fail "a reclaiming worker took ownership despite a quarantine published inside its claim window"
assert_absent "$LATE_QUARANTINE_STATE/worker.ready" \
  "a quarantined reclaim still reported the account ready"
assert_absent "$LATE_QUARANTINE_STATE/worker.lock/claim" \
  "a reclaim that deferred to quarantine left its claim marker behind"
kill "$LATE_QUARANTINE_PROCESS_PID" 2>/dev/null || true
wait "$LATE_QUARANTINE_PROCESS_PID" 2>/dev/null || true
LATE_QUARANTINE_PROCESS_PID=
pass "a quarantine published inside the claim window survives reclaim"

# Every staleness gate is read before the claim marker is taken, and a peer
# reclaim only frees that marker after it has published its own ownership
# records. A worker descheduled across that whole window therefore wins the
# marker against a lock that is no longer stale, and sweeping it would delete a
# live owner's records and put two workers on one account queue. Winning the
# marker has to be re-validated against the records. The staged mkdir publishes
# a live owner's records exactly as the marker is taken, which is the only way
# to reach that window deterministically.
FINISHED_RECLAIM_HOME="$TMP_ROOT/finished-reclaim-account"
FINISHED_RECLAIM_STATE="$TMP_ROOT/finished-reclaim-jobs"
FINISHED_RECLAIM_BIN="$TMP_ROOT/finished-reclaim-bin"
FINISHED_RECLAIM_ONCE="$TMP_ROOT/finished-reclaim-published"
mkdir -p "$FINISHED_RECLAIM_HOME" "$FINISHED_RECLAIM_STATE/worker.lock" "$FINISHED_RECLAIM_BIN"
chmod 700 "$FINISHED_RECLAIM_HOME" "$FINISHED_RECLAIM_STATE" "$FINISHED_RECLAIM_STATE/worker.lock"
sleep 30 &
FINISHED_RECLAIM_OWNER_PID=$!
cat > "$FINISHED_RECLAIM_BIN/mkdir" <<SH
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in
    */worker.lock/claim)
      $(command -v mkdir) "\$@" || exit \$?
      if [ ! -e "$FINISHED_RECLAIM_ONCE" ]; then
        : > "$FINISHED_RECLAIM_ONCE"
        lock=\${arg%/claim}
        printf '%s\n' "$FINISHED_RECLAIM_OWNER_PID" > "\$lock/pid"
        ps -p "$FINISHED_RECLAIM_OWNER_PID" -o lstart= > "\$lock/start"
        ps -p "$FINISHED_RECLAIM_OWNER_PID" -o command= > "\$lock/command"
        chmod 600 "\$lock/pid" "\$lock/start" "\$lock/command"
      fi
      exit 0
      ;;
  esac
done
exec $(command -v mkdir) "\$@"
SH
chmod 755 "$FINISHED_RECLAIM_BIN/mkdir"
printf '999999\n' > "$FINISHED_RECLAIM_STATE/worker.lock/pid"
printf 'stale-start\n' > "$FINISHED_RECLAIM_STATE/worker.lock/start"
printf 'stale-command\n' > "$FINISHED_RECLAIM_STATE/worker.lock/command"
printf '999999\n' > "$FINISHED_RECLAIM_STATE/worker.ready"
chmod 600 "$FINISHED_RECLAIM_STATE/worker.lock"/* "$FINISHED_RECLAIM_STATE/worker.ready"
touch -t 200001010000 "$FINISHED_RECLAIM_STATE/worker.lock" "$FINISHED_RECLAIM_STATE/worker.ready"
HOME="$FINISHED_RECLAIM_HOME" PATH="$FINISHED_RECLAIM_BIN:$PATH" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$FINISHED_RECLAIM_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/finished-reclaim.out" 2> "$TMP_ROOT/finished-reclaim.err" &
FINISHED_RECLAIM_WORKER_PID=$!
FINISHED_RECLAIM_DEADLINE=$((SECONDS + 20))
while kill -0 "$FINISHED_RECLAIM_WORKER_PID" 2>/dev/null && [ "$SECONDS" -lt "$FINISHED_RECLAIM_DEADLINE" ]; do
  sleep 0.1
done
if kill -0 "$FINISHED_RECLAIM_WORKER_PID" 2>/dev/null; then
  kill -KILL "$FINISHED_RECLAIM_WORKER_PID" 2>/dev/null || true
  wait "$FINISHED_RECLAIM_WORKER_PID" 2>/dev/null || true
  FINISHED_RECLAIM_WORKER_PID=
  fail "a worker served the account after winning the claim against a finished peer reclaim"
fi
set +e
wait "$FINISHED_RECLAIM_WORKER_PID"
FINISHED_RECLAIM_RC=$?
set -e
FINISHED_RECLAIM_WORKER_PID=
assert_present "$FINISHED_RECLAIM_ONCE" "the staged owner records were never published into the claim window"
[ "$FINISHED_RECLAIM_RC" -eq 0 ] \
  || fail "a worker that found a live owner after winning the claim did not defer (rc=$FINISHED_RECLAIM_RC): $(cat "$TMP_ROOT/finished-reclaim.err")"
[ "$(cat "$FINISHED_RECLAIM_STATE/worker.lock/pid")" = "$FINISHED_RECLAIM_OWNER_PID" ] \
  || fail "a worker swept the ownership records a finished peer reclaim had just published"
assert_absent "$FINISHED_RECLAIM_STATE/worker.lock/claim" \
  "a worker that deferred to a finished peer reclaim left its claim marker behind"
kill -0 "$FINISHED_RECLAIM_OWNER_PID" 2>/dev/null || fail "the staged live owner is not alive"
kill "$FINISHED_RECLAIM_OWNER_PID" 2>/dev/null || true
wait "$FINISHED_RECLAIM_OWNER_PID" 2>/dev/null || true
FINISHED_RECLAIM_OWNER_PID=
pass "a claim won against a finished peer reclaim defers instead of sweeping it"

# An owner guarding its shutdown writes worker.lock/.quarantine.XXXXXX, fills it,
# chmods it and only then renames it onto worker.lock/quarantine, so that temp is
# present in the ownership directory for several forks. Reclaim sweeps that
# directory. Deleting the temp makes the owner's rename fail, and a failed guard
# publish sends the owner back to its serving loop instead of stopping it, so the
# reclaimer and the owner both serve the account. The lock directory is this
# protocol's persisted state, so the temp surviving a completed reclaim is the
# contract being asserted here.
SHUTDOWN_TEMP_HOME="$TMP_ROOT/shutdown-temp-account"
SHUTDOWN_TEMP_STATE="$TMP_ROOT/shutdown-temp-jobs"
SHUTDOWN_TEMP_INFLIGHT="$SHUTDOWN_TEMP_STATE/worker.lock/.quarantine.aBcDeF"
mkdir -p "$SHUTDOWN_TEMP_HOME" "$SHUTDOWN_TEMP_STATE/worker.lock"
chmod 700 "$SHUTDOWN_TEMP_HOME" "$SHUTDOWN_TEMP_STATE" "$SHUTDOWN_TEMP_STATE/worker.lock"
printf '999999\n' > "$SHUTDOWN_TEMP_STATE/worker.lock/pid"
printf 'stale-start\n' > "$SHUTDOWN_TEMP_STATE/worker.lock/start"
printf 'stale-command\n' > "$SHUTDOWN_TEMP_STATE/worker.lock/command"
printf 'active execution could not be confirmed stopped\n' > "$SHUTDOWN_TEMP_INFLIGHT"
printf '999999\n' > "$SHUTDOWN_TEMP_STATE/worker.ready"
chmod 600 "$SHUTDOWN_TEMP_STATE/worker.lock"/* "$SHUTDOWN_TEMP_INFLIGHT" \
  "$SHUTDOWN_TEMP_STATE/worker.ready"
touch -t 200001010000 "$SHUTDOWN_TEMP_STATE/worker.lock" "$SHUTDOWN_TEMP_STATE/worker.ready"
HOME="$SHUTDOWN_TEMP_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$SHUTDOWN_TEMP_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/shutdown-temp.out" 2> "$TMP_ROOT/shutdown-temp.err" &
SHUTDOWN_TEMP_WORKER_PID=$!
SHUTDOWN_TEMP_READY=
for _ in $(seq 1 300); do
  SHUTDOWN_TEMP_READY=$(cat "$SHUTDOWN_TEMP_STATE/worker.ready" 2>/dev/null || true)
  case "$SHUTDOWN_TEMP_READY" in
    ''|999999) ;;
    *) kill -0 "$SHUTDOWN_TEMP_READY" 2>/dev/null && break ;;
  esac
  kill -0 "$SHUTDOWN_TEMP_WORKER_PID" 2>/dev/null || break
  sleep 0.05
done
case "$SHUTDOWN_TEMP_READY" in
  ''|999999) fail "the worker did not reclaim past an in-flight shutdown guard temp: $(cat "$TMP_ROOT/shutdown-temp.err")" ;;
esac
assert_present "$SHUTDOWN_TEMP_INFLIGHT" \
  "reclaim deleted the guard temp an owner shutdown was still writing"
kill -TERM "$SHUTDOWN_TEMP_WORKER_PID"
wait "$SHUTDOWN_TEMP_WORKER_PID" 2>/dev/null || true
SHUTDOWN_TEMP_WORKER_PID=
pass "reclaim leaves an in-flight shutdown guard temp alone"

# The guard can also land after reclaim has read for it and while the sweep is
# still running. Taking ownership then records live pid/start/command beside a
# live guard, and from there the account can never probe ready while every
# replacement refuses to retire a guard held by a live recorded owner. Reclaim
# has to re-read the guard before recording itself and stop while the lock still
# holds nothing but the guard. The staged rm publishes it mid-sweep, which is the
# only way to reach that window deterministically.
SWEPT_QUARANTINE_HOME="$TMP_ROOT/swept-quarantine-account"
SWEPT_QUARANTINE_STATE="$TMP_ROOT/swept-quarantine-jobs"
SWEPT_QUARANTINE_BIN="$TMP_ROOT/swept-quarantine-bin"
SWEPT_QUARANTINE_ONCE="$TMP_ROOT/swept-quarantine-published"
mkdir -p "$SWEPT_QUARANTINE_HOME" "$SWEPT_QUARANTINE_STATE/worker.lock" "$SWEPT_QUARANTINE_BIN"
chmod 700 "$SWEPT_QUARANTINE_HOME" "$SWEPT_QUARANTINE_STATE" "$SWEPT_QUARANTINE_STATE/worker.lock"
cat > "$SWEPT_QUARANTINE_BIN/rm" <<SH
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in
    */worker.lock/*)
      if [ ! -e "$SWEPT_QUARANTINE_ONCE" ]; then
        : > "$SWEPT_QUARANTINE_ONCE"
        lock=\${arg%/*}
        printf 'active execution could not be confirmed stopped\n' > "\$lock/quarantine"
        chmod 600 "\$lock/quarantine"
      fi
      break
      ;;
  esac
done
exec $(command -v rm) "\$@"
SH
chmod 755 "$SWEPT_QUARANTINE_BIN/rm"
printf '999999\n' > "$SWEPT_QUARANTINE_STATE/worker.lock/pid"
printf 'stale-start\n' > "$SWEPT_QUARANTINE_STATE/worker.lock/start"
printf 'stale-command\n' > "$SWEPT_QUARANTINE_STATE/worker.lock/command"
printf '999999\n' > "$SWEPT_QUARANTINE_STATE/worker.ready"
chmod 600 "$SWEPT_QUARANTINE_STATE/worker.lock"/* "$SWEPT_QUARANTINE_STATE/worker.ready"
touch -t 200001010000 "$SWEPT_QUARANTINE_STATE/worker.lock" "$SWEPT_QUARANTINE_STATE/worker.ready"
HOME="$SWEPT_QUARANTINE_HOME" PATH="$SWEPT_QUARANTINE_BIN:$PATH" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$SWEPT_QUARANTINE_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/swept-quarantine.out" 2> "$TMP_ROOT/swept-quarantine.err" &
SWEPT_QUARANTINE_WORKER_PID=$!
SWEPT_QUARANTINE_DEADLINE=$((SECONDS + 20))
while kill -0 "$SWEPT_QUARANTINE_WORKER_PID" 2>/dev/null && [ "$SECONDS" -lt "$SWEPT_QUARANTINE_DEADLINE" ]; do
  sleep 0.1
done
if kill -0 "$SWEPT_QUARANTINE_WORKER_PID" 2>/dev/null; then
  kill -KILL "$SWEPT_QUARANTINE_WORKER_PID" 2>/dev/null || true
  wait "$SWEPT_QUARANTINE_WORKER_PID" 2>/dev/null || true
  SWEPT_QUARANTINE_WORKER_PID=
  fail "a reclaiming worker served the account over a guard published during its sweep"
fi
set +e
wait "$SWEPT_QUARANTINE_WORKER_PID"
SWEPT_QUARANTINE_RC=$?
set -e
SWEPT_QUARANTINE_WORKER_PID=
assert_present "$SWEPT_QUARANTINE_ONCE" "the staged guard was never published into the sweep window"
[ "$SWEPT_QUARANTINE_RC" -eq 75 ] \
  || fail "a reclaim stopped by a guard published mid-sweep did not report quarantined ownership (rc=$SWEPT_QUARANTINE_RC): $(cat "$TMP_ROOT/swept-quarantine.err")"
assert_present "$SWEPT_QUARANTINE_STATE/worker.lock/quarantine" \
  "a guard published during the sweep did not survive it"
assert_absent "$SWEPT_QUARANTINE_STATE/worker.lock/pid" \
  "a reclaiming worker recorded ownership beside a guard published during its sweep"
assert_absent "$SWEPT_QUARANTINE_STATE/worker.lock/claim" \
  "a reclaim stopped by a guard left its claim marker behind"
pass "a guard published during the sweep stops reclaim before it records ownership"

# A child that stays up for FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS clears the
# consecutive-failure backoff, so a child that dies just past that threshold
# used to reset the only guard the supervisor had and restart forever. The
# fixture below is that worker: it exits non-zero after living just longer than
# the healthy window, so every restart is accounted as healthy-then-failed.
RESTART_ROOT="$TMP_ROOT/restart-root"
RESTART_HOME="$TMP_ROOT/restart-account"
RESTART_STATE="$TMP_ROOT/restart-state"
RESTART_CHILD_LOG="$TMP_ROOT/restart-children"
mkdir -p "$RESTART_ROOT/bin" "$RESTART_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$RESTART_ROOT/bin/"
cp "$ROOT/bin/fm-remote-job-worker.sh" "$RESTART_ROOT/bin/fm-remote-job-supervisor-under-test.sh"
printf 'fixture\n' > "$RESTART_ROOT/AGENTS.md"
cat > "$RESTART_ROOT/bin/fm-remote-job-worker.sh" <<'SH'
#!/bin/bash
set -u
[ "${1:-}" = --serve ] || exit 2
printf '%s\n' "${BASHPID:-$$}" >> "$FM_TEST_SUPERVISOR_CHILD_LOG"
sleep "$FM_TEST_SUPERVISOR_CHILD_SECONDS"
exit "$FM_TEST_SUPERVISOR_CHILD_STATUS"
SH
chmod +x "$RESTART_ROOT/bin"/*.sh
HOME="$RESTART_HOME" FM_ROOT_OVERRIDE="$RESTART_ROOT" \
  FM_REMOTE_JOB_STATE_ROOT="$RESTART_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_SUPERVISOR_HEALTHY_SECONDS=1 FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS=3 \
  FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS=0 FM_TEST_SUPERVISOR_CHILD_LOG="$RESTART_CHILD_LOG" \
  FM_TEST_SUPERVISOR_CHILD_SECONDS=1.1 FM_TEST_SUPERVISOR_CHILD_STATUS=1 \
  "$RESTART_ROOT/bin/fm-remote-job-supervisor-under-test.sh" \
  > "$TMP_ROOT/restart-supervisor.out" 2> "$TMP_ROOT/restart-supervisor.err" &
RESTART_SUPERVISOR_PID=$!
for _ in $(seq 1 300); do
  kill -0 "$RESTART_SUPERVISOR_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$RESTART_SUPERVISOR_PID" 2>/dev/null; then
  fail "workers dying just past the healthy threshold drove an unbounded restart loop"
fi
set +e
wait "$RESTART_SUPERVISOR_PID"
RESTART_SUPERVISOR_RC=$?
set -e
RESTART_SUPERVISOR_PID=
[ "$RESTART_SUPERVISOR_RC" -ne 0 ] || fail "the exhausted restart guard reported success"
[ "$(wc -l < "$RESTART_CHILD_LOG" | tr -d ' ')" -eq 3 ] \
  || fail "the restart guard did not stop at the configured maximum"
assert_grep "remote job worker exited 3 times; stopping the supervisor" "$TMP_ROOT/restart-supervisor.err" \
  "the restart guard did not explain why it stopped"
pass "barely healthy worker failures remain bounded by the restart guard"

echo "ALL TESTS PASSED"
