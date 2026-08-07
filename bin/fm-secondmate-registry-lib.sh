#!/usr/bin/env bash
# shellcheck disable=SC2034 # Parsed fields are output globals for sourcing callers.
# Shared parser and binding validator for data/secondmates.md records.
#
# A generated record ends with this structured suffix:
#   (home: ...; scope: ...; projects: ...; added YYYY-MM-DD)
# Summary and scope are natural language and may contain parentheses or
# semicolons, so parsing anchors to the complete suffix and its field markers.
#
# secondmate_registry_validate_bindings accepts optional expected-id,
# expected-home, active-home, code-root, and mode arguments after its registry
# and path-resolver arguments.
# active-home and code-root adapt the common parser to this fork's isolated-home
# model by refusing a registered home equal to, inside, or containing either
# active root.
#
# Mode selects how far a defect reaches.
# In the default strict mode any defective entry fails the whole registry, which
# is what a deliberate registry audit wants.
# In scoped mode a defect in an entry other than the expected id is skipped, and
# only defects of the expected entry - including the duplicate and overlap
# checks it genuinely participates in - refuse.
# Scoped mode exists because a malformed line for an unrelated secondmate must
# never abort spawning or tearing down a healthy one.
#
# In scoped mode an expected id with no entry at all is not an error: the caller
# is told through SECONDMATE_REGISTRY_MATCH_FOUND so it can accept other proof of
# ownership, such as an on-disk home marker, and still reach guarded cleanup.

SECONDMATE_REGISTRY_ID=
SECONDMATE_REGISTRY_SUMMARY=
SECONDMATE_REGISTRY_HOME=
SECONDMATE_REGISTRY_SCOPE=
SECONDMATE_REGISTRY_PROJECTS=
SECONDMATE_REGISTRY_ADDED=
SECONDMATE_REGISTRY_LINE=
SECONDMATE_REGISTRY_MATCH_HOME=
SECONDMATE_REGISTRY_MATCH_HOME_KEY=
SECONDMATE_REGISTRY_MATCH_PROJECTS=
SECONDMATE_REGISTRY_MATCH_FOUND=
SECONDMATE_REGISTRY_ERROR=

# Trailing whitespace is trimmed from every captured field.
# The field patterns stop at their delimiter and would otherwise keep the padding
# in a hand-edited entry such as "(home: /srv/sub ; scope: x)", which turns a
# working binding into an unresolvable one.
secondmate_registry_rtrim() {
  local value=$1
  while [ -n "$value" ]; do
    case "$value" in
      *[[:space:]]) value=${value%?} ;;
      *) break ;;
    esac
  done
  printf '%s' "$value"
}

secondmate_registry_parse_line() {
  local line=$1
  local record_re='^- ([A-Za-z0-9._-]+) - (.+) \(home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  SECONDMATE_REGISTRY_ID=
  SECONDMATE_REGISTRY_SUMMARY=
  SECONDMATE_REGISTRY_HOME=
  SECONDMATE_REGISTRY_SCOPE=
  SECONDMATE_REGISTRY_PROJECTS=
  SECONDMATE_REGISTRY_ADDED=
  if [[ "$line" =~ $record_re ]]; then
    SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
    SECONDMATE_REGISTRY_SUMMARY=$(secondmate_registry_rtrim "${BASH_REMATCH[2]}")
    SECONDMATE_REGISTRY_HOME=$(secondmate_registry_rtrim "${BASH_REMATCH[3]}")
    SECONDMATE_REGISTRY_SCOPE=$(secondmate_registry_rtrim "${BASH_REMATCH[4]}")
    SECONDMATE_REGISTRY_PROJECTS=$(secondmate_registry_rtrim "${BASH_REMATCH[5]}")
    SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[6]}
  else
    return 1
  fi
  [ -n "$SECONDMATE_REGISTRY_HOME" ] || return 1
  [ -n "$SECONDMATE_REGISTRY_SCOPE" ] || return 1
}

# rc=2 from the read helpers below is produced only by this refusal, and they
# usually run inside a command substitution where SECONDMATE_REGISTRY_ERROR
# cannot reach the caller, so rc=2 call sites rebuild the exact message here.
secondmate_registry_symlink_refusal() {
  printf 'secondmate registry is unavailable or unsafe: %s (registry is a symlink and is refused)\n' "$1"
}

