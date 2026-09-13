#!/usr/bin/env bash
# fm-voice-relay.sh - the deterministic freshness, evidence, and presentation
# ledger for the spoken desktop-companion relay.
#
# THE PROBLEM THIS SOLVES: a spoken relay turn is a pipeline of queued messages
# with no shared clock. The companion is still reading a message the captain has
# already corrected, a queue item arrives after the thing it asks for succeeded,
# and the only record of "what is current" lives in a conversation that compacts.
# The observed failures were all one bug: an instruction was acted on, or spoken,
# long after it stopped being true - a stale sign-in password step re-read after
# the sign-in already succeeded, a prior answer repeated as if new, and a queue
# receipt reported as though the work had happened.
#
# So every decision here is a DISK decision. A step is performed only after this
# ledger says its revision is still current; a sentence is spoken only after this
# ledger says that exact sentence has not already been spoken for that topic.
#
# WHAT THIS IS NOT:
#   - Not a backend, not a second fleet manager, not a command gateway: it runs
#     no command for anyone, sends no message, and speaks nothing. It answers
#     "is this still current?" and records what happened.
#   - Not the steering transport. Delivering a correction into a turn that is
#     already running is a real, supported operation, but it belongs to the
#     app-server protocol and lives in bin/fm-voice-relay-appserver.sh
#     (turn/steer, turn/interrupt). This ledger decides WHETHER something is
#     still current; that adapter delivers the correction.
#   - Not a hard cancellation, even with that adapter. A turn can be steered or
#     interrupted; a tool call already executing, a command already run, and any
#     effect already produced outside these gates cannot be recalled. The
#     guarantee here is cooperative and bounded: a caller that asks before each
#     not-yet-performed step and before each presentation cannot act on or speak
#     a superseded revision. `begin` records an in-flight step exactly so a
#     correction reports honestly what is past the point of recall, instead of
#     implying it was killed.
#   - Not proof of speech. `present` records that text was released to the
#     speaking frontend. No receipt here means audio was produced or heard.
#
# OWNERSHIP BOUNDARIES (do not re-implement them here):
#   docs/desktop-companion.md   what the companion is, its setup, its transport,
#                               and the accepted/picked-up/completed distinction.
#   docs/codex-app-backend.md   why `codex-app` is still not a backend.
#   bin/fm-path-lib.sh          durable-directory resolution.
#
# STATE: private, per-home, under $FM_HOME/state/voice-relay (0700). Nothing here
# is tracked, and no session identifier, path, or account value reaches a tracked
# file. A home that never runs this script has no directory and pays nothing.
#
# CONCURRENCY: every state-changing write is a publish-once same-directory hard
# link of a completed temporary file, so two racing callers cannot both win and
# the loser fails closed with a conflict. Revisions advance by link-once too, so
# the current revision is derived from what exists rather than from a mutable
# pointer that a crash could leave half-written. Receipts, once published, are
# never rewritten: a duplicate reads the existing bytes and a mismatch is
# refused with the original untouched.
#
# Usage:
#   fm-voice-relay.sh bind --companion <id> --primary <id> --home <codex-home>
#         --dir <authorized shared directory>
#       Record the exact enrolled session pair this home may talk to. A second
#       bind archives the previous one and invalidates it: every request created
#       under the old binding is refused from then on, so a replaced session can
#       never be answered on its old target. This script never discovers,
#       lists, or guesses a session, and it never checks an identifier against
#       the transport: the caller supplies the exact ids it established
#       elsewhere, and they are recorded as given, not as verified here. The
#       replacement is written in full and renamed into place, so a failed write
#       leaves the previous enrollment in force rather than unbinding the home.
#       A rebind that fails after archiving can leave a history entry for a
#       binding that is still the current one: read that as an inconsistency in
#       the history, never as a lost enrollment. `binding` is authoritative for
#       which one is in force.
#
#   fm-voice-relay.sh binding
#       Print the current binding. Exit 1 when none is bound.
#
#   fm-voice-relay.sh open <topic> --summary <text>
#       Start topic <topic> at revision 1 and print "<request-id> <revision>".
#       The request id is topic-scoped and stable across revisions; corrections
#       advance the revision of the SAME request rather than opening a new one.
#
#   fm-voice-relay.sh revise <topic> --summary <text> [--expect-revision <n>]
#       Record a correction: the next revision of the same request. Every older
#       revision is superseded from this moment. --expect-revision makes the
#       advance a compare-and-swap, so a caller working from a stale read is
#       refused instead of overwriting someone else's correction.
#
#   fm-voice-relay.sh cancel <topic> --reason <text>
#       Stop the topic. Not a rollback: steps already performed stay performed
#       and stay in the evidence. Only not-yet-performed steps are refused.
#       An in-flight step is reported as uninterruptible, not as stopped.
#
#   fm-voice-relay.sh complete <topic> --revision <n> [--outcome <text>]
#       Record the topic's success at that revision and retire every declared
#       step that has not been performed. This is the sign-in case: success
#       retires the pending password and clipboard substeps of THIS topic, and
#       touches no other topic.
#
#   fm-voice-relay.sh step <topic> --step <slug> [--step <slug>]...
#       Declare substeps of this topic so success can retire them. A step
#       identity is scoped to the TOPIC, not to a revision: once a step is
#       performed it stays performed for the topic, and advancing the revision
#       never re-opens it. That is deliberate - a correction preserves the
#       actions already performed and must never re-authorize one - so
#       re-declaring a performed slug leaves it performed and the next gate
#       still answers 6 already-performed. To do a comparable action again on
#       purpose, declare a NEW distinct step slug under the current request, or
#       open a genuinely new request, and establish authority the normal way
#       through check-action and begin. Gated like the commands that act on
#       those substeps: a finished, cancelled, or re-bound topic is refused
#       rather than accumulating declarations nobody could ever perform or
#       retire. Re-declaring a step that is already tracked is idempotent.
#
#   fm-voice-relay.sh check-action <topic> --revision <n> [--step <slug>]
#       THE GATE TO CALL BEFORE PERFORMING ANYTHING. Prints one verdict line and
#       exits with its code (see EXIT CODES). Nothing is recorded.
#
#   fm-voice-relay.sh begin <topic> --revision <n> --step <slug>
#       Claim a step for execution after check-action cleared it. The claim is
#       publish-once, so a step cannot be executed twice by racing callers, and
#       it marks the step in-flight for honest correction reporting.
#
#   fm-voice-relay.sh performed <topic> --revision <n> --step <slug> [--note <text>]
#       Record that the step actually happened. Permanent: a later cancellation
#       or correction never deletes it.
#
#   fm-voice-relay.sh phase <topic> --revision <n> --phase <phase> [--note <text>]
#         [--message-id <id>] [--turn-id <id>] [--queue-exit <n>]
#         [--rejection <text>]
#       Append one evidence line. Phases are kept distinct on purpose:
#         enqueued          the queue command accepted the message. NOTHING ELSE.
#         picked-up         the companion actually began a turn on it.
#         working           the companion reported progress inside that turn.
#         completed         the companion persisted and read back its result.
#         failed            the TURN ended without the result. It says nothing
#                           about whether the instruction ever arrived.
#         handoff-unknown   the queue command failed without refusing the
#                           message, so whether it was accepted is unknown.
#         handoff-rejected  the queue refused it in its own words: a definite
#                           non-send.
#         superseded        a correction overtook this revision.
#         cancelled         the topic was stopped.
#         presented         text was released to the speaking frontend (not audio).
#       The revision and binding are checked as the action gate checks them, so
#       nothing can be recorded against a request that was never opened.
#       A non-zero --queue-exit is NOT proof of a non-send: a timeout, a killed
#       process, or a broken pipe can follow a message that was already
#       enqueued, so on its own it records handoff-unknown and names the
#       duplicate risk. A definite non-send needs the queue's own refusal in
#       --rejection, which is accepted only alongside --phase enqueued and a
#       non-zero --queue-exit - any other combination is refused rather than
#       dropping the refusal and storing a successful handoff.
#       A record carries a transport reference only when it carries the id for
#       its phase - a queue message id for an enqueue, a turn id for a pickup -
#       and a reference is an id this ledger recorded, never one it checked;
#       everything else is stored as an operator claim and reported as one.
#
#   fm-voice-relay.sh handoff <topic> --revision <n>
#       Authorize the handoff ONCE. The first call says send it now; every
#       later call reports the authorization that already exists instead of
#       asking again, which is what ends the "shall I send it?" loop. This
#       command never sends anything itself.
#
#   fm-voice-relay.sh accept <topic> --revision <n> --answer <path>
#         --sha256 <hex> --receipt <path>
#       Completion acceptance, separate from execution and from presentation.
#       Validates the answer is a regular non-symlink file inside the bound
#       authorized directory, recomputes its SHA-256, and publishes the
#       immutable receipt once. An identical repeat is "duplicate" and changes
#       nothing; any disagreement in id, hash, or revision is "conflict",
#       refused, with the existing receipt left byte-identical.
#
#   fm-voice-relay.sh present <topic> --revision <n> --outcome <text>
#         [--limitation <text>] [--question <text>] [--allow-repeat] [--final]
#         --attribution <companion-observed|firstmate-verified|mixed>
#       THE GATE TO CALL BEFORE SPEAKING. Refuses a superseded, cancelled, or
#       unknown revision; suppresses an exact repeat and pure filler; otherwise
#       prints the sentence to speak and records the presentation once. The
#       template is deliberately short - outcome, one material limitation, one
#       question - because everything else belongs in the text artifact.
#       A finished topic speaks only through --final, which announces how it
#       ended: any other sentence about finished work is stale by construction.
#       --attribution is required so a companion observation is never reported
#       as a Firstmate finding, or the other way round.
#
#   fm-voice-relay.sh sent-status <topic> [--revision <n> | --all]
#       Answer "did you send it?" from what is recorded. It never re-sends and
#       never infers: an accepted-but-unconfirmed send is reported as exactly
#       that, which is the whole point of keeping enqueued separate. It answers
#       for the CURRENT revision unless one is named, so a corrected request
#       never reports the fate of the instruction it replaced, and it reports a
#       pickup as backed only when the record carries the transport's own turn
#       id - an id this ledger recorded rather than checked, and an operator's
#       typed pickup stays an unconfirmed claim. --revision and --all ask for
#       different scopes and are refused together, so the header can never claim
#       a wider scope than the lines under it cover.
#
#   fm-voice-relay.sh pending
#       The logical pending count, evidence-backed: one line per open topic
#       with its current revision, its declared-but-unperformed steps, and its
#       last recorded phase. Revisions are grouped, so a request corrected
#       twice counts once rather than three times. Native queue depth and
#       audible playback are printed as unknown, because they are unknown.
#
#   fm-voice-relay.sh pref set <key> --value <text>
#         --source <captain-confirmed|companion-proposal> [--scope <text>]
#   fm-voice-relay.sh pref show <key> | forget <key> | list | render
#       Inspect, edit and forget the companion-scoped style record. Keys are
#       confined to speech., style., detail. and format., and no gate in this
#       script ever reads one, which is the structural reason a preference can
#       never widen execution authority. Each record carries its value, source,
#       scope, revision and supersession; a record written under a replaced
#       binding is reported as invalidated rather than silently inherited.
#
#   fm-voice-relay.sh steer-command <topic> --revision <n> --turn <turn-id>
#       Print the exact bin/fm-voice-relay-appserver.sh command that delivers
#       this revision's correction into the turn running now, with the bound
#       thread and the turn id filled in, so no caller hand-assembles a target.
#       Refuses for a superseded, retired, or unbound revision.
#
#   fm-voice-relay.sh evidence <topic>
#       The per-phase table with UTC timestamps, the gap between phases, and the
#       observable handoff and turn counts. Latencies are wall-clock between
#       recorded events; no cost, saving, or audio claim is derived from them.
#
# EXIT CODES (stable; the verdict word is always the first token of stdout):
#   0  ok / fresh / duplicate acceptance that changed nothing
#   2  usage error
#   3  superseded    a newer revision of this request exists
#   4  unknown-revision  that revision was never opened
#   5  retired       the topic already completed, or was cancelled
#   6  already-performed  that step is done; doing it again is the stale-step bug
#   7  binding-replaced   the request belongs to a binding that no longer exists
#   8  duplicate-suppressed | filler-suppressed  that exact sentence was already
#                    released for presentation, or it carries no outcome at all
#   9  conflict      an id, hash, or revision disagreed; nothing was written,
#                    a record already exists, and repeating the call will not help
#  10  write-failed  the record could not be written at all; nothing was stored,
#                    so the work still has to happen or be escalated
#  11  steps-not-retired  the completion itself was stored and stands, but the
#                    named pending substeps could not be retired; they must be
#                    retired or re-declared by hand. Completing again answers 5
#
# FM_VOICE_RELAY_DIR overrides the state directory (tests only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RELAY_DIR="${FM_VOICE_RELAY_DIR:-$STATE/voice-relay}"

