#!/usr/bin/env bash
# fm-backport.sh - check, stamp and track the cards of the weekly Backport pass.
#
# WHAT. A Backport card is one improvement written so that any Starship can
# rebuild it, with nothing in it that says or hints who, where, when or for
# whom. docs/backport.md owns the rule, the swap table and the card shape; the
# opt-in backport skill owns the weekly pass. This script is the machine part:
# it refuses a card that breaks the shape or the anonymity rule, stamps a card
# that passes with a stamp bound to its exact text, records the fresh reader's
# verdict and the owner's answer against that same text, and prints a card
# for sending or building only once all three hold.
#
# OFF BY DEFAULT. Nothing runs until the home switches Backport on with a file
# at config/backport, whatever it holds; every command refuses before then.
# The same file switches on the backport skill (bin/fm-opt-in-skills.sh).
# A home must also keep a private word list or a config/leak-names-approved
# file (an empty one is enough), because the leak guard checks new names only
# where one exists, and check refuses without one.
#
# FOLDER. Everything lives in the home's private data/backport/ (mode 700):
#   cards/<slug>.md    the card, the only thing that ever leaves the home
#   notes/<slug>.md    where it came from, the raw note, the owner's words and
#                      anything else that stays home; free form, never read
#                      by this script and never sent
#   ledger.tsv         one line per event: epoch, slug, event, sha256 of the
#                      card text at that moment, detail
# A slug is lower-case letters, digits and dashes.
#
# THE CHECK. check <slug> refuses the card, naming each problem by line, when:
#   - the shape differs: a first line "# <title>", then the lines Kind:,
#     Fits:, Needs: and Lands in: in that order, Kind one of fix, rule,
#     practice or capability, optionally followed by one short note in
#     brackets, then exactly the six sections "## The problem",
#     "## The general rule", "## How it works", "## Evidence it worked",
#     "## Left out on purpose" and "## Done when", in that order, none empty,
#     and no other heading or text outside them;
#   - it holds more than 500 words;
#   - it holds a date or a time: a four-digit year, a numeric date, a month
#     name, a clock time such as 23:30 or 9pm, or a relative time such as
#     today, tonight, yesterday, this morning, last week or three days ago;
#     a count written 9/10 looks like a date too, so write 9 of 10;
#   - it holds a link or address other than one into this repository's own
#     public home on GitHub (the origin of this checkout): any other URL, a
#     bare www. address or an email address;
#   - it holds quoted speech: a block quote, or three or more words inside
#     double or single quotes, straight or curly, anywhere but under
#     "## How it works", where a rule card carries the exact wording to add;
#     code fences are no exception outside that section;
#   - bin/fm-leak-guard.sh --text --new-names finds a private word, a new
#     name, a customer data shape or a key in it.
# A card that passes gets a "checked" event carrying its sha256: the stamp.
# Any later edit changes the hash, so the stamp, the reader's verdict and the
# answer no longer match and the card needs a new check.
#
# Usage:
#   fm-backport.sh check <slug>             check and stamp a card
#   fm-backport.sh reader <slug> pass|fail  record the fresh reader's verdict
#                                           on the stamped text
#   fm-backport.sh answer <slug> yes|not-now|never
#                                           record the owner's answer on the
#                                           stamped text
#   fm-backport.sh ready <slug>             check again, then print the card
#                                           only when it is stamped, the
#                                           reader passed it and the answer is
#                                           yes, all for the text as it is now
#   fm-backport.sh sent <slug> [<detail>]   record that the card went to the
#                                           publishing Starship
#   fm-backport.sh built <slug> [<detail>]  record the public change it became
#   fm-backport.sh list                     show every card and where it stands
# Exit codes: 0 done, 1 refused (with each reason on stderr), 2 misuse.
#
# WHAT LIST SAYS. One line per card, tab separated: slug, state, title. The
# states are: new (never checked), changed (edited since its stamp), checked,
# reader failed, waiting for yes, yes, not now (back after 30
# days), not now, due again, set aside (a second not now, never raised
# again), never, sent and built.
#
# Environment overrides, for tests and unusual layouts:
#   FM_HOME, FM_BACKPORT_NOW (epoch used as now)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="$FM_HOME/config"
DIR="$FM_HOME/data/backport"
LEDGER="$DIR/ledger.tsv"
WORD_CAP=500
NOT_NOW_SECONDS=$((30 * 86400))

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

