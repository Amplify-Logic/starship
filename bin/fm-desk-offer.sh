#!/usr/bin/env bash
# The desk floater's "Do it" offer: one easy-to-undo step Firstmate offers to
# take on the captain's screen, shown on the floater's reply bubble with Do it
# and Not now buttons.
#
# Usage:
#   fm-desk-offer.sh offer <what will happen...>
#   fm-desk-offer.sh working <id>
#   fm-desk-offer.sh done [<id>]
#   fm-desk-offer.sh status
#   fm-desk-offer.sh answer do|not-now|stop <id>
#   fm-desk-offer.sh --help
#
# WHY A RECORD OF ITS OWN: the floater's bubble shows Firstmate's newest reply,
# but the spoken line cannot carry an offer, because the spoken register refuses
# any line that asks the captain to decide (bin/fm-speak.sh). So Firstmate says
# what it found in its reply and, beside it, records the offer here; the floater
# shows the offer's one line under the reply with the two buttons.
#
# The floater never acts: a Do it tap only sends one short line of the
# captain's own into the primary Firstmate chat, through the same path a talk
# message takes, bin/fm-desk-voice.sh send --source desk-floater-offer (typed
# into the chat, or saved to its mailbox when the chat shows a question, a
# permission prompt or a picker, so a tap can never answer a dialog;
# docs/desk-floater.md). Firstmate then takes the step under its own screen
# rules (docs/desk-voice-replies.md and the macos-computer-use skill,
# .agents/opt-in-skills/macos-computer-use/SKILL.md).
#
# Commands, for Firstmate:
#   offer <what will happen...>
#             records a new offer, replacing any earlier one, and prints
#             `offer: <id>`. The text is one line of at most 160 characters
#             saying what the step will do ("Turn on Do Not Disturb until 6pm").
#             A tap may approve only a step that is easy to undo (a setting, a
#             window, an export), so text naming a step that sends, buys,
#             books, deletes or submits is refused with exit 2: such a step
#             still waits for the captain's yes in the chat or on the approvals
#             page. The check is a backstop for that rule, not its owner.
#   working <id>
#             marks the offer as being carried out, after the captain's Do it
#             tap (or a yes in the chat), so the floater keeps the bubble up and
#             shows Stop. Refused with exit 1 unless <id> is the current offer,
#             so a late tap for an older offer can never approve a newer one.
#   done [<id>]
#             removes the offer once the step is finished, stopped or dropped;
#             with <id>, only when it is still the current one.
# Commands, for the floater:
#   status    prints the current offer as one JSON object, schema
#             fm-desk-offer.v1: id, text, state, after, created_at, updated_at.
#             state is open (waiting for a tap), expired, accepted (Do it was
#             tapped), working, stopping (Stop was tapped), or none, with no
#             other fields, when there is no offer. An open offer expires once
#             a newer reply than the one it came with arrives (a reply history
#             number above after + 1, read through bin/fm-speak.sh --history)
#             or after 30 minutes. An accepted or stopping offer that
#             Firstmate has not marked working or done within 30 minutes of the
#             tap also reads as expired. Any record not updated for two hours
#             reads as none.
#   answer do <id>
#             the Do it tap: only for the current open offer, it becomes
#             accepted and the line `Do it: <text> (floater offer <id>)` is sent.
#   answer not-now <id>
#             the Not now tap: removes the current open offer and sends
#             nothing, so declining never interrupts Firstmate. Prints
#             `declined`.
#   answer stop <id>
#             the Stop tap while the offer is accepted or working: it becomes
#             stopping and the line `Stop: <text> (floater offer <id>)` is sent.
# answer do and stop print fm-desk-voice.sh send's own outcome line. When that
# send fails, the offer goes back to the state it had, so the tap can be tried
# again.
#
# Automated runs never reach the captain's chat: under CI, GITHUB_ACTIONS or a
# no-mistakes gate (NO_MISTAKES_GATE, or this script running from a no-mistakes
# worktree), answer do and stop refuse before sending anything.
#
# The record is $FM_HOME/state/desk-voice/offer.json, readable only by this
# account, written whole by rename.
#
# Environment: FM_HOME selects the home (default: this code root);
# FM_STATE_OVERRIDE its state directory.
#
# Exit: 0 ok, 1 failure or not the current offer, 2 bad usage or a refused
# offer, 3 refused in an automated run.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OFFER_DIR="$STATE/desk-voice"
OFFER="$OFFER_DIR/offer.json"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

note() { printf 'fm-desk-offer: %s\n' "$*" >&2; }
die() { note "$*"; exit 1; }
refuse() { note "$*"; exit 2; }

