#!/usr/bin/env bash
# fm-factory-pane.sh - the Herdr side of the Factory pane.
#
# The Factory pane is a Herdr plugin pane (herdr-plugins/starship-factory/)
# that draws the factory record bin/fm-factory.py builds. This script owns the
# Herdr lifecycle: linking the plugin, showing the pane beside a pane, and
# stopping what it started. bin/fm-factory.py owns the record, the screen, the
# keys and the factory tabs; docs/factory-pane.md owns what the pane shows.
#
# Usage:
#   fm-factory-pane.sh install   link the plugin into Herdr, remember this home,
#                                and, when run inside a Herdr pane, show the
#                                Factory pane beside that pane
#   fm-factory-pane.sh remove    stop every running Factory pane and factory tab
#                                page (their panes close with them) and unlink
#                                the plugin
#   fm-factory-pane.sh open [--pane ID] [--item ID]
#                                show the Factory pane to the right of a pane
#                                (default: the pane this runs in, or the
#                                focused pane when Herdr runs the plugin action).
#                                With --item the highlight goes to that item of
#                                NEEDS YOU; a Factory pane already showing in
#                                this tab moves its highlight there instead of
#                                a second pane opening.
#   fm-factory-pane.sh run [--factory ID] [--origin-tab ID]
#                                the pane itself; Herdr starts it. With
#                                --factory it is that factory's tab page.
#                                FM_FACTORY_ITEM, which open passes, names the
#                                item the highlight starts on.
#   fm-factory-pane.sh follow <task-id>
#                                a read-only live copy of one worker's pane, for
#                                a factory tab
#
# Installing the pane is the owner's opt-in to its Already settled? key, so
# `install` binds the pane's reconcile source id (`factory-pane`) through
# bin/fm-captain-hold.sh bind and `remove` unbinds it; nothing else binds it,
# so a pane installed before the key existed needs one `install` again.
#
# `remove` finds running panes only through the records each one keeps in the
# plugin's Herdr config directory, and stops a recorded process only after
# checking it is still this script's pane, so it never closes another pane.
# Those records also name which kind of pane each is (view=overview, page or
# follow), so `open --item` can find an overview already in its tab; it asks
# that pane to move its highlight by writing the item id to focus/<pid> in the
# same directory, which the pane reads and removes.
#
# Environment:
#   FM_HOME                       the home whose factories are shown. Unset, the
#                                 home `install` recorded is used, else this
#                                 code root.
#   HERDR_BIN_PATH                the Herdr binary (default: herdr on PATH)
# Test seams:
#   FM_FACTORY_PANE_CONFIG_DIR    the plugin's config directory, instead of
#                                 asking Herdr
# Exit: 0 on success; 1 when a step fails, with the reason on stderr; 2 on a
# usage error.
set -u

SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(CDPATH='' cd -P -- "$SCRIPT_DIR/.." && pwd -P)
PLUGIN_ID=starship.factory
PLUGIN_DIR="$ROOT/herdr-plugins/starship-factory"
ME=fm-factory-pane.sh

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 1; }

# The pane's reconcile source; bin/fm-factory.py files requests under it.
SETTLED_SOURCE=factory-pane

bind_settled() {  # <home>
  FM_HOME=$1 bash "$SCRIPT_DIR/fm-captain-hold.sh" bind "$SETTLED_SOURCE" >/dev/null
}

herdr_bin() { printf '%s' "${HERDR_BIN_PATH:-herdr}"; }

config_dir() {
  local dir=${FM_FACTORY_PANE_CONFIG_DIR:-${HERDR_PLUGIN_CONFIG_DIR:-}}
  [ -n "$dir" ] || dir=$("$(herdr_bin)" plugin config-dir "$PLUGIN_ID" 2>/dev/null | tail -n 1) || dir=
  [ -n "$dir" ] || return 1
  printf '%s' "$dir"
}

resolve_home() {
  local dir recorded
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s' "$FM_HOME"
    return 0
  fi
  if dir=$(config_dir) && [ -f "$dir/home" ]; then
    recorded=$(head -n 1 "$dir/home")
    [ -z "$recorded" ] || { printf '%s' "$recorded"; return 0; }
  fi
  printf '%s' "$ROOT"
}

# A running pane is recorded as panes/<pid> so `remove` can stop it and `open
# --item` can find an overview in its tab.
record_self() {  # <view: overview|page|follow>
  local dir
  dir=$(config_dir) || return 0
  mkdir -p "$dir/panes" 2>/dev/null || return 0
  printf 'pane=%s\ntab=%s\nsession=%s\nview=%s\n' "${HERDR_PANE_ID:-}" "${HERDR_TAB_ID:-}" \
    "${HERDR_SOCKET_PATH:-}" "$1" > "$dir/panes/$$" 2>/dev/null || return 0
  printf '%s' "$dir/panes/$$"
}

record_value() {  # <file> <key>
  awk -F= -v k="$2" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$1" 2>/dev/null
}

# is_pane_pid: the recorded process is still one of this script's panes.
is_pane_pid() {  # <pid>
  local cmd
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  cmd=$(ps -p "$1" -o command= 2>/dev/null) || return 1
  case "$cmd" in *"$ME run"|*"$ME run "*|*"$ME follow "*) return 0 ;; esac
  return 1
}

