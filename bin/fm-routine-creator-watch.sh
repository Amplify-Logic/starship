#!/usr/bin/env bash
# fm-routine-creator-watch.sh - the creator-repo watch that a scheduled Claude
# cloud routine runs while the laptop is closed (docs/cloud-routines.md).
#
# Usage:
#   fm-routine-creator-watch.sh run       build the digest and publish it
#   fm-routine-creator-watch.sh --help
#
# It reads public git data for a fixed list of public repositories and writes
# one rolling markdown digest: each repository's new tags on default-branch
# commits and its commits on the default branch inside the reporting window. A
# release tag on a commit that is not on the default branch is not listed; the
# laptop creator watch, which keeps running alongside, covers those. `run`
# publishes that digest as the
# single file creator-watch.md on the main branch of the dedicated public
# reports repository Amplify-Logic/firstmate-routine-reports, replacing the
# previous copy with one new commit, so that branch's history is the routine's
# audit log. The firstmate clone the routine runs this from is only read: the
# commit is built in a temporary repository and nothing is ever pushed to
# firstmate.
#
# Reads use plain git over https because a cloud session's GitHub proxy binds
# the REST API and github.com pages to the session's own configured repository,
# while public git reads of other repositories pass. Each repository costs one
# `git ls-remote --tags` and one bare, tree-less, depth-bounded clone of the
# default branch into a temporary directory; nothing is checked out.
#
# The whole job is this script so the routine's model never has to read
# third-party text: tag names and commit subjects from other people's
# repositories go into the digest file and nowhere else, and stdout carries
# only one summary line built from counts.
#
# What it can touch, and nothing more:
#   - Public git reads of the listed repositories.
#   - The main branch of the reports repository: one non-forced push of one
#     commit whose tree is the previous tree with creator-watch.md replaced. It
#     never pushes any other branch or repository, and never rewrites history.
#
# Bounds: each git read is capped at FM_ROUTINE_READ_SECS (default 45) and the
# whole sweep at FM_ROUTINE_BUDGET_SECS (default 240); repositories left unread
# are named in the digest. Each clone holds at most FM_ROUTINE_DEPTH (default
# 1000) commits, and a window that fills it is reported as "1000+". The digest
# is capped at FM_ROUTINE_MAX_BYTES (default 65536) and each line at 300
# characters. When every read fails, nothing is published and the exit status
# is 1, so a broken run never looks like a quiet week.
#
# Kill switch in the reports repository itself: when its main tree holds a file
# named PAUSED, `run` publishes nothing and exits 0. The primary kill switch is
# pausing or deleting the routine at claude.ai/code/routines.
#
# The reporting window starts one day before the previous digest's window ended
# (read from its trailing marker), capped at 31 days back, and defaults to 8
# days so a late weekly run still overlaps the last one. The day of overlap
# catches a tag added after a run to a commit from just before it, and a commit
# pushed after the run it predates; items in that day can appear in two digests.
#
# Test seams: FM_ROUTINE_NOW (epoch seconds), FM_ROUTINE_REMOTE (default the
# reports repository's https URL), FM_ROUTINE_URL_BASE (default
# https://github.com/), and FM_ROUTINE_REPOS (a whitespace-separated
# replacement repository list).
set -u
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

