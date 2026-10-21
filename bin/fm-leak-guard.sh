#!/usr/bin/env bash
# Scan tracked files for captain-private PII and live-token shapes.
#
# CI entry point for the public-repo leak guard.
# Pattern ownership for email and /Users/<name> lives in bin/fm-leak-lib.sh
# (shared with fm-home-port.sh --warn-machine-local).
# Fails when a tracked file (outside the explicit allowlist) contains:
#   - a real email address (placeholder domains are allowed)
#   - a macOS absolute home path (/Users/<name>/...)
#   - a live-token shape matching the portable-home credential scan
#   - a word or phrase from the home's private word list (below)
#
# The credential half reuses the same token regex family as scan_path() in
# bin/fm-home-port.sh so both gates stay aligned.
# tests/ fixtures that intentionally embed synthetic tokens are allowlisted.
# This script, bin/fm-leak-lib.sh, and bin/fm-home-port.sh are allowlisted
# because they embed pattern strings.
#
# PRIVATE WORDS. The patterns above cannot know a person's names, projects or
# plans, so a home may list them in the optional, gitignored config/leak-words:
# one word or phrase per line, blank lines and lines starting with # ignored,
# matched case-insensitively as whole words. That list is checked against
# EVERY scanned file, tests/ and the allowlisted scripts included, because a
# fixture is exactly where a real name slips in. The list is read from
# FM_HOME's config/ when FM_HOME is set, else from the config/ of the primary
# checkout this checkout is a worktree of (so a task worktree finds its home's
# list), else from ~/starship/config/, the default home, which is how a
# no-mistakes validation copy - a worktree of the gate's own bare mirror that
# belongs to no home - still finds it. No list means no word check; CI has
# none. A hit prints the offending line locally, so the words never leave this
# machine. bin/fm-lint.sh runs --private-words on every default lint, which is
# how the list is checked before each push.
#
#
# DRAFT TEXT. --text checks text that is about to be published rather than
# tracked files: a PR title, description or comment, or a no-mistakes intent.
# It reads each named file, or stdin when none is named or the name is -,
# checks only the private word list, and prints one
# `LEAK_HIT: private-word: <source>: <word>` line per distinct listed word the
# text contains (the source is the file as named, or stdin), so the writer
# knows exactly what to take out. bin/fm-pr-text-guard.py runs it on what a
# spawned Claude worker is about to publish, and the ship brief tells every
# worker to run it on draft PR text first.
#
# Usage:
#   fm-leak-guard.sh                  scan the whole tracked tree (what CI runs)
#   fm-leak-guard.sh <path>...        scan only the given paths (developer convenience)
#   fm-leak-guard.sh --private-words [<path>...]
#                                     check only the private word list, and
#                                     exit 0 silently when this home has none
#   fm-leak-guard.sh --text [<file>|-]...
#                                     check draft text against the private word
#                                     list: exit 1 naming each listed word found,
#                                     0 when clean, and 0 silently when this home
#                                     has no list
set -eu

WORDS_ONLY=0
TEXT_MODE=0
case "${1:-}" in
  --private-words) WORDS_ONLY=1; shift ;;
  --text) WORDS_ONLY=1; TEXT_MODE=1; shift ;;
esac
CALLER_PWD=$PWD

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=bin/fm-leak-lib.sh disable=SC1091
. "$ROOT/bin/fm-leak-lib.sh"

# Credential half - same live-token shapes as scan_path() in bin/fm-home-port.sh.
# Assignment forms (FMX_PAIRING_TOKEN= / CMUX_SOCKET_PASSWORD=) require a
# non-empty literal value here so documenting the env var name, or passing
# "$pw", does not fail CI. Portable-home export still uses the stricter
# name-only match because any presence in a bundle is refuse-worthy.
# shellcheck disable=SC2016
TOKEN_PATTERN='(FMX_PAIRING_TOKEN[[:space:]]*=[[:space:]]*['\''\"]?[A-Za-z0-9._-]{8,}|(^|[^A-Za-z0-9_])(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|api[_-]?key[[:space:]]*[=:][[:space:]]*['\''\"]?[A-Za-z0-9_-]{20,}|CMUX_SOCKET_PASSWORD[[:space:]]*=[[:space:]]*['\''\"]?[A-Za-z0-9._-]{8,})'

