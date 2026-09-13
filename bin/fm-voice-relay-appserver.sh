#!/usr/bin/env bash
# fm-voice-relay-appserver.sh - the supported steering transport for the spoken
# companion relay, and the honest answer to "can a correction actually reach an
# active turn?".
#
# WHY THIS EXISTS: `codex queue` only enqueues - its options carry no interrupt,
# cancel, dequeue, or priority flag, so a correction queued behind an obsolete
# message waits its turn. The app-server protocol the same installed build
# speaks DOES expose steering:
#
#   turn/steer        {threadId, expectedTurnId, input}  -> {turnId}
#   turn/interrupt    {threadId, turnId}                 -> {}
#   thread/turns/list {threadId, limit, sortDirection}   -> {data[...]}
#   thread/read       {threadId, includeTurns}           -> {thread{...}}
#
# `expectedTurnId` is the part that matters: the protocol itself makes steering a
# compare-and-swap against the turn the caller believes is running, so a steer
# aimed at a turn that already finished fails instead of landing somewhere new.
# That is the same freshness rule fm-voice-relay.sh enforces on disk, enforced
# again by the server - which is why this adapter stays thin and never invents a
# retry, a fallback target, or a "close enough" turn id.
#
# WHAT IS AND IS NOT PROVEN HERE: the method names, their parameters, and the
# compare-and-swap contract come from the schema the INSTALLED build generates
# (`codex app-server generate-json-schema`), so `probe` verifies them against
# this machine rather than against documentation.
#
# REACHABILITY IS A SEPARATE QUESTION, AND IT IS THE ONE THAT DECIDES WHETHER
# STEERING IS REAL HERE. A steer only moves the captain's live desktop
# conversation if it arrives at the server that actually owns that thread:
#   - `codex app-server proxy` attaches to an EXISTING control socket. On a
#     machine with no such socket it fails, and no steer is possible that way.
#   - Starting a fresh stdio app-server instead gives a server that can read
#     thread history, but it reports the desktop thread as not loaded - it does
#     not own the live turn, so a steer aimed through it proves nothing about
#     reaching the companion.
# `thread-status` exists to make that distinction visible BEFORE anyone relies
# on it: it reports whether the server answering us has a turn running on that
# thread, and treats a thread it merely holds idle, cannot load, or reports in a
# status this build does not recognise as not steerable. "The schema supports
# turn/steer" and "this server can steer that conversation" are two different
# claims, and only the second one helps.
#
# SAFETY: every command is a DRY RUN unless --live is passed. A dry run prints
# the exact JSON-RPC frames it would write and touches no daemon, no thread, and
# no session, so the frames can be reviewed before anything reaches the
# captain's live conversation. This script never discovers threads, never lists
# sessions, never starts a turn, and never archives or deletes anything: the
# caller supplies the exact bound thread id.
#
# Usage:
#   fm-voice-relay-appserver.sh probe [--schema-dir <dir>]
#       Prove the installed build speaks the steering contract. Without
#       --schema-dir it generates a fresh schema bundle from the installed
#       binary into a temporary directory and reads that. Prints one line per
#       required method with supported/missing, plus the parameter names it
#       found, and exits non-zero if anything required is missing. Contacts no
#       daemon.
#
#   fm-voice-relay-appserver.sh thread-status --thread <id> [--live]
#         [--sock <path>]
#       Read the thread and report whether the answering server has a turn to
#       steer, plus how many turns it can see. Status is a tagged union and only
#       "active" answers steerable: "idle" means the server holds the thread but
#       no turn is running, "notLoaded" means it can read history but does not
#       own the live conversation, "systemError" means it reports the thread
#       broken, and an unrecognised shape answers "steerable: unknown". Every
#       answer but active is treated as not steerable. Read-only.
#
#   fm-voice-relay-appserver.sh active-turn --thread <id> [--live]
#       Ask for the most recent turn of that thread and print
#       "turn <id> status <status>". This is how a caller learns the
#       expectedTurnId it must pass to steer.
#
#   fm-voice-relay-appserver.sh steer --thread <id> --expected-turn <id>
#         --text <correction> [--live]
#       Deliver a correction into the turn that is running now. Fails when the
#       turn already ended: that refusal is the feature, not an error to retry.
#
#   fm-voice-relay-appserver.sh interrupt --thread <id> --turn <id> [--live]
#       Ask the server to stop that turn. Stopping a turn does not undo an
#       action it already performed outside this process.
#
# Every live command accepts --sock <path> to name the control socket to attach
# to, because which server answers decides whether a steer can land at all.
#
# FM_VOICE_RELAY_PROXY_CMD overrides the proxy command (tests use a fake
# app-server; production leaves it unset and gets `codex app-server proxy`).
# FM_VOICE_RELAY_RPC_TIMEOUT (default 20) bounds the wait for a live answer in
# seconds. It applies to each answer separately - once to the handshake, then
# afresh to the request - so a slow initialization cannot spend the budget the
# call itself needs and leave a steer reported as an unknown outcome it never
# really waited for. A proxy that accepts the frames and never answers ends as a
# transport failure at that bound instead of hanging the caller for ever; one
# that answers and then stays open is not penalised for staying open, because
# the bound is on the answer arriving rather than on the proxy exiting.
#
# Exit codes: 0 ok, 2 usage, 3 the server refused (including a stale
# expectedTurnId), 4 required protocol support missing, 5 transport failure.
set -u

