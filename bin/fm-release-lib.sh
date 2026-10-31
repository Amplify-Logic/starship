# shellcheck shell=bash
# fm-release-lib.sh - Starship's named releases and a home's update channel.
# Usage: . bin/fm-release-lib.sh   (sourced by bin/fm-ff-lib.sh and bin/fm-release.sh)
#
# A release is a git tag on the default branch named starship-YYYY.MM, or
# starship-YYYY.MM.N for the Nth fix release of that month, cut from a green
# default branch by bin/fm-release.sh. Release order is the numeric order of
# year, month, and fix number, never tag date or tag-creation order. A tag of
# that shape whose commit is not on the default branch is not a release.
#
# A home chooses what "update starship" (bin/fm-update.sh) follows in its own
# gitignored config/update-channel; docs/configuration.md "Update channel" owns
# the operator-facing schema. The file holds one value line (blank lines and
# full-line # comments ignored):
#   main               - the default; identical to an absent file
#   release            - follow the newest release
#   starship-YYYY.MM[.N] - stay on that one release (written by
#                        bin/fm-update.sh --step-back)
# Anything else is malformed and refuses rather than guessing a channel.
#
# Public functions:
#   fm_release_name_valid <name>            - 0 when <name> is a release name
#   fm_release_sort                         - stdin release names, stdout newest first
#   fm_update_channel_value_valid <value>   - 0 for main, release, or a release name
#   fm_update_channel_resolve <config-dir>  - sets FM_UPDATE_CHANNEL; on a
#                                             malformed file returns 1 with
#                                             FM_UPDATE_CHANNEL_DIAG set
#   fm_release_fetch_tags <dir>             - fetch origin's release tags once per
#                                             object store; never moves a local tag
#   fm_release_list <dir> <ref>             - releases on <ref>, newest first
#   fm_release_newest <dir> <ref>           - newest release on <ref>
#   fm_release_at <dir> <commit> <ref>      - newest release pointing exactly at <commit>
#   fm_release_previous <dir> <ref> <name>  - the release just before <name>

fm_release_name_valid() {
  printf '%s\n' "$1" | grep -Eqx 'starship-[0-9]{4}\.(0[1-9]|1[0-2])(\.[1-9][0-9]{0,3})?'
}

fm_release_sort() {
  local name
  while IFS= read -r name; do
    fm_release_name_valid "$name" || continue
    printf '%s\n' "$name" | awk -F'[-.]' '{ print $2 "\t" $3 "\t" ($4 == "" ? 0 : $4) "\t" $0 }'
  done | sort -t "$(printf '\t')" -k1,1nr -k2,2nr -k3,3nr | cut -f4
}

fm_update_channel_value_valid() {
  case "$1" in
    main|release) return 0 ;;
  esac
  fm_release_name_valid "$1"
}

# Output globals, read by the sourcing caller.
# shellcheck disable=SC2034
FM_UPDATE_CHANNEL=main
# shellcheck disable=SC2034
FM_UPDATE_CHANNEL_DIAG=
# shellcheck disable=SC2034
fm_update_channel_resolve() {
  local file="${1%/}/update-channel" values count
  FM_UPDATE_CHANNEL=main
  FM_UPDATE_CHANNEL_DIAG=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_UPDATE_CHANNEL_DIAG="config/update-channel is not a readable regular file"
    return 1
  fi
  values=$(sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$file" | grep -v -e '^$' -e '^#') || true
  count=$(printf '%s' "$values" | grep -c '^' || true)
  if [ "$count" -ne 1 ] || ! fm_update_channel_value_valid "$values"; then
    FM_UPDATE_CHANNEL_DIAG="config/update-channel must hold one line: main, release, or a release name such as starship-2026.11"
    return 1
  fi
  FM_UPDATE_CHANNEL=$values
}

# Release tags come from an explicit refspec without "+", so a local tag that
# already names a different commit makes the fetch fail instead of moving: a
# rewritten release upstream stops the update rather than silently following it.
FM_RELEASE_TAGS_FETCHED=""
fm_release_fetch_tags() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case " $FM_RELEASE_TAGS_FETCHED " in
      *" $common "*) return 0 ;;
    esac
  fi
  git -C "$dir" fetch --quiet --no-tags origin 'refs/tags/starship-*:refs/tags/starship-*' 2>/dev/null || return 1
  [ -z "$common" ] || FM_RELEASE_TAGS_FETCHED="$FM_RELEASE_TAGS_FETCHED $common"
}

fm_release_list() {
  local dir=$1 ref=$2 name
  git -C "$dir" for-each-ref --format='%(refname:strip=2)' 'refs/tags/starship-*' 2>/dev/null \
    | while IFS= read -r name; do
        fm_release_name_valid "$name" || continue
        git -C "$dir" merge-base --is-ancestor "refs/tags/$name^{commit}" "$ref" 2>/dev/null || continue
        printf '%s\n' "$name"
      done | fm_release_sort
}

fm_release_newest() {
  fm_release_list "$1" "$2" | head -1
}

fm_release_at() {
  local dir=$1 commit=$2 ref=$3 name
  while IFS= read -r name; do
    if [ "$(git -C "$dir" rev-parse --verify --quiet "refs/tags/$name^{commit}")" = "$commit" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(fm_release_list "$dir" "$ref")
  return 1
}

fm_release_previous() {
  fm_release_list "$1" "$2" | awk -v cur="$3" 'found { print; exit } $0 == cur { found = 1 }'
}
