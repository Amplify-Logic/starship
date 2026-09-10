#!/usr/bin/env bash
# Install or remove Firstmate's status line in Cursor CLI's existing user config.
#
# Usage:
#   fm-cursor-statusline.sh status
#   fm-cursor-statusline.sh install
#   fm-cursor-statusline.sh uninstall
#
# Cursor CLI 2026.09.08 exposes a native custom status line as a single
# `statusLine` object in its user config, and validates it ONLY there: a
# per-project .cursor/cli.json rejects the key outright. There is therefore no
# tracked in-repo integration for Cursor the way .claude/settings.json is one
# for Claude, so this opt-in installer writes that one key into the config the
# captain already uses.
#
# It is deliberately narrow:
#   - exactly one key, `statusLine`, is added, replaced, or removed;
#   - every other setting, including model choice and permissions, is preserved;
#   - credentials are never read, copied, moved, or linked (Cursor stores auth
#     outside this file, so the existing login is untouched either way);
#   - install backs the file up first and uninstall restores the key's prior
#     state, so the change is reversible from any checkout: the key is
#     recognised as ours by the renderer invocation it ends with, not by the
#     absolute path of the checkout that installed it.
#
# The installed command is inert unless bin/fm-primary.sh supplied
# FM_PRIMARY_HARNESS=cursor, so an unguarded manual `cursor-agent` run renders
# nothing and behaves exactly as before.
#
# docs/status-bar.md owns the field contract.
set -u

SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(CDPATH='' cd -P -- "$SCRIPT_DIR/.." && pwd -P)

CONFIG_DIR=${CURSOR_CONFIG_DIR:-$HOME/.cursor}
CONFIG="$CONFIG_DIR/cli-config.json"
RENDERER="$FM_ROOT/bin/fm-status-bar.sh"
# Ownership is decided by the renderer invocation, not by the absolute path that
# happens to lead to it: a key installed from the main checkout must still be
# recognised as ours by an uninstall run from a worktree.
OWNED_SUFFIX='bin/fm-status-bar.sh --adapter cursor'

die() {
  echo "fm-cursor-statusline: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required"

command_for() {
  printf '%s --adapter cursor' "$RENDERER"
}

# Presence, not shape, decides ownership: a statusLine that is a non-object, or
# an object with no command key, is still somebody else's key and is refused in
# both directions rather than silently replaced.
statusline_present() {
  jq -e '(.statusLine? // null) != null' "$CONFIG" >/dev/null 2>&1
}

statusline_is_ours() {
  jq -e --arg suffix "$OWNED_SUFFIX" \
    '((.statusLine? | objects | .command) // "") | strings | endswith($suffix)' \
    "$CONFIG" >/dev/null 2>&1
}

statusline_describe() {
  jq -r '(.statusLine? | objects | .command) // (.statusLine | tojson)' "$CONFIG" 2>/dev/null
}

case "${1:-}" in
  status)
    [ -f "$CONFIG" ] || { echo "absent: no Cursor config at $CONFIG"; exit 0; }
    jq -e . "$CONFIG" >/dev/null 2>&1 || die "could not read $CONFIG"
    if ! statusline_present; then
      echo "not-installed: $CONFIG has no statusLine"
    elif statusline_is_ours; then
      if [ "$(statusline_describe)" = "$(command_for)" ]; then
        echo "installed: $CONFIG statusLine is this Firstmate renderer"
      else
        echo "installed: $CONFIG statusLine is a Firstmate renderer from another checkout: $(statusline_describe)"
      fi
    else
      echo "foreign: $CONFIG statusLine belongs to something else: $(statusline_describe)"
    fi
    ;;
  install)
    [ -f "$CONFIG" ] \
      || die "no Cursor config at $CONFIG; run cursor-agent once first so it writes its own settings"
    [ -x "$RENDERER" ] || die "missing renderer: $RENDERER"
    jq -e . "$CONFIG" >/dev/null 2>&1 || die "$CONFIG is not valid JSON; refusing to rewrite it"
    if statusline_present && ! statusline_is_ours; then
      die "$CONFIG already has a different statusLine ($(statusline_describe)); remove it by hand first"
    fi
    backup="$CONFIG.fm-backup.$(date +%Y%m%d%H%M%S)"
    cp "$CONFIG" "$backup" || die "could not back up $CONFIG"
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-cursor-statusline.XXXXXX") || die "could not create a temporary file"
    jq --arg cmd "$(command_for)" \
      '.statusLine = {type: "command", command: $cmd, updateIntervalMs: 1000, timeoutMs: 5000}' \
      "$CONFIG" > "$tmp" 2>/dev/null || { rm -f "$tmp"; die "could not build the updated config"; }
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "refusing to install invalid JSON"; }
    cat "$tmp" > "$CONFIG" || { rm -f "$tmp"; die "could not write $CONFIG"; }
    rm -f "$tmp"
    echo "installed: statusLine added to $CONFIG"
    echo "backup:    $backup"
    echo "note:      the row renders only under a guarded Firstmate Cursor launch"
    ;;
  uninstall)
    [ -f "$CONFIG" ] || { echo "absent: no Cursor config at $CONFIG"; exit 0; }
    jq -e . "$CONFIG" >/dev/null 2>&1 || die "$CONFIG is not valid JSON; refusing to rewrite it"
    statusline_present || { echo "not-installed: nothing to remove"; exit 0; }
    statusline_is_ours \
      || die "$CONFIG statusLine belongs to something else ($(statusline_describe)); refusing to remove it"
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-cursor-statusline.XXXXXX") || die "could not create a temporary file"
    jq 'del(.statusLine)' "$CONFIG" > "$tmp" 2>/dev/null \
      || { rm -f "$tmp"; die "could not build the updated config"; }
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "refusing to install invalid JSON"; }
    cat "$tmp" > "$CONFIG" || { rm -f "$tmp"; die "could not write $CONFIG"; }
    rm -f "$tmp"
    echo "uninstalled: statusLine removed from $CONFIG"
    ;;
  *)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