die() {
  echo "error: $*" >&2
  exit 2
}

json_escape() {  # <text>
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.argv[1]))' "$1"
}

SOCK=''

# POSIX single-quoting for a value that is interpolated into a command STRING
# and split again later: the socket path is operator-supplied, so a space in it
# would otherwise become two extra arguments and an apostrophe would make the
# whole command line unparseable and report a usage error instead of attaching.
shell_quote() {  # <text>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

rpc_timeout_secs() {
  local secs=${FM_VOICE_RELAY_RPC_TIMEOUT:-20}
  case "$secs" in
    ''|*[!0-9]*|0) die "FM_VOICE_RELAY_RPC_TIMEOUT must be a positive whole number of seconds: $secs" ;;
  esac
  printf '%s\n' "$secs"
}

proxy_cmd() {
  if [ -n "${FM_VOICE_RELAY_PROXY_CMD:-}" ]; then
    printf '%s\n' "$FM_VOICE_RELAY_PROXY_CMD"
  elif [ -n "$SOCK" ]; then
    printf 'codex app-server proxy --sock %s\n' "$(shell_quote "$SOCK")"
  else
    printf 'codex app-server proxy\n'
  fi
}

# One request/response exchange over the proxy's stdio. The frames are
# newline-delimited JSON-RPC 2.0 objects, and the answer is the first object
# whose id matches the request, so a notification stream in between is ignored
# rather than mistaken for an answer.
#
# The read is INCREMENTAL and owns its own bound. Reading to EOF and parsing
# afterwards looked simpler, but it makes the exchange hostage to when the proxy
# decides to exit: a server that answers correctly and then keeps running past
# stdin EOF - which a long-lived app-server is entitled to do - was reported as
# "no answer" at the bound, with the answer it had already sent discarded.
# Recognising the matching id as it arrives removes that failure and removes the
# need for a second copy of the fleet timeout helper: the bound lives here, on
# the read, rather than around the whole process.
#
# Exit: 0 with the result object on stdout, 2 when the proxy command string is
# not a parseable command line, 3 when the server refused (a stale
# expectedTurnId lands here), 5 for any transport failure. The child is signalled
# on EVERY exit path, interrupt included: the proxy runs in its own session so it
# never sees the terminal's SIGINT, and only this cleanup stands between a
# cancelled --live call and a proxy left running unattached.
rpc_exchange() {  # <method> <params-json> <timeout-secs> ; prints the id-2 result
  local method=$1 params=$2 secs=$3 cmd
  cmd=$(proxy_cmd)
  FM_RPC_CMD="$cmd" FM_RPC_SECS="$secs" FM_RPC_METHOD="$method" FM_RPC_PARAMS="$params" \
    python3 - <<'PY'
import json, os, select, shlex, signal, subprocess, sys, time

try:
    cmd = shlex.split(os.environ["FM_RPC_CMD"])
except ValueError as exc:
    sys.stderr.write("error: the app-server proxy command is not a parseable command line: %s\n" % exc)
    raise SystemExit(2)
if not cmd:
    sys.stderr.write("error: the app-server proxy command is empty\n")
    raise SystemExit(2)
secs = float(os.environ["FM_RPC_SECS"])
method = os.environ["FM_RPC_METHOD"]
params = os.environ["FM_RPC_PARAMS"]

# The handshake is the documented three steps, in order: send initialize, wait
# for its answer, send the "initialized" notification, and only then send the
# request. Writing initialize and the request together and closing stdin lets a
# server that refuses work before initialization completes drop the request, and
# the failure surfaces as an unexplained transport error.
#
# "initialized" is the installed protocol's sole client notification - it is
# defined at the top level of the generated schema (ClientNotification.json),
# NOT inside the v2 subtree, so a grep confined to v2 wrongly concludes it does
# not exist. It takes no params.
init_frame = (
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
    '{"clientInfo":{"name":"fm-voice-relay","title":"Firstmate voice relay","version":"1"}}}\n'
)
initialized_frame = '{"jsonrpc":"2.0","method":"initialized"}\n'
request_frame = '{"jsonrpc":"2.0","id":2,"method":%s,"params":%s}\n' % (json.dumps(method), params)

try:
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, start_new_session=True)
except OSError as exc:
    sys.stderr.write("transport failure: could not start the app-server proxy: %s\n" % exc)
    raise SystemExit(5)


