# shellcheck shell=bash
# Read-only upstream-drift detection for a forked firstmate home.
# Usage: . bin/fm-upstream-lib.sh
#
# fm_upstream_check prints at most one actionable bootstrap line when the
# configured upstream remote has commits this home lacks AND the ported ledger
# below cannot account for them:
#   UPSTREAM: <N> commits behind <remote>/<branch> (<url>) - <subject>; ...
#   UPSTREAM: <N> commits behind <remote>/<branch> (<url>) - <R> upstream
#             commits, <D> already delivered here - <subject>; ...
# The second form appears whenever the ledger accounted for at least one commit.
# Silent (no output) when there is no upstream remote, origin and upstream are
# the same URL (not a fork), the home is a secondmate, the network is down, the
# tip is already reachable and current, every unmerged upstream commit is
# already delivered here, or any probe fails.
#
# Detection never merges, never force-updates local branches, and never touches
# projects/. The only git write is a bounded fetch that updates
# refs/remotes/<remote>/<branch> so commit subjects can be listed.
# Mechanics and defaults below are owned by this file; bin/fm-bootstrap.sh only
# sources and calls it.
#
# ---------------------------------------------------------------------------
# The ported ledger: why the reported number can fall
# ---------------------------------------------------------------------------
# A fork ports upstream work by hand or by cherry-pick, so the ported commit
# gets a NEW sha and upstream's original stays unreachable from HEAD forever.
# A raw `rev-list --count HEAD..upstream/main` therefore counts delivered work
# as outstanding, can only ever rise, and trains the reader to ignore it.
#
# The ledger classifies each unmerged upstream commit as already-delivered or
# genuinely outstanding, and only the outstanding ones are counted and listed.
# It is DERIVED from the fork's own commit history, never a stored number, so
# it self-corrects the moment a batch lands. Three classes, first match wins:
#
#   1. Explicit ledger override (docs/upstream-ported-ledger.txt, or
#      FM_UPSTREAM_LEDGER). One `<upstream-sha> <ported|not-ported> <evidence>`
#      record per line; `<upstream-sha>` may be abbreviated and matches by
#      prefix. This is the reviewable escape hatch for hand-integrations that
#      left no machine-readable reference, and for correcting a false positive
#      from class 2 or 3 with `not-ported`. An override always wins.
#   2. Subject reference. The upstream subject ends in `(#<pr>)` and that exact
#      subject line appears in the body of a fork-only commit message. Squash
#      merges preserve each ported commit's original subject, including its
#      upstream PR number, so this catches every batch landed as a PR.
#      Requiring the whole subject, not the bare `(#<pr>)` token, is what keeps
#      the fork's own PR numbers from colliding with upstream's.
#   3. Sha reference. The upstream commit's abbreviated sha appears in a
#      fork-only commit message - `(cherry picked from commit <sha>)`,
#      `Cherry-picked from upstream <sha>`, `(upstream <sha>)`, and the like.
#      This catches hand-ports that reworded or truncated the subject.
#
# Patch-id equivalence (`git cherry`) is deliberately NOT a class: measured
# against this fork it identifies zero commits, because every port lands on a
# diverged tree and no patch-id survives. Adding it would be an untested path
# backed by no evidence.
#
# The fork-only corpus scanned is `<upstream-tip>..HEAD`, bounded to
# FM_UPSTREAM_LEDGER_SCAN_LIMIT commits so a long-lived fork stays cheap.
# A fork with no ledger file and no port references simply reports the raw
# count, exactly as before.

# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_UPSTREAM_REMOTE_DEFAULT="${FM_UPSTREAM_REMOTE_DEFAULT:-upstream}"
FM_UPSTREAM_LS_TIMEOUT_DEFAULT="${FM_UPSTREAM_LS_TIMEOUT_DEFAULT:-3}"
FM_UPSTREAM_FETCH_TIMEOUT_DEFAULT="${FM_UPSTREAM_FETCH_TIMEOUT_DEFAULT:-5}"
FM_UPSTREAM_SUBJECT_LIMIT_DEFAULT="${FM_UPSTREAM_SUBJECT_LIMIT_DEFAULT:-8}"
FM_UPSTREAM_LEDGER_DEFAULT="${FM_UPSTREAM_LEDGER_DEFAULT:-docs/upstream-ported-ledger.txt}"
FM_UPSTREAM_LEDGER_SCAN_LIMIT_DEFAULT="${FM_UPSTREAM_LEDGER_SCAN_LIMIT_DEFAULT:-500}"
# Separates the fork-message corpus from the upstream commit list on one pipe.
FM_UPSTREAM_LEDGER_SPLIT='<<<FM_UPSTREAM_LEDGER_SPLIT>>>'

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

# Join the first <limit> subjects from "<sha>\t<subject>" lines read on stdin.
fm_upstream_subjects() {
  local limit=$1
  local sha subject clipped out="" n=0
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] && [ -n "$subject" ] || continue
    clipped=$(fm_upstream_clip "$subject" 72)
    if [ -z "$out" ]; then
      out=$clipped
    else
      out="$out; $clipped"
    fi
    n=$((n + 1))
    [ "$n" -lt "$limit" ] || break
  done
  printf '%s\n' "$out"
}

