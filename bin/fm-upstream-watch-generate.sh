#!/usr/bin/env bash
# Generate one upstream-watch report from already-present git objects.
#
# Usage:
#   fm-upstream-watch-generate.sh --git-dir DIR --base REF --tip REF \
#     --ledger FILE [--watermark SHA] [--fork-root DIR] [--upstream-url URL]
#
# This generator is deliberately separate from delivery and NEVER fetches,
# updates a ref, writes a watermark, or ports work.
# bin/fm-upstream-watch.sh owns the local private delivery and fetches only into
# its standalone bare cache under data/upstream-watch/cache.git, which shares no
# object store or refs with the live checkout.
# A future private-repo GitHub Action can fetch its own clone, call this script
# with refs available there, and publish stdout instead of changing generation.
#
# stdout is the complete report.
# A quiet interval is exactly one line: no heading or repeated backlog.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-upstream-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-upstream-lib.sh"

GIT_DIR=
BASE=
TIP=
LEDGER=
WATERMARK=
FORK_ROOT=
UPSTREAM_URL=
SCAN_LIMIT=${FM_UPSTREAM_LEDGER_SCAN_LIMIT:-$FM_UPSTREAM_LEDGER_SCAN_LIMIT_DEFAULT}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-upstream-watch-generate: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --git-dir) [ "$#" -ge 2 ] || die '--git-dir requires a value'; GIT_DIR=$2; shift 2 ;;
    --base) [ "$#" -ge 2 ] || die '--base requires a value'; BASE=$2; shift 2 ;;
    --tip) [ "$#" -ge 2 ] || die '--tip requires a value'; TIP=$2; shift 2 ;;
    --ledger) [ "$#" -ge 2 ] || die '--ledger requires a value'; LEDGER=$2; shift 2 ;;
    --watermark) [ "$#" -ge 2 ] || die '--watermark requires a value'; WATERMARK=$2; shift 2 ;;
    --fork-root) [ "$#" -ge 2 ] || die '--fork-root requires a value'; FORK_ROOT=$2; shift 2 ;;
    --upstream-url) [ "$#" -ge 2 ] || die '--upstream-url requires a value'; UPSTREAM_URL=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$GIT_DIR" ] || die '--git-dir is required'
[ -n "$BASE" ] || die '--base is required'
[ -n "$TIP" ] || die '--tip is required'
[ -n "$LEDGER" ] || die '--ledger is required'
git -C "$GIT_DIR" rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || die "base does not resolve: $BASE"
git -C "$GIT_DIR" rev-parse --verify "$TIP^{commit}" >/dev/null 2>&1 || die "tip does not resolve: $TIP"
case "$SCAN_LIMIT" in ''|*[!0-9]*|0) SCAN_LIMIT=$FM_UPSTREAM_LEDGER_SCAN_LIMIT_DEFAULT ;; esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-upstream-watch-generate.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
ALL="$TMP/all.tsv"
NEW="$TMP/new.tsv"
SURFACES="$TMP/surfaces.tsv"
FORK_PATHS="$TMP/fork-paths"
: >"$SURFACES"
: >"$FORK_PATHS"

fm_upstream_undelivered "$GIT_DIR" "$BASE" "$TIP" "$LEDGER" "$SCAN_LIMIT" >"$ALL"
RAW=$(git -C "$GIT_DIR" rev-list --count "$BASE..$TIP")
OUTSTANDING=$(grep -c '[^[:space:]]' "$ALL" || true)

if [ -z "$WATERMARK" ]; then
  cp "$ALL" "$NEW"
elif git -C "$GIT_DIR" cat-file -e "$WATERMARK^{commit}" 2>/dev/null \
  && git -C "$GIT_DIR" merge-base --is-ancestor "$WATERMARK" "$TIP" 2>/dev/null; then
  awk -F '\t' 'NR==FNR { wanted[$1]=1; next } wanted[$1]' \
    <(git -C "$GIT_DIR" rev-list "$WATERMARK..$TIP") "$ALL" >"$NEW"
else
  # A rewritten or pruned watermark must not hide work.
  # Re-reporting the current outstanding set is safer than silently skipping it.
  cp "$ALL" "$NEW"
fi
NEW_COUNT=$(grep -c '[^[:space:]]' "$NEW" || true)

if [ "$NEW_COUNT" -eq 0 ]; then
  printf 'Upstream watch: nothing to do - no new outstanding upstream work since the last report.\n'
  exit 0
fi

# Prefer the declared fork-surface owner when it is present.
# Supplement it with the actual fork delta so shared files modified by a fork
# capability still collide even when they are not an `owns` path.
if [ -n "$FORK_ROOT" ] && [ -x "$FORK_ROOT/bin/fm-fork-surface.sh" ] \
  && [ -f "$FORK_ROOT/fork-surface.conf" ]; then
  FM_FORK_SURFACE_MANIFEST="$FORK_ROOT/fork-surface.conf" \
    "$FORK_ROOT/bin/fm-fork-surface.sh" paths >"$SURFACES" 2>/dev/null || : >"$SURFACES"