def stop():
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if proc.poll() is not None:
            return
        try:
            os.killpg(os.getpgid(proc.pid), sig)
        except OSError:
            return
        try:
            proc.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            continue


def answer_in(line, want):
    try:
        msg = json.loads(line)
    except ValueError:
        return None
    if not isinstance(msg, dict) or msg.get("id") != want:
        return None
    return msg


answer = None
timed_out = False
buf = b""


def write_frame(frame):
    try:
        proc.stdin.write(frame.encode())
        proc.stdin.flush()
    except (BrokenPipeError, OSError):
        pass


def read_answer(want, deadline):
    """Read until the response with this id arrives, EOF, or the deadline.

    Returns (answer, timed_out). Notification traffic in between is skipped
    rather than mistaken for the answer, and the buffer is shared across both
    reads so a response that arrived early is never lost.
    """
    global buf
    fd = proc.stdout.fileno()
    while True:
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            found = answer_in(line, want)
            if found is not None:
                return found, False
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None, True
        if not select.select([fd], [], [], remaining)[0]:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            for line in buf.splitlines():
                found = answer_in(line, want)
                if found is not None:
                    return found, False
            return None, False
        buf += chunk

try:
    write_frame(init_frame)
    deadline = time.monotonic() + secs
    handshake, timed_out = read_answer(1, deadline)
    if handshake is not None and "error" in handshake:
        sys.stderr.write("server refused initialization: %s\n" % json.dumps(handshake["error"]))
        stop()
        raise SystemExit(3)
    if handshake is None:
        # No usable handshake answer: the request is not sent, because a server
        # that never initialized cannot be trusted to have understood it.
        if timed_out:
            sys.stderr.write(
                "transport failure: no initialization answer within %ss (FM_VOICE_RELAY_RPC_TIMEOUT); "
                "the request was never sent\n" % os.environ["FM_RPC_SECS"])
        else:
            sys.stderr.write("transport failure: the proxy closed before answering initialization\n")
        stop()
        raise SystemExit(5)
    write_frame(initialized_frame)
    write_frame(request_frame)
    try:
        proc.stdin.close()
    except OSError:
        pass
    # The request gets its own full bound. Sharing one deadline with the
    # handshake meant a server that took nearly the whole timeout to answer
    # initialize left the actual call about zero seconds, and the steer was
    # abandoned as "outcome unknown" after waiting almost nothing for it - the
    # one outcome this adapter exists to avoid reporting needlessly.
    answer, timed_out = read_answer(2, time.monotonic() + secs)
finally:
    stop()

if answer is None:
    if timed_out:
        sys.stderr.write(
            "transport failure: no answer within %ss (FM_VOICE_RELAY_RPC_TIMEOUT); "
            "the call was abandoned, and whether the server acted on it is unknown\n"
            % os.environ["FM_RPC_SECS"])
    else:
        sys.stderr.write("transport failure: the proxy closed without answering the request\n")
    raise SystemExit(5)
if "error" in answer:
    sys.stderr.write("server refused: %s\n" % json.dumps(answer["error"]))
    raise SystemExit(3)
sys.stdout.write(json.dumps(answer.get("result", {})))
raise SystemExit(0)
PY
}

emit_or_send() {  # <live> <method> <params-json>
  local live=$1 method=$2 params=$3 status secs
  if [ "$live" != 1 ]; then
    printf 'dry-run: would send over "%s"\n' "$(proxy_cmd)"
    printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"fm-voice-relay","title":"Firstmate voice relay","version":"1"}}}\n'
    printf '{"jsonrpc":"2.0","method":"initialized"}\n'
    printf '{"jsonrpc":"2.0","id":2,"method":%s,"params":%s}\n' "$(json_escape "$method")" "$params"
    return 0
  fi
  # Resolved here rather than inside rpc_exchange: that call is captured in a
  # command substitution, and a usage error raised inside it would come back as
  # a transport failure instead of the usage error it is.
  secs=$(rpc_timeout_secs) || exit 2
  rpc_exchange "$method" "$params" "$secs"
  status=$?
  [ "$status" = 0 ] && printf '\n'
  return "$status"
}

