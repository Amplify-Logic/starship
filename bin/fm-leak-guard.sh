#!/usr/bin/env bash
# Scan tracked files for captain-private PII and live-token shapes.
#
# CI entry point for the public-repo leak guard.
# Pattern ownership for email and /Users/<name> lives in bin/fm-leak-lib.sh
# (shared with fm-home-port.sh --warn-machine-local).
# Fails when a tracked file (outside the explicit allowlist) contains:
#   - a real email address (placeholder domains are allowed)
#   - a macOS absolute home path (/Users/<name>/...)
#   - a live key or token shape (bin/fm_secret_shapes.py owns the provider
#     prefixes, shared with the command guard's redaction; bin/fm-leak-shapes.py
#     adds API key assignments in any case and reports each)
#   - a customer data shape, such as a Slack id or a phone number (NEW NAMES
#     AND DATA SHAPES below)
#   - a word or phrase from the home's private word list (below)
#
# tests/ fixtures that intentionally embed synthetic tokens are allowlisted.
# This script, bin/fm-leak-lib.sh, and bin/fm-home-port.sh are allowlisted
# because they embed pattern strings.
#
# PRIVATE WORDS. The patterns above cannot know a person's names, projects or
# plans, so a home may list them in the optional, gitignored config/leak-words:
# one word or phrase per line, blank lines and lines starting with # ignored,
# matched case-insensitively as whole words. That list is checked against
# EVERY scanned file, tests/ and the allowlisted scripts included, because a
# fixture is exactly where a real name slips in. The home is FM_HOME when it is
# set, else the primary checkout this checkout is a worktree of (so a task
# worktree finds its home's list), else ~/starship, the default home, which is
# how a no-mistakes validation copy - a worktree of the gate's own bare mirror
# that belongs to no home - still finds it. The list a secondmate home inherits
# from its primary, config/leak-words.inherited, and a file named leak-words at
# the root of the home's private add-on (bin/fm-addon.sh), both in the same
# format, add their words to the home's own; fm_leak_words_write in
# bin/fm-leak-lib.sh owns that merge. No list means no word check; CI has none.
# bin/fm-lint.sh runs --private-words on every default lint, which is how the
# list is checked before each push.
#
# WHERE, NEVER WHAT. A private word or a token is reported only by where it
# sits, `LEAK_HIT: private-word: <where>:<line>:<column>` or `LEAK_HIT: token:
# <where>:<line>:<column>`, and a failure counts them; neither the word, the
# token nor its line is ever printed, so checking a file that holds the word
# list itself does not put the list on the screen. Other hits print the
# offending line or value locally.
#
#
# DRAFT TEXT. --text checks text that is about to be published rather than
# tracked files: a PR title, description or comment, or a no-mistakes intent.
# It reads each named file, or stdin when none is named or the name is -,
# checks the private word list and the token shapes (with --new-names, also the
# new-name and shape checks below), and prints one
# `LEAK_HIT: private-word: <source>:<line>:<column>` or `LEAK_HIT: token:
# <source>:<line>:<column>` line per occurrence (the source is the file as
# named, or stdin), so the writer knows exactly where to take one out.
# Without a list or approvals file only the token shapes are checked, and a
# clean text then passes silently. bin/fm-pr-text-guard.py runs it on what a
# Claude session is about to publish, and the ship brief tells every worker
# to run it on draft PR text first.
#
# NEW NAMES AND DATA SHAPES. A list cannot keep up with the names a home works
# with, so a home that keeps one (or an approvals file, below) also refuses any
# name-shaped word that has never appeared in this repository before, until the
# owner approves it once. --new-names checks the lines this checkout adds since
# its merge base with origin/main, committed and uncommitted changes to tracked
# files, tests/ included, and the messages of the commits origin/main..HEAD,
# each hit there named as `commit <short-sha>`. A word that occurs
# anywhere in the tracked files at the merge base is never new, so once a change
# lands its words stop being new. bin/fm-leak-shapes.py owns what counts as
# name-shaped and as an occurrence. The approvals file is the home's optional,
# gitignored config/leak-names-approved, one word per line in the word list's
# format; firstmate appends a word there once the owner approves it, and the
# guard never prints the file. The same added lines, and every scanned file in
# the default scan, are checked for the shapes customer data takes: Slack ids
# and workspace links, HubSpot record and portal links, phone numbers in
# international form or as a Dutch mobile number (06 and 8 digits) and IBANs,
# which bin/fm-leak-shapes.py also owns, with the same allowlist as the other
# patterns; commit messages have no allowlist. bin/fm-lint.sh runs --new-names on every
# default lint, so the pipeline's lint step checks each push; without a list or
# approvals file, as in CI, it is silent. Each hit prints
# `LEAK_HIT: new-name: <path>:<line>: <word>` or `LEAK_HIT: <shape>: ...`. A
# word or phrase from the private word list in those added lines or commit
# messages is placed as `LEAK_HIT: private-word: <where>:<line>:<column>` and
# never printed, and no word inside it is named as new.
# Without origin/main, or without a merge base with it, --new-names exits 2.
# --text --new-names adds the same two checks to a draft text, with the tracked
# files at this checkout's HEAD as what is already known, and, when the caller's
# working directory is in a checkout that shares a remote's owner/repo with this
# one and has a commit, the tracked files at that checkout's HEAD too, so the words of the branch
# being published count as known; bin/fm-pr-text-guard.py uses it for text
# bound for this repository and runs it from the publishing command's directory.
#
# Usage:
#   fm-leak-guard.sh                  scan the whole tracked tree (what CI runs)
#   fm-leak-guard.sh <path>...        scan only the given paths (developer convenience)
#   fm-leak-guard.sh --private-words [<path>...]
#                                     check only the private word list, and
#                                     exit 0 silently when this home has none
#   fm-leak-guard.sh --text [--new-names] [<file>|-]...
#                                     check draft text against the private word
#                                     list and the token shapes, and with
#                                     --new-names for new names and data shapes
#                                     too: exit 1 placing each hit, 0 when
#                                     clean, silently when this home has no
#                                     list or approvals file, and 2 when the
#                                     check cannot run
#   fm-leak-guard.sh --new-names
#                                     check the lines and commit messages this
#                                     checkout adds for new names and data
#                                     shapes: exit 1 naming each hit, 2 when no
#                                     merge base with origin/main is found, and
#                                     0 silently without a list or approvals file
set -eu

