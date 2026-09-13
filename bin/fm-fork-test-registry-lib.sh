#!/usr/bin/env bash
# Parse the optional fork-owned test registry consumed by bin/fm-test-run.sh.
#
# Registry rows are whitespace-separated and have one of these exact forms:
#   family <family-name> tests/<script>.test.sh
#   covers <repository-path-glob> tests/<script>.test.sh
#   adds   <repository-path-glob> tests/<script>.test.sh
# A covers row claims a fork-only path the upstream map does not own, so the
# registry answer is the complete answer for that path. An adds row contributes
# an extra owner for a path the upstream map already owns, so the upstream map
# still runs and its owners are kept alongside the fork owner.
#
# A covers row is an override, and an override is legitimate only where its
# trigger is narrower than "the fork is installed" and upstream's behaviour is
# unchanged outside that trigger. For this registry that means exclusivity is
# confined to paths upstream has no answer for. A covers row on a path upstream
# still owns is not an override but a replacement, and it would delete those
# owners with no error at all. fork_registry_assert_no_shadow proves the
# confinement per row and fails closed, so use adds wherever upstream and the
# fork both have an answer and upstream's answer must survive.
#
# Note what makes upstream "have an answer" here. The runner's map falls back
# to a grep over the test suite, so it claims a path as soon as any test file
# mentions that path as text, including in a comment or a fixture filename. A
# covers row is therefore safe only for a path no test text mentions, and
# adding such a mention later flips the correct row type from covers to adds.
# The assertion reports that as a shadow, which is the intended loud failure,
# but the fix is usually to stop naming the path in the test rather than to
# widen the row.
# A family row is confined the same way on the family dimension: it may name
# only a family the runner already lists, and only a script the runner's own
# map leaves unclassified. fork_registry_assert_family_confined proves both per
# row and fails closed, because a row that re-homes a script upstream already
# classifies, or that invents a family no lane composition can see, is again a
# replacement rather than an override.
# Blank lines and lines whose first non-whitespace character is # are ignored.
# A present malformed registry fails closed with an actionable line number.
# A missing library or registry is handled by the guarded hooks in the runner
# and preserves the upstream runner's built-in selection exactly.
#
# Public functions:
#   fork_registry_apply <registry-file>
#   fork_registry_family_for_basename <test-basename>
#   fork_registry_scripts_for_path <repository-relative-path>
#   fork_registry_assert_no_shadow <upstream-map-function>
#   fork_registry_assert_family_confined <upstream-family-function> <known-families-function>

FORK_REGISTRY_FAMILY_NAMES=()
FORK_REGISTRY_FAMILY_SCRIPTS=()
FORK_REGISTRY_COVER_GLOBS=()
FORK_REGISTRY_COVER_SCRIPTS=()
FORK_REGISTRY_COVER_EXCLUSIVE=()
# Set while fork_registry_assert_no_shadow asks the upstream map what it would
# select on its own. The bypass lives here rather than in the runner's hook so
# the core script carries no fork-specific conditional.
FORK_REGISTRY_UPSTREAM_ONLY=

fork_registry_error() {
  printf 'fm-fork-test-registry: %s\n' "$*" >&2
}

fork_registry_script_valid() {
  case "$1" in
    tests/*.test.sh)
      case "$1" in
        *'*'*|*'?'*|*'['*) return 1 ;;
      esac
      return 0
      ;;
  esac
  return 1
}

fork_registry_glob_valid() {
  case "$1" in
    ''|/*|./*|../*|*/../*|*/..|*//*|*[$'\r\n']) return 1 ;;
  esac
  # A glob must start with a literal character. A leading wildcard, and a bare
  # * most of all, would claim every changed path, which on a covers row makes
  # the registry the exclusive answer for the whole repository.
  case "$1" in
    '*'*|'?'*|'['*) return 1 ;;
  esac
  return 0
}