# Print "<sha>\t<subject>", newest first, for every commit in <base>..<tip> that
# the ported ledger does NOT class as already delivered in <base>.
# <ledger> may be empty or point at a missing file; <scan> bounds the fork-only
# message corpus. See this file's header for the three evidence classes.
fm_upstream_undelivered() {
  local dir=$1 base=$2 tip=$3 ledger=$4 scan=$5
  {
    git -C "$dir" log --format='%b' --no-decorate -n "$scan" "$tip..$base" 2>/dev/null || true
    printf '%s\n' "$FM_UPSTREAM_LEDGER_SPLIT"
    git -C "$dir" log --format='%H%x09%s' --no-decorate "$base..$tip" 2>/dev/null || true
  } | awk -v ledger="$ledger" -v split_marker="$FM_UPSTREAM_LEDGER_SPLIT" '
    # Class 2: the upstream subject, PR number and all, quoted in a fork body.
    function subject_ref(subj,   i) {
      if (subj !~ /\(#[0-9]+\)$/) return 0
      for (i = 1; i <= nc; i++) if (index(corpus[i], subj) > 0) return 1
      return 0
    }
    # Class 3: the upstream abbreviated sha quoted in a fork message.
    function sha_ref(short,   i) {
      for (i = 1; i <= nc; i++) if (index(lowered[i], short) > 0) return 1
      return 0
    }
    BEGIN {
      phase = 1
      nc = 0
      while (ledger != "" && (getline line < ledger) > 0) {
        gsub(/^[ \t]+/, "", line)
        gsub(/[ \t]+$/, "", line)
        if (line == "" || substr(line, 1, 1) == "#") continue
        if (split(line, field, /[ \t]+/) < 2) continue
        key = tolower(field[1])
        verdict = tolower(field[2])
        if (verdict == "ported") override[key] = 1
        else if (verdict == "not-ported") override[key] = 0
      }
      if (ledger != "") close(ledger)
    }
    $0 == split_marker { phase = 2; next }
    phase == 1 {
      if ($0 ~ /[^ \t]/) { nc++; corpus[nc] = $0; lowered[nc] = tolower($0) }
      next
    }
    {
      tab = index($0, "\t")
      if (tab == 0) next
      sha = tolower(substr($0, 1, tab - 1))
      subject = substr($0, tab + 1)
      decided = 0
      delivered = 0
      for (key in override) {
        if (index(sha, key) == 1) { decided = 1; delivered = override[key]; break }
      }
      if (!decided && (subject_ref(subject) || sha_ref(substr(sha, 1, 7)))) delivered = 1
      if (!delivered) print $0
    }
  '
}

# Detect upstream drift for the firstmate repo at <dir>.
# Optional <home> enables the secondmate-home silence rule when that home carries
# a .fm-secondmate-home marker. Always exits 0; prints one line or nothing.
fm_upstream_check() {
  local dir=$1 home=${2:-} remote branch origin_url upstream_url tip head
  local track_ref raw count delivered subjects ls_timeout fetch_timeout
  local subject_limit url_disp ledger scan_limit undelivered accounting
  local tip_ok=0

  remote=${FM_UPSTREAM_REMOTE:-$FM_UPSTREAM_REMOTE_DEFAULT}
  ls_timeout=${FM_UPSTREAM_LS_TIMEOUT:-$FM_UPSTREAM_LS_TIMEOUT_DEFAULT}
  fetch_timeout=${FM_UPSTREAM_FETCH_TIMEOUT:-$FM_UPSTREAM_FETCH_TIMEOUT_DEFAULT}
  subject_limit=${FM_UPSTREAM_SUBJECT_LIMIT:-$FM_UPSTREAM_SUBJECT_LIMIT_DEFAULT}
  scan_limit=${FM_UPSTREAM_LEDGER_SCAN_LIMIT:-$FM_UPSTREAM_LEDGER_SCAN_LIMIT_DEFAULT}

  case "$ls_timeout" in *[!0-9]* | '') ls_timeout=$FM_UPSTREAM_LS_TIMEOUT_DEFAULT ;; esac
  case "$fetch_timeout" in *[!0-9]* | '') fetch_timeout=$FM_UPSTREAM_FETCH_TIMEOUT_DEFAULT ;; esac
  case "$subject_limit" in *[!0-9]* | '' | 0) subject_limit=$FM_UPSTREAM_SUBJECT_LIMIT_DEFAULT ;; esac
  case "$scan_limit" in *[!0-9]* | '' | 0) scan_limit=$FM_UPSTREAM_LEDGER_SCAN_LIMIT_DEFAULT ;; esac

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
      fm_run_timeout "$ls_timeout" \
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
      fm_run_timeout "$fetch_timeout" \
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

  raw=$(git -C "$dir" rev-list --count "$head..$tip" 2>/dev/null || true)
  case "$raw" in
    '' | *[!0-9]*) return 0 ;;
    0) return 0 ;;
  esac

  # Subtract the derived ported ledger so the reported figure is what is
  # actually still outstanding, and falls as batches land.
  ledger=${FM_UPSTREAM_LEDGER-$dir/$FM_UPSTREAM_LEDGER_DEFAULT}
  [ -z "$ledger" ] || [ -f "$ledger" ] || ledger=
  undelivered=$(fm_upstream_undelivered "$dir" "$head" "$tip" "$ledger" "$scan_limit")
  count=$(printf '%s\n' "$undelivered" | grep -c '[^[:space:]]' || true)
  case "$count" in
    '' | *[!0-9]*) count=$raw ;;
  esac
  # Everything upstream has is already delivered here: nothing actionable.
  [ "$count" -gt 0 ] || return 0
  delivered=$((raw - count))

  subjects=$(printf '%s\n' "$undelivered" | fm_upstream_subjects "$subject_limit")
  url_disp=$(fm_upstream_normalize_url "$upstream_url")
  accounting=
  if [ "$delivered" -gt 0 ]; then
    accounting=$(printf '%s upstream commits, %s already delivered here' "$raw" "$delivered")
  fi
  if [ -n "$accounting" ] && [ -n "$subjects" ]; then
    printf 'UPSTREAM: %s commits behind %s/%s (%s) - %s - %s\n' \
      "$count" "$remote" "$branch" "$url_disp" "$accounting" "$subjects"
  elif [ -n "$accounting" ]; then
    printf 'UPSTREAM: %s commits behind %s/%s (%s) - %s\n' \
      "$count" "$remote" "$branch" "$url_disp" "$accounting"
  elif [ -n "$subjects" ]; then
    printf 'UPSTREAM: %s commits behind %s/%s (%s) - %s\n' \
      "$count" "$remote" "$branch" "$url_disp" "$subjects"
  else
    printf 'UPSTREAM: %s commits behind %s/%s (%s)\n' \
      "$count" "$remote" "$branch" "$url_disp"
  fi
  return 0
}
