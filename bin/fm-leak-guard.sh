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
#
# The credential half reuses the same token regex family as scan_path() in
# bin/fm-home-port.sh so both gates stay aligned.
# tests/ fixtures that intentionally embed synthetic tokens are allowlisted.
# This script, bin/fm-leak-lib.sh, and bin/fm-home-port.sh are allowlisted
# because they embed pattern strings.
#
# Usage:
#   fm-leak-guard.sh              scan the whole tracked tree (what CI runs)
#   fm-leak-guard.sh <path>...    scan only the given paths (developer convenience)
set -eu

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

  if is_allowlisted "$rel"; then
    return 0
  fi

  # Skip empty or binary files (grep -I skips binary).
  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
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

if [ "$hits" -ne 0 ]; then
  printf 'fm-leak-guard.sh: FAIL - tracked files contain email, /Users/<name>, or live-token shapes (see LEAK_HIT lines above)\n' >&2
  exit 1
fi

printf 'fm-leak-guard.sh: PASS - no email, /Users/<name>, or live-token shapes in scanned tracked files\n'
exit 0