# shellcheck source=bin/fm-path-lib.sh
. "$SCRIPT_DIR/fm-path-lib.sh"

umask 077

die() {
  echo "error: $*" >&2
  exit 2
}

refuse() {  # <code> <verdict> <detail>
  local code=$1 verdict=$2
  shift 2
  printf '%s: %s\n' "$verdict" "$*"
  exit "$code"
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

epoch_now() {
  date -u +%s
}

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" 2>/dev/null | awk '{print $1}'
  else
    sha256sum -- "$1" 2>/dev/null | awk '{print $1}'
  fi
}

sha256_text() {  # reads stdin
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# One-line-per-field records, the same shape as state/<id>.meta, so a human
# reading private state never needs a parser.
record_field() {  # <file> <key>
  [ -f "$1" ] || return 1
  sed -n "s/^$2=//p" "$1" | head -1
}

# Publish-once: write the completed content to a temporary file in the SAME
# directory, then hard link it into place. The link is the atomic step, so a
# racing caller either created it first (return 1, nothing overwritten) or lost
# and sees the winner's bytes.
publish_once() {  # <target> ; content on stdin
  local target=$1 dir tmp status
  dir=$(dirname "$target")
  mkdir -p "$dir" || return 2
  tmp=$(mktemp "$dir/.fm-voice-relay.XXXXXX") || return 2
  cat > "$tmp" || { rm -f "$tmp"; return 2; }
  chmod 0600 "$tmp" 2>/dev/null || true
  if ln "$tmp" "$target" 2>/dev/null; then
    status=0
  else
    status=1
  fi
  rm -f "$tmp"
  return "$status"
}

# publish_once fails for two different reasons that demand opposite responses,
# so they carry different exit codes rather than one shared "something went
# wrong": 1 means a racing caller's record stands and repeating the call cannot
# help (9, conflict), 2 means the write never happened at all - a full disk, a
# read-only state directory, EPERM - so the work still has to happen or be
# escalated (10, write-failed). Both fail closed; only the second is a reason to
# go and look at the disk.
publish_status_or_refuse() {  # <status> <what> <conflict-detail>
  case "$1" in
    0) return 0 ;;
    2) refuse 10 write-failed "the $2 record could not be written; nothing was recorded" ;;
    *) refuse 9 conflict "$3" ;;
  esac
}

