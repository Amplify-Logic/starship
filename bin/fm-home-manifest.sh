#!/usr/bin/env bash
# Print an environment-fidelity manifest for one home: the resolved runtime
# backend and a version line per resolved tool.
#
# Two Macs are compared by diffing two of these before a home is ported, so the
# output is deliberately stable: backend first, then a generated stamp, then the
# resolved tool set sorted and deduplicated.
#
# This is fork-owned. bin/fm-bootstrap.sh resolves the backend and the tool set
# and dispatches here for its `manifest` subcommand; the tool set is passed as
# separate arguments rather than re-derived, so this script never has to know
# how bootstrap resolves it.
#
# Usage:
#   fm-home-manifest.sh <backend> [<tool>...]
#
# A tool that is not on PATH prints MISSING. A tool that is present but answers
# none of the version probes prints unknown, so a missing binary and an
# unparseable one are never confused.

set -eu

usage() {
  echo "usage: fm-home-manifest.sh <backend> [<tool>...]" >&2
}

# Resolve a one-line version string for environment-fidelity comparison.
# Prefers --version, then -V, then version; falls back to "unknown" when the
# binary exists but none of those probes produce a parseable first line.
home_manifest_tool_version() {
  local tool=$1 out=""
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'MISSING\n'
    return 0
  fi
  out=$("$tool" --version 2>/dev/null | head -n 1) || true
  if [ -z "$out" ]; then
    out=$("$tool" -V 2>/dev/null | head -n 1) || true
  fi
  if [ -z "$out" ]; then
    out=$("$tool" version 2>/dev/null | head -n 1) || true
  fi
  if [ -z "$out" ]; then
    printf 'unknown\n'
    return 0
  fi
  printf '%s\n' "$out" | tr '\t' ' ' | sed 's/[[:space:]]\{1,\}/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

main() {
  local backend t
  if [ "$#" -lt 1 ]; then
    usage
    return 1
  fi
  backend=$1
  shift
  # Stable ordering: backend first, then sorted unique tools from the resolved set.
  printf 'backend=%s\n' "$backend"
  printf 'generated=%s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
  printf '%s\n' "$@" | sort -u | while IFS= read -r t; do
    [ -n "$t" ] || continue
    printf '%s=%s\n' "$t" "$(home_manifest_tool_version "$t")"
  done
}

main "$@"
