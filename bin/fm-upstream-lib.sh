# shellcheck shell=bash
# Read-only upstream-drift detection for a forked firstmate home.
# Usage: . bin/fm-upstream-lib.sh
#
# fm_upstream_check prints at most one actionable bootstrap line when the
# configured upstream remote has commits this home lacks:
#   UPSTREAM: <N> commits behind <remote>/<branch> (<url>) - <subject>; ...
# Silent (no output) when there is no upstream remote, origin and upstream are
# the same URL (not a fork), the home is a secondmate, the network is down, the
# tip is already reachable and current, or any probe fails.
#
# Detection never merges, never force-updates local branches, and never touches
# projects/. The only git write is a bounded fetch that updates
# refs/remotes/<remote>/<branch> so commit subjects can be listed.
# Mechanics and defaults below are owned by this file; bin/fm-bootstrap.sh only
# sources and calls it.

FM_UPSTREAM_REMOTE_DEFAULT="${FM_UPSTREAM_REMOTE_DEFAULT:-upstream}"
FM_UPSTREAM_LS_TIMEOUT_DEFAULT="${FM_UPSTREAM_LS_TIMEOUT_DEFAULT:-3}"
FM_UPSTREAM_FETCH_TIMEOUT_DEFAULT="${FM_UPSTREAM_FETCH_TIMEOUT_DEFAULT:-5}"
FM_UPSTREAM_SUBJECT_LIMIT_DEFAULT="${FM_UPSTREAM_SUBJECT_LIMIT_DEFAULT:-8}"

# Run <cmd...> under a portable wall-clock timeout of <secs> seconds.
# Exit status is the command's, or 124 on timeout (GNU timeout convention).
fm_upstream_run_timeout() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
    return $?
  fi
  perl -e '
    my $seconds = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$secs" "$@"
}

# Normalize a remote URL for equality checks: strip trailing .git and slash,
# and peel a file:// scheme so path-form and file-form remotes compare equal.
fm_upstream_normalize_url() {
  local u=$1
  u=${u%.git}
  u=${u%/}
  case "$u" in
    file://*) u=${u#file://} ;;
  esac
  printf '%s\n' "$u"
}