WORDS_ONLY=0
TEXT_MODE=0
NAMES_MODE=0
case "${1:-}" in
  --private-words) WORDS_ONLY=1; shift ;;
  --text)
    WORDS_ONLY=1; TEXT_MODE=1; shift
    if [ "${1:-}" = --new-names ]; then NAMES_MODE=1; shift; fi
    ;;
  --new-names)
    WORDS_ONLY=1; NAMES_MODE=1; shift
    if [ "$#" -gt 0 ]; then
      printf 'usage: fm-leak-guard.sh --new-names (see the header)\n' >&2
      exit 2
    fi
    ;;
esac
CALLER_PWD=$PWD

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=bin/fm-leak-lib.sh disable=SC1091
. "$ROOT/bin/fm-leak-lib.sh"

leak_words_home() {
  local common
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s\n' "$FM_HOME"
  elif common=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && [ "${common##*/}" = .git ]; then
    printf '%s\n' "${common%/.git}"
  else
    printf '%s\n' "${HOME:-}/starship"
  fi
}

# The cleaned word list (one fixed string per line), or empty when there is none.
words_home=$(leak_words_home)
WORDS_LIST=$(mktemp "${TMPDIR:-/tmp}/fm-leak-words.XXXXXX")
trap 'rm -f "$WORDS_LIST"' EXIT
fm_leak_words_write "$words_home" "$words_home/config" "$WORDS_LIST" || [ "$?" -eq 2 ]
[ -s "$WORDS_LIST" ] || { rm -f "$WORDS_LIST"; WORDS_LIST=; }
APPROVED="$words_home/config/leak-names-approved"
# The new-name and shape checks run where the home keeps a list or approvals.
NAMES_ON=0
if [ "$NAMES_MODE" -eq 1 ] && { [ -n "$WORDS_LIST" ] || [ -f "$APPROVED" ]; }; then
  NAMES_ON=1
