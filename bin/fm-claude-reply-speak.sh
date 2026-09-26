#!/usr/bin/env bash
# Claude Stop hook that speaks the primary's final reply through desk voice-out.
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "async": true, so the turn ends at once and this runs in the background.
# It carries out AGENTS.md section 9's voice-out duty on a Claude primary: the
# model writes its reply's opening lead for the ear, and this hook speaks that
# lead whenever the model did not speak a line itself during the turn.
#
# What it speaks: the reply's opening lead (AGENTS.md section 9), taken from the
# Stop payload's `last_assistant_message`, which is the exact final reply:
#   - a leading routine "Captain, shipshape." is dropped first, so that line is
#     never spoken and the news after it is;
#   - only the first plain paragraph, with headings, tables, fenced code, and
#     rules dropped, and list markers, emphasis, backticks, and link targets
#     stripped, because the register would otherwise read pipes and code aloud;
#   - split into sentences only at . ! or ? (optionally closed by a quote or
#     bracket) followed by a word that opens with a capital, a digit, or an
#     opening quote or bracket, so "5.5" and "0.9.1" stay whole;
#   - a closing sentence ending in ":" introduces a list on screen, so it is
#     dropped when another sentence precedes it and ended with "." when it is
#     the only one;
#   - at most 3 sentences and 38 words (about 35, with slack so a lead written
#     to AGENTS.md section 9 is never cut), cut back to the last whole sentence;
#     a first sentence longer than that is kept whole for the register to cut;
#   - ended with "." when it does not already end in . ! or ?;
#   - followed by one voice-only pointer, first match wins, unless the lead
#     already says "on screen", "see below", "is below", or "are below": "The
#     choice is on screen." when the rest of the reply offers lettered options
#     (a line opening "A." or "**A.**"), says "Say A, B ..." or "you choose", or
#     asks for a quoted reply such as Say "land it"; "There's a question for you
#     on screen." when a later paragraph ends with "?"; "The steps are on
#     screen." when the rest holds a numbered list; "More on screen." when the
#     rest holds more than a one-line sign-off of at most 15 words (another
#     paragraph or line, a list, a table, code, or a link) or the cuts above
#     dropped anything. The desk budget (docs/examples/desk-speak-register.toml)
#     is 41 words, and the lead is cut back further so that it and the pointer
#     fit, because past the budget the register drops the pointer sentence.
# When the register refuses the line (bin/fm-speak.sh exit 2), the hook speaks
# only the lead's first sentence plus the pointer, or plus "More on screen." when
# there was none; when the refusal names a decision, as below, "The choice is on
# screen." replaces a missing pointer or "More on screen.". When that is refused
# too, or the lead was a single sentence, it speaks "Captain, a decision is
# waiting for you on screen." or "Captain, my reply is on screen." A decision is named
# only when a refusal reason said the line asked the captain to decide AND the
# reply itself agrees: the rest offers a choice, a question, or steps, or the
# lead asks a question. The reason is the register's own "refused: <reason>"
# line, which bin/fm-speak.sh passes to stderr. No path ever puts a choice to
# the captain by voice.
#
# What stays silent:
#   - an empty or missing `last_assistant_message`, such as a turn that ended on
#     tool calls only;
#   - the routine no-news reply: exactly "Captain, shipshape." after trimming,
#     so a bare routine update costs no speech;
#   - a turn in which bin/fm-speak.sh already handed a line over: the hook
#     records the newest reply number in state/speak-history/ (numbers only
#     grow) after each Stop it accounts for, including after its own speech, and
#     a different number at the next Stop means someone spoke during this turn.
#     Its own speech therefore never silences the next turn;
#   - a Stop superseded by a newer Stop: each Stop writes a fresh token to
#     state/.reply-speak-stop, waits FM_REPLY_SPEAK_SETTLE_MS (default 2000),
#     and speaks only while its token is still the latest. That drops the
#     mid-turn line when another Stop hook blocked the stop and a newer Stop
#     arrived within the settle window. A continuation that runs longer than the
#     window can still speak both lines; the final reply is then spoken as well,
#     because the hook's own speech is not counted as the model's.
#   - a muted or not-opted-in home: bin/fm-speak.sh owns both and exits 0
#     without a sound.
#
# Scope, so workers never speak: every worktree of this repo loads the same
# tracked settings, so the hook runs only in the plain primary checkout (not a
# linked crew or scout worktree, and not a secondmate home, whose chat the
# captain does not read) AND only when this session's harness ancestry holds the
# home session lock - the same scope and identity tests
# bin/fm-claude-stop-autoarm.sh uses, without its stale-lock recovery. A
# Cursor-delivered payload stands down through bin/fm-hook-host-lib.sh, and the
# settings entry's GROK_* guard keeps it inert under Grok.
#
# Never blocks and never prints: every path exits 0 with no stdout, and
# bin/fm-speak.sh's diagnostics are read only for the refusal reason, then
# discarded.
#
# Environment overrides, for tests and unusual layouts:
#   FM_REPLY_SPEAK_CMD           speak command (default: bin/fm-speak.sh)
#   FM_REPLY_SPEAK_SETTLE_MS     wait before the superseded check (default 2000)
#   FM_ROOT_OVERRIDE, FM_HOME, FM_STATE_OVERRIDE  as for the other hooks
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SPEAK="${FM_REPLY_SPEAK_CMD:-$SCRIPT_DIR/fm-speak.sh}"
STOP_TOKEN_FILE="$STATE/.reply-speak-stop"
SEEN_FILE="$STATE/.reply-speak-seen"
SPEAK_HISTORY="$STATE/speak-history"
DECISION_NOTICE="Captain, a decision is waiting for you on screen."
REPLY_NOTICE="Captain, my reply is on screen."

