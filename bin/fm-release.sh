#!/usr/bin/env bash
# fm-release.sh - cut Starship's next named release (maintainer only).
#
# A release is a tag on origin's default branch named starship-YYYY.MM, or
# starship-YYYY.MM.N for a fix release in a month that already has one
# (bin/fm-release-lib.sh owns the name and ordering rules). A home on the
# release channel (docs/configuration.md "Update channel") moves to the newest
# one on its next "update starship". The usual moment to cut one is right after
# the month's reviewed upstream catch-up has landed on a green default branch.
#
# Each step refuses, naming what is missing, before anything is published:
#   1. This home's role (config/firstmate-role, bin/fm-role-lib.sh) must be
#      maintainer, and its scope must name the repository this code root's
#      origin points at.
#   2. Fetch origin and its release tags. The release commit is the tip of
#      origin's default branch, and it must not already carry a release.
#   3. Name: starship-YYYY.MM for the current UTC month, or the next
#      starship-YYYY.MM.N when that month already has a release.
#   4. Notes: the "## <name>" section of CHANGELOG.md at the release commit,
#      which must exist and hold text. The CHANGELOG.md preamble owns that
#      convention, so the notes are reviewed in a pull request before the cut.
#   5. Checks: every check run and commit status the forge reports on the
#      release commit must have finished green (success, neutral, or skipped),
#      and at least one must exist. That is stricter than the branch's required
#      checks alone, so a release never lands on a red or still-running main.
#   6. gh release create <name> --target <commit> --title <name>
#      --notes-file <notes>, which creates the tag on the forge. --dry-run does
#      steps 1-5 and prints this command instead of running it.
#
# Usage: fm-release.sh [--dry-run]
# Environment: FM_HOME, FM_ROOT_OVERRIDE, FM_CONFIG_OVERRIDE, and FM_RELEASE_MONTH
# (YYYY.MM, overriding the current UTC month).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-release-lib.sh
. "$SCRIPT_DIR/fm-release-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"

usage() { echo "usage: fm-release.sh [--dry-run]" >&2; }
refuse() { echo "fm-release: refusing: $1" >&2; exit 1; }

dry_run=no
case "${1:-}" in
  '') ;;
  --dry-run) dry_run=yes ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
[ $# -le 1 ] || { usage; exit 2; }
command -v jq >/dev/null 2>&1 || refuse "jq is not installed"
command -v gh >/dev/null 2>&1 || refuse "gh is not installed"

# 1. Maintainer of exactly this origin.
fm_role_resolve "$FM_HOME" "$CONFIG_DIR"
[ "$FM_ROLE" = maintainer ] \
  || refuse "cutting a release needs this home's maintainer role (config/firstmate-role)${FM_ROLE_DIAG:+: $FM_ROLE_DIAG}"
origin_url=$(git -C "$FM_ROOT" config --get remote.origin.url 2>/dev/null) || refuse "no origin remote"
identity=$(fm_role_remote_identity "$origin_url" "$FM_ROOT" nolocal)
[ -n "$identity" ] && [ "$identity" = "$(fm_role_scope_norm "$FM_ROLE_SCOPE")" ] \
  || refuse "origin ($origin_url) is not the maintainer scope $FM_ROLE_SCOPE"
host=${identity%%/*}
repo=${identity#*/}

# 2. Release commit.
git -C "$FM_ROOT" fetch --quiet origin 2>/dev/null || refuse "fetch from origin failed"
fm_release_fetch_tags "$FM_ROOT" || refuse "release tags could not be fetched without moving a local tag"
default=$(git -C "$FM_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
default=${default#origin/}
[ -n "$default" ] || default=main
sha=$(git -C "$FM_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$default^{commit}") \
  || refuse "origin/$default does not exist"
if existing=$(fm_release_at "$FM_ROOT" "$sha" "origin/$default"); then
  refuse "origin/$default ($sha) is already release $existing"
fi

# 3. Name.
month=${FM_RELEASE_MONTH:-$(date -u +%Y.%m)}
fm_release_name_valid "starship-$month" || refuse "FM_RELEASE_MONTH must be YYYY.MM"
name="starship-$month"
if git -C "$FM_ROOT" rev-parse --verify --quiet "refs/tags/$name" >/dev/null; then
  n=1
  while git -C "$FM_ROOT" rev-parse --verify --quiet "refs/tags/$name.$n" >/dev/null; do
    n=$((n + 1))
  done
  name="$name.$n"
fi

# 4. Notes.
work=$(mktemp -d "${TMPDIR:-/tmp}/fm-release.XXXXXX")
trap 'rm -rf "$work"' EXIT
notes_file="$work/notes.md"
git -C "$FM_ROOT" show "$sha:CHANGELOG.md" 2>/dev/null \
  | awk -v head="## $name" '
      $0 == head { found = 1; next }
      found && /^## / { exit }
      found { lines[++n] = $0 }
      END {
        first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
        last = n; while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
        for (i = first; i <= last; i++) print lines[i]
      }' > "$notes_file"
[ -s "$notes_file" ] || refuse "CHANGELOG.md at $sha has no notes under \"## $name\""

# 5. Checks on the release commit. A paginated read prints one JSON document per
# page, so both reads are slurped as document lists.
gh api --hostname "$host" --paginate "repos/$repo/commits/$sha/check-runs?per_page=100" \
  > "$work/runs.json" 2>/dev/null || refuse "could not read the check runs on $sha"
gh api --hostname "$host" "repos/$repo/commits/$sha/status" \
  > "$work/status.json" 2>/dev/null || refuse "could not read the commit statuses on $sha"
verdict=$(jq -rn --slurpfile runs "$work/runs.json" --slurpfile status "$work/status.json" '
  def must(f): if f then . else error("unreadable") end;
  ($runs | must(length > 0) | map(.check_runs | must(type == "array")) | add) as $r
  | ($status | must(length == 1) | .[0].statuses // [] | must(type == "array")) as $st
  | ([$r[] | select(.status != "completed"
        or ((.conclusion // "") | IN("success", "neutral", "skipped") | not)) | .name]
     + [$st[] | select(.state != "success") | .context]) as $bad
  | if ($r | length) + ($st | length) == 0 then "none"
    elif ($bad | length) > 0 then "bad " + ($bad | unique | join(", "))
    else "green" end' 2>/dev/null) || refuse "could not read the checks on $sha"
case "$verdict" in
  green) ;;
  none) refuse "no checks have reported on $sha" ;;
  *) refuse "checks on $sha are not all green: ${verdict#bad }" ;;
esac

# 6. Publish.
if [ "$dry_run" = yes ]; then
  echo "would run: gh release create $name --repo $identity --target $sha --title $name --notes-file <the $name section of CHANGELOG.md>"
  echo "notes:"
  cat "$notes_file"
  exit 0
fi
gh release create "$name" --repo "$identity" --target "$sha" --title "$name" --notes-file "$notes_file"
echo "released: $name at $sha"