refuse() {
  printf 'fm-backport: %s\n' "$*" >&2
  exit 1
}

now() {
  printf '%s\n' "${FM_BACKPORT_NOW:-$(date +%s)}"
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{print $1}'
  else
    shasum -a 256 < "$1" | awk '{print $1}'
  fi
}

require_on() {
  [ -e "$CONFIG/backport" ] \
    || refuse "Backport is off in this home; a file at config/backport switches it on (docs/backport.md)"
}

card_path() {  # <slug>
  case "$1" in
    ''|*[!a-z0-9-]*|-*) printf 'fm-backport: a slug is lower-case letters, digits and dashes, not "%s"\n' "$1" >&2; exit 2 ;;
  esac
  printf '%s/cards/%s.md\n' "$DIR" "$1"
}

ensure_dir() {
  mkdir -p "$DIR/cards" "$DIR/notes" || refuse "cannot create $DIR"
  chmod 700 "$DIR" 2>/dev/null || true
  [ -e "$LEDGER" ] || : > "$LEDGER"
}

record() {  # <slug> <event> <hash> [detail]
  local detail=${4:-}
  detail=$(printf '%s' "$detail" | tr '\t\n' '  ')
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$3" "$detail" >> "$LEDGER"
}

# events <slug>: the card's ledger lines, oldest first.
events() {
  [ -f "$LEDGER" ] || return 0
  awk -F '\t' -v s="$1" '$2 == s' "$LEDGER"
}

# has_event <slug> <event> <hash>: the event was recorded for this text.
has_event() {
  events "$1" | awk -F '\t' -v e="$2" -v h="$3" '$3 == e && $4 == h { found = 1 } END { exit !found }'
}

# last_of <slug> <event...>: the newest line whose event is one of these.
last_of() {
  local slug=$1
  shift
  events "$slug" | awk -F '\t' -v list=" $* " 'index(list, " " $3 " ") { line = $0 } END { if (line != "") print line }'
}

# reader_verdict <slug> <hash>: the newest reader event for this text.
reader_verdict() {
  events "$1" | awk -F '\t' -v h="$2" '($3 == "reader-pass" || $3 == "reader-fail") && $4 == h { r = $3 } END { print r }'
}

# public_repo: owner/repo of this checkout's origin on GitHub, or empty.
public_repo() {
  git -C "$FM_ROOT" remote get-url origin 2>/dev/null \
    | sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p' \
    | sed 's/\.git$//'
}