cmd_run() {
  local home record status view=overview focus='' arg start=()
  home=$(resolve_home)
  for arg in "$@"; do
    [ "$arg" != --factory ] || view=page
  done
  record=$(record_self "$view")
  if [ "$view" = overview ]; then
    [ -z "${FM_FACTORY_ITEM:-}" ] || start=(--item "$FM_FACTORY_ITEM")
    [ -z "$record" ] || focus="${record%/panes/*}/focus/$$"
  fi
  FM_HOME=$home FM_FACTORY_FOCUS_FILE=$focus python3 "$SCRIPT_DIR/fm-factory.py" view \
    ${start[@]+"${start[@]}"} "$@"
  status=$?
  [ -z "$record" ] || rm -f "$record" 2>/dev/null
  [ -z "$focus" ] || rm -f "$focus" 2>/dev/null
  return "$status"
}

cmd_follow() {
  local home record status
  [ "$#" -eq 1 ] || { usage; exit 2; }
  home=$(resolve_home)
  record=$(record_self follow)
  FM_HOME=$home python3 "$SCRIPT_DIR/fm-factory.py" follow "$1"
  status=$?
  [ -z "$record" ] || rm -f "$record" 2>/dev/null
  return "$status"
}

cmd_open() {
  local target=${HERDR_PANE_ID:-} out pane home item='' dir rec pid tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pane) target=${2:-}; shift ;;
      --item) item=${2:-}; shift; [ -n "$item" ] || { usage; exit 2; } ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  # An overview already showing in this tab of this Herdr session moves its
  # highlight to the item rather than a second pane opening beside it.
  if [ -n "$item" ] && [ -n "${HERDR_TAB_ID:-}" ] && dir=$(config_dir); then
    for rec in "$dir"/panes/*; do
      [ -f "$rec" ] || continue
      pid=$(basename "$rec")
      is_pane_pid "$pid" || continue
      [ "$(record_value "$rec" view)" = overview ] || continue
      [ "$(record_value "$rec" tab)" = "$HERDR_TAB_ID" ] || continue
      [ "$(record_value "$rec" session)" = "${HERDR_SOCKET_PATH:-}" ] || continue
      mkdir -p "$dir/focus" 2>/dev/null || break
      tmp="$dir/focus/.$pid.$$"
      if ! { printf '%s\n' "$item" > "$tmp" && mv -f "$tmp" "$dir/focus/$pid"; } 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        break
      fi
      printf 'The Factory pane in this tab is showing that item.\n'
      return 0
    done
  fi
  [ -n "$target" ] || die "no pane to show the Factory pane beside; run this inside a Herdr pane or pass --pane"
  command -v jq >/dev/null 2>&1 || die "jq is needed to read Herdr's answer"
  home=$(resolve_home)
  out=$("$(herdr_bin)" plugin pane open --plugin "$PLUGIN_ID" --entrypoint factory \
    --placement split --direction right --target-pane "$target" --focus \
    --env "FM_HOME=$home" ${item:+--env "FM_FACTORY_ITEM=$item"} 2>&1) \
    || die "Herdr did not open the Factory pane: $out"
  pane=$(printf '%s' "$out" | jq -r '(.result.plugin_pane.pane.pane_id // .result.pane.pane_id) // empty' 2>/dev/null)
  [ -n "$pane" ] || die "Herdr opened a Factory pane beside pane $target but did not name it"
  printf 'The Factory pane is showing beside this pane.\n'
}

cmd_install() {
  local herdr dir home
  herdr=$(herdr_bin)
  [ -f "$PLUGIN_DIR/herdr-plugin.toml" ] || die "the plugin is missing from $PLUGIN_DIR"
  "$herdr" plugin link "$PLUGIN_DIR" >/dev/null || die "Herdr did not link the plugin at $PLUGIN_DIR"
  home=${FM_HOME:-$ROOT}
  dir=$(config_dir) || die "the plugin is linked, but Herdr did not say where its config lives"
  if ! { mkdir -p "$dir" && printf '%s\n' "$home" > "$dir/home"; }; then
    die "the plugin is linked, but this home could not be recorded in $dir"
  fi
  bind_settled "$home" || die "the plugin is linked, but its Already settled? key could not be bound"
  printf 'The Factory pane is installed.\n'
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    cmd_open
  else
    printf 'Show it from a Herdr pane with: %s open\n' "$0"
  fi
}

cmd_remove() {
  local herdr dir rec pid stopped=0
  herdr=$(herdr_bin)
  FM_HOME=$(resolve_home) bash "$SCRIPT_DIR/fm-captain-hold.sh" unbind "$SETTLED_SOURCE" >/dev/null 2>&1 || true
  if dir=$(config_dir); then
    for rec in "$dir"/panes/*; do
      [ -f "$rec" ] || continue
      pid=$(basename "$rec")
      if is_pane_pid "$pid"; then
        # The script is its pane's only process, so the pane closes with it.
        kill -TERM "$pid" 2>/dev/null && stopped=$((stopped + 1))
      fi
      rm -f "$rec"
    done
    rm -rf "$dir/focus"
    rm -f "$dir/home"
  fi
  "$herdr" plugin unlink "$PLUGIN_ID" >/dev/null || die "stopped $stopped pane(s), but Herdr did not unlink the plugin"
  printf 'The Factory pane is removed (%s pane(s) closed).\n' "$stopped"
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  follow) shift; cmd_follow "$@" ;;
  open) shift; cmd_open "$@" ;;
  install) shift; cmd_install "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
