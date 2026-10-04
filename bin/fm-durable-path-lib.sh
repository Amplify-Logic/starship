#!/usr/bin/env bash
# Shared normalization for durable directory inputs.
#
# A relative FM_HOME, state override, or data override otherwise resolves
# against whatever directory the caller happened to be in, which is the whole
# bug class the durable-path work exists to close.
#
# fm_path_resolve_directory prints the absolute path and fails silently, for a
# caller that reports through its own channel.
# fm_path_require_directory adds the shared diagnostic that several test files
# assert on verbatim, so the exact wording is part of this contract.
#
# An already-absolute path is returned untouched and is not required to exist,
# which every copy this replaces also did.

fm_path_resolve_directory() {
  local path=$1
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  ( CDPATH='' cd -- "$path" 2>/dev/null && pwd -P )
}

fm_path_require_directory() {
  local name=$1 path=$2 resolved
  resolved=$(fm_path_resolve_directory "$path") || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  [ -n "$resolved" ] || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}
