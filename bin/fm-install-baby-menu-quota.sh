#!/usr/bin/env bash
# fm-install-baby-menu-quota.sh - install the tracked Baby Menu quota widget into
# a Baby Menu home.
#
# Copies assets/baby-menu/weekly-quota/ into <home>/extensions/weekly-quota/ and
# seeds an example machine-local settings file. Baby Menu watches its extensions
# directory and rebuilds the widget itself, so no restart is issued here and the
# running app is never started, stopped, or otherwise driven by this script.
#
# What it will not do:
#   - touch any other extension, the app bundle, preferences, credentials, or the
#     app database
#   - overwrite an existing <home>/weekly-quota.local.json (that file is the
#     machine's own setting and is never tracked)
#   - carry any source machine's paths: the tracked sources contain none
#
# Re-running is safe. When an installed widget already differs from the tracked
# sources, the previous copy is kept as
# <home>/extensions/.weekly-quota-backup-<UTC timestamp>.<unique>/ before it is
# replaced. Each replacing install gets its own backup directory, so one never
# lands inside another.
#
# Usage:
#   fm-install-baby-menu-quota.sh [--home <baby-menu-home>] [--dry-run] [--force]
#   fm-install-baby-menu-quota.sh --help
#
# Options:
#   --home <dir>  Baby Menu home to install into. Default: $BABY_MENU_HOME, else
#                 ~/.baby-menu. The directory must already exist - Baby Menu
#                 creates it on first run, and creating it here would hide a
#                 typo'd path as a silently successful install.
#   --dry-run     Report what would change and write nothing.
#   --force       Reinstall even when the installed files already match.
#
# Exit status is non-zero when the home is missing or a copy fails.
set -eu

SELF=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE_DIR="$ROOT/assets/baby-menu/weekly-quota"
WIDGET_FILES="components.tsx local-settings.ts quota-windows.ts server.ts store.ts widget.tsx"
LOCAL_SETTINGS_NAME=weekly-quota.local.json
EXAMPLE_SETTINGS_NAME=weekly-quota.local.example.json

die() {
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit 1
}

note() {
  printf '%s: %s\n' "$SELF" "$*"
}

usage() {
  sed -n '2,/^set -eu/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

HOME_DIR=${BABY_MENU_HOME:-}
DRY_RUN=0
FORCE=0

while [ $# -gt 0 ]; do
  case $1 in
    --home)
      [ $# -ge 2 ] || die "--home needs a directory"
      HOME_DIR=$2
      shift 2
      ;;
    --home=*)
      HOME_DIR=${1#--home=}
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument '$1' (see --help)"
      ;;
  esac
done

[ -n "$HOME_DIR" ] || HOME_DIR="${HOME:?HOME is not set}/.baby-menu"

[ -d "$SOURCE_DIR" ] || die "tracked widget sources are missing at $SOURCE_DIR"
for file in $WIDGET_FILES; do
  [ -f "$SOURCE_DIR/$file" ] || die "tracked widget source $file is missing"
done

# Baby Menu creates its own home on first run. Requiring it to exist keeps a
# mistyped --home from installing a widget into a directory no app will ever read.
[ -e "$HOME_DIR" ] || die "Baby Menu home '$HOME_DIR' does not exist; run Baby Menu once first, or pass --home"
[ -d "$HOME_DIR" ] || die "Baby Menu home '$HOME_DIR' is not a directory"

EXTENSIONS_DIR="$HOME_DIR/extensions"
TARGET_DIR="$EXTENSIONS_DIR/weekly-quota"

up_to_date=1
for file in $WIDGET_FILES; do
  if ! cmp -s "$SOURCE_DIR/$file" "$TARGET_DIR/$file"; then
    up_to_date=0
    break
  fi
done
# An installed copy carrying files the tracked widget no longer ships is not up
# to date either.
if [ "$up_to_date" -eq 1 ] && [ -d "$TARGET_DIR" ]; then
  for existing in "$TARGET_DIR"/*; do
    [ -e "$existing" ] || continue
    case " $WIDGET_FILES " in
      *" $(basename "$existing") "*) ;;
      *) up_to_date=0 ;;
    esac
  done
fi

if [ "$up_to_date" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  note "widget already matches the tracked sources in $TARGET_DIR; nothing to do"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    note "would install the widget into $TARGET_DIR"
    [ -d "$TARGET_DIR" ] && note "would keep the current copy as a timestamped backup beside it"
  else
    mkdir -p "$EXTENSIONS_DIR"
    if [ -d "$TARGET_DIR" ]; then
      # A directory name starting with a dot is not itself a widget, so the
      # backup cannot be loaded as a second copy of this extension. mktemp, not
      # the timestamp alone, decides the name: a timestamp has one-second
      # resolution, and two replacing installs within the same second would
      # otherwise resolve to one path and nest the second backup inside the
      # first while this script reported the top level.
      backup=$(mktemp -d "$EXTENSIONS_DIR/.weekly-quota-backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") \
        || die "could not create a backup directory in $EXTENSIONS_DIR"
      # The directory already exists, so the contents are copied into it rather
      # than the directory into itself.
      cp -R "$TARGET_DIR/." "$backup/" || die "could not back up the installed widget to $backup"
      note "kept the previous copy at $backup"
      rm -rf "$TARGET_DIR"
    fi
    mkdir -p "$TARGET_DIR"
    for file in $WIDGET_FILES; do
      cp "$SOURCE_DIR/$file" "$TARGET_DIR/$file" || die "could not install $file"
    done
    note "installed the quota widget into $TARGET_DIR"
  fi
fi

# The machine-local settings file is the operator's, not the installer's. Only an
# example is ever written, and only when the real file is absent.
LOCAL_SETTINGS="$HOME_DIR/$LOCAL_SETTINGS_NAME"
EXAMPLE_SETTINGS="$HOME_DIR/$EXAMPLE_SETTINGS_NAME"
if [ -e "$LOCAL_SETTINGS" ]; then
  note "keeping your existing $LOCAL_SETTINGS_NAME untouched"
elif [ "$DRY_RUN" -eq 1 ]; then
  note "would write an example settings file to $EXAMPLE_SETTINGS"
else
  cat >"$EXAMPLE_SETTINGS" <<'EOF'
{
  "_comment": "Copy to weekly-quota.local.json and edit. Optional: without it the panel simply shows the one Claude seat this machine is signed into.",
  "claudeTeamConfigDir": "/absolute/path/to/the/second/seat/claude/config/dir",
  "claudeTeamSeatLabel": "TEAM"
}
EOF
  note "wrote an example settings file to $EXAMPLE_SETTINGS"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  note "Baby Menu rebuilds a changed widget on its own; no restart is needed"
fi
