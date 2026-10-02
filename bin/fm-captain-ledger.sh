#!/usr/bin/env bash
# fm-captain-ledger.sh - the captain ledger: every prompt the captain submits to
# the primary, written to disk before the model answers, so a decision given in
# chat survives a session that never runs /stow, a compaction, or a crash.
#
# WHY. A decision the captain gives in chat used to live only in conversation
# until an agent chose to write it down. Stow memory, the captain-hold
# lifecycle, and RECORD DIVERGENCE all act on what an agent already recorded,
# so a turn that said "all logged" without logging lost the words for good.
# The ledger takes that step away from the model: a code-owned hook records the
# words, and the session-start digest keeps listing them until an agent says it
# has reconciled them.
#
# This script never interprets the words. It captures and counts; the agent
# reconciles each entry against data/captain.md, the backlog, and the decision
# files (or runs /stow), then marks the ledger reconciled.
#
# WRITER. `hook claude` runs as the tracked Claude UserPromptSubmit hook in
# .claude/settings.json. It appends the submitted prompt, with only the
# whitespace at its very end trimmed, and records nothing for:
#   - input bin/fm-operational-input.sh classifies as operational (watcher
#     wakes, turn-end guard follow-ups, away-supervisor escalations, launch
#     briefs, from-firstmate steers, and their pre-protocol forms), and a
#     prompt opening with the current "FIRSTMATE_OP: v1 <kind>: " label whose
#     mark Claude stripped from typed input;
#   - a prompt that opens with <task-notification>, the wrapper Claude puts
#     around a turn it started itself, such as a Stop-hook rewake;
#   - a payload Cursor delivered through the same settings file
#     (bin/fm-hook-host-lib.sh), any event other than UserPromptSubmit, and an
#     empty prompt;
#   - any session outside a genuine primary root (a plain firstmate checkout or
#     a marked secondmate home, never a linked crew or scout worktree, and never
#     a task worker pane) or one that does not hold this home's session lock
#     (bin/fm-primary-scope-lib.sh), so crewmates and read-only second sessions
#     record nothing.
# It always exits 0, prints nothing, and writes nothing to stderr, so it can
# neither block nor delay a prompt.
#
# FILE. data/captain-ledger.jsonl, append-only, created owner-only (mode 600)
# and kept inside gitignored data/. One JSON object per line:
#   {"seq":N,"epoch":N,"session":"<harness session id>","text":"..."}
# seq rises by one per entry and stays above the cursor even if the ledger is
# removed. text is capped at 4000 characters, its truncation note included,
# keeping the head and the tail. The ledger is never trimmed.
#
# CURSOR. state/.captain-ledger-cursor holds the seq of the newest entry marked
# reconciled. `pending` lists the entries above it: a heading with their count
# and the date of the oldest, previews of the newest 12 (each at most 160
# characters, whitespace collapsed), the ledger path, and the one instruction to
# reconcile and then run `mark <seq>` with the newest seq it showed. It prints
# nothing when nothing is pending, and a heading naming the ledger when the
# ledger exists but cannot be read.
# bin/fm-session-start.sh prints that output as a digest section on both its
# full and --reemit paths, so it reappears at every startup, /clear, and
# compaction until `mark` moves the cursor past every entry.
# `mark <seq>` moves the cursor up to that seq, never backwards and never past
# the newest entry, so a prompt recorded while an agent reconciled what pending
# showed stays pending; a bare `mark` moves it to the newest entry.
# The ledger holds the captain's raw words, so nothing but `pending` (and through
# it the digest) ever prints them.
#
# Usage:
#   fm-captain-ledger.sh hook claude   a UserPromptSubmit payload on stdin
#   fm-captain-ledger.sh pending       list entries not yet marked reconciled
#   fm-captain-ledger.sh mark [<seq>]  mark entries through <seq> reconciled
#                                      (every entry so far when omitted)
# hook always exits 0 silently; pending and mark exit 0, and 2 on misuse.
#
# Environment overrides, for tests and unusual layouts:
#   FM_ROOT_OVERRIDE, FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$DATA/captain-ledger.jsonl"
CURSOR="$STATE/.captain-ledger-cursor"