fi
if [ "$WORDS_ONLY" -eq 1 ] && [ "$TEXT_MODE" -eq 0 ] && [ -z "$WORDS_LIST" ] && [ "$NAMES_ON" -eq 0 ]; then
  exit 0
fi

# word_hits <file> <where>: `<where>:<line>:<column>` for each listed word in
# the file, the column counted in bytes; never the word itself.
word_hits() {
  grep -FIiwnob -f "$WORDS_LIST" "$1" 2>/dev/null \
    | LC_ALL=C awk -v where="$2" '
        NR == FNR { start[FNR] = pos; pos += length($0) + 1; next }
        { split($0, f, ":"); print where ":" f[1] ":" (f[2] - start[f[1]] + 1) }' "$1" -
}

# plural <count> <noun>: "1 word", "2 words".
plural() {
  if [ "$1" -eq 1 ]; then printf '1 %s' "$2"; else printf '%s %ss' "$1" "$2"; fi
}

# Paths, relative to the repo root, that may hold synthetic fixtures or the
# pattern definitions themselves; the private word and new-name checks still
# read them.
ALLOWLIST=(tests 'tests/*' bin/fm-home-port.sh bin/fm-leak-guard.sh bin/fm-leak-lib.sh)
SHAPES="$ROOT/bin/fm-leak-shapes.py"

# --new-names: the lines and commit messages this checkout adds since its
# merge base with origin/main.
if [ "$NAMES_MODE" -eq 1 ] && [ "$TEXT_MODE" -eq 0 ]; then
  if ! BASE=$(git merge-base origin/main HEAD 2>/dev/null) || [ -z "$BASE" ]; then
    printf 'fm-leak-guard.sh: FAIL - no merge base with origin/main to find the new lines against; fetch origin and try again\n' >&2
    exit 2
  fi
  exempt=()
  for glob in "${ALLOWLIST[@]}"; do exempt+=(--exempt "$glob"); done
  status=0
  out=$(python3 "$SHAPES" "${exempt[@]}" --names "$ROOT" "$BASE" --approved "$APPROVED" \
    ${WORDS_LIST:+--private "$WORDS_LIST"} --diff "$BASE") || status=$?
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  case "$status" in
    0)
      printf 'fm-leak-guard.sh: PASS - no new names, private words, customer data shapes or token shapes in the lines and commit messages this branch adds\n'
      exit 0
      ;;
    1)
      printf 'fm-leak-guard.sh: FAIL - the lines or commit messages this branch adds hold words that never appeared in this repository, words from the private word list, customer data shapes or token shapes (see LEAK_HIT lines above); rewrite each out, or have the owner approve a new word once, which firstmate records as a line of %s\n' "$APPROVED" >&2
      exit 1
      ;;
    *) exit 2 ;;
  esac
fi

# remote_repos <checkout>: the owner/repo, lowercased, of each of its remotes.
remote_repos() {
  git -C "$1" config --get-regexp '^remote\..*\.url$' 2>/dev/null \
    | awk '{print tolower($2)}' \
    | sed -E 's#/+$##; s#\.git$##; s#.*[:/]([^:/]+/[^:/]+)$#\1#' \
    | sort -u
}