fi
MERGE_BASE=$(git -C "$GIT_DIR" merge-base "$BASE" "$TIP" 2>/dev/null || true)
if [ -n "$MERGE_BASE" ]; then
  git -C "$GIT_DIR" diff --name-only "$MERGE_BASE..$BASE" 2>/dev/null \
    | awk 'NF && !seen[$0]++' >"$FORK_PATHS"
fi

plain_gain() {
  local subject=$1 text rest first
  text=$(printf '%s\n' "$subject" \
    | sed -E 's/[[:space:]]+\(#[0-9]+\)$//; s/^[[:alnum:]_-]+(\([^)]*\))?!?:[[:space:]]*//')
  text=${text%.}
  first=$(printf '%s\n' "$text" | awk '{ print tolower($1) }')
  rest=${text#* }
  [ "$rest" = "$text" ] && rest=
  if [ -z "$rest" ]; then
    printf 'Lets us %s.\n' "$text"
    return 0
  fi
  case "$first" in
    prevent|prevents) printf 'Stops %s.\n' "$rest" ;;
    preserve|preserves) printf 'Keeps %s.\n' "$rest" ;;
    avoid|avoids) printf 'Avoids %s.\n' "$rest" ;;
    ensure|ensures) printf 'Ensures %s.\n' "$rest" ;;
    restore|restores) printf 'Restores %s.\n' "$rest" ;;
    define|defines) printf 'Clarifies %s.\n' "$rest" ;;
    support|supports) printf 'Adds support for %s.\n' "$rest" ;;
    add|adds) printf 'Adds %s.\n' "$rest" ;;
    remove|removes) printf 'Removes %s.\n' "$rest" ;;
    replace|replaces) printf 'Lets us replace %s.\n' "$rest" ;;
    prioritize|prioritizes) printf 'Lets us prioritize %s.\n' "$rest" ;;
    fix|fixes) printf 'Fixes %s.\n' "$rest" ;;
    *) printf 'Lets us %s.\n' "$text" ;;
  esac
}

collision_for() {
  local sha=$1 status path sid spath key label collisions=0
  local detail="$TMP/collision.$sha"
  local changed="$TMP/changed.$sha"
  : >"$detail"
  git -C "$GIT_DIR" diff-tree --root --no-renames --no-commit-id --name-status -r "$sha" 2>/dev/null >"$changed"
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    while IFS=$'\t' read -r sid spath; do
      [ -n "$sid" ] && [ -n "$spath" ] || continue
      case "$path" in
        "$spath"|"$spath"/*)
          key="$status|$path|$sid"
          grep -Fqx "$key" "$detail" 2>/dev/null || printf '%s\n' "$key" >>"$detail"
          ;;
      esac
    done <"$SURFACES"
    if grep -Fqx "$path" "$FORK_PATHS" 2>/dev/null; then
      key="$status|$path|fork changes"
      grep -Fqx "$key" "$detail" 2>/dev/null || printf '%s\n' "$key" >>"$detail"
    fi
  done <"$changed"

  collisions=$(wc -l <"$detail" | tr -d ' ')
  if [ "$collisions" -eq 0 ]; then
    printf 'none detected against declared or changed fork surfaces'
    return 0
  fi
  label=
  while IFS='|' read -r status path sid; do
    if [ -n "$label" ]; then
      label="$label; "
    fi
    if [ "$status" = D ] && [ "$sid" != 'fork changes' ]; then
      label="${label}deletes $sid at $path"
    elif [ "$sid" = 'fork changes' ]; then
      label="${label}overlaps fork changes at $path"
    else
      label="${label}touches $sid at $path"
    fi
  done < <(head -n 4 "$detail")
  if [ "$collisions" -gt 4 ]; then
    label="$label; and $((collisions - 4)) more"
  fi
  printf '%s - preserve the fork behavior during any port' "$label"
}

DATE=${FM_UPSTREAM_WATCH_DATE:-$(date -u +%Y-%m-%d)}
UPSTREAM_URL=${UPSTREAM_URL%.git}
TICK=$(printf '\140')
printf '# Upstream watch - %s\n\n' "$DATE"
printf 'Outstanding: %s of %s raw upstream commits remain after the ported-ledger derivation.\n' "$OUTSTANDING" "$RAW"
printf 'New since the previous report: %s.\n\n' "$NEW_COUNT"

while IFS=$'\t' read -r sha subject; do
  [ -n "$sha" ] || continue
  short=${sha:0:12}
  gain=$(plain_gain "$subject")
  collision=$(collision_for "$sha")
  printf -- '- %s%s%s - Gain: %s\n' "$TICK" "$short" "$TICK" "$gain"
  printf '  - Collision: %s.\n' "$collision"
  if [ -n "$UPSTREAM_URL" ]; then
    printf '  - Source: %s/commit/%s\n' "$UPSTREAM_URL" "$sha"
  else
    printf '  - Source: commit %s%s%s\n' "$TICK" "$sha" "$TICK"
  fi
done <"$NEW"

printf '\nThis is a decision report only. Nothing was ported, merged, rebased, or changed.\n'