fork_registry_apply() { # <registry-file>
  local file=${1:-} line line_no=0 kind value script extra existing
  [ -n "$file" ] || { fork_registry_error 'registry path is required'; return 2; }
  [ -r "$file" ] || { fork_registry_error "registry is not readable: $file"; return 2; }

  FORK_REGISTRY_FAMILY_NAMES=()
  FORK_REGISTRY_FAMILY_SCRIPTS=()
  FORK_REGISTRY_COVER_GLOBS=()
  FORK_REGISTRY_COVER_SCRIPTS=()
  FORK_REGISTRY_COVER_EXCLUSIVE=()

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    read -r kind value script extra <<< "$line"
    case "$kind" in
      \#*) continue ;;
    esac
    if [ -n "${extra:-}" ] || [ -z "${script:-}" ]; then
      fork_registry_error "$file:$line_no: expected exactly three fields"
      return 2
    fi
    fork_registry_script_valid "$script" || {
      fork_registry_error "$file:$line_no: invalid test script: $script"
      return 2
    }
    [ -f "$script" ] || {
      fork_registry_error "$file:$line_no: test script does not exist: $script"
      return 2
    }
    case "$kind" in
      family)
        [[ "$value" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
          fork_registry_error "$file:$line_no: invalid family name: $value"
          return 2
        }
        for existing in "${FORK_REGISTRY_FAMILY_SCRIPTS[@]+"${FORK_REGISTRY_FAMILY_SCRIPTS[@]}"}"; do
          [ "$existing" != "$script" ] || {
            fork_registry_error "$file:$line_no: duplicate family owner for $script"
            return 2
          }
        done
        FORK_REGISTRY_FAMILY_NAMES+=("$value")
        FORK_REGISTRY_FAMILY_SCRIPTS+=("$script")
        ;;
      covers|adds)
        fork_registry_glob_valid "$value" || {
          fork_registry_error "$file:$line_no: unsafe repository path glob: $value"
          return 2
        }
        FORK_REGISTRY_COVER_GLOBS+=("$value")
        FORK_REGISTRY_COVER_SCRIPTS+=("$script")
        if [ "$kind" = covers ]; then
          FORK_REGISTRY_COVER_EXCLUSIVE+=(1)
        else
          FORK_REGISTRY_COVER_EXCLUSIVE+=(0)
        fi
        ;;
      *)
        fork_registry_error "$file:$line_no: unknown row type: $kind"
        return 2
        ;;
    esac
  done < "$file"
}

fork_registry_family_for_basename() { # <test-basename>
  local want=${1:-} index=0 script
  [ -z "${FORK_REGISTRY_UPSTREAM_ONLY:-}" ] || return 1
  for script in "${FORK_REGISTRY_FAMILY_SCRIPTS[@]+"${FORK_REGISTRY_FAMILY_SCRIPTS[@]}"}"; do
    if [ "${script##*/}" = "$want" ]; then
      printf '%s\n' "${FORK_REGISTRY_FAMILY_NAMES[$index]}"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

# Prints every registry owner of <path>. Returns 0 only when a covers row
# matched, which tells the runner the registry answer is complete; an adds-only
# match returns 1 so the caller still consults the upstream map and keeps the
# owners declared there.
fork_registry_scripts_for_path() { # <repository-relative-path>
  local path=${1:-} index=0 pattern exclusive=1 script
  # Answer nothing while the shadow assertion is asking the upstream map what
  # it selects on its own. Returning 1 makes the runner's hook fall through to
  # the upstream case exactly as it does when this library is absent.
  [ -z "${FORK_REGISTRY_UPSTREAM_ONLY:-}" ] || return 1
  for pattern in "${FORK_REGISTRY_COVER_GLOBS[@]+"${FORK_REGISTRY_COVER_GLOBS[@]}"}"; do
    # Registry cover values are intentionally expanded as shell globs.
    # shellcheck disable=SC2254
    case "$path" in
      $pattern)
        script=${FORK_REGISTRY_COVER_SCRIPTS[$index]}
        printf '__script__:%s\n' "${script##*/}"
        if [ "${FORK_REGISTRY_COVER_EXCLUSIVE[$index]}" = 1 ]; then
          exclusive=0
        fi
        ;;
    esac
    index=$((index + 1))
  done
  return "$exclusive"
}

# Every repository path a registry glob claims. A literal glob claims itself; a
# wildcard glob claims every tracked path it currently matches, so the check
# below is exact against the working tree rather than a guess about the shape.
fork_registry_probe_paths() { # <glob>
  local pattern=${1:-} path
  case "$pattern" in
    *'*'*|*'?'*|*'['*) ;;
    *) printf '%s\n' "$pattern"; return 0 ;;
  esac
  # A wildcard glob is never itself a path. Passing its text to the upstream
  # map would reach the reference fallback as a literal string and could claim
  # a shadow that no real path has, so only the paths it matches are probed.
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    # Registry cover values are intentionally expanded as shell globs.
    # shellcheck disable=SC2254
    case "$path" in
      $pattern) printf '%s\n' "$path" ;;
    esac
  done < <(git ls-files -z 2>/dev/null)
}