# POSIX single-quoting for text that is printed as part of a command a human is
# meant to paste. Free text reaches this - an apostrophe in "don't touch the
# left panel" would otherwise end the quote, and a crafted summary would append
# a second command to the line the captain runs.
shell_quote() {  # <text>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

slug_valid() {  # <slug>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    .|..) return 1 ;;
  esac
  return 0
}

revision_valid() {  # <n>
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
  esac
  return 0
}

sha_valid() {  # <hex>
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

# Collapse a free-text field to one safe line: the record format is one field
# per line, so an embedded newline would forge a second field.
clean_text() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -d '\000'
}

topic_dir() {  # <topic>
  printf '%s/topics/%s\n' "$RELAY_DIR" "$1"
}

request_id() {  # <topic>
  printf 'voice-%s\n' "$1"
}

binding_file() {
  printf '%s/bindings/current\n' "$RELAY_DIR"
}

binding_fingerprint() {
  local file
  file=$(binding_file)
  [ -f "$file" ] || return 1
  record_field "$file" fingerprint
}

# The current revision is DERIVED from the immutable revision records, never
# read from a mutable pointer: a crash between two writes cannot invent one.
current_revision() {  # <topic>
  local dir n best=0
  dir="$(topic_dir "$1")/revisions"
  [ -d "$dir" ] || { printf '0\n'; return 0; }
  for f in "$dir"/*.rec; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .rec)
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt "$best" ] && best=$n
  done
  printf '%s\n' "$best"
}

# "" when open; otherwise "<state> <revision>".
#
# The terminal record is ONE publish-once file per topic, not one per state: a
# per-state file lets a cancellation land on top of a success and makes every
# later gate, evidence line and --final announcement report a completed topic
# as cancelled. Publishing once per topic means the first terminal state wins
# and racing callers cannot both be right.
topic_terminal() {  # <topic>
  local file
  file="$(topic_dir "$1")/terminal/state"
  [ -f "$file" ] || return 0
  printf '%s %s\n' "$(record_field "$file" state)" "$(record_field "$file" revision)"
}

# The evidence class is its OWN tab-separated field, never a word inside the
# detail: the detail is operator free text, and a note reading "evidence=verified"
# must not be readable back as verification. The writer decides the value and
# reduces it to one of two tokens, clean_text strips the tab out of every free
# text field so none can forge the separator, and the reader takes the field by
# position. A record written before this field existed has no sixth field and is
# therefore read as a claim, which is the safe direction.
#
# Only a transport observation carries this notion at all. Everything else the
# ledger writes - an opened request, a hash-checked acceptance, a released
# sentence - is a fact this code established itself, so it is recorded as n/a
# rather than being labelled an unbacked claim about a transport.
record_event() {  # <topic> <revision> <phase> <detail> [reference|claim]
  local dir line class
  dir=$(topic_dir "$1")
  mkdir -p "$dir" || return 1
  # "reference" means the record carries an identifier the transport produced -
  # a queue message id, a turn id. This ledger never calls the transport, so it
  # has NOT checked that identifier against anything: a reference is a pointer
  # someone handed us, not proof. "verified" is accepted for records written by
  # an older build and read back with the same conservative meaning.
  case "${5:-}" in
    reference|verified) class=reference ;;
    claim) class=claim ;;
    *) class=n/a ;;
  esac
  line=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$(utc_now)" "$(epoch_now)" "$2" "$3" "$(clean_text "$4")" "$class")
  printf '%s\n' "$line" >> "$dir/events.log"
}

# Split one event record by position. `read` with IFS set to tab collapses a run
# of tabs into one separator, so an empty detail would silently shift the
# evidence class into the detail slot; this splits on exactly one tab at a time
# instead, which is the whole point of keeping the class in its own field.
EV_UTC=''
EV_EPOCH=''
EV_REV=''
EV_PHASE=''
EV_DETAIL=''
EV_CLASS=''
parse_event() {  # <record line>
  local rest=$1 tab
  tab=$(printf '\t')
  EV_UTC=${rest%%"$tab"*}; rest=${rest#*"$tab"}
  EV_EPOCH=${rest%%"$tab"*}; rest=${rest#*"$tab"}
  EV_REV=${rest%%"$tab"*}; rest=${rest#*"$tab"}
  EV_PHASE=${rest%%"$tab"*}; rest=${rest#*"$tab"}
  case "$rest" in
    *"$tab"*) EV_DETAIL=${rest%%"$tab"*}; EV_CLASS=${rest#*"$tab"} ;;
    *) EV_DETAIL=$rest; EV_CLASS='' ;;
  esac
}

require_topic() {  # <topic>
  slug_valid "$1" || die "invalid topic: $1"
  [ -d "$(topic_dir "$1")/revisions" ] || die "unknown topic: $1"
}

# A path this script will read or write must be unambiguous and inside the
# bound authorized directory. Everything else - a relative path, a traversal, a
# symlink, a directory, a path whose parent resolves elsewhere - is refused
# before any read, because the relay's whole job is to decide from real bytes.
authorized_dir() {
  local file dir
  file=$(binding_file)
  [ -f "$file" ] || return 1
  dir=$(record_field "$file" dir)
  [ -n "$dir" ] || return 1
  printf '%s\n' "$dir"
}

path_under_authorized() {  # <path> ; prints resolved parent
  local path=$1 auth parent resolved
  auth=$(authorized_dir) || return 1
  case "$path" in
    /*) : ;;
    *) return 1 ;;
  esac
  case "$path" in
    *../*|*/..|*..) return 1 ;;
  esac
  parent=$(dirname "$path")
  resolved=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  case "$resolved" in
    "$auth"|"$auth"/*) : ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$resolved"
}

# The shared freshness decision. Every gate calls exactly this, so "fresh" can
# never mean two different things in two places.
freshness_verdict() {  # <topic> <revision> ; echoes "<code> <verdict> <detail>"
  local topic=$1 rev=$2 dir cur terminal tstate trev bound want
  dir=$(topic_dir "$topic")
  cur=$(current_revision "$topic")
  if [ "$cur" = 0 ]; then
    printf '4 unknown-revision topic %s was never opened\n' "$topic"
    return 0
  fi
  if [ ! -f "$dir/revisions/$rev.rec" ]; then
    printf '4 unknown-revision revision %s of %s was never opened\n' "$rev" "$topic"
    return 0
  fi
  bound=$(record_field "$dir/revisions/$rev.rec" binding)
  want=$(binding_fingerprint || true)
  if [ -z "$want" ]; then
    printf '7 binding-replaced no session binding is recorded; rebind before acting\n'
    return 0
  fi
  if [ "$bound" != "$want" ]; then
    printf '7 binding-replaced revision %s belongs to a replaced session binding\n' "$rev"
    return 0
  fi
  terminal=$(topic_terminal "$topic")
  if [ -n "$terminal" ]; then
    tstate=${terminal%% *}
    trev=${terminal##* }
    if [ "$tstate" = cancelled ]; then
      printf '5 retired %s was cancelled at revision %s\n' "$topic" "$trev"
    else
      printf '5 retired %s already completed at revision %s\n' "$topic" "$trev"
    fi
    return 0
  fi
  if [ "$rev" -lt "$cur" ]; then
    printf '3 superseded revision %s of %s was corrected by revision %s\n' "$rev" "$topic" "$cur"
    return 0
  fi
  printf '0 fresh revision %s is current for %s\n' "$rev" "$topic"
}

# Every gate destructured that verdict by hand, four times, with four slightly
# different sets of accepted codes. It lives here once instead, so "fresh" and
# the code each refusal exits with cannot drift apart between commands.
GATE_CODE=''
GATE_WORD=''
GATE_DETAIL=''

# Must be called directly, never inside a command substitution: refuse() exits,
# and a subshell would swallow both the verdict text and the exit code.
gate_or_refuse() {  # <topic> <revision> <accepted codes, space separated>
  local verdict rest accepted=$3 code
  verdict=$(freshness_verdict "$1" "$2")
  GATE_CODE=${verdict%% *}
  rest=${verdict#* }
  GATE_WORD=${rest%% *}
  GATE_DETAIL=${rest#* }
  for code in $accepted; do
    [ "$code" = "$GATE_CODE" ] && return 0
  done
  refuse "$GATE_CODE" "$GATE_WORD" "$GATE_DETAIL"
}

# The same gate, for callers that only want the refusal. check-action prints
# "fresh: ..." on success, which these callers suppress - but redirecting the
# whole call to /dev/null threw the REFUSAL away too, leaving a companion with
# a bare exit code and nothing to say or log.
gate_quietly() {  # <topic> --revision <n> [--step <slug>]
  local out status=0
  out=$(cmd_check_action "$@") || status=$?
  [ "$status" = 0 ] && return 0
  [ -n "$out" ] && printf '%s\n' "$out"
  exit "$status"
}

usage() {
  sed -n '/^# Usage:/,/^# FM_VOICE_RELAY_DIR/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cmd_bind() {
  local companion='' primary='' home='' dir='' file prev fingerprint stamp tmp status
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --companion) companion=${2:-}; shift 2 ;;
      --primary) primary=${2:-}; shift 2 ;;
      --home) home=${2:-}; shift 2 ;;
      --dir) dir=${2:-}; shift 2 ;;
      *) die "bind: unexpected argument: $1" ;;
    esac
  done
  [ -n "$companion" ] || die "bind requires --companion <id>"
  [ -n "$primary" ] || die "bind requires --primary <id>"
  [ -n "$home" ] || die "bind requires --home <codex-home>"
  [ -n "$dir" ] || die "bind requires --dir <authorized directory>"
  dir=$(fm_path_require_directory "authorized" "$dir") || exit 2
  [ -d "$dir" ] || die "bind: authorized directory does not exist: $dir"
  # Store the fully resolved spelling: /tmp and /private/tmp are the same
  # directory, and a containment test that compares two different spellings of
  # one path refuses real files for no reason.
  dir=$(CDPATH='' cd -P -- "$dir" && pwd -P) || die "bind: cannot resolve the authorized directory: $dir"
  companion=$(clean_text "$companion")
  primary=$(clean_text "$primary")
  home=$(clean_text "$home")
  fingerprint=$(printf '%s\n%s\n%s\n%s\n' "$companion" "$primary" "$home" "$dir" | sha256_text)
  file=$(binding_file)
  mkdir -p "$(dirname "$file")/history" || die "bind: cannot create state directory"
  if [ -f "$file" ] && [ "$(record_field "$file" fingerprint)" = "$fingerprint" ]; then
    printf 'ok: binding unchanged %s\n' "$fingerprint"
    return 0
  fi
  # Replace the binding by an atomic rename, never by remove-then-write, and do
  # every fallible step before the one that retires the old record. A home with
  # no binding at all is the worst state this script can be in: every request
  # answers 7 binding-replaced and nothing can be acted on or spoken until
  # someone rebinds. So the replacement is written in full first, the enrollment
  # it replaces is archived second, and only then does the rename retire the old
  # record - a full disk, a read-only state directory, or EPERM at any of those
  # steps leaves the previous enrollment intact and still in force. What that
  # ordering does NOT promise is that a failure leaves no trace: the archive is
  # written BEFORE the replacement is published, so a failure at the final
  # rename leaves a history copy of an enrollment that is still the active one.
  # That is an inconsistency to read - a history entry marked invalidated for a
  # binding that never stopped being current - and never a lost enrollment.
  tmp=$(mktemp "$(dirname "$file")/.fm-voice-relay-binding.XXXXXX" 2>/dev/null) \
    || refuse 10 write-failed "the binding could not be written; any existing binding is untouched and still in force"
  if ! {
    printf 'companion=%s\n' "$companion"
    printf 'primary=%s\n' "$primary"
    printf 'home=%s\n' "$home"
    printf 'dir=%s\n' "$dir"
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'bound_utc=%s\n' "$(utc_now)"
  } > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    refuse 10 write-failed "the binding could not be written; any existing binding is untouched and still in force"
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  if [ -f "$file" ]; then
    # The archive is what makes a replaced enrollment recoverable, so a copy
    # that was never written stops the replacement rather than being shrugged
    # off. A copy that is already there (status 1) is this same enrollment
    # archived by a racing caller, which is exactly what was wanted.
    prev=$(record_field "$file" fingerprint)
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    status=0
    {
      cat "$file"
      printf 'invalidated_utc=%s\n' "$(utc_now)"
      printf 'replaced_by=%s\n' "$fingerprint"
    } | publish_once "$(dirname "$file")/history/$stamp-$prev" >/dev/null 2>&1 || status=$?
    if [ "$status" = 2 ]; then
      rm -f "$tmp"
      refuse 10 write-failed "the enrollment being replaced could not be archived; it is untouched and still in force, and nothing was rebound"
    fi
  fi
  if ! mv -f "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp"
    refuse 10 write-failed "the binding could not be published; any existing binding is untouched and still in force"
  fi
  printf 'ok: bound %s\n' "$fingerprint"
}

cmd_binding() {
  local file
  file=$(binding_file)
  if [ ! -f "$file" ]; then
    printf 'none: no session binding is recorded\n'
    return 1
  fi
  cat "$file"
}

cmd_open() {
  local topic=${1:-} summary='' dir fingerprint rid status=0
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --summary) summary=${2:-}; shift 2 ;;
      *) die "open: unexpected argument: $1" ;;
    esac
  done
  slug_valid "$topic" || die "open requires a topic slug"
  [ -n "$summary" ] || die "open requires --summary <text>"
  fingerprint=$(binding_fingerprint) || die "open: bind a session first"
  dir=$(topic_dir "$topic")
  if [ "$(current_revision "$topic")" != 0 ]; then
    refuse 9 conflict "topic $topic already exists at revision $(current_revision "$topic"); correct it with revise instead of opening a duplicate"
  fi
  rid=$(request_id "$topic")
  mkdir -p "$dir/revisions" || die "open: cannot create topic state"
  {
    printf 'request_id=%s\n' "$rid"
    printf 'topic=%s\n' "$topic"
    printf 'revision=1\n'
    printf 'created_utc=%s\n' "$(utc_now)"
    printf 'created_epoch=%s\n' "$(epoch_now)"
    printf 'summary=%s\n' "$(clean_text "$summary")"
    printf 'binding=%s\n' "$fingerprint"
    printf 'supersedes=\n'
  } | publish_once "$dir/revisions/1.rec" || status=$?
  publish_status_or_refuse "$status" "revision 1 of $topic" "revision 1 of $topic was created concurrently"
  record_event "$topic" 1 opened "$(clean_text "$summary")"
  printf '%s 1\n' "$rid"
}

cmd_revise() {
  local topic=${1:-} summary='' expect='' dir cur next fingerprint rid status=0
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --summary) summary=${2:-}; shift 2 ;;
      --expect-revision) expect=${2:-}; shift 2 ;;
      *) die "revise: unexpected argument: $1" ;;
    esac
  done
  slug_valid "$topic" || die "revise requires a topic slug"
  [ -n "$summary" ] || die "revise requires --summary <text>"
  require_topic "$topic"
  fingerprint=$(binding_fingerprint) || die "revise: bind a session first"
  dir=$(topic_dir "$topic")
  cur=$(current_revision "$topic")
  # A correction inherits the freshness of what it corrects. Without this the
  # revision it mints would carry the CURRENT binding fingerprint, and a single
  # revise would quietly re-adopt the pending work of a retired enrollment onto
  # the newly bound session - the exact routing the second bind invalidated.
  gate_or_refuse "$topic" "$cur" 0
  if [ -n "$expect" ]; then
    revision_valid "$expect" || die "revise: --expect-revision must be a positive integer"
    [ "$expect" = "$cur" ] || refuse 9 conflict "expected revision $expect but $topic is at revision $cur"
  fi
  next=$((cur + 1))
  rid=$(request_id "$topic")
  {
    printf 'request_id=%s\n' "$rid"
    printf 'topic=%s\n' "$topic"
    printf 'revision=%s\n' "$next"
    printf 'created_utc=%s\n' "$(utc_now)"
    printf 'created_epoch=%s\n' "$(epoch_now)"
    printf 'summary=%s\n' "$(clean_text "$summary")"
    printf 'binding=%s\n' "$fingerprint"
    printf 'supersedes=%s\n' "$cur"
  } | publish_once "$dir/revisions/$next.rec" || status=$?
  publish_status_or_refuse "$status" "revision $next of $topic" "revision $next of $topic was created concurrently"
  record_event "$topic" "$cur" superseded "corrected by revision $next"
  record_event "$topic" "$next" opened "$(clean_text "$summary")"
  printf '%s %s\n' "$rid" "$next"
  # Honesty about the boundary: a step already running cannot be recalled by
  # anything in this ledger or in the installed transport.
  inflight_report "$topic"
}

inflight_report() {  # <topic>
  local dir f base
  dir="$(topic_dir "$1")/steps"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.inflight; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .inflight)
    printf 'in-flight: step %s is already running and cannot be interrupted; the correction applies at the next gate\n' "$base"
  done
}

cmd_cancel() {
  local topic=${1:-} reason='' cur terminal status=0
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=${2:-}; shift 2 ;;
      *) die "cancel: unexpected argument: $1" ;;
    esac
  done
  slug_valid "$topic" || die "cancel requires a topic slug"
  [ -n "$reason" ] || die "cancel requires --reason <text>"
  require_topic "$topic"
  cur=$(current_revision "$topic")
  # A topic ends once. Cancelling a topic that already succeeded would rewrite
  # a success as a cancellation everywhere it is read from then on, which is the
  # queued/picked-up/completed confusion this ledger exists to remove.
  terminal=$(topic_terminal "$topic")
  [ -z "$terminal" ] || refuse 5 retired "$topic already ended as ${terminal%% *} at revision ${terminal##* }; a terminal record is published once and is never replaced"
  {
    printf 'topic=%s\n' "$topic"
    printf 'revision=%s\n' "$cur"
    printf 'state=cancelled\n'
    printf 'reason=%s\n' "$(clean_text "$reason")"
    printf 'utc=%s\n' "$(utc_now)"
  } | publish_once "$(topic_dir "$topic")/terminal/state" || status=$?
  publish_status_or_refuse "$status" "terminal state of $topic" "$topic already has a terminal record at revision $cur"
  record_event "$topic" "$cur" cancelled "$(clean_text "$reason")"
  printf 'ok: cancelled %s at revision %s; performed steps are kept, not rolled back\n' "$topic" "$cur"
  inflight_report "$topic"
}

cmd_complete() {
  local topic=${1:-} rev='' outcome='' dir retired=0 unretired='' f base status=0
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --revision) rev=${2:-}; shift 2 ;;
      --outcome) outcome=${2:-}; shift 2 ;;
      *) die "complete: unexpected argument: $1" ;;
    esac
  done
  slug_valid "$topic" || die "complete requires a topic slug"
  revision_valid "$rev" || die "complete requires --revision <n>"
  require_topic "$topic"
  gate_or_refuse "$topic" "$rev" 0
  dir=$(topic_dir "$topic")
  {
    printf 'topic=%s\n' "$topic"
    printf 'revision=%s\n' "$rev"
    printf 'state=completed\n'
    printf 'outcome=%s\n' "$(clean_text "$outcome")"
    printf 'utc=%s\n' "$(utc_now)"
  } | publish_once "$dir/terminal/state" || status=$?
  publish_status_or_refuse "$status" "terminal state of $topic" "$topic already has a terminal record at revision $rev"
  # Success retires this topic's pending substeps and NOTHING else: another
  # topic's work is untouched, which is the whole point of topic scoping.
  if [ -d "$dir/steps" ]; then
    for f in "$dir/steps"/*.declared; do
      [ -f "$f" ] || continue
      base=$(basename "$f" .declared)
      [ -f "$dir/steps/$base.performed" ] && continue
      status=0
      printf 'step=%s\nretired_by_revision=%s\nutc=%s\n' "$base" "$rev" "$(utc_now)" \
        | publish_once "$dir/steps/$base.retired" >/dev/null 2>&1 || status=$?
      case "$status" in
        0|1) retired=$((retired + 1)) ;;
        *) unretired="${unretired:+$unretired }$base" ;;
      esac
    done
  fi
  record_event "$topic" "$rev" completed "$(clean_text "$outcome")"
  # The completion itself is recorded and the terminal state already refuses
  # every later action on this topic, so nothing stale can run. But a retirement
  # that was never written must not be counted as one: the operator is told
  # which substeps still carry a declared record to clear by hand.
  #
  # This is NOT write-failed. Exit 10 promises that nothing was stored and the
  # work still has to happen; here the terminal record and the completed event
  # both published and are true, so a caller that retried on 10 would be told
  # the topic is retired and would have no idea which substeps were left behind.
  # The partial outcome gets its own code and says exactly what is missing.
  if [ -n "$unretired" ]; then
    refuse 11 steps-not-retired "completed $topic at revision $rev and that completion stands; retired $retired pending step(s), but these could not be retired: $unretired; their declarations are still on disk and must be retired or re-declared by hand"
  fi
  printf 'ok: completed %s at revision %s; retired %s pending step(s) of this topic only\n' "$topic" "$rev" "$retired"
}

cmd_step() {
  local topic=${1:-} dir added=0 slug status cur
  shift || true
  require_topic "$topic"
  [ "$#" -gt 0 ] || die "step requires at least one --step <slug>"
  # Declaring a substep is a state-writing command and is gated exactly like the
  # ones that act on it. Ungated, a finished or cancelled topic could still gain
  # a declaration that no success will ever retire, and a topic under a replaced
  # enrollment could gain one that every later gate refuses to perform - both of
  # them counted as pending work nobody can ever do. The gate runs against the
  # current revision because that is what decides whether the topic is still
  # actionable at all; the step records themselves are topic-scoped and outlive
  # every revision. So a declaration exists only where the work it describes is
  # still actionable.
  cur=$(current_revision "$topic")
  gate_or_refuse "$topic" "$cur" 0
  dir="$(topic_dir "$topic")/steps"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --step)
        slug=${2:-}
        slug_valid "$slug" || die "step: invalid step slug: $slug"
        status=0
        printf 'step=%s\ndeclared_utc=%s\n' "$slug" "$(utc_now)" \
          | publish_once "$dir/$slug.declared" >/dev/null 2>&1 || status=$?
        # 1 is a step that is already declared, which is exactly what declaring
        # it again should mean: it is tracked either way, so it counts. 2 is a
        # write that never happened - counting it would report a substep as
        # tracked while nothing retires it and nothing refuses it later, which
        # is the stale-substep failure this ledger exists to prevent.
        case "$status" in
          0|1) added=$((added + 1)) ;;
          *) refuse 10 write-failed "step $slug of $topic could not be declared; nothing was recorded, so this substep is not tracked" ;;
        esac
        shift 2
        ;;
      *) die "step: unexpected argument: $1" ;;
    esac
  done
  printf 'ok: %s step(s) declared for %s\n' "$added" "$topic"
}

# The gate. Reports and records nothing, so a caller may ask as often as it
# likes - which is exactly what "check before every not-yet-performed step"
# needs to be cheap enough to actually do.
cmd_check_action() {
  local topic=${1:-} rev='' step='' dir
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --revision) rev=${2:-}; shift 2 ;;
      --step) step=${2:-}; shift 2 ;;
      *) die "check-action: unexpected argument: $1" ;;
    esac
  done
  slug_valid "$topic" || die "check-action requires a topic slug"
  revision_valid "$rev" || die "check-action requires --revision <n>"
  gate_or_refuse "$topic" "$rev" 0
  if [ -n "$step" ]; then
    slug_valid "$step" || die "check-action: invalid step slug: $step"
    dir="$(topic_dir "$topic")/steps"
    if [ -f "$dir/$step.performed" ]; then
      refuse 6 already-performed "step $step of $topic was already performed"
    fi
    if [ -f "$dir/$step.retired" ]; then
      refuse 5 retired "step $step of $topic was retired by a later success"
    fi
    if [ -f "$dir/$step.inflight" ]; then
      refuse 9 conflict "step $step of $topic is already claimed and running"
    fi
  fi
  printf 'fresh: %s\n' "$GATE_DETAIL"
}

cmd_begin() {
  local topic=${1:-} rev='' step='' dir status=0
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --revision) rev=${2:-}; shift 2 ;;
      --step) step=${2:-}; shift 2 ;;
      *) die "begin: unexpected argument: $1" ;;
    esac
  done
  revision_valid "$rev" || die "begin requires --revision <n>"
  slug_valid "${step:-}" || die "begin requires --step <slug>"
  gate_quietly "$topic" --revision "$rev" --step "$step"
  dir="$(topic_dir "$topic")/steps"
  printf 'step=%s\nrevision=%s\nstarted_utc=%s\npid=%s\n' "$step" "$rev" "$(utc_now)" "$$" \
    | publish_once "$dir/$step.inflight" || status=$?
  publish_status_or_refuse "$status" "in-flight claim for step $step" "step $step of $topic is already claimed"
  record_event "$topic" "$rev" step-begin "$step"
  printf 'ok: claimed %s for revision %s; this claim cannot be revoked once the action leaves the gate\n' "$step" "$rev"
}

cmd_performed() {
  local topic=${1:-} rev='' step='' note='' dir status=0
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --revision) rev=${2:-}; shift 2 ;;
      --step) step=${2:-}; shift 2 ;;
      --note) note=${2:-}; shift 2 ;;
      *) die "performed: unexpected argument: $1" ;;
    esac
  done
  revision_valid "$rev" || die "performed requires --revision <n>"
  slug_valid "${step:-}" || die "performed requires --step <slug>"
  require_topic "$topic"
  # Recording what a revision actually did stays possible after it is superseded
  # or the topic is finished - that history is real, and it is what stops the
  # step being done twice. A revision that was never opened, or one belonging to
  # a replaced enrollment, is refused: it would otherwise write a performed
  # record for a phantom step, which both fabricates an action in the evidence
  # and blocks the real step at the next gate with already-performed.
  gate_or_refuse "$topic" "$rev" "0 3 5"
  dir="$(topic_dir "$topic")/steps"
  printf 'step=%s\nrevision=%s\nperformed_utc=%s\nnote=%s\n' "$step" "$rev" "$(utc_now)" "$(clean_text "$note")" \
    | publish_once "$dir/$step.performed" || status=$?
  publish_status_or_refuse "$status" "performed record for step $step" "step $step of $topic was already recorded as performed"
  rm -f "$dir/$step.inflight"
  record_event "$topic" "$rev" step-performed "$step"
  printf 'ok: recorded %s as performed at revision %s\n' "$step" "$rev"
}

# Record one phase event. Two rules keep this from manufacturing evidence:
# the revision and binding are checked exactly as the action gate checks them,
# so a phase cannot be recorded against a request that was never opened; and a
# record is marked as an operator CLAIM unless it carries the transport's own
# identifier for that phase - a queue message id for an enqueue, a turn id for a
# pickup. That identifier makes the record a REFERENCE, not a verification: this
# ledger never calls the transport and has checked nothing, so a reference is
# the strongest thing a record here can carry, and only a reference may later be
# reported as backed by the transport at all.
cmd_phase() {
  local topic=${1:-} rev='' phase='' note='' msgid='' qexit='' turnid='' rejection='' detail evidence
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --revision) rev=${2:-}; shift 2 ;;
      --phase) phase=${2:-}; shift 2 ;;
      --note) note=${2:-}; shift 2 ;;
      --message-id) msgid=${2:-}; shift 2 ;;
      --turn-id) turnid=${2:-}; shift 2 ;;
      --queue-exit) qexit=${2:-}; shift 2 ;;
      --rejection) rejection=${2:-}; shift 2 ;;
      *) die "phase: unexpected argument: $1" ;;
    esac
  done
  revision_valid "$rev" || die "phase requires --revision <n>"
  require_topic "$topic"
  case "$phase" in
    enqueued|picked-up|working|completed|failed|handoff-rejected|handoff-unknown|superseded|cancelled|presented) : ;;
    *) die "phase: unknown phase: ${phase:-<missing>}" ;;
  esac
  if [ -n "$qexit" ]; then
    case "$qexit" in
      ''|*[!0-9]*) die "phase: --queue-exit must be the command's exit status as a whole number" ;;
    esac
  fi
  # --rejection carries the queue's own refusal, the one thing that turns a
  # failed handoff from unknown into a definite non-send. It is only read on the
  # branch that records a failed enqueue, so any other combination would drop
  # the refusal on the floor and store a successful handoff while holding the
  # proof that nothing was accepted. Refuse the combination instead of
  # discarding it: an argument-order slip must not manufacture a handoff.
  if [ -n "$rejection" ]; then
    [ "$phase" = enqueued ] \
      || die "phase: --rejection is the queue's own refusal of a handoff and is only meaningful with --phase enqueued; got --phase $phase"
    if [ -z "$qexit" ] || [ "$qexit" = 0 ]; then
      die "phase: --rejection needs the failing --queue-exit <n> of the same command; a refusal recorded against a zero or missing exit status would be discarded and the handoff stored as accepted"
    fi
  fi
  # An event about a revision that was never opened, or one belonging to a
  # replaced enrollment, is not history - it is noise that later reads as fact.
  # Superseded and finished revisions DO keep recording: their history is real.
  gate_or_refuse "$topic" "$rev" "0 3 5"

  # A non-zero queue exit does NOT mean the message was refused. A timeout, a
  # killed process, or a broken pipe can all follow a message that was already
  # enqueued, so the only honest outcome is UNKNOWN - and unknown is the answer
  # that stops a blind resend from creating a duplicate. A definite non-send
  # needs the queue's own refusal, which the caller passes in --rejection.
  if [ "$phase" = enqueued ] && [ -n "$qexit" ] && [ "$qexit" != 0 ]; then
    detail="queue_exit=$qexit"
    [ -n "$note" ] && detail="$detail $(clean_text "$note")"
    [ -n "$msgid" ] && detail="$detail message=$(clean_text "$msgid")"
    if [ -n "$rejection" ]; then
      detail="$detail rejection=$(clean_text "$rejection")"
      record_event "$topic" "$rev" handoff-rejected "$detail" reference
      printf 'handoff-rejected: the queue refused the message for %s revision %s (exit %s): %s. Nothing was accepted.\n' \
        "$topic" "$rev" "$qexit" "$(clean_text "$rejection")"
    else
      record_event "$topic" "$rev" handoff-unknown "$detail" claim
      printf 'handoff-unknown: the queue command failed for %s revision %s (exit %s) without saying it refused the message, so whether it was accepted is UNKNOWN. Check the queue or the receipt before sending again - a blind resend can duplicate the work.\n' \
        "$topic" "$rev" "$qexit"
    fi
    return 0
  fi

  evidence=claim
  case "$phase" in
    enqueued)
      [ -n "$msgid" ] && [ "${qexit:-0}" = 0 ] && evidence=reference
      ;;
    picked-up)
      [ -n "$turnid" ] && evidence=reference
      ;;
  esac

  detail=$(clean_text "$note")
  [ -n "$msgid" ] && detail="$detail message=$(clean_text "$msgid")"
  [ -n "$turnid" ] && detail="$detail turn=$(clean_text "$turnid")"
  [ -n "$qexit" ] && detail="$detail queue_exit=$(clean_text "$qexit")"
  record_event "$topic" "$rev" "$phase" "$detail" "$evidence"

  case "$phase:$evidence" in
    enqueued:reference)
      printf 'ok: recorded enqueued for %s revision %s with its queue receipt id. The receipt says the queue accepted the message and nothing else, and this ledger has not checked the id itself.\n' "$topic" "$rev"
      ;;
    enqueued:claim)
      printf 'ok: recorded enqueued for %s revision %s as an operator claim - no queue receipt was supplied, so even acceptance is unconfirmed.\n' "$topic" "$rev"
      ;;
    picked-up:reference)
      printf 'ok: recorded picked-up for %s revision %s against turn id %s - a reference from the transport, not something this ledger checked.\n' "$topic" "$rev" "$turnid"
      ;;
    picked-up:claim)
      printf 'ok: recorded picked-up for %s revision %s as an operator claim - without a turn id this is not evidence the companion started a turn.\n' "$topic" "$rev"
      ;;
    *)
      printf 'ok: recorded %s for %s revision %s\n' "$phase" "$topic" "$rev"
      ;;
  esac
}

# Handoff authorization is recorded ONCE. The second call is not a new prompt
# and not a second send: it reports that the authorization already exists, which
# is what kills the "shall I send it?" loop.
cmd_handoff() {
  local topic=${1:-} rev='' file when status=0
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --revision) rev=${2:-}; shift 2 ;;
      *) die "handoff: unexpected argument: $1" ;;
    esac
  done
  revision_valid "$rev" || die "handoff requires --revision <n>"
  gate_quietly "$topic" --revision "$rev"
  file="$(topic_dir "$topic")/handoff/$rev.authorized"
  printf 'topic=%s\nrevision=%s\nauthorized_utc=%s\n' "$topic" "$rev" "$(utc_now)" | publish_once "$file" || status=$?
  if [ "$status" = 0 ]; then
    record_event "$topic" "$rev" handoff-authorized ''
    printf 'send-now: %s revision %s is authorized; hand it off immediately and record the queue receipt with phase enqueued\n' "$topic" "$rev"
    return 0
  fi
  # Only a lost race means the authorization already exists. A failed write means
  # no authorization was recorded at all, and reporting that as "already
  # authorized" would suppress the send that still has to happen.
  [ "$status" = 2 ] && refuse 10 write-failed "the handoff authorization for $topic revision $rev could not be written; nothing was authorized"
  when=$(record_field "$file" authorized_utc)
  printf 'already-authorized: %s revision %s was authorized at %s; do not ask again and do not send a second copy\n' "$topic" "$rev" "$when"
}

# "Did you send it?" is answered from the ledger. This command never sends,
# never re-queues, and never advises a retry: an accepted-but-unconfirmed send
# is reported as exactly that.
cmd_sent_status() {
  local topic=${1:-} rev='' all=0 log line f_rev phase detail cur
  local last_enq='' last_pick='' last_work='' last_done='' last_fail='' last_pres='' last_rej='' last_unk=''
  local enq_ev='' pick_ev=''
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --revision) rev=${2:-}; shift 2 ;;
      --all) all=1; shift ;;
      *) die "sent-status: unexpected argument: $1" ;;
    esac
  done
  # The header and the body have to answer for the same scope. --all printed
  # "all revisions" while the per-event filter still dropped everything but the
  # named revision, so the one command whose job is to answer "did you send it?"
  # without misleading claimed more than it showed. The two flags ask different
  # questions; asking both is a mistake worth naming rather than resolving
  # silently in either direction.
  if [ "$all" = 1 ] && [ -n "$rev" ]; then
    die "sent-status: --all and --revision <n> ask for different scopes; pass one or the other"
  fi
  require_topic "$topic"
  cur=$(current_revision "$topic")
  # Default to the revision that is current. An older revision's transport
  # history is still readable, but it must be asked for, or a corrected request
  # would report the fate of the instruction it replaced.
  if [ "$all" = 0 ] && [ -z "$rev" ]; then
    rev=$cur
  fi
  log="$(topic_dir "$topic")/events.log"
  if [ ! -f "$log" ]; then
    printf 'unknown: no transport evidence recorded for %s\n' "$topic"
    return 0
  fi
  while IFS= read -r line; do
    parse_event "$line"
    f_rev=$EV_REV
    phase=$EV_PHASE
    detail=$EV_DETAIL
    [ -n "$rev" ] && [ "$f_rev" != "$rev" ] && continue
    case "$phase" in
      enqueued) last_enq="$EV_UTC${detail:+ - $detail}"; enq_ev=$(evidence_class "$EV_CLASS") ;;
      picked-up) last_pick="$EV_UTC${detail:+ - $detail}"; pick_ev=$(evidence_class "$EV_CLASS") ;;
      working) last_work="$EV_UTC${detail:+ - $detail}" ;;
      completed) last_done="$EV_UTC${detail:+ - $detail}" ;;
      failed) last_fail="$EV_UTC${detail:+ - $detail}" ;;
      handoff-rejected) last_rej="$EV_UTC${detail:+ - $detail}" ;;
      handoff-unknown) last_unk="$EV_UTC${detail:+ - $detail}" ;;
      presented) last_pres="$EV_UTC${detail:+ - $detail}" ;;
    esac
  done < "$log"
  if [ "$all" = 1 ]; then
    printf 'status: %s all revisions (current is %s)\n' "$topic" "$cur"
  else
    printf 'status: %s revision %s%s\n' "$topic" "$rev" "$([ "$rev" = "$cur" ] && printf ' (current)' || printf ' (superseded)')"
  fi
  printf '  enqueued: %s\n' "${last_enq:-no record}"
  printf '  picked-up: %s\n' "${last_pick:-no record - the companion is not known to have started a turn}"
  printf '  working: %s\n' "${last_work:-no record}"
  printf '  completed: %s\n' "${last_done:-no record}"
  [ -n "$last_fail" ] && printf '  task failed: %s\n' "$last_fail"
  [ -n "$last_rej" ] && printf '  handoff rejected: %s\n' "$last_rej"
  [ -n "$last_unk" ] && printf '  handoff outcome unknown: %s\n' "$last_unk"
  printf '  released for presentation: %s\n' "${last_pres:-no record}"
  # Each outcome answers only for itself. A failed TASK says nothing about
  # whether the handoff was accepted, an unknown handoff is not a refusal, and a
  # recorded turn id is a reference this ledger never checked.
  if [ -n "$last_rej" ] && [ -z "$last_enq" ]; then
    printf '  verdict: the queue refused the handoff in its own words, so nothing was accepted. Nothing to wait for; send again only deliberately.\n'
  elif [ -n "$last_unk" ] && [ -z "$last_enq" ]; then
    printf '  verdict: the handoff command failed without a refusal, so whether it was accepted is unknown. Not resent: check the queue or the receipt first, because a blind resend can duplicate the work.\n'
  elif [ -z "$last_enq" ]; then
    if [ -n "$last_fail" ]; then
      printf '  verdict: no handoff is recorded. The task failure above is the work'"'"'s outcome, not the handoff'"'"'s.\n'
    else
      printf '  verdict: nothing was handed off yet.\n'
    fi
  elif [ -z "$last_pick" ]; then
    if [ "$enq_ev" = reference ]; then
      printf '  verdict: a queue receipt records acceptance; delivery is unconfirmed. Not resent: a second copy would duplicate the work.\n'
    else
      printf '  verdict: a handoff was recorded without a queue receipt, so even acceptance is unconfirmed. Not resent: read the receipt rather than sending again.\n'
    fi
  elif [ "$pick_ev" = reference ]; then
    printf '  verdict: a pickup was recorded with the transport'"'"'s own turn id. That reference is the strongest evidence here, and this ledger did not itself check it.\n'
  else
    printf '  verdict: a pickup was recorded by the operator with no turn id behind it, so delivery stays unconfirmed. Not resent.\n'
  fi
  if [ -n "$last_fail" ] && [ -n "$last_enq" ]; then
    printf '  note: the task failure above is the work'"'"'s outcome. The handoff state is the line above it.\n'
  fi
}

# A record counts as carrying a transport "reference" only when its own evidence
# field says so - `verified` is the older build's spelling of the same token and
# is read back with the same meaning, which is a recorded pointer, not a check.
# The field is written by this script and read by position, so no operator text -
# a note, a message id, a turn id - can reach or imitate it.
evidence_class() {  # <recorded evidence field>
  case "$1" in
    reference|verified) printf 'reference\n' ;;
    *) printf 'claim\n' ;;
  esac
}

# What the transport column shows. A record with no transport notion prints "-"
# rather than "claim": the ledger established it itself, and rendering a
# hash-checked acceptance as an unbacked claim invites an operator to discount
# the strongest record in the file. A transport record still classifies
# conservatively - anything but a recognised reference token reads as a claim.
transport_label() {  # <recorded evidence field>
  case "$1" in
    reference|verified|claim) evidence_class "$1" ;;
    *) printf -- '-\n' ;;
  esac
}

# Logical pending count: one open request per topic, revisions grouped, so a
# corrected request is one pending item and not three. The native queue depth is
# printed as unknown because the installed transport exposes no way to read it.
cmd_pending() {
  local root topic cur terminal open=0 steps log last_phase
  root="$RELAY_DIR/topics"
  if [ -d "$root" ]; then
    for d in "$root"/*; do
      [ -d "$d" ] || continue
      topic=$(basename "$d")
      terminal=$(topic_terminal "$topic")
      [ -n "$terminal" ] && continue
      cur=$(current_revision "$topic")
      [ "$cur" = 0 ] && continue
      open=$((open + 1))
      steps=0
      if [ -d "$d/steps" ]; then
        for f in "$d/steps"/*.declared; do
          [ -f "$f" ] || continue
          base=$(basename "$f" .declared)
          [ -f "$d/steps/$base.performed" ] && continue
          [ -f "$d/steps/$base.retired" ] && continue
          steps=$((steps + 1))
        done
      fi
      last_phase=unknown
      log="$d/events.log"
      [ -f "$log" ] && last_phase=$(awk -F'\t' 'END{print $4}' "$log")
      printf 'pending: %s revision=%s steps_pending=%s last_phase=%s\n' "$topic" "$cur" "$steps" "${last_phase:-unknown}"
    done
  fi
  printf 'logical-pending: %s\n' "$open"
  printf 'native-queue-depth: unknown - the installed transport exposes no queue inspection\n'
  printf 'audio-playback: unknown - no record here proves anything was heard\n'
}

cmd_accept() {
  local topic=${1:-} rev='' answer='' claimed='' receipt='' parent actual rid existing_id existing_sha status=0
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --revision) rev=${2:-}; shift 2 ;;
      --answer) answer=${2:-}; shift 2 ;;
      --sha256) claimed=${2:-}; shift 2 ;;
      --receipt) receipt=${2:-}; shift 2 ;;
      *) die "accept: unexpected argument: $1" ;;
    esac
  done
  revision_valid "$rev" || die "accept requires --revision <n>"
  [ -n "$answer" ] || die "accept requires --answer <path>"
  [ -n "$receipt" ] || die "accept requires --receipt <path>"
  sha_valid "$claimed" || die "accept requires --sha256 <64 hex characters>"
  require_topic "$topic"
  gate_or_refuse "$topic" "$rev" "0 5"
  parent=$(path_under_authorized "$answer") || refuse 9 conflict "answer path is not an unambiguous file inside the bound authorized directory: $answer"
  path_under_authorized "$receipt" >/dev/null || refuse 9 conflict "receipt path is not inside the bound authorized directory: $receipt"
  [ -L "$answer" ] && refuse 9 conflict "answer path is a symlink: $answer"
  [ -f "$answer" ] || refuse 9 conflict "answer is not a regular file: $answer"
  [ -L "$receipt" ] && refuse 9 conflict "receipt path is a symlink: $receipt"
  actual=$(sha256_file "$answer")
  [ -n "$actual" ] || refuse 9 conflict "could not hash the answer file: $answer"
  rid=$(request_id "$topic")
  if [ "$actual" != "$claimed" ]; then
    record_event "$topic" "$rev" conflict "answer hash disagreed"
    refuse 9 conflict "answer hash disagrees with the queued value; nothing was written"
  fi
  if [ -e "$receipt" ]; then
    existing_id=$(sed -n 's/^Request id: //p' "$receipt" | head -1)
    existing_sha=$(sed -n 's/^Answer SHA-256: //p' "$receipt" | head -1)
    if [ "$existing_id" = "$rid@r$rev" ] && [ "$existing_sha" = "$actual" ]; then
      record_event "$topic" "$rev" duplicate "acceptance repeated; receipt untouched"
      printf 'duplicate: %s revision %s was already accepted; the receipt is unchanged\n' "$rid" "$rev"
      return 0
    fi
    record_event "$topic" "$rev" conflict "receipt exists with different identity"
    refuse 9 conflict "a different receipt already exists at that path; it was left untouched"
  fi
  {
    printf 'Request id: %s@r%s\n' "$rid" "$rev"
    printf 'Answer path: %s/%s\n' "$parent" "$(basename "$answer")"
    printf 'Answer SHA-256: %s\n' "$actual"
    printf 'Received UTC: %s\n' "$(utc_now)"
    printf 'Delivery state: received-by-primary\n'
  } | publish_once "$receipt" || status=$?
  if [ "$status" != 0 ]; then
    [ "$status" = 2 ] && refuse 10 write-failed "the receipt could not be written at $receipt; nothing was recorded"
    record_event "$topic" "$rev" conflict "receipt published concurrently"
    refuse 9 conflict "the receipt was published concurrently; the first one stands"
  fi
  record_event "$topic" "$rev" accepted "$actual"
  printf 'ok: accepted %s revision %s; receipt published once at %s\n' "$rid" "$rev" "$receipt"
}

# The speech gate. Short by construction: the captain asked for outcome first,
# one material limitation, one question, and everything else on screen.
cmd_present() {
  local topic=${1:-} rev='' outcome='' limitation='' question='' attribution='' allow_repeat=0 questions=0 final=0
  local text hash prefix low status=0
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --revision) rev=${2:-}; shift 2 ;;
      --outcome) outcome=${2:-}; shift 2 ;;
      --limitation) limitation=${2:-}; shift 2 ;;
      --question) question=${2:-}; questions=$((questions + 1)); shift 2 ;;
      --attribution) attribution=${2:-}; shift 2 ;;
      --allow-repeat) allow_repeat=1; shift ;;
      --final) final=1; shift ;;
      *) die "present: unexpected argument: $1" ;;
    esac
  done
  revision_valid "$rev" || die "present requires --revision <n>"
  [ -n "$outcome" ] || die "present requires --outcome <text>"
  [ "$questions" -le 1 ] || die "present takes at most one --question; extra questions belong in the text artifact"
  require_topic "$topic"
  case "$attribution" in
    companion-observed) prefix='Companion saw' ;;
    firstmate-verified) prefix='Firstmate confirmed' ;;
    mixed) prefix='Companion saw and Firstmate confirmed' ;;
    *) die "present requires --attribution <companion-observed|firstmate-verified|mixed>" ;;
  esac
  gate_or_refuse "$topic" "$rev" "0 5"
  if [ "$GATE_CODE" = 5 ]; then
    # A finished topic may announce its own ending - that is what --final is
    # for. Everything else it might have said is stale by definition: the
    # queued "type the password now" belongs to work that already succeeded,
    # and speaking it is the exact failure this gate exists to stop.
    if [ "$final" != 1 ]; then
      refuse 5 retired "$GATE_DETAIL; only --final may announce a finished topic"
    fi
    case "$(topic_terminal "$topic")" in
      "completed $rev"|"cancelled $rev") : ;;
      *) refuse 5 retired "revision $rev is not the revision that ended $topic" ;;
    esac
  fi
  low=$(printf '%s' "$outcome" | LC_ALL=C tr '[:upper:]' '[:lower:]' | sed 's/[[:punct:]]*$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
  # Filler is the spoken equivalent of a progress bar: it costs a turn, says
  # nothing, and invites an acknowledgement in reply. Anything that is only a
  # promise to continue is refused; say something when there is something.
  case "$low" in
    ok|okay|sure|"got it"|"will do"|understood|"on it"|thanks|noted|"no problem"|"of course")
      refuse 8 filler-suppressed "\"$outcome\" carries no outcome; say nothing instead"
      ;;
    "one moment"*|"just a moment"*|"just a sec"*|"still working"*|"working on it"*|"let me check"*|"looking into"*)
      refuse 8 filler-suppressed "\"$outcome\" is a progress noise, not a result; speak when there is one"
      ;;
  esac
  text="$prefix: $(clean_text "$outcome")"
  [ -n "$limitation" ] && text="$text Limitation: $(clean_text "$limitation")"
  [ -n "$question" ] && text="$text Next: $(clean_text "$question")"
  hash=$(printf '%s' "$text" | sha256_text)
  if [ "$allow_repeat" = 0 ]; then
    printf 'revision=%s\nutc=%s\ntext=%s\n' "$rev" "$(utc_now)" "$text" \
      | publish_once "$(topic_dir "$topic")/claims/present/$hash" || status=$?
    # A failed write is not a duplicate: reporting it as one would silently
    # withhold a sentence that was never actually claimed.
    [ "$status" = 2 ] && refuse 10 write-failed "the presentation claim for $topic could not be written; nothing was released to the speaker"
    [ "$status" = 0 ] || refuse 8 duplicate-suppressed "that exact sentence was already released for presentation for $topic"
  fi
  record_event "$topic" "$rev" presented "$hash"
  printf '%s\n' "$text"
}

pref_root() {
  printf '%s/prefs\n' "$RELAY_DIR"
}

pref_key_valid() {  # <key>
  case "$1" in
    speech.*|style.*|detail.*|format.*) : ;;
    *) return 1 ;;
  esac
  slug_valid "$1"
}

pref_current() {  # <key> ; prints the latest record path
  local dir n best=0 f
  dir="$(pref_root)/$1"
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.rec; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .rec)
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt "$best" ] && best=$n
  done
  [ "$best" != 0 ] || return 1
  printf '%s/%s.rec\n' "$dir" "$best"
}

# Preferences are style only. No gate in this script ever reads one, so a
# preference cannot widen what may be executed, and a preference recorded under
# a replaced binding is reported as invalidated rather than silently inherited.
cmd_pref() {
  local action=${1:-} key value='' source='' scope='companion' file next want have state status=0
  shift || true
  case "$action" in
    set)
      key=${1:-}; shift || true
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --value) value=${2:-}; shift 2 ;;
          --source) source=${2:-}; shift 2 ;;
          --scope) scope=${2:-}; shift 2 ;;
          *) die "pref set: unexpected argument: $1" ;;
        esac
      done
      pref_key_valid "${key:-}" || die "pref keys are style only and must start with speech., style., detail., or format.; a preference can never grant execution authority"
      [ -n "$value" ] || die "pref set requires --value <text>"
      case "$source" in
        captain-confirmed|companion-proposal) : ;;
        *) die "pref set requires --source <captain-confirmed|companion-proposal>" ;;
      esac
      want=$(binding_fingerprint) || die "pref set: bind a session first"
      file=$(pref_current "$key" || true)
      next=1
      [ -n "$file" ] && next=$(( $(basename "$file" .rec) + 1 ))
      {
        printf 'key=%s\n' "$key"
        printf 'value=%s\n' "$(clean_text "$value")"
        printf 'source=%s\n' "$source"
        printf 'scope=%s\n' "$(clean_text "$scope")"
        printf 'revision=%s\n' "$next"
        printf 'binding=%s\n' "$want"
        printf 'utc=%s\n' "$(utc_now)"
        printf 'state=active\n'
        printf 'supersedes=%s\n' "$((next - 1))"
      } | publish_once "$(pref_root)/$key/$next.rec" || status=$?
      publish_status_or_refuse "$status" "preference $key revision $next" "preference $key revision $next was written concurrently"
      printf 'ok: %s revision %s recorded as %s\n' "$key" "$next" "$source"
      ;;
    show)
      key=${1:-}
      pref_key_valid "${key:-}" || die "pref show requires a style preference key"
      file=$(pref_current "$key") || { printf 'none: %s has no record\n' "$key"; return 1; }
      cat "$file"
      have=$(record_field "$file" binding)
      want=$(binding_fingerprint || true)
      if [ "$have" != "$want" ]; then
        printf 'status=invalidated-by-binding-replacement\n'
        return 7
      fi
      printf 'status=active\n'
      ;;
    list)
      [ -d "$(pref_root)" ] || { printf 'none: no preferences recorded\n'; return 0; }
      want=$(binding_fingerprint || true)
      for d in "$(pref_root)"/*; do
        [ -d "$d" ] || continue
        key=$(basename "$d")
        file=$(pref_current "$key") || continue
        have=$(record_field "$file" binding)
        state=$(record_field "$file" state)
        if [ "$have" != "$want" ]; then
          state='invalidated-by-binding-replacement'
        fi
        printf '%s = %s [source=%s scope=%s revision=%s state=%s]\n' \
          "$key" "$(record_field "$file" value)" "$(record_field "$file" source)" \
          "$(record_field "$file" scope)" "$(record_field "$file" revision)" "$state"
      done
      ;;
    forget)
      key=${1:-}
      pref_key_valid "${key:-}" || die "pref forget requires a style preference key"
      file=$(pref_current "$key") || { printf 'none: %s has no record\n' "$key"; return 1; }
      next=$(( $(basename "$file" .rec) + 1 ))
      want=$(binding_fingerprint || true)
      {
        printf 'key=%s\n' "$key"
        printf 'value=\n'
        printf 'source=captain-confirmed\n'
        printf 'scope=%s\n' "$(record_field "$file" scope)"
        printf 'revision=%s\n' "$next"
        printf 'binding=%s\n' "$want"
        printf 'utc=%s\n' "$(utc_now)"
        printf 'state=forgotten\n'
        printf 'supersedes=%s\n' "$((next - 1))"
      } | publish_once "$(pref_root)/$key/$next.rec" || status=$?
      publish_status_or_refuse "$status" "preference $key revision $next" "preference $key revision $next was written concurrently"
      printf 'ok: %s forgotten at revision %s\n' "$key" "$next"
      ;;
    render)
      [ -d "$(pref_root)" ] || { printf 'none: no preferences recorded\n'; return 0; }
      want=$(binding_fingerprint || true)
      printf 'Companion style preferences (scoped to this enrollment, never global model settings):\n'
      for d in "$(pref_root)"/*; do
        [ -d "$d" ] || continue
        key=$(basename "$d")
        file=$(pref_current "$key") || continue
        [ "$(record_field "$file" state)" = active ] || continue
        [ "$(record_field "$file" binding)" = "$want" ] || continue
        if [ "$(record_field "$file" source)" = captain-confirmed ]; then
          printf -- '- %s: %s (captain-confirmed)\n' "$key" "$(record_field "$file" value)"
        else
          printf -- '- %s: %s (PROPOSAL - not a captain rule until confirmed)\n' "$key" "$(record_field "$file" value)"
        fi
      done
      ;;
    *) die "pref: use set, show, list, forget, or render" ;;
  esac
}

# The correction path for work already in flight: print the exact supported
# steer, with the bound thread filled in. A superseded or retired revision has
# no business steering anything, so the same gate applies here.
cmd_steer_command() {
  local topic=${1:-} rev='' turn='' summary thread
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --revision) rev=${2:-}; shift 2 ;;
      --turn) turn=${2:-}; shift 2 ;;
      *) die "steer-command: unexpected argument: $1" ;;
    esac
  done
  revision_valid "$rev" || die "steer-command requires --revision <n>"
  [ -n "$turn" ] || die "steer-command requires --turn <id> from fm-voice-relay-appserver.sh active-turn"
  gate_quietly "$topic" --revision "$rev"
  thread=$(record_field "$(binding_file)" companion)
  summary=$(record_field "$(topic_dir "$topic")/revisions/$rev.rec" summary)
  # Every field is shell-quoted, including the free-text summary: this line is
  # printed to be pasted, and an apostrophe or a crafted correction would
  # otherwise break the command or append a second one to it.
  printf '%s steer --thread %s --expected-turn %s --text %s --live\n' \
    "$(shell_quote "$SCRIPT_DIR/fm-voice-relay-appserver.sh")" \
    "$(shell_quote "$thread")" "$(shell_quote "$turn")" "$(shell_quote "$summary")"
  printf 'note: the steer fails if that turn already ended; that refusal is correct and must not be retried blindly.\n'
  printf 'fallback: if steering is unavailable or the turn already ended, the correction above is already the current revision of this request; queue it once through codex queue and let check-action and present refuse the superseded step at the next gate.\n'
}

cmd_evidence() {
  local topic=${1:-} log line prev=0 gap handoffs=0 turns_referenced=0 turns_claimed=0 presented=0
  require_topic "$topic"
  log="$(topic_dir "$topic")/events.log"
  printf 'topic: %s request=%s current-revision=%s\n' "$topic" "$(request_id "$topic")" "$(current_revision "$topic")"
  local terminal
  terminal=$(topic_terminal "$topic")
  printf 'state: %s\n' "${terminal:-open}"
  if [ ! -f "$log" ]; then
    printf 'no events recorded\n'
    return 0
  fi
  printf '%-22s %-4s %-16s %-9s %-9s %s\n' UTC REV PHASE GAP TRANSPORT DETAIL
  while IFS= read -r line; do
    parse_event "$line"
    if [ "$prev" = 0 ]; then
      gap='-'
    else
      gap="$((EV_EPOCH - prev))s"
    fi
    prev=$EV_EPOCH
    case "$EV_PHASE" in
      enqueued) handoffs=$((handoffs + 1)) ;;
      picked-up)
        # A pickup counts as a referenced turn only when the record carries the
        # transport's own turn id. An operator saying a turn started is counted
        # apart, under the same word the TRANSPORT column uses for it.
        if [ "$(evidence_class "$EV_CLASS")" = reference ]; then
          turns_referenced=$((turns_referenced + 1))
        else
          turns_claimed=$((turns_claimed + 1))
        fi
        ;;
      presented) presented=$((presented + 1)) ;;
    esac
    printf '%-22s %-4s %-16s %-9s %-9s %s\n' \
      "$EV_UTC" "$EV_REV" "$EV_PHASE" "$gap" "$(transport_label "$EV_CLASS")" "$EV_DETAIL"
  done < "$log"
  # No count here is an observation: nothing in this ledger watched a turn run.
  printf 'counts: handoffs-recorded=%s pickups-with-turn-id=%s pickups-claimed-only=%s presentations-released=%s\n' \
    "$handoffs" "$turns_referenced" "$turns_claimed" "$presented"
  printf 'transport: reference = the record carries an id the transport produced, which this ledger did not check; claim = the operator said so, with no id; - = not a transport record, established by this ledger itself, such as an acceptance whose hash it recomputed.\n'
  printf 'limits: gaps are wall-clock between recorded events, not model or cost measurements.\n'
  printf 'limits: native queue depth and audible playback are unknown to this ledger.\n'
}

main() {
  local cmd=${1:-}
  shift || true
  case "$cmd" in
    bind) cmd_bind "$@" ;;
    binding) cmd_binding "$@" ;;
    open) cmd_open "$@" ;;
    revise) cmd_revise "$@" ;;
    cancel) cmd_cancel "$@" ;;
    complete) cmd_complete "$@" ;;
    step) cmd_step "$@" ;;
    check-action) cmd_check_action "$@" ;;
    begin) cmd_begin "$@" ;;
    performed) cmd_performed "$@" ;;
    phase) cmd_phase "$@" ;;
    handoff) cmd_handoff "$@" ;;
    sent-status) cmd_sent_status "$@" ;;
    pending) cmd_pending "$@" ;;
    accept) cmd_accept "$@" ;;
    present) cmd_present "$@" ;;
    pref) cmd_pref "$@" ;;
    steer-command) cmd_steer_command "$@" ;;
    evidence) cmd_evidence "$@" ;;
    -h|--help|help|'') usage ;;
    *) die "unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"