# --text: where each listed word and token sits in each source.
if [ "$TEXT_MODE" -eq 1 ]; then
  [ "$#" -gt 0 ] || set -- -
  words=0
  labelled=()
  for source in "$@"; do
    if [ "$source" = - ]; then
      label=stdin
      if [ -z "${stdin_copy:-}" ]; then
        stdin_copy=$(mktemp "${TMPDIR:-/tmp}/fm-leak-text.XXXXXX")
        trap 'rm -f "$WORDS_LIST" "$stdin_copy"' EXIT
        cat > "$stdin_copy"
      fi
      text=$stdin_copy
    else
      label=$source
      case "$source" in
        /*) text=$source ;;
        *) text="$CALLER_PWD/$source" ;;
      esac
      if [ ! -f "$text" ] || [ ! -r "$text" ]; then
        printf 'fm-leak-guard.sh: cannot read %s\n' "$source" >&2
        exit 2
      fi
    fi
    while IFS= read -r where; do
      [ -n "$where" ] || continue
      printf 'LEAK_HIT: private-word: %s\n' "$where" >&2
      words=$((words + 1))
    done < <([ -z "$WORDS_LIST" ] || word_hits "$text" "$label")
    labelled+=("$label" "$text")
  done
  # Token shapes always; with the new-name check on, the same pass also finds
  # new names and data shapes.
  shape_args=(--tokens-only)
  if [ "$NAMES_ON" -eq 1 ]; then
    shape_args=(--names "$ROOT" HEAD)
    caller=$(git -C "$CALLER_PWD" rev-parse --show-toplevel 2>/dev/null) || caller=
    if [ -n "$caller" ] && [ "$caller" != "$ROOT" ] \
      && git -C "$caller" rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1 \
      && [ -n "$(comm -12 <(remote_repos "$ROOT") <(remote_repos "$caller"))" ]; then
      shape_args+=(--names "$caller" HEAD)
    fi
    shape_args+=(--approved "$APPROVED" ${WORDS_LIST:+--private "$WORDS_LIST"})
  fi
  status=0
  out=$(python3 "$SHAPES" "${shape_args[@]}" --text "${labelled[@]}") || status=$?
  # A crash also exits 1, so a hit status must come with a hit.
  if [ "$status" -gt 1 ] || { [ "$status" -eq 1 ] && [[ "$out" != *LEAK_HIT:* ]]; }; then
    printf 'fm-leak-guard.sh: FAIL - the token and data shape check could not run\n' >&2
    exit 2
  fi
  tokens=0
  fresh=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" >&2
    case "$line" in
      'LEAK_HIT: token: '*) tokens=$((tokens + 1)) ;;
      *) fresh="${fresh:+$fresh, }${line##*: }" ;;
    esac
  done < <(printf '%s\n' "$out" | awk 'NF && !seen[$0]++')
  if [ "$words" -gt 0 ] || [ "$tokens" -gt 0 ] || [ -n "$fresh" ]; then
    [ "$words" -eq 0 ] || printf 'fm-leak-guard.sh: FAIL - the text contains %s from the private word list of the home %s, where the LEAK_HIT lines above say; rewrite it without them\n' "$(plural "$words" word)" "$words_home" >&2
    [ "$tokens" -eq 0 ] || printf 'fm-leak-guard.sh: FAIL - the text holds %s, where the LEAK_HIT lines above say; take each out\n' "$(plural "$tokens" "token shape")" >&2
    [ -z "$fresh" ] || printf 'fm-leak-guard.sh: FAIL - the text holds words that never appeared in this repository, or customer data shapes: %s; rewrite each out, or have the owner approve a new word once, which firstmate records as a line of %s\n' "$fresh" "$APPROVED" >&2
    exit 1
  fi
  # A home with no list or approvals file checked token shapes alone, and
  # stays silent when the text is clean.
  [ -n "$WORDS_LIST" ] || [ "$NAMES_ON" -eq 1 ] || exit 0
  printf 'fm-leak-guard.sh: PASS - no words from the private list or token shapes in the text\n'
  exit 0
fi

is_allowlisted() {
  local rel=${1#./} glob
  for glob in "${ALLOWLIST[@]}"; do
    # shellcheck disable=SC2254 # each entry is a pattern
    case "$rel" in $glob) return 0 ;; esac
  done
  return 1
}

hits=0
words=0

report_hit() {
  local kind=$1 file=$2 detail=$3
  printf 'LEAK_HIT: %s: %s: %s\n' "$kind" "$file" "$detail" >&2
  hits=1
}

scan_file() {
  local file=$1
  local rel=${file#"$ROOT/"}
  rel=${rel#./}

  # Skip empty or binary files (grep -I skips binary).
  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    return 0
  fi

  # Private words: every file, allowlisted ones included, placed but never
  # printed.
  if [ -n "$WORDS_LIST" ]; then
    while IFS= read -r where; do
      printf 'LEAK_HIT: private-word: %s\n' "$where" >&2
      hits=1
      words=$((words + 1))
    done < <(word_hits "$file" "$rel" | head -5)
  fi

  if [ "$WORDS_ONLY" -eq 1 ] || is_allowlisted "$rel"; then
    return 0
  fi

  # Absolute macOS home paths (shared pattern owner: fm-leak-lib.sh)
  if grep -EIq "$FM_LEAK_USERS_PATH_PATTERN" "$file" 2>/dev/null; then
    while IFS= read -r line; do
      report_hit users-path "$rel" "$line"
    done < <(grep -En "$FM_LEAK_USERS_PATH_PATTERN" "$file" 2>/dev/null | head -5)
  fi

  # Email addresses (filter placeholders and git@ SSH URLs)
  if grep -EIq "$FM_LEAK_EMAIL_PATTERN" "$file" 2>/dev/null; then
    while IFS= read -r line; do
      local emails
      emails=$(printf '%s\n' "$line" | grep -Eo "$FM_LEAK_EMAIL_PATTERN" || true)
      local email
      while IFS= read -r email; do
        [ -n "$email" ] || continue
        if ! fm_leak_is_allowed_email "$email"; then
          report_hit email "$rel" "$line"
          break
        fi
      done <<< "$emails"
    done < <(grep -En "$FM_LEAK_EMAIL_PATTERN" "$file" 2>/dev/null | head -20)
  fi

  SHAPE_FILES+=("$rel")
}

SHAPE_FILES=()

if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    if [ -d "$path" ]; then
      while IFS= read -r -d '' f; do
        scan_file "$f"
      done < <(find "$path" -type f -print0)
    else
      scan_file "$path"
    fi
  done
else
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    scan_file "$ROOT/$f"
  done < <(git -C "$ROOT" ls-files)
fi

# Token and customer data shapes, in one pass over the files scan_file kept.
if [ "$WORDS_ONLY" -eq 0 ] && [ "${#SHAPE_FILES[@]}" -gt 0 ]; then
  status=0
  out=$(python3 "$SHAPES" --files "${SHAPE_FILES[@]}") || status=$?
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" >&2
    hits=1
  done <<< "$out"
  # A crash also exits 1, so a hit status must come with a hit.
  if [ "$status" -gt 1 ] || { [ "$status" -eq 1 ] && [[ "$out" != *LEAK_HIT:* ]]; }; then
    printf 'fm-leak-guard.sh: FAIL - the token and customer data shape check could not run\n' >&2
    exit 2
  fi
fi

if [ "$WORDS_ONLY" -eq 1 ]; then
  if [ "$hits" -ne 0 ]; then
    printf 'fm-leak-guard.sh: FAIL - tracked files contain %s from the private word list of the home %s, where the LEAK_HIT lines above say (at most 5 a file)\n' "$(plural "$words" word)" "$words_home" >&2
    exit 1
  fi
  printf 'fm-leak-guard.sh: PASS - no words from the private list in scanned tracked files\n'
  exit 0
fi

if [ "$hits" -ne 0 ]; then
  printf 'fm-leak-guard.sh: FAIL - tracked files contain email, /Users/<name>, live-token shapes, customer data shapes, or private words (see LEAK_HIT lines above)\n' >&2
  exit 1
fi

if [ -n "$WORDS_LIST" ]; then
  printf 'fm-leak-guard.sh: PASS - no email, /Users/<name>, live-token shapes, or private words in scanned tracked files\n'
  exit 0
fi
printf 'fm-leak-guard.sh: PASS - no email, /Users/<name>, or live-token shapes in scanned tracked files\n'
exit 0