# Returns 2 when the registry itself cannot be read safely, and 1 when the file
# is fine but holds no single usable entry for the id.
# Callers must keep those apart: a refused symlink is an operator-visible fault
# that has to name its cause, not an id that happens to be unregistered.
secondmate_registry_line_for_id() {
  local reg=$1 id=$2 line count=0
  SECONDMATE_REGISTRY_ERROR=
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ -L "$reg" ]; then
    SECONDMATE_REGISTRY_ERROR=$(secondmate_registry_symlink_refusal "$reg")
    return 2
  fi
  [ -f "$reg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "- $id" ] || case "$line" in "- $id "*) ;; *) continue ;; esac
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    SECONDMATE_REGISTRY_LINE=$line
  done < "$reg"
  [ "$count" -eq 1 ] || return 1
  secondmate_registry_parse_line "$SECONDMATE_REGISTRY_LINE"
}

# Propagates the registry-unreadable code so callers can report the real cause
# instead of reporting the id as unregistered.
secondmate_registry_field() {
  local reg=$1 id=$2 key=$3 rc=0
  secondmate_registry_line_for_id "$reg" "$id" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  case "$key" in
    home) printf '%s\n' "$SECONDMATE_REGISTRY_HOME" ;;
    projects) printf '%s\n' "$SECONDMATE_REGISTRY_PROJECTS" ;;
    *) return 1 ;;
  esac
}