ROUTINE_LINE="Captain, shipshape."
# AGENTS.md section 9 asks for a lead of about 35 words; the cap leaves a few
# words of slack so a lead written to that rule is never cut mid-thought.
MAX_WORDS=38
MAX_SENTENCES=3
# Words the desk register speaks: 16s at 2.6 words a second
# (docs/examples/desk-speak-register.toml).
SPOKEN_WORDS=41

SETTLE_MS=${FM_REPLY_SPEAK_SETTLE_MS:-2000}
case "$SETTLE_MS" in ''|*[!0-9]*) SETTLE_MS=2000 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# --- scope: the lock-holding primary session only ---------------------------
fm_root_is_secondmate_home "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0

# --- claim the latest Stop ---------------------------------------------------
# Written before anything can exit, so an empty newer Stop still supersedes an
# older Stop that is waiting out its settle window.
write_atomic() {  # <file> <text>
  local tmp
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}
MY_TOKEN="$$.$(date +%s).$RANDOM"
write_atomic "$STOP_TOKEN_FILE" "$MY_TOKEN" || exit 0

newest_spoken_number() {
  local entry name newest=none
  for entry in "$SPEAK_HISTORY"/*; do
    name=${entry##*/}
    case "$name" in ''|*[!0-9]*) continue ;; esac
    [ -d "$entry" ] || continue
    if [ "$newest" = none ] || [ "$name" -gt "$newest" ]; then newest=$name; fi
  done
  printf '%s\n' "$newest"
}
record_seen() {
  write_atomic "$SEEN_FILE" "$(newest_spoken_number)" || true
}

# --- did bin/fm-speak.sh already speak during this turn? ---------------------
# Only a baseline this hook recorded counts; without one (first Stop on a new
# home) the reply is spoken.
SPOKE_THIS_TURN=0
if [ -f "$SEEN_FILE" ]; then
  SEEN=$(cat "$SEEN_FILE" 2>/dev/null || true)
  [ "$SEEN" = "$(newest_spoken_number)" ] || SPOKE_THIS_TURN=1
fi
record_seen
[ "$SPOKE_THIS_TURN" -eq 0 ] || exit 0

MSG=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty | strings' 2>/dev/null || true)

# --- routine no-news line: never spoken -------------------------------------
MSG=${MSG#"${MSG%%[![:space:]]*}"}
case "$MSG" in
  "$ROUTINE_LINE"|"$ROUTINE_LINE"[[:space:]]*) MSG=${MSG#"$ROUTINE_LINE"} ;;
esac
case "$MSG" in
  *[![:space:]]*) ;;
  *) exit 0 ;;
esac