# shape_problems <card>: one line per break of the fixed shape.
shape_problems() {
  LC_ALL=C awk '
    BEGIN {
      split("Kind:|Fits:|Needs:|Lands in:", top, "|")
      split("The problem|The general rule|How it works|Evidence it worked|Left out on purpose|Done when", want, "|")
      ntop = 4; nwant = 6; ti = 0; si = 0; fence = 0
    }
    function blank(s) { return s ~ /^[ \t]*$/ }
    {
      line = $0
      if (NR == 1) {
        if (line !~ /^# [^ \t]/) print "line 1: the card must open with \"# <what it does, in one plain line>\""
        next
      }
      if (line ~ /^[ \t]*(```|~~~)/) fence = !fence
      if (!fence && line ~ /^#/) {
        if (line !~ /^## /) { print "line " NR ": only the six fixed \"## \" sections may be headings"; next }
        if (ti < ntop) { print "line " NR ": the Kind, Fits, Needs and Lands in lines must come before the first section"; ti = ntop }
        name = substr(line, 4); sub(/[ \t]+$/, "", name)
        if (si >= nwant || name != want[si + 1]) {
          expect = (si < nwant) ? "\"## " want[si + 1] "\"" : "no further section"
          print "line " NR ": found \"" line "\" where the card needs " expect
          bad = 1; next
        }
        if (si > 0 && !filled) print "section \"## " want[si] "\" is empty"
        si++; filled = 0
        next
      }
      if (si == 0) {
        if (blank(line)) next
        if (ti < ntop && index(line, top[ti + 1] " ") == 1 && length(line) > length(top[ti + 1]) + 1) {
          if (ti == 0) {
            kind = substr(line, 7)
            if (kind !~ /^(fix|rule|practice|capability)([ \t]+\([^()]*\))?[ \t]*$/)
              print "line " NR ": Kind must be fix, rule, practice or capability, with at most one short note in brackets"
          }
          ti++; next
        }
        if (ti < ntop) print "line " NR ": expected \"" top[ti + 1] " ...\" here"
        else print "line " NR ": text outside the fixed sections"
        next
      }
      if (!blank(line)) filled = 1
    }
    END {
      if (ti < ntop) print "the card is missing the line \"" top[ti + 1] " ...\""
      if (si > 0 && !filled) print "section \"## " want[si] "\" is empty"
      if (!bad && si < nwant) print "the card is missing the section \"## " want[si + 1] "\""
    }
  ' "$1"
}

# text_problems <card> <repo>: dates, links and quoted speech, one per line.
text_problems() {
  LC_ALL=C awk -v repo="$2" '
    BEGIN {
      fence = 0; section = ""
      # Month names match capitalised only, so the verb "march" passes; the
      # list is written in lower case and capitalised here.
      n = split("january february march april june july august september october november december jan feb mar apr jun jul aug sept sep oct nov dec", names, " ")
      month = ""
      for (i = 1; i <= n; i++) month = month (i > 1 ? "|" : "") toupper(substr(names[i], 1, 1)) substr(names[i], 2)
      month = "(" month ")"
      allowed = (repo == "") ? "" : "https://github.com/" repo
    }
    function report(what) { print "line " NR ": " what }
    function quoted(s, re, mark,   m, i, inner, n, w) {
      while (match(s, re)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        i = index(m, mark); inner = substr(m, i + 1, length(m) - i - 1)
        gsub(/^[ \t]+|[ \t]+$/, "", inner)
        n = split(inner, w, /[ \t]+/)
        if (inner != "" && n >= 3) return 1
      }
      return 0
    }
    {
      line = $0
      if (!fence && line ~ /^## /) { section = substr(line, 4) }
      if (line ~ /^[ \t]*(```|~~~)/) { fence = !fence; next }
      low = tolower(line)
      if (line ~ /(^|[^0-9])(19|20)[0-9][0-9]([^0-9]|$)/) report("a year; leave dates out")
      if (line ~ /(^|[^0-9\/])[0-9][0-9]?\/[0-9][0-9]?(\/[0-9][0-9]([0-9][0-9])?)?([^0-9\/]|$)/) report("looks like a date; write counts as N of M")
      if (line ~ ("(^|[^A-Za-z])" month "([^A-Za-z]|$)") || line ~ /(^|[^A-Za-z])May[ \t,]+[0-9]/ || line ~ /[0-9][ \t]+May([^A-Za-z]|$)/) report("a month name; leave dates out")
      if (line ~ /(^|[^0-9:])[0-2]?[0-9]:[0-5][0-9]([^0-9]|$)/ || low ~ /(^|[^0-9:])[0-9][0-9]?[ \t]*[ap]\.?m([^a-z]|$)/) report("a clock time; leave times out")
      if (low ~ /(^|[^a-z])(yesterday|tomorrow|today|tonight|ago)([^a-z]|$)/ ||
          low ~ /(^|[^a-z])(last|next|this|this past)[ \t]+(week|month|year|night|morning|afternoon|evening|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday)([^a-z]|$)/)
        report("a relative date; say once, or how many times, instead")
      rest = line
      while (match(rest, /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^ \t)>\]"`]*/)) {
        url = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        if (allowed == "" || !(url == allowed || index(url, allowed "/") == 1 || index(url, allowed "#") == 1))
          report("a link outside this repository; leave it out")
      }
      if (low ~ /(^|[^a-z0-9.\/])www\.[a-z0-9-]+\./) report("a web address; leave it out")
      if (line ~ /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]+/) report("an email address; leave it out")
      if (section == "How it works" && fence) next
      if (line ~ /^[ \t]*>/) report("a block quote; never quote anyone")
      if (section != "How it works") {
        q = line
        gsub(/\342\200\234|\342\200\235/, "\"", q)
        gsub(/\342\200\230|\342\200\231/, "\047", q)
        if (quoted(q, "\"[^\"]*\"", "\"") || quoted(q, "(^|[^A-Za-z0-9])\047([^\047]|[A-Za-z0-9]\047[A-Za-z0-9])*\047", "\047"))
          report("quoted words; never quote anyone (a rule card puts its exact wording under \"## How it works\")")
      }
    }
  ' "$1"
}