# Both branches resolve inside a subshell so the caller's working directory is
# never relocated, matching resolve_path in bin/fm-ff-lib.sh.
# This function is passed to the validator by name, so a future direct caller
# gets no warning that it once had a side effect.
secondmate_registry_path_key() {
  local path=$1 parent base
  case "$path" in /*) ;; *) return 1 ;; esac
  if [ -d "$path" ]; then
    ( CDPATH='' cd -- "$path" && pwd -P )
  else
    parent=$(dirname -- "$path")
    base=$(basename -- "$path")
    ( CDPATH='' cd -- "$parent" && printf '%s/%s\n' "$(pwd -P)" "$base" )
  fi
}

secondmate_registry_paths_overlap() {
  local left=$1 right=$2
  [ "$left" = "$right" ] && return 0
  case "$left/" in "$right/"*) return 0 ;; esac
  case "$right/" in "$left/"*) return 0 ;; esac
  return 1
}

# A defect stops the whole registry in strict mode.
# In scoped mode it only stops the expected entry, so an unrelated bad line is
# skipped instead of blocking an operation on a healthy secondmate.
# Scoped mode with no expected id skips every defect, which is what an
# enumeration such as the descendant scan wants.
secondmate_registry_defect_is_fatal() {
  local mode=$1 id=$2 expected_id=$3
  [ "$mode" = scoped ] || return 0
  [ -n "$expected_id" ] && [ "$id" = "$expected_id" ]
}

secondmate_registry_validate_bindings() {
  local reg=$1 resolver=$2 expected_id=${3:-} expected_home=${4:-}
  local active_home=${5:-} code_root=${6:-} mode=${7:-strict}
  local tmp rc=0
  SECONDMATE_REGISTRY_MATCH_HOME=
  SECONDMATE_REGISTRY_MATCH_HOME_KEY=
  SECONDMATE_REGISTRY_MATCH_PROJECTS=
  SECONDMATE_REGISTRY_MATCH_FOUND=0
  SECONDMATE_REGISTRY_ERROR=
  case "$mode" in
    strict|scoped) ;;
    *) SECONDMATE_REGISTRY_ERROR="unknown secondmate registry validation mode: $mode"; return 1 ;;
  esac
  case "$expected_id" in *[!A-Za-z0-9._-]*) SECONDMATE_REGISTRY_ERROR="invalid secondmate id: $expected_id"; return 1 ;; esac
  if [ -L "$reg" ]; then
    SECONDMATE_REGISTRY_ERROR=$(secondmate_registry_symlink_refusal "$reg")
    return 1
  fi
  if [ ! -f "$reg" ]; then
    SECONDMATE_REGISTRY_ERROR="secondmate registry is unavailable or unsafe: $reg"
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-registry.XXXXXX") || {
    SECONDMATE_REGISTRY_ERROR="could not create secondmate registry validation state"
    return 1
  }
  secondmate_registry_validate_scan "$tmp" "$reg" "$resolver" "$expected_id" \
    "$expected_home" "$active_home" "$code_root" "$mode" || rc=$?
  rm -rf -- "$tmp"
  return "$rc"
}

# Every exit here is a plain return: the caller owns the one cleanup of $tmp, so
# a future early return cannot leak the validation directory.
secondmate_registry_validate_scan() {
  local tmp=$1 reg=$2 resolver=$3 expected_id=$4 expected_home=$5
  local active_home=$6 code_root=$7 mode=$8
  local snapshot bindings line id home home_key duplicate_homes duplicate_ids overlaps
  local active_key='' root_key=''
  if [ -n "$active_home" ]; then
    active_key=$("$resolver" "$active_home" 2>/dev/null || true)
    [ -n "$active_key" ] || {
      SECONDMATE_REGISTRY_ERROR="active firstmate home cannot be resolved: $active_home"
      return 1
    }
  fi
  if [ -n "$code_root" ]; then
    root_key=$("$resolver" "$code_root" 2>/dev/null || true)
    [ -n "$root_key" ] || {
      SECONDMATE_REGISTRY_ERROR="firstmate code root cannot be resolved: $code_root"
      return 1
    }
  fi
  snapshot="$tmp/registry"
  bindings="$tmp/bindings"
  if ! cat "$reg" > "$snapshot" 2>/dev/null || ! : > "$bindings"; then
    SECONDMATE_REGISTRY_ERROR="secondmate registry is unavailable or unsafe: $reg"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! secondmate_registry_parse_line "$line"; then
      # An unparseable line exposes no id, so it can never be the expected entry.
      secondmate_registry_defect_is_fatal "$mode" "" "$expected_id" || continue
      SECONDMATE_REGISTRY_ERROR="malformed secondmate registry entry: $line"
      return 1
    fi
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    case "$home" in
      /*) ;;
      *)
        secondmate_registry_defect_is_fatal "$mode" "$id" "$expected_id" || continue
        SECONDMATE_REGISTRY_ERROR="unsafe non-absolute secondmate home for $id: $home"
        return 1
        ;;
    esac
    case "$home" in
      *$'\t'*)
        secondmate_registry_defect_is_fatal "$mode" "$id" "$expected_id" || continue
        SECONDMATE_REGISTRY_ERROR="unsafe secondmate home for $id"
        return 1
        ;;
    esac
    home_key=$("$resolver" "$home" 2>/dev/null || true)
    if [ -z "$home_key" ]; then
      secondmate_registry_defect_is_fatal "$mode" "$id" "$expected_id" || continue
      SECONDMATE_REGISTRY_ERROR="unresolvable secondmate home for $id: $home"
      return 1
    fi
    if { [ -n "$active_key" ] && secondmate_registry_paths_overlap "$home_key" "$active_key"; } \
      || { [ -n "$root_key" ] && secondmate_registry_paths_overlap "$home_key" "$root_key"; }; then
      secondmate_registry_defect_is_fatal "$mode" "$id" "$expected_id" || continue
      SECONDMATE_REGISTRY_ERROR="secondmate home for $id is not isolated from the active firstmate home or code root: $home"
      return 1
    fi
    printf '%s\t%s\n' "$home_key" "$id" >> "$bindings"
    if [ -n "$expected_id" ] && [ "$id" = "$expected_id" ]; then
      SECONDMATE_REGISTRY_MATCH_HOME=$home
      SECONDMATE_REGISTRY_MATCH_HOME_KEY=$home_key
      SECONDMATE_REGISTRY_MATCH_PROJECTS=$SECONDMATE_REGISTRY_PROJECTS
      SECONDMATE_REGISTRY_MATCH_FOUND=1
    fi
  done < "$snapshot"
  if [ "$mode" = scoped ]; then
    secondmate_registry_validate_scoped_collisions "$bindings" "$expected_id" || return 1
    if [ -n "$expected_id" ] && [ "$SECONDMATE_REGISTRY_MATCH_FOUND" != 1 ]; then
      # An absent binding is not a defect here; the caller decides whether other
      # proof of ownership, such as an on-disk marker, is enough.
      return 0
    fi
    secondmate_registry_validate_expected_home "$resolver" "$expected_id" "$expected_home"
    return $?
  fi
  duplicate_homes=$(awk -F '\t' '
    {
      if ($1 in owner) {
        print $1 ": " owner[$1] ", " $2
        bad=1
      } else {
        owner[$1]=$2
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    SECONDMATE_REGISTRY_ERROR="duplicate secondmate home assignment: $duplicate_homes"
    return 1
  }
  duplicate_ids=$(awk -F '\t' '
    {
      if ($2 in home) {
        print $2 ": " home[$2] ", " $1
        bad=1
      } else {
        home[$2]=$1
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    SECONDMATE_REGISTRY_ERROR="duplicate secondmate id assignment: $duplicate_ids"
    return 1
  }
  overlaps=$(awk -F '\t' '
    function ancestor(a, b) { return a != b && index(b, a "/") == 1 }
    {
      for (i = 1; i <= count; i++) {
        if (ancestor($1, path[i])) {
          print $1 " (" $2 ") contains " path[i] " (" id[i] ")"
          bad=1
        } else if (ancestor(path[i], $1)) {
          print path[i] " (" id[i] ") contains " $1 " (" $2 ")"
          bad=1
        }
      }
      count++
      path[count]=$1
      id[count]=$2
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    SECONDMATE_REGISTRY_ERROR="overlapping secondmate home assignment: $overlaps"
    return 1
  }
  if [ -n "$expected_id" ] && [ "$SECONDMATE_REGISTRY_MATCH_FOUND" != 1 ]; then
    SECONDMATE_REGISTRY_ERROR="no registry binding for secondmate $expected_id"
    return 1
  fi
  secondmate_registry_validate_expected_home "$resolver" "$expected_id" "$expected_home"
}

# Only the collisions the expected entry itself takes part in.
# A duplicate or overlap between two unrelated entries is somebody else's
# problem and must not block an operation on a healthy secondmate.
secondmate_registry_validate_scoped_collisions() {
  local bindings=$1 expected_id=$2 target_count sibling_key sibling_id
  [ -n "$expected_id" ] || return 0
  [ "$SECONDMATE_REGISTRY_MATCH_FOUND" = 1 ] || return 0
  target_count=$(awk -F '\t' -v want="$expected_id" '$2 == want { n++ } END { print n + 0 }' "$bindings" 2>/dev/null)
  if [ "${target_count:-0}" -gt 1 ]; then
    SECONDMATE_REGISTRY_ERROR="duplicate secondmate id assignment: $expected_id"
    return 1
  fi
  while IFS="$(printf '\t')" read -r sibling_key sibling_id || [ -n "$sibling_key" ]; do
    [ -n "$sibling_key" ] || continue
    [ "$sibling_id" = "$expected_id" ] && continue
    if [ "$sibling_key" = "$SECONDMATE_REGISTRY_MATCH_HOME_KEY" ]; then
      SECONDMATE_REGISTRY_ERROR="duplicate secondmate home assignment: $sibling_key: $expected_id, $sibling_id"
      return 1
    fi
    if secondmate_registry_paths_overlap "$sibling_key" "$SECONDMATE_REGISTRY_MATCH_HOME_KEY"; then
      SECONDMATE_REGISTRY_ERROR="overlapping secondmate home assignment: $SECONDMATE_REGISTRY_MATCH_HOME_KEY ($expected_id) contains or sits inside $sibling_key ($sibling_id)"
      return 1
    fi
  done < "$bindings"
  return 0
}

# A binding that exists but points somewhere else is always a refusal, in either
# mode: only the absent-binding case is ever tolerated.
secondmate_registry_validate_expected_home() {
  local resolver=$1 expected_id=$2 expected_home=$3 expected_home_key
  [ -n "$expected_home" ] || return 0
  expected_home_key=$("$resolver" "$expected_home" 2>/dev/null || true)
  if [ -z "$expected_home_key" ] || [ "$expected_home_key" != "$SECONDMATE_REGISTRY_MATCH_HOME_KEY" ]; then
    SECONDMATE_REGISTRY_ERROR="secondmate $expected_id is registered at $SECONDMATE_REGISTRY_MATCH_HOME, not $expected_home"
    return 1
  fi
  return 0
}