REQUIRED_METHODS='turn/steer turn/interrupt thread/turns/list thread/read'

cmd_probe() {
  local schema_dir='' tmp='' bundle missing=0 method found
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --schema-dir) schema_dir=${2:-}; shift 2 ;;
      *) die "probe: unexpected argument: $1" ;;
    esac
  done
  if [ -z "$schema_dir" ]; then
    command -v codex >/dev/null 2>&1 || { echo "missing: codex is not installed" >&2; return 4; }
    tmp=$(mktemp -d) || die "probe: cannot create a temporary directory"
    if ! codex app-server generate-json-schema --out "$tmp" >/dev/null 2>&1; then
      rm -rf "$tmp"
      echo "missing: this build cannot generate the app-server schema, so its steering support is unproven" >&2
      return 4
    fi
    schema_dir=$tmp
  fi
  bundle=$(find "$schema_dir" -name 'codex_app_server_protocol.v2.schemas.json' -print 2>/dev/null | head -1)
  if [ -z "$bundle" ]; then
    bundle=$(find "$schema_dir" -name '*.schemas.json' -print 2>/dev/null | head -1)
  fi
  if [ -z "$bundle" ]; then
    [ -n "$tmp" ] && rm -rf "$tmp"
    echo "missing: no protocol schema bundle under $schema_dir" >&2
    return 4
  fi
  for method in $REQUIRED_METHODS; do
    if grep -q "\"$method\"" "$bundle"; then
      found=supported
    else
      found=missing
      missing=1
    fi
    printf '%-20s %s\n' "$method" "$found"
  done
  printf 'steer-params: %s\n' "$(schema_props "$schema_dir" TurnSteerParams)"
  printf 'interrupt-params: %s\n' "$(schema_props "$schema_dir" TurnInterruptParams)"
  printf 'note: schema support is not live proof. Run thread-status against the bound thread first:\n'
  printf 'note: a server that reports the thread not loaded can read history but cannot steer that conversation.\n'
  [ -n "$tmp" ] && rm -rf "$tmp"
  [ "$missing" = 0 ] || return 4
  return 0
}

schema_props() {  # <schema-dir> <title>
  local dir=$1 title=$2 file
  file=$(find "$dir" -name "$title.json" -print 2>/dev/null | head -1)
  [ -n "$file" ] || { printf 'unknown\n'; return 0; }
  python3 - "$file" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print("unknown"); raise SystemExit
req=d.get("required") or []
props=sorted((d.get("properties") or {}).keys())
print("required=%s all=%s" % (",".join(req) or "-", ",".join(props) or "-"))
PY
}

# Read-only: which server is answering, and does it actually own this thread?
cmd_thread_status() {
  local thread='' live=0 params result
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) thread=${2:-}; shift 2 ;;
      --sock) SOCK=${2:-}; shift 2 ;;
      --live) live=1; shift ;;
      *) die "thread-status: unexpected argument: $1" ;;
    esac
  done
  [ -n "$thread" ] || die "thread-status requires --thread <id>"
  params=$(printf '{"threadId":%s,"includeTurns":true}' "$(json_escape "$thread")")
  if [ "$live" != 1 ]; then
    emit_or_send 0 thread/read "$params"
    return 0
  fi
  result=$(emit_or_send 1 thread/read "$params") || return $?
  python3 - "$result" <<'PY'
import json,sys
raw=sys.argv[1].strip()
try:
    d=json.loads(raw) if raw else {}
except ValueError:
    print("unknown: the server response was not readable"); raise SystemExit(5)
thread=d.get("thread") if isinstance(d.get("thread"), dict) else {}
# ThreadStatus is a TAGGED UNION in the installed protocol - {"type":"notLoaded"},
# {"type":"idle"}, {"type":"systemError"}, {"type":"active","activeFlags":[...]}.
# Reading it as a bare string reports a not-loaded thread as steerable, which is
# the one answer the whole steering claim rests on, so anything that is not a
# recognised tagged variant is treated as unknown and NOT steerable.
status=thread.get("status")
kind=status.get("type") if isinstance(status, dict) else None
if not isinstance(kind, str) or kind not in ("notLoaded", "idle", "systemError", "active"):
    kind = None
turns=thread.get("turns")
count=len(turns) if isinstance(turns, list) else "unknown"
print("thread %s status %s turns %s" % (thread.get("id", "unknown"), kind or "unknown", count))