TEXT_CAP=4000
PREVIEW_COUNT=12
PREVIEW_CAP=160

usage() {
  sed -n '/^# Usage:/,/^# hook always/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# The seq of the newest entry marked reconciled, 0 when none.
cursor_seq() {
  local seq=
  [ -f "$CURSOR" ] && IFS= read -r seq < "$CURSOR" 2>/dev/null
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  printf '%s\n' "$seq"
}

# The highest seq in the ledger, 0 when it is missing or holds none.
# The last line answers in the common case, read without a jq process because
# this writer always puts seq first; a torn or foreign last line falls back to
# a scan of the whole file.
ledger_last_seq() {
  local line seq
  [ -f "$LEDGER" ] || { printf '0\n'; return 0; }
  line=$(tail -n 1 "$LEDGER" 2>/dev/null)
  if [[ $line =~ ^\{\"seq\":([1-9][0-9]*),.*\}$ ]]; then
    seq=${BASH_REMATCH[1]}
  else
    seq=$(jq -Rn '[inputs | fromjson? | select(type == "object") | .seq | numbers] | max // 0' "$LEDGER" 2>/dev/null)
  fi
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  printf '%s\n' "$seq"
}

hook_claude() {
  # kind receives the classifier's verdict, which only its exit status decides here.
  # shellcheck disable=SC2034
  local payload parsed session text trimmed kind last cursor seq record
  payload=$(cat 2>/dev/null) || return 0
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh" || return 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh" || return 0
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh" || return 0

  fm_is_task_worker && return 0
  fm_hook_payload_is_foreign_host "$payload" && return 0

  # Line 1 is the session id; the prompt follows as the remainder.
  parsed=$(printf '%s' "$payload" | jq -r '
    select(type == "object" and .hook_event_name == "UserPromptSubmit")
    | ((.prompt // "") | tostring | sub("\\s+\\z"; "")) as $text
    | select($text != "")
    | "\((.session_id // "") | tostring | gsub("[\\n\\r]"; ""))\n\($text)"' 2>/dev/null) || return 0
  [ -n "$parsed" ] || return 0
  session=${parsed%%$'\n'*}
  text=${parsed#*$'\n'}
  [ -n "$text" ] || return 0

  trimmed=${text#"${text%%[![:space:]]*}"}
  case "$trimmed" in
    '<task-notification>'*) return 0 ;;
  esac
  fm_operational_input_classify "$text" kind && return 0
  # Claude Code strips invisible characters from typed input, so operational
  # input typed into a Claude pane arrives without its leading mark.
  fm_operational_generic_kind "$FM_OPERATIONAL_MARK$text" kind && return 0

  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  fm_session_lock_owned_by_self "$STATE" || return 0

  umask 077
  [ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null || return 0
  last=$(ledger_last_seq)
  cursor=$(cursor_seq)
  [ "$cursor" -le "$last" ] || last=$cursor
  seq=$((last + 1))
  record=$(printf '%s' "$text" | jq -cRs --argjson seq "$seq" \
    --arg session "$session" --argjson cap "$TEXT_CAP" '
      def note($n): "\n[ledger truncated: \($n) characters omitted]\n";
      def capped: if length <= $cap then .
        else length as $len
          | ($cap - (note($len - $cap + (note($len - $cap) | length)) | length)) as $keep
          | .[0:($keep / 2 | ceil)] + note($len - $keep) + .[$len - ($keep / 2 | floor):]
        end;
      {seq: $seq, epoch: (now | floor), session: $session, text: capped}' 2>/dev/null) || return 0
  [ -n "$record" ] || return 0
  # A last line left without its newline would swallow this record into one
  # unreadable line, so close it first.
  # (Command substitution strips a final newline, so a closed file reads empty.)
  if [ -s "$LEDGER" ] && [ -n "$(tail -c 1 "$LEDGER" 2>/dev/null)" ]; then
    printf '\n%s\n' "$record" >> "$LEDGER"
  else
    printf '%s\n' "$record" >> "$LEDGER"
  fi
  return 0
}

pending() {
  local after out
  [ -e "$LEDGER" ] || return 0
  after=$(cursor_seq)
  if [ ! -r "$LEDGER" ] || ! command -v jq >/dev/null 2>&1 \
    || ! out=$(jq -Rnr --argjson after "$after" --argjson show "$PREVIEW_COUNT" \
      --argjson cap "$PREVIEW_CAP" --arg ledger "$LEDGER" '
      def preview: gsub("\\s+"; " ") | sub("^ "; "")
        | if length <= $cap then . else .[0:($cap - 3)] + "..." end;
      [inputs | fromjson? | select(type == "object" and (.seq | type) == "number"
        and (.text | type) == "string" and .seq > $after)] as $all
      | select($all | length > 0)
      | ($all | min_by(.seq)) as $oldest
      | ($all | sort_by(.seq) | .[-$show:]) as $shown
      | "UNRECONCILED CAPTAIN WORDS (\($all | length) since \(($oldest.epoch // 0) | strflocaltime("%Y-%m-%d")))",
        ($shown[] | "  #\(.seq) \((.epoch // 0) | strflocaltime("%Y-%m-%d %H:%M"))  \(.text | preview)"),
        (if ($all | length) > ($shown | length)
          then "  (\(($all | length) - ($shown | length)) earlier entries not shown)" else empty end),
        "Ledger: \($ledger) (full text of every entry after #\($after))",
        "Reconcile each entry against data/captain.md, the backlog, and the decision files, or run /stow, then run \($mark) \($all | max_by(.seq) | .seq)."' \
      --arg mark "$FM_ROOT/bin/fm-captain-ledger.sh mark" "$LEDGER" 2>/dev/null); then
    printf 'UNRECONCILED CAPTAIN WORDS (unknown - the ledger could not be read)\n'
    printf 'Ledger: %s\n' "$LEDGER"
    printf 'Read it directly and reconcile every entry after #%s, then run %s/bin/fm-captain-ledger.sh mark <the newest seq you reconciled>.\n' "$after" "$FM_ROOT"
    return 0
  fi
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

mark() {  # [<seq>]
  local last cursor tmp
  last=$(ledger_last_seq)
  cursor=$(cursor_seq)
  if [ "$#" -eq 1 ] && [ "$1" -lt "$last" ]; then
    last=$1
  fi
  if [ "$last" -le "$cursor" ]; then
    printf 'captain ledger: nothing new to mark (reconciled through #%s)\n' "$cursor"
    return 0
  fi
  [ -d "$STATE" ] || { printf 'fm-captain-ledger: state directory missing: %s\n' "$STATE" >&2; return 1; }
  umask 077
  tmp=$(mktemp "$CURSOR.XXXXXX" 2>/dev/null) || { printf 'fm-captain-ledger: could not write %s\n' "$CURSOR" >&2; return 1; }
  if printf '%s\n' "$last" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CURSOR" 2>/dev/null; then
    printf 'captain ledger: reconciled through #%s\n' "$last"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  printf 'fm-captain-ledger: could not write %s\n' "$CURSOR" >&2
  return 1
}

case "${1:-}" in
  hook)
    exec 2>/dev/null
    [ "$#" -eq 2 ] && [ "$2" = claude ] || exit 0
    hook_claude >/dev/null
    exit 0
    ;;
  pending)
    [ "$#" -eq 1 ] || usage
    pending
    exit 0
    ;;
  mark)
    [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [[ $2 =~ ^[1-9][0-9]{0,17}$ ]]; } || usage
    shift
    mark "$@"
    exit $?
    ;;
  -h|--help)
    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) usage ;;
esac
