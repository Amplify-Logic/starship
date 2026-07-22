#!/usr/bin/env bash
# Resolve a project slug to the human display name used on captain-facing UI.
#
# Usage: fm-project-display-name.sh <project-slug>
#
# This script is the single owner of project display-name resolution.
# Explicit entries preserve brand casing, acronyms, and names that cannot be
# inferred from a repository basename.
# Unknown slugs use a documented synthesized fallback: split on dash,
# underscore, and dot boundaries, then capitalize each word.
# The fallback is presentation only and is never claimed to be an authoritative
# human title.
set -eu

slug=${1:?usage: fm-project-display-name.sh <project-slug>}

case "$slug" in
  api-platform) printf '%s\n' 'API Platform' ;;
  starship|firstmate) printf '%s\n' 'Starship' ;;
  *)
    printf '%s\n' "$slug" | awk '
      BEGIN { FS="[-_.]+"; OFS=" " }
      {
        for (i = 1; i <= NF; i++) {
          if ($i == "") continue
          $i = toupper(substr($i, 1, 1)) substr($i, 2)
        }
        print
      }
    '
    ;;
esac