# guard_ready: the home keeps a word list or an approvals file, so the leak
# guard's new-name check is on.
guard_ready() {
  local list rc=0
  [ -f "$CONFIG/leak-names-approved" ] && return 0
  # shellcheck source=bin/fm-leak-lib.sh disable=SC1091
  . "$FM_ROOT/bin/fm-leak-lib.sh"
  list=$(mktemp "${TMPDIR:-/tmp}/fm-backport-words.XXXXXX") || return 1
  fm_leak_words_write "$FM_HOME" "$CONFIG" "$list" 2>/dev/null || rc=$?
  if { [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; } && [ -s "$list" ]; then rc=0; else rc=1; fi
  rm -f "$list"
  return "$rc"
}

# run_check <slug> <card>: 0 when the card passes every rule, 1 otherwise,
# with each problem on stderr.
run_check() {
  local slug=$1 card=$2 problems words guard_out guard_rc=0
  [ -f "$card" ] || refuse "no card at data/backport/cards/$slug.md"
  problems=$(shape_problems "$card"; text_problems "$card" "$(public_repo)")
  words=$(wc -w < "$card" | tr -d ' ')
  if [ "$words" -gt "$WORD_CAP" ]; then
    problems=$(printf '%s\n%s' "$problems" "the card holds $words words; at most $WORD_CAP")
  fi
  if ! guard_ready; then
    problems=$(printf '%s\n%s' "$problems" "this home keeps no private word list and no config/leak-names-approved, so new names cannot be checked; create config/leak-names-approved (it may be empty)")
  else
    guard_out=$( cd "$FM_ROOT" && FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-leak-guard.sh" --text --new-names "$card" 2>&1 ) || guard_rc=$?
    case "$guard_rc" in
      0) ;;
      1) problems=$(printf '%s\n%s' "$problems" "$(printf '%s\n' "$guard_out" | grep '^LEAK_HIT' | awk -v c="$card" -v n="cards/$slug.md" '{ i = index($0, c); if (i) $0 = substr($0, 1, i - 1) n substr($0, i + length(c)); print "leak guard: " $0 }')")
         printf '%s\n' "$guard_out" | grep -q '^LEAK_HIT' \
           || problems=$(printf '%s\n%s' "$problems" "leak guard: refused the card")
         ;;
      *) problems=$(printf '%s\n%s' "$problems" "leak guard could not run: $(printf '%s\n' "$guard_out" | tail -1)") ;;
    esac
  fi
  problems=$(printf '%s\n' "$problems" | sed '/^[[:space:]]*$/d')
  if [ -n "$problems" ]; then
    printf 'fm-backport: card %s refused:\n' "$slug" >&2
    printf '%s\n' "$problems" | sed 's/^/  /' >&2
    return 1
  fi
  return 0
}

cmd_check() {
  [ "$#" -eq 1 ] || usage
  local slug=$1 card hash
  card=$(card_path "$slug") || exit 2
  ensure_dir
  run_check "$slug" "$card" || exit 1
  hash=$(sha_of "$card")
  has_event "$slug" checked "$hash" || record "$slug" checked "$hash" "check v1"
  printf 'stamped %s %s\n' "$slug" "$hash"
}

# stamped_hash <slug>: the hash of the card as it is now, when that text is
# stamped; refuses otherwise.
stamped_hash() {
  local slug=$1 card hash
  card=$(card_path "$slug") || exit 2
  [ -f "$card" ] || refuse "no card at data/backport/cards/$slug.md"
  hash=$(sha_of "$card")
  has_event "$slug" checked "$hash" \
    || refuse "card $slug has no stamp for its current text; run check first"
  printf '%s\n' "$hash"
}

cmd_reader() {
  [ "$#" -eq 2 ] || usage
  local hash
  case "$2" in pass|fail) ;; *) usage ;; esac
  ensure_dir
  hash=$(stamped_hash "$1") || exit
  record "$1" "reader-$2" "$hash"
  printf 'recorded reader %s for %s\n' "$2" "$1"
}

cmd_answer() {
  [ "$#" -eq 2 ] || usage
  local hash
  case "$2" in yes|not-now|never) ;; *) usage ;; esac
  ensure_dir
  hash=$(stamped_hash "$1") || exit
  if [ "$2" = yes ]; then
    [ "$(reader_verdict "$1" "$hash")" = reader-pass ] \
      || refuse "card $1 has no fresh reader pass for its current text; a yes needs one first"
  fi
  record "$1" "$2" "$hash"
  printf 'recorded answer %s for %s\n' "$2" "$1"
}

