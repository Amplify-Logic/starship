#!/usr/bin/env bash
# Owns the durable worktree-path claim at allocator handoff and pool return.
#
# A provider can make a pooled path available to a new task before an older
# teardown removes that task's meta file. Once a provider has assigned a path,
# fm_worktree_claim_acquired clears every other meta file's claim to the same
# canonical path before the new task records its own claim. Once teardown has
# returned or removed a worktree, fm_worktree_claim_release clears that task's
# claim immediately. Both transitions share one state-local lock, so a return
# racing a new allocation cannot resurrect or preserve two owners.
#
# A cleared record retains worktree= as an explicit empty value plus transition
# evidence. Recovery must treat that as an unavailable old lease, never as a
# path to resume in.

FM_WORKTREE_LEASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$FM_WORKTREE_LEASE_LIB_DIR/fm-wake-lib.sh"

fm_worktree_claim_real_path() {
  local path=$1
  [ -n "$path" ] || return 1
  (cd "$path" 2>/dev/null && pwd -P)
}

fm_worktree_claim_paths_match() {
  local left=$1 right=$2 left_real right_real
  [ -n "$left" ] && [ -n "$right" ] || return 1
  [ "$left" = "$right" ] && return 0
  left_real=$(fm_worktree_claim_real_path "$left") || return 1
  right_real=$(fm_worktree_claim_real_path "$right") || return 1
  [ "$left_real" = "$right_real" ]
}

fm_worktree_claim_meta_value() {
  local meta=$1 key=$2
  grep -E "^${key}=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2-
}

fm_worktree_claim_rewrite() {
  local meta=$1 transition=$2 owner=$3 old_path=$4 tmp
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "error: unsafe worktree claimant record $meta" >&2
    return 1
  }
  tmp=$(mktemp "$(dirname "$meta")/.worktree-claim.XXXXXX") || return 1
  if ! awk '
    !/^worktree=/ &&
    !/^worktree_reassigned_to=/ &&
    !/^worktree_reassigned_path=/ &&
    !/^worktree_released_path=/
  ' "$meta" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  case "$transition" in
    reassigned)
      printf 'worktree=\nworktree_reassigned_to=%s\nworktree_reassigned_path=%s\n' \
        "$owner" "$old_path" >> "$tmp" || {
        rm -f "$tmp"
        return 1
      }
      ;;
    released)
      printf 'worktree=\nworktree_released_path=%s\n' "$old_path" >> "$tmp" || {
        rm -f "$tmp"
        return 1
      }
      ;;
    *)
      rm -f "$tmp"
      echo "error: unknown worktree claim transition $transition" >&2
      return 1
      ;;
  esac
  chmod 600 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$meta"
}

# fm_worktree_claim_allocation_begin <state-dir>
# Call before asking the provider to assign a path.
fm_worktree_claim_allocation_begin() {
  local state=$1
  FM_WORKTREE_CLAIM_ALLOCATION_LOCK="$state/.worktree-lease-claims.lock"
  fm_lock_acquire_wait "$FM_WORKTREE_CLAIM_ALLOCATION_LOCK"
}

fm_worktree_claim_allocation_cancel() {
  if [ -n "${FM_WORKTREE_CLAIM_ALLOCATION_LOCK:-}" ]; then
    fm_lock_release "$FM_WORKTREE_CLAIM_ALLOCATION_LOCK"
    FM_WORKTREE_CLAIM_ALLOCATION_LOCK=
  fi
}

# fm_worktree_claim_acquired <state-dir> <task-id> <worktree>
# Call after the provider has assigned and the caller has validated the worktree.
fm_worktree_claim_acquired() {
  local state=$1 owner=$2 worktree=$3 lock meta claimed rc=0 held=0
  lock="$state/.worktree-lease-claims.lock"
  if [ "${FM_WORKTREE_CLAIM_ALLOCATION_LOCK:-}" = "$lock" ]; then
    held=1
  else
    fm_lock_acquire_wait "$lock"
  fi
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ "$meta" != "$state/$owner.meta" ] || continue
    claimed=$(fm_worktree_claim_meta_value "$meta" worktree)
    fm_worktree_claim_paths_match "$claimed" "$worktree" || continue
    if ! fm_worktree_claim_rewrite "$meta" reassigned "$owner" "$claimed"; then
      rc=1
      break
    fi
  done
  fm_lock_release "$lock"
  [ "$held" -eq 0 ] || FM_WORKTREE_CLAIM_ALLOCATION_LOCK=
  return "$rc"
}

# fm_worktree_claim_release <state-dir> <task-id> <worktree> <release-function>
# The release function performs every path mutation and the provider return.
fm_worktree_claim_release() {
  local state=$1 owner=$2 worktree=$3 release_function=$4
  local lock meta claimed reassigned rc=0
  lock="$state/.worktree-lease-claims.lock"
  meta="$state/$owner.meta"
  fm_lock_acquire_wait "$lock"
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    claimed=$(fm_worktree_claim_meta_value "$meta" worktree)
    if fm_worktree_claim_paths_match "$claimed" "$worktree"; then
      if "$release_function"; then
        fm_worktree_claim_rewrite "$meta" released "$owner" "$claimed" || rc=1
      else
        rc=1
      fi
    else
      reassigned=$(fm_worktree_claim_meta_value "$meta" worktree_reassigned_path)
      if ! fm_worktree_claim_paths_match "$reassigned" "$worktree"; then
        echo "error: worktree $worktree is not durably claimed by $owner" >&2
        rc=1
      fi
    fi
  else
    echo "error: missing or unsafe worktree claimant record $meta" >&2
    rc=1
  fi
  fm_lock_release "$lock"
  return "$rc"
}