# What the upstream map selects for <path> with this registry out of the way.
fork_registry_upstream_owners() { # <upstream-map-function> <path>
  ( FORK_REGISTRY_UPSTREAM_ONLY=1; "$1" "$2" )
}

# Fails closed when a covers row claims a path the upstream map still owns.
# A covers row is exclusive, so such a row deletes upstream's owners for that
# path with no error at all, and every future upstream change to them becomes a
# change this fork quietly does not get. That is a replacement wearing an
# override's clothes, which is the one shape this grammar must refuse.
# An __unmapped__ answer is not an owner:
# it is upstream saying it has no mapping, which is exactly what a covers row is
# for. Call this once from the changed-path selector, in the parent shell, so a
# failure can stop the run: from a process substitution an exit would only end
# the subshell and the selection would silently continue. The check asks the
# upstream map once per claimed path, so it costs about a second on a repository
# this size, paid once per changed-run and only when a registry is present.
fork_registry_assert_no_shadow() { # <upstream-map-function>
  local fn=${1:-} index=0 pattern probe owner script failed=0
  [ -n "$fn" ] || {
    fork_registry_error 'upstream map function name is required'
    return 2
  }
  command -v "$fn" >/dev/null 2>&1 || {
    fork_registry_error "upstream map function is not defined: $fn"
    return 2
  }
  for pattern in "${FORK_REGISTRY_COVER_GLOBS[@]+"${FORK_REGISTRY_COVER_GLOBS[@]}"}"; do
    if [ "${FORK_REGISTRY_COVER_EXCLUSIVE[$index]}" = 1 ]; then
      while IFS= read -r probe; do
        [ -n "$probe" ] || continue
        while IFS= read -r owner; do
          [ -n "$owner" ] || continue
          case "$owner" in
            __unmapped__:*) continue ;;
          esac
          script=${FORK_REGISTRY_COVER_SCRIPTS[$index]}
          fork_registry_error \
            "covers $pattern $script shadows the upstream owner of $probe: $owner"
          failed=1
        done < <(fork_registry_upstream_owners "$fn" "$probe")
      done < <(fork_registry_probe_paths "$pattern")
    fi
    index=$((index + 1))
  done
  [ "$failed" -eq 0 ] || {
    fork_registry_error \
      'covers is confined to paths upstream has no answer for: use adds where upstream still selects owners'
    return 1
  }
  return 0
}

# Fails closed when a family row is not confined to what upstream leaves open:
# the family must already be one the runner lists, so --list-families and lane
# composition see it, and the script must be one the runner's own map leaves
# unclassified, so the row adds a home rather than moving a script out of the
# family upstream gave it. Call it once in the parent shell after the runner's
# family functions are defined, for the same reason as the shadow assertion.
fork_registry_assert_family_confined() { # <upstream-family-function> <known-families-function>
  local family_fn=${1:-} known_fn=${2:-} index=0 script family upstream known failed=0
  [ -n "$family_fn" ] && [ -n "$known_fn" ] || {
    fork_registry_error 'upstream family and known-families function names are required'
    return 2
  }
  command -v "$family_fn" >/dev/null 2>&1 || {
    fork_registry_error "upstream family function is not defined: $family_fn"
    return 2
  }
  command -v "$known_fn" >/dev/null 2>&1 || {
    fork_registry_error "known-families function is not defined: $known_fn"
    return 2
  }
  for script in "${FORK_REGISTRY_FAMILY_SCRIPTS[@]+"${FORK_REGISTRY_FAMILY_SCRIPTS[@]}"}"; do
    family=${FORK_REGISTRY_FAMILY_NAMES[$index]}
    known=0
    while IFS= read -r upstream; do
      [ "$upstream" != "$family" ] || known=1
    done < <("$known_fn")
    if [ "$known" -ne 1 ]; then
      fork_registry_error \
        "family $family $script names a family the runner does not list: $family"
      failed=1
    fi
    upstream=$( FORK_REGISTRY_UPSTREAM_ONLY=1; "$family_fn" "${script##*/}" )
    if [ "$upstream" != unclassified ]; then
      fork_registry_error \
        "family $family $script re-homes a script the runner already classifies as $upstream"
      failed=1
    fi
    index=$((index + 1))
  done
  [ "$failed" -eq 0 ] || {
    fork_registry_error \
      'family is confined to listed families and scripts upstream leaves unclassified'
    return 1
  }
  return 0
}
