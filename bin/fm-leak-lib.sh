#!/usr/bin/env bash
# Single owner of email and /Users/<name> regex patterns for public-repo and
# portable-home machine-local scans.
#
# Sourced by:
#   bin/fm-leak-guard.sh          CI hard-fail public-repo leak guard
#   bin/fm-home-port.sh           --warn-machine-local advisory pass on scan
#
# Do not duplicate EMAIL or /Users/<name> patterns elsewhere.
# Live-token shapes stay with each caller's credential scan (portable export
# uses a stricter name-only match than CI).

if [ -n "${FM_LEAK_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_LEAK_LIB_SOURCED=1

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
