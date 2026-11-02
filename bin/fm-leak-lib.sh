#!/usr/bin/env bash
# Single owner of email and /Users/<name> regex patterns for public-repo and
# portable-home machine-local scans, and of what a home's private word list is
# (fm_leak_words_write below).
#
# Sourced by:
#   bin/fm-leak-guard.sh          CI hard-fail public-repo leak guard
#   bin/fm-home-port.sh           --warn-machine-local advisory pass on scan
#   bin/fm-config-inherit-lib.sh  the word list a secondmate home inherits
#
# Do not duplicate EMAIL or /Users/<name> patterns elsewhere.
# Live-token shapes stay with each caller's credential scan (portable export
# uses a stricter name-only match than CI).

if [ -n "${FM_LEAK_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_LEAK_LIB_SOURCED=1
FM_LEAK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Real email addresses (placeholder domains filtered by fm_leak_is_allowed_email).
FM_LEAK_EMAIL_PATTERN='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

# Absolute macOS home paths: /Users/<name>/...
FM_LEAK_USERS_PATH_PATTERN='/Users/[A-Za-z_][A-Za-z0-9_-]*/'

# Placeholder / non-personal email shapes that docs and fixtures may use.
fm_leak_is_allowed_email() {
  local email=$1
  case "$email" in
    git@github.com) return 0 ;;
    *@example.com|*@example.org|*@example.net|*@example.invalid|*@example.test) return 0 ;;
    *@localhost|*@local.test) return 0 ;;
    # Vendor bot identities, not people: bin/fm-git-strip-ai-trailers.sh names
    # them to recognise and strip AI co-author trailers.
    noreply@anthropic.com|noreply@openai.com|copilot@github.com|noreply@commandcode.ai|noreply@snowflake.com) return 0 ;;
  esac
  return 1
}

# Scan one file for machine-local PII. Prints MACHINE_LOCAL_HIT lines to stderr.
# Returns 0 when clean, 1 when any hit was reported (callers that are advisory
# may ignore the status).
fm_leak_scan_file_machine_local() {
  local file=$1
  local rel=${2:-$file}
  local hits=0 line emails email

  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    return 0
  fi

  if grep -EIq "$FM_LEAK_USERS_PATH_PATTERN" "$file" 2>/dev/null; then
    while IFS= read -r line; do
      printf 'MACHINE_LOCAL_HIT: users-path: %s: %s\n' "$rel" "$line" >&2
      hits=1
    done < <(grep -En "$FM_LEAK_USERS_PATH_PATTERN" "$file" 2>/dev/null | head -20)
  fi

  if grep -EIq "$FM_LEAK_EMAIL_PATTERN" "$file" 2>/dev/null; then
    while IFS= read -r line; do
      emails=$(printf '%s\n' "$line" | grep -Eo "$FM_LEAK_EMAIL_PATTERN" || true)
      while IFS= read -r email; do
        [ -n "$email" ] || continue
        if ! fm_leak_is_allowed_email "$email"; then
          printf 'MACHINE_LOCAL_HIT: email: %s: %s\n' "$rel" "$line" >&2
          hits=1
          break
        fi
      done <<< "$emails"
    done < <(grep -En "$FM_LEAK_EMAIL_PATTERN" "$file" 2>/dev/null | head -20)
  fi

  [ "$hits" -eq 0 ]
}

# Scan a file or directory tree for machine-local PII (advisory helper).
# Prints MACHINE_LOCAL_HIT lines to stderr. Returns 0 when clean, 1 on hits.
fm_leak_scan_machine_local() {
  local path=$1
  local hits=0 f rel

  if [ -d "$path" ]; then
    while IFS= read -r -d '' f; do
      rel=${f#"$path"/}
      if ! fm_leak_scan_file_machine_local "$f" "$rel"; then
        hits=1
      fi
    done < <(find "$path" -type f -print0)
  elif [ -f "$path" ]; then
    if ! fm_leak_scan_file_machine_local "$path" "$path"; then
      hits=1
    fi
  else
    printf 'error: machine-local scan target missing: %s\n' "$path" >&2
    return 2
  fi

  [ "$hits" -eq 0 ]
}

# fm_leak_words_clean <file>: the file's words and phrases, one per line, with
# surrounding blanks trimmed and blank and # comment lines dropped. Every line
# it prints ends in a newline, even when the file's last line does not, so lists
# printed one after another never join two words.
fm_leak_words_clean() {
  awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") } $0 != "" && substr($0, 1, 1) != "#"' "$1"
}

# fm_leak_words_write <home> <config-dir> <out-file>
# Write the home's private word list to <out-file>, one fixed string per line:
# the home's own <config-dir>/leak-words, then <config-dir>/leak-words.inherited
# (the list a secondmate home inherits from its primary), then the leak-words
# file at the root of the home's private add-on (bin/fm-addon.sh root, read
# with FM_HOME=<home> and that config dir), which is how a private team add-on
# carries the team's list. <out-file> is empty when the home has none of them. An add-on that is
# configured but unusable is named on stderr, adds no words, and returns 2 with
# the home's own words still written. Never prints a word; returns 1 when
# <out-file> cannot be written.
fm_leak_words_write() {
  local home=$1 config=$2 out=$3 addon list rc=0
  : > "$out" || return 1
  for list in "$config/leak-words" "$config/leak-words.inherited"; do
    if [ -f "$list" ]; then
      fm_leak_words_clean "$list" >> "$out" || return 1
    fi
  done
  [ -x "$FM_LEAK_LIB_DIR/fm-addon.sh" ] || return 0
  addon=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$FM_LEAK_LIB_DIR/fm-addon.sh" root 2>/dev/null) || rc=$?
  case "$rc" in
    0)
      if [ -f "$addon/leak-words" ]; then
        fm_leak_words_clean "$addon/leak-words" >> "$out" || return 1
      fi
      ;;
    1) ;;
    *)
      printf 'fm-leak-lib: the private add-on in %s/addon is unusable, so its leak-words list is not read; bin/fm-addon.sh root names why\n' "$config" >&2
      return 2
      ;;
  esac
  return 0
}

# fm_leak_words_inherit_payload <home> <config-dir> <out-file>
# Stage the word list a primary home publishes to its secondmate homes as their
# config/leak-words.inherited (bin/fm-config-inherit-lib.sh): the merged list
# above, so a secondmate also keeps its primary's add-on words out of what it
# publishes. A secondmate's own config/leak-words is never touched. <out-file>
# is left absent when the home has no words, which the inheritance mirrors as
# absence downstream. Fails when the add-on is unusable, so a secondmate keeps
# its last inherited list rather than losing the add-on's words.
fm_leak_words_inherit_payload() {
  local out=$3
  rm -f "$out" || return 1
  fm_leak_words_write "$1" "$2" "$out" || { rm -f "$out"; return 1; }
  [ -s "$out" ] || rm -f "$out"
}