# Resolve the branch name to compare against on <remote> in <dir>.
# Prefers refs/remotes/<remote>/HEAD, then origin-default, then main/master.
fm_upstream_branch() {
  local dir=$1 remote=$2 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#"$remote"/}"
    return 0
  fi
  if command -v fm_default_branch >/dev/null 2>&1; then
    branch=$(fm_default_branch "$dir" 2>/dev/null || true)
    if [ -n "$branch" ]; then
      printf '%s\n' "$branch"
      return 0
    fi
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/remotes/$remote/$branch" \
      || git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Truncate <text> to <max> characters, appending "..." when clipped.
fm_upstream_clip() {
  local text=$1 max=$2
  if [ "${#text}" -le "$max" ]; then
    printf '%s\n' "$text"
    return 0
  fi
  printf '%s...\n' "${text:0:$((max - 3))}"
}

# Print subjects for commits in <tip> not reachable from <base>, bounded.
fm_upstream_subjects() {
  local dir=$1 base=$2 tip=$3 limit=$4
  local line clipped out="" n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    clipped=$(fm_upstream_clip "$line" 72)
    if [ -z "$out" ]; then
      out=$clipped
    else
      out="$out; $clipped"
    fi
    n=$((n + 1))
    [ "$n" -lt "$limit" ] || break
  done < <(git -C "$dir" log --format=%s --no-decorate -n "$limit" "$base..$tip" 2>/dev/null || true)
  printf '%s\n' "$out"
}

# Detect upstream drift for the firstmate repo at <dir>.
# Optional <home> enables the secondmate-home silence rule when that home carries
# a .fm-secondmate-home marker. Always exits 0; prints one line or nothing.
fm_upstream_check() {
  local dir=$1 home=${2:-} remote branch origin_url upstream_url tip head
  local track_ref count subjects ls_timeout fetch_timeout subject_limit url_disp
  local tip_ok=0

  remote=${FM_UPSTREAM_REMOTE:-$FM_UPSTREAM_REMOTE_DEFAULT}
  ls_timeout=${FM_UPSTREAM_LS_TIMEOUT:-$FM_UPSTREAM_LS_TIMEOUT_DEFAULT}
  fetch_timeout=${FM_UPSTREAM_FETCH_TIMEOUT:-$FM_UPSTREAM_FETCH_TIMEOUT_DEFAULT}
  subject_limit=${FM_UPSTREAM_SUBJECT_LIMIT:-$FM_UPSTREAM_SUBJECT_LIMIT_DEFAULT}

  case "$ls_timeout" in *[!0-9]* | '') ls_timeout=$FM_UPSTREAM_LS_TIMEOUT_DEFAULT ;; esac
  case "$fetch_timeout" in *[!0-9]* | '') fetch_timeout=$FM_UPSTREAM_FETCH_TIMEOUT_DEFAULT ;; esac
  case "$subject_limit" in *[!0-9]* | '' | 0) subject_limit=$FM_UPSTREAM_SUBJECT_LIMIT_DEFAULT ;; esac

  [ -n "$dir" ] || return 0
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  if [ -n "$home" ] && [ -f "$home/.fm-secondmate-home" ]; then
    return 0
  fi

  git -C "$dir" remote get-url "$remote" >/dev/null 2>&1 || return 0

  origin_url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  upstream_url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null || true)
  [ -n "$upstream_url" ] || return 0
  if [ -n "$origin_url" ] \
    && [ "$(fm_upstream_normalize_url "$origin_url")" = "$(fm_upstream_normalize_url "$upstream_url")" ]; then
    return 0
  fi

  branch=$(fm_upstream_branch "$dir" "$remote" 2>/dev/null || true)
  [ -n "$branch" ] || branch=main
  track_ref="refs/remotes/$remote/$branch"

  tip=$(
    GIT_TERMINAL_PROMPT=0 \
      fm_upstream_run_timeout "$ls_timeout" \
      git -C "$dir" ls-remote --refs "$remote" "refs/heads/$branch" 2>/dev/null \
      | awk 'NR==1 { print $1; exit }'
  ) || true
  [ -n "$tip" ] || return 0

  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
  [ -n "$head" ] || return 0
  [ "$tip" != "$head" ] || return 0

  if git -C "$dir" cat-file -e "$tip^{commit}" 2>/dev/null; then
    tip_ok=1
  else
    # Bounded fetch into the remote-tracking ref only - never merges, never
    # touches local branches or projects/.
    if GIT_TERMINAL_PROMPT=0 \
      fm_upstream_run_timeout "$fetch_timeout" \
      git -C "$dir" fetch --no-tags --quiet "$remote" \
      "+refs/heads/$branch:$track_ref" >/dev/null 2>&1; then
      if git -C "$dir" cat-file -e "$tip^{commit}" 2>/dev/null; then
        tip_ok=1
      fi
    fi
  fi
  [ "$tip_ok" -eq 1 ] || return 0

  # Upstream tip already contained in HEAD means we are ahead or equal, not behind.
  if git -C "$dir" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then
    return 0
  fi

  count=$(git -C "$dir" rev-list --count "$head..$tip" 2>/dev/null || true)
  case "$count" in
    '' | *[!0-9]*) return 0 ;;
    0) return 0 ;;
  esac

  subjects=$(fm_upstream_subjects "$dir" "$head" "$tip" "$subject_limit")
  url_disp=$(fm_upstream_normalize_url "$upstream_url")
  if [ -n "$subjects" ]; then
    printf 'UPSTREAM: %s commits behind %s/%s (%s) - %s\n' \
      "$count" "$remote" "$branch" "$url_disp" "$subjects"
  else
    printf 'UPSTREAM: %s commits behind %s/%s (%s)\n' \
      "$count" "$remote" "$branch" "$url_disp"
  fi
  return 0
}