# --- spoken lead: first plain paragraph ---------------------------------------
# One pass prints two lines: the pointer cue found in the rest of the reply
# (choice, question, steps, more, or none; first match wins in that order), then
# the first plain paragraph, joined onto one line.
SCAN=$(printf '%s\n' "$MSG" | awk '
  function cue_line(line,   t, ws) {
    if (line ~ /^[[:space:]]*(```|~~~)/) { rfence = !rfence; rich = 1; end_para(); return }
    if (rfence) return
    if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*([-*_][[:space:]]*){3,}$/) { end_para(); return }
    rlines++
    rwords += split(line, ws)
    if (line ~ /^[[:space:]]*\|/ || line ~ /\]\(|https?:\/\//) rich = 1
    if (line ~ /^[[:space:]]*[|#]/) { end_para(); return }
    if (line ~ /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/) rich = 1
    if (line ~ /^[[:space:]]*[0-9]+[.)][[:space:]]/) steps = 1
    t = line
    sub(/^[[:space:]]*(>[[:space:]]*)?([-*+][[:space:]]+)?/, "", t)
    if (t ~ /^(\*\*|__)?A[.)](\*\*|__)?[[:space:]]/) choice = 1
    if (line ~ /[Ss]ay A(,| or) B/) choice = 1
    if (tolower(line) ~ /you choose/) choice = 1
    # Only an instruction to answer with a quoted phrase, such as Say "land it",
    # not a quote inside news or a question ("did the text say "Stopped"?").
    if (t ~ /(^(\*\*|__)?|[.:;!?][*_]*[[:space:]]+|([Oo]therwise|[Jj]ust|[Tt]hen|[Pp]lease)[[:space:]]+)([Ss]ay|[Rr]eply)( with)?:?[[:space:]]+["`\047]/) choice = 1
    last = line
  }
  function end_para(   t) {
    if (last == "") return
    t = last
    sub(/[[:space:]*_`"\047)]*$/, "", t)
    if (t ~ /\?$/) question = 1
    last = ""
  }
  rest { cue_line($0); next }
  /^[[:space:]]*(```|~~~)/ { if (n) { rest = 1; cue_line($0); next } fence = !fence; next }
  fence { next }
  /^[[:space:]]*\|/ || /^[[:space:]]*#/ || /^[[:space:]]*([-*_][[:space:]]*){3,}$/ || /^[[:space:]]*$/ {
    if (n) { rest = 1; cue_line($0) }
    next
  }
  {
    line = $0
    sub(/^[[:space:]]*>[[:space:]]*/, "", line)
    sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/, "", line)
    para = para line " "
    n++
  }
  END {
    end_para()
    more = rich || rlines > 1 || rwords > 15
    print (choice ? "choice" : question ? "question" : steps ? "steps" : more ? "more" : "none")
    print para
  }
')
CUE=${SCAN%%$'\n'*}
PARA=
case "$SCAN" in *$'\n'*) PARA=${SCAN#*$'\n'} ;; esac
PARA=$(printf '%s\n' "$PARA" | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g; s/(\*\*|__|`)//g')

# Shape the lead and print five lines: the lead, its first sentence, the
# voice-only pointer (empty when none applies), 1 when the first sentence already
# points at the screen, and 1 when the reply itself holds a choice, a question,
# or steps for the captain.
SHAPED=$(printf '%s\n' "$PARA" | awk -v max_words="$MAX_WORDS" -v max_sentences="$MAX_SENTENCES" \
  -v budget="$SPOKEN_WORDS" -v cue="$CUE" '
  function closed(word) { return word ~ /[.!?]["\047)\]]*$/ }
  function finish(word) {
    if (closed(word)) return word
    sub(/[,;:-]+$/, "", word)
    return word "."
  }
  function join(from, to,   i, out) {
    out = ""
    for (i = from; i < to; i++) out = out w[i] " "
    return out finish(w[to])
  }
  function onscreen(text) { text = tolower(text); return text ~ /on screen|see below|(is|are) below/ }
  function words(text,   ws) { return split(text, ws, " ") }
  function keep(limit,   s, k) {
    k = 1
    for (s = 2; s <= count && s <= max_sentences; s++) {
      if (end_at[s] > limit) break
      k = s
    }
    return k
  }
  {
    for (i = 1; i <= NF; i++) w[++total] = $i
  }
  END {
    if (total == 0) exit
    # A sentence ends at . ! or ? (optionally closed by a quote or bracket)
    # followed by a word that can open one, so "5.5" and "0.9.1" stay whole.
    count = 0
    for (i = 1; i <= total; i++) {
      if (i == total || (closed(w[i]) && w[i + 1] ~ /^["\047(\[]?[A-Z0-9]/)) end_at[++count] = i
    }
    cut = 0
    # A closing "...:" only introduces what follows it on screen.
    if (w[end_at[count]] ~ /:$/) {
      if (count > 1) { count--; cut = 1 }
      else sub(/:$/, ".", w[end_at[count]])
    }
    asks = 0
    for (s = 1; s <= count; s++) if (w[end_at[s]] ~ /\?["\047)\]]*$/) asks = 1
    pointer = ""
    if (cue == "choice") pointer = "The choice is on screen."
    else if (cue == "question") pointer = "There\047s a question for you on screen."
    else if (cue == "steps") pointer = "The steps are on screen."
    else if (cue == "more") pointer = "More on screen."
    kept = keep(max_words)
    if (onscreen(join(1, end_at[kept]))) pointer = ""
    else {
      if (pointer == "" && (cut || kept < count)) pointer = "More on screen."
      # Leave room in the register budget for the pointer, so it is always heard.
      if (budget - words(pointer) < max_words) kept = keep(budget - words(pointer))
    }
    lead = join(1, end_at[kept])
    first = join(1, end_at[1])
    print lead
    print first
    print pointer
    print (onscreen(first) ? 1 : 0)
    print ((cue ~ /^(choice|question|steps)$/ || asks) ? 1 : 0)
  }
')
LEAD=$(printf '%s\n' "$SHAPED" | sed -n 1p)
FIRST=$(printf '%s\n' "$SHAPED" | sed -n 2p)
POINTER=$(printf '%s\n' "$SHAPED" | sed -n 3p)
FIRST_POINTS=$(printf '%s\n' "$SHAPED" | sed -n 4p)
ASKS_CAPTAIN=$(printf '%s\n' "$SHAPED" | sed -n 5p)
case "$LEAD" in
  *[![:space:]]*) ;;
  *) exit 0 ;;
esac
LINE=$LEAD${POINTER:+ $POINTER}

# --- speak only while this Stop is still the latest ---------------------------
still_latest() {
  [ "$(cat "$STOP_TOKEN_FILE" 2>/dev/null || true)" = "$MY_TOKEN" ]
}
if [ "$SETTLE_MS" -gt 0 ]; then
  sleep "$((SETTLE_MS / 1000)).$(printf '%03d' "$((SETTLE_MS % 1000))")"
fi
still_latest || exit 0

# --- speak, falling back when the register refuses ---------------------------
# bin/fm-speak.sh exits 2 when the register refuses and passes the register's
# own "refused: <reason>" line to stderr, which says whether the line asked the
# captain to decide. The register matches approval words in plain news too, so
# a decision counts only when the reply itself asks the captain something.
REFUSED_DECISION=0
speak_line() {  # <line>; returns bin/fm-speak.sh's exit status
  local err rc=0
  err=$("$SPEAK" "$1" 2>&1 >/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 2 ] && [ "$ASKS_CAPTAIN" = 1 ] \
    && printf '%s\n' "$err" | grep -Eq '^refused:.*(decide|spoken yes)'; then
    REFUSED_DECISION=1
  fi
  return "$rc"
}

rc=0
speak_line "$LINE" || rc=$?
if [ "$rc" -eq 2 ] && [ "$FIRST" != "$LEAD" ] && still_latest; then
  # Only the first sentence, plus a pointer to what the voice left out.
  FALLBACK_POINTER=$POINTER
  case "$REFUSED_DECISION:$FALLBACK_POINTER" in
    1:|"1:More on screen.") FALLBACK_POINTER="The choice is on screen." ;;
    0:) FALLBACK_POINTER="More on screen." ;;
  esac
  [ "$FIRST_POINTS" != 1 ] || FALLBACK_POINTER=
  rc=0
  speak_line "$FIRST${FALLBACK_POINTER:+ $FALLBACK_POINTER}" || rc=$?
fi
if [ "$rc" -eq 2 ] && still_latest; then
  if [ "$REFUSED_DECISION" -eq 1 ]; then
    speak_line "$DECISION_NOTICE" || true
  else
    speak_line "$REPLY_NOTICE" || true
  fi
fi
# Account for this hook's own line so the next Stop does not read it as the
# model having spoken during that turn. This is recorded even when a newer Stop
# arrived meanwhile: that Stop already took its baseline before this line was
# handed over, so leaving the line unaccounted would silence the turn after it.
record_seen
exit 0