leak_words_file() {
  local common
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s\n' "$FM_HOME/config/leak-words"
  elif common=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && [ "${common##*/}" = .git ]; then
    printf '%s\n' "${common%/.git}/config/leak-words"
  else
    printf '%s\n' "${HOME:-}/starship/config/leak-words"
  fi
}

# The cleaned word list (one fixed string per line), or empty when there is none.
WORDS_LIST=
words_source=$(leak_words_file)
if [ -f "$words_source" ]; then
  WORDS_LIST=$(mktemp "${TMPDIR:-/tmp}/fm-leak-words.XXXXXX")
  trap 'rm -f "$WORDS_LIST"' EXIT
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$words_source" > "$WORDS_LIST"
  [ -s "$WORDS_LIST" ] || { rm -f "$WORDS_LIST"; WORDS_LIST=; }
fi
if [ "$WORDS_ONLY" -eq 1 ] && [ -z "$WORDS_LIST" ]; then
  exit 0
fi

# --text: every distinct listed word in each source, named once.
if [ "$TEXT_MODE" -eq 1 ]; then
  [ "$#" -gt 0 ] || set -- -
  found=
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
    while IFS= read -r word; do
      [ -n "$word" ] || continue
      printf 'LEAK_HIT: private-word: %s: %s\n' "$label" "$word" >&2
      found="${found:+$found, }$word"
    done < <(grep -Fiwo -f "$WORDS_LIST" "$text" 2>/dev/null | awk '!seen[tolower($0)]++')
  done
  if [ -n "$found" ]; then
    printf 'fm-leak-guard.sh: FAIL - the text contains words from the private list %s: %s; rewrite it without them\n' "$words_source" "$found" >&2
    exit 1
  fi
  printf 'fm-leak-guard.sh: PASS - no words from the private list in the text\n'
  exit 0
fi

# Paths relative to repo root that may contain synthetic fixtures or the
# pattern definitions themselves.
is_allowlisted() {
  local rel=$1
  case "$rel" in
    tests/*|tests) return 0 ;;
    bin/fm-home-port.sh|./bin/fm-home-port.sh) return 0 ;;
    bin/fm-leak-guard.sh|./bin/fm-leak-guard.sh) return 0 ;;
    bin/fm-leak-lib.sh|./bin/fm-leak-lib.sh) return 0 ;;
  esac
  return 1
}

hits=0

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

  # Private words: every file, allowlisted ones included.
  if [ -n "$WORDS_LIST" ]; then
    while IFS= read -r line; do
      report_hit private-word "$rel" "$line"
    done < <(grep -FIinw -f "$WORDS_LIST" "$file" 2>/dev/null | head -5)
  fi

  if [ "$WORDS_ONLY" -eq 1 ] || is_allowlisted "$rel"; then
    return 0
  fi

  # Token shapes
  if grep -EIq "$TOKEN_PATTERN" "$file" 2>/dev/null; then
    while IFS= read -r line; do
      report_hit token "$rel" "$line"
    done < <(grep -En "$TOKEN_PATTERN" "$file" 2>/dev/null | head -5)
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
}

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

if [ "$WORDS_ONLY" -eq 1 ]; then
  if [ "$hits" -ne 0 ]; then
    printf 'fm-leak-guard.sh: FAIL - tracked files contain words from the private list %s (see LEAK_HIT lines above)\n' "$words_source" >&2
    exit 1
  fi
  printf 'fm-leak-guard.sh: PASS - no words from the private list in scanned tracked files\n'
  exit 0
fi

if [ "$hits" -ne 0 ]; then
  printf 'fm-leak-guard.sh: FAIL - tracked files contain email, /Users/<name>, live-token shapes, or private words (see LEAK_HIT lines above)\n' >&2
  exit 1
fi

if [ -n "$WORDS_LIST" ]; then
  printf 'fm-leak-guard.sh: PASS - no email, /Users/<name>, live-token shapes, or private words in scanned tracked files\n'
  exit 0
fi
printf 'fm-leak-guard.sh: PASS - no email, /Users/<name>, or live-token shapes in scanned tracked files\n'
exit 0