ROUTINE=creator-watch
BRANCH=main
FILE="$ROUTINE.md"
MARKER_PREFIX="<!-- fm-routine-report: $ROUTINE v1 window-end-epoch="
REMOTE=${FM_ROUTINE_REMOTE:-https://github.com/Amplify-Logic/firstmate-routine-reports.git}
URL_BASE=${FM_ROUTINE_URL_BASE:-https://github.com/}
READ_SECS=${FM_ROUTINE_READ_SECS:-45}
BUDGET_SECS=${FM_ROUTINE_BUDGET_SECS:-240}
DEPTH=${FM_ROUTINE_DEPTH:-1000}
MAX_BYTES=${FM_ROUTINE_MAX_BYTES:-65536}
LINE_CHARS=300
DEFAULT_WINDOW=$(( 8 * 86400 ))
OVERLAP=86400
MAX_WINDOW=$(( 31 * 86400 ))

# The same public repositories as the laptop's creator watch. Only public
# repositories may ever be listed here: the routine runs in Anthropic's cloud.
REPOS="
kunchenguid/no-mistakes
kunchenguid/treehouse
kunchenguid/tasks-axi
kunchenguid/quota-axi
kunchenguid/lavish-axi
kunchenguid/gh-axi
kunchenguid/chrome-devtools-axi
kunchenguid/axi
kunchenguid/gnhf
kunchenguid/backpass
kunchenguid/vision
kunchenguid/grok-ship
kunchenguid/dotfiles
kunchenguid/pi-launcher
herdrdev/herdr
omacom/omarchy
anthropics/claude-code
openai/codex
earendil-works/pi
"
REPOS=${FM_ROUTINE_REPOS:-$REPOS}

usage() {
  cat <<'EOF'
Usage:
  fm-routine-creator-watch.sh run       build the digest and publish it to the reports repository
  fm-routine-creator-watch.sh --help    print this help

Run by the scheduled creator-watch Claude cloud routine; see docs/cloud-routines.md.
EOF
}

whole_number() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

for setting in READ_SECS BUDGET_SECS DEPTH MAX_BYTES; do
  if ! whole_number "${!setting}" || [ "${!setting}" -lt 1 ]; then
    printf 'fm-routine-creator-watch: %s must be a positive whole number\n' "$setting" >&2
    exit 2
  fi
done

now_epoch() {
  if [ -n "${FM_ROUTINE_NOW:-}" ]; then
    printf '%s\n' "$FM_ROUTINE_NOW"
  else
    date +%s
  fi
}

# GNU date takes -d @N and BSD date takes -r N; the routine runs on Linux and
# the tests run on both.
iso_from_epoch() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# Third-party text is data: drop control characters and cap the length of
# every line.
clean_lines() {
  tr -d '\000-\010\013-\037\177' | tr '\t' ' ' | cut -c1-200
}

NOW=$(now_epoch)
whole_number "$NOW" || { echo "fm-routine-creator-watch: FM_ROUTINE_NOW must be epoch seconds" >&2; exit 2; }
START=$(date +%s)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-routine-creator-watch.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT
REPORTS="$WORK/reports.git"
git init --quiet --bare "$REPORTS" || exit 1

PARENT=
PREVIOUS_END=

# Find the previous digest. ls-remote exits 2 when the branch does not exist yet,
# which is the first run into the empty reports repository; any other failure
# is a real error.
locate_parent() {
  local rc marker
  fm_run_timed "$READ_SECS" git ls-remote --exit-code "$REMOTE" "refs/heads/$BRANCH" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) echo "fm-routine-creator-watch: could not read the $BRANCH branch of $REMOTE" >&2; return 1 ;;
  esac
  fm_run_timed "$READ_SECS" git -C "$REPORTS" fetch --quiet --no-tags "$REMOTE" "+refs/heads/$BRANCH:refs/heads/$BRANCH" >/dev/null 2>&1 \
    || { echo "fm-routine-creator-watch: could not fetch the $BRANCH branch of $REMOTE" >&2; return 1; }
  PARENT=$(git -C "$REPORTS" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}") || return 1
  marker=$(git -C "$REPORTS" cat-file -p "$PARENT:$FILE" 2>/dev/null | grep -F "$MARKER_PREFIX" | tail -1)
  marker=${marker#"$MARKER_PREFIX"}
  marker=${marker%% *}
  if whole_number "$marker"; then
    PREVIOUS_END=$marker
  fi
}

paused() {
  [ -n "$PARENT" ] && git -C "$REPORTS" cat-file -e "$PARENT:PAUSED" 2>/dev/null
}

window_start() {
  local since=$(( NOW - DEFAULT_WINDOW ))
  if [ -n "$PREVIOUS_END" ] && [ "$PREVIOUS_END" -lt "$NOW" ]; then
    since=$(( PREVIOUS_END - OVERLAP ))
  fi
  [ "$since" -ge $(( NOW - MAX_WINDOW )) ] || since=$(( NOW - MAX_WINDOW ))
  printf '%s\n' "$since"
}

READ_OK=0
READ_FAILED=
ITEMS=0

budget_left() {
  [ $(( $(date +%s) - START )) -lt "$BUDGET_SECS" ]
}

# read_repo <repo> <since-iso>: append this repository's items, or fail.
read_repo() {
  local repo=$1 since_iso=$2 url dir count shown tag sha subjects
  url="$URL_BASE$repo.git"
  dir="$WORK/clone"
  rm -rf -- "$dir"
  fm_run_timed "$READ_SECS" git ls-remote --tags "$url" > "$WORK/tags" 2>/dev/null || return 1
  fm_run_timed "$READ_SECS" git clone --quiet --bare --no-tags --filter=tree:0 \
    --depth="$DEPTH" "$url" "$dir" >/dev/null 2>&1 || return 1
  git -C "$dir" rev-list --since="$since_iso" HEAD > "$WORK/window" 2>/dev/null || return 1
  # A tag is new when the commit it names (peeled, for an annotated tag) is
  # inside the window. ls-remote lists an annotated tag twice, the second time
  # with ^{} and the commit, so the last line seen for a name wins.
  awk -F '\t' '{ name = $2; sub(/^refs\/tags\//, "", name); sub(/\^\{\}$/, "", name); peeled[name] = $1 }
    END { for (n in peeled) print peeled[n] "\t" n }' "$WORK/tags" | sort -k2 > "$WORK/tag-commits"
  while IFS=$'\t' read -r sha tag; do
    [ -n "$tag" ] || continue
    grep -qxF "$sha" "$WORK/window" || continue
    tag=$(printf '%s\n' "$tag" | clean_lines)
    printf -- '- [%s] TAG %s :: https://github.com/%s/releases/tag/%s\n' "$repo" "$tag" "$repo" "$tag" >> "$WORK/items"
    ITEMS=$(( ITEMS + 1 ))
  done < "$WORK/tag-commits"
  count=$(wc -l < "$WORK/window" | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    shown=$count
    [ "$count" -lt "$DEPTH" ] || shown="$DEPTH+"
    subjects=$(git -C "$dir" log -5 --since="$since_iso" --format=%s HEAD 2>/dev/null \
      | clean_lines | paste -sd ';' - | sed 's/;/; /g')
    printf -- '- [%s] %s new commit(s): %s\n' "$repo" "$shown" "$subjects" >> "$WORK/items"
    ITEMS=$(( ITEMS + 1 ))
  fi
  rm -rf -- "$dir"
}

sweep() {
  local since_iso=$1 repo
  : > "$WORK/items"
  for repo in $REPOS; do
    if budget_left && read_repo "$repo" "$since_iso"; then
      READ_OK=$(( READ_OK + 1 ))
    else
      READ_FAILED="$READ_FAILED $repo"
    fi
  done
}

# Assemble the digest, keeping whole lines while they fit under the byte cap.
build_digest() {
  local since_iso=$1 now_iso=$2 out=$3 footer
  footer="$MARKER_PREFIX$NOW -->"
  {
    printf '# Creator-repo activity\n\n'
    printf 'Window (UTC): %s to %s\n\n' "$since_iso" "$now_iso"
    printf 'Written by the creator-watch Claude cloud routine from public git data only.\n'
    printf 'This file is replaced on every run; the branch history keeps earlier digests.\n\n'
    if [ -s "$WORK/items" ]; then
      cat "$WORK/items"
    else
      printf 'No new tags or commits in this window.\n'
    fi
    if [ -n "$READ_FAILED" ]; then
      printf '\n'
      # shellcheck disable=SC2086 # one line per repository, so the line cap never hides one
      printf 'Could not read: %s\n' $READ_FAILED
    fi
  } | cut -c1-"$LINE_CHARS" > "$WORK/body"
  awk -v cap=$(( MAX_BYTES - ${#footer} - 64 )) '
    { len = length($0) + 1
      if (total + len > cap) { truncated = 1; exit }
      total += len; print }
    END { if (truncated) print "\n(Truncated at the routine report size cap.)" }
  ' "$WORK/body" > "$out"
  printf '\n%s\n' "$footer" >> "$out"
}

PUBLISHED=

publish() {
  local digest=$1 since_iso=$2 now_iso=$3 blob tree commit
  blob=$(git -C "$REPORTS" hash-object -w "$digest") || return 1
  if [ -n "$PARENT" ]; then
    tree=$( { git -C "$REPORTS" ls-tree "$PARENT" | awk -F '\t' -v f="$FILE" '$2 != f'
              printf '100644 blob %s\t%s\n' "$blob" "$FILE"; } | git -C "$REPORTS" mktree) || return 1
  else
    tree=$(printf '100644 blob %s\t%s\n' "$blob" "$FILE" | git -C "$REPORTS" mktree) || return 1
  fi
  commit=$(
    export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-firstmate routine}"
    export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-firstmate-routine@example.invalid}"
    export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
    export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"
    if [ -n "$PARENT" ]; then
      git -C "$REPORTS" commit-tree "$tree" -p "$PARENT" -m "$ROUTINE: digest for $since_iso to $now_iso"
    else
      git -C "$REPORTS" commit-tree "$tree" -m "$ROUTINE: digest for $since_iso to $now_iso"
    fi
  ) || return 1
  fm_run_timed "$READ_SECS" git -C "$REPORTS" push --quiet --no-verify "$REMOTE" "$commit:refs/heads/$BRANCH" >/dev/null 2>&1 || {
    echo "fm-routine-creator-watch: the push to $BRANCH of $REMOTE was refused or timed out" >&2
    return 1
  }
  PUBLISHED=$(git -C "$REPORTS" rev-parse --short "$commit")
}

action_run() {
  local since since_iso now_iso unread
  locate_parent || exit 1
  if paused; then
    printf '%s: paused by a PAUSED file on the reports %s; nothing published\n' "$ROUTINE" "$BRANCH"
    exit 0
  fi
  since=$(window_start)
  since_iso=$(iso_from_epoch "$since") || exit 1
  now_iso=$(iso_from_epoch "$NOW") || exit 1
  sweep "$since_iso"
  if [ "$READ_OK" -eq 0 ]; then
    printf '%s: every repository read failed; nothing published\n' "$ROUTINE" >&2
    exit 1
  fi
  build_digest "$since_iso" "$now_iso" "$WORK/digest"
  publish "$WORK/digest" "$since_iso" "$now_iso" || exit 1
  unread=$(printf '%s' "$READ_FAILED" | wc -w | tr -d ' ')
  printf '%s: published %s item(s) from %s repositories (%s unread) to the reports %s at %s\n' \
    "$ROUTINE" "$ITEMS" "$READ_OK" "$unread" "$BRANCH" "$PUBLISHED"
}

case "${1:-}" in
  run) action_run ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
