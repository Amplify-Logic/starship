#!/usr/bin/env bash
# Shared macOS launchd LaunchAgent installer for this fork's scheduled owners.
#
# Every scheduled job here wants the same thing: one inspectable per-home
# LaunchAgent, rendered as a complete plist, lint-checked before it is written,
# and reloaded with bootout-then-bootstrap. That logic lives here once so a fix
# to the plist body or the load sequence cannot land in one owner and rot in
# the other. Each owner keeps what is genuinely its own: its cadence source,
# its opt-in policy, and whatever it arms or disarms alongside the agent.
#
# The label is derived from FM_HOME, so each operational home installs its own
# agent and installing in one home never disturbs another home's schedule.
#
# Sourcing contract. Set these before sourcing; the label and plist path are
# resolved at source time:
#   FM_LAUNCHD_STEM             label stem, also the staged plist name prefix
#   FM_LAUNCHD_PROGRAM          absolute path launchd executes
#   FM_LAUNCHD_PROGRAM_ARG      the single argument it is executed with
#   FM_LAUNCHD_ROOT             WorkingDirectory, also FM_ROOT_OVERRIDE
#   FM_LAUNCHD_FM_HOME          FM_HOME for the scheduled job
#   FM_LAUNCHD_LOG_DIR          directory receiving the job's launchd logs
#   FM_LAUNCHD_AGENTS_DIR       LaunchAgents directory to write the plist into
#   FM_LAUNCHD_LAUNCHCTL        launchctl transport; overridable so a suite can
#                               install against a temporary home without ever
#                               loading anything into a real launchd session
#   FM_LAUNCHD_REMOVE_NEEDS_DARWIN  true to refuse `remove` away from macOS
#
# The sourcing script must also define `die` and `fm_launchd_interval`, and may
# define any of these optional hooks, which are called only when they exist:
#   fm_launchd_preinstall     refuse or prepare before anything is written
#   fm_launchd_postinstall    arm whatever else belongs with a loaded agent
#   fm_launchd_postremove     disarm it again
#   fm_launchd_status_detail  owner-specific lines printed under `status`

FM_LAUNCHD_LABEL="dev.firstmate.$FM_LAUNCHD_STEM.$(printf '%s' "$FM_LAUNCHD_FM_HOME" | cksum | awk '{print $1}')"
FM_LAUNCHD_PLIST="$FM_LAUNCHD_AGENTS_DIR/$FM_LAUNCHD_LABEL.plist"

fm_launchd_xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&apos;/g'
}

fm_launchd_hook() {
  local hook=$1
  declare -F "$hook" >/dev/null 2>&1 || return 0
  "$hook"
}

# `StartInterval` plus `RunAtLoad` is the whole trigger: launchd runs the job at
# login and then on the interval, and an interval that elapsed while the machine
# slept runs shortly after it wakes. There is no lid-open event here.
fm_launchd_render() {
  local interval root home program stdout stderr
  interval=$(fm_launchd_interval)
  root=$(fm_launchd_xml_escape "$FM_LAUNCHD_ROOT")
  home=$(fm_launchd_xml_escape "$FM_LAUNCHD_FM_HOME")
  program=$(fm_launchd_xml_escape "$FM_LAUNCHD_PROGRAM")
  stdout=$(fm_launchd_xml_escape "$FM_LAUNCHD_LOG_DIR/launchd.stdout.log")
  stderr=$(fm_launchd_xml_escape "$FM_LAUNCHD_LOG_DIR/launchd.stderr.log")
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$FM_LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$program</string>
    <string>$FM_LAUNCHD_PROGRAM_ARG</string>
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

fm_launchd_install() {
  local tmp domain
  [ "$(uname)" = Darwin ] || die 'install requires macOS launchd; use render for an inspectable scheduler definition'
  fm_launchd_hook fm_launchd_preinstall
  mkdir -p "$FM_LAUNCHD_AGENTS_DIR" "$FM_LAUNCHD_LOG_DIR"
  tmp=$(mktemp "$FM_LAUNCHD_AGENTS_DIR/.$FM_LAUNCHD_STEM.XXXXXX")
  fm_launchd_render >"$tmp"
  chmod 600 "$tmp"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; die 'rendered plist failed plutil validation'; }
  fi
  mv -f "$tmp" "$FM_LAUNCHD_PLIST"
  domain="gui/$(id -u)"
  "$FM_LAUNCHD_LAUNCHCTL" bootout "$domain/$FM_LAUNCHD_LABEL" >/dev/null 2>&1 || true
  "$FM_LAUNCHD_LAUNCHCTL" bootstrap "$domain" "$FM_LAUNCHD_PLIST"
  fm_launchd_hook fm_launchd_postinstall
  printf 'installed: %s\n' "$FM_LAUNCHD_PLIST"
  printf 'interval_seconds: %s\n' "$(fm_launchd_interval)"
}

fm_launchd_status() {
  printf 'plist: %s\n' "$FM_LAUNCHD_PLIST"
  fm_launchd_hook fm_launchd_status_detail
  if [ -f "$FM_LAUNCHD_PLIST" ]; then
    printf '%s\n' '--- installed definition ---'
    cat "$FM_LAUNCHD_PLIST"
    if [ "$(uname)" = Darwin ]; then
      printf '%s\n' '--- launchd status ---'
      "$FM_LAUNCHD_LAUNCHCTL" print "gui/$(id -u)/$FM_LAUNCHD_LABEL" 2>&1 || true
    fi
  else
    printf 'not installed; inspect the proposed definition with: %s render\n' "$0"
  fi
}

fm_launchd_remove() {
  [ "${FM_LAUNCHD_REMOVE_NEEDS_DARWIN:-false}" != true ] || [ "$(uname)" = Darwin ] \
    || die 'remove requires macOS launchd'
  "$FM_LAUNCHD_LAUNCHCTL" bootout "gui/$(id -u)/$FM_LAUNCHD_LABEL" >/dev/null 2>&1 || true
  rm -f "$FM_LAUNCHD_PLIST"
  fm_launchd_hook fm_launchd_postremove
  printf 'removed: %s\n' "$FM_LAUNCHD_PLIST"
}