def fallback():
    print("fallback 1: revise the shared request record first - fm-voice-relay.sh revise <topic> --summary '<the correction>' - so the correction IS the current revision")
    print("fallback 2: then queue that correction once through codex queue; do not send a second copy")
    print("fallback 3: freshness is enforced at the next cooperative boundary - fm-voice-relay.sh check-action before acting, present before speaking - and that is where the superseded step is refused")
    print("fallback limits: queueing alone kills nothing. The refusal comes from those two gates, not from the queue. This cannot interrupt an external action already in flight, and it cannot make the companion pick the correction up promptly")
    print("fallback, human: when the correction cannot wait for pickup, say it directly in the terminal session or through Herdr")

if kind == "active":
    print("steerable: this server reports a turn running on the thread; a steer may reach it, which still has to be confirmed against the turn id")
    raise SystemExit(0)
if kind == "idle":
    print("steerable: no - this server holds the thread but no turn is running, so there is nothing to steer right now")
elif kind == "notLoaded":
    print("steerable: no - this server can read history but does not own the live turn, so turn/steer would not reach the companion")
elif kind == "systemError":
    print("steerable: no - this server reports the thread in a system error state")
else:
    print("steerable: unknown - the server did not report a status this build recognises, so treat the thread as not steerable")
fallback()
PY
}

cmd_active_turn() {
  local thread='' live=0 params result
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) thread=${2:-}; shift 2 ;;
      --sock) SOCK=${2:-}; shift 2 ;;
      --live) live=1; shift ;;
      *) die "active-turn: unexpected argument: $1" ;;
    esac
  done
  [ -n "$thread" ] || die "active-turn requires --thread <id>"
  params=$(printf '{"threadId":%s,"limit":1,"sortDirection":"desc"}' "$(json_escape "$thread")")
  if [ "$live" != 1 ]; then
    emit_or_send 0 thread/turns/list "$params"
    return 0
  fi
  result=$(emit_or_send 1 thread/turns/list "$params") || return $?
  python3 - "$result" <<'PY'
import json,sys
raw=sys.argv[1].strip()
try:
    d=json.loads(raw) if raw else {}
except ValueError:
    print("unknown: the server response was not readable"); raise SystemExit(5)
data=d.get("data") or []
if not data:
    print("none: that thread has no recorded turn")
    raise SystemExit(0)
turn=data[0]
print("turn %s status %s" % (turn.get("id", "unknown"), turn.get("status", "unknown")))
PY
}

cmd_steer() {
  local thread='' expected='' text='' live=0 params
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) thread=${2:-}; shift 2 ;;
      --expected-turn) expected=${2:-}; shift 2 ;;
      --text) text=${2:-}; shift 2 ;;
      --sock) SOCK=${2:-}; shift 2 ;;
      --live) live=1; shift ;;
      *) die "steer: unexpected argument: $1" ;;
    esac
  done
  [ -n "$thread" ] || die "steer requires --thread <id>"
  [ -n "$expected" ] || die "steer requires --expected-turn <id>; steering without it would land the correction on whatever turn happens to be running"
  [ -n "$text" ] || die "steer requires --text <correction>"
  params=$(printf '{"threadId":%s,"expectedTurnId":%s,"input":[{"type":"text","text":%s}]}' \
    "$(json_escape "$thread")" "$(json_escape "$expected")" "$(json_escape "$text")")
  emit_or_send "$live" turn/steer "$params"
}

cmd_interrupt() {
  local thread='' turn='' live=0 params
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) thread=${2:-}; shift 2 ;;
      --turn) turn=${2:-}; shift 2 ;;
      --sock) SOCK=${2:-}; shift 2 ;;
      --live) live=1; shift ;;
      *) die "interrupt: unexpected argument: $1" ;;
    esac
  done
  [ -n "$thread" ] || die "interrupt requires --thread <id>"
  [ -n "$turn" ] || die "interrupt requires --turn <id>"
  params=$(printf '{"threadId":%s,"turnId":%s}' "$(json_escape "$thread")" "$(json_escape "$turn")")
  emit_or_send "$live" turn/interrupt "$params"
}

usage() {
  # The exit-code list is the LAST header paragraph, so the range has to run to
  # the first non-comment line and then drop it. Ending the range on
  # `/^# Exit codes:/` would stop on that line and cut the list off mid-sentence.
  sed -n '/^# Usage:/,/^[^#]/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

main() {
  local cmd=${1:-}
  shift || true
  case "$cmd" in
    probe) cmd_probe "$@" ;;
    thread-status) cmd_thread_status "$@" ;;
    active-turn) cmd_active_turn "$@" ;;
    steer) cmd_steer "$@" ;;
    interrupt) cmd_interrupt "$@" ;;
    -h|--help|help|'') usage ;;
    *) die "unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"