cmd_ready() {
  [ "$#" -eq 1 ] || usage
  local slug=$1 card hash reader answer
  card=$(card_path "$slug") || exit 2
  ensure_dir
  run_check "$slug" "$card" || exit 1
  hash=$(stamped_hash "$slug") || exit
  reader=$(reader_verdict "$slug" "$hash")
  [ "$reader" = reader-pass ] || refuse "card $slug has no fresh reader pass for its current text"
  answer=$(last_of "$slug" yes not-now never)
  [ -n "$answer" ] || refuse "card $slug has no answer from the owner yet"
  [ "$(printf '%s\n' "$answer" | cut -f3)" = yes ] \
    || refuse "card $slug was answered $(printf '%s\n' "$answer" | cut -f3), not yes"
  [ "$(printf '%s\n' "$answer" | cut -f4)" = "$hash" ] \
    || refuse "card $slug changed after the owner's yes; it needs a new check, reader and yes"
  cat "$card"
}

cmd_done() {  # <event> <slug> [detail]
  local event=$1 slug=${2:-} hash answer
  [ -n "$slug" ] && [ "$#" -le 3 ] || usage
  ensure_dir
  hash=$(stamped_hash "$slug") || exit
  answer=$(last_of "$slug" yes not-now never)
  [ "$(printf '%s\n' "$answer" | cut -f3)" = yes ] && [ "$(printf '%s\n' "$answer" | cut -f4)" = "$hash" ] \
    || refuse "card $slug has no yes for its current text; it cannot have been $event"
  [ "$(reader_verdict "$slug" "$hash")" = reader-pass ] \
    || refuse "card $slug has no fresh reader pass for its current text; it cannot have been $event"
  record "$slug" "$event" "$hash" "${3:-}"
  printf 'recorded %s for %s\n' "$event" "$slug"
}

cmd_list() {
  [ "$#" -eq 0 ] || usage
  local card slug hash title state last answer reader at t
  ensure_dir
  t=$(now)
  for card in "$DIR"/cards/*.md; do
    [ -f "$card" ] || continue
    slug=${card##*/}; slug=${slug%.md}
    hash=$(sha_of "$card")
    title=$(sed -n '1s/^# //p' "$card")
    answer=$(last_of "$slug" yes not-now never)
    last=$(last_of "$slug" built sent)
    if [ "$(printf '%s\n' "$answer" | cut -f3)" = never ]; then
      state=never
    elif [ "$(printf '%s\n' "$answer" | cut -f3)" = not-now ] && [ "$(events "$slug" | awk -F '\t' '$3 == "not-now"' | wc -l)" -ge 2 ]; then
      state="set aside"
    elif [ -n "$last" ] && [ "$(printf '%s\n' "$last" | cut -f4)" = "$hash" ]; then
      state=$(printf '%s\n' "$last" | cut -f3)
    elif ! has_event "$slug" checked "$hash"; then
      if [ -n "$(events "$slug")" ]; then state=changed; else state=new; fi
    elif [ "$(printf '%s\n' "$answer" | cut -f3)" = not-now ]; then
      at=$(printf '%s\n' "$answer" | cut -f1)
      if [ $((t - at)) -ge "$NOT_NOW_SECONDS" ]; then state="not now, due again"; else state="not now"; fi
    elif [ "$(printf '%s\n' "$answer" | cut -f3)" = yes ] && [ "$(printf '%s\n' "$answer" | cut -f4)" = "$hash" ] \
      && [ "$(reader_verdict "$slug" "$hash")" = reader-pass ]; then
      state=yes
    else
      reader=$(reader_verdict "$slug" "$hash")
      case "$reader" in
        reader-pass) state="waiting for yes" ;;
        reader-fail) state="reader failed" ;;
        *) state=checked ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "$slug" "$state" "$title"
  done
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  -h|--help|help) usage ;;
esac
require_on
case "$cmd" in
  check) cmd_check "$@" ;;
  reader) cmd_reader "$@" ;;
  answer) cmd_answer "$@" ;;
  ready) cmd_ready "$@" ;;
  sent|built) cmd_done "$cmd" "$@" ;;
  list) cmd_list "$@" ;;
  *) usage ;;
esac
