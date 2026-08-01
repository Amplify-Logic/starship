#!/usr/bin/env bash
# Install and inspect the local weekly upstream-watch schedule on macOS launchd.
#
# Usage:
#   fm-upstream-watch-schedule.sh render
#   fm-upstream-watch-schedule.sh install
#   fm-upstream-watch-schedule.sh status
#   fm-upstream-watch-schedule.sh remove
#   fm-upstream-watch-schedule.sh --help
#
# The schedule is intentionally visible, not an opaque cron entry.
# `render` prints the complete plist, `status` prints its path and contents, and
# `install` writes ~/Library/LaunchAgents/<label>.plist before loading it.
# The default interval is 604800 seconds (weekly).
# Override it with FM_UPSTREAM_WATCH_INTERVAL_SECONDS or a private
# config/upstream-watch line: `interval_seconds = N`.
# launchd calls bin/fm-upstream-watch.sh run; generation remains separately
# callable by a future private-repository workflow.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DEFAULT_INTERVAL=604800

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-upstream-watch-schedule: %s\n' "$*" >&2
  exit 2
}

interval_seconds() {
  local value=${FM_UPSTREAM_WATCH_INTERVAL_SECONDS:-} line key parsed
  if [ -z "$value" ] && [ -f "$CONFIG/upstream-watch" ]; then
    while IFS= read -r line; do
      line=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      case "$line" in ''|'#'*) continue ;; esac
      key=${line%%=*}
      parsed=${line#*=}
      key=$(printf '%s\n' "$key" | tr -d '[:space:]')
      parsed=$(printf '%s\n' "$parsed" | tr -d '[:space:]')
      [ "$key" = interval_seconds ] || die "unknown config key: $key"
      [ -z "$value" ] || die 'duplicate interval_seconds setting'
      value=$parsed
    done <"$CONFIG/upstream-watch"
  fi
  [ -n "$value" ] || value=$DEFAULT_INTERVAL
  case "$value" in ''|*[!0-9]*|0) die "interval_seconds must be a positive integer: $value" ;; esac
  printf '%s\n' "$value"
}

xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&apos;/g'
}

home_key=$(printf '%s' "$FM_HOME" | cksum | awk '{print $1}')
LABEL="dev.firstmate.upstream-watch.$home_key"
AGENTS_DIR=${FM_UPSTREAM_WATCH_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
PLIST="$AGENTS_DIR/$LABEL.plist"

render() {
  local interval root home program stdout stderr
  interval=$(interval_seconds)
  root=$(xml_escape "$ROOT")
  home=$(xml_escape "$FM_HOME")
  program=$(xml_escape "$SCRIPT_DIR/fm-upstream-watch.sh")
  stdout=$(xml_escape "$DATA/upstream-watch/launchd.stdout.log")
  stderr=$(xml_escape "$DATA/upstream-watch/launchd.stderr.log")
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$program</string>
    <string>run</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$root</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key>
    <string>$home</string>
    <key>FM_ROOT_OVERRIDE</key>
    <string>$root</string>
  </dict>
  <key>StartInterval</key>
  <integer>$interval</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$stdout</string>
  <key>StandardErrorPath</key>
  <string>$stderr</string>
</dict>
</plist>
EOF
}

install_schedule() {
  local tmp domain
  [ "$(uname)" = Darwin ] || die 'install requires macOS launchd; use render for an inspectable scheduler definition'
  mkdir -p "$AGENTS_DIR" "$DATA/upstream-watch"
  tmp=$(mktemp "$AGENTS_DIR/.upstream-watch.XXXXXX")
  render >"$tmp"
  chmod 600 "$tmp"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; die 'rendered plist failed plutil validation'; }
  fi
  mv -f "$tmp" "$PLIST"
  domain="gui/$(id -u)"
  launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$PLIST"
  printf 'installed: %s\n' "$PLIST"
  printf 'interval_seconds: %s\n' "$(interval_seconds)"
}

status_schedule() {
  printf 'plist: %s\n' "$PLIST"
  printf 'interval_seconds: %s\n' "$(interval_seconds)"
  if [ -f "$PLIST" ]; then
    printf '%s\n' '--- installed definition ---'
    cat "$PLIST"
    if [ "$(uname)" = Darwin ]; then
      printf '%s\n' '--- launchd status ---'
      launchctl print "gui/$(id -u)/$LABEL" 2>&1 || true
    fi
  else
    printf 'not installed; inspect the proposed definition with: %s render\n' "$0"
  fi
}

remove_schedule() {
  [ "$(uname)" = Darwin ] || die 'remove requires macOS launchd'
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  printf 'removed: %s\n' "$PLIST"
}

case "${1:-}" in
  render) [ "$#" -eq 1 ] || die 'render takes no arguments'; render ;;
  install) [ "$#" -eq 1 ] || die 'install takes no arguments'; install_schedule ;;
  status) [ "$#" -eq 1 ] || die 'status takes no arguments'; status_schedule ;;
  remove) [ "$#" -eq 1 ] || die 'remove takes no arguments'; remove_schedule ;;
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