# Refuses <action> in an automated run, so a test or pipeline agent never
# types into the captain's Firstmate chat.
refuse_automated() {  # <action>
  local why=
  if [ -n "${CI:-}" ]; then
    why=CI
  elif [ -n "${GITHUB_ACTIONS:-}" ]; then
    why=GITHUB_ACTIONS
  elif [ -n "${NO_MISTAKES_GATE:-}" ]; then
    why=NO_MISTAKES_GATE
  else
    case "$ROOT" in */.no-mistakes/worktrees/*) why="a no-mistakes worktree" ;; esac
  fi
  [ -n "$why" ] || return 0
  note "refusing to $1 in an automated run ($why): the captain's Firstmate chat is off limits to tests and pipeline agents"
  exit 3
}

newest_reply() {
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-speak.sh" --history 2>/dev/null | head -n 1 | cut -f 1 || true
}

# Runs one step on the record: python3 owns the JSON so the text is never
# parsed by the shell.
record() {  # <op> [args...]
  { mkdir -p "$OFFER_DIR" && chmod 700 "$OFFER_DIR"; } 2>/dev/null || die "cannot use $OFFER_DIR"
  python3 - "$OFFER" "$(newest_reply)" "$@" <<'PY'
import json, os, re, secrets, sys, time

path, newest, op = sys.argv[1], sys.argv[2], sys.argv[3]
args = sys.argv[4:]
newest = int(newest) if newest.isdigit() else 0
now = int(time.time())
OPEN_FOR = 30 * 60
KEPT_FOR = 2 * 60 * 60
# Steps a tap may never approve (fm-desk-offer.sh offer).
NOT_EASY = re.compile(r"\b(send\w*|e-?mail\w*|repl(y|ies|ied|ying)|buy\w*|bought|purchas\w*|pa(y|ys|id|ying|yment|yments)|book(s|ed|ing)?|reserv(e|es|ed|ing|ation|ations)|delet\w*|trash\w*|eras\w*|submit\w*|publish\w*)\b", re.I)


def load():
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("schema") != "fm-desk-offer.v1":
        return None
    if now - int(data.get("updated_at") or 0) > KEPT_FOR:
        return None
    return data


def shown(data):
    if data is None:
        return {"schema": "fm-desk-offer.v1", "state": "none"}
    out = dict(data)
    if out["state"] == "open" and (newest > int(out.get("after") or 0) + 1 or now - int(out["created_at"]) > OPEN_FOR):
        out["state"] = "expired"
    if out["state"] in ("accepted", "stopping") and now - int(out["updated_at"]) > OPEN_FOR:
        out["state"] = "expired"
    return out


def save(data):
    data["updated_at"] = now
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, path)


def remove():
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def current(want, states):
    data = shown(load())
    if data["state"] == "none" or data.get("id") != want:
        print("offer %s is not the current offer" % want, file=sys.stderr)
        sys.exit(1)
    if data["state"] not in states:
        print("offer %s is %s" % (want, data["state"]), file=sys.stderr)
        sys.exit(1)
    return data


if op == "offer":
    text = " ".join(" ".join(args).split())
    text = "".join(ch for ch in text if ch.isprintable())
    if not text:
        print("offer needs the one line saying what will happen", file=sys.stderr)
        sys.exit(2)
    if len(text) > 160:
        print("the offer line is longer than 160 characters", file=sys.stderr)
        sys.exit(2)
    if NOT_EASY.search(text):
        print("a Do it tap approves only easy-to-undo steps; a step that sends, buys, books, deletes or submits waits for the captain's yes in the chat or on the approvals page", file=sys.stderr)
        sys.exit(2)
    data = {"schema": "fm-desk-offer.v1", "id": secrets.token_hex(4), "text": text,
            "state": "open", "after": newest, "created_at": now}
    save(data)
    print("offer: %s" % data["id"])
elif op == "status":
    print(json.dumps(shown(load())))
elif op == "working":
    data = current(args[0], ("open", "accepted"))
    data["state"] = "working"
    save(data)
    print("working: %s" % data["id"])
elif op == "finish":
    if args:
        current(args[0], ("open", "expired", "accepted", "working", "stopping"))
    remove()
    print("done")
elif op == "set":
    # set <id> <to> <from...>: one tap's change, printing the state it replaced.
    data = current(args[0], tuple(args[2:]))
    before = data["state"]
    if args[1] == "removed":
        remove()
    else:
        data["state"] = args[1]
        save(data)
    print("%s\t%s" % (before, data["text"]))
elif op == "restore":
    data = load()
    if data is not None and data.get("id") == args[0]:
        data["state"] = args[1]
        save(data)
PY
}

valid_id() {  # <id>
  case "${1:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) refuse "needs the offer id that status prints: ${1:-}" ;;
  esac
}

# A tap that sends its line: <id> moves to <to> from one of <from>, the line is
# sent, and a failed send puts the old state back.
tap_and_send() {  # <id> <to> <prefix> <from...>
  local id=$1 to=$2 prefix=$3 changed before text out rc=0
  shift 3
  changed=$(record set "$id" "$to" "$@") || exit 1
  before=${changed%%$'\t'*}
  text=${changed#*$'\t'}
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-desk-voice.sh" send --source desk-floater-offer -- \
    "$prefix: $text (floater offer $id)") || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    record restore "$id" "$before" || true
    die "the tap could not be sent to Firstmate"
  fi
  printf '%s\n' "$out"
}

cmd_answer() {
  local kind=${1:-} id=${2:-}
  [ "$#" -eq 2 ] || refuse "answer needs do, not-now or stop, and the offer id"
  valid_id "$id"
  case "$kind" in
    do)
      refuse_automated "send a Do it tap into the Firstmate chat"
      tap_and_send "$id" accepted "Do it" open
      ;;
    stop)
      refuse_automated "send a Stop tap into the Firstmate chat"
      tap_and_send "$id" stopping "Stop" accepted working
      ;;
    not-now)
      record set "$id" removed open >/dev/null || exit 1
      printf 'declined\n'
      ;;
    *) refuse "answer needs do, not-now or stop: $kind" ;;
  esac
}

main() {
  local cmd=${1:-}
  [ "$#" -eq 0 ] || shift
  case "$cmd" in
    --help|-h) usage; exit 0 ;;
    offer) record offer "$@" ;;
    status) [ "$#" -eq 0 ] || refuse "status takes no arguments"; record status ;;
    working) [ "$#" -eq 1 ] || refuse "working needs the offer id"; valid_id "$1"; record working "$1" ;;
    done)
      [ "$#" -le 1 ] || refuse "done takes at most the offer id"
      [ "$#" -eq 0 ] || valid_id "$1"
      record finish "$@"
      ;;
    answer) cmd_answer "$@" ;;
    '') usage >&2; exit 2 ;;
    *) refuse "unknown command: $cmd" ;;
  esac
}

main "$@"
